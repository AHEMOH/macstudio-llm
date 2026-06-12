#!/usr/bin/env python3
"""
Prometheus exporter for Apple Silicon power / thermal / memory-pressure metrics.

Primary sampler: `macmon pipe` (one long-lived process streaming a JSON sample
per interval via IOReport/SMC). It provides what powermetrics on Apple Silicon
cannot: whole-system power (sys_power, the "Total" macmon's TUI shows), CPU/GPU
temperatures, and a real GPU utilization (powermetrics' idle_ratio is frequency
residency and reads ~17% on an idle M1 Max). Falls back to the original
powermetrics loop when macmon is missing or keeps dying.

macmon has no thermal-pressure level, so in macmon mode a slow side loop runs
`powermetrics --samplers thermal` every 30 s (root required — this LaunchDaemon
runs without a UserName, so effective UID is 0).

Metrics:
  apple_silicon_up                           1 if the sampler produced a sample
  apple_silicon_cpu_power_watts              CPU power
  apple_silicon_gpu_power_watts              GPU power
  apple_silicon_ane_power_watts              Neural Engine power
  apple_silicon_dram_power_watts             DRAM power (powermetrics mode only)
  apple_silicon_package_power_watts          combined compute power (cpu+gpu+ane)
  apple_silicon_sys_power_watts              whole-system power from SMC (macmon mode)
  apple_silicon_ram_power_watts              RAM power (macmon mode)
  apple_silicon_cpu_temp_celsius             CPU temperature (macmon mode)
  apple_silicon_gpu_temp_celsius             GPU temperature (macmon mode)
  apple_silicon_gpu_active_ratio             0..1 GPU utilization
  apple_silicon_gpu_freq_hz                  current GPU frequency
  apple_silicon_cpu_cluster_active_ratio{cluster=...}
  apple_silicon_cpu_cluster_freq_hz{cluster=...}
  apple_silicon_thermal_pressure_level       0=Nominal 1=Fair 2=Serious 3=Critical 4=Unknown
  apple_silicon_memory_pressure_level        0=Normal 1=Warn 2=Critical (absent if probe fails)
  apple_silicon_last_sample_age_seconds      age of the cached snapshot
  apple_silicon_exporter_scrape_duration_seconds

Config via env:
  LISTEN_PORT            (default 9101)
  SAMPLE_INTERVAL_MS     (default 10000) — sampler cadence; macmon averages over
                         the interval, so match it to the publish/scrape cadence
  MACMON_BIN             (default /opt/homebrew/bin/macmon)
"""
from __future__ import annotations

import json
import os
import plistlib
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "9101"))
SAMPLE_INTERVAL_MS = int(os.environ.get("SAMPLE_INTERVAL_MS", "10000"))
MACMON_BIN = os.environ.get("MACMON_BIN", "/opt/homebrew/bin/macmon")
POWERMETRICS = "/usr/bin/powermetrics"
SYSCTL = "/usr/sbin/sysctl"
THERMAL_INTERVAL_SEC = 30          # macmon-mode side loop cadence
MACMON_MAX_FAILURES = 3            # consecutive failures before falling back

THERMAL_PRESSURE_MAP = {
    "Nominal": 0, "nominal": 0,
    "Fair": 1, "fair": 1,
    "Serious": 2, "serious": 2,
    "Critical": 3, "critical": 3,
}
# kern.memorystatus_vm_pressure_level → Prometheus level.
# Dispatch source flags: NORMAL=1, WARN=2, CRITICAL=4.
MEMORY_PRESSURE_MAP = {1: 0, 2: 1, 4: 2}

# Each global below is written by exactly ONE thread and read by the HTTP
# handlers; whole-dict reference swaps are atomic under the GIL, so no locks.
_mode = "powermetrics"                       # flipped to "macmon" in main()
_mm_snap: dict = {"ts": 0.0, "data": None}   # macmon reader thread
_aux: dict = {"thermal": None, "mem": None}  # thermal/mem side loop (macmon mode)
_snapshot: dict = {"ts": 0.0, "power": None, "mem": None}  # powermetrics fallback


def log(msg: str) -> None:
    print(f"[{time.strftime('%F %T')}][silicon-exporter] {msg}", flush=True)


# --------------------------------------------------------------------------
# macmon mode
# --------------------------------------------------------------------------
def macmon_loop() -> None:
    """Stream samples from one long-lived `macmon pipe` process; restart it on
    exit. After MACMON_MAX_FAILURES consecutive failures, switch the exporter
    to the powermetrics fallback for the rest of this process's life."""
    failures = 0
    while True:
        try:
            proc = subprocess.Popen(
                [MACMON_BIN, "pipe", "-s", "0", "-i", str(SAMPLE_INTERVAL_MS)],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
            )
        except Exception as exc:
            log(f"macmon spawn failed: {exc}")
            failures += 1
        else:
            got_any = False
            try:
                for line in proc.stdout:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        data = json.loads(line)
                    except ValueError:
                        continue
                    got_any = True
                    failures = 0
                    globals()["_mm_snap"] = {"ts": time.time(), "data": data}
            except Exception as exc:
                log(f"macmon read error: {exc}")
            rc = proc.wait()
            log(f"macmon exited rc={rc}")
            if not got_any:
                failures += 1
        if failures >= MACMON_MAX_FAILURES:
            log(f"macmon failed {failures}x in a row — falling back to powermetrics sampling")
            globals()["_mode"] = "powermetrics"
            sampler_loop()   # never returns
            return
        time.sleep(5)


def thermal_mem_loop() -> None:
    """macmon has no thermal-pressure level; sample it (plus memory pressure)
    from a cheap thermal-only powermetrics call every THERMAL_INTERVAL_SEC."""
    while True:
        if _mode != "macmon":   # fallback took over — its loop covers both
            return
        data = sample_powermetrics(samplers="thermal", interval_ms=1000)
        level = None
        if data:
            pressure = data.get("thermal_pressure") or data.get("pressure") or ""
            level = THERMAL_PRESSURE_MAP.get(str(pressure), 4)
        mem = sample_memory_pressure()
        globals()["_aux"] = {"thermal": level, "mem": mem}
        time.sleep(THERMAL_INTERVAL_SEC)


# --------------------------------------------------------------------------
# powermetrics (fallback mode + thermal side loop)
# --------------------------------------------------------------------------
def sample_powermetrics(samplers: str = "cpu_power,gpu_power,thermal",
                        interval_ms: int | None = None) -> dict | None:
    ms = interval_ms if interval_ms is not None else SAMPLE_INTERVAL_MS
    try:
        proc = subprocess.run(
            [POWERMETRICS, "-n", "1", "-i", str(ms),
             "--samplers", samplers,
             "--format", "plist"],
            capture_output=True, timeout=max(10, ms // 1000 + 10),
        )
    except Exception as exc:
        log(f"powermetrics subprocess failed: {exc}")
        return None
    if proc.returncode != 0 and not proc.stdout:
        log(f"powermetrics returned {proc.returncode}: {proc.stderr[:200]!r}")
        return None
    raw = proc.stdout
    end = raw.rfind(b"</plist>")
    if end < 0:
        return None
    raw = raw[: end + len(b"</plist>")]
    try:
        return plistlib.loads(raw)
    except Exception as exc:
        log(f"plist parse failed: {exc}")
        return None


def sample_memory_pressure() -> int | None:
    """Map `kern.memorystatus_vm_pressure_level` to 0/1/2, or None.

    The sysctl returns the dispatch-source flag (1=Normal, 2=Warn, 4=Critical)
    and is cheap (no fork/exec beyond sysctl itself). If the sysctl is
    missing or unparseable, return None so the metric is emitted as absent
    rather than as a false 0/Normal.
    """
    try:
        proc = subprocess.run(
            [SYSCTL, "-n", "kern.memorystatus_vm_pressure_level"],
            capture_output=True, timeout=2, text=True,
        )
    except Exception:
        return None
    if proc.returncode != 0:
        return None
    try:
        raw = int(proc.stdout.strip())
    except ValueError:
        return None
    return MEMORY_PRESSURE_MAP.get(raw)


def sampler_loop() -> None:
    interval = max(0.25, SAMPLE_INTERVAL_MS / 1000.0)
    while True:
        t0 = time.monotonic()
        power = sample_powermetrics()
        mem = sample_memory_pressure()
        globals()["_snapshot"] = {"ts": time.time(), "power": power, "mem": mem}
        # Sleep out the remainder of the interval; powermetrics internally
        # blocks for SAMPLE_INTERVAL_MS so we're already paced, but cover the
        # case where it returned instantly (cached / error path).
        elapsed = time.monotonic() - t0
        if elapsed < interval:
            time.sleep(interval - elapsed)


def mw_to_w(x) -> float:
    try:
        return float(x) / 1000.0
    except Exception:
        return 0.0


# --------------------------------------------------------------------------
# Rendering
# --------------------------------------------------------------------------
def _gauge(lines: list[str], name: str, help_: str, value) -> None:
    lines.append(f"# HELP {name} {help_}")
    lines.append(f"# TYPE {name} gauge")
    lines.append(f"{name} {value}")


def render_macmon(lines: list[str]) -> None:
    snap = _mm_snap
    mm = snap.get("data")
    aux = _aux

    _gauge(lines, "apple_silicon_up", "1 if the sampler produced a valid sample",
           1 if mm else 0)
    age = (time.time() - snap["ts"]) if snap.get("ts") else -1
    _gauge(lines, "apple_silicon_last_sample_age_seconds",
           "Wall-clock age of the cached sample", f"{age:.3f}")

    if mm:
        cpu_w = float(mm.get("cpu_power") or 0)
        gpu_w = float(mm.get("gpu_power") or 0)
        ane_w = float(mm.get("ane_power") or 0)
        pkg_w = float(mm.get("all_power") or (cpu_w + gpu_w + ane_w))
        _gauge(lines, "apple_silicon_cpu_power_watts", "CPU power (W)", f"{cpu_w:.3f}")
        _gauge(lines, "apple_silicon_gpu_power_watts", "GPU power (W)", f"{gpu_w:.3f}")
        _gauge(lines, "apple_silicon_ane_power_watts", "Neural Engine power (W)", f"{ane_w:.3f}")
        _gauge(lines, "apple_silicon_package_power_watts",
               "Combined compute power cpu+gpu+ane (W)", f"{pkg_w:.3f}")
        if mm.get("sys_power") is not None:
            _gauge(lines, "apple_silicon_sys_power_watts",
                   "Whole-system power from SMC (W) — the 'Total' macmon shows",
                   f"{float(mm['sys_power']):.3f}")
        if mm.get("ram_power") is not None:
            _gauge(lines, "apple_silicon_ram_power_watts", "RAM power (W)",
                   f"{float(mm['ram_power']):.3f}")

        gpu = mm.get("gpu_usage") or [0, 0.0]
        _gauge(lines, "apple_silicon_gpu_active_ratio",
               "GPU active fraction 0..1 (IOReport utilization)", f"{float(gpu[1]):.4f}")
        _gauge(lines, "apple_silicon_gpu_freq_hz", "Current GPU frequency",
               int(float(gpu[0])))

        temp = mm.get("temp") or {}
        if temp.get("cpu_temp_avg") is not None:
            _gauge(lines, "apple_silicon_cpu_temp_celsius", "CPU temperature (°C)",
                   f"{float(temp['cpu_temp_avg']):.1f}")
        if temp.get("gpu_temp_avg") is not None:
            _gauge(lines, "apple_silicon_gpu_temp_celsius", "GPU temperature (°C)",
                   f"{float(temp['gpu_temp_avg']):.1f}")

        # E/P cluster usage — keep the powermetrics label scheme
        lines.append("# HELP apple_silicon_cpu_cluster_active_ratio Per-cluster active fraction (0..1)")
        lines.append("# TYPE apple_silicon_cpu_cluster_active_ratio gauge")
        lines.append("# HELP apple_silicon_cpu_cluster_freq_hz Per-cluster frequency")
        lines.append("# TYPE apple_silicon_cpu_cluster_freq_hz gauge")
        for name, key in (("E-Cluster", "ecpu_usage"), ("P-Cluster", "pcpu_usage")):
            usage = mm.get(key)
            if not usage:
                continue
            lines.append(f'apple_silicon_cpu_cluster_active_ratio{{cluster="{name}"}} {float(usage[1]):.4f}')
            lines.append(f'apple_silicon_cpu_cluster_freq_hz{{cluster="{name}"}} {int(float(usage[0]))}')

    if aux.get("thermal") is not None:
        _gauge(lines, "apple_silicon_thermal_pressure_level",
               "0=Nominal 1=Fair 2=Serious 3=Critical 4=Unknown", aux["thermal"])
    if aux.get("mem") is not None:
        _gauge(lines, "apple_silicon_memory_pressure_level",
               "0=Normal 1=Warn 2=Critical (matches macOS memory_pressure -Q)", aux["mem"])


def render_powermetrics(lines: list[str]) -> None:
    snap = _snapshot
    data = snap.get("power")
    mem = snap.get("mem")

    _gauge(lines, "apple_silicon_up", "1 if the sampler produced a valid sample",
           1 if data else 0)
    age = (time.time() - snap["ts"]) if snap.get("ts") else -1
    _gauge(lines, "apple_silicon_last_sample_age_seconds",
           "Wall-clock age of the cached sample", f"{age:.3f}")

    if data:
        # Power — values in mW in powermetrics plist
        processor = data.get("processor", {})
        gpu = data.get("gpu", {})
        cpu_power_w = mw_to_w(processor.get("package_power") or processor.get("cpu_power", 0))
        gpu_power_w = mw_to_w(gpu.get("gpu_energy") or gpu.get("gpu_power", 0))
        ane_power_w = mw_to_w(processor.get("ane_power", 0))
        dram_power_w = mw_to_w(processor.get("dram_power", 0))
        pkg_power_w = mw_to_w(processor.get("combined_power") or
                              (processor.get("package_power", 0) + gpu.get("gpu_power", 0)))

        _gauge(lines, "apple_silicon_cpu_power_watts", "CPU power (W)", f"{cpu_power_w:.3f}")
        _gauge(lines, "apple_silicon_gpu_power_watts", "GPU power (W)", f"{gpu_power_w:.3f}")
        _gauge(lines, "apple_silicon_ane_power_watts", "Neural Engine power (W)", f"{ane_power_w:.3f}")
        _gauge(lines, "apple_silicon_dram_power_watts",
               "DRAM power (W); 0 if the SoC doesn't report it", f"{dram_power_w:.3f}")
        _gauge(lines, "apple_silicon_package_power_watts",
               "Combined compute power cpu+gpu+ane (W)", f"{pkg_power_w:.3f}")

        # GPU active fraction. powermetrics builds differ: some report
        # gpu_active_ratio/active_ratio directly; the M1 Max build reports only
        # idle_ratio (frequency residency — coarse; macmon mode is preferred).
        if gpu.get("gpu_active_ratio") is not None:
            gpu_active = float(gpu["gpu_active_ratio"])
        elif gpu.get("active_ratio") is not None:
            gpu_active = float(gpu["active_ratio"])
        elif gpu.get("idle_ratio") is not None:
            gpu_active = max(0.0, 1.0 - float(gpu["idle_ratio"]))
        else:
            gpu_active = 0.0
        gpu_freq = int(gpu.get("freq_hz") or 0)
        _gauge(lines, "apple_silicon_gpu_active_ratio", "GPU active fraction (0..1)",
               f"{gpu_active:.4f}")
        _gauge(lines, "apple_silicon_gpu_freq_hz", "Current GPU frequency", gpu_freq)

        # CPU clusters
        lines.append("# HELP apple_silicon_cpu_cluster_active_ratio Per-cluster active fraction (0..1)")
        lines.append("# TYPE apple_silicon_cpu_cluster_active_ratio gauge")
        lines.append("# HELP apple_silicon_cpu_cluster_freq_hz Per-cluster frequency")
        lines.append("# TYPE apple_silicon_cpu_cluster_freq_hz gauge")
        for cluster in processor.get("clusters", []) or []:
            name = str(cluster.get("name", "?")).replace('"', '')
            active = float(cluster.get("active_ratio", 0))
            freq = int(cluster.get("freq_hz") or 0)
            lines.append(f'apple_silicon_cpu_cluster_active_ratio{{cluster="{name}"}} {active:.4f}')
            lines.append(f'apple_silicon_cpu_cluster_freq_hz{{cluster="{name}"}} {freq}')

        # Thermal pressure
        pressure = data.get("thermal_pressure") or data.get("pressure") or ""
        level = THERMAL_PRESSURE_MAP.get(str(pressure), 4)
        _gauge(lines, "apple_silicon_thermal_pressure_level",
               "0=Nominal 1=Fair 2=Serious 3=Critical 4=Unknown", level)

    # Memory pressure (absent if the probe failed — no false Normal).
    if mem is not None:
        _gauge(lines, "apple_silicon_memory_pressure_level",
               "0=Normal 1=Warn 2=Critical (matches macOS memory_pressure -Q)", mem)


def render_metrics() -> str:
    t0 = time.monotonic()
    lines: list[str] = []
    if _mode == "macmon":
        render_macmon(lines)
    else:
        render_powermetrics(lines)
    duration = time.monotonic() - t0
    _gauge(lines, "apple_silicon_exporter_scrape_duration_seconds",
           "Wall time of the last /metrics render", f"{duration:.6f}")
    lines.append("")
    return "\n".join(lines)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt: str, *args) -> None:
        pass

    def do_GET(self) -> None:
        if self.path in ("/", "/metrics"):
            body = render_metrics().encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(404)
        self.end_headers()


def main() -> None:
    global _mode
    if os.geteuid() != 0:
        log("warning: powermetrics (fallback + thermal pressure) requires root")
    if os.path.exists(MACMON_BIN):
        _mode = "macmon"
        threading.Thread(target=macmon_loop, name="macmon", daemon=True).start()
        threading.Thread(target=thermal_mem_loop, name="thermal", daemon=True).start()
        log(f"sampler: macmon ({MACMON_BIN}, every {SAMPLE_INTERVAL_MS} ms; "
            f"thermal/mem via powermetrics every {THERMAL_INTERVAL_SEC} s)")
    else:
        log(f"macmon not found at {MACMON_BIN} — using powermetrics sampling "
            "(no sys power / temperatures)")
        threading.Thread(target=sampler_loop, name="sampler", daemon=True).start()
    server = ThreadingHTTPServer(("0.0.0.0", LISTEN_PORT), Handler)
    log(f"listening on 0.0.0.0:{LISTEN_PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        sys.exit(0)


if __name__ == "__main__":
    main()
