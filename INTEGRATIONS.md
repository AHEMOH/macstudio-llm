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
TOKEN=…   # sudo sed -n "s/^DASHBOARD_TOKEN=//p" /usr/local/etc/macstudio.conf | tr -d "'"
curl -s -H "Authorization: Bearer $TOKEN" http://mac.home.arpa:8090/api/status      # daemons + memory + active models
curl -s -H "Authorization: Bearer $TOKEN" http://mac.home.arpa:8090/api/telemetry   # power/thermal/RAM history
curl -s -H "Authorization: Bearer $TOKEN" -X POST http://mac.home.arpa:8090/api/models/select \
  -H "Content-Type: application/json" -d '{"slot":"main","id":"gemma4-26b-optiq"}'  # returns {"job_id":…}
```

---

## Remote desktop (VNC + browser) — `INSTALL_REMOTE` / `INSTALL_NOVNC`

The Mac is headless, but sometimes you need the **graphical desktop** — a GUI app,
System Settings, a login prompt. `INSTALL_REMOTE` (default **on**) turns on macOS'
built-in **Screen Sharing** (VNC on `:5900`); `INSTALL_NOVNC` (default **on**) adds a
tiny browser bridge so you don't even need a client. Both use the **same password**,
auto-generated once into `VNC_PASSWORD` in `/usr/local/etc/macstudio.conf`
(plaintext, LAN-only — like `DASHBOARD_TOKEN`/`MQTT_PASS`). Read it with:

```bash
sudo sed -n "s/^VNC_PASSWORD=//p" /usr/local/etc/macstudio.conf | tr -d "'"
```

> **Use `:5901`, not `:5900`, for password-only login.** macOS' Screen Sharing on `:5900`
> offers its own Apple/ARD account authentication (real macOS username + password) *before*
> plain VNC-password auth, and most clients (including the browser) pick whichever the
> server prefers — so connecting straight to `:5900` gets you a macOS username/password
> prompt instead of the shared `VNC_PASSWORD`, and noVNC crashes outright (Apple's auth needs
> WebCrypto, which browsers only expose over HTTPS/localhost, not plain LAN HTTP). A tiny
> proxy, `com.local.vncfilter` on **`VNC_FILTER_PORT`** (default **5901**), sits in front of
> `:5900` and strips that offer down to VNC-password auth only. Both entry points below
> already go through it.

**From Windows (VNC client):** install RealVNC Viewer or TightVNC Viewer, connect to
**`mac.home.arpa:5901`** (`VNC_FILTER_PORT` — **not** `:5900`), enter the `VNC_PASSWORD`
only (no username field, or leave it blank).

**From a browser (no client):** open **`http://mac.home.arpa:6080/vnc.html`**
(`NOVNC_PORT`, default 6080) → **Connect** → enter the `VNC_PASSWORD`. This is
[noVNC](https://novnc.com) served by `websockify` (~30 MB, always-on) bridging through
`com.local.vncfilter` to `:5900`; `screensharingd` itself only spawns while a session is
open, so the RAM cost is negligible and never touches the model budget.

**RAM:** websockify ~30 MB idle; Screen Sharing ~0 idle (on-demand). It does **not**
count against the "one big model" / 30 GB-wired budget.

**Headless notes:**
- **Resolution:** attach an **HDMI dummy plug** (or a real monitor) so macOS renders a
  usable framebuffer — a fully displayless Mac defaults to a tiny resolution over VNC.
- **Login window vs desktop:** without auto-login, VNC shows the **login window** after a
  reboot; log in over VNC to reach the desktop. To land straight on the desktop, enable
  auto-login manually (System Settings → Users & Groups → *Automatically log in as* — note
  it stores the login password locally).
- **FileVault:** Screen Sharing only starts **after** boot reaches the macOS login window,
  so with FileVault on you can't do the pre-boot disk unlock over VNC — unlock it locally
  (or keep FileVault off on a headless LAN server) so it can boot to the login window.
- **Turning it off:** toggling `INSTALL_REMOTE=0` stops the noVNC bridge but does **not**
  disable macOS Screen Sharing (one-way, like the SMB share). Turn it off in
  System Settings → General → Sharing → Screen Sharing, or run
  `sudo /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart -deactivate -configure -access -off`.

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

## paperless-ngx — Apple-Vision searchable-PDF OCR (`INSTALL_PAPERLESS_OCR`)

A Mac-side worker (`com.local.paperless.ocr`, opt-in `INSTALL_PAPERLESS_OCR=1`) that
produces **genuinely searchable PDFs** using **Apple Vision** OCR — the engine that, in
testing, cleanly transcribed dense Russian/Cyrillic documents that Tesseract (paperless's
built-in OCR) turns into mojibake and that GLM-OCR truncates. It adds an *invisible*,
correctly-Unicode-encoded text layer (via `ocrmac` + PyMuPDF) without changing how the page
looks. Runs on the Mac because Apple Vision is macOS-only; paperless-ngx can live anywhere
reachable over HTTP.

**Enable it** (edit `/usr/local/etc/macstudio.conf`, then `sudo bash setup.sh --apply`):
```sh
INSTALL_PAPERLESS_OCR=1
PAPERLESS_OCR_URL=http://paperless.home.arpa:8000      # your paperless-ngx
PAPERLESS_OCR_TOKEN=<paperless API token>              # Settings → API token
PAPERLESS_OCR_LANGS=ru-RU,en-US                        # Apple Vision locales (multiple OK)
# optional: PAPERLESS_OCR_RECMODE=accurate  PAPERLESS_OCR_DPI=200
```

**On the paperless-ngx side:** keep the default `PAPERLESS_OCR_MODE=skip` so paperless
**indexes the text layer we provide** instead of re-running Tesseract. Create the trigger tags
you want to use — `ocr:apple`, `ocr:apple-force`, `ocr:vlm`, `ocr:vlm-force` (see the retro-fix
table below) — plus `ocr:done` / `ocr:superseded` (the worker creates the latter two on demand).

Two workflows run together:

- **Gateway (new documents):** drop PDFs/images into `PAPERLESS_OCR_INBOX`
  (`~/paperless-ocr/inbox`). Each is OCR'd, uploaded to paperless (searchable), and the
  pristine original is kept in `PAPERLESS_OCR_ARCHIVE`. After OCR the worker asks the LLM
  for a **short descriptive name** from the text (e.g. `Rechnung Airbrush City Juni 2026`
  instead of `SCN_0001`) and uses it as the paperless title **and** the archived-original
  filename (`PAPERLESS_OCR_SMART_NAME=0` to keep the scanner's name). Archived originals are
  auto-deleted after **`PAPERLESS_OCR_ARCHIVE_RETENTION_DAYS`** (default 30; `0` = keep
  forever) — the searchable copy already lives in paperless.
- **Retro-fix (existing documents):** tag any paperless document with one of **four** tags.
  The worker downloads the original, re-OCRs it, uploads a new searchable copy (tagged
  `ocr:done`, metadata preserved), and retags the old one `ocr:superseded` (kept unless
  `PAPERLESS_OCR_DELETE_ORIGINAL=1`). The tags differ on **engine** × **force**:

  | Tag | Engine | If the doc already has a text layer |
  |---|---|---|
  | `ocr:apple` | Apple Vision | **skipped** (safe to mass-tag; digital-born released) |
  | `ocr:apple-force` | Apple Vision | **re-OCR'd anyway** (replace e.g. Tesseract mojibake) |
  | `ocr:vlm` | Gemma-4 | skipped |
  | `ocr:vlm-force` | Gemma-4 | re-OCR'd anyway (handwriting/math) |

  > **Most existing paperless docs already have a Tesseract text layer** (from ingestion), so
  > plain `ocr:apple` would just skip them. To actually replace that layer with Apple Vision,
  > use **`ocr:apple-force`**. The plain tags stay useful for mass-tagging a mail source where
  > digital-born docs should be left untouched.

**Digital-born vs scan (important).** By default both loops are smart: a PDF that **already has
a good text layer** (digital-born — e.g. an emailed invoice from a report generator) is **passed
through untouched** — never rasterized or re-OCR'd, so perfect text is preserved. Only
**scans/images without a text layer** get Apple-Vision OCR. The threshold is
`PAPERLESS_OCR_TEXT_MIN_CHARS` (avg chars/page, default 50). The **`*-force`** retro-fix tags
override this — they re-OCR regardless of an existing layer.

**Handwriting / math → VLM fallback route.** An OCR benchmark on real documents (see
[`docs/ocr-benchmark.md`](docs/ocr-benchmark.md)) found a clean split: **Apple Vision wins on
printed text** (fast, exact, tiny RAM) but is **blind to faint pencil handwriting and breaks
math symbols** (∀→"Kk", ℕ→"IN"); the large vision model **Gemma-4** (`main`) reads handwriting
and emits correct **LaTeX** — but *loops* on dense tables, so it is a **fallback, not a
replacement**. So handwriting/math docs are routed to the VLM (`PAPERLESS_OCR_VLM_MODEL`,
default `main-fast`), which lays its transcription down as one **invisible full-page** searchable
layer (no per-word boxes). Two ways to trigger it:
- **Manual (reliable):** tag a paperless doc **`ocr:vlm`** (retro-fix), or put **`_vlm`** in an
  inbox filename (gateway) — forces the Gemma-4 route.
- **Auto (best-effort):** if Apple Vision reads fewer than `PAPERLESS_OCR_VLM_MIN_CHARS`
  chars/page (default 80 — a near-empty scan), the worker re-OCRs with the VLM. This only fires
  on *sparse* pages; a printed form whose labels alone exceed the threshold won't auto-escalate,
  so use the tag for known-handwriting docs. Set `PAPERLESS_OCR_VLM_AUTO=0` to disable auto.
The VLM route reuses the already-loaded `main` (no second model — the "one big model" rule holds)
but a full-page Gemma pass takes ~1–2 min, versus ~2 s for Apple Vision.

**E-mail attachments.** paperless-ngx reads mail and ingests attachments **itself** — those
never pass through this worker. Digital-born attachments (most) already have text, so paperless
indexes them fine. For the rare **scanned** attachment (no text, e.g. Cyrillic → Tesseract
mojibake), tag it `ocr:apple` (manually, or via a paperless **Workflow** that auto-tags a whole
mail source): retro-fix then re-OCRs scans with Apple Vision and simply releases the
already-text ones (no duplicates).

**Scan straight into the inbox (SMB).** A network scanner (e.g. Canon MAXIFY GX2050 →
"Scan to shared folder / SMB") can drop files directly into `PAPERLESS_OCR_INBOX`:
1. macOS **System Settings → General → Sharing → File Sharing** on; add the inbox folder;
   give the scanner's SMB login (ideally the same `mac` user) read/write.
2. Point the scanner at `smb://<mac>/…/paperless-ocr/inbox` and scan a **multi-page PDF**
   (one job = one file).
The gateway only picks up a file once it is **fully written** — unchanged for
`PAPERLESS_OCR_STABLE_SEC` (default 30 s) **and** no longer held open by `smbd`. So a slow
50-page scan is never OCR'd half-finished. If your scanner pauses longer than 30 s between
pages, raise `PAPERLESS_OCR_STABLE_SEC`.

**Host the inbox on the Mac itself** (not on a NAS): the worker runs on the Mac and reads
the folder locally, and the "still being written" guard uses `lsof`, which only sees writes
on the Mac. An inbox on a NAS would need mounting on the Mac and would fall back to the
weaker mtime-only settle. Files here are temporary (deleted after upload), so disk use is nil.

**Double-sided originals (simplex ADF, e.g. GX2050).** The GX2050's ADF scans one side per
pass. Scan the fronts, flip the stack, scan the backs — send **both passes to the
`<inbox>/duplex/` subfolder**. The gateway interleaves them (backs reversed) into one
page-ordered document, then OCRs + uploads it. If pages come out mis-ordered (depends on how
you flip), set `PAPERLESS_OCR_DUPLEX_REVERSE=0`. A single file left alone in `duplex/` for
`PAPERLESS_OCR_DUPLEX_TIMEOUT_SEC` (30 min) is treated as single-sided.

**Ad-hoc CLI:** `paperless-ocr in.pdf out.pdf -l ru-RU,en-US` (also accepts images).
Verify with `pdftotext out.pdf -` → clean Unicode text.

Notes: `PAPERLESS_OCR_RECMODE` must be `accurate` or `fast` — **not** `livetext` (VisionKit,
crashes headless). This supersedes the `OCR_PROVIDER=llm` path above for OCR quality; keep
paperless-gpt only if you also want LLM-generated titles/tags. The API token sits in the
644 conf (LAN-only, same precedent as `MQTT_PASS`/`DASHBOARD_TOKEN`).

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
