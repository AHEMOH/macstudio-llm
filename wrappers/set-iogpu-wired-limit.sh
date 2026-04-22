#!/usr/bin/env bash
# Runs once at boot via com.local.iogpu.wiredlimit — raises the GPU wired
# memory ceiling so Ollama can hold large models entirely in VRAM.
set -eu

CONF=/usr/local/etc/macstudio.conf
[ -r "$CONF" ] && . "$CONF"

TARGET_MB="${IOGPU_WIRED_LIMIT_MB:-30720}"

TOTAL_BYTES=$(/usr/sbin/sysctl -n hw.memsize 2>/dev/null || echo 0)
TOTAL_MB=$(( TOTAL_BYTES / 1024 / 1024 ))
if [ "$TOTAL_MB" -gt 0 ] && [ "$TARGET_MB" -ge "$TOTAL_MB" ]; then
  echo "[iogpu-wired-limit] requested ${TARGET_MB} MB >= total ${TOTAL_MB} MB; refusing" >&2
  exit 1
fi

CURRENT=$(/usr/sbin/sysctl -n iogpu.wired_limit_mb 2>/dev/null || echo 0)
if [ "$CURRENT" = "$TARGET_MB" ]; then
  echo "[iogpu-wired-limit] already at ${TARGET_MB} MB"
  exit 0
fi

/usr/sbin/sysctl -w iogpu.wired_limit_mb="$TARGET_MB"
echo "[iogpu-wired-limit] set iogpu.wired_limit_mb=${TARGET_MB} (was ${CURRENT})"
