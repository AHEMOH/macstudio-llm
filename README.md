# Mac Studio Headless LLM Server

Headless Apple Silicon Mac as an **MLX inference server**: **one unified
multimodal model permanently warm** — by default **gemma-4-26b on `mlx_vlm.server`**,
which handles **text *and* images in the same chat** plus tool calling, with KV-cache
quantization — a **LiteLLM gateway** that gives apps stable aliases, an on-demand
**GLM-OCR** model for document OCR, and an on-demand **BGE embeddings + reranker**
pair (for RAG). Plus optional companion services (image AI,
document conversion) that sleep when idle and wake on first request. Runs fully
unattended: no GUI, no login, auto-restart on power loss, weekly self-update.

Designed for a 32 GB M1 Max but scales unchanged to bigger Apple Silicon — just
raise a couple of config keys.

> **Text engine — one switch (`TEXT_ENGINE`).** Default **`optiq`** (`mlx-optiq`'s
> `optiq serve`, **BETA**): the `main` is one of the **QAT OptiQ Gemma-4** mains
> (default `gemma4-26b-optiq`) — Mixed-Precision quantization, **one unified model that
> handles text *and* images in the same chat**, KV-cache quantization (bigger context on
> 32 GB) + tool calling, served over OpenAI `/v1`, single-stream (fine for one user).
> It builds its own venv (`mlx-optiq` + `mlx-lm` from git) and has **no audio**.
> Flip to **`mlx-vlm`** (`mlx_vlm.server`, pinned 0.6.3) to run stock/**QAT** Gemma-4 mains
> with **working text+images+tools** (verified: `gemma4-{26b,12b,e4b,e2b}-qat`, vision 4/4) —
> the go-to engine when you want image chat on non-OptiQ models. Or **`mlx-lm`** (Apple
> `mlx_lm.server`) for a text-only main that **batches** parallel requests and supports broad
> archs (granite/glm) — no images, no KV-quant. Or **`vllm-mlx`** (waybarrios `vllm-mlx serve`)
> for stock/QAT Gemma-4 **text + tools + continuous batching** (multi-user throughput) over
> OpenAI `/v1` (+ Anthropic) — but **its Gemma-4 vision is broken (v0.4.0, tested), so use it
> for text/tools only** and switch to `mlx-vlm` for images.
> One text daemon runs at a time; `--apply` to switch or roll back. Either way only
> **one big model** is in memory (GLM-OCR and the small BGE embed/rerank pair are the
> only on-demand extras).

> **The `agent` co-resident model.** Optionally (`INSTALL_AGENT=1`) a small, fast
> OptiQ Gemma-4 (default `gemma4-e2b-optiq`) runs as a **second `optiq serve`**
> *alongside* the big unified main, exposed as the LiteLLM `agent` alias. Because it's
> optiq (OpenAI `/v1`) it does **text + tools + images (vision)** and holds a **huge
> context (128K)** at tiny KV (1 KV head) — verified swap-free co-resident with the 26B
> main (peak ~13.6 GB). It's the **long-context path**: send long documents here (the big
> 26B main OOM-crashes above ~110K on 32 GB — `optiq serve` has no context cap — and the
> e2b prefills long prompts far faster anyway). (Earlier this was an Ollama-served model,
> but Ollama's MLX runner drops Gemma-4 vision — verified — so `agent` is optiq now.)
>
> **Ollama** is not the unified `main` and no longer backs `agent`; it remains only an
> opt-in full-daemon fallback (`INSTALL_OLLAMA=1`, the gpt-oss/paperless Modelfiles),
> off by default.

## What this gives you

- **`mlx_lm.server`** always on (internal :18000): **one** text model, Apple's
  reference server — **tool calling + reasoning auto-detected per model** (the
  server infers the tool parser from the chat template and splits reasoning into
  its own field). 16-bit KV cache (no KV quantization yet — mlx-lm issue #1308);
  RAM bounded via `MLXLM_PROMPT_CACHE_MB`. Stable and simple.
- **LiteLLM gateway** on the public port (:11434): apps talk OpenAI `/v1` (and
  Anthropic `/v1/messages`) to the stable aliases — `main` (text + images, reasons by
  default), `main-fast` (same, thinking-off), `ocr`, `embed` (BGE-M3 embeddings),
  `rerank` (BGE reranker), and — when `INSTALL_AGENT=1` — `agent` (fast co-resident
  text+tools+vision helper, 128K, thinking-off). The underlying model is swappable
  without the app noticing.
- **`agent`** (opt-in `INSTALL_AGENT=1`, off by default): a small, fast, **co-resident**
  OptiQ Gemma-4 (default `gemma4-e2b-optiq`, ~5 GB) served by a **second `optiq serve`**
  on its own internal port (:18002), exposed as the LiteLLM `agent` alias. Does
  **text + tools + images (vision)** and a **128K context** at tiny KV — verified
  swap-free co-resident with the 26B main (peak ~13.6 GB). It's the long-context / fast
  path — send long documents here (the big main OOMs above ~110K; `optiq serve` has no
  context cap, and e2b prefills long prompts far faster). thinking-off by default
  (verified: e2b stays clean thinking-off, unlike the 12B which loops). Switch the model
  via `AGENT_MODEL` (any OptiQ catalog id; note e4b **swaps** co-resident on 32 GB — stay on e2b).
- **GLM-OCR** (0.9 B, ~2 GB) on-demand on :5002 via `mlx-vlm` — document OCR,
  #1 on OmniDocBench. The only vision model small enough to co-reside with the
  big text main.
- **Embeddings + rerank** (opt-in `INSTALL_EMBED=1`, on by default): **BAAI/bge-m3**
  (1024-dim multilingual dense embeddings, `embed` alias) + **BAAI/bge-reranker-v2-m3**
  (cross-encoder, `rerank` alias) served together by **Infinity** in one Torch-MPS
  process, on-demand on :5004. Both small (~2 GB each) — they co-reside with the
  big main like GLM-OCR. Reachable via LiteLLM `/v1/embeddings` and `/v1/rerank`.
- **Dormant vision path:** a separate on-demand `vision` model/alias (`ALIAS_VISION`,
  :5003) existed for the text-only `mlx-lm` mode. Under the default unified main
  (`optiq`/`mlx-vlm`, which does images itself) the **`vision` gateway alias is not exposed**; the
  wrapper/daemon stay in the repo but unused (`ALIAS_VISION=""`).
- **Model catalog + `llm-models` TUI**: download pre-converted MLX models from
  HuggingFace, pick the active text / ocr / vision / embed / rerank model, manage
  your HF token. Only fully-downloaded models become selectable.
- **30 GB GPU wired memory limit** (on a 32 GB box) + OS trim → nearly the whole
  machine is available to the model.
- **On-demand companions** on :3003 (immich-ml) and :5001 (docling-serve),
  optional — public ports always listen; the real backend wakes on request and
  sleeps after 15 min, freeing RAM.
- **Weekly auto-update** (Sat 06:00): **OS + brew system packages only**
  (`brew update`, macOS security updates). The model/LLM stack is **frozen** —
  `mlx-lm` is pinned via `MLXLM_VERSION`, and `mlx-vlm`/`litellm`/Ollama/models
  are never auto-upgraded (a surprise version jump once broke a model). The run
  logs which LLM versions are available but held. Bump them deliberately via
  **Check for updates** → set the pin → Install/update.
- **Watchdogs**: a memory-pressure safety net (offloads optional services,
  keeps the main model healthy) and an Ollama-only inference-stall killer
  (idle unless `INSTALL_OLLAMA=1`).
- **Prometheus exporters** for Grafana are **opt-in** (`INSTALL_EXPORTERS=1`,
  off by default): node_exporter (:9100), Apple-Silicon metrics (:9101, via
  **macmon**: whole-system power from the SMC, CPU/GPU temperatures, real GPU
  utilization; powermetrics fallback), on-demand stack state (:9103). Note:
  `mlx_lm.server` has no `/metrics` endpoint.
- **MQTT bridge → Home Assistant** is **opt-in** (`INSTALL_MQTT=1`, off by
  default): publishes power/GPU/thermal/RAM/disk/update telemetry with HA
  autodiscovery and exposes a **one-click main-model switch** as an HA `select`.
  See [INTEGRATIONS.md](INTEGRATIONS.md#mac-studio-in-home-assistant-mqtt).
- **Web dashboard** (on by default, `INSTALL_DASHBOARD=1`): browser control of
  the whole box on `http://mac.home.arpa:8090` — models (download with live
  progress, switch main/agent/ocr/embed/rerank), services (restart/stop/wake +
  live state), every `macstudio.conf` setting with **Save & Apply**, live log
  tails, and power/thermal/GPU/RAM charts. Token-protected (auto-generated
  `DASHBOARD_TOKEN` in `macstudio.conf`). The SSH TUI stays fully authoritative
  — the dashboard only calls the same `setup.sh` verbs.
- **Remote desktop** (on by default, `INSTALL_REMOTE=1` + `INSTALL_NOVNC=1`):
  control the headless macOS **desktop** over the LAN — macOS Screen Sharing (VNC
  on `:5900`) for a Windows client (RealVNC/TightVNC), plus a browser bridge at
  `http://mac.home.arpa:6080/vnc.html` (noVNC, no client needed). One
  auto-generated `VNC_PASSWORD`; ~30 MB idle, so it never touches the model
  budget. See [INTEGRATIONS.md](INTEGRATIONS.md#remote-desktop-vnc--browser--install_remote--install_novnc).
- **One script** (`setup.sh`): install, update, settings, **model manager**,
  service control, clean-up, uninstall. TUI by default, `--apply` for
  non-interactive runs. Idempotent — re-run safely any time.

## Architecture

```
Public (apps point here):
  com.local.litellm.proxy          :11434   LiteLLM gateway — aliases main / main-fast /
                                             ocr / embed / rerank / agent
                                             (OpenAI /v1 + Anthropic /v1/messages)
Always on (internal / support):
  com.local.optiq.main             :18000   the ONE unified multimodal main (TEXT_ENGINE)
  com.local.optiq.agent            :18002   fast co-resident 'agent' (OptiQ e2b, text+tools+vision, 128K, if INSTALL_AGENT=1)
  com.local.glmocr.proxy           :5002    on-demand proxy for GLM-OCR
  com.local.infinity.proxy         :5004    on-demand proxy for embed + rerank (Infinity)
  com.local.vision.proxy           :5003    on-demand proxy for the vision model (if ALIAS_VISION set)
  com.local.immich.proxy           :3003    on-demand proxy (optional)
  com.local.docling.proxy          :5001    on-demand proxy (optional)
  com.local.llm.watchdog                    memory-pressure safety net
  com.local.inference.watchdog              Ollama stall killer (idle w/o Ollama)
  com.local.preventsleep                    caffeinate

Registered but sleeping until requested:
  com.local.glmocr.serve           :15002   GLM-OCR backend (mlx-vlm)
  com.local.infinity.serve         :15004   Infinity embed + rerank backend (Torch MPS)
  com.local.vision.serve           :15003   vision backend (mlx-vlm)
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

Opt-in only (INSTALL_OLLAMA=1, off by default):
  com.local.ollama.headless        :11434   Ollama (collides with LiteLLM — see note)
  com.local.ollama.exporter        :9102     Ollama /api/ps exporter
```

The main model is kept warm; switching it is an **explicit** action (pick in
`llm-models` → `mlx_lm.server` restarts, ~30–60 s) — never a silent hot-swap.

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
builds the three MLX venvs (`mlxlm`, `litellm`, `mlxvlm`).

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
#   t                         → paste your HuggingFace token (gemma is gated — required)
#   d gemma4-26b-optiq       → download the default unified main (~16 GB, live progress)
#   s gemma4-26b-optiq       → set it as the active 'main' (text+images under optiq)
#   d glm-ocr                 → download GLM-OCR (~2 GB)
#   o glm-ocr                 → set it as the active 'ocr' model
#   d bge-m3                  → download the embedder (~2 GB, ungated)
#   m bge-m3                  → set it as the active 'embed' model
#   d bge-reranker-v2-m3      → download the matching reranker (~2 GB, ungated)
#   k bge-reranker-v2-m3      → set it as the active 'rerank' model
#   q                         → back
# (Prefer a text-only main that batches? Set TEXT_ENGINE=mlx-lm and pick e.g. granite41-30b.)
```

Only `STATUS=ok` (fully downloaded + verified) models are selectable. After
`s`, `mlx_lm.server` restarts and loads the model.

### 5. Use it

Apps point at the **LiteLLM gateway on :11434** and address the **alias**, never
the real model id:

```bash
# OpenAI-style chat
curl http://mac.home.arpa:11434/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"main","messages":[{"role":"user","content":"Hallo!"}]}'

# OCR (wakes GLM-OCR on demand) — or use model "vision" for general image Q&A
curl http://mac.home.arpa:11434/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"ocr","messages":[{"role":"user","content":[
        {"type":"text","text":"Extract the text"},
        {"type":"image_url","image_url":{"url":"data:image/png;base64,..."}}]}]}'
```

Tool calling and reasoning separation are automatic on `mlx_lm.server` (per the
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

Three roles are selectable: **`text`** (alias `main`, plus the `main-fast`
preset on the same model), **`ocr`** (alias `ocr`, on-demand) and
**`vision`** (mlx-vlm machinery still in the repo but **not exposed as a gateway alias**
under the unified mlx-vlm main).

`llm-models` actions:

| Key | Action |
|---|---|
| `d <id>` | **Download** the repo from HuggingFace (live progress), then verify |
| `s <id>` | Set as the active **text/main** model (role=text only) → `mlx_lm.server` restarts |
| `o <id>` | Set as the active **ocr** model (role=ocr only) |
| `v <id>` | Set as the active **vision** model (role=vision only) |
| `a` / `e <id>` / `x <id>` | Add / edit / remove a catalog entry |
| `r <id>` | Delete the locally-downloaded files |
| `t` | Store/clear your **HuggingFace token** (`hf auth login`) |
| `q` | Back |

Per-model columns the catalog carries: `role`, `engine`, `quant`, `gb`,
`gated`, `reasoning_parser`, `tool_parser`, `max_kv_size`, `max_num_seqs`,
`rating`, `notes`, sampling defaults. The `reasoning_parser`/`tool_parser`
columns are **informational** now — `mlx_lm.server` and `mlx-vlm` auto-detect
them from the model. The `engine` column is informational: `mlxvlm` = unified
text+images main (`TEXT_ENGINE=mlx-vlm`), `mlxlm` = text-only (`TEXT_ENGINE=mlx-lm`),
`optiq` = QAT OptiQ multimodal main (`TEXT_ENGINE=optiq`, BETA). The old
`vllm`/`vllm-mllm` values are **historical** (vllm-mlx is retired). A model is
refused for a slot when its `notes` carry a `BROKEN[<engine>]` flag for the engine
that slot runs (the OptiQ rows carry `BROKEN[mlx-vlm]`+`BROKEN[mlx-lm]`, so they are
selectable **only** under `TEXT_ENGINE=optiq`).

**Per-model sampling** (temperature/top_p/…) defaults are injected into the
LiteLLM `main` alias; clients can override per request. `main`/`main-fast` use
Gemma's reference sampling (temp 1.0 / top_p 0.95 from the catalog + `top_k`=`GEMMA_TOP_K`
via `extra_body`). On `mlx_lm.server` the generation ceiling for `main` is
`MLXLM_MAX_TOKENS` (default 16384 ≈ unrestricted for chat).

**HuggingFace token:** set it via `llm-models` → `t`. It is stored in the user's
HF cache (`$HF_CACHE_DIR/.../token`, mode 600) — **never** in `macstudio.conf`
or git. Needed for gated repos (e.g. Gemma) and for higher download rate limits.

Seeded models — intentionally **lean** (a gemma-4 unified main + GLM-OCR). Add more via
`llm-models` (e.g. `granite`/`qwen`/`glm` if you switch to `TEXT_ENGINE=mlx-lm`):

| id | role | ~GB | notes |
|---|---|---|---|
| `gemma4-26b-optiq` | text | 16 | **default main** — OptiQ engine (`TEXT_ENGINE=optiq`, BETA), QAT 26B-A4B MoE, unified text+images+tools, KV-quant (~44 tok/s thinking-off); German (**gated**) |
| `gemma4-e4b-optiq` / `-e2b-optiq` | text | 8 / 6 | OptiQ (BETA) — QAT edge variants, multimodal, faster/smaller (raw ~56 / ~91 tok/s); **gated** |
| `glm-ocr` | ocr | 2 | **default ocr**, on-demand, #1 OmniDocBench (full page via `GLMOCR_MAX_TOKENS`) |

The `*-optiq` rows are selectable only under `TEXT_ENGINE=optiq` (BETA `mlx-optiq`,
own venv). All are multimodal text+images — **none support audio**.

## Prerequisites installed automatically

`setup.sh --apply` installs these on first run (hash/presence-checked, no-op if
present):

| Prerequisite | How | When |
|---|---|---|
| **Xcode Command Line Tools** | `softwareupdate -i` (headless) | unless present |
| **Homebrew** | official installer, `NONINTERACTIVE=1`, as `TARGET_USER` | if absent |
| **python@3.12** | `brew install python@3.12` (MLX/docling wheels need ≥3.10) | if `INSTALL_MLX=1`, `INSTALL_EMBED=1` or `INSTALL_DOCLING=1` |
| **mlxlm venv** | `pip install mlx-lm==$MLXLM_VERSION huggingface_hub[cli]` in `$VENV_DIR/mlxlm` | if `INSTALL_MLX=1` |
| **litellm venv** | `pip install 'litellm[proxy]'` in `$VENV_DIR/litellm` | if `INSTALL_MLX=1` |
| **mlxvlm venv** | `pip install mlx-vlm huggingface_hub[cli]` in `$VENV_DIR/mlxvlm` | if `INSTALL_MLX=1` |
| **infinity venv** | `pip install 'infinity-emb[all]' huggingface_hub[cli]` in `$VENV_DIR/infinity` | if `INSTALL_EMBED=1` |
| **node_exporter** | `brew install node_exporter` | if `INSTALL_EXPORTERS=1` (off by default) |
| **mactop + macmon** | `brew install mactop macmon` | if `INSTALL_TUI=1` |
| **docling-serve venv** | `pip install 'docling[…]' 'docling-serve[ui]'` | if `INSTALL_DOCLING=1` |
| **ollama** | `brew install ollama` | only if `INSTALL_OLLAMA=1` |

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

**Memory note (32 GB):** `mlx_lm.server` uses a 16-bit KV cache (no KV
quantization yet — mlx-lm issue #1308), so plan context conservatively; bound
prompt-cache RAM with `MLXLM_PROMPT_CACHE_MB`. Only **one** big model fits, so
GLM-OCR (~2 GB) co-resides but a larger `vision` model is on-demand and a ~16 GB
vision model will not co-reside with a 16 GB text main.

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
3) Models & aliases…             (download MLX models, pick main / ocr / vision / embed / rerank)
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
| `INSTALL_MLX` | `1` | The MLX stack (mlx_lm.server + LiteLLM + GLM-OCR/vision) — primary backend |
| `INSTALL_OLLAMA` | `0` | Opt-in Ollama fallback (kept in repo, off by default) |
| `VENV_DIR` | `/Users/mac/.macstudio-venvs` | Where the mlxlm/litellm/mlxvlm venvs live |
| `HF_CACHE_DIR` | `/Users/mac/.cache/huggingface` | HF model cache (`HF_HOME`) + token store |
| `ALIAS_MAIN` | `gemma4-26b-optiq` | Catalog id of the active text model (an OptiQ Gemma-4 main under `optiq`; a VLM like gemma-4 under `mlx-vlm`; any text arch under `mlx-lm`) |
| `ALIAS_OCR` | _(empty)_ | Catalog id of the on-demand OCR model (`ocr` gateway alias). Empty = no `ocr` alias (off by default); set to `glm-ocr` to re-enable |
| `ALIAS_EMBED` | `bge-m3` | Catalog id of the on-demand embedder (Infinity, alias `embed`). Empty = no embed alias |
| `ALIAS_RERANK` | `bge-reranker-v2-m3` | Catalog id of the on-demand reranker (Infinity, alias `rerank`). Empty = no rerank alias |
| `ALIAS_VISION` | _(empty)_ | (Dormant) catalog id of an on-demand vision model. The `vision` **gateway alias is no longer emitted** under the unified mlx-vlm main — send images to `main` instead. Leave empty |
| `MODEL_PIN_MAIN` | `1` | Keep the main model permanently warm |
| `LITELLM_PORT` | `11434` | Public gateway port (apps use this) |
| `VLLM_BACKEND_PORT` | `18000` | Internal text-engine port (legacy `VLLM_` name; mlx_lm.server binds it) |
| `VLLM_MAX_NUM_SEQS` | `4` | Fallback for `MLXLM_DECODE_CONCURRENCY` (legacy `VLLM_` name) |
| `LLM_REQUEST_TIMEOUT` | `3600` | Per-request timeout (s) for the text engine **and** LiteLLM; long docs/OCR |
| `TEXT_ENGINE` | `optiq` | Engine for `main`: **`optiq`** (default — **BETA** `mlx-optiq`, QAT OptiQ Gemma-4 mains, **unified text+images** + KV-quant + tools, single-stream, own `mlx-lm`-from-git venv, no audio) \| `mlx-vlm` (stock VLM mains, unified text+images, KV-quant) \| `mlx-lm` (text-only, batches parallel requests, broad archs incl. granite/glm). Flip + `--apply` to switch/rollback |
| `MLXLM_VERSION` | `0.31.3` | Pinned mlx-lm for the `mlxlm` venv (the text engine) |
| `MLXLM_PROMPT_CACHE_MB` | `8192` | mlx-lm prompt-cache RAM cap (`--prompt-cache-bytes`); bounds 16-bit KV |
| `MLXLM_DECODE_CONCURRENCY` | _(empty)_ | mlx-lm `--decode-concurrency`; empty = reuse `VLLM_MAX_NUM_SEQS` |
| `MLXLM_PROMPT_CONCURRENCY` | `1` | mlx-lm `--prompt-concurrency`; 1 on 32 GB |
| `MLXLM_MAX_TOKENS` | `16384` | mlx-lm default `--max-tokens` = ceiling for `main` (else only 512). 16384 ≈ unrestricted for chat; stops at EOS. The preset aliases use their own `*_MAXTOK` caps |
| `MLXLM_CHAT_TEMPLATE_ARGS` | _(empty)_ | mlx-lm `--chat-template-args` JSON, e.g. `{"enable_thinking":false}` |
| `MLXVLM_MAIN_KV_BITS` / `_KV_SCHEME` | `8` / `uniform` | KV-quant for the **mlx-vlm** unified main (`turboquant` for fractional bits) |
| `MLXVLM_MAIN_MAX_KV_SIZE` | _(empty)_ | mlx-vlm main context cap; raise to exploit KV-quant for big context |
| `MLXVLM_MAIN_ENABLE_THINKING` | `1` | mlx-vlm main thinks by default (so `main` reasons). `main-fast` is forced thinking-off at the proxy; clients can override per request |
| `OPTIQ_KV_BITS` / `OPTIQ_KV_GROUP_SIZE` | `8` / _(empty)_ | `optiq serve` KV-cache quant (`--kv-bits` 4\|8, `--kv-group-size`); only when `TEXT_ENGINE=optiq` |
| `OPTIQ_MAX_TOKENS` | `16384` | `optiq serve` default `--max-tokens` ceiling for `main` (only when `TEXT_ENGINE=optiq`) |
| `OPTIQ_DRAFTER` | _(empty)_ | `optiq serve` speculative-decoding drafter repo (`--drafter`); empty = **off** (drafter costs extra RAM — leave off on 32 GB unless verified) |
| `INSTALL_AGENT` | `0` | Opt-in fast co-resident OptiQ Gemma-4 (2nd `optiq serve`) → LiteLLM alias `agent` (text+tools+vision, 128K; runs alongside the main; needs `INSTALL_MLX=1` + the optiq venv, auto-built) |
| `AGENT_MODEL` | `gemma4-e2b-optiq` | HF **catalog id** of the `agent` model (an OptiQ build). ~5 GB, ~76 tok/s, tools+vision, 128K. e.g. `gemma4-e4b-optiq` for more quality (but e4b **swaps** co-resident on 32 GB — stay on e2b) |
| `AGENT_BACKEND_PORT` | `18002` | Internal port the `agent` optiq daemon binds (LiteLLM fronts it; distinct from `:18000` main and `:11434` Ollama fallback) |
| `AGENT_KV_BITS` | `4` | `agent` optiq KV-cache quant bits (`4` keeps 128K KV tiny, or `8`); empty = fp16 |
| `AGENT_MAX_TOKENS` | `8192` | `agent` default output-token cap (optiq `--max-tokens`); clients can override. (No context cap — the model's `max_position` 128K is the ceiling) |
| `OLLAMA_VERSION` | `0.31.1` | Pinned Ollama fetched as `ollama-darwin.tgz` from GitHub → `$VENV_DIR/ollama-dist` (used only by the `INSTALL_OLLAMA` fallback; `agent` is optiq now) |
| `GEMMA_TOP_K` | `64` | Gemma reference top_k for `main`/`main-fast`/`agent` (via `extra_body`; top_k is not a native OpenAI param). `0`/empty = off; inert at temperature 0 |
| `PRESET_ALIASES` | `1` | Expose the `main-fast` preset alias (same loaded model as `main`, thinking-off) |
| `GLMOCR_PUBLIC_PORT` | `5002` | Public GLM-OCR port (proxy) |
| `GLMOCR_BACKEND_PORT` | `15002` | Internal GLM-OCR backend port |
| `IDLE_TIMEOUT_GLMOCR` | `60` | Seconds before GLM-OCR sleeps; **`-1` = never sleep** |
| `STARTUP_TIMEOUT_GLMOCR` | `120` | GLM-OCR wake-up deadline |
| `INFINITY_PUBLIC_PORT` | `5004` | Public embed/rerank port (proxy) |
| `INFINITY_BACKEND_PORT` | `15004` | Internal Infinity backend port |
| `IDLE_TIMEOUT_INFINITY` | `900` | Seconds before the embed/rerank backend sleeps; **`-1` = never** |
| `STARTUP_TIMEOUT_INFINITY` | `180` | Infinity wake-up deadline (Torch/MPS load) |
| `INFINITY_DEVICE` | `mps` | Infinity compute device (`mps` Apple GPU \| `cpu`) |
| `INFINITY_DTYPE` | `float16` | Infinity model precision (`float16` ~half the RAM \| `float32`) |
| `INFINITY_BATCH_SIZE` | `4` | Infinity max batch size (single-user default; raise for parallel load) |
| `VISION_PUBLIC_PORT` / `VISION_BACKEND_PORT` | `5003` / `15003` | Public / internal vision (mlx-vlm) ports |
| `IDLE_TIMEOUT_VISION` / `STARTUP_TIMEOUT_VISION` | `60` / `180` | Vision idle-to-sleep / wake deadline (VLM loads are slow) |
| `VISION_KV_BITS` / `VISION_KV_SCHEME` | `8` / `uniform` | mlx-vlm KV quantization (`uniform` or `turboquant` for fractional bits) |
| `VISION_MAX_KV_SIZE` / `VISION_ENABLE_THINKING` | _(empty)_ / `0` | Vision context cap / enable reasoning |
| `ML_PUBLIC_PORT` / `ML_BACKEND_PORT` | `3003` / `13003` | immich-ml (optional) |
| `DOCLING_PUBLIC_PORT` / `DOCLING_BACKEND_PORT` | `5001` / `15001` | docling-serve (optional) |
| `IDLE_TIMEOUT_IMMICH` / `IDLE_TIMEOUT_DOCLING` | `900` | Idle-to-sleep seconds (`-1` = never) |
| `AUTOUPDATE_WEEKDAY` / `_HOUR` / `_MINUTE` | `6` / `6` / `0` | Weekly schedule (Sat 06:00) |
| `NODE_EXPORTER_PORT` / `SILICON_EXPORTER_PORT` / `ONDEMAND_EXPORTER_PORT` | `9100` / `9101` / `9103` | Prometheus exporters (only if `INSTALL_EXPORTERS=1`) |
| `OLLAMA_*` | — | Only used when `INSTALL_OLLAMA=1` |
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

> **Port note:** LiteLLM and Ollama both default to :11434. They only collide if
> you run **both** (`INSTALL_MLX=1` *and* `INSTALL_OLLAMA=1`) — then change
> `OLLAMA_PORT`. With the default (Ollama off) there's no conflict.

## Updating & version pinning

The weekly job updates **only the OS and brew system packages**; everything that
serves a model (`mlx-lm`, `mlx-vlm`, `litellm`, `immich-ml`, `docling`, Ollama,
and the model weights) stays put until you change it on purpose (a floating
auto-upgrade once broke a loaded model).

- **See what's available** (read-only): `sudo bash setup.sh --check-updates`
  (or main-menu *Check for updates*). Shows installed vs PyPI (stable + newest
  incl. pre-release) for the LLM stack, `brew outdated`, and macOS updates.
- **Upgrade the text engine on purpose:** set `MLXLM_VERSION` (menu 4, or edit
  `macstudio.conf`) then `sudo bash setup.sh --apply`. The installer reinstalls
  that exact version and restarts `mlx_lm.server`. It's an isolated venv, so
  up/down-grades are clean and reversible.
- `mlx-vlm`/`litellm` stay at their built version; bump manually in the venv if
  ever needed (`<venv>/bin/pip install -U …`).

## Commands (installed to `/usr/local/bin`)

| Command | Purpose |
|---|---|
| `llm-status` | Live overview: memory, daemons, scheduled jobs |
| `llm-models` | Model & alias manager (download, pick main/ocr/vision, HF token) |
| `llm-restart [name\|all]` | Restart one or all services |
| `llm-update` | Run the weekly autoupdate job now |
| `llm-service-ctl wake\|sleep\|status glmocr\|vision\|immich\|docling\|all` | Manual on-demand override |
| `llm-logs [name]` | `tail -F` a service log (`mlxlm`, `litellm`, `glmocr-serve`, `vision-serve`, …) |
| `sudo mactop` / `sudo macmon` | Live Apple-Silicon TUIs |

To watch **what the model is doing right now** from the TUI: `sudo bash setup.sh`
→ *View logs* → type `f <n>` to **follow live** (Ctrl-C returns to the menu);
the `mlxlm.log` follow is filtered to request/completion lines. Or on the CLI:
`llm-logs mlxlm`.

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
  download with a live progress bar, activate per slot (main / agent / ocr /
  embed / rerank; same validation incl. BROKEN refusal), delete local files,
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
for the Apple-Silicon + on-demand panels. Note: `mlx_lm.server` does **not**
expose `/metrics` (the old vllm-mlx metrics panels stay dark).

## How on-demand works

The proxy plist always owns the public port (e.g. GLM-OCR :5002, vision :5003);
the real backend plist (`com.local.glmocr.serve` / `com.local.vision.serve`) is
registered with `KeepAlive=false, RunAtLoad=false` and stays stopped. On the
first TCP connection the proxy kickstarts the backend, polls its health endpoint,
then streams traffic. A 30 s loop stops the backend after `IDLE_TIMEOUT_*`
seconds of idle (set `-1` to keep it warm forever). Transparent to clients apart
from a short cold-start latency.

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
├── models/catalog.tsv  model catalog seed (schema v6)
├── wrappers/           scripts plists execute (start-mlx-lm, start-litellm, start-glmocr, start-vision, …)
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
/Users/mac/.macstudio-venvs/    mlxlm / litellm / mlxvlm venvs
/Users/mac/.cache/huggingface/  downloaded models + HF token
/Library/LaunchDaemons/         com.local.*.plist
/var/log/macstudio/             per-service logs
```

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `llm-models` / `llm-status` say "setup.sh not found" | Old build — `git pull && sudo bash setup.sh --apply`. |
| `hf auth login` / `hf download` fail with help text | huggingface_hub ≥ 1.0 renamed the CLI to `hf`. `git pull && --apply`. |
| `main` flapping in `mlxlm.log` | No model downloaded yet, or `ALIAS_MAIN` points at a model that isn't `ok`. Run `llm-models` → `d` then `s`. |
| Short answer comes back empty from a reasoning model | The model spent the token budget thinking. Raise `MLXLM_MAX_TOKENS`, use the thinking-off `main-fast` alias, or set `MLXLM_CHAT_TEMPLATE_ARGS='{"enable_thinking":false}'`. |
| Need image/vision input | The unified mlx-vlm `main` is multimodal — send `image_url` straight to `main` (or `main-fast`), image **before** the text. For best document transcription use `ocr` (GLM-OCR). |
| Download is slow / rate-limited | Set your HF token: `llm-models` → `t`. |
| `memory_pressure` reports `Warn` with a model loaded | Use a smaller model, lower `MLXLM_PROMPT_CACHE_MB`, or `IOGPU_WIRED_LIMIT_MB` by 1024, via `setup.sh` menu 4. |
| Mac doesn't come back after reboot / power loss | **FileVault is ON** and no console operator. Use `sudo fdesetup authrestart` for planned reboots; never plain `sudo reboot` on a headless FileVault Mac. |
| `/var/macstudio/reboot-pending` exists | Weekly autoupdate needs a restart it refused to do (FileVault). Clear with `sudo fdesetup authrestart`. |

## Uninstalling

`sudo bash setup.sh` → menu 9. Removes every plist, wrapper, script, config and
log this tool installed. **Keeps** the Python venvs (`$VENV_DIR`) and the
HuggingFace model cache — delete those by hand to reclaim disk.

## Credits / license

MIT.
