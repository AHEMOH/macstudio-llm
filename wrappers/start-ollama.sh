#!/usr/bin/env bash
# Launched by com.local.ollama.headless — primary LLM engine.
# All tunables come from /usr/local/etc/macstudio.conf so env changes
# do not require plist/wrapper re-rendering.
set -eu

CONF=/usr/local/etc/macstudio.conf
[ -r "$CONF" ] && . "$CONF"

export HOME="${TARGET_HOME:-/Users/mac}"
export USER="${TARGET_USER:-mac}"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# Prefer the version-pinned Ollama distribution (ensure_ollama_dist unpacks the
# GitHub tgz into $VENV_DIR/ollama-dist; the brew formula lags behind the version
# the -mlx model tags require). Fall back to the brew binary if the dist is absent.
VENV_DIR="${VENV_DIR:-/Users/mac/.macstudio-venvs}"
OLLAMA_BIN=/opt/homebrew/opt/ollama/bin/ollama
if [ -x "$VENV_DIR/ollama-dist/ollama" ]; then
  OLLAMA_BIN="$VENV_DIR/ollama-dist/ollama"
  export OLLAMA_LIBRARY_PATH="$VENV_DIR/ollama-dist"
fi

export OLLAMA_HOST="0.0.0.0:${OLLAMA_PORT:-11434}"
export OLLAMA_MODELS="${OLLAMA_MODELS:-$HOME/.ollama/models}"
export OLLAMA_MAX_LOADED_MODELS="${OLLAMA_MAX_LOADED_MODELS:-1}"
export OLLAMA_NUM_PARALLEL="${OLLAMA_NUM_PARALLEL:-1}"
export OLLAMA_FLASH_ATTENTION="${OLLAMA_FLASH_ATTENTION:-1}"
export OLLAMA_KV_CACHE_TYPE="${OLLAMA_KV_CACHE_TYPE:-q8_0}"
export OLLAMA_KEEP_ALIVE="${OLLAMA_KEEP_ALIVE:--1}"
export OLLAMA_LOAD_TIMEOUT="${OLLAMA_LOAD_TIMEOUT:-15m}"

exec "$OLLAMA_BIN" serve
