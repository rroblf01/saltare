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
    shutdown_timeout: int = 30,
    uds_path: str | None = None,
    metrics_path: str | None = None,
    access_log: bool = False,
    proxy_headers: bool = False,
    ws_keepalive_timeout: int = 20,
    workers: int = 1,
    health_path: str | None = None,
    cors_preflight_allow_all: bool = False,
    rate_limit_per_sec: int = 0,
    rate_limit_burst: int = 100,
    tracemalloc_path: str | None = None,
    favicon_204: bool = False,
    max_connections_per_ip: int = 0,
    access_log_path: str | None = None,
    request_id_header: str | None = None,
    server_timing: bool = False,
    listen_backlog: int = 256,
    tcp_keepidle: int = 0,
    tcp_keepintvl: int = 0,
    tcp_keepcnt: int = 0,
    proxy_protocol: bool = False,
    tcp_user_timeout_ms: int = 0,
    auto_raise_nofile: bool = False,
    max_connection_lifetime: int = 0,
    tls_session_cache_size: int = 0,
    startup_request: bool = False,
    server_header: str | None = None,
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

    On `SIGTERM` / `SIGINT`, saltare enters a graceful drain: it stops
    accepting new connections, lets in-flight requests finish, and only
    then runs `lifespan.shutdown` and exits. `shutdown_timeout` (seconds)
    bounds how long to wait — past that, surviving connections are cut
    and the process exits regardless. A second signal during drain
    promotes to immediate force-exit.

    Multi-worker (`workers > 1`): saltare forks N pre-fork workers that
    each run lifespan + accept loop on a shared listen socket. The master
    supervises and propagates SIGTERM. A worker exiting unexpectedly
    propagates shutdown to the rest (v1.0 policy: if a worker dies, the
    pod dies — let your supervisor restart). Each worker reports its
    own counters at `metrics_path`; aggregation across workers is left
    to the scraper. `workers=1` (the default) keeps the legacy single-
    process flow unchanged.

    Observability + deployment knobs (all opt-in, off by default):
        uds_path             — bind a Unix domain socket at this path
                               instead of host:port. Saves the localhost
                               TCP stack when behind nginx on the same box.
        metrics_path         — if set (e.g. "/metrics"), saltare answers
                               that path internally with Prometheus-format
                               counters. The user app never sees the
                               request; no Python overhead per scrape.
        access_log           — emit one JSON line per completed request
                               to stderr (method, path, status, bytes,
                               latency_us, user_agent). Off-path is
                               zero-allocation.
        proxy_headers        — parse `X-Forwarded-For` and
                               `X-Forwarded-Proto` from incoming requests
                               into `scope["client"]` and `scope["scheme"]`.
                               Only enable behind a trusted reverse proxy
                               that strips client-supplied X-Forwarded-*
                               headers; otherwise clients can spoof.
        health_path          — if set (e.g. "/healthz"), saltare answers
                               that path with `200 OK\\nok\\n` directly
                               from Zig — no Python dispatch. Useful for
                               k8s liveness/readiness probes that fire
                               often and don't need the full ASGI stack.
        cors_preflight_allow_all
                             — if True, OPTIONS requests bearing an
                               `Origin` header are answered from Zig with
                               permissive CORS headers (`*` origin,
                               common methods + headers, 24 h cache).
                               The user app never sees preflight requests.
                               Only enable if your app's CORS policy is
                               actually permissive — Zig doesn't read
                               your allow-list.
        rate_limit_per_sec   — per-IP request rate ceiling. 0 disables.
                               When set, peer IPs that exceed the rate get
                               a 429 from Zig before the app sees them.
                               Token bucket: refilled at this rate up to
                               `rate_limit_burst`. Tracks up to 4096 IPs;
                               beyond that, oldest entries evict.
        rate_limit_burst     — burst ceiling for the rate limiter. Default
                               100. Applied per IP.
        tracemalloc_path     — if set (e.g. "/debug/tracemalloc"), saltare
                               starts `tracemalloc.start(25)` at server
                               init and answers that path with the top-30
                               Python allocations. Diagnostic only;
                               tracking has CPU + RAM cost (~5-10% RSS).
                               The user app never sees the request.

    Listening on IPv6: pass an IPv6 address (with or without brackets)
    in `host`, e.g. `host="::"` to listen on all v6 interfaces or
    `host="[::1]"` for v6 loopback. saltare auto-detects v6 by the
    presence of a colon and creates an `AF_INET6` socket with
    `IPV6_V6ONLY=1` set. Run a second saltare process for v4 if you
    need both families.
    """
    # Wire Python-side proxy-headers handling. Done before _core.serve
    # because the dispatcher's scope build happens on every request.
    from saltare import _dispatcher
    _dispatcher.set_proxy_headers(bool(proxy_headers))
    _dispatcher.set_request_id_header(request_id_header)
    _dispatcher.set_server_timing(bool(server_timing))
    _dispatcher.set_server_header(server_header)

    # `workers=0` is shorthand for "use what the kernel says we have,
    # capped at 4". Multi-worker past 4 hits diminishing returns under
    # CPython's GIL-locked dispatch and inflates the Pss floor with no
    # gain on RAM-budget workloads. Set explicitly for finer control.
    if int(workers) <= 0:
        import os as _os
        cpu = _os.cpu_count() or 1
        workers = min(cpu, 4)

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
        int(shutdown_timeout),
        uds_path,
        metrics_path,
        int(bool(access_log)),
        int(ws_keepalive_timeout),
        int(workers),
        health_path,
        int(bool(cors_preflight_allow_all)),
        int(rate_limit_per_sec),
        int(rate_limit_burst),
        tracemalloc_path,
        int(bool(proxy_headers)),
        int(bool(favicon_204)),
        int(max_connections_per_ip),
        access_log_path,
        int(listen_backlog),
        int(tcp_keepidle),
        int(tcp_keepintvl),
        int(tcp_keepcnt),
        int(bool(proxy_protocol)),
        int(tcp_user_timeout_ms),
        int(bool(auto_raise_nofile)),
        int(max_connection_lifetime),
        int(tls_session_cache_size),
        int(bool(startup_request)),
        server_header,
    )
