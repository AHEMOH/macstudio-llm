#!/usr/bin/env bash
# Launched by com.local.ondemand.exporter — probes the on-demand stack
# (immich-ml, docling-serve) plus the memory-pressure watchdog and exposes
# the state as Prometheus text. Runs as root so `launchctl print system/*`
# returns full output on recent macOS.
set -eu

CONF=/usr/local/etc/macstudio.conf
[ -r "$CONF" ] && . "$CONF"

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
export LISTEN_PORT="${ONDEMAND_EXPORTER_PORT:-9103}"
export ML_PUBLIC_PORT="${ML_PUBLIC_PORT:-3003}"
export DOCLING_PUBLIC_PORT="${DOCLING_PUBLIC_PORT:-5001}"

exec /usr/bin/python3 /usr/local/libexec/ondemand-exporter.py
