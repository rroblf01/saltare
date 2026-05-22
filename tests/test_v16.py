"""v1.6 tests:
  - streaming brotli (response_brotli + chunked)
  - streaming zstd (response_zstd + chunked)
  - WebSocket per-message-deflate handshake echo
  - WS p-m-d outbound deflate (rsv1 set + payload decompresses)
  - WS p-m-d inbound inflate (server inflates rsv1=1 payload)

libbrotli / libzstd may not be present in every test image; tests
skip gracefully when the encoder probe returns None.
"""

from __future__ import annotations

import platform as _platform
import socket
import struct
import threading
import time
import zlib
from typing import Any

import httpx
import pytest

_TIMING_FACTOR: float = 4.0 if _platform.machine() in {"aarch64", "arm64"} else 1.0


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


# ---------------------------------------------------------------------------
# Streaming brotli / zstd — skip when the lib isn't loadable.
# ---------------------------------------------------------------------------


def _brotli_available() -> bool:
    try:
        from saltare import _core
    except ImportError:
        return False
    return _core.brotli_encode(b"probe", 4) is not None


def _zstd_available() -> bool:
    try:
        from saltare import _core
    except ImportError:
        return False
    return _core.zstd_encode(b"probe", 3) is not None


_BIG_CHUNK = (b'{"items":[' + b'"x",' * 1000 + b'"end"]}')


async def _streaming_json(scope, receive, send):
    if scope["type"] == "lifespan":
        await _lifespan_drain(receive, send)
        return
    await receive()
    await send({"type": "http.response.start", "status": 200,
                "headers": [(b"content-type", b"application/json")]})
    await send({"type": "http.response.body", "body": _BIG_CHUNK, "more_body": True})
    await send({"type": "http.response.body", "body": _BIG_CHUNK, "more_body": True})
    await send({"type": "http.response.body", "body": _BIG_CHUNK, "more_body": False})


@pytest.mark.skipif(not _brotli_available(), reason="libbrotli not loadable")
def test_streaming_brotli_response():
    """Three-chunk streaming JSON + Accept-Encoding: br → response is
    Content-Encoding: br + payload decompresses to expected."""
    port = _free_port()
    _serve(_streaming_json, port, response_brotli=True)
    # httpx doesn't auto-decompress br without the optional extras;
    # ask it to keep raw compressed bytes by passing the encoding
    # ourselves and decoding via _core.
    r = httpx.get(
        f"http://127.0.0.1:{port}/",
        headers={"Accept-Encoding": "br"},
        timeout=5.0 * _TIMING_FACTOR,
    )
    assert r.status_code == 200
    assert r.headers.get("content-encoding") == "br"
    from saltare import _core
    decoded = _core.brotli_decode(bytes(r.content), 16 * 1024 * 1024)
    assert decoded == _BIG_CHUNK * 3


@pytest.mark.skipif(not _zstd_available(), reason="libzstd not loadable")
def test_streaming_zstd_response():
    """Streaming zstd encoder emits via `ZSTD_e_flush` per chunk +
    `ZSTD_e_end` at finish. The wire may carry multiple zstd frames
    concatenated (each flush starts a new frame), which one-shot
    `ZSTD_decompress` doesn't handle. We assert the content-encoding
    header + non-empty body; full streaming-decode coverage lives in
    the bench harness where libzstd's `ZSTD_decompressStream` is used."""
    port = _free_port()
    _serve(_streaming_json, port, response_zstd=True)
    r = httpx.get(
        f"http://127.0.0.1:{port}/",
        headers={"Accept-Encoding": "zstd"},
        timeout=5.0 * _TIMING_FACTOR,
    )
    assert r.status_code == 200
    assert r.headers.get("content-encoding") == "zstd"
    assert len(r.content) > 0 and len(r.content) < len(_BIG_CHUNK * 3)


# ---------------------------------------------------------------------------
# WebSocket per-message-deflate
# ---------------------------------------------------------------------------


def _ws_handshake(sock: socket.socket, port: int, extensions: str) -> dict[str, str]:
    """Send a minimal WS upgrade and parse the response headers as
    {lower_name: value}. Used to verify the 101 echoes the negotiated
    Sec-WebSocket-Extensions when the client offers permessage-deflate."""
    req = (
        b"GET / HTTP/1.1\r\n"
        b"Host: 127.0.0.1:" + str(port).encode() + b"\r\n"
        b"Upgrade: websocket\r\n"
        b"Connection: Upgrade\r\n"
        b"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
        b"Sec-WebSocket-Version: 13\r\n"
        b"Sec-WebSocket-Extensions: " + extensions.encode() + b"\r\n"
        b"\r\n"
    )
    sock.sendall(req)
    raw = b""
    deadline = time.monotonic() + 3.0 * _TIMING_FACTOR
    while b"\r\n\r\n" not in raw and time.monotonic() < deadline:
        chunk = sock.recv(4096)
        if not chunk:
            break
        raw += chunk
    head, _, _ = raw.partition(b"\r\n\r\n")
    headers: dict[str, str] = {}
    for line in head.split(b"\r\n")[1:]:
        if b":" not in line:
            continue
        name, _, value = line.partition(b":")
        headers[name.strip().lower().decode("ascii")] = value.strip().decode("ascii")
    headers["__status__"] = head.split(b"\r\n", 1)[0].decode("ascii")
    return headers


async def _ws_echo(scope, receive, send):
    if scope["type"] == "lifespan":
        await _lifespan_drain(receive, send)
        return
    if scope["type"] != "websocket":
        return
    msg = await receive()
    if msg["type"] != "websocket.connect":
        return
    await send({"type": "websocket.accept"})
    while True:
        m = await receive()
        if m["type"] == "websocket.disconnect":
            return
        if m["type"] != "websocket.receive":
            continue
        if m.get("text") is not None:
            await send({"type": "websocket.send", "text": m["text"]})
        elif m.get("bytes") is not None:
            await send({"type": "websocket.send", "bytes": m["bytes"]})


def test_ws_pmd_handshake_negotiated():
    """Client offers permessage-deflate → 101 echoes the extension
    with no_context_takeover params."""
    port = _free_port()
    _serve(_ws_echo, port)
    with socket.socket() as s:
        s.settimeout(3.0 * _TIMING_FACTOR)
        s.connect(("127.0.0.1", port))
        headers = _ws_handshake(s, port, "permessage-deflate")
    assert "101" in headers["__status__"]
    assert "permessage-deflate" in headers.get("sec-websocket-extensions", "")
    assert "no_context_takeover" in headers.get("sec-websocket-extensions", "")


def test_ws_pmd_not_offered_no_extension_header():
    """Client doesn't offer the extension → 101 has no
    Sec-WebSocket-Extensions header."""
    port = _free_port()
    _serve(_ws_echo, port)
    with socket.socket() as s:
        s.settimeout(3.0 * _TIMING_FACTOR)
        s.connect(("127.0.0.1", port))
        # Send handshake without extensions header.
        req = (
            b"GET / HTTP/1.1\r\n"
            b"Host: 127.0.0.1:" + str(port).encode() + b"\r\n"
            b"Upgrade: websocket\r\n"
            b"Connection: Upgrade\r\n"
            b"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
            b"Sec-WebSocket-Version: 13\r\n"
            b"\r\n"
        )
        s.sendall(req)
        raw = b""
        deadline = time.monotonic() + 3.0 * _TIMING_FACTOR
        while b"\r\n\r\n" not in raw and time.monotonic() < deadline:
            chunk = s.recv(4096)
            if not chunk:
                break
            raw += chunk
    head = raw.split(b"\r\n\r\n", 1)[0].lower()
    assert b"sec-websocket-extensions" not in head


def _read_ws_frame(sock: socket.socket) -> tuple[int, bool, bytes]:
    """Read one WS frame from the socket; return (opcode, rsv1, payload).
    Server frames are unmasked. Tested only with sub-126 payloads here
    (echo response of small messages)."""
    hdr = sock.recv(2)
    while len(hdr) < 2:
        more = sock.recv(2 - len(hdr))
        if not more:
            raise AssertionError("eof during frame read")
        hdr += more
    b0, b1 = hdr[0], hdr[1]
    rsv1 = bool(b0 & 0x40)
    opcode = b0 & 0x0F
    n = b1 & 0x7F
    if n == 126:
        ext = sock.recv(2)
        n = struct.unpack(">H", ext)[0]
    elif n == 127:
        ext = sock.recv(8)
        n = struct.unpack(">Q", ext)[0]
    payload = b""
    while len(payload) < n:
        more = sock.recv(n - len(payload))
        if not more:
            raise AssertionError("eof during payload read")
        payload += more
    return opcode, rsv1, payload


def _build_client_frame(opcode: int, payload: bytes, rsv1: bool = False) -> bytes:
    """Client-side masked frame for sending into the test socket."""
    b0 = 0x80 | opcode
    if rsv1:
        b0 |= 0x40
    out = bytes([b0])
    n = len(payload)
    mask = b"\x12\x34\x56\x78"
    if n < 126:
        out += bytes([n | 0x80])
    elif n < 65536:
        out += bytes([126 | 0x80]) + struct.pack(">H", n)
    else:
        out += bytes([127 | 0x80]) + struct.pack(">Q", n)
    out += mask
    out += bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    return out


def test_ws_pmd_outbound_compressed():
    """With pmd negotiated, server sends rsv1=1 frames whose payload
    decompresses to the original message via raw inflate."""
    port = _free_port()
    _serve(_ws_echo, port)
    msg = "hello " * 50  # repetitive, compresses well
    with socket.socket() as s:
        s.settimeout(3.0 * _TIMING_FACTOR)
        s.connect(("127.0.0.1", port))
        _ws_handshake(s, port, "permessage-deflate")
        # Send an uncompressed text frame (server will decompress nothing
        # since rsv1=0; we test the compressed-outbound path).
        s.sendall(_build_client_frame(0x1, msg.encode("utf-8"), rsv1=False))
        opcode, rsv1, payload = _read_ws_frame(s)
    assert opcode == 0x1
    assert rsv1, "server should set rsv1 on compressed echo"
    decoded = zlib.decompressobj(-15).decompress(payload + b"\x00\x00\xff\xff")
    assert decoded.decode("utf-8") == msg


def test_ws_pmd_inbound_compressed():
    """Server inflates client-compressed frames and the app sees the
    decoded text."""
    port = _free_port()
    _serve(_ws_echo, port)
    msg = "ping " * 80
    co = zlib.compressobj(6, zlib.DEFLATED, -15)
    compressed = co.compress(msg.encode("utf-8")) + co.flush(zlib.Z_SYNC_FLUSH)
    if compressed.endswith(b"\x00\x00\xff\xff"):
        compressed = compressed[:-4]
    with socket.socket() as s:
        s.settimeout(3.0 * _TIMING_FACTOR)
        s.connect(("127.0.0.1", port))
        _ws_handshake(s, port, "permessage-deflate")
        s.sendall(_build_client_frame(0x1, compressed, rsv1=True))
        opcode, _rsv1, payload = _read_ws_frame(s)
    assert opcode == 0x1
    # Server echoes back compressed; decompress to verify.
    decoded = zlib.decompressobj(-15).decompress(payload + b"\x00\x00\xff\xff")
    assert decoded.decode("utf-8") == msg


# ---------------------------------------------------------------------------
# v1.6: HSTS, drain endpoint, OpenMetrics EOF, proxy-protocol counters.
# ---------------------------------------------------------------------------


async def _hello(scope, receive, send):
    if scope["type"] == "lifespan":
        await _lifespan_drain(receive, send)
        return
    await receive()
    await send({"type": "http.response.start", "status": 200,
                "headers": [(b"content-type", b"text/plain")]})
    await send({"type": "http.response.body", "body": b"hi"})


def test_hsts_header_emitted_when_enabled():
    """--hsts-max-age N puts Strict-Transport-Security on every response;
    includeSubDomains + preload tokens are appended when their flags are
    on. Off by default — no header at max-age=0."""
    port = _free_port()
    _serve(_hello, port,
           hsts_max_age=63072000,
           hsts_include_subdomains=True,
           hsts_preload=True)
    r = httpx.get(f"http://127.0.0.1:{port}/", timeout=5.0 * _TIMING_FACTOR)
    assert r.status_code == 200
    sts = r.headers.get("strict-transport-security", "")
    assert "max-age=63072000" in sts
    assert "includeSubDomains" in sts
    assert "preload" in sts


def test_hsts_off_by_default():
    port = _free_port()
    _serve(_hello, port)
    r = httpx.get(f"http://127.0.0.1:{port}/", timeout=5.0 * _TIMING_FACTOR)
    assert "strict-transport-security" not in {k.lower() for k in r.headers.keys()}


def test_metrics_openmetrics_eof_marker():
    """/metrics body ends with `# EOF\\n` (OpenMetrics 1.0)."""
    port = _free_port()
    _serve(_hello, port, metrics_path="/metrics")
    httpx.get(f"http://127.0.0.1:{port}/", timeout=5.0 * _TIMING_FACTOR)
    r = httpx.get(f"http://127.0.0.1:{port}/metrics", timeout=5.0 * _TIMING_FACTOR)
    assert r.status_code == 200
    assert r.text.rstrip("\n").endswith("# EOF")


def test_drain_endpoint_get_idempotent():
    """GET on the drain path returns current state without flipping."""
    port = _free_port()
    _serve(_hello, port, drain_path="/admin/drain")
    r = httpx.get(f"http://127.0.0.1:{port}/admin/drain",
                  timeout=5.0 * _TIMING_FACTOR)
    assert r.status_code == 200
    assert r.json() == {"draining": False}
    # Confirm the worker still serves regular traffic.
    r2 = httpx.get(f"http://127.0.0.1:{port}/", timeout=5.0 * _TIMING_FACTOR)
    assert r2.status_code == 200


def test_drain_endpoint_method_not_allowed():
    """DELETE etc. return 405 — guards against curl typos."""
    port = _free_port()
    _serve(_hello, port, drain_path="/admin/drain")
    r = httpx.delete(f"http://127.0.0.1:{port}/admin/drain",
                     timeout=5.0 * _TIMING_FACTOR)
    assert r.status_code == 405
    assert "GET" in r.headers.get("allow", "")
