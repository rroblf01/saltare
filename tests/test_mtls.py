"""Mutual TLS — `ssl_ca_file` + `ssl_verify_client=True`.

Also previously untested, and it is the feature most likely to be
misconfigured in production: it decides whether a client is allowed to
connect at all, and a wrong answer in either direction is a security
problem rather than a cosmetic one.

The mechanism is `SSL_CTX_load_verify_locations` for the CA bundle plus
`SSL_VERIFY_PEER | SSL_VERIFY_FAIL_IF_NO_PEER_CERT` (tls.zig:234), so a
handshake without a client certificate must fail rather than fall
through to an anonymous session.

The matrix that matters, and that this module pins down:

  - server with `verify_client=True` + client cert signed by the trusted
    CA          -> handshake succeeds, request served
  - client with no cert                    -> rejected
  - client cert signed by a *different* CA -> rejected
  - server with `verify_client=False` but a CA loaded -> still accepts
    anonymous clients (loading a CA must not by itself start demanding
    certs)
  - `ssl_ca_file` pointing at a nonexistent path -> the server must fail
    loudly at startup rather than silently running with no trust store

Test CAs are minted with the `openssl` CLI into pytest's tmp_path, the
same approach `tests/test_tls.py` uses for its self-signed certs.
"""

from __future__ import annotations

import socket
import ssl
import subprocess
import threading
import time
from pathlib import Path
from typing import Any

import pytest

# RSA-2048 rather than something smaller: some OpenSSL builds refuse to
# go below 2048 in the security level, and a refusal here would look
# like a saltare failure.
_KEYGEN = ["rsa:2048"]


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _openssl(*args: str) -> None:
    subprocess.check_call(
        ["openssl", *args],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def _server_cert(tmp_path: Path) -> tuple[str, str]:
    """Self-signed server certificate for 127.0.0.1."""
    cert = tmp_path / "server-cert.pem"
    key = tmp_path / "server-key.pem"
    _openssl(
        "req", "-x509", "-newkey", *_KEYGEN, "-sha256", "-days", "1", "-nodes",
        "-keyout", str(key), "-out", str(cert),
        "-subj", "/CN=localhost",
        "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1",
    )
    return str(cert), str(key)


def _make_ca(tmp_path: Path, name: str) -> tuple[str, str]:
    """A CA plus the key needed to sign client certs with it.

    Returns (ca_cert_path, ca_key_path). Callers sign client certs against
    the key, so a second CA can be produced to test rejection.
    """
    ca_key = tmp_path / f"{name}-key.pem"
    ca_cert = tmp_path / f"{name}.pem"
    # No `-addext basicConstraints=critical,CA:TRUE` here. `req -x509`
    # already emits it — but only *once* on OpenSSL 3, and on OpenSSL 1.1.1
    # it emits its own copy from openssl.cnf's x509_extensions *as well*,
    # so the -addext produced a second one. A certificate with a
    # duplicated extension violates RFC 5280 §4.2 and OpenSSL's verifier
    # then refuses to use it as an issuer:
    #
    #   error 20 at 0 depth lookup: unable to get local issuer certificate
    #
    # which surfaced as three mTLS tests failing on the manylinux_2_28
    # build image (OpenSSL 1.1.1k) while passing on the GitHub runner
    # (OpenSSL 3.x) — an environment difference that had nothing to do
    # with saltare. Letting the tool add it once works on both.
    _openssl(
        "req", "-x509", "-newkey", *_KEYGEN, "-sha256", "-days", "1", "-nodes",
        "-keyout", str(ca_key), "-out", str(ca_cert),
        "-subj", f"/CN={name}-ca",
    )
    return str(ca_cert), str(ca_key)


def _client_cert(
    tmp_path: Path, ca_cert: str, ca_key: str, name: str
) -> tuple[str, str]:
    """A client key+cert signed by `ca_cert`, with the CA chain inlined
    so the client can present a complete chain."""
    key = tmp_path / f"{name}-key.pem"
    csr = tmp_path / f"{name}.csr"
    cert = tmp_path / f"{name}-cert.pem"
    _openssl("req", "-newkey", *_KEYGEN, "-nodes",
             "-keyout", str(key), "-out", str(csr), "-subj", f"/CN={name}")
    _openssl("x509", "-req", "-in", str(csr), "-CA", ca_cert, "-CAkey", ca_key,
             "-CAcreateserial", "-days", "1", "-sha256", "-out", str(cert))
    return str(cert), str(key)


async def _echo(scope, receive, send):
    if scope["type"] == "lifespan":
        while True:
            msg = await receive()
            if msg["type"] == "lifespan.startup":
                await send({"type": "lifespan.startup.complete"})
            elif msg["type"] == "lifespan.shutdown":
                await send({"type": "lifespan.shutdown.complete"})
                return
        return
    await receive()
    await send({
        "type": "http.response.start",
        "status": 200,
        "headers": [(b"content-type", b"text/plain")],
    })
    await send({"type": "http.response.body", "body": b"mtls ok", "more_body": False})


def _serve_mtls_in_background(
    app: Any, port: int, cert: str, key: str, **kwargs
) -> None:
    """Start a TLS server and wait until it is accepting handshakes.

    Note this waits on a *plain* (non-client-cert) handshake, which
    deliberately fails when verify_client is on. We therefore only treat
    "connected at the TCP level" as readiness, not "handshake
    succeeded" — otherwise a correctly-rejecting server would look
    permanently unready and time out.
    """
    from saltare import run

    threading.Thread(
        target=run,
        args=(app,),
        kwargs={
            "host": "127.0.0.1",
            "port": port,
            "ssl_certfile": cert,
            "ssl_keyfile": key,
            **kwargs,
        },
        daemon=True,
    ).start()
    deadline = time.monotonic() + 3.0
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.5):
                return
        except (ConnectionRefusedError, socket.timeout, OSError):
            time.sleep(0.05)
    pytest.fail("mTLS server never became ready")


def _https_get(
    port: int,
    *,
    client_cert: tuple[str, str] | None = None,
    timeout: float = 3.0,
) -> int | None:
    """Perform a TLS request with Python's own client, so the assertions
    are about what OpenSSL on the server does, not about saltare.

    Returns the HTTP status, or None when the client never got an HTTP
    response at all.

    The None case is not an edge case, it is the normal shape of an mTLS
    rejection under TLS 1.3. There the client certificate is verified
    *after* the server has already sent its Finished, so the client
    completes the handshake successfully and only discovers the rejection
    when the connection is torn down before its request is answered. Under
    TLS 1.2 the same rejection surfaces as an SSLError during the
    handshake instead. Both are rejection; callers should assert on
    "not served", not on which of the two shapes occurred.
    """
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE  # we are testing the *client* cert path
    if client_cert is not None:
        ctx.load_cert_chain(client_cert[0], client_cert[1])
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=timeout) as raw:
            with ctx.wrap_socket(raw, server_hostname="localhost") as tls_sock:
                tls_sock.sendall(
                    f"GET / HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n"
                    f"Connection: close\r\n\r\n".encode()
                )
                chunks = []
                try:
                    while True:
                        b = tls_sock.recv(65536)
                        if not b:
                            break
                        chunks.append(b)
                except (ssl.SSLError, socket.timeout, ConnectionResetError):
                    pass
    except (ssl.SSLError, OSError):
        # Rejected during the handshake (the TLS 1.2 shape).
        return None
    body = b"".join(chunks)
    if not body.startswith(b"HTTP/1."):
        return None
    return int(body.split(b" ", 2)[1])


def _assert_rejected(port: int, client_cert: tuple[str, str] | None) -> None:
    """The client must not be served. Asserted as "no 200" so it holds for
    both the handshake-failure and the post-handshake-drop shapes."""
    status = _https_get(port, client_cert=client_cert)
    assert status != 200, (
        f"expected the client to be rejected, got HTTP {status}"
    )


# ---------------------------------------------------------------------------
# The matrix
# ---------------------------------------------------------------------------


def test_valid_client_cert_is_accepted(tmp_path: Path) -> None:
    cert, key = _server_cert(tmp_path)
    ca_cert, ca_key = _make_ca(tmp_path, "trusted")
    client = _client_cert(tmp_path, ca_cert, ca_key, "good-client")

    port = _free_port()
    _serve_mtls_in_background(
        _echo, port, cert, key,
        ssl_ca_file=ca_cert, ssl_verify_client=True,
    )

    assert _https_get(port, client_cert=client) == 200


def test_missing_client_cert_is_rejected(tmp_path: Path) -> None:
    """SSL_VERIFY_FAIL_IF_NO_PEER_CERT means an anonymous client must not
    get a session. If this ever succeeds, the server is serving
    unauthenticated traffic to a client that asked it to authenticate
    everyone.

    The second half matters as much as the first: without it this test
    would also pass if the server had failed to start or was wedged,
    since a dead server looks exactly like a rejecting one. Serving a
    trusted certificate on the same listener proves the rejection was a
    decision rather than an outage.
    """
    cert, key = _server_cert(tmp_path)
    ca_cert, ca_key = _make_ca(tmp_path, "trusted")
    good = _client_cert(tmp_path, ca_cert, ca_key, "good-client")

    port = _free_port()
    _serve_mtls_in_background(
        _echo, port, cert, key,
        ssl_ca_file=ca_cert, ssl_verify_client=True,
    )

    _assert_rejected(port, client_cert=None)
    assert _https_get(port, client_cert=good) == 200, (
        "the server stopped serving trusted clients; the rejection above "
        "was not a policy decision"
    )


def test_client_cert_from_an_untrusted_ca_is_rejected(tmp_path: Path) -> None:
    """A self-signed client certificate the server was not told to trust
    must be refused. This is the case that actually proves the CA bundle
    is being consulted — `SSL_VERIFY_PEER` alone would reject nothing
    beyond a malformed cert."""
    cert, key = _server_cert(tmp_path)
    trusted_ca, trusted_key = _make_ca(tmp_path, "trusted")
    rogue_ca, rogue_key = _make_ca(tmp_path, "rogue")
    rogue_client = _client_cert(tmp_path, rogue_ca, rogue_key, "rogue-client")

    port = _free_port()
    _serve_mtls_in_background(
        _echo, port, cert, key,
        ssl_ca_file=trusted_ca, ssl_verify_client=True,
    )

    _assert_rejected(port, client_cert=rogue_client)


def test_two_clients_one_rejected_one_accepted(tmp_path: Path) -> None:
    """Same server, same connection sequence: a rogue cert is refused and
    a trusted one is served. Guards against a fix that simply breaks the
    handshake for everyone."""
    cert, key = _server_cert(tmp_path)
    trusted_ca, trusted_key = _make_ca(tmp_path, "trusted")
    rogue_ca, rogue_key = _make_ca(tmp_path, "rogue")
    good = _client_cert(tmp_path, trusted_ca, trusted_key, "good-client")
    bad = _client_cert(tmp_path, rogue_ca, rogue_key, "rogue-client")

    port = _free_port()
    _serve_mtls_in_background(
        _echo, port, cert, key,
        ssl_ca_file=trusted_ca, ssl_verify_client=True,
    )

    _assert_rejected(port, client_cert=bad)
    assert _https_get(port, client_cert=good) == 200


# ---------------------------------------------------------------------------
# The off switches
# ---------------------------------------------------------------------------


def test_ca_loaded_without_verify_client_still_serves_anonymous(
    tmp_path: Path,
) -> None:
    """`ssl_ca_file` on its own must not start demanding certificates.
    Loading a trust store and requiring client certs are two separate
    decisions in the API, and conflating them would break every operator
    who loads a CA for one listener and mutes another."""
    cert, key = _server_cert(tmp_path)
    ca_cert, ca_key = _make_ca(tmp_path, "trusted")

    port = _free_port()
    _serve_mtls_in_background(
        _echo, port, cert, key,
        ssl_ca_file=ca_cert, ssl_verify_client=False,
    )

    assert _https_get(port, client_cert=None) == 200


def test_plain_tls_still_works_with_no_ca_at_all(tmp_path: Path) -> None:
    """The baseline: without mTLS options this is an ordinary HTTPS
    server. Guards the default path against the mTLS wiring."""
    cert, key = _server_cert(tmp_path)
    port = _free_port()
    _serve_mtls_in_background(_echo, port, cert, key)
    assert _https_get(port, client_cert=None) == 200


def test_missing_ca_file_fails_at_startup(tmp_path: Path) -> None:
    """`SSL_CTX_load_verify_locations` returning 0 must abort startup.
    A server that cannot find its trust store and then serves anyway
    would be silently accepting any client certificate — or, worse,
    silently serving with no verification while the operator believes
    mTLS is on."""
    cert, key = _server_cert(tmp_path)
    ca_cert, ca_key = _make_ca(tmp_path, "trusted")
    absent = tmp_path / "does-not-exist.pem"

    port = _free_port()
    errors: list[str] = []

    from saltare import run

    def _serve() -> None:
        try:
            run(
                _echo,
                host="127.0.0.1",
                port=port,
                ssl_certfile=cert,
                ssl_keyfile=key,
                ssl_ca_file=str(absent),
                ssl_verify_client=True,
            )
        except BaseException as exc:  # noqa: BLE001 - recorded and asserted
            errors.append(f"{type(exc).__name__}: {exc}")

    t = threading.Thread(target=_serve, daemon=True)
    t.start()
    t.join(timeout=5.0)

    assert not t.is_alive(), (
        "serve() returned instead of blocking, or kept running despite an "
        "unreadable CA file"
    )
    assert errors, (
        "an unreadable ssl_ca_file must raise at startup; the server "
        "stayed up, which means mTLS was silently disabled"
    )
    # And nothing is listening on the port.
    with pytest.raises((ConnectionRefusedError, OSError)):
        socket.create_connection(("127.0.0.1", port), timeout=0.5).close()
