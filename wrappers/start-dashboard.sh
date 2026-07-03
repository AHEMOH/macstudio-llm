#!/usr/bin/env bash
# Launched by com.local.dashboard — the web dashboard (browser control of
# models / services / settings / logs / telemetry) on :DASHBOARD_PORT. Runs as
# root (the plist has no UserName): it reads `launchctl print system/*`,
# kickstarts daemons, and spawns `setup.sh --apply/--set-model/…` as DETACHED
# jobs (start_new_session — see dashboard.py) so an apply survives the
# dashboard's own restart. Stdlib python3 only.
set -eu

CONF=/usr/local/etc/macstudio.conf
[ -r "$CONF" ] && . "$CONF"

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
export DASHBOARD_PORT="${DASHBOARD_PORT:-8090}"

exec /usr/bin/python3 /usr/local/libexec/dashboard.py
