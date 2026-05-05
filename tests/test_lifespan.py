"""ASGI lifespan protocol behaviour."""

from __future__ import annotations

import socket
import threading
import time
from contextlib import asynccontextmanager
from typing import Any

import httpx
import pytest


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


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


def test_fastapi_lifespan_startup_runs() -> None:
    """FastAPI's `lifespan=` async context manager has its `before yield` body
    executed before the server starts handling HTTP requests."""
    fastapi = pytest.importorskip("fastapi")

    startup_done = threading.Event()

    @asynccontextmanager
    async def lifespan(app):
        startup_done.set()
        yield

    app = fastapi.FastAPI(lifespan=lifespan)

    @app.get("/")
    def root():
        return {"ok": True}

    port = _free_port()
    _serve_in_background(app, port)

    # Server is "ready" only after lifespan startup has completed — saltare
    # blocks the I/O loop start until then. So when we can connect, startup
    # must already have run.
    assert startup_done.is_set(), "lifespan startup did not run before serving"

    response = httpx.get(f"http://127.0.0.1:{port}/", timeout=2.0)
    assert response.status_code == 200


def test_app_without_lifespan_still_serves() -> None:
    """An ASGI app that explicitly raises NotImplementedError on lifespan
    scope must still be able to serve HTTP requests."""

    async def bare_app(scope, receive, send):
        if scope["type"] == "lifespan":
            raise NotImplementedError("this app doesn't support lifespan")

        await receive()
        await send({
            "type": "http.response.start",
            "status": 200,
            "headers": [(b"content-type", b"text/plain")],
        })
        await send({"type": "http.response.body", "body": b"bare ok\n"})

    port = _free_port()
    _serve_in_background(bare_app, port)

    response = httpx.get(f"http://127.0.0.1:{port}/", timeout=2.0)
    assert response.status_code == 200
    assert response.content == b"bare ok\n"


def test_lifespan_startup_failed_raises() -> None:
    """If the app explicitly responds with `lifespan.startup.failed`, saltare
    should raise rather than silently serving with a half-initialised app."""

    async def failing_app(scope, receive, send):
        if scope["type"] != "lifespan":
            return
        msg = await receive()
        assert msg["type"] == "lifespan.startup"
        await send({
            "type": "lifespan.startup.failed",
            "message": "could not connect to upstream",
        })

    from saltare import run

    port = _free_port()
    error: list[BaseException] = []

    def runner():
        try:
            run(failing_app, host="127.0.0.1", port=port)
        except BaseException as exc:
            error.append(exc)

    t = threading.Thread(target=runner, daemon=True)
    t.start()
    t.join(timeout=5.0)

    assert error, "expected serve() to raise on lifespan.startup.failed"
    assert isinstance(error[0], RuntimeError)
    assert "lifespan startup failed" in str(error[0]).lower()
