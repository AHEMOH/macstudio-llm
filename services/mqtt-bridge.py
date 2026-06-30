#!/usr/bin/env python3
"""
MQTT bridge for the MacStudio LLM Server — publishes runtime telemetry to an
MQTT broker with Home Assistant autodiscovery, and lets HA switch the active
main model via a `select` entity.

Stdlib only (runs on /usr/bin/python3 as the launchd daemon
com.local.mqtt.bridge, as root). It speaks a minimal subset of MQTT 3.1.1 over
a raw socket — CONNECT (user/pass + LWT), PUBLISH/SUBSCRIBE QoS0, PINGREQ
keepalive — with an outer reconnect loop. No pip, no paho.

Data sources (all cheap, no duplication of the exporters):
  * power / GPU / thermal / memory   <- HTTP scrape of the silicon exporter
  * daemon state (text backend, OCR) <- `launchctl print system/<label>`
  * LiteLLM gateway                  <- TCP probe
  * active model / engine / ports    <- re-parse /usr/local/etc/macstudio.conf
  * RAM / disk / boot time / reboot  <- sysctl / vm_stat / statvfs / marker file
  * versions + updates (every 6 h)   <- venv importlib.metadata + PyPI + brew

Topics (prefix default `macstudio`):
  <p>/availability            online|offline  (retained, LWT)
  <p>/silicon/availability    online|offline  (retained; power sensors' 2nd avail)
  <p>/state                   JSON telemetry snapshot (retained)
  <p>/updates                 JSON versions / update counts (retained)
  <p>/model/state             active main model id (retained)
  <p>/model/status            ready | loading <id> | error: <msg> (retained)
  <p>/model/set               command: model id to switch to (subscribed)
  <discovery>/<comp>/macstudio/<obj>/config   HA discovery (retained)
  <discovery>/status          HA birth — triggers a full republish

Config via env (set by wrappers/start-mqtt-bridge.sh from macstudio.conf):
  MQTT_HOST MQTT_PORT MQTT_USER MQTT_PASS
  MQTT_TOPIC_PREFIX MQTT_DISCOVERY_PREFIX MQTT_PUBLISH_INTERVAL_SEC
"""
from __future__ import annotations

import json
import os
import queue
import re
import signal
import socket
import struct
import subprocess
import threading
import time
from datetime import datetime, timezone

# --- Fixed on-Mac paths (mirror setup.sh) ----------------------------------
CONF_FILE = "/usr/local/etc/macstudio.conf"
REPO_POINTER_FILE = "/usr/local/etc/macstudio.repo"
CATALOG_FILE = "/usr/local/etc/macstudio-models/catalog.tsv"
REBOOT_PENDING_FILE = "/var/macstudio/reboot-pending"
AUTOUPDATE_LOG = "/var/log/macstudio/autoupdate.log"
DEFAULT_HF = "/Users/mac/.cache/huggingface"
DEFAULT_VENVS = "/Users/mac/.macstudio-venvs"

LAUNCHCTL = "/bin/launchctl"
SYSCTL = "/usr/sbin/sysctl"
VM_STAT = "/usr/bin/vm_stat"
SW_VERS = "/usr/bin/sw_vers"
SUDO = "/usr/bin/sudo"
BREW = "/opt/homebrew/bin/brew"
IOREG = "/usr/sbin/ioreg"

KEEPALIVE = 60          # MQTT keepalive seconds
SLOW_INTERVAL = 6 * 3600  # version/update poll cadence
SWITCH_TIMEOUT = 300    # max seconds for a --set-model run
BACKEND_WAIT = 180      # max seconds to wait for the text backend to rebind
TCP_PROBE_TIMEOUT = 0.3
LAUNCHCTL_TIMEOUT = 2.0

THERMAL_LABEL = {0: "Nominal", 1: "Fair", 2: "Serious", 3: "Critical", 4: "Unknown"}
MEM_LABEL = {0: "Normal", 1: "Warn", 2: "Critical"}
ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")
# Mirror set_model_alias's BROKEN refusal: a bare BROKEN blocks everywhere; an
# engine-tagged BROKEN[<engine>] blocks only for that engine (so BROKEN[mlx-lm]
# is fine — and selectable — under mlx-vlm).
BARE_BROKEN_RE = re.compile(r"BROKEN([^[]|$)", re.IGNORECASE)


def is_broken_for(notes, engine):
    if BARE_BROKEN_RE.search(notes):
        return True
    return f"broken[{engine}]" in notes.lower()


def log(msg: str) -> None:
    print(f"[{time.strftime('%F %T')}][mqtt-bridge] {msg}", flush=True)


# ===========================================================================
# Minimal MQTT 3.1.1 client
# ===========================================================================
def _enc_len(n: int) -> bytes:
    out = bytearray()
    while True:
        b = n % 128
        n //= 128
        if n > 0:
            b |= 0x80
        out.append(b)
        if n == 0:
            break
    return bytes(out)


def _enc_str(s: str) -> bytes:
    b = s.encode("utf-8")
    return struct.pack("!H", len(b)) + b


class MiniMQTT:
    def __init__(self, host, port, user, password, client_id,
                 keepalive=KEEPALIVE, lwt_topic=None, lwt_payload="offline"):
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.client_id = client_id
        self.keepalive = keepalive
        self.lwt_topic = lwt_topic
        self.lwt_payload = lwt_payload
        self.sock = None
        self.alive = False
        self.lock = threading.Lock()
        self.last_activity = 0.0
        self.on_message = None
        self._pid = 0

    # -- low-level IO --------------------------------------------------------
    def _recv_exact(self, n: int) -> bytes:
        buf = bytearray()
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise ConnectionError("EOF from broker")
            buf += chunk
        return bytes(buf)

    def _read_packet(self):
        first = self._recv_exact(1)[0]
        mult, rl = 1, 0
        while True:
            b = self._recv_exact(1)[0]
            rl += (b & 0x7F) * mult
            if not (b & 0x80):
                break
            mult *= 128
            if mult > 128 ** 3:
                raise ConnectionError("malformed remaining length")
        data = self._recv_exact(rl) if rl else b""
        return first, data

    def _send(self, raw: bytes) -> None:
        with self.lock:
            if self.sock is None:
                raise ConnectionError("no socket")
            self.sock.sendall(raw)
            self.last_activity = time.monotonic()

    # -- connection ----------------------------------------------------------
    def connect(self) -> None:
        self.sock = socket.create_connection((self.host, self.port), timeout=10)
        flags = 0x02  # clean session
        payload = _enc_str(self.client_id)
        if self.lwt_topic:
            flags |= 0x04 | 0x20  # will flag + will retain (qos 0)
            payload += _enc_str(self.lwt_topic) + _enc_str(self.lwt_payload)
        if self.user:
            flags |= 0x80
            payload += _enc_str(self.user)
            if self.password:
                flags |= 0x40
                payload += _enc_str(self.password)
        var = _enc_str("MQTT") + bytes([0x04, flags]) + struct.pack("!H", self.keepalive)
        body = var + payload
        self.sock.sendall(bytes([0x10]) + _enc_len(len(body)) + body)
        typ, data = self._read_packet()
        if (typ & 0xF0) != 0x20:
            raise ConnectionError(f"expected CONNACK, got 0x{typ:02x}")
        rc = data[1] if len(data) >= 2 else -1
        if rc != 0:
            raise ConnectionError(f"CONNACK refused rc={rc}")
        self.sock.settimeout(None)  # blocking reads in the reader thread
        self.last_activity = time.monotonic()
        self.alive = True

    def publish(self, topic, payload, retain=False) -> None:
        if isinstance(payload, str):
            payload = payload.encode("utf-8")
        header = 0x30 | (0x01 if retain else 0x00)  # PUBLISH, qos 0
        body = _enc_str(topic) + payload
        self._send(bytes([header]) + _enc_len(len(body)) + body)

    def subscribe(self, topic) -> None:
        self._pid = (self._pid + 1) & 0xFFFF
        body = struct.pack("!H", self._pid or 1) + _enc_str(topic) + bytes([0x00])
        self._send(bytes([0x82]) + _enc_len(len(body)) + body)

    def ping(self) -> None:
        self._send(bytes([0xC0, 0x00]))

    def disconnect(self) -> None:
        try:
            self._send(bytes([0xE0, 0x00]))
        except Exception:
            pass
        self.alive = False
        try:
            if self.sock:
                self.sock.close()
        except Exception:
            pass
        self.sock = None

    def reader_loop(self) -> None:
        try:
            while True:
                first, data = self._read_packet()
                if (first & 0xF0) != 0x30:
                    continue  # PINGRESP / SUBACK / etc. — ignore
                qos = (first >> 1) & 0x03
                if len(data) < 2:
                    continue
                tlen = (data[0] << 8) | data[1]
                topic = data[2:2 + tlen].decode("utf-8", "replace")
                idx = 2 + tlen
                if qos > 0:
                    pid = (data[idx] << 8) | data[idx + 1]
                    idx += 2
                    if qos == 1:
                        self._send(bytes([0x40, 0x02, (pid >> 8) & 0xFF, pid & 0xFF]))
                payload = data[idx:].decode("utf-8", "replace")
                if self.on_message:
                    try:
                        self.on_message(topic, payload)
                    except Exception as exc:
                        log(f"on_message error: {exc}")
        except Exception as exc:
            log(f"reader stopped: {exc}")
        finally:
            self.alive = False
            try:
                if self.sock:
                    self.sock.close()
            except Exception:
                pass


# ===========================================================================
# Collectors (stdlib, no exporter duplication)
# ===========================================================================
def run_out(cmd, timeout=15):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except Exception:
        return None
    if p.returncode != 0:
        return None
    return p.stdout.strip()


def parse_conf(path=CONF_FILE) -> dict:
    conf = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, _, v = line.partition("=")
                k, v = k.strip(), v.strip()
                if len(v) >= 2 and v[0] == v[-1] and v[0] in ("'", '"'):
                    v = v[1:-1]
                conf[k] = v
    except OSError:
        pass
    return conf


def launchctl_state(label):
    out = run_out([LAUNCHCTL, "print", f"system/{label}"], timeout=LAUNCHCTL_TIMEOUT)
    if out is None:
        return False, 0
    pid, running = 0, False
    for line in out.splitlines():
        m = re.match(r"\s*pid\s*=\s*(\d+)", line)
        if m:
            pid = int(m.group(1))
            continue
        m = re.match(r"\s*state\s*=\s*(\w+)", line)
        if m and m.group(1).lower() == "running":
            running = True
    return (running and pid > 0), pid


def tcp_listening(port, host="127.0.0.1"):
    try:
        with socket.create_connection((host, port), TCP_PROBE_TIMEOUT):
            return True
    except OSError:
        return False


def scrape_silicon(port):
    try:
        import urllib.request
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/metrics", timeout=2) as r:
            body = r.read().decode("utf-8", "replace")
    except Exception:
        return None
    out = {}
    for line in body.splitlines():
        if line.startswith("#") or " " not in line:
            continue
        name, _, val = line.partition(" ")
        if "{" in name:  # skip labelled series (cpu clusters)
            continue
        out[name] = val
    return out


def _gv(sil, key):
    if not sil:
        return None
    try:
        return float(sil[key])
    except (KeyError, ValueError):
        return None


def model_status(repo, hf_cache):
    safe = "models--" + repo.replace("/", "--")
    d = os.path.join(hf_cache, "hub", safe)
    snaps = os.path.join(d, "snapshots")
    has_st = False
    if os.path.isdir(snaps):
        for _root, _dirs, files in os.walk(snaps):
            if any(fn.endswith(".safetensors") for fn in files):
                has_st = True
                break
    if has_st:
        blobs = os.path.join(d, "blobs")
        if os.path.isdir(blobs):
            for _root, _dirs, files in os.walk(blobs):
                if any(fn.endswith(".incomplete") for fn in files):
                    return "partial"
        return "ok"
    return "partial" if os.path.isdir(d) else "none"


def text_model_options(hf_cache, engine):
    """Catalog ids selectable for the main slot — same rule as set_model_alias:
    role=text, fully downloaded, not broken for the engine that will run it."""
    opts = []
    try:
        with open(CATALOG_FILE) as f:
            for line in f:
                if line.startswith("#") or not line.strip():
                    continue
                cols = line.rstrip("\n").split("|")
                if len(cols) < 13:
                    continue
                cid, repo, role, notes = cols[0], cols[1], cols[2], cols[12]
                if role != "text":
                    continue
                if is_broken_for(notes, engine):
                    continue
                if model_status(repo, hf_cache) != "ok":
                    continue
                opts.append(cid)
    except OSError:
        pass
    return opts


def text_daemon_label(engine):
    """launchd label of the text daemon TEXT_ENGINE selects (one runs at a time)."""
    if engine == "mlx-vlm":
        return "com.local.mlxvlm.main"
    if engine == "optiq":
        return "com.local.optiq.main"
    return "com.local.mlxlm.serve"


def ram_free_mb():
    try:
        ps = int(run_out([SYSCTL, "-n", "hw.pagesize"]) or "0")
        out = run_out([VM_STAT]) or ""
        m = re.search(r"Pages free:\s+(\d+)", out)
        if ps and m:
            return (int(m.group(1)) * ps) // 1024 // 1024
    except Exception:
        pass
    return None


def wired_limit_mb():
    try:
        return int(run_out([SYSCTL, "-n", "iogpu.wired_limit_mb"]) or "")
    except (TypeError, ValueError):
        return None


def swap_used_mb():
    # vm.swapusage: "total = 1024.00M  used = 90.56M  free = 933.44M  (encrypted)"
    out = run_out([SYSCTL, "-n", "vm.swapusage"])
    if not out:
        return None
    m = re.search(r"used\s*=\s*([0-9.]+)([KMGT]?)", out)
    if not m:
        return None
    mult = {"K": 1 / 1024, "M": 1.0, "G": 1024.0, "T": 1024.0 * 1024}[m.group(2) or "M"]
    return round(float(m.group(1)) * mult, 1)


def gpu_mem_used_mb():
    """MB the GPU allocator currently holds ('Alloc system memory' in the
    IOAccelerator registry entry). MLX model weights + KV cache live here —
    GPU-wired memory is accounted separately from vm_stat's wired pages, so
    this is the number iogpu.wired_limit_mb actually caps."""
    out = run_out([IOREG, "-r", "-d", "1", "-c", "IOAccelerator"])
    if not out:
        return None
    m = re.search(r'"Alloc system memory"\s*=\s*(\d+)', out)
    if not m:
        return None
    return int(m.group(1)) // (1024 * 1024)


def disk_free_gb(path):
    try:
        if not os.path.exists(path):
            path = "/"
        s = os.statvfs(path)
        return round(s.f_bavail * s.f_frsize / 1e9, 1)
    except OSError:
        return None


def boot_time_iso():
    out = run_out([SYSCTL, "-n", "kern.boottime"])
    if not out:
        return None
    m = re.search(r"sec\s*=\s*(\d+)", out)
    if not m:
        return None
    return datetime.fromtimestamp(int(m.group(1)), tz=timezone.utc).isoformat()


def last_autoupdate_run():
    ts = None
    try:
        with open(AUTOUPDATE_LOG) as f:
            for line in f:
                if "weekly autoupdate begin" in line:
                    m = re.search(r"(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)", line)
                    if m:
                        ts = m.group(1)
    except OSError:
        pass
    return ts or "unknown"


def pypi_latest(pkg):
    try:
        import urllib.request
        with urllib.request.urlopen(f"https://pypi.org/pypi/{pkg}/json", timeout=8) as r:
            return json.load(r)["info"]["version"]
    except Exception:
        return None


# ===========================================================================
# Bridge
# ===========================================================================
class Bridge:
    def __init__(self):
        self.host = os.environ.get("MQTT_HOST", "").strip()
        self.port = int(os.environ.get("MQTT_PORT", "1883") or 1883)
        self.user = os.environ.get("MQTT_USER", "").strip() or None
        self.password = os.environ.get("MQTT_PASS", "") or None
        self.prefix = (os.environ.get("MQTT_TOPIC_PREFIX", "macstudio").strip() or "macstudio").rstrip("/")
        self.disc_prefix = (os.environ.get("MQTT_DISCOVERY_PREFIX", "homeassistant").strip() or "homeassistant").rstrip("/")
        self.interval = max(2, int(os.environ.get("MQTT_PUBLISH_INTERVAL_SEC", "10") or 10))
        self.keepalive = KEEPALIVE

        p = self.prefix
        self.avail_topic = f"{p}/availability"
        self.sil_avail_topic = f"{p}/silicon/availability"
        self.state_topic = f"{p}/state"
        self.updates_topic = f"{p}/updates"
        self.cmd_topic = f"{p}/model/set"
        self.model_state_topic = f"{p}/model/state"
        self.model_status_topic = f"{p}/model/status"

        self.macos_version = None
        self.last_options = None
        self.busy = False
        self.stop = False
        self.slow_running = False
        self.last_slow_ts = 0.0
        self.cmd_queue = queue.Queue()

        self.mqtt = MiniMQTT(self.host, self.port, self.user, self.password,
                             client_id="macstudio-bridge", keepalive=self.keepalive,
                             lwt_topic=self.avail_topic, lwt_payload="offline")
        self.mqtt.on_message = self.on_message

    # -- HA discovery --------------------------------------------------------
    def device(self):
        d = {"identifiers": ["macstudio-llm"], "name": "Mac Studio",
             "manufacturer": "Apple", "model": "MacStudio LLM Server"}
        if self.macos_version:
            d["sw_version"] = self.macos_version
        return d

    def _entities(self):
        p = self.prefix
        st = self.state_topic
        up = self.updates_topic
        am = [{"topic": self.avail_topic}]
        asil = [{"topic": self.avail_topic}, {"topic": self.sil_avail_topic}]
        ents = []

        def add(comp, oid, cfg, avail):
            cfg["unique_id"] = f"macstudio_{oid}"
            cfg["object_id"] = f"macstudio_{oid}"
            cfg["device"] = self.device()
            cfg["availability"] = avail
            if len(avail) > 1:
                cfg["availability_mode"] = "all"
            ents.append((f"{self.disc_prefix}/{comp}/macstudio/{oid}/config", cfg))

        for oid, name, key in [("total_power", "Total Power", "total_power_w"),
                               ("package_power", "Package Power", "package_power_w"),
                               ("cpu_power", "CPU Power", "cpu_power_w"),
                               ("gpu_power", "GPU Power", "gpu_power_w"),
                               ("ane_power", "ANE Power", "ane_power_w")]:
            add("sensor", oid, {
                "name": name, "state_topic": st,
                "value_template": f"{{{{ value_json.{key} }}}}",
                "unit_of_measurement": "W", "device_class": "power",
                "state_class": "measurement",
            }, asil)
        for oid, name, key in [("cpu_temp", "CPU Temperature", "cpu_temp_c"),
                               ("gpu_temp", "GPU Temperature", "gpu_temp_c")]:
            add("sensor", oid, {
                "name": name, "state_topic": st,
                "value_template": f"{{{{ value_json.{key} }}}}",
                "unit_of_measurement": "°C", "device_class": "temperature",
                "state_class": "measurement",
            }, asil)
        add("sensor", "gpu_util", {
            "name": "GPU Utilization", "state_topic": st,
            "value_template": "{{ value_json.gpu_util_pct }}",
            "unit_of_measurement": "%", "state_class": "measurement",
            "icon": "mdi:expansion-card",
        }, asil)
        add("sensor", "thermal_pressure", {
            "name": "Thermal Pressure", "state_topic": st,
            "value_template": "{{ value_json.thermal_pressure }}",
            "icon": "mdi:thermometer",
        }, asil)
        add("sensor", "memory_pressure", {
            "name": "Memory Pressure", "state_topic": st,
            "value_template": "{{ value_json.memory_pressure }}",
            "icon": "mdi:memory",
        }, asil)
        add("sensor", "ram_free", {
            "name": "RAM Free", "state_topic": st,
            "value_template": "{{ value_json.ram_free_mb }}",
            "unit_of_measurement": "MB", "device_class": "data_size",
            "state_class": "measurement",
        }, am)
        add("sensor", "wired_limit", {
            "name": "GPU Wired Limit", "state_topic": st,
            "value_template": "{{ value_json.wired_limit_mb }}",
            "unit_of_measurement": "MB", "device_class": "data_size",
        }, am)
        add("sensor", "gpu_mem_used", {
            "name": "GPU Memory Used", "state_topic": st,
            "value_template": "{{ value_json.gpu_mem_used_mb }}",
            "unit_of_measurement": "MB", "device_class": "data_size",
            "state_class": "measurement", "icon": "mdi:memory",
        }, am)
        add("sensor", "gpu_mem_free", {
            "name": "GPU Memory Free", "state_topic": st,
            "value_template": "{{ value_json.gpu_mem_free_mb }}",
            "unit_of_measurement": "MB", "device_class": "data_size",
            "state_class": "measurement", "icon": "mdi:gauge",
        }, am)
        add("sensor", "swap_used", {
            "name": "Swap Used", "state_topic": st,
            "value_template": "{{ value_json.swap_used_mb }}",
            "unit_of_measurement": "MB", "device_class": "data_size",
            "state_class": "measurement", "icon": "mdi:swap-horizontal",
        }, am)
        add("sensor", "disk_free", {
            "name": "Model Cache Disk Free", "state_topic": st,
            "value_template": "{{ value_json.disk_free_gb }}",
            "unit_of_measurement": "GB", "device_class": "data_size",
            "state_class": "measurement", "icon": "mdi:harddisk",
        }, am)
        add("sensor", "boot_time", {
            "name": "Boot Time", "state_topic": st,
            "value_template": "{{ value_json.boot_time }}",
            "device_class": "timestamp", "icon": "mdi:clock-start",
        }, am)
        add("sensor", "active_model", {
            "name": "Active Model", "state_topic": st,
            "value_template": "{{ value_json.active_model }}", "icon": "mdi:robot",
        }, am)
        add("sensor", "text_engine", {
            "name": "Text Engine", "state_topic": st,
            "value_template": "{{ value_json.text_engine }}", "icon": "mdi:engine",
        }, am)
        add("sensor", "model_status", {
            "name": "Model Status", "state_topic": self.model_status_topic,
            "icon": "mdi:progress-clock",
        }, am)
        for oid, name, key, dclass in [
                ("text_backend", "Text Backend Running", "text_backend_running", "running"),
                ("litellm", "LiteLLM Gateway", "litellm_up", "connectivity"),
                ("glmocr_awake", "GLM-OCR Awake", "glmocr_awake", "running")]:
            add("binary_sensor", oid, {
                "name": name, "state_topic": st,
                "value_template": f"{{{{ 'ON' if value_json.{key} else 'OFF' }}}}",
                "payload_on": "ON", "payload_off": "OFF", "device_class": dclass,
            }, am)
        add("binary_sensor", "reboot_pending", {
            "name": "Restart Pending", "state_topic": st,
            "value_template": "{{ 'ON' if value_json.reboot_pending else 'OFF' }}",
            "payload_on": "ON", "payload_off": "OFF", "device_class": "problem",
            "icon": "mdi:restart-alert",
        }, am)
        add("sensor", "updates_available", {
            "name": "Updates Available", "state_topic": up,
            "value_template": "{{ value_json.updates_available }}",
            "json_attributes_topic": up, "json_attributes_template": "{{ value_json | tojson }}",
            "state_class": "measurement", "icon": "mdi:package-up",
        }, am)
        add("sensor", "last_autoupdate", {
            "name": "Last Autoupdate Run", "state_topic": up,
            "value_template": "{{ value_json.last_autoupdate_run }}", "icon": "mdi:update",
        }, am)
        return ents

    def _select_entity(self, opts):
        cfg = {
            "name": "Main Model", "unique_id": "macstudio_main_model",
            "object_id": "macstudio_main_model", "device": self.device(),
            "availability": [{"topic": self.avail_topic}],
            "command_topic": self.cmd_topic, "state_topic": self.model_state_topic,
            "options": opts if opts else ["(none downloaded)"],
            "icon": "mdi:robot-happy",
        }
        return f"{self.disc_prefix}/select/macstudio/main_model/config", cfg

    def _refresh_options(self):
        conf = parse_conf()
        hf = conf.get("HF_CACHE_DIR", DEFAULT_HF)
        opts = text_model_options(hf, conf.get("TEXT_ENGINE", "mlx-vlm"))
        active = conf.get("ALIAS_MAIN", "")
        if active and active not in opts:
            opts = [active] + opts
        return opts

    def publish_discovery(self):
        if self.last_options is None:
            self.last_options = self._refresh_options()
        for topic, cfg in self._entities():
            self.mqtt.publish(topic, json.dumps(cfg), retain=True)
        topic, cfg = self._select_entity(self.last_options)
        self.mqtt.publish(topic, json.dumps(cfg), retain=True)

    def publish_select_discovery(self, opts):
        topic, cfg = self._select_entity(opts)
        self.mqtt.publish(topic, json.dumps(cfg), retain=True)

    # -- telemetry -----------------------------------------------------------
    def publish_fast(self):
        conf = parse_conf()
        sil_port = int(conf.get("SILICON_EXPORTER_PORT", "9101") or 9101)
        sil = scrape_silicon(sil_port)
        self.mqtt.publish(self.sil_avail_topic, "online" if sil else "offline", retain=True)

        engine = conf.get("TEXT_ENGINE", "mlx-vlm")
        text_label = text_daemon_label(engine)
        text_running, _ = launchctl_state(text_label)
        litellm_port = int(conf.get("LITELLM_PORT", "11434") or 11434)
        glm_running, _ = launchctl_state("com.local.glmocr.serve")
        hf = conf.get("HF_CACHE_DIR", DEFAULT_HF)
        active = conf.get("ALIAS_MAIN", "")

        util = _gv(sil, "apple_silicon_gpu_active_ratio")
        therm = _gv(sil, "apple_silicon_thermal_pressure_level")
        mem = _gv(sil, "apple_silicon_memory_pressure_level")
        state = {
            "package_power_w": _gv(sil, "apple_silicon_package_power_watts"),
            "total_power_w": _gv(sil, "apple_silicon_sys_power_watts"),
            "cpu_temp_c": _gv(sil, "apple_silicon_cpu_temp_celsius"),
            "gpu_temp_c": _gv(sil, "apple_silicon_gpu_temp_celsius"),
            "cpu_power_w": _gv(sil, "apple_silicon_cpu_power_watts"),
            "gpu_power_w": _gv(sil, "apple_silicon_gpu_power_watts"),
            "ane_power_w": _gv(sil, "apple_silicon_ane_power_watts"),
            "gpu_util_pct": round(util * 100, 1) if util is not None else None,
            "thermal_pressure": THERMAL_LABEL.get(int(therm)) if therm is not None else None,
            "memory_pressure": MEM_LABEL.get(int(mem)) if mem is not None else None,
            "ram_free_mb": ram_free_mb(),
            "wired_limit_mb": wired_limit_mb(),
            "swap_used_mb": swap_used_mb(),
            "gpu_mem_used_mb": gpu_mem_used_mb(),
            "disk_free_gb": disk_free_gb(hf),
            "boot_time": boot_time_iso(),
            "reboot_pending": os.path.exists(REBOOT_PENDING_FILE),
            "active_model": active,
            "text_engine": engine,
            "text_backend_running": text_running,
            "litellm_up": tcp_listening(litellm_port),
            "glmocr_awake": glm_running,
        }
        # Headroom under the GPU wired-memory ceiling — what's left for a
        # bigger model / longer context before hitting iogpu.wired_limit_mb.
        if state["wired_limit_mb"] and state["gpu_mem_used_mb"] is not None:
            state["gpu_mem_free_mb"] = max(0, state["wired_limit_mb"] - state["gpu_mem_used_mb"])
        else:
            state["gpu_mem_free_mb"] = None
        self.mqtt.publish(self.state_topic, json.dumps(state), retain=True)
        if not self.busy:
            self.mqtt.publish(self.model_state_topic, active, retain=True)

        opts = text_model_options(hf, engine)
        if active and active not in opts:
            opts = [active] + opts
        if opts != self.last_options:
            self.last_options = opts
            self.publish_select_discovery(opts)

    def collect_updates(self):
        conf = parse_conf()
        venv_dir = conf.get("VENV_DIR", DEFAULT_VENVS)
        target_user = conf.get("TARGET_USER", "mac")
        result = {"updates_available": 0,
                  "macos_version": run_out([SW_VERS, "-productVersion"]) or "?"}
        n = 0
        for vn, pkg, key in [("mlxlm", "mlx-lm", "mlx_lm"),
                             ("mlxvlm", "mlx-vlm", "mlx_vlm"),
                             ("litellm", "litellm", "litellm")]:
            py = os.path.join(venv_dir, vn, "bin", "python")
            installed = "?"
            if os.path.exists(py):
                installed = run_out(
                    [py, "-c", f"import importlib.metadata as m;print(m.version('{pkg}'))"]
                ) or "?"
            latest = pypi_latest(pkg)
            result[key] = {"installed": installed, "latest": latest or "?"}
            if installed not in ("?", None) and latest and installed != latest:
                n += 1
        brew_list = []
        out = run_out([SUDO, "-u", target_user, "-H", BREW, "outdated", "--quiet"], timeout=60)
        if out:
            brew_list = [ln.strip() for ln in out.splitlines() if ln.strip()]
        result["brew_outdated"] = brew_list
        n += len(brew_list)
        result["updates_available"] = n
        result["last_autoupdate_run"] = last_autoupdate_run()
        return result

    def kick_slow(self):
        if self.slow_running:
            return
        self.slow_running = True
        self.last_slow_ts = time.monotonic()
        threading.Thread(target=self._slow_run, name="slow", daemon=True).start()

    def _slow_run(self):
        try:
            payload = self.collect_updates()
            new_macos = payload.get("macos_version")
            if new_macos and new_macos not in ("?", self.macos_version):
                self.macos_version = new_macos
                self.publish_discovery()  # sw_version lives in the device block
            self.mqtt.publish(self.updates_topic, json.dumps(payload), retain=True)
        except Exception as exc:
            log(f"slow collect error: {exc}")
        finally:
            self.slow_running = False

    # -- model switching -----------------------------------------------------
    def find_setup_sh(self):
        try:
            with open(REPO_POINTER_FILE) as f:
                for line in f:
                    if line.startswith("SETUP_SH="):
                        return line.split("=", 1)[1].strip()
        except OSError:
            pass
        return None

    def on_message(self, topic, payload):
        if topic == f"{self.disc_prefix}/status":
            if payload.strip().lower() == "online":
                log("HA birth — republishing discovery + state")
                self.publish_discovery()
                self.mqtt.publish(self.avail_topic, "online", retain=True)
                self.publish_fast()
                self.kick_slow()
            return
        if topic == self.cmd_topic:
            model = payload.strip()
            if not model:
                return
            if self.busy:
                self.mqtt.publish(self.model_status_topic, "error: switch in progress", retain=True)
                self.mqtt.publish(self.model_state_topic, parse_conf().get("ALIAS_MAIN", ""), retain=True)
                return
            self.cmd_queue.put(model)

    def worker_loop(self):
        while not self.stop:
            try:
                model = self.cmd_queue.get(timeout=1)
            except queue.Empty:
                continue
            self.busy = True
            try:
                self.do_switch(model)
            except Exception as exc:
                log(f"switch error: {exc}")
                try:
                    self.mqtt.publish(self.model_status_topic, f"error: {exc}", retain=True)
                except Exception:
                    pass
            finally:
                self.busy = False
                self.cmd_queue.task_done()

    def do_switch(self, model):
        setup = self.find_setup_sh()
        if not setup or not os.path.exists(setup):
            self.mqtt.publish(self.model_status_topic, "error: setup.sh not found", retain=True)
            return
        log(f"switching main model -> {model}")
        self.mqtt.publish(self.model_status_topic, f"loading {model}", retain=True)
        try:
            proc = subprocess.run(["/bin/bash", setup, "--set-model", "main", model],
                                  capture_output=True, text=True, timeout=SWITCH_TIMEOUT)
        except subprocess.TimeoutExpired:
            self.mqtt.publish(self.model_status_topic, "error: switch timed out", retain=True)
            return
        if proc.returncode != 0:
            lines = ANSI_RE.sub("", (proc.stderr or proc.stdout or "")).strip().splitlines()
            last = lines[-1].strip() if lines else f"rc={proc.returncode}"
            self.mqtt.publish(self.model_status_topic, f"error: {last}", retain=True)
            self.mqtt.publish(self.model_state_topic, parse_conf().get("ALIAS_MAIN", ""), retain=True)
            log(f"switch failed: {last}")
            return
        conf = parse_conf()
        active = conf.get("ALIAS_MAIN", model)
        self.mqtt.publish(self.model_state_topic, active, retain=True)
        port = int(conf.get("VLLM_BACKEND_PORT", "18000") or 18000)
        deadline = time.monotonic() + BACKEND_WAIT
        while time.monotonic() < deadline:
            if tcp_listening(port):
                self.mqtt.publish(self.model_status_topic, "ready", retain=True)
                log(f"switch complete -> {active}")
                return
            time.sleep(2)
        self.mqtt.publish(self.model_status_topic, "ready (backend slow to bind)", retain=True)
        log(f"switch done but backend not yet bound on :{port}")

    def init_model_status(self):
        conf = parse_conf()
        engine = conf.get("TEXT_ENGINE", "mlx-vlm")
        label = text_daemon_label(engine)
        running, _ = launchctl_state(label)
        self.mqtt.publish(self.model_state_topic, conf.get("ALIAS_MAIN", ""), retain=True)
        self.mqtt.publish(self.model_status_topic, "ready" if running else "backend down", retain=True)

    # -- main loop -----------------------------------------------------------
    def sleep_with_ping(self, secs):
        end = time.monotonic() + secs
        while not self.stop and self.mqtt.alive and time.monotonic() < end:
            time.sleep(min(1.0, max(0.0, end - time.monotonic())))
            if time.monotonic() - self.mqtt.last_activity > self.keepalive / 2:
                try:
                    self.mqtt.ping()
                except Exception:
                    self.mqtt.alive = False

    def session(self):
        self.mqtt.subscribe(self.cmd_topic)
        self.mqtt.subscribe(f"{self.disc_prefix}/status")
        threading.Thread(target=self.mqtt.reader_loop, name="reader", daemon=True).start()
        self.publish_discovery()
        self.mqtt.publish(self.avail_topic, "online", retain=True)
        self.init_model_status()
        self.publish_fast()
        self.kick_slow()
        while not self.stop and self.mqtt.alive:
            self.sleep_with_ping(self.interval)
            if self.stop or not self.mqtt.alive:
                break
            self.publish_fast()
            if time.monotonic() - self.last_slow_ts >= SLOW_INTERVAL:
                self.kick_slow()

    def run(self):
        if not self.host:
            log("MQTT_HOST is empty — bridge idle. Set MQTT_HOST in macstudio.conf "
                "and restart the daemon (sudo bash setup.sh --apply).")
            while not self.stop:
                time.sleep(30)
            return
        backoff = 5
        while not self.stop:
            try:
                self.mqtt.connect()
                log(f"connected to {self.host}:{self.port} as "
                    f"{self.user or '(anonymous)'} prefix={self.prefix}")
                backoff = 5
                self.session()
            except Exception as exc:
                msg = str(exc)
                log(f"connection error: {msg}")
                if "rc=4" in msg or "rc=5" in msg:  # bad auth — back off harder
                    backoff = max(backoff, 30)
            try:
                if self.stop:
                    self.mqtt.publish(self.avail_topic, "offline", retain=True)
                self.mqtt.disconnect()
            except Exception:
                pass
            if self.stop:
                break
            log(f"reconnecting in {backoff}s")
            for _ in range(backoff):
                if self.stop:
                    break
                time.sleep(1)
            backoff = min(backoff * 2, 60)

    def handle_term(self, *_):
        self.stop = True
        self.mqtt.alive = False


def main():
    bridge = Bridge()
    signal.signal(signal.SIGTERM, bridge.handle_term)
    signal.signal(signal.SIGINT, bridge.handle_term)
    threading.Thread(target=bridge.worker_loop, name="cmd-worker", daemon=True).start()
    bridge.run()


if __name__ == "__main__":
    main()
