#!/usr/bin/env bash
# Launched by com.local.docling.proxy — asyncio TCP proxy that wakes the
# docling-serve backend on demand and stops it after idle timeout.
set -eu

CONF=/usr/local/etc/macstudio.conf
[ -r "$CONF" ] && . "$CONF"

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
export LISTEN_HOST="0.0.0.0"
export LISTEN_PORT="${DOCLING_PUBLIC_PORT:-5001}"
export BACKEND_HOST="127.0.0.1"
export BACKEND_PORT="${DOCLING_BACKEND_PORT:-15001}"
export BACKEND_LABEL="com.local.docling.serve"
export HEALTH_URL="http://127.0.0.1:${DOCLING_BACKEND_PORT:-15001}/version"
export IDLE_TIMEOUT_SEC="${IDLE_TIMEOUT_DOCLING:-900}"
export STARTUP_TIMEOUT_SEC="${STARTUP_TIMEOUT_DOCLING:-120}"
export SERVICE_NAME="docling"

exec /usr/bin/python3 /usr/local/libexec/ondemand-proxy.py
