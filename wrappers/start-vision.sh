#!/usr/bin/env bash
# Launched by com.local.vision.serve (on-demand, woken by com.local.vision.proxy).
# Serves a general vision-language model (catalog id = ALIAS_VISION, engine
# mlxvlm) via mlx-vlm's OpenAI/Anthropic-compatible server on an internal port.
#
# This is the multimodal path: mlx_lm.server (the text 'main') is TEXT-ONLY, so
# images go here instead. mlx-vlm supports gemma4 AND gemma4_unified (the 12B
# that mlx-lm can't load) and — unlike mlx_lm.server — exposes KV-cache
# quantization (--kv-bits / --kv-quant-scheme) and a context cap (--max-kv-size).
#
# On 32 GB only ONE big model fits: this wakes on demand and the proxy stops it
# after idle. Keep ALIAS_VISION modest (gemma-4-12B ~8 GB) so it can co-reside
# with the ~16 GB text main; a larger VLM would need the main swapped out.
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

MODEL_ID="${ALIAS_VISION:-}"
if [ -z "$MODEL_ID" ]; then
  echo "[start-vision] ALIAS_VISION is empty — vision endpoint disabled, refusing to start" >&2
  exit 78   # EX_CONFIG
fi
REPO=$(/usr/bin/awk -F'|' -v id="$MODEL_ID" '!/^#/ && $1==id {print $2; exit}' "$CATALOG" 2>/dev/null || true)
if [ -z "${REPO:-}" ]; then
  echo "[start-vision] ALIAS_VISION='$MODEL_ID' not found in $CATALOG — refusing to start" >&2
  exit 78
fi

# Fail fast (clear message) if the model isn't downloaded yet — same guard as
# the text wrapper, so a missing model never looks like "the server won't start".
HUB="$HF_HOME/hub/models--${REPO//\//--}"
if ! /usr/bin/find "$HUB/snapshots" -name '*.safetensors' 2>/dev/null | /usr/bin/grep -q .; then
  echo "[start-vision] model '$REPO' (id '$MODEL_ID') is NOT downloaded — run: llm-models -> d $MODEL_ID" >&2
  exit 78
fi

# mlx-vlm KV-cache quantization + context cap (NOT available on mlx_lm.server).
ARGS=( -m mlx_vlm.server
  --model "$REPO"
  --host 127.0.0.1
  --port "${VISION_BACKEND_PORT:-15003}" )
[ -n "${VISION_KV_BITS:-}" ]     && ARGS+=( --kv-bits "$VISION_KV_BITS" )
[ -n "${VISION_KV_SCHEME:-}" ]   && ARGS+=( --kv-quant-scheme "$VISION_KV_SCHEME" )
[ -n "${VISION_MAX_KV_SIZE:-}" ] && ARGS+=( --max-kv-size "$VISION_MAX_KV_SIZE" )
[ -n "${MLXLM_MAX_TOKENS:-}" ]   && ARGS+=( --max-tokens "$MLXLM_MAX_TOKENS" )
[ "${VISION_ENABLE_THINKING:-0}" = 1 ] && ARGS+=( --enable-thinking )

echo "[start-vision] serving vision='$MODEL_ID' repo='$REPO' on 127.0.0.1:${VISION_BACKEND_PORT:-15003}"
echo "[start-vision] kv_bits='${VISION_KV_BITS:-default}' kv_scheme='${VISION_KV_SCHEME:-default}' max_kv_size='${VISION_MAX_KV_SIZE:-default}' thinking='${VISION_ENABLE_THINKING:-0}'"

exec "$VENV_DIR/mlxvlm/bin/python" "${ARGS[@]}"
