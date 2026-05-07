"""v1.4 extras tests:

  - max_request_uri (414)
  - max_request_head_bytes (431)
  - traceparent propagation
  - latency histogram on /metrics
  - streaming response gzip (Z_SYNC_FLUSH)

Brotli + zstd negotiation are exercised only via the negotiation logic
unit-test below; the libs aren't typically present in the manylinux test
image, so the encode/decode call falls through to identity.
"""

from __future__ import annotations

import gzip
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


async def _hello(scope, receive, send):
    if scope["type"] == "lifespan":
        await _lifespan_drain(receive, send)
        return
    await receive()
    await send({"type": "http.response.start", "status": 200,
                "headers": [(b"content-type", b"text/plain")]})
    await send({"type": "http.response.body", "body": b"hi", "more_body": False})


# ---------------------------------------------------------------------------
# 414 URI Too Long
# ---------------------------------------------------------------------------


def test_max_request_uri_414():
    """Target longer than max_request_uri returns 414."""
    port = _free_port()
    _serve(_hello, port, max_request_uri=64)
    long_path = "/" + "x" * 200
    with httpx.Client(timeout=2.0) as client:
        r = client.get(f"http://127.0.0.1:{port}{long_path}")
    assert r.status_code == 414


def test_max_request_uri_default_allows_normal_paths():
    port = _free_port()
    _serve(_hello, port)
    r = httpx.get(f"http://127.0.0.1:{port}/users/42", timeout=2.0)
    assert r.status_code == 200


# ---------------------------------------------------------------------------
# 431 Request Header Fields Too Large
# ---------------------------------------------------------------------------


def test_max_request_head_bytes_431():
    """Total head section longer than max_request_head_bytes returns 431."""
    port = _free_port()
    _serve(_hello, port, max_request_head_bytes=512)
    big_header_value = "y" * 1024
    with httpx.Client(timeout=2.0) as client:
        r = client.get(
            f"http://127.0.0.1:{port}/",
            headers={"X-Big": big_header_value},
        )
    assert r.status_code == 431


# ---------------------------------------------------------------------------
# Traceparent propagation
# ---------------------------------------------------------------------------


_SEEN_TRACEPARENT: list[str] = []


async def _trace_app(scope, receive, send):
    if scope["type"] == "lifespan":
        await _lifespan_drain(receive, send)
        return
    _SEEN_TRACEPARENT.append(scope.get("traceparent", ""))
    await receive()
    await send({"type": "http.response.start", "status": 200,
                "headers": [(b"content-type", b"text/plain")]})
    await send({"type": "http.response.body", "body": b"ok", "more_body": False})


def test_traceparent_propagation_echo():
    port = _free_port()
    _SEEN_TRACEPARENT.clear()
    _serve(_trace_app, port, traceparent_propagation=True)
    tp = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
    r = httpx.get(
        f"http://127.0.0.1:{port}/",
        headers={"traceparent": tp},
        timeout=2.0,
    )
    assert r.status_code == 200
    assert r.headers.get("traceparent") == tp
    assert _SEEN_TRACEPARENT[-1] == tp


def test_traceparent_disabled_by_default():
    port = _free_port()
    _SEEN_TRACEPARENT.clear()
    _serve(_trace_app, port)  # propagation off
    tp = "00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-01"
    r = httpx.get(
        f"http://127.0.0.1:{port}/",
        headers={"traceparent": tp},
        timeout=2.0,
    )
    assert r.status_code == 200
    assert "traceparent" not in {k.lower() for k in r.headers.keys()}
    assert _SEEN_TRACEPARENT[-1] == ""


# ---------------------------------------------------------------------------
# Latency histogram
# ---------------------------------------------------------------------------


def test_latency_histogram_on_metrics():
    port = _free_port()
    _serve(_hello, port, metrics_path="/metrics", latency_histogram=True)
    # Drive at least one request so the histogram has an observation.
    httpx.get(f"http://127.0.0.1:{port}/", timeout=2.0)
    r = httpx.get(f"http://127.0.0.1:{port}/metrics", timeout=2.0)
    assert r.status_code == 200
    body = r.text
    assert "saltare_request_duration_seconds_bucket" in body
    assert 'le="+Inf"' in body
    assert "saltare_request_duration_seconds_sum" in body
    assert "saltare_request_duration_seconds_count" in body


def test_latency_histogram_disabled_by_default():
    port = _free_port()
    _serve(_hello, port, metrics_path="/metrics")
    httpx.get(f"http://127.0.0.1:{port}/", timeout=2.0)
    r = httpx.get(f"http://127.0.0.1:{port}/metrics", timeout=2.0)
    body = r.text
    assert "saltare_request_duration_seconds_bucket" not in body


# ---------------------------------------------------------------------------
# Streaming response gzip
# ---------------------------------------------------------------------------


_BIG_STREAM_CHUNK = (b'{"items":[' + b'"x",' * 1000 + b'"end"]}')


async def _streaming_json(scope, receive, send):
    if scope["type"] == "lifespan":
        await _lifespan_drain(receive, send)
        return
    await receive()
    await send({"type": "http.response.start", "status": 200,
                "headers": [(b"content-type", b"application/json")]})
    # Three chunks → forces the streaming path (more_body=True).
    await send({"type": "http.response.body", "body": _BIG_STREAM_CHUNK, "more_body": True})
    await send({"type": "http.response.body", "body": _BIG_STREAM_CHUNK, "more_body": True})
    await send({"type": "http.response.body", "body": _BIG_STREAM_CHUNK, "more_body": False})


def test_streaming_response_gzip():
    port = _free_port()
    _serve(_streaming_json, port, response_gzip=True)
    r = httpx.get(
        f"http://127.0.0.1:{port}/",
        headers={"Accept-Encoding": "gzip"},
        timeout=5.0,
    )
    assert r.status_code == 200
    assert r.headers.get("content-encoding") == "gzip"
    # httpx auto-decodes; concatenated body must equal three chunks worth.
    assert r.content == _BIG_STREAM_CHUNK * 3


# ---------------------------------------------------------------------------
# Encoding negotiation logic (unit test, no server)
# ---------------------------------------------------------------------------


def test_negotiation_prefers_brotli_when_offered_and_enabled():
    from saltare import _dispatcher
    _dispatcher.set_response_brotli(True)
    _dispatcher.set_response_gzip(True)
    try:
        chosen = _dispatcher._negotiate_encoding(b"gzip, br, deflate")
        assert chosen == b"br"
    finally:
        _dispatcher.set_response_brotli(False)
        _dispatcher.set_response_gzip(False)


def test_negotiation_falls_back_to_gzip_when_brotli_disabled():
    from saltare import _dispatcher
    _dispatcher.set_response_gzip(True)
    try:
        chosen = _dispatcher._negotiate_encoding(b"br, gzip")
        assert chosen == b"gzip"
    finally:
        _dispatcher.set_response_gzip(False)


def test_negotiation_respects_q_zero():
    from saltare import _dispatcher
    _dispatcher.set_response_gzip(True)
    try:
        chosen = _dispatcher._negotiate_encoding(b"gzip;q=0, identity")
        assert chosen == b""
    finally:
        _dispatcher.set_response_gzip(False)
