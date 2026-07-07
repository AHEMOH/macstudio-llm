#!/usr/bin/env bash
# =============================================================================
# MacStudio LLM Server — single entry point
#
#   sudo bash setup.sh             # interactive TUI
#   sudo bash setup.sh --apply     # non-interactive install/update
#   sudo bash setup.sh --status    # print live status and exit
#   sudo bash setup.sh --help      # show flags
#
# Idempotent. Re-run safely at any time. Every action inspects live state
# before changing anything.
# =============================================================================
set -u

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT_VERSION=1.0.0

# --- On-Mac target paths ----------------------------------------------------
CONF_FILE=/usr/local/etc/macstudio.conf
REPO_POINTER_FILE=/usr/local/etc/macstudio.repo
LOG_DIR=/var/log/macstudio
LIBEXEC_DIR=/usr/local/libexec
BIN_DIR=/usr/local/bin
SBIN_DIR=/usr/local/sbin
PLIST_DIR=/Library/LaunchDaemons
MOTD_FILE=/etc/motd
MOTD_BACKUP=/etc/motd.macstudio.bak

# --- Labels & their plist source filenames ---------------------------------
# Always-on services
ALWAYS_ON_LABELS=(
  com.local.mlxvlm.main
  com.local.litellm.proxy
  com.local.infinity.proxy
  com.local.immich.proxy
  com.local.docling.proxy
  com.local.node.exporter
  com.local.silicon.exporter
  com.local.ondemand.exporter
  com.local.llm.watchdog
  com.local.preventsleep
  com.local.iogpu.wiredlimit
  com.local.weekly.autoupdate
  com.local.mqtt.bridge
  com.local.dashboard
  com.local.vncfilter
  com.local.novnc
  com.local.paperless.ocr
)
# On-demand backends (KeepAlive=false, RunAtLoad=false)
ONDEMAND_LABELS=(
  com.local.infinity.serve
  com.local.immich.ml
  com.local.docling.serve
)
ALL_LABELS=( "${ALWAYS_ON_LABELS[@]}" "${ONDEMAND_LABELS[@]}" )
# Labels the dashboard/TUI may power off/on to free RAM. Whitelisted — these
# are the only two daemons with KeepAlive=true that hold significant memory;
# a plain `launchctl stop` on them is undone by launchd within a second, so
# freeing memory for good requires the persistent disable+bootout below.
POWER_LABELS=(com.local.mlxvlm.main com.local.infinity.proxy)

# --- Config keys with defaults --------------------------------------------
# (order preserved, used for save_config and menu_settings)
CONFIG_KEYS=(
  TARGET_USER
  TARGET_HOME
  IMMICH_PROJECT_DIR
  DOCLING_PROJECT_DIR
  IOGPU_WIRED_LIMIT_MB
  INSTALL_MLX
  VENV_DIR
  HF_CACHE_DIR
  ALIAS_MAIN
  MODEL_PIN_MAIN
  MAIN_BACKEND_PORT
  MAIN_MAX_NUM_SEQS
  LLM_REQUEST_TIMEOUT
  TEXT_ENGINE
  MLXVLM_VERSION
  MLXVLM_MAIN_KV_BITS
  MLXVLM_MAIN_KV_SCHEME
  MLXVLM_MAIN_MAX_KV_SIZE
  MLXVLM_MAIN_ENABLE_THINKING
  MLXVLM_MAX_TOKENS
  MLXVLM_DRAFT_MODEL
  MLXVLM_DRAFT_KIND
  MLXVLM_DRAFT_BLOCK_SIZE
  GEMMA_TOP_K
  PRESET_ALIASES
  LITELLM_PORT
  INSTALL_EMBED
  ALIAS_EMBED
  ALIAS_RERANK
  INFINITY_PUBLIC_PORT
  INFINITY_BACKEND_PORT
  IDLE_TIMEOUT_INFINITY
  STARTUP_TIMEOUT_INFINITY
  INFINITY_DEVICE
  INFINITY_BATCH_SIZE
  INFINITY_DTYPE
  ML_PUBLIC_PORT
  ML_BACKEND_PORT
  DOCLING_PUBLIC_PORT
  DOCLING_BACKEND_PORT
  IDLE_TIMEOUT_IMMICH
  IDLE_TIMEOUT_DOCLING
  STARTUP_TIMEOUT_IMMICH
  STARTUP_TIMEOUT_DOCLING
  AUTOUPDATE_WEEKDAY
  AUTOUPDATE_HOUR
  AUTOUPDATE_MINUTE
  NODE_EXPORTER_PORT
  SILICON_EXPORTER_PORT
  ONDEMAND_EXPORTER_PORT
  SILICON_SAMPLE_INTERVAL_MS
  INSTALL_IMMICH
  INSTALL_DOCLING
  INSTALL_EXPORTERS
  INSTALL_TUI
  INSTALL_WATCHDOG
  WATCHDOG_PRESSURE_THRESHOLD
  WATCHDOG_AUTO_RESTORE
  INSTALL_MQTT
  MQTT_HOST
  MQTT_PORT
  MQTT_USER
  MQTT_PASS
  MQTT_TOPIC_PREFIX
  MQTT_DISCOVERY_PREFIX
  MQTT_PUBLISH_INTERVAL_SEC
  INSTALL_DASHBOARD
  DASHBOARD_PORT
  DASHBOARD_TOKEN
  INSTALL_REMOTE
  INSTALL_NOVNC
  NOVNC_PORT
  VNC_FILTER_PORT
  VNC_PASSWORD
  INSTALL_PAPERLESS_OCR
  PAPERLESS_OCR_URL
  PAPERLESS_OCR_TOKEN
  PAPERLESS_OCR_LANGS
  PAPERLESS_OCR_RECMODE
  PAPERLESS_OCR_FONT
  PAPERLESS_OCR_DPI
  PAPERLESS_OCR_JPEG_Q
  PAPERLESS_OCR_TEXT_MIN_CHARS
  PAPERLESS_OCR_SMART_NAME
  PAPERLESS_OCR_ARCHIVE_RETENTION_DAYS
  PAPERLESS_OCR_INBOX
  PAPERLESS_OCR_ARCHIVE
  PAPERLESS_OCR_ERRORS
  PAPERLESS_OCR_TRIGGER_TAG
  PAPERLESS_OCR_TRIGGER_FORCE_TAG
  PAPERLESS_OCR_VLM_FORCE_TAG
  PAPERLESS_OCR_DONE_TAG
  PAPERLESS_OCR_SUPERSEDED_TAG
  PAPERLESS_OCR_DELETE_ORIGINAL
  PAPERLESS_OCR_POLL_SEC
  PAPERLESS_OCR_STABLE_SEC
  PAPERLESS_OCR_SMB_SHARE
  PAPERLESS_OCR_SMB_NAME
  PAPERLESS_OCR_DUPLEX_SUBDIR
  PAPERLESS_OCR_DUPLEX_TIMEOUT_SEC
  PAPERLESS_OCR_DUPLEX_REVERSE
  PAPERLESS_OCR_VLM_AUTO
  PAPERLESS_OCR_VLM_MODEL
  PAPERLESS_OCR_VLM_URL
  PAPERLESS_OCR_VLM_TAG
  PAPERLESS_OCR_VLM_MIN_CHARS
  PAPERLESS_OCR_VLM_MAX_TOKENS
  PAPERLESS_OCR_VLM_TIMEOUT_SEC
  AUTO_ACCEPT
)
# Bash-3.2 safe (macOS ships /bin/bash 3.2): lookup functions instead of
# associative arrays. Keep key order in CONFIG_KEYS above as the source of
# truth for iteration.
config_default() {
  case "$1" in
    TARGET_USER)                 echo mac ;;
    TARGET_HOME)                 echo /Users/mac ;;
    IMMICH_PROJECT_DIR)          echo /Users/mac/projects/immich-ml-metal ;;
    DOCLING_PROJECT_DIR)         echo /Users/mac/projects/docling-serve ;;
    IOGPU_WIRED_LIMIT_MB)        echo 30720 ;;
    INSTALL_MLX)                 echo 1 ;;
    VENV_DIR)                    echo /Users/mac/.macstudio-venvs ;;
    HF_CACHE_DIR)                echo /Users/mac/.cache/huggingface ;;
    ALIAS_MAIN)                  echo gemma4-26b-qat ;;
    MODEL_PIN_MAIN)              echo 1 ;;
    MAIN_BACKEND_PORT)           echo 18000 ;;
    MAIN_MAX_NUM_SEQS)           echo 4 ;;
    LLM_REQUEST_TIMEOUT)         echo 3600 ;;
    TEXT_ENGINE)                 echo mlx-vlm ;;
    MLXVLM_VERSION)              echo 0.6.3 ;;
    MLXVLM_MAIN_KV_BITS)         echo 8 ;;
    MLXVLM_MAIN_KV_SCHEME)       echo uniform ;;
    MLXVLM_MAIN_MAX_KV_SIZE)     echo 65536 ;;
    MLXVLM_MAIN_ENABLE_THINKING) echo 1 ;;
    MLXVLM_MAX_TOKENS)           echo 16384 ;;
    MLXVLM_DRAFT_MODEL)          echo "" ;;
    MLXVLM_DRAFT_KIND)           echo mtp ;;
    MLXVLM_DRAFT_BLOCK_SIZE)     echo "" ;;
    GEMMA_TOP_K)                 echo 64 ;;
    PRESET_ALIASES)              echo 1 ;;
    LITELLM_PORT)                echo 11434 ;;
    INSTALL_EMBED)               echo 1 ;;
    ALIAS_EMBED)                 echo bge-m3 ;;
    ALIAS_RERANK)                echo bge-reranker-v2-m3 ;;
    INFINITY_PUBLIC_PORT)        echo 5004 ;;
    INFINITY_BACKEND_PORT)       echo 15004 ;;
    IDLE_TIMEOUT_INFINITY)       echo 900 ;;
    STARTUP_TIMEOUT_INFINITY)    echo 180 ;;
    INFINITY_DEVICE)             echo mps ;;
    INFINITY_BATCH_SIZE)         echo 4 ;;
    INFINITY_DTYPE)              echo float16 ;;
    ML_PUBLIC_PORT)              echo 3003 ;;
    ML_BACKEND_PORT)             echo 13003 ;;
    DOCLING_PUBLIC_PORT)         echo 5001 ;;
    DOCLING_BACKEND_PORT)        echo 15001 ;;
    IDLE_TIMEOUT_IMMICH)         echo 900 ;;
    IDLE_TIMEOUT_DOCLING)        echo 900 ;;
    STARTUP_TIMEOUT_IMMICH)      echo 60 ;;
    STARTUP_TIMEOUT_DOCLING)     echo 120 ;;
    AUTOUPDATE_WEEKDAY)          echo 6 ;;
    AUTOUPDATE_HOUR)             echo 6 ;;
    AUTOUPDATE_MINUTE)           echo 0 ;;
    NODE_EXPORTER_PORT)          echo 9100 ;;
    SILICON_EXPORTER_PORT)       echo 9101 ;;
    ONDEMAND_EXPORTER_PORT)      echo 9103 ;;
    SILICON_SAMPLE_INTERVAL_MS)  echo 10000 ;;
    INSTALL_IMMICH)              echo 1 ;;
    INSTALL_DOCLING)             echo 1 ;;
    INSTALL_EXPORTERS)           echo 0 ;;
    INSTALL_TUI)                 echo 1 ;;
    INSTALL_WATCHDOG)            echo 1 ;;
    WATCHDOG_PRESSURE_THRESHOLD) echo warn ;;
    WATCHDOG_AUTO_RESTORE)       echo 0 ;;
    INSTALL_MQTT)                echo 0 ;;
    MQTT_HOST)                   echo mqtt.home.arpa ;;
    MQTT_PORT)                   echo 1883 ;;
    MQTT_USER)                   echo "" ;;
    MQTT_PASS)                   echo "" ;;
    MQTT_TOPIC_PREFIX)           echo macstudio ;;
    MQTT_DISCOVERY_PREFIX)       echo homeassistant ;;
    MQTT_PUBLISH_INTERVAL_SEC)   echo 10 ;;
    INSTALL_DASHBOARD)           echo 1 ;;
    DASHBOARD_PORT)              echo 8090 ;;
    DASHBOARD_TOKEN)             echo "" ;;
    INSTALL_REMOTE)              echo 1 ;;
    INSTALL_NOVNC)               echo 1 ;;
    NOVNC_PORT)                  echo 6080 ;;
    VNC_FILTER_PORT)             echo 5901 ;;
    VNC_PASSWORD)                echo "" ;;
    INSTALL_PAPERLESS_OCR)       echo 0 ;;
    PAPERLESS_OCR_URL)           echo "" ;;
    PAPERLESS_OCR_TOKEN)         echo "" ;;
    PAPERLESS_OCR_LANGS)         echo ru-RU,en-US ;;
    PAPERLESS_OCR_RECMODE)       echo accurate ;;
    PAPERLESS_OCR_FONT)          echo "/System/Library/Fonts/Supplemental/Arial Unicode.ttf" ;;
    PAPERLESS_OCR_DPI)           echo 300 ;;
    PAPERLESS_OCR_JPEG_Q)        echo 75 ;;
    PAPERLESS_OCR_TEXT_MIN_CHARS) echo 50 ;;
    PAPERLESS_OCR_SMART_NAME)    echo 1 ;;
    PAPERLESS_OCR_ARCHIVE_RETENTION_DAYS) echo 30 ;;
    PAPERLESS_OCR_INBOX)         echo /Users/mac/paperless-ocr/inbox ;;
    PAPERLESS_OCR_ARCHIVE)       echo /Users/mac/paperless-ocr/originals ;;
    PAPERLESS_OCR_ERRORS)        echo /Users/mac/paperless-ocr/errors ;;
    PAPERLESS_OCR_TRIGGER_TAG)   echo ocr:apple ;;
    PAPERLESS_OCR_TRIGGER_FORCE_TAG) echo ocr:apple-force ;;
    PAPERLESS_OCR_VLM_FORCE_TAG) echo ocr:vlm-force ;;
    PAPERLESS_OCR_DONE_TAG)      echo ocr:done ;;
    PAPERLESS_OCR_SUPERSEDED_TAG) echo ocr:superseded ;;
    PAPERLESS_OCR_DELETE_ORIGINAL) echo 0 ;;
    PAPERLESS_OCR_POLL_SEC)      echo 60 ;;
    PAPERLESS_OCR_STABLE_SEC)    echo 30 ;;
    PAPERLESS_OCR_SMB_SHARE)     echo 0 ;;
    PAPERLESS_OCR_SMB_NAME)      echo inbox ;;
    PAPERLESS_OCR_DUPLEX_SUBDIR) echo duplex ;;
    PAPERLESS_OCR_DUPLEX_TIMEOUT_SEC) echo 1800 ;;
    PAPERLESS_OCR_DUPLEX_REVERSE) echo 1 ;;
    PAPERLESS_OCR_VLM_AUTO)      echo 1 ;;
    PAPERLESS_OCR_VLM_MODEL)     echo main-fast ;;
    PAPERLESS_OCR_VLM_URL)       echo "http://127.0.0.1:11434/v1/chat/completions" ;;
    PAPERLESS_OCR_VLM_TAG)       echo ocr:vlm ;;
    PAPERLESS_OCR_VLM_MIN_CHARS) echo 80 ;;
    PAPERLESS_OCR_VLM_MAX_TOKENS) echo 4000 ;;
    PAPERLESS_OCR_VLM_TIMEOUT_SEC) echo 300 ;;
    AUTO_ACCEPT)                 echo 0 ;;
    *)                           echo "" ;;
  esac
}

config_hint() {
  case "$1" in
    IOGPU_WIRED_LIMIT_MB)        echo "GPU wired memory ceiling in MB (28672–30720 on 32 GB; 2048 headroom for OS)" ;;
    INSTALL_MLX)                 echo "1 = install the MLX stack (mlx_vlm.server unified text+images main + LiteLLM gateway) as the primary backend" ;;
    VENV_DIR)                    echo "Where the mlxvlm/litellm/infinity Python venvs live (owned by TARGET_USER)" ;;
    HF_CACHE_DIR)                echo "HuggingFace model cache (HF_HOME) — where downloaded MLX models land" ;;
    ALIAS_MAIN)                  echo "Catalog id of the ONE active main/text model (manage via 'llm-models')" ;;
    MODEL_PIN_MAIN)              echo "1 = keep the main model permanently warm (agentic main load)" ;;
    MAIN_BACKEND_PORT)           echo "Internal port the text engine (mlx_vlm.server) binds; LiteLLM fronts it" ;;
    MAIN_MAX_NUM_SEQS)           echo "Fallback for concurrent decode streams" ;;
    LLM_REQUEST_TIMEOUT)         echo "Per-request timeout in seconds for the text engine + LiteLLM (default 3600 = 60 min; long docs/OCR)" ;;
    TEXT_ENGINE)                 echo "Engine serving 'main': mlx-vlm (mlx_vlm.server — UNIFIED text+images, KV-quant, single-stream; needs a VLM main like gemma-4). The only supported engine" ;;
    MLXVLM_VERSION)              echo "Pinned mlx-vlm for the 'mlxvlm' venv (unified text+vision main). 0.6.3 = the release that FIXED Gemma-4 unified silently dropping images (0.6.2 answered text-only, no error). Bump deliberately + --apply" ;;
    MLXVLM_MAIN_KV_BITS)         echo "KV-cache quant bits for the mlx-vlm unified main: 8 (recommended), 4, or 3.5 with turboquant. empty=off. (Only when TEXT_ENGINE=mlx-vlm)" ;;
    MLXVLM_MAIN_KV_SCHEME)       echo "mlx-vlm main KV quant scheme: uniform | turboquant (fractional bits like 3.5)" ;;
    MLXVLM_MAIN_MAX_KV_SIZE)     echo "mlx-vlm main CONTEXT cap (--max-kv-size) = the OOM guard (bounds prompt+KV, unlike MLXVLM_MAX_TOKENS which only caps generation). Default 65536 (64K) — swap-safe with headroom. Verified swap-safe 2026-07-04 on both 26B-A4B and 12B @ 8-bit KV. 128K is also memory-safe on 26B-A4B (~8.7min prefill at 125K, ~96M swap) but leaves no co-residence headroom at the ceiling; on dense 12B a ~121K prompt fits in RAM but prefill takes ~19min — impractical. Raise to 131072 for max solo context on 26B. empty = model native 262144 (256K, OOM-risky uncapped)" ;;
    MLXVLM_MAIN_ENABLE_THINKING) echo "mlx-vlm main: 1 = think by default (default — so 'main' reasons; OpenWebUI shows it), 0 = off. main-fast is forced thinking-off at the proxy regardless; clients can override per request" ;;
    MLXVLM_MAX_TOKENS)           echo "mlx-vlm server default --max-tokens = generation ceiling for main (default 16384 = effectively unrestricted for chat/long text; model stops at EOS)" ;;
    MLXVLM_DRAFT_MODEL)          echo "mlx-vlm speculative-decoding (MTP) drafter HF repo for the main (--draft-model). empty = OFF (default, recommended). WORKLOAD-DEPENDENT — not a free win: best-case high-acceptance code-gen gave +18% (12B) / +8% (26B-A4B), but a broader decode test 2026-07-04 (long generative output, temp0) showed MTP NET-NEGATIVE — 12B ~23→~19 tok/s (−17%), 26B-A4B fine on short prompts (+7%) but 47→36 tok/s (−23%) on a 6.5K-token prompt (drafter prefill + rejected drafts cost more than they save when acceptance is low). Enable ONLY for a verified high-acceptance workload; leave OFF for general chat. Use the matching assistant, e.g. mlx-community/gemma-4-12B-it-qat-assistant-4bit or gemma-4-26B-A4B-it-qat-assistant-4bit. E2B/E4B MTP is BROKEN in mlx-vlm 0.6.3 (reshape crash) — leave empty for those. Must be downloaded first (hf download); if missing, the main starts WITHOUT the drafter" ;;
    MLXVLM_DRAFT_KIND)           echo "mlx-vlm drafter family (--draft-kind): mtp (Gemma-4) | dflash | eagle3. Default mtp. Only used when MLXVLM_DRAFT_MODEL is set" ;;
    MLXVLM_DRAFT_BLOCK_SIZE)     echo "mlx-vlm drafter block size (--draft-block-size); empty = drafter's configured default. Only used when MLXVLM_DRAFT_MODEL is set" ;;
    GEMMA_TOP_K)                 echo "Gemma reference top_k for main/main-fast (default 64; Gemma's recommended sampling is temp 1.0 / top_p 0.95 / top_k 64). top_k is NOT a native OpenAI param so it rides in extra_body. 0/empty = off" ;;
    PRESET_ALIASES)              echo "1 = also expose the 'main-fast' preset alias (same loaded model as 'main' but thinking-OFF at the proxy — fast non-reasoning chat / tools / web / cron / email)" ;;
    LITELLM_PORT)                echo "Public gateway port apps use (/v1, /v1/messages). Replaces Ollama's :11434" ;;
    INSTALL_EMBED)               echo "1 = run the on-demand Infinity backend serving the BGE embedder + reranker (LiteLLM aliases 'embed' + 'rerank'). Needs INSTALL_MLX=1 for the LiteLLM gateway" ;;
    ALIAS_EMBED)                 echo "Catalog id of the embedding model (role=embed, engine infinity) -> LiteLLM alias 'embed'. empty = embeddings off" ;;
    ALIAS_RERANK)                echo "Catalog id of the reranker (role=rerank, engine infinity) -> LiteLLM alias 'rerank'. empty = rerank off" ;;
    IDLE_TIMEOUT_INFINITY)       echo "Seconds before the Infinity (embed+rerank) backend sleeps (default 900); -1 = never sleep" ;;
    INFINITY_DEVICE)             echo "Torch device for Infinity: mps (Apple GPU, default), cpu, or auto" ;;
    INFINITY_BATCH_SIZE)         echo "Infinity max batch size per forward pass (default 4 — plenty for a single user; raise for heavy parallel load, lower still if MPS memory is tight)" ;;
    INFINITY_DTYPE)              echo "Infinity model weight precision: float16 (default — ~half the RAM of float32, ample for BGE) or float32" ;;
    IDLE_TIMEOUT_IMMICH)         echo "Seconds before immich-ml backend is put to sleep" ;;
    IDLE_TIMEOUT_DOCLING)        echo "Seconds before docling-serve backend is put to sleep" ;;
    AUTOUPDATE_WEEKDAY)          echo "launchd weekday: 0=Sun 1=Mon … 6=Sat" ;;
    AUTO_ACCEPT)                 echo "1 = skip all 'press Enter to proceed' prompts in TUI" ;;
    INSTALL_TUI)                 echo "Install mactop + macmon (live TUI for GPU/ANE/CPU/power; needs sudo)" ;;
    WATCHDOG_PRESSURE_THRESHOLD) echo "warn | critical — when watchdog offloads optional services" ;;
    SILICON_SAMPLE_INTERVAL_MS)  echo "Silicon sampler cadence in ms (default 10000). macmon averages over the interval — match the MQTT/Prometheus cadence; longer = less load AND more representative values" ;;
    INSTALL_MQTT)                echo "1 = run the MQTT bridge (publishes runtime data + Home Assistant autodiscovery; lets HA switch the main model). Needs MQTT_HOST set" ;;
    MQTT_HOST)                   echo "MQTT broker host/IP for the bridge (e.g. mqtt.home.arpa). Empty = bridge idles" ;;
    MQTT_PORT)                   echo "MQTT broker port (default 1883, plain TCP — home network)" ;;
    MQTT_USER)                   echo "MQTT username (empty = anonymous). Stored plaintext in this 644 conf — use a dedicated low-privilege broker user" ;;
    MQTT_PASS)                   echo "MQTT password (empty = none). Plaintext in this 644 conf; avoid \$ and quote if it has spaces" ;;
    MQTT_TOPIC_PREFIX)           echo "Base topic for state/command (default 'macstudio' -> macstudio/state, macstudio/model/set)" ;;
    MQTT_DISCOVERY_PREFIX)       echo "Home Assistant MQTT discovery prefix (default 'homeassistant' — match HA's mqtt integration setting)" ;;
    MQTT_PUBLISH_INTERVAL_SEC)   echo "Seconds between fast telemetry publishes (power/status/model; default 10). Version/update checks run every 6 h" ;;
    INSTALL_DASHBOARD)           echo "1 = run the web dashboard (browser control of models / services / settings / logs / telemetry) on :8090. Token-protected; the SSH TUI stays fully authoritative" ;;
    DASHBOARD_PORT)              echo "Public port the web dashboard binds (default 8090)" ;;
    DASHBOARD_TOKEN)             echo "Web-dashboard access token (browser login + 'Authorization: Bearer' for curl). Plaintext in this 644 conf — LAN-only, like MQTT_PASS. Empty = auto-generated on the next --apply; clear it + --apply to rotate (logs out all browsers)" ;;
    INSTALL_REMOTE)              echo "1 = enable macOS built-in Screen Sharing (VNC on :5900) so you can control the headless desktop from a VNC client. Sets a legacy VNC password (VNC_PASSWORD). Also starts com.local.vncfilter on VNC_FILTER_PORT — connect Windows VNC clients (RealVNC/TightVNC) there, NOT :5900, for password-only login (macOS offers its Apple/ARD account auth FIRST on :5900, which prompts for a real macOS username+password instead). One-way: toggling to 0 does NOT disable Screen Sharing (turn it off in System Settings, or 'kickstart -deactivate')" ;;
    INSTALL_NOVNC)               echo "1 = also run the tiny browser VNC bridge (noVNC via websockify, ~30 MB) on NOVNC_PORT, so you can control the desktop from any browser at http://<mac>:<port>/vnc.html with NO client install. Needs INSTALL_REMOTE=1 (it bridges through VNC_FILTER_PORT, not :5900 directly — noVNC's Apple/ARD auth path needs WebCrypto, unavailable over plain HTTP). Uses the same VNC_PASSWORD" ;;
    NOVNC_PORT)                  echo "Public HTTP port the noVNC browser bridge binds (default 6080). Open http://<mac>:6080/vnc.html" ;;
    VNC_FILTER_PORT)             echo "Port for com.local.vncfilter (default 5901): a tiny proxy in front of :5900 that strips macOS' Apple/ARD auth offer from the RFB handshake, leaving only VNC-password auth. Point Windows VNC clients AND the noVNC bridge here instead of :5900 so both use the single shared VNC_PASSWORD" ;;
    VNC_PASSWORD)                echo "Screen Sharing / VNC password (max 8 chars — legacy VNC/DES limit). Plaintext in this 644 conf — LAN-only, like MQTT_PASS. Empty = auto-generated (8 random chars) on the next --apply; used by both the Windows VNC client and the browser (noVNC), both connecting via VNC_FILTER_PORT" ;;
    INSTALL_PAPERLESS_OCR)       echo "1 = run the Apple-Vision searchable-PDF worker for paperless-ngx (gateway inbox + tag-triggered retro-fix). Opt-in (default 0): needs PAPERLESS_OCR_URL + _TOKEN" ;;
    PAPERLESS_OCR_URL)           echo "Base URL of your paperless-ngx (e.g. http://paperless.home.arpa:8000). Empty = worker idles" ;;
    PAPERLESS_OCR_TOKEN)         echo "paperless-ngx API token (Settings -> API token). Plaintext in this 644 conf — LAN-only, like MQTT_PASS. Empty = worker idles" ;;
    PAPERLESS_OCR_LANGS)         echo "Apple Vision recognition languages, comma-separated BCP-47 (e.g. ru-RU,en-US). Multiple allowed (unlike ocrmypdf-appleocr)" ;;
    PAPERLESS_OCR_RECMODE)       echo "Vision recognition level: accurate (default) or fast. NOT 'livetext' (VisionKit, crashes headless under launchd)" ;;
    PAPERLESS_OCR_FONT)          echo "Path to a Unicode/Cyrillic-capable TTF embedded for the invisible text layer (default: macOS 'Arial Unicode.ttf')" ;;
    PAPERLESS_OCR_DPI)           echo "Render DPI for OCR (default 300 = match a typical scanner; verified: 300 fixes small-text errors that 200 misses, same speed). Above the scan's native DPI only bloats the file — no quality gain" ;;
    PAPERLESS_OCR_JPEG_Q)        echo "JPEG quality (1-100) of the embedded page image in the output PDF (default 75)" ;;
    PAPERLESS_OCR_TEXT_MIN_CHARS) echo "Digital-born detection: a PDF with at least this many text chars/page is passed through UNTOUCHED (no re-OCR); below it = treated as a scan and OCR'd. Default 50" ;;
    PAPERLESS_OCR_SMART_NAME)    echo "1 = after OCR, ask the LLM for a short descriptive name from the text and use it as the paperless title AND the archived-original filename (instead of 'SCN_0001'). 0 = keep the scanner's filename. Adds one quick LLM call per document" ;;
    PAPERLESS_OCR_ARCHIVE_RETENTION_DAYS) echo "Delete archived original scans older than this many days (default 30; 0 = keep forever). The searchable copy already lives in paperless — this only trims the local pristine-scan safety net" ;;
    PAPERLESS_OCR_INBOX)         echo "Gateway watch folder: drop PDFs/images here -> OCR'd + uploaded to paperless" ;;
    PAPERLESS_OCR_ARCHIVE)       echo "Where pristine originals are kept after the gateway processes them" ;;
    PAPERLESS_OCR_ERRORS)        echo "Where the gateway moves files it failed to OCR/upload" ;;
    PAPERLESS_OCR_TRIGGER_TAG)   echo "Retro-fix trigger: existing paperless docs with this tag get re-OCR'd with Apple Vision — but SKIPPED if they already have a text layer (safe to mass-tag). Use the -force tag to re-OCR anyway" ;;
    PAPERLESS_OCR_TRIGGER_FORCE_TAG) echo "Retro-fix FORCE trigger (Apple Vision): re-OCR even if the doc already has text — the only way to replace an existing (e.g. Tesseract mojibake) layer. Default ocr:apple-force" ;;
    PAPERLESS_OCR_VLM_FORCE_TAG) echo "Retro-fix FORCE trigger (Gemma-4 VLM): re-OCR with the VLM even if the doc already has text (handwriting/math). Default ocr:vlm-force" ;;
    PAPERLESS_OCR_DONE_TAG)      echo "Tag applied to the new searchable copy after retro-fix" ;;
    PAPERLESS_OCR_SUPERSEDED_TAG) echo "Tag applied to the OLD document after a retro-fix copy is created" ;;
    PAPERLESS_OCR_DELETE_ORIGINAL) echo "1 = delete the old paperless doc after retro-fix (default 0 = keep it, tagged superseded)" ;;
    PAPERLESS_OCR_POLL_SEC)      echo "Retro-fix poll interval in seconds (gateway polls every min(10,this))" ;;
    PAPERLESS_OCR_STABLE_SEC)    echo "Gateway waits until an inbox file is unmodified AND not held open (SMB) for this many seconds before OCR — prevents processing half-scanned files. Raise if your scanner pauses long between pages (default 30)" ;;
    PAPERLESS_OCR_SMB_SHARE)     echo "1 = --apply enables macOS File Sharing (smbd) and shares the inbox folder over SMB (no guest) so a network scanner can drop files in. Default 0 (off). Toggling back to 0 does NOT remove the share (do that with 'sudo sharing -r <name>')" ;;
    PAPERLESS_OCR_SMB_NAME)      echo "SMB share name for the inbox folder (Windows: \\\\<mac>\\<name>). Default 'inbox'" ;;
    PAPERLESS_OCR_DUPLEX_SUBDIR) echo "Inbox subfolder for double-sided jobs: scan fronts then backs here; the two files are interleaved into one document (for simplex ADFs). Default 'duplex'" ;;
    PAPERLESS_OCR_DUPLEX_TIMEOUT_SEC) echo "If only one file waits in the duplex folder this long, treat it as single-sided (the backs pass never came). Default 1800 (30 min)" ;;
    PAPERLESS_OCR_DUPLEX_REVERSE) echo "1 = reverse the 2nd (backs) file when interleaving (normal after flipping the stack). Set 0 if pages come out mis-ordered" ;;
    PAPERLESS_OCR_VLM_AUTO)      echo "1 = auto-fallback to the vision LLM when Apple Vision reads suspiciously little (handwriting/forms). 0 = only the '$(config_default PAPERLESS_OCR_VLM_TAG)' tag / '_vlm' filename force it. Benchmark: Vision wins on print, VLM on handwriting/math, VLMs loop on dense tables (docs/ocr-benchmark.md)" ;;
    PAPERLESS_OCR_VLM_MODEL)     echo "Gateway model alias for the VLM fallback route (default main-fast = Gemma-4, thinking-off). Reads handwriting/math; no per-word boxes (full-page invisible layer)" ;;
    PAPERLESS_OCR_VLM_URL)       echo "LiteLLM gateway chat-completions URL for the VLM route (default http://127.0.0.1:11434/v1/chat/completions). Empty = VLM route off" ;;
    PAPERLESS_OCR_VLM_TAG)       echo "Retro-fix tag that routes a doc to the Gemma-4 VLM (default ocr:vlm) — but SKIPPED if it already has text; use ocr:vlm-force to re-OCR anyway. Inbox files: '_vlm' in the filename picks the VLM route" ;;
    PAPERLESS_OCR_VLM_MIN_CHARS) echo "Auto-fallback threshold: if Apple Vision yields fewer than this many text chars/page, re-OCR with the VLM (default 80). Raise if blank/near-blank scans wrongly trigger the VLM" ;;
    PAPERLESS_OCR_VLM_MAX_TOKENS) echo "Max tokens for the VLM transcription per page (default 4000)" ;;
    PAPERLESS_OCR_VLM_TIMEOUT_SEC) echo "HTTP timeout (seconds) for a VLM page request (default 300; a big model can be slow)" ;;
    *)                           echo "" ;;
  esac
}

# --- Colors -----------------------------------------------------------------
if [ -t 1 ]; then
  C_DIM='\033[2m'; C_BOLD='\033[1m'
  C_RED='\033[0;31m'; C_GRN='\033[0;32m'; C_YEL='\033[0;33m'; C_BLU='\033[0;34m'
  C_RST='\033[0m'
else
  C_DIM=; C_BOLD=; C_RED=; C_GRN=; C_YEL=; C_BLU=; C_RST=
fi

# --- Logging & prompts ------------------------------------------------------
log()  { printf "${C_BLU}[setup]${C_RST} %s\n" "$*"; }
ok()   { printf "${C_GRN}[ ok ]${C_RST} %s\n" "$*"; }
warn() { printf "${C_YEL}[warn]${C_RST} %s\n" "$*" >&2; }
err()  { printf "${C_RED}[err ]${C_RST} %s\n" "$*" >&2; }
dbg()  { [ "${VERBOSE:-0}" = 1 ] && printf "${C_DIM}[dbg ]${C_RST} %s\n" "$*" >&2; return 0; }

APPLY_MODE=0
INTERACTIVE=1
VERBOSE=0
DEBUG=0

confirm() {
  # confirm "Do the thing?"  → returns 0 (yes) or 1 (no)
  local prompt="$1"
  if [ "$INTERACTIVE" = 0 ] || [ "${AUTO_ACCEPT:-0}" = 1 ]; then
    return 0
  fi
  local ans
  read -r -p "$prompt [Y/n] " ans
  case "${ans:-y}" in
    y|Y|yes|YES) return 0 ;;
    *)           return 1 ;;
  esac
}

need_root() {
  # No-op: argv dispatch at the bottom of the file already self-elevates.
  # Kept as a documentation shim in case someone calls a function directly.
  [ "$(id -u)" -eq 0 ] || { err "must run as root"; exit 1; }
}

# --- Hash helpers -----------------------------------------------------------
hash_file() {
  if [ -f "$1" ]; then /usr/bin/shasum -a 256 "$1" | awk '{print $1}'; else echo missing; fi
}

install_if_different() {
  # install_if_different <src> <dst> <mode> [<owner>]
  local src=$1 dst=$2 mode=$3 owner=${4:-root:wheel}
  if [ "$(hash_file "$src")" = "$(hash_file "$dst")" ]; then
    dbg "unchanged: $dst"
    return 1   # no change
  fi
  dbg "installing: $src → $dst (mode $mode, owner $owner)"
  /bin/mkdir -p "$(dirname "$dst")"
  /usr/bin/install -m "$mode" -o "${owner%:*}" -g "${owner#*:}" "$src" "$dst"
  return 0     # changed
}

render_template() {
  # render_template <src> <dst> <mode> [<owner>]
  # Substitutes @KEY@ from env. Writes to dst only if content changed.
  #
  # Uses bash parameter expansion, NOT one big `sed` program: macOS/BSD sed has
  # a ~2 KB compiled-program limit and once enough @KEY@ rules accumulate it
  # silently fails ("unterminated substitute pattern") and emits NOTHING — which
  # would then overwrite every rendered plist with an empty file (= "daemons
  # won't load"). Literal bash replace has no length limit and needs no
  # delimiter/metachar escaping. A guard below also refuses to ever write an
  # empty file over a non-empty template.
  local src=$1 dst=$2 mode=$3 owner=${4:-root:wheel}
  local tmp content val k
  tmp=$(/usr/bin/mktemp -t macstudio-render)
  # $(...) strips trailing newlines; the printf-x trick preserves them.
  content=$(/bin/cat "$src"; printf 'x'); content=${content%x}
  for k in "${CONFIG_KEYS[@]}" TOTAL_RAM_GB IDLE_MIN_IMMICH IDLE_MIN_DOCLING AUTOUPDATE_HUMAN; do
    val=${!k:-}
    content=${content//"@${k}@"/$val}
  done
  printf '%s' "$content" >"$tmp"
  if [ ! -s "$tmp" ] && [ -s "$src" ]; then
    warn "render produced empty output for $dst — keeping existing file (not overwriting)"
    /bin/rm -f "$tmp"
    return 1
  fi
  if [ "$(hash_file "$tmp")" = "$(hash_file "$dst")" ]; then
    dbg "template unchanged: $dst"
    rm -f "$tmp"
    return 1   # no change
  fi
  dbg "rendering template: $src → $dst (mode $mode, owner $owner)"
  /bin/mkdir -p "$(dirname "$dst")"
  /bin/chmod "$mode" "$tmp"
  /usr/sbin/chown "$owner" "$tmp" 2>/dev/null || true
  /bin/mv -f "$tmp" "$dst"
  return 0     # changed
}

# --- Config file management -------------------------------------------------
# Shell-quote a value so `. macstudio.conf` survives spaces and shell
# metacharacters (& $ ` " ' etc.) in free-form values like MQTT_PASS — every
# wrapper sources this file (some under `set -e`), so an unquoted `&`/space
# would be parsed as a command and abort the daemon. `printf %q` is a bash
# builtin (3.2+) that emits reusable shell input: simple values stay bare (so
# numbers/paths/ids still parse), only specials get escaped. Empty -> ''.
conf_quote() {
  if [ -z "$1" ]; then printf "''"; else printf '%q' "$1"; fi
}

write_default_config() {
  /bin/mkdir -p "$(dirname "$CONF_FILE")"
  {
    echo "# /usr/local/etc/macstudio.conf — managed by setup.sh"
    echo "# Edit via: sudo bash setup.sh → menu 2, or sudo bash setup.sh --apply"
    echo "# Free-form edits are respected; unknown keys are preserved."
    echo
    for k in "${CONFIG_KEYS[@]}"; do
      printf '%s=%s\n' "$k" "$(conf_quote "$(config_default "$k")")"
    done
  } >"$CONF_FILE"
  /bin/chmod 644 "$CONF_FILE"
}

load_config() {
  if [ ! -f "$CONF_FILE" ]; then
    dbg "config missing, writing defaults to $CONF_FILE"
    write_default_config
  else
    dbg "loading config from $CONF_FILE"
  fi
  # Fill in any missing keys from defaults without clobbering user values.
  local missing=()
  for k in "${CONFIG_KEYS[@]}"; do
    if ! /usr/bin/grep -qE "^${k}=" "$CONF_FILE"; then
      missing+=("$k")
    fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    dbg "added missing config keys: ${missing[*]}"
    {
      echo ""
      echo "# keys added on $(date '+%F')"
      for k in "${missing[@]}"; do
        printf '%s=%s\n' "$k" "$(conf_quote "$(config_default "$k")")"
      done
    } >>"$CONF_FILE"
  fi
  # shellcheck disable=SC1090
  . "$CONF_FILE"
  # Export every key so render_template can reference them as env vars.
  for k in "${CONFIG_KEYS[@]}"; do export "$k"; done
  # Derived convenience vars for motd and the like
  local bytes mb
  bytes=$(/usr/sbin/sysctl -n hw.memsize 2>/dev/null || echo 0)
  mb=$(( bytes / 1024 / 1024 ))
  export TOTAL_RAM_GB=$(( (mb + 512) / 1024 ))
  export IDLE_MIN_IMMICH=$(( IDLE_TIMEOUT_IMMICH / 60 ))
  export IDLE_MIN_DOCLING=$(( IDLE_TIMEOUT_DOCLING / 60 ))
  local dow_names=(Sun Mon Tue Wed Thu Fri Sat)
  export AUTOUPDATE_HUMAN="$(printf '%s %02d:%02d' "${dow_names[$AUTOUPDATE_WEEKDAY]:-?}" "$AUTOUPDATE_HOUR" "$AUTOUPDATE_MINUTE")"
  # Compute ACTIVE_LABELS — the subset of ALL_LABELS the current config says
  # should be installed. Used by status/service-control menus. ALL_LABELS is
  # still the authoritative list for plist cleanup on toggle-off.
  ACTIVE_LABELS=()
  local _lbl
  for _lbl in "${ALL_LABELS[@]}"; do
    case "$_lbl" in
      com.local.mlxvlm.main)
        [ "${INSTALL_MLX:-1}" = 1 ] || continue ;;
      com.local.litellm.*)
        [ "${INSTALL_MLX:-1}" = 1 ] || continue ;;
      com.local.infinity.*)
        [ "${INSTALL_EMBED:-1}" = 1 ] || continue ;;
      com.local.immich.*)  [ "${INSTALL_IMMICH:-1}"  = 1 ] || continue ;;
      com.local.docling.*) [ "${INSTALL_DOCLING:-1}" = 1 ] || continue ;;
      com.local.node.exporter|com.local.silicon.exporter|com.local.ondemand.exporter)
        [ "${INSTALL_EXPORTERS:-1}" = 1 ] || continue ;;
      com.local.llm.watchdog)
        [ "${INSTALL_WATCHDOG:-1}" = 1 ] || continue ;;
      com.local.mqtt.bridge)
        [ "${INSTALL_MQTT:-0}" = 1 ] || continue ;;
      com.local.dashboard)
        [ "${INSTALL_DASHBOARD:-1}" = 1 ] || continue ;;
      com.local.vncfilter)
        [ "${INSTALL_REMOTE:-1}" = 1 ] || continue ;;
      com.local.novnc)
        { [ "${INSTALL_NOVNC:-1}" = 1 ] && [ "${INSTALL_REMOTE:-1}" = 1 ]; } || continue ;;
      com.local.paperless.ocr)
        [ "${INSTALL_PAPERLESS_OCR:-0}" = 1 ] || continue ;;
    esac
    ACTIVE_LABELS+=("$_lbl")
  done
}

save_config_key() {
  # save_config_key KEY VALUE — edit the single line in-place. The value is
  # single-quoted (conf_quote) so it survives sourcing; a plain bash read loop
  # rewrites the matching line so arbitrary metacharacters in VALUE are never
  # interpreted (awk -v would mangle backslashes / C-escapes).
  local key=$1 value=$2 qv
  qv=$(conf_quote "$value")
  if /usr/bin/grep -qE "^${key}=" "$CONF_FILE"; then
    local tmp line; tmp=$(/usr/bin/mktemp)
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        "$key="*) printf '%s=%s\n' "$key" "$qv" ;;
        *)        printf '%s\n' "$line" ;;
      esac
    done <"$CONF_FILE" >"$tmp"
    /bin/mv -f "$tmp" "$CONF_FILE"
  else
    printf '%s=%s\n' "$key" "$qv" >>"$CONF_FILE"
  fi
  /bin/chmod 644 "$CONF_FILE"
}

# --- label → log file mapping ---------------------------------------------
label_log() {
  case "$1" in
    com.local.mlxvlm.main)       echo "$LOG_DIR/mlxvlm-main.log" ;;
    com.local.litellm.proxy)     echo "$LOG_DIR/litellm.log" ;;
    com.local.infinity.proxy)    echo "$LOG_DIR/infinity-proxy.log" ;;
    com.local.infinity.serve)    echo "$LOG_DIR/infinity-serve.log" ;;
    com.local.immich.proxy)      echo "$LOG_DIR/immich-proxy.log" ;;
    com.local.immich.ml)         echo "$LOG_DIR/immich-ml.log" ;;
    com.local.docling.proxy)     echo "$LOG_DIR/docling-proxy.log" ;;
    com.local.docling.serve)     echo "$LOG_DIR/docling-serve.log" ;;
    com.local.node.exporter)     echo "$LOG_DIR/node-exporter.log" ;;
    com.local.silicon.exporter)  echo "$LOG_DIR/silicon-exporter.log" ;;
    com.local.ondemand.exporter) echo "$LOG_DIR/ondemand-exporter.log" ;;
    com.local.llm.watchdog)      echo "$LOG_DIR/watchdog.log" ;;
    com.local.preventsleep)      echo "$LOG_DIR/preventsleep.log" ;;
    com.local.iogpu.wiredlimit)  echo "$LOG_DIR/iogpu-wired-limit.log" ;;
    com.local.weekly.autoupdate) echo "$LOG_DIR/autoupdate.log" ;;
    com.local.mqtt.bridge)       echo "$LOG_DIR/mqtt-bridge.log" ;;
    com.local.dashboard)         echo "$LOG_DIR/dashboard.log" ;;
    com.local.vncfilter)         echo "$LOG_DIR/vncfilter.log" ;;
    com.local.novnc)             echo "$LOG_DIR/novnc.log" ;;
    com.local.paperless.ocr)     echo "$LOG_DIR/paperless-ocr.log" ;;
    *) echo "$LOG_DIR/${1#com.local.}.log" ;;
  esac
}

# --- launchctl helpers ------------------------------------------------------
daemon_pid() {
  /bin/launchctl print "system/$1" 2>/dev/null \
    | awk '/^[[:space:]]*pid[[:space:]]*=/{print $3; exit}'
}
daemon_loaded()  { /bin/launchctl print "system/$1" >/dev/null 2>&1; }
daemon_running() { local p; p=$(daemon_pid "$1"); [ -n "$p" ] && [ "$p" != 0 ]; }
label_disabled() {
  /bin/launchctl print-disabled system 2>/dev/null \
    | /usr/bin/grep -qE "\"$1\"[[:space:]]*=>[[:space:]]*true"
}

bootstrap_plist() {
  local label=$1 plist="$PLIST_DIR/$1.plist"
  daemon_loaded "$label" && return 0
  /bin/launchctl bootstrap system "$plist" 2>/dev/null \
    && ok "bootstrapped $label" \
    || warn "bootstrap failed: $label"
}

bootout_plist() {
  local label=$1
  daemon_loaded "$label" || return 0
  /bin/launchctl bootout "system/$label" 2>/dev/null || true
}

disable_plist() {
  # Persistent override — survives reboot AND a later --apply/bootstrap.
  # KeepAlive/RunAtLoad in the plist cannot override this; only enable_plist can.
  local label=$1
  /bin/launchctl disable "system/$label" 2>/dev/null || true
}

enable_plist() {
  local label=$1
  /bin/launchctl enable "system/$label" 2>/dev/null || true
}

reload_plist_if_changed() {
  # reload_plist_if_changed <label> <"changed"|"unchanged">
  local label=$1 status=$2
  case "$status" in
    changed)
      if daemon_loaded "$label"; then bootout_plist "$label"; fi
      bootstrap_plist "$label"
      ;;
    unchanged)
      if ! daemon_loaded "$label"; then bootstrap_plist "$label"; fi
      ;;
  esac
}

# ===========================================================================
# Idempotent "apply" functions — each is safe to re-run
# ===========================================================================

ensure_dirs() {
  /bin/mkdir -p "$LOG_DIR" "$LIBEXEC_DIR" "$SBIN_DIR" "$BIN_DIR" "$PLIST_DIR" \
                "$(dirname "$CONF_FILE")"
  /bin/chmod 755 "$LOG_DIR"
  # Daemons run as TARGET_USER (via plist UserName); launchd opens
  # StandardOutPath/StandardErrorPath as that user, so the log dir must be
  # writable by it. Without this, every daemon fails init with EX_CONFIG.
  /usr/sbin/chown -R "${TARGET_USER:-mac}:admin" "$LOG_DIR" 2>/dev/null || true
}

ensure_xcode_clt() {
  # A fresh macOS has /usr/bin/git as a stub that pops a GUI prompt. The
  # softwareupdate flow below is the documented headless install path.
  if /usr/bin/xcode-select -p >/dev/null 2>&1; then
    ok "Xcode Command Line Tools present"
    return 0
  fi
  log "Xcode Command Line Tools missing — installing headlessly (several minutes)"
  /usr/bin/touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
  local label
  label=$(/usr/sbin/softwareupdate -l 2>/dev/null \
    | /usr/bin/grep -E 'Label:.*Command Line Tools for Xcode' \
    | /usr/bin/sed -E 's/.*Label: //; s/ *$//' \
    | /usr/bin/head -1)
  if [ -z "$label" ]; then
    warn "softwareupdate did not advertise a Command Line Tools package"
    warn "fallback: run  xcode-select --install  at the GUI and re-run setup.sh"
    /bin/rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
    return 1
  fi
  /usr/sbin/softwareupdate -i "$label" --verbose >/dev/null 2>&1 \
    || warn "softwareupdate -i '$label' exited non-zero"
  /bin/rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
  if /usr/bin/xcode-select -p >/dev/null 2>&1; then
    ok "Xcode Command Line Tools installed: $label"
  else
    warn "Xcode Command Line Tools install did not complete"
    return 1
  fi
}

ensure_homebrew() {
  if command -v brew >/dev/null 2>&1 || [ -x /opt/homebrew/bin/brew ]; then
    ok "homebrew present"
    return 0
  fi
  log "homebrew missing — running official installer non-interactively"
  # Homebrew's installer aborts if invoked as root, so it must run as
  # TARGET_USER. NONINTERACTIVE=1 stops the "Press RETURN to continue"
  # prompt, but the installer still shells out to sudo for chown /opt/homebrew
  # and writing /etc/paths.d/homebrew. Grant passwordless sudo *for the
  # duration of this install only*, then revoke.
  local sudoers_tmp=/etc/sudoers.d/99-macstudio-bootstrap
  /bin/cat >"$sudoers_tmp" <<EOF
${TARGET_USER} ALL=(ALL) NOPASSWD: ALL
EOF
  /usr/sbin/chown root:wheel "$sudoers_tmp"
  /bin/chmod 440 "$sudoers_tmp"
  local rc=0
  /usr/bin/sudo -u "$TARGET_USER" -H \
    /usr/bin/env NONINTERACTIVE=1 CI=1 \
    /bin/bash -c "$(/usr/bin/curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
    >/dev/null 2>&1 || rc=$?
  /bin/rm -f "$sudoers_tmp"
  if [ "$rc" -ne 0 ] || [ ! -x /opt/homebrew/bin/brew ]; then
    warn "homebrew install failed (rc=$rc). Install manually, then re-run:"
    warn '  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
    return 1
  fi
  # Persist brew shellenv in TARGET_USER's .zprofile for future SSH logins.
  local zprofile="$TARGET_HOME/.zprofile"
  if [ ! -f "$zprofile" ] || ! /usr/bin/grep -q 'brew shellenv' "$zprofile"; then
    {
      [ -f "$zprofile" ] && echo ''
      echo '# Added by macstudio-llm setup.sh'
      echo 'eval "$(/opt/homebrew/bin/brew shellenv zsh)"'
    } >> "$zprofile"
    /usr/sbin/chown "$TARGET_USER:staff" "$zprofile"
  fi
  ok "homebrew installed"
}

brew_() { sudo -u "$TARGET_USER" -H /opt/homebrew/bin/brew "$@"; }

ensure_formula() {
  local f=$1
  if brew_ list --formula "$f" >/dev/null 2>&1; then
    ok "brew: $f present"
  else
    log "brew install $f"
    brew_ install "$f" || warn "brew install $f failed"
  fi
}

ensure_formulas() {
  # The MLX stack is the primary backend and runs from Python venvs, not a brew formula.
  [ "${INSTALL_EXPORTERS:-1}" = 1 ] && ensure_formula node_exporter
  [ "${INSTALL_TUI:-1}" = 1 ] && ensure_formula mactop
  # macmon doubles as the silicon-exporter's sampler (sys power, temps, real
  # GPU usage), so the exporters need it even when the TUI tools are off.
  if [ "${INSTALL_TUI:-1}" = 1 ] || [ "${INSTALL_EXPORTERS:-1}" = 1 ]; then
    ensure_formula macmon
  fi
}

ensure_modern_python() {
  # The MLX stack (mlx-vlm, litellm) and docling-serve all need
  # Python ≥ 3.10; macOS ships /usr/bin/python3 at 3.9. Install python@3.12
  # via brew so those venvs have a compatible interpreter. Skip only if both
  # the MLX stack and docling are off.
  [ "${INSTALL_MLX:-1}" = 1 ] || [ "${INSTALL_DOCLING:-1}" = 1 ] || return 0
  if [ -x /opt/homebrew/bin/python3.12 ]; then
    ok "python@3.12 present (needed by MLX/docling venvs)"
    return 0
  fi
  ensure_formula python@3.12
}

ensure_immich_venv() {
  [ "${INSTALL_IMMICH:-1}" = 1 ] || return 0
  if [ -x "$IMMICH_PROJECT_DIR/.venv/bin/python" ]; then
    ok "immich-ml venv present"
    return 0
  fi
  warn "immich-ml venv missing at $IMMICH_PROJECT_DIR/.venv — create it manually:"
  warn "  cd $IMMICH_PROJECT_DIR && python3 -m venv .venv && .venv/bin/pip install -r requirements.txt"
}

ensure_docling_venv() {
  [ "${INSTALL_DOCLING:-1}" = 1 ] || return 0
  local pydir="${DOCLING_PROJECT_DIR:-$TARGET_HOME/projects/docling-serve}"
  if [ -x "$pydir/.venv/bin/docling-serve" ]; then
    ok "docling-serve venv present at $pydir"
    return 0
  fi
  if [ ! -x /opt/homebrew/bin/python3.12 ]; then
    warn "docling-serve needs python@3.12, which is not installed yet."
    warn "Re-run 'sudo bash setup.sh --apply' after Homebrew is available."
    return 1
  fi
  log "Building docling-serve venv at $pydir (~2 GB of wheels; several minutes)"
  /usr/bin/sudo -u "$TARGET_USER" -H /bin/mkdir -p "$pydir"
  if [ ! -x "$pydir/.venv/bin/python" ]; then
    /usr/bin/sudo -u "$TARGET_USER" -H /opt/homebrew/bin/python3.12 -m venv "$pydir/.venv"
  fi
  /usr/bin/sudo -u "$TARGET_USER" -H "$pydir/.venv/bin/pip" install --upgrade pip wheel >/dev/null 2>&1 \
    || warn "pip upgrade inside venv returned non-zero"
  log "pip install 'docling[ocrmac,vlm,htmlrender,easyocr]' 'docling-serve[ui]' — this downloads torch/transformers/easyocr"
  if ! /usr/bin/sudo -u "$TARGET_USER" -H "$pydir/.venv/bin/pip" install \
        'docling[ocrmac,vlm,htmlrender,easyocr]' 'docling-serve[ui]' >/var/log/macstudio/docling-venv-install.log 2>&1; then
    warn "docling pip install failed; see /var/log/macstudio/docling-venv-install.log"
    return 1
  fi
  if [ -x "$pydir/.venv/bin/docling-serve" ]; then
    ok "docling-serve venv built at $pydir (first backend wake will also fetch ~1 GB of models from HuggingFace)"
  else
    warn "docling pip install succeeded but .venv/bin/docling-serve is missing"
    return 1
  fi
}

ensure_paperless_ocr_venv() {
  # Small venv for the Apple-Vision searchable-PDF worker (com.local.paperless.ocr).
  # ocrmac drives Apple Vision; pymupdf builds the invisible Unicode text layer;
  # requests talks to paperless-ngx. No brew deps (pymupdf bundles its rendering).
  [ "${INSTALL_PAPERLESS_OCR:-0}" = 1 ] || return 0
  local venv="${VENV_DIR:-/Users/mac/.macstudio-venvs}/paperlessocr"
  if [ -x "$venv/bin/python" ] && "$venv/bin/python" -c 'import ocrmac, fitz, requests, fontTools' >/dev/null 2>&1; then
    ok "paperless-ocr venv present at $venv"
    return 0
  fi
  if [ ! -x /opt/homebrew/bin/python3.12 ]; then
    warn "paperless-ocr needs python@3.12, which is not installed yet."
    warn "Re-run 'sudo bash setup.sh --apply' after Homebrew is available."
    return 1
  fi
  log "Building paperless-ocr venv at $venv (ocrmac + pymupdf + requests)"
  /usr/bin/sudo -u "$TARGET_USER" -H /bin/mkdir -p "$venv"
  if [ ! -x "$venv/bin/python" ]; then
    /usr/bin/sudo -u "$TARGET_USER" -H /opt/homebrew/bin/python3.12 -m venv "$venv"
  fi
  /usr/bin/sudo -u "$TARGET_USER" -H "$venv/bin/pip" install --upgrade pip wheel >/dev/null 2>&1 \
    || warn "pip upgrade inside paperless-ocr venv returned non-zero"
  if ! /usr/bin/sudo -u "$TARGET_USER" -H "$venv/bin/pip" install \
        ocrmac pymupdf requests fonttools >/var/log/macstudio/paperless-ocr-venv-install.log 2>&1; then
    warn "paperless-ocr pip install failed; see /var/log/macstudio/paperless-ocr-venv-install.log"
    return 1
  fi
  if "$venv/bin/python" -c 'import ocrmac, fitz, requests, fontTools' >/dev/null 2>&1; then
    ok "paperless-ocr venv built at $venv"
  else
    warn "paperless-ocr pip install succeeded but ocrmac/pymupdf/requests won't import"
    return 1
  fi
}

ensure_paperless_ocr_share() {
  # Opt-in: enable macOS File Sharing (smbd) and share the inbox folder over SMB so a
  # network scanner (e.g. Canon MAXIFY) can drop files straight into the gateway. Only
  # ADDS the share; never removes it (toggling SMB_SHARE=0 leaves it — remove manually
  # with `sudo sharing -r <name>`). Idempotent.
  { [ "${INSTALL_PAPERLESS_OCR:-0}" = 1 ] && [ "${PAPERLESS_OCR_SMB_SHARE:-0}" = 1 ]; } || return 0
  local inbox name
  inbox="${PAPERLESS_OCR_INBOX:-$TARGET_HOME/paperless-ocr/inbox}"
  name="${PAPERLESS_OCR_SMB_NAME:-inbox}"
  /usr/bin/sudo -u "$TARGET_USER" -H /bin/mkdir -p "$inbox" 2>/dev/null || true
  # Enable + start the SMB service (harmless if already on).
  /bin/launchctl enable system/com.apple.smbd 2>/dev/null || true
  /bin/launchctl bootstrap system /System/Library/LaunchDaemons/com.apple.smbd.plist 2>/dev/null || true
  if /usr/sbin/sharing -l 2>/dev/null | grep -qF "$inbox"; then
    ok "SMB share for inbox already present ($inbox)"
  elif /usr/sbin/sharing -a "$inbox" -S "$name" -n "$name" -s 001 -g 000 >/dev/null 2>&1; then
    ok "SMB share '$name' → $inbox (SMB only, no guest)"
  else
    warn "could not add SMB share; run manually: sudo /usr/sbin/sharing -a '$inbox' -S $name -s 001 -g 000"
  fi
}

# --- Remote desktop: Screen Sharing (VNC) + browser bridge (noVNC) ---------
ensure_vnc_password() {
  # Generate the Screen Sharing / VNC password ONCE (empty = not yet generated).
  # Legacy VNC (DES) caps the password at 8 chars, so we generate exactly 8.
  # Plaintext in the 644 conf on purpose (LAN-only), like DASHBOARD_TOKEN/MQTT_PASS.
  # Idempotent: an existing password is never touched (rotate by clearing it + --apply,
  # then re-run so ensure_screensharing_enabled pushes the new one into ARD).
  [ "${INSTALL_REMOTE:-1}" = 1 ] || return 0
  if [ -n "${VNC_PASSWORD:-}" ]; then
    ok "VNC password present"
    return 0
  fi
  local p
  p=$(/usr/bin/openssl rand -base64 12 2>/dev/null | /usr/bin/tr -dc 'A-Za-z0-9' | /usr/bin/cut -c1-8)
  if [ -z "$p" ] || [ "${#p}" -lt 8 ]; then
    warn "openssl rand failed — VNC password NOT generated (Screen Sharing enable will be skipped)"
    return 0
  fi
  save_config_key VNC_PASSWORD "$p"
  export VNC_PASSWORD="$p"
  ok "VNC password generated: $p  (also in $CONF_FILE)"
}

ensure_screensharing_enabled() {
  # Opt-in: turn on macOS' built-in Screen Sharing (VNC on :5900) and set a legacy
  # VNC password so non-Apple VNC clients (Windows RealVNC/TightVNC) — and the noVNC
  # browser bridge — can authenticate. One-way like the SMB share: toggling
  # INSTALL_REMOTE=0 does NOT disable it (turn it off in System Settings > General >
  # Sharing, or run `.../kickstart -deactivate -configure -access -off`). Idempotent —
  # re-running just re-pushes the same config/password.
  [ "${INSTALL_REMOTE:-1}" = 1 ] || return 0
  local ks=/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart
  if [ ! -x "$ks" ]; then
    warn "ARD kickstart not found at $ks — cannot enable Screen Sharing automatically."
    warn "  Enable it manually: System Settings > General > Sharing > Screen Sharing."
    return 1
  fi
  if [ -z "${VNC_PASSWORD:-}" ]; then
    warn "VNC_PASSWORD empty — skipping Screen Sharing enable (set it in menu 4 + --apply)."
    return 0
  fi
  if "$ks" -activate -configure -access -on \
        -clientopts -setvnclegacy -vnclegacy yes -setvncpw -vncpw "$VNC_PASSWORD" \
        -restart -agent -privs -all >/dev/null 2>&1; then
    ok "Screen Sharing (VNC :5900) enabled with legacy VNC password"
  else
    warn "kickstart returned non-zero enabling Screen Sharing; verify in System Settings > Sharing"
  fi
}

ensure_novnc_venv() {
  # Tiny venv for the browser VNC bridge (com.local.novnc): just websockify, which
  # proxies the browser's WebSocket connection to the local VNC server on :5900.
  { [ "${INSTALL_NOVNC:-1}" = 1 ] && [ "${INSTALL_REMOTE:-1}" = 1 ]; } || return 0
  local venv="${VENV_DIR:-/Users/mac/.macstudio-venvs}/novnc"
  if [ -x "$venv/bin/python" ] && "$venv/bin/python" -c 'import websockify' >/dev/null 2>&1; then
    ok "novnc venv present at $venv"
    return 0
  fi
  if [ ! -x /opt/homebrew/bin/python3.12 ]; then
    warn "novnc bridge needs python@3.12, which is not installed yet."
    warn "Re-run 'sudo bash setup.sh --apply' after Homebrew is available."
    return 1
  fi
  log "Building novnc venv at $venv (websockify)"
  /usr/bin/sudo -u "$TARGET_USER" -H /bin/mkdir -p "$venv"
  if [ ! -x "$venv/bin/python" ]; then
    /usr/bin/sudo -u "$TARGET_USER" -H /opt/homebrew/bin/python3.12 -m venv "$venv"
  fi
  /usr/bin/sudo -u "$TARGET_USER" -H "$venv/bin/pip" install --upgrade pip wheel >/dev/null 2>&1 \
    || warn "pip upgrade inside novnc venv returned non-zero"
  if ! /usr/bin/sudo -u "$TARGET_USER" -H "$venv/bin/pip" install \
        websockify >/var/log/macstudio/novnc-venv-install.log 2>&1; then
    warn "novnc pip install failed; see /var/log/macstudio/novnc-venv-install.log"
    return 1
  fi
  if "$venv/bin/python" -c 'import websockify' >/dev/null 2>&1; then
    ok "novnc venv built at $venv"
  else
    warn "novnc pip install succeeded but websockify won't import"
    return 1
  fi
}

ensure_novnc_assets() {
  # Download the noVNC HTML5 client (static files) once — websockify serves these as
  # its --web root so the browser gets a full VNC UI at /vnc.html. Pinned release,
  # fetched at --apply time (not vendored in git). Idempotent: skips if vnc.html exists.
  { [ "${INSTALL_NOVNC:-1}" = 1 ] && [ "${INSTALL_REMOTE:-1}" = 1 ]; } || return 0
  local ver=1.5.0 dir=/usr/local/share/novnc
  if [ -f "$dir/vnc.html" ]; then
    ok "noVNC web assets present at $dir"
    return 0
  fi
  log "Downloading noVNC $ver web assets -> $dir"
  /bin/mkdir -p "$dir"
  local tgz; tgz=$(/usr/bin/mktemp)
  if ! /usr/bin/curl -fsSL "https://github.com/novnc/noVNC/archive/refs/tags/v${ver}.tar.gz" -o "$tgz"; then
    warn "could not download noVNC $ver (browser VNC will 404). Check network; re-run --apply."
    /bin/rm -f "$tgz"; return 1
  fi
  if /usr/bin/tar -xzf "$tgz" -C "$dir" --strip-components=1 >/dev/null 2>&1; then
    /bin/chmod -R a+rX "$dir"
    ok "noVNC $ver extracted to $dir"
  else
    warn "noVNC tarball extraction failed"
    /bin/rm -f "$tgz"; return 1
  fi
  /bin/rm -f "$tgz"
}

# --- MLX stack: venvs, model catalog, LiteLLM routing ----------------------
CATALOG_DIR=/usr/local/etc/macstudio-models
CATALOG_FILE="$CATALOG_DIR/catalog.tsv"
LITELLM_CONFIG_FILE=/usr/local/etc/litellm.config.yaml

# catalog_field <id> <column-number> — print a single field from the live
# catalog, skipping comment lines. Columns (schema v7):
#   1 id  2 hf_repo  3 role  4 engine  5 quant  6 gb  7 gated
#   8 reasoning_parser  9 tool_parser  10 max_kv_size  11 max_num_seqs
#   12 rating  13 notes  14 temperature  15 top_p  16 frequency_penalty
#   17 presence_penalty
catalog_field() {
  [ -f "$CATALOG_FILE" ] || return 0
  /usr/bin/awk -F'|' -v id="$1" -v n="$2" '!/^#/ && $1==id {print $n; exit}' "$CATALOG_FILE"
}
catalog_repo()   { catalog_field "$1" 2; }
catalog_role()   { catalog_field "$1" 3; }
catalog_engine() { catalog_field "$1" 4; }
catalog_gb()     { catalog_field "$1" 6; }
catalog_gated()  { catalog_field "$1" 7; }

# model_local_dir <hf_repo> — the HF hub snapshot dir for a repo, or empty.
model_local_dir() {
  local repo=$1
  local hub="${HF_CACHE_DIR:-/Users/mac/.cache/huggingface}/hub"
  local safe="models--${repo//\//--}"
  echo "$hub/$safe"
}

# model_status <hf_repo> — ok | partial | none  (derived, never stored).
model_status() {
  local repo=$1 d; d=$(model_local_dir "$repo")
  if [ -d "$d/snapshots" ] && \
     /usr/bin/find "$d/snapshots" -maxdepth 2 -name '*.safetensors' 2>/dev/null | /usr/bin/grep -q . ; then
    # A completed download leaves no *.incomplete blobs behind.
    if /usr/bin/find "$d/blobs" -name '*.incomplete' 2>/dev/null | /usr/bin/grep -q . ; then
      echo partial
    else
      echo ok
    fi
  elif [ -d "$d" ]; then
    echo partial
  else
    echo none
  fi
}

ensure_python_venvs() {
  [ "${INSTALL_MLX:-1}" = 1 ] || return 0
  if [ ! -x /opt/homebrew/bin/python3.12 ]; then
    warn "MLX stack needs python@3.12, which is not installed yet."
    warn "Re-run 'sudo bash setup.sh --apply' after Homebrew is available."
    return 1
  fi
  local vdir="${VENV_DIR:-/Users/mac/.macstudio-venvs}"
  # HF cache + venv root owned by the user the daemons run as.
  /usr/bin/sudo -u "$TARGET_USER" -H /bin/mkdir -p "$vdir" "${HF_CACHE_DIR:-$TARGET_HOME/.cache/huggingface}"

  # _venv_ok <name> <check-token> — token is "bin:<console-script>" (what the
  # wrapper actually execs) or "mod:<python-module>" (for module-run servers).
  _venv_ok() {
    local v="$vdir/$1" tok=$2
    case "$tok" in
      bin:*) [ -x "$v/bin/${tok#bin:}" ] ;;
      mod:*) [ -x "$v/bin/python" ] && \
             /usr/bin/sudo -u "$TARGET_USER" -H "$v/bin/python" -c "import ${tok#mod:}" >/dev/null 2>&1 ;;
      *)     return 1 ;;
    esac
  }

  # _ensure_venv <name> <check-token> <pip-args…>
  _ensure_venv() {
    local name=$1 tok=$2; shift 2
    local v="$vdir/$name"
    if _venv_ok "$name" "$tok"; then
      ok "venv '$name' present ($v)"
      return 0
    fi
    log "building venv '$name' at $v (downloads wheels; several minutes)"
    if [ ! -x "$v/bin/python" ]; then
      /usr/bin/sudo -u "$TARGET_USER" -H /opt/homebrew/bin/python3.12 -m venv "$v"
    fi
    /usr/bin/sudo -u "$TARGET_USER" -H "$v/bin/pip" install --upgrade pip wheel >/dev/null 2>&1 \
      || warn "pip upgrade in venv '$name' returned non-zero"
    if ! /usr/bin/sudo -u "$TARGET_USER" -H "$v/bin/pip" install "$@" \
          >"$LOG_DIR/${name}-venv-install.log" 2>&1; then
      warn "pip install for venv '$name' failed; see $LOG_DIR/${name}-venv-install.log"
      return 1
    fi
    if _venv_ok "$name" "$tok"; then
      ok "venv '$name' built"
    else
      warn "venv '$name' pip succeeded but check '$tok' failed"
      return 1
    fi
  }

  # The text engine is mlx_vlm.server (venv 'mlxvlm', unified text+vision main),
  # pinned via MLXVLM_VERSION: 0.6.3 is the release that fixed Gemma-4 unified
  # SILENTLY DROPPING image/video inputs (0.6.2 had the bug — a main would answer
  # text-only with no error). litellm floats.
  _ensure_venv litellm bin:litellm       'litellm[proxy]'
  local mlxvlm_spec="mlx-vlm"
  [ -n "${MLXVLM_VERSION:-}" ] && mlxvlm_spec="mlx-vlm==${MLXVLM_VERSION}"
  _ensure_venv mlxvlm  mod:mlx_vlm        "$mlxvlm_spec" 'huggingface_hub[cli]'

  # Embeddings + reranker: BGE pair served by Infinity (infinity-emb) on MPS,
  # on-demand. Independent of the text engine; pulls torch, so only built when
  # INSTALL_EMBED=1. The wrapper execs the 'infinity_emb' console script.
  #   - extras [torch,server] (NOT [all]): the torch/MPS backend + the v2 HTTP
  #     server, WITHOUT 'optimum'. optimum 2.x dropped the `bettertransformer`
  #     submodule that this infinity-emb build imports, so [all] yields a backend
  #     that crashes on startup. We don't use BetterTransformer (CUDA-only varlen)
  #     — the wrapper also passes --no-bettertransformer.
  #   - click<8.2: typer 0.12.x is incompatible with click >= 8.2 ("Secondary
  #     flag is not valid for non-boolean flag"); pin keeps the CLI parseable.
  if [ "${INSTALL_EMBED:-1}" = 1 ]; then
    _ensure_venv infinity bin:infinity_emb 'infinity-emb[torch,server]' 'click<8.2' 'huggingface_hub[cli]'
  fi

  # Version-sync: set MLXVLM_VERSION + `--apply` to up/downgrade the text engine.
  if [ -n "${MLXVLM_VERSION:-}" ] && [ -x "$vdir/mlxvlm/bin/python" ]; then
    local cur_m
    cur_m=$(/usr/bin/sudo -u "$TARGET_USER" -H "$vdir/mlxvlm/bin/python" -c \
      'import importlib.metadata as m; print(m.version("mlx-vlm"))' 2>/dev/null)
    if [ -n "$cur_m" ] && [ "$cur_m" != "$MLXVLM_VERSION" ]; then
      log "mlx-vlm pin: $cur_m -> $MLXVLM_VERSION (reinstalling)"
      if /usr/bin/sudo -u "$TARGET_USER" -H "$vdir/mlxvlm/bin/pip" install "mlx-vlm==${MLXVLM_VERSION}" \
            >"$LOG_DIR/mlxvlm-pin-install.log" 2>&1; then
        ok "mlx-vlm pinned to $MLXVLM_VERSION"
        daemon_loaded com.local.mlxvlm.main \
          && /bin/launchctl kickstart -k system/com.local.mlxvlm.main >/dev/null 2>&1 \
          && ok "restarted mlx_vlm.server to apply the version change"
      else
        warn "mlx-vlm pin install failed; see $LOG_DIR/mlxvlm-pin-install.log"
      fi
    fi
  fi
}

catalog_schema_ver() {
  # Read the "# schema: N" header line; default 1 if absent.
  local v; v=$(/usr/bin/awk -F: '/^# schema:/{gsub(/[^0-9]/,"",$2); print $2; exit}' "$1" 2>/dev/null)
  echo "${v:-1}"
}

ensure_model_catalog() {
  [ "${INSTALL_MLX:-1}" = 1 ] || return 0
  /bin/mkdir -p "$CATALOG_DIR"
  local seed="$REPO_DIR/models/catalog.tsv"
  [ -f "$seed" ] || { warn "repo seed models/catalog.tsv missing"; return 0; }
  local seedver; seedver=$(catalog_schema_ver "$seed")
  # SEED ONCE per schema: after the live file exists the TUI owns it (downloads
  # + alias picks persist). On a schema bump we back up the old file and re-seed
  # so column indices stay valid — alias assignments live in macstudio.conf and
  # downloaded models live in the HF cache, so neither is lost.
  if [ ! -f "$CATALOG_FILE" ]; then
    /usr/bin/install -m 644 "$seed" "$CATALOG_FILE"
    ok "seeded model catalog → $CATALOG_FILE (schema $seedver)"
    return 0
  fi
  local livever; livever=$(catalog_schema_ver "$CATALOG_FILE")
  if [ "$livever" != "$seedver" ]; then
    local bak="$CATALOG_FILE.bak.$(date +%Y%m%d-%H%M%S)"
    /bin/cp -f "$CATALOG_FILE" "$bak"
    /usr/bin/install -m 644 "$seed" "$CATALOG_FILE"
    warn "model catalog migrated schema $livever → $seedver (backup: $bak)"
    warn "  re-check your picks via 'llm-models' (downloads + alias assignments preserved)"
  else
    ok "model catalog present ($CATALOG_FILE, schema $livever) — left as-is (TUI-managed)"
  fi
}

# Generate /usr/local/etc/litellm.config.yaml from the active alias
# assignments. Roles: `main` (the ONE loaded mlx_vlm.server text+images model) and
# the embed/rerank Infinity aliases. Only rewrites + reloads on a real change.
render_litellm_config() {
  [ "${INSTALL_MLX:-1}" = 1 ] || return 0
  local main_repo embed_repo rerank_repo tmp
  main_repo=$(catalog_repo "${ALIAS_MAIN:-}")
  if [ -z "$main_repo" ]; then
    warn "ALIAS_MAIN='${ALIAS_MAIN:-}' has no catalog repo — LiteLLM config not (re)written"
    warn "(download a model and set it as main via 'llm-models')"
    return 0
  fi
  # Embeddings + reranking (BGE pair) served by the on-demand Infinity backend.
  embed_repo=$(catalog_repo "${ALIAS_EMBED:-}")
  rerank_repo=$(catalog_repo "${ALIAS_RERANK:-}")

  # Per-model DEFAULT sampling (schema v7, cols 14-17) for the active main model.
  # We inject per-model default sampling into the LiteLLM alias; clients can
  # still override per request (drop_params drops anything the backend rejects).
  # Empty cell = omit (LiteLLM/backend default).
  local m_temp m_topp m_freq m_pres
  m_temp=$(catalog_field "${ALIAS_MAIN:-}" 14)
  m_topp=$(catalog_field "${ALIAS_MAIN:-}" 15)
  m_freq=$(catalog_field "${ALIAS_MAIN:-}" 16)
  m_pres=$(catalog_field "${ALIAS_MAIN:-}" 17)

  # emit_model <alias> <repo> <port> [temp] [top_p] [freq_pen] [pres_pen] [max_tok] [nothink] [top_k]
  # One LiteLLM model_list entry; optional sampling lines only when non-empty.
  # extra_body carries up to two things, merged into ONE object:
  #   nothink (arg 9) non-empty -> suppress the model's reasoning at the proxy (so clients
  #     like OpenWebUI never see a thinking block, and short-output tasks like paperless
  #     extraction aren't eaten by hidden think tokens). The wire form is ENGINE-SPECIFIC:
  #     mlx_vlm.server reads a TOP-LEVEL `enable_thinking`; mlx_lm.server reads it inside
  #     `chat_template_kwargs`.
  #   top_k (arg 10) non-empty -> Gemma's reference sampling. top_k is NOT a native OpenAI
  #     param, so it MUST ride in extra_body (catalog has no top_k column). At temperature 0
  #     it is inert, so we don't bother passing it to deterministic aliases.
  # LiteLLM forwards extra_body verbatim (drop_params leaves it untouched).
  # mlx-vlm uses the TOP-LEVEL enable_thinking wire form.
  local _nothink_body='{"enable_thinking": false}'
  emit_model() {
    printf '  - model_name: %s\n    litellm_params:\n      model: openai/%s\n      api_base: http://127.0.0.1:%s/v1\n      api_key: dummy\n' "$1" "$2" "$3"
    [ -n "${4:-}" ] && printf '      temperature: %s\n' "$4"
    [ -n "${5:-}" ] && printf '      top_p: %s\n' "$5"
    [ -n "${6:-}" ] && printf '      frequency_penalty: %s\n' "$6"
    [ -n "${7:-}" ] && printf '      presence_penalty: %s\n' "$7"
    [ -n "${8:-}" ] && printf '      max_tokens: %s\n' "$8"
    local _eb=""
    if [ -n "${9:-}" ] && [ -n "${10:-}" ]; then
      _eb=$(printf '{"enable_thinking": false, "top_k": %s}' "${10}")
    elif [ -n "${9:-}" ]; then
      _eb="$_nothink_body"
    elif [ -n "${10:-}" ]; then
      _eb=$(printf '{"top_k": %s}' "${10}")
    fi
    [ -n "$_eb" ] && printf '      extra_body: %s\n' "$_eb"
    return 0
  }
  tmp=$(/usr/bin/mktemp -t macstudio-litellm)
  {
    echo "# Managed by setup.sh -> render_litellm_config(). Do not edit by hand;"
    echo "# change aliases via 'llm-models'. Apps see only model_name aliases."
    echo "model_list:"
    # main: Gemma reference sampling (temp/top_p from catalog, top_k via extra_body);
    # thinking is left to the model/client (a reasoning model thinks by default; a client
    # can pass enable_thinking per request).
    # main-fast: thinking ALWAYS off at the proxy (emit_model arg 9).
    emit_model main "$main_repo" "${MAIN_BACKEND_PORT:-18000}" "$m_temp" "$m_topp" "$m_freq" "$m_pres" "" "" "${GEMMA_TOP_K:-64}"
    # main-fast = SAME loaded gemma model as 'main' (shares :18000 -> only ONE resident),
    # exactly 'main' sampling but thinking OFF at the proxy
    # (fast, non-reasoning chat / tools / web / cron / email). (main-metadata was retired.)
    if [ "${PRESET_ALIASES:-1}" = 1 ]; then
      emit_model main-fast "$main_repo" "${MAIN_BACKEND_PORT:-18000}" "$m_temp" "$m_topp" "$m_freq" "$m_pres" "" 1 "${GEMMA_TOP_K:-64}"
    fi
    # Embeddings + reranking via the on-demand Infinity backend (BGE pair on MPS).
    # LiteLLM's 'infinity/<served-name>' provider posts to <api_base>/embeddings and
    # <api_base>/rerank (api_base = the on-demand PROXY port — the FIRST call wakes the
    # backend). The served-name after 'infinity/' MUST equal start-infinity.sh's
    # --served-model-name (i.e. the catalog id). model_info.mode lets LiteLLM route and
    # list them correctly. Emitted only when the catalog id resolves (download first).
    if [ "${INSTALL_EMBED:-1}" = 1 ] && [ -n "$embed_repo" ]; then
      printf '  - model_name: embed\n    litellm_params:\n      model: infinity/%s\n      api_base: http://127.0.0.1:%s\n      api_key: dummy\n    model_info:\n      mode: embedding\n' \
        "${ALIAS_EMBED}" "${INFINITY_PUBLIC_PORT:-5004}"
    fi
    if [ "${INSTALL_EMBED:-1}" = 1 ] && [ -n "$rerank_repo" ]; then
      printf '  - model_name: rerank\n    litellm_params:\n      model: infinity/%s\n      api_base: http://127.0.0.1:%s\n      api_key: dummy\n    model_info:\n      mode: rerank\n' \
        "${ALIAS_RERANK}" "${INFINITY_PUBLIC_PORT:-5004}"
    fi
    # No separate 'vision' alias: the unified 'main' already does images, so the chat set
    # is intentionally main / main-fast (plus the embed / rerank utility aliases above).
    echo "litellm_settings:"
    echo "  drop_params: true"
    # Long docs/OCR generations can run minutes — raise the gateway timeout and
    # do NOT retry (re-running a 20-min generation 2x is wasteful, not helpful).
    printf '  request_timeout: %s\n' "${LLM_REQUEST_TIMEOUT:-3600}"
    echo "  num_retries: 0"
  } >"$tmp"

  if [ "$(hash_file "$tmp")" = "$(hash_file "$LITELLM_CONFIG_FILE")" ]; then
    /bin/rm -f "$tmp"
    ok "litellm config up to date"
    return 0
  fi
  /usr/bin/install -m 644 "$tmp" "$LITELLM_CONFIG_FILE"
  /bin/rm -f "$tmp"
  ok "litellm config written → $LITELLM_CONFIG_FILE (main=${ALIAS_MAIN}, embed=${ALIAS_EMBED:-none}, rerank=${ALIAS_RERANK:-none})"
  if daemon_loaded com.local.litellm.proxy; then
    /bin/launchctl kickstart -k system/com.local.litellm.proxy >/dev/null 2>&1 \
      && ok "restarted litellm to pick up new routing"
  fi
}

render_wrappers() {
  local changed=0 name dst
  for src in "$REPO_DIR"/wrappers/*.sh; do
    name=$(basename "$src")
    dst="$LIBEXEC_DIR/$name"
    if install_if_different "$src" "$dst" 755; then
      changed=$((changed+1)); ok "updated $dst"
    fi
  done
  # set-iogpu-wired-limit.sh belongs in sbin
  if install_if_different "$REPO_DIR/wrappers/set-iogpu-wired-limit.sh" "$SBIN_DIR/set-iogpu-wired-limit.sh" 755; then
    changed=$((changed+1)); ok "updated $SBIN_DIR/set-iogpu-wired-limit.sh"
  fi
  [ "$changed" -eq 0 ] && ok "wrappers up to date"
}

# Daemon label a service .py belongs to, for the post-update hot-restart in
# render_services. The ondemand-proxy.py proxies are deliberately ABSENT —
# restarting them would drop in-flight LLM/OCR requests; they pick the new
# code up on their next natural restart.
service_py_label() {
  case "$1" in
    mqtt-bridge.py)        echo com.local.mqtt.bridge ;;
    dashboard.py)          echo com.local.dashboard ;;
    silicon-exporter.py)   echo com.local.silicon.exporter ;;
    ondemand-exporter.py)  echo com.local.ondemand.exporter ;;
    paperless-ocr.py)      echo com.local.paperless.ocr ;;
    vnc-secfilter.py)      echo com.local.vncfilter ;;
    *) echo "" ;;
  esac
}

render_services() {
  local changed=0 restart_labels=""
  for src in "$REPO_DIR"/services/*.py; do
    local name dst; name=$(basename "$src"); dst="$LIBEXEC_DIR/$name"
    if install_if_different "$src" "$dst" 755; then
      changed=$((changed+1)); ok "updated $dst"
      local _lbl; _lbl=$(service_py_label "$name")
      [ -n "$_lbl" ] && restart_labels="$restart_labels $_lbl"
    fi
  done
  if install_if_different "$REPO_DIR/services/llm-watchdog.sh" "$LIBEXEC_DIR/llm-watchdog.sh" 755; then
    changed=$((changed+1)); ok "updated $LIBEXEC_DIR/llm-watchdog.sh"
  fi
  if install_if_different "$REPO_DIR/services/weekly-autoupdate.sh" "$SBIN_DIR/weekly-autoupdate.sh" 755; then
    changed=$((changed+1)); ok "updated $SBIN_DIR/weekly-autoupdate.sh"
  fi
  # The dashboard SPA is a data file dashboard.py re-reads from disk (mtime
  # cache) — an html-only change needs NO daemon restart, so it is deliberately
  # not mapped in service_py_label.
  if [ -f "$REPO_DIR/services/dashboard-ui.html" ] \
     && install_if_different "$REPO_DIR/services/dashboard-ui.html" "$LIBEXEC_DIR/dashboard-ui.html" 644; then
    changed=$((changed+1)); ok "updated $LIBEXEC_DIR/dashboard-ui.html"
  fi
  # A .py-only change doesn't touch the plist, so render_all_plists sees no
  # diff and never restarts the daemon — it would keep running stale code.
  local _lbl
  for _lbl in $restart_labels; do
    if daemon_loaded "$_lbl"; then
      /bin/launchctl kickstart -k "system/$_lbl" >/dev/null 2>&1 \
        && ok "restarted $_lbl with updated code"
    fi
  done
  [ "$changed" -eq 0 ] && ok "services up to date"
}

render_bin() {
  local changed=0
  for src in "$REPO_DIR"/bin/*; do
    [ -f "$src" ] || continue
    local name dst; name=$(basename "$src"); dst="$BIN_DIR/$name"
    if install_if_different "$src" "$dst" 755; then changed=$((changed+1)); ok "updated $dst"; fi
  done
  [ "$changed" -eq 0 ] && ok "user commands up to date"
}

render_all_plists() {
  local any_changed=0
  for label in "${ALL_LABELS[@]}"; do
    local src="$REPO_DIR/daemons/$label.plist"
    local dst="$PLIST_DIR/$label.plist"
    if [ ! -f "$src" ]; then
      warn "plist template missing in repo: $src"
      continue
    fi
    # Skip optional services per config
    case "$label" in
      com.local.mlxvlm.main)
        # Text engine: mlx_vlm.server (unified text+vision). The one always-on main.
        [ "${INSTALL_MLX:-1}" = 1 ] || { remove_plist "$label"; continue; } ;;
      com.local.litellm.*)
        [ "${INSTALL_MLX:-1}" = 1 ] || { remove_plist "$label"; continue; } ;;
      com.local.infinity.*)
        # On-demand BGE embedder + reranker (Infinity, MPS). Independent of the
        # text engine, but only reachable through the LiteLLM gateway.
        [ "${INSTALL_EMBED:-1}" = 1 ] || { remove_plist "$label"; continue; } ;;
      com.local.immich.*)  [ "${INSTALL_IMMICH:-1}"  = 1 ] || { remove_plist "$label"; continue; } ;;
      com.local.docling.*) [ "${INSTALL_DOCLING:-1}" = 1 ] || { remove_plist "$label"; continue; } ;;
      com.local.node.exporter|com.local.silicon.exporter|com.local.ondemand.exporter)
        [ "${INSTALL_EXPORTERS:-1}" = 1 ] || { remove_plist "$label"; continue; } ;;
      com.local.llm.watchdog)
        [ "${INSTALL_WATCHDOG:-1}" = 1 ] || { remove_plist "$label"; continue; } ;;
      com.local.mqtt.bridge)
        [ "${INSTALL_MQTT:-0}" = 1 ] || { remove_plist "$label"; continue; } ;;
      com.local.dashboard)
        # Web dashboard (browser control). Root daemon like the MQTT bridge.
        [ "${INSTALL_DASHBOARD:-1}" = 1 ] || { remove_plist "$label"; continue; } ;;
      com.local.vncfilter)
        # RFB security-type filter in front of :5900 (strips Apple/ARD auth so
        # only the shared VNC_PASSWORD is offered). Runs as TARGET_USER, stdlib.
        [ "${INSTALL_REMOTE:-1}" = 1 ] || { remove_plist "$label"; continue; } ;;
      com.local.novnc)
        # Browser VNC bridge (websockify -> vncfilter -> :5900). Runs as TARGET_USER;
        # needs the novnc venv + Screen Sharing enabled (INSTALL_REMOTE).
        { [ "${INSTALL_NOVNC:-1}" = 1 ] && [ "${INSTALL_REMOTE:-1}" = 1 ]; } || { remove_plist "$label"; continue; } ;;
      com.local.paperless.ocr)
        # Apple-Vision searchable-PDF worker for paperless-ngx. Runs as TARGET_USER
        # (Vision needs a user context); needs its own venv (ocrmac/pymupdf/requests).
        [ "${INSTALL_PAPERLESS_OCR:-0}" = 1 ] || { remove_plist "$label"; continue; } ;;
    esac
    local before_hash; before_hash=$(hash_file "$dst")
    render_template "$src" "$dst" 644 root:wheel || true
    local after_hash; after_hash=$(hash_file "$dst")
    if [ "$before_hash" != "$after_hash" ]; then
      any_changed=1
      ok "plist updated: $label"
      reload_plist_if_changed "$label" changed
    else
      reload_plist_if_changed "$label" unchanged
    fi
  done
  [ "$any_changed" = 0 ] && ok "plists up to date"
}

remove_plist() {
  local label=$1
  local dst="$PLIST_DIR/$label.plist"
  bootout_plist "$label"
  if [ -f "$dst" ]; then
    /bin/rm -f "$dst"
    ok "removed $dst (disabled by config)"
  fi
}

render_motd() {
  if [ ! -f "$REPO_DIR/motd.txt" ]; then return 0; fi
  # Back up the original once
  if [ ! -f "$MOTD_BACKUP" ] && [ -f "$MOTD_FILE" ]; then
    /bin/cp -f "$MOTD_FILE" "$MOTD_BACKUP"
  fi
  if render_template "$REPO_DIR/motd.txt" "$MOTD_FILE" 644 root:wheel; then
    ok "motd updated"
  fi
  # Ensure sshd actually shows it
  if [ -f /etc/ssh/sshd_config ] \
     && /usr/bin/grep -qiE '^\s*PrintMotd\s+no' /etc/ssh/sshd_config; then
    warn "/etc/ssh/sshd_config has 'PrintMotd no' — banner will not show on SSH login"
  fi
}

apply_iogpu_wired_limit() {
  local current target
  current=$(/usr/sbin/sysctl -n iogpu.wired_limit_mb 2>/dev/null || echo 0)
  target="${IOGPU_WIRED_LIMIT_MB:-30720}"
  if [ "$current" = "$target" ]; then
    ok "iogpu.wired_limit_mb already $target"
  else
    /usr/sbin/sysctl -w iogpu.wired_limit_mb="$target" >/dev/null \
      && ok "iogpu.wired_limit_mb set to $target (was $current)" \
      || warn "failed to set iogpu.wired_limit_mb"
  fi
}

apply_pmset() {
  # These settings are idempotent; pmset prints nothing when already set.
  /usr/bin/pmset -a autorestart 1 sleep 0 displaysleep 0 disksleep 0 \
                    powernap 0 standby 0 tcpkeepalive 1 womp 1 >/dev/null 2>&1 || true
  ok "pmset applied (autorestart=1, sleep=0, powernap=0)"
}

apply_os_trim() {
  [ "${INSTALL_MLX:-1}" = 1 ] && /usr/bin/mdutil -i off "${HF_CACHE_DIR:-/Users/mac/.cache/huggingface}" >/dev/null 2>&1 || true
  /usr/bin/mdutil -i off "$LOG_DIR"       >/dev/null 2>&1 || true
  sudo -u "$TARGET_USER" defaults write com.apple.SubmitDiagInfo AutoSubmit -bool false 2>/dev/null || true
  sudo -u "$TARGET_USER" defaults write com.apple.CrashReporter DialogType none 2>/dev/null || true
  sudo -u "$TARGET_USER" defaults write com.apple.assistant.support "Assistant Enabled" -bool false 2>/dev/null || true
  ok "OS trim applied (Spotlight off on models/logs, analytics/crash/Siri disabled)"
}

write_repo_pointer() {
  /bin/mkdir -p "$(dirname "$REPO_POINTER_FILE")"
  printf 'SETUP_SH=%s/setup.sh\nREPO_DIR=%s\n' "$REPO_DIR" "$REPO_DIR" >"$REPO_POINTER_FILE"
  /bin/chmod 644 "$REPO_POINTER_FILE"
}

# Extend sudo's secure_path with /opt/homebrew/bin so `sudo mactop` /
# `sudo macmon` work without typing a full path. Removed cleanly when
# INSTALL_TUI=0. Validated with `visudo -cf` before being kept.
apply_tui_sudoers() {
  local f=/etc/sudoers.d/macstudio-tui
  if [ "${INSTALL_TUI:-1}" != 1 ]; then
    if [ -e "$f" ]; then
      /bin/rm -f "$f" && ok "removed $f"
    fi
    return 0
  fi
  # secure_path is a single string in sudo 1.9.x, not a list — `+=` is
  # rejected, so we set the full path here. /opt/homebrew/bin first so brew
  # binaries win over identically-named system tools.
  local desired='Defaults secure_path = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"'
  if [ -f "$f" ] && /usr/bin/grep -qxF "$desired" "$f"; then
    ok "$f present"
    return 0
  fi
  printf '%s\n' "$desired" >"$f"
  /usr/sbin/chown root:wheel "$f"
  /bin/chmod 440 "$f"
  if ! /usr/sbin/visudo -cf "$f" >/dev/null 2>&1; then
    warn "$f failed visudo check — removing"
    /bin/rm -f "$f"
    return 1
  fi
  ok "wrote $f"
}

# ===========================================================================
# Orchestration
# ===========================================================================

ensure_dashboard_token() {
  # Generate the web-dashboard access token ONCE (empty = not yet generated).
  # Idempotent: an existing token is never touched — rotate by clearing
  # DASHBOARD_TOKEN (menu 4) and re-running --apply. The dashboard daemon
  # re-reads the conf per auth check, so no restart is needed after rotation.
  [ "${INSTALL_DASHBOARD:-1}" = 1 ] || return 0
  if [ -n "${DASHBOARD_TOKEN:-}" ]; then
    ok "dashboard token present"
    return 0
  fi
  local t
  t=$(/usr/bin/openssl rand -hex 16 2>/dev/null)
  if [ -z "$t" ]; then
    warn "openssl rand failed — dashboard token NOT generated (dashboard will refuse all logins)"
    return 0
  fi
  save_config_key DASHBOARD_TOKEN "$t"
  export DASHBOARD_TOKEN="$t"
  ok "dashboard token generated: $t"
  ok "  (log in at http://$(/bin/hostname 2>/dev/null || echo localhost):${DASHBOARD_PORT:-8090} — also in $CONF_FILE)"
}

mqtt_apply_warnings() {
  [ "${INSTALL_MQTT:-0}" = 1 ] || return 0
  if [ -z "${MQTT_HOST:-}" ]; then
    warn "INSTALL_MQTT=1 but MQTT_HOST is empty — the bridge will idle until you set it (menu 4)."
  fi
  if [ "${INSTALL_EXPORTERS:-0}" != 1 ]; then
    warn "INSTALL_MQTT=1 but INSTALL_EXPORTERS=0 — power/GPU sensors will be 'unavailable' in Home Assistant"
    warn "  (the bridge scrapes the silicon exporter on :${SILICON_EXPORTER_PORT:-9101}). Enable exporters in menu 'Select services' to get them."
  fi
}

apply_everything() {
  need_root "$@"
  dbg "step: load_config";            load_config
  dbg "step: ensure_dirs";             ensure_dirs
  dbg "step: write_repo_pointer";      write_repo_pointer
  dbg "step: ensure_xcode_clt";        ensure_xcode_clt || true
  dbg "step: ensure_homebrew";         ensure_homebrew || true
  dbg "step: ensure_formulas";         ensure_formulas
  dbg "step: apply_tui_sudoers";       apply_tui_sudoers || true
  dbg "step: ensure_modern_python";    ensure_modern_python || true
  dbg "step: ensure_immich_venv";      ensure_immich_venv
  dbg "step: ensure_docling_venv";     ensure_docling_venv
  dbg "step: ensure_paperless_ocr_venv"; ensure_paperless_ocr_venv || true
  dbg "step: ensure_paperless_ocr_share"; ensure_paperless_ocr_share || true
  dbg "step: ensure_vnc_password";     ensure_vnc_password
  dbg "step: ensure_screensharing";    ensure_screensharing_enabled || true
  dbg "step: ensure_novnc_venv";       ensure_novnc_venv || true
  dbg "step: ensure_novnc_assets";     ensure_novnc_assets || true
  dbg "step: ensure_python_venvs";     ensure_python_venvs || true
  dbg "step: ensure_model_catalog";    ensure_model_catalog
  dbg "step: render_wrappers";        render_wrappers
  dbg "step: render_services";        render_services
  dbg "step: render_bin";             render_bin
  dbg "step: render_litellm_config";   render_litellm_config
  dbg "step: ensure_dashboard_token";  ensure_dashboard_token
  dbg "step: render_all_plists";      render_all_plists
  dbg "step: mqtt_apply_warnings";    mqtt_apply_warnings
  dbg "step: render_motd";            render_motd
  dbg "step: apply_iogpu_wired_limit"; apply_iogpu_wired_limit
  dbg "step: apply_pmset";            apply_pmset
  dbg "step: apply_os_trim";          apply_os_trim
  echo
  verify_and_summary
}

# ===========================================================================
# Status / verify
# ===========================================================================

verify_and_summary() {
  load_config
  printf "\n${C_BOLD}── Live state ────────────────────────────────────${C_RST}\n"

  # Memory
  local wired free_pages page_size free_mb pressure
  wired=$(/usr/sbin/sysctl -n iogpu.wired_limit_mb 2>/dev/null || echo ?)
  page_size=$(/usr/sbin/sysctl -n hw.pagesize 2>/dev/null || echo 16384)
  free_pages=$(/usr/bin/vm_stat 2>/dev/null | awk '/Pages free/{gsub(/\./,"",$3); print $3; exit}')
  free_mb=$(( (free_pages * page_size) / 1024 / 1024 ))
  pressure=$(/usr/bin/memory_pressure 2>/dev/null | awk -F': ' '/System memory pressure/{print $2; exit}')

  printf "Memory: %s MB free  |  wired limit %s MB  |  pressure %s  |  total %s GB\n" \
         "$free_mb" "$wired" "${pressure:-?}" "${TOTAL_RAM_GB:-?}"

  # pmset
  local ar sl
  ar=$(/usr/bin/pmset -g | awk '/autorestart/{print $2}')
  sl=$(/usr/bin/pmset -g | awk '/ sleep /{print $2; exit}')
  printf "pmset:  autorestart=%s  sleep=%s\n" "${ar:-?}" "${sl:-?}"

  echo
  printf "%-36s %-10s %-8s %s\n" LABEL STATE PID NOTES
  printf "%-36s %-10s %-8s %s\n" ------- ----- --- ----
  local active_list=" ${ACTIVE_LABELS[*]:-} "
  for label in "${ALL_LABELS[@]}"; do
    local state pid notes=""
    case "$active_list" in
      *" $label "*)
        if daemon_loaded "$label"; then
          state=$(/bin/launchctl print "system/$label" 2>/dev/null | awk '/^[[:space:]]*state[[:space:]]*=/{print $3; exit}')
          pid=$(daemon_pid "$label")
        else
          state="absent"; pid=""
        fi
        case "$label" in
          com.local.immich.ml|com.local.docling.serve|com.local.infinity.serve)
            [ -z "$pid" ] || [ "$pid" = 0 ] && notes="on-demand (sleeping)"
            [ -n "$pid" ] && [ "$pid" != 0 ] && notes="on-demand (awake)"
            ;;
          com.local.iogpu.wiredlimit|com.local.weekly.autoupdate)
            notes="scheduled / one-shot"
            ;;
        esac
        ;;
      *)
        state="skipped"; pid=""; notes="disabled in config (menu 2)"
        ;;
    esac
    printf "%-36s %-10s %-8s %s\n" "$label" "${state:-?}" "${pid:-0}" "$notes"
  done

  echo
  # Scheduled
  local next
  next=$(/bin/launchctl print system/com.local.weekly.autoupdate 2>/dev/null \
         | awk '/next run/{print; exit}')
  printf "Scheduled autoupdate: %s\n" "${next:-(not scheduled)}"

  if [ "${INSTALL_DASHBOARD:-1}" = 1 ]; then
    printf "Web dashboard: http://%s:%s/  (token: DASHBOARD_TOKEN in %s)\n" \
      "$(/bin/hostname 2>/dev/null || echo localhost)" "${DASHBOARD_PORT:-8090}" "$CONF_FILE"
  fi

  if [ "${INSTALL_REMOTE:-1}" = 1 ]; then
    local _host; _host=$(/bin/hostname 2>/dev/null || echo localhost)
    printf "Remote desktop (VNC client): %s:%s  (password: VNC_PASSWORD in %s; NOT :5900 — that offers macOS account login first)\n" \
      "$_host" "${VNC_FILTER_PORT:-5901}" "$CONF_FILE"
    if [ "${INSTALL_NOVNC:-1}" = 1 ]; then
      printf "Remote desktop (browser): http://%s:%s/vnc.html\n" "$_host" "${NOVNC_PORT:-6080}"
    fi
  fi

  echo
}

# ===========================================================================
# Interactive service selection
# ===========================================================================

onoff_label() { [ "$1" = 1 ] && printf 'on ' || printf 'off'; }

toggle_install_flag() {
  local key=$1 cur
  eval "cur=\"\${$key:-1}\""
  if [ "$cur" = 1 ]; then
    save_config_key "$key" 0
    eval "$key=0"
    ok "$key → off"
  else
    save_config_key "$key" 1
    eval "$key=1"
    ok "$key → on"
  fi
}

menu_select_services() {
  load_config
  while true; do
    printf "\n${C_BOLD}── Select services to install ─────────────────${C_RST}\n"
    printf "%s\n" "The MLX stack (mlx_vlm.server + LiteLLM gateway) is the primary backend."
    printf "%s\n" "The GPU-wired-limit helper, caffeinate and the weekly autoupdate are"
    printf "%s\n" "always installed. Re-running setup.sh never overwrites a healthy installed service."
    echo
    printf "  1) %-18s [%s]   MLX stack: mlx_vlm.server :%s internal, LiteLLM :%s public\n" \
      INSTALL_MLX       "$(onoff_label "${INSTALL_MLX:-1}")" \
      "${MAIN_BACKEND_PORT:-18000}" "${LITELLM_PORT:-11434}"
    printf "  2) %-18s [%s]   immich-ml on-demand photo AI (:%s)\n" \
      INSTALL_IMMICH    "$(onoff_label "${INSTALL_IMMICH:-1}")"    "${ML_PUBLIC_PORT:-3003}"
    printf "  3) %-18s [%s]   docling-serve on-demand OCR/VLM (:%s)\n" \
      INSTALL_DOCLING   "$(onoff_label "${INSTALL_DOCLING:-1}")"   "${DOCLING_PUBLIC_PORT:-5001}"
    printf "  4) %-18s [%s]   Prometheus exporters (:%s :%s :%s)\n" \
      INSTALL_EXPORTERS "$(onoff_label "${INSTALL_EXPORTERS:-1}")" \
      "${NODE_EXPORTER_PORT:-9100}" "${SILICON_EXPORTER_PORT:-9101}" "${ONDEMAND_EXPORTER_PORT:-9103}"
    printf "  5) %-18s [%s]   Memory-pressure safety watchdog\n" \
      INSTALL_WATCHDOG  "$(onoff_label "${INSTALL_WATCHDOG:-1}")"
    printf "  6) %-18s [%s]   MQTT bridge -> Home Assistant (runtime data + model switch); host %s\n" \
      INSTALL_MQTT      "$(onoff_label "${INSTALL_MQTT:-0}")" "${MQTT_HOST:-<unset>}"
    printf "  7) %-18s [%s]   Web dashboard (browser control: models/services/settings/logs) :%s\n" \
      INSTALL_DASHBOARD "$(onoff_label "${INSTALL_DASHBOARD:-1}")" "${DASHBOARD_PORT:-8090}"
    printf "  8) %-18s [%s]   Remote desktop: macOS Screen Sharing / VNC, password-only via :%s (Windows client)\n" \
      INSTALL_REMOTE    "$(onoff_label "${INSTALL_REMOTE:-1}")" "${VNC_FILTER_PORT:-5901}"
    printf "  9) %-18s [%s]   Browser VNC bridge (noVNC) :%s/vnc.html — needs #8\n" \
      INSTALL_NOVNC     "$(onoff_label "${INSTALL_NOVNC:-1}")" "${NOVNC_PORT:-6080}"
    echo
    echo "   a) Apply these choices now     q) Back (don't apply)"
    read -r -p "Toggle which? [1-9 / a / q]: " c
    case "$c" in
      1) toggle_install_flag INSTALL_MLX       ;;
      2) toggle_install_flag INSTALL_IMMICH    ;;
      3) toggle_install_flag INSTALL_DOCLING   ;;
      4) toggle_install_flag INSTALL_EXPORTERS ;;
      5) toggle_install_flag INSTALL_WATCHDOG  ;;
      6) toggle_install_flag INSTALL_MQTT      ;;
      7) toggle_install_flag INSTALL_DASHBOARD ;;
      8) toggle_install_flag INSTALL_REMOTE    ;;
      9) toggle_install_flag INSTALL_NOVNC    ;;
      a|A) apply_everything; pause_enter; return 0 ;;
      q|Q|"") return 0 ;;
      *) warn "unknown: $c"; sleep 1 ;;
    esac
  done
}

# ===========================================================================
# TUI menus
# ===========================================================================

pause_enter() { [ "${AUTO_ACCEPT:-0}" = 1 ] && return 0; read -r -p "Press Enter to continue…" _; }

menu_settings() {
  while true; do
    load_config
    printf "\n${C_BOLD}── Change settings ────────────────────────────${C_RST}\n"
    local i=1
    for k in "${CONFIG_KEYS[@]}"; do
      local hint; hint=$(config_hint "$k")
      printf "  %2d) %-28s = %-12s %s\n" "$i" "$k" "${!k:-}" "${hint:+($hint)}"
      i=$((i+1))
    done
    echo "   a) Apply changes now  |  r) Reset to defaults  |  q) Back"
    read -r -p "Edit which? [1-$((i-1)) / a / r / q]: " c
    case "$c" in
      q|Q|"") return 0 ;;
      a|A)
        log "applying settings…"
        apply_everything
        pause_enter
        return 0
        ;;
      r|R)
        if confirm "Reset all keys to defaults (file will be rewritten)?"; then
          write_default_config
          ok "config reset to defaults"
        fi
        ;;
      *[!0-9]*|"") continue ;;
      *)
        if [ "$c" -ge 1 ] && [ "$c" -lt "$i" ]; then
          local key="${CONFIG_KEYS[$((c-1))]}"
          local cur="${!key:-}"
          local hint; hint=$(config_hint "$key")
          printf "%s current value: %s\n" "$key" "$cur"
          [ -n "$hint" ] && printf "  hint: %s\n" "$hint"
          read -r -p "  new value (empty = keep): " newv
          if [ -n "$newv" ]; then
            save_config_key "$key" "$newv"
            ok "saved $key=$newv (not applied yet; choose 'a' to apply)"
          fi
        fi
        ;;
    esac
  done
}

# ===========================================================================
# Model & alias manager (TUI)  — `llm-models` / setup.sh --models
# ===========================================================================

# Path to the `hf` CLI inside one of the MLX venvs. (huggingface_hub >= 1.0
# renamed `huggingface-cli` -> `hf`; the old name is a deprecated no-op shim.)
hf_cli() {
  local base="${VENV_DIR:-/Users/mac/.macstudio-venvs}"
  if [ -x "$base/mlxvlm/bin/hf" ]; then echo "$base/mlxvlm/bin/hf"
  else echo "$base/litellm/bin/hf"; fi
}

ram_guard_warn() {
  local mg; mg=$(catalog_gb "${ALIAS_MAIN:-}"); mg=${mg:-0}
  case "$mg" in *[!0-9]*) mg=0 ;; esac
  local total=$(( mg + 2 ))   # + ~2 GB for the on-demand embed/rerank pair when awake
  if [ "$total" -gt 26 ]; then
    warn "RAM budget: main ${mg} GB + on-demand extras ~2 GB ≈ ${total} GB on a 32 GB box."
    warn "docling/immich may get paused by the watchdog when they wake. A smaller main"
    warn "model leaves more headroom for parallel services."
  fi
}

download_model() {
  local id=$1 repo cli out rc
  [ -z "${id:-}" ] && { err "usage: d <id>"; return 1; }
  repo=$(catalog_repo "$id"); [ -z "$repo" ] && { err "unknown id: $id"; return 1; }
  cli=$(hf_cli)
  [ -x "$cli" ] || { err "hf CLI missing — run 'sudo bash setup.sh --apply' first"; return 1; }
  log "downloading '$id' ($repo) into ${HF_CACHE_DIR:-~/.cache/huggingface} — can be many GB…"
  # tee so the user sees live progress AND we can classify failures afterwards.
  local logf; logf=$(/usr/bin/mktemp -t macstudio-hf-download)
  /usr/bin/sudo -u "$TARGET_USER" -H /usr/bin/env HF_HOME="${HF_CACHE_DIR:-$TARGET_HOME/.cache/huggingface}" \
        "$cli" download "$repo" 2>&1 | /usr/bin/tee "$logf"
  rc=${PIPESTATUS[0]}
  out=$(/usr/bin/tail -40 "$logf" 2>/dev/null)
  if [ "$rc" -eq 0 ] && [ "$(model_status "$repo")" = ok ]; then
    ok "downloaded + verified '$id' — selectable now ('s'/'m'/'k' $id for main/embed/rerank)"
    return 0
  fi
  # Classify the failure so a dead list-item explains itself.
  if printf '%s' "$out" | /usr/bin/grep -qiE '401|403|gated|gating|awaiting|access to|authenticated|restricted'; then
    err "GATED: $repo needs a token + licence acceptance."
    warn "  1) press 't' to store your HF token"
    warn "  2) accept the licence at https://huggingface.co/$repo"
    warn "  3) retry 'd $id'"
  elif printf '%s' "$out" | /usr/bin/grep -qiE '404|repository not found|not found|does not exist'; then
    err "NOT FOUND: '$repo' — fix the repo id with 'e $id' (must be a ready MLX build)"
  elif printf '%s' "$out" | /usr/bin/grep -qiE 'could not resolve|connection|timed out|timeout|network|temporary failure|getaddrinfo'; then
    err "NETWORK: cannot reach HuggingFace — check connectivity, then retry 'd $id'"
  else
    err "download failed (rc=$rc). Last lines:"
    printf '%s\n' "$out" | /usr/bin/tail -6
  fi
  return 1
}

set_model_alias() {
  local slot=$1 id=$2 key repo st role want_role
  [ -z "${id:-}" ] && { err "usage: ${slot:0:1} <id>"; return 1; }
  repo=$(catalog_repo "$id"); [ -z "$repo" ] && { err "unknown id: $id"; return 1; }
  st=$(model_status "$repo")
  [ "$st" = ok ] || { err "'$id' is not fully downloaded (status=$st) — run 'd $id' first"; return 1; }
  case "$slot" in
    main)   key=ALIAS_MAIN;   want_role=text ;;
    embed)  key=ALIAS_EMBED;  want_role=embed ;;
    rerank) key=ALIAS_RERANK; want_role=rerank ;;
    *) err "bad slot: $slot"; return 1 ;;
  esac
  # Roles: text -> 'main' (mlx_vlm.server, unified text+images), embed -> 'embed' +
  # rerank -> 'rerank' (both the Infinity backend).
  role=$(catalog_role "$id"); role=${role:-text}
  if [ "$role" != "$want_role" ]; then
    err "'$id' has role '$role' but slot '$slot' needs role '$want_role' — wrong list"
    return 1
  fi
  # Refuse models the catalog flags BROKEN for the engine that will actually run
  # this slot — selecting one just breaks the server. A bare legacy BROKEN always
  # blocks; an engine-tagged BROKEN[<engine>] blocks ONLY for that engine. Everything
  # runs on mlx-vlm (main) or infinity (embed/rerank).
  local _notes _broken=0 _check_engine
  case "$slot" in
    embed|rerank) _check_engine="infinity" ;;
    *)            _check_engine="mlx-vlm" ;;
  esac
  _notes=$(catalog_field "$id" 13)
  if printf '%s' "$_notes" | /usr/bin/grep -qiE 'BROKEN([^[]|$)'; then
    _broken=1   # bare BROKEN — broken everywhere
  elif printf '%s' "$_notes" | /usr/bin/grep -qiF "BROKEN[$_check_engine]"; then
    _broken=1   # broken on the engine this slot uses
  fi
  if [ "$_broken" = 1 ]; then
    err "'$id' is flagged BROKEN — refusing (would break the server)."
    warn "  see 'i $id' for the reason. Override (not advised): FORCE_BROKEN=1 …"
    [ "${FORCE_BROKEN:-0}" = 1 ] || return 1
    warn "FORCE_BROKEN=1 set — proceeding anyway."
  fi
  save_config_key "$key" "$id"
  eval "$key=\$id"
  ok "$key = $id"
  render_litellm_config
  if [ "$slot" = main ]; then
    ram_guard_warn
    if daemon_loaded com.local.mlxvlm.main; then
      /bin/launchctl kickstart -k system/com.local.mlxvlm.main >/dev/null 2>&1 \
        && ok "restarting com.local.mlxvlm.main with new main model (load ~30–60 s, no hot-swap)"
    fi
  elif [ "$slot" = embed ] || [ "$slot" = rerank ]; then
    if daemon_running com.local.infinity.serve; then
      /bin/launchctl stop com.local.infinity.serve >/dev/null 2>&1 || true
      ok "stopped Infinity backend; next embed/rerank request wakes it with the new model"
    fi
  fi
}

cli_set_model() {
  # Non-interactive model switch — e.g. invoked by the MQTT bridge when Home
  # Assistant selects a model. Reuses set_model_alias and ALL its validation
  # (downloaded, role match, BROKEN refusal). Usage: --set-model <slot> <id>.
  INTERACTIVE=0
  load_config
  [ "$#" -eq 2 ] || { err "usage: --set-model <main|embed|rerank> <id>"; exit 2; }
  set_model_alias "$1" "$2" || exit 1
}

cli_set_config() {
  # --set-config KEY VALUE — save one config key non-interactively (same
  # semantics as the TUI settings menu: save-only, --apply activates). The
  # key must be a known CONFIG_KEYS entry; quoting stays in bash
  # (save_config_key/conf_quote). Used by the web dashboard.
  INTERACTIVE=0
  load_config
  [ "$#" -eq 2 ] || { err "usage: --set-config KEY VALUE"; exit 2; }
  local key=$1 value=$2 k found=0
  for k in "${CONFIG_KEYS[@]}"; do
    [ "$k" = "$key" ] && { found=1; break; }
  done
  [ "$found" = 1 ] || { err "unknown config key: $key"; exit 2; }
  save_config_key "$key" "$value"
  ok "saved $key=$value (not applied yet — run 'sudo bash setup.sh --apply' to activate)"
}

cli_set_service_power() {
  # --set-service-power <label> <on|off> — persistently stop a KeepAlive
  # daemon to free memory (off), or restore normal autorestart + reboot
  # survival (on). Used by the web dashboard's "Stoppen & Freigeben" /
  # "Einschalten" buttons; whitelisted to POWER_LABELS.
  INTERACTIVE=0
  load_config
  [ "$#" -eq 2 ] || { err "usage: --set-service-power <label> <on|off>"; exit 2; }
  local label=$1 want=$2 l found=0
  for l in "${POWER_LABELS[@]}"; do
    [ "$l" = "$label" ] && { found=1; break; }
  done
  [ "$found" = 1 ] || { err "unsupported label for power control: $label"; exit 2; }
  case "$want" in
    off)
      disable_plist "$label"
      bootout_plist "$label"
      if [ "$label" = com.local.infinity.proxy ]; then
        /bin/launchctl stop com.local.infinity.serve >/dev/null 2>&1 || true
      fi
      ok "powered off $label (disabled — survives --apply and reboot)"
      ;;
    on)
      enable_plist "$label"
      bootstrap_plist "$label"
      ok "powered on $label (autorestart + reboot survival restored)"
      ;;
    *)
      err "usage: --set-service-power <label> <on|off>"; exit 2 ;;
  esac
}

cli_config_schema() {
  # --config-schema — dump KEY<TAB>current<TAB>default<TAB>hint, one line per
  # key. TAB-delimited on purpose: hints contain '|' (e.g. TEXT_ENGINE).
  # Consumed by the web dashboard's settings view.
  INTERACTIVE=0
  load_config
  local k
  for k in "${CONFIG_KEYS[@]}"; do
    printf '%s\t%s\t%s\t%s\n' "$k" "${!k:-}" "$(config_default "$k")" "$(config_hint "$k")"
  done
}

cli_download_model() {
  # --download-model <id> — non-interactive download (same classification of
  # gated/404/network failures as the TUI 'd' action). The web dashboard runs
  # this as a detached job and streams the log.
  INTERACTIVE=0
  load_config
  [ "$#" -eq 1 ] || { err "usage: --download-model <id>"; exit 2; }
  download_model "$1" || exit 1
}

cli_delete_model() {
  # --delete-model <id> — delete the local HF files for a catalog id
  # (confirm() auto-accepts because INTERACTIVE=0). Catalog row is kept.
  INTERACTIVE=0
  load_config
  [ "$#" -eq 1 ] || { err "usage: --delete-model <id>"; exit 2; }
  delete_local_model "$1" || exit 1
}

cli_remove_model() {
  # --remove-model <id> — drop a catalog row (local HF files are kept, like the
  # TUI's 'x'). confirm() auto-accepts because INTERACTIVE=0. The dashboard's
  # "Aus Katalog entfernen".
  INTERACTIVE=0
  load_config
  [ "$#" -eq 1 ] || { err "usage: --remove-model <id>"; exit 2; }
  catalog_remove_entry "$1" || exit 1
}

cli_edit_model() {
  # --edit-model id=<slug> [repo=] [role=] [engine=] [quant=] [gb=] [gated=]
  #   [reasoning=] [tool=] [max_kv=] [max_seqs=] [rating=] [notes=]
  #   [temp=] [top_p=] [freq=] [pres=]
  # In-place edit of ONE catalog row (the dashboard's "Bearbeiten"). Only the
  # keys you pass change; the rest keep their current values (pass key= to
  # clear a field). Values may not contain '|' (the TSV delimiter). Mirrors the
  # TUI's catalog_edit_entry + 644 chmod.
  INTERACTIVE=0
  load_config
  local id="" arg k v
  local s_repo=0 s_role=0 s_engine=0 s_quant=0 s_gb=0 s_gated=0 s_rp=0 s_tp=0
  local s_kv=0 s_seqs=0 s_rating=0 s_notes=0 s_temp=0 s_topp=0 s_freq=0 s_pres=0
  local n_repo n_role n_engine n_quant n_gb n_gated n_rp n_tp
  local n_kv n_seqs n_rating n_notes n_temp n_topp n_freq n_pres
  for arg in "$@"; do
    case "$arg" in *=*) : ;; *) err "bad arg '$arg' (expected key=value)"; exit 2 ;; esac
    k=${arg%%=*}; v=${arg#*=}
    case "$v" in *"|"*) err "value for '$k' must not contain '|'"; exit 2 ;; esac
    case "$k" in
      id)        id=$v ;;
      repo)      n_repo=$v;   s_repo=1 ;;
      role)      n_role=$v;   s_role=1 ;;
      engine)    n_engine=$v; s_engine=1 ;;
      quant)     n_quant=$v;  s_quant=1 ;;
      gb)        n_gb=$v;     s_gb=1 ;;
      gated)     n_gated=$v;  s_gated=1 ;;
      reasoning) n_rp=$v;     s_rp=1 ;;
      tool)      n_tp=$v;     s_tp=1 ;;
      max_kv)    n_kv=$v;     s_kv=1 ;;
      max_seqs)  n_seqs=$v;   s_seqs=1 ;;
      rating)    n_rating=$v; s_rating=1 ;;
      notes)     n_notes=$v;  s_notes=1 ;;
      temp)      n_temp=$v;   s_temp=1 ;;
      top_p)     n_topp=$v;   s_topp=1 ;;
      freq)      n_freq=$v;   s_freq=1 ;;
      pres)      n_pres=$v;   s_pres=1 ;;
      *) err "unknown key '$k'"; exit 2 ;;
    esac
  done
  [ -n "$id" ] || { err "usage: --edit-model id=<slug> [repo=] [gb=] [max_kv=] [notes=] …"; exit 2; }
  ensure_model_catalog
  local line; line=$(/usr/bin/grep -E "^${id}\|" "$CATALOG_FILE" | /usr/bin/head -1)
  [ -n "$line" ] || { err "unknown id: $id"; exit 2; }
  local c1 c2 c3 c4 c5 c6 c7 c8 c9 c10 c11 c12 c13 c14 c15 c16 c17
  IFS='|' read -r c1 c2 c3 c4 c5 c6 c7 c8 c9 c10 c11 c12 c13 c14 c15 c16 c17 <<EOF
$line
EOF
  [ "$s_repo" = 1 ]   && c2=$n_repo
  [ "$s_role" = 1 ]   && c3=$n_role
  [ "$s_engine" = 1 ] && c4=$n_engine
  [ "$s_quant" = 1 ]  && c5=$n_quant
  [ "$s_gb" = 1 ]     && c6=$n_gb
  [ "$s_gated" = 1 ]  && c7=$n_gated
  [ "$s_rp" = 1 ]     && c8=$n_rp
  [ "$s_tp" = 1 ]     && c9=$n_tp
  [ "$s_kv" = 1 ]     && c10=$n_kv
  [ "$s_seqs" = 1 ]   && c11=$n_seqs
  [ "$s_rating" = 1 ] && c12=$n_rating
  [ "$s_notes" = 1 ]  && c13=$n_notes
  [ "$s_temp" = 1 ]   && c14=$n_temp
  [ "$s_topp" = 1 ]   && c15=$n_topp
  [ "$s_freq" = 1 ]   && c16=$n_freq
  [ "$s_pres" = 1 ]   && c17=$n_pres
  case "$c3" in text|embed|rerank) : ;; *) err "invalid role '$c3'"; exit 2 ;; esac
  local newline; newline="$c1|$c2|$c3|$c4|$c5|$c6|$c7|$c8|$c9|$c10|$c11|$c12|$c13|$c14|$c15|$c16|$c17"
  local tmp l; tmp=$(/usr/bin/mktemp)
  while IFS= read -r l || [ -n "$l" ]; do
    case "$l" in
      "$id|"*) printf '%s\n' "$newline" ;;
      *)       printf '%s\n' "$l" ;;
    esac
  done <"$CATALOG_FILE" >"$tmp"
  /bin/mv -f "$tmp" "$CATALOG_FILE"
  /bin/chmod 644 "$CATALOG_FILE"
  ok "updated catalog entry '$id'"
  if [ "$id" = "${ALIAS_MAIN:-}" ] \
     || [ "$id" = "${ALIAS_EMBED:-}" ] || [ "$id" = "${ALIAS_RERANK:-}" ]; then
    render_litellm_config
    warn "'$id' is an active alias — re-select it to apply engine-level changes"
  fi
}

cli_add_model() {
  # --add-model key=value … — append a catalog row non-interactively (the web
  # dashboard's "Modell hinzufügen"). Same 17-col schema and 644 chmod as the
  # TUI's catalog_add_entry; editing/removing rows stays TUI-only. Keys:
  #   id=      short slug (required, [A-Za-z0-9._-])
  #   repo=    HF org/name — a ready MLX build (required)
  #   role=    text|embed|rerank            (default text)
  #   engine=  mlxvlm|infinity              (default: derived from role)
  #   quant=   e.g. 4bit                     (default ?)
  #   gb=      approx footprint              (default ?)
  #   gated=   yes|no                        (default no)
  INTERACTIVE=0
  load_config
  local id="" repo="" role="text" engine="" quant="?" gb="?" gated="no" arg
  for arg in "$@"; do
    case "$arg" in
      id=*)     id=${arg#id=} ;;
      repo=*)   repo=${arg#repo=} ;;
      role=*)   role=${arg#role=} ;;
      engine=*) engine=${arg#engine=} ;;
      quant=*)  quant=${arg#quant=} ;;
      gb=*)     gb=${arg#gb=} ;;
      gated=*)  gated=${arg#gated=} ;;
      *) err "bad arg '$arg' (expected key=value)"; exit 2 ;;
    esac
  done
  [ -n "$id" ] && [ -n "$repo" ] || { err "usage: --add-model id=<slug> repo=<org/name> [role=] [engine=] [gb=] [gated=]"; exit 2; }
  case "$id" in
    *[!A-Za-z0-9._-]*) err "invalid id '$id' — use only letters, digits, . _ -"; exit 2 ;;
  esac
  case "$repo" in
    */*) : ;;
    *) err "invalid repo '$repo' — expected 'org/name'"; exit 2 ;;
  esac
  case "$repo" in
    *[\|]*|*" "*) err "invalid repo '$repo' — no spaces or '|'"; exit 2 ;;
  esac
  case "$role" in
    text|embed|rerank) : ;;
    *) err "invalid role '$role' (text|embed|rerank)"; exit 2 ;;
  esac
  if [ -z "$engine" ]; then
    case "$role" in
      embed|rerank) engine=infinity ;;
      *)            engine=mlxvlm ;;
    esac
  fi
  ensure_model_catalog
  if [ -n "$(catalog_repo "$id")" ]; then
    err "id '$id' already exists in the catalog — use the TUI ('e $id') to edit"
    exit 2
  fi
  # 17 cols: id|repo|role|engine|quant|gb|gated|rp|tp|kv|seqs|rating|notes|temp|topp|freq|pres
  printf '%s|%s|%s|%s|%s|%s|%s|||||3|added via dashboard||||\n' \
    "$id" "$repo" "$role" "$engine" "$quant" "$gb" "$gated" >> "$CATALOG_FILE"
  /bin/chmod 644 "$CATALOG_FILE"
  ok "added '$id' (role=$role, engine=$engine) → $repo  (download it next)"
}

cli_set_hf_token() {
  # --set-hf-token — token on STDIN (never argv: visible in `ps`), e.g.
  #   printf '%s' "$TOKEN" | sudo bash setup.sh --set-hf-token
  # Empty stdin = logout. Used by the web dashboard's HF-token dialog.
  INTERACTIVE=0
  load_config
  set_hf_token
}

set_hf_token() {
  # Interactive: prompt. Non-interactive (INTERACTIVE=0, --set-hf-token):
  # read the token from stdin — never from argv (visible in `ps`).
  local t cli
  cli=$(hf_cli)
  [ -x "$cli" ] || { err "hf CLI missing — run 'sudo bash setup.sh --apply' first"; return 1; }
  if [ "$INTERACTIVE" = 0 ]; then
    IFS= read -r t || t=""
  else
    read -r -p "Paste HF token (input visible; blank = logout): " t
  fi
  if [ -z "$t" ]; then
    /usr/bin/sudo -u "$TARGET_USER" -H /usr/bin/env HF_HOME="${HF_CACHE_DIR:-$TARGET_HOME/.cache/huggingface}" \
      "$cli" auth logout >/dev/null 2>&1 || true
    ok "HF token cleared (logged out)"
  elif /usr/bin/sudo -u "$TARGET_USER" -H /usr/bin/env HF_HOME="${HF_CACHE_DIR:-$TARGET_HOME/.cache/huggingface}" \
      "$cli" auth login --token "$t" >/dev/null 2>&1; then
    ok "HF token stored in the user's HF cache (mode 600, not in macstudio.conf)"
  else
    err "hf auth login failed (check the token value)"
  fi
}

delete_local_model() {
  local id=$1 repo d
  [ -z "${id:-}" ] && { err "usage: r <id>"; return 1; }
  repo=$(catalog_repo "$id"); [ -z "$repo" ] && { err "unknown id: $id"; return 1; }
  d=$(model_local_dir "$repo")
  [ -d "$d" ] || { warn "'$id' is not downloaded"; return 0; }
  confirm "delete local files for '$id' ($repo)?" || return 0
  /bin/rm -rf "$d" && ok "deleted $d"
}

catalog_add_entry() {
  # Columns (schema v7): id|hf_repo|role|engine|quant|gb|gated|reasoning|tool|
  #   max_kv|max_seqs|rating|notes|temperature|top_p|frequency_penalty|presence_penalty
  local id repo role engine quant gb gated rp tp
  read -r -p "new id (short slug): " id;       [ -z "$id" ] && return 0
  if catalog_repo "$id" >/dev/null && [ -n "$(catalog_repo "$id")" ]; then
    err "id '$id' already exists — use 'e $id' to edit"; return 0
  fi
  read -r -p "HF repo-id (org/name, MUST be a ready MLX build): " repo; [ -z "$repo" ] && return 0
  read -r -p "role [text] (default text): " role; role=${role:-text}
  # Only engine is mlx-vlm (unified text+images main). embed/rerank use infinity.
  engine=mlxvlm
  read -r -p "quant (e.g. 4bit): " quant;       quant=${quant:-?}
  read -r -p "approx GB: " gb;                  gb=${gb:-?}
  read -r -p "gated? [yes/no] (default no): " gated; gated=${gated:-no}
  rp=""; tp=""
  if [ "$role" = text ]; then
    read -r -p "reasoning_parser [qwen3/glm4/gemma4/gpt_oss/deepseek_r1/empty]: " rp
    read -r -p "tool_parser [hermes/qwen/qwen3_coder/glm47/gemma4/granite/gpt-oss/empty]: " tp
  fi
  # reasoning(8) tool(9) max_kv(10) max_seqs(11) left for per-model override later;
  # rating(12)=3; sampling cols temp(14) top_p(15) freq(16) pres(17) empty = global
  # defaults. Trailing '||||' keeps the row at the full schema-v7 width (17 cols).
  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|||3|added via TUI||||\n' \
    "$id" "$repo" "$role" "$engine" "$quant" "$gb" "$gated" "$rp" "$tp" >> "$CATALOG_FILE"
  /bin/chmod 644 "$CATALOG_FILE"   # keep readable by the daemon user (mac)
  ok "added '$id' (role=$role) → $repo  (download it with 'd $id')"
}

catalog_edit_entry() {
  local id=$1 line
  [ -z "${id:-}" ] && { err "usage: e <id>"; return 1; }
  line=$(/usr/bin/grep -E "^${id}\|" "$CATALOG_FILE" | /usr/bin/head -1)
  [ -z "$line" ] && { err "unknown id: $id"; return 0; }
  local f_id f_repo f_role f_engine f_quant f_gb f_gated f_rp f_tp f_kv f_seqs f_rating f_notes f_temp f_topp f_freq f_pres
  IFS='|' read -r f_id f_repo f_role f_engine f_quant f_gb f_gated f_rp f_tp f_kv f_seqs f_rating f_notes f_temp f_topp f_freq f_pres <<EOF
$line
EOF
  local n_repo n_gb n_gated n_rp n_tp n_kv n_seqs n_temp n_topp n_freq n_pres
  read -r -p "HF repo [$f_repo]: " n_repo;     n_repo=${n_repo:-$f_repo}
  read -r -p "approx GB [$f_gb]: " n_gb;        n_gb=${n_gb:-$f_gb}
  read -r -p "gated [$f_gated]: " n_gated;      n_gated=${n_gated:-$f_gated}
  read -r -p "reasoning_parser [$f_rp]: " n_rp; n_rp=${n_rp:-$f_rp}
  read -r -p "tool_parser [$f_tp]: " n_tp;      n_tp=${n_tp:-$f_tp}
  read -r -p "max_kv_size (empty=global) [$f_kv]: " n_kv;     n_kv=${n_kv:-$f_kv}
  read -r -p "max_num_seqs (empty=global) [$f_seqs]: " n_seqs; n_seqs=${n_seqs:-$f_seqs}
  read -r -p "temperature (empty=model default) [$f_temp]: " n_temp;       n_temp=${n_temp:-$f_temp}
  read -r -p "top_p (empty=model default) [$f_topp]: " n_topp;             n_topp=${n_topp:-$f_topp}
  read -r -p "frequency_penalty (empty=off) [$f_freq]: " n_freq;           n_freq=${n_freq:-$f_freq}
  read -r -p "presence_penalty (empty=off) [$f_pres]: " n_pres;            n_pres=${n_pres:-$f_pres}
  local tmp; tmp=$(/usr/bin/mktemp)
  /usr/bin/awk -F'|' -v OFS='|' -v id="$id" -v repo="$n_repo" -v gb="$n_gb" -v gated="$n_gated" \
      -v rp="$n_rp" -v tp="$n_tp" -v kv="$n_kv" -v seqs="$n_seqs" \
      -v temp="$n_temp" -v topp="$n_topp" -v freq="$n_freq" -v pres="$n_pres" \
    '!/^#/ && $1==id { $2=repo; $6=gb; $7=gated; $8=rp; $9=tp; $10=kv; $11=seqs; $14=temp; $15=topp; $16=freq; $17=pres } { print }' \
    "$CATALOG_FILE" >"$tmp" && /bin/mv -f "$tmp" "$CATALOG_FILE"
  /bin/chmod 644 "$CATALOG_FILE"   # mktemp+mv leaves 600 → restore daemon-readable mode
  ok "updated '$id' (restart vllm with 's $id' if it's the active main)"
}

catalog_remove_entry() {
  local id=$1
  [ -z "${id:-}" ] && { err "usage: x <id>"; return 1; }
  /usr/bin/grep -qE "^${id}\|" "$CATALOG_FILE" || { err "unknown id: $id"; return 0; }
  confirm "remove catalog entry '$id' (downloaded files are kept)?" || return 0
  local tmp; tmp=$(/usr/bin/mktemp)
  /usr/bin/grep -vE "^${id}\|" "$CATALOG_FILE" >"$tmp" && /bin/mv -f "$tmp" "$CATALOG_FILE"
  /bin/chmod 644 "$CATALOG_FILE"   # mktemp+mv leaves 600 → restore daemon-readable mode
  ok "removed catalog entry '$id'"
}

print_catalog_table() {
  local fmt="  %-16s %-5s %-6s %-7s %-10s %-4s %-5s %-3s %-6s %s\n"
  printf "$fmt" ID ROLE STATUS FLAG ENGINE GB GATED RAT ALIAS REPO
  printf "$fmt" ---------------- ---- ------ ------- ---------- ---- ----- --- ------ ----
  local id repo role engine quant gb gated rp tp kv seqs rating notes
  while IFS='|' read -r id repo role engine quant gb gated rp tp kv seqs rating notes; do
    case "$id" in ''|\#*) continue ;; esac
    local st mark tag="" flag=""
    st=$(model_status "$repo")
    case "$st" in ok) mark="ok" ;; partial) mark="PART" ;; *) mark="-" ;; esac
    # FLAG: BROKEN (notes say so -> not selectable) wins; else REC for rating>=5.
    case "$notes" in *BROKEN*|*broken*) flag="BROKEN" ;; esac
    if [ -z "$flag" ]; then case "${rating:-}" in 5) flag="REC" ;; esac; fi
    [ "$id" = "${ALIAS_MAIN:-}" ] && tag="${tag}main "
    printf "$fmt" \
      "$id" "${role:-text}" "$mark" "$flag" "$engine" "$gb" "$gated" "$rating" "${tag:-}" "$repo"
  done <"$CATALOG_FILE"
}

# Full detail for one model — the place to read WHY a model is BROKEN, its
# native context ceiling, parsers, footprint. 'i <id>' in the models menu.
print_model_detail() {
  local id=$1 repo role engine quant gb gated rp tp kv seqs rating notes st
  [ -z "${id:-}" ] && { err "usage: i <id>"; return 1; }
  repo=$(catalog_repo "$id"); [ -z "$repo" ] && { err "unknown id: $id"; return 1; }
  role=$(catalog_field "$id" 3); engine=$(catalog_field "$id" 4)
  quant=$(catalog_field "$id" 5); gb=$(catalog_field "$id" 6)
  gated=$(catalog_field "$id" 7); rp=$(catalog_field "$id" 8)
  tp=$(catalog_field "$id" 9); kv=$(catalog_field "$id" 10)
  seqs=$(catalog_field "$id" 11); rating=$(catalog_field "$id" 12)
  notes=$(catalog_field "$id" 13)
  st=$(model_status "$repo")
  printf "\n${C_BOLD}── %s ──────────────────────────────${C_RST}\n" "$id"
  printf "  repo        %s\n" "$repo"
  printf "  role/engine %s / %s%s\n" "${role:-text}" "${engine:-mlxvlm}" \
    "$( [ "$id" = "${ALIAS_MAIN:-}" ] && printf '   [active main]' )"
  printf "  quant/gb    %s / %s GB\n" "${quant:--}" "${gb:-?}"
  printf "  status      %s   gated=%s   rating=%s/5\n" "$st" "${gated:-no}" "${rating:-?}"
  printf "  parsers     reasoning=%s  tool=%s\n" "${rp:-none}" "${tp:-none}"
  printf "  max_kv/seqs %s / %s\n" "${kv:-<global>}" "${seqs:-<global>}"
  case "$notes" in *BROKEN*|*broken*) printf "  ${C_RED}FLAG        BROKEN — not selectable as main (would break the server)${C_RST}\n" ;;
    *) case "${rating:-}" in 5) printf "  ${C_GRN}FLAG        REC — recommended for this box${C_RST}\n" ;; esac ;;
  esac
  printf "  notes       %s\n\n" "${notes:--}"
}

menu_models() {
  load_config
  ensure_model_catalog
  if [ ! -f "$CATALOG_FILE" ]; then err "no catalog at $CATALOG_FILE"; pause_enter; return 1; fi
  while true; do
    clear 2>/dev/null || true
    printf "${C_BOLD}── Models & aliases ───────────────────────────${C_RST}\n"
    printf "Active:  main=%s  embed=%s  rerank=%s\n" \
      "${ALIAS_MAIN:-none}" "${ALIAS_EMBED:-off}" "${ALIAS_RERANK:-off}"
    printf "${C_DIM}(ONE text+images model loads as 'main'; embed/rerank are on-demand)${C_RST}\n\n"
    print_catalog_table
    printf "\nSTATUS ok = downloaded+verified (only ok is selectable).  FLAG: ${C_RED}BROKEN${C_RST}=not selectable  ${C_GRN}REC${C_RST}=recommended (rating 5).\n"
    printf "Roles: text -> 's' (main)   embed -> 'm'   rerank -> 'k'. Source: HuggingFace repo-ids.\n"
    printf "Actions:  i <id> info   d <id> download   s <id> set TEXT/main\n"
    printf "          m <id> set EMBED   k <id> set RERANK   a add   e <id> edit   x <id> remove   r <id> delete-local   t HF token   q back\n"
    read -r -p "models> " line || return 0
    local cmd arg
    cmd=$(printf '%s' "$line" | /usr/bin/awk '{print $1}')
    arg=$(printf '%s' "$line" | /usr/bin/awk '{print $2}')
    case "$cmd" in
      i) print_model_detail "$arg";    pause_enter ;;
      d) download_model "$arg";        pause_enter ;;
      s) set_model_alias main "$arg";   pause_enter ;;
      m) set_model_alias embed "$arg";  pause_enter ;;
      k) set_model_alias rerank "$arg"; pause_enter ;;
      a) catalog_add_entry;            pause_enter ;;
      e) catalog_edit_entry "$arg";    pause_enter ;;
      x) catalog_remove_entry "$arg";  pause_enter ;;
      r) delete_local_model "$arg";    pause_enter ;;
      t) set_hf_token;                 pause_enter ;;
      q|Q|"") return 0 ;;
      *) warn "unknown: $cmd"; sleep 1 ;;
    esac
  done
}

# Read-only "what could be updated" view. Changes NOTHING — the LLM stack is
# frozen on purpose; the user bumps it deliberately via MLXVLM_VERSION.
menu_updates() {
  load_config
  printf "\n${C_BOLD}── Check for updates (read-only) ──────────────${C_RST}\n"
  printf "mlx-vlm pin: MLXVLM_VERSION=%s   (text engine — frozen unless you bump it)\n\n" \
    "${MLXVLM_VERSION:-<float=latest>}"
  printf "LLM stack (installed vs PyPI):\n"
  local pair vn pk py
  for pair in mlxvlm:mlx-vlm litellm:litellm; do
    vn=${pair%%:*}; pk=${pair##*:}
    py="${VENV_DIR:-/Users/mac/.macstudio-venvs}/$vn/bin/python"
    if [ ! -x "$py" ]; then printf "  %-10s (venv not built)\n" "$pk"; continue; fi
    /usr/bin/sudo -u "$TARGET_USER" -H "$py" - "$pk" <<'PY' 2>/dev/null || printf "  %-10s (check failed)\n" "$pk"
import sys, json, urllib.request, importlib.metadata as M
pkg = sys.argv[1]
try: cur = M.version(pkg)
except Exception: cur = "?"
try:
    d = json.load(urllib.request.urlopen("https://pypi.org/pypi/%s/json" % pkg, timeout=8))
    stable = d["info"]["version"]
    try:
        from packaging.version import Version
        newest = str(max(Version(v) for v in d["releases"].keys()))
    except Exception:
        newest = stable
    flag = "" if cur in (stable, newest) else "   <-- newer available"
    print("  %-10s installed=%-11s stable=%-11s newest=%-11s%s" % (pkg, cur, stable, newest, flag))
except Exception:
    print("  %-10s installed=%-11s (PyPI n/a — offline?)" % (pkg, cur))
PY
  done
  printf "\nHomebrew packages (auto-updated weekly):\n"
  brew_ outdated 2>/dev/null | /usr/bin/sed 's/^/  /' || echo "  (brew n/a)"
  printf "macOS updates:\n"
  /usr/sbin/softwareupdate -l 2>&1 | /usr/bin/grep -iE 'label:|recommended|^\* |no new software' | /usr/bin/sed 's/^/  /' | /usr/bin/head -8
  printf "\n${C_DIM}Upgrade the LLM stack on purpose: menu 4 -> set MLXVLM_VERSION -> menu 1.${C_RST}\n"
  pause_enter
}

menu_service_ctl() {
  load_config
  while true; do
    printf "\n${C_BOLD}── Service control ────────────────────────────${C_RST}\n"
    local i=1
    local -a menu_labels=()
    for label in "${ACTIVE_LABELS[@]}"; do
      local pid state
      pid=$(daemon_pid "$label"); pid=${pid:-0}
      if daemon_loaded "$label"; then
        if [ "$pid" != 0 ]; then state="${C_GRN}running${C_RST}"; else state="${C_DIM}sleeping${C_RST}"; fi
      elif label_disabled "$label"; then state="${C_RED}disabled${C_RST}"
      else state="${C_RED}absent${C_RST}"; fi
      printf "  %2d) %-36s %b  pid=%s\n" "$i" "$label" "$state" "$pid"
      menu_labels+=("$label")
      i=$((i+1))
    done
    echo "   a) Restart all always-on  |  q) Back"
    read -r -p "Pick a number to act on (or a/q): " c
    case "$c" in
      q|Q|"") return 0 ;;
      a|A)
        for l in "${ALWAYS_ON_LABELS[@]}"; do
          daemon_loaded "$l" && /bin/launchctl kickstart -k "system/$l" && ok "kickstarted $l"
        done
        pause_enter
        ;;
      *[!0-9]*|"") continue ;;
      *)
        if [ "$c" -ge 1 ] && [ "$c" -le "${#menu_labels[@]}" ]; then
          local label="${menu_labels[$((c-1))]}"
          local is_power=0 pl
          for pl in "${POWER_LABELS[@]}"; do [ "$pl" = "$label" ] && is_power=1; done
          if [ "$is_power" = 1 ]; then
            echo "  1) kickstart (restart)  2) stop  3) view logs  4) power off (free memory permanently)  5) power on (restore autorestart)  q) back"
          else
            echo "  1) kickstart (restart)  2) stop  3) view logs  q) back"
          fi
          read -r -p "Action: " a
          case "$a" in
            1) /bin/launchctl kickstart -k "system/$label" && ok "kickstarted $label" ;;
            2) /bin/launchctl stop "$label" && ok "stop signal sent to $label" ;;
            3) local logf
               logf=$(label_log "$label")
               if [ -f "$logf" ]; then /usr/bin/tail -n 40 "$logf"; else warn "log not found: $logf"; fi
               pause_enter
               ;;
            4) [ "$is_power" = 1 ] && { local _prev_ia="$INTERACTIVE"; cli_set_service_power "$label" off; INTERACTIVE="$_prev_ia"; } ;;
            5) [ "$is_power" = 1 ] && { local _prev_ia="$INTERACTIVE"; cli_set_service_power "$label" on; INTERACTIVE="$_prev_ia"; } ;;
          esac
        fi
        ;;
    esac
  done
}

menu_cleanup() {
  while true; do
    printf "\n${C_BOLD}── Clean-up tasks ─────────────────────────────${C_RST}\n"
    echo "  1) Purge logs older than 30 days in $LOG_DIR"
    echo "  2) Uninstall node_exporter"
    echo "  q) Back"
    read -r -p "Choice: " c
    case "$c" in
      q|Q|"") return 0 ;;
      1) /usr/bin/find "$LOG_DIR" -type f -name '*.log*' -mtime +30 -print -delete 2>/dev/null; pause_enter ;;
      2) confirm "uninstall node_exporter?" && brew_ uninstall node_exporter >/dev/null 2>&1 || true; pause_enter ;;
    esac
  done
}

# Follow a log live; Ctrl-C returns to the menu (trap keeps the TUI alive).
# For the text-engine log we filter to the lines that show what the model is
# actually doing (requests, completions, running/queued, errors) — rest is noise.
follow_log() {
  local f=$1
  printf "\n${C_DIM}── live: %s  (Ctrl-C to stop) ──${C_RST}\n" "$f"
  trap 'true' INT
  case "$f" in
    *mlxvlm-main.log)
      /usr/bin/tail -n 20 -F "$f" 2>/dev/null \
        | /usr/bin/grep --line-buffered -E 'REQUEST|Chat completion|tok/s|running=|ABORTED|schedule|Error|Traceback|mllm=' || true ;;
    *)
      /usr/bin/tail -n 40 -F "$f" 2>/dev/null || true ;;
  esac
  trap - INT
  printf "\n${C_DIM}(stopped)${C_RST}\n"
}

menu_logs() {
  printf "\n${C_BOLD}── Logs in %s ──${C_RST}\n" "$LOG_DIR"
  local files=()
  for f in "$LOG_DIR"/*.log; do [ -f "$f" ] && files+=("$f"); done
  if [ "${#files[@]}" = 0 ]; then warn "no logs found"; pause_enter; return 0; fi
  local i=1
  for f in "${files[@]}"; do printf "  %2d) %s\n" "$i" "$(basename "$f")"; i=$((i+1)); done
  echo "   q) Back"
  echo "   Tip: prefix with 'f' to FOLLOW live (e.g. 'f 1'); a number alone = last 100 lines."
  read -r -p "View which? " c
  local follow=0
  case "$c" in
    f\ *|F\ *) follow=1; c=${c#* } ;;
    f*|F*)     follow=1; c=${c#?} ;;
  esac
  case "$c" in
    q|Q|"") return 0 ;;
    *[!0-9]*) return 0 ;;
  esac
  if [ "$c" -ge 1 ] && [ "$c" -le "${#files[@]}" ]; then
    if [ "$follow" = 1 ]; then
      follow_log "${files[$((c-1))]}"
    else
      /usr/bin/tail -n 100 "${files[$((c-1))]}"
    fi
    pause_enter
  fi
}

menu_uninstall() {
  echo
  warn "This will REMOVE everything this tool installed (plists, wrappers, logs, config)."
  warn "It will NOT touch Homebrew or your downloaded models."
  if ! confirm "Proceed with uninstall?"; then return 0; fi
  for label in "${ALL_LABELS[@]}"; do
    bootout_plist "$label"
    /bin/rm -f "$PLIST_DIR/$label.plist"
  done
  /bin/rm -rf "$LIBEXEC_DIR"/start-*.sh "$LIBEXEC_DIR"/ondemand-proxy.py \
              "$LIBEXEC_DIR"/silicon-exporter.py \
              "$LIBEXEC_DIR"/ondemand-exporter.py "$LIBEXEC_DIR"/llm-watchdog.sh \
              "$LIBEXEC_DIR"/mqtt-bridge.py "$LIBEXEC_DIR"/dashboard.py \
              "$LIBEXEC_DIR"/dashboard-ui.html "$LIBEXEC_DIR"/paperless-ocr.py
  /bin/rm -rf /usr/local/etc/macstudio-models
  /bin/rm -f /usr/local/etc/litellm.config.yaml
  /bin/rm -f "$SBIN_DIR/set-iogpu-wired-limit.sh" "$SBIN_DIR/weekly-autoupdate.sh"
  for b in llm-status llm-restart llm-update llm-service-ctl llm-logs llm-models; do
    /bin/rm -f "$BIN_DIR/$b"
  done
  warn "Kept: Python venvs ($VENV_DIR) and the HuggingFace model cache"
  warn "      (${HF_CACHE_DIR:-~/.cache/huggingface}). Delete those by hand to reclaim disk."
  if [ -f "$MOTD_BACKUP" ]; then /bin/cp -f "$MOTD_BACKUP" "$MOTD_FILE"; fi
  /bin/rm -f "$CONF_FILE" "$REPO_POINTER_FILE"
  /bin/rm -rf "$LOG_DIR"
  ok "uninstalled (Homebrew + Ollama untouched)"
  pause_enter
}

print_header() {
  printf "\n${C_BOLD}══════════════════════════════════════════════════════════════════════\n"
  printf "  Mac Studio Headless LLM Server  —  setup.sh v%s\n" "$SCRIPT_VERSION"
  printf "══════════════════════════════════════════════════════════════════════${C_RST}\n"
}

main_menu() {
  need_root "$@"
  # First-run welcome: guide the user through service selection before the
  # normal TUI. Config file was absent at startup → FIRST_RUN=1.
  if [ "${FIRST_RUN:-0}" = 1 ]; then
    clear 2>/dev/null || true
    print_header
    load_config   # writes defaults if absent
    printf "\n${C_BOLD}Welcome — first run detected.${C_RST}\n"
    printf "Default config written to %s\n" "$CONF_FILE"
    printf "Step 1: pick which optional services you want installed.\n"
    printf "        (Everything is on by default. Re-run later to add more.)\n"
    pause_enter
    menu_select_services
    FIRST_RUN=0
  fi
  while true; do
    clear 2>/dev/null || true
    print_header
    verify_and_summary
    echo "Main menu:"
    echo "  1) Install / update everything   (recommended — applies current config)"
    echo "  2) Select services to install…   (toggle MLX / Ollama / immich / docling / …)"
    echo "  3) Models & aliases…             (download MLX models, pick main / embed / rerank)"
    echo "  4) Change settings…"
    echo "  5) Service control…"
    echo "  6) Check for updates…           (versions: LLM stack / brew / macOS — read-only)"
    echo "  7) Run weekly autoupdate now     (OS + brew system packages only)"
    echo "  8) Clean-up tasks…"
    echo "  9) View logs…"
    echo " 10) Uninstall everything this tool installed"
    echo "  q) Quit"
    read -r -p "Choice: " choice
    case "$choice" in
      1) apply_everything; pause_enter ;;
      2) menu_select_services ;;
      3) menu_models ;;
      4) menu_settings ;;
      5) menu_service_ctl ;;
      6) menu_updates ;;
      7) log "running weekly-autoupdate.sh NOW"; /bin/bash "$SBIN_DIR/weekly-autoupdate.sh" || true; pause_enter ;;
      8) menu_cleanup ;;
      9) menu_logs ;;
      10) menu_uninstall ;;
      q|Q|"") exit 0 ;;
      *) warn "unknown choice: $choice"; sleep 1 ;;
    esac
  done
}

show_help() {
  cat <<USAGE
MacStudio LLM Server — setup.sh v${SCRIPT_VERSION}

  sudo bash setup.sh             Interactive TUI (recommended)
  sudo bash setup.sh --apply     Non-interactive install/update (no prompts)
  sudo bash setup.sh --status    Print live status and exit
  sudo bash setup.sh --set-model <main|embed|rerank> <id>
                                 Switch a model slot non-interactively (same
                                 validation as the TUI; used by the MQTT bridge
                                 and the web dashboard)
  sudo bash setup.sh --set-config KEY VALUE
                                 Save one config key (no apply; key must exist)
  sudo bash setup.sh --set-service-power <label> <on|off>
                                 Persistently power off/on the main LLM or the
                                 Infinity proxy to free/restore memory (off =
                                 disable+bootout, survives --apply and reboot;
                                 on = enable+bootstrap, normal autorestart)
  sudo bash setup.sh --config-schema
                                 Dump KEY<TAB>current<TAB>default<TAB>hint
  sudo bash setup.sh --add-model id=<slug> repo=<org/name> [role=text] [engine=] [gb=] [gated=no]
                                 Append a new catalog entry (then download it)
  sudo bash setup.sh --edit-model id=<slug> [repo=] [gb=] [reasoning=] [tool=]
                                 [max_kv=] [max_seqs=] [rating=] [notes=] [temp=] …
                                 Edit fields of an existing catalog entry in place
  sudo bash setup.sh --remove-model <id>
                                 Remove a catalog row (local files are kept)
  sudo bash setup.sh --download-model <id>
                                 Download a catalog model non-interactively
  sudo bash setup.sh --delete-model <id>
                                 Delete a model's local HF files (row is kept)
  sudo bash setup.sh --set-hf-token
                                 Store the HF token read from STDIN (empty=logout)
  sudo bash setup.sh --help      Show this help

Global modifiers (combine with any mode above):
  -v, --verbose                  Chatty output ([dbg] decision traces)
  -d, --debug                    Shell-level trace (set -x with file:line)

Re-running is always safe — every action inspects current state first.
Config lives at: $CONF_FILE
Logs: $LOG_DIR
USAGE
}

# ===========================================================================
# Argv dispatch
# ===========================================================================

# Pre-parse global modifiers (-v/-d). They can appear in any position; we
# set VERBOSE/DEBUG eagerly so they affect every subsequent step, strip them
# from the dispatched argv, but keep the ORIGINAL argv around so the sudo
# re-exec can pass the flags through (shell variables don't survive re-exec).
# Bash 3.2 + `set -u` errors on "${arr[@]}" when empty, so guard the rebuild.
if [ "$#" -gt 0 ]; then
  _orig_args=("$@")
  for _arg in "$@"; do
    case "$_arg" in
      -v|--verbose) VERBOSE=1 ;;
      -d|--debug)   DEBUG=1; VERBOSE=1 ;;
    esac
  done
  _args=()
  for _arg in "$@"; do
    case "$_arg" in
      -v|--verbose|-d|--debug) ;;
      *) _args+=("$_arg") ;;
    esac
  done
  if [ "${#_args[@]}" -gt 0 ]; then
    set -- "${_args[@]}"
  else
    set --
  fi
  unset _args _arg
else
  _orig_args=()
fi
[ "$DEBUG" = 1 ] && { PS4='+ ${BASH_SOURCE##*/}:${LINENO}: '; set -x; }

# First-run detection: config-file absence at startup triggers the welcome
# flow in main_menu(). The self-elevate re-exec below re-runs the script, so
# this is naturally re-evaluated in the child — no state to pass through.
FIRST_RUN=0
[ -f "$CONF_FILE" ] || FIRST_RUN=1

# Self-elevate before doing real work. Use the stripped argv for the help
# check (so `-d --help` still skips sudo), but pass the ORIGINAL argv to
# the re-exec so global modifiers survive.
case "${1:-}" in
  --help|-h) : ;;   # help is readable; don't require sudo
  *)
    if [ "$(id -u)" -ne 0 ]; then
      if [ "${#_orig_args[@]}" -gt 0 ]; then
        exec sudo -E /bin/bash "$0" "${_orig_args[@]}"
      else
        exec sudo -E /bin/bash "$0"
      fi
    fi
    ;;
esac
unset _orig_args

case "${1:-}" in
  --apply)  APPLY_MODE=1; INTERACTIVE=0; shift; apply_everything "$@" ;;
  --status) INTERACTIVE=0; load_config; verify_and_summary ;;
  --models) need_root "$@"; menu_models ;;
  --set-model) need_root "$@"; shift; cli_set_model "$@" ;;
  --set-config) need_root "$@"; shift; cli_set_config "$@" ;;
  --set-service-power) need_root "$@"; shift; cli_set_service_power "$@" ;;
  --config-schema) need_root "$@"; cli_config_schema ;;
  --download-model) need_root "$@"; shift; cli_download_model "$@" ;;
  --delete-model) need_root "$@"; shift; cli_delete_model "$@" ;;
  --add-model) need_root "$@"; shift; cli_add_model "$@" ;;
  --edit-model) need_root "$@"; shift; cli_edit_model "$@" ;;
  --remove-model) need_root "$@"; shift; cli_remove_model "$@" ;;
  --set-hf-token) need_root "$@"; cli_set_hf_token ;;
  --check-updates) need_root "$@"; menu_updates ;;
  --help|-h) show_help ;;
  "") main_menu "$@" ;;
  *) err "unknown flag: $1"; show_help; exit 2 ;;
esac
