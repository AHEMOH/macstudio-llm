# Mac Studio Headless LLM Server

Headless Apple Silicon Mac as a maximum-memory **Ollama** inference server, with
on-demand companion services (image AI, document OCR/VLM) that sleep when idle
and wake automatically on the first incoming request. Runs fully unattended —
no GUI, no login, auto-restart on power loss, weekly self-update.

Designed for a 32 GB M1 Max but scales unchanged to M2/M3/M4 Max/Ultra with
more RAM — just edit one config key.

## What this gives you

- **Ollama** always on :11434, one big model pinned in VRAM forever (no reload
  latency), tuned env (`OLLAMA_KEEP_ALIVE=-1`, `OLLAMA_KV_CACHE_TYPE=q8_0`,
  flash attention, `MAX_LOADED_MODELS=1`).
- **30 GB GPU wired memory limit** (on a 32 GB box) + OS trim → nearly the
  whole machine is available to the model.
- **On-demand proxies** on :3003 (immich-ml) and :5001 (docling-serve). Public
  ports are always listening; the real backend is only started when a request
  arrives and is stopped after 15 min of idle, freeing RAM back to Ollama.
- **Weekly auto-update** Saturday 06:00: brew upgrade, Python venv pip upgrade,
  macOS minor/security updates (with auto-reboot if needed).
- **Prometheus exporters** for your Proxmox Grafana stack: node_exporter
  (:9100), Apple-Silicon metrics via `powermetrics` (:9101, GPU %, power,
  thermal pressure), Ollama state (:9102, loaded model, size, KV cache).
- **Memory-pressure watchdog** as a safety net — offloads optional services
  if macOS reports RAM pressure while Ollama is active.
- **Auto-restart on power loss**, sleep disabled, `caffeinate` daemon,
  LaunchDaemon-based so no login required.
- **MOTD banner** on every SSH login listing ports, commands, and logs.
- **One script** (`setup.sh`) for install, update, settings, service control,
  clean-up, uninstall. TUI by default, `--apply` for non-interactive runs.
  Idempotent — re-run safely at any time.

## Architecture

```
Always on  (LaunchDaemon, KeepAlive=true, RunAtLoad=true):
  com.local.ollama.headless        :11434   Ollama LLM engine
  com.local.immich.proxy           :3003    on-demand proxy, ~20 MB
  com.local.docling.proxy          :5001    on-demand proxy, ~20 MB
  com.local.node.exporter          :9100    Prometheus system metrics
  com.local.silicon.exporter       :9101    GPU / power / thermal metrics
  com.local.ollama.exporter        :9102    Ollama /api/ps exporter
  com.local.llm.watchdog                    memory-pressure safety net
  com.local.preventsleep                    caffeinate

One-shot at boot:
  com.local.iogpu.wiredlimit                sets iogpu.wired_limit_mb

Scheduled (Sat 06:00 default):
  com.local.weekly.autoupdate               brew + pip + softwareupdate

Registered but sleeping until requested:
  com.local.immich.ml              :13003   real immich-ml backend
  com.local.docling.serve          :15001   real docling-serve backend
```

First request after idle pays a one-time ~3 s warm-up. Subsequent requests
within the idle window are instant.

## Quick start

### 1. From your PC — copy SSH key once (PowerShell/macOS/Linux)

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

### 2. On the Mac — clone and install

```bash
# SSH into the Mac, then:
cd ~
git clone https://github.com/<you>/macstudio-llm.git
cd macstudio-llm

# Interactive TUI (recommended for the first run):
sudo bash setup.sh

# …or non-interactive one-shot:
sudo bash setup.sh --apply
```

### 3. Pull and run your model

```bash
ollama pull gemma4:31b-nvfp4          # or whatever fits your VRAM
ollama run  gemma4:31b-nvfp4 "hello"  # stays loaded forever
```

### 4. Later — update everything

```bash
cd ~/macstudio-llm
git pull
sudo bash setup.sh --apply
```

Or let it happen automatically every Saturday at 06:00 (and reboot if macOS
updates require it).

## Hardware assumptions

- **Apple Silicon** (M1 / M2 / M3 / M4, any variant). Powermetrics-based
  exporter is Apple-Silicon-specific.
- **16 – 192 GB unified RAM**. The default `IOGPU_WIRED_LIMIT_MB=30720`
  (30 GB) assumes 32 GB; adjust per `docs` table below.
- **macOS 14+** tested on macOS 26.3.1. The `iogpu.wired_limit_mb` sysctl
  exists on 13.4+.
- A dedicated user account (default `mac`) — this user runs Ollama and the
  Python venvs; the other LaunchDaemons that need root run as root.

| Total RAM | Recommended `IOGPU_WIRED_LIMIT_MB` | OS headroom |
|-----------|------------------------------------|-------------|
| 16 GB     | 14336                              | 2 GB        |
| 32 GB     | **30720** (default)                | 2 GB        |
| 64 GB     | 61440                              | 4 GB        |
| 96 GB     | 92160                              | 6 GB        |
| 192 GB    | 184320                             | 12 GB       |

If `memory_pressure` ever reports `Warn` while a model is loaded, drop
`IOGPU_WIRED_LIMIT_MB` by 1024 (e.g., 30720 → 29696) via `setup.sh` menu 2.

## `setup.sh` — one file, whole lifecycle

```
sudo bash setup.sh            # interactive TUI (main menu)
sudo bash setup.sh --apply    # non-interactive: install or update, no prompts
sudo bash setup.sh --status   # print live status table and exit
sudo bash setup.sh --help     # show flags
```

TUI main menu:

```
1) Install / update everything   (recommended — applies current config)
2) Select services to install…   (toggle immich / docling / exporters / watchdog)
3) Change settings…              (GPU memory, keep-alive, idle timeouts, …)
4) Service control…              (start / stop / restart each daemon)
5) Run weekly autoupdate now
6) Scan for leftovers from previous installs
7) Clean-up tasks…               (old logs, uninstall node_exporter)
8) View logs…
9) Uninstall everything this tool installed
q) Quit
```

**On first run** (no config file yet) the TUI jumps straight to menu 2 so
you can pick which optional services to install before anything is touched.
Everything is on by default. Re-run later and toggle more on — the script
never overwrites a healthy service (brew formulas, venvs, and rendered
files are all hash-checked before touching). Toggling a service **off**
removes its launchd plist; toggling **on** re-renders and bootstraps it.

Every action is **idempotent**. Re-running on a healthy system is a
~5-second no-op. There are no `.state/` checkpoint files — the script
inspects `/Library/LaunchDaemons/`, `sysctl`, `launchctl print`, file hashes,
and `brew list` to decide what needs touching.

**Leftovers from previous installs** (stale `com.local.*` plists from an
older layout, orphan files in `/usr/local/libexec/`, leftover `LM Studio.app`
or `Ollama.app`) are detected at the start of every interactive install,
listed, and removed only with your confirmation. Menu 6 runs the same scan
on demand.

## Configuration reference

All tunables live in **`/usr/local/etc/macstudio.conf`** (key=value, shell-
sourceable). Managed via `setup.sh` menu 2, or edit the file directly and
run `sudo bash setup.sh --apply`.

| Key                          | Default      | Meaning |
|------------------------------|--------------|---------|
| `TARGET_USER`                | `mac`        | Unix user that owns Ollama and venvs |
| `IOGPU_WIRED_LIMIT_MB`       | `30720`      | GPU wired memory ceiling |
| `OLLAMA_PORT`                | `11434`      | Ollama API port |
| `OLLAMA_KEEP_ALIVE`          | `-1`         | `-1` = pin forever; `24h`, `1h`, `5m` also valid |
| `OLLAMA_KV_CACHE_TYPE`       | `q8_0`       | `q8_0` (safe ~2× saving), `q4_0` (aggressive), `fp16` |
| `OLLAMA_FLASH_ATTENTION`     | `1`          | Required for q8_0/q4_0 KV cache |
| `OLLAMA_MAX_LOADED_MODELS`   | `1`          | Single-model server; raise only if you have RAM to spare |
| `OLLAMA_NUM_PARALLEL`        | `1`          | Parallel requests per model |
| `OLLAMA_LOAD_TIMEOUT`        | `15m`        | Gives huge models time to page in |
| `ML_PUBLIC_PORT`             | `3003`       | Public immich-ml port (proxy listens here) |
| `ML_BACKEND_PORT`            | `13003`      | Internal immich-ml backend port |
| `DOCLING_PUBLIC_PORT`        | `5001`       | Public docling-serve port |
| `DOCLING_BACKEND_PORT`       | `15001`      | Internal docling-serve backend port |
| `IDLE_TIMEOUT_IMMICH`        | `900` (15 m) | Seconds before backend sleeps |
| `IDLE_TIMEOUT_DOCLING`       | `900` (15 m) | Seconds before backend sleeps |
| `STARTUP_TIMEOUT_IMMICH`     | `60`         | Wake-up deadline for immich backend |
| `STARTUP_TIMEOUT_DOCLING`    | `120`        | Wake-up deadline for docling backend |
| `AUTOUPDATE_WEEKDAY`         | `6`          | launchd weekday: 0=Sun 1=Mon … 6=Sat |
| `AUTOUPDATE_HOUR`            | `6`          | Hour (0–23) |
| `AUTOUPDATE_MINUTE`          | `0`          | Minute (0–59) |
| `NODE_EXPORTER_PORT`         | `9100`       | Prometheus node_exporter |
| `SILICON_EXPORTER_PORT`      | `9101`       | GPU/power/thermal exporter |
| `OLLAMA_EXPORTER_PORT`       | `9102`       | Ollama state exporter |
| `INSTALL_IMMICH`             | `1`          | 0 to skip installing the immich-ml on-demand service |
| `INSTALL_DOCLING`            | `1`          | 0 to skip installing the docling-serve on-demand service |
| `INSTALL_EXPORTERS`          | `1`          | 0 to skip Prometheus exporters |
| `INSTALL_WATCHDOG`           | `1`          | 0 to skip the memory-pressure watchdog |
| `WATCHDOG_PRESSURE_THRESHOLD`| `warn`       | `warn` or `critical` |
| `WATCHDOG_AUTO_RESTORE`      | `0`          | `1` = re-wake immich+docling after pressure clears |
| `AUTO_ACCEPT`                | `0`          | `1` = skip all "press Enter" prompts in the TUI |

## Commands (installed to `/usr/local/bin`)

| Command | Purpose |
|---------|---------|
| `llm-status` | Live overview: memory, daemons, scheduled jobs |
| `llm-restart [name\|all]` | Restart one or all services. `llm-restart list` for names |
| `llm-update` | Run the weekly autoupdate job right now |
| `llm-service-ctl wake\|sleep\|status immich\|docling\|all` | Manual on-demand override |
| `llm-logs [name]` | `tail -F` a service's log file |
| `asitop` | Interactive Apple-Silicon TUI (installed via pipx) |

Plus the vanilla Ollama CLI: `ollama list`, `ollama ps`, `ollama pull <m>`,
`ollama run <m>`.

## Monitoring setup (Proxmox → Grafana)

Add these to your Proxmox `prometheus.yml`:

```yaml
scrape_configs:
  - job_name: mac-system
    static_configs: [{ targets: ['mac.home.arpa:9100'] }]
  - job_name: mac-silicon
    static_configs: [{ targets: ['mac.home.arpa:9101'] }]
  - job_name: mac-ollama
    static_configs: [{ targets: ['mac.home.arpa:9102'] }]
```

Then import in Grafana:
- Dashboard **1860** (node_exporter full) for system metrics.
- Custom dashboard JSON shipped in `grafana/mac-llm-dashboard.json` for the
  Ollama + silicon-specific panels.

## How on-demand works

The proxy plist (`com.local.immich.proxy` / `com.local.docling.proxy`) always
owns the public port (e.g. :3003). The real backend plist (`com.local.immich.ml`)
is registered but with `KeepAlive=false, RunAtLoad=false` — it stays stopped.

When a TCP connection arrives:

1. Proxy updates `last_request_ts = now`.
2. If the backend's `launchctl print` shows `pid = 0`, the proxy runs
   `launchctl kickstart -k system/com.local.immich.ml` and polls the backend's
   health endpoint (`/ping` or `/version`) until it returns 200.
3. Proxy opens a TCP socket to the backend on the internal port (e.g. :13003)
   and runs a bidirectional async stream copy.

A background task in the proxy runs every 30 s: if `now - last_request_ts
> IDLE_TIMEOUT_SEC` **and** the backend has a live pid, it runs
`launchctl stop com.local.immich.ml`, which sends SIGTERM and frees the RAM
back to the system (and hence to Ollama).

This is transparent to clients: they hit :3003 as before; the only visible
change is a ~3 s first-request latency after cold start.

## File layout

```
<repo root>/
├── setup.sh                    single TUI / --apply entry point
├── motd.txt                    SSH-login banner template
├── wrappers/                   scripts that plists execute
├── bin/                        user commands (llm-*)
├── daemons/                    plist templates (@VAR@ substitution)
├── services/                   long-running helpers (proxy, exporters, watchdog, autoupdate)
├── grafana/                    Grafana dashboard JSON
└── README.md                   this file
```

On the Mac after `setup.sh --apply`:
```
/usr/local/bin/          llm-status, llm-restart, llm-update, llm-service-ctl, llm-logs
/usr/local/sbin/         set-iogpu-wired-limit.sh, weekly-autoupdate.sh
/usr/local/libexec/      wrappers + Python services
/usr/local/etc/macstudio.conf     source of truth for config
/Library/LaunchDaemons/  12 com.local.*.plist files
/var/log/macstudio/      per-service logs
/etc/motd                banner
```

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `memory_pressure` reports `Warn` with a model loaded | `IOGPU_WIRED_LIMIT_MB` too high. Lower by 1024 via `setup.sh` menu 2. |
| Proxy returns 503 for first request | Backend venv missing or crashed. Check `/var/log/macstudio/immich-ml.log` (or `docling-serve.log`). |
| `ollama ps` unexpectedly empty | `OLLAMA_KEEP_ALIVE=-1` should prevent unload, but `ollama stop` or model switch clears it. Re-run `ollama run <m>`. |
| Autoupdate didn't run on Saturday | `launchctl print system/com.local.weekly.autoupdate` — check `state` and next-run timestamp. Logs in `/var/log/macstudio/autoupdate.log`. |
| MOTD banner doesn't show on SSH | `grep -i printmotd /etc/ssh/sshd_config` — must be `yes` (default). macOS SSH may also show only on interactive sessions. |
| `sysctl iogpu.wired_limit_mb` returns 0 | You're on an older macOS. 13.4+ required. |
| Exporter :9101 returns only `apple_silicon_up 0` | `powermetrics` needs root. The daemon runs without `UserName` so should have root — check `/var/log/macstudio/silicon-exporter.log`. |

## Uninstalling

`sudo bash setup.sh` → menu 7. Removes every plist, wrapper, script,
config, and log this tool installed. Leaves Homebrew, Ollama itself, and
your `~/.ollama/models/` untouched. To also remove Ollama:
`brew uninstall ollama && rm -rf ~/.ollama`.

## Credits / license

MIT. The memory-pressure watchdog and service-control tooling were
refined over several iterations before arriving at this layout.
