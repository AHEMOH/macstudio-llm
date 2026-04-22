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
startup_lock = asyncio.Lock()


def log(msg: str) -> None:
    print(f"[{time.strftime('%F %T')}][{SERVICE_NAME}-proxy] {msg}", flush=True)


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
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, ConnectionError):
        return False
    except Exception:
        return False


async def ensure_backend_up() -> bool:
    """Wake the backend if needed and block until HEALTH_URL is green."""
    async with startup_lock:
        if health_ok():
            return True
        log(f"waking {BACKEND_LABEL}")
        kickstart_backend()
        deadline = time.monotonic() + STARTUP_TIMEOUT_SEC
        while time.monotonic() < deadline:
            await asyncio.sleep(1.0)
            if health_ok():
                elapsed = STARTUP_TIMEOUT_SEC - (deadline - time.monotonic())
                log(f"{BACKEND_LABEL} healthy after {elapsed:.1f}s")
                return True
        log(f"{BACKEND_LABEL} did not become healthy within {STARTUP_TIMEOUT_SEC}s")
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
    global last_request_ts
    last_request_ts = time.time()
    peer = client_writer.get_extra_info("peername")
    try:
        if not await ensure_backend_up():
            body = f"{SERVICE_NAME} backend failed to start".encode()
            client_writer.write(
                b"HTTP/1.1 503 Service Unavailable\r\n"
                b"Content-Type: text/plain\r\n"
                b"Connection: close\r\n"
                b"Content-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body
            )
            await client_writer.drain()
            return
        try:
            backend_reader, backend_writer = await asyncio.wait_for(
                asyncio.open_connection(BACKEND_HOST, BACKEND_PORT), timeout=5
            )
        except Exception as exc:
            log(f"backend connect failed from {peer}: {exc}")
            body = f"{SERVICE_NAME} backend unreachable: {exc}".encode()
            client_writer.write(
                b"HTTP/1.1 503 Service Unavailable\r\n"
                b"Content-Type: text/plain\r\n"
                b"Connection: close\r\n"
                b"Content-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body
            )
            await client_writer.drain()
            return
        await asyncio.gather(
            pipe(client_reader, backend_writer),
            pipe(backend_reader, client_writer),
            return_exceptions=True,
        )
    finally:
        try:
            client_writer.close()
        except Exception:
            pass
        last_request_ts = time.time()


async def idle_watchdog() -> None:
    while True:
        await asyncio.sleep(IDLE_CHECK_INTERVAL_SEC)
        idle_for = time.time() - last_request_ts if last_request_ts > 0 else float("inf")
        if idle_for > IDLE_TIMEOUT_SEC and backend_pid() > 0:
            log(f"idle for {idle_for:.0f}s — stopping {BACKEND_LABEL}")
            stop_backend()


async def main() -> None:
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
