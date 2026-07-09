#!/usr/bin/env bash
# Launched by com.local.voicewyoming.proxy — asyncio TCP proxy that wakes the
# SAME Speech-to-Text backend as com.local.voicestt.proxy (com.local.voicestt.
# serve) on demand, but forwards to its Wyoming port instead of its HTTP port.
# One Wyoming TCP connection carries BOTH STT and TTS for Home Assistant's
# native Wyoming integration — HA auto-discovers both capabilities on this
# single port. Reuses ondemand-proxy.py unmodified; health is checked via the
# backend's HTTP port (Wyoming itself isn't a simple GET-able protocol).
#
# IDLE_TIMEOUT_SEC intentionally reuses IDLE_TIMEOUT_VOICESTT (default -1,
# never sleep): two independent proxies (this one + com.local.voicestt.proxy)
# share one backend daemon, and letting either auto-sleep it on its own idle
# clock would fight the other's wake cycle.
set -eu

CONF=/usr/local/etc/macstudio.conf
[ -r "$CONF" ] && . "$CONF"

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
export LISTEN_HOST="0.0.0.0"
export LISTEN_PORT="${VOICE_WYOMING_PUBLIC_PORT:-10300}"
export BACKEND_HOST="127.0.0.1"
export BACKEND_PORT="${VOICE_WYOMING_BACKEND_PORT:-15008}"
export BACKEND_LABEL="com.local.voicestt.serve"
export HEALTH_URL="http://127.0.0.1:${VOICESTT_BACKEND_PORT:-15006}/"
export IDLE_TIMEOUT_SEC="${IDLE_TIMEOUT_VOICESTT:--1}"
export STARTUP_TIMEOUT_SEC="${STARTUP_TIMEOUT_VOICESTT:-60}"
export SERVICE_NAME="voicewyoming"

exec /usr/bin/python3 /usr/local/libexec/ondemand-proxy.py
