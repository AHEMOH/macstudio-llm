#!/usr/bin/env bash
# Launched by com.local.mlxvlm.main — the UNIFIED multimodal text engine
# (Apple-Silicon mlx-vlm's mlx_vlm.server). Serves exactly ONE model that does
# BOTH text and images on the same 'main' alias, internal-only; LiteLLM fronts it.
#
# Active ONLY when TEXT_ENGINE=mlx-vlm. render_all_plists() then bootouts the
# mlx_lm.server daemon so the two never fight over the internal text port — exactly
# one text daemon runs. Flip TEXT_ENGINE=mlx-lm + `--apply` is a one-step rollback.
#
# Why this engine: it serves gemma-4 (incl. gemma4_unified, the 12B mlx_lm.server
# can't load) and — unlike mlx_lm.server — exposes KV-cache quantization
# (--kv-bits / --kv-quant-scheme) so a big model + large context stays in budget on
# 32 GB, plus native vision. Tradeoff: single-stream (no batched concurrency).
# Thinking is OFF by default here; set MLXVLM_MAIN_ENABLE_THINKING=1 to allow it.
#
# Only ONE big model loads at a time (GLM-OCR is the sole on-demand co-resident).
# Switching the model is an explicit act (llm-models -> set main) that restarts
# this daemon; no hot-swap.
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

MODEL_ID="${ALIAS_MAIN:-gemma4-26b}"
field() { /usr/bin/awk -F'|' -v id="$MODEL_ID" -v n="$1" '!/^#/ && $1==id {print $n; exit}' "$CATALOG" 2>/dev/null; }
REPO=$(field 2)
if [ -z "${REPO:-}" ]; then
  echo "[start-mlxvlm-main] ALIAS_MAIN='$MODEL_ID' not found in $CATALOG — refusing to start" >&2
  echo "[start-mlxvlm-main] run 'llm-models' to download a model and set it as main" >&2
  exit 78   # EX_CONFIG
fi
# Fail fast with a clear message if the model isn't downloaded yet.
HUB="$HF_HOME/hub/models--${REPO//\//--}"
if ! /usr/bin/find "$HUB/snapshots" -name '*.safetensors' 2>/dev/null | /usr/bin/grep -q .; then
  echo "[start-mlxvlm-main] model '$REPO' (id '$MODEL_ID') is NOT downloaded — run: llm-models -> d $MODEL_ID" >&2
  exit 78   # EX_CONFIG
fi

# mlx-vlm KV-cache quantization (the thing mlx_lm.server lacks) + optional context cap.
ARGS=( -m mlx_vlm.server
  --model "$REPO"
  --host 127.0.0.1
  --port "${VLLM_BACKEND_PORT:-18000}" )
[ -n "${MLXVLM_MAIN_KV_BITS:-}" ]     && ARGS+=( --kv-bits "$MLXVLM_MAIN_KV_BITS" )
[ -n "${MLXVLM_MAIN_KV_SCHEME:-}" ]   && ARGS+=( --kv-quant-scheme "$MLXVLM_MAIN_KV_SCHEME" )
[ -n "${MLXVLM_MAIN_MAX_KV_SIZE:-}" ] && ARGS+=( --max-kv-size "$MLXVLM_MAIN_MAX_KV_SIZE" )
[ -n "${MLXLM_MAX_TOKENS:-}" ]        && ARGS+=( --max-tokens "$MLXLM_MAX_TOKENS" )
# Thinking is OFF by default on mlx_vlm.server; only opt in explicitly.
[ "${MLXVLM_MAIN_ENABLE_THINKING:-0}" = 1 ] && ARGS+=( --enable-thinking )

# Speculative decoding (MTP). OFF by default (MLXVLM_DRAFT_MODEL empty). Verified +18% (12B) /
# +8% (26B) on code-gen; E2B/E4B drafters crash on mlx-vlm 0.6.3 so leave empty for those.
# FAIL-SOFT: if the drafter repo isn't downloaded, start the main WITHOUT it rather than block
# the whole main daemon for an optional accelerator.
DRAFT_OK=0
if [ -n "${MLXVLM_DRAFT_MODEL:-}" ]; then
  DHUB="$HF_HOME/hub/models--${MLXVLM_DRAFT_MODEL//\//--}"
  if /usr/bin/find "$DHUB/snapshots" -name '*.safetensors' 2>/dev/null | /usr/bin/grep -q .; then
    ARGS+=( --draft-model "$MLXVLM_DRAFT_MODEL" --draft-kind "${MLXVLM_DRAFT_KIND:-mtp}" )
    [ -n "${MLXVLM_DRAFT_BLOCK_SIZE:-}" ] && ARGS+=( --draft-block-size "$MLXVLM_DRAFT_BLOCK_SIZE" )
    DRAFT_OK=1
  else
    echo "[start-mlxvlm-main] WARN: drafter '$MLXVLM_DRAFT_MODEL' not downloaded — starting WITHOUT MTP (run: llm-models -> d, or hf download)" >&2
  fi
fi

echo "[start-mlxvlm-main] serving UNIFIED main='$MODEL_ID' repo='$REPO' (text+vision) on 127.0.0.1:${VLLM_BACKEND_PORT:-18000}"
echo "[start-mlxvlm-main] kv_bits='${MLXVLM_MAIN_KV_BITS:-default}' kv_scheme='${MLXVLM_MAIN_KV_SCHEME:-default}' max_kv_size='${MLXVLM_MAIN_MAX_KV_SIZE:-default}' max_tokens='${MLXLM_MAX_TOKENS:-default}' thinking='${MLXVLM_MAIN_ENABLE_THINKING:-0}' mtp_drafter='${MLXVLM_DRAFT_MODEL:-off}'($([ "$DRAFT_OK" = 1 ] && echo active || echo off))"

exec "$VENV_DIR/mlxvlm/bin/python" "${ARGS[@]}"
