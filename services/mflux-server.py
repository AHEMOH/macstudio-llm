#!/usr/bin/env python3
"""On-demand FLUX image-generation backend (mflux), OpenAI-compatible.

Launched by com.local.images.serve (on-demand, woken by com.local.images.proxy).
Each request shells out to the mflux-generate CLI against a pre-quantized,
pre-saved model directory (built once by setup.sh's ensure_mflux_model()) —
deliberately NOT keeping the model resident across requests: mflux's own
--low-ram memory saver evicts the text encoder after the first generation
(valid for its CLI use case of many seeds/one prompt per process), which
would break every subsequent request with a different prompt in a
persistent server. Shelling out per request re-runs the exact CLI path
already measured safe (see project history), at the cost of a fresh model
load every time — acceptable for an occasional-use tool, not a chat-speed API.
"""
import base64
import os
import random
import subprocess
import tempfile
import threading
import time

from flask import Flask, jsonify, request

app = Flask(__name__)

# Only one generation at a time: each request loads a full FLUX model, so two
# concurrent LAN requests would race to allocate ~full-model RAM and can OOM the
# box that also holds the resident main LLM. A busy backend returns 429 rather
# than queueing (an occasional-use tool, not a chat API).
_gen_lock = threading.Lock()

MODEL_PATH = os.environ["MFLUX_MODEL_PATH"]
MODEL_NAME = os.environ.get("MFLUX_MODEL", "dev")
IS_FLUX2 = MODEL_NAME.startswith("flux2-")
# FLUX.2/Klein ships a separate generate CLI from FLUX.1's mflux-generate;
# mflux-save itself is unified across families (see setup.sh ensure_mflux_model()).
MFLUX_BIN = os.environ.get("MFLUX_BIN") or ("mflux-generate-flux2" if IS_FLUX2 else "mflux-generate")
STEPS = os.environ.get("MFLUX_STEPS") or ("4" if MODEL_NAME == "schnell" or MODEL_NAME.startswith("flux2-klein") else "20")
GEN_TIMEOUT_SEC = int(os.environ.get("MFLUX_GEN_TIMEOUT_SEC", "900"))
BACKEND_PORT = int(os.environ.get("IMAGES_BACKEND_PORT", "15005"))
# Upper bound on requested image dimensions — an unbounded width/height from the
# request JSON is a trivial LAN OOM vector. FLUX wants multiples of 16.
MAX_DIM = int(os.environ.get("MFLUX_MAX_DIM", "1536"))


@app.route("/health")
def health():
    if os.path.isdir(MODEL_PATH):
        return "ok", 200
    return f"model not found at {MODEL_PATH} — run setup.sh --apply with INSTALL_IMAGES=1", 503


@app.route("/v1/images/generations", methods=["POST"])
def generate():
    data = request.get_json(force=True) or {}
    prompt = (data.get("prompt") or "").strip()
    if not prompt:
        return jsonify({"error": {"message": "prompt is required"}}), 400

    size = data.get("size") or "1024x1024"
    try:
        width_s, height_s = size.lower().split("x")
        width, height = int(width_s), int(height_s)
    except (ValueError, AttributeError):
        width = height = 1024

    def _clamp(v):
        v = max(256, min(MAX_DIM, v))
        return v - (v % 16)  # FLUX requires multiples of 16
    width, height = _clamp(width), _clamp(height)

    seed = random.randint(0, 2**31 - 1)

    # Serialize generations — refuse rather than queue/race for model RAM.
    if not _gen_lock.acquire(blocking=False):
        return jsonify({"error": {"message": "image backend busy — one generation at a time"}}), 429
    try:
        return _run_generation(prompt, width, height, seed)
    finally:
        _gen_lock.release()


def _run_generation(prompt, width, height, seed):
    with tempfile.TemporaryDirectory() as tmpdir:
        out_path = os.path.join(tmpdir, "out.png")
        cmd = [
            MFLUX_BIN,
            "--model", MODEL_PATH,
            "--prompt", prompt,
            "--steps", str(STEPS),
            "--seed", str(seed),
            "--height", str(height),
            "--width", str(width),
            "--output", out_path,
        ]
        if not IS_FLUX2:
            # --low-ram is confirmed for mflux-generate (FLUX.1); unconfirmed for
            # mflux-generate-flux2 as of this writing — omit until verified live.
            cmd.append("--low-ram")
        try:
            result = subprocess.run(
                cmd, capture_output=True, text=True, timeout=GEN_TIMEOUT_SEC
            )
        except subprocess.TimeoutExpired:
            return jsonify({"error": {"message": "generation timed out"}}), 504

        if result.returncode != 0 or not os.path.exists(out_path):
            return jsonify({
                "error": {
                    "message": "generation failed",
                    "detail": result.stderr[-2000:],
                }
            }), 500

        with open(out_path, "rb") as f:
            b64 = base64.b64encode(f.read()).decode()

    return jsonify({"created": int(time.time()), "data": [{"b64_json": b64}]})


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=BACKEND_PORT)
