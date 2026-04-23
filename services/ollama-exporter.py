#!/usr/bin/env python3
"""
Prometheus exporter for Ollama. Scrapes /api/ps and /api/tags; emits:

  ollama_up                                     1 if /api/tags responds
  ollama_loaded_model_count                     number of resident models (0..N)
  ollama_loaded_model{name=...,digest=...}      1 per currently-loaded model
  ollama_loaded_model_size_bytes{name=...}      VRAM/size of loaded model
  ollama_loaded_model_expires_seconds{name=...} seconds until KEEP_ALIVE
  ollama_loaded_model_info{name,format,family,parameter_size,quantization,
                           context_length}      1 per loaded model, labels only
  ollama_installed_model_size_bytes{name=...}   size of every pulled model
  ollama_installed_model_count                  total pulled models
  ollama_config_info{keep_alive,kv_cache_type,flash_attention,num_parallel,
                     max_loaded_models}         1, static labels from env
  ollama_iogpu_wired_limit_bytes                macOS iogpu.wired_limit_mb in bytes
  ollama_exporter_scrape_duration_seconds       last scrape wall time
  ollama_exporter_scrape_errors_total{endpoint} cumulative Ollama API errors

Config via env: LISTEN_PORT (default 9102), OLLAMA_URL (default
http://127.0.0.1:11434). Uses stdlib only.
"""
from __future__ import annotations

import json
import os
import sys
import time
from datetime import datetime, timezone
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "9102"))
OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://127.0.0.1:11434").rstrip("/")

# Static config surfaced as labels. Wrapper sources /usr/local/etc/macstudio.conf
# before exec so these env vars are already populated at startup.
CONFIG_LABELS = {
    "keep_alive":        os.environ.get("OLLAMA_KEEP_ALIVE", ""),
    "kv_cache_type":     os.environ.get("OLLAMA_KV_CACHE_TYPE", ""),
    "flash_attention":   os.environ.get("OLLAMA_FLASH_ATTENTION", ""),
    "num_parallel":      os.environ.get("OLLAMA_NUM_PARALLEL", ""),
    "max_loaded_models": os.environ.get("OLLAMA_MAX_LOADED_MODELS", ""),
}
try:
    IOGPU_WIRED_LIMIT_BYTES = int(os.environ.get("IOGPU_WIRED_LIMIT_MB", "0")) * 1024 * 1024
except ValueError:
    IOGPU_WIRED_LIMIT_BYTES = 0

# ThreadingHTTPServer means two scrapes can race these counters. A stray
# increment is harmless for a debug metric — no lock.
_scrape_errors: dict[str, int] = {"ps": 0, "tags": 0}


def log(msg: str) -> None:
    print(f"[{time.strftime('%F %T')}][ollama-exporter] {msg}", flush=True)


def fetch_json(path: str, endpoint_label: str, timeout: float = 3.0):
    try:
        with urllib.request.urlopen(OLLAMA_URL + path, timeout=timeout) as r:
            return json.load(r)
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError,
            ConnectionError, json.JSONDecodeError, OSError):
        _scrape_errors[endpoint_label] = _scrape_errors.get(endpoint_label, 0) + 1
        return None


def esc(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def parse_expires_seconds(expires: str) -> int | None:
    """Return seconds until `expires`, honoring its UTC offset.

    Ollama returns ISO-8601 with either `Z` or an explicit `+HH:MM` offset.
    The previous implementation stripped the suffix and called `mktime`
    (local time), which was off by the host's UTC offset.
    """
    if not isinstance(expires, str) or not expires:
        return None
    s = expires.replace("Z", "+00:00")
    # Trim sub-second precision past microseconds that fromisoformat rejects.
    if "." in s:
        head, _, rest = s.partition(".")
        # Split fraction from offset/tz suffix.
        i = 0
        while i < len(rest) and rest[i].isdigit():
            i += 1
        s = head + "." + rest[:min(i, 6)] + rest[i:]
    try:
        dt = datetime.fromisoformat(s)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return int((dt - datetime.now(timezone.utc)).total_seconds())


def render_metrics() -> str:
    t0 = time.monotonic()
    lines: list[str] = []
    ps = fetch_json("/api/ps", "ps")
    tags = fetch_json("/api/tags", "tags")

    up = 1 if tags is not None else 0
    lines.append("# HELP ollama_up 1 if the Ollama HTTP API responded")
    lines.append("# TYPE ollama_up gauge")
    lines.append(f"ollama_up {up}")

    loaded = (ps or {}).get("models", []) if ps else []

    lines.append("# HELP ollama_loaded_model_count Number of models currently resident in VRAM")
    lines.append("# TYPE ollama_loaded_model_count gauge")
    lines.append(f"ollama_loaded_model_count {len(loaded)}")

    lines.append("# HELP ollama_loaded_model 1 per currently loaded model")
    lines.append("# TYPE ollama_loaded_model gauge")
    lines.append("# HELP ollama_loaded_model_size_bytes Resident size of loaded model in bytes")
    lines.append("# TYPE ollama_loaded_model_size_bytes gauge")
    lines.append("# HELP ollama_loaded_model_expires_seconds Seconds until Ollama unloads the model (negative = already past)")
    lines.append("# TYPE ollama_loaded_model_expires_seconds gauge")
    lines.append("# HELP ollama_loaded_model_info Labels for the currently loaded model (format, family, quantization, context length)")
    lines.append("# TYPE ollama_loaded_model_info gauge")
    for m in loaded:
        name = esc(m.get("name", ""))
        digest = esc(m.get("digest", ""))
        size = int(m.get("size_vram") or m.get("size") or 0)
        lines.append(f'ollama_loaded_model{{name="{name}",digest="{digest}"}} 1')
        lines.append(f'ollama_loaded_model_size_bytes{{name="{name}"}} {size}')
        secs = parse_expires_seconds(m.get("expires_at", ""))
        if secs is not None:
            lines.append(f'ollama_loaded_model_expires_seconds{{name="{name}"}} {secs}')
        d = m.get("details") or {}
        info_labels = {
            "name":            name,
            "format":          esc(str(d.get("format", ""))),
            "family":          esc(str(d.get("family", ""))),
            "parameter_size":  esc(str(d.get("parameter_size", ""))),
            "quantization":    esc(str(d.get("quantization_level", ""))),
            "context_length":  esc(str(m.get("context_length", ""))),
        }
        label_str = ",".join(f'{k}="{v}"' for k, v in info_labels.items())
        lines.append(f"ollama_loaded_model_info{{{label_str}}} 1")

    installed = (tags or {}).get("models", []) if tags else []
    lines.append("# HELP ollama_installed_model_count Number of pulled models on disk")
    lines.append("# TYPE ollama_installed_model_count gauge")
    lines.append(f"ollama_installed_model_count {len(installed)}")
    lines.append("# HELP ollama_installed_model_size_bytes On-disk size of each pulled model")
    lines.append("# TYPE ollama_installed_model_size_bytes gauge")
    for m in installed:
        name = esc(m.get("name", ""))
        size = int(m.get("size") or 0)
        lines.append(f'ollama_installed_model_size_bytes{{name="{name}"}} {size}')

    # Static config info — read once at startup from env.
    lines.append("# HELP ollama_config_info Static server config from macstudio.conf (labels carry values)")
    lines.append("# TYPE ollama_config_info gauge")
    cfg_str = ",".join(f'{k}="{esc(v)}"' for k, v in CONFIG_LABELS.items())
    lines.append(f"ollama_config_info{{{cfg_str}}} 1")

    lines.append("# HELP ollama_iogpu_wired_limit_bytes Configured iogpu.wired_limit_mb expressed in bytes")
    lines.append("# TYPE ollama_iogpu_wired_limit_bytes gauge")
    lines.append(f"ollama_iogpu_wired_limit_bytes {IOGPU_WIRED_LIMIT_BYTES}")

    lines.append("# HELP ollama_exporter_scrape_errors_total Failures contacting the Ollama API by endpoint")
    lines.append("# TYPE ollama_exporter_scrape_errors_total counter")
    for endpoint, n in _scrape_errors.items():
        lines.append(f'ollama_exporter_scrape_errors_total{{endpoint="{endpoint}"}} {n}')

    duration = time.monotonic() - t0
    lines.append("# HELP ollama_exporter_scrape_duration_seconds Wall time of the last /metrics render")
    lines.append("# TYPE ollama_exporter_scrape_duration_seconds gauge")
    lines.append(f"ollama_exporter_scrape_duration_seconds {duration:.6f}")

    lines.append("")
    return "\n".join(lines)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt: str, *args) -> None:
        # Silence default per-request logging; we log errors ourselves.
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
    log(f"listening on 0.0.0.0:{LISTEN_PORT} scraping {OLLAMA_URL}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        sys.exit(0)


if __name__ == "__main__":
    main()
