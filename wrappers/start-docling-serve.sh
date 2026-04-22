#!/usr/bin/env bash
# Launched by com.local.docling.serve (on-demand, woken by com.local.docling.proxy).
set -eu

CONF=/usr/local/etc/macstudio.conf
[ -r "$CONF" ] && . "$CONF"

export HOME="${TARGET_HOME:-/Users/mac}"
export USER="${TARGET_USER:-mac}"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

export UVICORN_HOST="127.0.0.1"
export UVICORN_PORT="${DOCLING_BACKEND_PORT:-15001}"
export DOCLING_SERVE_ENABLE_UI="true"
export DOCLING_SERVE_LOG_LEVEL="INFO"
export DOCLING_DEVICE="mps"
export DOCLING_SERVE_ENABLE_REMOTE_SERVICES="true"
export DOCLING_SERVE_ALLOW_CUSTOM_VLM_CONFIG="true"

PROJ="${DOCLING_PROJECT_DIR:-$HOME/projects/docling-serve}"
cd "$PROJ"
exec "$PROJ/.venv/bin/docling-serve" run --host 127.0.0.1 --port "${DOCLING_BACKEND_PORT:-15001}" --enable-ui
