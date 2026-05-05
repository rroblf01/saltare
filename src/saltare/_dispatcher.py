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


def _ensure_loop() -> asyncio.AbstractEventLoop:
    global _loop
    if _loop is None:
        _loop = asyncio.new_event_loop()
    return _loop


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

_SERVER_HEADER = b"saltare/0.4.0"


def dispatch(
    app: Any,
    method: str,
    raw_path: bytes,
    query_string: bytes,
    raw_headers: list[tuple[bytes, bytes]],
    body: bytes,
    server_host: str,
    server_port: int,
) -> bytes:
    """Run the ASGI app once. Returns the full HTTP/1.1 response as bytes."""
    loop = _ensure_loop()

    try:
        path = unquote_to_bytes(raw_path).decode("utf-8")
    except UnicodeDecodeError:
        return _build_wire(400, [], b"path is not valid UTF-8\n")

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
        return _build_wire(
            500,
            [(b"content-type", b"text/plain; charset=utf-8")],
            b"Internal Server Error\n",
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

    return _build_wire(status, out_headers, b"".join(body_chunks))


def _build_wire(
    status: int,
    headers: list[tuple[bytes, bytes]],
    body: bytes,
) -> bytes:
    reason = _REASONS.get(status, "OK")
    parts: list[bytes] = [f"HTTP/1.1 {status} {reason}\r\n".encode("ascii")]
    parts.append(b"server: " + _SERVER_HEADER + b"\r\n")
    parts.append(b"connection: close\r\n")

    has_content_length = False
    for name, value in headers:
        if name.lower() == b"content-length":
            has_content_length = True
        parts.append(name + b": " + value + b"\r\n")

    if not has_content_length:
        parts.append(f"content-length: {len(body)}\r\n".encode("ascii"))

    parts.append(b"\r\n")
    parts.append(body)
    return b"".join(parts)
