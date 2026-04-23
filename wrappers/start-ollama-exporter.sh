#!/usr/bin/env bash
# Launched by com.local.ollama.exporter — exposes Ollama state as Prometheus text.
set -eu

CONF=/usr/local/etc/macstudio.conf
[ -r "$CONF" ] && . "$CONF"

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
export LISTEN_PORT="${OLLAMA_EXPORTER_PORT:-9102}"
export OLLAMA_URL="http://127.0.0.1:${OLLAMA_PORT:-11434}"

# Surfaced as labels by the exporter so dashboards can show the running config.
export OLLAMA_KEEP_ALIVE="${OLLAMA_KEEP_ALIVE:-}"
export OLLAMA_KV_CACHE_TYPE="${OLLAMA_KV_CACHE_TYPE:-}"
export OLLAMA_FLASH_ATTENTION="${OLLAMA_FLASH_ATTENTION:-}"
export OLLAMA_NUM_PARALLEL="${OLLAMA_NUM_PARALLEL:-}"
export OLLAMA_MAX_LOADED_MODELS="${OLLAMA_MAX_LOADED_MODELS:-}"
export IOGPU_WIRED_LIMIT_MB="${IOGPU_WIRED_LIMIT_MB:-0}"

exec /usr/bin/python3 /usr/local/libexec/ollama-exporter.py
