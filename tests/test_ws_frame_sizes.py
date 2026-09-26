"""WebSocket frame sizes larger than the read buffer.

A single unfragmented frame bigger than the 4 KiB small pool buffer used
to be fatal. `doReadWs` compared the declared frame length against the
buffer and called `wsTeardown` when it did not fit, with a comment saying
it "will retry as fragmentation handler if it's the start of a legit
fragmented message" — but the branch never looked at `hdr.fin`, so a
plain unfragmented frame was killed too. Measured threshold: 3000 bytes
worked, 4096 failed, which is `pool.SMALL_DATA_SIZE` exactly. A client
saw a TCP reset mid-message.

The fix grows to the large buffer, the same way `doReadHttp` has always
done for a request head that does not fit. Past the large buffer the
frame genuinely cannot be buffered, and the peer is told so with close
**1009 (message too big)** — a code it can act on — instead of a silent
reset.

Ceilings worth stating plainly, since they are design and not accident:

  - single unfragmented frame: up to the 16 KiB large buffer
  - fragmented message: up to 1 MiB, reassembled into a heap buffer

That asymmetry is the same one the HTTP path has: beyond 16 KiB a request
body switches to *streaming*, which WebSocket framing cannot do without a
much larger redesign. Clients that need more should fragment, and the
1 MiB reassembly path is covered by `test_ws_deflate_wire.py` and here.

Raw sockets rather than the `websockets` library, per the v0.10 teardown
segfault documented in `tests/test_websocket.py`.
"""

from __future__ import annotations

import socket
import struct
import threading
import time

import pytest

_MASK = b"\x37\xfa\x21\x3d"

# pool.SMALL_DATA_SIZE and pool.LARGE_DATA_SIZE. A frame has to fit in
# the buffer it is read into, so these are the interesting boundaries.
SMALL = 4 * 1024
LARGE = 16 * 1024


async def _lifespan_echo(scope, receive, send):
    """Echoes text messages back, and records the length so a wrong
    payload is distinguishable from a lost one."""
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
                await send({"type": "websocket.send", "text": f"len:{len(text)}"})
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


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _frame(opcode: int, payload: bytes, *, fin: bool = True) -> bytes:
    """Masked client frame; RFC 6455 §5.3 requires client masking."""
    b0 = (0x80 if fin else 0) | opcode
    n = len(payload)
    if n < 126:
        head = bytes([b0, 0x80 | n])
    elif n < (1 << 16):
        head = bytes([b0, 0x80 | 126]) + struct.pack(">H", n)
    else:
        head = bytes([b0, 0x80 | 127]) + struct.pack(">Q", n)
    return head + _MASK + bytes(b ^ _MASK[i % 4] for i, b in enumerate(payload))


class _Client:
    def __init__(self, sock: socket.socket) -> None:
        self.sock = sock
        self.buf = bytearray()

    def _fill(self, need: int, deadline: float) -> None:
        while len(self.buf) < need:
            self.sock.settimeout(max(deadline - time.monotonic(), 0.1))
            chunk = self.sock.recv(65536)
            if not chunk:
                raise EOFError("eof")
            self.buf.extend(chunk)

    def handshake(self, port: int, seconds: float = 3.0) -> bytes:
        self.sock.sendall(
            f"GET / HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n"
            f"Upgrade: websocket\r\nConnection: Upgrade\r\n"
            f"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
            f"Sec-WebSocket-Version: 13\r\n\r\n".encode()
        )
        deadline = time.monotonic() + seconds
        while b"\r\n\r\n" not in self.buf:
            self.sock.settimeout(max(deadline - time.monotonic(), 0.1))
            chunk = self.sock.recv(4096)
            if not chunk:
                raise EOFError("eof before handshake")
            self.buf.extend(chunk)
        i = self.buf.find(b"\r\n\r\n")
        head = bytes(self.buf[: i + 4])
        del self.buf[: i + 4]
        return head

    def frame(self, seconds: float = 5.0) -> tuple[int, bytes]:
        """Return (opcode, payload) for the next frame."""
        deadline = time.monotonic() + seconds
        self._fill(2, deadline)
        b0, b1 = self.buf[0], self.buf[1]
        n = b1 & 0x7F
        idx = 2
        if n == 126:
            self._fill(idx + 2, deadline)
            n = struct.unpack(">H", bytes(self.buf[idx : idx + 2]))[0]
            idx += 2
        elif n == 127:
            self._fill(idx + 8, deadline)
            n = struct.unpack(">Q", bytes(self.buf[idx : idx + 8]))[0]
            idx += 8
        self._fill(idx + n, deadline)
        payload = bytes(self.buf[idx : idx + n])
        del self.buf[: idx + n]
        return b0 & 0x0F, payload


def _roundtrip(size: int, opcode: int = 0x1) -> tuple[str, object]:
    """Send one frame of `size` bytes. Returns ('echo', len) or
    ('close', code) — never raises, so the caller can assert on either."""
    port = _free_port()
    _serve(_lifespan_echo, port)
    sock = socket.create_connection(("127.0.0.1", port), timeout=5.0)
    try:
        client = _Client(sock)
        head = client.handshake(port)
        assert head.startswith(b"HTTP/1.1 101"), head[:80]
        sock.sendall(_frame(opcode, b"a" * size))
        op, payload = client.frame()
        if op == 0x8:
            code = struct.unpack(">H", payload[:2])[0] if len(payload) >= 2 else None
            return "close", code
        return "echo", payload.decode("latin-1")
    except (ConnectionResetError, EOFError) as exc:
        return "reset", type(exc).__name__
    finally:
        sock.close()


# ---------------------------------------------------------------------------
# The regression
# ---------------------------------------------------------------------------


def test_frame_just_over_the_small_buffer_used_to_be_fatal() -> None:
    """The exact shape of the bug: a single unfragmented text frame one
    byte over SMALL_DATA_SIZE. It must be echoed, not reset."""
    status, detail = _roundtrip(SMALL + 1)
    assert status == "echo", f"got {status} ({detail})"
    assert detail == f"len:{SMALL + 1}", detail


def test_five_kilobyte_frame_round_trips() -> None:
    """A 5 KB text message is unremarkable in a real application and was
    the size that reliably reproduced the reset."""
    status, detail = _roundtrip(5_000)
    assert status == "echo", f"got {status} ({detail})"
    assert detail == "len:5000", detail


@pytest.mark.parametrize("size", [500, 2_000, 3_000, 4_095, 4_096, 4_097,
                                  8_192, 12_000, 15_000])
def test_sizes_across_the_buffer_boundaries(size: int) -> None:
    """Every size from well inside the small buffer to just inside the
    large one, with the 4 KiB boundary called out explicitly since that
    is where the old code gave up."""
    status, detail = _roundtrip(size)
    assert status == "echo", f"size {size}: got {status} ({detail})"
    assert detail == f"len:{size}", f"size {size}: {detail}"


def test_binary_frame_larger_than_the_small_buffer() -> None:
    """The bug was not text-specific — it was the frame length check, so
    binary frames were killed at the same threshold. The echo app returns
    binary payloads verbatim, so this asserts the full round-trip."""
    port = _free_port()
    _serve(_lifespan_echo, port)
    sock = socket.create_connection(("127.0.0.1", port), timeout=5.0)
    try:
        client = _Client(sock)
        assert client.handshake(port).startswith(b"HTTP/1.1 101")
        payload = bytes(range(256)) * 40          # 10240, not a clean multiple
        sock.sendall(_frame(0x2, payload))
        op, got = client.frame()
        assert op == 0x2, f"opcode {op}, expected binary"
        assert got == payload, f"{len(got)} bytes back, expected {len(payload)}"
    finally:
        sock.close()


# ---------------------------------------------------------------------------
# Past the large buffer: a clean, actionable close
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("size", [LARGE + 1, 20_000, 64_000])
def test_oversized_single_frame_closes_with_1009(size: int) -> None:
    """Beyond the large buffer the frame cannot be buffered, so the peer
    is told why. 1009 is "message too big" (RFC 6455 §7.4.1) and is the
    only thing a client can act on — the old behaviour was a bare TCP
    reset, which no client can distinguish from a network fault."""
    status, detail = _roundtrip(size)
    assert status == "close", f"size {size}: got {status} ({detail})"
    assert detail == 1009, f"size {size}: close code {detail}"


def test_server_survives_an_oversized_frame() -> None:
    """The close is orderly: the listener is still healthy afterwards.
    A teardown here would also have been survivable, but the point of the
    1009 is that it is a *negotiated* end, so the connection state has to
    unwind cleanly."""
    port = _free_port()
    _serve(_lifespan_echo, port)

    first = socket.create_connection(("127.0.0.1", port), timeout=5.0)
    try:
        c = _Client(first)
        c.handshake(port)
        first.sendall(_frame(0x1, b"a" * 100_000))
        op, payload = c.frame()
        assert op == 0x8
        assert struct.unpack(">H", payload[:2])[0] == 1009
    finally:
        first.close()

    # A fresh connection must work, and a modest frame on it too.
    second = socket.create_connection(("127.0.0.1", port), timeout=5.0)
    try:
        c = _Client(second)
        assert c.handshake(port).startswith(b"HTTP/1.1 101")
        second.sendall(_frame(0x1, b"still fine"))
        op, payload = c.frame()
        assert op == 0x1
        assert payload == b"len:10", payload
    finally:
        second.close()


# ---------------------------------------------------------------------------
# Fragmentation still reaches its own, larger, ceiling
# ---------------------------------------------------------------------------


def test_fragmented_message_beyond_the_large_buffer() -> None:
    """A client that genuinely needs more than 16 KiB can fragment, and
    the reassembly path is unaffected by the fix — it allocates a heap
    buffer rather than reading into the pool buffer. 24 KiB in three
    fragments, each comfortably inside the small buffer."""
    port = _free_port()
    _serve(_lifespan_echo, port)
    sock = socket.create_connection(("127.0.0.1", port), timeout=5.0)
    try:
        client = _Client(sock)
        assert client.handshake(port).startswith(b"HTTP/1.1 101")
        chunk = 8_000
        sock.sendall(_frame(0x1, b"a" * chunk, fin=False))
        sock.sendall(_frame(0x0, b"b" * chunk, fin=False))
        sock.sendall(_frame(0x0, b"c" * chunk, fin=True))
        op, payload = client.frame()
        assert op == 0x1, f"opcode {op}"
        assert payload == f"len:{chunk * 3}".encode(), payload
    finally:
        sock.close()


def test_fragmented_message_totalling_100kb() -> None:
    """Well past the single-frame ceiling and past the large buffer, which
    is what WS_FRAG_MAX exists for."""
    port = _free_port()
    _serve(_lifespan_echo, port)
    sock = socket.create_connection(("127.0.0.1", port), timeout=10.0)
    try:
        client = _Client(sock)
        assert client.handshake(port).startswith(b"HTTP/1.1 101")
        total = 0
        parts = [10_000] * 10
        for i, n in enumerate(parts):
            total += n
            sock.sendall(_frame(0x1 if i == 0 else 0x0, b"z" * n,
                                fin=(i == len(parts) - 1)))
        op, payload = client.frame(seconds=10.0)
        assert op == 0x1
        assert payload == f"len:{total}".encode(), payload
    finally:
        sock.close()


# ---------------------------------------------------------------------------
# No regression on the connection accounting
# ---------------------------------------------------------------------------


def test_buffer_upgrade_does_not_leak_pool_buffers() -> None:
    """`upgradeBuffer` releases the small buffer back to the pool while
    keeping the partial frame, so a connection that sends one big frame
    must not strand two buffers per connection. Checked indirectly: many
    sequential large frames on separate connections all succeed, which a
    pool leak would eventually starve."""
    port = _free_port()
    _serve(_lifespan_echo, port)
    for i in range(40):
        sock = socket.create_connection(("127.0.0.1", port), timeout=5.0)
        try:
            client = _Client(sock)
            assert client.handshake(port).startswith(b"HTTP/1.1 101")
            sock.sendall(_frame(0x1, b"q" * 10_000))
            op, payload = client.frame()
            assert op == 0x1, f"iteration {i}: opcode {op}"
            assert payload == b"len:10000", (i, payload)
        finally:
            sock.close()


def test_repeated_large_frames_on_one_connection() -> None:
    """After the first large frame the connection is already on the large
    buffer, so subsequent frames must not re-upgrade or corrupt the
    stream."""
    port = _free_port()
    _serve(_lifespan_echo, port)
    sock = socket.create_connection(("127.0.0.1", port), timeout=5.0)
    try:
        client = _Client(sock)
        assert client.handshake(port).startswith(b"HTTP/1.1 101")
        for size in (5_000, 12_000, 200, 9_000, 15_000):
            sock.sendall(_frame(0x1, b"a" * size))
            op, payload = client.frame()
            assert op == 0x1, f"size {size}: opcode {op}"
            assert payload == f"len:{size}".encode(), (size, payload)
    finally:
        sock.close()
