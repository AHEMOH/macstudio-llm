#!/usr/bin/env bash
# Memory-pressure watchdog — belt-and-suspenders safety net that stops
# optional services when macOS reports memory pressure. Even with
# on-demand proxies, a rare combined spike (big model load + both
# services in use) can trigger Warn. This keeps Ollama healthy.
#
# Launched by com.local.llm.watchdog (KeepAlive=true).
set -u

CONF=/usr/local/etc/macstudio.conf
[ -r "$CONF" ] && . "$CONF"

POLL_INTERVAL="${WATCHDOG_POLL_INTERVAL:-15}"
PRESSURE_THRESHOLD="${WATCHDOG_PRESSURE_THRESHOLD:-warn}"
AUTO_RESTORE="${WATCHDOG_AUTO_RESTORE:-0}"
RESTORE_DELAY="${WATCHDOG_RESTORE_DELAY:-120}"

LOG=/var/log/macstudio/watchdog.log
mkdir -p "$(dirname "$LOG")"

IMMICH_LABEL=com.local.immich.ml
DOCLING_LABEL=com.local.docling.serve

ts()   { date '+%F %T'; }
log()  { printf "[%s][watchdog] %s\n" "$(ts)" "$*" >>"$LOG"; }
warn() { printf "[%s][watchdog][WARN] %s\n" "$(ts)" "$*" >>"$LOG"; }

daemon_pid() {
  /bin/launchctl print "system/$1" 2>/dev/null \
    | awk '/^[[:space:]]*pid[[:space:]]*=/{print $3; exit}'
}

daemon_running() {
  local pid
  pid=$(daemon_pid "$1")
  [ -n "$pid" ] && [ "$pid" != "0" ]
}

svc_stop() {
  local label="$1" name="$2"
  if daemon_running "$label"; then
    log "PRESSURE: stopping ${name} to free RAM"
    /bin/launchctl stop "$label" >/dev/null 2>&1 || true
  fi
}

svc_wake() {
  local label="$1" name="$2"
  if /bin/launchctl print "system/$label" >/dev/null 2>&1; then
    log "RESTORE: kickstarting ${name}"
    /bin/launchctl kickstart "system/$label" >/dev/null 2>&1 || true
  fi
}

get_pressure_level() {
  local output
  output=$(/usr/bin/memory_pressure 2>/dev/null | head -5 || echo "")
  if printf "%s" "$output" | grep -qi "pressure: Critical"; then
    echo critical
  elif printf "%s" "$output" | grep -qi "pressure: Warn"; then
    echo warn
  elif printf "%s" "$output" | grep -qi "pressure: Normal"; then
    echo normal
  else
    local pageouts
    pageouts=$(/usr/bin/vm_stat 2>/dev/null | awk '/Pageouts/{gsub(/\./,"",$2); print $2+0}')
    if [ "${pageouts:-0}" -gt 1000 ]; then echo warn; else echo normal; fi
  fi
}

should_trigger() {
  case "$PRESSURE_THRESHOLD" in
    warn)     [ "$1" = warn ] || [ "$1" = critical ] ;;
    critical) [ "$1" = critical ] ;;
    *)        return 1 ;;
  esac
}

offloaded=0
normal_since=0

log "watchdog start poll=${POLL_INTERVAL}s threshold=${PRESSURE_THRESHOLD} auto_restore=${AUTO_RESTORE}"

while true; do
  level=$(get_pressure_level)
  if should_trigger "$level"; then
    if [ "$offloaded" = 0 ]; then
      warn "memory pressure ${level} — offloading optional services"
      svc_stop "$IMMICH_LABEL" immich-ml
      svc_stop "$DOCLING_LABEL" docling-serve
      offloaded=1
      normal_since=0
    fi
  else
    if [ "$offloaded" = 1 ]; then
      now=$(date +%s)
      if [ "$normal_since" = 0 ]; then
        normal_since=$now
        log "pressure back to normal — waiting ${RESTORE_DELAY}s"
      elif [ $(( now - normal_since )) -ge "$RESTORE_DELAY" ]; then
        log "sustained normal pressure ${RESTORE_DELAY}s"
        if [ "$AUTO_RESTORE" = 1 ]; then
          svc_wake "$IMMICH_LABEL" immich-ml
          svc_wake "$DOCLING_LABEL" docling-serve
        else
          log "auto_restore=0 — proxies will wake backends on next request"
        fi
        offloaded=0
        normal_since=0
      fi
    fi
  fi
  sleep "$POLL_INTERVAL"
done
