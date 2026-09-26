"""WebSocket permessage-deflate (RFC 7692) over the wire.

`tests/test_ws_compression.py` covers the deflate/inflate primitives and
the negotiation function directly, by loading `_dispatcher.py` as a
standalone module. That proves the codecs round-trip; it does not prove
the *server* applies them. The gap is everything between:

  - the extension token in the 101 response head,
  - the RSV1 bit on the frames the server actually emits,
  - and the `ws_compression_level` / `ws_compression_server_takeover`
    run() kwargs, which no test passed at all — the existing suite only
    ever called the setter directly.

So this module speaks raw WebSocket frames. RFC 7692 payload framing is
the part worth being pedantic about: the sender compresses with a raw
DEFLATE stream (no zlib header, negative window bits), strips the
trailing `00 00 FF FF`, and the receiver appends it back before
inflating. Client-to-server frames must be masked (RFC 6455 §5.3).

Raw sockets rather than the `websockets` library on purpose. Five tests
in `tests/test_websocket.py` are permanently skipped because multiple
WebSocket tests in one pytest process hit a daemon-thread teardown
segfault, and the module docstring there says to verify WebSocket changes
one test per process. `tests/test_ws_lifecycle.py` shows raw sockets
avoid that entirely, which is what lets a whole WS module run in-suite.
"""

from __future__ import annotations

import socket
import struct
import threading
import time
import zlib

import pytest

_TIMING_FACTOR = 2.0

# RFC 7692: 4 octets appended to every message payload, present in the
# DEFLATE stream and stripped on the wire.
_PMD_TAIL = b"\x00\x00\xff\xff"

_MASK = b"\x37\xfa\x21\x3d"


# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


async def _lifespan_and_echo(scope, receive, send):
    """Echoes every text message back, prefixed so the test can tell the
    echo apart from anything the handshake pushed."""
    if scope["type"] == "lifespan":
        while True:
            msg = await receive()
            if msg["type"] == "lifespan.startup":
                await send({"type": "lifespan.startup.complete"})
            elif msg["type"] == "lifespan.shutdown":
                await send({"type": "lifespan.shutdown.complete"})
                return
        return
    if scope["type"] != "websocket":
        return
    while True:
        event = await receive()
        if event["type"] == "websocket.connect":
            await send({"type": "websocket.accept"})
        elif event["type"] == "websocket.receive":
            text = event.get("text")
            if text is not None:
                await send({"type": "websocket.send", "text": "echo:" + text})
            else:
                await send({"type": "websocket.send", "bytes": event["bytes"]})
        elif event["type"] == "websocket.disconnect":
            return


def _serve(app, port: int, **kwargs) -> None:
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
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return
        except (ConnectionRefusedError, socket.timeout, OSError):
            time.sleep(0.05)
    pytest.fail("server never became ready")


# ---------------------------------------------------------------------------
# Minimal RFC 6455 / RFC 7692 client
# ---------------------------------------------------------------------------


class _WsClient:
    """Single read buffer. saltare writes the 101 head and any immediate
    server frames in one go, so bytes past the head terminator have to be
    retained or the first frame is lost."""

    def __init__(self, sock: socket.socket) -> None:
        self.sock = sock
        self._buf = bytearray()

    def _fill(self, needed: int, deadline: float) -> None:
        while len(self._buf) < needed:
            self.sock.settimeout(max(deadline - time.monotonic(), 0.05))
            chunk = self.sock.recv(4096)
            if not chunk:
                raise AssertionError("eof during recv")
            self._buf.extend(chunk)

    def read_head(self, seconds: float = 3.0) -> bytes:
        deadline = time.monotonic() + seconds * _TIMING_FACTOR
        while b"\r\n\r\n" not in self._buf:
            self.sock.settimeout(max(deadline - time.monotonic(), 0.05))
            try:
                chunk = self.sock.recv(4096)
            except socket.timeout:
                break
            if not chunk:
                break
            self._buf.extend(chunk)
        sep = self._buf.find(b"\r\n\r\n")
        assert sep >= 0, f"no 101 head; got {bytes(self._buf)[:200]!r}"
        head = bytes(self._buf[: sep + 4])
        del self._buf[: sep + 4]
        return head

    def read_frame(self, seconds: float = 2.0) -> tuple[bool, bool, int, bytes]:
        """Return (fin, rsv1, opcode, payload) for the next frame."""
        deadline = time.monotonic() + seconds * _TIMING_FACTOR
        self._fill(2, deadline)
        b0, b1 = self._buf[0], self._buf[1]
        fin = bool(b0 & 0x80)
        rsv1 = bool(b0 & 0x40)
        opcode = b0 & 0x0F
        masked = bool(b1 & 0x80)
        n = b1 & 0x7F
        idx = 2
        if n == 126:
            self._fill(idx + 2, deadline)
            n = struct.unpack(">H", bytes(self._buf[idx : idx + 2]))[0]
            idx += 2
        elif n == 127:
            self._fill(idx + 8, deadline)
            n = struct.unpack(">Q", bytes(self._buf[idx : idx + 8]))[0]
            idx += 8
        if masked:  # a server must not mask, but stay honest
            self._fill(idx + 4, deadline)
            mask = bytes(self._buf[idx : idx + 4])
            idx += 4
        else:
            mask = b""
        self._fill(idx + n, deadline)
        payload = bytes(self._buf[idx : idx + n])
        del self._buf[: idx + n]
        if mask:
            payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        return fin, rsv1, opcode, payload

    def read_text(self, seconds: float = 2.0) -> str:
        _, _, opcode, payload = self.read_frame(seconds)
        assert opcode == 0x1, f"expected a text frame, got opcode {opcode}"
        return payload.decode("utf-8")


def _handshake(
    port: int, *, offer: str | None = "permessage-deflate", timeout: float = 3.0
) -> tuple[socket.socket, _WsClient, bytes]:
    """Perform the upgrade. `offer` is the raw Sec-WebSocket-Extensions
    value; None omits the header entirely."""
    sock = socket.create_connection(("127.0.0.1", port), timeout=timeout)
    req = (
        b"GET / HTTP/1.1\r\n"
        b"Host: 127.0.0.1:" + str(port).encode() + b"\r\n"
        b"Upgrade: websocket\r\n"
        b"Connection: Upgrade\r\n"
        b"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
        b"Sec-WebSocket-Version: 13\r\n"
    )
    if offer is not None:
        req += b"Sec-WebSocket-Extensions: " + offer.encode() + b"\r\n"
    req += b"\r\n"
    sock.sendall(req)
    client = _WsClient(sock)
    head = client.read_head()
    assert head.startswith(b"HTTP/1.1 101"), head[:120]
    return sock, client, head


def _head_value(head: bytes, name: bytes) -> str | None:
    for line in head.split(b"\r\n\r\n", 1)[0].split(b"\r\n")[1:]:
        if b":" in line:
            key, _, value = line.partition(b":")
            if key.strip().lower() == name.lower():
                return value.strip().decode()
    return None


def _deflate(payload: bytes, level: int = 6) -> bytes:
    """RFC 7692 payload: raw DEFLATE, trailing 4 octets removed.

    The 4 octets only appear with Z_SYNC_FLUSH — a plain Z_FINISH emits a
    proper final block instead and there is nothing to strip. That is
    exactly why RFC 7692 mandates the sync-flush form: it lets the
    compressor be reused across messages when context takeover is
    negotiated, and it gives the receiver a fixed, unambiguous tail.
    """
    compressor = zlib.compressobj(level, zlib.DEFLATED, -zlib.MAX_WBITS)
    out = compressor.compress(payload) + compressor.flush(zlib.Z_SYNC_FLUSH)
    assert out.endswith(_PMD_TAIL), (
        f"Z_SYNC_FLUSH did not end in the 4-octet tail: {out[-6:].hex()}"
    )
    return out[: -len(_PMD_TAIL)]


def _inflate(payload: bytes) -> bytes:
    """Reverse of `_deflate`: re-append the tail, then raw inflate."""
    return zlib.decompressobj(-zlib.MAX_WBITS).decompress(payload + _PMD_TAIL)


def _frame(opcode: int, body: bytes, *, compressed: bool) -> bytes:
    """Build a masked client-to-server frame with the correct length
    encoding for `body` (7-bit, 16-bit extended, or 64-bit extended)."""
    rsv1 = 0x40 if compressed else 0x00
    n = len(body)
    if n < 126:
        header = bytes([0x80 | rsv1 | opcode, 0x80 | n])
    elif n < (1 << 16):
        header = bytes([0x80 | rsv1 | opcode, 0x80 | 126]) + struct.pack(">H", n)
    else:
        header = bytes([0x80 | rsv1 | opcode, 0x80 | 127]) + struct.pack(">Q", n)
    return header + _MASK + bytes(b ^ _MASK[i % 4] for i, b in enumerate(body))


def _text_frame(text: str, *, compressed: bool) -> bytes:
    """Client-to-server text frame. Always masked, per RFC 6455 §5.3."""
    if compressed:
        return _frame(0x1, _deflate(text.encode()), compressed=True)
    return _frame(0x1, text.encode(), compressed=False)


def _binary_frame(raw: bytes, *, compressed: bool) -> bytes:
    if compressed:
        return _frame(0x2, _deflate(raw), compressed=True)
    return _frame(0x2, raw, compressed=False)


def _close_frame(code: int = 1000) -> bytes:
    payload = code.to_bytes(2, "big")
    return (
        bytes([0x88, 0x80 | len(payload)]) + _MASK
        + bytes(b ^ _MASK[i % 4] for i, b in enumerate(payload))
    )


# A payload with real redundancy, so compression actually shrinks it and a
# broken deflate cannot pass by accident on incompressible data.
_REDUNDANT = "saltare permessage-deflate round trip. " * 12


# ---------------------------------------------------------------------------
# Negotiation
# ---------------------------------------------------------------------------


def test_offer_is_answered_with_a_permessage_deflate_token() -> None:
    port = _free_port()
    _serve(_lifespan_and_echo, port, ws_compression_level=6)
    sock, _client, head = _handshake(port)
    try:
        token = _head_value(head, b"sec-websocket-extensions")
        assert token is not None, f"no extension negotiated:\n{head!r}"
        assert token.split(";")[0].strip() == "permessage-deflate", token
    finally:
        sock.close()


def test_no_offer_means_no_extension() -> None:
    """A client that does not ask for compression must not get RSV1 frames
    and must not be told it negotiated anything."""
    port = _free_port()
    _serve(_lifespan_and_echo, port, ws_compression_level=6)
    sock, client, head = _handshake(port, offer=None)
    try:
        assert _head_value(head, b"sec-websocket-extensions") is None, head
        sock.sendall(_text_frame("plain", compressed=False))
        assert client.read_text() == "echo:plain"
    finally:
        sock.close()


def test_uncompressed_frame_gets_a_compressed_reply() -> None:
    """A client that negotiates permessage-deflate may still send plain
    frames, and RFC 7692 §7.2 leaves the *sender* free to compress each
    message or not. saltare compresses its own outbound frames whenever
    the extension is active, independent of how the client framed its
    message.

    Pinned because it is a real obligation on the client: once you offer
    permessage-deflate you must be prepared to inflate compressed frames
    even for messages you sent uncompressed. An implementation that
    assumed "I sent plain, so the reply is plain" breaks against saltare.
    """
    port = _free_port()
    _serve(_lifespan_and_echo, port, ws_compression_level=6)
    sock, client, _head = _handshake(port)
    try:
        sock.sendall(_text_frame("plain frame", compressed=False))
        _fin, rsv1, opcode, payload = client.read_frame()
        assert opcode == 0x1, f"expected text, got opcode {opcode}"
        assert rsv1, "expected the server to compress its reply"
        assert _inflate(payload) == b"echo:plain frame", payload
    finally:
        sock.close()


# ---------------------------------------------------------------------------
# Framing on the wire
# ---------------------------------------------------------------------------


def test_compressed_message_round_trips_with_rsv1_set() -> None:
    """The headline check: the server inflates an RSV1 message and echoes
    it back compressed, with RSV1 set on its own frame."""
    port = _free_port()
    _serve(_lifespan_and_echo, port, ws_compression_level=6)
    sock, client, _head = _handshake(port)
    try:
        sock.sendall(_text_frame(_REDUNDANT, compressed=True))
        _fin, rsv1, opcode, payload = client.read_frame()
        assert opcode == 0x1, f"expected text, got opcode {opcode}"
        assert rsv1, "server did not set RSV1 on a compressed reply"
        assert _inflate(payload) == b"echo:" + _REDUNDANT.encode()
    finally:
        sock.close()


def test_compression_actually_shrinks_the_frame() -> None:
    """A server that sets RSV1 but sends the payload uncompressed would
    pass the round-trip check above only if the client inflated it — so
    pin the ratio too, which is the whole point of the feature."""
    port = _free_port()
    _serve(_lifespan_and_echo, port, ws_compression_level=9)
    sock, client, _head = _handshake(port)
    try:
        sock.sendall(_text_frame(_REDUNDANT, compressed=True))
        _fin, rsv1, _op, payload = client.read_frame()
        assert rsv1
        assert len(payload) < len(_REDUNDANT) // 4, (
            f"payload was {len(payload)} bytes for "
            f"{len(_REDUNDANT)} bytes of repetitive text"
        )
        assert _inflate(payload) == b"echo:" + _REDUNDANT.encode()
    finally:
        sock.close()


def test_binary_message_round_trips() -> None:
    """Compression applies to binary frames too, and the payload is not
    UTF-8 text. 2 KiB of every byte value also exercises the 16-bit
    extended-length path in the frame header."""
    port = _free_port()
    _serve(_lifespan_and_echo, port, ws_compression_level=6)
    sock, client, _head = _handshake(port)
    try:
        raw = bytes(range(256)) * 8
        sock.sendall(_binary_frame(raw, compressed=True))
        _fin, rsv1, opcode, payload = client.read_frame()
        assert opcode == 0x2, f"expected binary, got opcode {opcode}"
        assert rsv1
        assert _inflate(payload) == raw
    finally:
        sock.close()


def test_extended_length_frame_round_trips() -> None:
    """A payload past 125 bytes takes the 16-bit extended length path in
    the frame header, which is a separate encoder from the short form."""
    port = _free_port()
    _serve(_lifespan_and_echo, port, ws_compression_level=6)
    sock, client, _head = _handshake(port)
    try:
        big = "compressible " * 200  # > 64 KiB once uncompressed
        sock.sendall(_text_frame(big, compressed=True))
        _fin, rsv1, opcode, payload = client.read_frame()
        assert opcode == 0x1
        assert rsv1
        assert _inflate(payload) == b"echo:" + big.encode()
    finally:
        sock.close()


# ---------------------------------------------------------------------------
# Context takeover
# ---------------------------------------------------------------------------


def test_no_takeover_announces_both_directives() -> None:
    """Default is both sides resetting every message, so the server has
    to say so — otherwise the peer keeps a stale context and desyncs on
    the second message."""
    port = _free_port()
    _serve(_lifespan_and_echo, port, ws_compression_level=6)
    sock, _client, head = _handshake(port)
    try:
        token = _head_value(head, b"sec-websocket-extensions") or ""
        assert "client_no_context_takeover" in token, token
        assert "server_no_context_takeover" in token, token
    finally:
        sock.close()


def test_server_takeover_omits_the_server_directive() -> None:
    port = _free_port()
    _serve(_lifespan_and_echo, port,
           ws_compression_level=6, ws_compression_server_takeover=True)
    sock, _client, head = _handshake(port)
    try:
        token = _head_value(head, b"sec-websocket-extensions") or ""
        assert "server_no_context_takeover" not in token, (
            f"server announced no-takeover while configured for it: {token}"
        )
        # client_no_context_takeover is independent and stays on.
        assert "client_no_context_takeover" in token, token
    finally:
        sock.close()


def test_client_forbidding_server_takeover_is_honoured() -> None:
    """RFC 7692 lets the client veto server context takeover. The operator
    asking for takeover must not override the peer."""
    port = _free_port()
    _serve(_lifespan_and_echo, port,
           ws_compression_level=6, ws_compression_server_takeover=True)
    sock, _client, head = _handshake(
        port, offer="permessage-deflate; server_no_context_takeover"
    )
    try:
        token = _head_value(head, b"sec-websocket-extensions") or ""
        assert "server_no_context_takeover" in token, (
            f"client veto was ignored: {token}"
        )
    finally:
        sock.close()


def test_repeated_messages_survive_with_takeover_enabled() -> None:
    """With server takeover on, the deflater state carries across
    messages, so the *client's* inflater has to carry across them too or
    the second message references distances the fresh inflater has never
    seen ("invalid distance too far back").

    This is the direction that is easy to get wrong and that the existing
    unit tests cannot catch: `test_ws_compression.py` drives `_pmd_deflate`
    / `_pmd_inflate` directly with hand-managed contexts, so the
    negotiation and the frame codec were never exercised together.

    Note the asymmetry the test has to respect: the server also announced
    `client_no_context_takeover`, so the client→server direction resets
    every message and a fresh deflater per message is correct there. Only
    the server→client direction carries context.
    """
    port = _free_port()
    _serve(_lifespan_and_echo, port,
           ws_compression_level=6, ws_compression_server_takeover=True)
    sock, client, _head = _handshake(port)
    inflater = zlib.decompressobj(-zlib.MAX_WBITS)  # persistent, per takeover
    try:
        for i in range(6):
            text = f"message {i}: " + _REDUNDANT
            sock.sendall(_text_frame(text, compressed=True))
            _fin, rsv1, opcode, payload = client.read_frame()
            assert opcode == 0x1, f"message {i}: opcode {opcode}"
            assert rsv1, f"message {i}: RSV1 not set"
            got = inflater.decompress(payload + _PMD_TAIL)
            assert got == b"echo:" + text.encode(), (
                f"message {i} failed to round-trip under server takeover"
            )
    finally:
        sock.close()


def test_repeated_messages_survive_without_takeover() -> None:
    """The default configuration: every message resets, so each one must
    be independently inflatable."""
    port = _free_port()
    _serve(_lifespan_and_echo, port, ws_compression_level=6)
    sock, client, _head = _handshake(port)
    try:
        for i in range(6):
            text = f"message {i}: " + _REDUNDANT
            sock.sendall(_text_frame(text, compressed=True))
            _fin, rsv1, _op, payload = client.read_frame()
            assert rsv1, f"message {i}: RSV1 not set"
            assert _inflate(payload) == b"echo:" + text.encode(), (
                f"message {i} failed to round-trip"
            )
    finally:
        sock.close()


def test_compression_level_is_accepted_across_the_range() -> None:
    """`ws_compression_level` had no test that reached it. Levels 1 and 9
    both have to produce a working connection — an out-of-range or
    misparsed level would otherwise show up as a decode failure in
    production and nowhere in CI."""
    for level in (1, 6, 9):
        port = _free_port()
        _serve(_lifespan_and_echo, port, ws_compression_level=level)
        sock, client, head = _handshake(port)
        try:
            token = _head_value(head, b"sec-websocket-extensions")
            assert token is not None, f"level {level}: nothing negotiated"
            sock.sendall(_text_frame(_REDUNDANT, compressed=True))
            _fin, rsv1, _op, payload = client.read_frame()
            assert rsv1, f"level {level}: RSV1 not set"
            assert _inflate(payload) == b"echo:" + _REDUNDANT.encode(), (
                f"level {level}: payload did not round-trip"
            )
        finally:
            sock.close()
