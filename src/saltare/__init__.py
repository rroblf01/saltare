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
    max_concurrent_connections: int = 1024,
    max_keepalive_requests: int = 1000,
    max_request_body: int = 1024 * 1024,
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

    Resource caps (turn the architectural RAM win into a hard guarantee):
        max_concurrent_connections
                             — accepted connections held open at once.
                               Past this, new connections are accepted to
                               drain the listen backlog and immediately
                               closed.
        max_keepalive_requests
                             — requests served on a single keep-alive
                               connection before forcing `Connection: close`.
                               Recycles CPython arena memory on long-lived
                               connections.
        max_request_body     — declared body size (Content-Length, or the
                               final decoded length for chunked) that the
                               server will accept; oversize requests get
                               a 413. Bounded by the read-buffer size in
                               v0.13 (request-body streaming lifts that
                               in a later milestone).

    Apps using the `Expect: 100-continue` request header are honoured
    automatically: the interim response is written as soon as headers
    parse and the body-size cap check passes.
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
        int(max_concurrent_connections),
        int(max_keepalive_requests),
        int(max_request_body),
    )
