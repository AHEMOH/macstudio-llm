# Bug: immich-ml never actually goes to sleep

**Status:** mitigated 2026-07-30. Documented 2026-07-29 as a handoff for investigation; see
`## Resolution (2026-07-30)` below for what was found and fixed. The investigation trail below
this point is left intact as historical record — none of it turned out to be wrong, it just
wasn't the whole picture.

## Resolution (2026-07-30)

Investigated live on the Mac (read-only diagnostics: `docker inspect`/`top`/`ps`, log tails,
`launchctl print` — nothing destructive run) to test the two hypotheses below.

- **Hypothesis 1 (shell-form entrypoint swallowing SIGTERM) is disproven.** Both the running
  container and the image report clean exec-form `Entrypoint=[tini --]`, `Cmd=[python -m
  immich_ml]`. `tini` is confirmed as real PID 1 inside the container (`docker top`, parented by
  `containerd-shim` on the host) — there is no intervening `/bin/sh -c` that could eat the signal.
- **Hypothesis 2 (sig-proxy fundamentally ineffective through Colima) is not a clean yes either.**
  The chain was witnessed working: two clean stop→restart cycles happened live during this
  investigation (`docker inspect`'s `FinishedAt` → next `StartedAt` ~21s apart, `ExitCode=0`,
  brand-new PID 1, fresh gunicorn boot log), both matching `immich-proxy.log`'s "waking"/"healthy"
  lines and `launchctl print`'s `runs` counter incrementing. So the `launchctl stop → SIGTERM →
  docker start -a → sig-proxy → tini → gunicorn` chain plainly *can* work end-to-end.
- **Suspicious, unconfirmed timing correlation:** the original 44h-stuck window
  (2026-07-27 19:4x → 2026-07-29 20:2x) overlaps almost entirely with the separate
  [[project_immich_ml_colima_oom]] incident — Colima's VM was undersized (2 vCPU/2GiB stock
  default) and OOM-killed the ONNX/gunicorn worker repeatedly while a large CLIP model loaded,
  which can leave gunicorn's arbiter process stuck in a tight worker-respawn loop (container-level
  state never visibly changes, since gunicorn handles worker respawn internally — this is exactly
  why `docker ps`/`RestartCount` looked fine in both incidents despite real internal trouble). That
  was fixed 2026-07-29 by raising `IMMICH_COLIMA_CPU`/`_MEMORY` to 4/6. The two clean stop→restart
  cycles witnessed above happened *after* that fix shipped. Working theory: gunicorn's arbiter only
  services its own signal queue inside its main-loop iteration, so a wedged respawn loop could
  plausibly delay or drop its handling of an incoming SIGTERM — but this is **not proven**, and
  re-triggering the OOM condition live to confirm it was deliberately not attempted (real
  disruption risk for a confirmation that turned out not to be required — see below).

**The fix does not depend on that theory being correct.** `wrappers/start-immich-ml.sh` no longer
`exec`s into `docker start -a` and hopes `--sig-proxy` forwards the signal correctly. It now
backgrounds `docker start -a`, traps `TERM`/`INT`, and translates a stop request into
`docker stop --time 15 immich_machine_learning` directly against `dockerd` — which sends its own
SIGTERM to the container's real PID 1, then an unmaskable SIGKILL after the grace period,
independent of whatever the attached CLI's signal plumbing or the container's own userspace
(gunicorn) responsiveness is doing. `daemons/com.local.immich.ml.plist` gained an explicit
`ExitTimeOut=30` so launchd's own last-resort SIGKILL of the wrapper itself can't fire before
`docker stop`'s 15s grace has had a chance to work. `services/ondemand-proxy.py` needed **no**
changes — it stays fully backend-agnostic; all the Docker-specific handling lives in the one
wrapper that already owns every other immich-specific quirk (session user, colima socket path).

Verification (temporarily lowering `IDLE_TIMEOUT_IMMICH`, per the "How to safely test" section
below, and watching for `Exited` status within ~15-17s of the "idle...stopping" log line across
several consecutive cycles) — record results here once run for real on the Mac after deploy.

## Symptom

`com.local.immich.proxy`'s idle-watchdog (`services/ondemand-proxy.py::idle_watchdog()`) is
supposed to `launchctl stop com.local.immich.ml` once the backend has been idle for
`IDLE_TIMEOUT_IMMICH` (900s), so the Colima/Docker-based ML container isn't resident 24/7 for
nothing. In practice, on this Mac, it has been logging this every ~30s **continuously for 44+
hours straight** without the backend ever actually stopping:

```
/var/log/macstudio/immich-proxy.log:
[2026-07-27 17:50:19][immich-proxy] idle for 158902s — stopping com.local.immich.ml
[2026-07-27 17:50:49][immich-proxy] idle for 158932s — stopping com.local.immich.ml
[2026-07-27 17:51:19][immich-proxy] idle for 158962s — stopping com.local.immich.ml
... (same line, every ~30s, unbroken, for 44+ hours) ...
[2026-07-29 19:47:58][immich-proxy] idle for 165961s — stopping com.local.immich.ml
```

Confirmed at the Docker level that the backend genuinely never stopped during that whole window:

```
$ docker --context colima inspect immich_machine_learning \
    --format '{{.State.StartedAt}} restarts={{.RestartCount}} status={{.State.Status}}'
2026-07-27T19:41:55.109813711Z restarts=0 status=running
```

`RestartCount=0` and a `StartedAt` matching the container's original creation time, checked ~47
hours later — the container was continuously "Up ... (healthy)" the entire time `stopping` was
being logged every 30 seconds. The idle-sleep design (see `ondemand-proxy.py`'s module docstring:
"runs `launchctl stop BACKEND_LABEL` so RAM returns to [the rest of the system]") is simply not
working for this backend — it stays resident regardless of idle time.

## Impact

Low urgency, but real: the whole point of the on-demand pattern is that this backend (and others
like it) don't sit resident 24/7. Right now immich-ml effectively runs 24/7 anyway, which defeats
that design goal (extra idle RAM/CPU on a box that also runs the main LLM). It is **not** related
to the 2026-07-29 OOM incident that was just fixed (see [[project_immich_ml_colima_oom]] /
`project_immich_ml_colima_oom.md` in this repo's Claude memory, and the "Immich-ML" bullet in
`CLAUDE.md`) — that was Colima's VM being too small (2GB/2CPU), separate from this idle-sleep
issue, and is already resolved. This bug means the backend runs warm all the time, which if
anything makes cold-start-related failures *less* likely, not more — so it's a resource-hygiene
bug, not a correctness bug, as far as we can tell so far.

## Ruled out

- **Not specific to today's incident/model switch.** The stuck idle-loop pattern spans from
  2026-07-27 19:4x (right after the Docker/Colima migration) through 2026-07-29 20:2x (when it was
  discovered) — i.e. from the very first hours after the container existed.
- **Not a general `ondemand-proxy.py` bug.** The exact same shared script
  (`services/ondemand-proxy.py`) runs the proxy for every on-demand backend (images, voicestt,
  voicetts, docling, immich). Checked `/var/log/macstudio/docling-proxy.log` for comparison:
  `com.local.docling.serve` (a **plain venv Python process**, not Docker) shows the same
  "idle...stopping" pattern repeating for a few minutes, then it actually stops — confirmed
  currently via `sudo launchctl list | grep docling` → `- 0 com.local.docling.serve` (dash = no
  live pid). So the shared idle-watchdog/stop logic itself works; something specific to **how
  immich-ml is wrapped** is the problem.

## Leading hypothesis: `docker start -a`'s attached CLI dying ≠ the container stopping

`wrappers/start-immich-ml.sh` ends with:

```sh
# `docker start -a` proxies signals to the container by default (--sig-proxy), so
# `launchctl stop`'s SIGTERM stops the container itself, not just this CLI client.
exec /opt/homebrew/bin/docker start -a immich_machine_learning
```

This comment states the assumption the whole idle-sleep design rests on for this backend: that
`launchctl stop com.local.immich.ml` → SIGTERM to the exec'd `docker start -a` process → forwarded
via `--sig-proxy` into the container → container's PID 1 (gunicorn) shuts down → `docker start -a`
itself exits once the container exits → launchd sees the tracked pid disappear → `backend_pid()`
in `ondemand-proxy.py` returns 0 → the "idle...stopping" log line stops appearing (the watchdog
only logs+calls stop while `backend_pid() > 0`).

That chain has several links that could silently break, and the observed behavior (endless
"stopping" with `backend_pid()` apparently *never* dropping to 0 for 44+ hours, while the
container's own `RestartCount`/`StartedAt` never move) is consistent with the chain breaking
**after** the SIGTERM leaves launchd's hands but **before** the container actually exits. Two
concrete things to check, in order of suspicion:

1. **The image's `ENTRYPOINT`/`CMD` form.** If `ghcr.io/immich-app/immich-machine-learning`'s
   entrypoint is *shell form* (`CMD gunicorn ...` as a string, run via `/bin/sh -c "..."`) rather
   than *exec form* (JSON array), the shell becomes PID 1 and does **not** forward signals to the
   gunicorn child by default — a textbook Docker gotcha. `docker start -a --sig-proxy` would then
   correctly deliver SIGTERM to PID 1 (the shell), but the shell simply ignores it while gunicorn
   keeps running underneath, so the container never exits.
   ```
   docker --context colima inspect ghcr.io/immich-app/immich-machine-learning:release \
     --format 'Entrypoint={{.Config.Entrypoint}} Cmd={{.Config.Cmd}} StopSignal={{.Config.StopSignal}}'
   ```
   If `Entrypoint`/`Cmd` show a single string starting with `/bin/sh -c` (rather than a JSON
   array), that's very likely the root cause.
2. **Whether `--sig-proxy` is actually effective in this colima/lima setup at all.** `docker start
   -a` defaults to `--sig-proxy=true`, but this is worth confirming directly rather than assuming
   Docker's documented default holds unmodified through colima's VM/socket path. Reproduce
   directly: `docker --context colima kill -s TERM immich_machine_learning` and watch whether the
   container actually exits (`docker ps -a` shows `Exited`) — if a **direct** `docker kill -s TERM`
   (not going through `docker start -a`'s CLI attachment at all) also fails to stop it, the
   problem is inside the container/image (points strongly at hypothesis 1), not in
   launchd→CLI→sig-proxy plumbing. If direct `docker kill -s TERM` *does* stop it cleanly, the
   problem is specifically in the `launchctl stop` → SIGTERM-to-`docker start -a` → sig-proxy path,
   and hypothesis 2 (or something in launchd's own signal delivery to an `exec`'d Docker CLI
   process) becomes more likely.

**Update 2026-07-30: see `## Resolution` at the top of this doc.** Hypothesis 1 confirmed disproven
(exec-form entrypoint); hypothesis 2 confirmed to work at least sometimes rather than being
categorically broken. The fix landed anyway, in the wrapper (trap SIGTERM/INT → `docker stop`),
precisely because it doesn't require either hypothesis to be fully resolved — `docker stop` is
root-cause-agnostic. `ondemand-proxy.py` was deliberately left untouched (kept backend-agnostic)
rather than special-cased, per its own design rule.

## How to safely test without waiting 900s

Lower `IDLE_TIMEOUT_IMMICH` temporarily in `/usr/local/etc/macstudio.conf` (e.g. to `30`), `sudo
bash setup.sh --apply` is NOT needed for a conf-only test — the proxy reads the env at its own
process start, so restart just the proxy: `sudo launchctl kickstart -k
system/com.local.immich.proxy`. Then watch `/var/log/macstudio/immich-proxy.log` and `docker
--context colima ps -a --filter name=immich` in parallel after the backend goes idle. Remember to
restore `IDLE_TIMEOUT_IMMICH` (or just re-run `--apply`, which re-renders from `macstudio.conf` —
don't forget to revert the conf edit first) afterward.

## Relevant files

- `services/ondemand-proxy.py` — shared idle-watchdog/wake/stop logic for every on-demand backend
  (`idle_watchdog()`, `stop_backend()`, `backend_pid()`, ~lines 78-103, 241-252).
- `wrappers/start-immich-ml.sh` — the wrapper whose signal-forwarding assumption is in question.
- `daemons/com.local.immich.ml.plist` — `KeepAlive=false`, `RunAtLoad=false`, `ThrottleInterval=5`.
- `daemons/com.local.immich.proxy.plist` / `wrappers/start-immich-proxy.sh` — sets
  `IDLE_TIMEOUT_IMMICH`/`STARTUP_TIMEOUT_IMMICH` env for the proxy.
- Logs on the Mac: `/var/log/macstudio/immich-proxy.log` (proxy's own log),
  `/var/log/macstudio/immich-ml.log` (container's stdout/stderr, piped through `docker start -a`).
- Access: `ssh mac@mac.home.arpa` (passwordless key auth + passwordless sudo); Docker container
  ops need `DOCKER_HOST=unix:///Users/colima-svc/.colima/default/docker.sock` or
  `sudo -u colima-svc -i docker --context colima ...`.
