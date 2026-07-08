#!/usr/bin/env bash
# Launched by com.local.images.proxy — asyncio TCP proxy that wakes the
# FLUX image-generation backend (com.local.images.serve) on demand and stops
# it after idle. Same on-demand pattern as infinity/docling/immich (reuses
# ondemand-proxy.py).
set -eu

CONF=/usr/local/etc/macstudio.conf
[ -r "$CONF" ] && . "$CONF"

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
export LISTEN_HOST="0.0.0.0"
export LISTEN_PORT="${IMAGES_PUBLIC_PORT:-5005}"
export BACKEND_HOST="127.0.0.1"
export BACKEND_PORT="${IMAGES_BACKEND_PORT:-15005}"
export BACKEND_LABEL="com.local.images.serve"
export HEALTH_URL="http://127.0.0.1:${IMAGES_BACKEND_PORT:-15005}/health"
export IDLE_TIMEOUT_SEC="${IDLE_TIMEOUT_IMAGES:-900}"
export STARTUP_TIMEOUT_SEC="${STARTUP_TIMEOUT_IMAGES:-60}"
export SERVICE_NAME="images"

exec /usr/bin/python3 /usr/local/libexec/ondemand-proxy.py
