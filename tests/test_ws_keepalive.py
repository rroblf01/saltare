"""Server-side WebSocket keepalive (v0.18).

Saltare sends a ping frame every `ws_keepalive_timeout` seconds; if no
inbound frame arrives in 2× that window, the connection is reaped. These
tests use raw sockets (not the `websockets` library) so they bypass the
known multi-test daemon teardown issue that affects test_websocket.py.
"""

from __future__ import annotations

import base64
import hashlib
import os
import socket
import threading
import time
from typing import Any

import pytest


WS_GUID = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


async def echo_ws_app(scope: dict, receive, send) -> None:
    if scope["type"] == "lifespan":
        while True:
            msg = await receive()
            if msg["type"] == "lifespan.startup":
                await send({"type": "lifespan.startup.complete"})
            elif msg["type"] == "lifespan.shutdown":
                await send({"type": "lifespan.shutdown.complete"})
                return
        return
    assert scope["type"] == "websocket"
    msg = await receive()
    assert msg["type"] == "websocket.connect"
    await send({"type": "websocket.accept"})
    # Drain whatever the client sends; only return on disconnect.
    while True:
        msg = await receive()
        if msg["type"] == "websocket.disconnect":
            return


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _serve_in_background(app: Any, port: int, **kwargs) -> None:
    from saltare import run

    threading.Thread(
        target=run,
        args=(app,),
        kwargs={"host": "127.0.0.1", "port": port, **kwargs},
        daemon=True,
    ).start()
    deadline = time.monotonic() + 2.0
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return
        except (ConnectionRefusedError, socket.timeout):
            time.sleep(0.05)
    pytest.fail("server never became ready")


def _do_ws_handshake(sock: socket.socket) -> None:
    """Send a minimal valid RFC 6455 handshake and consume the 101
    response. Caller is left with the socket positioned right at the
    first WS frame from the server."""
    key = base64.b64encode(os.urandom(16)).decode("ascii")
    expected_accept = base64.b64encode(
        hashlib.sha1(key.encode("ascii") + WS_GUID).digest()
    ).decode("ascii")

    request = (
        f"GET /ws HTTP/1.1\r\n"
        f"Host: x\r\n"
        f"Upgrade: websocket\r\n"
        f"Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        f"Sec-WebSocket-Version: 13\r\n"
        f"\r\n"
    ).encode("ascii")
    sock.sendall(request)

    sock.settimeout(2.0)
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = sock.recv(4096)
        if not chunk:
            raise AssertionError("server closed during WS handshake")
        buf += chunk

    head, _, leftover = buf.partition(b"\r\n\r\n")
    assert head.startswith(b"HTTP/1.1 101 "), head
    assert f"Sec-WebSocket-Accept: {expected_accept}".encode("ascii") in head
    assert leftover == b"", "server pre-shipped frames before handshake reply was consumed"


def _read_ws_frame(sock: socket.socket, deadline_seconds: float) -> tuple[int, bytes]:
    """Read a single WS frame off the wire and return (opcode, payload).
    Server frames are unmasked. Times out at `deadline_seconds`."""
    sock.settimeout(deadline_seconds)
    header = sock.recv(2)
    if len(header) < 2:
        raise AssertionError(f"short header read: {header!r}")
    fin_opcode = header[0]
    opcode = fin_opcode & 0x0F
    masked = (header[1] & 0x80) != 0
    length = header[1] & 0x7F
    assert not masked, "server frames must not be masked (RFC 6455)"
    if length == 126:
        length = int.from_bytes(sock.recv(2), "big")
    elif length == 127:
        length = int.from_bytes(sock.recv(8), "big")
    payload = b""
    while len(payload) < length:
        chunk = sock.recv(length - len(payload))
        if not chunk:
            break
        payload += chunk
    return opcode, payload


def test_ws_keepalive_emits_ping_on_idle() -> None:
    """With ws_keepalive_timeout=1 s and an idle WS connection, the server
    must send a ping (opcode 0x9) within ~2 s of the upgrade."""
    port = _free_port()
    _serve_in_background(echo_ws_app, port, ws_keepalive_timeout=1)

    with socket.create_connection(("127.0.0.1", port), timeout=2.0) as sock:
        _do_ws_handshake(sock)
        # Wait long enough for at least one ping (1 s timeout, ~1 s of
        # wheel granularity, plus a little CI slack).
        opcode, payload = _read_ws_frame(sock, deadline_seconds=4.0)
        assert opcode == 0x9, f"expected ping (opcode 0x9), got {opcode:#x}"
        assert payload == b"", f"server pings should be empty-payload, got {payload!r}"


def test_ws_keepalive_closes_silent_client() -> None:
    """A client that never sends any frame (not even a pong) gets reaped
    after 2× the keepalive interval."""
    port = _free_port()
    _serve_in_background(echo_ws_app, port, ws_keepalive_timeout=1)

    with socket.create_connection(("127.0.0.1", port), timeout=2.0) as sock:
        _do_ws_handshake(sock)
        # The server will send 2-3 pings before timing us out (~3-4 s
        # total). We discard everything we read until the socket closes.
        sock.settimeout(6.0)
        closed = False
        deadline = time.monotonic() + 5.0
        while time.monotonic() < deadline:
            try:
                data = sock.recv(4096)
                if not data:
                    closed = True
                    break
            except (ConnectionResetError, BrokenPipeError):
                closed = True
                break
            except socket.timeout:
                break
        assert closed, "server didn't reap the silent WS connection in time"
