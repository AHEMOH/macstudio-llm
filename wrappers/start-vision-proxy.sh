#!/usr/bin/env bash
# Launched by com.local.vision.proxy — asyncio TCP proxy that wakes the vision
# backend (com.local.vision.serve) on demand and stops it after idle.
# Same on-demand pattern as glmocr/docling/immich (reuses ondemand-proxy.py).
set -eu

CONF=/usr/local/etc/macstudio.conf
[ -r "$CONF" ] && . "$CONF"

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
export LISTEN_HOST="0.0.0.0"
export LISTEN_PORT="${VISION_PUBLIC_PORT:-5003}"
export BACKEND_HOST="127.0.0.1"
export BACKEND_PORT="${VISION_BACKEND_PORT:-15003}"
export BACKEND_LABEL="com.local.vision.serve"
export HEALTH_URL="http://127.0.0.1:${VISION_BACKEND_PORT:-15003}/v1/models"
export IDLE_TIMEOUT_SEC="${IDLE_TIMEOUT_VISION:-60}"
export STARTUP_TIMEOUT_SEC="${STARTUP_TIMEOUT_VISION:-180}"
export SERVICE_NAME="vision"

exec /usr/bin/python3 /usr/local/libexec/ondemand-proxy.py
