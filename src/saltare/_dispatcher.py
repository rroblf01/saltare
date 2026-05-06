"""Per-request ASGI dispatcher.

Owns a persistent ``asyncio`` event loop that's reused across every request
for the lifetime of the server. The Zig core calls ``dispatch()`` from the
main thread, having re-acquired the GIL after parsing HTTP. ``dispatch()``
returns the full HTTP/1.1 wire response as ``bytes`` so the Zig side just
writes them to the socket.

Why persistent loop and not ``asyncio.run`` per request:
    Saving every Task/Future allocation matters for the project's RAM goal.
    A persistent loop costs ~a few KB once; ``asyncio.run`` would create
    and tear down a fresh ``EventLoop`` (~tens of KB) every request.

Limitations (intentional, scheduled for later milestones):
    - No lifespan protocol (FastAPI startup/shutdown hooks don't fire).
    - No keep-alive, no chunked Transfer-Encoding, no streaming bodies.
    - No WebSockets.
"""

from __future__ import annotations

import asyncio
import sys
import threading
import traceback
from typing import Any
from urllib.parse import unquote_to_bytes

# Per-thread state. In production there's exactly one `serve()` per process,
# so this collapses to a single namespace. In tests we run several saltare
# daemons concurrently (one per test) and they MUST NOT share an asyncio
# loop or task tables — that mixed up done-Task callbacks and ws handles
# across servers and produced segfaults during cleanup.
_state = threading.local()

# Process-wide flag for v0.15 X-Forwarded-* parsing. Off by default —
# enabling it on a server that *isn't* behind a trusted proxy lets clients
# spoof their address. Set via `saltare.run(proxy_headers=True)` (the
# wrapper calls `set_proxy_headers` before invoking _core.serve).
_proxy_headers_enabled = False


def set_proxy_headers(enabled: bool) -> None:
    """Toggle X-Forwarded-For / X-Forwarded-Proto handling. Called by the
    `saltare.run()` wrapper just before the I/O loop starts."""
    global _proxy_headers_enabled
    _proxy_headers_enabled = bool(enabled)


def _ensure_state() -> threading.local:
    if not hasattr(_state, "loop"):
        _state.loop = asyncio.new_event_loop()
        _state.ws_states = {}
        _state.next_ws_handle = 1
        _state.http_states = {}
        _state.next_http_handle = 1
        _state.lifespan_task = None
        _state.lifespan_receive_queue = None
        _state.lifespan_send_queue = None
    return _state


def _ensure_loop() -> asyncio.AbstractEventLoop:
    return _ensure_state().loop


_LIFESPAN_TIMEOUT = 10.0


async def _drive_lifespan_event(
    task: asyncio.Task,
    send_queue: asyncio.Queue,
    timeout: float = _LIFESPAN_TIMEOUT,
) -> tuple[str, Any]:
    """Wait for either a message from the app via send_queue, or for the
    lifespan task to finish. Returns a (kind, value) tuple where kind is one
    of: 'message', 'returned', 'exception', 'cancelled', 'timeout'."""
    receive_task = asyncio.create_task(send_queue.get())
    try:
        done, _pending = await asyncio.wait(
            {receive_task, task},
            return_when=asyncio.FIRST_COMPLETED,
            timeout=timeout,
        )
    finally:
        if not receive_task.done():
            receive_task.cancel()

    if receive_task in done:
        return ("message", receive_task.result())

    if task in done:
        if task.cancelled():
            return ("cancelled", None)
        try:
            task.result()
            return ("returned", None)
        except BaseException as exc:
            return ("exception", exc)

    return ("timeout", None)


def lifespan_startup(app: Any) -> bool:
    """Drive the app's lifespan startup. Returns True on success or if the
    app doesn't support lifespan; False on explicit startup failure or
    timeout. Called by the Zig bridge once, with the GIL held, before the
    I/O loop accepts any connection.
    """
    state = _ensure_state()
    loop = state.loop

    # If a previous serve() left a stale task around (rare; mostly a tests
    # concern), cancel it.
    if state.lifespan_task is not None and not state.lifespan_task.done():
        state.lifespan_task.cancel()
        try:
            loop.run_until_complete(state.lifespan_task)
        except BaseException:
            pass

    state.lifespan_receive_queue = asyncio.Queue()
    state.lifespan_send_queue = asyncio.Queue()

    rq, sq = state.lifespan_receive_queue, state.lifespan_send_queue

    async def lifespan_receive() -> dict[str, Any]:
        return await rq.get()

    async def lifespan_send(message: dict[str, Any]) -> None:
        await sq.put(message)

    scope: dict[str, Any] = {
        "type": "lifespan",
        "asgi": _ASGI_LIFESPAN_SUB,
    }

    state.lifespan_task = loop.create_task(app(scope, lifespan_receive, lifespan_send))
    rq.put_nowait({"type": "lifespan.startup"})

    kind, value = loop.run_until_complete(
        _drive_lifespan_event(state.lifespan_task, sq)
    )

    if kind == "message":
        msg_type = value.get("type") if isinstance(value, dict) else None
        if msg_type == "lifespan.startup.complete":
            return True
        if msg_type == "lifespan.startup.failed":
            sys.stderr.write(
                f"saltare: lifespan.startup.failed: "
                f"{value.get('message', '') if isinstance(value, dict) else ''}\n"
            )
            return False
        sys.stderr.write(f"saltare: unexpected lifespan startup message: {value}\n")
        return True

    if kind == "exception":
        # Per ASGI convention, an exception before any send() typically means
        # the app doesn't support lifespan. We log it and continue serving.
        sys.stderr.write(
            f"saltare: lifespan task raised during startup "
            f"({type(value).__name__}: {value}). Treating as 'no lifespan support'.\n"
        )
        return True

    if kind == "returned":
        # App finished its lifespan handler without sending startup.complete.
        # Tolerated: minimal apps sometimes just return.
        return True

    if kind == "timeout":
        sys.stderr.write(f"saltare: lifespan startup timed out ({_LIFESPAN_TIMEOUT}s)\n")
        return False

    return True


def lifespan_shutdown() -> None:
    """Drive the app's lifespan shutdown. Best-effort: errors are logged and
    the server proceeds to exit either way. Called by the Zig bridge once,
    with the GIL held, after the I/O loop has stopped accepting connections.
    """
    state = _ensure_state()
    if (
        state.lifespan_task is None
        or state.lifespan_receive_queue is None
        or state.lifespan_send_queue is None
    ):
        return

    loop = state.loop

    if state.lifespan_task.done():
        return

    state.lifespan_receive_queue.put_nowait({"type": "lifespan.shutdown"})

    kind, value = loop.run_until_complete(
        _drive_lifespan_event(state.lifespan_task, state.lifespan_send_queue)
    )

    if kind == "exception":
        sys.stderr.write(
            f"saltare: lifespan shutdown raised ({type(value).__name__}: {value})\n"
        )
    elif kind == "timeout":
        sys.stderr.write(f"saltare: lifespan shutdown timed out ({_LIFESPAN_TIMEOUT}s)\n")
        if not state.lifespan_task.done():
            state.lifespan_task.cancel()
            try:
                loop.run_until_complete(state.lifespan_task)
            except BaseException:
                pass


_REASONS: dict[int, str] = {
    200: "OK", 201: "Created", 202: "Accepted", 204: "No Content",
    301: "Moved Permanently", 302: "Found", 303: "See Other",
    304: "Not Modified", 307: "Temporary Redirect", 308: "Permanent Redirect",
    400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
    404: "Not Found", 405: "Method Not Allowed", 409: "Conflict",
    410: "Gone", 413: "Content Too Large", 415: "Unsupported Media Type",
    422: "Unprocessable Content", 429: "Too Many Requests",
    500: "Internal Server Error", 501: "Not Implemented",
    502: "Bad Gateway", 503: "Service Unavailable", 504: "Gateway Timeout",
}

_SERVER_HEADER = b"saltare/1.2.2"

# ASGI scope sub-dicts. These never change between requests, so caching them
# at module level avoids one dict allocation (~200 B) per dispatch. ASGI
# consumers are not allowed to mutate `scope["asgi"]` per spec, so sharing
# the same instance across all requests is safe.
_ASGI_LIFESPAN_SUB = {"version": "3.0", "spec_version": "2.0"}
_ASGI_HTTP_SUB = {"version": "3.0", "spec_version": "2.3"}
_ASGI_WS_SUB = {"version": "3.0", "spec_version": "2.3"}

# v1.2: pre-built wire-format byte constants. Each response used to rebuild
# `b"server: " + _SERVER_HEADER + b"\r\n"` (one `+` allocation), the
# Connection line via a branch on `keep_alive`, and the status line via an
# f-string + `.encode("ascii")`. Pre-caching the common ones drops several
# transient `bytes` allocations per response — especially noticeable in
# concurrent bursts where the GC churn from those tiny strings used to
# dominate the per-response Python work.
_SERVER_LINE = b"server: " + _SERVER_HEADER + b"\r\n"
_CONNECTION_KEEPALIVE_LINE = b"connection: keep-alive\r\n"
_CONNECTION_CLOSE_LINE = b"connection: close\r\n"
_TRANSFER_ENCODING_CHUNKED_LINE = b"transfer-encoding: chunked\r\n"
_CHUNKED_TERMINATOR = b"0\r\n\r\n"
_CRLF = b"\r\n"

# Status lines for the codes saltare emits or that user apps use heavily.
# Apps returning an unusual code fall back to the fmt path.
_STATUS_LINE_CACHE: dict[int, bytes] = {
    code: f"HTTP/1.1 {code} {reason}\r\n".encode("ascii")
    for code, reason in _REASONS.items()
}


def _status_line(status: int) -> bytes:
    cached = _STATUS_LINE_CACHE.get(status)
    if cached is not None:
        return cached
    reason = _REASONS.get(status, "OK")
    return f"HTTP/1.1 {status} {reason}\r\n".encode("ascii")


# ---------------------------------------------------------------------------
# WebSocket support.
#
# Each upgraded connection has a `_WsState` carrying:
#   - the app coroutine, scheduled as an asyncio.Task on the persistent loop
#   - a receive queue (events server pushes for the app to consume)
#   - an outbound buffer (encoded server-side WS frames the I/O loop drains)
#
# The Zig bridge calls `ws_open` once on upgrade, then `ws_event` per inbound
# frame, then `ws_disconnect` on close. Each call pushes an event into the
# receive queue and pumps the asyncio loop just long enough for the coro to
# reach its next `await receive()` — no run_until_complete (the coroutine
# never completes until close).


def _build_server_frame(opcode: int, payload: bytes) -> bytes:
    """RFC 6455 server-side frame (no masking). FIN=1, single fragment."""
    out = bytearray()
    out.append(0x80 | (opcode & 0x0F))
    n = len(payload)
    if n < 126:
        out.append(n)
    elif n < 65536:
        out.append(126)
        out += n.to_bytes(2, "big")
    else:
        out.append(127)
        out += n.to_bytes(8, "big")
    out += payload
    return bytes(out)


class _WsState:
    __slots__ = (
        "recv_queue", "outgoing", "outgoing_bytes", "accepted", "closed", "task",
    )

    def __init__(self, app: Any, scope: dict[str, Any]) -> None:
        self.recv_queue: asyncio.Queue = asyncio.Queue()
        self.outgoing: list[bytes] = []
        # Running total of bytes queued in `outgoing` since the last drain.
        # Bounds the worst-case RAM cost of a slow client + fast app.
        self.outgoing_bytes: int = 0
        self.accepted: bool = False
        self.closed: bool = False

        async def receive() -> dict[str, Any]:
            return await self.recv_queue.get()

        def _queue(frame: bytes) -> bool:
            # Returns False once the cap is exceeded so callers can stop
            # producing. The connection is marked closed; the next pump
            # tears it down.
            if self.outgoing_bytes + len(frame) > _WS_OUTGOING_MAX_BYTES:
                self.closed = True
                return False
            self.outgoing.append(frame)
            self.outgoing_bytes += len(frame)
            return True

        async def send(message: dict[str, Any]) -> None:
            mtype = message.get("type")
            if mtype == "websocket.accept":
                self.accepted = True
            elif mtype == "websocket.send":
                if self.closed:
                    return
                if message.get("text") is not None:
                    _queue(_build_server_frame(0x1, message["text"].encode("utf-8")))
                elif message.get("bytes") is not None:
                    _queue(_build_server_frame(0x2, message["bytes"]))
            elif mtype == "websocket.close":
                code = int(message.get("code", 1000))
                reason = message.get("reason", "") or ""
                payload = code.to_bytes(2, "big") + reason.encode("utf-8")
                _queue(_build_server_frame(0x8, payload))
                self.closed = True

        loop = _ensure_loop()
        self.task: asyncio.Task = loop.create_task(app(scope, receive, send))

    def push(self, event: dict[str, Any]) -> None:
        self.recv_queue.put_nowait(event)

    def drain(self) -> bytes:
        if not self.outgoing:
            return b""
        out = b"".join(self.outgoing)
        self.outgoing.clear()
        self.outgoing_bytes = 0
        return out


def _pump_once() -> None:
    """Process one batch of ready callbacks on the loop. We use the
    `_run_once` private method directly: it's the cheapest way to advance
    coroutines parked on a Future that we've just resolved (via Queue.put)
    without the overhead of wrapping a marker coroutine in a Task.

    A no-op `call_soon` is scheduled before each tick so `_run_once` sees
    `_ready` as non-empty and uses `timeout=0` for its selector poll. Without
    this, an app awaiting on `asyncio.sleep(N)` between sends would block
    the entire I/O loop for N seconds inside the asyncio selector.
    """
    loop = _ensure_loop()
    loop.call_soon(_no_op)
    # Each WS event we process needs the loop to "see" itself as the
    # currently running loop, otherwise asyncio.get_running_loop() inside
    # any framework code (FastAPI, Starlette) raises.
    asyncio.events._set_running_loop(loop)
    try:
        loop._run_once()
    finally:
        asyncio.events._set_running_loop(None)


def _no_op() -> None:
    pass


def http_global_pump() -> None:
    """One iteration of the asyncio loop. Advances every in-flight Task by
    one step concurrently; cheaper than per-connection multi-pumping when
    many requests are in flight (work is amortized across all of them).

    Called by the Zig main loop once per iteration whenever the stalled
    list is non-empty. The loop also calls this implicitly through
    `http_dispatch_start` and `http_dispatch_push_body` for the
    common-case fast path where a simple app completes in one tick.
    """
    _pump_once()


def ws_open(
    app: Any,
    method: str,
    raw_path: bytes,
    query_string: bytes,
    raw_headers: list[tuple[bytes, bytes]],
    server_host: str,
    server_port: int,
    scheme: str,
) -> tuple[int, bool, bytes, bool]:
    """Start a WebSocket coroutine, push the websocket.connect event, and
    pump the loop. Returns (handle, accepted, frames, done):
       handle:   opaque int the bridge keeps for subsequent ws_event calls.
       accepted: True if the app called websocket.accept.
       frames:   already-encoded server frames to write (close, early sends).
       done:     True if the coroutine finished (clean close).
    """
    global _next_ws_handle

    try:
        path = unquote_to_bytes(raw_path).decode("utf-8")
    except UnicodeDecodeError:
        return (0, False, b"", True)

    # Same as the HTTP path: names already lowercase from the bridge.
    headers = raw_headers

    scope: dict[str, Any] = {
        "type": "websocket",
        "asgi": _ASGI_WS_SUB,
        "http_version": "1.1",
        "scheme": "wss" if scheme == "https" else "ws",
        "path": path,
        "raw_path": raw_path,
        "query_string": query_string,
        "headers": headers,
        "server": (server_host, server_port),
        "client": None,
        "root_path": "",
        "subprotocols": [],
        "method": method,
    }

    tstate = _ensure_state()
    handle = tstate.next_ws_handle
    tstate.next_ws_handle += 1

    ws_state = _WsState(app, scope)
    tstate.ws_states[handle] = ws_state
    ws_state.push({"type": "websocket.connect"})

    try:
        _pump_once()
    except BaseException:
        traceback.print_exc(file=sys.stderr)

    return (handle, ws_state.accepted, ws_state.drain(), ws_state.task.done())


def ws_event(handle: int, opcode: int, payload: bytes) -> tuple[bytes, bool]:
    """Deliver a WebSocket frame to the running coroutine. `opcode` is 1
    (text) or 2 (binary). Returns (frames_to_send, done)."""
    tstate = _ensure_state()
    ws_state = tstate.ws_states.get(handle)
    if ws_state is None or ws_state.task.done():
        return (b"", True)

    if opcode == 0x1:
        try:
            text = payload.decode("utf-8")
        except UnicodeDecodeError:
            return (b"", True)
        ws_state.push({"type": "websocket.receive", "text": text})
    elif opcode == 0x2:
        ws_state.push({"type": "websocket.receive", "bytes": payload})
    else:
        return (b"", True)

    try:
        _pump_once()
    except BaseException:
        traceback.print_exc(file=sys.stderr)

    return (ws_state.drain(), ws_state.task.done())


def ws_disconnect(handle: int, code: int) -> bytes:
    """Tell the coroutine the connection has been (or is being) torn down,
    drain any final frames, and clean up the state. After this call the
    handle is gone; further ws_event calls return done=True immediately."""
    tstate = _ensure_state()
    ws_state = tstate.ws_states.pop(handle, None)
    if ws_state is None:
        return b""

    if not ws_state.task.done():
        ws_state.push({"type": "websocket.disconnect", "code": code})
        try:
            _pump_once()
        except BaseException:
            traceback.print_exc(file=sys.stderr)

    if not ws_state.task.done():
        ws_state.task.cancel()
        try:
            _pump_once()
        except BaseException:
            pass

    return ws_state.drain()


# ---------------------------------------------------------------------------
# HTTP streaming dispatch (v0.12).
#
# Each in-flight HTTP request is a long-lived asyncio.Task. The Zig core
# pumps it via four entry points:
#
#   http_dispatch_start(app, ..., initial_body, more_body)
#       Build the ASGI scope, create the Task, push the first request.
#       chunk to its receive queue, pump the loop once. Return any wire
#       bytes the app produced (typically status line + headers + first
#       body chunk if the app responded synchronously).
#
#   http_dispatch_push_body(handle, body, more_body)
#       More request-body bytes arrived. Push them into the Task's receive
#       queue and pump. Return any newly-produced wire bytes.
#
#   http_dispatch_tick(handle)
#       Drain remaining response chunks without pushing input. Used by Zig
#       between socket-write events to pull more chunks the app may have
#       produced after its last `await send()`.
#
#   http_dispatch_abort(handle)
#       Connection went away mid-stream. Cancel the Task, clean up.
#
# Wire-format building lives entirely in Python: each `http.response.start`
# stages headers; the first `http.response.body` decides Content-Length vs
# Transfer-Encoding: chunked based on whether the app declared a length and
# whether more body chunks are coming. Subsequent chunks are wrapped in
# chunked-encoding frames if needed. Zig just writes raw bytes.


def _encode_chunk(body: bytes) -> bytes:
    """RFC 7230 chunked-encoding frame for a single non-empty chunk."""
    return f"{len(body):x}\r\n".encode("ascii") + body + b"\r\n"


# Module-level free list for `_HttpState` instances. `_HttpState` has 13
# slots; recycling instead of constructing fresh saves the slot-allocation
# step (~200 B of GC churn) per request and reuses the `outgoing` list
# (one less `list` object created per request). Capped to keep idle pool
# memory bounded — beyond `_HTTP_POOL_MAX` the GC reclaims naturally.
#
# v1.2.2: bumped 32 → 128. With max_concurrent_connections defaulting to
# 1024, bursts above 32 reused to fall back to fresh `_HttpState`
# allocations. 128 covers realistic concurrency curves while idle pool
# RAM stays bounded (~128 × 600 B = 75 KiB).
_http_state_pool: list["_HttpState"] = []
_HTTP_POOL_MAX = 128

# Soft backpressure threshold. After an `await send()` chain has appended
# more than this many bytes to `outgoing`, the next send yields back to the
# event loop (one `await asyncio.sleep(0)`). The Zig main loop pumps the
# loop and harvests bytes via `http_dispatch_drain`, capping per-task
# accumulated outgoing memory at ~one threshold's worth. Apps streaming
# many small chunks at once (server-sent events, log tails) used to pin
# arbitrary RAM here; now they don't.
_HTTP_SEND_YIELD_BYTES = 64 * 1024

# Hard cap on per-WS connection outgoing buffer. A slow consumer with a
# fast producer used to grow `outgoing` without bound. Above the cap we
# mark the connection closed; the bridge tears it down on the next pump.
_WS_OUTGOING_MAX_BYTES = 1024 * 1024


def _acquire_http_state(
    app: Any,
    scope: dict[str, Any],
    initial_body: bytes,
    more_body: bool,
    keep_alive: bool,
) -> "_HttpState":
    if _http_state_pool:
        s = _http_state_pool.pop()
        s.reset(app, scope, initial_body, more_body, keep_alive)
        return s
    return _HttpState(app, scope, initial_body, more_body, keep_alive)


def _release_http_state(s: "_HttpState") -> None:
    if len(_http_state_pool) < _HTTP_POOL_MAX:
        # `task` and `out_headers` are released-by-reset on the next
        # acquire; we don't have to wipe them now. Just append.
        _http_state_pool.append(s)


class _HttpState:
    __slots__ = (
        # Single-slot mailbox: holds the next request event for the app's
        # `await receive()`. None when the queue is empty.
        "_pending_event",
        # When the app awaits receive() and there is no pending event, we
        # park it on this Future. The next `push_body` / `push_disconnect`
        # resolves it. Replaces v0.12's `asyncio.Queue` per request — saves
        # ~300 B of GC churn (Queue + internal deque + getters list) for
        # the typical request that does receive() once and is done.
        "_recv_future",
        "outgoing",
        # Running byte total of `outgoing` since the last drain. Drives the
        # `_HTTP_SEND_YIELD_BYTES` backpressure check in `_send` so a busy
        # streaming app yields back to the loop instead of pinning RAM.
        "_outgoing_bytes",
        "task",
        "status",
        "out_headers",
        "headers_sent",
        "chunked",
        "explicit_cl",
        "ka",
        "headers_done",
        "body_done",
    )

    def __init__(
        self,
        app: Any,
        scope: dict[str, Any],
        initial_body: bytes,
        more_body: bool,
        keep_alive: bool,
    ) -> None:
        # Initial request event sits in the mailbox; receive() pops it.
        self._pending_event: dict[str, Any] | None = {
            "type": "http.request",
            "body": initial_body,
            "more_body": more_body,
        }
        self._recv_future: asyncio.Future | None = None
        # Wire bytes produced by the app, drained by the I/O loop.
        self.outgoing: list[bytes] = []
        self._outgoing_bytes: int = 0
        # Filled in when http.response.start arrives.
        self.status: int = 500
        self.out_headers: list[tuple[bytes, bytes]] = []
        self.headers_sent: bool = False
        self.headers_done: bool = False
        # True once a body chunk with more_body=False has been processed.
        # _finalize_if_needed checks this to avoid emitting a duplicate
        # chunked terminator when the app already sent its last chunk.
        self.body_done: bool = False
        # Decided when the first http.response.body is observed (we need to
        # know if more chunks are coming to pick Content-Length vs chunked).
        self.chunked: bool = False
        self.explicit_cl: bool = False
        self.ka: bool = bool(keep_alive)

        loop = _ensure_loop()
        # `self._receive` and `self._send` are bound methods; they replace
        # the per-`__init__` closures used through v1.1. Bound methods
        # are about half the size of a closure (no per-instance cell
        # for the captured `self`) and they share the same underlying
        # compiled function across every instance — so for pooled
        # `_HttpState`s we don't even rebuild the compiled code.
        self.task: asyncio.Task = loop.create_task(
            app(scope, self._receive, self._send)
        )
        # The initial request event is already in `_pending_event`; the
        # app will pick it up on its first `await receive()`.

    async def _receive(self) -> dict[str, Any]:
        # Fast path: an event is already in the mailbox.
        ev = self._pending_event
        if ev is not None:
            self._pending_event = None
            return ev
        # Park on a Future; the next push_* will resolve it. Re-creating
        # the Future per await is unavoidable because asyncio's contract
        # is one-shot — but it's cheaper than a Queue + deque + getters.
        loop = asyncio.get_running_loop()
        self._recv_future = loop.create_future()
        try:
            return await self._recv_future
        finally:
            self._recv_future = None

    async def _send(self, message: dict[str, Any]) -> None:
        mtype = message.get("type")
        if mtype == "http.response.start":
            if self.headers_done:
                return  # ASGI: ignore double-start
            self.status = int(message.get("status", 500))
            self.out_headers = list(message.get("headers", []))
            self.explicit_cl = any(
                name.lower() == b"content-length"
                for name, _ in self.out_headers
            )
            self.headers_done = True
        elif mtype == "http.response.body":
            chunk = message.get("body", b"") or b""
            more = bool(message.get("more_body", False))
            if not self.headers_sent:
                if not self.headers_done:
                    return  # ASGI violation; bail without crashing
                self._emit_headers(
                    streaming=more,
                    complete_body_len=None if more else len(chunk),
                )
                self.headers_sent = True
            if chunk:
                if self.chunked:
                    framed = _encode_chunk(chunk)
                    self.outgoing.append(framed)
                    self._outgoing_bytes += len(framed)
                else:
                    self.outgoing.append(chunk)
                    self._outgoing_bytes += len(chunk)
            if not more:
                if self.chunked:
                    self.outgoing.append(_CHUNKED_TERMINATOR)
                    self._outgoing_bytes += len(_CHUNKED_TERMINATOR)
                self.body_done = True
            # Backpressure: if a streaming app has accumulated more than
            # `_HTTP_SEND_YIELD_BYTES` since the last drain, hand control
            # back to the event loop. The Zig main loop's stalled-pump
            # path harvests via `http_dispatch_drain`, which clears
            # `_outgoing_bytes` and lets us keep producing without
            # pinning unbounded RAM. Skipped on the final chunk so a
            # one-shot response never pays the yield cost.
            if more and self._outgoing_bytes >= _HTTP_SEND_YIELD_BYTES:
                await asyncio.sleep(0)
        # Ignored message types (http.response.trailers etc.) silently drop.

    def reset(
        self,
        app: Any,
        scope: dict[str, Any],
        initial_body: bytes,
        more_body: bool,
        keep_alive: bool,
    ) -> None:
        """Reuse this `_HttpState` for a new request after pulling it from
        the module-level pool. Every slot is rewritten so nothing leaks
        from the previous request. Identical effect to constructing a
        fresh instance, just without the slot-allocation churn."""
        self._pending_event = {
            "type": "http.request",
            "body": initial_body,
            "more_body": bool(more_body),
        }
        self._recv_future = None
        # Reuse the existing list — `clear()` is in-place; no new list
        # allocation. Marginal but cumulative across requests.
        self.outgoing.clear()
        self._outgoing_bytes = 0
        self.status = 500
        self.out_headers = []
        self.headers_sent = False
        self.headers_done = False
        self.body_done = False
        self.chunked = False
        self.explicit_cl = False
        self.ka = bool(keep_alive)

        loop = _ensure_loop()
        self.task = loop.create_task(app(scope, self._receive, self._send))

    def _emit_headers(
        self, streaming: bool, complete_body_len: int | None
    ) -> None:
        parts: list[bytes] = [
            _status_line(self.status),
            _SERVER_LINE,
            _CONNECTION_KEEPALIVE_LINE if self.ka else _CONNECTION_CLOSE_LINE,
        ]

        if streaming:
            if self.explicit_cl:
                # App declared length: trust it and emit raw.
                self.chunked = False
            else:
                # Streaming with no declared length → chunked encoding.
                self.chunked = True
        else:
            # Single-shot (more_body=False on the first body chunk).
            if not self.explicit_cl:
                parts.append(
                    f"content-length: {complete_body_len or 0}\r\n".encode("ascii")
                )

        for name, value in self.out_headers:
            lname = name.lower()
            # saltare owns Connection and (when chunked) Transfer-Encoding.
            if lname == b"connection":
                continue
            if self.chunked and lname == b"transfer-encoding":
                continue
            parts.append(name + b": " + value + b"\r\n")

        if self.chunked:
            parts.append(_TRANSFER_ENCODING_CHUNKED_LINE)

        parts.append(_CRLF)
        self.outgoing.extend(parts)

    def push_body(self, body: bytes, more_body: bool) -> None:
        self._deliver({"type": "http.request", "body": body, "more_body": more_body})

    def push_disconnect(self) -> None:
        self._deliver({"type": "http.disconnect"})

    def _deliver(self, event: dict[str, Any]) -> None:
        """Hand `event` to the app's pending `await receive()`. If a Future
        is parked we resolve it directly (the app resumes on the next loop
        tick); otherwise the event sits in the mailbox until receive() is
        called. Mirrors the old `asyncio.Queue.put_nowait` semantics
        without the queue."""
        fut = self._recv_future
        if fut is not None and not fut.done():
            fut.set_result(event)
        else:
            self._pending_event = event

    def drain(self) -> bytes:
        if not self.outgoing:
            return b""
        out = b"".join(self.outgoing)
        self.outgoing.clear()
        self._outgoing_bytes = 0
        return out


def _finalize_if_needed(handle: int, s: _HttpState) -> bytes:
    """If the app finished without ever emitting headers/body, synthesize
    a 500 so the wire is a valid HTTP response. Otherwise, if it sent
    headers but never sent a final more_body=False, close out the chunked
    stream. Returns extra wire bytes to append."""
    extra = b""
    if not s.headers_sent:
        # App returned without responding at all → 500.
        extra = _build_wire(
            500,
            [(b"content-type", b"text/plain; charset=utf-8")],
            b"Internal Server Error\n",
            keep_alive=False,
        )
    elif s.chunked and not s.body_done:
        # App finished but didn't send the terminating empty chunk. RFC 7230
        # requires `0\r\n\r\n` to delimit a chunked response.
        extra = _CHUNKED_TERMINATOR
    return extra


def http_dispatch_start(
    app: Any,
    method: str,
    raw_path: bytes,
    query_string: bytes,
    raw_headers: list[tuple[bytes, bytes]],
    initial_body: bytes,
    more_body: int,
    server_host: str,
    server_port: int,
    keep_alive: int,
    scheme: str,
) -> tuple[int, bytes, bool]:
    """Begin a streaming dispatch. Returns (handle, initial_chunks, done).

    handle:         opaque int Zig keeps for subsequent push_body / tick / abort calls.
    initial_chunks: any wire bytes the app produced before suspending. For
                    fast non-streaming apps this is the *full* response.
    done:           True if the Task finished in this initial pump.
    """
    state_obj = _ensure_state()

    try:
        path = unquote_to_bytes(raw_path).decode("utf-8")
    except UnicodeDecodeError:
        return (
            0,
            _build_wire(400, [], b"path is not valid UTF-8\n", keep_alive=False),
            True,
        )

    # Header names are already lowercased by the bridge (`buildHeadersList`
    # lowercases in-place in Zig before building the PyBytes list), so the
    # dispatcher can iterate `raw_headers` directly without an extra
    # `.lower()` pass and the per-header tuple rebuild it forced.
    headers = raw_headers
    effective_scheme = scheme
    effective_client: tuple[str, int] | None = None

    if _proxy_headers_enabled:
        for name, value in headers:
            if name == b"x-forwarded-for":
                # Convention: leftmost IP is the original client; entries
                # to the right are intermediate proxies. We trust the
                # whole chain here — saltare assumes the immediate peer
                # is a trusted proxy that already filtered spoofed values.
                first = value.split(b",", 1)[0].strip()
                if first:
                    try:
                        ip = first.decode("ascii")
                        effective_client = (ip, 0)
                    except UnicodeDecodeError:
                        pass
            elif name == b"x-forwarded-proto":
                proto = value.strip().lower()
                if proto in (b"http", b"https"):
                    effective_scheme = proto.decode("ascii")

    scope: dict[str, Any] = {
        "type": "http",
        "asgi": _ASGI_HTTP_SUB,
        "http_version": "1.1",
        "method": method,
        "scheme": effective_scheme,
        "path": path,
        "raw_path": raw_path,
        "query_string": query_string,
        "headers": headers,
        "server": (server_host, server_port),
        "client": effective_client,
        "root_path": "",
    }

    handle = state_obj.next_http_handle
    state_obj.next_http_handle += 1

    s = _acquire_http_state(app, scope, initial_body, bool(more_body), bool(keep_alive))
    state_obj.http_states[handle] = s

    try:
        _pump_once()
    except BaseException:
        traceback.print_exc(file=sys.stderr)

    chunks = s.drain()
    done = s.task.done()

    if done:
        # Surface any task exception so it isn't silently swallowed.
        if not s.task.cancelled():
            exc = s.task.exception()
            if exc is not None:
                traceback.print_exception(type(exc), exc, exc.__traceback__, file=sys.stderr)
                # If we never emitted a response, give the client a 500.
                if not s.headers_sent:
                    chunks = chunks + _build_wire(
                        500,
                        [(b"content-type", b"text/plain; charset=utf-8")],
                        b"Internal Server Error\n",
                        keep_alive=False,
                    )
                    state_obj.http_states.pop(handle, None)
                    _release_http_state(s)
                    return (handle, chunks, True)
        chunks += _finalize_if_needed(handle, s)
        state_obj.http_states.pop(handle, None)
        _release_http_state(s)

    return (handle, chunks, done)


def http_dispatch_push_body(
    handle: int, body: bytes, more_body: int
) -> tuple[bytes, bool]:
    """Push more request-body bytes into the running Task. Pumps once and
    returns (chunks, done)."""
    state_obj = _ensure_state()
    s = state_obj.http_states.get(handle)
    if s is None or s.task.done():
        return (b"", True)

    s.push_body(body, bool(more_body))

    try:
        _pump_once()
    except BaseException:
        traceback.print_exc(file=sys.stderr)

    chunks = s.drain()
    done = s.task.done()

    if done:
        if not s.task.cancelled():
            exc = s.task.exception()
            if exc is not None:
                traceback.print_exception(type(exc), exc, exc.__traceback__, file=sys.stderr)
        chunks += _finalize_if_needed(handle, s)
        state_obj.http_states.pop(handle, None)
        _release_http_state(s)

    return (chunks, done)


def http_dispatch_drain(handle: int) -> tuple[bytes, bool]:
    """Return any wire bytes the request's Task has emitted since the last
    drain, *without* pumping the asyncio loop. Used by the Zig server loop
    after a global pump to harvest output from each stalled connection
    without paying the per-connection pump cost.

    Returns (chunks, done). When `done`, the handle is freed.
    """
    state_obj = _ensure_state()
    s = state_obj.http_states.get(handle)
    if s is None or s.task.done():
        # Either never existed (stale handle) or already finished. If
        # finished but state still around (race), drain it now.
        if s is not None and s.task.done():
            chunks = s.drain()
            if not s.task.cancelled():
                exc = s.task.exception()
                if exc is not None:
                    traceback.print_exception(type(exc), exc, exc.__traceback__, file=sys.stderr)
            chunks += _finalize_if_needed(handle, s)
            state_obj.http_states.pop(handle, None)
            _release_http_state(s)
            return (chunks, True)
        return (b"", True)

    chunks = s.drain()
    done = s.task.done()

    if done:
        if not s.task.cancelled():
            exc = s.task.exception()
            if exc is not None:
                traceback.print_exception(type(exc), exc, exc.__traceback__, file=sys.stderr)
        chunks += _finalize_if_needed(handle, s)
        state_obj.http_states.pop(handle, None)
        _release_http_state(s)

    return (chunks, done)


def http_dispatch_abort(handle: int) -> None:
    """Connection went away mid-stream. Cancel the Task and free state."""
    state_obj = _ensure_state()
    s = state_obj.http_states.pop(handle, None)
    if s is None:
        return

    if not s.task.done():
        s.push_disconnect()
        try:
            _pump_once()
        except BaseException:
            pass
    if not s.task.done():
        s.task.cancel()
        try:
            _pump_once()
        except BaseException:
            pass


def _build_wire(
    status: int,
    headers: list[tuple[bytes, bytes]],
    body: bytes,
    *,
    keep_alive: bool,
) -> bytes:
    """Build a single-shot HTTP/1.1 response. Used for synthesized error
    responses (saltare-emitted 4xx/5xx); the streaming dispatcher emits
    its own wire bytes incrementally."""
    parts: list[bytes] = [
        _status_line(status),
        _SERVER_LINE,
        _CONNECTION_KEEPALIVE_LINE if keep_alive else _CONNECTION_CLOSE_LINE,
    ]

    has_content_length = False
    for name, value in headers:
        if name.lower() == b"connection":
            continue
        if name.lower() == b"content-length":
            has_content_length = True
        parts.append(name + b": " + value + b"\r\n")

    if not has_content_length:
        parts.append(f"content-length: {len(body)}\r\n".encode("ascii"))

    parts.append(_CRLF)
    parts.append(body)
    return b"".join(parts)
