#!/usr/bin/env bash
# Launched by com.local.infinity.proxy — asyncio TCP proxy that wakes the
# Infinity embed+rerank backend (com.local.infinity.serve) on demand and stops
# it after idle. Same on-demand pattern as docling (reuses ondemand-proxy.py).
set -eu

CONF=/usr/local/etc/macstudio.conf
[ -r "$CONF" ] && . "$CONF"

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
export LISTEN_HOST="0.0.0.0"
export LISTEN_PORT="${INFINITY_PUBLIC_PORT:-5004}"
export BACKEND_HOST="127.0.0.1"
export BACKEND_PORT="${INFINITY_BACKEND_PORT:-15004}"
export BACKEND_LABEL="com.local.infinity.serve"
export HEALTH_URL="http://127.0.0.1:${INFINITY_BACKEND_PORT:-15004}/health"
export IDLE_TIMEOUT_SEC="${IDLE_TIMEOUT_INFINITY:-900}"
export STARTUP_TIMEOUT_SEC="${STARTUP_TIMEOUT_INFINITY:-180}"
export SERVICE_NAME="infinity"

exec /usr/bin/python3 /usr/local/libexec/ondemand-proxy.py
