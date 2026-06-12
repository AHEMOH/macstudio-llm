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
| `main` | The big always-on model (chat)   | `/v1/chat/completions`, `/v1/completions`, `/v1/messages` | mlx_lm.server (always on)      |
| `main-agents` | `main` tuned for **tool use / web / cron / email**: low temp, **no thinking**, mild anti-repetition + `max_tokens` backstop | same as `main` | **same loaded model**, agent sampling |
| `main-metadata` | `main` for **paperless-ngx JSON**: deterministic + tight `max_tokens` cap, **no thinking** (title/date/tags JSON) | same as `main` | **same loaded model**, different default sampling |
| `main-ocr` | `main` (gemma) for **document transcription**: anti-loop sampling (`frequency_penalty`), A4-page `max_tokens` cap, **no thinking** | same as `main` | **same loaded model**, OCR sampling |
| `ocr`  | Dedicated OCR (document → text), best quality | `/v1/chat/completions` (image input) | GLM-OCR via mlx-vlm (on-demand) |
| `vision` | General multimodal/vision (images → text) | `/v1/chat/completions` (`image_url` input) | mlx-vlm (on-demand; opt-in via `ALIAS_VISION`) |

The `main-*` aliases all point at the **one** loaded text model — they only differ
in DEFAULT sampling (temperature/top_p/penalties/max_tokens), so picking one does
**not** load a second model. `main` itself uses the per-model sampling defaults from
the catalog; clients may override any of these per request. Toggle the presets with
`PRESET_ALIASES` and tune them via the `PRESET_*` keys in
`/usr/local/etc/macstudio.conf` (set via `setup.sh` → settings).

**Thinking/reasoning:** `main` reasons by default (a reasoning model thinks; clients
can send `enable_thinking:false` to turn it off). **`main-agents`, `main-metadata`
and `main-ocr` always run without thinking** (suppressed at the gateway) — so
agent tool-calls stay tight, metadata returns clean JSON, and OCR transcribes
without reasoning overhead.

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
| `macstudio/state` | pub | yes | JSON snapshot: `total_power_w` (whole system, SMC), `package_power_w`, `cpu_power_w`, `gpu_power_w`, `ane_power_w`, `cpu_temp_c`, `gpu_temp_c`, `gpu_util_pct`, `thermal_pressure`, `memory_pressure`, `ram_free_mb`, `wired_limit_mb`, `disk_free_gb`, `boot_time`, `reboot_pending`, `active_model`, `text_engine`, `text_backend_running`, `litellm_up`, `glmocr_awake` |
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
mosquitto_pub -h mqtt.home.arpa -u <user> -P <pass> -t macstudio/model/set -m gemma4-12b
```

An ESP32 (e.g. ESPHome) can subscribe to the same `macstudio/state` topic to drive
a local display — the JSON keys above are the contract.

---

## Open WebUI

**Settings → Connections → OpenAI API**:

- **API Base URL:** `http://mac.home.arpa:11434/v1`
- **API Key:** `sk-local`

The models `main` (plus the `main-agents`/`main-metadata`/`main-ocr` presets) and
`ocr` (and `vision` if enabled) appear in the model picker. For chat use `main`,
which may emit reasoning that Open WebUI renders as a foldable "thinking" block;
`main-agents`, `main-metadata` and `main-ocr` are thinking-off, so they return clean
output with no thinking block. (Embeddings/STT are not served by this stack.)

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
- **Long requests:** the gateway timeout is `LLM_REQUEST_TIMEOUT` (default 3600 s
  = 60 min) with **no retries**, sized for long documents / OCR.
- **Streaming** is supported on chat completions (`"stream": true`).
- **Health check:** `GET /v1/models` returns 200 with the alias list when the
  gateway and backend are up.
