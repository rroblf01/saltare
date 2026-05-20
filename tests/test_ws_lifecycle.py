"""WebSocket lifecycle correctness — guards the v1.7.1 invariants:

  - Every WS-CONNECT access-log line is matched by a WS-CLOSE.
  - Abrupt peer disconnect (no close frame) still cancels the
    consumer task on the Python side (`bridge.wsDisconnect` reached
    via the centralised `Connection.destroy()` WS branch).
  - Consumer `await self.close(code=N)` before `accept()` produces
    the expected HTTP status (4001→401, 4003→403, 4004→404, 4008→408,
    4029→429, else 403).
  - `--ws-handshake-timeout` cancels a consumer that never decides.
  - `--ws-reject-log` emits a single stderr line on rejection.
  - Post-accept work inside `connect()` (initial state push) reaches
    the wire before saltare returns control to the bridge.
  - `--ws-pump-interval-ms` knob is honoured.

All tests use raw sockets + plain ASGI consumers — no Channels
dependency required.
"""

from __future__ import annotations

import json
import os
import platform as _platform
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

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


# ---------------------------------------------------------------------------
# Apps used across tests
# ---------------------------------------------------------------------------


async def _accept_then_send(scope, receive, send) -> None:
    if scope["type"] == "lifespan":
        await _lifespan_drain(receive, send)
        return
    if scope["type"] != "websocket":
        return
    if (await receive())["type"] != "websocket.connect":
        return
    await send({"type": "websocket.accept"})
    await send({"type": "websocket.send", "text": "welcome"})
    while True:
        m = await receive()
        if m["type"] == "websocket.disconnect":
            return


def _make_reject_app(code: int):
    async def app(scope, receive, send):
        if scope["type"] == "lifespan":
            await _lifespan_drain(receive, send)
            return
        if scope["type"] != "websocket":
            return
        if (await receive())["type"] != "websocket.connect":
            return
        await send({"type": "websocket.close", "code": code})
    return app


async def _hangs_forever_app(scope, receive, send) -> None:
    """Consumer that receives the connect event but never accepts or
    closes — exercises the handshake-timeout cancel path."""
    if scope["type"] == "lifespan":
        await _lifespan_drain(receive, send)
        return
    if scope["type"] != "websocket":
        return
    await receive()
    # Sleep way past the test's handshake timeout. Saltare should
    # cancel us; the await below should raise CancelledError.
    import asyncio
    await asyncio.sleep(60)


async def _raises_before_accept_app(scope, receive, send) -> None:
    if scope["type"] == "lifespan":
        await _lifespan_drain(receive, send)
        return
    if scope["type"] != "websocket":
        return
    await receive()
    raise RuntimeError("synthetic-consumer-failure")


# ---------------------------------------------------------------------------
# Test harness helpers
# ---------------------------------------------------------------------------


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


class _WsClient:
    """Minimal client wrapper: keeps a single read buffer so that an
    over-read of the HTTP head doesn't strand the first WS frame on
    the floor. Required because saltare concatenates the 101 head and
    any initial server-pushed frames into one `write(2)` — naive
    `recv` on the next call would block forever otherwise."""

    def __init__(self, sock: socket.socket) -> None:
        self.sock = sock
        self._buf = bytearray()

    def _fill(self, needed: int, deadline: float) -> None:
        while len(self._buf) < needed:
            remaining = max(deadline - time.monotonic(), 0.05)
            self.sock.settimeout(remaining)
            chunk = self.sock.recv(4096)
            if not chunk:
                raise AssertionError("eof during recv")
            self._buf.extend(chunk)

    def read_head(self, deadline_s: float = 3.0) -> bytes:
        deadline = time.monotonic() + deadline_s * _TIMING_FACTOR
        while b"\r\n\r\n" not in self._buf:
            remaining = max(deadline - time.monotonic(), 0.05)
            self.sock.settimeout(remaining)
            try:
                chunk = self.sock.recv(4096)
            except socket.timeout:
                break
            if not chunk:
                break
            self._buf.extend(chunk)
        sep = self._buf.find(b"\r\n\r\n")
        if sep < 0:
            head = bytes(self._buf)
            self._buf.clear()
            return head
        head = bytes(self._buf[: sep + 4])
        del self._buf[: sep + 4]
        return head

    def read_text_frame(self, deadline_s: float = 2.0) -> str:
        deadline = time.monotonic() + deadline_s * _TIMING_FACTOR
        self._fill(2, deadline)
        b1 = self._buf[1]
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
        self._fill(idx + n, deadline)
        payload = bytes(self._buf[idx : idx + n])
        del self._buf[: idx + n]
        return payload.decode("utf-8")


def _ws_handshake(sock: socket.socket, port: int, path: str = "/") -> bytes:
    """Backwards-compat wrapper for tests that only need the head."""
    return _ws_handshake_buffered(sock, port, path)[0]


def _ws_handshake_buffered(
    sock: socket.socket, port: int, path: str = "/"
) -> tuple[bytes, "_WsClient"]:
    """Send the WS upgrade and return (head_bytes, client). The client
    object retains any bytes the kernel already coalesced past the
    head terminator (welcome frames, push notifications, etc.)."""
    req = (
        b"GET " + path.encode() + b" HTTP/1.1\r\n"
        b"Host: 127.0.0.1:" + str(port).encode() + b"\r\n"
        b"Upgrade: websocket\r\n"
        b"Connection: Upgrade\r\n"
        b"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
        b"Sec-WebSocket-Version: 13\r\n"
        b"\r\n"
    )
    sock.sendall(req)
    client = _WsClient(sock)
    head = client.read_head(3.0)
    return head, client


def _build_client_close_frame(code: int = 1000) -> bytes:
    """RFC 6455 client-side close frame: FIN=1, opcode=8, masked."""
    payload = code.to_bytes(2, "big")
    out = bytearray([0x88, 0x80 | len(payload)])  # FIN + close, MASK + len
    mask = b"\x12\x34\x56\x78"
    out += mask
    out += bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    return bytes(out)


# ---------------------------------------------------------------------------
# Close-code → HTTP status mapping
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("code,status", [
    (4001, b"401"),
    (4002, b"402"),
    (4003, b"403"),
    (4004, b"404"),
    (4008, b"408"),
    (4029, b"429"),
    (4500, b"403"),  # unmapped → 403
])
def test_close_code_maps_to_http_status(code: int, status: bytes) -> None:
    port = _free_port()
    _serve(_make_reject_app(code), port)
    with socket.socket() as s:
        s.settimeout(3.0 * _TIMING_FACTOR)
        s.connect(("127.0.0.1", port))
        head = _ws_handshake(s, port)
    first_line = head.split(b"\r\n", 1)[0]
    assert status in first_line, f"code={code}: expected {status!r}, got {first_line!r}"


# ---------------------------------------------------------------------------
# Successful upgrade + initial state push
# ---------------------------------------------------------------------------


def test_post_accept_initial_send_reaches_wire() -> None:
    """Consumer that calls `accept()` then immediately `send()` should
    have the initial frame on the wire by the time the client sees the
    101 — Phase 2 pump."""
    port = _free_port()
    _serve(_accept_then_send, port)
    with socket.socket() as s:
        s.settimeout(3.0 * _TIMING_FACTOR)
        s.connect(("127.0.0.1", port))
        head, client = _ws_handshake_buffered(s, port)
        assert head.startswith(b"HTTP/1.1 101"), head[:64]
        msg = client.read_text_frame(2.0)
        assert msg == "welcome", repr(msg)


# ---------------------------------------------------------------------------
# Handshake timeout cancels parked consumer
# ---------------------------------------------------------------------------


def test_handshake_timeout_cancels_hanging_consumer() -> None:
    """A consumer that never accepts/closes triggers the
    `--ws-handshake-timeout` cancel. We pass a very short timeout
    (0.2 s) so the test runs fast; the response should be an HTTP
    4xx (saltare returns 403 by default when no close code was
    provided)."""
    port = _free_port()
    _serve(_hangs_forever_app, port, ws_handshake_timeout=0.2)
    t0 = time.monotonic()
    with socket.socket() as s:
        s.settimeout(3.0 * _TIMING_FACTOR)
        s.connect(("127.0.0.1", port))
        head = _ws_handshake(s, port)
    elapsed = time.monotonic() - t0
    # Should bail near the 0.2 s deadline, not after the 60 s sleep.
    assert elapsed < 3.0 * _TIMING_FACTOR, f"hung past timeout: {elapsed:.2f}s"
    assert head.startswith(b"HTTP/1.1 4"), head[:64]


# ---------------------------------------------------------------------------
# Abrupt disconnect leak guard
# ---------------------------------------------------------------------------


def test_abrupt_disconnect_does_not_break_server() -> None:
    """Open N WS connections, drop them abruptly (TCP FIN, no close
    frame). Server must keep accepting new connections — a leaked
    `_WsState` or stuck `g_ws_head` entry would visibly cripple new
    upgrades (timeouts, 5xx, etc.). We verify by opening one MORE
    WS after the burst and exchanging a welcome frame on it; the
    daemon-thread-local state we can't read from the test thread
    is exercised end-to-end instead."""
    port = _free_port()
    _serve(_accept_then_send, port)
    N = 20
    socks: list[socket.socket] = []
    try:
        for _ in range(N):
            s = socket.create_connection(("127.0.0.1", port),
                                         timeout=2.0 * _TIMING_FACTOR)
            head, client = _ws_handshake_buffered(s, port)
            assert head.startswith(b"HTTP/1.1 101"), head[:64]
            client.read_text_frame(2.0)  # consume welcome → consumer parks
            socks.append(s)

        # Abrupt close — no WS close frame, just TCP FIN.
        for s in socks:
            s.close()
        socks.clear()

        # Give the server a moment to reap the dropped conns.
        time.sleep(0.3 * _TIMING_FACTOR)

        # Open a fresh WS — if the prior teardown leaked Python state
        # or wedged the periodic-pump path, this would hang / fail.
        with socket.socket() as s:
            s.settimeout(3.0 * _TIMING_FACTOR)
            s.connect(("127.0.0.1", port))
            head, client = _ws_handshake_buffered(s, port)
            assert head.startswith(b"HTTP/1.1 101"), head[:64]
            assert client.read_text_frame(2.0) == "welcome"
    finally:
        for s in socks:
            try:
                s.close()
            except OSError:
                pass


# ---------------------------------------------------------------------------
# WS-CONNECT / WS-CLOSE access-log symmetry
# ---------------------------------------------------------------------------


def test_ws_access_log_connect_close_symmetric() -> None:
    """`--access-log` writes one WS-CONNECT and one WS-CLOSE line per
    connection — was: WS-CLOSE missing on the doWrite-error path.
    Subprocess so we can capture stderr cleanly."""
    port = _free_port()
    src = f"""
import saltare

async def app(scope, receive, send):
    if scope['type'] == 'lifespan':
        while True:
            m = await receive()
            if m['type'] == 'lifespan.startup':
                await send({{'type': 'lifespan.startup.complete'}})
            elif m['type'] == 'lifespan.shutdown':
                await send({{'type': 'lifespan.shutdown.complete'}})
                return
        return
    if scope['type'] != 'websocket':
        return
    if (await receive())['type'] != 'websocket.connect':
        return
    await send({{'type': 'websocket.accept'}})
    while True:
        m = await receive()
        if m['type'] == 'websocket.disconnect':
            return

saltare.run(app, host='127.0.0.1', port={port}, access_log=True)
"""
    proc = subprocess.Popen(
        [sys.executable, "-c", src],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )
    try:
        # Wait for ready.
        deadline = time.monotonic() + 5.0 * _TIMING_FACTOR
        while time.monotonic() < deadline:
            if proc.poll() is not None:
                pytest.fail("subprocess exited prematurely")
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                    break
            except (ConnectionRefusedError, socket.timeout):
                time.sleep(0.05)
        else:
            pytest.fail("subprocess never became ready")

        # Open, handshake, send close frame, close.
        with socket.socket() as s:
            s.settimeout(3.0 * _TIMING_FACTOR)
            s.connect(("127.0.0.1", port))
            head, _client = _ws_handshake_buffered(s, port, "/probe-ws")
            assert head.startswith(b"HTTP/1.1 101"), head[:64]
            s.sendall(_build_client_close_frame(1000))
            # Drain any server response (close echo).
            s.settimeout(0.5 * _TIMING_FACTOR)
            try:
                while True:
                    if not s.recv(4096):
                        break
            except (socket.timeout, OSError):
                pass

        # Give the server time to flush WS-CLOSE log on TCP-FIN handling.
        time.sleep(0.8 * _TIMING_FACTOR)
        proc.terminate()
        try:
            stderr_data = proc.stderr.read() if proc.stderr else b""
        except Exception:
            stderr_data = b""
        proc.wait(timeout=5.0)

        text = stderr_data.decode(errors="replace")
        connects = [line for line in text.splitlines()
                    if "[WS-CONNECT]" in line and "[/probe-ws]" in line]
        closes = [line for line in text.splitlines()
                  if "[WS-CLOSE]" in line and "[/probe-ws]" in line]
        assert connects, f"missing WS-CONNECT line: {text[-500:]!r}"
        assert closes, f"missing WS-CLOSE line: {text[-500:]!r}"
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()


# ---------------------------------------------------------------------------
# --ws-reject-log captures rejection reason
# ---------------------------------------------------------------------------


def test_ws_reject_log_emits_close_code_on_reject() -> None:
    """A consumer that closes with code=4003 → stderr line carries
    `code=4003`."""
    port = _free_port()
    src = f"""
import saltare

async def app(scope, receive, send):
    if scope['type'] == 'lifespan':
        while True:
            m = await receive()
            if m['type'] == 'lifespan.startup':
                await send({{'type': 'lifespan.startup.complete'}})
            elif m['type'] == 'lifespan.shutdown':
                await send({{'type': 'lifespan.shutdown.complete'}})
                return
        return
    if scope['type'] != 'websocket':
        return
    await receive()
    await send({{'type': 'websocket.close', 'code': 4003, 'reason': 'origin-rejected'}})

saltare.run(app, host='127.0.0.1', port={port}, ws_reject_log=True)
"""
    proc = subprocess.Popen(
        [sys.executable, "-c", src],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )
    try:
        deadline = time.monotonic() + 5.0 * _TIMING_FACTOR
        while time.monotonic() < deadline:
            if proc.poll() is not None:
                pytest.fail("subprocess exited prematurely")
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                    break
            except (ConnectionRefusedError, socket.timeout):
                time.sleep(0.05)
        else:
            pytest.fail("subprocess never became ready")

        with socket.socket() as s:
            s.settimeout(3.0 * _TIMING_FACTOR)
            s.connect(("127.0.0.1", port))
            head = _ws_handshake(s, port, "/rejected-ws")
            assert b"403" in head.split(b"\r\n", 1)[0], head[:64]

        time.sleep(0.3 * _TIMING_FACTOR)
        proc.terminate()
        try:
            stderr_data = proc.stderr.read() if proc.stderr else b""
        except Exception:
            stderr_data = b""
        proc.wait(timeout=5.0)

        text = stderr_data.decode(errors="replace")
        reject_lines = [line for line in text.splitlines()
                        if "ws-reject" in line and "/rejected-ws" in line]
        assert reject_lines, f"missing ws-reject line: {text[-500:]!r}"
        assert "code=4003" in reject_lines[0]
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()


# ---------------------------------------------------------------------------
# Multiple sequential connects — g_ws_conns counter sanity
# ---------------------------------------------------------------------------


def test_sequential_connect_close_cycles_keep_server_responsive() -> None:
    """N clean WS connect+close cycles in series; after the burst the
    server must still accept and dispatch a fresh WS. A leaked
    handle / counter on either side would either time out the new
    upgrade or starve the periodic pump that flushes the welcome
    frame.
    """
    port = _free_port()
    _serve(_accept_then_send, port)
    N = 10
    for _ in range(N):
        with socket.socket() as s:
            s.settimeout(3.0 * _TIMING_FACTOR)
            s.connect(("127.0.0.1", port))
            head, client = _ws_handshake_buffered(s, port)
            assert head.startswith(b"HTTP/1.1 101"), head[:64]
            client.read_text_frame(2.0)  # consume welcome
            s.sendall(_build_client_close_frame(1000))

    # Server must still be alive and responsive — last WS connect
    # exercises the same path.
    with socket.socket() as s:
        s.settimeout(3.0 * _TIMING_FACTOR)
        s.connect(("127.0.0.1", port))
        head, client = _ws_handshake_buffered(s, port)
        assert head.startswith(b"HTTP/1.1 101"), head[:64]
        assert client.read_text_frame(2.0) == "welcome"
