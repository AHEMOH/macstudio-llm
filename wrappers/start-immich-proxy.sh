#!/usr/bin/env bash
# Launched by com.local.immich.proxy — asyncio TCP proxy that wakes the
# immich-ml backend on demand and stops it after idle timeout.
set -eu

CONF=/usr/local/etc/macstudio.conf
[ -r "$CONF" ] && . "$CONF"

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
export LISTEN_HOST="0.0.0.0"
export LISTEN_PORT="${ML_PUBLIC_PORT:-3003}"
export BACKEND_HOST="127.0.0.1"
export BACKEND_PORT="${ML_BACKEND_PORT:-13003}"
export BACKEND_LABEL="com.local.immich.ml"
export HEALTH_URL="http://127.0.0.1:${ML_BACKEND_PORT:-13003}/ping"
export IDLE_TIMEOUT_SEC="${IDLE_TIMEOUT_IMMICH:-900}"
export STARTUP_TIMEOUT_SEC="${STARTUP_TIMEOUT_IMMICH:-60}"
export SERVICE_NAME="immich"

exec /usr/bin/python3 /usr/local/libexec/ondemand-proxy.py
