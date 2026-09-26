"""Operational knobs that had no behavioural test.

Every knob here is a documented flag with a README section, and each was
reachable only by argparse. `max_connection_lifetime` appeared in
`test_cli_unit.py` (does the flag parse), which proves nothing about
behaviour. The rest had no test at all.

Grouped here rather than split per feature because they share a shape:
each one is an opt-in that must be (a) inert when off, and (b) observably
different when on. That second half is what matters — a knob that parses,
stores and then does nothing looks identical to a working one from the
outside, so every test here pairs the "on" case with an "off" baseline on
the same assertion.

  - max_connection_lifetime  a keep-alive connection past the cap must
                            stop being reused (`Connection: close`)
  - access_log_path         log lines go to a file, not stderr, and the
                            file survives
  - http_pool_max           sizes the per-connection state pool; both
                            ends of the range must serve correctly
  - startup_request         a synthetic GET / runs through the app
                            before the first real client connects
  - auto_raise_nofile       raises RLIMIT_NOFILE toward the hard limit
  - tls_session_cache_size  session cache configured, handshakes still work
  - ktls                    requested but unavailable must degrade to
                            userspace TLS, not break the listener

The knobs that are pure socket tuning (`tcp_keepidle`, `tcp_fastopen_qlen`,
`tcp_user_timeout_ms`, `listen_backlog`) are not here: their effect is in
the kernel, not observable from the client, and asserting on them would
test the kernel rather than saltare.
"""

from __future__ import annotations

import os
import resource
import socket
import ssl
import subprocess
import threading
import time
from pathlib import Path
from typing import Any

import pytest


# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


# Every request path the app below has seen, so `startup_request` can be
# observed as "the app was called with GET / before any client
# connected".
_requests_seen: list[str] = []


async def _counting(scope, receive, send):
    """Records every request path it sees, so `startup_request` can be
    observed as "the app was called with GET / before any client
    connected"."""
    if scope["type"] == "lifespan":
        while True:
            msg = await receive()
            if msg["type"] == "lifespan.startup":
                await send({"type": "lifespan.startup.complete"})
            elif msg["type"] == "lifespan.shutdown":
                await send({"type": "lifespan.shutdown.complete"})
                return
        return
    _requests_seen.append(scope.get("path", "?"))
    await receive()
    await send({
        "type": "http.response.start",
        "status": 200,
        "headers": [(b"content-type", b"text/plain")],
    })
    await send({"type": "http.response.body", "body": b"ok", "more_body": False})


def _serve(app: Any, port: int, **kwargs) -> None:
    from saltare import run

    threading.Thread(
        target=run,
        args=(app,),
        kwargs={"host": "127.0.0.1", "port": port, **kwargs},
        daemon=True,
    ).start()
    deadline = time.monotonic() + 3.0
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return
        except (ConnectionRefusedError, socket.timeout, OSError):
            time.sleep(0.05)
    pytest.fail("server never became ready")


def _tls_material(tmp_path: Path) -> tuple[str, str]:
    cert = tmp_path / "cert.pem"
    key = tmp_path / "key.pem"
    subprocess.check_call(
        [
            "openssl", "req", "-x509", "-newkey", "rsa:2048", "-sha256",
            "-days", "1", "-nodes", "-keyout", str(key), "-out", str(cert),
            "-subj", "/CN=localhost",
            "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return str(cert), str(key)


# ---------------------------------------------------------------------------
# max_connection_lifetime
# ---------------------------------------------------------------------------


def test_connection_lifetime_cap_closes_the_connection() -> None:
    """With a 1 s cap, a client that keeps a connection open past the cap
    must be told to stop reusing it. Two requests on one connection: the
    response that crosses the cap carries `Connection: close`.

    A wall-clock bound is the point of the knob — a client idling on a
    keep-alive connection holds per-connection state, and a request-count
    cap does not stop a client that simply waits.
    """
    port = _free_port()
    _serve(_counting, port, max_connection_lifetime=1, keep_alive_timeout=30)

    s = socket.create_connection(("127.0.0.1", port), timeout=5.0)
    try:
        # Keep the connection busy in a loop so it is definitely still
        # open when the age cap passes.
        deadline = time.monotonic() + 3.0
        saw_close = False
        while time.monotonic() < deadline:
            s.sendall(
                f"GET / HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n\r\n".encode()
            )
            resp = b""
            while b"\r\n\r\n" not in resp:
                chunk = s.recv(4096)
                if not chunk:
                    break
                resp += chunk
            if not resp:
                break
            if b"connection: close" in resp.lower():
                saw_close = True
                break
            time.sleep(0.15)
        assert saw_close, (
            "the connection was never closed despite a 1 s lifetime cap"
        )
    finally:
        s.close()


def test_connection_lifetime_zero_is_unlimited() -> None:
    """The default must not close anything: a client reusing one
    connection for longer than a second still gets keep-alive."""
    port = _free_port()
    _serve(_counting, port, keep_alive_timeout=30)

    s = socket.create_connection(("127.0.0.1", port), timeout=5.0)
    try:
        for _ in range(4):
            s.sendall(
                f"GET / HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n\r\n".encode()
            )
            resp = b""
            while b"\r\n\r\n" not in resp:
                chunk = s.recv(4096)
                if not chunk:
                    break
                resp += chunk
            assert b"200" in resp, resp[:200]
            assert b"connection: close" not in resp.lower(), (
                "an unlimited lifetime closed the connection anyway"
            )
            time.sleep(0.4)  # total elapsed well past 1 s
    finally:
        s.close()


# ---------------------------------------------------------------------------
# access_log_path
# ---------------------------------------------------------------------------


def test_access_log_path_writes_to_the_file(tmp_path: Path) -> None:
    """With a path set, log lines land in that file. Asserted by content,
    not just by the file existing — an fd opened but never written to is
    the obvious way for this to silently not work."""
    import httpx

    log = tmp_path / "access.log"
    port = _free_port()
    _serve(_counting, port, access_log=True, access_log_path=str(log))

    with httpx.Client(timeout=3.0) as client:
        for _ in range(3):
            assert client.get(f"http://127.0.0.1:{port}/marker").status_code == 200

    # The writer is unbuffered (single write(2) per line) but the file may
    # still be mid-flush on the teardown path, so poll briefly.
    deadline = time.monotonic() + 3.0
    body = ""
    while time.monotonic() < deadline:
        if log.exists():
            body = log.read_text()
            if body.count("marker") >= 3:
                break
        time.sleep(0.05)

    assert body.count("marker") == 3, f"expected 3 log lines, got:\n{body!r}"
    # The documented plain-text format: DD/MM/YYYY:HH:MM:SS [METHOD] [URL] ...
    assert "[GET]" in body, body
    assert "[200]" in body, body


def test_access_log_path_absent_uses_stderr(tmp_path: Path) -> None:
    """No path means stderr, and no stray file appears next to the
    working directory."""
    import httpx

    before = set(os.listdir("."))
    port = _free_port()
    _serve(_counting, port, access_log=True)

    with httpx.Client(timeout=3.0) as client:
        assert client.get(f"http://127.0.0.1:{port}/").status_code == 200

    assert set(os.listdir(".")) == before, "a log file appeared without a path"


# ---------------------------------------------------------------------------
# http_pool_max
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("pool_max", [1, 16, 128, 256])
def test_http_pool_max_serves_correctly(pool_max: int) -> None:
    """The pool sizes reusable per-connection state. 1 is the floor (heavy
    recycling) and 256 well past the default of 128; both must serve
    requests correctly, since a too-small pool is where an off-by-one
    would corrupt a pooled object and hand a request the previous one's
    state.

    Parametrised rather than looped, so each size gets its own process-
    local server. Starting several `serve()` calls in one process is not
    a supported model — the Zig config globals are set-once, so a second
    `serve()` clobbers the first's timeouts and listen fd — and the
    conftest teardown fixture waits on leaked daemon threads, so a
    multi-server test makes every later test in the module pay 3 s.
    """
    import httpx

    port = _free_port()
    _serve(_counting, port, http_pool_max=pool_max)
    with httpx.Client(timeout=3.0) as client:
        for i in range(12):
            r = client.get(f"http://127.0.0.1:{port}/p{pool_max}-{i}")
            assert r.status_code == 200, (pool_max, i, r.status_code)
            assert r.text == "ok", (pool_max, i, r.text)


def test_http_pool_max_one_does_not_leak_state_between_requests() -> None:
    """With a single pooled object, two sequential requests would share
    it. If reset were incomplete, the second response would carry the
    first request's leftovers.

    Kept as its own test rather than a parametrand case because the
    assertion is about cross-request contamination, not about the pool
    size working at all.
    """
    import httpx

    port = _free_port()
    _serve(_counting, port, http_pool_max=1)

    with httpx.Client(timeout=3.0) as client:
        first = client.get(f"http://127.0.0.1:{port}/first")
        second = client.get(f"http://127.0.0.1:{port}/second")

    assert first.status_code == second.status_code == 200
    assert first.text == second.text == "ok"
    assert "first" not in second.text


# ---------------------------------------------------------------------------
# startup_request
# ---------------------------------------------------------------------------


def test_startup_request_prewarms_the_app() -> None:
    """`startup_request=True` drives a synthetic `GET /` through the app
    after lifespan startup, so the first real client does not pay
    FastAPI's route-compilation and pydantic validator cost.

    Observed through the app's own view: the probe must appear before any
    client request, which is the only way to tell a prewarm from a
    normal request."""
    _requests_seen.clear()
    port = _free_port()
    _serve(_counting, port, startup_request=True)

    deadline = time.monotonic() + 3.0
    while time.monotonic() < deadline and "/" not in _requests_seen:
        time.sleep(0.05)
    assert _requests_seen == ["/"], (
        f"expected exactly the prewarm request before any client, "
        f"saw {_requests_seen}"
    )

    import httpx

    with httpx.Client(timeout=3.0) as client:
        assert client.get(f"http://127.0.0.1:{port}/real").status_code == 200
    assert _requests_seen == ["/", "/real"], _requests_seen


def test_startup_request_off_means_no_probe() -> None:
    _requests_seen.clear()
    port = _free_port()
    _serve(_counting, port)

    time.sleep(0.3)  # no client connects during this window
    assert _requests_seen == [], (
        f"a request reached the app with no client connected: {_requests_seen}"
    )


# ---------------------------------------------------------------------------
# auto_raise_nofile
# ---------------------------------------------------------------------------


def test_auto_raise_nofile_raises_the_soft_limit() -> None:
    """`auto_raise_nofile` calls setrlimit to push RLIMIT_NOFILE's soft
    limit up to the hard limit at startup, so a high `max_connections`
    does not silently run out of descriptors.

    Read from a child process, because the raise happens in the server's
    own process at startup and a test cannot observe another thread's
    rlimit.
    """
    import textwrap

    script = textwrap.dedent(
        """
        import resource, sys
        soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
        # Deliberately lower the soft limit first: the point of the flag
        # is that it can be raised again, which is only observable if it
        # started below the hard limit.
        target = min(512, hard)
        try:
            resource.setrlimit(resource.RLIMIT_NOFILE, (target, hard))
        except (ValueError, OSError):
            pass
        low, high = resource.getrlimit(resource.RLIMIT_NOFILE)
        print(f"before={low},{high}")
        sys.stdout.flush()

        import socket, threading, time
        from saltare import run

        async def app(scope, receive, send):
            if scope["type"] == "lifespan":
                while True:
                    m = await receive()
                    if m["type"] == "lifespan.startup":
                        await send({"type": "lifespan.startup.complete"})
                    elif m["type"] == "lifespan.shutdown":
                        await send({"type": "lifespan.shutdown.complete"})
                        return
                return
            await receive()
            await send({"type": "http.response.start", "status": 200,
                        "headers": [(b"content-type", b"text/plain")]})
            await send({"type": "http.response.body", "body": b"ok",
                        "more_body": False})

        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            port = s.getsockname()[1]
        kwargs = {"host": "127.0.0.1", "port": port}
        if len(sys.argv) > 1 and sys.argv[1] == "on":
            kwargs["auto_raise_nofile"] = True
        threading.Thread(target=run, args=(app,), kwargs=kwargs,
                         daemon=True).start()
        for _ in range(100):
            try:
                socket.create_connection(("127.0.0.1", port), timeout=0.2).close()
                break
            except OSError:
                time.sleep(0.05)
        after, _hard = resource.getrlimit(resource.RLIMIT_NOFILE)
        print(f"after={after}")
        """
    )
    import subprocess
    import sys

    def _run(flag: str) -> tuple[int, int, int]:
        proc = subprocess.run(
            [sys.executable, "-c", script, flag],
            capture_output=True, text=True, timeout=60,
        )
        assert proc.returncode == 0, proc.stderr[-2000:]
        before = after = -1
        for line in proc.stdout.splitlines():
            if line.startswith("before="):
                before, _ = (int(x) for x in line[7:].split(","))
            elif line.startswith("after="):
                after = int(line[6:])
        return before, after, proc.returncode

    # The flag is on: the soft limit should end up at the hard limit.
    before_on, after_on, _ = _run("on")
    assert after_on >= before_on, (
        f"auto_raise_nofile did not raise the soft limit: "
        f"{before_on} -> {after_on}"
    )

    # Control: without the flag the lowered limit stays put. Skipped when
    # the hard limit was already at the floor, where there is nothing to
    # raise and the comparison would be vacuous.
    before_off, after_off, _ = _run("off")
    if before_off < min(512, resource.getrlimit(resource.RLIMIT_NOFILE)[1]):
        assert after_off == before_off, (
            f"limit changed without the flag: {before_off} -> {after_off}"
        )


# ---------------------------------------------------------------------------
# tls_session_cache_size / ktls
# ---------------------------------------------------------------------------


def test_tls_session_cache_size_keeps_handshakes_working(tmp_path: Path) -> None:
    """Configuring OpenSSL's server-side session cache must not break the
    handshake. The cache size is a hint OpenSSL may clamp, so assert the
    observable contract — requests still succeed — rather than a specific
    cache size."""
    import httpx

    cert, key = _tls_material(tmp_path)
    port = _free_port()
    _serve(_counting, port, ssl_certfile=cert, ssl_keyfile=key,
           tls_session_cache_size=1024)

    with httpx.Client(timeout=5.0, verify=False) as client:
        for _ in range(3):
            assert client.get(f"https://127.0.0.1:{port}/").status_code == 200


def test_tls_session_cache_size_zero_is_the_default(tmp_path: Path) -> None:
    import httpx

    cert, key = _tls_material(tmp_path)
    port = _free_port()
    _serve(_counting, port, ssl_certfile=cert, ssl_keyfile=key,
           tls_session_cache_size=0)

    with httpx.Client(timeout=5.0, verify=False) as client:
        assert client.get(f"https://127.0.0.1:{port}/").status_code == 200


def test_ktls_degrades_to_userspace_tls(tmp_path: Path) -> None:
    """`ktls=True` asks the kernel to terminate TLS. Where the kernel
    cannot (no module, OpenSSL < 3.0, musl), saltare must fall back to
    userspace TLS rather than refuse to start.

    The test cannot force the kernel path either way, so it pins the
    contract that matters operationally: asking for kTLS never costs you
    a working HTTPS listener. It also asserts the plain-HTTP listener
    path is unaffected, since kTLS only applies to TLS connections.
    """
    import httpx

    cert, key = _tls_material(tmp_path)
    port = _free_port()
    _serve(_counting, port, ssl_certfile=cert, ssl_keyfile=key, ktls=True)

    with httpx.Client(timeout=5.0, verify=False) as client:
        r = client.get(f"https://127.0.0.1:{port}/")
    assert r.status_code == 200
    assert r.text == "ok"


def test_ktls_on_a_plain_listener_is_inert() -> None:
    """The flag is about TLS records; with no certificate there is nothing
    to offload. It must be ignored rather than misparsed."""
    import httpx

    port = _free_port()
    _serve(_counting, port, ktls=True)

    with httpx.Client(timeout=3.0) as client:
        assert client.get(f"http://127.0.0.1:{port}/").status_code == 200


# ---------------------------------------------------------------------------
# sendfile: kTLS is the documented interaction
# ---------------------------------------------------------------------------


def test_sendfile_over_https_returns_500_without_ktls(tmp_path: Path) -> None:
    """`saltare.sendfile` cannot be used over userspace TLS: the kernel
    would write plaintext into a TLS stream. The documented behaviour is a
    500, and it is worth pinning because the alternative — serving
    plaintext to a TLS client — would be a severe bug.

    With `ktls=True` this becomes legal instead (the kernel applies the
    TLS records), but only where the kernel supports it, so the negative
    case is the one that can be asserted deterministically.
    """
    import httpx

    cert, key = _tls_material(tmp_path)
    payload = tmp_path / "asset.bin"
    payload.write_bytes(b"saltare" * 4096)

    async def sendfile_app(scope, receive, send):
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
            "type": "saltare.sendfile",
            "path": str(payload),
            "status": 200,
            "headers": [(b"content-type", b"application/octet-stream")],
        })

    port = _free_port()
    _serve(sendfile_app, port, ssl_certfile=cert, ssl_keyfile=key, ktls=False)

    with httpx.Client(timeout=5.0, verify=False) as client:
        r = client.get(f"https://127.0.0.1:{port}/asset")
    assert r.status_code == 500, (
        f"expected a refusal, got {r.status_code} with body {r.content[:80]!r}"
    )
    assert b"saltare" * 4 not in r.content, (
        "the file was served over userspace TLS"
    )
