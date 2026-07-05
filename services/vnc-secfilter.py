#!/usr/bin/env python3
"""
RFB security-type filter proxy for macOS Screen Sharing (VNC).

macOS' screensharingd offers Apple/ARD authentication (RFB security type 30,
Diffie-Hellman/AES-based) FIRST in its security-type list, with legacy VNC
password auth (type 2) listed after it. RFB clients pick the server's most
preferred type they support — so:
  - noVNC (browser) picks type 30 and crashes, because AES via WebCrypto
    (crypto.subtle) is only available in a "secure context" (HTTPS/localhost),
    not over plain http://mac.home.arpa:6080.
  - Some native VNC viewers pick type 30 too and then prompt for a macOS
    username + real login password instead of the shared VNC_PASSWORD.

This proxy sits in front of :5900, passes the RFB version handshake through
unmodified, then rewrites the server's security-type list to keep ONLY the
types in ALLOWED_SEC_TYPES (default: VNC password auth, type 2) before
forwarding it to the client. Every byte after that is piped through verbatim —
the client picks one of the (now-filtered) types the server already offered,
so the rest of the negotiation/auth proceeds exactly as normal. If none of the
server's offered types are in ALLOWED_SEC_TYPES, the original unfiltered list
is passed through instead (fail open rather than break the connection).

Configuration via environment (set by the wrapper script):
  LISTEN_HOST, LISTEN_PORT
  BACKEND_HOST, BACKEND_PORT   (macOS Screen Sharing, normally 127.0.0.1:5900)
  ALLOWED_SEC_TYPES            comma-separated RFB security-type numbers to
                               keep, in the server's original order (default "2")
"""
from __future__ import annotations

import asyncio
import os
import sys
import time

LISTEN_HOST = os.environ.get("LISTEN_HOST", "0.0.0.0")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "5901"))
BACKEND_HOST = os.environ.get("BACKEND_HOST", "127.0.0.1")
BACKEND_PORT = int(os.environ.get("BACKEND_PORT", "5900"))
ALLOWED_SEC_TYPES = {
    int(t) for t in os.environ.get("ALLOWED_SEC_TYPES", "2").split(",") if t.strip()
}


def log(msg: str) -> None:
    print(f"[{time.strftime('%F %T')}][vncfilter] {msg}", flush=True)


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


async def filter_handshake(
    client_reader: asyncio.StreamReader, client_writer: asyncio.StreamWriter,
    backend_reader: asyncio.StreamReader, backend_writer: asyncio.StreamWriter,
    peer,
) -> bool:
    """Relay the RFB version handshake, then filter the security-type list.
    Returns True if the connection should continue to the raw pipe stage."""
    version = await backend_reader.readexactly(12)
    client_writer.write(version)
    await client_writer.drain()

    client_version = await client_reader.readexactly(12)
    backend_writer.write(client_version)
    await backend_writer.drain()

    count = (await backend_reader.readexactly(1))[0]
    if count == 0:
        # Server refused outright (e.g. too many auth failures) — relay the
        # reason string unmodified and let the client display it.
        reason_len_bytes = await backend_reader.readexactly(4)
        reason_len = int.from_bytes(reason_len_bytes, "big")
        reason = await backend_reader.readexactly(reason_len) if reason_len else b""
        client_writer.write(bytes([0]) + reason_len_bytes + reason)
        await client_writer.drain()
        return False

    types = await backend_reader.readexactly(count)
    filtered = bytes(t for t in types if t in ALLOWED_SEC_TYPES)
    if not filtered:
        log(f"no allowed security type in {list(types)} (peer {peer}) — passing through unfiltered")
        filtered = types
    elif filtered != types:
        log(f"filtered security types {list(types)} -> {list(filtered)} for {peer}")

    client_writer.write(bytes([len(filtered)]) + filtered)
    await client_writer.drain()
    return True


async def handle_client(client_reader: asyncio.StreamReader, client_writer: asyncio.StreamWriter) -> None:
    peer = client_writer.get_extra_info("peername")
    try:
        backend_reader, backend_writer = await asyncio.wait_for(
            asyncio.open_connection(BACKEND_HOST, BACKEND_PORT), timeout=5
        )
    except Exception as exc:
        log(f"backend connect failed from {peer}: {exc}")
        try:
            client_writer.close()
        except Exception:
            pass
        return

    try:
        proceed = await filter_handshake(client_reader, client_writer, backend_reader, backend_writer, peer)
    except (asyncio.IncompleteReadError, ConnectionError, OSError) as exc:
        log(f"handshake filter failed for {peer}: {exc}")
        proceed = False
    except Exception as exc:
        log(f"unexpected error filtering handshake for {peer}: {exc}")
        proceed = False

    if not proceed:
        for w in (client_writer, backend_writer):
            try:
                w.close()
            except Exception:
                pass
        return

    await asyncio.gather(
        pipe(client_reader, backend_writer),
        pipe(backend_reader, client_writer),
        return_exceptions=True,
    )


async def main() -> None:
    server = await asyncio.start_server(handle_client, LISTEN_HOST, LISTEN_PORT)
    addrs = ", ".join(str(s.getsockname()) for s in server.sockets or [])
    log(f"listening on {addrs} -> {BACKEND_HOST}:{BACKEND_PORT}, allowed sec types {sorted(ALLOWED_SEC_TYPES)}")
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(0)
