#!/usr/bin/env bash
# Launched by com.local.weekly.autoupdate at the time set in
# /usr/local/etc/macstudio.conf (AUTOUPDATE_* keys). Default: Sat 06:00.
#
# Updates ONLY the OS + system packages — the model/LLM stack is intentionally
# frozen (a surprise version jump broke a model once):
#   1. Homebrew: brew update, upgrade node_exporter, cleanup
#   2. macOS minor / security updates (no auto-reboot — see below)
# NOT touched here: oMLX (pinned via OMLX_REPO_REF), litellm,
# immich-ml, docling, and the models. Upgrade those deliberately via
# `setup.sh` ("Check for updates" → set the pin → Install/update everything).
# The run logs available-but-held versions so you can see when an update exists.
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
LOG_FILE="$LOG_DIR/autoupdate.log"
mkdir -p "$LOG_DIR"

# When run by launchd there is no terminal — write everything to the logfile.
# When invoked interactively (e.g. via `llm-update`) it's frustrating to see
# nothing happen for several minutes; tee the same stream to the terminal too.
if [ -t 1 ]; then
  exec > >(/usr/bin/tee -a "$LOG_FILE") 2>&1
else
  exec >>"$LOG_FILE" 2>&1
fi

# step() — a single, clearly marked progress line per phase so a human watching
# the terminal can see what's actively in flight. Same output in the log.
step() { printf "\n=== [%s] %s ===\n" "$(date '+%H:%M:%S')" "$*"; }

echo
echo "=== $(date '+%F %T') weekly autoupdate begin ==="
echo "log: $LOG_FILE"

run_as_user() { sudo -u "$TARGET_USER" -H bash -lc "$*"; }

VENV_DIR="${VENV_DIR:-$TARGET_HOME/.macstudio-venvs}"
HF_CACHE_DIR="${HF_CACHE_DIR:-$TARGET_HOME/.cache/huggingface}"
CATALOG_FILE=/usr/local/etc/macstudio-models/catalog.tsv

step "Homebrew: update + system packages only (LLM/model stack is frozen)"
run_as_user '/opt/homebrew/bin/brew update' || true
run_as_user '/opt/homebrew/bin/brew upgrade node_exporter' || true
run_as_user '/opt/homebrew/bin/brew cleanup -s --prune=7' || true

# DELIBERATELY NOT auto-upgraded: a surprise version jump broke a model before.
# oMLX is pinned via OMLX_REPO_REF (a git tag, not a PyPI package — checked
# against GitHub releases below); litellm, immich-ml and docling stay at
# their installed versions. Upgrade them on purpose with `setup.sh` (menu:
# Check for updates -> set the pin -> Install/update everything).
step "held versions (available but NOT auto-upgraded — bump deliberately)"
for pair in "litellm:litellm"; do
  vn=${pair%%:*}; pk=${pair##*:}
  py="$VENV_DIR/$vn/bin/python"; [ -x "$py" ] || continue
  "$py" - "$pk" <<'PY' 2>/dev/null || true
import sys, json, urllib.request, importlib.metadata as M
pkg=sys.argv[1]
try: cur=M.version(pkg)
except Exception: cur="?"
try:
    d=json.load(urllib.request.urlopen("https://pypi.org/pypi/%s/json"%pkg, timeout=8))
    print("  %-10s installed=%s  latest_stable=%s"%(pkg,cur,d["info"]["version"]))
except Exception:
    print("  %-10s installed=%s  (pypi check n/a)"%(pkg,cur))
PY
done
omlx_dir="${OMLX_PROJECT_DIR:-$TARGET_HOME/projects/omlx}"
if [ -d "$omlx_dir/.git" ]; then
  omlx_installed=$(run_as_user "/usr/bin/git -C '$omlx_dir' describe --tags --exact-match 2>/dev/null || /usr/bin/git -C '$omlx_dir' rev-parse --short HEAD 2>/dev/null")
  omlx_latest=$(/usr/bin/git ls-remote --tags --refs "${OMLX_REPO:-https://github.com/jundot/omlx}" 2>/dev/null \
    | /usr/bin/awk -F/ '{print $NF}' | /usr/bin/sort -V | /usr/bin/tail -1)
  printf "  %-10s installed=%s  latest_tag=%s\n" omlx "${omlx_installed:-?}" "${omlx_latest:-?}"
fi
echo "  -> to upgrade the LLM stack on purpose: OMLX_REPO_REF + 'sudo bash setup.sh --apply'"

step "restart long-running services"
if [ "${INSTALL_MLX:-1}" = "1" ]; then
  /bin/launchctl kickstart -k system/com.local.omlx.main       2>/dev/null || true
  /bin/launchctl kickstart -k system/com.local.litellm.proxy  2>/dev/null || true
fi
/bin/launchctl kickstart -k system/com.local.immich.proxy   2>/dev/null || true
/bin/launchctl kickstart -k system/com.local.docling.proxy  2>/dev/null || true
/bin/launchctl kickstart -k system/com.local.node.exporter  2>/dev/null || true
/bin/launchctl kickstart -k system/com.local.silicon.exporter 2>/dev/null || true

step "macOS minor / security updates (no --restart; FileVault-aware)"
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

echo
echo "=== $(date '+%F %T') weekly autoupdate end ==="
