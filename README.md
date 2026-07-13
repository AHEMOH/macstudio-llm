# Mac Studio Headless LLM Server

Headless Apple Silicon Mac as an **MLX inference server**: **one unified
multimodal model permanently warm** — by default **gemma-4-26b on `oMLX`**,
which handles **text *and* images in the same chat** plus tool calling, plus
**BGE embeddings + reranker** in that SAME resident process (for RAG) — a
**LiteLLM gateway** that gives apps stable aliases. Plus optional companion
services (image AI, document conversion) that sleep when idle and wake on
first request. Runs fully unattended: no GUI, no login, auto-restart on power
loss, weekly self-update.

Designed for a 32 GB M1 Max but scales unchanged to bigger Apple Silicon — just
raise a couple of config keys.

> **Text engine — oMLX.** The always-on backend is **oMLX**
> (pinned `OMLX_REPO_REF=v0.5.1`), serving **one unified multimodal
> model** that handles **text *and* images in the same chat** plus tool calling —
> AND, in the SAME process, the BGE embed/rerank pair — with an SSD
> paged-prefix-cache and continuous batching. The default main is `gemma4-26b-qat`
> (verified: `gemma4-{26b,12b,e4b,e2b}-qat`, text+tools+vision, vision 4/4). Only **one
> process** is in memory — there is no second backend for embed/rerank anymore.

## What this gives you

- **oMLX** always on (internal :18000): **one** unified multimodal
  model that does **text *and* images in the same chat** plus tool calling, plus
  the BGE embed/rerank pair, ALL in one process. Soft RAM ceiling
  (`OMLX_MEMORY_GUARD_GB`) and a per-model context cap (`OMLX_MAX_CONTEXT_WINDOW`,
  pre-seeded into `~/.omlx/settings.json`). Reasoning is left to the model/client
  by default; tool calling is auto-detected from the model's chat template.
  Version pinned via `OMLX_REPO_REF` (v0.5.1).
- **LiteLLM gateway** on the public port (:11434): apps talk OpenAI `/v1` (and
  Anthropic `/v1/messages`) to the stable aliases — `main` (text + images, reasons by
  default), `main-fast` (same model, thinking-off), `embed` (BGE-M3 embeddings)
  and `rerank` (BGE reranker) — all FOUR served by the same resident oMLX
  process. The underlying model is swappable without the app noticing.
- **Embeddings + rerank** (aliases `embed`/`rerank`, on by default — no separate
  install toggle, they live inside the one MLX-stack process): **BAAI/bge-m3**
  (1024-dim multilingual dense embeddings, `embed` alias) + **BAAI/bge-reranker-v2-m3**
  (cross-encoder, `rerank` alias) served by the SAME resident oMLX process as
  `main`, discoverable via a `--model-dir` symlink farm. No separate backend,
  port, or idle/wake cycle — they're always available whenever `main` is.
  Reachable via LiteLLM `/v1/embeddings` and `/v1/rerank`.
- **Voice: Speech-to-Text + Text-to-Speech** (opt-in `INSTALL_VOICE=1`, off by
  default): `stt` alias via **FluidAudio's Parakeet** model running on the Apple
  Neural Engine (measured to cause zero slowdown of the main model — the ANE is
  separate silicon from the GPU) and `tts` alias via macOS's own `say`/
  AVSpeechSynthesizer. Point any OpenAI-compatible client (e.g. Open WebUI) at the
  gateway's `stt`/`tts` models for voice input/output, **or** add Home Assistant's
  native **Wyoming protocol** integration (:10300) for a fully on-device Assist
  voice pipeline — one port, auto-discovered as both STT and TTS. See
  [INTEGRATIONS.md](INTEGRATIONS.md#open-webui) for Open WebUI, and
  [INTEGRATIONS.md](INTEGRATIONS.md#home-assistant-voice-assistant-wyoming) for
  Home Assistant, including a one-time manual step to install a higher-quality
  system voice.
- **Model catalog + `llm-models` TUI**: download pre-converted MLX models from
  HuggingFace, pick the active text / embed / rerank model, manage
  your HF token. Only fully-downloaded models become selectable.
- **30 GB GPU wired memory limit** (on a 32 GB box) + OS trim → nearly the whole
  machine is available to the model.
- **On-demand companions** on :3003 (immich-ml) and :5001 (docling-serve),
  optional — public ports always listen; the real backend wakes on request and
  sleeps after 15 min, freeing RAM.
- **Weekly auto-update** (Sat 06:00): **OS + brew system packages only**
  (`brew update`, macOS security updates). The model/LLM stack is **frozen** —
  `oMLX` is pinned via `OMLX_REPO_REF`, and `litellm`/models are never
  auto-upgraded (a surprise version jump once broke a model). The run logs which
  LLM versions are available but held. Bump them deliberately via
  **Check for updates** → set the pin → Install/update.
- **Watchdogs**: a memory-pressure safety net (offloads optional services,
  keeps the main model healthy) and an inference-stall killer.
- **Prometheus exporters** for Grafana are **opt-in** (`INSTALL_EXPORTERS=1`,
  off by default): node_exporter (:9100), Apple-Silicon metrics (:9101, via
  **macmon**: whole-system power from the SMC, CPU/GPU temperatures, real GPU
  utilization; powermetrics fallback), on-demand stack state (:9103).
- **MQTT bridge → Home Assistant** is **opt-in** (`INSTALL_MQTT=1`, off by
  default): publishes power/GPU/thermal/RAM/disk/update telemetry with HA
  autodiscovery and exposes a **one-click main-model switch** as an HA `select`.
  See [INTEGRATIONS.md](INTEGRATIONS.md#mac-studio-in-home-assistant-mqtt).
- **Web dashboard** (on by default, `INSTALL_DASHBOARD=1`): browser control of
  the whole box on `http://mac.home.arpa:8090` — models (download with live
  progress, switch main/embed/rerank), services (restart/stop/wake +
  live state), every `macstudio.conf` setting with **Save & Apply**, live log
  tails, and power/thermal/GPU/RAM charts. Token-protected (auto-generated
  `DASHBOARD_TOKEN` in `macstudio.conf`). The SSH TUI stays fully authoritative
  — the dashboard only calls the same `setup.sh` verbs.
- **Remote desktop** (on by default, `INSTALL_REMOTE=1` + `INSTALL_NOVNC=1`):
  control the headless macOS **desktop** over the LAN — macOS Screen Sharing (VNC,
  password-only via `:5901`, **not** `:5900`) for a Windows client (RealVNC/TightVNC),
  plus a browser bridge at `http://mac.home.arpa:6080/vnc.html` (noVNC, no client
  needed). A tiny `com.local.vncfilter` proxy strips macOS' Apple/ARD account-login
  offer so both entry points use one auto-generated `VNC_PASSWORD`; ~30 MB idle, so
  it never touches the model budget. See [INTEGRATIONS.md](INTEGRATIONS.md#remote-desktop-vnc--browser--install_remote--install_novnc).
- **One script** (`setup.sh`): install, update, settings, **model manager**,
  service control, clean-up, uninstall. TUI by default, `--apply` for
  non-interactive runs. Idempotent — re-run safely any time.

## Architecture

```
Public (apps point here):
  com.local.litellm.proxy          :11434   LiteLLM gateway — aliases main / main-fast /
                                             embed / rerank
                                             (OpenAI /v1 + Anthropic /v1/messages)
Always on (internal / support):
  com.local.omlx.main              :18000   the ONE unified process: main text+images
                                             + embed + rerank (oMLX)
  com.local.immich.proxy           :3003    on-demand proxy (optional)
  com.local.docling.proxy          :5001    on-demand proxy (optional)
  com.local.llm.watchdog                    memory-pressure safety net
  com.local.preventsleep                    caffeinate

Registered but sleeping until requested:
  com.local.immich.ml              :13003   immich-ml backend (optional)
  com.local.docling.serve          :15001   docling-serve backend (optional)

Opt-in metrics (INSTALL_EXPORTERS=1, off by default):
  com.local.node.exporter          :9100    Prometheus system metrics
  com.local.silicon.exporter       :9101    GPU / power / thermal / mem-pressure
  com.local.ondemand.exporter      :9103    on-demand backend + proxy liveness

Opt-in Home Assistant (INSTALL_MQTT=1, off by default):
  com.local.mqtt.bridge                     MQTT telemetry + HA autodiscovery + model switch

One-shot at boot:
  com.local.iogpu.wiredlimit                sets iogpu.wired_limit_mb
Scheduled (Sat 06:00 default):
  com.local.weekly.autoupdate               brew + macOS security updates (LLM stack frozen)
```

The main model is kept warm; switching it is an **explicit** action (pick in
`llm-models` → `omlx.main` restarts, ~30–60 s) — never a silent hot-swap.
Switching `embed`/`rerank` to an already-downloaded model does **not** restart
the daemon.

> **Connecting apps?** See **[INTEGRATIONS.md](INTEGRATIONS.md)** for the
> endpoint reference and ready-to-paste configs (Open WebUI, paperless-gpt,
> OpenAI/Anthropic SDKs, vision/OCR).

## Quick start

### 1. On the Mac — enable remote access

**System Settings → General → Sharing**

| Toggle | Why | Required? |
|---|---|---|
| **Remote Login** | SSH daemon — needed to `ssh` in and `git pull`. | **Required** |
| **Remote Management** | Screen-sharing for GUI repair when headless. | Recommended |
| **Remote Application Scripting** | Run AppleScript/`osascript` over SSH. | Recommended |

Under **Remote Login**, tick **"Allow full disk access for remote users"**.
After this the Mac can go fully headless.

### 2. From your PC — copy SSH key once

**Windows PowerShell:**
```powershell
if (-not (Test-Path $env:USERPROFILE\.ssh\id_ed25519)) {
  ssh-keygen -t ed25519 -f $env:USERPROFILE\.ssh\id_ed25519 -N '""' -C "mac-llm"
}
Get-Content $env:USERPROFILE\.ssh\id_ed25519.pub | ssh mac@mac.home.arpa `
  "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
ssh mac@mac.home.arpa 'echo ok'
```

**macOS / Linux:**
```bash
[ -f ~/.ssh/id_ed25519 ] || ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N '' -C mac-llm
ssh-copy-id mac@mac.home.arpa
ssh mac@mac.home.arpa 'echo ok'
```

### 3. On the Mac — clone and install

On fresh macOS, `/usr/bin/git` is a stub that triggers a GUI prompt. The
one-liner installs the Command Line Tools headlessly first, then clones and
runs the installer. `setup.sh` then auto-installs Homebrew, **python@3.12**, and
builds the MLX venvs (`omlx`, `litellm`).

```bash
# SSH into the Mac, then (one-time CLT bootstrap so `git clone` works):
sudo softwareupdate -i "$(softwareupdate -l 2>/dev/null \
  | awk -F'Label: ' '/Command Line Tools for Xcode/ {print $2; exit}' \
  | sed 's/ *$//')" --verbose

cd ~
git clone https://github.com/<you>/macstudio-llm.git
cd macstudio-llm

sudo bash setup.sh            # interactive TUI (recommended first run)
# …or non-interactive (installs CLT, Homebrew, python@3.12, the MLX venvs):
sudo bash setup.sh --apply
```

The first `--apply` builds the venvs (several minutes of pip wheels). It does
**not** download any model — that's an explicit step next.

### 4. Download a model and pick it

```bash
llm-models                    # opens the model & alias manager
#   t                         → paste your HuggingFace token (gemma is gated — required)
#   d gemma4-26b-qat          → download the default unified main (~16 GB, live progress)
#   s gemma4-26b-qat          → set it as the active 'main' (text+images)
#   d bge-m3                  → download the embedder (~2 GB, ungated)
#   m bge-m3                  → set it as the active 'embed' model
#   d bge-reranker-v2-m3      → download the matching reranker (~2 GB, ungated)
#   k bge-reranker-v2-m3      → set it as the active 'rerank' model
#   q                         → back
```

Only `STATUS=ok` (fully downloaded + verified) models are selectable. After
`s`, `omlx.main` restarts and loads the model. After `m`/`k`, embed/rerank
become available on the SAME running process — no restart.

### 5. Use it

Apps point at the **LiteLLM gateway on :11434** and address the **alias**, never
the real model id:

```bash
# OpenAI-style chat
curl http://mac.home.arpa:11434/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"main","messages":[{"role":"user","content":"Hallo!"}]}'

# Image Q&A — send images straight to "main" (the unified multimodal model)
curl http://mac.home.arpa:11434/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"main","messages":[{"role":"user","content":[
        {"type":"text","text":"What is in this image?"},
        {"type":"image_url","image_url":{"url":"data:image/png;base64,..."}}]}]}'
```

Tool calling and reasoning separation are automatic on `oMLX` (per the
model's chat template) — no per-model flags needed.

### 6. Update later

```bash
cd ~/macstudio-llm && git pull && sudo bash setup.sh --apply
```

Or let the weekly job do brew + macOS updates automatically (LLM stack frozen).

## Model catalog & the `llm-models` TUI

The catalog (`models/catalog.tsv`, seeded once to
`/usr/local/etc/macstudio-models/catalog.tsv`) lists **pre-converted MLX models
on HuggingFace** — there is **no local conversion**. Source is always
HuggingFace; entries are repo-ids (`org/name`), not URLs.

Roles that are selectable: **`text`** (alias `main`, plus the `main-fast`
preset on the same model), **`embed`** (alias `embed`) and **`rerank`**
(alias `rerank`).

`llm-models` actions:

| Key | Action |
|---|---|
| `d <id>` | **Download** the repo from HuggingFace (live progress), then verify |
| `s <id>` | Set as the active **text/main** model (role=text only) → `omlx.main` restarts |
| `m <id>` / `k <id>` | Set the active **embed** / **rerank** model (no restart if already downloaded) |
| `a` / `e <id>` / `x <id>` | Add / edit / remove a catalog entry |
| `r <id>` | Delete the locally-downloaded files |
| `t` | Store/clear your **HuggingFace token** (`hf auth login`) |
| `q` | Back |

Per-model columns the catalog carries: `role`, `engine`, `quant`, `gb`,
`gated`, `reasoning_parser`, `tool_parser`, `max_kv_size`, `max_num_seqs`,
`rating`, `notes`, sampling defaults. `oMLX` auto-detects reasoning and
the tool parser from the model, so those columns are informational. A model is
refused for a slot when its `notes` carry a `BROKEN` flag (or `BROKEN[omlx]` —
every slot runs on the one `omlx` engine now).

**Per-model sampling** (temperature/top_p/…) defaults are injected into the
LiteLLM `main` alias; clients can override per request. `main`/`main-fast` use
Gemma's reference sampling (temp 1.0 / top_p 0.95 from the catalog + `top_k`=`GEMMA_TOP_K`
via `extra_body`).

**HuggingFace token:** set it via `llm-models` → `t`. It is stored in the user's
HF cache (`$HF_CACHE_DIR/.../token`, mode 600) — **never** in `macstudio.conf`
or git. Needed for gated repos (e.g. Gemma) and for higher download rate limits.

Seeded models — intentionally **lean** (QAT Gemma-4 unified mains + the
BGE embed/rerank pair). Add more via `llm-models`:

| id | role | ~GB | notes |
|---|---|---|---|
| `gemma4-26b-qat` | text | 16 | **default main** — QAT 26B-A4B MoE on oMLX, unified text+images+tools (~48 tok/s in a sandboxed eval); German (**gated**) |
| `gemma4-12b-qat` / `-e4b-qat` / `-e2b-qat` | text | 8 / 4 / 3 | QAT variants on oMLX — multimodal, faster/smaller; **gated** |
| `bge-m3` | embed | 2 | **default embed** — 1024-dim multilingual dense embeddings (same oMLX process) |
| `bge-reranker-v2-m3` | rerank | 2 | **default rerank** — cross-encoder reranker (same oMLX process) |

All Gemma-4 rows are multimodal text+images — **none support audio**.

## Prerequisites installed automatically

`setup.sh --apply` installs these on first run (hash/presence-checked, no-op if
present):

| Prerequisite | How | When |
|---|---|---|
| **Xcode Command Line Tools** | `softwareupdate -i` (headless) | unless present |
| **Homebrew** | official installer, `NONINTERACTIVE=1`, as `TARGET_USER` | if absent |
| **python@3.12** | `brew install python@3.12` (MLX/docling wheels need ≥3.10) | if `INSTALL_MLX=1` or `INSTALL_DOCLING=1` |
| **omlx project + venv** | `git clone` `OMLX_REPO`@`OMLX_REPO_REF` + `pip install -e .` (editable, alpha-stage, not on PyPI) in `$VENV_DIR/omlx` | if `INSTALL_MLX=1` |
| **litellm venv** | `pip install 'litellm[proxy]'` in `$VENV_DIR/litellm` | if `INSTALL_MLX=1` |
| **node_exporter** | `brew install node_exporter` | if `INSTALL_EXPORTERS=1` (off by default) |
| **mactop + macmon** | `brew install mactop macmon` | if `INSTALL_TUI=1` |
| **docling-serve venv** | `pip install 'docling[…]' 'docling-serve[ui]'` | if `INSTALL_DOCLING=1` |
| **python@3.11** | `brew install python@3.11` (immich-ml's venv needs 3.11; 3.13 lacks wheels) | if `INSTALL_IMMICH=1` |
| **immich-ml project** | `git clone` `IMMICH_REPO` + `python3.11 -m venv .venv && pip install -r requirements.txt` | if `INSTALL_IMMICH=1` |

The **immich-ml backend** (`IMMICH_PROJECT_DIR`) is now auto-cloned from `IMMICH_REPO`
(default the maintained upstream **`sebastianfredette/immich-ml-metal`**) and its venv
built with **Python 3.11** — no manual fork step anymore. It's a Metal/ANE drop-in for
Immich's own ML service: CLIP embeddings run on the GPU (MLX — brief bursts during photo
imports/backfill), face-detection + OCR on the **Apple Neural Engine** (Apple Vision),
face-recognition via ONNX/CoreML. **Needs macOS 26+**, and the on-demand backend sleeps
when idle, so it only touches the GPU during active jobs. Point your Immich server at
`http://<mac>:3003` — see INTEGRATIONS.md.

## Hardware assumptions

- **Apple Silicon** (M1–M5, any variant).
- **32 GB+ unified RAM** for a ~16–20 GB main model. Default
  `IOGPU_WIRED_LIMIT_MB=30720` (30 GB) assumes 32 GB.
- **macOS 13.4+** (for `iogpu.wired_limit_mb`); tested on macOS 26.

| Total RAM | `IOGPU_WIRED_LIMIT_MB` | OS headroom |
|-----------|------------------------|-------------|
| 32 GB     | **30720** (default)    | 2 GB        |
| 64 GB     | 61440                  | 4 GB        |
| 96 GB     | 92160                  | 6 GB        |
| 192 GB    | 184320                 | 12 GB       |

**Memory note (32 GB):** `oMLX` has a soft RAM ceiling
(`OMLX_MEMORY_GUARD_GB`, default 30) and caps context per-model with
`OMLX_MAX_CONTEXT_WINDOW` (default 65536) via `~/.omlx/settings.json`. Only
**one** process fits — the BGE embed/rerank pair lives inside that SAME
process (no second backend to co-reside); a second big main does not fit.

## `setup.sh` — one file, whole lifecycle

```
sudo bash setup.sh            # interactive TUI
sudo bash setup.sh --apply    # non-interactive install/update
sudo bash setup.sh --status   # live status table
sudo bash setup.sh --models   # jump straight to the model manager
sudo bash setup.sh --help
```

TUI main menu:

```
1) Install / update everything
2) Select services to install…   (MLX / immich / docling / exporters / watchdog)
3) Models & aliases…             (download MLX models, pick main / embed / rerank)
4) Change settings…
5) Service control…
6) Run weekly autoupdate now
7) Clean-up tasks…
8) View logs…
9) Uninstall everything this tool installed
q) Quit
```

Idempotent: re-running on a healthy system is a ~5 s no-op. Toggling a service
**off** removes its plist; **on** re-renders and bootstraps it.

## Configuration reference

All tunables live in **`/usr/local/etc/macstudio.conf`** (key=value). Managed
via `setup.sh` menu 4, or edit + `--apply`. Existing values are respected —
changing a default in the repo only affects fresh installs; edit the conf (or
use the menu) to change a live box.

| Key | Default | Meaning |
|---|---|---|
| `TARGET_USER` | `mac` | Unix user that owns the venvs + daemons |
| `IOGPU_WIRED_LIMIT_MB` | `30720` | GPU wired memory ceiling |
| `INSTALL_MLX` | `1` | The MLX stack (oMLX + LiteLLM gateway) — primary backend, now including embed/rerank |
| `VENV_DIR` | `/Users/mac/.macstudio-venvs` | Where the omlx/litellm venvs live |
| `HF_CACHE_DIR` | `/Users/mac/.cache/huggingface` | HF model cache (`HF_HOME`) + token store |
| `ALIAS_MAIN` | `gemma4-26b-qat` | Catalog id of the active unified text+images main (a VLM arch like gemma-4) |
| `ALIAS_EMBED` | `bge-m3` | Catalog id of the embedder (served by the SAME oMLX process, alias `embed`). Empty = no embed alias |
| `ALIAS_RERANK` | `bge-reranker-v2-m3` | Catalog id of the reranker (served by the SAME oMLX process, alias `rerank`). Empty = no rerank alias |
| `MODEL_PIN_MAIN` | `1` | Keep the main model permanently warm |
| `LITELLM_PORT` | `11434` | Public gateway port (apps use this) |
| `MAIN_BACKEND_PORT` | `18000` | Internal port `oMLX` binds (serves main + embed + rerank) |
| `LLM_REQUEST_TIMEOUT` | `3600` | Per-request timeout (s) for the text engine **and** LiteLLM; long docs/OCR |
| `TEXT_ENGINE` | `omlx` | The engine (`oMLX`) — one unified process for main (text+images+tools) + embed + rerank |
| `OMLX_REPO` / `OMLX_REPO_REF` | `github.com/jundot/omlx` / `v0.5.1` | Git source + pinned tag for the `omlx` venv (alpha-stage, not on PyPI) |
| `OMLX_PROJECT_DIR` | `/Users/mac/projects/omlx` | Where the oMLX git checkout lives |
| `OMLX_MODEL_DIR` | `/Users/mac/.cache/omlx-models` | `--model-dir` symlink farm making every downloaded model discoverable |
| `OMLX_MEMORY_GUARD_GB` | `30` | Soft RAM ceiling for the one oMLX process (`--memory-guard-gb`) |
| `OMLX_MAX_CONTEXT_WINDOW` | `65536` | Per-model context cap for `main`, pre-seeded into `~/.omlx/settings.json` (NOT a CLI flag) |
| `OMLX_SSD_CACHE_DIR` / `_MAX_SIZE` | `~/.cache/omlx-ssd-cache` / `20GB` | SSD paged-prefix-cache — real speedup on repeated long prompts. Empty dir = disabled |
| `OMLX_HOT_CACHE_MAX_SIZE` | _(empty)_ | In-memory hot-cache max size. Empty = oMLX default |
| `OMLX_MAX_CONCURRENT_REQUESTS` | `8` | Max concurrent in-flight requests (continuous batching) |
| `GEMMA_TOP_K` | `64` | Gemma reference top_k for `main`/`main-fast` (via `extra_body`; top_k is not a native OpenAI param). `0`/empty = off; inert at temperature 0 |
| `PRESET_ALIASES` | `1` | Expose the `main-fast` preset alias (same loaded model as `main`, thinking-off) |
| `ML_PUBLIC_PORT` / `ML_BACKEND_PORT` | `3003` / `13003` | immich-ml (optional) |
| `IMMICH_REPO` / `IMMICH_REPO_REF` | `sebastianfredette/immich-ml-metal` / `main` | immich-ml source repo + branch (override to use a fork) |
| `DOCLING_PUBLIC_PORT` / `DOCLING_BACKEND_PORT` | `5001` / `15001` | docling-serve (optional) |
| `IDLE_TIMEOUT_IMMICH` / `IDLE_TIMEOUT_DOCLING` | `900` | Idle-to-sleep seconds (`-1` = never) |
| `AUTOUPDATE_WEEKDAY` / `_HOUR` / `_MINUTE` | `6` / `6` / `0` | Weekly schedule (Sat 06:00) |
| `NODE_EXPORTER_PORT` / `SILICON_EXPORTER_PORT` / `ONDEMAND_EXPORTER_PORT` | `9100` / `9101` / `9103` | Prometheus exporters (only if `INSTALL_EXPORTERS=1`) |
| `INSTALL_DOCLING` / `INSTALL_TUI` / `INSTALL_WATCHDOG` | `1` | Toggle optional pieces |
| `INSTALL_EXPORTERS` | `0` | Prometheus exporters — **off by default** |
| `INSTALL_VOICE` | `0` | Speech-to-Text (`stt`) + Text-to-Speech (`tts`) — **off by default** |
| `INSTALL_IMMICH` | `0` | Metal/ANE Immich-ML backend (:3003) — **off by default** (needs macOS 26 + a running Immich server) |
| `VOICE_PROJECT_DIR` | `/Users/mac/projects/macos-speech-server` | Where FluidAudio's `macos-speech-server` is cloned+built |
| `VOICESTT_PUBLIC_PORT` / `VOICESTT_BACKEND_PORT` | `5006` / `15006` | Speech-to-Text ports (proxy / backend) |
| `IDLE_TIMEOUT_VOICESTT` / `STARTUP_TIMEOUT_VOICESTT` | `900` / `60` | STT idle-to-sleep / wake-deadline seconds |
| `VOICETTS_PUBLIC_PORT` / `VOICETTS_BACKEND_PORT` | `5007` / `15007` | Text-to-Speech ports (proxy / backend) |
| `IDLE_TIMEOUT_VOICETTS` / `STARTUP_TIMEOUT_VOICETTS` | `900` / `60` | TTS idle-to-sleep / wake-deadline seconds |
| `VOICE_TTS_DEFAULT_VOICE` | `Katya (Enhanced)` | macOS voice `say` uses when a request omits one — **requires a one-time manual install**, see [INTEGRATIONS.md](INTEGRATIONS.md#open-webui) |
| `VOICE_WYOMING_PUBLIC_PORT` / `VOICE_WYOMING_BACKEND_PORT` | `10300` / `15008` | Home Assistant Wyoming-protocol voice pipeline ports (proxy / backend) — see [INTEGRATIONS.md](INTEGRATIONS.md#home-assistant-voice-assistant-wyoming) |
| `INSTALL_MQTT` | `0` | MQTT bridge → Home Assistant — **off by default** |
| `MQTT_HOST` / `MQTT_PORT` | `mqtt.home.arpa` / `1883` | Broker (empty host = bridge idles) |
| `MQTT_USER` / `MQTT_PASS` | _(empty)_ | Broker auth (plaintext in the 644 conf) |
| `MQTT_TOPIC_PREFIX` / `MQTT_DISCOVERY_PREFIX` | `macstudio` / `homeassistant` | Topic base / HA discovery prefix |
| `MQTT_PUBLISH_INTERVAL_SEC` | `10` | Telemetry cadence (updates polled every 6 h) |
| `WATCHDOG_PRESSURE_THRESHOLD` | `warn` | `warn` or `critical` |
| `AUTO_ACCEPT` | `0` | `1` = skip "press Enter" prompts in the TUI |

## Updating & version pinning

The weekly job updates **only the OS and brew system packages**; everything that
serves a model (`oMLX`, `litellm`, `immich-ml`, `docling`, and the model
weights) stays put until you change it on purpose (a floating auto-upgrade once
broke a loaded model).

- **See what's available** (read-only): `sudo bash setup.sh --check-updates`
  (or main-menu *Check for updates*). Shows the installed vs latest GitHub tag
  for oMLX (it isn't on PyPI), installed vs PyPI for `litellm`, `brew
  outdated`, and macOS updates.
- **Upgrade the engine on purpose:** set `OMLX_REPO_REF` (menu 4, or edit
  `macstudio.conf`) then `sudo bash setup.sh --apply`. The installer checks out
  that exact tag, reinstalls the venv, and restarts `com.local.omlx.main`. It's
  an isolated venv + pinned git checkout, so up/down-grades are clean and
  reversible.
- `litellm` stays at its built version; bump manually in the venv if ever needed
  (`<venv>/bin/pip install -U …`).

## Commands (installed to `/usr/local/bin`)

| Command | Purpose |
|---|---|
| `llm-status` | Live overview: memory, daemons, scheduled jobs |
| `llm-models` | Model & alias manager (download, pick main/embed/rerank, HF token) |
| `llm-restart [name\|all]` | Restart one or all services |
| `llm-update` | Run the weekly autoupdate job now |
| `llm-service-ctl wake\|sleep\|status images\|immich\|docling\|voicestt\|voicetts\|all` | Manual on-demand override |
| `llm-logs [name]` | `tail -F` a service log (`omlx-main`, `litellm`, `images-serve`, …) |
| `sudo mactop` / `sudo macmon` | Live Apple-Silicon TUIs |

To watch **what the model is doing right now** from the TUI: `sudo bash setup.sh`
→ *View logs* → type `f <n>` to **follow live** (Ctrl-C returns to the menu);
the `omlx-main.log` follow is filtered to request/completion lines. Or on the CLI:
`llm-logs omlx-main`.

## Web dashboard (browser control)

Open **`http://mac.home.arpa:8090`** and log in with the token from
`/usr/local/etc/macstudio.conf` (key `DASHBOARD_TOKEN` — printed once when
`--apply` generates it; `grep DASHBOARD_TOKEN /usr/local/etc/macstudio.conf`
shows it any time). Five views:

- **Übersicht** — status tiles (gateway, active models, RAM/GPU/swap/pressure)
  plus power / temperature / GPU / memory charts (~1 h history). The
  power/thermal charts need `INSTALL_EXPORTERS=1`; without it they say so.
- **Modelle** — full catalog management (same catalog as `llm-models`): **add**
  a new model by HF repo id (e.g. `mlx-community/…-OptiQ-4bit`) which appends a
  row and starts the download, **edit** any row's fields (repo, GB, context /
  `max_kv_size`, parsers, rating, notes, sampling), **remove** a catalog row,
  download with a live progress bar, activate per slot (main / embed /
  rerank; same validation incl. BROKEN refusal), delete local files,
  store the HF token. The GB column shows the real on-disk size once downloaded.
- **Dienste** — every active daemon with live state; restart / stop / wake.
- **Einstellungen** — every `macstudio.conf` key, grouped, with the same hints
  as the TUI; **Speichern** writes the conf, **Speichern & Anwenden** runs
  `setup.sh --apply` with a live log. The apply survives the dashboard
  restarting itself mid-run (jobs are detached processes) — the page reconnects
  automatically.
- **Logs** — live tail of any `/var/log/macstudio/*.log` with a text filter.

Long-running actions (apply, downloads, model switches) run **one at a time**;
a second request gets "Ein Vorgang läuft bereits" and the job banner links to
the running one. The API also works headless with the same token:

```bash
TOKEN=$(sudo sed -n "s/^DASHBOARD_TOKEN=//p" /usr/local/etc/macstudio.conf | tr -d "'")
curl -s -H "Authorization: Bearer $TOKEN" http://mac.home.arpa:8090/api/status
```

Rotate the token by clearing `DASHBOARD_TOKEN` (menu 4) and re-running
`--apply` — a new one is generated and every browser session is logged out.
Turn the dashboard off with `INSTALL_DASHBOARD=0` + `--apply`. Note it is
**LAN-only trust**: HTTP without TLS, like every other port on this box.

## Monitoring (opt-in: Prometheus → Grafana)

Set `INSTALL_EXPORTERS=1` (menu 2) to install the exporters, then scrape:

```yaml
scrape_configs:
  - job_name: mac-system
    static_configs: [{ targets: ['mac.home.arpa:9100'] }]
  - job_name: mac-silicon
    static_configs: [{ targets: ['mac.home.arpa:9101'] }]
  - job_name: mac-ondemand
    static_configs: [{ targets: ['mac.home.arpa:9103'] }]
```

Import dashboard **1860** (node_exporter) and `grafana/mac-llm-dashboard.json`
for the Apple-Silicon + on-demand panels.

## How on-demand works

The proxy plist always owns the public port (e.g. immich-ml :3003); the real
backend plist (`com.local.immich.ml`) is registered with
`KeepAlive=false, RunAtLoad=false` and stays stopped. On the
first TCP connection the proxy kickstarts the backend, polls its health endpoint,
then streams traffic. A 30 s loop stops the backend after `IDLE_TIMEOUT_*`
seconds of idle (set `-1` to keep it warm forever). Transparent to clients apart
from a short cold-start latency. (`main`/`embed`/`rerank` are NOT on-demand —
`com.local.omlx.main` is always-on and serves all three from one process.)

## File layout

```
<repo root>/
├── setup.sh            single TUI / --apply entry point
├── motd.txt            SSH-login banner template
├── models/catalog.tsv  model catalog seed
├── wrappers/           scripts plists execute (start-omlx-main, start-litellm, …)
├── bin/                user commands (llm-*)
├── daemons/            plist templates (@VAR@ substitution)
├── services/           proxy, exporters, watchdogs, autoupdate
├── grafana/            dashboard JSON
└── README.md
```

On the Mac after `--apply`:
```
/usr/local/bin/                 llm-status, llm-models, llm-restart, llm-update, llm-service-ctl, llm-logs
/usr/local/sbin/                set-iogpu-wired-limit.sh, weekly-autoupdate.sh
/usr/local/libexec/             wrappers + Python services
/usr/local/etc/macstudio.conf   config (source of truth)
/usr/local/etc/macstudio-models/catalog.tsv   live model catalog (TUI-managed)
/usr/local/etc/litellm.config.yaml            generated alias routing
/Users/mac/.macstudio-venvs/    omlx / litellm venvs
/Users/mac/.cache/huggingface/  downloaded models + HF token
/Library/LaunchDaemons/         com.local.*.plist
/var/log/macstudio/             per-service logs
```

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `llm-models` / `llm-status` say "setup.sh not found" | Old build — `git pull && sudo bash setup.sh --apply`. |
| `hf auth login` / `hf download` fail with help text | huggingface_hub ≥ 1.0 renamed the CLI to `hf`. `git pull && --apply`. |
| `main` flapping in `omlx-main.log` | No model downloaded yet, or `ALIAS_MAIN` points at a model that isn't `ok`. Run `llm-models` → `d` then `s`. |
| Short answer comes back empty from a reasoning model | The model spent the token budget thinking. Use the thinking-off `main-fast` alias. |
| Need image/vision input | The unified oMLX `main` is multimodal — send `image_url` straight to `main` (or `main-fast`), image **before** the text. For bulk document OCR into paperless, use the separate paperless-ocr service. |
| Download is slow / rate-limited | Set your HF token: `llm-models` → `t`. |
| `memory_pressure` reports `Warn` with a model loaded | Use a smaller model, lower `OMLX_MAX_CONTEXT_WINDOW`/`OMLX_MEMORY_GUARD_GB`, or `IOGPU_WIRED_LIMIT_MB` by 1024, via `setup.sh` menu 4. |
| Mac doesn't come back after reboot / power loss | **FileVault is ON** and no console operator. Use `sudo fdesetup authrestart` for planned reboots; never plain `sudo reboot` on a headless FileVault Mac. |
| `/var/macstudio/reboot-pending` exists | Weekly autoupdate needs a restart it refused to do (FileVault). Clear with `sudo fdesetup authrestart`. |

## Uninstalling

`sudo bash setup.sh` → menu 9. Removes every plist, wrapper, script, config and
log this tool installed — the daemons are `com.local.omlx.main`,
`com.local.litellm.proxy`,
`com.local.voicestt.{proxy,serve}`,
`com.local.voicetts.{proxy,serve}`, `com.local.voicewyoming.proxy`,
`com.local.immich.{proxy,ml}`,
`com.local.docling.{proxy,serve}`, `com.local.node.exporter`,
`com.local.silicon.exporter`, `com.local.ondemand.exporter`,
`com.local.llm.watchdog`,
`com.local.preventsleep`, `com.local.iogpu.wiredlimit`,
`com.local.weekly.autoupdate`, `com.local.mqtt.bridge`, `com.local.dashboard`,
`com.local.vncfilter`, `com.local.novnc` and `com.local.paperless.ocr`.
**Keeps** the Python venvs (`$VENV_DIR`), the oMLX git checkout
(`$OMLX_PROJECT_DIR`), the HuggingFace model cache, and (if Voice
was installed) the cloned+built `macos-speech-server` at `$VOICE_PROJECT_DIR` —
delete those by hand to reclaim disk.

## Credits / license

MIT.
