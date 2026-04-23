#!/usr/bin/env python3
"""
Prometheus exporter for Apple Silicon power / thermal / memory-pressure metrics.

Uses the built-in `powermetrics` tool (requires root — the LaunchDaemon runs
without a UserName, so effective UID is 0). A background sampler thread
writes a fresh snapshot every `SAMPLE_INTERVAL_MS` milliseconds; HTTP scrapes
render from that snapshot and return in well under 100 ms.

Metrics:
  apple_silicon_up                           1 if powermetrics produced output
  apple_silicon_cpu_power_watts              package CPU power
  apple_silicon_gpu_power_watts              GPU package power
  apple_silicon_ane_power_watts              Neural Engine power
  apple_silicon_dram_power_watts             DRAM power (if reported by powermetrics)
  apple_silicon_package_power_watts          combined (cpu + gpu + ane + dram)
  apple_silicon_gpu_active_ratio             0..1, fraction of interval GPU was active
  apple_silicon_gpu_freq_hz                  current GPU frequency
  apple_silicon_cpu_cluster_active_ratio{cluster=...}
  apple_silicon_cpu_cluster_freq_hz{cluster=...}
  apple_silicon_thermal_pressure_level       0=Nominal 1=Fair 2=Serious 3=Critical 4=Unknown
  apple_silicon_memory_pressure_level        0=Normal 1=Warn 2=Critical (absent if probe fails)
  apple_silicon_last_sample_age_seconds      age of the cached snapshot
  apple_silicon_exporter_scrape_duration_seconds

Config via env:
  LISTEN_PORT            (default 9101)
  SAMPLE_INTERVAL_MS     (default 1000) — background cadence
"""
from __future__ import annotations

import os
import plistlib
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "9101"))
SAMPLE_INTERVAL_MS = int(os.environ.get("SAMPLE_INTERVAL_MS", "1000"))
POWERMETRICS = "/usr/bin/powermetrics"
SYSCTL = "/usr/sbin/sysctl"

THERMAL_PRESSURE_MAP = {
    "Nominal": 0, "nominal": 0,
    "Fair": 1, "fair": 1,
    "Serious": 2, "serious": 2,
    "Critical": 3, "critical": 3,
}
# kern.memorystatus_vm_pressure_level → Prometheus level.
# Dispatch source flags: NORMAL=1, WARN=2, CRITICAL=4.
MEMORY_PRESSURE_MAP = {1: 0, 2: 1, 4: 2}

# Snapshot written by the sampler thread, read by HTTP handlers. Dict reference
# swap is atomic under the GIL, so no lock is needed.
_snapshot: dict = {"ts": 0.0, "power": None, "mem": None}


def log(msg: str) -> None:
    print(f"[{time.strftime('%F %T')}][silicon-exporter] {msg}", flush=True)


def sample_powermetrics() -> dict | None:
    try:
        proc = subprocess.run(
            [POWERMETRICS, "-n", "1", "-i", str(SAMPLE_INTERVAL_MS),
             "--samplers", "cpu_power,gpu_power,thermal",
             "--format", "plist"],
            capture_output=True, timeout=10,
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


def render_metrics() -> str:
    t0 = time.monotonic()
    lines: list[str] = []
    snap = _snapshot
    data = snap.get("power")
    mem = snap.get("mem")

    up = 1 if data else 0
    lines.append("# HELP apple_silicon_up 1 if powermetrics produced a valid sample")
    lines.append("# TYPE apple_silicon_up gauge")
    lines.append(f"apple_silicon_up {up}")

    lines.append("# HELP apple_silicon_last_sample_age_seconds Wall-clock age of the cached powermetrics sample")
    lines.append("# TYPE apple_silicon_last_sample_age_seconds gauge")
    age = (time.time() - snap["ts"]) if snap.get("ts") else -1
    lines.append(f"apple_silicon_last_sample_age_seconds {age:.3f}")

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

        lines.append("# HELP apple_silicon_cpu_power_watts CPU package power (W)")
        lines.append("# TYPE apple_silicon_cpu_power_watts gauge")
        lines.append(f"apple_silicon_cpu_power_watts {cpu_power_w:.3f}")
        lines.append("# HELP apple_silicon_gpu_power_watts GPU package power (W)")
        lines.append("# TYPE apple_silicon_gpu_power_watts gauge")
        lines.append(f"apple_silicon_gpu_power_watts {gpu_power_w:.3f}")
        lines.append("# HELP apple_silicon_ane_power_watts Neural Engine power (W)")
        lines.append("# TYPE apple_silicon_ane_power_watts gauge")
        lines.append(f"apple_silicon_ane_power_watts {ane_power_w:.3f}")
        lines.append("# HELP apple_silicon_dram_power_watts DRAM power (W); 0 if the SoC doesn't report it")
        lines.append("# TYPE apple_silicon_dram_power_watts gauge")
        lines.append(f"apple_silicon_dram_power_watts {dram_power_w:.3f}")
        lines.append("# HELP apple_silicon_package_power_watts Combined SoC power (W)")
        lines.append("# TYPE apple_silicon_package_power_watts gauge")
        lines.append(f"apple_silicon_package_power_watts {pkg_power_w:.3f}")

        # GPU
        gpu_active = float(gpu.get("gpu_active_ratio") or gpu.get("active_ratio", 0))
        gpu_freq = int(gpu.get("freq_hz") or 0)
        lines.append("# HELP apple_silicon_gpu_active_ratio GPU active fraction (0..1)")
        lines.append("# TYPE apple_silicon_gpu_active_ratio gauge")
        lines.append(f"apple_silicon_gpu_active_ratio {gpu_active:.4f}")
        lines.append("# HELP apple_silicon_gpu_freq_hz Current GPU frequency")
        lines.append("# TYPE apple_silicon_gpu_freq_hz gauge")
        lines.append(f"apple_silicon_gpu_freq_hz {gpu_freq}")

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
        lines.append("# HELP apple_silicon_thermal_pressure_level 0=Nominal 1=Fair 2=Serious 3=Critical 4=Unknown")
        lines.append("# TYPE apple_silicon_thermal_pressure_level gauge")
        lines.append(f"apple_silicon_thermal_pressure_level {level}")

    # Memory pressure (absent if the probe failed — no false Normal).
    if mem is not None:
        lines.append("# HELP apple_silicon_memory_pressure_level 0=Normal 1=Warn 2=Critical (matches macOS memory_pressure -Q)")
        lines.append("# TYPE apple_silicon_memory_pressure_level gauge")
        lines.append(f"apple_silicon_memory_pressure_level {mem}")

    duration = time.monotonic() - t0
    lines.append("# HELP apple_silicon_exporter_scrape_duration_seconds Wall time of the last /metrics render")
    lines.append("# TYPE apple_silicon_exporter_scrape_duration_seconds gauge")
    lines.append(f"apple_silicon_exporter_scrape_duration_seconds {duration:.6f}")

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
    if os.geteuid() != 0:
        log("warning: powermetrics usually requires root; exporter may return empty samples")
    t = threading.Thread(target=sampler_loop, name="sampler", daemon=True)
    t.start()
    server = ThreadingHTTPServer(("0.0.0.0", LISTEN_PORT), Handler)
    log(f"listening on 0.0.0.0:{LISTEN_PORT} (sampler every {SAMPLE_INTERVAL_MS} ms)")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        sys.exit(0)


if __name__ == "__main__":
    main()
