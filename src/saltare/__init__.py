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

    NOTE (v0.1.0): the listening socket and accept loop are in Zig, but the
    `app` callable is not yet routed through the ASGI bridge. Every request
    receives a fixed stub response. The next milestone wires the HTTP/1.1
    parser and ASGI dispatcher so FastAPI apps can run end-to-end.
    """
    _ = app  # ASGI dispatcher is not implemented yet
    _core.serve(host, int(port))
