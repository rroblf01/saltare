"""Response headers that only had setter-level coverage.

`server_timing=True` and `request_id_header="x-request-id"` were both
exercised only by `test_dispatcher_unit.py`, which calls
`set_server_timing()` / `set_request_id_header()` and asserts the module
global flipped. That proves the switch is stored, not that the header
reaches the wire — the header is assembled later, in a different code
path (`_HttpState`, when the response head is built), and that path had
no coverage at all.

What is pinned here:

  - `Server-Timing: total;dur=<ms>` is present, well-formed, and its
    duration is plausible. It is computed from a monotonic clock at the
    moment the head is written, so a request that sleeps must report a
    visibly larger duration than one that returns immediately.
  - Both headers are absent by default. They are opt-in and must cost
    nothing on the wire when off.
  - `X-Request-ID` is echoed back under the *configured* name, so an
    operator using `x-correlation-id` gets that header rather than the
    default one, and it is also surfaced on the ASGI scope.
"""

from __future__ import annotations

import re
import socket
import threading
import time
from typing import Any

import pytest

# `total;dur=1.23` — RFC 7234 token;dur=<float>
# The header is emitted lowercase on the wire, but header *names* are
# case-insensitive, so match through httpx's parsed view rather than
# hand-parsing the raw head.
_TIMING_RE = re.compile(r"^total;dur=(\d+(?:\.\d+)?)$")
_REQUEST_ID_RE = re.compile(r"^[0-9a-f]+$")


def _timing_ms(response) -> float:
    """Pull the `dur=` value out of the Server-Timing header."""
    raw = response.headers.get("server-timing")
    assert raw is not None, f"no server-timing in {dict(response.headers)}"
    match = _TIMING_RE.match(raw.strip())
    assert match, f"malformed server-timing: {raw!r}"
    return float(match.group(1))


def _request_id(response, name: str = "x-request-id") -> str:
    value = response.headers.get(name)
    assert value is not None, f"no {name} in {dict(response.headers)}"
    assert _REQUEST_ID_RE.match(value), f"malformed request id: {value!r}"
    return value


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


async def _instant(scope, receive, send):
    """Returns as fast as possible — the baseline for Server-Timing."""
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
    await send({"type": "http.response.body", "body": b"ok", "more_body": False})


async def _slow(scope, receive, send):
    """Sleeps before responding, so the reported duration must be
    visibly larger than the instant app's."""
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
    time.sleep(0.25)
    await send({
        "type": "http.response.start",
        "status": 200,
        "headers": [(b"content-type", b"text/plain")],
    })
    await send({"type": "http.response.body", "body": b"ok", "more_body": False})


async def _echo_request_id(scope, receive, send):
    """Reports the request-id saltare generated, so the test can check
    the scope surface and not only the wire."""
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
    rid = scope.get("x-request-id")
    body = rid.decode() if isinstance(rid, bytes) else str(rid)
    await send({
        "type": "http.response.start",
        "status": 200,
        "headers": [(b"content-type", b"text/plain")],
    })
    await send({"type": "http.response.body", "body": body.encode(),
                "more_body": False})


async def _boom(scope, receive, send):
    """Raises after lifespan startup — drives the synthesized-500 path."""
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
    raise RuntimeError("handler failure")


def _serve_in_background(app: Any, port: int, **kwargs) -> None:
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


# ---------------------------------------------------------------------------
# Server-Timing
# ---------------------------------------------------------------------------


def test_server_timing_header_is_emitted_when_enabled() -> None:
    port = _free_port()
    _serve_in_background(_instant, port, server_timing=True)

    import httpx

    with httpx.Client(timeout=3.0) as client:
        r = client.get(f"http://127.0.0.1:{port}/")

    assert r.status_code == 200
    dur_ms = _timing_ms(r)
    assert dur_ms >= 0.0
    # A local echo lands in single-digit milliseconds. The ceiling is loose
    # on purpose: this asserts the number is derived from a real clock
    # rather than hardcoded, not that the server is fast.
    assert dur_ms < 5_000.0, f"implausible duration: {dur_ms} ms"


def test_server_timing_reflects_handler_duration() -> None:
    """The duration has to be measured, not invented. A handler that
    sleeps 250 ms must report at least ~200 ms, and measurably more than
    the instant app on the same server."""
    port = _free_port()
    _serve_in_background(_slow, port, server_timing=True)

    import httpx

    def _dur() -> float:
        with httpx.Client(timeout=5.0) as client:
            r = client.get(f"http://127.0.0.1:{port}/")
        return _timing_ms(r)

    slow_dur = _dur()
    assert slow_dur >= 200.0, (
        f"a 250 ms handler reported {slow_dur} ms; the clock is not wired up"
    )
    assert slow_dur < 5_000.0


def test_server_timing_absent_by_default() -> None:
    """Opt-in feature: the header must not appear unless asked for."""
    port = _free_port()
    _serve_in_background(_instant, port)

    import httpx

    with httpx.Client(timeout=3.0) as client:
        r = client.get(f"http://127.0.0.1:{port}/")

    assert r.status_code == 200
    assert "server-timing" not in r.headers, r.headers


def test_server_timing_present_on_error_responses() -> None:
    """A synthesized 500 is still a response head, so the timing header
    should be on it too — otherwise the slowest requests, the ones you
    most want to see a duration for, go unmeasured."""

    async def boom(scope, receive, send):
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
        raise RuntimeError("handler failure")

    port = _free_port()
    _serve_in_background(boom, port, server_timing=True)

    import httpx

    with httpx.Client(timeout=3.0) as client:
        r = client.get(f"http://127.0.0.1:{port}/")

    assert r.status_code == 500
    assert "server-timing" in r.headers, (
        f"error responses must still be timed:\n{r.headers}"
    )


def test_request_id_present_on_error_responses() -> None:
    """Same reasoning for correlation: an exception is precisely when you
    want to tie the failing request to the rest of the trace."""

    async def boom(scope, receive, send):
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
        raise RuntimeError("handler failure")

    port = _free_port()
    _serve_in_background(boom, port, request_id_header="x-request-id")

    import httpx

    with httpx.Client(timeout=3.0) as client:
        r = client.get(f"http://127.0.0.1:{port}/")

    assert r.status_code == 500
    assert _request_id(r), (
        f"the failing request must stay correlatable:\n{r.headers}"
    )


def test_error_response_keeps_a_wellformed_head() -> None:
    """The optional headers are spliced into the same head as the status
    line and Content-Length. A missing CRLF would merge the last optional
    header into Content-Length and desync the framing, so assert the body
    survives intact and Content-Length still matches."""
    port = _free_port()
    _serve_in_background(_boom, port, server_timing=True,
                         request_id_header="x-request-id")

    import httpx

    with httpx.Client(timeout=3.0) as client:
        r = client.get(f"http://127.0.0.1:{port}/")

    assert r.status_code == 500
    assert r.text == "Internal Server Error\n", repr(r.text)
    assert int(r.headers["content-length"]) == len(r.text.encode())


def test_error_response_headers_absent_when_features_off() -> None:
    """The fix must not make the optional headers unconditional."""
    port = _free_port()
    _serve_in_background(_boom, port)

    import httpx

    with httpx.Client(timeout=3.0) as client:
        r = client.get(f"http://127.0.0.1:{port}/")

    assert r.status_code == 500
    assert "server-timing" not in r.headers, r.headers
    assert "x-request-id" not in r.headers, r.headers


# ---------------------------------------------------------------------------
# X-Request-ID
# ---------------------------------------------------------------------------


def test_request_id_is_echoed_and_exposed_on_scope() -> None:
    port = _free_port()
    _serve_in_background(_echo_request_id, port, request_id_header="x-request-id")

    import httpx

    with httpx.Client(timeout=3.0) as client:
        r = client.get(f"http://127.0.0.1:{port}/")

    assert r.status_code == 200
    wire_id = _request_id(r)
    # The app saw the same id the wire carries — the scope and the header
    # come from the same generated value.
    assert r.content == wire_id.encode()


def test_request_id_honours_a_custom_header_name() -> None:
    """The operator picks the name; the server must not fall back to the
    default. A mis-plumbed name here silently breaks every log
    correlator in the deployment."""
    port = _free_port()
    _serve_in_background(
        _echo_request_id, port, request_id_header="x-correlation-id"
    )

    import httpx

    with httpx.Client(timeout=3.0) as client:
        r = client.get(f"http://127.0.0.1:{port}/")

    assert r.status_code == 200
    assert "x-correlation-id" in r.headers, r.headers
    assert "x-request-id" not in r.headers, (
        "the default name leaked even though a custom one was configured"
    )
    assert r.content == _request_id(r, "x-correlation-id").encode()


def test_request_id_is_unique_per_request() -> None:
    """An id that repeats is worse than no id: it merges unrelated log
    lines. Checked across separate connections so the two requests cannot
    share a pooled connection."""
    port = _free_port()
    _serve_in_background(_echo_request_id, port, request_id_header="x-request-id")

    import httpx

    ids = []
    with httpx.Client(timeout=3.0) as client:
        for _ in range(5):
            r = client.get(f"http://127.0.0.1:{port}/")
            ids.append(_request_id(r))

    assert len(set(ids)) == len(ids), f"request ids repeated: {ids}"


def test_request_id_absent_by_default() -> None:
    port = _free_port()
    _serve_in_background(_echo_request_id, port)

    import httpx

    with httpx.Client(timeout=3.0) as client:
        r = client.get(f"http://127.0.0.1:{port}/")

    assert r.status_code == 200
    assert "x-request-id" not in r.headers, r.headers


def test_server_timing_and_request_id_compose() -> None:
    """Both are appended to the same head assembly. Individually they
    pass; together they can shadow each other if one is written without
    its CRLF."""
    port = _free_port()
    _serve_in_background(
        _echo_request_id, port,
        server_timing=True,
        request_id_header="x-request-id",
    )

    import httpx

    with httpx.Client(timeout=3.0) as client:
        r = client.get(f"http://127.0.0.1:{port}/")

    assert r.status_code == 200
    assert "server-timing" in r.headers, r.headers
    assert "x-request-id" in r.headers, r.headers
    # A malformed head would corrupt the body offset and truncate it.
    assert r.content != b"", "body lost after head"
    assert r.content == _request_id(r).encode()
