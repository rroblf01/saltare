"""Protocol-level smoke tests using a minimal ASGI echo app."""

from __future__ import annotations

import socket
import threading
import time
from typing import Any

import httpx
import pytest


async def echo_app(scope: dict, receive, send) -> None:
    """Minimal ASGI app that echoes method + raw_path[?query] in the body."""
    assert scope["type"] == "http"
    await receive()  # consume the request body event

    method: str = scope["method"]
    target: bytes = scope["raw_path"]
    if scope["query_string"]:
        target = target + b"?" + scope["query_string"]
    body = b"saltare parsed: " + method.encode("ascii") + b" " + target + b"\n"

    await send({
        "type": "http.response.start",
        "status": 200,
        "headers": [(b"content-type", b"text/plain; charset=utf-8")],
    })
    await send({"type": "http.response.body", "body": body})


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


def test_version_string() -> None:
    import saltare

    assert saltare.__version__ == "0.10.0"


def test_core_exports() -> None:
    from saltare import _core

    assert callable(_core.version)
    assert callable(_core.serve)
    assert _core.version() == "0.10.0"


def test_get_dispatches_to_app() -> None:
    port = _free_port()
    _serve_in_background(echo_app, port)
    response = httpx.get(f"http://127.0.0.1:{port}/some/path", timeout=2.0)
    assert response.status_code == 200
    assert b"saltare parsed: GET /some/path" in response.content


def test_query_string_reaches_app() -> None:
    port = _free_port()
    _serve_in_background(echo_app, port)
    response = httpx.get(f"http://127.0.0.1:{port}/search?q=hello&n=3", timeout=2.0)
    assert response.status_code == 200
    assert b"GET /search?q=hello&n=3" in response.content


def test_post_body_reaches_app() -> None:
    port = _free_port()
    _serve_in_background(echo_app, port)
    response = httpx.post(
        f"http://127.0.0.1:{port}/items",
        content=b"payload",
        timeout=2.0,
    )
    assert response.status_code == 200
    assert b"POST /items" in response.content


def test_malformed_request_gets_400() -> None:
    port = _free_port()
    _serve_in_background(echo_app, port)
    with socket.create_connection(("127.0.0.1", port)) as s:
        s.sendall(b"NOT-AN-HTTP-REQUEST\r\n\r\n")
        data = s.recv(4096)
    assert data.startswith(b"HTTP/1.1 400 ")
