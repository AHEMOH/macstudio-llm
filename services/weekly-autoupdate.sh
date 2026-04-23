#!/usr/bin/env bash
# Launched by com.local.weekly.autoupdate at the time set in
# /usr/local/etc/macstudio.conf (AUTOUPDATE_* keys). Default: Sat 06:00.
#
# Updates:
#   1. Homebrew formulas (ollama + node_exporter + brew itself)
#   2. Python venvs for immich-ml and docling-serve
#   3. macOS minor / security updates (no auto-reboot — see below)
#
# Reboots are FileVault-aware: we NEVER pass --restart to softwareupdate,
# because a plain reboot hangs at the FileVault pre-boot prompt. If an
# update needs a restart we write /var/macstudio/reboot-pending and log
# the required command; the operator clears it with:
#   sudo fdesetup authrestart
#
# Major macOS upgrades (26.x → 27.x) still require the GUI; run manually.
set -u

CONF=/usr/local/etc/macstudio.conf
[ -r "$CONF" ] && . "$CONF"

TARGET_USER="${TARGET_USER:-mac}"
TARGET_HOME="${TARGET_HOME:-/Users/mac}"
IMMICH_PROJECT_DIR="${IMMICH_PROJECT_DIR:-$TARGET_HOME/projects/immich-ml-metal}"
DOCLING_PROJECT_DIR="${DOCLING_PROJECT_DIR:-$TARGET_HOME/projects/docling-serve}"

LOG_DIR=/var/log/macstudio
mkdir -p "$LOG_DIR"
exec >>"$LOG_DIR/autoupdate.log" 2>&1

echo
echo "=== $(date '+%F %T') weekly autoupdate begin ==="

run_as_user() { sudo -u "$TARGET_USER" -H bash -lc "$*"; }

echo "--- Homebrew update & upgrade ---"
run_as_user '/opt/homebrew/bin/brew update' || true
run_as_user '/opt/homebrew/bin/brew upgrade ollama' || true
run_as_user '/opt/homebrew/bin/brew upgrade node_exporter' || true
run_as_user '/opt/homebrew/bin/brew cleanup -s --prune=7' || true

if [ "${INSTALL_IMMICH:-1}" = "1" ] && [ -d "$IMMICH_PROJECT_DIR/.venv" ]; then
  echo "--- immich-ml venv upgrade ---"
  run_as_user "cd '$IMMICH_PROJECT_DIR' && .venv/bin/pip install --upgrade pip" || true
  if [ -f "$IMMICH_PROJECT_DIR/requirements.txt" ]; then
    run_as_user "cd '$IMMICH_PROJECT_DIR' && .venv/bin/pip install --upgrade -r requirements.txt" || true
  fi
fi

if [ "${INSTALL_DOCLING:-1}" = "1" ] && [ -d "$DOCLING_PROJECT_DIR/.venv" ]; then
  echo "--- docling-serve venv upgrade ---"
  run_as_user "cd '$DOCLING_PROJECT_DIR' && .venv/bin/pip install --upgrade pip" || true
  run_as_user "cd '$DOCLING_PROJECT_DIR' && .venv/bin/pip install --upgrade 'docling[ocrmac,vlm,htmlrender,easyocr]' 'docling-serve[ui]'" || true
fi

echo "--- restart long-running services ---"
/bin/launchctl kickstart -k system/com.local.ollama.headless || true
/bin/launchctl kickstart -k system/com.local.immich.proxy   2>/dev/null || true
/bin/launchctl kickstart -k system/com.local.docling.proxy  2>/dev/null || true
/bin/launchctl kickstart -k system/com.local.node.exporter  2>/dev/null || true
/bin/launchctl kickstart -k system/com.local.silicon.exporter 2>/dev/null || true
/bin/launchctl kickstart -k system/com.local.ollama.exporter 2>/dev/null || true

echo "--- macOS minor / security updates (no --restart; FileVault-aware) ---"
su_out=$(/usr/bin/mktemp)
/usr/sbin/softwareupdate --install --all --agree-to-license 2>&1 | /usr/bin/tee "$su_out"
if /usr/bin/grep -qiE 'require that you restart|\[restart\]|restart.* required|action: restart' "$su_out"; then
  /bin/mkdir -p /var/macstudio
  /bin/date '+%F %T' > /var/macstudio/reboot-pending
  /bin/chmod 644 /var/macstudio/reboot-pending
  echo
  echo "!!! A macOS restart is required to finish applying the updates above."
  echo "    Flag written: /var/macstudio/reboot-pending"
  echo "    Run this (FileVault-aware, survives power loss until next reboot):"
  echo "        sudo fdesetup authrestart"
  echo "    Plain 'sudo reboot' / 'shutdown -r' would hang at the FileVault"
  echo "    lock screen until someone types a password at the console."
else
  # No restart needed → clear any stale pending flag from a prior run.
  /bin/rm -f /var/macstudio/reboot-pending 2>/dev/null || true
fi
/bin/rm -f "$su_out"

echo "=== $(date '+%F %T') weekly autoupdate end ==="
