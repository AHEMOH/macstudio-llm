#!/usr/bin/env bash
# Launched by com.local.weekly.autoupdate at the time set in
# /usr/local/etc/macstudio.conf (AUTOUPDATE_* keys). Default: Sat 06:00.
#
# Updates:
#   1. Homebrew formulas (ollama + node_exporter + brew itself)
#   2. Python venvs for immich-ml and docling-serve
#   3. macOS minor / security updates (restarts the Mac if needed)
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

echo "--- macOS minor / security updates (will reboot if required) ---"
/usr/sbin/softwareupdate --install --all --restart --agree-to-license || true

echo "=== $(date '+%F %T') weekly autoupdate end ==="
