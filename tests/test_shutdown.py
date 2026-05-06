"""Graceful shutdown behaviour and ASGI exception isolation (v0.14).

Graceful shutdown is tested in subprocess because the signal handler is
process-wide and would kill the test runner if exercised in-process. The
exception-isolation tests stay in-process (they're cheaper).
"""

from __future__ import annotations

import signal
import socket
import subprocess
import sys
import threading
import time
from typing import Any

import httpx
import pytest


# ---------------------------------------------------------------------------
# Shared helpers


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


# ---------------------------------------------------------------------------
# Subprocess-driven graceful-shutdown tests


def _spawn_saltare_subprocess(
    port: int, sleep_secs: float = 1.0, shutdown_timeout: int = 30
) -> subprocess.Popen:
    """Launch saltare in a child Python process running an app whose
    response is artificially delayed by `asyncio.sleep(sleep_secs)`.
    Returns the Popen handle once the server's listening socket accepts
    connections."""
    src = f"""
import asyncio
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
    await asyncio.sleep({sleep_secs})
    await send({{
        "type": "http.response.start",
        "status": 200,
        "headers": [(b"content-type", b"text/plain")],
    }})
    await send({{"type": "http.response.body", "body": b"slow ok\\n", "more_body": False}})

saltare.run(app, host="127.0.0.1", port={port}, shutdown_timeout={shutdown_timeout})
"""
    proc = subprocess.Popen(
        [sys.executable, "-c", src],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            err = (proc.stderr.read() if proc.stderr else b"").decode(errors="replace")
            pytest.fail(f"subprocess exited prematurely: rc={proc.returncode} err={err}")
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return proc
        except (ConnectionRefusedError, socket.timeout):
            time.sleep(0.05)
    proc.terminate()
    pytest.fail("subprocess never became ready")


def _kill_if_alive(proc: subprocess.Popen) -> None:
    if proc.poll() is None:
        proc.kill()
        try:
            proc.wait(timeout=2.0)
        except subprocess.TimeoutExpired:
            pass


def test_graceful_shutdown_lets_inflight_request_complete() -> None:
    """A SIGTERM during an in-flight request must let the request finish
    before the server exits."""
    port = _free_port()
    proc = _spawn_saltare_subprocess(port, sleep_secs=1.0, shutdown_timeout=30)
    try:
        sock = socket.create_connection(("127.0.0.1", port), timeout=5.0)
        sock.sendall(b"GET /slow HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        time.sleep(0.15)  # let saltare start dispatching
        proc.send_signal(signal.SIGTERM)

        sock.settimeout(10.0)
        buf = b""
        while True:
            chunk = sock.recv(4096)
            if not chunk:
                break
            buf += chunk
        sock.close()
        assert b"200 OK" in buf, f"unexpected response: {buf!r}"
        assert b"slow ok" in buf, f"unexpected body: {buf!r}"

        rc = proc.wait(timeout=5.0)
        assert rc == 0, f"subprocess exited with code {rc}"
    finally:
        _kill_if_alive(proc)


def test_graceful_shutdown_timeout_force_exits() -> None:
    """If in-flight requests would take longer than `shutdown_timeout`,
    the server exits anyway and the client gets disconnected mid-response."""
    port = _free_port()
    # App sleeps 10 s; shutdown_timeout caps the drain at 1 s.
    proc = _spawn_saltare_subprocess(port, sleep_secs=10.0, shutdown_timeout=1)
    try:
        sock = socket.create_connection(("127.0.0.1", port), timeout=5.0)
        sock.sendall(b"GET /reallyslow HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        time.sleep(0.15)

        t0 = time.monotonic()
        proc.send_signal(signal.SIGTERM)
        rc = proc.wait(timeout=8.0)
        elapsed = time.monotonic() - t0

        assert rc == 0, f"subprocess exited with code {rc}"
        # 1 s shutdown_timeout + a bit of slack for lifespan teardown.
        assert elapsed < 4.0, f"server took {elapsed:.2f}s, expected ~1s"

        sock.settimeout(2.0)
        try:
            data = sock.recv(4096)
            assert b"slow ok" not in data, "request shouldn't have completed"
        except (ConnectionResetError, socket.timeout):
            pass
        sock.close()
    finally:
        _kill_if_alive(proc)


def test_idle_server_exits_immediately_on_sigterm() -> None:
    """With no in-flight requests, SIGTERM should result in a near-instant
    exit (just the cost of asyncio lifespan teardown)."""
    port = _free_port()
    proc = _spawn_saltare_subprocess(port, sleep_secs=0.0, shutdown_timeout=30)
    try:
        # Probe the server is alive, then close the probe socket immediately.
        with socket.create_connection(("127.0.0.1", port), timeout=2.0):
            pass
        # Wait briefly so the probe connection gets fully reaped (its
        # idle keep-alive timer would otherwise hold the active count).
        time.sleep(0.2)

        t0 = time.monotonic()
        proc.send_signal(signal.SIGTERM)
        rc = proc.wait(timeout=10.0)
        elapsed = time.monotonic() - t0

        assert rc == 0, f"subprocess exited with code {rc}"
        # Idle conns reap via keep_alive_timeout (default 5 s); add slack.
        assert elapsed < 7.0, f"idle drain took {elapsed:.2f}s"
    finally:
        _kill_if_alive(proc)


# ---------------------------------------------------------------------------
# In-process exception-isolation tests


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


def test_app_exception_before_response_returns_500() -> None:
    """An ASGI app that raises before sending any response message should
    elicit a synthesized 500 from saltare; the server itself must not
    crash and must keep serving subsequent requests."""

    request_count = 0

    async def flaky_app(scope, receive, send):
        nonlocal request_count
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
        request_count += 1
        if request_count == 1:
            raise RuntimeError("intentional v0.14 test failure")
        await send({
            "type": "http.response.start",
            "status": 200,
            "headers": [(b"content-type", b"text/plain")],
        })
        await send({"type": "http.response.body", "body": b"second ok\n"})

    port = _free_port()
    _serve_in_background(flaky_app, port)

    r1 = httpx.get(f"http://127.0.0.1:{port}/", timeout=2.0)
    assert r1.status_code == 500

    # Server still alive: subsequent request goes through.
    r2 = httpx.get(f"http://127.0.0.1:{port}/", timeout=2.0)
    assert r2.status_code == 200
    assert r2.content == b"second ok\n"


def test_app_exception_mid_stream_closes_connection() -> None:
    """If the app raises *after* sending the start frame, the response is
    half-written and the only safe thing is to close the connection. The
    server keeps serving."""

    async def flaky_app(scope, receive, send):
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
        if scope["path"] == "/boom":
            await send({
                "type": "http.response.start",
                "status": 200,
                "headers": [(b"content-type", b"text/plain")],
            })
            await send({"type": "http.response.body", "body": b"hi", "more_body": True})
            raise RuntimeError("mid-stream failure")
        await send({
            "type": "http.response.start",
            "status": 200,
            "headers": [(b"content-type", b"text/plain")],
        })
        await send({"type": "http.response.body", "body": b"healthy\n"})

    port = _free_port()
    _serve_in_background(flaky_app, port)

    # /boom: the response truncates; httpx surfaces this as a protocol error
    # OR a partial body depending on timing. We just want to confirm the
    # server stayed up.
    try:
        httpx.get(f"http://127.0.0.1:{port}/boom", timeout=2.0)
    except (httpx.RemoteProtocolError, httpx.ReadError):
        pass

    r = httpx.get(f"http://127.0.0.1:{port}/health", timeout=2.0)
    assert r.status_code == 200
    assert r.content == b"healthy\n"
