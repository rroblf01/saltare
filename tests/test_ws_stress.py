"""WebSocket stress: verify the v1.7.1 periodic-pump + drainWsOutbound
scale to many simultaneous connections receiving server-pushed frames
that originate OUTSIDE the request cycle (the `channel_layer.group_send`
pattern Channels apps use for chat / notification fan-out).

Without the periodic pump, a saltare WS connection that's idle on the
client side never sees server-pushed frames — the asyncio loop only
ran when bridge events fired. v1.7.1's main-loop tick + `wsDrainAll`
batch close that gap; this test confirms it under N concurrent conns.

The test uses saltare's own primitives (no Channels dependency): a
plain ASGI WebSocket consumer that subscribes to an in-process queue
and forwards every queued message to its client. We then start N
sockets, drop a burst of messages on the queue, and assert every
socket received them.
"""

from __future__ import annotations

import asyncio
import platform as _platform
import socket
import struct
import threading
import time
from typing import Any

import pytest

_TIMING_FACTOR: float = 4.0 if _platform.machine() in {"aarch64", "arm64"} else 1.0

_NUM_CONNS = 40        # well under default max_concurrent_connections (1024)
_BURST_MSGS = 5        # messages per connection in the burst
_RECV_DEADLINE_S = 5.0 * _TIMING_FACTOR


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


# In-process broadcast queue — every connect() adds an asyncio queue
# to the registry; the test thread calls `_broadcast(...)` which
# pushes the message into every registered queue from the saltare
# asyncio loop's perspective (via `loop.call_soon_threadsafe`).
_subscribers: list[asyncio.Queue] = []
_subscribers_lock = threading.Lock()
_loop_ref: list[asyncio.AbstractEventLoop] = []


def _broadcast(text: str) -> None:
    """Called from the test (main) thread. Schedules a put on every
    subscriber queue via the saltare worker's loop."""
    if not _loop_ref:
        return
    loop = _loop_ref[0]
    with _subscribers_lock:
        subs = list(_subscribers)
    for q in subs:
        loop.call_soon_threadsafe(q.put_nowait, text)


async def _broadcast_app(scope, receive, send) -> None:
    if scope["type"] == "lifespan":
        while True:
            msg = await receive()
            if msg["type"] == "lifespan.startup":
                # Snapshot the loop the dispatcher built so the test
                # thread can schedule callbacks back into it.
                _loop_ref.append(asyncio.get_running_loop())
                await send({"type": "lifespan.startup.complete"})
            elif msg["type"] == "lifespan.shutdown":
                await send({"type": "lifespan.shutdown.complete"})
                return
        return
    if scope["type"] != "websocket":
        return
    if (await receive())["type"] != "websocket.connect":
        return
    await send({"type": "websocket.accept"})

    queue: asyncio.Queue = asyncio.Queue()
    with _subscribers_lock:
        _subscribers.append(queue)

    try:
        while True:
            # Race: either the client sends us something (we ignore
            # the content) and we keep going, or a broadcast lands
            # on our queue and we forward it. asyncio.wait gives us
            # both edges.
            recv_task = asyncio.create_task(receive())
            queue_task = asyncio.create_task(queue.get())
            done, pending = await asyncio.wait(
                {recv_task, queue_task},
                return_when=asyncio.FIRST_COMPLETED,
            )
            for p in pending:
                p.cancel()
            if recv_task in done:
                ev = recv_task.result()
                if ev["type"] == "websocket.disconnect":
                    break
            if queue_task in done:
                try:
                    msg = queue_task.result()
                except asyncio.CancelledError:
                    continue
                await send({"type": "websocket.send", "text": msg})
    finally:
        with _subscribers_lock:
            try:
                _subscribers.remove(queue)
            except ValueError:
                pass


def _serve(port: int, **kwargs: Any) -> None:
    from saltare import run
    threading.Thread(
        target=run,
        args=(_broadcast_app,),
        kwargs={"host": "127.0.0.1", "port": port, **kwargs},
        daemon=True,
    ).start()
    deadline = time.monotonic() + 3.0 * _TIMING_FACTOR
    while time.monotonic() < deadline:
        try:
            with socket.socket() as s:
                s.settimeout(0.2)
                s.connect(("127.0.0.1", port))
                if _loop_ref:
                    return
        except (ConnectionRefusedError, socket.timeout, OSError):
            time.sleep(0.05)
    pytest.fail(f"server never came up on 127.0.0.1:{port}")


def _ws_handshake(sock: socket.socket, port: int) -> None:
    req = (
        b"GET / HTTP/1.1\r\n"
        b"Host: 127.0.0.1:" + str(port).encode() + b"\r\n"
        b"Upgrade: websocket\r\n"
        b"Connection: Upgrade\r\n"
        b"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
        b"Sec-WebSocket-Version: 13\r\n"
        b"\r\n"
    )
    sock.sendall(req)
    raw = b""
    deadline = time.monotonic() + 2.0 * _TIMING_FACTOR
    while b"\r\n\r\n" not in raw and time.monotonic() < deadline:
        chunk = sock.recv(4096)
        if not chunk:
            break
        raw += chunk
    assert raw.startswith(b"HTTP/1.1 101"), f"expected 101, got: {raw[:64]!r}"


def _read_text_frame(sock: socket.socket) -> str:
    hdr = b""
    while len(hdr) < 2:
        more = sock.recv(2 - len(hdr))
        if not more:
            raise AssertionError("eof during frame header")
        hdr += more
    b1 = hdr[1]
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
            raise AssertionError("eof during frame payload")
        payload += more
    return payload.decode("utf-8")


def _drain_n_messages(sock: socket.socket, n: int, deadline: float) -> list[str]:
    received: list[str] = []
    sock.settimeout(0.5)
    while len(received) < n and time.monotonic() < deadline:
        try:
            received.append(_read_text_frame(sock))
        except (socket.timeout, AssertionError):
            continue
    return received


@pytest.mark.flaky(reruns=2, reruns_delay=1)
def test_ws_periodic_pump_delivers_to_many_idle_connections() -> None:
    """N WS connections sit idle (no inbound traffic) while the test
    thread fires `_BURST_MSGS` broadcasts. v1.7.1's periodic asyncio
    pump + drainWsOutbound must deliver every broadcast to every
    connection — was: server-pushed frames sat in `_WsState.outgoing`
    until the next inbound event."""
    port = _free_port()
    _serve(port, ws_pump_interval_ms=20)  # 20 ms for snappier test

    socks: list[socket.socket] = []
    try:
        # Phase 1: open N connections, do the WS handshake on each.
        for _ in range(_NUM_CONNS):
            s = socket.create_connection(
                ("127.0.0.1", port),
                timeout=2.0 * _TIMING_FACTOR,
            )
            _ws_handshake(s, port)
            socks.append(s)
        # Give the pump one tick to settle every subscriber registration.
        time.sleep(0.1 * _TIMING_FACTOR)

        # Phase 2: send a burst of broadcasts.
        for i in range(_BURST_MSGS):
            _broadcast(f"msg-{i}")

        # Phase 3: every socket must receive every message within the
        # deadline. Order is not strictly guaranteed (asyncio scheduling),
        # so we collect-then-compare on a set.
        deadline = time.monotonic() + _RECV_DEADLINE_S
        expected = {f"msg-{i}" for i in range(_BURST_MSGS)}
        for idx, s in enumerate(socks):
            got = _drain_n_messages(s, _BURST_MSGS, deadline)
            assert set(got) == expected, \
                f"conn {idx}: expected {expected}, got {got}"
    finally:
        for s in socks:
            try:
                s.close()
            except OSError:
                pass
