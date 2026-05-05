"""Chunked Transfer-Encoding on request bodies."""

from __future__ import annotations

import socket
import threading
import time
from typing import Any

import pytest


async def echo_body_app(scope: dict, receive, send) -> None:
    """ASGI app that echoes the received request body length and content."""
    assert scope["type"] == "http"
    body_chunks: list[bytes] = []
    while True:
        msg = await receive()
        body_chunks.append(msg.get("body", b""))
        if not msg.get("more_body", False):
            break
    body = b"".join(body_chunks)
    out = b"received " + str(len(body)).encode() + b" bytes: " + body + b"\n"
    await send({
        "type": "http.response.start",
        "status": 200,
        "headers": [(b"content-type", b"text/plain; charset=utf-8")],
    })
    await send({"type": "http.response.body", "body": out})


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _serve_in_background(app: Any, port: int) -> None:
    from saltare import run

    threading.Thread(
        target=run,
        args=(app,),
        kwargs={"host": "127.0.0.1", "port": port},
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


def _read_response(sock: socket.socket) -> tuple[int, dict[str, str], bytes]:
    sock.settimeout(2.0)
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = sock.recv(4096)
        if not chunk:
            raise RuntimeError("server closed before response")
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
            raise RuntimeError("server closed mid-body")
        rest += chunk
    return status, headers, rest[:cl]


def test_chunked_request_two_chunks() -> None:
    port = _free_port()
    _serve_in_background(echo_body_app, port)
    request = (
        b"POST /upload HTTP/1.1\r\n"
        b"Host: x\r\n"
        b"Transfer-Encoding: chunked\r\n"
        b"\r\n"
        b"5\r\nhello\r\n"
        b"6\r\n world\r\n"
        b"0\r\n"
        b"\r\n"
    )
    with socket.create_connection(("127.0.0.1", port)) as sock:
        sock.sendall(request)
        status, _, body = _read_response(sock)
    assert status == 200
    assert b"received 11 bytes: hello world" in body


def test_chunked_request_empty_body() -> None:
    port = _free_port()
    _serve_in_background(echo_body_app, port)
    request = (
        b"POST /empty HTTP/1.1\r\n"
        b"Host: x\r\n"
        b"Transfer-Encoding: chunked\r\n"
        b"\r\n"
        b"0\r\n"
        b"\r\n"
    )
    with socket.create_connection(("127.0.0.1", port)) as sock:
        sock.sendall(request)
        status, _, body = _read_response(sock)
    assert status == 200
    assert b"received 0 bytes:" in body


def test_chunked_request_split_across_packets() -> None:
    """Send the chunked body in two TCP segments — saltare's decoder must
    pick up where it left off when the next read arrives."""
    port = _free_port()
    _serve_in_background(echo_body_app, port)

    head = (
        b"POST /split HTTP/1.1\r\n"
        b"Host: x\r\n"
        b"Transfer-Encoding: chunked\r\n"
        b"\r\n"
        b"5\r\nhello\r\n"
        b"6\r\n wor"  # partial chunk: only 4 of 6 bytes
    )
    tail = b"ld\r\n0\r\n\r\n"

    with socket.create_connection(("127.0.0.1", port)) as sock:
        sock.sendall(head)
        time.sleep(0.05)  # force a separate read on the server side
        sock.sendall(tail)
        status, _, body = _read_response(sock)
    assert status == 200
    assert b"received 11 bytes: hello world" in body


def test_chunked_request_invalid_returns_400() -> None:
    port = _free_port()
    _serve_in_background(echo_body_app, port)
    request = (
        b"POST /bad HTTP/1.1\r\n"
        b"Host: x\r\n"
        b"Transfer-Encoding: chunked\r\n"
        b"\r\n"
        b"zz\r\n"  # invalid hex chunk size
    )
    with socket.create_connection(("127.0.0.1", port)) as sock:
        sock.sendall(request)
        sock.settimeout(2.0)
        data = b""
        while b"\r\n" not in data:
            chunk = sock.recv(4096)
            if not chunk:
                break
            data += chunk
    assert data.startswith(b"HTTP/1.1 400 ")
