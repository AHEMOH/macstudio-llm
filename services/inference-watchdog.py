#!/usr/bin/env python3
"""
Inference-Watchdog — last-resort safety net for stuck Ollama inferences.

Ollama has no server-side per-request timeout. When a model (notably gpt-oss:20b)
enters a reasoning loop, the GPU pins at ~100% and the request never returns
until the client closes the TCP connection. paperless-gpt has no client-side
timeout either (PR #972 still open), so a single stuck doc can block a batch
of hundreds for hours.

This daemon polls three independent signals and kills the `ollama runner`
subprocess (NOT `ollama serve` — the parent stays alive and reloads the
model on the next request) only when ALL three signals agree for the
full STALL_TIMEOUT_MIN window.

Detection signals (multi-signal AND, conservative):
  1. apple_silicon_gpu_active_ratio  >= GPU_THRESHOLD       (silicon-exporter)
  2. seconds since last [GIN] | 200 | line in ollama.log >= STALL_MIN*60
  3. at least one ESTABLISHED TCP connection on the Ollama port from a
     non-loopback remote IP                                 (lsof / netstat)

Failsafes:
  - any probe failure -> reset state, do NOT kill (false-negative > false-positive)
  - 5-minute cooldown between kills
  - require runner ppid to match an `ollama serve` pid (don't kill stray runners)
  - in-memory state; daemon restart re-observes before acting

Configuration via /usr/local/etc/macstudio.conf (KEY=VALUE, shell-sourceable):
  INFERENCE_WATCHDOG_ENABLED        default 1
  INFERENCE_STALL_TIMEOUT_MIN       default 15
  INFERENCE_WATCHDOG_POLL_SEC       default 30
  INFERENCE_WATCHDOG_GPU_THRESHOLD  default 0.5
  SILICON_EXPORTER_PORT             default 9101  (existing key)
  OLLAMA_PORT                       default 11434 (existing key)
"""
from __future__ import annotations

import os
import re
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime

CONF = "/usr/local/etc/macstudio.conf"
OLLAMA_LOG = "/var/log/macstudio/ollama.log"
KILL_COOLDOWN_SEC = 300         # 5 min between consecutive kills
SIGTERM_GRACE_SEC = 10          # wait this long for SIGTERM before SIGKILL
PROBE_HTTP_TIMEOUT = 2          # silicon-exporter scrape timeout

# Recognises the standard Gin access-log line that Ollama emits for every
# completed HTTP request, e.g.:
#   [GIN] 2026/05/19 - 21:33:00 | 200 |  1m50s | 192.168.178.251 | POST  "/api/chat"
GIN_200_RE = re.compile(
    r"\[GIN\]\s+(\d{4}/\d{2}/\d{2}\s+-\s+\d{2}:\d{2}:\d{2})\s+\|\s+200\s+\|"
)


# --- config loading ---------------------------------------------------------

def load_conf() -> dict[str, str]:
    """Parse /usr/local/etc/macstudio.conf as plain KEY=VALUE lines.

    The file is shell-sourceable but we don't need a shell — it's flat
    assignments without expansion. Comments and blank lines are skipped.
    """
    cfg: dict[str, str] = {}
    try:
        with open(CONF, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, _, v = line.partition("=")
                cfg[k.strip()] = v.strip().strip('"').strip("'")
    except OSError:
        # Missing or unreadable conf is non-fatal — fall back to defaults.
        pass
    return cfg


# --- logging ----------------------------------------------------------------

def log(msg: str) -> None:
    print(f"[{time.strftime('%F %T')}][inference-watchdog] {msg}", flush=True)


# --- probes -----------------------------------------------------------------

def gpu_active_ratio(silicon_url: str) -> float | None:
    """Scrape silicon-exporter for apple_silicon_gpu_active_ratio."""
    try:
        with urllib.request.urlopen(silicon_url, timeout=PROBE_HTTP_TIMEOUT) as r:
            body = r.read().decode("utf-8", errors="replace")
    except (urllib.error.URLError, urllib.error.HTTPError,
            TimeoutError, ConnectionError, OSError):
        return None
    for line in body.splitlines():
        if line.startswith("apple_silicon_gpu_active_ratio "):
            try:
                return float(line.split()[1])
            except (IndexError, ValueError):
                return None
    return None


def seconds_since_last_200() -> float | None:
    """Find the most recent [GIN] | 200 | line in ollama.log and return its age.

    Reads the tail of the file (last 64 KB) to keep this O(1) even on
    long-running servers with multi-MB logs.
    """
    try:
        size = os.path.getsize(OLLAMA_LOG)
        with open(OLLAMA_LOG, "rb") as f:
            if size > 65536:
                f.seek(-65536, os.SEEK_END)
            chunk = f.read().decode("utf-8", errors="replace")
    except OSError:
        return None

    last_match = None
    for m in GIN_200_RE.finditer(chunk):
        last_match = m
    if last_match is None:
        return None

    try:
        ts = datetime.strptime(last_match.group(1), "%Y/%m/%d - %H:%M:%S")
    except ValueError:
        return None
    return max(0.0, (datetime.now() - ts).total_seconds())


def has_remote_client(port: int) -> bool | None:
    """True iff at least one ESTABLISHED TCP socket on `port` has a remote
    (non-loopback) peer. Returns None on probe failure (do not act)."""
    try:
        out = subprocess.run(
            ["/usr/sbin/lsof", "-nP", f"-iTCP:{port}", "-sTCP:ESTABLISHED"],
            capture_output=True, text=True, timeout=5,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return None

    for line in out.splitlines()[1:]:  # skip header
        # NAME column is the last field, format "src->dst" for established sockets.
        # We want at least one row where the remote side is not 127.0.0.1 / ::1.
        if "->" not in line:
            continue
        try:
            name = line.split()[-1]
            remote = name.split("->")[1]
        except IndexError:
            continue
        # Strip port suffix
        remote_host = remote.rsplit(":", 1)[0]
        if remote_host not in ("127.0.0.1", "[::1]", "::1", "localhost"):
            return True
    return False


# --- runner discovery & kill ------------------------------------------------

def find_ollama_runner_pid() -> int | None:
    """Find an `ollama runner` process whose parent is an `ollama serve`.

    The ppid check is intentional: it ensures we never SIGTERM a stray runner
    started by some other test or manual invocation outside of the
    launchd-managed serve. If multiple runners exist (MAX_LOADED_MODELS > 1),
    we return the first match — the watchdog kills one at a time, and the
    cooldown prevents a chain reaction.
    """
    try:
        out = subprocess.run(
            ["/bin/ps", "-axo", "pid,ppid,command"],
            capture_output=True, text=True, timeout=5,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return None

    serve_pids: set[int] = set()
    runners: list[tuple[int, int]] = []  # (pid, ppid)
    for raw in out.splitlines()[1:]:
        parts = raw.split(None, 2)
        if len(parts) < 3:
            continue
        try:
            pid = int(parts[0])
            ppid = int(parts[1])
        except ValueError:
            continue
        cmd = parts[2]
        if "ollama serve" in cmd:
            serve_pids.add(pid)
        elif "ollama runner" in cmd or "ollama-runner" in cmd:
            runners.append((pid, ppid))

    for pid, ppid in runners:
        if ppid in serve_pids:
            return pid
    return None


def pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True  # exists but not signalable by us; treat as alive
    return True


def kill_runner(pid: int) -> None:
    """SIGTERM, wait up to SIGTERM_GRACE_SEC, then SIGKILL if still alive."""
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        log(f"runner pid={pid} already gone before SIGTERM")
        return
    except PermissionError as exc:
        log(f"SIGTERM denied for pid={pid}: {exc}")
        return

    deadline = time.monotonic() + SIGTERM_GRACE_SEC
    while time.monotonic() < deadline and pid_alive(pid):
        time.sleep(0.5)

    if pid_alive(pid):
        log(f"runner pid={pid} still alive after {SIGTERM_GRACE_SEC}s -> SIGKILL")
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        except PermissionError as exc:
            log(f"SIGKILL denied for pid={pid}: {exc}")


# --- main loop --------------------------------------------------------------

def main() -> int:
    cfg = load_conf()
    enabled = cfg.get("INFERENCE_WATCHDOG_ENABLED", "1") == "1"
    stall_min = int(cfg.get("INFERENCE_STALL_TIMEOUT_MIN", "15"))
    poll_sec = int(cfg.get("INFERENCE_WATCHDOG_POLL_SEC", "30"))
    gpu_thresh = float(cfg.get("INFERENCE_WATCHDOG_GPU_THRESHOLD", "0.5"))
    silicon_port = int(cfg.get("SILICON_EXPORTER_PORT", "9101"))
    ollama_port = int(cfg.get("OLLAMA_PORT", "11434"))

    silicon_url = f"http://127.0.0.1:{silicon_port}/metrics"

    log(
        f"start enabled={enabled} stall_min={stall_min} poll={poll_sec}s "
        f"gpu_threshold={gpu_thresh} silicon={silicon_url} ollama_port={ollama_port}"
    )
    if not enabled:
        # Stay alive but idle, so launchd doesn't relaunch in a tight loop.
        while True:
            time.sleep(3600)

    stall_started: float | None = None  # monotonic ts when suspect first armed
    last_kill: float = 0.0

    while True:
        time.sleep(poll_sec)
        try:
            gpu = gpu_active_ratio(silicon_url)
            age = seconds_since_last_200()
            busy = has_remote_client(ollama_port)

            # Any probe failure -> reset state, no action this cycle.
            if gpu is None or age is None or busy is None:
                if stall_started is not None:
                    log(f"probe-unavailable: gpu={gpu} age={age} busy={busy} — disarming")
                stall_started = None
                continue

            suspect = (gpu >= gpu_thresh) and (age >= stall_min * 60) and busy
            if not suspect:
                if stall_started is not None:
                    log(f"clear: gpu={gpu:.2f} age={age:.0f}s busy={busy} — disarming")
                stall_started = None
                continue

            now = time.monotonic()
            if stall_started is None:
                stall_started = now
                log(
                    f"suspect-start: gpu={gpu:.2f} age={age:.0f}s busy={busy} — arming"
                )
                continue

            elapsed = now - stall_started
            if elapsed < stall_min * 60:
                # Still arming. Belt-and-suspenders: require the suspect state
                # to persist for the full window, not just one poll that happens
                # to coincide with an old `| 200 |` line.
                continue

            if now - last_kill < KILL_COOLDOWN_SEC:
                log(
                    f"cooldown: refusing to kill within {KILL_COOLDOWN_SEC}s of last kill"
                )
                continue

            pid = find_ollama_runner_pid()
            if pid is None:
                log("STUCK matched but no ollama-runner child found — disarming")
                stall_started = None
                continue

            log(
                f"STUCK CONFIRMED gpu={gpu:.2f} age={age:.0f}s busy={busy} "
                f"elapsed={elapsed:.0f}s — SIGTERM ollama runner pid={pid}"
            )
            kill_runner(pid)
            last_kill = time.monotonic()
            stall_started = None

        except KeyboardInterrupt:
            log("interrupted, exiting")
            return 0
        except Exception as exc:  # noqa: BLE001 — last-resort daemon, log and continue
            log(f"loop error: {exc!r}")
            stall_started = None
            time.sleep(5)

    return 0


if __name__ == "__main__":
    sys.exit(main())
