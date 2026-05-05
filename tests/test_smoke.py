"""Smoke tests: verify the native extension is built and the parser works."""

from __future__ import annotations

import socket
import threading
import time

import httpx
import pytest


def test_version_string() -> None:
    import saltare

    assert isinstance(saltare.__version__, str)
    assert saltare.__version__.count(".") >= 1


def test_core_exports() -> None:
    from saltare import _core

    assert callable(_core.version)
    assert callable(_core.serve)
    assert _core.version() == "0.2.0"


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _serve_in_background(port: int) -> None:
    from saltare import _core

    thread = threading.Thread(
        target=_core.serve, args=("127.0.0.1", port), daemon=True
    )
    thread.start()
    deadline = time.monotonic() + 2.0
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return
        except (ConnectionRefusedError, socket.timeout):
            time.sleep(0.05)
    pytest.fail("server never became ready")


def test_get_echoes_method_and_target() -> None:
    port = _free_port()
    _serve_in_background(port)

    response = httpx.get(f"http://127.0.0.1:{port}/some/path", timeout=1.0)

    assert response.status_code == 200
    assert response.headers["server"] == "saltare/0.2.0"
    assert b"saltare parsed: GET /some/path HTTP/1.1" in response.content


def test_query_string_is_preserved_in_target() -> None:
    port = _free_port()
    _serve_in_background(port)

    response = httpx.get(f"http://127.0.0.1:{port}/search?q=hello&n=3", timeout=1.0)

    assert response.status_code == 200
    assert b"GET /search?q=hello&n=3" in response.content


def test_post_with_body_is_parsed() -> None:
    port = _free_port()
    _serve_in_background(port)

    response = httpx.post(
        f"http://127.0.0.1:{port}/items",
        content=b"payload",
        timeout=1.0,
    )

    assert response.status_code == 200
    assert b"POST /items" in response.content


def test_malformed_request_gets_400() -> None:
    port = _free_port()
    _serve_in_background(port)

    # Send something that's not a valid HTTP request.
    with socket.create_connection(("127.0.0.1", port)) as s:
        s.sendall(b"NOT-AN-HTTP-REQUEST\r\n\r\n")
        data = s.recv(4096)

    assert data.startswith(b"HTTP/1.1 400 ")
