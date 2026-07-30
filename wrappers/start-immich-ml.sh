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

CONTAINER=immich_machine_learning
DOCKER=/opt/homebrew/bin/docker

# --- stop path -----------------------------------------------------------
# `launchctl stop com.local.immich.ml` sends SIGTERM to whatever pid launchd
# tracks for this job. An earlier version of this wrapper `exec`'d straight
# into `docker start -a`, making the attached docker CLI itself the tracked
# pid, and relied on its `--sig-proxy=true` default to forward SIGTERM into
# the container's tini (confirmed exec-form PID 1, not shell-form) -> gunicorn.
# That chain CAN work end-to-end (confirmed live: clean stop->restart cycles),
# but a real 44+ hour window was also observed where it silently didn't (see
# docs/immich-ml-idle-sleep-bug.md) — leading theory is gunicorn's arbiter,
# busy in a tight OOM-triggered worker-respawn loop (separately fixed by
# right-sizing the Colima VM, IMMICH_COLIMA_CPU/_MEMORY), wasn't servicing its
# own signal queue promptly. This wrapper no longer needs that theory to be
# true either way: `docker stop` talks to dockerd directly (its own SIGTERM to
# the container's real PID 1, then an unmaskable SIGKILL after --time seconds)
# — independent of whatever the attached CLI's signal plumbing or the
# container's own userspace responsiveness is doing.
#
# Keyed on the container NAME, not a child pid, so this is already correct
# (a safe no-op) even if a stop signal arrives before `docker start -a` below
# has been launched.
#
# --time 15 gives gunicorn's own ~10s --graceful-timeout room to finish
# cleanly before Docker's own grace would otherwise force a SIGKILL at
# roughly the same moment; paired with this job's plist ExitTimeOut=30 so
# launchd's own last-resort SIGKILL of THIS wrapper can't fire first.
stop_container() {
  # set +e: a failing `docker stop` here (already exited, transient socket
  # hiccup) must not itself abort this handler under the script's `set -eu`.
  set +e
  echo "[start-immich-ml] caught stop signal, running: docker stop --time 15 $CONTAINER" >&2
  "$DOCKER" stop --time 15 "$CONTAINER" >&2
  set -e
}
trap stop_container TERM INT

# Colima's own `brew services` LaunchAgent (RunAtLoad) is NOT reliable right
# at boot — confirmed live 2026-07-27: even with the auto-login session
# already up, it can fail its first start attempt (a race with
# Virtualization.framework not being ready that early) and then never retry.
# Self-heal here instead of depending on that timing: if the docker socket
# isn't answering, start colima ourselves before continuing. No-op (fast) once
# colima is already up, which is the common case after the first request.
# (Known, accepted limitation: a stop signal landing while this is mid-flight
# won't be handled until it returns, since it's a plain foreground command,
# not `wait` — not a regression, and too narrow a window, reachable only via
# a stop racing a cold boot, to be worth the extra complexity of closing.)
if ! "$DOCKER" info >/dev/null 2>&1; then
  /opt/homebrew/bin/colima start >&2 || {
    echo "colima start failed" >&2
    exit 1
  }
fi

# docker create'd once by ensure_immich_ml_container(); this (re)starts it and
# attaches so launchd has a real, trackable foreground pid — same contract
# the old venv-python process gave services/ondemand-proxy.py (health-checked
# at ML_BACKEND_PORT). Backgrounded (not exec'd) specifically so the stop path
# above works: this bash process is now what launchd tracks, staying alive
# exactly as long as `docker start -a` does.
"$DOCKER" start -a "$CONTAINER" &
child_pid=$!

# set +e: a container that exited because we asked it to (via the trap above)
# is the expected, successful shutdown path, not a wrapper failure — under
# `set -eu`, letting `wait` propagate that non-zero status directly would
# otherwise be treated as this script itself failing.
set +e
wait "$child_pid"
status=$?
set -e
exit "$status"
