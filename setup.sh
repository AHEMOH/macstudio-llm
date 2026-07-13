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
  com.local.omlx.main
  com.local.litellm.proxy
  com.local.images.proxy
  com.local.voicestt.proxy
  com.local.voicetts.proxy
  com.local.voicewyoming.proxy
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
  com.local.images.serve
  com.local.voicestt.serve
  com.local.voicetts.serve
  com.local.immich.ml
  com.local.docling.serve
)
ALL_LABELS=( "${ALWAYS_ON_LABELS[@]}" "${ONDEMAND_LABELS[@]}" )
# Label the dashboard/TUI may power off/on to free RAM. Whitelisted — this is
# the only daemon with KeepAlive=true that holds significant memory; a plain
# `launchctl stop` on it is undone by launchd within a second, so freeing
# memory for good requires the persistent disable+bootout below.
POWER_LABELS=(com.local.omlx.main)

# --- Config keys with defaults --------------------------------------------
# (order preserved, used for save_config and menu_settings)
CONFIG_KEYS=(
  TARGET_USER
  TARGET_HOME
  IMMICH_PROJECT_DIR
  IMMICH_REPO
  IMMICH_REPO_REF
  IMMICH_MLX_VERSION
  DOCLING_PROJECT_DIR
  IOGPU_WIRED_LIMIT_MB
  INSTALL_MLX
  VENV_DIR
  HF_CACHE_DIR
  ALIAS_MAIN
  MODEL_PIN_MAIN
  MAIN_BACKEND_PORT
  LLM_REQUEST_TIMEOUT
  TEXT_ENGINE
  OMLX_REPO
  OMLX_REPO_REF
  OMLX_PROJECT_DIR
  OMLX_MODEL_DIR
  OMLX_MEMORY_GUARD_GB
  OMLX_SSD_CACHE_DIR
  OMLX_SSD_CACHE_MAX_SIZE
  OMLX_HOT_CACHE_MAX_SIZE
  OMLX_MAX_CONCURRENT_REQUESTS
  OMLX_MAX_CONTEXT_WINDOW
  GEMMA_TOP_K
  PRESET_ALIASES
  LITELLM_PORT
  ALIAS_EMBED
  ALIAS_RERANK
  INSTALL_IMAGES
  IMAGES_PUBLIC_PORT
  IMAGES_BACKEND_PORT
  IDLE_TIMEOUT_IMAGES
  STARTUP_TIMEOUT_IMAGES
  MFLUX_MODEL
  MFLUX_QUANTIZE
  MFLUX_STEPS
  MFLUX_MODEL_DIR
  INSTALL_VOICE
  VOICE_PROJECT_DIR
  VOICESTT_PUBLIC_PORT
  VOICESTT_BACKEND_PORT
  IDLE_TIMEOUT_VOICESTT
  STARTUP_TIMEOUT_VOICESTT
  VOICETTS_PUBLIC_PORT
  VOICETTS_BACKEND_PORT
  IDLE_TIMEOUT_VOICETTS
  STARTUP_TIMEOUT_VOICETTS
  VOICE_TTS_DEFAULT_VOICE
  VOICE_WYOMING_PUBLIC_PORT
  VOICE_WYOMING_BACKEND_PORT
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
    IMMICH_REPO)                 echo https://github.com/sebastianfredette/immich-ml-metal ;;
    IMMICH_REPO_REF)             echo main ;;
    IMMICH_MLX_VERSION)          echo 0.30.0 ;;
    DOCLING_PROJECT_DIR)         echo /Users/mac/projects/docling-serve ;;
    IOGPU_WIRED_LIMIT_MB)        echo 30720 ;;
    INSTALL_MLX)                 echo 1 ;;
    VENV_DIR)                    echo /Users/mac/.macstudio-venvs ;;
    HF_CACHE_DIR)                echo /Users/mac/.cache/huggingface ;;
    ALIAS_MAIN)                  echo gemma4-26b-qat ;;
    MODEL_PIN_MAIN)              echo 1 ;;
    MAIN_BACKEND_PORT)           echo 18000 ;;
    LLM_REQUEST_TIMEOUT)         echo 3600 ;;
    TEXT_ENGINE)                 echo omlx ;;
    OMLX_REPO)                   echo https://github.com/jundot/omlx ;;
    OMLX_REPO_REF)               echo v0.5.1 ;;
    OMLX_PROJECT_DIR)            echo /Users/mac/projects/omlx ;;
    OMLX_MODEL_DIR)              echo /Users/mac/.cache/omlx-models ;;
    OMLX_MEMORY_GUARD_GB)        echo 30 ;;
    OMLX_SSD_CACHE_DIR)          echo /Users/mac/.cache/omlx-ssd-cache ;;
    OMLX_SSD_CACHE_MAX_SIZE)     echo 20GB ;;
    OMLX_HOT_CACHE_MAX_SIZE)     echo "" ;;
    OMLX_MAX_CONCURRENT_REQUESTS) echo 8 ;;
    OMLX_MAX_CONTEXT_WINDOW)     echo 65536 ;;
    GEMMA_TOP_K)                 echo 64 ;;
    PRESET_ALIASES)              echo 1 ;;
    LITELLM_PORT)                echo 11434 ;;
    ALIAS_EMBED)                 echo bge-m3 ;;
    ALIAS_RERANK)                echo bge-reranker-v2-m3 ;;
    INSTALL_IMAGES)              echo 0 ;;
    IMAGES_PUBLIC_PORT)          echo 5005 ;;
    IMAGES_BACKEND_PORT)         echo 15005 ;;
    IDLE_TIMEOUT_IMAGES)         echo 900 ;;
    STARTUP_TIMEOUT_IMAGES)      echo 60 ;;
    MFLUX_MODEL)                 echo dev ;;
    MFLUX_QUANTIZE)              echo 8 ;;
    MFLUX_STEPS)                 echo "" ;;
    MFLUX_MODEL_DIR)             echo /Users/mac/.cache/mflux-models ;;
    INSTALL_VOICE)               echo 0 ;;
    VOICE_PROJECT_DIR)           echo /Users/mac/projects/macos-speech-server ;;
    VOICESTT_PUBLIC_PORT)        echo 5006 ;;
    VOICESTT_BACKEND_PORT)       echo 15006 ;;
    IDLE_TIMEOUT_VOICESTT)       echo -1 ;;
    STARTUP_TIMEOUT_VOICESTT)    echo 60 ;;
    VOICETTS_PUBLIC_PORT)        echo 5007 ;;
    VOICETTS_BACKEND_PORT)       echo 15007 ;;
    IDLE_TIMEOUT_VOICETTS)       echo 900 ;;
    STARTUP_TIMEOUT_VOICETTS)    echo 60 ;;
    VOICE_TTS_DEFAULT_VOICE)     echo "Katya (Enhanced)" ;;
    VOICE_WYOMING_PUBLIC_PORT)   echo 10300 ;;
    VOICE_WYOMING_BACKEND_PORT)  echo 15008 ;;
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
    INSTALL_IMMICH)              echo 0 ;;
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
    INSTALL_MLX)                 echo "1 = install the MLX stack (oMLX — unified text+images+embed+rerank main + LiteLLM gateway) as the primary backend" ;;
    VENV_DIR)                    echo "Where the omlx/litellm Python venvs live (owned by TARGET_USER)" ;;
    HF_CACHE_DIR)                echo "HuggingFace model cache (HF_HOME) — where downloaded MLX models land" ;;
    ALIAS_MAIN)                  echo "Catalog id of the ONE active main/text model (manage via 'llm-models')" ;;
    MODEL_PIN_MAIN)              echo "1 = keep the main model permanently warm (agentic main load)" ;;
    MAIN_BACKEND_PORT)           echo "Internal port the text engine (oMLX) binds; LiteLLM fronts it" ;;
    LLM_REQUEST_TIMEOUT)         echo "Per-request timeout in seconds for the text engine + LiteLLM (default 3600 = 60 min; long docs/OCR)" ;;
    TEXT_ENGINE)                 echo "Engine serving 'main'/'embed'/'rerank': omlx (UNIFIED text+images+embed+rerank in ONE process, SSD paged-prefix-cache, continuous batching). The only supported engine" ;;
    OMLX_REPO)                   echo "Git URL of oMLX (jundot/omlx), cloned+editable-installed into OMLX_PROJECT_DIR" ;;
    OMLX_REPO_REF)               echo "Pinned oMLX tag (default v0.5.1, alpha-stage) — bump deliberately + --apply, mirrors MLXVLM_VERSION's old pin discipline" ;;
    OMLX_PROJECT_DIR)            echo "Where ensure_omlx_project() clones+builds oMLX (git clone + pip install -e, one-time + on ref bump during --apply)" ;;
    OMLX_MODEL_DIR)              echo "--model-dir symlink farm (mlx-<catalog-id> per downloaded row) that makes every model — main AND embed/rerank — discoverable by the one resident oMLX process" ;;
    OMLX_MEMORY_GUARD_GB)        echo "oMLX's soft RAM ceiling (--memory-guard-gb) — matches the project's 30GB wired-memory hard rule. oMLX has no hard --max-kv-size-equivalent flag" ;;
    OMLX_SSD_CACHE_DIR)          echo "oMLX's paged-prefix SSD cache directory (--paged-ssd-cache-dir) — gives ~15x TTFT on repeated long prompts. Empty = disabled" ;;
    OMLX_SSD_CACHE_MAX_SIZE)     echo "Max size of the SSD paged-prefix cache (--paged-ssd-cache-max-size), e.g. 20GB" ;;
    OMLX_HOT_CACHE_MAX_SIZE)     echo "oMLX in-memory hot-cache max size (--hot-cache-max-size). Empty = oMLX default" ;;
    OMLX_MAX_CONCURRENT_REQUESTS) echo "oMLX max concurrent in-flight requests (--max-concurrent-requests, continuous batching). Default 8" ;;
    OMLX_MAX_CONTEXT_WINDOW)     echo "Per-model context cap for the active main, pre-seeded into ~/.omlx/settings.json (NOT a CLI flag — oMLX has no --max-kv-size equivalent). Default 65536 (64K), preserving today's documented ceiling" ;;
    GEMMA_TOP_K)                 echo "Gemma reference top_k for main/main-fast (default 64; Gemma's recommended sampling is temp 1.0 / top_p 0.95 / top_k 64). top_k is NOT a native OpenAI param so it rides in extra_body. 0/empty = off" ;;
    PRESET_ALIASES)              echo "1 = also expose the 'main-fast' preset alias (same loaded model as 'main' but thinking-OFF at the proxy — fast non-reasoning chat / tools / web / cron / email)" ;;
    LITELLM_PORT)                echo "Public gateway port apps use (/v1, /v1/messages). Replaces Ollama's :11434" ;;
    ALIAS_EMBED)                 echo "Catalog id of the embedding model (role=embed, engine omlx, served by the SAME process as main) -> LiteLLM alias 'embed'. empty = embeddings off" ;;
    ALIAS_RERANK)                echo "Catalog id of the reranker (role=rerank, engine omlx, served by the SAME process as main) -> LiteLLM alias 'rerank'. empty = rerank off" ;;
    INSTALL_IMAGES)              echo "1 = run the on-demand FLUX image-generation backend (mflux, MLX-native) exposed via LiteLLM as the 'image' alias for OpenWebUI's native Images feature. Opt-in (default 0) — NOT part of the model catalog (image generation doesn't fit the text/embed/rerank role system; see CLAUDE.md)" ;;
    IMAGES_PUBLIC_PORT)          echo "Public on-demand-proxy port for the images backend (default 5005)" ;;
    IMAGES_BACKEND_PORT)         echo "Internal port mflux-server.py binds (127.0.0.1 only, default 15005)" ;;
    IDLE_TIMEOUT_IMAGES)         echo "Seconds before the images backend sleeps (default 900); -1 = never sleep. Low idle cost either way — mflux-server.py holds no model in memory between requests" ;;
    STARTUP_TIMEOUT_IMAGES)      echo "Seconds the proxy waits for the images backend to report healthy after waking (default 60 — fast, since health is just 'is Flask up + is the quantized model on disk', not a model load)" ;;
    MFLUX_MODEL)                 echo "FLUX variant for mflux: dev (gated on HF, better quality) or schnell (ungated, faster, more artifacts on text/hands). Tested 2026-07: dev+4-bit is quality-safe and fits alongside main (28.35 of 32GB); dev+8-bit is closer to full quality but noticeably degrades main during generation (17 tok/s vs 48 baseline) and briefly spikes swap ~3GB — acceptable for infrequent use, revisit if usage grows" ;;
    MFLUX_QUANTIZE)              echo "mflux quantization bits: 3,4,5,6, or 8. Lower = smaller/faster/safer alongside main, higher = closer to full bf16 quality. See MFLUX_MODEL hint for the 4 vs 8 bit measurements" ;;
    MFLUX_STEPS)                 echo "Inference steps per image; empty = model default (schnell=4, dev=20)" ;;
    MFLUX_MODEL_DIR)             echo "Where ensure_mflux_model() saves the pre-quantized checkpoint (mflux-save, one-time during --apply). Subdirectory name is <MFLUX_MODEL>-q<MFLUX_QUANTIZE>" ;;
    INSTALL_VOICE)               echo "1 = run two on-demand voice backends exposed via LiteLLM as 'stt'/'tts' aliases for OpenWebUI's native voice input/output: Speech-to-Text via FluidAudio's macos-speech-server (Parakeet, Apple Neural Engine — measured zero GPU contention with the resident main LLM) and Text-to-Speech via macOS's own 'say' (faster and bug-free vs. macos-speech-server's bundled TTS, see CLAUDE.md). Opt-in (default 0) — NOT part of the model catalog, same reasoning as INSTALL_IMAGES" ;;
    VOICE_PROJECT_DIR)           echo "Where ensure_voice_project() clones+builds FluidAudio's macos-speech-server (git clone + swift build -c release, one-time during --apply, several minutes)" ;;
    VOICESTT_PUBLIC_PORT)        echo "Public on-demand-proxy port for the Speech-to-Text backend (default 5006)" ;;
    VOICESTT_BACKEND_PORT)       echo "Internal port the speech-server binary binds (127.0.0.1 only, default 15006)" ;;
    IDLE_TIMEOUT_VOICESTT)       echo "Seconds before the STT backend sleeps; default -1 = never sleep. Deliberately kept warm — this backend is shared by TWO independent on-demand proxies (com.local.voicestt.proxy for LiteLLM's 'stt' HTTP alias, com.local.voicewyoming.proxy for Home Assistant), and letting either one auto-sleep it would fight the other's wake cycle. Small footprint either way (~200MB Parakeet model)" ;;
    STARTUP_TIMEOUT_VOICESTT)    echo "Seconds the proxy waits for the STT backend to report healthy after waking (default 60)" ;;
    VOICETTS_PUBLIC_PORT)        echo "Public on-demand-proxy port for the Text-to-Speech backend (default 5007)" ;;
    VOICETTS_BACKEND_PORT)       echo "Internal port say-tts-server.py binds (127.0.0.1 only, default 15007)" ;;
    IDLE_TIMEOUT_VOICETTS)       echo "Seconds before the TTS backend sleeps (default 900); -1 = never sleep. Near-zero idle cost either way — say-tts-server.py holds no model in memory between requests" ;;
    STARTUP_TIMEOUT_VOICETTS)    echo "Seconds the proxy waits for the TTS backend to report healthy after waking (default 60 — fast, 'say' needs no model load)" ;;
    VOICE_TTS_DEFAULT_VOICE)     echo "macOS voice name passed to 'say' when a request omits 'voice' (default 'Katya (Enhanced)' — Russian, chosen 2026-07 in an A/B listening test). Also used as the Wyoming/Home-Assistant TTS voice (avspeech.default_voice in speech-server.yaml). NOT installed on a fresh macOS and has no headless install path — see CLAUDE.md/INTEGRATIONS.md for the one-time manual System Settings > Accessibility > VoiceOver > Open VoiceOver Utility > Speech > Voices step. Falls back to whatever 'say -v <name>' recognizes; already-installed voices (e.g. plain 'Milena') work with zero setup" ;;
    VOICE_WYOMING_PUBLIC_PORT)   echo "Public port for Home Assistant's native Wyoming-protocol voice integration (default 10300, the Wyoming ecosystem convention) — one port carries BOTH STT and TTS, auto-discovered by HA. Shares the SAME backend as 'stt' (com.local.voicestt.serve), just a second proxy in front of it" ;;
    VOICE_WYOMING_BACKEND_PORT)  echo "Internal Wyoming port the speech-server binary binds (127.0.0.1 only, default 15008)" ;;
    IDLE_TIMEOUT_IMMICH)         echo "Seconds before immich-ml backend is put to sleep" ;;
    IMMICH_REPO)                 echo "Git URL of the Metal/ANE Immich-ML backend cloned+built into IMMICH_PROJECT_DIR (default the maintained upstream sebastianfredette/immich-ml-metal; point at your own fork to carry local patches). Hybrid accel: CLIP on the GPU (MLX), face-detect+OCR on the ANE (Apple Vision), face-recog via ONNX/CoreML. Needs Python 3.11 + macOS 26" ;;
    IMMICH_REPO_REF)             echo "Branch/tag of IMMICH_REPO to check out (default main)" ;;
    IMMICH_MLX_VERSION)          echo "MLX version pinned in the immich-ml venv (default 0.30.0). Upstream leaves mlx unpinned; MLX >=0.31 crashes CLIP inference with 'There is no Stream(cpu, 1) in current thread'. Enforced on every --apply. Bump only if upstream adapts to a newer MLX" ;;
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
      com.local.omlx.main)
        [ "${INSTALL_MLX:-1}" = 1 ] || continue ;;
      com.local.litellm.*)
        [ "${INSTALL_MLX:-1}" = 1 ] || continue ;;
      com.local.images.*)
        [ "${INSTALL_IMAGES:-0}" = 1 ] || continue ;;
      com.local.voicestt.*|com.local.voicetts.*|com.local.voicewyoming.*)
        [ "${INSTALL_VOICE:-0}" = 1 ] || continue ;;
      com.local.immich.*)  [ "${INSTALL_IMMICH:-0}"  = 1 ] || continue ;;
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
    com.local.omlx.main)         echo "$LOG_DIR/omlx-main.log" ;;
    com.local.litellm.proxy)     echo "$LOG_DIR/litellm.log" ;;
    com.local.images.proxy)      echo "$LOG_DIR/images-proxy.log" ;;
    com.local.images.serve)      echo "$LOG_DIR/images-serve.log" ;;
    com.local.voicestt.proxy)    echo "$LOG_DIR/voicestt-proxy.log" ;;
    com.local.voicestt.serve)    echo "$LOG_DIR/voicestt-serve.log" ;;
    com.local.voicetts.proxy)    echo "$LOG_DIR/voicetts-proxy.log" ;;
    com.local.voicetts.serve)    echo "$LOG_DIR/voicetts-serve.log" ;;
    com.local.voicewyoming.proxy) echo "$LOG_DIR/voicewyoming-proxy.log" ;;
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
  # launchctl print-disabled prints `"<label>" => disabled` / `=> enabled`
  # (NOT a `true`/`false` boolean — verified on-device).
  /bin/launchctl print-disabled system 2>/dev/null \
    | /usr/bin/grep -qE "\"$1\"[[:space:]]*=>[[:space:]]*disabled"
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
  # Optional for the TTS backend: only needed if a client requests a
  # response_format afconvert can't produce (mp3/opus/aac/flac) — wav/aiff
  # work with zero extra dependencies. say-tts-server.py degrades gracefully
  # (501 with a clear message) if this is missing.
  [ "${INSTALL_VOICE:-0}" = 1 ] && ensure_formula ffmpeg
  # immich-ml-metal's venv needs python@3.11 specifically (3.13 lacks required wheels).
  # This is separate from ensure_modern_python()'s python@3.12 (MLX/docling): the immich
  # backend is built by ensure_immich_project() against 3.11.
  [ "${INSTALL_IMMICH:-0}" = 1 ] && ensure_formula python@3.11
}

ensure_modern_python() {
  # The MLX stack (omlx, litellm) and docling-serve all need
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

ensure_immich_project() {
  # Clones + builds the Metal/ANE Immich-ML backend (default the maintained upstream
  # sebastianfredette/immich-ml-metal; IMMICH_REPO overridable to point at a fork).
  # Hybrid acceleration: CLIP on the GPU via MLX, face-detection + OCR on the Apple
  # Neural Engine via Apple Vision, face-recognition via ONNX/CoreML — so it mostly
  # rides the ANE and only bursts the GPU for CLIP (see CLAUDE.md). The SECOND
  # "clone an external git repo and build it" pattern in this repo (after
  # ensure_voice_project()), but pip/venv-based rather than swift: upstream requires
  # python@3.11 (3.13 lacks required wheels). The run contract matches the existing
  # wrapper/plist unchanged — `python -m src.main`, ML_HOST/ML_PORT, health GET /ping —
  # so nothing under wrappers/ or daemons/ needs to change.
  [ "${INSTALL_IMMICH:-0}" = 1 ] || return 0
  local dir="${IMMICH_PROJECT_DIR:-/Users/mac/projects/immich-ml-metal}"
  local repo="${IMMICH_REPO:-https://github.com/sebastianfredette/immich-ml-metal}"
  local ref="${IMMICH_REPO_REF:-main}"
  local changed=0

  if [ ! -d "$dir/.git" ]; then
    if [ ! -x /usr/bin/git ]; then
      warn "git not found; cannot clone immich-ml-metal"
      return 1
    fi
    log "cloning immich-ml-metal ($repo@$ref) -> $dir"
    /usr/bin/sudo -u "$TARGET_USER" -H /bin/mkdir -p "$(dirname "$dir")"
    if ! /usr/bin/sudo -u "$TARGET_USER" -H /usr/bin/git clone --depth 1 --branch "$ref" \
          "$repo" "$dir" >"$LOG_DIR/immich-clone.log" 2>&1; then
      warn "git clone of immich-ml-metal failed; see $LOG_DIR/immich-clone.log"
      return 1
    fi
    changed=1
  else
    local head_before; head_before=$(/usr/bin/sudo -u "$TARGET_USER" -H /usr/bin/git -C "$dir" rev-parse HEAD 2>/dev/null)
    /usr/bin/sudo -u "$TARGET_USER" -H /usr/bin/git -C "$dir" pull --ff-only \
      >"$LOG_DIR/immich-clone.log" 2>&1 \
      || warn "git pull for immich-ml-metal failed (continuing with existing checkout); see $LOG_DIR/immich-clone.log"
    [ "$head_before" != "$(/usr/bin/sudo -u "$TARGET_USER" -H /usr/bin/git -C "$dir" rev-parse HEAD 2>/dev/null)" ] && changed=1
  fi

  # Project-local .venv built with python@3.11 specifically (like docling-serve's own
  # .venv, NOT one of the $VENV_DIR MLX-stack venvs). ensure_formulas() installs
  # python@3.11 when INSTALL_IMMICH=1.
  if [ ! -x /opt/homebrew/bin/python3.11 ]; then
    warn "immich-ml needs python@3.11, which is not installed yet."
    warn "Re-run 'sudo bash setup.sh --apply' after Homebrew is available."
    return 1
  fi
  local req="$dir/requirements.txt"
  if [ ! -f "$req" ]; then
    warn "immich-ml checkout has no requirements.txt at $req — unexpected repo layout for '$repo'"
    return 1
  fi
  local req_stamp="$dir/.venv/.requirements.sha256"
  local req_hash; req_hash=$(hash_file "$req")
  if [ ! -x "$dir/.venv/bin/python" ]; then
    log "building immich-ml venv at $dir/.venv (python@3.11; MLX + onnxruntime + insightface + open-clip — several minutes)"
    /usr/bin/sudo -u "$TARGET_USER" -H /opt/homebrew/bin/python3.11 -m venv "$dir/.venv"
    changed=1
  fi
  # Reinstall only when requirements.txt changed (fresh build, or a pull touched deps).
  if [ "$req_hash" != "$(/bin/cat "$req_stamp" 2>/dev/null)" ]; then
    /usr/bin/sudo -u "$TARGET_USER" -H "$dir/.venv/bin/pip" install --upgrade pip wheel >/dev/null 2>&1 \
      || warn "pip upgrade inside immich-ml venv returned non-zero"
    log "pip install -r requirements.txt (immich-ml) — downloads MLX/onnxruntime/insightface wheels"
    if ! /usr/bin/sudo -u "$TARGET_USER" -H "$dir/.venv/bin/pip" install -r "$req" \
          >"$LOG_DIR/immich-venv-install.log" 2>&1; then
      warn "immich-ml pip install failed; see $LOG_DIR/immich-venv-install.log"
      return 1
    fi
    /usr/bin/sudo -u "$TARGET_USER" -H /bin/sh -c "printf '%s' '$req_hash' > '$req_stamp'"
    changed=1
  fi

  # Pin MLX. Upstream's requirements.txt leaves it unpinned (`mlx>=0.22.0`, comment
  # says "current stable 0.30.x"), so a fresh install pulls the latest — and MLX >=0.31
  # crashes CLIP inference in the pool threads with
  #   libc++abi: std::runtime_error: There is no Stream(cpu, 1) in current thread
  # (the per-thread stream init in src/main.py:_init_ml_thread only warms the GPU
  # stream, not the CPU one newer MLX now demands). 0.30.0 is verified working (text +
  # 6-face detect + CoreML recog, 2026-07-12). Enforced on every apply so a re-clone or
  # a `pip install -r` can't silently reintroduce the crash. Bump IMMICH_MLX_VERSION if
  # upstream adapts to a newer MLX.
  local want_mlx="${IMMICH_MLX_VERSION:-0.30.0}"
  local have_mlx; have_mlx=$(/usr/bin/sudo -u "$TARGET_USER" -H "$dir/.venv/bin/python" -c 'import mlx.core as mx; print(mx.__version__)' 2>/dev/null)
  if [ -n "$want_mlx" ] && [ "$have_mlx" != "$want_mlx" ]; then
    log "pinning mlx ${have_mlx:-none} -> $want_mlx (upstream leaves it unpinned; >=0.31 crashes CLIP pool threads — see comment)"
    if /usr/bin/sudo -u "$TARGET_USER" -H "$dir/.venv/bin/pip" install "mlx==$want_mlx" >>"$LOG_DIR/immich-venv-install.log" 2>&1; then
      ok "mlx pinned to $want_mlx"
      changed=1
    else
      warn "mlx pin to $want_mlx failed; see $LOG_DIR/immich-venv-install.log"
    fi
  fi

  if [ -x "$dir/.venv/bin/python" ]; then
    ok "immich-ml project ready at $dir (first CLIP request does a one-time model download+convert to MLX, ~1-2 GB into ~/.cache/immich-ml-metal)"
  else
    warn "immich-ml venv build reported success but $dir/.venv/bin/python is missing"
    return 1
  fi

  # Only refresh a LIVE backend (an idle on-demand backend picks up the new checkout on
  # its next wake, since the wrapper re-execs from disk). Same "config changed -> kick"
  # idea ensure_voice_project() uses, but guarded on daemon_running so we don't wake an
  # idle backend just to have the proxy idle-stop it again.
  if [ "$changed" = 1 ] && daemon_running com.local.immich.ml; then
    /bin/launchctl kickstart -k system/com.local.immich.ml >/dev/null 2>&1 \
      && ok "restarted com.local.immich.ml to pick up the updated checkout/venv"
  fi
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

# ensure_omlx_model_dir — build/refresh the --model-dir symlink farm. EVERY
# omlx-engine catalog row that's fully downloaded gets a mlx-<id> entry —
# including gemma4 rows that would auto-discover fine via HF-cache scanning
# alone — so served-name is ALWAYS "mlx-<catalog-id>", independent of
# model_discovery.py's _is_hf_cache_mlx_compatible() heuristic (alpha-stage;
# this is exactly the heuristic that silently skipped raw BAAI/* checkpoints
# in the sandboxed eval). Symlinking ALL downloaded rows (not just the
# currently active ALIAS_MAIN/EMBED/RERANK) is what lets set_model_alias
# switch embed/rerank to an already-downloaded model WITHOUT restarting.
ensure_omlx_model_dir() {
  [ "${INSTALL_MLX:-1}" = 1 ] || return 0
  local root="${OMLX_MODEL_DIR:-$TARGET_HOME/.cache/omlx-models}"
  local hf="${HF_CACHE_DIR:-$TARGET_HOME/.cache/huggingface}"
  /usr/bin/sudo -u "$TARGET_USER" -H /bin/mkdir -p "$root"
  [ -f "$CATALOG_FILE" ] || return 0
  local id repo role engine rest any=0
  while IFS='|' read -r id repo role engine rest; do
    case "$id" in ''|\#*) continue ;; esac
    [ "$engine" = omlx ] || continue
    [ "$(model_status "$repo")" = ok ] || continue
    _omlx_symlink_one "$id" "$repo" "$root" "$hf" && any=1
  done <"$CATALOG_FILE"
  [ "$any" = 1 ] || dbg "no downloaded omlx-engine catalog rows yet"
}

# _omlx_symlink_one <catalog-id> <hf-repo> <model-dir-root> <hf-cache-dir>
# Wipes and rebuilds ONE mlx-<id> dir from the UNION of every snapshot
# directory under the repo's HF-cache entry — not just what refs/main points
# at — because a repo's cache CAN be split across snapshots (observed for
# BAAI/bge-m3 in the sandboxed eval: one snapshot had config.json+tokenizer
# files, a DIFFERENT one had only model.safetensors). Wipe+recreate (not
# incremental) so an edited `repo` column never leaves stale symlinks behind.
_omlx_symlink_one() {
  local id=$1 repo=$2 root=$3 hf=$4
  local snaproot="$hf/hub/models--${repo//\//--}/snapshots"
  [ -d "$snaproot" ] || return 1
  local target="$root/mlx-$id"
  /usr/bin/sudo -u "$TARGET_USER" -H /bin/rm -rf "$target"
  /usr/bin/sudo -u "$TARGET_USER" -H /bin/mkdir -p "$target"
  local snap f base n
  for snap in "$snaproot"/*/; do
    [ -d "$snap" ] || continue
    for f in "$snap"*; do
      [ -e "$f" ] || continue
      base=$(basename "$f")
      [ -e "$target/$base" ] || /usr/bin/sudo -u "$TARGET_USER" -H /bin/ln -s "$f" "$target/$base"
    done
  done
  n=$(/usr/bin/find "$target" -type l 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ')
  ok "omlx model-dir: mlx-$id -> $repo ($n files)"
}

# ensure_omlx_settings — pre-seed OMLX_MAX_CONTEXT_WINDOW for the ACTIVE main
# model into oMLX's per-model settings file (~/.omlx/settings.json — NOT a
# CLI flag; oMLX has no --max-kv-size equivalent, only --memory-guard-gb
# [soft RAM ceiling] + this per-model cap). Targeted merge of one key, never
# a wholesale clobber, since oMLX itself may write other keys to this file
# at runtime.
ensure_omlx_settings() {
  [ "${INSTALL_MLX:-1}" = 1 ] || return 0
  [ -n "${OMLX_MAX_CONTEXT_WINDOW:-}" ] || return 0
  local id="${ALIAS_MAIN:-}"
  [ -n "$id" ] || return 0
  local served="mlx-$id"
  local dir="${TARGET_HOME:-/Users/mac}/.omlx"
  local file="$dir/settings.json"
  /usr/bin/sudo -u "$TARGET_USER" -H /bin/mkdir -p "$dir"
  local before; before=$(hash_file "$file")
  local tmp; tmp=$(/usr/bin/mktemp)
  /usr/bin/sudo -u "$TARGET_USER" -H /usr/bin/env \
    OMLX_SETTINGS_FILE="$file" OMLX_MODEL_KEY="$served" OMLX_CTX="$OMLX_MAX_CONTEXT_WINDOW" \
    /usr/bin/python3 - >"$tmp" <<'PY'
import json, os
path, key, ctx = os.environ["OMLX_SETTINGS_FILE"], os.environ["OMLX_MODEL_KEY"], int(os.environ["OMLX_CTX"])
try:
    with open(path) as f: data = json.load(f)
except (OSError, ValueError):
    data = {}
data.setdefault(key, {})
data[key]["max_context_window"] = ctx
print(json.dumps(data, indent=2))
PY
  if [ "$before" != "$(hash_file "$tmp")" ]; then
    /bin/mv -f "$tmp" "$file"
    /bin/chmod 644 "$file"
    /usr/sbin/chown "$TARGET_USER" "$file" 2>/dev/null || true
    ok "omlx settings: $served max_context_window=$OMLX_MAX_CONTEXT_WINDOW -> $file"
    if daemon_running com.local.omlx.main; then
      /bin/launchctl kickstart -k system/com.local.omlx.main >/dev/null 2>&1 \
        && ok "restarted com.local.omlx.main to apply the new context window"
    fi
  else
    /bin/rm -f "$tmp"
    dbg "omlx settings up to date"
  fi
}

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

ensure_omlx_project() {
  # Clones + builds oMLX (github.com/jundot/omlx) — replaces mlx-vlm (main) AND
  # Infinity (embed/rerank) with ONE process. Alpha-stage, not on PyPI:
  # installed from source via `pip install -e .`. Git checkout lives at
  # OMLX_PROJECT_DIR (~/projects/omlx — same convention as
  # ensure_immich_project/ensure_voice_project); the venv it installs INTO is
  # the SHARED $VENV_DIR/omlx (matches mlxvlm/litellm/infinity/mflux — every
  # wrapper execs "$VENV_DIR/<name>/bin/...", zero special-casing needed).
  #
  # OMLX_REPO_REF is a PINNED TAG (v0.5.1), not a floating branch — mirrors
  # MLXVLM_VERSION's old pin discipline. Unlike ensure_immich_project's
  # `git pull --ff-only` (tracks a moving branch), we `fetch` + explicit
  # `checkout "$ref"` every run — a no-op when already on that tag.
  [ "${INSTALL_MLX:-1}" = 1 ] || return 0
  local dir="${OMLX_PROJECT_DIR:-$TARGET_HOME/projects/omlx}"
  local repo="${OMLX_REPO:-https://github.com/jundot/omlx}"
  local ref="${OMLX_REPO_REF:-v0.5.1}"
  local vdir="${VENV_DIR:-/Users/mac/.macstudio-venvs}/omlx"
  local changed=0

  if [ ! -x /opt/homebrew/bin/python3.12 ]; then
    warn "oMLX needs python@3.12, which is not installed yet."
    warn "Re-run 'sudo bash setup.sh --apply' after Homebrew is available."
    return 1
  fi

  if [ ! -d "$dir/.git" ]; then
    if [ ! -x /usr/bin/git ]; then
      warn "git not found; cannot clone omlx"
      return 1
    fi
    log "cloning oMLX ($repo@$ref) -> $dir"
    /usr/bin/sudo -u "$TARGET_USER" -H /bin/mkdir -p "$(dirname "$dir")"
    if ! /usr/bin/sudo -u "$TARGET_USER" -H /usr/bin/git clone --branch "$ref" \
          "$repo" "$dir" >"$LOG_DIR/omlx-clone.log" 2>&1; then
      warn "git clone of omlx failed; see $LOG_DIR/omlx-clone.log"
      return 1
    fi
    changed=1
  else
    local head_before; head_before=$(/usr/bin/sudo -u "$TARGET_USER" -H /usr/bin/git -C "$dir" rev-parse HEAD 2>/dev/null)
    /usr/bin/sudo -u "$TARGET_USER" -H /usr/bin/git -C "$dir" fetch --tags origin "$ref" \
      >"$LOG_DIR/omlx-clone.log" 2>&1 \
      || warn "git fetch for omlx failed (continuing with existing checkout); see $LOG_DIR/omlx-clone.log"
    /usr/bin/sudo -u "$TARGET_USER" -H /usr/bin/git -C "$dir" checkout "$ref" \
      >>"$LOG_DIR/omlx-clone.log" 2>&1 \
      || warn "git checkout $ref for omlx failed; see $LOG_DIR/omlx-clone.log"
    [ "$head_before" != "$(/usr/bin/sudo -u "$TARGET_USER" -H /usr/bin/git -C "$dir" rev-parse HEAD 2>/dev/null)" ] && changed=1
  fi

  local pyproject="$dir/pyproject.toml"
  if [ ! -f "$pyproject" ]; then
    warn "omlx checkout has no pyproject.toml at $pyproject — unexpected repo layout"
    return 1
  fi
  local stamp="$vdir/.pyproject.sha256"
  local want_hash; want_hash=$(hash_file "$pyproject")
  if [ ! -x "$vdir/bin/python" ]; then
    log "building omlx venv at $vdir (python@3.12)"
    /usr/bin/sudo -u "$TARGET_USER" -H /bin/mkdir -p "$(dirname "$vdir")"
    /usr/bin/sudo -u "$TARGET_USER" -H /opt/homebrew/bin/python3.12 -m venv "$vdir"
    changed=1
  fi
  if [ "$want_hash" != "$(/bin/cat "$stamp" 2>/dev/null)" ]; then
    /usr/bin/sudo -u "$TARGET_USER" -H "$vdir/bin/pip" install --upgrade pip wheel >/dev/null 2>&1 \
      || warn "pip upgrade inside omlx venv returned non-zero"
    log "pip install -e '$dir' (omlx, editable — resolves pinned mlx/mlx-lm/mlx-vlm/mlx-embeddings commits from pyproject.toml; several minutes)"
    if ! /usr/bin/sudo -u "$TARGET_USER" -H "$vdir/bin/pip" install -e "$dir" \
          >"$LOG_DIR/omlx-venv-install.log" 2>&1; then
      warn "omlx pip install failed; see $LOG_DIR/omlx-venv-install.log"
      return 1
    fi
    /usr/bin/sudo -u "$TARGET_USER" -H /bin/sh -c "printf '%s' '$want_hash' > '$stamp'"
    changed=1
  fi

  if [ -x "$vdir/bin/omlx" ]; then
    ok "omlx venv ready at $vdir (pinned $ref)"
  else
    warn "omlx pip install succeeded but $vdir/bin/omlx is missing — check the console-script name (pyproject.toml [project.scripts]) hasn't changed upstream"
    return 1
  fi

  if [ "$changed" = 1 ] && daemon_running com.local.omlx.main; then
    /bin/launchctl kickstart -k system/com.local.omlx.main >/dev/null 2>&1 \
      && ok "restarted com.local.omlx.main to pick up the updated checkout/venv"
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

  # litellm floats (no engine pin needed — it's the gateway, not the engine).
  # The text/embed/rerank engine is oMLX (venv 'omlx', cloned+editable-installed
  # by ensure_omlx_project() below — alpha-stage/not-on-PyPI, so it needs its
  # own git-clone flow, not this generic pip-spec helper).
  _ensure_venv litellm bin:litellm       'litellm[proxy]'

  # FLUX image generation: mflux (MLX-native, no PyTorch/ComfyUI) + flask for the
  # thin OpenAI-compatible front end in mflux-server.py. On-demand, catalog-
  # independent (see CLAUDE.md) — only built when INSTALL_IMAGES=1.
  if [ "${INSTALL_IMAGES:-0}" = 1 ]; then
    _ensure_venv mflux bin:mflux-generate 'mflux' 'flask' 'huggingface_hub[cli]'
  fi
}

ensure_mflux_model() {
  # Proactively runs mflux-save once so the FIRST real image request is normal
  # speed (model load + generate), not a one-shot conversion+generate that can
  # take 15+ minutes and blow past client timeouts. Idempotent — skips if the
  # target directory already exists. Catalog-independent by design (see
  # CLAUDE.md: image generation doesn't fit the text/embed/rerank role system).
  [ "${INSTALL_IMAGES:-0}" = 1 ] || return 0
  local vdir="${VENV_DIR:-/Users/mac/.macstudio-venvs}"
  if [ ! -x "$vdir/mflux/bin/mflux-save" ]; then
    warn "mflux venv missing — ensure_python_venvs should have built it; check $LOG_DIR/mflux-venv-install.log"
    return 1
  fi
  local model="${MFLUX_MODEL:-dev}" quant="${MFLUX_QUANTIZE:-8}"
  local model_dir="${MFLUX_MODEL_DIR:-/Users/mac/.cache/mflux-models}"
  local target="$model_dir/${model}-q${quant}"
  if [ -d "$target" ]; then
    ok "mflux model present ($target)"
    return 0
  fi
  /usr/bin/sudo -u "$TARGET_USER" -H /bin/mkdir -p "$model_dir"
  log "quantizing FLUX.1-$model to ${quant}-bit -> $target (one-time: downloads the full checkpoint + quantizes, several minutes)"
  local logf="$LOG_DIR/mflux-save.log"
  if /usr/bin/sudo -u "$TARGET_USER" -H /usr/bin/env HF_HOME="${HF_CACHE_DIR:-$TARGET_HOME/.cache/huggingface}" \
        "$vdir/mflux/bin/mflux-save" --model "$model" --path "$target" --quantize "$quant" \
        >"$logf" 2>&1; then
    ok "mflux model saved -> $target"
  else
    warn "mflux-save failed for model='$model' quantize='$quant'; see $logf"
    if /usr/bin/grep -qiE '401|403|gated|gating|awaiting|access to|authenticated|restricted' "$logf" 2>/dev/null; then
      warn "  FLUX.1-dev is gated: accept the licence at https://huggingface.co/black-forest-labs/FLUX.1-dev"
      warn "  then log in as $TARGET_USER via 'hf auth login --token' (or use MFLUX_MODEL=schnell, ungated)"
    fi
    return 1
  fi
}

ensure_voice_project() {
  # Clones+builds FluidAudio's macos-speech-server (Swift) for Speech-to-Text
  # (Parakeet, Apple Neural Engine — measured zero GPU contention with the
  # resident main LLM, see CLAUDE.md). First "clone an external git repo and
  # build it" pattern in this repo — immich-ml/docling-serve are pip-based or
  # user-provided, not a fresh git clone, so there's no prior helper to reuse.
  # Only STT is served from here: TTS goes through wrappers/start-voicetts.sh
  # (plain `say`) instead of this project's bundled avspeech TTS engine — see
  # that wrapper's comment for why (faster, and avoids a real sentence-
  # boundary silence-dropping bug).
  [ "${INSTALL_VOICE:-0}" = 1 ] || return 0
  local dir="${VOICE_PROJECT_DIR:-/Users/mac/projects/macos-speech-server}"
  local port="${VOICESTT_BACKEND_PORT:-15006}"
  local wport="${VOICE_WYOMING_BACKEND_PORT:-15008}"

  if [ ! -d "$dir/.git" ]; then
    if [ ! -x /usr/bin/git ]; then
      warn "git not found; cannot clone macos-speech-server"
      return 1
    fi
    log "cloning macos-speech-server -> $dir"
    /usr/bin/sudo -u "$TARGET_USER" -H /bin/mkdir -p "$(dirname "$dir")"
    if ! /usr/bin/sudo -u "$TARGET_USER" -H /usr/bin/git clone --depth 1 \
          https://github.com/dokterbob/macos-speech-server "$dir" \
          >"$LOG_DIR/voicestt-clone.log" 2>&1; then
      warn "git clone of macos-speech-server failed; see $LOG_DIR/voicestt-clone.log"
      return 1
    fi
  else
    /usr/bin/sudo -u "$TARGET_USER" -H /usr/bin/git -C "$dir" pull --ff-only \
      >"$LOG_DIR/voicestt-clone.log" 2>&1 \
      || warn "git pull for macos-speech-server failed (continuing with existing checkout); see $LOG_DIR/voicestt-clone.log"
  fi

  # Local patch: upstream hardcodes "en" as the ONLY language it ever
  # advertises over Wyoming, for both Parakeet's ASR model (actually
  # multilingual, 25 languages incl. Russian) and every AVSpeechSynthesizer
  # TTS voice (regardless of the voice's real locale — Katya/Milena/Yuri are
  # ru_RU, but got reported as "en"). This makes Home Assistant's pipeline
  # language picker only ever offer English, even though transcription/
  # synthesis themselves already work fine in Russian via the plain HTTP
  # 'stt'/'tts' aliases. Reset to a clean upstream tree first so re-applying
  # is idempotent across repeated --apply runs (a raw `git apply` on an
  # already-patched tree would fail).
  /usr/bin/sudo -u "$TARGET_USER" -H /usr/bin/git -C "$dir" checkout -- . >/dev/null 2>&1 || true
  local patch_file="$REPO_DIR/patches/macos-speech-server-wyoming-languages.patch"
  if [ -f "$patch_file" ]; then
    if /usr/bin/sudo -u "$TARGET_USER" -H /usr/bin/git -C "$dir" apply "$patch_file" \
          >"$LOG_DIR/voicestt-patch.log" 2>&1; then
      ok "applied macos-speech-server Wyoming-language patch"
    else
      warn "failed to apply macos-speech-server Wyoming-language patch; see $LOG_DIR/voicestt-patch.log (continuing with unpatched upstream — HA's pipeline language picker will only offer English)"
    fi
  fi

  # Two independent consumers share this ONE backend process now:
  # - LiteLLM's 'stt' alias (OpenWebUI etc.) via the HTTP port ($port),
  #   fronted by com.local.voicestt.proxy.
  # - Home Assistant's native Wyoming integration via the Wyoming port
  #   ($wport), fronted by the SEPARATE com.local.voicewyoming.proxy (same
  #   BACKEND_LABEL=com.local.voicestt.serve — one Wyoming TCP port carries
  #   BOTH STT and TTS for HA, auto-discovered; see INTEGRATIONS.md).
  # The 'tts' stanza's avspeech engine is what HA's Wyoming TTS actually
  # uses (unlike LiteLLM's 'tts' alias, which bypasses it — see
  # wrappers/start-voicetts.sh) — pointed at the same VOICE_TTS_DEFAULT_VOICE
  # for consistency. Its sentence-concatenation silence-dropping bug (see
  # CLAUDE.md) only matters for multi-sentence input; HA voice-assistant
  # replies are typically one short sentence, so it's a non-issue here.
  local yaml_before; yaml_before=$(hash_file "$dir/speech-server.yaml")
  cat >"$dir/speech-server.yaml" <<YAML
log_level: notice
servers:
  http:
    host: 127.0.0.1
    port: $port
  wyoming:
    host: 127.0.0.1
    port: $wport
stt:
  engine: parakeet
  parakeet:
    model_version: v3
tts:
  engine: avspeech
  avspeech:
    default_voice: ${VOICE_TTS_DEFAULT_VOICE:-Katya (Enhanced)}
YAML
  /bin/chmod 644 "$dir/speech-server.yaml"

  # The binary only reads speech-server.yaml at startup — an already-running
  # instance won't notice a port/voice change until kickstarted (found the
  # hard way: added the Wyoming port here, but a live voicestt.serve kept
  # listening with the OLD config, silently 0-porting Wyoming, until
  # restarted). Same "config changed -> kickstart" pattern render_litellm_
  # config() already uses.
  if [ "$yaml_before" != "$(hash_file "$dir/speech-server.yaml")" ] && daemon_loaded com.local.voicestt.serve; then
    /bin/launchctl kickstart -k system/com.local.voicestt.serve >/dev/null 2>&1 \
      && ok "restarted com.local.voicestt.serve to pick up the updated speech-server.yaml"
  fi

  if [ ! -x /usr/bin/swift ]; then
    warn "Swift toolchain not found — install Xcode Command Line Tools: xcode-select --install"
    return 1
  fi
  # Always invoke swift build rather than skipping when a binary already
  # exists — Swift Package Manager's build is incremental (a no-op re-run
  # takes seconds), and skipping unconditionally would silently leave a
  # stale binary in place after a git pull or a patch-file change to the
  # source (found the hard way while developing the language patch above).
  local bin_before; bin_before=$(hash_file "$dir/.build/release/speech-server")
  log "building macos-speech-server (swift build -c release; incremental after the first run)"
  if /usr/bin/sudo -u "$TARGET_USER" -H /bin/sh -c "cd '$dir' && swift build -c release" \
        >"$LOG_DIR/voicestt-build.log" 2>&1; then
    ok "macos-speech-server built -> $dir/.build/release/speech-server"
  else
    warn "swift build failed for macos-speech-server; see $LOG_DIR/voicestt-build.log"
    return 1
  fi
  # Same reasoning as the yaml restart above: a running instance keeps the
  # OLD binary loaded in memory until kickstarted, even though the file on
  # disk is already the new one.
  if [ "$bin_before" != "$(hash_file "$dir/.build/release/speech-server")" ] && daemon_loaded com.local.voicestt.serve; then
    /bin/launchctl kickstart -k system/com.local.voicestt.serve >/dev/null 2>&1 \
      && ok "restarted com.local.voicestt.serve to run the newly built binary"
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
# assignments. Roles: `main` (the ONE loaded oMLX text+images model) and the
# embed/rerank aliases — served by the SAME resident oMLX process. Only
# rewrites + reloads on a real change.
render_litellm_config() {
  [ "${INSTALL_MLX:-1}" = 1 ] || return 0
  local main_repo embed_repo rerank_repo tmp
  main_repo=$(catalog_repo "${ALIAS_MAIN:-}")
  if [ -z "$main_repo" ]; then
    warn "ALIAS_MAIN='${ALIAS_MAIN:-}' has no catalog repo — LiteLLM config not (re)written"
    warn "(download a model and set it as main via 'llm-models')"
    return 0
  fi
  # Every model — main AND embed/rerank — is served by the SAME resident omlx
  # process now, discoverable via its uniform mlx-<catalog-id> --model-dir
  # entry (ensure_omlx_model_dir()). Served names are a deterministic function
  # of the catalog id, not a transform of the HF repo string.
  local main_served="mlx-${ALIAS_MAIN}"
  embed_repo=$(catalog_repo "${ALIAS_EMBED:-}")
  rerank_repo=$(catalog_repo "${ALIAS_RERANK:-}")
  local embed_served="" rerank_served=""
  [ -n "$embed_repo" ]  && embed_served="mlx-${ALIAS_EMBED}"
  [ -n "$rerank_repo" ] && rerank_served="mlx-${ALIAS_RERANK}"

  # Per-model DEFAULT sampling (schema v7, cols 14-17) for the active main model.
  # We inject per-model default sampling into the LiteLLM alias; clients can
  # still override per request (drop_params drops anything the backend rejects).
  # Empty cell = omit (LiteLLM/backend default).
  local m_temp m_topp m_freq m_pres
  m_temp=$(catalog_field "${ALIAS_MAIN:-}" 14)
  m_topp=$(catalog_field "${ALIAS_MAIN:-}" 15)
  m_freq=$(catalog_field "${ALIAS_MAIN:-}" 16)
  m_pres=$(catalog_field "${ALIAS_MAIN:-}" 17)

  # emit_model <alias> <served-name> <port> [temp] [top_p] [freq_pen] [pres_pen] [max_tok] [nothink] [top_k]
  # One LiteLLM model_list entry; optional sampling lines only when non-empty.
  # extra_body carries up to two things, merged into ONE object:
  #   nothink (arg 9) non-empty -> suppress the model's reasoning at the proxy (so clients
  #     like OpenWebUI never see a thinking block, and short-output tasks like paperless
  #     extraction aren't eaten by hidden think tokens). oMLX's wire form is the NESTED
  #     `chat_template_kwargs.enable_thinking` (confirmed via source read of omlx/server.py
  #     AND live-tested) — unlike mlx_vlm.server's old top-level `enable_thinking` key.
  #   top_k (arg 10) non-empty -> Gemma's reference sampling. top_k is NOT a native OpenAI
  #     param, so it MUST ride in extra_body (catalog has no top_k column). At temperature 0
  #     it is inert, so we don't bother passing it to deterministic aliases.
  # LiteLLM forwards extra_body verbatim (drop_params leaves it untouched).
  local _nothink_body='{"chat_template_kwargs": {"enable_thinking": false}}'
  emit_model() {
    printf '  - model_name: %s\n    litellm_params:\n      model: openai/%s\n      api_base: http://127.0.0.1:%s/v1\n      api_key: dummy\n' "$1" "$2" "$3"
    [ -n "${4:-}" ] && printf '      temperature: %s\n' "$4"
    [ -n "${5:-}" ] && printf '      top_p: %s\n' "$5"
    [ -n "${6:-}" ] && printf '      frequency_penalty: %s\n' "$6"
    [ -n "${7:-}" ] && printf '      presence_penalty: %s\n' "$7"
    [ -n "${8:-}" ] && printf '      max_tokens: %s\n' "$8"
    local _eb=""
    if [ -n "${9:-}" ] && [ -n "${10:-}" ]; then
      _eb=$(printf '{"chat_template_kwargs": {"enable_thinking": false}, "top_k": %s}' "${10}")
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
    emit_model main "$main_served" "${MAIN_BACKEND_PORT:-18000}" "$m_temp" "$m_topp" "$m_freq" "$m_pres" "" "" "${GEMMA_TOP_K:-64}"
    # main-fast = SAME loaded gemma model as 'main' (shares :18000 -> only ONE resident),
    # exactly 'main' sampling but thinking OFF at the proxy
    # (fast, non-reasoning chat / tools / web / cron / email). (main-metadata was retired.)
    if [ "${PRESET_ALIASES:-1}" = 1 ]; then
      emit_model main-fast "$main_served" "${MAIN_BACKEND_PORT:-18000}" "$m_temp" "$m_topp" "$m_freq" "$m_pres" "" 1 "${GEMMA_TOP_K:-64}"
    fi
    # Embeddings + reranking now served by the SAME resident omlx process as
    # main (mlx-<id> served-name, MAIN_BACKEND_PORT). 'embed' uses the generic
    # 'openai/<served-name>' provider — the SAME mechanism 'main'/'image' use —
    # confirmed working (verified live 2026-07-13: 1024-dim vectors from
    # /v1/embeddings). 'rerank' CANNOT use a bare 'openai/' provider — LiteLLM's
    # rerank_api/main.py has no OpenAI branch and raises "Unsupported provider:
    # openai" (confirmed live 2026-07-13). It uses the 'infinity/<served-name>'
    # provider instead: despite the name, LiteLLM's InfinityRerankConfig is
    # just a generic Cohere/Jina-shaped /rerank client (posts to
    # "<api_base>/rerank"), and oMLX's own /v1/rerank route is explicitly
    # documented as "Cohere/Jina-compatible" — so pointing the infinity
    # provider's api_base at the SAME :18000/v1 (oMLX's port, not a separate
    # Infinity daemon) works. Emitted only when the catalog id resolves
    # (download first).
    if [ -n "$embed_served" ]; then
      printf '  - model_name: embed\n    litellm_params:\n      model: openai/%s\n      api_base: http://127.0.0.1:%s/v1\n      api_key: dummy\n    model_info:\n      mode: embedding\n' \
        "$embed_served" "${MAIN_BACKEND_PORT:-18000}"
    fi
    if [ -n "$rerank_served" ]; then
      # return_documents: false — oMLX's own default is true, always nesting
      # document as {"text": ...} (real Cohere shape). LiteLLM's Infinity
      # transformer instead expects document to be a bare string (Infinity's
      # own historical shape) and crashes on the nested form. litellm_params
      # keys are spread directly into litellm.arerank(), so this static
      # false suppresses the field on the oMLX side entirely — sidesteps the
      # mismatch rather than fighting it. Confirmed live 2026-07-13.
      printf '  - model_name: rerank\n    litellm_params:\n      model: infinity/%s\n      api_base: http://127.0.0.1:%s/v1\n      api_key: dummy\n      return_documents: false\n    model_info:\n      mode: rerank\n' \
        "$rerank_served" "${MAIN_BACKEND_PORT:-18000}"
    fi
    # FLUX image generation via the on-demand mflux backend (mflux-server.py).
    # Uses the SAME generic 'openai/<served-name>' provider every other alias
    # uses — mflux-server.py speaks OpenAI's /v1/images/generations shape
    # directly, so LiteLLM just forwards. Gated purely on INSTALL_IMAGES, not
    # a catalog id: image generation is deliberately NOT a 4th catalog role
    # (see CLAUDE.md).
    if [ "${INSTALL_IMAGES:-0}" = 1 ]; then
      printf '  - model_name: image\n    litellm_params:\n      model: openai/mflux-%s\n      api_base: http://127.0.0.1:%s/v1\n      api_key: dummy\n    model_info:\n      mode: image_generation\n' \
        "${MFLUX_MODEL:-dev}" "${IMAGES_PUBLIC_PORT:-5005}"
    fi
    # Speech-to-Text via the on-demand FluidAudio backend (macos-speech-server,
    # Parakeet engine, Apple Neural Engine — measured zero GPU contention with
    # the resident main LLM, unlike a GPU/MLX-based alternative that was tried
    # and rejected; see CLAUDE.md's "Voice" bullet). Same generic
    # 'openai/<served-name>' provider as 'image' — the backend speaks OpenAI's
    # /v1/audio/transcriptions shape directly and, unlike mflux-server.py,
    # doesn't actually look at the 'model' field (engine choice is fixed by
    # its own config, rendered by ensure_voice_project()).
    if [ "${INSTALL_VOICE:-0}" = 1 ]; then
      printf '  - model_name: stt\n    litellm_params:\n      model: openai/parakeet\n      api_base: http://127.0.0.1:%s/v1\n      api_key: dummy\n    model_info:\n      mode: audio_transcription\n' \
        "${VOICESTT_PUBLIC_PORT:-5006}"
    fi
    # Text-to-Speech via the on-demand say-tts-server.py backend (plain
    # `say`/AVSpeechSynthesizer, NOT macos-speech-server's bundled avspeech
    # engine — measured faster and bug-free, see wrappers/start-voicetts.sh).
    # NOTE: LiteLLM's own /v1/audio/speech routing REQUIRES a 'voice' key to be
    # PRESENT in the client's raw request body — Router.aspeech(voice: str, ...)
    # has no default, and `data` is parsed straight from the request with no
    # config-level merge before dispatch (verified against the installed
    # litellm source) — a totally MISSING 'voice' key 500s inside LiteLLM
    # itself, before ever reaching say-tts-server.py. A static litellm_params
    # default here does NOT help (tried, confirmed empirically ineffective for
    # this specific endpoint/failure mode). The client must always send a
    # 'voice' key — an EMPTY STRING is fine (say-tts-server.py falls back to
    # VOICE_TTS_DEFAULT_VOICE for that) — see INTEGRATIONS.md's Open WebUI
    # section, which documents setting AUDIO_TTS_VOICE explicitly rather than
    # leaving it unset.
    if [ "${INSTALL_VOICE:-0}" = 1 ]; then
      printf '  - model_name: tts\n    litellm_params:\n      model: openai/say\n      api_base: http://127.0.0.1:%s/v1\n      api_key: dummy\n    model_info:\n      mode: audio_speech\n' \
        "${VOICETTS_PUBLIC_PORT:-5007}"
    fi
    # No separate 'vision' alias: the unified 'main' already does images, so the chat set
    # is intentionally main / main-fast (plus the embed / rerank / image utility aliases above).
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
  ok "litellm config written → $LITELLM_CONFIG_FILE (main=${ALIAS_MAIN}, embed=${ALIAS_EMBED:-none}, rerank=${ALIAS_RERANK:-none}, image=$([ "${INSTALL_IMAGES:-0}" = 1 ] && echo "${MFLUX_MODEL:-dev}-q${MFLUX_QUANTIZE:-8}" || echo none), voice=$([ "${INSTALL_VOICE:-0}" = 1 ] && echo "stt+tts (${VOICE_TTS_DEFAULT_VOICE:-default})" || echo none))"
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
      com.local.omlx.main)
        # Text/embed/rerank engine: oMLX (unified text+vision+embed+rerank,
        # ONE resident process). The one always-on main.
        [ "${INSTALL_MLX:-1}" = 1 ] || { remove_plist "$label"; continue; } ;;
      com.local.litellm.*)
        [ "${INSTALL_MLX:-1}" = 1 ] || { remove_plist "$label"; continue; } ;;
      com.local.images.*)
        # On-demand FLUX image generation (mflux, MLX-native). Catalog-
        # independent (see CLAUDE.md) — fronted through LiteLLM's 'image' alias.
        [ "${INSTALL_IMAGES:-0}" = 1 ] || { remove_plist "$label"; continue; } ;;
      com.local.voicestt.*|com.local.voicetts.*|com.local.voicewyoming.*)
        # On-demand Speech-to-Text (FluidAudio/Parakeet, ANE) + Text-to-Speech
        # (plain `say`) — two separate backends fronted through LiteLLM's
        # 'stt'/'tts' aliases. Catalog-independent (see CLAUDE.md).
        # com.local.voicewyoming.proxy is a THIRD proxy in front of the SAME
        # voicestt.serve backend (no separate .serve daemon) — native Home
        # Assistant voice-pipeline integration (Wyoming protocol carries both
        # STT and TTS on one port).
        [ "${INSTALL_VOICE:-0}" = 1 ] || { remove_plist "$label"; continue; } ;;
      com.local.immich.*)  [ "${INSTALL_IMMICH:-0}"  = 1 ] || { remove_plist "$label"; continue; } ;;
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

retire_old_engine_daemons() {
  # ONE-TIME migration cleanup (oMLX cutover). com.local.mlxvlm.main /
  # infinity.serve / infinity.proxy were FULLY RETIRED — removed from
  # ALL_LABELS/ALWAYS_ON_LABELS/ONDEMAND_LABELS entirely, not just gated off —
  # so render_all_plists()'s normal "walk ALL_LABELS, remove if config says
  # off" loop never visits them again. Without this, they'd be orphaned:
  # still bootstrapped, still running, invisible to every menu/dashboard/
  # status view that only iterates the current label registry.
  local old_label old_wrapper
  for old_label in com.local.mlxvlm.main com.local.infinity.serve com.local.infinity.proxy; do
    if [ -f "$PLIST_DIR/$old_label.plist" ] || daemon_loaded "$old_label"; then
      bootout_plist "$old_label"
      /bin/rm -f "$PLIST_DIR/$old_label.plist"
      ok "retired old daemon: $old_label"
    fi
  done
  for old_wrapper in start-mlxvlm-main.sh start-infinity.sh start-infinity-proxy.sh; do
    if [ -f "$LIBEXEC_DIR/$old_wrapper" ]; then
      /bin/rm -f "$LIBEXEC_DIR/$old_wrapper"
      ok "removed retired wrapper: $LIBEXEC_DIR/$old_wrapper"
    fi
  done
  # Deliberately DO NOT touch $VENV_DIR/mlxvlm or $VENV_DIR/infinity, or any
  # HF-cached weights — matches menu_uninstall()'s existing precedent, and
  # keeps the git-revert rollback path cheap (no re-download/re-build needed).
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
  dbg "step: retire_old_engine_daemons"; retire_old_engine_daemons || true
  dbg "step: ensure_modern_python";    ensure_modern_python || true
  dbg "step: ensure_immich_project";   ensure_immich_project
  dbg "step: ensure_docling_venv";     ensure_docling_venv
  dbg "step: ensure_paperless_ocr_venv"; ensure_paperless_ocr_venv || true
  dbg "step: ensure_paperless_ocr_share"; ensure_paperless_ocr_share || true
  dbg "step: ensure_vnc_password";     ensure_vnc_password
  dbg "step: ensure_screensharing";    ensure_screensharing_enabled || true
  dbg "step: ensure_novnc_venv";       ensure_novnc_venv || true
  dbg "step: ensure_novnc_assets";     ensure_novnc_assets || true
  dbg "step: ensure_omlx_project";     ensure_omlx_project || true
  dbg "step: ensure_python_venvs";     ensure_python_venvs || true
  dbg "step: ensure_mflux_model";      ensure_mflux_model || true
  dbg "step: ensure_voice_project";    ensure_voice_project || true
  dbg "step: ensure_model_catalog";    ensure_model_catalog
  dbg "step: ensure_omlx_model_dir";   ensure_omlx_model_dir || true
  dbg "step: ensure_omlx_settings";    ensure_omlx_settings || true
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
          com.local.immich.ml|com.local.docling.serve)
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
    printf "%s\n" "The MLX stack (oMLX + LiteLLM gateway) is the primary backend."
    printf "%s\n" "The GPU-wired-limit helper, caffeinate and the weekly autoupdate are"
    printf "%s\n" "always installed. Re-running setup.sh never overwrites a healthy installed service."
    echo
    printf "  1) %-18s [%s]   MLX stack: oMLX :%s internal, LiteLLM :%s public\n" \
      INSTALL_MLX       "$(onoff_label "${INSTALL_MLX:-1}")" \
      "${MAIN_BACKEND_PORT:-18000}" "${LITELLM_PORT:-11434}"
    printf "  2) %-18s [%s]   immich-ml on-demand photo AI (:%s)\n" \
      INSTALL_IMMICH    "$(onoff_label "${INSTALL_IMMICH:-0}")"    "${ML_PUBLIC_PORT:-3003}"
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
  # Prefers the omlx venv's 'hf' (present if oMLX's own pyproject.toml pulls in
  # huggingface_hub[cli] — verify this once cloned; if not, this silently
  # falls through to litellm's, which already carries it as a dependency).
  local base="${VENV_DIR:-/Users/mac/.macstudio-venvs}"
  if [ -x "$base/omlx/bin/hf" ]; then echo "$base/omlx/bin/hf"
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
    if [ "$(catalog_engine "$id")" = omlx ]; then
      _omlx_symlink_one "$id" "$repo" "${OMLX_MODEL_DIR:-$TARGET_HOME/.cache/omlx-models}" "${HF_CACHE_DIR:-$TARGET_HOME/.cache/huggingface}" \
        && ok "omlx model-dir entry ready — no --apply needed before selecting it"
    fi
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
  # Roles: text -> 'main' (oMLX, unified text+images), embed -> 'embed' +
  # rerank -> 'rerank' (all three served by the SAME oMLX process).
  role=$(catalog_role "$id"); role=${role:-text}
  if [ "$role" != "$want_role" ]; then
    err "'$id' has role '$role' but slot '$slot' needs role '$want_role' — wrong list"
    return 1
  fi
  # Refuse models the catalog flags BROKEN for the engine that will actually run
  # this slot — selecting one just breaks the server. A bare legacy BROKEN always
  # blocks; an engine-tagged BROKEN[<engine>] blocks ONLY for that engine. Every
  # slot (main/embed/rerank) now runs on the one omlx engine.
  local _notes _broken=0 _check_engine="omlx"
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
    ensure_omlx_settings   # re-seed OMLX_MAX_CONTEXT_WINDOW under the NEW main's served-name first
    if daemon_loaded com.local.omlx.main; then
      /bin/launchctl kickstart -k system/com.local.omlx.main >/dev/null 2>&1 \
        && ok "restarting com.local.omlx.main with new main model (load ~30–60 s, no hot-swap — oMLX's multi-model hot-swap is a possible FUTURE follow-on, out of scope here)"
    fi
  elif [ "$slot" = embed ] || [ "$slot" = rerank ]; then
    # No restart needed in the common case: ensure_omlx_model_dir() (run during
    # --apply AND right after every successful download_model()) already made
    # every downloaded omlx-engine row discoverable, and render_litellm_config
    # above already repointed the alias at the new served-name on the SAME
    # running process. Defensive fallback (oMLX rescanning --model-dir for a
    # NEW entry without a restart is unverified): probe /v1/models and only
    # restart if the new served-name genuinely isn't listed yet.
    local _served="mlx-$id"
    if daemon_running com.local.omlx.main \
       && ! /usr/bin/curl -fsS "http://127.0.0.1:${MAIN_BACKEND_PORT:-18000}/v1/models" 2>/dev/null \
            | /usr/bin/grep -q "\"$_served\""; then
      warn "omlx.main doesn't list '$_served' yet — restarting to pick it up"
      /bin/launchctl kickstart -k system/com.local.omlx.main >/dev/null 2>&1 \
        && ok "restarted com.local.omlx.main"
    else
      ok "'$id' is already served by the running omlx.main — no restart needed"
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
  #   engine=  omlx                          (default: omlx — the only engine)
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
  [ -z "$engine" ] && engine=omlx
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
  # Only engine is omlx — main/embed/rerank all served by the same process.
  engine=omlx
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
  printf "  role/engine %s / %s%s\n" "${role:-text}" "${engine:-omlx}" \
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
    printf "${C_DIM}(ONE resident oMLX process serves main/embed/rerank together)${C_RST}\n\n"
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
# frozen on purpose; the user bumps it deliberately via OMLX_REPO_REF.
menu_updates() {
  load_config
  printf "\n${C_BOLD}── Check for updates (read-only) ──────────────${C_RST}\n"
  printf "oMLX pin: OMLX_REPO_REF=%s   (engine — frozen unless you bump it)\n\n" "${OMLX_REPO_REF:-v0.5.1}"
  local odir="${OMLX_PROJECT_DIR:-/Users/mac/projects/omlx}"
  if [ -d "$odir/.git" ]; then
    local installed latest
    installed=$(/usr/bin/sudo -u "$TARGET_USER" -H /usr/bin/git -C "$odir" describe --tags --exact-match 2>/dev/null \
      || /usr/bin/sudo -u "$TARGET_USER" -H /usr/bin/git -C "$odir" rev-parse --short HEAD 2>/dev/null)
    latest=$(/usr/bin/sudo -u "$TARGET_USER" -H /usr/bin/git ls-remote --tags --refs "${OMLX_REPO:-https://github.com/jundot/omlx}" 2>/dev/null \
      | /usr/bin/awk -F/ '{print $NF}' | /usr/bin/sort -V | /usr/bin/tail -1)
    printf "  %-10s installed=%-11s latest_tag=%-11s%s\n" omlx "${installed:-?}" "${latest:-?}" \
      "$([ -n "$latest" ] && [ "$installed" != "$latest" ] && echo '   <-- newer available')"
  fi
  printf "\nLLM stack (installed vs PyPI):\n"
  local pair vn pk py
  for pair in litellm:litellm; do
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
  printf "\n${C_DIM}Upgrade the LLM stack on purpose: menu 4 -> set OMLX_REPO_REF -> menu 1.${C_RST}\n"
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
    *omlx-main.log)
      # Conservative superset of mlx_vlm.server's old log vocabulary — refine
      # against real oMLX log lines once verified in production.
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
                                 Persistently power off/on the main LLM
                                 (oMLX) to free/restore memory (off =
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
