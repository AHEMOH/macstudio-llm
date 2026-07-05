#!/usr/bin/env bash
# Launched by com.local.vncfilter — a tiny RFB security-type filter proxy in
# front of macOS Screen Sharing (:5900). Strips the Apple/ARD auth offer from
# the handshake so clients (including noVNC, which can't do ARD's WebCrypto
# auth over plain HTTP) only ever see VNC-password auth. Connect Windows VNC
# clients AND the noVNC bridge to VNC_FILTER_PORT, not :5900 directly.
set -eu

CONF=/usr/local/etc/macstudio.conf
[ -r "$CONF" ] && . "$CONF"

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
export LISTEN_HOST="0.0.0.0"
export LISTEN_PORT="${VNC_FILTER_PORT:-5901}"
export BACKEND_HOST="127.0.0.1"
export BACKEND_PORT="5900"
export ALLOWED_SEC_TYPES="2"

exec /usr/bin/python3 /usr/local/libexec/vnc-secfilter.py
