#!/usr/bin/env bash
# Launched by com.local.immich.ml (on-demand, woken by com.local.immich.proxy).
# Runs as IMMICH_SESSION_USER (plist UserName) — NOT TARGET_USER — because it
# needs that account's colima docker socket (see ensure_immich_ml_container()
# in setup.sh for why colima itself lives under a separate, auto-login
# account rather than TARGET_USER).
set -eu

CONF=/usr/local/etc/macstudio.conf
[ -r "$CONF" ] && . "$CONF"

SESSION_USER="${IMMICH_SESSION_USER:-colima-svc}"
export HOME="/Users/$SESSION_USER"
export USER="$SESSION_USER"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
# colima doesn't register a "colima" docker CLI context on this macOS/colima
# combination — its socket lives per-user at ~/.colima/default/docker.sock
# regardless (see ensure_immich_ml_container() in setup.sh).
export DOCKER_HOST="unix://$HOME/.colima/default/docker.sock"

# Colima's own `brew services` LaunchAgent (RunAtLoad) is NOT reliable right
# at boot — confirmed live 2026-07-27: even with the auto-login session
# already up, it can fail its first start attempt (a race with
# Virtualization.framework not being ready that early) and then never retry.
# Self-heal here instead of depending on that timing: if the docker socket
# isn't answering, start colima ourselves before continuing. No-op (fast) once
# colima is already up, which is the common case after the first request.
if ! /opt/homebrew/bin/docker info >/dev/null 2>&1; then
  /opt/homebrew/bin/colima start >&2 || {
    echo "colima start failed" >&2
    exit 1
  }
fi

# docker create'd once by ensure_immich_ml_container(); this just (re)starts
# it and attaches so launchd has a real, trackable foreground pid — same
# contract the old venv-python process gave services/ondemand-proxy.py
# (health-checked at ML_BACKEND_PORT). `docker start -a` proxies signals to
# the container by default (--sig-proxy), so `launchctl stop`'s SIGTERM stops
# the container itself, not just this CLI client.
exec /opt/homebrew/bin/docker start -a immich_machine_learning
