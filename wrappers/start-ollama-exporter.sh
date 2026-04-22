#!/usr/bin/env bash
# Launched by com.local.ollama.exporter — exposes Ollama state as Prometheus text.
set -eu

CONF=/usr/local/etc/macstudio.conf
[ -r "$CONF" ] && . "$CONF"

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
export LISTEN_PORT="${OLLAMA_EXPORTER_PORT:-9102}"
export OLLAMA_URL="http://127.0.0.1:${OLLAMA_PORT:-11434}"

exec /usr/bin/python3 /usr/local/libexec/ollama-exporter.py
