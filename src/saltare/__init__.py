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
) -> None:
    """Run an ASGI application under saltare.

    Blocks until SIGINT or SIGTERM. Pass `ssl_certfile` and `ssl_keyfile`
    (both PEM) to serve HTTPS instead of plain HTTP. Lifespan startup runs
    before the I/O loop accepts connections.
    """
    _core.serve(app, host, int(port), ssl_certfile, ssl_keyfile)
