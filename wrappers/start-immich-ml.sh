#!/usr/bin/env bash
# Launched by com.local.immich.ml (on-demand, woken by com.local.immich.proxy).
set -eu

CONF=/usr/local/etc/macstudio.conf
[ -r "$CONF" ] && . "$CONF"

export HOME="${TARGET_HOME:-/Users/mac}"
export USER="${TARGET_USER:-mac}"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
unset PYENV_VERSION

export ML_HOST="127.0.0.1"
export ML_PORT="${ML_BACKEND_PORT:-13003}"

cd "${IMMICH_PROJECT_DIR:-$HOME/projects/immich-ml-metal}"
exec "${IMMICH_PROJECT_DIR:-$HOME/projects/immich-ml-metal}/.venv/bin/python" -m src.main
