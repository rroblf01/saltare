"""Streaming response bodies (v0.12).

Apps that emit `more_body=True` ASGI body chunks now stream through the
bridge instead of being buffered in Python. When the app does not declare
a Content-Length, saltare adds Transfer-Encoding: chunked automatically.
"""

from __future__ import annotations

import socket
import threading
import time
from typing import Any

import httpx
import pytest


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _serve_in_background(app: Any, port: int, **kwargs: int) -> None:
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


def test_streaming_response_auto_chunked() -> None:
    """App sends headers without Content-Length, then multiple body chunks
    with more_body=True. Server should switch to Transfer-Encoding: chunked
    automatically."""

    async def streaming_app(scope, receive, send):
        assert scope["type"] == "http"
        await receive()
        await send({
            "type": "http.response.start",
            "status": 200,
            "headers": [(b"content-type", b"text/plain")],
        })
        for i in range(5):
            await send({
                "type": "http.response.body",
                "body": f"chunk-{i};".encode("ascii"),
                "more_body": True,
            })
        await send({"type": "http.response.body", "body": b"end", "more_body": False})

    port = _free_port()
    _serve_in_background(streaming_app, port)

    response = httpx.get(f"http://127.0.0.1:{port}/", timeout=2.0)
    assert response.status_code == 200
    assert response.headers.get("transfer-encoding", "").lower() == "chunked"
    assert "content-length" not in response.headers
    # httpx already de-chunks for us — body is the concatenation of all chunks.
    assert response.content == b"chunk-0;chunk-1;chunk-2;chunk-3;chunk-4;end"


def test_streaming_response_explicit_content_length() -> None:
    """When the app declares Content-Length, saltare must emit raw body
    bytes (no chunked encoding) even if more_body=True is used to send the
    body in pieces."""
    total_body = b"x" * 4096  # 4 KiB

    async def cl_streaming_app(scope, receive, send):
        await receive()
        await send({
            "type": "http.response.start",
            "status": 200,
            "headers": [
                (b"content-type", b"application/octet-stream"),
                (b"content-length", str(len(total_body)).encode("ascii")),
            ],
        })
        # Send in 4 equal slices.
        slice_size = len(total_body) // 4
        for i in range(4):
            await send({
                "type": "http.response.body",
                "body": total_body[i * slice_size:(i + 1) * slice_size],
                "more_body": i < 3,
            })

    port = _free_port()
    _serve_in_background(cl_streaming_app, port)

    response = httpx.get(f"http://127.0.0.1:{port}/", timeout=2.0)
    assert response.status_code == 200
    assert "transfer-encoding" not in response.headers
    assert int(response.headers["content-length"]) == len(total_body)
    assert response.content == total_body


def test_two_streaming_responses_on_one_keepalive_connection() -> None:
    """Streaming dispatch must reset cleanly between requests on the same
    connection — verifies dispatch_handle/active are wiped in keepAliveReset."""

    async def streaming_app(scope, receive, send):
        await receive()
        await send({
            "type": "http.response.start",
            "status": 200,
            "headers": [(b"content-type", b"text/plain")],
        })
        await send({"type": "http.response.body", "body": b"a", "more_body": True})
        await send({"type": "http.response.body", "body": b"b", "more_body": True})
        await send({"type": "http.response.body", "body": b"c", "more_body": False})

    port = _free_port()
    _serve_in_background(streaming_app, port)

    with httpx.Client(timeout=2.0) as client:
        r1 = client.get(f"http://127.0.0.1:{port}/")
        r2 = client.get(f"http://127.0.0.1:{port}/")
        assert r1.status_code == 200 and r1.content == b"abc"
        assert r2.status_code == 200 and r2.content == b"abc"
        assert r1.headers.get("transfer-encoding", "").lower() == "chunked"


@pytest.mark.flaky(reruns=3, reruns_delay=1)
def test_large_streaming_response_is_complete() -> None:
    """Sanity check that many chunks adding up to a large body round-trip
    correctly. RAM is not measured here (that's the bench's job) but the
    test confirms no chunks are dropped when we recurse through the
    dispatchTick path many times."""
    n_chunks = 500
    chunk_size = 1024  # 1 KiB → 500 KiB total

    async def big_streaming_app(scope, receive, send):
        await receive()
        await send({
            "type": "http.response.start",
            "status": 200,
            "headers": [(b"content-type", b"application/octet-stream")],
        })
        for i in range(n_chunks):
            await send({
                "type": "http.response.body",
                "body": bytes([i % 256]) * chunk_size,
                "more_body": i < n_chunks - 1,
            })

    port = _free_port()
    _serve_in_background(big_streaming_app, port)

    response = httpx.get(f"http://127.0.0.1:{port}/", timeout=10.0)
    assert response.status_code == 200
    assert len(response.content) == n_chunks * chunk_size
    # Spot-check: each chunk is a single repeating byte equal to (i % 256).
    for i in range(n_chunks):
        slice_ = response.content[i * chunk_size:(i + 1) * chunk_size]
        assert set(slice_) == {i % 256}, f"chunk {i} mismatched"
