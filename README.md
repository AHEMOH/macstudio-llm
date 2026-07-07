# Mac Studio Headless LLM Server

Headless Apple Silicon Mac as an **MLX inference server**: **one unified
multimodal model permanently warm** — by default **gemma-4-26b on `mlx_vlm.server`**,
which handles **text *and* images in the same chat** plus tool calling, with KV-cache
quantization — a **LiteLLM gateway** that gives apps stable aliases, and an on-demand
**BGE embeddings + reranker** pair (for RAG). Plus optional companion services (image AI,
document conversion) that sleep when idle and wake on first request. Runs fully
unattended: no GUI, no login, auto-restart on power loss, weekly self-update.

Designed for a 32 GB M1 Max but scales unchanged to bigger Apple Silicon — just
raise a couple of config keys.

> **Text engine — mlx-vlm.** The always-on text backend is Apple mlx-vlm's
> `mlx_vlm.server` (pinned `MLXVLM_VERSION=0.6.3`), serving **one unified multimodal
> model** that handles **text *and* images in the same chat** plus tool calling, with
> KV-cache quantization (bigger context on 32 GB). The default main is `gemma4-26b-qat`
> (verified: `gemma4-{26b,12b,e4b,e2b}-qat`, text+tools+vision, vision 4/4). Only **one
> big model** is in memory (the small BGE embed/rerank pair is the only on-demand
> extra).

## What this gives you

- **`mlx_vlm.server`** always on (internal :18000): **one** unified multimodal
  model that does **text *and* images in the same chat** plus tool calling, with
  **KV-cache quantization** (`MLXVLM_MAIN_KV_BITS`/`_KV_SCHEME`) and a context/OOM
  cap (`MLXVLM_MAIN_MAX_KV_SIZE`). Reasoning is on by default
  (`MLXVLM_MAIN_ENABLE_THINKING`); tool calling is auto-detected from the model's
  chat template. Version pinned via `MLXVLM_VERSION` (0.6.3).
- **LiteLLM gateway** on the public port (:11434): apps talk OpenAI `/v1` (and
  Anthropic `/v1/messages`) to the stable aliases — `main` (text + images, reasons by
  default), `main-fast` (same model, thinking-off), `embed` (BGE-M3 embeddings)
  and `rerank` (BGE reranker). The underlying model is swappable without the app
  noticing.
- **Embeddings + rerank** (opt-in `INSTALL_EMBED=1`, on by default): **BAAI/bge-m3**
  (1024-dim multilingual dense embeddings, `embed` alias) + **BAAI/bge-reranker-v2-m3**
  (cross-encoder, `rerank` alias) served together by **Infinity** in one Torch-MPS
  process, on-demand on :5004. Both small (~2 GB each) — they are the only on-demand
  extra that co-resides with the big main. Reachable via LiteLLM `/v1/embeddings` and
  `/v1/rerank`.
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
  `mlx-vlm` is pinned via `MLXVLM_VERSION`, and `litellm`/models are never
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
  com.local.mlxvlm.main            :18000   the ONE unified multimodal main (mlx_vlm.server)
  com.local.infinity.proxy         :5004    on-demand proxy for embed + rerank (Infinity)
  com.local.immich.proxy           :3003    on-demand proxy (optional)
  com.local.docling.proxy          :5001    on-demand proxy (optional)
  com.local.llm.watchdog                    memory-pressure safety net
  com.local.preventsleep                    caffeinate

Registered but sleeping until requested:
  com.local.infinity.serve         :15004   Infinity embed + rerank backend (Torch MPS)
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
`llm-models` → `mlx_vlm.server` restarts, ~30–60 s) — never a silent hot-swap.

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
builds the MLX venvs (`mlxvlm`, `litellm`).

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
`s`, `mlx_vlm.server` restarts and loads the model.

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

Tool calling and reasoning separation are automatic on `mlx_vlm.server` (per the
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
| `s <id>` | Set as the active **text/main** model (role=text only) → `mlx_vlm.server` restarts |
| `m <id>` / `k <id>` | Set the active **embed** / **rerank** model |
| `a` / `e <id>` / `x <id>` | Add / edit / remove a catalog entry |
| `r <id>` | Delete the locally-downloaded files |
| `t` | Store/clear your **HuggingFace token** (`hf auth login`) |
| `q` | Back |

Per-model columns the catalog carries: `role`, `engine`, `quant`, `gb`,
`gated`, `reasoning_parser`, `tool_parser`, `max_kv_size`, `max_num_seqs`,
`rating`, `notes`, sampling defaults. `mlx_vlm.server` auto-detects reasoning and
the tool parser from the model, so those columns are informational. A model is
refused for a slot when its `notes` carry a `BROKEN` flag (or `BROKEN[<engine>]`
for the engine that slot runs).

**Per-model sampling** (temperature/top_p/…) defaults are injected into the
LiteLLM `main` alias; clients can override per request. `main`/`main-fast` use
Gemma's reference sampling (temp 1.0 / top_p 0.95 from the catalog + `top_k`=`GEMMA_TOP_K`
via `extra_body`). The generation ceiling for `main` is `MLXVLM_MAX_TOKENS`.

**HuggingFace token:** set it via `llm-models` → `t`. It is stored in the user's
HF cache (`$HF_CACHE_DIR/.../token`, mode 600) — **never** in `macstudio.conf`
or git. Needed for gated repos (e.g. Gemma) and for higher download rate limits.

Seeded models — intentionally **lean** (QAT Gemma-4 unified mains + the
BGE embed/rerank pair). Add more via `llm-models`:

| id | role | ~GB | notes |
|---|---|---|---|
| `gemma4-26b-qat` | text | 16 | **default main** — QAT 26B-A4B MoE on mlx-vlm, unified text+images+tools, KV-quant (~32 tok/s); German (**gated**) |
| `gemma4-12b-qat` / `-e4b-qat` / `-e2b-qat` | text | 8 / 4 / 3 | QAT variants on mlx-vlm — multimodal, faster/smaller; **gated** |
| `bge-m3` | embed | 2 | **default embed** — 1024-dim multilingual dense embeddings (Infinity) |
| `bge-reranker-v2-m3` | rerank | 2 | **default rerank** — cross-encoder reranker (Infinity) |

All Gemma-4 rows are multimodal text+images — **none support audio**.

## Prerequisites installed automatically

`setup.sh --apply` installs these on first run (hash/presence-checked, no-op if
present):

| Prerequisite | How | When |
|---|---|---|
| **Xcode Command Line Tools** | `softwareupdate -i` (headless) | unless present |
| **Homebrew** | official installer, `NONINTERACTIVE=1`, as `TARGET_USER` | if absent |
| **python@3.12** | `brew install python@3.12` (MLX/docling wheels need ≥3.10) | if `INSTALL_MLX=1`, `INSTALL_EMBED=1` or `INSTALL_DOCLING=1` |
| **mlxvlm venv** | `pip install mlx-vlm==$MLXVLM_VERSION huggingface_hub[cli]` in `$VENV_DIR/mlxvlm` | if `INSTALL_MLX=1` |
| **litellm venv** | `pip install 'litellm[proxy]'` in `$VENV_DIR/litellm` | if `INSTALL_MLX=1` |
| **infinity venv** | `pip install 'infinity-emb[all]' huggingface_hub[cli]` in `$VENV_DIR/infinity` | if `INSTALL_EMBED=1` |
| **node_exporter** | `brew install node_exporter` | if `INSTALL_EXPORTERS=1` (off by default) |
| **mactop + macmon** | `brew install mactop macmon` | if `INSTALL_TUI=1` |
| **docling-serve venv** | `pip install 'docling[…]' 'docling-serve[ui]'` | if `INSTALL_DOCLING=1` |

The **immich-ml venv** is the only thing not auto-built (needs your fork in
`IMMICH_PROJECT_DIR`); the script prints the command to finish it.

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

**Memory note (32 GB):** `mlx_vlm.server` quantizes the KV cache
(`MLXVLM_MAIN_KV_BITS`, default 8-bit) and caps context with
`MLXVLM_MAIN_MAX_KV_SIZE` (default 65536) as an OOM guard. Only **one** big model
fits, so the BGE embed/rerank pair (~2 GB each) co-resides as the small on-demand
extra; a second big model does not fit.

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
| `INSTALL_MLX` | `1` | The MLX stack (mlx_vlm.server + LiteLLM gateway) — primary backend |
| `VENV_DIR` | `/Users/mac/.macstudio-venvs` | Where the mlxvlm/litellm venvs live |
| `HF_CACHE_DIR` | `/Users/mac/.cache/huggingface` | HF model cache (`HF_HOME`) + token store |
| `ALIAS_MAIN` | `gemma4-26b-qat` | Catalog id of the active unified text+images main (a VLM arch like gemma-4) |
| `ALIAS_EMBED` | `bge-m3` | Catalog id of the on-demand embedder (Infinity, alias `embed`). Empty = no embed alias |
| `ALIAS_RERANK` | `bge-reranker-v2-m3` | Catalog id of the on-demand reranker (Infinity, alias `rerank`). Empty = no rerank alias |
| `MODEL_PIN_MAIN` | `1` | Keep the main model permanently warm |
| `LITELLM_PORT` | `11434` | Public gateway port (apps use this) |
| `MAIN_BACKEND_PORT` | `18000` | Internal port `mlx_vlm.server` binds |
| `MAIN_MAX_NUM_SEQS` | `4` | Max concurrent sequences for the main backend |
| `LLM_REQUEST_TIMEOUT` | `3600` | Per-request timeout (s) for the text engine **and** LiteLLM; long docs/OCR |
| `TEXT_ENGINE` | `mlx-vlm` | The text engine (`mlx_vlm.server`) — one unified multimodal main (text+images+tools, KV-quant) |
| `MLXVLM_VERSION` | `0.6.3` | Pinned mlx-vlm for the `mlxvlm` venv (the text engine) |
| `MLXVLM_MAX_TOKENS` | `16384` | mlx-vlm default `--max-tokens` = generation ceiling for `main`. The preset aliases use their own caps |
| `MLXVLM_MAIN_KV_BITS` / `_KV_SCHEME` | `8` / `uniform` | KV-quant for the mlx-vlm unified main (`turboquant` for fractional bits) |
| `MLXVLM_MAIN_MAX_KV_SIZE` | `65536` | mlx-vlm main context/OOM cap (`--max-kv-size`); raise to exploit KV-quant for big context |
| `MLXVLM_MAIN_ENABLE_THINKING` | `1` | mlx-vlm main thinks by default (so `main` reasons). `main-fast` is forced thinking-off at the proxy; clients can override per request |
| `MLXVLM_DRAFT_MODEL` / `_KIND` / `_BLOCK_SIZE` | _(empty)_ | Optional MTP speculative-decoding drafter (`--draft-model`/`--draft-kind`); empty = **off** (helps only bigger dense/MoE mains; broken on e2b/e4b) |
| `GEMMA_TOP_K` | `64` | Gemma reference top_k for `main`/`main-fast` (via `extra_body`; top_k is not a native OpenAI param). `0`/empty = off; inert at temperature 0 |
| `PRESET_ALIASES` | `1` | Expose the `main-fast` preset alias (same loaded model as `main`, thinking-off) |
| `INFINITY_PUBLIC_PORT` | `5004` | Public embed/rerank port (proxy) |
| `INFINITY_BACKEND_PORT` | `15004` | Internal Infinity backend port |
| `IDLE_TIMEOUT_INFINITY` | `900` | Seconds before the embed/rerank backend sleeps; **`-1` = never** |
| `STARTUP_TIMEOUT_INFINITY` | `180` | Infinity wake-up deadline (Torch/MPS load) |
| `INFINITY_DEVICE` | `mps` | Infinity compute device (`mps` Apple GPU \| `cpu`) |
| `INFINITY_DTYPE` | `float16` | Infinity model precision (`float16` ~half the RAM \| `float32`) |
| `INFINITY_BATCH_SIZE` | `4` | Infinity max batch size (single-user default; raise for parallel load) |
| `ML_PUBLIC_PORT` / `ML_BACKEND_PORT` | `3003` / `13003` | immich-ml (optional) |
| `DOCLING_PUBLIC_PORT` / `DOCLING_BACKEND_PORT` | `5001` / `15001` | docling-serve (optional) |
| `IDLE_TIMEOUT_IMMICH` / `IDLE_TIMEOUT_DOCLING` | `900` | Idle-to-sleep seconds (`-1` = never) |
| `AUTOUPDATE_WEEKDAY` / `_HOUR` / `_MINUTE` | `6` / `6` / `0` | Weekly schedule (Sat 06:00) |
| `NODE_EXPORTER_PORT` / `SILICON_EXPORTER_PORT` / `ONDEMAND_EXPORTER_PORT` | `9100` / `9101` / `9103` | Prometheus exporters (only if `INSTALL_EXPORTERS=1`) |
| `INSTALL_IMMICH` / `INSTALL_DOCLING` / `INSTALL_TUI` / `INSTALL_WATCHDOG` | `1` | Toggle optional pieces |
| `INSTALL_EXPORTERS` | `0` | Prometheus exporters — **off by default** |
| `INSTALL_EMBED` | `1` | BGE embeddings + reranker via Infinity (`embed`/`rerank` aliases) — on by default |
| `INSTALL_MQTT` | `0` | MQTT bridge → Home Assistant — **off by default** |
| `MQTT_HOST` / `MQTT_PORT` | `mqtt.home.arpa` / `1883` | Broker (empty host = bridge idles) |
| `MQTT_USER` / `MQTT_PASS` | _(empty)_ | Broker auth (plaintext in the 644 conf) |
| `MQTT_TOPIC_PREFIX` / `MQTT_DISCOVERY_PREFIX` | `macstudio` / `homeassistant` | Topic base / HA discovery prefix |
| `MQTT_PUBLISH_INTERVAL_SEC` | `10` | Telemetry cadence (updates polled every 6 h) |
| `WATCHDOG_PRESSURE_THRESHOLD` | `warn` | `warn` or `critical` |
| `AUTO_ACCEPT` | `0` | `1` = skip "press Enter" prompts in the TUI |

## Updating & version pinning

The weekly job updates **only the OS and brew system packages**; everything that
serves a model (`mlx-vlm`, `litellm`, `immich-ml`, `docling`, and the model
weights) stays put until you change it on purpose (a floating auto-upgrade once
broke a loaded model).

- **See what's available** (read-only): `sudo bash setup.sh --check-updates`
  (or main-menu *Check for updates*). Shows installed vs PyPI (stable + newest
  incl. pre-release) for the LLM stack, `brew outdated`, and macOS updates.
- **Upgrade the text engine on purpose:** set `MLXVLM_VERSION` (menu 4, or edit
  `macstudio.conf`) then `sudo bash setup.sh --apply`. The installer reinstalls
  that exact version and restarts `mlx_vlm.server`. It's an isolated venv, so
  up/down-grades are clean and reversible.
- `litellm` stays at its built version; bump manually in the venv if ever needed
  (`<venv>/bin/pip install -U …`).

## Commands (installed to `/usr/local/bin`)

| Command | Purpose |
|---|---|
| `llm-status` | Live overview: memory, daemons, scheduled jobs |
| `llm-models` | Model & alias manager (download, pick main/embed/rerank, HF token) |
| `llm-restart [name\|all]` | Restart one or all services |
| `llm-update` | Run the weekly autoupdate job now |
| `llm-service-ctl wake\|sleep\|status infinity\|immich\|docling\|all` | Manual on-demand override |
| `llm-logs [name]` | `tail -F` a service log (`mlxvlm-main`, `litellm`, `infinity-serve`, …) |
| `sudo mactop` / `sudo macmon` | Live Apple-Silicon TUIs |

To watch **what the model is doing right now** from the TUI: `sudo bash setup.sh`
→ *View logs* → type `f <n>` to **follow live** (Ctrl-C returns to the menu);
the `mlxvlm-main.log` follow is filtered to request/completion lines. Or on the CLI:
`llm-logs mlxvlm-main`.

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

The proxy plist always owns the public port (e.g. Infinity :5004); the real
backend plist (`com.local.infinity.serve`) is registered with
`KeepAlive=false, RunAtLoad=false` and stays stopped. On the
first TCP connection the proxy kickstarts the backend, polls its health endpoint,
then streams traffic. A 30 s loop stops the backend after `IDLE_TIMEOUT_*`
seconds of idle (set `-1` to keep it warm forever). Transparent to clients apart
from a short cold-start latency.

## File layout

```
<repo root>/
├── setup.sh            single TUI / --apply entry point
├── motd.txt            SSH-login banner template
├── models/catalog.tsv  model catalog seed
├── wrappers/           scripts plists execute (start-mlxvlm-main, start-litellm, start-infinity, …)
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
/Users/mac/.macstudio-venvs/    mlxvlm / litellm venvs
/Users/mac/.cache/huggingface/  downloaded models + HF token
/Library/LaunchDaemons/         com.local.*.plist
/var/log/macstudio/             per-service logs
```

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `llm-models` / `llm-status` say "setup.sh not found" | Old build — `git pull && sudo bash setup.sh --apply`. |
| `hf auth login` / `hf download` fail with help text | huggingface_hub ≥ 1.0 renamed the CLI to `hf`. `git pull && --apply`. |
| `main` flapping in `mlxvlm-main.log` | No model downloaded yet, or `ALIAS_MAIN` points at a model that isn't `ok`. Run `llm-models` → `d` then `s`. |
| Short answer comes back empty from a reasoning model | The model spent the token budget thinking. Raise `MLXVLM_MAX_TOKENS` or use the thinking-off `main-fast` alias. |
| Need image/vision input | The unified mlx-vlm `main` is multimodal — send `image_url` straight to `main` (or `main-fast`), image **before** the text. For bulk document OCR into paperless, use the separate paperless-ocr service. |
| Download is slow / rate-limited | Set your HF token: `llm-models` → `t`. |
| `memory_pressure` reports `Warn` with a model loaded | Use a smaller model, lower `MLXVLM_MAIN_MAX_KV_SIZE`, or `IOGPU_WIRED_LIMIT_MB` by 1024, via `setup.sh` menu 4. |
| Mac doesn't come back after reboot / power loss | **FileVault is ON** and no console operator. Use `sudo fdesetup authrestart` for planned reboots; never plain `sudo reboot` on a headless FileVault Mac. |
| `/var/macstudio/reboot-pending` exists | Weekly autoupdate needs a restart it refused to do (FileVault). Clear with `sudo fdesetup authrestart`. |

## Uninstalling

`sudo bash setup.sh` → menu 9. Removes every plist, wrapper, script, config and
log this tool installed — the daemons are `com.local.mlxvlm.main`,
`com.local.litellm.proxy`,
`com.local.infinity.{proxy,serve}`, `com.local.immich.{proxy,ml}`,
`com.local.docling.{proxy,serve}`, `com.local.node.exporter`,
`com.local.silicon.exporter`, `com.local.ondemand.exporter`,
`com.local.llm.watchdog`,
`com.local.preventsleep`, `com.local.iogpu.wiredlimit`,
`com.local.weekly.autoupdate`, `com.local.mqtt.bridge`, `com.local.dashboard`,
`com.local.vncfilter`, `com.local.novnc` and `com.local.paperless.ocr`.
**Keeps** the Python venvs (`$VENV_DIR`) and the HuggingFace model cache — delete
those by hand to reclaim disk.

## Credits / license

MIT.
