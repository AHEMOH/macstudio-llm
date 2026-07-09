#!/usr/bin/env bash
# Launched by com.local.voicestt.proxy — asyncio TCP proxy that wakes the
# Speech-to-Text backend (com.local.voicestt.serve) on demand and stops it
# after idle. Same on-demand pattern as infinity/images/immich/docling
# (reuses ondemand-proxy.py unmodified).
#
# HEALTH_URL points at "/" rather than a dedicated health route: this
# backend (macos-speech-server) exposes only POST /v1/audio/* endpoints and
# 404s on any GET — ondemand-proxy.py's health_ok() treats any HTTP
# response, including 404, as "backend is up" (see its comment).
set -eu

CONF=/usr/local/etc/macstudio.conf
[ -r "$CONF" ] && . "$CONF"

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
export LISTEN_HOST="0.0.0.0"
export LISTEN_PORT="${VOICESTT_PUBLIC_PORT:-5006}"
export BACKEND_HOST="127.0.0.1"
export BACKEND_PORT="${VOICESTT_BACKEND_PORT:-15006}"
export BACKEND_LABEL="com.local.voicestt.serve"
export HEALTH_URL="http://127.0.0.1:${VOICESTT_BACKEND_PORT:-15006}/"
export IDLE_TIMEOUT_SEC="${IDLE_TIMEOUT_VOICESTT:-900}"
export STARTUP_TIMEOUT_SEC="${STARTUP_TIMEOUT_VOICESTT:-60}"
export SERVICE_NAME="voicestt"

exec /usr/bin/python3 /usr/local/libexec/ondemand-proxy.py
