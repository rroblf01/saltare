"""v1.4 zlib wiring tests.

  - response_gzip                  — Accept-Encoding negotiation, content-type gating.
  - request_decompression          — Content-Encoding: gzip on request body.
  - response_gzip below threshold  — small bodies pass through unchanged.
"""

from __future__ import annotations

import gzip
import socket
import threading
import time
from typing import Any

import httpx

import platform as _platform
_TIMING_FACTOR: float = 4.0 if _platform.machine() in {"aarch64", "arm64"} else 1.0
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


# Long, repetitive body — gzip should compress 10× or so.
_BIG_JSON_BODY = (b'{"items": [' + b'"x",' * 4000 + b'"end"]}')


async def _big_json(scope, receive, send):
    if scope["type"] == "lifespan":
        await _lifespan_drain(receive, send)
        return
    await receive()
    await send({
        "type": "http.response.start",
        "status": 200,
        "headers": [(b"content-type", b"application/json")],
    })
    await send({"type": "http.response.body", "body": _BIG_JSON_BODY, "more_body": False})


async def _small_json(scope, receive, send):
    if scope["type"] == "lifespan":
        await _lifespan_drain(receive, send)
        return
    await receive()
    await send({
        "type": "http.response.start",
        "status": 200,
        "headers": [(b"content-type", b"application/json")],
    })
    await send({"type": "http.response.body", "body": b'{"k":"v"}', "more_body": False})


async def _binary(scope, receive, send):
    if scope["type"] == "lifespan":
        await _lifespan_drain(receive, send)
        return
    await receive()
    await send({
        "type": "http.response.start",
        "status": 200,
        "headers": [(b"content-type", b"image/png")],
    })
    body = b"\x89PNG\r\n\x1a\n" + b"\x00" * 10000
    await send({"type": "http.response.body", "body": body, "more_body": False})


async def _echo_body(scope, receive, send):
    if scope["type"] == "lifespan":
        await _lifespan_drain(receive, send)
        return
    body = b""
    while True:
        evt = await receive()
        body += evt.get("body", b"") or b""
        if not evt.get("more_body", False):
            break
    await send({
        "type": "http.response.start",
        "status": 200,
        "headers": [(b"content-type", b"application/octet-stream")],
    })
    await send({"type": "http.response.body", "body": body, "more_body": False})


# ---------------------------------------------------------------------------
# Response gzip
# ---------------------------------------------------------------------------


def test_response_gzip_compressible_content_type():
    """Accept-Encoding: gzip + JSON body → response is gzipped."""
    port = _free_port()
    _serve(_big_json, port, response_gzip=True)
    r = httpx.get(
        f"http://127.0.0.1:{port}/",
        headers={"Accept-Encoding": "gzip"},
        timeout=2.0 * _TIMING_FACTOR,
    )
    assert r.status_code == 200
    # httpx auto-decodes by default; we want to see the wire.
    raw = r.content  # decoded
    # Header should report gzip + Vary
    assert r.headers.get("content-encoding") == "gzip"
    assert "accept-encoding" in r.headers.get("vary", "").lower()
    # Sanity: decoded payload matches original
    assert raw == _BIG_JSON_BODY


def test_response_gzip_skipped_on_binary_content_type():
    """image/png is not in the compressible set — no Content-Encoding."""
    port = _free_port()
    _serve(_binary, port, response_gzip=True)
    r = httpx.get(
        f"http://127.0.0.1:{port}/",
        headers={"Accept-Encoding": "gzip"},
        timeout=2.0 * _TIMING_FACTOR,
    )
    assert r.status_code == 200
    assert "content-encoding" not in {k.lower() for k in r.headers.keys()}


def test_response_gzip_skipped_below_threshold():
    """Body smaller than min_bytes (default 512) → no compression."""
    port = _free_port()
    _serve(_small_json, port, response_gzip=True)
    r = httpx.get(
        f"http://127.0.0.1:{port}/",
        headers={"Accept-Encoding": "gzip"},
        timeout=2.0 * _TIMING_FACTOR,
    )
    assert r.status_code == 200
    assert "content-encoding" not in {k.lower() for k in r.headers.keys()}


def test_response_gzip_disabled_by_default():
    """Default-off — no Content-Encoding even for compressible JSON."""
    port = _free_port()
    _serve(_big_json, port)  # response_gzip not set
    r = httpx.get(
        f"http://127.0.0.1:{port}/",
        headers={"Accept-Encoding": "gzip"},
        timeout=2.0 * _TIMING_FACTOR,
    )
    assert r.status_code == 200
    assert "content-encoding" not in {k.lower() for k in r.headers.keys()}


def test_response_gzip_skipped_when_client_omits_accept_encoding():
    """No Accept-Encoding header → no compression even when enabled."""
    port = _free_port()
    _serve(_big_json, port, response_gzip=True)
    r = httpx.get(
        f"http://127.0.0.1:{port}/",
        headers={"Accept-Encoding": "identity"},
        timeout=2.0 * _TIMING_FACTOR,
    )
    assert r.status_code == 200
    assert "content-encoding" not in {k.lower() for k in r.headers.keys()}


# ---------------------------------------------------------------------------
# Request decompression
# ---------------------------------------------------------------------------


def test_request_decompression_gzip_body():
    """POST gzipped JSON → app receives decompressed bytes."""
    port = _free_port()
    _serve(_echo_body, port, request_decompression=True, max_request_body=1 * 1024 * 1024)
    payload = b'{"items":' + b'"x",' * 1000 + b'"end"]}'
    encoded = gzip.compress(payload)
    r = httpx.post(
        f"http://127.0.0.1:{port}/",
        content=encoded,
        headers={"Content-Encoding": "gzip", "Content-Type": "application/json"},
        timeout=2.0 * _TIMING_FACTOR,
    )
    assert r.status_code == 200
    assert r.content == payload


def test_request_decompression_overflow_returns_413():
    """Decompressed body would exceed max_request_body → 413."""
    port = _free_port()
    _serve(_echo_body, port, request_decompression=True, max_request_body=1024)
    # 100 KiB of zeros compresses to a few hundred bytes — well under
    # the 1 KiB max_request_body, but the decompressed body blows the cap.
    payload = b"\x00" * (100 * 1024)
    encoded = gzip.compress(payload)
    assert len(encoded) < 1024
    r = httpx.post(
        f"http://127.0.0.1:{port}/",
        content=encoded,
        headers={"Content-Encoding": "gzip"},
        timeout=2.0 * _TIMING_FACTOR,
    )
    assert r.status_code == 413


def test_request_decompression_disabled_by_default():
    """Default-off — gzipped body delivered raw to the app."""
    port = _free_port()
    _serve(_echo_body, port)  # request_decompression not set
    payload = b"plain"
    encoded = gzip.compress(payload)
    r = httpx.post(
        f"http://127.0.0.1:{port}/",
        content=encoded,
        headers={"Content-Encoding": "gzip"},
        timeout=2.0 * _TIMING_FACTOR,
    )
    assert r.status_code == 200
    # App got the raw gzipped bytes (default behaviour preserved).
    assert r.content == encoded
