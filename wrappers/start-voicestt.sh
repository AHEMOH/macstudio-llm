#!/usr/bin/env bash
# Launched by com.local.voicestt.serve (on-demand, woken by
# com.local.voicestt.proxy). Serves Speech-to-Text via FluidAudio's
# macos-speech-server (Parakeet, Apple Neural Engine) — an externally
# cloned+built Swift project, same pattern as immich-ml/docling-serve
# (VOICE_PROJECT_DIR, built once by setup.sh's ensure_voice_project()).
# Measured 2026-07: ~zero GPU contention with the resident main LLM (ANE is
# separate silicon from the GPU MLX uses) — see CLAUDE.md's "Voice" bullet.
#
# TTS is deliberately NOT served from this backend (see
# wrappers/start-voicetts.sh + services/say-tts-server.py) even though
# macos-speech-server bundles its own AVSpeechSynthesizer-based TTS engine —
# calling `say` directly was measured faster and avoids a sentence-boundary
# silence-dropping bug in that project's TTS code path.
set -eu

CONF=/usr/local/etc/macstudio.conf
[ -r "$CONF" ] && . "$CONF"

VOICE_PROJECT_DIR="${VOICE_PROJECT_DIR:-/Users/mac/projects/macos-speech-server}"
BIN="$VOICE_PROJECT_DIR/.build/release/speech-server"

export HOME="${TARGET_HOME:-/Users/mac}"
export USER="${TARGET_USER:-mac}"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
export VOICESTT_BACKEND_PORT="${VOICESTT_BACKEND_PORT:-15006}"

if [ ! -x "$BIN" ]; then
  echo "[start-voicestt] speech-server binary not found at $BIN" >&2
  echo "[start-voicestt] run 'sudo bash setup.sh --apply' with INSTALL_VOICE=1 to clone+build it (one-time, several minutes)" >&2
  exit 78
fi

echo "[start-voicestt] serving Parakeet STT on 127.0.0.1:${VOICESTT_BACKEND_PORT} from $VOICE_PROJECT_DIR"

cd "$VOICE_PROJECT_DIR"
exec "$BIN" serve --port "$VOICESTT_BACKEND_PORT"
