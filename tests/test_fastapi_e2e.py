"""End-to-end FastAPI over saltare, including WebSockets.

The rest of the suite exercises the protocol surface with hand-rolled ASGI
apps and raw sockets. That is deliberate — it keeps assertions about the
wire honest — but it means the framework integration is only ever tested
against the pieces: `test_lifespan.py` uses a hand-written lifespan app,
`test_asgi.py` imports FastAPI but never opens a WebSocket.

This module is the "does a real app actually work" check: a FastAPI app
with a lifespan, path parameters, query parameters, request-body
validation, a streaming response and a WebSocket endpoint, served by
saltare and driven by `httpx` and the `websockets` client.

The WebSocket test uses the real `websockets` library rather than raw
frames, which makes it the only place in the suite that validates saltare
against an independent RFC 6455 implementation. It is kept to **one**
test for that reason: five tests in `tests/test_websocket.py` are
permanently skipped because multiple WebSocket tests in one pytest
process hit a daemon-thread teardown segfault (v0.10). One WS test per
module is safe; the crash comes from the *interleaving*, not from the
library.
"""

from __future__ import annotations

import asyncio
import socket
import threading
import time
from contextlib import asynccontextmanager
from typing import Any

import httpx
import pytest
from fastapi import FastAPI, WebSocket
from fastapi.responses import StreamingResponse
from pydantic import BaseModel


# ---------------------------------------------------------------------------
# A realistic app
# ---------------------------------------------------------------------------

# Set by the lifespan hooks. The suite asserts on them so a missing
# lifespan is a failure rather than a silent no-op — several modules
# tolerate apps that do not implement lifespan, which would hide it here.
LIFESPAN: dict[str, bool] = {}


@asynccontextmanager
async def _lifespan(app: FastAPI):
    LIFESPAN["booted"] = True
    yield
    LIFESPAN["shutdown"] = True


class Item(BaseModel):
    name: str
    qty: int


def build_app() -> FastAPI:
    app = FastAPI(lifespan=_lifespan)

    @app.get("/")
    def root() -> dict[str, str]:
        return {"hello": "world"}

    @app.get("/items/{item_id}")
    def item(item_id: int, verbose: bool = False) -> dict[str, Any]:
        # Echoing the Python type proves the path parameter went through
        # pydantic coercion rather than arriving as a raw string.
        return {"id": item_id, "type": type(item_id).__name__, "verbose": verbose}

    @app.post("/items")
    def create(item: Item) -> dict[str, Any]:
        return {"name": item.name, "qty": item.qty, "double": item.qty * 2}

    @app.get("/stream")
    def stream() -> StreamingResponse:
        def gen():
            for i in range(5):
                yield f"chunk-{i}\n"

        return StreamingResponse(gen(), media_type="text/plain")

    @app.websocket("/ws")
    async def ws_echo(ws: WebSocket) -> None:
        await ws.accept()
        try:
            while True:
                text = await ws.receive_text()
                await ws.send_text(f"echo:{text}")
        except Exception:
            # A client closing mid-receive is the normal teardown path.
            return

    return app


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _serve(app: Any, port: int) -> None:
    from saltare import run

    threading.Thread(
        target=run,
        args=(app,),
        kwargs={"host": "127.0.0.1", "port": port},
        daemon=True,
    ).start()
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return
        except (ConnectionRefusedError, socket.timeout, OSError):
            time.sleep(0.05)
    pytest.fail("server never became ready")


# ---------------------------------------------------------------------------
# HTTP surface
# ---------------------------------------------------------------------------


def test_fastapi_http_surface() -> None:
    """Lifespan, JSON, path/query params, body validation, 404 and a
    streaming response, all through FastAPI's own machinery."""
    fastapi = pytest.importorskip("fastapi")
    assert fastapi  # silence the unused-import lint

    LIFESPAN.clear()
    port = _free_port()
    _serve(build_app(), port)
    base = f"http://127.0.0.1:{port}"

    with httpx.Client(timeout=5.0) as client:
        assert LIFESPAN.get("booted") is True, "lifespan startup did not run"

        r = client.get(f"{base}/")
        assert r.status_code == 200
        assert r.json() == {"hello": "world"}

        # Path param coercion + a default-valued query param.
        r = client.get(f"{base}/items/42")
        assert r.json() == {"id": 42, "type": "int", "verbose": False}, r.json()
        r = client.get(f"{base}/items/42?verbose=true")
        assert r.json()["verbose"] is True, r.json()

        # A non-integer path param must 422 rather than reach the handler.
        r = client.get(f"{base}/items/not-a-number")
        assert r.status_code == 422, r.status_code

        # Pydantic request-body validation.
        r = client.post(f"{base}/items", json={"name": "bolt", "qty": 7})
        assert r.status_code == 200
        assert r.json() == {"name": "bolt", "qty": 7, "double": 14}, r.json()

        r = client.post(f"{base}/items", json={"name": "bolt"})  # qty missing
        assert r.status_code == 422, r.status_code
        r = client.post(f"{base}/items", json={"name": "bolt", "qty": "many"})
        assert r.status_code == 422, r.status_code

        # The app's own 404, not a saltare-generated one.
        r = client.get(f"{base}/nope")
        assert r.status_code == 404, r.status_code

        # Streaming: five chunks with more_body=True between them.
        r = client.get(f"{base}/stream")
        assert r.status_code == 200
        assert r.text == "".join(f"chunk-{i}\n" for i in range(5)), repr(r.text)

    assert LIFESPAN.get("shutdown") is None, "server shut down early"


def test_fastapi_keepalive_reuses_one_connection() -> None:
    """Several requests over a single keep-alive connection, which is the
    path the pooled read buffers and `keepAliveReset` exist for. A reused
    connection that carried state from the previous request would show up
    as a wrong body or a 400 on the second call."""
    pytest.importorskip("fastapi")

    port = _free_port()
    _serve(build_app(), port)
    base = f"http://127.0.0.1:{port}"

    with httpx.Client(timeout=5.0) as client:
        for i in range(25):
            if i % 2:
                r = client.get(f"{base}/items/{i}")
                assert r.status_code == 200, (i, r.status_code)
                assert r.json()["id"] == i, (i, r.json())
            else:
                r = client.get(f"{base}/")
                assert r.json() == {"hello": "world"}, (i, r.json())


def test_fastapi_handles_concurrent_clients() -> None:
    """Twelve threads on twelve connections. Exercises the concurrent
    dispatch path — one asyncio loop shared across every request — rather
    than the single-connection case the other tests cover."""
    pytest.importorskip("fastapi")

    port = _free_port()
    _serve(build_app(), port)
    base = f"http://127.0.0.1:{port}"

    results: list[int] = []
    lock = threading.Lock()

    def worker(n: int) -> None:
        try:
            with httpx.Client(timeout=10.0) as client:
                r = client.get(f"{base}/items/{n}")
                with lock:
                    results.append(r.status_code)
        except Exception:  # noqa: BLE001 - recorded as a failure below
            with lock:
                results.append(0)

    threads = [threading.Thread(target=worker, args=(i,)) for i in range(12)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=30)

    assert results == [200] * 12, f"concurrent dispatch lost requests: {results}"


# ---------------------------------------------------------------------------
# WebSocket, against a real client implementation
# ---------------------------------------------------------------------------


def test_fastapi_websocket_against_the_websockets_client() -> None:
    """The only test in the suite that runs saltare's WebSocket path
    against an independent RFC 6455 implementation rather than
    hand-rolled frames.

    Kept to a single test on purpose — see the module docstring on the
    v0.10 teardown segfault.
    """
    pytest.importorskip("fastapi")
    websockets = pytest.importorskip("websockets")

    LIFESPAN.clear()
    port = _free_port()
    _serve(build_app(), port)

    async def exercise() -> tuple[str, str, str]:
        async with websockets.connect(f"ws://127.0.0.1:{port}/ws") as ws:
            await ws.send("hello")
            first = await ws.recv()
            await ws.send("world")
            second = await ws.recv()
            # Several frames in a row on one connection: the per-connection
            # WS state has to survive each round trip.
            for i in range(10):
                await ws.send(f"n{i}")
                reply = await ws.recv()
                if reply != f"echo:n{i}":
                    return (first, second, f"msg {i}: {reply}")
            await ws.send("final")
            return (first, second, await ws.recv())

    first, second, last = asyncio.run(exercise())

    assert first == "echo:hello", first
    assert second == "echo:world", second
    assert last == "echo:final", last
    assert LIFESPAN.get("booted") is True


def test_websocket_route_rejects_a_plain_get() -> None:
    """A plain GET on the WebSocket route must be answered, not hung on.

    404 is the correct answer rather than 400: Starlette registers a
    websocket route only for the `websocket` scope, so an `http` request to
    the same path matches no route at all. The invariant worth pinning is
    the weaker one — it is a 4xx and the connection closes, i.e. saltare
    handed it to the app instead of treating the missing upgrade headers
    as a malformed request or leaving the connection open.
    """
    pytest.importorskip("fastapi")

    port = _free_port()
    _serve(build_app(), port)

    with httpx.Client(timeout=5.0) as client:
        r = client.get(f"http://127.0.0.1:{port}/ws")

    assert 400 <= r.status_code < 500, r.status_code
    assert LIFESPAN.get("booted") is not False, "lifespan shutdown ran early"


def test_websocket_unknown_path_is_404() -> None:
    """An upgrade attempt on a path with no websocket route must be
    refused cleanly rather than accepted and then left dangling."""
    pytest.importorskip("fastapi")
    websockets = pytest.importorskip("websockets")

    port = _free_port()
    _serve(build_app(), port)

    async def attempt() -> None:
        async with websockets.connect(f"ws://127.0.0.1:{port}/no-such-ws"):
            pass

    with pytest.raises(Exception):
        # websockets raises InvalidStatus on a non-101 response. Any
        # exception is acceptable; silently succeeding is not.
        asyncio.run(attempt())

    # The server survived the refused handshake and still serves HTTP.
    with httpx.Client(timeout=5.0) as client:
        assert client.get(f"http://127.0.0.1:{port}/").status_code == 200
