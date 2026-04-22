#!/usr/bin/env bash
# =============================================================================
# MacStudio LLM Server — single entry point
#
#   sudo bash setup.sh             # interactive TUI
#   sudo bash setup.sh --apply     # non-interactive install/update
#   sudo bash setup.sh --status    # print live status and exit
#   sudo bash setup.sh --help      # show flags
#
# Idempotent. Re-run safely at any time. Every action inspects live state
# before changing anything.
# =============================================================================
set -u

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT_VERSION=1.0.0

# --- On-Mac target paths ----------------------------------------------------
CONF_FILE=/usr/local/etc/macstudio.conf
REPO_POINTER_FILE=/usr/local/etc/macstudio.repo
LOG_DIR=/var/log/macstudio
LIBEXEC_DIR=/usr/local/libexec
BIN_DIR=/usr/local/bin
SBIN_DIR=/usr/local/sbin
PLIST_DIR=/Library/LaunchDaemons
MOTD_FILE=/etc/motd
MOTD_BACKUP=/etc/motd.macstudio.bak

# --- Labels & their plist source filenames ---------------------------------
# Always-on services
ALWAYS_ON_LABELS=(
  com.local.ollama.headless
  com.local.immich.proxy
  com.local.docling.proxy
  com.local.node.exporter
  com.local.silicon.exporter
  com.local.ollama.exporter
  com.local.llm.watchdog
  com.local.preventsleep
  com.local.iogpu.wiredlimit
  com.local.weekly.autoupdate
)
# On-demand backends (KeepAlive=false, RunAtLoad=false)
ONDEMAND_LABELS=(
  com.local.immich.ml
  com.local.docling.serve
)
ALL_LABELS=( "${ALWAYS_ON_LABELS[@]}" "${ONDEMAND_LABELS[@]}" )

# --- Config keys with defaults --------------------------------------------
# (order preserved, used for save_config and menu_settings)
CONFIG_KEYS=(
  TARGET_USER
  TARGET_HOME
  IMMICH_PROJECT_DIR
  DOCLING_PROJECT_DIR
  IOGPU_WIRED_LIMIT_MB
  OLLAMA_PORT
  OLLAMA_MODELS
  OLLAMA_MAX_LOADED_MODELS
  OLLAMA_NUM_PARALLEL
  OLLAMA_FLASH_ATTENTION
  OLLAMA_KV_CACHE_TYPE
  OLLAMA_KEEP_ALIVE
  OLLAMA_LOAD_TIMEOUT
  ML_PUBLIC_PORT
  ML_BACKEND_PORT
  DOCLING_PUBLIC_PORT
  DOCLING_BACKEND_PORT
  IDLE_TIMEOUT_IMMICH
  IDLE_TIMEOUT_DOCLING
  STARTUP_TIMEOUT_IMMICH
  STARTUP_TIMEOUT_DOCLING
  AUTOUPDATE_WEEKDAY
  AUTOUPDATE_HOUR
  AUTOUPDATE_MINUTE
  NODE_EXPORTER_PORT
  SILICON_EXPORTER_PORT
  OLLAMA_EXPORTER_PORT
  INSTALL_IMMICH
  INSTALL_DOCLING
  INSTALL_EXPORTERS
  INSTALL_WATCHDOG
  WATCHDOG_PRESSURE_THRESHOLD
  WATCHDOG_AUTO_RESTORE
  AUTO_ACCEPT
)
# Bash-3.2 safe (macOS ships /bin/bash 3.2): lookup functions instead of
# associative arrays. Keep key order in CONFIG_KEYS above as the source of
# truth for iteration.
config_default() {
  case "$1" in
    TARGET_USER)                 echo mac ;;
    TARGET_HOME)                 echo /Users/mac ;;
    IMMICH_PROJECT_DIR)          echo /Users/mac/projects/immich-ml-metal ;;
    DOCLING_PROJECT_DIR)         echo /Users/mac/projects/docling-serve ;;
    IOGPU_WIRED_LIMIT_MB)        echo 30720 ;;
    OLLAMA_PORT)                 echo 11434 ;;
    OLLAMA_MODELS)               echo /Users/mac/.ollama/models ;;
    OLLAMA_MAX_LOADED_MODELS)    echo 1 ;;
    OLLAMA_NUM_PARALLEL)         echo 1 ;;
    OLLAMA_FLASH_ATTENTION)      echo 1 ;;
    OLLAMA_KV_CACHE_TYPE)        echo q8_0 ;;
    OLLAMA_KEEP_ALIVE)           echo -1 ;;
    OLLAMA_LOAD_TIMEOUT)         echo 15m ;;
    ML_PUBLIC_PORT)              echo 3003 ;;
    ML_BACKEND_PORT)             echo 13003 ;;
    DOCLING_PUBLIC_PORT)         echo 5001 ;;
    DOCLING_BACKEND_PORT)        echo 15001 ;;
    IDLE_TIMEOUT_IMMICH)         echo 900 ;;
    IDLE_TIMEOUT_DOCLING)        echo 900 ;;
    STARTUP_TIMEOUT_IMMICH)      echo 60 ;;
    STARTUP_TIMEOUT_DOCLING)     echo 120 ;;
    AUTOUPDATE_WEEKDAY)          echo 6 ;;
    AUTOUPDATE_HOUR)             echo 6 ;;
    AUTOUPDATE_MINUTE)           echo 0 ;;
    NODE_EXPORTER_PORT)          echo 9100 ;;
    SILICON_EXPORTER_PORT)       echo 9101 ;;
    OLLAMA_EXPORTER_PORT)        echo 9102 ;;
    INSTALL_IMMICH)              echo 1 ;;
    INSTALL_DOCLING)             echo 1 ;;
    INSTALL_EXPORTERS)           echo 1 ;;
    INSTALL_WATCHDOG)            echo 1 ;;
    WATCHDOG_PRESSURE_THRESHOLD) echo warn ;;
    WATCHDOG_AUTO_RESTORE)       echo 0 ;;
    AUTO_ACCEPT)                 echo 0 ;;
    *)                           echo "" ;;
  esac
}

config_hint() {
  case "$1" in
    IOGPU_WIRED_LIMIT_MB)        echo "GPU wired memory ceiling in MB (28672–30720 on 32 GB; 2048 headroom for OS)" ;;
    OLLAMA_KEEP_ALIVE)           echo "How long Ollama keeps a model in VRAM: -1=forever, 24h, 1h, 5m" ;;
    OLLAMA_KV_CACHE_TYPE)        echo "KV cache precision: q8_0 (recommended), q4_0 (aggressive), fp16 (default)" ;;
    IDLE_TIMEOUT_IMMICH)         echo "Seconds before immich-ml backend is put to sleep" ;;
    IDLE_TIMEOUT_DOCLING)        echo "Seconds before docling-serve backend is put to sleep" ;;
    AUTOUPDATE_WEEKDAY)          echo "launchd weekday: 0=Sun 1=Mon … 6=Sat" ;;
    AUTO_ACCEPT)                 echo "1 = skip all 'press Enter to proceed' prompts in TUI" ;;
    WATCHDOG_PRESSURE_THRESHOLD) echo "warn | critical — when watchdog offloads optional services" ;;
    *)                           echo "" ;;
  esac
}

# --- Colors -----------------------------------------------------------------
if [ -t 1 ]; then
  C_DIM='\033[2m'; C_BOLD='\033[1m'
  C_RED='\033[0;31m'; C_GRN='\033[0;32m'; C_YEL='\033[0;33m'; C_BLU='\033[0;34m'
  C_RST='\033[0m'
else
  C_DIM=; C_BOLD=; C_RED=; C_GRN=; C_YEL=; C_BLU=; C_RST=
fi

# --- Logging & prompts ------------------------------------------------------
log()  { printf "${C_BLU}[setup]${C_RST} %s\n" "$*"; }
ok()   { printf "${C_GRN}[ ok ]${C_RST} %s\n" "$*"; }
warn() { printf "${C_YEL}[warn]${C_RST} %s\n" "$*" >&2; }
err()  { printf "${C_RED}[err ]${C_RST} %s\n" "$*" >&2; }
dbg()  { [ "${VERBOSE:-0}" = 1 ] && printf "${C_DIM}[dbg ]${C_RST} %s\n" "$*" >&2; return 0; }

APPLY_MODE=0
INTERACTIVE=1
VERBOSE=0
DEBUG=0

confirm() {
  # confirm "Do the thing?"  → returns 0 (yes) or 1 (no)
  local prompt="$1"
  if [ "$INTERACTIVE" = 0 ] || [ "${AUTO_ACCEPT:-0}" = 1 ]; then
    return 0
  fi
  local ans
  read -r -p "$prompt [Y/n] " ans
  case "${ans:-y}" in
    y|Y|yes|YES) return 0 ;;
    *)           return 1 ;;
  esac
}

need_root() {
  # No-op: argv dispatch at the bottom of the file already self-elevates.
  # Kept as a documentation shim in case someone calls a function directly.
  [ "$(id -u)" -eq 0 ] || { err "must run as root"; exit 1; }
}

# --- Hash helpers -----------------------------------------------------------
hash_file() {
  if [ -f "$1" ]; then /usr/bin/shasum -a 256 "$1" | awk '{print $1}'; else echo missing; fi
}

install_if_different() {
  # install_if_different <src> <dst> <mode> [<owner>]
  local src=$1 dst=$2 mode=$3 owner=${4:-root:wheel}
  if [ "$(hash_file "$src")" = "$(hash_file "$dst")" ]; then
    dbg "unchanged: $dst"
    return 1   # no change
  fi
  dbg "installing: $src → $dst (mode $mode, owner $owner)"
  /bin/mkdir -p "$(dirname "$dst")"
  /usr/bin/install -m "$mode" -o "${owner%:*}" -g "${owner#*:}" "$src" "$dst"
  return 0     # changed
}

render_template() {
  # render_template <src> <dst> <mode> [<owner>]
  # Substitutes @KEY@ from env. Writes to dst only if content changed.
  local src=$1 dst=$2 mode=$3 owner=${4:-root:wheel}
  local tmp; tmp=$(/usr/bin/mktemp -t macstudio-render)
  local sedprog=""
  for k in "${CONFIG_KEYS[@]}" TOTAL_RAM_GB IDLE_MIN_IMMICH IDLE_MIN_DOCLING AUTOUPDATE_HUMAN; do
    local v="${!k:-}"
    v=$(printf '%s' "$v" | /usr/bin/sed -e 's/[\\&|]/\\&/g')
    sedprog+="s|@${k}@|${v}|g;"
  done
  /usr/bin/sed "$sedprog" "$src" >"$tmp"
  if [ "$(hash_file "$tmp")" = "$(hash_file "$dst")" ]; then
    dbg "template unchanged: $dst"
    rm -f "$tmp"
    return 1   # no change
  fi
  dbg "rendering template: $src → $dst (mode $mode, owner $owner)"
  /bin/mkdir -p "$(dirname "$dst")"
  /bin/chmod "$mode" "$tmp"
  /usr/sbin/chown "$owner" "$tmp" 2>/dev/null || true
  /bin/mv -f "$tmp" "$dst"
  return 0     # changed
}

# --- Config file management -------------------------------------------------
write_default_config() {
  /bin/mkdir -p "$(dirname "$CONF_FILE")"
  {
    echo "# /usr/local/etc/macstudio.conf — managed by setup.sh"
    echo "# Edit via: sudo bash setup.sh → menu 2, or sudo bash setup.sh --apply"
    echo "# Free-form edits are respected; unknown keys are preserved."
    echo
    for k in "${CONFIG_KEYS[@]}"; do
      printf '%s=%s\n' "$k" "$(config_default "$k")"
    done
  } >"$CONF_FILE"
  /bin/chmod 644 "$CONF_FILE"
}

load_config() {
  if [ ! -f "$CONF_FILE" ]; then
    dbg "config missing, writing defaults to $CONF_FILE"
    write_default_config
  else
    dbg "loading config from $CONF_FILE"
  fi
  # Fill in any missing keys from defaults without clobbering user values.
  local missing=()
  for k in "${CONFIG_KEYS[@]}"; do
    if ! /usr/bin/grep -qE "^${k}=" "$CONF_FILE"; then
      missing+=("$k")
    fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    dbg "added missing config keys: ${missing[*]}"
    {
      echo ""
      echo "# keys added on $(date '+%F')"
      for k in "${missing[@]}"; do
        printf '%s=%s\n' "$k" "$(config_default "$k")"
      done
    } >>"$CONF_FILE"
  fi
  # shellcheck disable=SC1090
  . "$CONF_FILE"
  # Export every key so render_template can reference them as env vars.
  for k in "${CONFIG_KEYS[@]}"; do export "$k"; done
  # Derived convenience vars for motd and the like
  local bytes mb
  bytes=$(/usr/sbin/sysctl -n hw.memsize 2>/dev/null || echo 0)
  mb=$(( bytes / 1024 / 1024 ))
  export TOTAL_RAM_GB=$(( (mb + 512) / 1024 ))
  export IDLE_MIN_IMMICH=$(( IDLE_TIMEOUT_IMMICH / 60 ))
  export IDLE_MIN_DOCLING=$(( IDLE_TIMEOUT_DOCLING / 60 ))
  local dow_names=(Sun Mon Tue Wed Thu Fri Sat)
  export AUTOUPDATE_HUMAN="$(printf '%s %02d:%02d' "${dow_names[$AUTOUPDATE_WEEKDAY]:-?}" "$AUTOUPDATE_HOUR" "$AUTOUPDATE_MINUTE")"
  # Compute ACTIVE_LABELS — the subset of ALL_LABELS the current config says
  # should be installed. Used by status/service-control menus. ALL_LABELS is
  # still the authoritative list for plist cleanup on toggle-off.
  ACTIVE_LABELS=()
  local _lbl
  for _lbl in "${ALL_LABELS[@]}"; do
    case "$_lbl" in
      com.local.immich.*)  [ "${INSTALL_IMMICH:-1}"  = 1 ] || continue ;;
      com.local.docling.*) [ "${INSTALL_DOCLING:-1}" = 1 ] || continue ;;
      com.local.node.exporter|com.local.silicon.exporter|com.local.ollama.exporter)
        [ "${INSTALL_EXPORTERS:-1}" = 1 ] || continue ;;
      com.local.llm.watchdog)
        [ "${INSTALL_WATCHDOG:-1}" = 1 ] || continue ;;
    esac
    ACTIVE_LABELS+=("$_lbl")
  done
}

save_config_key() {
  # save_config_key KEY VALUE — edit the single line in-place
  local key=$1 value=$2
  if /usr/bin/grep -qE "^${key}=" "$CONF_FILE"; then
    local tmp; tmp=$(/usr/bin/mktemp)
    /usr/bin/awk -v k="$key" -v v="$value" -F= '
      $1==k { printf "%s=%s\n", k, v; next }
            { print }' "$CONF_FILE" >"$tmp"
    /bin/mv -f "$tmp" "$CONF_FILE"
  else
    printf '%s=%s\n' "$key" "$value" >>"$CONF_FILE"
  fi
  /bin/chmod 644 "$CONF_FILE"
}

# --- label → log file mapping ---------------------------------------------
label_log() {
  case "$1" in
    com.local.ollama.headless)   echo "$LOG_DIR/ollama.log" ;;
    com.local.immich.proxy)      echo "$LOG_DIR/immich-proxy.log" ;;
    com.local.immich.ml)         echo "$LOG_DIR/immich-ml.log" ;;
    com.local.docling.proxy)     echo "$LOG_DIR/docling-proxy.log" ;;
    com.local.docling.serve)     echo "$LOG_DIR/docling-serve.log" ;;
    com.local.node.exporter)     echo "$LOG_DIR/node-exporter.log" ;;
    com.local.silicon.exporter)  echo "$LOG_DIR/silicon-exporter.log" ;;
    com.local.ollama.exporter)   echo "$LOG_DIR/ollama-exporter.log" ;;
    com.local.llm.watchdog)      echo "$LOG_DIR/watchdog.log" ;;
    com.local.preventsleep)      echo "$LOG_DIR/preventsleep.log" ;;
    com.local.iogpu.wiredlimit)  echo "$LOG_DIR/iogpu-wired-limit.log" ;;
    com.local.weekly.autoupdate) echo "$LOG_DIR/autoupdate.log" ;;
    *) echo "$LOG_DIR/${1#com.local.}.log" ;;
  esac
}

# --- launchctl helpers ------------------------------------------------------
daemon_pid() {
  /bin/launchctl print "system/$1" 2>/dev/null \
    | awk '/^[[:space:]]*pid[[:space:]]*=/{print $3; exit}'
}
daemon_loaded()  { /bin/launchctl print "system/$1" >/dev/null 2>&1; }
daemon_running() { local p; p=$(daemon_pid "$1"); [ -n "$p" ] && [ "$p" != 0 ]; }

bootstrap_plist() {
  local label=$1 plist="$PLIST_DIR/$1.plist"
  daemon_loaded "$label" && return 0
  /bin/launchctl bootstrap system "$plist" 2>/dev/null \
    && ok "bootstrapped $label" \
    || warn "bootstrap failed: $label"
}

bootout_plist() {
  local label=$1
  daemon_loaded "$label" || return 0
  /bin/launchctl bootout "system/$label" 2>/dev/null || true
}

reload_plist_if_changed() {
  # reload_plist_if_changed <label> <"changed"|"unchanged">
  local label=$1 status=$2
  case "$status" in
    changed)
      if daemon_loaded "$label"; then bootout_plist "$label"; fi
      bootstrap_plist "$label"
      ;;
    unchanged)
      if ! daemon_loaded "$label"; then bootstrap_plist "$label"; fi
      ;;
  esac
}

# ===========================================================================
# Idempotent "apply" functions — each is safe to re-run
# ===========================================================================

ensure_dirs() {
  /bin/mkdir -p "$LOG_DIR" "$LIBEXEC_DIR" "$SBIN_DIR" "$BIN_DIR" "$PLIST_DIR" \
                "$(dirname "$CONF_FILE")"
  /bin/chmod 755 "$LOG_DIR"
}

ensure_homebrew() {
  if command -v brew >/dev/null 2>&1 || [ -x /opt/homebrew/bin/brew ]; then
    ok "homebrew present"
    return 0
  fi
  warn "homebrew not installed — please install manually first:"
  warn '  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
  return 1
}

brew_() { sudo -u "$TARGET_USER" -H /opt/homebrew/bin/brew "$@"; }

ensure_formula() {
  local f=$1
  if brew_ list --formula "$f" >/dev/null 2>&1; then
    ok "brew: $f present"
  else
    log "brew install $f"
    brew_ install "$f" || warn "brew install $f failed"
  fi
}

ensure_formulas() {
  ensure_formula ollama
  [ "${INSTALL_EXPORTERS:-1}" = 1 ] && ensure_formula node_exporter
  # pipx is optional; used for asitop
  if ! command -v pipx >/dev/null 2>&1 && [ "${INSTALL_EXPORTERS:-1}" = 1 ]; then
    ensure_formula pipx
    brew_ postinstall pipx >/dev/null 2>&1 || true
  fi
  if command -v pipx >/dev/null 2>&1 && ! sudo -u "$TARGET_USER" -H pipx list 2>/dev/null | /usr/bin/grep -qi asitop; then
    log "pipx install asitop (optional ad-hoc TUI)"
    sudo -u "$TARGET_USER" -H pipx install asitop >/dev/null 2>&1 || true
  fi
}

ensure_immich_venv() {
  [ "${INSTALL_IMMICH:-1}" = 1 ] || return 0
  if [ -x "$IMMICH_PROJECT_DIR/.venv/bin/python" ]; then
    ok "immich-ml venv present"
    return 0
  fi
  warn "immich-ml venv missing at $IMMICH_PROJECT_DIR/.venv — create it manually:"
  warn "  cd $IMMICH_PROJECT_DIR && python3 -m venv .venv && .venv/bin/pip install -r requirements.txt"
}

ensure_docling_venv() {
  [ "${INSTALL_DOCLING:-1}" = 1 ] || return 0
  if [ -x "$DOCLING_PROJECT_DIR/.venv/bin/docling-serve" ]; then
    ok "docling-serve venv present"
    return 0
  fi
  warn "docling-serve venv missing at $DOCLING_PROJECT_DIR/.venv — create it manually:"
  warn "  cd $DOCLING_PROJECT_DIR && python3 -m venv .venv && .venv/bin/pip install 'docling[ocrmac,vlm,htmlrender,easyocr]' 'docling-serve[ui]'"
}

render_wrappers() {
  local changed=0 name dst
  for src in "$REPO_DIR"/wrappers/*.sh; do
    name=$(basename "$src")
    dst="$LIBEXEC_DIR/$name"
    if install_if_different "$src" "$dst" 755; then
      changed=$((changed+1)); ok "updated $dst"
    fi
  done
  # set-iogpu-wired-limit.sh belongs in sbin
  if install_if_different "$REPO_DIR/wrappers/set-iogpu-wired-limit.sh" "$SBIN_DIR/set-iogpu-wired-limit.sh" 755; then
    changed=$((changed+1)); ok "updated $SBIN_DIR/set-iogpu-wired-limit.sh"
  fi
  [ "$changed" -eq 0 ] && ok "wrappers up to date"
}

render_services() {
  local changed=0
  for src in "$REPO_DIR"/services/*.py; do
    local name dst; name=$(basename "$src"); dst="$LIBEXEC_DIR/$name"
    if install_if_different "$src" "$dst" 755; then changed=$((changed+1)); ok "updated $dst"; fi
  done
  if install_if_different "$REPO_DIR/services/llm-watchdog.sh" "$LIBEXEC_DIR/llm-watchdog.sh" 755; then
    changed=$((changed+1)); ok "updated $LIBEXEC_DIR/llm-watchdog.sh"
  fi
  if install_if_different "$REPO_DIR/services/weekly-autoupdate.sh" "$SBIN_DIR/weekly-autoupdate.sh" 755; then
    changed=$((changed+1)); ok "updated $SBIN_DIR/weekly-autoupdate.sh"
  fi
  [ "$changed" -eq 0 ] && ok "services up to date"
}

render_bin() {
  local changed=0
  for src in "$REPO_DIR"/bin/*; do
    [ -f "$src" ] || continue
    local name dst; name=$(basename "$src"); dst="$BIN_DIR/$name"
    if install_if_different "$src" "$dst" 755; then changed=$((changed+1)); ok "updated $dst"; fi
  done
  [ "$changed" -eq 0 ] && ok "user commands up to date"
}

render_all_plists() {
  local any_changed=0
  for label in "${ALL_LABELS[@]}"; do
    local src="$REPO_DIR/daemons/$label.plist"
    local dst="$PLIST_DIR/$label.plist"
    if [ ! -f "$src" ]; then
      warn "plist template missing in repo: $src"
      continue
    fi
    # Skip optional services per config
    case "$label" in
      com.local.immich.*)  [ "${INSTALL_IMMICH:-1}"  = 1 ] || { remove_plist "$label"; continue; } ;;
      com.local.docling.*) [ "${INSTALL_DOCLING:-1}" = 1 ] || { remove_plist "$label"; continue; } ;;
      com.local.node.exporter|com.local.silicon.exporter|com.local.ollama.exporter)
        [ "${INSTALL_EXPORTERS:-1}" = 1 ] || { remove_plist "$label"; continue; } ;;
      com.local.llm.watchdog)
        [ "${INSTALL_WATCHDOG:-1}" = 1 ] || { remove_plist "$label"; continue; } ;;
    esac
    local before_hash; before_hash=$(hash_file "$dst")
    render_template "$src" "$dst" 644 root:wheel || true
    local after_hash; after_hash=$(hash_file "$dst")
    if [ "$before_hash" != "$after_hash" ]; then
      any_changed=1
      ok "plist updated: $label"
      reload_plist_if_changed "$label" changed
    else
      reload_plist_if_changed "$label" unchanged
    fi
  done
  [ "$any_changed" = 0 ] && ok "plists up to date"
}

remove_plist() {
  local label=$1
  local dst="$PLIST_DIR/$label.plist"
  bootout_plist "$label"
  if [ -f "$dst" ]; then
    /bin/rm -f "$dst"
    ok "removed $dst (disabled by config)"
  fi
}

render_motd() {
  if [ ! -f "$REPO_DIR/motd.txt" ]; then return 0; fi
  # Back up the original once
  if [ ! -f "$MOTD_BACKUP" ] && [ -f "$MOTD_FILE" ]; then
    /bin/cp -f "$MOTD_FILE" "$MOTD_BACKUP"
  fi
  if render_template "$REPO_DIR/motd.txt" "$MOTD_FILE" 644 root:wheel; then
    ok "motd updated"
  fi
  # Ensure sshd actually shows it
  if [ -f /etc/ssh/sshd_config ] \
     && /usr/bin/grep -qiE '^\s*PrintMotd\s+no' /etc/ssh/sshd_config; then
    warn "/etc/ssh/sshd_config has 'PrintMotd no' — banner will not show on SSH login"
  fi
}

apply_iogpu_wired_limit() {
  local current target
  current=$(/usr/sbin/sysctl -n iogpu.wired_limit_mb 2>/dev/null || echo 0)
  target="${IOGPU_WIRED_LIMIT_MB:-30720}"
  if [ "$current" = "$target" ]; then
    ok "iogpu.wired_limit_mb already $target"
  else
    /usr/sbin/sysctl -w iogpu.wired_limit_mb="$target" >/dev/null \
      && ok "iogpu.wired_limit_mb set to $target (was $current)" \
      || warn "failed to set iogpu.wired_limit_mb"
  fi
}

apply_pmset() {
  # These settings are idempotent; pmset prints nothing when already set.
  /usr/bin/pmset -a autorestart 1 sleep 0 displaysleep 0 disksleep 0 \
                    powernap 0 standby 0 tcpkeepalive 1 womp 1 >/dev/null 2>&1 || true
  ok "pmset applied (autorestart=1, sleep=0, powernap=0)"
}

apply_os_trim() {
  /usr/bin/mdutil -i off "$OLLAMA_MODELS" >/dev/null 2>&1 || true
  /usr/bin/mdutil -i off "$LOG_DIR"       >/dev/null 2>&1 || true
  sudo -u "$TARGET_USER" defaults write com.apple.SubmitDiagInfo AutoSubmit -bool false 2>/dev/null || true
  sudo -u "$TARGET_USER" defaults write com.apple.CrashReporter DialogType none 2>/dev/null || true
  sudo -u "$TARGET_USER" defaults write com.apple.assistant.support "Assistant Enabled" -bool false 2>/dev/null || true
  ok "OS trim applied (Spotlight off on models/logs, analytics/crash/Siri disabled)"
}

write_repo_pointer() {
  /bin/mkdir -p "$(dirname "$REPO_POINTER_FILE")"
  printf 'SETUP_SH=%s/setup.sh\nREPO_DIR=%s\n' "$REPO_DIR" "$REPO_DIR" >"$REPO_POINTER_FILE"
  /bin/chmod 644 "$REPO_POINTER_FILE"
}

# ===========================================================================
# Orchestration
# ===========================================================================

apply_everything() {
  need_root "$@"
  dbg "step: load_config";           load_config
  dbg "step: ensure_dirs";            ensure_dirs
  if [ "$INTERACTIVE" = 1 ]; then
    dbg "step: apply_leftover_cleanup_interactive"
    apply_leftover_cleanup_interactive
  fi
  dbg "step: write_repo_pointer";     write_repo_pointer
  dbg "step: ensure_homebrew";        ensure_homebrew || true
  dbg "step: ensure_formulas";        ensure_formulas
  dbg "step: ensure_immich_venv";     ensure_immich_venv
  dbg "step: ensure_docling_venv";    ensure_docling_venv
  dbg "step: render_wrappers";        render_wrappers
  dbg "step: render_services";        render_services
  dbg "step: render_bin";             render_bin
  dbg "step: render_all_plists";      render_all_plists
  dbg "step: render_motd";            render_motd
  dbg "step: apply_iogpu_wired_limit"; apply_iogpu_wired_limit
  dbg "step: apply_pmset";            apply_pmset
  dbg "step: apply_os_trim";          apply_os_trim
  echo
  verify_and_summary
}

# ===========================================================================
# Status / verify
# ===========================================================================

verify_and_summary() {
  load_config
  printf "\n${C_BOLD}── Live state ────────────────────────────────────${C_RST}\n"

  # Memory
  local wired free_pages page_size free_mb pressure
  wired=$(/usr/sbin/sysctl -n iogpu.wired_limit_mb 2>/dev/null || echo ?)
  page_size=$(/usr/sbin/sysctl -n hw.pagesize 2>/dev/null || echo 16384)
  free_pages=$(/usr/bin/vm_stat 2>/dev/null | awk '/Pages free/{gsub(/\./,"",$3); print $3; exit}')
  free_mb=$(( (free_pages * page_size) / 1024 / 1024 ))
  pressure=$(/usr/bin/memory_pressure 2>/dev/null | awk -F': ' '/System memory pressure/{print $2; exit}')

  printf "Memory: %s MB free  |  wired limit %s MB  |  pressure %s  |  total %s GB\n" \
         "$free_mb" "$wired" "${pressure:-?}" "${TOTAL_RAM_GB:-?}"

  # pmset
  local ar sl
  ar=$(/usr/bin/pmset -g | awk '/autorestart/{print $2}')
  sl=$(/usr/bin/pmset -g | awk '/ sleep /{print $2; exit}')
  printf "pmset:  autorestart=%s  sleep=%s\n" "${ar:-?}" "${sl:-?}"

  echo
  printf "%-36s %-10s %-8s %s\n" LABEL STATE PID NOTES
  printf "%-36s %-10s %-8s %s\n" ------- ----- --- ----
  local active_list=" ${ACTIVE_LABELS[*]:-} "
  for label in "${ALL_LABELS[@]}"; do
    local state pid notes=""
    case "$active_list" in
      *" $label "*)
        if daemon_loaded "$label"; then
          state=$(/bin/launchctl print "system/$label" 2>/dev/null | awk '/^[[:space:]]*state[[:space:]]*=/{print $3; exit}')
          pid=$(daemon_pid "$label")
        else
          state="absent"; pid=""
        fi
        case "$label" in
          com.local.immich.ml|com.local.docling.serve)
            [ -z "$pid" ] || [ "$pid" = 0 ] && notes="on-demand (sleeping)"
            [ -n "$pid" ] && [ "$pid" != 0 ] && notes="on-demand (awake)"
            ;;
          com.local.iogpu.wiredlimit|com.local.weekly.autoupdate)
            notes="scheduled / one-shot"
            ;;
        esac
        ;;
      *)
        state="skipped"; pid=""; notes="disabled in config (menu 2)"
        ;;
    esac
    printf "%-36s %-10s %-8s %s\n" "$label" "${state:-?}" "${pid:-0}" "$notes"
  done

  echo
  # Scheduled
  local next
  next=$(/bin/launchctl print system/com.local.weekly.autoupdate 2>/dev/null \
         | awk '/next run/{print; exit}')
  printf "Scheduled autoupdate: %s\n" "${next:-(not scheduled)}"

  echo
}

# ===========================================================================
# Leftover detection & interactive service selection
# ===========================================================================

# scan_leftovers — print TAB-separated "KIND<TAB>PATH" lines for anything
# on disk that looks like it's from a previous (incompatible) install.
# KINDs: foreign-plist, orphan-libexec, legacy-app. Returns 0 always.
scan_leftovers() {
  local known_plists=" ${ALL_LABELS[*]} "
  local f lbl
  for f in "$PLIST_DIR"/com.local.*.plist; do
    [ -f "$f" ] || continue
    lbl=$(basename "$f" .plist)
    case "$known_plists" in
      *" $lbl "*) : ;;
      *)          printf 'foreign-plist\t%s\n' "$f" ;;
    esac
  done
  # Build "expected libexec basenames" from what the repo actually ships.
  local expected=" "
  for f in "$REPO_DIR"/wrappers/*.sh "$REPO_DIR"/services/*.py "$REPO_DIR"/services/*.sh; do
    [ -f "$f" ] || continue
    expected+="$(basename "$f") "
  done
  for f in "$LIBEXEC_DIR"/start-*.sh \
           "$LIBEXEC_DIR"/*-exporter.py \
           "$LIBEXEC_DIR"/*-proxy.py \
           "$LIBEXEC_DIR"/llm-watchdog.sh; do
    [ -f "$f" ] || continue
    case "$expected" in
      *" $(basename "$f") "*) : ;;
      *)                       printf 'orphan-libexec\t%s\n' "$f" ;;
    esac
  done
  # GUI apps that must not coexist with this headless daemon stack.
  [ -d "/Applications/LM Studio.app" ] && printf 'legacy-app\t%s\n' "/Applications/LM Studio.app"
  [ -d "/Applications/Ollama.app" ]     && printf 'legacy-app\t%s\n' "/Applications/Ollama.app"
  return 0
}

apply_leftover_cleanup_interactive() {
  local output
  output=$(scan_leftovers)
  if [ -z "$output" ]; then
    dbg "no leftovers detected"
    return 0
  fi
  printf "\n${C_BOLD}── Leftovers detected from previous installs ─${C_RST}\n"
  printf '%s\n' "$output" | while IFS=$'\t' read -r kind path; do
    printf "  %-15s %s\n" "[$kind]" "$path"
  done
  echo
  if ! confirm "Clean these up now? (plists are bootout'ed + removed; legacy apps flagged for manual removal)"; then
    warn "leftovers left in place — re-run setup.sh to clean later"
    return 0
  fi
  local kind path lbl
  while IFS=$'\t' read -r kind path; do
    case "$kind" in
      foreign-plist)
        lbl=$(basename "$path" .plist)
        bootout_plist "$lbl"
        /bin/rm -f "$path"
        ok "removed foreign plist: $lbl"
        ;;
      orphan-libexec)
        /bin/rm -f "$path"
        ok "removed orphan file: $path"
        ;;
      legacy-app)
        warn "manual uninstall required: drag '$path' to Trash, or run:"
        warn "  sudo rm -rf \"$path\""
        ;;
    esac
  done <<< "$output"
}

onoff_label() { [ "$1" = 1 ] && printf 'on ' || printf 'off'; }

toggle_install_flag() {
  local key=$1 cur
  eval "cur=\"\${$key:-1}\""
  if [ "$cur" = 1 ]; then
    save_config_key "$key" 0
    eval "$key=0"
    ok "$key → off"
  else
    save_config_key "$key" 1
    eval "$key=1"
    ok "$key → on"
  fi
}

menu_select_services() {
  load_config
  while true; do
    printf "\n${C_BOLD}── Select services to install ─────────────────${C_RST}\n"
    printf "%s\n" "Ollama, the GPU-wired-limit helper, caffeinate, and the weekly"
    printf "%s\n" "autoupdate are always installed. The optional services below"
    printf "%s\n" "can be skipped now and added later — re-running setup.sh never"
    printf "%s\n" "overwrites a healthy installed service."
    echo
    printf "  1) %-18s [%s]   immich-ml on-demand photo AI (:%s)\n" \
      INSTALL_IMMICH    "$(onoff_label "${INSTALL_IMMICH:-1}")"    "${ML_PUBLIC_PORT:-3003}"
    printf "  2) %-18s [%s]   docling-serve on-demand OCR/VLM (:%s)\n" \
      INSTALL_DOCLING   "$(onoff_label "${INSTALL_DOCLING:-1}")"   "${DOCLING_PUBLIC_PORT:-5001}"
    printf "  3) %-18s [%s]   Prometheus exporters (:%s :%s :%s)\n" \
      INSTALL_EXPORTERS "$(onoff_label "${INSTALL_EXPORTERS:-1}")" \
      "${NODE_EXPORTER_PORT:-9100}" "${SILICON_EXPORTER_PORT:-9101}" "${OLLAMA_EXPORTER_PORT:-9102}"
    printf "  4) %-18s [%s]   Memory-pressure safety watchdog\n" \
      INSTALL_WATCHDOG  "$(onoff_label "${INSTALL_WATCHDOG:-1}")"
    echo
    echo "   a) Apply these choices now     q) Back (don't apply)"
    read -r -p "Toggle which? [1-4 / a / q]: " c
    case "$c" in
      1) toggle_install_flag INSTALL_IMMICH    ;;
      2) toggle_install_flag INSTALL_DOCLING   ;;
      3) toggle_install_flag INSTALL_EXPORTERS ;;
      4) toggle_install_flag INSTALL_WATCHDOG  ;;
      a|A) apply_everything; pause_enter; return 0 ;;
      q|Q|"") return 0 ;;
      *) warn "unknown: $c"; sleep 1 ;;
    esac
  done
}

# ===========================================================================
# TUI menus
# ===========================================================================

pause_enter() { [ "${AUTO_ACCEPT:-0}" = 1 ] && return 0; read -r -p "Press Enter to continue…" _; }

menu_settings() {
  while true; do
    load_config
    printf "\n${C_BOLD}── Change settings ────────────────────────────${C_RST}\n"
    local i=1
    for k in "${CONFIG_KEYS[@]}"; do
      local hint; hint=$(config_hint "$k")
      printf "  %2d) %-28s = %-12s %s\n" "$i" "$k" "${!k:-}" "${hint:+($hint)}"
      i=$((i+1))
    done
    echo "   a) Apply changes now  |  r) Reset to defaults  |  q) Back"
    read -r -p "Edit which? [1-$((i-1)) / a / r / q]: " c
    case "$c" in
      q|Q|"") return 0 ;;
      a|A)
        log "applying settings…"
        apply_everything
        pause_enter
        return 0
        ;;
      r|R)
        if confirm "Reset all keys to defaults (file will be rewritten)?"; then
          write_default_config
          ok "config reset to defaults"
        fi
        ;;
      *[!0-9]*|"") continue ;;
      *)
        if [ "$c" -ge 1 ] && [ "$c" -lt "$i" ]; then
          local key="${CONFIG_KEYS[$((c-1))]}"
          local cur="${!key:-}"
          local hint; hint=$(config_hint "$key")
          printf "%s current value: %s\n" "$key" "$cur"
          [ -n "$hint" ] && printf "  hint: %s\n" "$hint"
          read -r -p "  new value (empty = keep): " newv
          if [ -n "$newv" ]; then
            save_config_key "$key" "$newv"
            ok "saved $key=$newv (not applied yet; choose 'a' to apply)"
          fi
        fi
        ;;
    esac
  done
}

menu_service_ctl() {
  load_config
  while true; do
    printf "\n${C_BOLD}── Service control ────────────────────────────${C_RST}\n"
    local i=1
    local -a menu_labels=()
    for label in "${ACTIVE_LABELS[@]}"; do
      local pid state
      pid=$(daemon_pid "$label"); pid=${pid:-0}
      if daemon_loaded "$label"; then
        if [ "$pid" != 0 ]; then state="${C_GRN}running${C_RST}"; else state="${C_DIM}sleeping${C_RST}"; fi
      else state="${C_RED}absent${C_RST}"; fi
      printf "  %2d) %-36s %b  pid=%s\n" "$i" "$label" "$state" "$pid"
      menu_labels+=("$label")
      i=$((i+1))
    done
    echo "   a) Restart all always-on  |  q) Back"
    read -r -p "Pick a number to act on (or a/q): " c
    case "$c" in
      q|Q|"") return 0 ;;
      a|A)
        for l in "${ALWAYS_ON_LABELS[@]}"; do
          daemon_loaded "$l" && /bin/launchctl kickstart -k "system/$l" && ok "kickstarted $l"
        done
        pause_enter
        ;;
      *[!0-9]*|"") continue ;;
      *)
        if [ "$c" -ge 1 ] && [ "$c" -le "${#menu_labels[@]}" ]; then
          local label="${menu_labels[$((c-1))]}"
          echo "  1) kickstart (restart)  2) stop  3) view logs  q) back"
          read -r -p "Action: " a
          case "$a" in
            1) /bin/launchctl kickstart -k "system/$label" && ok "kickstarted $label" ;;
            2) /bin/launchctl stop "$label" && ok "stop signal sent to $label" ;;
            3) local logf
               logf=$(label_log "$label")
               if [ -f "$logf" ]; then /usr/bin/tail -n 40 "$logf"; else warn "log not found: $logf"; fi
               pause_enter
               ;;
          esac
        fi
        ;;
    esac
  done
}

menu_cleanup() {
  while true; do
    printf "\n${C_BOLD}── Clean-up tasks ─────────────────────────────${C_RST}\n"
    echo "  1) Purge logs older than 30 days in $LOG_DIR"
    echo "  2) Uninstall node_exporter (keeps ollama)"
    echo "  q) Back"
    read -r -p "Choice: " c
    case "$c" in
      q|Q|"") return 0 ;;
      1) /usr/bin/find "$LOG_DIR" -type f -name '*.log*' -mtime +30 -print -delete 2>/dev/null; pause_enter ;;
      2) confirm "uninstall node_exporter?" && brew_ uninstall node_exporter >/dev/null 2>&1 || true; pause_enter ;;
    esac
  done
}

menu_logs() {
  printf "\n${C_BOLD}── Logs in %s ──${C_RST}\n" "$LOG_DIR"
  local files=()
  for f in "$LOG_DIR"/*.log; do [ -f "$f" ] && files+=("$f"); done
  if [ "${#files[@]}" = 0 ]; then warn "no logs found"; pause_enter; return 0; fi
  local i=1
  for f in "${files[@]}"; do printf "  %2d) %s\n" "$i" "$f"; i=$((i+1)); done
  echo "   q) Back"
  read -r -p "Tail which? " c
  [ "$c" = q ] || [ "$c" = Q ] || [ -z "$c" ] && return 0
  case "$c" in
    *[!0-9]*) return 0 ;;
  esac
  if [ "$c" -ge 1 ] && [ "$c" -le "${#files[@]}" ]; then
    /usr/bin/tail -n 100 "${files[$((c-1))]}"
    pause_enter
  fi
}

menu_uninstall() {
  echo
  warn "This will REMOVE everything this tool installed (plists, wrappers, logs, config)."
  warn "It will NOT touch Homebrew, Ollama itself, or your models."
  if ! confirm "Proceed with uninstall?"; then return 0; fi
  for label in "${ALL_LABELS[@]}"; do
    bootout_plist "$label"
    /bin/rm -f "$PLIST_DIR/$label.plist"
  done
  /bin/rm -rf "$LIBEXEC_DIR"/start-*.sh "$LIBEXEC_DIR"/ondemand-proxy.py \
              "$LIBEXEC_DIR"/ollama-exporter.py "$LIBEXEC_DIR"/silicon-exporter.py \
              "$LIBEXEC_DIR"/llm-watchdog.sh
  /bin/rm -f "$SBIN_DIR/set-iogpu-wired-limit.sh" "$SBIN_DIR/weekly-autoupdate.sh"
  for b in llm-status llm-restart llm-update llm-service-ctl llm-logs; do
    /bin/rm -f "$BIN_DIR/$b"
  done
  if [ -f "$MOTD_BACKUP" ]; then /bin/cp -f "$MOTD_BACKUP" "$MOTD_FILE"; fi
  /bin/rm -f "$CONF_FILE" "$REPO_POINTER_FILE"
  /bin/rm -rf "$LOG_DIR"
  ok "uninstalled (Homebrew + Ollama untouched)"
  pause_enter
}

print_header() {
  printf "\n${C_BOLD}══════════════════════════════════════════════════════════════════════\n"
  printf "  Mac Studio Headless LLM Server  —  setup.sh v%s\n" "$SCRIPT_VERSION"
  printf "══════════════════════════════════════════════════════════════════════${C_RST}\n"
}

main_menu() {
  need_root "$@"
  # First-run welcome: guide the user through service selection before the
  # normal TUI. Config file was absent at startup → FIRST_RUN=1.
  if [ "${FIRST_RUN:-0}" = 1 ]; then
    clear 2>/dev/null || true
    print_header
    load_config   # writes defaults if absent
    printf "\n${C_BOLD}Welcome — first run detected.${C_RST}\n"
    printf "Default config written to %s\n" "$CONF_FILE"
    printf "Step 1: pick which optional services you want installed.\n"
    printf "        (Everything is on by default. Re-run later to add more.)\n"
    pause_enter
    menu_select_services
    FIRST_RUN=0
  fi
  while true; do
    clear 2>/dev/null || true
    print_header
    verify_and_summary
    echo "Main menu:"
    echo "  1) Install / update everything   (recommended — applies current config)"
    echo "  2) Select services to install…   (toggle immich / docling / exporters / watchdog)"
    echo "  3) Change settings…"
    echo "  4) Service control…"
    echo "  5) Run weekly autoupdate now"
    echo "  6) Scan for leftovers from previous installs"
    echo "  7) Clean-up tasks…"
    echo "  8) View logs…"
    echo "  9) Uninstall everything this tool installed"
    echo "  q) Quit"
    read -r -p "Choice: " choice
    case "$choice" in
      1) apply_everything; pause_enter ;;
      2) menu_select_services ;;
      3) menu_settings ;;
      4) menu_service_ctl ;;
      5) log "running weekly-autoupdate.sh NOW"; /bin/bash "$SBIN_DIR/weekly-autoupdate.sh" || true; pause_enter ;;
      6) apply_leftover_cleanup_interactive; pause_enter ;;
      7) menu_cleanup ;;
      8) menu_logs ;;
      9) menu_uninstall ;;
      q|Q|"") exit 0 ;;
      *) warn "unknown choice: $choice"; sleep 1 ;;
    esac
  done
}

show_help() {
  cat <<USAGE
MacStudio LLM Server — setup.sh v${SCRIPT_VERSION}

  sudo bash setup.sh             Interactive TUI (recommended)
  sudo bash setup.sh --apply     Non-interactive install/update (no prompts)
  sudo bash setup.sh --status    Print live status and exit
  sudo bash setup.sh --help      Show this help

Global modifiers (combine with any mode above):
  -v, --verbose                  Chatty output ([dbg] decision traces)
  -d, --debug                    Shell-level trace (set -x with file:line)

Re-running is always safe — every action inspects current state first.
Config lives at: $CONF_FILE
Logs: $LOG_DIR
USAGE
}

# ===========================================================================
# Argv dispatch
# ===========================================================================

# Pre-parse global modifiers (-v/-d). They can appear in any position; we
# set VERBOSE/DEBUG eagerly so they affect every subsequent step, strip them
# from the dispatched argv, but keep the ORIGINAL argv around so the sudo
# re-exec can pass the flags through (shell variables don't survive re-exec).
# Bash 3.2 + `set -u` errors on "${arr[@]}" when empty, so guard the rebuild.
if [ "$#" -gt 0 ]; then
  _orig_args=("$@")
  for _arg in "$@"; do
    case "$_arg" in
      -v|--verbose) VERBOSE=1 ;;
      -d|--debug)   DEBUG=1; VERBOSE=1 ;;
    esac
  done
  _args=()
  for _arg in "$@"; do
    case "$_arg" in
      -v|--verbose|-d|--debug) ;;
      *) _args+=("$_arg") ;;
    esac
  done
  if [ "${#_args[@]}" -gt 0 ]; then
    set -- "${_args[@]}"
  else
    set --
  fi
  unset _args _arg
else
  _orig_args=()
fi
[ "$DEBUG" = 1 ] && { PS4='+ ${BASH_SOURCE##*/}:${LINENO}: '; set -x; }

# First-run detection: config-file absence at startup triggers the welcome
# flow in main_menu(). The self-elevate re-exec below re-runs the script, so
# this is naturally re-evaluated in the child — no state to pass through.
FIRST_RUN=0
[ -f "$CONF_FILE" ] || FIRST_RUN=1

# Self-elevate before doing real work. Use the stripped argv for the help
# check (so `-d --help` still skips sudo), but pass the ORIGINAL argv to
# the re-exec so global modifiers survive.
case "${1:-}" in
  --help|-h) : ;;   # help is readable; don't require sudo
  *)
    if [ "$(id -u)" -ne 0 ]; then
      if [ "${#_orig_args[@]}" -gt 0 ]; then
        exec sudo -E /bin/bash "$0" "${_orig_args[@]}"
      else
        exec sudo -E /bin/bash "$0"
      fi
    fi
    ;;
esac
unset _orig_args

case "${1:-}" in
  --apply)  APPLY_MODE=1; INTERACTIVE=0; shift; apply_everything "$@" ;;
  --status) INTERACTIVE=0; load_config; verify_and_summary ;;
  --help|-h) show_help ;;
  "") main_menu "$@" ;;
  *) err "unknown flag: $1"; show_help; exit 2 ;;
esac
