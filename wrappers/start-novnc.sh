#!/usr/bin/env bash
# Launched by com.local.novnc — the browser VNC bridge. websockify serves the
# noVNC HTML5 client (static files under /usr/local/share/novnc) as its --web
# root and proxies the browser's WebSocket to macOS Screen Sharing (VNC) on
# 127.0.0.1:5900. Runs as TARGET_USER (the plist sets UserName — no root needed).
# LAN-only; authentication is the Screen Sharing / VNC password (VNC_PASSWORD).
# Open http://<mac>:$NOVNC_PORT/vnc.html in a browser.
set -eu

CONF=/usr/local/etc/macstudio.conf
[ -r "$CONF" ] && . "$CONF"

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"

VENV_DIR="${VENV_DIR:-/Users/mac/.macstudio-venvs}"
NOVNC_PORT="${NOVNC_PORT:-6080}"
WEB=/usr/local/share/novnc
WS="$VENV_DIR/novnc/bin/websockify"

if [ ! -x "$WS" ]; then
  echo "websockify not found at $WS — run: sudo bash setup.sh --apply" >&2
  exit 78
fi
if [ ! -f "$WEB/vnc.html" ]; then
  echo "noVNC web assets missing at $WEB — run: sudo bash setup.sh --apply" >&2
  exit 78
fi

exec "$WS" --web "$WEB" "$NOVNC_PORT" 127.0.0.1:5900
