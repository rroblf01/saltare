"""`saltare` command-line entry point."""

from __future__ import annotations

import argparse
import importlib
import os
import sys
from typing import Any


def _is_saltare_main_entry() -> bool:
    """True iff this process was started as a saltare CLI invocation
    (either the pip-installed `saltare` console script, or `python -m
    saltare`). Importing `saltare.cli` from a third-party script must
    NOT trigger the re-exec — that would surprise everyone."""
    arg0 = sys.argv[0] if sys.argv else ""
    base = os.path.basename(arg0)
    # pip's console_scripts wrapper is named exactly "saltare" (or
    # "saltare-script.py" on Windows). Strip a trailing extension to
    # match either form.
    base_stem = base.split(".")[0] if base else ""
    if base_stem == "saltare":
        return True
    # `python -m saltare` resolves argv[0] to the saltare package's
    # __main__.py, e.g. `/.../site-packages/saltare/__main__.py`.
    if arg0.endswith("__main__.py") and "saltare" in arg0:
        return True
    return False


def _ensure_optimized() -> None:
    """If we're not running with `python -OO` (`sys.flags.optimize >= 2`),
    re-exec ourselves with that flag set. CPython strips both `assert`
    statements and docstrings under `-OO`, which trims the heap by a few
    MiB once FastAPI / Starlette / Pydantic finish importing — those
    libraries carry hundreds of multi-line docstrings each. We also set
    `MALLOC_ARENA_MAX=1` in the re-exec environment so glibc's per-
    thread arena state lands in a single arena from process start
    (calling `mallopt(M_ARENA_MAX, 1)` later in PyInit__core only
    affects future allocations, not arenas already populated by
    CPython's bootstrap).

    Skip the re-exec if the user explicitly opts out via `SALTARE_NO_OPTIMIZE=1`
    (some apps inspect `__doc__` at runtime). Also skip if we've already
    re-execed once (`SALTARE_REEXECED=1`), to avoid an infinite loop in
    bizarre environments where `-OO` doesn't lift `sys.flags.optimize`.
    Finally, skip when this module is imported by code that isn't a
    saltare CLI invocation — re-execing somebody else's script would be
    rude.
    """
    if sys.flags.optimize >= 2:
        return
    if os.environ.get("SALTARE_NO_OPTIMIZE", "").lower() in {"1", "true", "yes"}:
        return
    if os.environ.get("SALTARE_REEXECED") == "1":
        return
    if not _is_saltare_main_entry():
        return
    new_env = os.environ.copy()
    new_env["SALTARE_REEXECED"] = "1"
    new_env["PYTHONOPTIMIZE"] = "2"
    # Bound glibc's per-thread arenas before CPython runs any malloc.
    # Setting it here, before exec, beats calling mallopt() mid-process
    # because the bootstrap allocations themselves stay in one arena.
    new_env.setdefault("MALLOC_ARENA_MAX", "1")
    os.execvpe(
        sys.executable,
        [sys.executable, "-OO", "-m", "saltare"] + sys.argv[1:],
        new_env,
    )


# Re-exec runs as early as possible — before importing `saltare` (which
# pulls _core, the dispatcher, etc.) — so that those imports themselves
# happen under -OO and shed their docstrings. The `_is_saltare_main_entry`
# gate makes this safe for third-party callers who import `saltare.cli`
# without intending to run it.
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
        "--favicon-204",
        action="store_true",
        help="answer GET /favicon.ico with 204 No Content from Zig "
             "(skips Python dispatch for browser favicon hits)",
    )
    parser.add_argument(
        "--max-connections-per-ip",
        type=int,
        default=0,
        metavar="N",
        help="per-IP open-connection ceiling (0 = disabled). Over-cap "
             "peers get a TCP-level close at accept time.",
    )
    parser.add_argument(
        "--access-log-path",
        type=str,
        default=None,
        metavar="PATH",
        help="route access-log JSON lines to PATH instead of stderr",
    )
    parser.add_argument(
        "--request-id-header",
        type=str,
        default=None,
        metavar="NAME",
        help="auto-generate an 8-byte hex request ID per request and "
             "echo it as response header NAME (e.g. 'X-Request-ID'). "
             "Apps can read it via scope['x-request-id'].",
    )
    parser.add_argument(
        "--server-timing",
        action="store_true",
        help="emit `Server-Timing: total;dur=<ms>` on every response",
    )
    parser.add_argument(
        "--listen-backlog",
        type=int,
        default=256,
        metavar="N",
        help="`listen(2)` backlog (default 256). Capped by /proc/sys/net/core/somaxconn.",
    )
    parser.add_argument(
        "--tcp-keepidle", type=int, default=0, metavar="SEC",
        help="seconds idle before kernel sends first keepalive probe "
             "(0 = kernel default, usually 7200)",
    )
    parser.add_argument(
        "--tcp-keepintvl", type=int, default=0, metavar="SEC",
        help="seconds between keepalive probes (0 = kernel default, usually 75)",
    )
    parser.add_argument(
        "--tcp-keepcnt", type=int, default=0, metavar="N",
        help="unanswered probes before connection is dropped (0 = kernel default, usually 9)",
    )
    parser.add_argument(
        "--proxy-protocol",
        action="store_true",
        help="parse HAProxy PROXY-protocol v1 (text) or v2 (binary) "
             "header at every accept (required behind L4 LBs like AWS "
             "NLB/ALB, HAProxy, GCP TCP LB)",
    )
    parser.add_argument(
        "--tcp-user-timeout-ms", type=int, default=0, metavar="MS",
        help="TCP_USER_TIMEOUT in milliseconds — caps unacked write "
             "windows for sub-second failure detection (Linux only)",
    )
    parser.add_argument(
        "--auto-raise-nofile",
        action="store_true",
        help="raise the soft RLIMIT_NOFILE to the hard limit at startup",
    )
    parser.add_argument(
        "--max-connection-lifetime", type=int, default=0, metavar="SEC",
        help="hard cap on a single connection's wall-clock lifetime "
             "(seconds; 0 = disabled)",
    )
    parser.add_argument(
        "--tls-session-cache-size", type=int, default=0, metavar="N",
        help="OpenSSL session cache size (0 = disabled). "
             "~20 KiB resident per cached session at peak.",
    )
    parser.add_argument(
        "--startup-request",
        action="store_true",
        help="issue an internal GET / after lifespan startup to warm "
             "FastAPI route compilation / pydantic validators",
    )
    parser.add_argument(
        "--server-header", type=str, default=None, metavar="VALUE",
        help="override the `Server:` response header (empty string omits it entirely)",
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
        favicon_204=args.favicon_204,
        max_connections_per_ip=args.max_connections_per_ip,
        access_log_path=args.access_log_path,
        request_id_header=args.request_id_header,
        server_timing=args.server_timing,
        listen_backlog=args.listen_backlog,
        tcp_keepidle=args.tcp_keepidle,
        tcp_keepintvl=args.tcp_keepintvl,
        tcp_keepcnt=args.tcp_keepcnt,
        proxy_protocol=args.proxy_protocol,
        tcp_user_timeout_ms=args.tcp_user_timeout_ms,
        auto_raise_nofile=args.auto_raise_nofile,
        max_connection_lifetime=args.max_connection_lifetime,
        tls_session_cache_size=args.tls_session_cache_size,
        startup_request=args.startup_request,
        server_header=args.server_header,
    )
