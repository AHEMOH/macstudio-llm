#!/usr/bin/env bash
# Launched by com.local.omlx.main — the UNIFIED LLM engine (oMLX). Serves the
# chat/vision main model AND, in the SAME resident process, the embed+rerank
# BGE pair — all discoverable via --model-dir (ensure_omlx_model_dir()'s
# mlx-<id> symlink farm). Replaces mlx-vlm (main) AND Infinity (embed/rerank)
# in one clean cutover. Context-window cap is NOT a flag here — it's pre-
# seeded into ~/.omlx/model_settings.json by ensure_omlx_settings() during --apply.
set -eu

CONF=/usr/local/etc/macstudio.conf
[ -r "$CONF" ] && . "$CONF"

CATALOG=/usr/local/etc/macstudio-models/catalog.tsv
VENV_DIR="${VENV_DIR:-/Users/mac/.macstudio-venvs}"

export HOME="${TARGET_HOME:-/Users/mac}"
export USER="${TARGET_USER:-mac}"
export PATH="$VENV_DIR/omlx/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
export HF_HOME="${HF_CACHE_DIR:-$HOME/.cache/huggingface}"
[ -n "${HF_TOKEN:-}" ] && export HF_TOKEN

if [ ! -x "$VENV_DIR/omlx/bin/omlx" ]; then
  echo "[start-omlx-main] omlx venv not built — run: sudo bash setup.sh --apply" >&2
  exit 78   # EX_CONFIG
fi

MODEL_ID="${ALIAS_MAIN:-gemma4-26b-qat}"
field() { /usr/bin/awk -F'|' -v id="$MODEL_ID" -v n="$1" '!/^#/ && $1==id {print $n; exit}' "$CATALOG" 2>/dev/null; }
REPO=$(field 2)
if [ -z "${REPO:-}" ]; then
  echo "[start-omlx-main] ALIAS_MAIN='$MODEL_ID' not found in $CATALOG — refusing to start" >&2
  echo "[start-omlx-main] run 'llm-models' to download a model and set it as main" >&2
  exit 78   # EX_CONFIG
fi
# Fail fast with a clear message if the model isn't downloaded yet.
HUB="$HF_HOME/hub/models--${REPO//\//--}"
if ! /usr/bin/find "$HUB/snapshots" -name '*.safetensors' 2>/dev/null | /usr/bin/grep -q .; then
  echo "[start-omlx-main] model '$REPO' (id '$MODEL_ID') is NOT downloaded — run: llm-models -> d $MODEL_ID" >&2
  exit 78   # EX_CONFIG
fi

OMLX_MODEL_DIR="${OMLX_MODEL_DIR:-$HOME/.cache/omlx-models}"

ARGS=( serve
  --host 127.0.0.1
  --port "${MAIN_BACKEND_PORT:-18000}"
  --model-dir "$OMLX_MODEL_DIR"
  --memory-guard-gb "${OMLX_MEMORY_GUARD_GB:-30}"
  --max-concurrent-requests "${OMLX_MAX_CONCURRENT_REQUESTS:-8}" )
[ -n "${OMLX_SSD_CACHE_DIR:-}" ]      && ARGS+=( --paged-ssd-cache-dir "$OMLX_SSD_CACHE_DIR" )
[ -n "${OMLX_SSD_CACHE_MAX_SIZE:-}" ] && ARGS+=( --paged-ssd-cache-max-size "$OMLX_SSD_CACHE_MAX_SIZE" )
[ -n "${OMLX_HOT_CACHE_MAX_SIZE:-}" ] && ARGS+=( --hot-cache-max-size "$OMLX_HOT_CACHE_MAX_SIZE" )

echo "[start-omlx-main] serving main='$MODEL_ID' repo='$REPO' (+ embed/rerank via $OMLX_MODEL_DIR) on 127.0.0.1:${MAIN_BACKEND_PORT:-18000}"
echo "[start-omlx-main] memory_guard_gb='${OMLX_MEMORY_GUARD_GB:-30}' ssd_cache='${OMLX_SSD_CACHE_DIR:-off}' max_concurrent='${OMLX_MAX_CONCURRENT_REQUESTS:-8}'"

exec "$VENV_DIR/omlx/bin/omlx" "${ARGS[@]}"
