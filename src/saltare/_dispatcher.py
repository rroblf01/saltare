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


def _ensure_state() -> threading.local:
    if not hasattr(_state, "loop"):
        _state.loop = asyncio.new_event_loop()
        _state.ws_states = {}
        _state.next_ws_handle = 1
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
        "asgi": {"version": "3.0", "spec_version": "2.0"},
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

_SERVER_HEADER = b"saltare/0.10.0"


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
    __slots__ = ("recv_queue", "outgoing", "accepted", "closed", "task")

    def __init__(self, app: Any, scope: dict[str, Any]) -> None:
        self.recv_queue: asyncio.Queue = asyncio.Queue()
        self.outgoing: list[bytes] = []
        self.accepted: bool = False
        self.closed: bool = False

        async def receive() -> dict[str, Any]:
            return await self.recv_queue.get()

        async def send(message: dict[str, Any]) -> None:
            mtype = message.get("type")
            if mtype == "websocket.accept":
                self.accepted = True
            elif mtype == "websocket.send":
                if message.get("text") is not None:
                    self.outgoing.append(
                        _build_server_frame(0x1, message["text"].encode("utf-8"))
                    )
                elif message.get("bytes") is not None:
                    self.outgoing.append(_build_server_frame(0x2, message["bytes"]))
            elif mtype == "websocket.close":
                code = int(message.get("code", 1000))
                reason = message.get("reason", "") or ""
                payload = code.to_bytes(2, "big") + reason.encode("utf-8")
                self.outgoing.append(_build_server_frame(0x8, payload))
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
        return out


def _pump_once() -> None:
    """Process one batch of ready callbacks on the loop. We use the
    `_run_once` private method directly: it's the cheapest way to advance
    coroutines parked on a Future that we've just resolved (via Queue.put)
    without the overhead of wrapping a marker coroutine in a Task."""
    loop = _ensure_loop()
    # Each WS event we process needs the loop to "see" itself as the
    # currently running loop, otherwise asyncio.get_running_loop() inside
    # any framework code (FastAPI, Starlette) raises.
    asyncio.events._set_running_loop(loop)
    try:
        loop._run_once()
    finally:
        asyncio.events._set_running_loop(None)


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

    headers = [(name.lower(), value) for name, value in raw_headers]

    scope: dict[str, Any] = {
        "type": "websocket",
        "asgi": {"version": "3.0", "spec_version": "2.3"},
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


def dispatch(
    app: Any,
    method: str,
    raw_path: bytes,
    query_string: bytes,
    raw_headers: list[tuple[bytes, bytes]],
    body: bytes,
    server_host: str,
    server_port: int,
    keep_alive: int,
    scheme: str,
) -> bytes:
    """Run the ASGI app once. Returns the full HTTP/1.1 response as bytes."""
    loop = _ensure_loop()

    try:
        path = unquote_to_bytes(raw_path).decode("utf-8")
    except UnicodeDecodeError:
        return _build_wire(400, [], b"path is not valid UTF-8\n", keep_alive=False)

    # ASGI requires lowercased header names.
    headers = [(name.lower(), value) for name, value in raw_headers]

    scope: dict[str, Any] = {
        "type": "http",
        "asgi": {"version": "3.0", "spec_version": "2.3"},
        "http_version": "1.1",
        "method": method,
        "scheme": scheme,
        "path": path,
        "raw_path": raw_path,
        "query_string": query_string,
        "headers": headers,
        "server": (server_host, server_port),
        "client": None,
        "root_path": "",
    }

    request_consumed = False
    responses: list[dict[str, Any]] = []

    async def receive() -> dict[str, Any]:
        nonlocal request_consumed
        if request_consumed:
            return {"type": "http.disconnect"}
        request_consumed = True
        return {
            "type": "http.request",
            "body": body,
            "more_body": False,
        }

    async def send(message: dict[str, Any]) -> None:
        responses.append(message)

    try:
        loop.run_until_complete(app(scope, receive, send))
    except Exception:
        traceback.print_exc(file=sys.stderr)
        # Errors close the connection — parser/state is no longer trustworthy.
        return _build_wire(
            500,
            [(b"content-type", b"text/plain; charset=utf-8")],
            b"Internal Server Error\n",
            keep_alive=False,
        )

    status = 500
    out_headers: list[tuple[bytes, bytes]] = []
    body_chunks: list[bytes] = []
    for msg in responses:
        msg_type = msg.get("type")
        if msg_type == "http.response.start":
            status = msg["status"]
            out_headers = msg.get("headers", [])
        elif msg_type == "http.response.body":
            chunk = msg.get("body", b"")
            if chunk:
                body_chunks.append(chunk)

    return _build_wire(status, out_headers, b"".join(body_chunks), keep_alive=bool(keep_alive))


def _build_wire(
    status: int,
    headers: list[tuple[bytes, bytes]],
    body: bytes,
    *,
    keep_alive: bool,
) -> bytes:
    reason = _REASONS.get(status, "OK")
    parts: list[bytes] = [f"HTTP/1.1 {status} {reason}\r\n".encode("ascii")]
    parts.append(b"server: " + _SERVER_HEADER + b"\r\n")
    parts.append(b"connection: keep-alive\r\n" if keep_alive else b"connection: close\r\n")

    has_content_length = False
    for name, value in headers:
        # Strip any Connection header from the app — saltare owns that decision.
        if name.lower() == b"connection":
            continue
        if name.lower() == b"content-length":
            has_content_length = True
        parts.append(name + b": " + value + b"\r\n")

    if not has_content_length:
        parts.append(f"content-length: {len(body)}\r\n".encode("ascii"))

    parts.append(b"\r\n")
    parts.append(body)
    return b"".join(parts)
