"""Saltare — low-RAM ASGI HTTP server with a Zig backbone."""

from __future__ import annotations

from typing import Any

from saltare import _core

__all__ = ["__version__", "run"]

__version__: str = _core.version()


def run(
    app: Any,
    host: str = "127.0.0.1",
    port: int = 8000,
    ssl_certfile: str | None = None,
    ssl_keyfile: str | None = None,
    header_timeout: int = 5,
    keep_alive_timeout: int = 5,
    body_timeout: int = 30,
    write_timeout: int = 30,
) -> None:
    """Run an ASGI application under saltare.

    Blocks until SIGINT or SIGTERM. Pass `ssl_certfile` and `ssl_keyfile`
    (both PEM) to serve HTTPS instead of plain HTTP. Lifespan startup runs
    before the I/O loop accepts connections.

    Timeouts (seconds, all configurable):
        header_timeout       — accept (or TLS handshake start) → headers
                               fully parsed. Bounds slowloris.
        keep_alive_timeout   — between requests on a kept-alive connection.
        body_timeout         — headers parsed → body fully received.
        write_timeout        — maximum time held in the writing state
                               (slow / non-draining client).
    """
    _core.serve(
        app,
        host,
        int(port),
        ssl_certfile,
        ssl_keyfile,
        int(header_timeout),
        int(keep_alive_timeout),
        int(body_timeout),
        int(write_timeout),
    )
