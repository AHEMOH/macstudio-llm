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

# Resolve the active main model (catalog id -> HF repo).
MODEL_ID="${ALIAS_MAIN:-qwen36-35b-a3b}"
REPO=$(/usr/bin/awk -F'|' -v id="$MODEL_ID" '!/^#/ && $1==id {print $2; exit}' "$CATALOG" 2>/dev/null || true)
if [ -z "${REPO:-}" ]; then
  echo "[start-vllm] ALIAS_MAIN='$MODEL_ID' not found in $CATALOG — refusing to start" >&2
  echo "[start-vllm] run 'llm-models' to download a model and set it as main" >&2
  exit 78   # EX_CONFIG
fi

echo "[start-vllm] serving main='$MODEL_ID' repo='$REPO' on 127.0.0.1:${VLLM_BACKEND_PORT:-18000}"

# Flags verified against `vllm-mlx serve --help` on macOS 26.5 (mlx build):
#   --use-paged-cache    paged KV  -> no reload when a request asks for a
#                        different context length (the core requirement)
#   --enable-prefix-cache  big win for paperless (shared system prompts)
#   --max-kv-size        caps KV/context tokens to keep us inside wired RAM
#   --served-model-name  pin the name LiteLLM forwards (model: openai/<repo>)
exec "$VENV_DIR/vllm/bin/vllm-mlx" serve "$REPO" \
  --host 127.0.0.1 \
  --port "${VLLM_BACKEND_PORT:-18000}" \
  --served-model-name "$REPO" \
  --continuous-batching \
  --use-paged-cache \
  --enable-prefix-cache \
  --max-num-seqs "${VLLM_MAX_NUM_SEQS:-4}" \
  --max-kv-size "${VLLM_MAX_MODEL_LEN:-32768}" \
  --enable-metrics
