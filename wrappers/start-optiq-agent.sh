#!/usr/bin/env bash
# Launched by com.local.optiq.agent — the small, fast, CO-RESIDENT 'agent' model.
# A SECOND `optiq serve` instance (same optiq venv as the main) serving a small
# OptiQ Gemma-4 (default gemma4-e2b-optiq) ALONGSIDE the big unified main. It is
# NOT the main and NOT a TEXT_ENGINE — a self-contained extra like ocr/embed,
# driven purely by INSTALL_AGENT + AGENT_* config (AGENT_MODEL is a HF CATALOG id,
# not an Ollama tag). Exposed as LiteLLM alias 'agent'.
#
# Why optiq (not Ollama): optiq speaks the OpenAI /v1 API, so 'agent' does
# text + tools + IMAGES (vision) unified — Ollama's MLX runner drops Gemma-4
# vision (verified). And OptiQ KV-quant lets e2b hold a huge context (128K) at a
# few hundred MB of KV (1 KV head), swap-free co-resident with the 26B main
# (verified: peak ~13.6 GB, no swap). thinking-off by default at the proxy
# (verified: e2b stays clean thinking-off, unlike the 12B which loops).
#
# Gated on INSTALL_MLX=1 && INSTALL_AGENT=1. Its own internal port
# (AGENT_BACKEND_PORT, default 18002); LiteLLM fronts it. Single-stream.
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

MODEL_ID="${AGENT_MODEL:-gemma4-e2b-optiq}"
field() { /usr/bin/awk -F'|' -v id="$MODEL_ID" -v n="$1" '!/^#/ && $1==id {print $n; exit}' "$CATALOG" 2>/dev/null; }
REPO=$(field 2)
if [ -z "${REPO:-}" ]; then
  echo "[start-optiq-agent] AGENT_MODEL='$MODEL_ID' not found in $CATALOG — refusing to start" >&2
  echo "[start-optiq-agent] run 'llm-models' to download it (or set AGENT_MODEL to a downloaded OptiQ catalog id)" >&2
  exit 78   # EX_CONFIG
fi
HUB="$HF_HOME/hub/models--${REPO//\//--}"
if ! /usr/bin/find "$HUB/snapshots" -name '*.safetensors' 2>/dev/null | /usr/bin/grep -q .; then
  echo "[start-optiq-agent] agent model '$REPO' (id '$MODEL_ID') is NOT downloaded — run: llm-models -> d $MODEL_ID" >&2
  exit 78   # EX_CONFIG
fi
# Resolve the LOCAL snapshot dir holding config.json (so optiq's vision path finds it).
MODEL_PATH=$(/usr/bin/find "$HUB/snapshots" -maxdepth 2 -name config.json -exec dirname {} \; 2>/dev/null | /usr/bin/head -1)
if [ -z "${MODEL_PATH:-}" ]; then
  echo "[start-optiq-agent] no config.json under $HUB/snapshots — model dir incomplete; run: llm-models -> d $MODEL_ID" >&2
  exit 78   # EX_CONFIG
fi

# `optiq serve` wraps mlx_lm.server. --max-kv-size caps the (rotating) context so a
# huge prompt can't OOM the box; e2b's max_position is 131072 (128K). --kv-bits keeps
# the KV tiny. --no-auth: internal localhost backend behind LiteLLM (the auth boundary).
ARGS=( serve
  --model "$MODEL_PATH"
  --host 127.0.0.1
  --port "${AGENT_BACKEND_PORT:-18002}"
  --no-anthropic
  --no-auth )
[ -n "${AGENT_KV_BITS:-}" ]     && ARGS+=( --kv-bits "$AGENT_KV_BITS" )
[ -n "${AGENT_MAX_KV_SIZE:-}" ] && ARGS+=( --max-kv-size "$AGENT_MAX_KV_SIZE" )
[ -n "${AGENT_MAX_TOKENS:-}" ]  && ARGS+=( --max-tokens "$AGENT_MAX_TOKENS" )

echo "[start-optiq-agent] serving co-resident agent='$MODEL_ID' repo='$REPO' (text+image, optiq) on 127.0.0.1:${AGENT_BACKEND_PORT:-18002}"
echo "[start-optiq-agent] kv_bits='${AGENT_KV_BITS:-default}' max_kv_size='${AGENT_MAX_KV_SIZE:-model default}' max_tokens='${AGENT_MAX_TOKENS:-default}'"

exec "$VENV_DIR/optiq/bin/optiq" "${ARGS[@]}"
