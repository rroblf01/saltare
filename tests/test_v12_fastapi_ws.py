"""FastAPI + WebSocket coverage through Starlette's own abstraction.

Every other WebSocket test drives saltare against a hand-written ASGI
app. That proves the wire protocol but skips the layer where real
applications live: Starlette's `WebSocket` owns the state machine, the
`receive_*` / `send_*` helpers, `WebSocketDisconnect` and the
`query_params` / `headers` properties, and FastAPI's dependency
resolution. A handler written against a raw ASGI app can be perfect
while the same handler written against Starlette fails — and the earlier
1009 work was only ever verified on the raw side, so nothing here
existed to catch it.

Covers, one behaviour per test:

  - the three payload types, which travel through different ASGI message
    keys and can each be dropped without the others noticing
  - `query_params` and handshake headers, i.e. the scope saltare builds
  - subprotocol negotiation
  - the disconnect code the app observes, for the three cases that
    differ: clean peer close, peer RST, and a message saltare itself
    rejected as too big
  - several concurrent connections, to catch per-connection state
    bleeding across sockets
  - a fragmented message large enough to cross the pool-buffer boundary

Deliberately no `from __future__ import annotations`: it would turn the
handlers' `ws: WebSocket` annotations into strings that FastAPI resolves
against module globals, and a name imported inside a test function is not
visible there — the handshake then fails with a bare 403 before the
handler runs. That cost a debugging round once already.

The oversized-message case builds its frame by hand because the
`websockets` client fragments large sends on its own, so it cannot
produce the single unfragmented frame the 1009 path is about.
"""

import asyncio
import json
import socket
import struct
import threading
import time
import uuid

import pytest

fastapi = pytest.importorskip("fastapi")
pytest.importorskip("websockets")

import websockets
from fastapi import FastAPI, WebSocket
from starlette.websockets import WebSocketDisconnect

_TIMING_FACTOR = 2.0

# Per-test record of what a handler observed. Module-level because the
# handler runs on saltare's event-loop thread and the assertions run on
# the test's; a plain dict is the simplest thing that crosses safely
# enough for this (single writer, read after the connection is done).
SEEN: dict = {}


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _serve(app, port: int) -> None:
    from saltare import run

    threading.Thread(
        target=run,
        args=(app,),
        kwargs={"host": "127.0.0.1", "port": port},
        daemon=True,
    ).start()
    deadline = time.monotonic() + 3.0 * _TIMING_FACTOR
    while time.monotonic() < deadline:
        try:
            with socket.socket() as s:
                s.settimeout(0.2)
                s.connect(("127.0.0.1", port))
                return
        except (ConnectionRefusedError, socket.timeout, OSError):
            time.sleep(0.05)
    pytest.fail(f"server never came up on 127.0.0.1:{port}")


def _connect(port: int, path: str = "/ws", **kw):
    return websockets.connect(f"ws://127.0.0.1:{port}{path}", **kw)


# ---------------------------------------------------------------------------
# Payload types
# ---------------------------------------------------------------------------


def _payload_app() -> FastAPI:
    app = FastAPI()

    @app.websocket("/ws")
    async def ws_echo(ws: WebSocket) -> None:
        await ws.accept()
        while True:
            message = await ws.receive()
            if message["type"] == "websocket.disconnect":
                return
            if message.get("text") is not None:
                await ws.send_text(f"text:{message['text']}")
            elif message.get("bytes") is not None:
                await ws.send_bytes(b"bytes:" + message["bytes"])

    return app


def test_text_messages_round_trip() -> None:
    port = _free_port()
    _serve(_payload_app(), port)
    received = []

    async def exercise() -> None:
        async with _connect(port) as ws:
            for value in ["", "hello", "acentuación ñ", "x" * 5000]:
                await ws.send(value)
                reply = await ws.recv()
                assert isinstance(reply, str), f"got {type(reply)}"
                received.append(reply)

    _run(exercise())
    assert received == [f"text:{v}" for v in ["", "hello", "acentuación ñ", "x" * 5000]]


def test_binary_messages_round_trip() -> None:
    """Separate from the text case on purpose: `text` and `bytes` are
    different ASGI keys, and only one can be dropped unnoticed."""
    port = _free_port()
    _serve(_payload_app(), port)
    payloads = [b"", b"\x00", b"\xff\xfe\xfd", bytes(range(256))]

    async def exercise() -> None:
        async with _connect(port) as ws:
            for payload in payloads:
                await ws.send(payload)
                reply = await ws.recv()
                assert isinstance(reply, bytes), f"got {type(reply)}"
                assert reply == b"bytes:" + payload

    _run(exercise())


def test_json_messages_round_trip() -> None:
    port = _free_port()
    _serve(_payload_app(), port)

    async def exercise() -> None:
        async with _connect(port) as ws:
            await ws.send('{"n": 1, "s": "hola"}')
            assert await ws.recv() == 'text:{"n": 1, "s": "hola"}'

    _run(exercise())


# ---------------------------------------------------------------------------
# Handshake surface
# ---------------------------------------------------------------------------


def test_query_params_and_headers_reach_the_handler() -> None:
    """Proves the ASGI scope saltare builds carries the handshake
    request line's query and headers, not just the path."""
    app = FastAPI()

    @app.websocket("/ws")
    async def ws_scope(ws: WebSocket) -> None:
        await ws.accept()
        await ws.send_json(
            {
                "room": ws.query_params.get("room"),
                "absent": ws.query_params.get("nope"),
                "agent": ws.headers.get("user-agent"),
                "custom": ws.headers.get("x-probe"),
                "path": ws.scope["path"],
            }
        )
        await ws.close()

    port = _free_port()
    _serve(app, port)

    async def exercise() -> dict:
        async with _connect(
            port, "/ws?room=lab&extra=ignored",
            additional_headers={"X-Probe": "probe-value"},
        ) as ws:
            return json.loads(await ws.recv())

    got = _run(exercise())
    assert got["room"] == "lab"
    assert got["absent"] is None, "a missing param must not be invented"
    assert got["custom"] == "probe-value"
    assert got["agent"], "user-agent must be forwarded"
    assert got["path"] == "/ws"


def test_subprotocol_is_negotiated() -> None:
    """Asserted from the client side: the handler picks one of the
    offered subprotocols and the handshake response has to carry it
    back, which is the part that can silently break."""
    app = FastAPI()

    @app.websocket("/ws")
    async def ws_sub(ws: WebSocket) -> None:
        # "chat.v1" is offered first by the client but the server is
        # allowed to choose either; picking the second proves the
        # response is the server's choice and not just an echo.
        await ws.accept(subprotocol="chat.v2")
        await ws.send_text("ready")
        await ws.close()

    port = _free_port()
    _serve(app, port)

    async def exercise() -> tuple:
        async with _connect(port, subprotocols=["chat.v1", "chat.v2"]) as ws:
            assert await ws.recv() == "ready"
            return ws.subprotocol

    assert _run(exercise()) == "chat.v2"


# ---------------------------------------------------------------------------
# Disconnect codes
# ---------------------------------------------------------------------------


def _code_app() -> FastAPI:
    """Records the code the app observes when the socket ends.

    Uses `receive()` rather than `receive_text()` on purpose: the raw
    disconnect message is what saltare actually delivers, and asserting
    on it avoids Starlette's `receive_text()` masking the code as a
    KeyError when there is no text to decode.
    """
    app = FastAPI()

    @app.websocket("/ws")
    async def ws_code(ws: WebSocket) -> None:
        await ws.accept()
        while True:
            message = await ws.receive()
            if message["type"] == "websocket.disconnect":
                SEEN["code"] = message.get("code")
                return

    return app


def _handshake(port: int, path: str = "/ws") -> socket.socket:
    s = socket.create_connection(("127.0.0.1", port), 3.0 * _TIMING_FACTOR)
    s.settimeout(3.0 * _TIMING_FACTOR)
    s.sendall(
        f"GET {path} HTTP/1.1\r\n"
        f"Host: 127.0.0.1:{port}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        "\r\n".encode()
    )
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = s.recv(4096)
        if not chunk:
            break
        buf += chunk
    assert b" 101 " in buf.split(b"\r\n")[0], buf[:120]
    return s


def test_clean_close_reports_1000() -> None:
    port = _free_port()
    _serve(_code_app(), port)

    async def exercise() -> None:
        async with _connect(port) as ws:
            await ws.send("hi")

    _run(exercise())
    time.sleep(0.2 * _TIMING_FACTOR)
    assert SEEN.get("code") == 1000


def test_peer_reset_reports_1006() -> None:
    """A hard RST, with no close frame from either side. saltare never
    sent a close, so 1006 is the honest answer — this is the case the
    recorded-close-code change must not paper over."""
    port = _free_port()
    _serve(_code_app(), port)
    s = _handshake(port)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
    s.close()
    time.sleep(0.4 * _TIMING_FACTOR)
    assert SEEN.get("code") == 1006


def test_oversized_message_reports_1009_to_both_ends() -> None:
    """A single unfragmented frame past the pool-buffer ceiling.

    The client must see 1009 (RFC 6455 §7.4.1, "message too big") and
    the app must see the same code rather than a generic 1006 — the app
    is the side that logs and cleans up, and "abnormal closure" is
    indistinguishable there from a dead network.
    """
    port = _free_port()
    _serve(_code_app(), port)
    s = _handshake(port)
    try:
        s.sendall(_masked_frame(0x1, b"a" * 100_000))
        response = b""
        while True:
            chunk = s.recv(65536)
            if not chunk:
                break
            response += chunk
            if response and (response[0] & 0x0F) == 0x8:
                break
    finally:
        s.close()

    assert response, "server closed without a close frame"
    assert response[0] & 0x0F == 0x8, f"expected close, got opcode {response[0] & 0x0F}"
    assert struct.unpack(">H", response[2:4])[0] == 1009
    time.sleep(0.3 * _TIMING_FACTOR)
    assert SEEN.get("code") == 1009


# ---------------------------------------------------------------------------
# Concurrency
# ---------------------------------------------------------------------------


def test_concurrent_connections_do_not_share_state() -> None:
    """Each connection echoes a token derived from its own path segment,
    so any cross-connection state leak shows up as a wrong token rather
    than as a lost message."""
    app = FastAPI()

    @app.websocket("/ws/{token}")
    async def ws_token(ws: WebSocket) -> None:
        await ws.accept()
        token = ws.path_params["token"]
        while True:
            message = await ws.receive()
            if message["type"] == "websocket.disconnect":
                return
            await ws.send_text(f"{token}:{message['text']}")

    port = _free_port()
    _serve(app, port)
    tokens = [uuid.uuid4().hex[:8] for _ in range(8)]

    async def one(token: str) -> None:
        async with _connect(port, f"/ws/{token}") as ws:
            for i in range(5):
                await ws.send(str(i))
                assert await ws.recv() == f"{token}:{i}"

    async def exercise() -> None:
        await asyncio.gather(*(one(t) for t in tokens))

    _run(exercise())


# ---------------------------------------------------------------------------
# Fragmentation across the pool-buffer boundary
# ---------------------------------------------------------------------------


def test_fragmented_message_crossing_the_buffer_boundary() -> None:
    """Fragments that each fit the small buffer but together exceed it,
    so reassembly has to grow past the pool buffer and hand the app one
    complete message. This is the path that used to double-free."""
    port = _free_port()
    _serve(_payload_app(), port)
    fragment = b"z" * 3000
    count = 8  # 24 KB total, each fragment 3 KB
    lengths = []

    async def exercise() -> None:
        async with _connect(port) as ws:
            await ws.send([fragment] * count)
            reply = await ws.recv()
            assert isinstance(reply, bytes), f"got {type(reply)}"
            lengths.append(len(reply))

    _run(exercise())
    assert lengths == [len(b"bytes:") + len(fragment) * count]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _run(coro):
    """Own event loop per test, so no loop outlives its connections."""
    return asyncio.new_event_loop().run_until_complete(coro)


def _masked_frame(opcode: int, payload: bytes, fin: bool = True) -> bytes:
    """A single client→server frame, masked as RFC 6455 §5.3 requires."""
    key = b"\x37\xfa\x21\x3d"
    b0 = (0x80 if fin else 0) | opcode
    n = len(payload)
    if n < 126:
        header = struct.pack("!BB", b0, 0x80 | n)
    elif n < 65536:
        header = struct.pack("!BBH", b0, 0x80 | 126, n)
    else:
        header = struct.pack("!BBQ", b0, 0x80 | 127, n)
    masked = bytes(payload[i] ^ key[i % 4] for i in range(n))
    return header + masked
