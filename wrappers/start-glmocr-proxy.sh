#!/usr/bin/env bash
# Launched by com.local.glmocr.proxy — asyncio TCP proxy that wakes the
# GLM-OCR backend (com.local.glmocr.serve) on demand and stops it after idle.
# Same on-demand pattern as docling/immich (reuses services/ondemand-proxy.py).
set -eu

CONF=/usr/local/etc/macstudio.conf
[ -r "$CONF" ] && . "$CONF"

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
export LISTEN_HOST="0.0.0.0"
export LISTEN_PORT="${GLMOCR_PUBLIC_PORT:-5002}"
export BACKEND_HOST="127.0.0.1"
export BACKEND_PORT="${GLMOCR_BACKEND_PORT:-15002}"
export BACKEND_LABEL="com.local.glmocr.serve"
export HEALTH_URL="http://127.0.0.1:${GLMOCR_BACKEND_PORT:-15002}/v1/models"
export IDLE_TIMEOUT_SEC="${IDLE_TIMEOUT_GLMOCR:-900}"
export STARTUP_TIMEOUT_SEC="${STARTUP_TIMEOUT_GLMOCR:-120}"
export SERVICE_NAME="glmocr"

exec /usr/bin/python3 /usr/local/libexec/ondemand-proxy.py
