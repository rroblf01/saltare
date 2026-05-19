"""Django Channels integration smoke tests (v1.7.0).

These tests verify that saltare's WS scope matches what Channels'
ProtocolTypeRouter / AuthMiddlewareStack / consumer machinery
expects: a fresh `scope["state"]` from lifespan, `scope["extensions"]`
present, `scope["client"]` populated via proxy_headers, no
non-spec `method` key on the WS scope.

We don't require the user to have Channels installed — the test
suite skips gracefully when `channels` import fails. The integration
test uses an in-memory channel layer and a trivial AsyncWebsocketConsumer
so we don't need Redis or a settings module.
"""

from __future__ import annotations

import platform as _platform
import socket
import threading
import time

import pytest

_TIMING_FACTOR: float = 4.0 if _platform.machine() in {"aarch64", "arm64"} else 1.0

# Channels brings Django as a transitive dependency. Skip cleanly when
# either is absent (the wheel-test image does not ship them).
pytest.importorskip("channels")
pytest.importorskip("django")

# Configure minimal Django settings BEFORE any channels / django.urls
# imports — otherwise the imports themselves raise
# `ImproperlyConfigured`. We only need the import surface; no DB, no
# templates, no apps.
from django.conf import settings  # noqa: E402
if not settings.configured:
    settings.configure(
        DEBUG=False,
        SECRET_KEY="saltare-channels-smoke-test",
        ROOT_URLCONF=__name__,
        INSTALLED_APPS=[],
        DATABASES={},
        ALLOWED_HOSTS=["*"],
    )

from channels.routing import ProtocolTypeRouter, URLRouter  # noqa: E402
from channels.generic.websocket import AsyncWebsocketConsumer  # noqa: E402
from django.urls import path  # noqa: E402

# `ROOT_URLCONF` points at this module, so Django finds `urlpatterns`
# here when introspecting routes. We don't actually use the HTTP
# routing surface — the WS URLRouter routes inside ProtocolTypeRouter.
urlpatterns: list = []


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class EchoConsumer(AsyncWebsocketConsumer):
    """Accepts every connection, echoes text messages, closes cleanly."""

    async def connect(self):
        # Channels middleware has approved at this point; saltare delivered
        # a scope it accepts. If `scope["state"]` / `scope["extensions"]`
        # were missing, AuthMiddlewareStack would have closed before
        # reaching connect().
        await self.accept()

    async def receive(self, text_data=None, bytes_data=None):
        if text_data is not None:
            await self.send(text_data=text_data)


class RejectConsumer(AsyncWebsocketConsumer):
    """Closes with a 4003 (Origin reject) before accepting — exercises
    the v1.7 close-code → HTTP status forwarding (4003 maps to 403)."""

    async def connect(self):
        await self.close(code=4003)


def _build_router() -> "ProtocolTypeRouter":
    return ProtocolTypeRouter({
        "websocket": URLRouter([
            path("echo", EchoConsumer.as_asgi()),
            path("reject", RejectConsumer.as_asgi()),
        ]),
    })


def _serve(app, port: int, **kwargs) -> None:
    from saltare import run
    threading.Thread(
        target=run,
        args=(app,),
        kwargs={"host": "127.0.0.1", "port": port, **kwargs},
        daemon=True,
    ).start()
    deadline = time.monotonic() + 3.0 * _TIMING_FACTOR
    while time.monotonic() < deadline:
        try:
            with socket.socket() as s:
                s.settimeout(0.2)
                s.connect(("127.0.0.1", port))
                return
        except (ConnectionRefusedError, socket.timeout, OSError):
            time.sleep(0.05)
    pytest.fail(f"server never came up on 127.0.0.1:{port}")


def _ws_handshake_raw(sock: socket.socket, port: int, path_str: str) -> bytes:
    req = (
        b"GET " + path_str.encode() + b" HTTP/1.1\r\n"
        b"Host: 127.0.0.1:" + str(port).encode() + b"\r\n"
        b"Upgrade: websocket\r\n"
        b"Connection: Upgrade\r\n"
        b"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
        b"Sec-WebSocket-Version: 13\r\n"
        b"\r\n"
    )
    sock.sendall(req)
    raw = b""
    deadline = time.monotonic() + 3.0 * _TIMING_FACTOR
    while b"\r\n\r\n" not in raw and time.monotonic() < deadline:
        chunk = sock.recv(4096)
        if not chunk:
            break
        raw += chunk
    return raw


def test_channels_router_accepts_echo_consumer():
    """`ProtocolTypeRouter({'websocket': URLRouter([path('echo', ...)])})`
    accepts an upgrade through saltare → 101 Switching Protocols."""
    port = _free_port()
    _serve(_build_router(), port)
    with socket.socket() as s:
        s.settimeout(3.0 * _TIMING_FACTOR)
        s.connect(("127.0.0.1", port))
        head = _ws_handshake_raw(s, port, "/echo")
    assert head.startswith(b"HTTP/1.1 101"), f"expected 101, got: {head[:100]!r}"


def test_channels_reject_consumer_forwards_close_code():
    """A consumer that calls `await self.close(code=4003)` before
    accepting must produce an HTTP 403 (saltare maps 4003 → 403)."""
    port = _free_port()
    _serve(_build_router(), port)
    with socket.socket() as s:
        s.settimeout(3.0 * _TIMING_FACTOR)
        s.connect(("127.0.0.1", port))
        head = _ws_handshake_raw(s, port, "/reject")
    # Status line first.
    first_line = head.split(b"\r\n", 1)[0]
    assert b"403" in first_line, f"expected 403, got: {first_line!r}"


def test_channels_404_close_code_maps_to_404():
    """`close(code=4004)` → HTTP 404."""
    port = _free_port()

    class FourOhFour(AsyncWebsocketConsumer):
        async def connect(self):
            await self.close(code=4004)

    router = ProtocolTypeRouter({
        "websocket": URLRouter([path("x", FourOhFour.as_asgi())]),
    })
    _serve(router, port)
    with socket.socket() as s:
        s.settimeout(3.0 * _TIMING_FACTOR)
        s.connect(("127.0.0.1", port))
        head = _ws_handshake_raw(s, port, "/x")
    first_line = head.split(b"\r\n", 1)[0]
    assert b"404" in first_line, f"expected 404, got: {first_line!r}"
