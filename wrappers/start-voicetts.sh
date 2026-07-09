#!/usr/bin/env bash
# Launched by com.local.voicetts.serve (on-demand, woken by
# com.local.voicetts.proxy). Serves Text-to-Speech via macOS's built-in
# `say`/AVSpeechSynthesizer (services/say-tts-server.py) — no venv, no model
# download, nothing to pre-build. See say-tts-server.py's docstring for why
# this was chosen over macos-speech-server's bundled TTS engine.
set -eu

CONF=/usr/local/etc/macstudio.conf
[ -r "$CONF" ] && . "$CONF"

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
export VOICE_TTS_DEFAULT_VOICE="${VOICE_TTS_DEFAULT_VOICE:-Katya (Enhanced)}"
export VOICETTS_BACKEND_PORT="${VOICETTS_BACKEND_PORT:-15007}"

echo "[start-voicetts] serving say(1) TTS on 127.0.0.1:${VOICETTS_BACKEND_PORT} (default voice: ${VOICE_TTS_DEFAULT_VOICE})"

exec /usr/bin/python3 /usr/local/libexec/say-tts-server.py
