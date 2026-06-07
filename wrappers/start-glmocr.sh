#!/usr/bin/env bash
# Launched by com.local.glmocr.serve (on-demand, woken by com.local.glmocr.proxy).
# Serves the OCR model (catalog id = ALIAS_OCR, engine mlxvlm) via mlx-vlm's
# OpenAI-compatible server on an internal port. GLM-OCR is ~0.9B / ~2 GB, the
# only model allowed to run alongside the big main model.
set -eu

CONF=/usr/local/etc/macstudio.conf
[ -r "$CONF" ] && . "$CONF"

CATALOG=/usr/local/etc/macstudio-models/catalog.tsv
VENV_DIR="${VENV_DIR:-/Users/mac/.macstudio-venvs}"

export HOME="${TARGET_HOME:-/Users/mac}"
export USER="${TARGET_USER:-mac}"
export PATH="$VENV_DIR/mlxvlm/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
export HF_HOME="${HF_CACHE_DIR:-$HOME/.cache/huggingface}"
[ -n "${HF_TOKEN:-}" ] && export HF_TOKEN

MODEL_ID="${ALIAS_OCR:-glm-ocr}"
REPO=$(/usr/bin/awk -F'|' -v id="$MODEL_ID" '!/^#/ && $1==id {print $2; exit}' "$CATALOG" 2>/dev/null || true)
if [ -z "${REPO:-}" ]; then
  echo "[start-glmocr] ALIAS_OCR='$MODEL_ID' not found in $CATALOG — refusing to start" >&2
  exit 78
fi

echo "[start-glmocr] serving ocr='$MODEL_ID' repo='$REPO' on 127.0.0.1:${GLMOCR_BACKEND_PORT:-15002}"

exec "$VENV_DIR/mlxvlm/bin/python" -m mlx_vlm.server \
  --model "$REPO" \
  --host 127.0.0.1 \
  --port "${GLMOCR_BACKEND_PORT:-15002}"
