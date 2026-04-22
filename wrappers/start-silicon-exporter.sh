#!/usr/bin/env bash
# Launched by com.local.silicon.exporter — Apple Silicon metrics exporter
# built on powermetrics (root required; this plist runs without UserName).
set -eu

CONF=/usr/local/etc/macstudio.conf
[ -r "$CONF" ] && . "$CONF"

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
export LISTEN_PORT="${SILICON_EXPORTER_PORT:-9101}"

exec /usr/bin/python3 /usr/local/libexec/silicon-exporter.py
