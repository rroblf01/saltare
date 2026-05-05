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
) -> None:
    """Run an ASGI application under saltare.

    Blocks until SIGINT or SIGTERM. The accept loop and HTTP/1.1 parsing
    run in Zig with the GIL released; the GIL is re-acquired only for the
    per-request ASGI dispatch into Python.
    """
    _core.serve(app, host, int(port))
