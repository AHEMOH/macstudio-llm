#!/usr/bin/env bash
# Launched by com.local.weekly.autoupdate at the time set in
# /usr/local/etc/macstudio.conf (AUTOUPDATE_* keys). Default: Sat 06:00.
#
# Updates ONLY the OS + Homebrew — the model/LLM stack is intentionally
# frozen (a surprise version jump broke a model once):
#   1. Homebrew: brew update, upgrade ALL formulas, cleanup. Safe for the
#      venvs: they point at the stable /opt/homebrew/opt/python@3.12 path, and
#      everything pip-side is pinned by setup.sh, not by brew.
#   2. immich-ml (if INSTALL_IMMICH=1): the ONE deliberately floating tool —
#      re-pulls IMMICH_ML_IMAGE_TAG ('release') so the ML container follows the
#      Portainer-managed Immich server instead of freezing at its first pull.
#   3. macOS: password-free items install (Safari etc.); OS updates notify-only.
# NOT touched here: oMLX (pinned via OMLX_REPO_REF), litellm/mflux (exact ==
# pins in setup.sh's ensure_python_venvs), the voice project (VOICE_REPO_REF),
# docling/paperless/novnc venvs (pinned at build), and the models.
# Upgrade those deliberately: bump the pin in config/setup.sh, then --apply.
# The run logs available-but-held versions so you can see when an update exists.
#
# macOS OS updates are NOTIFY-ONLY: on Apple Silicon `softwareupdate -i` of a
# macOS update needs the volume owner's password, which a launchd job can't
# type (every run until 2026-10 ended in "Failed to authenticate"). So a minor
# update in the CURRENT major is only downloaded and recorded in
# /var/macstudio/update-pending; a major upgrade (e.g. 26 → 27) is only logged.
# motd-compose.sh then shows the exact manual command at SSH login:
#   sudo softwareupdate -i "<label>" -R
# FileVault is OFF on this Mac (auto-login colima-svc), so a plain
# `sudo reboot` is fine whenever /var/macstudio/reboot-pending appears.
set -u

CONF=/usr/local/etc/macstudio.conf
[ -r "$CONF" ] && . "$CONF"

TARGET_USER="${TARGET_USER:-mac}"
TARGET_HOME="${TARGET_HOME:-/Users/mac}"

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

step "Homebrew: update + upgrade all formulas (pip-side LLM stack stays pinned)"
run_as_user '/opt/homebrew/bin/brew update' || true
run_as_user '/opt/homebrew/bin/brew upgrade' || true
run_as_user '/opt/homebrew/bin/brew cleanup -s --prune=7' || true

# DELIBERATELY NOT auto-upgraded: a surprise version jump broke a model before.
# oMLX is pinned via OMLX_REPO_REF (a git tag, not a PyPI package — checked
# against GitHub releases below); litellm/mflux carry exact == pins in
# setup.sh (2026-08 review: LiteLLM had a real PyPI supply-chain incident),
# and docling stays at its installed version. Upgrade them on purpose: bump
# the pin, then `sudo bash setup.sh --apply`. (immich-ml is the exception —
# see its own step below.)
step "held versions (available but NOT auto-upgraded — bump deliberately)"
for pair in "litellm:litellm" "mflux:mflux"; do
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
  # Pass $omlx_dir as a positional arg ($1) instead of interpolating it into the
  # bash -lc script string — a "'" in the path would otherwise break out of the
  # quoting and run as root.
  omlx_installed=$(sudo -u "$TARGET_USER" -H bash -lc \
    '/usr/bin/git -C "$1" describe --tags --exact-match 2>/dev/null || /usr/bin/git -C "$1" rev-parse --short HEAD 2>/dev/null' \
    _ "$omlx_dir")
  # Stable tags only (we never pin dev/rc builds) — otherwise v0.7.1.dev1 shows
  # up as "latest" next to an up-to-date v0.7.0.
  omlx_latest=$(/usr/bin/git ls-remote --tags --refs "${OMLX_REPO:-https://github.com/jundot/omlx}" 2>/dev/null \
    | /usr/bin/awk -F/ '{print $NF}' | /usr/bin/grep -viE 'dev|rc|a[0-9]|b[0-9]' \
    | /usr/bin/sort -V | /usr/bin/tail -1)
  printf "  %-10s installed=%s  latest_stable_tag=%s\n" omlx "${omlx_installed:-?}" "${omlx_latest:-?}"
fi
voice_dir="${VOICE_PROJECT_DIR:-$TARGET_HOME/projects/macos-speech-server}"
if [ "${INSTALL_VOICE:-0}" = "1" ] && [ -d "$voice_dir/.git" ]; then
  voice_url=$(/usr/bin/git -C "$voice_dir" remote get-url origin 2>/dev/null)
  voice_head=$(/usr/bin/git ls-remote "$voice_url" HEAD 2>/dev/null | /usr/bin/cut -c1-7)
  printf "  %-10s pinned=%s  upstream_head=%s\n" voice \
    "$(printf '%s' "${VOICE_REPO_REF:-?}" | /usr/bin/cut -c1-7)" "${voice_head:-?}"
fi
echo "  -> to upgrade the LLM stack on purpose: bump the pin + 'sudo bash setup.sh --apply'"

if [ "${INSTALL_IMMICH:-0}" = "1" ]; then
  step "immich-ml image (floating '${IMMICH_ML_IMAGE_TAG:-release}' tag — follows the Immich server)"
  setup_sh=$(/usr/bin/sed -n 's/^SETUP_SH=//p' /usr/local/etc/macstudio.repo 2>/dev/null)
  if [ -n "$setup_sh" ] && [ -r "$setup_sh" ]; then
    /bin/bash "$setup_sh" --update-immich-ml || echo "  immich-ml update failed (container left as it was)"
  else
    echo "  setup.sh not found via /usr/local/etc/macstudio.repo — run 'sudo bash setup.sh --apply' once"
  fi
fi

step "restart long-running services"
if [ "${INSTALL_MLX:-1}" = "1" ]; then
  /bin/launchctl kickstart -k system/com.local.omlx.main       2>/dev/null || true
  /bin/launchctl kickstart -k system/com.local.litellm.proxy  2>/dev/null || true
fi
[ "${INSTALL_IMMICH:-0}" = "1" ]  && { /bin/launchctl kickstart -k system/com.local.immich.proxy  2>/dev/null || true; }
[ "${INSTALL_DOCLING:-1}" = "1" ] && { /bin/launchctl kickstart -k system/com.local.docling.proxy 2>/dev/null || true; }
/bin/launchctl kickstart -k system/com.local.node.exporter  2>/dev/null || true
/bin/launchctl kickstart -k system/com.local.silicon.exporter 2>/dev/null || true

step "macOS updates (password-free items install; OS updates notify-only)"
FLAG_DIR=/var/macstudio
/bin/mkdir -p "$FLAG_DIR"
su_list=$(/usr/bin/mktemp); su_out=$(/usr/bin/mktemp)
trap 'rm -f "$su_list" "$su_out" 2>/dev/null || true' EXIT   # also clean up on Ctrl-C/kill mid-update
/usr/sbin/softwareupdate -l >"$su_list" 2>&1
cur_major=$(/usr/bin/sw_vers -productVersion | /usr/bin/cut -d. -f1)
pending_os=""
# `softwareupdate -l` prints "* Label: <label>" followed by a "Title: …,
# Version: <v>, …" line. Pair them up as label<TAB>version, one per update.
updates=$(/usr/bin/awk '
  /^\* Label: / { sub(/^\* Label: /, ""); label = $0; next }
  /Version: /   { if (label != "") { v = $0; sub(/.*Version: /, "", v); sub(/,.*/, "", v)
                                     print label "\t" v; label = "" } }
' "$su_list")
tab=$(printf '\t')
while IFS="$tab" read -r label version; do
  [ -n "$label" ] || continue
  case "$label" in
    macOS*)
      if [ "${version%%.*}" = "$cur_major" ]; then
        echo "  macOS update (current major $cur_major): $label — downloading only (install needs your password)"
        # </dev/null: softwareupdate reads stdin and would otherwise swallow the
        # rest of this loop's list (2026-10-14: the 27.x line never got logged).
        # Its trailing "Failed to authenticate" after a SUCCESSFUL download is
        # the install-preparation step we deliberately leave to the user.
        /usr/sbin/softwareupdate -d "$label" </dev/null 2>&1 \
          | /usr/bin/grep -v "Failed to authenticate" | /usr/bin/tail -3
        pending_os="${pending_os}${label}
"
      else
        echo "  major upgrade available: $label — NOT installed (manual, via System Settings)"
      fi
      ;;
    *)
      echo "  installing: $label"
      /usr/sbin/softwareupdate -i "$label" --agree-to-license </dev/null 2>&1 | /usr/bin/tee -a "$su_out"
      ;;
  esac
done <<EOF_UPDATES
$updates
EOF_UPDATES
[ -n "$updates" ] || echo "  no updates available"

if [ -n "$pending_os" ]; then
  printf '%s' "$pending_os" >"$FLAG_DIR/update-pending"
  /bin/chmod 644 "$FLAG_DIR/update-pending"
  echo
  echo "!!! macOS update(s) downloaded — install by hand (asks your password, reboots):"
  printf '%s' "$pending_os" | while IFS= read -r l; do
    [ -n "$l" ] && echo "        sudo softwareupdate -i \"$l\" -R"
  done
else
  /bin/rm -f "$FLAG_DIR/update-pending" 2>/dev/null || true
fi

if /usr/bin/grep -qiE 'require that you restart|\[restart\]|restart.* required|action: restart' "$su_out"; then
  /bin/date '+%F %T' >"$FLAG_DIR/reboot-pending"
  /bin/chmod 644 "$FLAG_DIR/reboot-pending"
  echo
  echo "!!! A restart is required to finish the updates above:  sudo reboot"
  echo "    (FileVault is off and auto-login is set — the Mac comes back on its own.)"
elif [ -f "$FLAG_DIR/reboot-pending" ]; then
  # Clear a stale flag only once the Mac has actually rebooted since it was set.
  boot_epoch=$(/usr/sbin/sysctl -n kern.boottime | /usr/bin/sed -E 's/.*sec = ([0-9]+).*/\1/')
  flag_epoch=$(/usr/bin/stat -f %m "$FLAG_DIR/reboot-pending")
  if [ "${boot_epoch:-0}" -gt "${flag_epoch:-0}" ] 2>/dev/null; then
    /bin/rm -f "$FLAG_DIR/reboot-pending"
  fi
fi
/bin/rm -f "$su_list" "$su_out"

# Refresh /etc/motd so its "action needed" block appears/clears right away.
if [ -x /usr/local/sbin/motd-compose.sh ]; then
  /usr/local/sbin/motd-compose.sh /etc/motd.macstudio.base /etc/motd || true
fi

echo
echo "=== $(date '+%F %T') weekly autoupdate end ==="
