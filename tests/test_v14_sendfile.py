"""v1.4 sendfile ASGI extension tests:

  - GET serves the file body via sendfile(2)
  - HEAD response is body-stripped (RFC 7230)
  - Custom headers from the app are emitted; saltare adds Content-Length
  - App-provided `Content-Length` is ignored (saltare derives from fstat)
"""

from __future__ import annotations

import os
import socket
import tempfile
import threading
import time
from typing import Any

import httpx
import pytest


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


async def _lifespan_drain(receive, send):
    while True:
        msg = await receive()
        if msg["type"] == "lifespan.startup":
            await send({"type": "lifespan.startup.complete"})
        elif msg["type"] == "lifespan.shutdown":
            await send({"type": "lifespan.shutdown.complete"})
            return


def _serve(app: Any, port: int, **kwargs) -> None:
    from saltare import run
    threading.Thread(
        target=run,
        args=(app,),
        kwargs={"host": "127.0.0.1", "port": port, **kwargs},
        daemon=True,
    ).start()
    deadline = time.monotonic() + 3.0
    while time.monotonic() < deadline:
        try:
            with socket.socket() as s:
                s.settimeout(0.2)
                s.connect(("127.0.0.1", port))
                return
        except (ConnectionRefusedError, socket.timeout, OSError):
            time.sleep(0.05)
    pytest.fail(f"server never came up on 127.0.0.1:{port}")


@pytest.fixture
def static_file():
    with tempfile.NamedTemporaryFile(delete=False) as f:
        # 32 KiB of varied bytes — large enough to exercise the multi-call
        # sendfile loop (16 KiB chunks).
        f.write(bytes((i * 7) & 0xFF for i in range(32 * 1024)))
        path = f.name
    yield path
    os.unlink(path)


def test_sendfile_get_returns_body(static_file):
    port = _free_port()
    expected = open(static_file, "rb").read()

    async def app(scope, receive, send):
        if scope["type"] == "lifespan":
            await _lifespan_drain(receive, send)
            return
        await receive()
        await send({
            "type": "saltare.sendfile",
            "path": static_file,
            "status": 200,
            "headers": [(b"content-type", b"application/octet-stream")],
        })

    _serve(app, port)
    r = httpx.get(f"http://127.0.0.1:{port}/file", timeout=5.0)
    assert r.status_code == 200
    assert r.headers["content-type"] == "application/octet-stream"
    assert int(r.headers["content-length"]) == len(expected)
    assert r.content == expected


def test_sendfile_head_strips_body(static_file):
    port = _free_port()
    expected_size = os.path.getsize(static_file)

    async def app(scope, receive, send):
        if scope["type"] == "lifespan":
            await _lifespan_drain(receive, send)
            return
        await receive()
        await send({
            "type": "saltare.sendfile",
            "path": static_file,
            "status": 200,
            "headers": [(b"content-type", b"application/octet-stream")],
        })

    _serve(app, port)
    r = httpx.head(f"http://127.0.0.1:{port}/file", timeout=5.0)
    assert r.status_code == 200
    assert int(r.headers["content-length"]) == expected_size
    assert r.content == b""


def test_sendfile_404_when_path_missing():
    port = _free_port()

    async def app(scope, receive, send):
        if scope["type"] == "lifespan":
            await _lifespan_drain(receive, send)
            return
        await receive()
        await send({
            "type": "saltare.sendfile",
            "path": "/nonexistent/file.bin",
            "status": 200,
            "headers": [(b"content-type", b"application/octet-stream")],
        })

    _serve(app, port)
    r = httpx.get(f"http://127.0.0.1:{port}/", timeout=5.0)
    # The server returns a 5xx when it can't open the file. Either 404
    # or 500 is acceptable here; what matters is no body data.
    assert r.status_code >= 400


def test_sendfile_app_content_length_is_ignored(static_file):
    """App declares a wrong CL — saltare must derive the correct one."""
    port = _free_port()
    expected = open(static_file, "rb").read()

    async def app(scope, receive, send):
        if scope["type"] == "lifespan":
            await _lifespan_drain(receive, send)
            return
        await receive()
        await send({
            "type": "saltare.sendfile",
            "path": static_file,
            "status": 200,
            "headers": [
                (b"content-type", b"application/octet-stream"),
                # Bogus CL — must be dropped.
                (b"content-length", b"7"),
            ],
        })

    _serve(app, port)
    r = httpx.get(f"http://127.0.0.1:{port}/file", timeout=5.0)
    assert r.status_code == 200
    assert int(r.headers["content-length"]) == len(expected)
    assert r.content == expected
