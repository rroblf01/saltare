"""`saltare` command-line entry point."""

from __future__ import annotations

import argparse
import importlib
import sys
from typing import Any

from saltare import __version__, run


def _load_app(target: str) -> Any:
    module_name, sep, attr = target.partition(":")
    if not sep or not module_name or not attr:
        raise SystemExit(
            f"invalid app target: {target!r} (expected 'module:attribute')"
        )
    sys.path.insert(0, "")
    module = importlib.import_module(module_name)
    try:
        return getattr(module, attr)
    except AttributeError as exc:
        raise SystemExit(
            f"module {module_name!r} has no attribute {attr!r}"
        ) from exc


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(
        prog="saltare",
        description="Low-RAM ASGI HTTP server with a Zig backbone.",
    )
    parser.add_argument(
        "app",
        nargs="?",
        help="ASGI app target as 'module:attr' (e.g. 'main:app').",
    )
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8000)
    parser.add_argument(
        "--header-timeout",
        type=int,
        default=5,
        help="seconds from accept to parsed headers (slowloris guard)",
    )
    parser.add_argument(
        "--keep-alive-timeout",
        type=int,
        default=5,
        help="seconds between requests on a kept-alive connection",
    )
    parser.add_argument(
        "--body-timeout",
        type=int,
        default=30,
        help="seconds from parsed headers to fully received body",
    )
    parser.add_argument(
        "--write-timeout",
        type=int,
        default=30,
        help="maximum seconds in the writing state",
    )
    parser.add_argument(
        "--max-concurrent-connections",
        type=int,
        default=1024,
        help="accepted connections held open at once (overflow is dropped)",
    )
    parser.add_argument(
        "--max-keepalive-requests",
        type=int,
        default=1000,
        help="requests per keep-alive connection before forcing close",
    )
    parser.add_argument(
        "--max-request-body",
        type=int,
        default=1024 * 1024,
        help="largest request body (in bytes) the server will accept",
    )
    parser.add_argument(
        "--shutdown-timeout",
        type=int,
        default=30,
        help="seconds to wait for in-flight requests after SIGTERM/SIGINT",
    )
    parser.add_argument(
        "--version",
        action="version",
        version=f"saltare {__version__}",
    )
    args = parser.parse_args(argv)

    if not args.app:
        parser.error("missing app target (e.g. 'main:app')")

    app = _load_app(args.app)
    run(
        app,
        host=args.host,
        port=args.port,
        header_timeout=args.header_timeout,
        keep_alive_timeout=args.keep_alive_timeout,
        body_timeout=args.body_timeout,
        write_timeout=args.write_timeout,
        max_concurrent_connections=args.max_concurrent_connections,
        max_keepalive_requests=args.max_keepalive_requests,
        max_request_body=args.max_request_body,
        shutdown_timeout=args.shutdown_timeout,
    )
