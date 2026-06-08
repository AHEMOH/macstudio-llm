# Connecting clients & services

How to point apps at this server, what the endpoints look like, and ready-to-paste
configs for the common clients (Home Assistant, Open WebUI, paperless-gpt, the
OpenAI/Anthropic SDKs, embeddings/RAG). For *what the server is* and *how to
install/operate it*, see [README.md](README.md).

> Replace `mac.home.arpa` with your Mac's hostname or LAN IP if different.
> The gateway listens on **all interfaces**, so any host on your LAN can reach it.

---

## The one address apps use

Everything goes through the **LiteLLM gateway**:

```
http://mac.home.arpa:11434
```

Apps only ever see **stable aliases**, never the underlying model id. The model
behind an alias can be swapped (`llm-models`) without the app noticing.

| Alias  | What it is                       | Endpoint(s)                       | Backed by                     |
|--------|----------------------------------|-----------------------------------|-------------------------------|
| `main` | The big always-on text model     | `/v1/chat/completions`, `/v1/completions`, `/v1/messages` | vllm-mlx (always on)          |
| `main-precise`  | `main` with low temperature (factual, careful) | same as `main` | **same loaded model**, different default sampling |
| `main-creative` | `main` with high temperature (varied prose) | same as `main` | **same loaded model**, different default sampling |
| `main-metadata` | `main` for extraction: deterministic + `max_tokens` cap (title/date, no long text) | same as `main` | **same loaded model**, different default sampling |
| `ocr`  | Vision OCR (document → text)     | `/v1/chat/completions` (image input) | GLM-OCR via mlx-vlm (on-demand) |
| `embed`| Text embeddings (RAG / search)   | `/v1/embeddings`                  | vllm-mlx co-resident model    |
| `stt`  | Speech → text (Whisper)          | `/v1/audio/transcriptions`        | vllm-mlx, request-time loaded |

The `main-*` aliases all point at the **one** loaded text model — they only differ
in DEFAULT sampling (temperature/top_p/penalties/max_tokens), so picking one does
**not** load a second model. `main` itself uses the per-model sampling defaults from
the catalog; clients may override any of these per request. Toggle the presets with
`PRESET_ALIASES` and tune them via the `PRESET_*` keys in
`/usr/local/etc/macstudio.conf` (set via `setup.sh` → settings).

`embed` and `stt` only exist if `VLLM_EMBEDDING_MODEL` / `VLLM_STT_MODEL` are set
in `/usr/local/etc/macstudio.conf` (set via `setup.sh` → settings).

### Authentication

LiteLLM does **not** enforce a master key here — **any** non-empty API key is
accepted (e.g. `sk-local`). Apps usually require *some* value in the key field;
put anything there.

### Endpoint reference

| Method & path                     | Use with model | Purpose                                  |
|-----------------------------------|----------------|------------------------------------------|
| `GET  /v1/models`                 | —              | List available aliases                   |
| `POST /v1/chat/completions`       | `main`, `ocr`  | Chat (OpenAI). Supports `stream: true`   |
| `POST /v1/completions`            | `main`         | Legacy text completion                   |
| `POST /v1/messages`               | `main`         | **Anthropic** Messages API               |
| `POST /v1/embeddings`             | `embed`        | Embedding vectors                        |
| `POST /v1/audio/transcriptions`   | `stt`          | Transcribe an audio file (multipart)     |

### Quick smoke tests

```bash
# list aliases
curl -s http://mac.home.arpa:11434/v1/models -H "Authorization: Bearer sk-local"

# chat
curl -s http://mac.home.arpa:11434/v1/chat/completions \
  -H "Authorization: Bearer sk-local" -H "Content-Type: application/json" \
  -d '{"model":"main","messages":[{"role":"user","content":"Say hi"}]}'

# embeddings (returns a 768-dim vector with the default embed model)
curl -s http://mac.home.arpa:11434/v1/embeddings \
  -H "Authorization: Bearer sk-local" -H "Content-Type: application/json" \
  -d '{"model":"embed","input":"hello world"}'

# speech-to-text (German or Russian, etc.)
curl -s http://mac.home.arpa:11434/v1/audio/transcriptions \
  -H "Authorization: Bearer sk-local" \
  -F "file=@/path/to/audio.wav" -F "model=stt" -F "language=de"
```

---

## Home Assistant — Speech-to-Text (Whisper on the Mac)

Offload HA's speech recognition to the Mac (Metal-accelerated Whisper,
multilingual — German, Russian, …). Keep TTS on HA's own Piper.

1. **HACS → Integrations** → install an **OpenAI-compatible Speech-to-Text**
   integration that allows a **custom base URL** (search "OpenAI Whisper STT").
2. Configure it with:
   - **Base URL / endpoint:** `http://mac.home.arpa:11434/v1`
   - **API key:** anything, e.g. `sk-local`
   - **Model:** `stt`
   - **Language:** `ru` (or `de`)
3. **Settings → Voice assistants →** your pipeline → set **Speech-to-text** to the
   new engine. Leave **Text-to-speech** on Piper.

Notes:
- The first request after a `vllm-mlx` restart loads the Whisper model (~5 s);
  afterwards it stays resident and responses take ~1 s.
- Endpoint used under the hood: `POST /v1/audio/transcriptions` with `model=stt`.

---

## Open WebUI

**Settings → Connections → OpenAI API**:

- **API Base URL:** `http://mac.home.arpa:11434/v1`
- **API Key:** `sk-local`

The models `main` (plus the `main-precise`/`main-creative`/`main-metadata` presets),
`ocr`, `embed` appear in the model picker. For chat use `main`. If the active main
model emits reasoning (e.g. Qwen3), Open WebUI renders it as a foldable "thinking"
block automatically.

For **RAG / Documents** in Open WebUI: **Settings → Documents → Embedding model
engine = OpenAI**, same base URL/key, embedding model **`embed`**.

---

## paperless-gpt (and paperless-ngx AI)

Point the OpenAI provider at the gateway:

```yaml
environment:
  LLM_PROVIDER: openai
  LLM_MODEL: main
  OPENAI_API_KEY: sk-local
  OPENAI_BASE_URL: http://mac.home.arpa:11434/v1
  # OCR via the on-demand vision model:
  OCR_PROVIDER: llm
  VISION_LLM_PROVIDER: openai
  VISION_LLM_MODEL: ocr
```

First OCR call wakes GLM-OCR (~10–20 s) and then it serves; it sleeps again after
the idle timeout, freeing RAM for the main model.

---

## OpenAI SDK (Python / JS / anything OpenAI-compatible)

```python
from openai import OpenAI
client = OpenAI(base_url="http://mac.home.arpa:11434/v1", api_key="sk-local")

# chat
r = client.chat.completions.create(
    model="main",
    messages=[{"role": "user", "content": "Erklär mir Hausratversicherung in einem Satz."}],
)
print(r.choices[0].message.content)

# embeddings
e = client.embeddings.create(model="embed", input=["doc one", "doc two"])
print(len(e.data[0].embedding))   # 768 with the default embed model

# speech-to-text
with open("audio.wav", "rb") as f:
    t = client.audio.transcriptions.create(model="stt", file=f, language="de")
print(t.text)
```

---

## Anthropic SDK (`/v1/messages`)

The gateway also speaks the Anthropic Messages API, so tools built for Claude
(e.g. agent frameworks) can target the local `main` model:

```python
from anthropic import Anthropic
client = Anthropic(base_url="http://mac.home.arpa:11434", api_key="sk-local")
msg = client.messages.create(
    model="main",
    max_tokens=512,
    messages=[{"role": "user", "content": "Hallo!"}],
)
print(msg.content[0].text)
```

---

## Things to know

- **One text model at a time.** `main` is whatever model is currently loaded;
  switching it (`llm-models`) restarts `vllm-mlx` (~30–60 s) — there is no silent
  hot-swap. `ocr`, `embed`, and `stt` are the only things that co-reside.
- **On-demand backends** (`ocr`, and the companion services) wake on the first
  request after idle — expect a one-time spin-up delay, then normal latency.
- **Long requests:** the gateway timeout is `LLM_REQUEST_TIMEOUT` (default 1200 s
  = 20 min) with **no retries**, sized for long documents / OCR.
- **Streaming** is supported on chat completions (`"stream": true`).
- **Health check:** `GET /v1/models` returns 200 with the alias list when the
  gateway and backend are up.
