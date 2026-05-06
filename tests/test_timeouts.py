"""Per-connection idle/state timeouts (v0.11).

Each test starts the server with very short timeouts (1 second) and verifies
that the timer wheel reaps a connection stuck in the relevant phase. Wait
budget is generous (4 s) to account for the 1 s wheel granularity plus the
100 ms epoll poll.
"""

from __future__ import annotations

import socket
import threading
import time
from typing import Any

import pytest


async def echo_app(scope: dict, receive, send) -> None:
    assert scope["type"] == "http"
    await receive()
    method: str = scope["method"]
    target: bytes = scope["raw_path"]
    body = b"saltare parsed: " + method.encode("ascii") + b" " + target + b"\n"
    await send({
        "type": "http.response.start",
        "status": 200,
        "headers": [(b"content-type", b"text/plain; charset=utf-8")],
    })
    await send({"type": "http.response.body", "body": body})


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _serve_in_background(app: Any, port: int, **kwargs: int) -> None:
    """Launch saltare.run on a daemon thread, forwarding timeout kwargs."""
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


def _wait_for_close(sock: socket.socket, deadline_seconds: float) -> bool:
    """Return True if the server closes (or resets) the connection within
    `deadline_seconds`. Any data the server sends before closing is
    discarded — we only care that the close happens."""
    sock.settimeout(deadline_seconds)
    try:
        while True:
            data = sock.recv(4096)
            if not data:
                return True  # clean EOF
    except (ConnectionResetError, BrokenPipeError):
        return True
    except socket.timeout:
        return False


def test_header_timeout_closes_slowloris() -> None:
    """A client that opens a TCP connection but never sends a full
    request line + headers should be reaped by header_timeout."""
    port = _free_port()
    _serve_in_background(echo_app, port, header_timeout=1)

    with socket.create_connection(("127.0.0.1", port), timeout=2.0) as sock:
        # Send a partial request — just the start of the request line.
        # Without CR/LF the parser will keep wanting more.
        sock.sendall(b"GET /slow")
        assert _wait_for_close(sock, deadline_seconds=4.0), (
            "server did not close the slow connection within header_timeout"
        )


def test_keep_alive_timeout_closes_idle_connection() -> None:
    """After completing one request on a keep-alive connection, the server
    must close the connection if the client doesn't send a second request
    within keep_alive_timeout."""
    port = _free_port()
    _serve_in_background(echo_app, port, keep_alive_timeout=1)

    with socket.create_connection(("127.0.0.1", port), timeout=2.0) as sock:
        sock.sendall(b"GET / HTTP/1.1\r\nHost: x\r\n\r\n")

        # Drain the first response so we know we're back in the idle
        # keep-alive state.
        sock.settimeout(2.0)
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = sock.recv(4096)
            assert chunk, "server closed before responding"
            buf += chunk
        # Drain any body bytes we can read non-blocking.
        sock.settimeout(0.2)
        try:
            while True:
                if not sock.recv(4096):
                    break
        except socket.timeout:
            pass

        assert _wait_for_close(sock, deadline_seconds=4.0), (
            "server did not close the idle keep-alive connection"
        )


def test_body_timeout_closes_slow_body_sender() -> None:
    """A client that sends headers declaring Content-Length but never
    follows up with the body should be reaped by body_timeout."""
    port = _free_port()
    _serve_in_background(echo_app, port, body_timeout=1)

    with socket.create_connection(("127.0.0.1", port), timeout=2.0) as sock:
        # Send full headers but no body bytes. The server parses headers,
        # transitions to body phase, arms body_timeout, and waits.
        sock.sendall(
            b"POST /slow-body HTTP/1.1\r\n"
            b"Host: x\r\n"
            b"Content-Length: 100\r\n"
            b"\r\n"
        )
        assert _wait_for_close(sock, deadline_seconds=4.0), (
            "server did not close the slow-body connection within body_timeout"
        )


def test_normal_request_does_not_trigger_timeout() -> None:
    """A regular fast request must not be killed by the timer wheel —
    sanity check that we don't reap connections we shouldn't."""
    port = _free_port()
    _serve_in_background(
        echo_app,
        port,
        header_timeout=1,
        keep_alive_timeout=1,
        body_timeout=1,
        write_timeout=1,
    )

    with socket.create_connection(("127.0.0.1", port), timeout=2.0) as sock:
        sock.sendall(b"GET / HTTP/1.1\r\nHost: x\r\n\r\n")
        sock.settimeout(2.0)
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = sock.recv(4096)
            assert chunk, "server closed mid-response"
            buf += chunk
        head, _, _ = buf.partition(b"\r\n\r\n")
        first_line = head.split(b"\r\n", 1)[0]
        assert first_line.startswith(b"HTTP/1.1 200 "), first_line
