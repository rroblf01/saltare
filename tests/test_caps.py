"""Resource caps and Expect: 100-continue (v0.13).

Each cap turns the architectural RAM advantage into a hard guarantee:
    - max_request_body: oversize bodies hit 413 instead of consuming heap.
    - max_concurrent_connections: kernel backlog can't pile up unboundedly.
    - max_keepalive_requests: long-lived connections eventually recycle.
"""

from __future__ import annotations

import socket
import threading
import time
from typing import Any

import pytest


async def echo_app(scope: dict, receive, send) -> None:
    if scope["type"] == "lifespan":
        while True:
            msg = await receive()
            if msg["type"] == "lifespan.startup":
                await send({"type": "lifespan.startup.complete"})
            elif msg["type"] == "lifespan.shutdown":
                await send({"type": "lifespan.shutdown.complete"})
                return
        return
    assert scope["type"] == "http"
    msg = await receive()
    body = msg.get("body", b"")
    await send({
        "type": "http.response.start",
        "status": 200,
        "headers": [(b"content-type", b"text/plain")],
    })
    await send({
        "type": "http.response.body",
        "body": b"got " + str(len(body)).encode("ascii") + b" bytes",
        "more_body": False,
    })


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _serve_in_background(app: Any, port: int, **kwargs: int) -> None:
    from saltare import run

    threading.Thread(
        target=run,
        args=(app,),
        kwargs={"host": "127.0.0.1", "port": port, **kwargs},
        daemon=True,
    ).start()
    deadline = time.monotonic() + 2.0
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return
        except (ConnectionRefusedError, socket.timeout):
            time.sleep(0.05)
    pytest.fail("server never became ready")


def _read_full_response(sock: socket.socket, deadline: float = 2.0) -> tuple[int, dict[str, str], bytes]:
    sock.settimeout(deadline)
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = sock.recv(4096)
        if not chunk:
            raise RuntimeError("server closed before response head")
        buf += chunk
    head, _, rest = buf.partition(b"\r\n\r\n")
    lines = head.split(b"\r\n")
    status = int(lines[0].decode("ascii").split(" ", 2)[1])
    headers: dict[str, str] = {}
    for line in lines[1:]:
        name, _, value = line.partition(b":")
        headers[name.decode("ascii").strip().lower()] = value.decode("ascii").strip()
    cl = int(headers.get("content-length", "0"))
    while len(rest) < cl:
        chunk = sock.recv(4096)
        if not chunk:
            break
        rest += chunk
    return status, headers, rest[:cl]


def test_max_request_body_rejects_oversize_content_length() -> None:
    """A request advertising a Content-Length larger than max_request_body
    must get a 413 immediately, before we read any body bytes."""
    port = _free_port()
    _serve_in_background(echo_app, port, max_request_body=256)

    with socket.create_connection(("127.0.0.1", port), timeout=2.0) as sock:
        sock.sendall(
            b"POST /huge HTTP/1.1\r\n"
            b"Host: x\r\n"
            b"Content-Length: 1000000\r\n"
            b"\r\n"
        )
        status, _, _ = _read_full_response(sock)
        assert status == 413


def test_max_request_body_accepts_within_limit() -> None:
    """A request whose Content-Length is below the cap goes through."""
    port = _free_port()
    _serve_in_background(echo_app, port, max_request_body=4096)

    body = b"x" * 100
    with socket.create_connection(("127.0.0.1", port), timeout=2.0) as sock:
        sock.sendall(
            b"POST /ok HTTP/1.1\r\n"
            b"Host: x\r\n"
            b"Content-Length: " + str(len(body)).encode("ascii") + b"\r\n"
            b"\r\n" + body
        )
        status, _, body_response = _read_full_response(sock)
        assert status == 200
        assert b"got 100 bytes" in body_response


def test_expect_100_continue_is_acknowledged() -> None:
    """Sending `Expect: 100-continue` must elicit a 100 Continue response
    *before* the final 200, so clients waiting for it can proceed."""
    port = _free_port()
    _serve_in_background(echo_app, port, max_request_body=4096)

    body = b"hello world"
    with socket.create_connection(("127.0.0.1", port), timeout=2.0) as sock:
        # Send headers without the body, mimicking what httpx/requests do.
        sock.sendall(
            b"POST /e HTTP/1.1\r\n"
            b"Host: x\r\n"
            b"Content-Length: " + str(len(body)).encode("ascii") + b"\r\n"
            b"Expect: 100-continue\r\n"
            b"\r\n"
        )
        # Read the interim response.
        sock.settimeout(2.0)
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = sock.recv(4096)
            assert chunk, "server closed before sending 100"
            buf += chunk
        assert buf.startswith(b"HTTP/1.1 100 Continue\r\n"), buf

        # Strip the 100 prelude and now send the body.
        _, _, leftover = buf.partition(b"\r\n\r\n")
        sock.sendall(body)
        # Read the final response (may need to consume `leftover` first if
        # the server pipelined any preamble).
        head_buf = leftover
        while b"\r\n\r\n" not in head_buf:
            chunk = sock.recv(4096)
            assert chunk
            head_buf += chunk
        head, _, rest = head_buf.partition(b"\r\n\r\n")
        status_line = head.split(b"\r\n", 1)[0]
        assert status_line.startswith(b"HTTP/1.1 200 "), status_line


def test_expect_100_continue_rejected_when_body_exceeds_cap() -> None:
    """If the declared body would exceed the cap, the server must NOT send
    100 Continue — it sends 413 directly so the client doesn't pump bytes."""
    port = _free_port()
    _serve_in_background(echo_app, port, max_request_body=64)

    with socket.create_connection(("127.0.0.1", port), timeout=2.0) as sock:
        sock.sendall(
            b"POST /huge-expect HTTP/1.1\r\n"
            b"Host: x\r\n"
            b"Content-Length: 1000\r\n"
            b"Expect: 100-continue\r\n"
            b"\r\n"
        )
        status, _, _ = _read_full_response(sock)
        assert status == 413


def test_max_keepalive_requests_forces_close_at_limit() -> None:
    """Once `max_keepalive_requests` requests have been served on a single
    TCP connection, the server stops advertising keep-alive and closes."""
    port = _free_port()
    _serve_in_background(echo_app, port, max_keepalive_requests=3)

    with socket.create_connection(("127.0.0.1", port), timeout=2.0) as sock:
        observed_connection_headers: list[str] = []
        for _ in range(3):
            sock.sendall(b"GET / HTTP/1.1\r\nHost: x\r\n\r\n")
            status, headers, _ = _read_full_response(sock)
            assert status == 200
            observed_connection_headers.append(headers["connection"].lower())

        # The first two responses keep the connection alive; the third —
        # the one that hits the cap — must say "close".
        assert observed_connection_headers[0] == "keep-alive"
        assert observed_connection_headers[1] == "keep-alive"
        assert observed_connection_headers[2] == "close"

        # And the server actually closes on its end.
        sock.settimeout(2.0)
        assert sock.recv(4096) == b""


def test_max_concurrent_connections_drops_extras() -> None:
    """Once the active-connection cap is hit, the server still accepts new
    sockets (to drain the kernel backlog) but immediately closes them — the
    client sees a clean EOF on its first read."""
    port = _free_port()
    _serve_in_background(echo_app, port, max_concurrent_connections=2)

    held: list[socket.socket] = []
    try:
        # Hold two connections open with no request — they sit idle, parked
        # on the header_timeout. Active-conn count is 2.
        for _ in range(2):
            held.append(socket.create_connection(("127.0.0.1", port), timeout=2.0))

        # Give the server a moment to register them.
        time.sleep(0.1)

        # The third connect succeeds at the TCP level (kernel queues it
        # then accept() returns) but saltare immediately closes it.
        with socket.create_connection(("127.0.0.1", port), timeout=2.0) as extra:
            extra.settimeout(2.0)
            try:
                data = extra.recv(4096)
            except (ConnectionResetError, BrokenPipeError):
                data = b""
            assert data == b"", f"expected immediate close, got {data!r}"
    finally:
        for s in held:
            try:
                s.close()
            except OSError:
                pass
