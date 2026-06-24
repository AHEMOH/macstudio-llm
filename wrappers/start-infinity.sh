#!/usr/bin/env bash
# Launched by com.local.infinity.serve (on-demand, woken by com.local.infinity.proxy).
# Serves the BGE embedder (catalog id = ALIAS_EMBED) AND the matching reranker
# (catalog id = ALIAS_RERANK) in ONE Infinity process on an internal port,
# OpenAI-compatible (/embeddings + /rerank), GPU-accelerated via Torch MPS.
# Both models are small (~1-2 GB each) — the only extra (besides GLM-OCR) allowed
# to co-reside with the big main model. On-demand: idles out via the proxy.
set -eu

CONF=/usr/local/etc/macstudio.conf
[ -r "$CONF" ] && . "$CONF"

CATALOG=/usr/local/etc/macstudio-models/catalog.tsv
VENV_DIR="${VENV_DIR:-/Users/mac/.macstudio-venvs}"

export HOME="${TARGET_HOME:-/Users/mac}"
export USER="${TARGET_USER:-mac}"
export PATH="$VENV_DIR/infinity/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
export HF_HOME="${HF_CACHE_DIR:-$HOME/.cache/huggingface}"
[ -n "${HF_TOKEN:-}" ] && export HF_TOKEN
# Torch MPS: fall back to CPU for any op the Metal backend lacks (keeps BGE working).
export PYTORCH_ENABLE_MPS_FALLBACK=1

catalog_repo() {  # id -> hf_repo (col 2), or empty
  /usr/bin/awk -F'|' -v id="$1" '!/^#/ && $1==id {print $2; exit}' "$CATALOG" 2>/dev/null || true
}

EMBED_ID="${ALIAS_EMBED:-}"
RERANK_ID="${ALIAS_RERANK:-}"

# Build the model args (repeated --model-id / --served-model-name pairs). Order
# matters: each served name lines up with the preceding model-id.
ARGS=()
if [ -n "$EMBED_ID" ]; then
  EMBED_REPO=$(catalog_repo "$EMBED_ID")
  if [ -z "${EMBED_REPO:-}" ]; then
    echo "[start-infinity] ALIAS_EMBED='$EMBED_ID' not found in $CATALOG — refusing to start" >&2
    exit 78
  fi
  ARGS+=(--model-id "$EMBED_REPO" --served-model-name "$EMBED_ID")
fi
if [ -n "$RERANK_ID" ]; then
  RERANK_REPO=$(catalog_repo "$RERANK_ID")
  if [ -z "${RERANK_REPO:-}" ]; then
    echo "[start-infinity] ALIAS_RERANK='$RERANK_ID' not found in $CATALOG — refusing to start" >&2
    exit 78
  fi
  ARGS+=(--model-id "$RERANK_REPO" --served-model-name "$RERANK_ID")
fi

if [ "${#ARGS[@]}" -eq 0 ]; then
  echo "[start-infinity] neither ALIAS_EMBED nor ALIAS_RERANK set — nothing to serve, refusing to start" >&2
  exit 78
fi

echo "[start-infinity] serving embed='${EMBED_ID:-none}' rerank='${RERANK_ID:-none}' on 127.0.0.1:${INFINITY_BACKEND_PORT:-15004} (device=${INFINITY_DEVICE:-mps}, batch=${INFINITY_BATCH_SIZE:-16})"

# --no-bettertransformer: BetterTransformer needs `optimum`, which we deliberately
# do NOT install (optimum 2.x dropped the `bettertransformer` submodule and is
# incompatible with this infinity-emb build). It's a CUDA varlen path anyway —
# irrelevant on Torch-MPS — so disable it to use the plain sentence-transformers
# loader.
exec "$VENV_DIR/infinity/bin/infinity_emb" v2 \
  "${ARGS[@]}" \
  --host 127.0.0.1 \
  --port "${INFINITY_BACKEND_PORT:-15004}" \
  --device "${INFINITY_DEVICE:-mps}" \
  --batch-size "${INFINITY_BATCH_SIZE:-16}" \
  --no-bettertransformer
