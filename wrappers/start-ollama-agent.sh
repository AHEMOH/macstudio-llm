#!/usr/bin/env bash
# Launched by com.local.ollama.agent — a SMALL, fast, co-resident text/agentic
# model served by Ollama's MLX runner (Multi-Token-Prediction on by default for
# gemma-4). It runs ALONGSIDE the big unified `main` (optiq/mlx-vlm) — like the
# on-demand GLM-OCR / Infinity extras, this is a small (~6 GB) always-warm helper,
# exposed through LiteLLM as the `agent` alias.
#
# WHY a separate Ollama daemon (not TEXT_ENGINE=ollama): Ollama's MLX runner is
# faster than optiq serve AND actually runs Gemma-4 MTP (~+25 % on e2b, verified),
# but it does NOT do image input for gemma-4 (0.31.x) — so it can't be the unified
# multimodal `main`. Instead we keep optiq as `main` (text+image) and add this fast
# TEXT model on the side for agentic / tool / quick-chat workloads.
#
# Binds an INTERNAL port (AGENT_BACKEND_PORT, default 18001) — distinct from optiq
# on VLLM_BACKEND_PORT (:18000) and LiteLLM (:11434). Gated on INSTALL_AGENT=1.
# Model stays warm (OLLAMA_KEEP_ALIVE=-1); because all traffic arrives via LiteLLM's
# OpenAI /v1 (which never sends Ollama's `num_ctx`), the model loads ONCE at the
# fixed OLLAMA_CONTEXT_LENGTH and never reloads — no Modelfiles needed.
set -eu

CONF=/usr/local/etc/macstudio.conf
[ -r "$CONF" ] && . "$CONF"

export HOME="${TARGET_HOME:-/Users/mac}"
export USER="${TARGET_USER:-mac}"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# Prefer the version-pinned Ollama distribution (>=0.31.0 needed for the -mlx tags;
# the brew formula lags). ensure_ollama_dist() unpacks it into $VENV_DIR/ollama-dist.
VENV_DIR="${VENV_DIR:-/Users/mac/.macstudio-venvs}"
OLLAMA_BIN=/opt/homebrew/opt/ollama/bin/ollama
if [ -x "$VENV_DIR/ollama-dist/ollama" ]; then
  OLLAMA_BIN="$VENV_DIR/ollama-dist/ollama"
  export OLLAMA_LIBRARY_PATH="$VENV_DIR/ollama-dist"
fi

AGENT_MODEL="${AGENT_MODEL:-gemma4:e2b-mlx}"
AGENT_PORT="${AGENT_BACKEND_PORT:-18001}"

export OLLAMA_HOST="127.0.0.1:${AGENT_PORT}"
export OLLAMA_MODELS="${OLLAMA_MODELS:-$HOME/.ollama/models}"
export OLLAMA_KEEP_ALIVE="-1"                                   # always warm — instant
export OLLAMA_MAX_LOADED_MODELS=1
export OLLAMA_NUM_PARALLEL="${OLLAMA_NUM_PARALLEL:-1}"
export OLLAMA_FLASH_ATTENTION="${OLLAMA_FLASH_ATTENTION:-1}"
export OLLAMA_KV_CACHE_TYPE="${OLLAMA_KV_CACHE_TYPE:-q8_0}"
export OLLAMA_CONTEXT_LENGTH="${AGENT_CONTEXT_LENGTH:-32768}"   # fixed => single load, no reload
export OLLAMA_LOAD_TIMEOUT="${OLLAMA_LOAD_TIMEOUT:-15m}"

echo "[start-ollama-agent] serving agent='$AGENT_MODEL' on 127.0.0.1:${AGENT_PORT} (ctx=${OLLAMA_CONTEXT_LENGTH}, kv=${OLLAMA_KV_CACHE_TYPE}, keep_alive=forever, bin=$OLLAMA_BIN)"

# Warm the model in the background so it's resident and instantly responsive after a
# (re)start. Runs detached; if the model isn't pulled yet the warmup just no-ops and
# `ensure_agent_model` (apply time) pulls it. Never blocks/fails the daemon.
(
  for _ in $(seq 1 30); do
    /usr/bin/curl -fsS -m 3 "http://127.0.0.1:${AGENT_PORT}/api/tags" >/dev/null 2>&1 && break
    sleep 2
  done
  /usr/bin/curl -fsS -m 300 "http://127.0.0.1:${AGENT_PORT}/api/generate" \
    -d "{\"model\":\"${AGENT_MODEL}\",\"prompt\":\"ok\",\"stream\":false,\"options\":{\"num_predict\":1}}" \
    >/dev/null 2>&1 && echo "[start-ollama-agent] warmup done ($AGENT_MODEL resident)" \
    || echo "[start-ollama-agent] warmup skipped ($AGENT_MODEL not pulled yet?)"
) &

exec "$OLLAMA_BIN" serve
