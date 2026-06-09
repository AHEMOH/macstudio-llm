#!/usr/bin/env bash
# Launched by com.local.mlxlm.serve — the always-on text engine
# (Apple's reference mlx_lm.server). Serves exactly ONE model, internal-only;
# LiteLLM (public :LITELLM_PORT) puts the stable 'main' alias in front.
#
# Tradeoffs of mlx_lm.server:
#   - NO KV quantization (mlx-lm issue #1308) -> 16-bit KV. We cap RAM with
#     --prompt-cache-bytes (MLXLM_PROMPT_CACHE_MB) instead of --kv-bits.
#     (Vision via mlx-vlm DOES have --kv-bits — see start-vision.sh.)
#   - NO Prometheus metrics endpoint.
# Tool calling + reasoning are NOT lost: mlx_lm.server auto-infers a per-model
# tool parser from the chat template (returns OpenAI tool_calls) and splits
# reasoning into its own field. So catalog col 9 (tool_parser) is informational
# here — the server detects it itself.
#
# The active model is whatever catalog id ALIAS_MAIN points at. Switching is an
# explicit act (llm-models -> set main) that restarts this daemon; no hot-swap.
set -eu

CONF=/usr/local/etc/macstudio.conf
[ -r "$CONF" ] && . "$CONF"

CATALOG=/usr/local/etc/macstudio-models/catalog.tsv
VENV_DIR="${VENV_DIR:-/Users/mac/.macstudio-venvs}"

export HOME="${TARGET_HOME:-/Users/mac}"
export USER="${TARGET_USER:-mac}"
export PATH="$VENV_DIR/mlxlm/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export HF_HOME="${HF_CACHE_DIR:-$HOME/.cache/huggingface}"
[ -n "${HF_TOKEN:-}" ] && export HF_TOKEN

# Resolve the active main model (catalog id -> HF repo). Same schema/columns as
# start-vllm.sh; mlx_lm.server only needs the repo (col 2) + sampling (14/15).
MODEL_ID="${ALIAS_MAIN:-granite41-30b}"
field() { /usr/bin/awk -F'|' -v id="$MODEL_ID" -v n="$1" '!/^#/ && $1==id {print $n; exit}' "$CATALOG" 2>/dev/null; }
REPO=$(field 2)
if [ -z "${REPO:-}" ]; then
  echo "[start-mlx-lm] ALIAS_MAIN='$MODEL_ID' not found in $CATALOG — refusing to start" >&2
  echo "[start-mlx-lm] run 'llm-models' to download a model and set it as main" >&2
  exit 78   # EX_CONFIG
fi
ENGINE=$(field 4)  # informational; mlx_lm.server is TEXT-only (vision ignored)
# Fail fast with a clear message if the model isn't downloaded yet — same guard
# as start-vllm.sh, so a missing model never looks like "the server won't start".
HUB="$HF_HOME/hub/models--${REPO//\//--}"
if ! /usr/bin/find "$HUB/snapshots" -name '*.safetensors' 2>/dev/null | /usr/bin/grep -q .; then
  echo "[start-mlx-lm] model '$REPO' (id '$MODEL_ID') is NOT downloaded — run: llm-models -> d $MODEL_ID" >&2
  echo "[start-mlx-lm] refusing to start until the model is present in $HF_HOME" >&2
  exit 78   # EX_CONFIG
fi

MTEMP=$(field 14)  # per-model default temperature (cols 16/17 have no mlx_lm flag)
MTOPP=$(field 15)  # per-model default top_p

# mlx_lm.server has NO --kv-bits (16-bit KV) and NO --max-kv-size context cap.
# Bound the KV/prefix-cache RAM with --prompt-cache-bytes; concurrency stays low
# on a 32 GB box (1 prompt prefill at a time mitigates the cache-isolation issue
# ml-explore/mlx-lm#965). decode-concurrency reuses the vllm batching budget.
PCACHE_MB="${MLXLM_PROMPT_CACHE_MB:-8192}"
PCACHE_BYTES=$(( PCACHE_MB * 1024 * 1024 ))
DCONC="${MLXLM_DECODE_CONCURRENCY:-${VLLM_MAX_NUM_SEQS:-4}}"
PCONC="${MLXLM_PROMPT_CONCURRENCY:-1}"

echo "[start-mlx-lm] serving main='$MODEL_ID' repo='$REPO' engine='${ENGINE:-vllm}' on 127.0.0.1:${VLLM_BACKEND_PORT:-18000}"
echo "[start-mlx-lm] mode=mlx-lm (16-bit KV, no kv-quant, tool-parser=auto) temp='${MTEMP:-default}' top_p='${MTOPP:-default}' prompt_cache_mb=${PCACHE_MB} decode_conc=${DCONC} prompt_conc=${PCONC}"

# Flags verified against `mlx_lm.server --help` (mlx-lm 0.31.3). Tool calling
# needs NO flag — the tokenizer/chat-template drives parser auto-detection.
ARGS=( --model "$REPO"
  --host 127.0.0.1
  --port "${VLLM_BACKEND_PORT:-18000}"
  --decode-concurrency "$DCONC"
  --prompt-concurrency "$PCONC"
  --prompt-cache-bytes "$PCACHE_BYTES" )
[ -n "${MTEMP:-}" ] && ARGS+=( --temp  "$MTEMP" )
[ -n "${MTOPP:-}" ] && ARGS+=( --top-p "$MTOPP" )
[ -n "${MLXLM_MAX_TOKENS:-}" ]         && ARGS+=( --max-tokens "$MLXLM_MAX_TOKENS" )
# e.g. MLXLM_CHAT_TEMPLATE_ARGS='{"enable_thinking":false}' to silence a
# reasoning model's think output where the template supports it.
[ -n "${MLXLM_CHAT_TEMPLATE_ARGS:-}" ] && ARGS+=( --chat-template-args "$MLXLM_CHAT_TEMPLATE_ARGS" )

exec "$VENV_DIR/mlxlm/bin/mlx_lm.server" "${ARGS[@]}"
