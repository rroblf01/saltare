"""TLS termination — saltare serves HTTPS when given a cert + key."""

from __future__ import annotations

import socket
import ssl
import subprocess
import threading
import time
from pathlib import Path
from typing import Any

import httpx
import pytest


async def echo_app(scope: dict, receive, send) -> None:
    assert scope["type"] == "http"
    await receive()
    body = (
        b"saltare parsed: "
        + scope["method"].encode("ascii")
        + b" "
        + scope["raw_path"]
        + b" scheme="
        + scope["scheme"].encode("ascii")
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


def _generate_self_signed(tmp_path: Path) -> tuple[str, str]:
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


def _serve_tls_in_background(app: Any, port: int, cert: str, key: str) -> None:
    from saltare import run

    threading.Thread(
        target=run,
        args=(app,),
        kwargs={
            "host": "127.0.0.1",
            "port": port,
            "ssl_certfile": cert,
            "ssl_keyfile": key,
        },
        daemon=True,
    ).start()
    deadline = time.monotonic() + 3.0
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.5) as raw:
                with ctx.wrap_socket(raw, server_hostname="localhost"):
                    return
        except (ConnectionRefusedError, socket.timeout, ssl.SSLError, OSError):
            time.sleep(0.1)
    pytest.fail("TLS server never became ready")


def test_https_get(tmp_path: Path) -> None:
    cert, key = _generate_self_signed(tmp_path)
    port = _free_port()
    _serve_tls_in_background(echo_app, port, cert, key)

    response = httpx.get(
        f"https://127.0.0.1:{port}/some/path",
        verify=False,
        timeout=3.0,
    )
    assert response.status_code == 200
    assert b"saltare parsed: GET /some/path" in response.content
    assert b"scheme=https" in response.content
    assert response.headers["server"] == "saltare/0.14.0"


def test_https_keep_alive(tmp_path: Path) -> None:
    """Two requests on the same TLS connection — saltare's keep-alive path
    must work over TLS too (SSL_pending drains buffered bytes between cycles)."""
    cert, key = _generate_self_signed(tmp_path)
    port = _free_port()
    _serve_tls_in_background(echo_app, port, cert, key)

    with httpx.Client(verify=False, timeout=3.0) as client:
        r1 = client.get(f"https://127.0.0.1:{port}/first")
        r2 = client.get(f"https://127.0.0.1:{port}/second")
    assert r1.status_code == 200 and b"GET /first" in r1.content
    assert r2.status_code == 200 and b"GET /second" in r2.content


def test_tls_init_fails_with_bad_cert(tmp_path: Path) -> None:
    """A non-existent cert file should make serve() raise immediately."""
    from saltare import run

    bogus = str(tmp_path / "missing-cert.pem")
    port = _free_port()
    error: list[BaseException] = []

    def runner():
        try:
            run(
                echo_app,
                host="127.0.0.1",
                port=port,
                ssl_certfile=bogus,
                ssl_keyfile=bogus,
            )
        except BaseException as exc:
            error.append(exc)

    t = threading.Thread(target=runner, daemon=True)
    t.start()
    t.join(timeout=3.0)

    assert error, "expected serve() to raise on missing cert"
    assert isinstance(error[0], RuntimeError)
    assert "TLS init" in str(error[0]) or "tls init" in str(error[0]).lower()


def test_certfile_without_keyfile_rejected() -> None:
    """Half-set TLS args should be rejected up front, not at first connection."""
    from saltare import run

    with pytest.raises(ValueError, match="ssl_certfile and ssl_keyfile"):
        run(echo_app, host="127.0.0.1", port=_free_port(), ssl_certfile="/tmp/x")
