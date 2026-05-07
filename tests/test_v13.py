"""v1.3 feature tests:

  - health_path                — Zig-side `200 ok` intercept.
  - cors_preflight_allow_all   — Zig-side OPTIONS+Origin → 204 + headers.
  - rate_limit_per_sec         — token-bucket 429 in Zig.
  - tracemalloc_path           — top-N Python alloc dump from Zig.
  - IPv6 listen                — `host="::1"` binds AF_INET6.
  - URL decode in Zig          — `%xx` sequences decoded before scope build.
"""

from __future__ import annotations

import socket
import threading
import time
from typing import Any

import httpx
import pytest


def _free_port(family: int = socket.AF_INET) -> int:
    if family == socket.AF_INET6:
        with socket.socket(socket.AF_INET6) as s:
            s.bind(("::1", 0))
            return s.getsockname()[1]
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


async def _hello(scope, receive, send):
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
    await send({
        "type": "http.response.body",
        "body": b"hello\n",
        "more_body": False,
    })


def _serve_in_background(app: Any, port: int, host: str = "127.0.0.1", **kwargs) -> None:
    from saltare import run

    threading.Thread(
        target=run,
        args=(app,),
        kwargs={"host": host, "port": port, **kwargs},
        daemon=True,
    ).start()
    family = socket.AF_INET6 if ":" in host else socket.AF_INET
    bind_host = host.strip("[]") if host.startswith("[") else host
    deadline = time.monotonic() + 3.0
    while time.monotonic() < deadline:
        try:
            with socket.socket(family, socket.SOCK_STREAM) as s:
                s.settimeout(0.2)
                s.connect((bind_host, port))
                return
        except (ConnectionRefusedError, socket.timeout, OSError):
            time.sleep(0.05)
    pytest.fail(f"server never became ready on [{host}]:{port}")


# ---------------------------------------------------------------------------
# Health endpoint
# ---------------------------------------------------------------------------


def test_health_path_returns_ok_without_dispatch() -> None:
    """`health_path` is answered entirely from Zig — the user app
    should never see the request."""
    port = _free_port()
    seen_paths: list[str] = []

    async def tracking(scope, receive, send):
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
        await send({"type": "http.response.body", "body": b"app", "more_body": False})

    _serve_in_background(tracking, port, health_path="/healthz")

    r = httpx.get(f"http://127.0.0.1:{port}/healthz", timeout=2.0)
    assert r.status_code == 200
    assert r.text == "ok\n"
    assert r.headers["content-type"].startswith("text/plain")

    # User app shouldn't have seen `/healthz`.
    httpx.get(f"http://127.0.0.1:{port}/regular", timeout=2.0)
    assert "/healthz" not in seen_paths
    assert "/regular" in seen_paths


# ---------------------------------------------------------------------------
# CORS preflight
# ---------------------------------------------------------------------------


def test_cors_preflight_intercepts_options_with_origin() -> None:
    """OPTIONS-with-Origin gets answered from Zig with 204 + permissive
    headers; the app never sees the preflight."""
    port = _free_port()
    seen_methods: list[str] = []

    async def tracking(scope, receive, send):
        if scope["type"] == "lifespan":
            while True:
                msg = await receive()
                if msg["type"] == "lifespan.startup":
                    await send({"type": "lifespan.startup.complete"})
                elif msg["type"] == "lifespan.shutdown":
                    await send({"type": "lifespan.shutdown.complete"})
                    return
            return
        seen_methods.append(scope["method"])
        await receive()
        await send({"type": "http.response.start", "status": 200,
                    "headers": [(b"content-type", b"text/plain")]})
        await send({"type": "http.response.body", "body": b"app", "more_body": False})

    _serve_in_background(tracking, port, cors_preflight_allow_all=True)

    # Preflight: must be 204 + CORS headers.
    r = httpx.options(
        f"http://127.0.0.1:{port}/api/x",
        headers={"Origin": "https://example.com",
                 "Access-Control-Request-Method": "POST"},
        timeout=2.0,
    )
    assert r.status_code == 204
    assert r.headers["access-control-allow-origin"] == "*"
    assert "POST" in r.headers["access-control-allow-methods"]

    # GET must still pass through.
    r2 = httpx.get(f"http://127.0.0.1:{port}/api/x", timeout=2.0)
    assert r2.status_code == 200
    assert "OPTIONS" not in seen_methods
    assert "GET" in seen_methods


def test_cors_options_without_origin_passes_to_app() -> None:
    """OPTIONS WITHOUT an Origin header is a regular OPTIONS request
    (not a CORS preflight) — the intercept must not fire."""
    port = _free_port()
    seen_methods: list[str] = []

    async def tracking(scope, receive, send):
        if scope["type"] == "lifespan":
            while True:
                msg = await receive()
                if msg["type"] == "lifespan.startup":
                    await send({"type": "lifespan.startup.complete"})
                elif msg["type"] == "lifespan.shutdown":
                    await send({"type": "lifespan.shutdown.complete"})
                    return
            return
        seen_methods.append(scope["method"])
        await receive()
        await send({"type": "http.response.start", "status": 200,
                    "headers": [(b"content-type", b"text/plain")]})
        await send({"type": "http.response.body", "body": b"app", "more_body": False})

    _serve_in_background(tracking, port, cors_preflight_allow_all=True)

    httpx.options(f"http://127.0.0.1:{port}/", timeout=2.0)
    assert "OPTIONS" in seen_methods


# ---------------------------------------------------------------------------
# Rate limiter
# ---------------------------------------------------------------------------


def test_rate_limit_returns_429_after_burst() -> None:
    """rate_limit_per_sec=10, burst=3: the 4th rapid request from the
    same IP gets a 429 — the app never sees it."""
    port = _free_port()
    seen_count = [0]

    async def counting(scope, receive, send):
        if scope["type"] == "lifespan":
            while True:
                msg = await receive()
                if msg["type"] == "lifespan.startup":
                    await send({"type": "lifespan.startup.complete"})
                elif msg["type"] == "lifespan.shutdown":
                    await send({"type": "lifespan.shutdown.complete"})
                    return
            return
        seen_count[0] += 1
        await receive()
        await send({"type": "http.response.start", "status": 200,
                    "headers": [(b"content-type", b"text/plain")]})
        await send({"type": "http.response.body", "body": b"ok", "more_body": False})

    _serve_in_background(
        counting, port, rate_limit_per_sec=10, rate_limit_burst=3
    )

    statuses: list[int] = []
    with httpx.Client(timeout=2.0) as client:
        for _ in range(6):
            statuses.append(client.get(f"http://127.0.0.1:{port}/").status_code)

    assert statuses[:3] == [200, 200, 200], f"first 3 should be 200: {statuses}"
    # After 3 tokens consumed, the next one (within the same second) is
    # over the rate. With rate_limit_per_sec=10 the bucket refills 1
    # token every 100 ms, so a tight loop fires faster than refill and
    # produces at least one 429.
    assert 429 in statuses[3:], f"no 429 in {statuses}"
    # The user app must NOT have seen the 429-ed requests.
    assert seen_count[0] == sum(1 for s in statuses if s == 200)


def test_rate_limit_zero_disables() -> None:
    """rate_limit_per_sec=0 (default) is a no-op — bursts pass."""
    port = _free_port()
    _serve_in_background(_hello, port)

    with httpx.Client(timeout=2.0) as client:
        for _ in range(20):
            r = client.get(f"http://127.0.0.1:{port}/")
            assert r.status_code == 200


# ---------------------------------------------------------------------------
# tracemalloc dump
# ---------------------------------------------------------------------------


def test_tracemalloc_path_serves_dump() -> None:
    """When tracemalloc_path is set, GET to that path returns a top-N
    text dump that mentions at least one Python source location."""
    port = _free_port()
    _serve_in_background(_hello, port, tracemalloc_path="/debug/tracemalloc")

    # Drive a request first so the dispatcher has done some work.
    httpx.get(f"http://127.0.0.1:{port}/", timeout=2.0)

    r = httpx.get(f"http://127.0.0.1:{port}/debug/tracemalloc", timeout=2.0)
    assert r.status_code == 200
    body = r.text
    # Output format: '   <kib> KiB  <count> blocks  <file:line>'
    assert "blocks" in body
    assert ".py" in body  # at least one line points at a Python source.


def test_tracemalloc_path_disabled_when_unset() -> None:
    """Without tracemalloc_path the path is just a normal request route —
    handled by the user app (or 404 if the app doesn't define it)."""
    port = _free_port()
    _serve_in_background(_hello, port)

    # Hello app doesn't route /debug/tracemalloc, so it'll just return
    # the same hello body (the app accepts any path). Just verify we get
    # a real response from the app, not the tracemalloc dump.
    r = httpx.get(f"http://127.0.0.1:{port}/debug/tracemalloc", timeout=2.0)
    assert r.status_code == 200
    assert r.text == "hello\n"


# ---------------------------------------------------------------------------
# IPv6 listen
# ---------------------------------------------------------------------------


def test_ipv6_loopback_listen() -> None:
    """`host='::1'` binds an AF_INET6 socket; an HTTP request over v6
    succeeds end-to-end."""
    port = _free_port(socket.AF_INET6)
    _serve_in_background(_hello, port, host="::1")

    # httpx selects v6 automatically because of the bracket notation.
    r = httpx.get(f"http://[::1]:{port}/", timeout=2.0)
    assert r.status_code == 200
    assert r.text == "hello\n"


def test_ipv6_bracketed_host_accepted() -> None:
    """`host='[::1]'` (with brackets) is also valid — v1.3 strips
    brackets before parsing."""
    port = _free_port(socket.AF_INET6)
    _serve_in_background(_hello, port, host="[::1]")
    r = httpx.get(f"http://[::1]:{port}/", timeout=2.0)
    assert r.status_code == 200


# ---------------------------------------------------------------------------
# URL decode in Zig
# ---------------------------------------------------------------------------


def test_zig_side_url_decode_decodes_pct_escapes() -> None:
    """v1.3 moved `unquote_to_bytes` from Python to Zig. Verify the
    user app sees the decoded path even though `urllib.parse` is no
    longer imported by the dispatcher."""
    port = _free_port()
    seen_paths: list[str] = []
    seen_raw: list[bytes] = []

    async def echo(scope, receive, send):
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
        seen_raw.append(scope["raw_path"])
        await receive()
        await send({"type": "http.response.start", "status": 200,
                    "headers": [(b"content-type", b"text/plain")]})
        await send({"type": "http.response.body", "body": b"ok", "more_body": False})

    _serve_in_background(echo, port)

    # %20 is space, %2F is /. The decoded path must show the literals.
    httpx.get(f"http://127.0.0.1:{port}/users/john%20doe", timeout=2.0)
    assert seen_paths[-1] == "/users/john doe"
    # raw_path retains the original encoding (ASGI spec).
    assert seen_raw[-1] == b"/users/john%20doe"
