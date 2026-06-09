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
| `main` | The big always-on text model     | `/v1/chat/completions`, `/v1/completions`, `/v1/messages` | mlx_lm.server (always on)      |
| `main-precise`  | `main` with low temperature (factual, careful) | same as `main` | **same loaded model**, different default sampling |
| `main-creative` | `main` with high temperature (varied prose) | same as `main` | **same loaded model**, different default sampling |
| `main-metadata` | `main` for extraction: deterministic + `max_tokens` cap, **no thinking** (title/date JSON) | same as `main` | **same loaded model**, different default sampling |
| `main-agents` | `main` tuned for **tool use**: low temp, deterministic, **no thinking** | same as `main` | **same loaded model**, agent sampling |
| `ocr`  | Vision OCR (document → text)     | `/v1/chat/completions` (image input) | GLM-OCR via mlx-vlm (on-demand) |
| `vision` | General multimodal/vision (images → text) | `/v1/chat/completions` (`image_url` input) | mlx-vlm (on-demand; opt-in via `ALIAS_VISION`) |

The `main-*` aliases all point at the **one** loaded text model — they only differ
in DEFAULT sampling (temperature/top_p/penalties/max_tokens), so picking one does
**not** load a second model. `main` itself uses the per-model sampling defaults from
the catalog; clients may override any of these per request. Toggle the presets with
`PRESET_ALIASES` and tune them via the `PRESET_*` keys in
`/usr/local/etc/macstudio.conf` (set via `setup.sh` → settings).

**Thinking/reasoning:** `main`, `main-precise`, `main-creative` reason by default (a
reasoning model thinks; clients can send `enable_thinking:false` to turn it off).
**`main-metadata` and `main-agents` always run without thinking** (suppressed at the
gateway) — so metadata returns clean JSON and agent tool-calls stay tight.

`vision` only exists if `ALIAS_VISION` is set (a `role=vision` model) — via
`setup.sh` → settings or `llm-models` → `v`. With the default `TEXT_ENGINE=mlx-lm`
the text `main` is **text-only**; send images to `ocr` (documents) or `vision`
(general). With **`TEXT_ENGINE=mlx-vlm`** the `main` is itself multimodal — send
`image_url` straight to `main` (and `vision` becomes redundant; set `ALIAS_VISION=""`).

### Authentication

LiteLLM does **not** enforce a master key here — **any** non-empty API key is
accepted (e.g. `sk-local`). Apps usually require *some* value in the key field;
put anything there.

### Endpoint reference

| Method & path                     | Use with model | Purpose                                  |
|-----------------------------------|----------------|------------------------------------------|
| `GET  /v1/models`                 | —              | List available aliases                   |
| `POST /v1/chat/completions`       | `main`, `ocr`, `vision` | Chat (OpenAI). `stream: true`; image input for `ocr`/`vision` |
| `POST /v1/completions`            | `main`         | Legacy text completion                   |
| `POST /v1/messages`               | `main`         | **Anthropic** Messages API               |

### Quick smoke tests

```bash
# list aliases
curl -s http://mac.home.arpa:11434/v1/models -H "Authorization: Bearer sk-local"

# chat
curl -s http://mac.home.arpa:11434/v1/chat/completions \
  -H "Authorization: Bearer sk-local" -H "Content-Type: application/json" \
  -d '{"model":"main","messages":[{"role":"user","content":"Say hi"}]}'

# vision / image Q&A (wakes the on-demand mlx-vlm backend; needs ALIAS_VISION set)
curl -s http://mac.home.arpa:11434/v1/chat/completions \
  -H "Authorization: Bearer sk-local" -H "Content-Type: application/json" \
  -d '{"model":"vision","messages":[{"role":"user","content":[
        {"type":"text","text":"What is in this image?"},
        {"type":"image_url","image_url":{"url":"data:image/png;base64,..."}}]}]}'
```

---

## Open WebUI

**Settings → Connections → OpenAI API**:

- **API Base URL:** `http://mac.home.arpa:11434/v1`
- **API Key:** `sk-local`

The models `main` (plus the `main-precise`/`main-creative`/`main-metadata`/`main-agents`
presets) and `ocr` (and `vision` if enabled) appear in the model picker. For chat use
`main`. `main`/`-precise`/`-creative` may emit reasoning, which Open WebUI renders as a
foldable "thinking" block; `main-metadata` and `main-agents` are thinking-off, so they
return clean output with no thinking block. (Embeddings/STT are not served by this stack.)

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

# vision / image Q&A (needs ALIAS_VISION set; wakes the on-demand mlx-vlm backend)
v = client.chat.completions.create(
    model="vision",
    messages=[{"role": "user", "content": [
        {"type": "text", "text": "Was steht auf diesem Bild?"},
        {"type": "image_url", "image_url": {"url": "data:image/png;base64,..."}},
    ]}],
)
print(v.choices[0].message.content)
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
  switching it (`llm-models`) restarts the text engine (~30–60 s) — there is no silent
  hot-swap. **GLM-OCR (`ocr`) is the only model that co-resides** (small, on-demand).
  Under `TEXT_ENGINE=mlx-vlm` the `main` model handles images itself.
- **On-demand backends** (`ocr`, and the companion services) wake on the first
  request after idle — expect a one-time spin-up delay, then normal latency.
- **Long requests:** the gateway timeout is `LLM_REQUEST_TIMEOUT` (default 1200 s
  = 20 min) with **no retries**, sized for long documents / OCR.
- **Streaming** is supported on chat completions (`"stream": true`).
- **Health check:** `GET /v1/models` returns 200 with the alias list when the
  gateway and backend are up.
