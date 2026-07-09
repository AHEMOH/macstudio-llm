#!/usr/bin/env python3
"""On-demand Text-to-Speech backend using macOS's built-in `say`/
AVSpeechSynthesizer, OpenAI-compatible (/v1/audio/speech).

Launched by com.local.voicetts.serve (on-demand, woken by
com.local.voicetts.proxy). Chosen over macos-speech-server's own bundled
`avspeech` TTS engine after a direct A/B: calling `say` here is faster
(~30% lower latency, measured) and avoids a real bug in that project's
sentence-concatenation logic that drops ~0.2s of trailing silence per
sentence boundary. `say` needs no model download and no venv — every
request just shells out fresh, same "no persistent model state" shape as
services/mflux-server.py, except here there's no model to keep warm at all.

Stdlib-only (http.server), like the other always-on daemons in this repo —
there's no MLX/model dependency here to justify a dedicated venv.
"""
import json
import os
import shutil
import subprocess
import tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DEFAULT_VOICE = os.environ.get("VOICE_TTS_DEFAULT_VOICE", "Katya (Enhanced)")
GEN_TIMEOUT_SEC = int(os.environ.get("VOICE_TTS_GEN_TIMEOUT_SEC", "60"))
BACKEND_PORT = int(os.environ.get("VOICETTS_BACKEND_PORT", "15007"))

# afconvert (bundled with macOS) covers wav/aiff with no extra dependency.
# ffmpeg (optional Homebrew formula, see ensure_formulas) is only needed for
# the remaining OpenAI response_format values.
_AFCONVERT_FORMATS = {
    "wav": ["-f", "WAVE", "-d", "LEI16"],
    "aiff": ["-f", "AIFF", "-d", "BEI16"],
}
_MIME = {
    "wav": "audio/wav",
    "aiff": "audio/aiff",
    "mp3": "audio/mpeg",
    "opus": "audio/opus",
    "aac": "audio/aac",
    "flac": "audio/flac",
}


def _synthesize(text: str, voice: str, fmt: str):
    """Returns (status_code, content_type_or_None, bytes_payload)."""
    with tempfile.TemporaryDirectory() as tmpdir:
        aiff_path = os.path.join(tmpdir, "out.aiff")
        try:
            result = subprocess.run(
                ["say", "-v", voice, "-o", aiff_path, text],
                capture_output=True, text=True, timeout=GEN_TIMEOUT_SEC,
            )
        except subprocess.TimeoutExpired:
            return 504, None, {"error": {"message": "speech synthesis timed out"}}

        if result.returncode != 0 or not os.path.exists(aiff_path):
            return 500, None, {
                "error": {
                    "message": f"say failed for voice '{voice}'",
                    "detail": result.stderr[-2000:],
                }
            }

        if fmt == "aiff":
            out_path = aiff_path
        elif fmt in _AFCONVERT_FORMATS:
            out_path = os.path.join(tmpdir, f"out.{fmt}")
            conv = subprocess.run(
                ["afconvert", *_AFCONVERT_FORMATS[fmt], aiff_path, out_path],
                capture_output=True, text=True, timeout=GEN_TIMEOUT_SEC,
            )
            if conv.returncode != 0 or not os.path.exists(out_path):
                return 500, None, {"error": {"message": "afconvert failed", "detail": conv.stderr[-2000:]}}
        else:
            # mp3/opus/aac/flac need ffmpeg — afconvert has no MP3 encoder.
            ffmpeg = shutil.which("ffmpeg")
            if not ffmpeg:
                return 501, None, {
                    "error": {
                        "message": (
                            f"response_format '{fmt}' needs ffmpeg, which is not installed "
                            "on this backend — use 'wav' or 'aiff', or install ffmpeg "
                            "(brew install ffmpeg) and restart com.local.voicetts.serve"
                        )
                    }
                }
            out_path = os.path.join(tmpdir, f"out.{fmt}")
            conv = subprocess.run(
                [ffmpeg, "-y", "-i", aiff_path, out_path],
                capture_output=True, text=True, timeout=GEN_TIMEOUT_SEC,
            )
            if conv.returncode != 0 or not os.path.exists(out_path):
                return 500, None, {"error": {"message": "ffmpeg conversion failed", "detail": conv.stderr[-2000:]}}

        with open(out_path, "rb") as f:
            return 200, _MIME[fmt], f.read()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print(f"[say-tts-server] {self.address_string()} {fmt % args}", flush=True)

    def _send_json(self, status: int, payload: dict):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            ok = shutil.which("say") is not None
            self._send_json(200 if ok else 503, {"status": "ok" if ok else "say(1) not found"})
            return
        self._send_json(404, {"error": {"message": "not found"}})

    def do_POST(self):
        if self.path not in ("/v1/audio/speech", "/audio/speech"):
            self._send_json(404, {"error": {"message": "not found"}})
            return

        length = int(self.headers.get("Content-Length", "0") or "0")
        raw = self.rfile.read(length) if length else b""
        try:
            data = json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            self._send_json(400, {"error": {"message": "invalid JSON body"}})
            return

        text = (data.get("input") or "").strip()
        if not text:
            self._send_json(400, {"error": {"message": "input is required"}})
            return

        voice = data.get("voice") or DEFAULT_VOICE
        fmt = (data.get("response_format") or "wav").lower()
        if fmt not in _MIME:
            self._send_json(400, {"error": {"message": f"unsupported response_format '{fmt}'"}})
            return

        status, content_type, payload = _synthesize(text, voice, fmt)
        if status != 200:
            self._send_json(status, payload)
            return
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", BACKEND_PORT), Handler)
    print(f"[say-tts-server] listening on 127.0.0.1:{BACKEND_PORT} (default voice: {DEFAULT_VOICE})", flush=True)
    server.serve_forever()
