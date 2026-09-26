"""WebSocket support — handshake, echo, close, FastAPI integration.

The last four tests here were `pass` stubs skipped since v0.10, on the
theory that several WebSocket tests in one pytest process crash during
teardown — "one daemon thread shutting down a WebSocket while another is
starting up". They are enabled again as of v1.12 because the crash no
longer reproduces.

Two later changes plausibly account for it, and both postdate the
original report. The autouse `_saltare_thread_cleanup` fixture in
`conftest.py` (v1.6) drains each server and waits for its thread between
tests, which is exactly the overlap the crash needed; and `destroy()`
(v1.7.1) centralised WebSocket teardown, so the WS-CLOSE log, the
`wsDisconnect` callback and the list unlink happen in one place on one
path instead of being spread across callers.

That is a hypothesis about the history, not a verified root cause — the
original stack trace was never recorded in the repo. What *is* verified
is the behaviour: this module now runs five WebSocket tests in one
process, alongside the rest of the suite, without crashing. If a
regression ever brings it back, re-adding the skips is cheaper than
re-deriving this.
"""

from __future__ import annotations

import asyncio
import socket
import threading
import time
from typing import Any

import pytest

websockets = pytest.importorskip("websockets")

# Imported at module scope, deliberately. This file uses
# `from __future__ import annotations`, so a handler's annotations reach
# FastAPI as *strings* and are resolved against the function's module
# globals. A function-local `from fastapi import WebSocket` leaves that
# name unresolvable, FastAPI stops recognising the parameter as the
# WebSocket itself, and it fails the handshake with a
# `WebSocketRequestValidationError` (surfacing as a bare 403) before the
# handler body ever runs. Guarded rather than importorskip'd, because the
# raw-ASGI tests below must stay runnable without FastAPI installed.
try:
    from fastapi import FastAPI, WebSocket
except ImportError:  # pragma: no cover - exercised only without fastapi
    FastAPI = None  # type: ignore[assignment]
    WebSocket = None  # type: ignore[assignment]


async def echo_ws_app(scope: dict, receive, send) -> None:
    if scope["type"] == "lifespan":
        while True:
            msg = await receive()
            if msg["type"] == "lifespan.startup":
                await send({"type": "lifespan.startup.complete"})
            elif msg["type"] == "lifespan.shutdown":
                await send({"type": "lifespan.shutdown.complete"})
                return

    assert scope["type"] == "websocket"
    msg = await receive()
    assert msg["type"] == "websocket.connect"
    await send({"type": "websocket.accept"})

    while True:
        msg = await receive()
        if msg["type"] == "websocket.disconnect":
            return
        if "text" in msg and msg["text"] is not None:
            await send({"type": "websocket.send", "text": msg["text"]})
        elif "bytes" in msg and msg["bytes"] is not None:
            await send({"type": "websocket.send", "bytes": msg["bytes"]})


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


async def _lifespan_pump(receive, send) -> None:
    """Answers lifespan startup/shutdown until shutdown arrives.

    Shared by the small apps defined next to individual tests, so each
    one only has to spell out the WebSocket half of its behaviour.
    """
    while True:
        msg = await receive()
        if msg["type"] == "lifespan.startup":
            await send({"type": "lifespan.startup.complete"})
        elif msg["type"] == "lifespan.shutdown":
            await send({"type": "lifespan.shutdown.complete"})
            return


def _serve_in_background(app: Any, port: int) -> None:
    from saltare import run

    threading.Thread(
        target=run,
        args=(app,),
        kwargs={"host": "127.0.0.1", "port": port},
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


def _run_ws(coro):
    return asyncio.new_event_loop().run_until_complete(coro)


def test_websocket_text_echo() -> None:
    """End-to-end WS smoke test: handshake, two text echoes, clean close."""
    port = _free_port()
    _serve_in_background(echo_ws_app, port)

    async def client():
        async with websockets.connect(f"ws://127.0.0.1:{port}/echo") as ws:
            await ws.send("hello")
            assert await ws.recv() == "hello"
            await ws.send("again")
            assert await ws.recv() == "again"

    _run_ws(client())


def test_websocket_binary_echo() -> None:
    """Binary frames must round-trip byte-for-byte.

    A dedicated test rather than an extension of the text echo: the two
    travel through different ASGI message keys (`text` vs `bytes`), and
    only one of them can be silently dropped without the other noticing.
    """
    port = _free_port()
    _serve_in_background(echo_ws_app, port)

    payloads = [b"", b"\x00", b"\xff\xfe\xfd", bytes(range(256))]

    async def client():
        async with websockets.connect(f"ws://127.0.0.1:{port}/echo") as ws:
            for payload in payloads:
                await ws.send(payload)
                got = await ws.recv()
                assert isinstance(got, bytes), f"text frame for {payload!r}"
                assert got == payload

    _run_ws(client())


def test_websocket_clean_close() -> None:
    """The close handshake completes with 1000 rather than being cut.

    The raw ASGI app returns on `websocket.disconnect`, so the server
    has to send the close frame itself for the client to see a
    negotiated end. A missing one shows up here as a 1006 (abnormal
    closure), which is the client-side symptom of a reset.
    """
    port = _free_port()
    _serve_in_background(echo_ws_app, port)
    seen: list[int | None] = []

    async def client():
        async with websockets.connect(f"ws://127.0.0.1:{port}/echo") as ws:
            await ws.send("hi")
            assert await ws.recv() == "hi"
        seen.append(ws.close_code)

    _run_ws(client())
    assert seen == [1000], seen


def test_websocket_reject_via_close_before_accept() -> None:
    """An app that closes before accepting gets an HTTP 403, not a 101.

    The ASGI spec requires `websocket.close` before `websocket.accept` to
    be turned into an HTTP rejection. Handing the client a 101 followed
    by an immediate close would be indistinguishable, from the client's
    side, from a server that accepted and then failed.
    """

    async def reject_app(scope: dict, receive, send) -> None:
        if scope["type"] == "lifespan":
            await _lifespan_pump(receive, send)
            return
        assert scope["type"] == "websocket"
        assert (await receive())["type"] == "websocket.connect"
        await send({"type": "websocket.close", "code": 1000})

    port = _free_port()
    _serve_in_background(reject_app, port)

    # Raw first, so the assertion is on the status line rather than on
    # whatever exception the client library chooses to raise.
    with socket.create_connection(("127.0.0.1", port), 3.0) as s:
        s.settimeout(3.0)
        s.sendall(
            f"GET /echo HTTP/1.1\r\n"
            f"Host: 127.0.0.1:{port}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            "\r\n".encode()
        )
        raw = s.recv(4096)
    assert raw.startswith(b"HTTP/1.1 403"), raw[:80]

    # And the client library must see it as a rejected handshake.
    async def client():
        with pytest.raises(websockets.InvalidStatus):
            async with websockets.connect(f"ws://127.0.0.1:{port}/echo"):
                pass

    _run_ws(client())


def test_fastapi_websocket_route() -> None:
    """    The same path through FastAPI's WebSocket abstraction.

    Starlette owns the handshake, the state machine and the disconnect
    exception here, so this exercises saltare's scope against a real
    framework client rather than against a hand-written app.
    """
    if FastAPI is None:
        pytest.skip("fastapi not installed")

    app = FastAPI()


    @app.websocket("/ws")
    async def ws_echo(ws: WebSocket) -> None:
        await ws.accept()
        while True:
            msg = await ws.receive()
            if msg["type"] == "websocket.disconnect":
                return
            if msg.get("text") is not None:
                await ws.send_text(f"echo:{msg['text']}")
            elif msg.get("bytes") is not None:
                await ws.send_bytes(msg["bytes"])

    port = _free_port()
    _serve_in_background(app, port)

    async def client():
        async with websockets.connect(f"ws://127.0.0.1:{port}/ws") as ws:
            await ws.send("hello")
            assert await ws.recv() == "echo:hello"
            await ws.send(b"\x01\x02")
            assert await ws.recv() == b"\x01\x02"

    _run_ws(client())
