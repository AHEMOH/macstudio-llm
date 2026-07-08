#!/usr/bin/env bash
# Launched by com.local.images.serve (on-demand, woken by com.local.images.proxy).
# Serves FLUX image generation (mflux, MLX-native) OpenAI-compatible
# (/v1/images/generations) on an internal port. The model itself is a
# pre-quantized, pre-saved local checkpoint (built once by setup.sh's
# ensure_mflux_model() during --apply) — this wrapper only starts the thin
# Flask front end; each request shells out to mflux-generate fresh (see
# services/mflux-server.py for why the model is not kept resident).
set -eu

CONF=/usr/local/etc/macstudio.conf
[ -r "$CONF" ] && . "$CONF"

VENV_DIR="${VENV_DIR:-/Users/mac/.macstudio-venvs}"
MFLUX_MODEL="${MFLUX_MODEL:-dev}"
MFLUX_QUANTIZE="${MFLUX_QUANTIZE:-8}"
MFLUX_MODEL_DIR="${MFLUX_MODEL_DIR:-/Users/mac/.cache/mflux-models}"
MODEL_PATH="$MFLUX_MODEL_DIR/${MFLUX_MODEL}-q${MFLUX_QUANTIZE}"

export HOME="${TARGET_HOME:-/Users/mac}"
export USER="${TARGET_USER:-mac}"
export PATH="$VENV_DIR/mflux/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
export HF_HOME="${HF_CACHE_DIR:-$HOME/.cache/huggingface}"
[ -n "${HF_TOKEN:-}" ] && export HF_TOKEN

if [ ! -d "$MODEL_PATH" ]; then
  echo "[start-images] quantized model not found at $MODEL_PATH" >&2
  echo "[start-images] run 'sudo bash setup.sh --apply' with INSTALL_IMAGES=1 to build it (one-time, several minutes)" >&2
  exit 78
fi

export MFLUX_MODEL_PATH="$MODEL_PATH"
export MFLUX_MODEL
export MFLUX_STEPS="${MFLUX_STEPS:-}"
export IMAGES_BACKEND_PORT="${IMAGES_BACKEND_PORT:-15005}"

echo "[start-images] serving $MFLUX_MODEL (quantize=$MFLUX_QUANTIZE) from $MODEL_PATH on 127.0.0.1:${IMAGES_BACKEND_PORT}"

exec "$VENV_DIR/mflux/bin/python" /usr/local/libexec/mflux-server.py
