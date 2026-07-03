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
| `main` | The big always-on model (chat **+ images**), reasons by default | `/v1/chat/completions`, `/v1/completions`, `/v1/messages` | unified optiq main (always on; for very long docs use `agent`) |
| `main-fast` | Exactly `main` but **thinking OFF** — fast, non-reasoning chat / tool use / web / cron / email | same as `main` | **same loaded model**, thinking-off |
| `agent` | Fast **co-resident** helper: text + tools + **images**, **128K context**, thinking-off — the long-context / fast path (send long docs here; the big main OOMs above ~110K) | `/v1/chat/completions`, `/v1/messages` | OptiQ Gemma-4 e2b, a 2nd `optiq serve` (only if `INSTALL_AGENT=1`) |
| `ocr`  | Dedicated OCR (document → text), best quality | `/v1/chat/completions` (image input) | GLM-OCR via mlx-vlm (on-demand, only if `ALIAS_OCR` is set) |
| `embed` | Dense text **embeddings** for RAG (1024-dim, multilingual) | `/v1/embeddings` | BAAI/bge-m3 via Infinity (on-demand) |
| `rerank` | Cross-encoder **reranker** (scores docs against a query) | `/v1/rerank`, `/rerank` | BAAI/bge-reranker-v2-m3 via Infinity (on-demand) |

The gateway exposes `main`, `main-fast`, `embed`, `rerank` by default — plus `ocr` when
`ALIAS_OCR` is set (**empty/off by default**; set it via `llm-models` or
`--set-model ocr <id>` to re-enable) and `agent` when
`INSTALL_AGENT=1` (**off by default**). `main` and `main-fast` point at the **one** big loaded model (they
differ only in DEFAULT thinking, so picking one does **not** load a second model);
`agent` is a **separate** small co-resident model. `main`/`main-fast`/`agent` share
Gemma's reference sampling (**temperature 1.0 / top_p 0.95 / top_k 64**); `main`/`main-fast`
temp+top_p come from the catalog, `top_k` from `GEMMA_TOP_K` (via `extra_body`, since
top_k is not a native OpenAI param). Clients may override any of these per request.
Toggle `main-fast` with `PRESET_ALIASES`.

**Thinking/reasoning:** `main` reasons by default (a reasoning model thinks; clients
can send `enable_thinking:false` to turn it off). **`main-fast` and `agent`
always run without thinking** (suppressed at the gateway) — so `main-fast` is the
fast/clean chat & tool path and metadata returns tidy JSON.

**Images:** the unified mlx-vlm `main` is multimodal — send `image_url` straight to
`main` (or `main-fast`). There is **no separate `vision` alias** (`ALIAS_VISION=""`);
the dedicated `ocr` alias (GLM-OCR) is for best-quality document transcription, when
enabled (`ALIAS_OCR` set — off by default).

### Authentication

LiteLLM does **not** enforce a master key here — **any** non-empty API key is
accepted (e.g. `sk-local`). Apps usually require *some* value in the key field;
put anything there.

### Endpoint reference

| Method & path                     | Use with model | Purpose                                  |
|-----------------------------------|----------------|------------------------------------------|
| `GET  /v1/models`                 | —              | List available aliases                   |
| `POST /v1/chat/completions`       | `main`, `main-fast`, `ocr` | Chat (OpenAI). `stream: true`; `image_url` input for `main`/`main-fast`/`ocr` |
| `POST /v1/completions`            | `main`         | Legacy text completion                   |
| `POST /v1/messages`               | `main`         | **Anthropic** Messages API               |
| `POST /v1/embeddings`             | `embed`        | Dense embeddings (OpenAI embeddings API) |
| `POST /v1/rerank` (or `/rerank`)  | `rerank`       | Rerank documents against a query         |

### Quick smoke tests

```bash
# list aliases
curl -s http://mac.home.arpa:11434/v1/models -H "Authorization: Bearer sk-local"

# chat
curl -s http://mac.home.arpa:11434/v1/chat/completions \
  -H "Authorization: Bearer sk-local" -H "Content-Type: application/json" \
  -d '{"model":"main","messages":[{"role":"user","content":"Say hi"}]}'

# image Q&A — the unified main is multimodal (put the image BEFORE the text)
curl -s http://mac.home.arpa:11434/v1/chat/completions \
  -H "Authorization: Bearer sk-local" -H "Content-Type: application/json" \
  -d '{"model":"main","messages":[{"role":"user","content":[
        {"type":"image_url","image_url":{"url":"data:image/png;base64,..."}},
        {"type":"text","text":"What is in this image?"}]}]}'

# embeddings — BGE-M3 dense vectors (1024-dim) for RAG (first call wakes Infinity)
curl -s http://mac.home.arpa:11434/v1/embeddings \
  -H "Authorization: Bearer sk-local" -H "Content-Type: application/json" \
  -d '{"model":"embed","input":["hallo welt","the quick brown fox"]}'

# rerank — score documents against a query, return the top matches
curl -s http://mac.home.arpa:11434/v1/rerank \
  -H "Authorization: Bearer sk-local" -H "Content-Type: application/json" \
  -d '{"model":"rerank","query":"Wie ist das Wetter?",
       "documents":["Es regnet heute.","Die Katze schläft.","Morgen wird es sonnig."],
       "top_n":2}'
```

---

## Web dashboard (browser + JSON API)

Management (not inference) lives on its own port — **`http://mac.home.arpa:8090`**:
browser control of models / services / settings / logs / telemetry (see the
README's "Web dashboard" section). Unlike the LiteLLM gateway it **is**
token-protected: log in with `DASHBOARD_TOKEN` from
`/usr/local/etc/macstudio.conf`, or script against the JSON API with a Bearer
header:

```bash
TOKEN=…   # sudo grep '^DASHBOARD_TOKEN=' /usr/local/etc/macstudio.conf | cut -d"'" -f2
curl -s -H "Authorization: Bearer $TOKEN" http://mac.home.arpa:8090/api/status      # daemons + memory + active models
curl -s -H "Authorization: Bearer $TOKEN" http://mac.home.arpa:8090/api/telemetry   # power/thermal/RAM history
curl -s -H "Authorization: Bearer $TOKEN" -X POST http://mac.home.arpa:8090/api/models/select \
  -H "Content-Type: application/json" -d '{"slot":"main","id":"gemma4-26b-optiq"}'  # returns {"job_id":…}
```

---

## Mac Studio in Home Assistant (MQTT)

Besides serving LLMs, the Mac can publish its **runtime telemetry** to your MQTT
broker and appear in Home Assistant as a device — power draw, GPU load,
thermal/memory pressure, RAM/disk, the active model, update status — plus a
**`select` to switch the main model from HA with one click**. This is separate
from the LLM gateway above; it's the `com.local.mqtt.bridge` daemon (stdlib
Python, speaks MQTT 3.1.1 directly — no add-on needed on the Mac).

**Turn it on:** `sudo bash setup.sh` → *Select services* → toggle `INSTALL_MQTT`
on, then *Change settings* (menu 4) to set at least `MQTT_HOST` (and
`MQTT_USER`/`MQTT_PASS` if your broker needs auth), then apply. Or set the keys
directly in `/usr/local/etc/macstudio.conf` and run `sudo bash setup.sh --apply`.

| Key | Default | Meaning |
|-----|---------|---------|
| `INSTALL_MQTT` | `0` | Run the bridge |
| `MQTT_HOST` | `mqtt.home.arpa` | Broker host/IP (empty = bridge idles) |
| `MQTT_PORT` | `1883` | Broker port (plain TCP) |
| `MQTT_USER` / `MQTT_PASS` | empty | Broker credentials (stored plaintext in the 644 conf — use a dedicated low-privilege broker user) |
| `MQTT_TOPIC_PREFIX` | `macstudio` | Base topic |
| `MQTT_DISCOVERY_PREFIX` | `homeassistant` | Must match HA's MQTT integration discovery prefix |
| `MQTT_PUBLISH_INTERVAL_SEC` | `10` | Telemetry cadence (version/update checks run every 6 h) |

With HA's **MQTT integration** enabled and pointed at the same broker, a device
**"Mac Studio"** appears automatically (autodiscovery) with sensors, binary
sensors and a **Main Model** select. No YAML required.

### Topics

| Topic | Dir | Retained | Payload |
|-------|-----|----------|---------|
| `macstudio/availability` | pub (LWT) | yes | `online` / `offline` |
| `macstudio/silicon/availability` | pub | yes | health of the powermetrics scrape (gates the power sensors) |
| `macstudio/state` | pub | yes | JSON snapshot: `total_power_w` (whole system, SMC), `package_power_w`, `cpu_power_w`, `gpu_power_w`, `ane_power_w`, `cpu_temp_c`, `gpu_temp_c`, `gpu_util_pct`, `thermal_pressure`, `memory_pressure`, `ram_free_mb`, `wired_limit_mb`, `gpu_mem_used_mb`, `gpu_mem_free_mb`, `swap_used_mb`, `disk_free_gb`, `boot_time`, `reboot_pending`, `active_model`, `text_engine`, `text_backend_running`, `litellm_up`, `glmocr_awake` |
| `macstudio/updates` | pub | yes | JSON: `updates_available`, `macos_version`, `mlx_lm`/`mlx_vlm`/`litellm` (installed+latest), `brew_outdated`, `last_autoupdate_run` |
| `macstudio/model/state` | pub | yes | catalog id of the active main model |
| `macstudio/model/status` | pub | yes | `ready` / `loading <id>` / `error: <msg>` |
| `macstudio/model/set` | **sub** | no | publish a catalog id here to switch the main model |

`thermal_pressure`/`memory_pressure` are strings (`Nominal`/`Fair`/…,
`Normal`/`Warn`/`Critical`). The power/temperature/GPU/thermal sensors have a
second availability bound to `macstudio/silicon/availability`, so if the
Prometheus exporters are off (`INSTALL_EXPORTERS=0`) those sensors show
*unavailable* while everything else keeps working.

The silicon numbers come from **macmon** (IOReport/SMC): `total_power_w` is the
whole-system draw (what macmon's TUI shows as *Total*), `package_power_w` only
the CPU+GPU+ANE compute rails, and `gpu_util_pct` is real utilization. Values
are averaged over `SILICON_SAMPLE_INTERVAL_MS` (default 10 s, matched to the
publish cadence). Without macmon the exporter falls back to `powermetrics` —
then `total_power_w`/`cpu_temp_c`/`gpu_temp_c` stay `null`.

`gpu_mem_used_mb` is what the GPU allocator currently holds (IORegistry
"Alloc system memory" — MLX model weights + KV cache; GPU-wired memory is
accounted separately from normal wired pages), and `gpu_mem_free_mb` =
`iogpu.wired_limit_mb` − used: the headroom left for a bigger model or longer
context. `swap_used_mb` comes from `vm.swapusage`. All three are read locally
by the bridge, so they work even with the exporters off.

### Switching the model from HA

The **Main Model** select lists every downloaded, non-broken `role=text` model
in the catalog. Picking one publishes the id to `macstudio/model/set`; the bridge
runs `setup.sh --set-model main <id>` (same validation as the TUI), restarts the
text backend (~30–60 s, no hot-swap), and reports progress on
`macstudio/model/status` (`loading <id>` → `ready`). A second request during a
switch is rejected. Switching is also available as a plain CLI:
`sudo bash setup.sh --set-model main <id>`.

### Smoke tests

```bash
# Watch everything the Mac publishes:
mosquitto_sub -h mqtt.home.arpa -u <user> -P <pass> -t 'macstudio/#' -v

# See the retained HA discovery messages:
mosquitto_sub -h mqtt.home.arpa -u <user> -P <pass> -t 'homeassistant/+/macstudio/+/config' -v

# Switch the main model (id from `llm-models`):
mosquitto_pub -h mqtt.home.arpa -u <user> -P <pass> -t macstudio/model/set -m gemma4-26b-optiq
```

An ESP32 (e.g. ESPHome) can subscribe to the same `macstudio/state` topic to drive
a local display — the JSON keys above are the contract.

---

## Open WebUI

**Settings → Connections → OpenAI API**:

- **API Base URL:** `http://mac.home.arpa:11434/v1`
- **API Key:** `sk-local`

The models `main` and `main-fast` always appear in the model picker; `agent` and `ocr`
appear only when enabled (`INSTALL_AGENT=1` / `ALIAS_OCR` set — both off by default).
For chat use `main`, which may emit reasoning that Open WebUI renders as a foldable
"thinking" block; `main-fast` and `agent` are thinking-off, so they return
clean output with no thinking block (`main-fast` is the fast non-reasoning chat path,
`agent` adds a 128K context for long documents).
(Embeddings/STT are not served by this stack.)

---

## paperless-gpt (and paperless-ngx AI)

Point the OpenAI provider at the gateway:

```yaml
environment:
  LLM_PROVIDER: openai
  LLM_MODEL: main
  OPENAI_API_KEY: sk-local
  OPENAI_BASE_URL: http://mac.home.arpa:11434/v1
  # OCR via the on-demand vision model (requires ALIAS_OCR set — off by default):
  OCR_PROVIDER: llm
  VISION_LLM_PROVIDER: openai
  VISION_LLM_MODEL: ocr
```

`ocr` is off by default (`ALIAS_OCR` empty) — enable it first via `llm-models` or
`setup.sh --set-model ocr <id>`. Once enabled, the first OCR call wakes GLM-OCR
(~10–20 s) and then it serves; it sleeps again after
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

# image Q&A — the unified main is multimodal (no separate vision alias).
# Put the image BEFORE the text (Gemma multimodal recommendation).
v = client.chat.completions.create(
    model="main",
    messages=[{"role": "user", "content": [
        {"type": "image_url", "image_url": {"url": "data:image/png;base64,..."}},
        {"type": "text", "text": "Was steht auf diesem Bild?"},
    ]}],
)
print(v.choices[0].message.content)

# override sampling per request (e.g. Gemma's top_k via extra_body):
r = client.chat.completions.create(
    model="main-fast",
    messages=[{"role": "user", "content": "..."}],
    temperature=1.0, top_p=0.95,
    extra_body={"top_k": 64},
)
```

### Gemma multimodal tips

- **Put image (and audio) content *before* the text** in the `content` array — Gemma's
  recommended modality order.
- **Sampling:** `main`/`main-fast` already default to Gemma's reference
  (temp 1.0 / top_p 0.95 / top_k 64). `top_k` is not a native OpenAI field, so pass it
  via `extra_body` when overriding per request.
- **Image detail / resolution:** Gemma's per-image *visual token budget*
  (`max_soft_tokens`, 70–1120 — higher for dense OCR, lower for captioning) is **not
  exposed by mlx-vlm 0.6.2** — there is no per-request image-resolution knob in this
  stack. For best document transcription use the dedicated `ocr` alias (GLM-OCR); the
  unified `main` handles general image Q&A.

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
  hot-swap. **GLM-OCR (`ocr`) is the only model that co-resides** (small, on-demand,
  and off by default — set `ALIAS_OCR` to enable). Under `TEXT_ENGINE=mlx-vlm` the
  `main` model handles images itself.
- **On-demand backends** (`ocr`, and the companion services) wake on the first
  request after idle — expect a one-time spin-up delay, then normal latency.
- **Long requests:** the gateway timeout is `LLM_REQUEST_TIMEOUT` (default 3600 s
  = 60 min) with **no retries**, sized for long documents / OCR.
- **Streaming** is supported on chat completions (`"stream": true`).
- **Health check:** `GET /v1/models` returns 200 with the alias list when the
  gateway and backend are up.
