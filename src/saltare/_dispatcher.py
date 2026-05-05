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
import traceback
from typing import Any
from urllib.parse import unquote_to_bytes

_loop: asyncio.AbstractEventLoop | None = None

# Lifespan state. The task is created in `lifespan_startup` and stays parked
# on its receive() between server start and shutdown. Globals because there
# is at most one server per process and the bridge calls these as plain
# top-level functions.
_lifespan_task: asyncio.Task | None = None
_lifespan_receive_queue: asyncio.Queue | None = None
_lifespan_send_queue: asyncio.Queue | None = None


def _ensure_loop() -> asyncio.AbstractEventLoop:
    global _loop
    if _loop is None:
        _loop = asyncio.new_event_loop()
    return _loop


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
    global _lifespan_task, _lifespan_receive_queue, _lifespan_send_queue

    loop = _ensure_loop()

    # If a previous serve() left a stale task around (test reuse), cancel it.
    if _lifespan_task is not None and not _lifespan_task.done():
        _lifespan_task.cancel()
        try:
            loop.run_until_complete(_lifespan_task)
        except BaseException:
            pass

    _lifespan_receive_queue = asyncio.Queue()
    _lifespan_send_queue = asyncio.Queue()

    rq, sq = _lifespan_receive_queue, _lifespan_send_queue

    async def lifespan_receive() -> dict[str, Any]:
        return await rq.get()

    async def lifespan_send(message: dict[str, Any]) -> None:
        await sq.put(message)

    scope: dict[str, Any] = {
        "type": "lifespan",
        "asgi": {"version": "3.0", "spec_version": "2.0"},
    }

    _lifespan_task = loop.create_task(app(scope, lifespan_receive, lifespan_send))
    rq.put_nowait({"type": "lifespan.startup"})

    kind, value = loop.run_until_complete(
        _drive_lifespan_event(_lifespan_task, sq)
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
    global _lifespan_task, _lifespan_receive_queue, _lifespan_send_queue

    if (
        _lifespan_task is None
        or _lifespan_receive_queue is None
        or _lifespan_send_queue is None
    ):
        return

    loop = _ensure_loop()

    if _lifespan_task.done():
        # App's lifespan handler already finished during startup; nothing left.
        return

    _lifespan_receive_queue.put_nowait({"type": "lifespan.shutdown"})

    kind, value = loop.run_until_complete(
        _drive_lifespan_event(_lifespan_task, _lifespan_send_queue)
    )

    if kind == "exception":
        sys.stderr.write(
            f"saltare: lifespan shutdown raised ({type(value).__name__}: {value})\n"
        )
    elif kind == "timeout":
        sys.stderr.write(f"saltare: lifespan shutdown timed out ({_LIFESPAN_TIMEOUT}s)\n")
        if not _lifespan_task.done():
            _lifespan_task.cancel()
            try:
                loop.run_until_complete(_lifespan_task)
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

_SERVER_HEADER = b"saltare/0.8.0"


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
        "scheme": "http",
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
