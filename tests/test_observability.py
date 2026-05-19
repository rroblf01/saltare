"""Observability + deployment knobs added in v0.15:

  - metrics_path  → Prometheus text dump from Zig counters.
  - access_log    → JSON line per completed request to stderr.
  - proxy_headers → X-Forwarded-For / X-Forwarded-Proto into ASGI scope.
  - uds_path      → bind a Unix domain socket instead of TCP.
"""

from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
from typing import Any

import httpx
import pytest


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


# ---------------------------------------------------------------------------
# In-process apps shared by several tests


async def echo_scope_app(scope, receive, send):
    """Returns the parts of the ASGI scope we want to introspect."""
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
    payload = json.dumps({
        "scheme": scope.get("scheme"),
        "client": list(scope.get("client") or []),
    }).encode("ascii")
    await send({
        "type": "http.response.start",
        "status": 200,
        "headers": [(b"content-type", b"application/json")],
    })
    await send({"type": "http.response.body", "body": payload, "more_body": False})


async def hello_app(scope, receive, send):
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
    await send({"type": "http.response.body", "body": b"hello\n", "more_body": False})


def _serve_in_background(app: Any, port: int, **kwargs) -> None:
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


# ---------------------------------------------------------------------------
# Metrics


def test_metrics_endpoint_exposes_counters() -> None:
    """When metrics_path is set, GET to that path returns Prometheus text
    with at least the per-connection and per-request counters."""
    port = _free_port()
    _serve_in_background(hello_app, port, metrics_path="/metrics")

    # First, hit / so the request counter has something non-zero.
    r1 = httpx.get(f"http://127.0.0.1:{port}/", timeout=2.0)
    assert r1.status_code == 200

    r2 = httpx.get(f"http://127.0.0.1:{port}/metrics", timeout=2.0)
    assert r2.status_code == 200
    assert r2.headers["content-type"].startswith("text/plain")
    body = r2.text
    # Spot-check: each counter we promised must be present and >= 0.
    for name in (
        "saltare_open_connections",
        "saltare_in_flight_requests",
        "saltare_requests_total",
        "saltare_responses_4xx_total",
        "saltare_responses_5xx_total",
        "saltare_bytes_sent_total",
        "saltare_bytes_received_total",
        "saltare_process_resident_memory_bytes",
    ):
        assert f"# TYPE {name} " in body, f"missing {name}"
        # Find the value line (last token on the line that starts with name).
        line = next((l for l in body.splitlines() if l.startswith(name + " ")), None)
        assert line is not None, f"no value line for {name}"
        value = int(line.rsplit(" ", 1)[1])
        assert value >= 0


def test_metrics_path_intercept_does_not_call_user_app() -> None:
    """The metrics endpoint must be answered entirely from Zig — the user
    app should never see the request even though it's registered."""
    port = _free_port()
    seen_paths: list[str] = []

    async def tracking_app(scope, receive, send):
        if scope["type"] == "lifespan":
            while True:
                msg = await receive()
                if msg["type"] == "lifespan.startup":
                    await send({"type": "lifespan.startup.complete"})
                elif msg["type"] == "lifespan.shutdown":
                    await send({"type": "lifespan.shutdown.complete"})
                    return
            return
        seen_paths.append(scope["path"])
        await receive()
        await send({"type": "http.response.start", "status": 200,
                    "headers": [(b"content-type", b"text/plain")]})
        await send({"type": "http.response.body", "body": b"ok"})

    _serve_in_background(tracking_app, port, metrics_path="/metrics")

    httpx.get(f"http://127.0.0.1:{port}/regular", timeout=2.0)
    httpx.get(f"http://127.0.0.1:{port}/metrics", timeout=2.0)
    httpx.get(f"http://127.0.0.1:{port}/another", timeout=2.0)

    # /metrics must NOT have hit the user app. The other two did.
    assert "/regular" in seen_paths
    assert "/another" in seen_paths
    assert "/metrics" not in seen_paths


# ---------------------------------------------------------------------------
# Proxy headers


def test_proxy_headers_disabled_keeps_client_none() -> None:
    """Without proxy_headers, scope['client'] stays None and scope['scheme']
    is the on-wire scheme (not what X-Forwarded-Proto says)."""
    port = _free_port()
    _serve_in_background(echo_scope_app, port, proxy_headers=False)

    r = httpx.get(
        f"http://127.0.0.1:{port}/",
        headers={
            "X-Forwarded-For": "203.0.113.42",
            "X-Forwarded-Proto": "https",
        },
        timeout=2.0,
    )
    assert r.status_code == 200
    body = r.json()
    assert body["scheme"] == "http"
    assert body["client"] == []


def test_proxy_headers_enabled_lifts_client_and_scheme() -> None:
    port = _free_port()
    _serve_in_background(echo_scope_app, port, proxy_headers=True)

    r = httpx.get(
        f"http://127.0.0.1:{port}/",
        headers={
            "X-Forwarded-For": "203.0.113.42, 10.0.0.1",
            "X-Forwarded-Proto": "https",
        },
        timeout=2.0,
    )
    assert r.status_code == 200
    body = r.json()
    assert body["scheme"] == "https"
    # We trust the leftmost IP as the original client.
    assert body["client"] == ["203.0.113.42", 0]


# ---------------------------------------------------------------------------
# Unix domain sockets


def test_uds_serves_requests() -> None:
    """Bind a Unix socket, send an HTTP request through it, get a response."""
    with tempfile.TemporaryDirectory() as tmp:
        sock_path = os.path.join(tmp, "saltare.sock")

        from saltare import run

        threading.Thread(
            target=run,
            args=(hello_app,),
            kwargs={"host": "ignored", "port": 0, "uds_path": sock_path},
            daemon=True,
        ).start()

        deadline = time.monotonic() + 2.0
        while time.monotonic() < deadline:
            if os.path.exists(sock_path):
                break
            time.sleep(0.05)
        else:
            pytest.fail("UDS path was never created")

        # Manual HTTP/1.1 over UDS.
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect(sock_path)
        try:
            sock.sendall(b"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
            sock.settimeout(2.0)
            buf = b""
            while True:
                chunk = sock.recv(4096)
                if not chunk:
                    break
                buf += chunk
        finally:
            sock.close()

        assert b"200 OK" in buf
        assert b"hello" in buf


# ---------------------------------------------------------------------------
# Access log (subprocess to capture stderr cleanly)


def test_access_log_emits_json_line_per_request() -> None:
    port = _free_port()
    src = f"""
import saltare

async def app(scope, receive, send):
    if scope["type"] == "lifespan":
        while True:
            msg = await receive()
            if msg["type"] == "lifespan.startup":
                await send({{"type": "lifespan.startup.complete"}})
            elif msg["type"] == "lifespan.shutdown":
                await send({{"type": "lifespan.shutdown.complete"}})
                return
        return
    await receive()
    await send({{"type": "http.response.start", "status": 200,
                "headers": [(b"content-type", b"text/plain")]}})
    await send({{"type": "http.response.body", "body": b"hi", "more_body": False}})

saltare.run(app, host="127.0.0.1", port={port}, access_log=True)
"""
    proc = subprocess.Popen(
        [sys.executable, "-c", src],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )
    try:
        # Wait for ready.
        deadline = time.monotonic() + 5.0
        while time.monotonic() < deadline:
            if proc.poll() is not None:
                pytest.fail(f"subprocess exited prematurely")
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                    break
            except (ConnectionRefusedError, socket.timeout):
                time.sleep(0.05)
        else:
            pytest.fail("subprocess never became ready")

        # Make a request with a recognisable User-Agent.
        r = httpx.get(
            f"http://127.0.0.1:{port}/probe?x=1",
            headers={"User-Agent": "saltare-test/1.0"},
            timeout=2.0,
        )
        assert r.status_code == 200

        # Give the server a beat to emit + flush, then send SIGTERM so we
        # can drain stderr.
        time.sleep(0.2)
        proc.terminate()
        try:
            stderr_data = proc.stderr.read() if proc.stderr else b""
        except Exception:
            stderr_data = b""
        proc.wait(timeout=5.0)

        # v1.6.1 line format: `DD/MM/YYYY:HH:MM:SS [METHOD] [URL] [STATUS] [BYTES]`.
        # Match by the recognisable tokens. Body / user-agent are no longer
        # part of the line (drop noise; structured logs go elsewhere).
        import re as _re
        text = stderr_data.decode(errors="replace")
        candidates = [
            line for line in text.splitlines()
            if "[GET]" in line and "[/probe?x=1]" in line
        ]
        assert candidates, f"no access-log line found in stderr: {text[-500:]!r}"
        line = candidates[0]
        m = _re.match(
            r"(\d{2})/(\d{2})/(\d{4}):(\d{2}):(\d{2}):(\d{2}) "
            r"\[GET\] \[/probe\?x=1\] \[(\d{3})\] \[(\d+)\]",
            line,
        )
        assert m, f"line did not match expected format: {line!r}"
        status_str, bytes_str = m.group(7), m.group(8)
        assert status_str == "200"
        assert int(bytes_str) > 0
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()


def test_access_log_exclude_silences_listed_paths() -> None:
    """`access_log_exclude=[...]` skips listed paths from the log without
    affecting the request itself (status / body unchanged)."""
    port = _free_port()
    src = f"""
import saltare

async def app(scope, receive, send):
    if scope["type"] == "lifespan":
        while True:
            msg = await receive()
            if msg["type"] == "lifespan.startup":
                await send({{"type": "lifespan.startup.complete"}})
            elif msg["type"] == "lifespan.shutdown":
                await send({{"type": "lifespan.shutdown.complete"}})
                return
        return
    await receive()
    await send({{"type": "http.response.start", "status": 200,
                "headers": [(b"content-type", b"text/plain")]}})
    await send({{"type": "http.response.body", "body": b"hi", "more_body": False}})

saltare.run(
    app, host="127.0.0.1", port={port},
    access_log=True,
    access_log_exclude=["/skip-me", "/healthz"],
)
"""
    proc = subprocess.Popen(
        [sys.executable, "-c", src],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )
    try:
        deadline = time.monotonic() + 5.0
        while time.monotonic() < deadline:
            if proc.poll() is not None:
                pytest.fail("subprocess exited prematurely")
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                    break
            except (ConnectionRefusedError, socket.timeout):
                time.sleep(0.05)
        else:
            pytest.fail("subprocess never became ready")

        # Excluded path: served fine, no log line.
        r_skip = httpx.get(f"http://127.0.0.1:{port}/skip-me",
                           headers={"User-Agent": "skip-ua/1.0"}, timeout=2.0)
        assert r_skip.status_code == 200
        # Non-excluded path: logged.
        r_keep = httpx.get(f"http://127.0.0.1:{port}/keep-me",
                           headers={"User-Agent": "keep-ua/1.0"}, timeout=2.0)
        assert r_keep.status_code == 200

        time.sleep(0.2)
        proc.terminate()
        try:
            stderr_data = proc.stderr.read() if proc.stderr else b""
        except Exception:
            stderr_data = b""
        proc.wait(timeout=5.0)

        text = stderr_data.decode(errors="replace")
        # v1.6.1 line format: `[METHOD] [URL] [STATUS] [BYTES]`.
        # Excluded → no record carrying its target.
        assert "[/skip-me]" not in text, \
            f"expected /skip-me to be filtered, but log shows it: {text[-500:]!r}"
        # Non-excluded → recorded.
        assert "[/keep-me]" in text, \
            f"expected /keep-me to be logged, got: {text[-500:]!r}"
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()
