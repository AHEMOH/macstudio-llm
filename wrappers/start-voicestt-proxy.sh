#!/usr/bin/env bash
# Launched by com.local.voicestt.proxy — asyncio TCP proxy that wakes the
# Speech-to-Text backend (com.local.voicestt.serve) on demand and stops it
# after idle. Same on-demand pattern as infinity/images/immich/docling
# (reuses ondemand-proxy.py unmodified).
#
# HEALTH_URL uses macos-speech-server's own GET /health (upstream #38, part of
# the 211c5de pin). Before that it pointed at bare "/" and relied on
# ondemand-proxy.py's health_ok() treating any HTTP response (incl. 404) as up.
set -eu

CONF=/usr/local/etc/macstudio.conf
[ -r "$CONF" ] && . "$CONF"

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
export LISTEN_HOST="0.0.0.0"
export LISTEN_PORT="${VOICESTT_PUBLIC_PORT:-5006}"
export BACKEND_HOST="127.0.0.1"
export BACKEND_PORT="${VOICESTT_BACKEND_PORT:-15006}"
export BACKEND_LABEL="com.local.voicestt.serve"
export HEALTH_URL="http://127.0.0.1:${VOICESTT_BACKEND_PORT:-15006}/health"
export IDLE_TIMEOUT_SEC="${IDLE_TIMEOUT_VOICESTT:-900}"
export STARTUP_TIMEOUT_SEC="${STARTUP_TIMEOUT_VOICESTT:-60}"
export SERVICE_NAME="voicestt"

exec /usr/bin/python3 /usr/local/libexec/ondemand-proxy.py
