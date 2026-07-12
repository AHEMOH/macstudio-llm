#!/usr/bin/env python3
"""
On-demand TCP proxy for macOS launchd-managed backends.

Listens on LISTEN_PORT. On the first incoming connection, kickstarts the
backend LaunchDaemon (BACKEND_LABEL), polls HEALTH_URL until it returns 200,
then proxies traffic to BACKEND_HOST:BACKEND_PORT. Every 30 s, if
now - last_request > IDLE_TIMEOUT_SEC and the backend has a live pid, runs
`launchctl stop BACKEND_LABEL` so RAM returns to Ollama.

Configuration via environment (set by the wrapper script):
  LISTEN_HOST, LISTEN_PORT
  BACKEND_HOST, BACKEND_PORT, BACKEND_LABEL
  HEALTH_URL
  IDLE_TIMEOUT_SEC, STARTUP_TIMEOUT_SEC
  SERVICE_NAME (display name in logs)
"""
from __future__ import annotations

import asyncio
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

LISTEN_HOST = os.environ.get("LISTEN_HOST", "0.0.0.0")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "3003"))
BACKEND_HOST = os.environ.get("BACKEND_HOST", "127.0.0.1")
BACKEND_PORT = int(os.environ.get("BACKEND_PORT", "13003"))
BACKEND_LABEL = os.environ["BACKEND_LABEL"]
HEALTH_URL = os.environ["HEALTH_URL"]
IDLE_TIMEOUT_SEC = int(os.environ.get("IDLE_TIMEOUT_SEC", "900"))
STARTUP_TIMEOUT_SEC = int(os.environ.get("STARTUP_TIMEOUT_SEC", "60"))
SERVICE_NAME = os.environ.get("SERVICE_NAME", BACKEND_LABEL.split(".")[-1])

IDLE_CHECK_INTERVAL_SEC = 30
last_request_ts = 0.0
# Created inside main() so the Lock binds to the running loop. Python 3.9's
# asyncio.Lock() at module scope binds to the default loop, which differs
# from the one `asyncio.run(main())` creates → "Future attached to a
# different loop" when two clients race the lock.
startup_lock: "asyncio.Lock | None" = None

# --- Failure back-off + load-shedding -------------------------------------
# Added after an immich-ml incident: the backend project was missing, so it
# could never become healthy. Every incoming connection re-kickstarted it and
# waited the full STARTUP_TIMEOUT, and clients (an Immich server) reconnected
# immediately — an endless wake→wait→fail→wake storm that piled blocked clients
# onto startup_lock (each holding a socket) until the process hit macOS' 256-fd
# soft limit and wedged with "OSError [Errno 24] Too many open files". These two
# guards make a never-healthy backend fail FAST and cheap instead:
#   1. exponential cooldown between wake attempts once a wake has failed, and
#   2. a cap on how many clients may block waiting for a wake at once.
FAILURE_BACKOFF_BASE_SEC = 30
FAILURE_BACKOFF_CAP_SEC = 300
MAX_PENDING_WAITERS = 8
consecutive_failures = 0
cooldown_until = 0.0      # monotonic; skip kickstart while time.monotonic() < this
pending_waiters = 0       # clients currently blocked in ensure_backend_up()


def log(msg: str) -> None:
    print(f"[{time.strftime('%F %T')}][{SERVICE_NAME}-proxy] {msg}", flush=True)


def http_503(body: bytes) -> bytes:
    return (
        b"HTTP/1.1 503 Service Unavailable\r\n"
        b"Content-Type: text/plain\r\n"
        b"Connection: close\r\n"
        b"Content-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body
    )


def backend_pid() -> int:
    """Return the pid of the backend daemon, or 0 if not running."""
    try:
        out = subprocess.run(
            ["/bin/launchctl", "print", f"system/{BACKEND_LABEL}"],
            capture_output=True, text=True, timeout=5,
        ).stdout
    except Exception as exc:
        log(f"launchctl print failed: {exc}")
        return 0
    m = re.search(r"^\s*pid\s*=\s*(\d+)", out, re.MULTILINE)
    return int(m.group(1)) if m and int(m.group(1)) > 0 else 0


def kickstart_backend() -> None:
    subprocess.run(
        ["/bin/launchctl", "kickstart", "-k", f"system/{BACKEND_LABEL}"],
        capture_output=True, timeout=10,
    )


def stop_backend() -> None:
    subprocess.run(
        ["/bin/launchctl", "stop", BACKEND_LABEL],
        capture_output=True, timeout=10,
    )


def health_ok() -> bool:
    try:
        with urllib.request.urlopen(HEALTH_URL, timeout=2) as r:
            return 200 <= r.status < 400
    except urllib.error.HTTPError:
        # The backend answered over HTTP (even with an error status), which
        # proves the process is up and serving — some backends (e.g.
        # macos-speech-server) expose no dedicated health route at all, only
        # POST-only endpoints that 404/405 on a plain GET.
        return True
    except (urllib.error.URLError, TimeoutError, ConnectionError):
        return False
    except Exception:
        return False


def _note_healthy() -> None:
    """Clear any accumulated failure back-off once the backend is serving again."""
    global consecutive_failures, cooldown_until
    consecutive_failures = 0
    cooldown_until = 0.0


async def ensure_backend_up() -> bool:
    """Wake the backend if needed and block until HEALTH_URL is green."""
    global consecutive_failures, cooldown_until
    # Fast path outside the lock: healthy traffic shouldn't serialize behind one
    # slow probe, and it clears the back-off the moment the backend recovers.
    if health_ok():
        _note_healthy()
        return True
    # Back-off: a prior wake failed and we're still inside its cooldown window —
    # don't kickstart again, just fail fast so the client gets a quick 503 and
    # backs off (this is what stops the wake storm / fd leak).
    if time.monotonic() < cooldown_until:
        return False
    async with startup_lock:
        # Re-check under the lock: another client may have just brought it up, or
        # opened a fresh cooldown, while we waited for the lock.
        if health_ok():
            _note_healthy()
            return True
        if time.monotonic() < cooldown_until:
            return False
        log(f"waking {BACKEND_LABEL}")
        kickstart_backend()
        deadline = time.monotonic() + STARTUP_TIMEOUT_SEC
        while time.monotonic() < deadline:
            await asyncio.sleep(1.0)
            if health_ok():
                elapsed = STARTUP_TIMEOUT_SEC - (deadline - time.monotonic())
                log(f"{BACKEND_LABEL} healthy after {elapsed:.1f}s")
                _note_healthy()
                return True
        consecutive_failures += 1
        backoff = min(FAILURE_BACKOFF_CAP_SEC,
                      FAILURE_BACKOFF_BASE_SEC * (2 ** (consecutive_failures - 1)))
        cooldown_until = time.monotonic() + backoff
        log(f"{BACKEND_LABEL} did not become healthy within {STARTUP_TIMEOUT_SEC}s "
            f"(failure #{consecutive_failures}; backing off {backoff:.0f}s before the next wake)")
        return False


async def pipe(src: asyncio.StreamReader, dst: asyncio.StreamWriter) -> None:
    try:
        while True:
            data = await src.read(65536)
            if not data:
                break
            dst.write(data)
            await dst.drain()
    except Exception:
        pass
    finally:
        try:
            dst.close()
        except Exception:
            pass


async def handle_client(client_reader: asyncio.StreamReader, client_writer: asyncio.StreamWriter) -> None:
    global last_request_ts, pending_waiters
    last_request_ts = time.time()
    peer = client_writer.get_extra_info("peername")
    try:
        # Load-shedding: if the backend is down and the wait queue is already full,
        # fail this request immediately instead of holding its socket open on the
        # startup_lock queue. When the backend is healthy, ensure_backend_up() returns
        # on the fast path so pending_waiters never climbs — a full queue only happens
        # while the backend is genuinely unavailable.
        if pending_waiters >= MAX_PENDING_WAITERS:
            body = f"{SERVICE_NAME} backend starting; too many pending requests, retry shortly".encode()
            client_writer.write(http_503(body))
            await client_writer.drain()
            return
        pending_waiters += 1
        try:
            backend_up = await ensure_backend_up()
        finally:
            pending_waiters -= 1
        if not backend_up:
            body = f"{SERVICE_NAME} backend failed to start".encode()
            client_writer.write(http_503(body))
            await client_writer.drain()
            return
        try:
            backend_reader, backend_writer = await asyncio.wait_for(
                asyncio.open_connection(BACKEND_HOST, BACKEND_PORT), timeout=5
            )
        except Exception as exc:
            log(f"backend connect failed from {peer}: {exc}")
            body = f"{SERVICE_NAME} backend unreachable: {exc}".encode()
            client_writer.write(http_503(body))
            await client_writer.drain()
            return
        await asyncio.gather(
            pipe(client_reader, backend_writer),
            pipe(backend_reader, client_writer),
            return_exceptions=True,
        )
    finally:
        # close() schedules the transport shut; wait_closed() ensures the fd is
        # actually released before this coroutine ends (prevents fd build-up under
        # a burst of short-lived connections).
        try:
            client_writer.close()
        except Exception:
            pass
        try:
            await client_writer.wait_closed()
        except Exception:
            pass
        last_request_ts = time.time()


async def idle_watchdog() -> None:
    # IDLE_TIMEOUT_SEC <= 0 means "never sleep" — once woken, the backend stays
    # resident (e.g. IDLE_TIMEOUT_INFINITY=-1 to keep embed/rerank permanently warm).
    if IDLE_TIMEOUT_SEC <= 0:
        log("idle timeout <= 0 — never auto-sleeping this backend")
        return
    while True:
        await asyncio.sleep(IDLE_CHECK_INTERVAL_SEC)
        idle_for = time.time() - last_request_ts if last_request_ts > 0 else float("inf")
        if idle_for > IDLE_TIMEOUT_SEC and backend_pid() > 0:
            log(f"idle for {idle_for:.0f}s — stopping {BACKEND_LABEL}")
            stop_backend()


async def main() -> None:
    global startup_lock, last_request_ts
    startup_lock = asyncio.Lock()
    # Treat proxy startup as a fresh activity timestamp so the idle_watchdog
    # doesn't immediately stop a backend that was kickstarted out-of-band
    # (e.g. by a prior proxy instance or manual launchctl).
    last_request_ts = time.time()
    server = await asyncio.start_server(handle_client, LISTEN_HOST, LISTEN_PORT)
    addrs = ", ".join(str(s.getsockname()) for s in server.sockets or [])
    log(f"listening on {addrs} → {BACKEND_HOST}:{BACKEND_PORT} ({BACKEND_LABEL})")
    log(f"idle timeout {IDLE_TIMEOUT_SEC}s, startup timeout {STARTUP_TIMEOUT_SEC}s")
    async with server:
        await asyncio.gather(server.serve_forever(), idle_watchdog())


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(0)
