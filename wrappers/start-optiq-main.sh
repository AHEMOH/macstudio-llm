#!/usr/bin/env bash
# Launched by com.local.optiq.main — the mlx-optiq UNIFIED multimodal text engine
# (`optiq serve`). Serves exactly ONE model that does BOTH text and images on the
# same 'main' alias, internal-only; LiteLLM fronts it. BETA (mlx-optiq).
#
# Active ONLY when TEXT_ENGINE=optiq. render_all_plists() then bootouts the
# mlx_lm.server AND mlx_vlm.server daemons so the engines never fight over the
# internal text port — exactly one text daemon runs. Flip TEXT_ENGINE back +
# --apply is a one-step rollback.
#
# Why this engine: it loads the QAT OptiQ Gemma-4 builds (Mixed-Precision quant;
# the MoE 26B-A4B and gemma4_unified towers that stock mlx_lm.server can't, and
# the OptiQ quant format stock mlx-vlm can't read). It speaks the OpenAI
# /v1/chat/completions API (LiteLLM fronts that), exposes KV-cache quantization,
# turns on image input automatically when the model carries the vision sidecar,
# and supports tool calling. NO audio (mlx-optiq has none). Single-stream.
# Runs from its OWN venv ('optiq', mlx-optiq + mlx-lm from git) so the pinned
# 'mlxlm' venv is never disturbed.
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
export PATH="$VENV_DIR/optiq/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
export HF_HOME="${HF_CACHE_DIR:-$HOME/.cache/huggingface}"
[ -n "${HF_TOKEN:-}" ] && export HF_TOKEN

MODEL_ID="${ALIAS_MAIN:-gemma4-26b-optiq}"
field() { /usr/bin/awk -F'|' -v id="$MODEL_ID" -v n="$1" '!/^#/ && $1==id {print $n; exit}' "$CATALOG" 2>/dev/null; }
REPO=$(field 2)
if [ -z "${REPO:-}" ]; then
  echo "[start-optiq-main] ALIAS_MAIN='$MODEL_ID' not found in $CATALOG — refusing to start" >&2
  echo "[start-optiq-main] run 'llm-models' to download a model and set it as main" >&2
  exit 78   # EX_CONFIG
fi
# Fail fast with a clear message if the model isn't downloaded yet.
HUB="$HF_HOME/hub/models--${REPO//\//--}"
if ! /usr/bin/find "$HUB/snapshots" -name '*.safetensors' 2>/dev/null | /usr/bin/grep -q .; then
  echo "[start-optiq-main] model '$REPO' (id '$MODEL_ID') is NOT downloaded — run: llm-models -> d $MODEL_ID" >&2
  exit 78   # EX_CONFIG
fi
# Resolve the LOCAL snapshot dir (the one holding config.json) and pass THAT to
# --model. optiq's vision/MTP engine does load_config(model_path) and looks for
# config.json *relative to the --model string* — a bare HF repo-id makes it fail
# with "Missing config.json in <repo-id>" the first time an image request hits.
# A local path makes both the text and image paths resolve config.json correctly.
MODEL_PATH=$(/usr/bin/find "$HUB/snapshots" -maxdepth 2 -name config.json -exec dirname {} \; 2>/dev/null | /usr/bin/head -1)
if [ -z "${MODEL_PATH:-}" ]; then
  echo "[start-optiq-main] no config.json under $HUB/snapshots — model dir incomplete; run: llm-models -> d $MODEL_ID" >&2
  exit 78   # EX_CONFIG
fi

# `optiq serve` wraps mlx_lm.server: --model/--host/--port/--max-tokens pass through;
# --kv-bits/--kv-group-size/--drafter are OptiQ-specific. --no-anthropic: LiteLLM
# fronts the OpenAI side, the Anthropic endpoint is unused here. --no-auth: this is
# an internal localhost backend behind LiteLLM (which sends api_key 'dummy'); without
# it optiq rejects any non-`sk-optiq-*` Bearer with 401. LiteLLM is the auth boundary.
ARGS=( serve
  --model "$MODEL_PATH"
  --host 127.0.0.1
  --port "${VLLM_BACKEND_PORT:-18000}"
  --no-anthropic
  --no-auth )
[ -n "${OPTIQ_KV_BITS:-}" ]       && ARGS+=( --kv-bits "$OPTIQ_KV_BITS" )
[ -n "${OPTIQ_KV_GROUP_SIZE:-}" ] && ARGS+=( --kv-group-size "$OPTIQ_KV_GROUP_SIZE" )
[ -n "${OPTIQ_MAX_TOKENS:-}" ]    && ARGS+=( --max-tokens "$OPTIQ_MAX_TOKENS" )
# --prompt-cache-bytes takes BYTES; OPTIQ_PROMPT_CACHE_MB is in MB → enables a large context window.
[ -n "${OPTIQ_PROMPT_CACHE_MB:-}" ] && ARGS+=( --prompt-cache-bytes "$(( OPTIQ_PROMPT_CACHE_MB * 1048576 ))" )
[ -n "${OPTIQ_DRAFTER:-}" ]       && ARGS+=( --drafter "$OPTIQ_DRAFTER" )

echo "[start-optiq-main] serving UNIFIED main='$MODEL_ID' repo='$REPO' (text+image, mlx-optiq BETA) on 127.0.0.1:${VLLM_BACKEND_PORT:-18000}"
echo "[start-optiq-main] kv_bits='${OPTIQ_KV_BITS:-default}' kv_group_size='${OPTIQ_KV_GROUP_SIZE:-default}' max_tokens='${OPTIQ_MAX_TOKENS:-default}' drafter='${OPTIQ_DRAFTER:-off}'"

exec "$VENV_DIR/optiq/bin/optiq" "${ARGS[@]}"
