"""`saltare` command-line entry point."""

from __future__ import annotations

import argparse
import importlib
import os
import sys
from typing import Any


def _ensure_optimized() -> None:
    """If we're not running with `python -OO` (`sys.flags.optimize >= 2`),
    re-exec ourselves with that flag set. CPython strips both `assert`
    statements and docstrings under `-OO`, which trims the heap by a few
    MiB once FastAPI / Starlette / Pydantic finish importing — those
    libraries carry hundreds of multi-line docstrings each.

    Skip the re-exec if the user explicitly opts out via `SALTARE_NO_OPTIMIZE=1`
    (some apps inspect `__doc__` at runtime). Also skip if we've already
    re-execed once (`SALTARE_REEXECED=1`), to avoid an infinite loop in
    bizarre environments where `-OO` doesn't lift `sys.flags.optimize`.
    """
    if sys.flags.optimize >= 2:
        return
    if os.environ.get("SALTARE_NO_OPTIMIZE", "").lower() in {"1", "true", "yes"}:
        return
    if os.environ.get("SALTARE_REEXECED") == "1":
        return
    new_env = os.environ.copy()
    new_env["SALTARE_REEXECED"] = "1"
    new_env["PYTHONOPTIMIZE"] = "2"
    os.execvpe(
        sys.executable,
        [sys.executable, "-OO", "-m", "saltare"] + sys.argv[1:],
        new_env,
    )


# Re-exec runs as early as possible — before importing `saltare` (which
# pulls _core, the dispatcher, etc.) — so that those imports themselves
# happen under -OO and shed their docstrings.
_ensure_optimized()


from saltare import __version__, run  # noqa: E402


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
        "--uds",
        type=str,
        default=None,
        metavar="PATH",
        help="bind a Unix domain socket at PATH instead of host:port",
    )
    parser.add_argument(
        "--metrics-path",
        type=str,
        default=None,
        metavar="PATH",
        help="serve Prometheus-format metrics at PATH (e.g. '/metrics')",
    )
    parser.add_argument(
        "--access-log",
        action="store_true",
        help="emit one JSON line per completed request to stderr",
    )
    parser.add_argument(
        "--proxy-headers",
        action="store_true",
        help="trust X-Forwarded-For/Proto from upstream proxies",
    )
    parser.add_argument(
        "--ws-keepalive-timeout",
        type=int,
        default=20,
        help="seconds between server-side WebSocket pings (close at 2× this)",
    )
    parser.add_argument(
        "--workers",
        type=int,
        default=1,
        help="number of pre-fork worker processes (1 = single process)",
    )
    parser.add_argument(
        "--health-path",
        type=str,
        default=None,
        metavar="PATH",
        help="answer GETs at PATH (e.g. '/healthz') with 200 'ok' from "
             "Zig — no Python dispatch (k8s probe-friendly)",
    )
    parser.add_argument(
        "--cors-preflight-allow-all",
        action="store_true",
        help="answer OPTIONS-with-Origin from Zig with permissive CORS "
             "headers — skips Python for browser preflight",
    )
    parser.add_argument(
        "--rate-limit-per-sec",
        type=int,
        default=0,
        metavar="N",
        help="per-IP request rate ceiling (0 = disabled). Token bucket "
             "implemented in Zig; over-rate IPs get 429 before Python.",
    )
    parser.add_argument(
        "--rate-limit-burst",
        type=int,
        default=100,
        metavar="N",
        help="burst ceiling for the per-IP rate limiter (default 100)",
    )
    parser.add_argument(
        "--tracemalloc-path",
        type=str,
        default=None,
        metavar="PATH",
        help="enable tracemalloc tracking and serve a top-30 Python "
             "allocation dump at PATH (e.g. '/debug/tracemalloc'). "
             "Diagnostic only — has CPU + RAM cost.",
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
        uds_path=args.uds,
        metrics_path=args.metrics_path,
        access_log=args.access_log,
        proxy_headers=args.proxy_headers,
        ws_keepalive_timeout=args.ws_keepalive_timeout,
        workers=args.workers,
        health_path=args.health_path,
        cors_preflight_allow_all=args.cors_preflight_allow_all,
        rate_limit_per_sec=args.rate_limit_per_sec,
        rate_limit_burst=args.rate_limit_burst,
        tracemalloc_path=args.tracemalloc_path,
    )
