#!/usr/bin/env python3
"""
Prometheus exporter for the on-demand stack (immich-ml, docling-serve) and
the memory-pressure watchdog. Uses `launchctl print system/<label>` plus a
cheap TCP connect to the public proxy port — no root-only APIs beyond what
the silicon-exporter already does.

Metrics (one series per service label in immich/docling):
  ondemand_backend_up{service}              1 if the backend plist reports running
  ondemand_backend_pid{service}             pid of the backend (0 when asleep)
  ondemand_proxy_listening{service}         1 if the public port accepts TCP
  ondemand_watchdog_up                      1 if com.local.llm.watchdog is running
  ondemand_exporter_scrape_duration_seconds
  ondemand_exporter_scrape_errors_total{probe}

Config via env:
  LISTEN_PORT            default 9103
  ML_PUBLIC_PORT         default 3003
  DOCLING_PUBLIC_PORT    default 5001
"""
from __future__ import annotations

import os
import re
import socket
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "9103"))
ML_PUBLIC_PORT = int(os.environ.get("ML_PUBLIC_PORT", "3003"))
DOCLING_PUBLIC_PORT = int(os.environ.get("DOCLING_PUBLIC_PORT", "5001"))

LAUNCHCTL = "/bin/launchctl"
TCP_PROBE_TIMEOUT = 0.2
LAUNCHCTL_TIMEOUT = 2.0

SERVICES = [
    # (label_for_metric, backend_plist_label, proxy_public_port)
    ("immich",  "com.local.immich.ml",      ML_PUBLIC_PORT),
    ("docling", "com.local.docling.serve",  DOCLING_PUBLIC_PORT),
]
WATCHDOG_LABEL = "com.local.llm.watchdog"

_scrape_errors: dict[str, int] = {"launchctl": 0, "tcp": 0}


def log(msg: str) -> None:
    print(f"[{time.strftime('%F %T')}][ondemand-exporter] {msg}", flush=True)


def launchctl_state(label: str) -> tuple[bool, int]:
    """Return (running, pid). `running=False, pid=0` if the label is absent."""
    try:
        proc = subprocess.run(
            [LAUNCHCTL, "print", f"system/{label}"],
            capture_output=True, timeout=LAUNCHCTL_TIMEOUT, text=True,
        )
    except Exception as exc:
        log(f"launchctl print failed for {label}: {exc}")
        _scrape_errors["launchctl"] += 1
        return False, 0
    if proc.returncode != 0:
        return False, 0
    pid = 0
    state_running = False
    for line in proc.stdout.splitlines():
        m = re.match(r"\s*pid\s*=\s*(\d+)", line)
        if m:
            pid = int(m.group(1))
            continue
        m = re.match(r"\s*state\s*=\s*(\w+)", line)
        if m and m.group(1).lower() == "running":
            state_running = True
    return (state_running and pid > 0), pid


def tcp_listening(port: int, host: str = "127.0.0.1") -> bool:
    try:
        with socket.create_connection((host, port), TCP_PROBE_TIMEOUT):
            return True
    except OSError:
        return False
    except Exception:
        _scrape_errors["tcp"] += 1
        return False


def render_metrics() -> str:
    t0 = time.monotonic()
    lines: list[str] = []

    lines.append("# HELP ondemand_backend_up 1 if the on-demand backend's launchd job is running")
    lines.append("# TYPE ondemand_backend_up gauge")
    lines.append("# HELP ondemand_backend_pid PID of the on-demand backend, 0 when asleep or absent")
    lines.append("# TYPE ondemand_backend_pid gauge")
    lines.append("# HELP ondemand_proxy_listening 1 if the always-on proxy is accepting TCP on its public port")
    lines.append("# TYPE ondemand_proxy_listening gauge")

    for svc, label, port in SERVICES:
        running, pid = launchctl_state(label)
        listening = tcp_listening(port)
        lines.append(f'ondemand_backend_up{{service="{svc}"}} {1 if running else 0}')
        lines.append(f'ondemand_backend_pid{{service="{svc}"}} {pid}')
        lines.append(f'ondemand_proxy_listening{{service="{svc}"}} {1 if listening else 0}')

    wd_running, _ = launchctl_state(WATCHDOG_LABEL)
    lines.append("# HELP ondemand_watchdog_up 1 if the memory-pressure watchdog daemon is running")
    lines.append("# TYPE ondemand_watchdog_up gauge")
    lines.append(f"ondemand_watchdog_up {1 if wd_running else 0}")

    lines.append("# HELP ondemand_exporter_scrape_errors_total Cumulative probe errors by kind")
    lines.append("# TYPE ondemand_exporter_scrape_errors_total counter")
    for probe, n in _scrape_errors.items():
        lines.append(f'ondemand_exporter_scrape_errors_total{{probe="{probe}"}} {n}')

    duration = time.monotonic() - t0
    lines.append("# HELP ondemand_exporter_scrape_duration_seconds Wall time of the last /metrics render")
    lines.append("# TYPE ondemand_exporter_scrape_duration_seconds gauge")
    lines.append(f"ondemand_exporter_scrape_duration_seconds {duration:.6f}")

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
    server = ThreadingHTTPServer(("0.0.0.0", LISTEN_PORT), Handler)
    log(f"listening on 0.0.0.0:{LISTEN_PORT} "
        f"(immich proxy:{ML_PUBLIC_PORT}, docling proxy:{DOCLING_PUBLIC_PORT})")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        sys.exit(0)


if __name__ == "__main__":
    main()
