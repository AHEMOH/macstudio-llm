#!/usr/bin/env bash
# Runs once at boot via com.local.iogpu.wiredlimit — raises the GPU wired
# memory ceiling so the MLX/oMLX model can stay entirely in GPU-wired memory.
set -eu

CONF=/usr/local/etc/macstudio.conf
[ -r "$CONF" ] && . "$CONF"

# Boot-time self-heal of the shared log dir (same rules as setup.sh's
# ensure_dirs). A major macOS upgrade wipes /var/log/macstudio; launchd then
# recreates it root:wheel 744 while opening a root daemon's log, and every
# daemon running as TARGET_USER fails its spawn with EX_CONFIG (78) because
# launchd opens StandardOutPath as that user — confirmed 2026-10-14 after the
# 26→27 upgrade (omlx, litellm, all proxies, novnc down). launchd does not
# retry an EX_CONFIG failure, so the already-failed labels get kickstarted.
LOG_DIR=/var/log/macstudio
log_user="${TARGET_USER:-mac}"
if [ "$(/usr/bin/stat -f '%Su %Lp' "$LOG_DIR" 2>/dev/null)" != "$log_user 775" ]; then
  echo "[iogpu-wired-limit] repairing $LOG_DIR ownership/mode"
  /bin/mkdir -p "$LOG_DIR" || true
  /usr/sbin/chown -R "$log_user:staff" "$LOG_DIR" || true
  /bin/chmod 775 "$LOG_DIR" || true
  /usr/bin/find "$LOG_DIR" -type f -exec /bin/chmod 660 {} + || true
  /bin/sleep 5   # let daemons racing us at boot finish failing first
  for label in $(/bin/launchctl list | /usr/bin/awk '$2 == 78 && $3 ~ /^com\.local\./ {print $3}'); do
    echo "[iogpu-wired-limit] kickstarting $label (failed with EX_CONFIG)"
    /bin/launchctl kickstart -k "system/$label" || true
  done
fi

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
