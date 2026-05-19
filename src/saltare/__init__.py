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
    ssl_ca_file: str | None = None,
    ssl_verify_client: bool = False,
    tcp_fastopen_qlen: int = 0,
    gc_collect_every_n_requests: int = 0,
    response_gzip: bool = False,
    response_gzip_min_bytes: int = 512,
    response_gzip_level: int = 6,
    response_brotli: bool = False,
    response_brotli_quality: int = 4,
    response_zstd: bool = False,
    response_zstd_level: int = 3,
    request_decompression: bool = False,
    max_request_uri: int = 8192,
    max_request_head_bytes: int = 0,
    latency_histogram: bool = False,
    traceparent_propagation: bool = False,
    reload: bool = False,
    reload_dirs: list[str] | tuple[str, ...] | None = None,
    reload_includes: list[str] | tuple[str, ...] | None = None,
    reload_excludes: list[str] | tuple[str, ...] | None = None,
    reload_poll_secs: float = 0.5,
    dispatch_path: str | None = None,
    runtime_config_path: str | None = None,
    dispatch_token: str | None = None,
    ktls: bool = False,
    hsts_max_age: int = 0,
    hsts_include_subdomains: bool = False,
    hsts_preload: bool = False,
    drain_path: str | None = None,
    access_log_exclude: list[str] | tuple[str, ...] | None = None,
    ws_reject_log: bool = False,
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
    # v1.4 --reload: parent process supervises a saltare child, watches
    # files, SIGTERM + respawn on change. The child re-enters this fn
    # with `_SALTARE_RELOAD_CHILD=1` set in env and skips the supervise
    # branch. Multi-worker (`--workers > 1`) is incompatible with the
    # supervisor — we silently fall back to single-worker so the
    # reloader can own the listen socket.
    if reload:
        from saltare import _reload
        if not _reload.is_reload_child():
            if int(workers) > 1:
                import sys as _sys
                _sys.stderr.write(
                    "saltare: --reload disables --workers > 1 "
                    "(reloader and pre-fork supervisor share no listen socket)\n"
                )
            dirs = tuple(reload_dirs) if reload_dirs else (".",)
            includes = tuple(reload_includes) if reload_includes else _reload._DEFAULT_INCLUDES
            excludes = tuple(reload_excludes) if reload_excludes else _reload._DEFAULT_EXCLUDES
            _reload.supervise(
                reload_dirs=dirs,
                includes=includes,
                excludes=excludes,
                poll_secs=float(reload_poll_secs),
            )
            return
        # Child path: force workers=1 so the child is a single saltare
        # process the supervisor can SIGTERM cleanly.
        if int(workers) > 1:
            workers = 1

    # Wire Python-side proxy-headers handling. Done before _core.serve
    # because the dispatcher's scope build happens on every request.
    from saltare import _dispatcher
    _dispatcher.set_proxy_headers(bool(proxy_headers))
    _dispatcher.set_request_id_header(request_id_header)
    _dispatcher.set_server_timing(bool(server_timing))
    _dispatcher.set_server_header(server_header)
    _dispatcher.set_gc_collect_every_n(int(gc_collect_every_n_requests))
    # v1.4 zlib wiring. Both off by default — when off, libz stays unloaded.
    _dispatcher.set_response_gzip(
        bool(response_gzip),
        int(response_gzip_min_bytes),
        int(response_gzip_level),
    )
    _dispatcher.set_response_brotli(bool(response_brotli), int(response_brotli_quality))
    _dispatcher.set_response_zstd(bool(response_zstd), int(response_zstd_level))
    # v1.4: probe each enabled codec once at startup. If `--response-brotli`
    # / `--response-zstd` is on but the system shared library is absent
    # (musl base, slim images), the dispatcher would silently fall back
    # to identity per-request — operator wouldn't know their flag is a
    # no-op. Emit a single-line stderr warning so the misconfiguration
    # is visible in container logs.
    import sys as _sys
    # Use known-good encoder params for the probe so an out-of-range
    # user param doesn't masquerade as a missing lib.
    if response_brotli:
        if _core.brotli_encode(b"probe", 4) is None:
            _sys.stderr.write(
                "saltare: warning: --response-brotli is on but libbrotlienc.so.1 "
                "could not be dlopen'd; falling back to gzip / identity\n"
            )
    if response_zstd:
        if _core.zstd_encode(b"probe", 3) is None:
            _sys.stderr.write(
                "saltare: warning: --response-zstd is on but libzstd.so.1 "
                "could not be dlopen'd; falling back to gzip / identity\n"
            )
    if response_gzip or request_decompression:
        if _core.gzip_encode(b"probe", 6) is None:
            _sys.stderr.write(
                "saltare: warning: --response-gzip / --request-decompression is on "
                "but libz.so.1 could not be dlopen'd; compression is a no-op\n"
            )
    _dispatcher.set_request_decompression(
        bool(request_decompression),
        int(max_request_body),
    )
    _dispatcher.set_traceparent_propagation(bool(traceparent_propagation))
    # v1.6 HSTS. `max_age=0` keeps the header line empty (zero-cost path).
    _dispatcher.set_hsts(
        int(hsts_max_age),
        bool(hsts_include_subdomains),
        bool(hsts_preload),
    )

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
        ssl_ca_file,
        int(bool(ssl_verify_client)),
        int(tcp_fastopen_qlen),
        int(gc_collect_every_n_requests),
        int(max_request_uri),
        int(max_request_head_bytes),
        int(bool(latency_histogram)),
        dispatch_path,
        runtime_config_path,
        dispatch_token,
        int(bool(ktls)),
        drain_path,
        # CSV-encoded so the Zig side parses with a single `z` argument
        # in PyArg_ParseTuple instead of iterating a Python tuple.
        # Stripped + filtered empties so trailing commas / accidental
        # blanks don't shadow real entries.
        (",".join(p for p in access_log_exclude if p) if access_log_exclude else None),
        int(bool(ws_reject_log)),
    )
