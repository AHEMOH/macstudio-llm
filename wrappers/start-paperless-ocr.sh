#!/usr/bin/env bash
# Launched by com.local.paperless.ocr — Apple-Vision searchable-PDF worker for
# paperless-ngx (gateway inbox + tag-triggered retro-fix). Runs as TARGET_USER
# because Apple Vision (VNRecognizeTextRequest) needs a user context. Uses its own
# venv (ocrmac/pymupdf/requests) — the stdlib-only daemon rule does NOT apply here,
# exactly like the MLX backends run from venvs.
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
export PAPERLESS_OCR_DPI="${PAPERLESS_OCR_DPI:-200}"
export PAPERLESS_OCR_JPEG_Q="${PAPERLESS_OCR_JPEG_Q:-75}"
export PAPERLESS_OCR_INBOX="${PAPERLESS_OCR_INBOX:-$HOME/paperless-ocr/inbox}"
export PAPERLESS_OCR_ARCHIVE="${PAPERLESS_OCR_ARCHIVE:-$HOME/paperless-ocr/originals}"
export PAPERLESS_OCR_ERRORS="${PAPERLESS_OCR_ERRORS:-$HOME/paperless-ocr/errors}"
export PAPERLESS_OCR_TRIGGER_TAG="${PAPERLESS_OCR_TRIGGER_TAG:-ocr:apple}"
export PAPERLESS_OCR_DONE_TAG="${PAPERLESS_OCR_DONE_TAG:-ocr:done}"
export PAPERLESS_OCR_SUPERSEDED_TAG="${PAPERLESS_OCR_SUPERSEDED_TAG:-ocr:superseded}"
export PAPERLESS_OCR_DELETE_ORIGINAL="${PAPERLESS_OCR_DELETE_ORIGINAL:-0}"
export PAPERLESS_OCR_POLL_SEC="${PAPERLESS_OCR_POLL_SEC:-60}"

exec "$PY" /usr/local/libexec/paperless-ocr.py
