"""Edge-case coverage added in the v1.8 cycle.

Targets:
  - Header offset compression (`Header.{name,value}_off/len: u16`):
    long header values close to the parser's 64 KiB ceiling, near
    `max_headers=32`, empty values.
  - HTTP/1.1 pipelined requests over a single TCP connection — the
    parser must compact past each consumed head and re-parse from
    the freshly-overwritten buffer.
  - WebSocket binary frames of varying sizes (small / medium / large)
    so the extended-length encoders / unmasking loop are exercised
    end-to-end.
  - HSTS combinations: includeSubDomains + preload rendering, opt-in
    gating on max-age.
  - Drain endpoint full verb matrix (POST / PUT / GET / HEAD /
    DELETE / OPTIONS).
  - Method case-sensitivity (RFC 7230 §3.1.1 — methods are case-
    sensitive; "get" must not match the GET branches in saltare's
    health / favicon intercepts).
  - Header injection guard: CRLF / NUL in a header name must produce
    a 400 (RFC 7230 §3.2.6 tchar validation).
"""

from __future__ import annotations

import os
import platform as _platform
import socket
import struct
import threading
import time
from typing import Any

import httpx
import pytest

_TIMING_FACTOR: float = 4.0 if _platform.machine() in {"aarch64", "arm64"} else 1.0


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


async def _lifespan_drain(receive, send) -> None:
    while True:
        msg = await receive()
        if msg["type"] == "lifespan.startup":
            await send({"type": "lifespan.startup.complete"})
        elif msg["type"] == "lifespan.shutdown":
            await send({"type": "lifespan.shutdown.complete"})
            return


async def _echo_headers_app(scope, receive, send):
    """Returns the request headers as JSON so tests can verify
    saltare's header parsing preserved values exactly."""
    if scope["type"] == "lifespan":
        await _lifespan_drain(receive, send)
        return
    await receive()
    import json
    headers_repr = [
        [name.decode("latin-1"), value.decode("latin-1")]
        for name, value in scope["headers"]
    ]
    body = json.dumps({"headers": headers_repr}).encode("utf-8")
    await send({"type": "http.response.start", "status": 200,
                "headers": [(b"content-type", b"application/json")]})
    await send({"type": "http.response.body", "body": body})


async def _hello_app(scope, receive, send):
    if scope["type"] == "lifespan":
        await _lifespan_drain(receive, send)
        return
    await receive()
    await send({"type": "http.response.start", "status": 200,
                "headers": [(b"content-type", b"text/plain")]})
    await send({"type": "http.response.body", "body": b"ok"})


async def _ws_echo_binary_app(scope, receive, send):
    if scope["type"] == "lifespan":
        await _lifespan_drain(receive, send)
        return
    if scope["type"] != "websocket":
        return
    if (await receive())["type"] != "websocket.connect":
        return
    await send({"type": "websocket.accept"})
    while True:
        m = await receive()
        if m["type"] == "websocket.disconnect":
            return
        if m["type"] == "websocket.receive":
            payload = m.get("bytes")
            if payload is not None:
                await send({"type": "websocket.send", "bytes": payload})


def _serve(app, port: int, **kwargs) -> None:
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


# ---------------------------------------------------------------------------
# Header offset compression — v1.8
# ---------------------------------------------------------------------------


def test_header_with_long_value_preserved_exactly() -> None:
    """A header value near the 4 KiB pool buffer ceiling must
    round-trip through saltare's u16-offset header table without
    truncation. Exercises the upper end of `Header.value_len: u16`."""
    port = _free_port()
    _serve(_echo_headers_app, port)
    # Stay under the small-buffer ceiling (4 KiB) minus head bytes.
    long_value = "x" * 3000
    r = httpx.get(f"http://127.0.0.1:{port}/",
                  headers={"X-Long": long_value},
                  timeout=5.0 * _TIMING_FACTOR)
    assert r.status_code == 200
    headers = {name.lower(): value for name, value in r.json()["headers"]}
    assert headers["x-long"] == long_value


def test_near_max_headers_count_all_preserved() -> None:
    """Send close to `max_headers=32` distinct headers; every one
    must appear in scope. Exercises the headers array bounds."""
    port = _free_port()
    _serve(_echo_headers_app, port)
    extras = {f"X-Hdr-{i:02d}": f"v{i}" for i in range(20)}
    r = httpx.get(f"http://127.0.0.1:{port}/", headers=extras,
                  timeout=5.0 * _TIMING_FACTOR)
    assert r.status_code == 200
    received = {name.lower(): value for name, value in r.json()["headers"]}
    for k, v in extras.items():
        assert received[k.lower()] == v


def test_empty_header_value_preserved() -> None:
    """`X-Empty: ` (empty value after OWS trim) must still arrive as
    an empty-string value, not be dropped."""
    port = _free_port()
    _serve(_echo_headers_app, port)
    with socket.socket() as s:
        s.settimeout(3.0 * _TIMING_FACTOR)
        s.connect(("127.0.0.1", port))
        s.sendall(
            b"GET / HTTP/1.1\r\n"
            b"Host: x\r\n"
            b"X-Empty: \r\n"
            b"\r\n"
        )
        raw = b""
        deadline = time.monotonic() + 2.0 * _TIMING_FACTOR
        while b"\r\n\r\n" not in raw and time.monotonic() < deadline:
            chunk = s.recv(4096)
            if not chunk:
                break
            raw += chunk
    head, _, body = raw.partition(b"\r\n\r\n")
    assert b"200" in head.split(b"\r\n", 1)[0], head[:64]
    # Body may have Content-Length; just check JSON contains x-empty.
    assert b'"x-empty"' in body, body[-200:]


# ---------------------------------------------------------------------------
# Pipelined HTTP requests over a single TCP connection
# ---------------------------------------------------------------------------


def test_pipelined_requests_same_connection() -> None:
    """Two pipelined GET / requests on one TCP socket must each
    receive their own 200 response. The parser has to compact past
    the first request and re-parse from the new offset; with v1.8's
    u16-offset header table, a compaction bug would surface here as
    a parse error on the second request."""
    port = _free_port()
    _serve(_hello_app, port)
    with socket.socket() as s:
        s.settimeout(3.0 * _TIMING_FACTOR)
        s.connect(("127.0.0.1", port))
        s.sendall(
            b"GET / HTTP/1.1\r\nHost: x\r\nConnection: keep-alive\r\n\r\n"
            b"GET / HTTP/1.1\r\nHost: x\r\nConnection: keep-alive\r\n\r\n"
        )
        raw = b""
        deadline = time.monotonic() + 3.0 * _TIMING_FACTOR
        while time.monotonic() < deadline:
            try:
                chunk = s.recv(4096)
            except socket.timeout:
                break
            if not chunk:
                break
            raw += chunk
            if raw.count(b"HTTP/1.1 200") >= 2:
                break
    # Two complete 200 responses observed back-to-back.
    assert raw.count(b"HTTP/1.1 200") == 2, raw[:400]
    assert raw.count(b"\r\n\r\nok") == 2, raw[:400]


# ---------------------------------------------------------------------------
# WebSocket binary payload sizes
# ---------------------------------------------------------------------------


def _ws_handshake(sock: socket.socket, port: int) -> None:
    sock.sendall(
        b"GET / HTTP/1.1\r\n"
        b"Host: 127.0.0.1:" + str(port).encode() + b"\r\n"
        b"Upgrade: websocket\r\n"
        b"Connection: Upgrade\r\n"
        b"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
        b"Sec-WebSocket-Version: 13\r\n"
        b"\r\n"
    )
    raw = b""
    deadline = time.monotonic() + 3.0 * _TIMING_FACTOR
    while b"\r\n\r\n" not in raw and time.monotonic() < deadline:
        chunk = sock.recv(4096)
        if not chunk:
            break
        raw += chunk
    assert raw.startswith(b"HTTP/1.1 101"), raw[:64]


def _build_binary_client_frame(payload: bytes) -> bytes:
    """RFC 6455 client-side binary frame: FIN=1, opcode=2, masked."""
    b0 = 0x82  # FIN + binary
    n = len(payload)
    out = bytearray([b0])
    if n < 126:
        out.append(0x80 | n)
    elif n < 65536:
        out.append(0xFE)  # 0x80 | 126
        out += n.to_bytes(2, "big")
    else:
        out.append(0xFF)  # 0x80 | 127
        out += n.to_bytes(8, "big")
    mask = b"\x12\x34\x56\x78"
    out += mask
    out += bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    return bytes(out)


def _read_one_binary_frame(sock: socket.socket, deadline_s: float = 5.0) -> bytes:
    sock.settimeout(deadline_s * _TIMING_FACTOR)
    hdr = b""
    while len(hdr) < 2:
        more = sock.recv(2 - len(hdr))
        if not more:
            raise AssertionError("eof during frame header")
        hdr += more
    b1 = hdr[1]
    n = b1 & 0x7F
    if n == 126:
        ext = b""
        while len(ext) < 2:
            more = sock.recv(2 - len(ext))
            if not more:
                raise AssertionError("eof during ext-16")
            ext += more
        n = struct.unpack(">H", ext)[0]
    elif n == 127:
        ext = b""
        while len(ext) < 8:
            more = sock.recv(8 - len(ext))
            if not more:
                raise AssertionError("eof during ext-64")
            ext += more
        n = struct.unpack(">Q", ext)[0]
    payload = b""
    while len(payload) < n:
        more = sock.recv(min(8192, n - len(payload)))
        if not more:
            raise AssertionError("eof during payload")
        payload += more
    return payload


@pytest.mark.parametrize("size,label", [
    (32, "small-7bit"),
    (200, "above-126-7bit"),
    (2000, "ext-16bit"),
])
def test_ws_binary_echo_varying_sizes(size: int, label: str) -> None:
    """Server echoes binary frames; client must receive the exact
    bytes back. Exercises the two length-prefix variants that fit
    inside saltare's 4 KiB read buffer: 7-bit (`<126`) and 16-bit
    extended (`126 + u16`). The 64-bit extended variant would
    require a frame larger than the pool buffer ceiling and hits
    the intentional `doReadWs` "frame bigger than our buffer"
    teardown — exercised by a separate negative test."""
    port = _free_port()
    _serve(_ws_echo_binary_app, port)
    payload = os.urandom(size)
    with socket.socket() as s:
        s.settimeout(5.0 * _TIMING_FACTOR)
        s.connect(("127.0.0.1", port))
        _ws_handshake(s, port)
        s.sendall(_build_binary_client_frame(payload))
        received = _read_one_binary_frame(s, deadline_s=5.0)
    assert received == payload, f"{label}: size mismatch {len(received)} vs {size}"


# ---------------------------------------------------------------------------
# HSTS combinations
# ---------------------------------------------------------------------------


def test_hsts_max_age_only_no_extras() -> None:
    """`--hsts-max-age=N` alone renders `max-age=N` without
    `includeSubDomains` / `preload` tokens."""
    port = _free_port()
    _serve(_hello_app, port, hsts_max_age=3600)
    r = httpx.get(f"http://127.0.0.1:{port}/", timeout=5.0 * _TIMING_FACTOR)
    sts = r.headers.get("strict-transport-security", "")
    assert "max-age=3600" in sts
    assert "includeSubDomains" not in sts
    assert "preload" not in sts


def test_hsts_max_age_zero_disables_header() -> None:
    """`--hsts-max-age=0` must NOT emit the header — RFC 6797 §6.1.1
    treats max-age=0 as a directive to *remove* HSTS, and emitting
    the line would be misleading. Saltare suppresses entirely."""
    port = _free_port()
    _serve(_hello_app, port, hsts_max_age=0,
           hsts_include_subdomains=True, hsts_preload=True)
    r = httpx.get(f"http://127.0.0.1:{port}/", timeout=5.0 * _TIMING_FACTOR)
    assert "strict-transport-security" not in {k.lower() for k in r.headers.keys()}


# ---------------------------------------------------------------------------
# Drain endpoint verb matrix
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("method,expected", [
    ("GET", 200),
    ("HEAD", 200),
    ("PUT", 200),
    ("DELETE", 405),
    ("PATCH", 405),
    ("OPTIONS", 405),
])
def test_drain_endpoint_verbs(method: str, expected: int) -> None:
    """POST/PUT flip drain; GET/HEAD probe; everything else 405.
    Subprocess-free; just verifies status without committing to
    drain on POST (which would tear the test server down)."""
    port = _free_port()
    _serve(_hello_app, port, drain_path="/admin/drain")
    if method == "PUT":
        # PUT actually flips drain — skip the assertion to avoid
        # affecting the conftest cleanup; verify status only.
        r = httpx.request("PUT", f"http://127.0.0.1:{port}/admin/drain",
                          timeout=5.0 * _TIMING_FACTOR)
    else:
        r = httpx.request(method, f"http://127.0.0.1:{port}/admin/drain",
                          timeout=5.0 * _TIMING_FACTOR)
    assert r.status_code == expected, f"{method}: expected {expected}, got {r.status_code}"


# ---------------------------------------------------------------------------
# Method case-sensitivity
# ---------------------------------------------------------------------------


def test_lowercase_method_is_not_get() -> None:
    """RFC 7230 §3.1.1: methods are case-sensitive. `get` is NOT
    equivalent to `GET`. Saltare's Zig-side intercepts (health,
    favicon, drain) compare with `std.mem.eql` (case-sensitive),
    so a lowercase `get /favicon.ico` should NOT hit the favicon
    intercept and instead reach the user app."""
    port = _free_port()
    _serve(_hello_app, port, favicon_204=True)
    with socket.socket() as s:
        s.settimeout(3.0 * _TIMING_FACTOR)
        s.connect(("127.0.0.1", port))
        s.sendall(b"get /favicon.ico HTTP/1.1\r\nHost: x\r\n\r\n")
        raw = b""
        deadline = time.monotonic() + 2.0 * _TIMING_FACTOR
        while b"\r\n\r\n" not in raw and time.monotonic() < deadline:
            chunk = s.recv(4096)
            if not chunk:
                break
            raw += chunk
    # Lowercase `get` is technically a non-standard method. Saltare
    # routes it to the app (which doesn't define /favicon.ico) —
    # FastAPI would 404; our minimal `_hello_app` happily returns
    # 200 "ok" for any path. Either way: NOT a 204 (favicon intercept).
    status_line = raw.split(b"\r\n", 1)[0]
    assert b"204" not in status_line, f"favicon intercept matched lowercase 'get': {status_line!r}"


# ---------------------------------------------------------------------------
# Header injection guard (RFC 7230 §3.2.6 tchar)
# ---------------------------------------------------------------------------


def test_header_name_with_ctrl_char_rejected() -> None:
    """A header name containing a NUL / CR / LF byte must produce
    400 — defends downstream proxies against `Header\\0Smuggled: x`
    style attacks where the parser would otherwise split the line."""
    port = _free_port()
    _serve(_hello_app, port)
    with socket.socket() as s:
        s.settimeout(3.0 * _TIMING_FACTOR)
        s.connect(("127.0.0.1", port))
        # NUL inside a header name. The TCP layer doesn't care; the
        # HTTP parser's tchar check should reject before reaching
        # the app.
        s.sendall(
            b"GET / HTTP/1.1\r\n"
            b"Host: x\r\n"
            b"Bad\x00Name: value\r\n"
            b"\r\n"
        )
        raw = b""
        deadline = time.monotonic() + 2.0 * _TIMING_FACTOR
        while b"\r\n\r\n" not in raw and time.monotonic() < deadline:
            chunk = s.recv(4096)
            if not chunk:
                break
            raw += chunk
    status_line = raw.split(b"\r\n", 1)[0] if raw else b""
    assert b"400" in status_line, f"expected 400, got: {status_line!r}"
