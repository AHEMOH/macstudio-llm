#!/usr/bin/env bash
# Launched by com.local.paperless.ocr — Apple-Vision searchable-PDF worker for
# paperless-ngx (gateway inbox + tag-triggered retro-fix). Runs as ROOT (see the plist):
# macOS 15+/26 "Local Network Privacy" blocks our non-Apple venv python from LAN access
# when the daemon runs as a user (→ "No route to host" reaching paperless-ngx), while root
# is exempt; Apple Vision (VNRecognizeTextRequest) still works fine as root. We export
# HOME/USER=TARGET_USER below so caches/paths stay under the user's home. Uses its own venv
# (ocrmac/pymupdf/requests) — the stdlib-only daemon rule does NOT apply here, like the MLX
# backends run from venvs.
set -eu

CONF=/usr/local/etc/macstudio.conf
[ -r "$CONF" ] && . "$CONF"

VENV_DIR="${VENV_DIR:-/Users/mac/.macstudio-venvs}"
export HOME="${TARGET_HOME:-/Users/mac}"
export USER="${TARGET_USER:-mac}"
export PATH="$VENV_DIR/paperlessocr/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

PY="$VENV_DIR/paperlessocr/bin/python"
if [ ! -x "$PY" ]; then
  echo "[start-paperless-ocr] venv missing at $PY — run 'sudo bash setup.sh --apply' with INSTALL_PAPERLESS_OCR=1" >&2
  exit 78
fi

export PAPERLESS_OCR_URL="${PAPERLESS_OCR_URL:-}"
export PAPERLESS_OCR_TOKEN="${PAPERLESS_OCR_TOKEN:-}"
export PAPERLESS_OCR_LANGS="${PAPERLESS_OCR_LANGS:-ru-RU,en-US}"
export PAPERLESS_OCR_RECMODE="${PAPERLESS_OCR_RECMODE:-accurate}"
export PAPERLESS_OCR_FONT="${PAPERLESS_OCR_FONT:-/System/Library/Fonts/Supplemental/Arial Unicode.ttf}"
export PAPERLESS_OCR_DPI="${PAPERLESS_OCR_DPI:-300}"
export PAPERLESS_OCR_JPEG_Q="${PAPERLESS_OCR_JPEG_Q:-75}"
export PAPERLESS_OCR_TEXT_MIN_CHARS="${PAPERLESS_OCR_TEXT_MIN_CHARS:-50}"
export PAPERLESS_OCR_SMART_NAME="${PAPERLESS_OCR_SMART_NAME:-1}"
export PAPERLESS_OCR_ARCHIVE_RETENTION_DAYS="${PAPERLESS_OCR_ARCHIVE_RETENTION_DAYS:-30}"
export PAPERLESS_OCR_INBOX="${PAPERLESS_OCR_INBOX:-$HOME/paperless-ocr/inbox}"
export PAPERLESS_OCR_ARCHIVE="${PAPERLESS_OCR_ARCHIVE:-$HOME/paperless-ocr/originals}"
export PAPERLESS_OCR_ERRORS="${PAPERLESS_OCR_ERRORS:-$HOME/paperless-ocr/errors}"
export PAPERLESS_OCR_TRIGGER_TAG="${PAPERLESS_OCR_TRIGGER_TAG:-ocr:apple}"
export PAPERLESS_OCR_TRIGGER_FORCE_TAG="${PAPERLESS_OCR_TRIGGER_FORCE_TAG:-ocr:apple-force}"
export PAPERLESS_OCR_VLM_FORCE_TAG="${PAPERLESS_OCR_VLM_FORCE_TAG:-ocr:vlm-force}"
export PAPERLESS_OCR_DONE_TAG="${PAPERLESS_OCR_DONE_TAG:-ocr:done}"
export PAPERLESS_OCR_SUPERSEDED_TAG="${PAPERLESS_OCR_SUPERSEDED_TAG:-ocr:superseded}"
export PAPERLESS_OCR_DELETE_ORIGINAL="${PAPERLESS_OCR_DELETE_ORIGINAL:-0}"
export PAPERLESS_OCR_POLL_SEC="${PAPERLESS_OCR_POLL_SEC:-60}"
export PAPERLESS_OCR_STABLE_SEC="${PAPERLESS_OCR_STABLE_SEC:-90}"
export PAPERLESS_OCR_DUPLEX_SUBDIR="${PAPERLESS_OCR_DUPLEX_SUBDIR:-duplex}"
export PAPERLESS_OCR_DUPLEX_TIMEOUT_SEC="${PAPERLESS_OCR_DUPLEX_TIMEOUT_SEC:-1800}"
export PAPERLESS_OCR_DUPLEX_REVERSE="${PAPERLESS_OCR_DUPLEX_REVERSE:-1}"
# Scan jobs (jam-tolerant duplex/stapel folders), page-number check, MOTD link.
export PAPERLESS_OCR_DUPLEX_AUTO="${PAPERLESS_OCR_DUPLEX_AUTO:-1}"
export PAPERLESS_OCR_DUPLEX_DROP_BLANK_BACKS="${PAPERLESS_OCR_DUPLEX_DROP_BLANK_BACKS:-1}"
export PAPERLESS_OCR_BLANK_MAX_DARK="${PAPERLESS_OCR_BLANK_MAX_DARK:-0.0003}"
export PAPERLESS_OCR_JOB_QUIET_SEC="${PAPERLESS_OCR_JOB_QUIET_SEC:-180}"
export PAPERLESS_OCR_BATCH_SUBDIR="${PAPERLESS_OCR_BATCH_SUBDIR:-stapel}"
export PAPERLESS_OCR_PAGE_CHECK="${PAPERLESS_OCR_PAGE_CHECK:-1}"
export PAPERLESS_OCR_CHECK_TAG="${PAPERLESS_OCR_CHECK_TAG:-scan:check}"
export PAPERLESS_OCR_ANALYZE_MODEL="${PAPERLESS_OCR_ANALYZE_MODEL:-main-fast}"
export PAPERLESS_OCR_ANALYZE_RECMODE="${PAPERLESS_OCR_ANALYZE_RECMODE:-accurate}"
export PAPERLESS_OCR_ANALYZE_DPI="${PAPERLESS_OCR_ANALYZE_DPI:-150}"
export PAPERLESS_OCR_ANALYZE_LLM="${PAPERLESS_OCR_ANALYZE_LLM:-1}"
export DASHBOARD_PORT="${DASHBOARD_PORT:-8090}"
# VLM fallback route (Gemma-4 via the LiteLLM gateway) for handwriting/math docs.
export PAPERLESS_OCR_VLM_AUTO="${PAPERLESS_OCR_VLM_AUTO:-1}"
export PAPERLESS_OCR_VLM_MODEL="${PAPERLESS_OCR_VLM_MODEL:-main-fast}"
export PAPERLESS_OCR_VLM_URL="${PAPERLESS_OCR_VLM_URL:-http://127.0.0.1:11434/v1/chat/completions}"
export PAPERLESS_OCR_VLM_TAG="${PAPERLESS_OCR_VLM_TAG:-ocr:vlm}"
export PAPERLESS_OCR_VLM_MIN_CHARS="${PAPERLESS_OCR_VLM_MIN_CHARS:-80}"
export PAPERLESS_OCR_VLM_MAX_TOKENS="${PAPERLESS_OCR_VLM_MAX_TOKENS:-4000}"
export PAPERLESS_OCR_VLM_TIMEOUT_SEC="${PAPERLESS_OCR_VLM_TIMEOUT_SEC:-300}"
# Pictures without text (drawings/photos): describe + tag instead of transcribing.
export PAPERLESS_OCR_PICTURE_DETECT="${PAPERLESS_OCR_PICTURE_DETECT:-1}"
export PAPERLESS_OCR_PICTURE_TAG_PREFIX="${PAPERLESS_OCR_PICTURE_TAG_PREFIX:-bild:}"

exec "$PY" /usr/local/libexec/paperless-ocr.py
