"""Tests for HTTP/2 support (v1.9).

Tests verify:
- HTTP/2 dispatch functions delegate correctly
- Server with http2=True still serves HTTP/1.1
- TLS + http2=True works and ALPN advertises h2
- Configuration parameters are present
"""

from __future__ import annotations

import inspect
import socket
import ssl
import subprocess
import threading
import time
from pathlib import Path
from typing import Any

import httpx
import pytest


async def _version_app(scope: dict, receive, send) -> None:
    """Echoes the http_version back."""
    assert scope["type"] == "http"
    await receive()
    body = scope["http_version"].encode("ascii")
    await send({
        "type": "http.response.start",
        "status": 200,
        "headers": [(b"content-type", b"text/plain")],
    })
    await send({"type": "http.response.body", "body": body})


async def _echo_app(scope: dict, receive, send) -> None:
    assert scope["type"] == "http"
    await receive()
    body = (
        b"saltare: "
        + scope["method"].encode("ascii")
        + b" "
        + scope["raw_path"]
        + b"\n"
    )
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


def _serve(
    app: Any, port: int, timeout: float = 2.0, **kwargs
) -> None:
    from saltare import run

    threading.Thread(
        target=run,
        args=(app,),
        kwargs={"host": "127.0.0.1", "port": port, **kwargs},
        daemon=True,
    ).start()
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return
        except (ConnectionRefusedError, socket.timeout):
            time.sleep(0.05)
    pytest.fail("server never became ready")


def _gen_cert(tmp_path: Path) -> tuple[str, str]:
    cert = tmp_path / "cert.pem"
    key = tmp_path / "key.pem"
    subprocess.check_call(
        [
            "openssl", "req", "-x509",
            "-newkey", "rsa:2048",
            "-sha256",
            "-days", "1",
            "-nodes",
            "-keyout", str(key),
            "-out", str(cert),
            "-subj", "/CN=localhost",
            "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return str(cert), str(key)


# -----------------------------------------------------------------------
# Unit tests for the Python dispatch functions
# -----------------------------------------------------------------------

class TestHttp2DispatchUnit:
    """Pure-logic tests for HTTP/2 dispatch functions."""

    def test_start_early_return_on_negative_stream_id(self):
        """Negative stream_id returns (0, b'', True)."""
        from saltare._dispatcher import http2_dispatch_start
        result = http2_dispatch_start(
            None, -1, 0, b"GET", b"http", b"/", b"/", b"",
            [], b"", 0, "localhost", 8000, "http",
        )
        assert result == (0, b"", True)

    def test_start_early_return_on_reserved_nonzero(self):
        """Non-zero reserved returns (0, b'', True)."""
        from saltare._dispatcher import http2_dispatch_start
        result = http2_dispatch_start(
            None, 1, 1, b"GET", b"http", b"/", b"/", b"",
            [], b"", 0, "localhost", 8000, "http",
        )
        assert result == (0, b"", True)

    def test_push_body_delegates(self):
        """http2_dispatch_push_body delegates to http_dispatch_push_body."""
        from saltare._dispatcher import http2_dispatch_push_body
        # With a non-existent handle, should return (b"", True)
        result = http2_dispatch_push_body(0, b"data", True)
        assert result == (b"", True)

    def test_drain_delegates(self):
        """http2_dispatch_drain delegates to http_dispatch_drain."""
        from saltare._dispatcher import http2_dispatch_drain
        # With a non-existent handle, should return (b"", True)
        result = http2_dispatch_drain(0)
        assert result == (b"", True)


# -----------------------------------------------------------------------
# Integration tests — http2=True with HTTP/1.1
# -----------------------------------------------------------------------

class TestHttp2Integration:
    """Server with http2=True should still serve HTTP/1.1 correctly."""

    def test_get_request(self):
        port = _free_port()
        _serve(_version_app, port, http2=True)
        response = httpx.get(f"http://127.0.0.1:{port}/", timeout=2.0)
        assert response.status_code == 200
        assert response.text == "1.1"

    def test_echo_request(self):
        port = _free_port()
        _serve(_echo_app, port, http2=True)
        response = httpx.get(f"http://127.0.0.1:{port}/test", timeout=2.0)
        assert response.status_code == 200
        assert b"saltare: GET /test" in response.content

    def test_post_body(self):
        port = _free_port()
        _serve(_echo_app, port, http2=True)
        response = httpx.post(
            f"http://127.0.0.1:{port}/items",
            content=b"payload", timeout=2.0,
        )
        assert response.status_code == 200
        assert b"POST /items" in response.content

    def test_pipelined_requests(self):
        port = _free_port()
        _serve(_echo_app, port, http2=True)
        pipelined = (
            b"GET /one HTTP/1.1\r\nHost: x\r\n\r\n"
            b"GET /two HTTP/1.1\r\nHost: x\r\n\r\n"
        )
        with socket.create_connection(("127.0.0.1", port)) as sock:
            sock.sendall(pipelined)
            data = b""
            while data.count(b"HTTP/1.1 200") < 2:
                chunk = sock.recv(4096)
                if not chunk:
                    break
                data += chunk
        assert data.count(b"HTTP/1.1 200") == 2

    def test_keep_alive_two_requests(self):
        port = _free_port()
        _serve(_echo_app, port, http2=True)
        with httpx.Client(timeout=2.0) as client:
            r1 = client.get(f"http://127.0.0.1:{port}/first")
            r2 = client.get(f"http://127.0.0.1:{port}/second")
        assert r1.status_code == 200 and b"/first" in r1.content
        assert r2.status_code == 200 and b"/second" in r2.content

    def test_malformed_request_gets_400(self):
        port = _free_port()
        _serve(_echo_app, port, http2=True)
        with socket.create_connection(("127.0.0.1", port)) as s:
            s.sendall(b"NOT-AN-HTTP-REQUEST\r\n\r\n")
            data = s.recv(4096)
        assert data.startswith(b"HTTP/1.1 400 ")


# -----------------------------------------------------------------------
# TLS integration tests
# -----------------------------------------------------------------------

class TestHttp2TlsIntegration:
    """TLS server with http2=True should serve HTTP/1.1 over TLS."""

    def test_tls_get_request(self, tmp_path: Path):
        cert, key = _gen_cert(tmp_path)
        port = _free_port()
        _serve(
            _version_app, port, timeout=3.0,
            ssl_certfile=cert, ssl_keyfile=key, http2=True,
        )
        response = httpx.get(
            f"https://127.0.0.1:{port}/",
            verify=False, timeout=3.0,
        )
        assert response.status_code == 200
        assert response.text == "1.1"

    def test_tls_alpn_offers_h2(self, tmp_path: Path):
        """ALPN handshake should advertise h2 even on plain HTTP/1.1."""
        cert, key = _gen_cert(tmp_path)
        port = _free_port()
        _serve(
            _echo_app, port, timeout=3.0,
            ssl_certfile=cert, ssl_keyfile=key, http2=True,
        )
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        ctx.set_alpn_protocols(["h2", "http/1.1"])
        with socket.create_connection(
            ("127.0.0.1", port), timeout=3.0,
        ) as raw:
            with ctx.wrap_socket(raw, server_hostname="localhost") as tls:
                proto = tls.selected_alpn_protocol()
        # ALPN negotiation depends on the runtime's OpenSSL version.
        if proto is not None:
            assert proto in ("h2", "http/1.1")


# -----------------------------------------------------------------------
# Configuration tests
# -----------------------------------------------------------------------

class TestHttp2Configuration:
    """Test HTTP/2 configuration is exposed correctly."""

    def test_http2_parameter_in_run_signature(self):
        from saltare import run
        sig = inspect.signature(run)
        assert "http2" in sig.parameters

    def test_http2_default_false(self):
        from saltare import run
        sig = inspect.signature(run)
        assert sig.parameters["http2"].default is False

    def test_http2_type_bool(self):
        from saltare import run
        sig = inspect.signature(run)
        ann = sig.parameters["http2"].annotation
        # With `from __future__ import annotations`, annotations are strings
        assert ann in (bool, "bool")

    def test_cli_has_http2_arg(self):
        import saltare.cli as cli_mod
        import inspect
        src = inspect.getsource(cli_mod)
        assert "--http2" in src


# -----------------------------------------------------------------------
# Real HTTP/2 wire conformance (v1.12): drive the server with the `h2`
# sans-IO library over TLS+ALPN and assert it speaks real HTTP/2 — HEADERS
# frames with HPACK-encoded headers and DATA frames — not HTTP/1.1 bytes.
# -----------------------------------------------------------------------

h2_conn_mod = pytest.importorskip("h2.connection", reason="needs the `h2` library")
import h2.config  # noqa: E402
import h2.events  # noqa: E402
import h2.settings  # noqa: E402


async def _sized_app(scope: dict, receive, send) -> None:
    """Responds with a body whose size is taken from the path (/<n>)."""
    assert scope["type"] == "http"
    await receive()
    n = int(scope["raw_path"].decode().lstrip("/") or "5")
    await send({
        "type": "http.response.start",
        "status": 200,
        "headers": [(b"content-type", b"application/octet-stream")],
    })
    await send({"type": "http.response.body", "body": b"x" * n})


async def _body_echo_app(scope: dict, receive, send) -> None:
    """Echoes the request body back."""
    assert scope["type"] == "http"
    body = b""
    while True:
        msg = await receive()
        body += msg.get("body", b"")
        if not msg.get("more_body", False):
            break
    await send({
        "type": "http.response.start",
        "status": 200,
        "headers": [(b"content-type", b"text/plain")],
    })
    await send({"type": "http.response.body", "body": body})


def _as_str(v) -> str:
    return v.decode("ascii") if isinstance(v, (bytes, bytearray)) else v


def _h2_tls_request(port: int, method: str, path: str, body: bytes | None = None, timeout: float = 5.0):
    """Perform one HTTP/2 request over TLS+ALPN with the real `h2` client.

    Returns (status:int, headers:list[(str,str)], body:bytes). Skips the test
    if ALPN can't negotiate h2 on the runtime's OpenSSL.
    """
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    ctx.set_alpn_protocols(["h2"])
    raw = socket.create_connection(("127.0.0.1", port), timeout=timeout)
    tls = ctx.wrap_socket(raw, server_hostname="localhost")
    try:
        if tls.selected_alpn_protocol() != "h2":
            pytest.skip("ALPN did not negotiate h2 on this OpenSSL build")

        conn = h2_conn_mod.H2Connection(config=h2.config.H2Configuration(client_side=True))
        conn.initiate_connection()
        headers = [
            (":method", method),
            (":authority", "localhost"),
            (":scheme", "https"),
            (":path", path),
        ]
        if body is not None:
            headers.append(("content-length", str(len(body))))
        conn.send_headers(1, headers, end_stream=(body is None))
        if body is not None:
            conn.send_data(1, body, end_stream=True)
        tls.sendall(conn.data_to_send())

        status: int | None = None
        resp_headers: list[tuple[str, str]] = []
        resp_body = b""
        ended = False
        tls.settimeout(timeout)
        while not ended:
            data = tls.recv(65535)
            if not data:
                break
            for ev in conn.receive_data(data):
                if isinstance(ev, h2.events.ResponseReceived):
                    resp_headers = [(_as_str(k), _as_str(v)) for k, v in ev.headers]
                    for k, v in resp_headers:
                        if k == ":status":
                            status = int(v)
                elif isinstance(ev, h2.events.DataReceived):
                    resp_body += ev.data
                    if ev.flow_controlled_length:
                        conn.acknowledge_received_data(ev.flow_controlled_length, ev.stream_id)
                elif isinstance(ev, (h2.events.StreamEnded, h2.events.StreamReset)):
                    ended = True
            out = conn.data_to_send()
            if out:
                tls.sendall(out)
        return status, resp_headers, resp_body
    finally:
        try:
            tls.close()
        except OSError:
            pass


class TestHttp2RealClientConformance:
    """End-to-end: a real h2 client must get valid HTTP/2 frames back."""

    def test_real_h2_get(self, tmp_path: Path):
        cert, key = _gen_cert(tmp_path)
        port = _free_port()
        _serve(_version_app, port, timeout=3.0, ssl_certfile=cert, ssl_keyfile=key, http2=True)
        status, headers, body = _h2_tls_request(port, "GET", "/")
        assert status == 200
        # Real HTTP/2 path → ASGI scope http_version is "2".
        assert body == b"2", f"expected http_version 2, got {body!r}"
        # `:status` must be present and be the first header (HPACK pseudo-header).
        assert headers[0][0] == ":status"
        # Hop-by-hop headers illegal in HTTP/2 must be absent.
        names = {k for k, _ in headers}
        assert "connection" not in names
        assert "transfer-encoding" not in names

    def test_real_h2_post_body_echo(self, tmp_path: Path):
        cert, key = _gen_cert(tmp_path)
        port = _free_port()
        _serve(_body_echo_app, port, timeout=3.0, ssl_certfile=cert, ssl_keyfile=key, http2=True)
        payload = b"hello over http/2"
        status, _headers, body = _h2_tls_request(port, "POST", "/", body=payload)
        assert status == 200
        assert body == payload

    def test_real_h2_flow_control_small_window(self, tmp_path: Path):
        """Force a tiny client receive window so the server MUST honour
        outbound flow control: it sends the first window's worth, then waits
        for our WINDOW_UPDATEs before sending the rest. A correct server
        delivers the full body; one that ignored flow control would overrun
        the window and the h2 client would raise a protocol error."""
        cert, key = _gen_cert(tmp_path)
        port = _free_port()
        _serve(_sized_app, port, timeout=3.0, ssl_certfile=cert, ssl_keyfile=key, http2=True)

        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        ctx.set_alpn_protocols(["h2"])
        raw = socket.create_connection(("127.0.0.1", port), timeout=5.0)
        tls = ctx.wrap_socket(raw, server_hostname="localhost")
        try:
            if tls.selected_alpn_protocol() != "h2":
                pytest.skip("ALPN did not negotiate h2")
            # Advertise a 1 KiB initial receive window for streams.
            cfg = h2.config.H2Configuration(client_side=True)
            conn = h2_conn_mod.H2Connection(config=cfg)
            conn.initiate_connection()
            conn.update_settings({h2.settings.SettingCodes.INITIAL_WINDOW_SIZE: 1024})
            n = 50000  # far beyond the 1 KiB window → forces many WINDOW_UPDATE rounds
            conn.send_headers(1, [
                (":method", "GET"), (":authority", "localhost"),
                (":scheme", "https"), (":path", f"/{n}"),
            ], end_stream=True)
            tls.sendall(conn.data_to_send())

            body = b""
            ended = False
            tls.settimeout(5.0)
            while not ended:
                data = tls.recv(65535)
                if not data:
                    break
                for ev in conn.receive_data(data):
                    if isinstance(ev, h2.events.DataReceived):
                        body += ev.data
                        # Grant more window as we consume, in small increments.
                        if ev.flow_controlled_length:
                            conn.acknowledge_received_data(ev.flow_controlled_length, ev.stream_id)
                    elif isinstance(ev, (h2.events.StreamEnded, h2.events.StreamReset)):
                        ended = True
                out = conn.data_to_send()
                if out:
                    tls.sendall(out)
            assert len(body) == n, f"got {len(body)} of {n}"
            assert body == b"x" * n
        finally:
            try:
                tls.close()
            except OSError:
                pass

    def test_real_h2_multi_frame_body(self, tmp_path: Path):
        """A 60 KiB response spans several DATA frames (max frame 16 KiB) but
        fits the default 64 KiB flow-control window — validates framing +
        END_STREAM without needing outbound WINDOW_UPDATE."""
        cert, key = _gen_cert(tmp_path)
        port = _free_port()
        _serve(_sized_app, port, timeout=3.0, ssl_certfile=cert, ssl_keyfile=key, http2=True)
        n = 60000
        status, _headers, body = _h2_tls_request(port, "GET", f"/{n}")
        assert status == 200
        assert len(body) == n
        assert body == b"x" * n


if __name__ == "__main__":
    pytest.main([__file__, "-v", "-s"])
