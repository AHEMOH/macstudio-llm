#!/usr/bin/env bash
# Launched by com.local.node.exporter — Prometheus node_exporter (brew).
set -eu

CONF=/usr/local/etc/macstudio.conf
[ -r "$CONF" ] && . "$CONF"

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
PORT="${NODE_EXPORTER_PORT:-9100}"

exec /opt/homebrew/bin/node_exporter \
  --web.listen-address="0.0.0.0:${PORT}" \
  --collector.filesystem.mount-points-exclude='^/(System|private/var/vm)($|/)'
