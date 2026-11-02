#!/usr/bin/env bash
# Launched by com.local.beszel.agent — Beszel monitoring agent (brew, runs as root).
set -eu

CONF=/usr/local/etc/macstudio.conf
[ -r "$CONF" ] && . "$CONF"

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
BIN=/opt/homebrew/bin/beszel-agent

if [ ! -x "$BIN" ]; then
  echo "beszel-agent not installed — run: sudo bash setup.sh --apply" >&2
  exit 78
fi
if [ -z "${BESZEL_HUB_URL:-}" ] || [ -z "${BESZEL_KEY:-}" ] || [ -z "${BESZEL_TOKEN:-}" ]; then
  echo "BESZEL_HUB_URL/BESZEL_KEY/BESZEL_TOKEN not set — run: sudo bash setup.sh --set-config BESZEL_HUB_URL '…' (same for _KEY/_TOKEN)" >&2
  exit 78
fi

# DATA_DIR holds the fingerprint the hub binds this system to on first registration —
# keep it outside the brew prefix so it survives upgrades and a disabled universal token.
DATA_DIR=/var/macstudio/beszel
/bin/mkdir -p "$DATA_DIR"
/bin/chmod 700 "$DATA_DIR"

export HOME=/var/root
export HUB_URL="$BESZEL_HUB_URL" KEY="$BESZEL_KEY" TOKEN="$BESZEL_TOKEN"
export LISTEN="${BESZEL_LISTEN:-45876}" DATA_DIR
# Apple-Silicon GPU stats are opt-in in the agent; empty = none. (No ANE metric in Beszel.)
[ -n "${BESZEL_GPU_COLLECTOR:-}" ] && export GPU_COLLECTOR="$BESZEL_GPU_COLLECTOR"
exec "$BIN"
