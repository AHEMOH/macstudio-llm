#!/usr/bin/env python3
"""
Prometheus exporter for Ollama. Scrapes /api/ps and /api/tags; emits:

  ollama_up                                     1 if /api/tags responds
  ollama_loaded_model{name=...,digest=...}      1 per currently-loaded model
  ollama_loaded_model_size_bytes{name=...}      VRAM/size of loaded model
  ollama_loaded_model_expires_seconds{name=...} seconds until KEEP_ALIVE
  ollama_installed_model_size_bytes{name=...}   size of every pulled model
  ollama_installed_model_count                  total pulled models

Config via env: LISTEN_PORT (default 9102), OLLAMA_URL (default
http://127.0.0.1:11434). Uses stdlib only.
"""
from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "9102"))
OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://127.0.0.1:11434").rstrip("/")


def log(msg: str) -> None:
    print(f"[{time.strftime('%F %T')}][ollama-exporter] {msg}", flush=True)


def fetch_json(path: str, timeout: float = 3.0):
    try:
        with urllib.request.urlopen(OLLAMA_URL + path, timeout=timeout) as r:
            return json.load(r)
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, ConnectionError, json.JSONDecodeError):
        return None


def esc(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def render_metrics() -> str:
    lines: list[str] = []
    ps = fetch_json("/api/ps")
    tags = fetch_json("/api/tags")

    up = 1 if tags is not None else 0
    lines.append("# HELP ollama_up 1 if the Ollama HTTP API responded")
    lines.append("# TYPE ollama_up gauge")
    lines.append(f"ollama_up {up}")

    loaded = (ps or {}).get("models", []) if ps else []
    lines.append("# HELP ollama_loaded_model 1 per currently loaded model")
    lines.append("# TYPE ollama_loaded_model gauge")
    lines.append("# HELP ollama_loaded_model_size_bytes Resident size of loaded model in bytes")
    lines.append("# TYPE ollama_loaded_model_size_bytes gauge")
    lines.append("# HELP ollama_loaded_model_expires_seconds Seconds until Ollama unloads the model (negative = already past)")
    lines.append("# TYPE ollama_loaded_model_expires_seconds gauge")
    now = time.time()
    for m in loaded:
        name = esc(m.get("name", ""))
        digest = esc(m.get("digest", ""))
        size = int(m.get("size_vram") or m.get("size") or 0)
        expires = m.get("expires_at")
        lines.append(f'ollama_loaded_model{{name="{name}",digest="{digest}"}} 1')
        lines.append(f'ollama_loaded_model_size_bytes{{name="{name}"}} {size}')
        if isinstance(expires, str):
            try:
                t = time.mktime(time.strptime(expires[:19], "%Y-%m-%dT%H:%M:%S"))
                lines.append(f'ollama_loaded_model_expires_seconds{{name="{name}"}} {int(t - now)}')
            except Exception:
                pass

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
