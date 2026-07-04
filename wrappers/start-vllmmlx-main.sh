#!/usr/bin/env bash
# Launched by com.local.vllmmlx.main — the vllm-mlx UNIFIED multimodal text engine
# (waybarrios `vllm-mlx serve`). Serves exactly ONE model that does BOTH text and
# images on the same 'main' alias, internal-only; LiteLLM fronts it.
#
# Active ONLY when TEXT_ENGINE=vllm-mlx. render_all_plists() then bootouts the
# mlx_lm.server / mlx_vlm.server / optiq daemons so the engines never fight over the
# internal text port — exactly one text daemon runs. Flip TEXT_ENGINE back +
# --apply is a one-step rollback.
#
# Why this engine: OpenAI /v1 (+ Anthropic /v1/messages) with CONTINUOUS BATCHING
# (multi-user throughput the single-stream engines lack) + KV-cache quant + paged
# KV. It pulls mlx-lm + mlx-vlm as core deps, so its Gemma-4 IMAGE path rides on
# mlx-vlm's SigLIP2 loader (auto-detected for models whose id contains "gemma-4").
# It loads STOCK / QAT gemma-4 builds (NOT the OptiQ mixed-precision format — those
# need TEXT_ENGINE=optiq). Runs from its OWN venv ('vllmmlx').
#
# CAVEAT: vllm-mlx's documented Gemma-4 vision is the e2b entry; 12B/26B image
# support must be verified on this Mac. If it drops images, flip TEXT_ENGINE=mlx-vlm
# (the same QAT rows run there, vision verified) + --apply.
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
export PATH="$VENV_DIR/vllmmlx/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
export HF_HOME="${HF_CACHE_DIR:-$HOME/.cache/huggingface}"
[ -n "${HF_TOKEN:-}" ] && export HF_TOKEN

MODEL_ID="${ALIAS_MAIN:-gemma4-12b-qat}"
field() { /usr/bin/awk -F'|' -v id="$MODEL_ID" -v n="$1" '!/^#/ && $1==id {print $n; exit}' "$CATALOG" 2>/dev/null; }
REPO=$(field 2)
if [ -z "${REPO:-}" ]; then
  echo "[start-vllmmlx-main] ALIAS_MAIN='$MODEL_ID' not found in $CATALOG — refusing to start" >&2
  echo "[start-vllmmlx-main] run 'llm-models' to download a model and set it as main" >&2
  exit 78   # EX_CONFIG
fi
# Fail fast with a clear message if the model isn't downloaded yet.
HUB="$HF_HOME/hub/models--${REPO//\//--}"
if ! /usr/bin/find "$HUB/snapshots" -name '*.safetensors' 2>/dev/null | /usr/bin/grep -q .; then
  echo "[start-vllmmlx-main] model '$REPO' (id '$MODEL_ID') is NOT downloaded — run: llm-models -> d $MODEL_ID" >&2
  exit 78   # EX_CONFIG
fi

# vllm-mlx takes the bare HF repo-id (it resolves the local snapshot itself, like
# mlx_vlm.server). It binds 127.0.0.1 by default and needs NO api-key (default: no
# auth) — LiteLLM is the auth boundary. Sampling (temp/top-p/top_k) is applied at the
# LiteLLM proxy per request, NOT here.
ARGS=( serve "$REPO"
  --host 127.0.0.1
  --port "${VLLM_BACKEND_PORT:-18000}" )
[ "${VLLMMLX_CONTINUOUS_BATCHING:-1}" = 1 ] && ARGS+=( --continuous-batching )
# vllm-mlx has NO --kv-bits (verified via `vllm-mlx serve --help`, v0.4.0). KV memory
# efficiency is --use-paged-cache; --max-kv-size is the real context cap (memory-critical
# on 32 GB). --mllm force-loads the model as multimodal (guarantees the Gemma-4 vision path
# even if name auto-detection misses). --reasoning-parser gemma4 splits thinking into the
# reasoning_content field (matches the model; helps clients hide thinking).
[ "${VLLMMLX_PAGED_CACHE:-1}" = 1 ]  && ARGS+=( --use-paged-cache )
[ "${VLLMMLX_FORCE_MLLM:-1}" = 1 ]   && ARGS+=( --mllm )
[ -n "${VLLMMLX_REASONING_PARSER:-}" ] && ARGS+=( --reasoning-parser "$VLLMMLX_REASONING_PARSER" )
[ -n "${VLLMMLX_MAX_TOKENS:-}" ]     && ARGS+=( --max-tokens "$VLLMMLX_MAX_TOKENS" )
[ -n "${VLLMMLX_MAX_KV_SIZE:-}" ]    && ARGS+=( --max-kv-size "$VLLMMLX_MAX_KV_SIZE" )

echo "[start-vllmmlx-main] serving UNIFIED main='$MODEL_ID' repo='$REPO' (text+image, vllm-mlx) on 127.0.0.1:${VLLM_BACKEND_PORT:-18000}"
echo "[start-vllmmlx-main] continuous_batching='${VLLMMLX_CONTINUOUS_BATCHING:-1}' paged_cache='${VLLMMLX_PAGED_CACHE:-1}' mllm='${VLLMMLX_FORCE_MLLM:-1}' reasoning_parser='${VLLMMLX_REASONING_PARSER:-off}' max_tokens='${VLLMMLX_MAX_TOKENS:-default}' max_kv_size='${VLLMMLX_MAX_KV_SIZE:-default}'"

exec "$VENV_DIR/vllmmlx/bin/vllm-mlx" "${ARGS[@]}"
