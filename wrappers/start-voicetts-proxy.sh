#!/usr/bin/env bash
# Launched by com.local.voicetts.proxy — asyncio TCP proxy that wakes the
# Text-to-Speech backend (com.local.voicetts.serve) on demand and stops it
# after idle. Same on-demand pattern as infinity/images/immich/docling
# (reuses ondemand-proxy.py unmodified).
set -eu

CONF=/usr/local/etc/macstudio.conf
[ -r "$CONF" ] && . "$CONF"

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
export LISTEN_HOST="0.0.0.0"
export LISTEN_PORT="${VOICETTS_PUBLIC_PORT:-5007}"
export BACKEND_HOST="127.0.0.1"
export BACKEND_PORT="${VOICETTS_BACKEND_PORT:-15007}"
export BACKEND_LABEL="com.local.voicetts.serve"
export HEALTH_URL="http://127.0.0.1:${VOICETTS_BACKEND_PORT:-15007}/health"
export IDLE_TIMEOUT_SEC="${IDLE_TIMEOUT_VOICETTS:-900}"
export STARTUP_TIMEOUT_SEC="${STARTUP_TIMEOUT_VOICETTS:-60}"
export SERVICE_NAME="voicetts"

exec /usr/bin/python3 /usr/local/libexec/ondemand-proxy.py
