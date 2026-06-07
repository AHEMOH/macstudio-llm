#!/usr/bin/env bash
# Launched by com.local.vllm.mlx — the primary always-on MLX engine
# (vLLM-style: continuous batching + paged KV cache). Serves exactly ONE
# model, internal-only; LiteLLM (public :LITELLM_PORT) puts the stable alias
# in front. All tunables come from /usr/local/etc/macstudio.conf so env
# changes don't require plist re-rendering.
#
# The active model is whatever catalog id ALIAS_MAIN points at — resolved to
# its HuggingFace repo via the TUI-managed catalog. Switching the model is an
# explicit act (llm-models -> set main) that restarts this daemon; there is no
# on-the-fly swap.
set -eu

CONF=/usr/local/etc/macstudio.conf
[ -r "$CONF" ] && . "$CONF"

CATALOG=/usr/local/etc/macstudio-models/catalog.tsv
VENV_DIR="${VENV_DIR:-/Users/mac/.macstudio-venvs}"

export HOME="${TARGET_HOME:-/Users/mac}"
export USER="${TARGET_USER:-mac}"
export PATH="$VENV_DIR/vllm/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export HF_HOME="${HF_CACHE_DIR:-$HOME/.cache/huggingface}"
[ -n "${HF_TOKEN:-}" ] && export HF_TOKEN

# Resolve the active main model (catalog id -> HF repo + per-model tuning).
# Catalog columns (schema v2):
#   1 id 2 hf_repo 3 role 4 engine 5 quant 6 gb 7 gated
#   8 reasoning_parser 9 tool_parser 10 max_kv_size 11 max_num_seqs 12 rating 13 notes
MODEL_ID="${ALIAS_MAIN:-qwen36-35b-a3b}"
field() { /usr/bin/awk -F'|' -v id="$MODEL_ID" -v n="$1" '!/^#/ && $1==id {print $n; exit}' "$CATALOG" 2>/dev/null; }
REPO=$(field 2)
if [ -z "${REPO:-}" ]; then
  echo "[start-vllm] ALIAS_MAIN='$MODEL_ID' not found in $CATALOG — refusing to start" >&2
  echo "[start-vllm] run 'llm-models' to download a model and set it as main" >&2
  exit 78   # EX_CONFIG
fi
RP=$(field 8)      # reasoning_parser   (empty = omit)
TP=$(field 9)      # tool_parser        (empty = omit)
MKV=$(field 10)    # per-model max_kv_size  (empty = global default)
MNS=$(field 11)    # per-model max_num_seqs (empty = global default)

echo "[start-vllm] serving main='$MODEL_ID' repo='$REPO' on 127.0.0.1:${VLLM_BACKEND_PORT:-18000}"
echo "[start-vllm] reasoning_parser='${RP:-none}' tool_parser='${TP:-none}' kv=${MKV:-${VLLM_MAX_MODEL_LEN:-131072}} seqs=${MNS:-${VLLM_MAX_NUM_SEQS:-4}} kv_bits='${VLLM_KV_BITS:-8}'"

# Flags verified against `vllm-mlx serve --help` on macOS 26.5 (mlx build):
#   --use-paged-cache / --enable-prefix-cache  paged KV (no reload on ctx change)
#                                              + shared-prefix cache (paperless win)
#   --max-kv-size        caps KV/context tokens (per-model override else global)
#   --kv-cache-quantization-bits  8 halves KV RAM -> big context affordable
#   --reasoning-parser / --tool-call-parser  model-specific (from the catalog) so
#                        reasoning is split out and tool calls are parsed
#   --served-model-name  pin the name LiteLLM forwards (model: openai/<repo>)
ARGS=( serve "$REPO"
  --host 127.0.0.1
  --port "${VLLM_BACKEND_PORT:-18000}"
  --served-model-name "$REPO"
  --continuous-batching
  --use-paged-cache
  --enable-prefix-cache
  --max-kv-size  "${MKV:-${VLLM_MAX_MODEL_LEN:-131072}}"
  --max-num-seqs "${MNS:-${VLLM_MAX_NUM_SEQS:-4}}"
  --enable-metrics )
[ -n "${RP:-}" ] && ARGS+=( --reasoning-parser "$RP" )
[ -n "${TP:-}" ] && ARGS+=( --enable-auto-tool-choice --tool-call-parser "$TP" )
case "${VLLM_KV_BITS:-8}" in
  4|8) ARGS+=( --kv-cache-quantization --kv-cache-quantization-bits "${VLLM_KV_BITS:-8}" ) ;;
esac

exec "$VENV_DIR/vllm/bin/vllm-mlx" "${ARGS[@]}"
