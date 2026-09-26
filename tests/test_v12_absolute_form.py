"""RFC 7230 §5.3.2 absolute-form request-target coverage (v1.12).

Targets the request-target forms an *origin* server must tolerate:

  - ``GET http://host/path`` — absolute-form. RFC 7230 §5.3.2 says an
    origin server "MUST ignore the scheme and authority" and route on
    what remains. Before v1.12 the target was handed to the router
    verbatim, so every absolute-form request 404'd. Browsers never send
    it, but forward proxies address the next hop this way and some
    health checkers and load balancers do too.
  - The empty-path variants ``http://host`` and ``http://host?a=1``.
    RFC 3986 §6.2.3 defines an empty path as ``/``; the parser addresses
    its slices by offset+len into the read buffer and there is no ``/``
    to point at, so the substitution is recorded in a flag and the
    query string is recovered from the pre-substitution remainder.
  - The authority must be dropped, *not* used to route: an absolute-form
    target naming a different host than ``Host:`` still routes on the
    path, because the origin server has no opinion about the authority
    a proxy put there.
  - Negative cases: a path segment is allowed to contain ``:`` and ``/``,
    so ``/redirect/http://example.com`` must survive intact, and a bare
    ``://`` with an empty scheme is not absolute-form.

Uses raw sockets throughout: a client library normalises the target into
origin-form before it hits the socket, which is exactly the code path
under test.
"""

from __future__ import annotations

import platform as _platform
import socket
import threading
import time

import pytest

_TIMING_FACTOR: float = 4.0 if _platform.machine() in {"aarch64", "arm64"} else 2.0


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


async def _lifespan(receive, send) -> None:
    while True:
        msg = await receive()
        if msg["type"] == "lifespan.startup":
            await send({"type": "lifespan.startup.complete"})
        elif msg["type"] == "lifespan.shutdown":
            await send({"type": "lifespan.shutdown.complete"})
            return


async def _echo_target_app(scope, receive, send):
    """Echoes back the method, path and query string the ASGI scope
    received, so a test can assert on the routing decision rather than
    on a route table."""
    if scope["type"] == "lifespan":
        await _lifespan(receive, send)
        return
    body = "{} {} {}".format(
        scope["method"], scope["path"], scope["query_string"].decode()
    ).encode()
    await send(
        {
            "type": "http.response.start",
            "status": 200,
            "headers": [
                (b"content-type", b"text/plain"),
                (b"content-length", str(len(body)).encode()),
            ],
        }
    )
    await send({"type": "http.response.body", "body": body})


def _serve() -> int:
    """Spawns a server and returns its port.

    Per-test rather than module-scoped: the autouse fixture in
    ``conftest.py`` calls ``request_shutdown()`` after every test, so a
    shared server would already be drained by the second test. This is
    also what keeps only one server thread alive at a time, which is
    what stops the cross-thread races in ``server.zig``.
    """
    from saltare import run

    port = _free_port()
    threading.Thread(
        target=run,
        args=(_echo_target_app,),
        kwargs={"host": "127.0.0.1", "port": port},
        daemon=True,
    ).start()
    deadline = time.monotonic() + 3.0 * _TIMING_FACTOR
    while time.monotonic() < deadline:
        try:
            with socket.socket() as s:
                s.settimeout(0.2)
                s.connect(("127.0.0.1", port))
                return port
        except (ConnectionRefusedError, socket.timeout, OSError):
            time.sleep(0.05)
    pytest.fail(f"server never came up on 127.0.0.1:{port}")


def _raw(port: int, target: str, method: str = "GET", extra: str = "") -> tuple[int, str]:
    """Sends a hand-built request line and returns (status, body)."""
    with socket.create_connection(("127.0.0.1", port), 3.0 * _TIMING_FACTOR) as s:
        s.settimeout(3.0 * _TIMING_FACTOR)
        s.sendall(
            f"{method} {target} HTTP/1.1\r\n"
            f"Host: 127.0.0.1:{port}\r\n"
            f"{extra}"
            "Connection: close\r\n\r\n".encode()
        )
        buf = b""
        while True:
            try:
                chunk = s.recv(65536)
            except socket.timeout:
                break
            if not chunk:
                break
            buf += chunk
    head, _, body = buf.partition(b"\r\n\r\n")
    status = int(head.split(b"\r\n", 1)[0].split(b" ")[1])
    return status, body.decode(errors="replace")


@pytest.mark.parametrize(
    "target,method,expected",
    [
        # The regression this module exists for.
        ("http://127.0.0.1:{p}/path", "GET", "GET /path "),
        # The authority is ignored for routing, whatever it names.
        ("http://elsewhere.invalid/path", "GET", "GET /path "),
        # A port in the authority must not leak into the path.
        ("http://127.0.0.1:1/path", "GET", "GET /path "),
        # Query survives the strip.
        ("http://127.0.0.1:{p}/q?a=1&b=2", "GET", "GET /q a=1&b=2"),
        # https scheme is stripped just like http.
        ("https://127.0.0.1:{p}/secure", "GET", "GET /secure "),
        # Non-GET methods route the same way.
        ("http://127.0.0.1:{p}/path", "POST", "POST /path "),
        # Empty path is "/" (RFC 3986 §6.2.3).
        ("http://127.0.0.1:{p}", "GET", "GET / "),
        # Empty path *with* a query: the query must not be swallowed.
        ("http://127.0.0.1:{p}?a=1", "GET", "GET / a=1"),
        # Trailing slash is a real, distinct path.
        ("http://127.0.0.1:{p}/", "GET", "GET / "),
    ],
)
def test_absolute_form_routes_on_path(target: str, method: str, expected: str):
    server = _serve()
    status, body = _raw(server, target.format(p=server), method=method)
    assert status == 200, f"{target} -> {status}"
    assert body == expected


def test_absolute_form_does_not_mangle_a_path_containing_scheme():
    server = _serve()
    """A colon and slash are legal in a path segment, so a target that
    *contains* "://" is origin-form and must be routed verbatim."""
    target = "/redirect/http://example.com"
    status, body = _raw(server, target)
    assert status == 200
    assert body == f"GET {target} "


def test_bare_scheme_separator_is_not_absolute_form():
    server = _serve()
    """An empty scheme is not a scheme, so this is not absolute-form."""
    status, body = _raw(server, "://example.com/x")
    assert status == 200
    assert body == "GET ://example.com/x "


def test_asterisk_form_is_passed_through_unchanged():
    server = _serve()
    """``OPTIONS *`` is its own form (RFC 7230 §5.3.4), not
    absolute-form. saltare hands ``*`` to the app verbatim; whether that
    404s is the application's routing decision, not the parser's."""
    status, body = _raw(server, "*", method="OPTIONS")
    assert status == 200
    assert body == "OPTIONS * "


def test_origin_form_still_works():
    server = _serve()
    """Control: the common case must be untouched by the fix."""
    status, body = _raw(server, "/path?x=1")
    assert status == 200
    assert body == "GET /path x=1"


def test_absolute_form_with_a_body():
    server = _serve()
    """Content-Length and the body offset are independent of the target
    form, so a POST body must still arrive whole."""
    with socket.create_connection(("127.0.0.1", server), 3.0 * _TIMING_FACTOR) as s:
        s.settimeout(3.0 * _TIMING_FACTOR)
        s.sendall(
            f"POST http://127.0.0.1:{server}/submit HTTP/1.1\r\n"
            f"Host: 127.0.0.1:{server}\r\n"
            "Content-Length: 5\r\n"
            "Connection: close\r\n\r\nhello".encode()
        )
        buf = b""
        while True:
            try:
                chunk = s.recv(65536)
            except socket.timeout:
                break
            if not chunk:
                break
            buf += chunk
    head, _, body = buf.partition(b"\r\n\r\n")
    assert int(head.split(b"\r\n", 1)[0].split(b" ")[1]) == 200
    assert body == b"POST /submit "
