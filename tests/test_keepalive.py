"""HTTP/1.1 keep-alive behaviour."""

from __future__ import annotations

import socket
import threading
import time
from typing import Any

import httpx
import pytest


async def echo_app(scope: dict, receive, send) -> None:
    assert scope["type"] == "http"
    await receive()
    method: str = scope["method"]
    target: bytes = scope["raw_path"]
    if scope["query_string"]:
        target = target + b"?" + scope["query_string"]
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


class _ResponseReader:
    """Stateful HTTP/1.1 response reader. Carries leftover bytes across
    calls so pipelined responses don't get lost between reads."""

    def __init__(self, sock: socket.socket) -> None:
        self.sock = sock
        self.buf = b""
        sock.settimeout(2.0)

    def read(self) -> tuple[int, dict[str, str], bytes]:
        while b"\r\n\r\n" not in self.buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise RuntimeError("server closed before response")
            self.buf += chunk

        head, _, rest = self.buf.partition(b"\r\n\r\n")
        lines = head.split(b"\r\n")
        status = int(lines[0].decode("ascii").split(" ", 2)[1])

        headers: dict[str, str] = {}
        for line in lines[1:]:
            name, _, value = line.partition(b":")
            headers[name.decode("ascii").strip().lower()] = value.decode("ascii").strip()

        content_length = int(headers.get("content-length", "0"))
        while len(rest) < content_length:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise RuntimeError("server closed mid-body")
            rest += chunk

        body = rest[:content_length]
        self.buf = rest[content_length:]  # preserve leftover for next read
        return status, headers, body


def _read_response(sock: socket.socket) -> tuple[int, dict[str, str], bytes]:
    """Single-shot helper for tests that read exactly one response."""
    return _ResponseReader(sock).read()


def test_response_advertises_keep_alive_by_default() -> None:
    port = _free_port()
    _serve_in_background(echo_app, port)
    response = httpx.get(f"http://127.0.0.1:{port}/", timeout=2.0)
    assert response.status_code == 200
    assert response.headers["connection"].lower() == "keep-alive"


def test_response_honours_client_connection_close() -> None:
    port = _free_port()
    _serve_in_background(echo_app, port)
    response = httpx.get(
        f"http://127.0.0.1:{port}/",
        headers={"Connection": "close"},
        timeout=2.0,
    )
    assert response.status_code == 200
    assert response.headers["connection"].lower() == "close"


def test_two_requests_on_one_tcp_connection() -> None:
    """Send a second request on the same socket and get a second 200 back."""
    port = _free_port()
    _serve_in_background(echo_app, port)
    with socket.create_connection(("127.0.0.1", port)) as sock:
        sock.sendall(b"GET /first HTTP/1.1\r\nHost: x\r\n\r\n")
        status1, headers1, body1 = _read_response(sock)
        assert status1 == 200
        assert headers1["connection"].lower() == "keep-alive"
        assert b"GET /first" in body1

        sock.sendall(b"GET /second HTTP/1.1\r\nHost: x\r\n\r\n")
        status2, headers2, body2 = _read_response(sock)
        assert status2 == 200
        assert b"GET /second" in body2


def test_pipelined_requests_in_one_packet() -> None:
    """Two requests sent back-to-back without waiting; expect two responses
    in order (saltare's keepAliveReset re-parses leftover bytes inline)."""
    port = _free_port()
    _serve_in_background(echo_app, port)
    pipelined = (
        b"GET /one HTTP/1.1\r\nHost: x\r\n\r\n"
        b"GET /two HTTP/1.1\r\nHost: x\r\n\r\n"
    )
    with socket.create_connection(("127.0.0.1", port)) as sock:
        sock.sendall(pipelined)
        reader = _ResponseReader(sock)
        status1, _, body1 = reader.read()
        status2, _, body2 = reader.read()
        assert status1 == 200 and b"GET /one" in body1
        assert status2 == 200 and b"GET /two" in body2
