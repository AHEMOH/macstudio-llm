# Mac Studio Headless LLM Server

Headless Apple Silicon Mac as a **vLLM-style MLX inference server**: one big
text model permanently warm via **`vllm-mlx`** (continuous batching, paged KV
cache, large context), a **LiteLLM gateway** that gives apps stable aliases, and
an on-demand **GLM-OCR** vision model — plus optional companion services (image
AI, document conversion) that sleep when idle and wake on first request. Runs
fully unattended: no GUI, no login, auto-restart on power loss, weekly
self-update.

Designed for a 32 GB M1 Max but scales unchanged to bigger Apple Silicon — just
raise a couple of config keys.

> **Why not Ollama?** Ollama bakes context length into the model load (every
> `num_ctx` change = a 30–60 s reload) and has weaker concurrency. `vllm-mlx`
> allocates KV per request (no reload when a prompt is longer/shorter) and
> batches parallel requests. Ollama is still shipped here as an **opt-in
> fallback** (`INSTALL_OLLAMA=1`), off by default.

## What this gives you

- **`vllm-mlx`** always on (internal :18000): **one** text model, continuous
  batching, **paged KV cache** (no reload on context change), **prefix cache**
  (big win for repeated system prompts, e.g. document pipelines), per-model
  **reasoning/tool-call parsers**, and **8-bit KV quantization** so a 128K
  context fits comfortably.
- **LiteLLM gateway** on the public port (:11434): apps talk OpenAI `/v1` (and
  Anthropic `/v1/messages`) to **stable aliases** — `main` (text) and `ocr`.
  The underlying model is swappable without the app noticing.
- **GLM-OCR** (0.9 B, ~2 GB) on-demand on :5002 via `mlx-vlm` — the only model
  allowed to run alongside the big main model. #1 on OmniDocBench.
- **Model catalog + `llm-models` TUI**: download pre-converted MLX models from
  HuggingFace, pick which one is the active text/ocr model, manage your HF
  token. Only fully-downloaded models become selectable.
- **30 GB GPU wired memory limit** (on a 32 GB box) + OS trim → nearly the whole
  machine is available to the model. KV math keeps it swap-free.
- **On-demand companions** on :3003 (immich-ml) and :5001 (docling-serve),
  optional — public ports always listen; the real backend wakes on request and
  sleeps after 15 min, freeing RAM.
- **Weekly auto-update** (Sat 06:00): **OS + brew system packages only**
  (`brew update`, `node_exporter`, macOS security updates). The model/LLM stack
  is **frozen** — `vllm-mlx` (alpha) is pinned via `VLLM_MLX_VERSION`, and
  `mlx-vlm`/`litellm`/Ollama/models are never auto-upgraded (a surprise version
  jump once broke a model). The run logs which LLM versions are available but
  held. Bump them deliberately via **Check for updates** → set the pin →
  Install/update.
- **Prometheus exporters** for Grafana: node_exporter (:9100), Apple-Silicon
  metrics (:9101), on-demand stack state (:9103). vllm-mlx and LiteLLM expose
  their own `/metrics`.
- **Watchdogs**: a memory-pressure safety net (offloads optional services,
  keeps the main model healthy) and an Ollama-only inference-stall killer
  (idle unless `INSTALL_OLLAMA=1`).
- **One script** (`setup.sh`): install, update, settings, **model manager**,
  service control, clean-up, uninstall. TUI by default, `--apply` for
  non-interactive runs. Idempotent — re-run safely any time.

## Architecture

```
Public (apps point here):
  com.local.litellm.proxy          :11434   LiteLLM gateway — aliases main / ocr
                                             (OpenAI /v1 + Anthropic /v1/messages)
Always on (internal / support):
  com.local.vllm.mlx               :18000   vllm-mlx — the ONE text model
  com.local.glmocr.proxy           :5002    on-demand proxy for GLM-OCR
  com.local.immich.proxy           :3003    on-demand proxy (optional)
  com.local.docling.proxy          :5001    on-demand proxy (optional)
  com.local.node.exporter          :9100    Prometheus system metrics
  com.local.silicon.exporter       :9101    GPU / power / thermal / mem-pressure
  com.local.ondemand.exporter      :9103    on-demand backend + proxy liveness
  com.local.llm.watchdog                    memory-pressure safety net
  com.local.inference.watchdog              Ollama stall killer (idle w/o Ollama)
  com.local.preventsleep                    caffeinate

Registered but sleeping until requested:
  com.local.glmocr.serve           :15002   GLM-OCR backend (mlx-vlm)
  com.local.immich.ml              :13003   immich-ml backend (optional)
  com.local.docling.serve          :15001   docling-serve backend (optional)

One-shot at boot:
  com.local.iogpu.wiredlimit                sets iogpu.wired_limit_mb
Scheduled (Sat 06:00 default):
  com.local.weekly.autoupdate               brew + venv pip + model refresh + softwareupdate

Opt-in only (INSTALL_OLLAMA=1, off by default):
  com.local.ollama.headless        :11434   Ollama (collides with LiteLLM — see note)
  com.local.ollama.exporter        :9102     Ollama /api/ps exporter
```

The main model is kept warm; switching it is an **explicit** action (pick in
`llm-models` → vllm-mlx restarts, ~30–60 s) — never a silent hot-swap.

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
builds the three MLX venvs (`vllm-mlx`, `litellm`, `mlx-vlm`).

```bash
# SSH into the Mac, then (one-time CLT bootstrap so `git clone` works):
sudo softwareupdate -i "$(softwareupdate -l 2>/dev/null \
  | awk -F'Label: ' '/Command Line Tools for Xcode/ {print $2; exit}' \
  | sed 's/ *$//')" --verbose

cd ~
git clone https://github.com/<you>/macstudio-llm.git
cd macstudio-llm

sudo bash setup.sh            # interactive TUI (recommended first run)
# …or non-interactive (installs CLT, Homebrew, python@3.12, the 3 MLX venvs):
sudo bash setup.sh --apply
```

The first `--apply` builds the venvs (several minutes of pip wheels). It does
**not** download any model — that's an explicit step next.

### 4. Download a model and pick it

```bash
llm-models                    # opens the model & alias manager
#   t                         → paste your HuggingFace token (for gated repos + speed)
#   d qwen36-35b-a3b          → download the default text model (~20 GB, live progress)
#   s qwen36-35b-a3b          → set it as the active 'main' (text) model
#   d glm-ocr                 → download GLM-OCR (~2 GB)
#   o glm-ocr                 → set it as the active 'ocr' model
#   q                         → back
```

Only `STATUS=ok` (fully downloaded + verified) models are selectable. After
`s`, vllm-mlx restarts and loads the model.

### 5. Use it

Apps point at the **LiteLLM gateway on :11434** and address the **alias**, never
the real model id:

```bash
# OpenAI-style chat
curl http://mac.home.arpa:11434/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"main","messages":[{"role":"user","content":"Hallo!"}]}'

# OCR (wakes GLM-OCR on demand)
curl http://mac.home.arpa:11434/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"ocr","messages":[{"role":"user","content":[
        {"type":"text","text":"Extract the text"},
        {"type":"image_url","image_url":{"url":"data:image/png;base64,..."}}]}]}'
```

Tool calling and (for tag-emitting models) reasoning separation are enabled per
model via the catalog — see [Model catalog](#model-catalog--the-llm-models-tui).

### 6. Update later

```bash
cd ~/macstudio-llm && git pull && sudo bash setup.sh --apply
```

Or let the weekly job do brew + venv + model + macOS updates automatically.

## Model catalog & the `llm-models` TUI

The catalog (`models/catalog.tsv`, seeded once to
`/usr/local/etc/macstudio-models/catalog.tsv`) lists **pre-converted MLX models
on HuggingFace** — there is **no local conversion**. Source is always
HuggingFace; entries are repo-ids (`org/name`), not URLs.

Two roles are selectable: **`text`** (served by vllm-mlx as alias `main`) and
**`ocr`** (served by mlx-vlm as alias `ocr`, on-demand).

`llm-models` actions:

| Key | Action |
|---|---|
| `d <id>` | **Download** the repo from HuggingFace (live progress), then verify |
| `s <id>` | Set as the active **text/main** model (role=text only) → vllm-mlx restarts |
| `o <id>` | Set as the active **ocr** model (role=ocr only) |
| `a` / `e <id>` / `x <id>` | Add / edit / remove a catalog entry |
| `r <id>` | Delete the locally-downloaded files |
| `t` | Store/clear your **HuggingFace token** (`hf auth login`) |
| `q` | Back |

Per-model columns the catalog carries: `role`, `engine`, `quant`, `gb`,
`gated`, `reasoning_parser`, `tool_parser`, `max_kv_size`, `max_num_seqs`,
`rating`, `notes`. Parsers/overrides apply only to text models and are passed
straight to `vllm-mlx serve`.

**Engines:** `vllm` (text), `vllm-mllm` (text **+** vision/audio — adds `--mllm`,
e.g. Gemma 4), `mlxvlm` (the on-demand OCR role). The `a`/`e` TUI actions ask
"multimodal?" for text models to pick `vllm` vs `vllm-mllm`.

**Per-model tuning:** `max_num_seqs` is set per model by footprint (big models
2, small ones up to 8); excess parallel requests queue. `max_kv_size` is left
empty = the global 128K (set per row only for a model whose native context is
< 128K). The **KV cache pool is auto-sized per active model** by
`start-vllm.sh`: `pool = IOGPU_WIRED_LIMIT_MB − model_gb − VLLM_CACHE_RESERVE_MB`
— so an 8 GB model automatically gets a big pool (lots of context/concurrency)
and a 20 GB model a small one, with no manual per-model knob. Pin it explicitly
with `VLLM_CACHE_MEMORY_MB` if you ever need to.

**HuggingFace token:** set it via `llm-models` → `t`. It is stored in the user's
HF cache (`$HF_CACHE_DIR/.../token`, mode 600) — **never** in `macstudio.conf`
or git. Needed for gated repos (e.g. Gemma) and for higher download rate limits.

Seeded models (all verified to exist as ready MLX builds):

| id | role | ~GB | notes |
|---|---|---|---|
| `qwen36-35b-a3b` | text | 20 | **default main** — agentic, multilingual, MoE (fast), tiny KV |
| `laguna-xs2` | text | 22 | agentic + long-horizon, 128K (mxfp4 — confirm FP4 support) |
| `gemma4-31b` | text | 18 | German + multimodal, `vllm-mllm` (**gated**) |
| `gemma4-26b` | text | 16 | Gemma 4 26B-A4B MoE, multimodal, fast (**gated**) |
| `gemma4-12b` | text | 8 | Gemma 4 12B, multimodal, lots of headroom for OCR (**gated**) |
| `granite41-30b` | text | 17 | enterprise/RAG (mxfp4) |
| `glm47-flash` | text | 19 | strong coding |
| `qwen36-27b` | text | 16 | dense alternative |
| `gptoss-20b` | text | 13 | small → more headroom; emits parseable reasoning |
| `lfm25-8b` | text | 5 | very fast — pre-classification / routing |
| `qwen35-9b-vl` | ocr | 9 | vision-language alternative to GLM-OCR |
| `glm-ocr` | ocr | 2 | **default ocr**, on-demand, #1 OmniDocBench |

## Prerequisites installed automatically

`setup.sh --apply` installs these on first run (hash/presence-checked, no-op if
present):

| Prerequisite | How | When |
|---|---|---|
| **Xcode Command Line Tools** | `softwareupdate -i` (headless) | unless present |
| **Homebrew** | official installer, `NONINTERACTIVE=1`, as `TARGET_USER` | if absent |
| **python@3.12** | `brew install python@3.12` (MLX/docling wheels need ≥3.10) | if `INSTALL_MLX=1` or `INSTALL_DOCLING=1` |
| **vllm venv** | `pip install vllm-mlx huggingface_hub[cli]` in `$VENV_DIR/vllm` | if `INSTALL_MLX=1` |
| **litellm venv** | `pip install 'litellm[proxy]'` in `$VENV_DIR/litellm` | if `INSTALL_MLX=1` |
| **mlxvlm venv** | `pip install mlx-vlm huggingface_hub[cli]` in `$VENV_DIR/mlxvlm` | if `INSTALL_MLX=1` |
| **node_exporter** | `brew install node_exporter` | if `INSTALL_EXPORTERS=1` |
| **mactop + macmon** | `brew install mactop macmon` | if `INSTALL_TUI=1` |
| **docling-serve venv** | `pip install 'docling[…]' 'docling-serve[ui]'` | if `INSTALL_DOCLING=1` |
| **ollama** | `brew install ollama` | only if `INSTALL_OLLAMA=1` |

The **immich-ml venv** is the only thing not auto-built (needs your fork in
`IMMICH_PROJECT_DIR`); the script prints the command to finish it.

## Hardware assumptions

- **Apple Silicon** (M1–M5, any variant).
- **32 GB+ unified RAM** for the default 20 GB main model. Default
  `IOGPU_WIRED_LIMIT_MB=30720` (30 GB) assumes 32 GB.
- **macOS 13.4+** (for `iogpu.wired_limit_mb`); tested on macOS 26.

| Total RAM | `IOGPU_WIRED_LIMIT_MB` | OS headroom |
|-----------|------------------------|-------------|
| 32 GB     | **30720** (default)    | 2 GB        |
| 64 GB     | 61440                  | 4 GB        |
| 96 GB     | 92160                  | 6 GB        |
| 192 GB    | 184320                 | 12 GB       |

**KV-cache math (why 128K fits on 32 GB):** the default model has tiny KV (2 KV
heads, 40 layers) → ~40 KiB/token at 8-bit. 128K context ≈ 5 GB KV + ~19 GB
weights = ~24 GB, well under the 30 GB wired limit with room for on-demand OCR.
256K would need 4-bit KV to stay swap-free — both are one config change
(`VLLM_MAX_MODEL_LEN`, `VLLM_KV_BITS`).

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
2) Select services to install…   (MLX / Ollama / immich / docling / exporters / watchdog)
3) Models & aliases…             (download MLX models, pick main / ocr)
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
| `INSTALL_MLX` | `1` | The MLX stack (vllm-mlx + LiteLLM + GLM-OCR) — primary backend |
| `INSTALL_OLLAMA` | `0` | Opt-in Ollama fallback (kept in repo, off by default) |
| `VENV_DIR` | `/Users/mac/.macstudio-venvs` | Where the vllm/litellm/mlxvlm venvs live |
| `HF_CACHE_DIR` | `/Users/mac/.cache/huggingface` | HF model cache (`HF_HOME`) + token store |
| `VLLM_MLX_VERSION` | `0.3.0` | Pinned vllm-mlx version (alpha pkg). Bump deliberately + `--apply`; empty = latest |
| `ALIAS_MAIN` | `qwen36-35b-a3b` | Catalog id of the active text model |
| `ALIAS_OCR` | `glm-ocr` | Catalog id of the on-demand OCR model |
| `MODEL_PIN_MAIN` | `1` | Keep the main model permanently warm |
| `LITELLM_PORT` | `11434` | Public gateway port (apps use this) |
| `VLLM_BACKEND_PORT` | `18000` | Internal vllm-mlx port |
| `VLLM_MAX_MODEL_LEN` | `131072` | `--max-kv-size`: max context tokens (128K) |
| `VLLM_MAX_NUM_SEQS` | `4` | Max concurrent sequences (excess requests queue) |
| `VLLM_KV_BITS` | `8` | KV-cache quantization bits (8/4; `0`/empty = off) |
| `VLLM_CACHE_MEMORY_MB` | _(empty)_ | KV cache pool size; empty = auto (wired − model_gb − reserve) |
| `VLLM_CACHE_RESERVE_MB` | `4096` | RAM the auto pool leaves free for OS + on-demand GLM-OCR |
| `LLM_REQUEST_TIMEOUT` | `1200` | Per-request timeout (s) for vllm-mlx **and** LiteLLM; 20 min for long docs/OCR |
| `GLMOCR_PUBLIC_PORT` | `5002` | Public GLM-OCR port (proxy) |
| `GLMOCR_BACKEND_PORT` | `15002` | Internal GLM-OCR backend port |
| `IDLE_TIMEOUT_GLMOCR` | `900` | Seconds before GLM-OCR sleeps; **`-1` = never sleep** |
| `STARTUP_TIMEOUT_GLMOCR` | `120` | GLM-OCR wake-up deadline |
| `ML_PUBLIC_PORT` / `ML_BACKEND_PORT` | `3003` / `13003` | immich-ml (optional) |
| `DOCLING_PUBLIC_PORT` / `DOCLING_BACKEND_PORT` | `5001` / `15001` | docling-serve (optional) |
| `IDLE_TIMEOUT_IMMICH` / `IDLE_TIMEOUT_DOCLING` | `900` | Idle-to-sleep seconds (`-1` = never) |
| `AUTOUPDATE_WEEKDAY` / `_HOUR` / `_MINUTE` | `6` / `6` / `0` | Weekly schedule (Sat 06:00) |
| `NODE_EXPORTER_PORT` | `9100` | Prometheus node_exporter |
| `SILICON_EXPORTER_PORT` | `9101` | GPU/power/thermal exporter |
| `ONDEMAND_EXPORTER_PORT` | `9103` | On-demand backend/proxy/watchdog exporter |
| `OLLAMA_*` | — | Only used when `INSTALL_OLLAMA=1` |
| `INSTALL_IMMICH` / `INSTALL_DOCLING` / `INSTALL_EXPORTERS` / `INSTALL_TUI` / `INSTALL_WATCHDOG` | `1` | Toggle optional pieces |
| `WATCHDOG_PRESSURE_THRESHOLD` | `warn` | `warn` or `critical` |
| `AUTO_ACCEPT` | `0` | `1` = skip "press Enter" prompts in the TUI |

> **Port note:** LiteLLM and Ollama both default to :11434. They only collide if
> you run **both** (`INSTALL_MLX=1` *and* `INSTALL_OLLAMA=1`) — then change
> `OLLAMA_PORT`. With the default (Ollama off) there's no conflict.

## Updating & version pinning

`vllm-mlx` is **alpha** software — a floating auto-upgrade once broke a loaded
model. So the weekly job updates **only the OS and brew system packages**;
everything that serves a model (`vllm-mlx`, `mlx-vlm`, `litellm`, `immich-ml`,
`docling`, Ollama, and the model weights) stays put until you change it on
purpose.

- **See what's available** (read-only): `sudo bash setup.sh --check-updates`
  (or main-menu *Check for updates*). Shows installed vs PyPI (stable + newest
  incl. pre-release) for the LLM stack, `brew outdated`, and macOS updates.
- **Upgrade vllm-mlx on purpose:** set `VLLM_MLX_VERSION` (menu 4 → e.g.
  `0.4.0rc1`, or edit `macstudio.conf`) then `sudo bash setup.sh --apply`. The
  installer reinstalls that exact version and restarts vllm-mlx.
- **Roll back:** set `VLLM_MLX_VERSION` back (e.g. `0.3.0`) and `--apply` again.
  It's an isolated venv, so up/down-grades are clean and reversible.
- `mlx-vlm`/`litellm` stay at their built version; bump manually in the venv if
  ever needed (`<venv>/bin/pip install -U …`).

## Commands (installed to `/usr/local/bin`)

| Command | Purpose |
|---|---|
| `llm-status` | Live overview: memory, daemons, scheduled jobs |
| `llm-models` | Model & alias manager (download, pick main/ocr, HF token) |
| `llm-restart [name\|all]` | Restart one or all services |
| `llm-update` | Run the weekly autoupdate job now |
| `llm-service-ctl wake\|sleep\|status glmocr\|immich\|docling\|all` | Manual on-demand override |
| `llm-logs [name]` | `tail -F` a service log (`vllm`, `litellm`, `glmocr-serve`, …) |

To watch **what the model is doing right now** from the TUI: `sudo bash setup.sh`
→ *View logs* → type `f <n>` to **follow live** (Ctrl-C returns to the menu);
the `vllm.log` follow is filtered to request/completion/`running=N` lines. Or on
the CLI: `llm-logs vllm | grep -E "REQUEST|running=|Chat completion"`.
| `sudo mactop` / `sudo macmon` | Live Apple-Silicon TUIs |

## Monitoring (Prometheus → Grafana)

```yaml
scrape_configs:
  - job_name: mac-system
    static_configs: [{ targets: ['mac.home.arpa:9100'] }]
  - job_name: mac-silicon
    static_configs: [{ targets: ['mac.home.arpa:9101'] }]
  - job_name: mac-ondemand
    static_configs: [{ targets: ['mac.home.arpa:9103'] }]
  # vllm-mlx and LiteLLM also expose /metrics on :18000 and :11434
```

Import dashboard **1860** (node_exporter) and `grafana/mac-llm-dashboard.json`
for the Apple-Silicon + on-demand panels.

## How on-demand works

The proxy plist always owns the public port (e.g. GLM-OCR :5002); the real
backend plist (`com.local.glmocr.serve`) is registered with
`KeepAlive=false, RunAtLoad=false` and stays stopped. On the first TCP
connection the proxy kickstarts the backend, polls its health endpoint, then
streams traffic. A 30 s loop stops the backend after `IDLE_TIMEOUT_* `seconds of
idle (set `-1` to keep it warm forever). Transparent to clients apart from a
short cold-start latency.

## Ollama as an opt-in fallback

Ollama is **off by default** (`INSTALL_OLLAMA=0`): its plist, wrapper,
`modelfiles/`, exporter and config keys stay in the repo but nothing is
installed or started. Turn it on in `setup.sh` menu 2 (or set
`INSTALL_OLLAMA=1`) and `--apply`. If you also keep the MLX stack on, change
`OLLAMA_PORT` to avoid the :11434 clash with LiteLLM.

## File layout

```
<repo root>/
├── setup.sh            single TUI / --apply entry point
├── motd.txt            SSH-login banner template
├── models/catalog.tsv  model catalog seed (schema v2)
├── wrappers/           scripts plists execute (start-vllm, start-litellm, start-glmocr, …)
├── bin/                user commands (llm-*)
├── daemons/            plist templates (@VAR@ substitution)
├── services/           proxy, exporters, watchdogs, autoupdate
├── modelfiles/         Ollama Modelfiles (only used if INSTALL_OLLAMA=1)
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
/Users/mac/.macstudio-venvs/    vllm / litellm / mlxvlm venvs
/Users/mac/.cache/huggingface/  downloaded models + HF token
/Library/LaunchDaemons/         com.local.*.plist
/var/log/macstudio/             per-service logs
```

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `llm-models` / `llm-status` say "setup.sh not found" | Old build — `git pull && sudo bash setup.sh --apply` (fixed: the wrapper now checks readable, not executable). |
| `hf auth login` / `hf download` fail with help text | huggingface_hub ≥ 1.0 renamed the CLI to `hf`. Fixed in current build — `git pull && --apply`. |
| `vllm-mlx: unrecognized arguments` in `vllm.log` | A `vllm-mlx serve` flag changed. Check `vllm-mlx serve --help` in the venv and adjust `wrappers/start-vllm.sh`. |
| vllm-mlx flapping in `vllm.log` | No model downloaded yet, or `ALIAS_MAIN` points at a model that isn't `ok`. Run `llm-models` → `d` then `s`. |
| Reasoning text leaks into the answer | The model doesn't emit `<think>` tags, so the parser can't split it. Use a model that does (e.g. `gptoss-20b`) or a "answer concisely" system prompt. |
| Gemma 4 vision doesn't work as `main` | vllm-mlx documents vision for Gemma **3**, not 4. The `vllm-mllm` engine passes `--mllm`; if Gemma 4 images still fail, set the entry to `engine=vllm` (text-only) via `llm-models` → `e` and use GLM-OCR for images. |
| Download is slow / rate-limited | Set your HF token: `llm-models` → `t`. |
| `memory_pressure` reports `Warn` with a model loaded | Lower `VLLM_MAX_MODEL_LEN`/`VLLM_MAX_NUM_SEQS`, or `IOGPU_WIRED_LIMIT_MB` by 1024, via `setup.sh` menu 4. |
| Mac doesn't come back after reboot / power loss | **FileVault is ON** and no console operator. Use `sudo fdesetup authrestart` for planned reboots; never plain `sudo reboot` on a headless FileVault Mac. |
| `/var/macstudio/reboot-pending` exists | Weekly autoupdate needs a restart it refused to do (FileVault). Clear with `sudo fdesetup authrestart`. |

## Uninstalling

`sudo bash setup.sh` → menu 9. Removes every plist, wrapper, script, config and
log this tool installed. **Keeps** the Python venvs (`$VENV_DIR`) and the
HuggingFace model cache — delete those by hand to reclaim disk.

## Credits / license

MIT.
