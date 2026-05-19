"""Per-request ASGI dispatcher.

Owns a persistent ``asyncio`` event loop that's reused across every request
for the lifetime of the server. The Zig core calls ``dispatch()`` from the
main thread, having re-acquired the GIL after parsing HTTP. ``dispatch()``
returns the full HTTP/1.1 wire response as ``bytes`` so the Zig side just
writes them to the socket.

Why persistent loop and not ``asyncio.run`` per request:
    Saving every Task/Future allocation matters for the project's RAM goal.
    A persistent loop costs ~a few KB once; ``asyncio.run`` would create
    and tear down a fresh ``EventLoop`` (~tens of KB) every request.

Limitations (intentional, scheduled for later milestones):
    - No lifespan protocol (FastAPI startup/shutdown hooks don't fire).
    - No keep-alive, no chunked Transfer-Encoding, no streaming bodies.
    - No WebSockets.
"""

from __future__ import annotations

import asyncio
import sys
import threading
from typing import Any

# v1.3: `traceback` is imported lazily inside the exception-handling
# paths below. The module is ~150 KiB resident once imported (it pulls
# `linecache`, `re`, `tokenize`, and a chunk of stdlib glue). Most
# requests never hit those paths, so deferring trims the idle floor by
# the same margin.
def _print_exception_lazy(exc_type, exc, tb=None) -> None:
    import traceback as _tb
    if tb is not None:
        _tb.print_exception(exc_type, exc, tb, file=sys.stderr)
    else:
        _tb.print_exc(file=sys.stderr)

# v1.3: percent-decoding moved to Zig (`http.urlDecode` in src/zig/http.zig).
# We used to import `urllib.parse.unquote_to_bytes` here; dropping the
# import shaves ~150 KiB of stdlib mappings off saltare's idle floor.

# Per-thread state. In production there's exactly one `serve()` per process,
# so this collapses to a single namespace. In tests we run several saltare
# daemons concurrently (one per test) and they MUST NOT share an asyncio
# loop or task tables — that mixed up done-Task callbacks and ws handles
# across servers and produced segfaults during cleanup.
_state = threading.local()

# Process-wide flag for v0.15 X-Forwarded-* parsing. Off by default —
# enabling it on a server that *isn't* behind a trusted proxy lets clients
# spoof their address. Set via `saltare.run(proxy_headers=True)` (the
# wrapper calls `set_proxy_headers` before invoking _core.serve).
_proxy_headers_enabled = False

# v1.3: per-request X-Request-ID. When set to a non-empty header name
# (e.g. b"x-request-id"), the dispatcher generates an 8-byte hex ID
# per HTTP request, attaches it to `scope["x-request-id"]`, and echoes
# it as a response header. Apps see the ID in scope without having to
# parse incoming headers themselves.
_request_id_header: bytes | None = None

# v1.3: Server-Timing. When True, dispatcher tracks request start time
# and prepends a `Server-Timing: total;dur=<ms>` header to every
# response. Cost ~0 RAM (one float64 per in-flight request); ~1 µs CPU.
_server_timing_enabled = False

# v1.3: per-N-requests `gc.collect(0)` cadence. 0 = leave gen-0 to
# CPython's default thresholds. Non-zero means "run a gen-0 sweep
# every N completed dispatches" — clears short-lived cyclic objects
# before they get promoted to gen-1, which keeps the gen-1 set small
# and the eventual full-gen sweep cheap. Each sweep is tens of µs.
_gc_collect_every_n: int = 0
_dispatch_counter: int = 0


def set_proxy_headers(enabled: bool) -> None:
    """Toggle X-Forwarded-For / X-Forwarded-Proto handling. Called by the
    `saltare.run()` wrapper just before the I/O loop starts."""
    global _proxy_headers_enabled
    _proxy_headers_enabled = bool(enabled)


def set_request_id_header(name: str | None) -> None:
    """Configure the response header name to echo the auto-generated
    request ID under. None disables — no ID generated, no scope key,
    no response header."""
    global _request_id_header
    _request_id_header = (
        name.lower().encode("ascii") if isinstance(name, str) and name else None
    )


def set_server_timing(enabled: bool) -> None:
    """Toggle the `Server-Timing: total;dur=<ms>` response header."""
    global _server_timing_enabled
    _server_timing_enabled = bool(enabled)


def set_gc_collect_every_n(n: int) -> None:
    """Schedule `gc.collect(0)` every N dispatches. 0 disables."""
    global _gc_collect_every_n
    _gc_collect_every_n = max(0, int(n))


# v1.4 W3C Trace Context. When enabled, the dispatcher reads `traceparent`
# (and optionally `tracestate`) from the request, exposes them on
# `scope["traceparent"]` / `scope["tracestate"]` as ASGI extension keys,
# and echoes `traceparent` back in the response so downstream services
# correlate without us pulling in the OpenTelemetry SDK. Off by default —
# zero per-request cost when off (one bool compare).
_traceparent_propagation: bool = False


def set_traceparent_propagation(enabled: bool) -> None:
    """Toggle W3C Trace Context (`traceparent` + `tracestate`) propagation
    on `scope` and the response. Off by default."""
    global _traceparent_propagation
    _traceparent_propagation = bool(enabled)


# v1.6 HSTS (RFC 6797). Opt-in. When `_hsts_header_line` is non-empty the
# dispatcher appends it to every response. Operator owns the decision —
# we don't gate on scope["scheme"] because real deployments terminate TLS
# at a proxy and saltare sees scheme="http" via X-Forwarded-Proto: https.
# Pre-rendered byte string saves a bytes-build per response.
_hsts_header_line: bytes = b""


def set_hsts(max_age: int, include_subdomains: bool, preload: bool) -> None:
    """Pre-render `Strict-Transport-Security` header. `max_age <= 0`
    disables (line cleared)."""
    global _hsts_header_line
    if max_age <= 0:
        _hsts_header_line = b""
        return
    parts = [f"max-age={int(max_age)}"]
    if include_subdomains:
        parts.append("includeSubDomains")
    if preload:
        parts.append("preload")
    _hsts_header_line = (
        b"strict-transport-security: " + "; ".join(parts).encode("ascii") + b"\r\n"
    )


def _ensure_state() -> threading.local:
    if not hasattr(_state, "loop"):
        _state.loop = asyncio.new_event_loop()
        _state.ws_states = {}
        _state.next_ws_handle = 1
        _state.http_states = {}
        _state.next_http_handle = 1
        _state.lifespan_task = None
        _state.lifespan_receive_queue = None
        _state.lifespan_send_queue = None
        # v1.7 ASGI 3.0 shared state. Same dict object passed through
        # lifespan startup (apps may populate it) and then surfaced as
        # `scope["state"]` in every subsequent HTTP and WebSocket scope
        # — matches uvicorn's behaviour and is what Channels'
        # `AuthMiddlewareStack` / custom middleware expect to find.
        _state.asgi_state = {}
    return _state


def _ensure_loop() -> asyncio.AbstractEventLoop:
    return _ensure_state().loop


_LIFESPAN_TIMEOUT = 10.0


async def _drive_lifespan_event(
    task: asyncio.Task,
    send_queue: asyncio.Queue,
    timeout: float = _LIFESPAN_TIMEOUT,
) -> tuple[str, Any]:
    """Wait for either a message from the app via send_queue, or for the
    lifespan task to finish. Returns a (kind, value) tuple where kind is one
    of: 'message', 'returned', 'exception', 'cancelled', 'timeout'."""
    receive_task = asyncio.create_task(send_queue.get())
    try:
        done, _pending = await asyncio.wait(
            {receive_task, task},
            return_when=asyncio.FIRST_COMPLETED,
            timeout=timeout,
        )
    finally:
        if not receive_task.done():
            receive_task.cancel()

    if receive_task in done:
        return ("message", receive_task.result())

    if task in done:
        if task.cancelled():
            return ("cancelled", None)
        try:
            task.result()
            return ("returned", None)
        except BaseException as exc:
            return ("exception", exc)

    return ("timeout", None)


def lifespan_startup(app: Any) -> bool:
    """Drive the app's lifespan startup. Returns True on success or if the
    app doesn't support lifespan; False on explicit startup failure or
    timeout. Called by the Zig bridge once, with the GIL held, before the
    I/O loop accepts any connection.
    """
    state = _ensure_state()
    loop = state.loop

    # If a previous serve() left a stale task around (rare; mostly a tests
    # concern), cancel it.
    if state.lifespan_task is not None and not state.lifespan_task.done():
        state.lifespan_task.cancel()
        try:
            loop.run_until_complete(state.lifespan_task)
        except BaseException:
            pass

    state.lifespan_receive_queue = asyncio.Queue()
    state.lifespan_send_queue = asyncio.Queue()

    rq, sq = state.lifespan_receive_queue, state.lifespan_send_queue

    async def lifespan_receive() -> dict[str, Any]:
        return await rq.get()

    async def lifespan_send(message: dict[str, Any]) -> None:
        await sq.put(message)

    # ASGI 3.0: fresh shared-state dict for this serve() invocation.
    # The app's lifespan-startup callable can populate it; every HTTP /
    # WebSocket scope built thereafter sees the same dict by reference.
    state.asgi_state = {}
    scope: dict[str, Any] = {
        "type": "lifespan",
        "asgi": _ASGI_LIFESPAN_SUB,
        "state": state.asgi_state,
    }

    state.lifespan_task = loop.create_task(app(scope, lifespan_receive, lifespan_send))
    rq.put_nowait({"type": "lifespan.startup"})

    kind, value = loop.run_until_complete(
        _drive_lifespan_event(state.lifespan_task, sq)
    )

    if kind == "message":
        msg_type = value.get("type") if isinstance(value, dict) else None
        if msg_type == "lifespan.startup.complete":
            return True
        if msg_type == "lifespan.startup.failed":
            sys.stderr.write(
                f"saltare: lifespan.startup.failed: "
                f"{value.get('message', '') if isinstance(value, dict) else ''}\n"
            )
            return False
        sys.stderr.write(f"saltare: unexpected lifespan startup message: {value}\n")
        return True

    if kind == "exception":
        # Per ASGI convention, an exception before any send() typically means
        # the app doesn't support lifespan. We log it and continue serving.
        sys.stderr.write(
            f"saltare: lifespan task raised during startup "
            f"({type(value).__name__}: {value}). Treating as 'no lifespan support'.\n"
        )
        return True

    if kind == "returned":
        # App finished its lifespan handler without sending startup.complete.
        # Tolerated: minimal apps sometimes just return.
        return True

    if kind == "timeout":
        sys.stderr.write(f"saltare: lifespan startup timed out ({_LIFESPAN_TIMEOUT}s)\n")
        return False

    return True


def lifespan_shutdown() -> None:
    """Drive the app's lifespan shutdown. Best-effort: errors are logged and
    the server proceeds to exit either way. Called by the Zig bridge once,
    with the GIL held, after the I/O loop has stopped accepting connections.
    """
    state = _ensure_state()
    if (
        state.lifespan_task is None
        or state.lifespan_receive_queue is None
        or state.lifespan_send_queue is None
    ):
        return

    loop = state.loop

    if state.lifespan_task.done():
        return

    state.lifespan_receive_queue.put_nowait({"type": "lifespan.shutdown"})

    kind, value = loop.run_until_complete(
        _drive_lifespan_event(state.lifespan_task, state.lifespan_send_queue)
    )

    if kind == "exception":
        sys.stderr.write(
            f"saltare: lifespan shutdown raised ({type(value).__name__}: {value})\n"
        )
    elif kind == "timeout":
        sys.stderr.write(f"saltare: lifespan shutdown timed out ({_LIFESPAN_TIMEOUT}s)\n")
        if not state.lifespan_task.done():
            state.lifespan_task.cancel()
            try:
                loop.run_until_complete(state.lifespan_task)
            except BaseException:
                pass


_REASONS: dict[int, str] = {
    200: "OK", 201: "Created", 202: "Accepted", 204: "No Content",
    301: "Moved Permanently", 302: "Found", 303: "See Other",
    304: "Not Modified", 307: "Temporary Redirect", 308: "Permanent Redirect",
    400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
    404: "Not Found", 405: "Method Not Allowed", 409: "Conflict",
    410: "Gone", 413: "Content Too Large", 415: "Unsupported Media Type",
    422: "Unprocessable Content", 429: "Too Many Requests",
    500: "Internal Server Error", 501: "Not Implemented",
    502: "Bad Gateway", 503: "Service Unavailable", 504: "Gateway Timeout",
}

_SERVER_HEADER = b"saltare/1.4.0"


# ---------------------------------------------------------------------------
# tracemalloc debug endpoint helpers (v1.3). Optional; only invoked when the
# operator passes `tracemalloc_path=` to `saltare.run()`. Bridge-side
# `init_tracemalloc` runs once at startup; `dump_tracemalloc` runs on every
# request to `tracemalloc_path` and returns a top-N text dump.

def init_tracemalloc() -> None:
    """Start tracemalloc tracking. Idempotent — safe to call repeatedly."""
    import tracemalloc
    if not tracemalloc.is_tracing():
        # 25 frames deep: enough to identify FastAPI / Pydantic call sites.
        tracemalloc.start(25)


# v1.4: cached tracemalloc snapshot. `take_snapshot()` is expensive
# (~10-50 ms for a real-world FastAPI app); without caching, hitting
# `/debug/tracemalloc` from a monitoring agent every few seconds
# would block the I/O loop. We cache the formatted text dump for
# `_TRACEMALLOC_CACHE_TTL_NS` (default 5 s) before regenerating.
_TRACEMALLOC_CACHE_TTL_NS = 5 * 1_000_000_000
_tracemalloc_cache: tuple[int, bytes] | None = None


def prewarm_app(app: Any) -> None:
    """Issue an internal `GET /` against the user app once lifespan
    startup has finished. Warms FastAPI route compilation, pydantic
    validators, etc., so the first real client request doesn't pay
    the cold-start latency cliff.

    Best-effort: any exception is swallowed (we don't want a buggy
    app to fail server startup over a warmup). Output bytes are
    discarded — the goal is purely to drive the import / JIT paths."""
    loop = _ensure_loop()
    asgi_sub = _ASGI_HTTP_SUB
    scope = {
        "type": "http",
        "asgi": asgi_sub,
        "http_version": "1.1",
        "method": "GET",
        "scheme": "http",
        "path": "/",
        "raw_path": b"/",
        "query_string": b"",
        "headers": [(b"host", b"saltare-prewarm")],
        "server": ("127.0.0.1", 0),
        "client": None,
        "root_path": "",
    }

    received = False
    finished = False

    async def receive():
        nonlocal received
        if not received:
            received = True
            return {"type": "http.request", "body": b"", "more_body": False}
        return {"type": "http.disconnect"}

    async def send(_message):
        return None

    async def driver():
        try:
            await app(scope, receive, send)
        except BaseException:
            pass
        nonlocal finished
        finished = True

    task = loop.create_task(driver())
    # Pump until the task finishes or we hit a deadline. The dummy
    # request should complete in a single tick for non-async apps and
    # within a few hundred ms for FastAPI cold start.
    deadline = 50  # ticks of 1 ms each = 50 ms ceiling
    asyncio.events._set_running_loop(loop)
    try:
        for _ in range(deadline):
            if task.done():
                break
            loop.call_soon(_no_op)
            try:
                loop._run_once()
            except BaseException:
                break
            if finished:
                break
    finally:
        asyncio.events._set_running_loop(None)
    if not task.done():
        task.cancel()


def dump_tracemalloc(top_n: int = 30) -> bytes:
    """Return a top-N tracemalloc snapshot as bytes (text/plain). Each
    line is `<size_kib> KiB  <count> blocks  <traceback-summary>`.
    Empty result if tracemalloc isn't tracking — happens when
    `tracemalloc_path` wasn't configured.

    v1.4: snapshots are cached for 5 s. A monitoring agent polling
    every second sees the same snapshot 5× before a fresh one;
    saves ~10-50 ms per cached hit (the take_snapshot() itself).
    Cache invalidates on each call past the TTL."""
    import tracemalloc
    if not tracemalloc.is_tracing():
        return b"tracemalloc not tracking (configure tracemalloc_path=)\n"

    import time as _time
    now_ns = _time.monotonic_ns()
    global _tracemalloc_cache
    if _tracemalloc_cache is not None:
        cached_ns, cached_bytes = _tracemalloc_cache
        if now_ns - cached_ns < _TRACEMALLOC_CACHE_TTL_NS:
            return cached_bytes

    snap = tracemalloc.take_snapshot()
    stats = snap.statistics("lineno")[:top_n]
    lines: list[str] = [
        f"# top {len(stats)} allocations (group: lineno; cached up to 5 s)\n"
    ]
    for stat in stats:
        size_kib = stat.size / 1024
        last_frame = stat.traceback[-1] if stat.traceback else None
        loc = (
            f"{last_frame.filename}:{last_frame.lineno}"
            if last_frame is not None
            else "?"
        )
        lines.append(
            f"{size_kib:>8.1f} KiB  {stat.count:>5d} blocks  {loc}\n"
        )
    payload = "".join(lines).encode("utf-8")
    _tracemalloc_cache = (now_ns, payload)
    return payload

# ASGI scope sub-dicts. These never change between requests, so caching them
# at module level avoids one dict allocation (~200 B) per dispatch. ASGI
# consumers are not allowed to mutate `scope["asgi"]` per spec, so sharing
# the same instance across all requests is safe.
_ASGI_LIFESPAN_SUB = {"version": "3.0", "spec_version": "2.0"}
_ASGI_HTTP_SUB = {"version": "3.0", "spec_version": "2.3"}
_ASGI_WS_SUB = {"version": "3.0", "spec_version": "2.3"}

def _apply_proxy_headers(
    headers: list[tuple[bytes, bytes]],
    scheme: str,
    server_host: str,
    server_port: int,
) -> tuple[str, tuple[str, int] | None, tuple[str, int]]:
    """v1.7: factor out the X-Forwarded-* / RFC 7239 parsing used by
    `http_dispatch_start`. Returns `(scheme, client, server)`. Called
    by both the HTTP and the WebSocket entry points so the WS path
    behind a reverse proxy now reflects the real client (was: always
    `None`, which broke Channels' `AllowedHostsOriginValidator`).

    Source-precedence (most specific first):
      1. RFC 7239 `Forwarded:` (`for=...;proto=...;host=...`)
      2. nginx `X-Real-IP` (single IP)
      3. `X-Forwarded-For` (comma-separated; leftmost = original client)
    plus optional `X-Forwarded-Proto` / `-Host`. We trust whatever the
    immediate peer (assumed: a hardened reverse proxy) sent.
    """
    effective_scheme = scheme
    effective_client: tuple[str, int] | None = None
    effective_server: tuple[str, int] = (server_host, server_port)
    x_real_ip: bytes | None = None
    x_forwarded_for: bytes | None = None
    x_forwarded_host: bytes | None = None
    forwarded_for: bytes | None = None
    forwarded_proto: bytes | None = None
    forwarded_host: bytes | None = None
    for name, value in headers:
        if name == b"x-real-ip":
            x_real_ip = value
        elif name == b"x-forwarded-for":
            x_forwarded_for = value
        elif name == b"x-forwarded-proto":
            proto = value.strip().lower()
            if proto in (b"http", b"https"):
                effective_scheme = proto.decode("ascii")
        elif name == b"x-forwarded-host":
            x_forwarded_host = value
        elif name == b"forwarded":
            first = value.split(b",", 1)[0]
            for part in first.split(b";"):
                p = part.strip()
                if p.startswith(b"for="):
                    forwarded_for = p[4:].strip(b"\"")
                elif p.startswith(b"proto="):
                    forwarded_proto = p[6:].strip(b"\"")
                elif p.startswith(b"host="):
                    forwarded_host = p[5:].strip(b"\"")
    if forwarded_proto:
        fp = forwarded_proto.lower()
        if fp in (b"http", b"https"):
            effective_scheme = fp.decode("ascii")
    host_raw = forwarded_host if forwarded_host is not None else x_forwarded_host
    if host_raw:
        try:
            host_str = host_raw.decode("ascii").strip().strip('"')
            if ":" in host_str and not host_str.startswith("["):
                h, _, p = host_str.rpartition(":")
                try:
                    effective_server = (h, int(p))
                except ValueError:
                    effective_server = (host_str, server_port)
            else:
                effective_server = (host_str, server_port)
        except UnicodeDecodeError:
            pass
    client_raw: bytes | None = None
    if forwarded_for is not None:
        cf = forwarded_for.strip(b"\"")
        if cf.startswith(b"["):
            end = cf.find(b"]")
            if end != -1:
                cf = cf[1:end]
        elif b":" in cf and cf.count(b":") == 1:
            cf = cf.split(b":", 1)[0]
        client_raw = cf
    elif x_real_ip is not None:
        client_raw = x_real_ip.strip()
    elif x_forwarded_for is not None:
        client_raw = x_forwarded_for.split(b",", 1)[0].strip()
    if client_raw:
        try:
            ip = client_raw.decode("ascii")
            effective_client = (ip, 0)
        except UnicodeDecodeError:
            pass
    return effective_scheme, effective_client, effective_server


# v1.7 ASGI 3.0 `extensions` marker. Empty dict shared by every scope
# (HTTP + WS). Apps that consult `scope["extensions"]` (the FastAPI
# lifespan-state helper, Django Channels' middleware that probes for
# server-side extension support) now see a real dict instead of
# `KeyError`. We don't advertise any extensions yet — `saltare.sendfile`
# remains an ASGI-message-type extension, not a scope-level one.
_SCOPE_EXTENSIONS: dict[str, Any] = {}

# v1.2: pre-built wire-format byte constants. Each response used to rebuild
# `b"server: " + _SERVER_HEADER + b"\r\n"` (one `+` allocation), the
# Connection line via a branch on `keep_alive`, and the status line via an
# f-string + `.encode("ascii")`. Pre-caching the common ones drops several
# transient `bytes` allocations per response — especially noticeable in
# concurrent bursts where the GC churn from those tiny strings used to
# dominate the per-response Python work.
#
# v1.3: `_SERVER_LINE` is now mutable via `set_server_header()` so the
# Python-side response builder (chunked-encoded streaming responses go
# through `_build_wire` and `_emit_headers`) honors the same override
# the Zig fast-paths apply via `g_server_line`.
_SERVER_LINE = b"server: " + _SERVER_HEADER + b"\r\n"


def set_server_header(value: str | None) -> None:
    """Override the `Server:` response header. None keeps default;
    empty string omits the line entirely."""
    global _SERVER_LINE
    if value is None:
        _SERVER_LINE = b"server: " + _SERVER_HEADER + b"\r\n"
    elif value == "":
        _SERVER_LINE = b""
    else:
        _SERVER_LINE = b"server: " + value.encode("ascii", errors="replace") + b"\r\n"
_CONNECTION_KEEPALIVE_LINE = b"connection: keep-alive\r\n"
_CONNECTION_CLOSE_LINE = b"connection: close\r\n"
_TRANSFER_ENCODING_CHUNKED_LINE = b"transfer-encoding: chunked\r\n"
_CHUNKED_TERMINATOR = b"0\r\n\r\n"
_CRLF = b"\r\n"

# v1.4 zlib wiring. Default-off operationally — both knobs are toggled via
# `set_compression_*` setters from `_core.serve`. When off (default), the
# Python dispatcher does no compression work and `_core.gzip_encode` /
# `_core.gunzip` are never called, so libz stays unloaded (the lazy dlopen
# in `src/zig/zlib.zig` only fires on first call).
#
# Response compression. `_response_gzip_enabled = True` triggers
# encoding on single-shot or chunked-streaming responses when (a) the
# client offered the encoding via `Accept-Encoding`, (b) Content-Type is
# in the compressible set, (c) body length ≥ `_response_gzip_min_bytes`,
# and (d) the app didn't pre-set Content-Encoding. Brotli + zstd are
# enabled per-flag; when `_response_brotli_enabled` is True and the
# client lists `br` ahead of (or with equal weight to) `gzip`, brotli
# wins. zstd similarly. The runtime auto-falls back to gzip when libbrotli
# / libzstd aren't present in the image.
_response_gzip_enabled: bool = False
_response_brotli_enabled: bool = False
_response_zstd_enabled: bool = False
_response_gzip_min_bytes: int = 512
_response_gzip_level: int = 6
_response_brotli_quality: int = 4
_response_zstd_level: int = 3
# Compressible content-type prefixes (lowercase, byte-string for cheap
# `startswith` against header values). HTML/JSON/JS/CSS/SVG/XML are the
# 95th-percentile cases; binary formats (png, mp4, woff2) compress poorly
# under gzip and we'd waste CPU.
_GZIPPABLE_TYPE_PREFIXES: tuple[bytes, ...] = (
    b"text/",
    b"application/json",
    b"application/javascript",
    b"application/xml",
    b"application/xhtml+xml",
    b"application/atom+xml",
    b"application/rss+xml",
    b"application/x-javascript",
    b"image/svg+xml",
)

# Request decompression: when set True, a request whose `Content-Encoding`
# header lists `gzip` gets decompressed before the body event lands in the
# app. Cap is `max_request_body` (the same byte budget that bounds raw
# bodies). Returns 413 on overflow, 400 on malformed gzip.
_request_decompress_enabled: bool = False
_request_decompress_cap: int = 1 * 1024 * 1024


def set_response_gzip(enabled: bool, min_bytes: int = 512, level: int = 6) -> None:
    """Toggle response gzip negotiation. Off by default — when off the
    dispatcher never calls `_core.gzip_encode`, so libz stays unmapped."""
    global _response_gzip_enabled, _response_gzip_min_bytes, _response_gzip_level
    _response_gzip_enabled = bool(enabled)
    if min_bytes > 0:
        _response_gzip_min_bytes = int(min_bytes)
    if 1 <= level <= 9:
        _response_gzip_level = int(level)
    elif enabled:
        import sys as _sys
        _sys.stderr.write(
            f"saltare: response_gzip_level={level} out of range [1, 9]; "
            f"keeping {_response_gzip_level}\n"
        )


def set_response_brotli(enabled: bool, quality: int = 4) -> None:
    """Toggle response brotli (`Accept-Encoding: br`). Off by default —
    libbrotli stays unloaded when off."""
    global _response_brotli_enabled, _response_brotli_quality
    _response_brotli_enabled = bool(enabled)
    if 0 <= quality <= 11:
        _response_brotli_quality = int(quality)
    elif enabled:
        import sys as _sys
        _sys.stderr.write(
            f"saltare: response_brotli_quality={quality} out of range [0, 11]; "
            f"keeping {_response_brotli_quality}\n"
        )


def set_response_zstd(enabled: bool, level: int = 3) -> None:
    """Toggle response zstd (`Accept-Encoding: zstd`). Off by default —
    libzstd stays unloaded when off."""
    global _response_zstd_enabled, _response_zstd_level
    _response_zstd_enabled = bool(enabled)
    if 1 <= level <= 22:
        _response_zstd_level = int(level)
    elif enabled:
        import sys as _sys
        _sys.stderr.write(
            f"saltare: response_zstd_level={level} out of range [1, 22]; "
            f"keeping {_response_zstd_level}\n"
        )


def set_request_decompression(enabled: bool, cap_bytes: int = 0) -> None:
    """Toggle request `Content-Encoding: gzip` decompression. `cap_bytes`
    matches `max_request_body`; 0 keeps the existing cap."""
    global _request_decompress_enabled, _request_decompress_cap
    _request_decompress_enabled = bool(enabled)
    if cap_bytes > 0:
        _request_decompress_cap = int(cap_bytes)


def _is_gzippable_content_type(ctype: bytes) -> bool:
    lower = ctype.lower().strip()
    if not lower:
        return False
    # Strip parameters (`; charset=…`) before prefix-matching.
    semi = lower.find(b";")
    if semi != -1:
        lower = lower[:semi].rstrip()
    for prefix in _GZIPPABLE_TYPE_PREFIXES:
        if lower.startswith(prefix):
            return True
    return False


def _parse_accept_encoding(value: bytes) -> dict[bytes, float]:
    """Parse `Accept-Encoding` into {encoding: q-weight}. Tokens with `q=0`
    are dropped. Empty / malformed weights default to 1.0 per RFC 7231."""
    result: dict[bytes, float] = {}
    for token in value.lower().split(b","):
        t = token.strip()
        if not t:
            continue
        name = t
        weight = 1.0
        if b";" in t:
            name, _, rest = t.partition(b";")
            name = name.strip()
            for param in rest.split(b";"):
                p = param.strip()
                if p.startswith(b"q="):
                    try:
                        weight = float(p[2:].strip())
                    except ValueError:
                        weight = 1.0
                    break
        if weight <= 0.0:
            continue
        result[name] = weight
    return result


def _negotiate_encoding(value: bytes) -> bytes:
    """Pick the best response encoding from `Accept-Encoding`. Server
    preference order is br > zstd > gzip when multiple are offered with
    equal weight (br compresses tightest for text, zstd is fastest, gzip
    is the universal fallback). Returns b"" when nothing is acceptable
    or the corresponding encoder is disabled at module level."""
    weights = _parse_accept_encoding(value)
    star = weights.get(b"*", 0.0)

    def acceptable(name: bytes) -> float:
        if name in weights:
            return weights[name]
        return star

    # Respect server-side ordering by walking the priority list and taking
    # the first encoder both enabled AND offered with q>0. Within an equal
    # client-q tier we still prefer the server order (br/zstd/gzip).
    candidates: list[tuple[bytes, float]] = []
    if _response_brotli_enabled:
        q = acceptable(b"br")
        if q > 0:
            candidates.append((b"br", q))
    if _response_zstd_enabled:
        q = acceptable(b"zstd")
        if q > 0:
            candidates.append((b"zstd", q))
    if _response_gzip_enabled:
        q = acceptable(b"gzip")
        if q > 0:
            candidates.append((b"gzip", q))
    if not candidates:
        return b""
    candidates.sort(key=lambda kv: kv[1], reverse=True)
    return candidates[0][0]

# Status lines for the codes saltare emits or that user apps use heavily.
# Apps returning an unusual code fall back to the fmt path.
_STATUS_LINE_CACHE: dict[int, bytes] = {
    code: f"HTTP/1.1 {code} {reason}\r\n".encode("ascii")
    for code, reason in _REASONS.items()
}


def _status_line(status: int) -> bytes:
    cached = _STATUS_LINE_CACHE.get(status)
    if cached is not None:
        return cached
    reason = _REASONS.get(status, "OK")
    return f"HTTP/1.1 {status} {reason}\r\n".encode("ascii")


# ---------------------------------------------------------------------------
# WebSocket support.
#
# Each upgraded connection has a `_WsState` carrying:
#   - the app coroutine, scheduled as an asyncio.Task on the persistent loop
#   - a receive queue (events server pushes for the app to consume)
#   - an outbound buffer (encoded server-side WS frames the I/O loop drains)
#
# The Zig bridge calls `ws_open` once on upgrade, then `ws_event` per inbound
# frame, then `ws_disconnect` on close. Each call pushes an event into the
# receive queue and pumps the asyncio loop just long enough for the coro to
# reach its next `await receive()` — no run_until_complete (the coroutine
# never completes until close).


# v1.6 RFC 7692 permessage-deflate. We negotiate
# `client_no_context_takeover; server_no_context_takeover` — both sides
# reset state every message. Simpler than carrying sliding-window state
# across messages, and the compression hit is < 5% on typical text.
_PMD_TRAIL = b"\x00\x00\xff\xff"
_PMD_LEVEL = 6  # zlib default; matches gzip default.


def _pmd_negotiate(headers: list[tuple[bytes, bytes]]) -> tuple[bool, str]:
    """Inspect `Sec-WebSocket-Extensions`. Returns (active, response_token).
    Active iff client offered `permessage-deflate`. Response is the
    token to echo on the 101 (with our preferred params)."""
    for name, value in headers:
        if name != b"sec-websocket-extensions":
            continue
        for offer in value.split(b","):
            tok = offer.strip()
            if not tok:
                continue
            head, *_rest = (p.strip() for p in tok.split(b";"))
            if head == b"permessage-deflate":
                # We always reply with both no-context-takeover params
                # — ignores any `server_max_window_bits` / `client_max_window_bits`
                # the client requested. RFC 7692 lets the server pick a
                # compatible subset of the offered params.
                return (True, "permessage-deflate; client_no_context_takeover; server_no_context_takeover")
    return (False, "")


def _pmd_deflate(co: Any, payload: bytes) -> bytes:
    """RFC 7692 §7.2.1: deflate, append `Z_SYNC_FLUSH`, strip trailing
    4 sync-bytes (`00 00 ff ff`). With no_context_takeover the encoder
    is reset to a fresh state every message — we recreate a compressobj
    each call to avoid sticky state."""
    import zlib as _zlib
    if co is None:
        co = _zlib.compressobj(_PMD_LEVEL, _zlib.DEFLATED, -15)
    out = co.compress(payload) + co.flush(_zlib.Z_SYNC_FLUSH)
    if out.endswith(_PMD_TRAIL):
        out = out[:-4]
    return out


def _pmd_inflate(co: Any, payload: bytes, max_size: int = 1 * 1024 * 1024) -> bytes | None:
    """Append the 4-byte sync trailer back + raw inflate. Cap at
    `max_size` to defend against zip-bomb messages. Returns None on
    overflow / invalid stream."""
    import zlib as _zlib
    if co is None:
        co = _zlib.decompressobj(-15)
    try:
        out = co.decompress(payload + _PMD_TRAIL, max_size)
    except _zlib.error:
        return None
    if co.unconsumed_tail:
        return None  # exceeded max_size
    return out


def _build_server_frame(opcode: int, payload: bytes, rsv1: bool = False) -> bytes:
    """RFC 6455 server-side frame (no masking). FIN=1, single fragment.
    `rsv1=True` sets bit 6 of byte 0 — used by RFC 7692 per-message-deflate
    on compressed text/binary frames."""
    out = bytearray()
    b0 = 0x80 | (opcode & 0x0F)
    if rsv1:
        b0 |= 0x40
    out.append(b0)
    n = len(payload)
    if n < 126:
        out.append(n)
    elif n < 65536:
        out.append(126)
        out += n.to_bytes(2, "big")
    else:
        out.append(127)
        out += n.to_bytes(8, "big")
    out += payload
    return bytes(out)


class _WsState:
    __slots__ = (
        "recv_queue", "outgoing", "outgoing_bytes", "accepted",
        "subprotocol", "closed", "task",
        # v1.6 RFC 7692 per-message-deflate.
        "extensions",          # str echoed in Sec-WebSocket-Extensions
        "pmd_active",          # bool — extension negotiated this conn
        "_pmd_inflater",       # zlib.decompressobj or None
        "_pmd_deflater",       # zlib.compressobj or None
        # v1.7 close-code forwarding. When the app emits `websocket.close`
        # *before* accepting (Channels' AuthMiddleware rejecting on Origin
        # / Host / session), saltare maps the code to an HTTP status so
        # the client sees something more specific than a flat 403. 0 =
        # never closed by the app pre-accept (just no `websocket.accept`).
        "close_code",
        "close_reason",
    )

    def __init__(self, app: Any, scope: dict[str, Any]) -> None:
        self.recv_queue: asyncio.Queue = asyncio.Queue()
        self.outgoing: list[bytes] = []
        # Running total of bytes queued in `outgoing` since the last drain.
        # Bounds the worst-case RAM cost of a slow client + fast app.
        self.outgoing_bytes: int = 0
        self.accepted: bool = False
        # Subprotocol the app picked in `websocket.accept`, if any.
        # Empty string when the app didn't negotiate one (default).
        # The Zig bridge reads this back after the upgrade pump and
        # echoes it as `Sec-WebSocket-Protocol` in the 101 response.
        self.subprotocol: str = ""
        self.extensions: str = ""
        self.pmd_active: bool = False
        self._pmd_inflater: Any = None
        self._pmd_deflater: Any = None
        self.closed: bool = False
        self.close_code: int = 0
        self.close_reason: str = ""

        async def receive() -> dict[str, Any]:
            return await self.recv_queue.get()

        def _queue(frame: bytes) -> bool:
            # Returns False once the cap is exceeded so callers can stop
            # producing. The connection is marked closed; the next pump
            # tears it down.
            if self.outgoing_bytes + len(frame) > _WS_OUTGOING_MAX_BYTES:
                self.closed = True
                return False
            self.outgoing.append(frame)
            self.outgoing_bytes += len(frame)
            return True

        async def send(message: dict[str, Any]) -> None:
            mtype = message.get("type")
            if mtype == "websocket.accept":
                self.accepted = True
                # ASGI 2.x: app may pick a subprotocol from the list the
                # client sent in `Sec-WebSocket-Protocol`. We pass it
                # back to Zig via `_WsState.subprotocol` and the bridge
                # surfaces it in the 101 response.
                sub = message.get("subprotocol")
                if isinstance(sub, str) and sub:
                    self.subprotocol = sub
            elif mtype == "websocket.send":
                if self.closed:
                    return
                if message.get("text") is not None:
                    payload = message["text"].encode("utf-8")
                    if self.pmd_active:
                        payload = _pmd_deflate(self._pmd_deflater, payload)
                    _queue(_build_server_frame(0x1, payload, rsv1=self.pmd_active))
                elif message.get("bytes") is not None:
                    payload = message["bytes"]
                    if self.pmd_active:
                        payload = _pmd_deflate(self._pmd_deflater, payload)
                    _queue(_build_server_frame(0x2, payload, rsv1=self.pmd_active))
            elif mtype == "websocket.close":
                code = int(message.get("code", 1000))
                reason = message.get("reason", "") or ""
                # v1.7: capture for the HTTP-reject path so the bridge can
                # surface the consumer's close code as an HTTP status.
                self.close_code = code
                self.close_reason = reason
                payload = code.to_bytes(2, "big") + reason.encode("utf-8")
                _queue(_build_server_frame(0x8, payload))
                self.closed = True

        loop = _ensure_loop()
        self.task: asyncio.Task = loop.create_task(app(scope, receive, send))

    def push(self, event: dict[str, Any]) -> None:
        self.recv_queue.put_nowait(event)

    def drain(self) -> bytes:
        if not self.outgoing:
            return b""
        out = b"".join(self.outgoing)
        self.outgoing.clear()
        self.outgoing_bytes = 0
        return out


def _pump_once() -> None:
    """Process one batch of ready callbacks on the loop. We use the
    `_run_once` private method directly: it's the cheapest way to advance
    coroutines parked on a Future that we've just resolved (via Queue.put)
    without the overhead of wrapping a marker coroutine in a Task.

    A no-op `call_soon` is scheduled before each tick so `_run_once` sees
    `_ready` as non-empty and uses `timeout=0` for its selector poll. Without
    this, an app awaiting on `asyncio.sleep(N)` between sends would block
    the entire I/O loop for N seconds inside the asyncio selector.
    """
    loop = _ensure_loop()
    loop.call_soon(_no_op)
    # Each WS event we process needs the loop to "see" itself as the
    # currently running loop, otherwise asyncio.get_running_loop() inside
    # any framework code (FastAPI, Starlette) raises.
    asyncio.events._set_running_loop(loop)
    try:
        loop._run_once()
    finally:
        asyncio.events._set_running_loop(None)


def _no_op() -> None:
    pass


def http_global_pump() -> None:
    """One iteration of the asyncio loop. Advances every in-flight Task by
    one step concurrently; cheaper than per-connection multi-pumping when
    many requests are in flight (work is amortized across all of them).

    Called by the Zig main loop once per iteration whenever the stalled
    list is non-empty. The loop also calls this implicitly through
    `http_dispatch_start` and `http_dispatch_push_body` for the
    common-case fast path where a simple app completes in one tick.
    """
    _pump_once()


def ws_open(
    app: Any,
    method: str,
    raw_path: bytes,
    decoded_path: bytes,
    query_string: bytes,
    raw_headers: list[tuple[bytes, bytes]],
    server_host: str,
    server_port: int,
    scheme: str,
) -> tuple[int, bool, bytes, bool, str, str, bool]:
    """Start a WebSocket coroutine, push the websocket.connect event, and
    pump the loop. Returns 7-tuple:
       handle:      opaque int the bridge keeps for subsequent ws_event calls.
       accepted:    True if the app called websocket.accept.
       frames:      already-encoded server frames to write (close, early sends).
       done:        True if the coroutine finished (clean close).
       subprotocol: subprotocol the app selected via `accept(subprotocol=...)`,
                    or empty string. Bridge echoes it as
                    `Sec-WebSocket-Protocol` in the 101 response.
       extensions:  v1.6 — token to echo as `Sec-WebSocket-Extensions`
                    when permessage-deflate negotiated (else empty).
       pmd_active:  v1.6 — True iff permessage-deflate was negotiated.
                    Bridge sets `conn.ws_pmd_active` so subsequent
                    rsv1 hints pass through.
    """
    global _next_ws_handle

    try:
        path = decoded_path.decode("utf-8")
    except UnicodeDecodeError:
        return (0, False, b"", True, "", "", False)

    # Same as the HTTP path: names already lowercase from the bridge.
    headers = raw_headers

    # ASGI scope must carry the client's offered subprotocol list so the
    # app can pick one. Parse the comma-separated `sec-websocket-protocol`
    # header here (case-insensitive lookup; header names are already
    # lowercased by the bridge).
    subprotocols: list[str] = []
    for name, value in headers:
        if name == b"sec-websocket-protocol":
            for tok in value.split(b","):
                t = tok.strip()
                if t:
                    try:
                        subprotocols.append(t.decode("ascii"))
                    except UnicodeDecodeError:
                        continue
            break

    # `method` from the request line is unused here — ASGI WebSocket
    # scope does not carry it, and shipping it confused strict middleware
    # (notably Django Channels' AuthMiddlewareStack v4).
    del method  # documented signature-arg discard

    # v1.7 ASGI 3.0: derive scheme/client/server identically to the HTTP
    # path so proxy_headers actually works on WS upgrades behind nginx /
    # traefik / k8s ingress. Previously `scope["client"]` was hardcoded
    # to None, which broke Channels' `AllowedHostsOriginValidator` and
    # any per-IP rate limiting that lives in the consumer.
    base_scheme = "wss" if scheme == "https" else "ws"
    effective_scheme = base_scheme
    effective_client: tuple[str, int] | None = None
    effective_server: tuple[str, int] = (server_host, server_port)
    if _proxy_headers_enabled:
        # `_apply_proxy_headers` speaks http/https; translate back to
        # ws/wss after the proxy-aware scheme is known.
        proxy_scheme, effective_client, effective_server = _apply_proxy_headers(
            headers,
            "https" if base_scheme == "wss" else "http",
            server_host,
            server_port,
        )
        effective_scheme = "wss" if proxy_scheme == "https" else "ws"

    tstate = _ensure_state()
    scope: dict[str, Any] = {
        "type": "websocket",
        "asgi": _ASGI_WS_SUB,
        "http_version": "1.1",
        "scheme": effective_scheme,
        "path": path,
        "raw_path": raw_path,
        "query_string": query_string,
        "headers": headers,
        "server": effective_server,
        "client": effective_client,
        "root_path": "",
        "subprotocols": subprotocols,
        # v1.7 ASGI 3.0 — shared lifespan state + extensions marker
        # (same dict references as the HTTP path).
        "state": tstate.asgi_state,
        "extensions": _SCOPE_EXTENSIONS,
    }
    handle = tstate.next_ws_handle
    tstate.next_ws_handle += 1

    ws_state = _WsState(app, scope)
    # v1.6 RFC 7692 negotiate before the app runs, so the app sees a
    # consistent extensions value if it inspects scope. The connection
    # state machine + frame builder consult `pmd_active` from here on.
    pmd_active, pmd_response = _pmd_negotiate(headers)
    if pmd_active:
        ws_state.pmd_active = True
        ws_state.extensions = pmd_response
    tstate.ws_states[handle] = ws_state
    ws_state.push({"type": "websocket.connect"})

    # v1.7.1: two-phase pump during the upgrade.
    #
    # Phase 1 (pre-accept): spin until `accepted` or `closed` or
    # `task.done()`. Channels' `AuthMiddlewareStack` parks on an
    # async session lookup; a single `_pump_once()` returns before
    # the lookup resolves.
    #
    # Phase 2 (post-accept): the consumer's `connect()` typically
    # does MORE work after `await self.accept()` — adds the channel
    # to a group, fetches initial state from the DB, sends an
    # initial frame to the client. v1.7.1 broke out of the pump as
    # soon as `accepted=True`, leaving those follow-up coroutines
    # parked. The client saw "WebSocket connected" but never got
    # the initial state push. Now we keep pumping until the consumer
    # quiets down (no new outgoing bytes for `_WS_QUIET_TICKS_BEFORE_RETURN`
    # consecutive ticks) — that means the task has parked again,
    # presumably on `await receive_queue.get()` waiting for the next
    # client frame.
    import time as _time
    deadline = _time.monotonic() + _WS_UPGRADE_DEADLINE_S
    prev_outgoing = 0
    quiet_ticks = 0
    while True:
        try:
            _pump_once()
        except BaseException:
            _print_exception_lazy(*sys.exc_info())

        if ws_state.task.done():
            break

        # Pre-accept: keep going until decision arrives.
        if not ws_state.accepted and not ws_state.closed:
            if _time.monotonic() > deadline:
                # Cancel the parked task to avoid leaking the coroutine
                # behind a 403.
                ws_state.task.cancel()
                try:
                    _pump_once()
                except BaseException:
                    _print_exception_lazy(*sys.exc_info())
                if not ws_state.close_reason:
                    ws_state.close_reason = (
                        f"handshake timeout ({_WS_UPGRADE_DEADLINE_S}s; "
                        "consumer never called accept() or close())"
                    )
                break
            _time.sleep(0.001)
            continue

        if ws_state.closed:
            break

        # Post-accept: let the consumer flush its initial-state work
        # (group_add, initial send, etc.) before returning control to
        # the bridge. We watch `outgoing_bytes` as a proxy for "did
        # the consumer make progress this tick?". Three consecutive
        # ticks with no growth = parked on receive — safe to return.
        if ws_state.outgoing_bytes > prev_outgoing:
            prev_outgoing = ws_state.outgoing_bytes
            quiet_ticks = 0
        else:
            quiet_ticks += 1
            if quiet_ticks >= _WS_QUIET_TICKS_BEFORE_RETURN:
                break

        if _time.monotonic() > deadline:
            break

        _time.sleep(0.001)

    # v1.7.1 → v1.7.1: surface unconsumed task exceptions so a raise
    # in the user's middleware chain (Channels' AuthMiddlewareStack
    # exploding because Django settings weren't ready / ALLOWED_HOSTS
    # mismatched / SessionMiddleware missing) doesn't disappear silently.
    # Without this, the only visible signal was a flat 403 with
    # `ws-reject ... code=0 reason=`. Now operators see the actual stack.
    if ws_state.task.done() and not ws_state.accepted:
        try:
            exc = ws_state.task.exception()
        except (asyncio.CancelledError, asyncio.InvalidStateError):
            exc = None
        if exc is not None:
            _print_exception_lazy(type(exc), exc, exc.__traceback__)
            # Also stuff a short reason into close_reason so the
            # `--ws-reject-log` line carries the exception class —
            # the full traceback already went to stderr above.
            if not ws_state.close_reason:
                ws_state.close_reason = f"{type(exc).__name__}: {exc}"[:200]

    return (
        handle,
        ws_state.accepted,
        ws_state.drain(),
        ws_state.task.done(),
        ws_state.subprotocol,
        ws_state.extensions,
        ws_state.pmd_active,
        # v1.7 close-code forwarding. Only meaningful when accepted=False;
        # bridge.zig reads these on the reject path to map e.g. 4003 → 403,
        # 4001 → 401 in the HTTP status of the rejection response.
        ws_state.close_code,
        ws_state.close_reason,
    )


def ws_event(handle: int, opcode: int, payload: bytes, rsv1: int = 0) -> tuple[bytes, bool]:
    """Deliver a WebSocket frame to the running coroutine. `opcode` is 1
    (text) or 2 (binary). `rsv1=1` + permessage-deflate-negotiated →
    inflate the payload before pushing. Returns (frames_to_send, done)."""
    tstate = _ensure_state()
    ws_state = tstate.ws_states.get(handle)
    if ws_state is None or ws_state.task.done():
        return (b"", True)

    if rsv1 and ws_state.pmd_active:
        decoded = _pmd_inflate(ws_state._pmd_inflater, payload)
        if decoded is None:
            # Malformed compressed frame or zip-bomb cap exceeded.
            # Treat as protocol error — close the conn.
            return (b"", True)
        payload = decoded

    if opcode == 0x1:
        try:
            text = payload.decode("utf-8")
        except UnicodeDecodeError:
            return (b"", True)
        ws_state.push({"type": "websocket.receive", "text": text})
    elif opcode == 0x2:
        ws_state.push({"type": "websocket.receive", "bytes": payload})
    else:
        return (b"", True)

    try:
        _pump_once()
    except BaseException:
        _print_exception_lazy(*sys.exc_info())

    return (ws_state.drain(), ws_state.task.done())


def ws_drain(handle: int) -> tuple[bytes, bool]:
    """v1.7.1 — server-initiated WebSocket frame harvest. Called by
    the Zig main-loop periodic pump (`drainWsOutbound`) to flush any
    outgoing bytes the consumer produced since the last tick — most
    commonly via `channel_layer.group_send` -> consumer handler ->
    `await self.send(...)`. Does NOT push any inbound event; the
    asyncio loop was already pumped by `http_global_pump` before this
    call. Returns (frames, done). `done=True` when the consumer task
    has finished — server should not call us again for this handle.
    """
    tstate = _ensure_state()
    ws_state = tstate.ws_states.get(handle)
    if ws_state is None:
        return (b"", True)
    return (ws_state.drain(), ws_state.closed or ws_state.task.done())


def ws_disconnect(handle: int, code: int) -> bytes:
    """Tell the coroutine the connection has been (or is being) torn down,
    drain any final frames, and clean up the state. After this call the
    handle is gone; further ws_event calls return done=True immediately."""
    tstate = _ensure_state()
    ws_state = tstate.ws_states.pop(handle, None)
    if ws_state is None:
        return b""

    if not ws_state.task.done():
        ws_state.push({"type": "websocket.disconnect", "code": code})
        try:
            _pump_once()
        except BaseException:
            _print_exception_lazy(*sys.exc_info())

    if not ws_state.task.done():
        ws_state.task.cancel()
        try:
            _pump_once()
        except BaseException:
            pass

    return ws_state.drain()


# ---------------------------------------------------------------------------
# HTTP streaming dispatch (v0.12).
#
# Each in-flight HTTP request is a long-lived asyncio.Task. The Zig core
# pumps it via four entry points:
#
#   http_dispatch_start(app, ..., initial_body, more_body)
#       Build the ASGI scope, create the Task, push the first request.
#       chunk to its receive queue, pump the loop once. Return any wire
#       bytes the app produced (typically status line + headers + first
#       body chunk if the app responded synchronously).
#
#   http_dispatch_push_body(handle, body, more_body)
#       More request-body bytes arrived. Push them into the Task's receive
#       queue and pump. Return any newly-produced wire bytes.
#
#   http_dispatch_tick(handle)
#       Drain remaining response chunks without pushing input. Used by Zig
#       between socket-write events to pull more chunks the app may have
#       produced after its last `await send()`.
#
#   http_dispatch_abort(handle)
#       Connection went away mid-stream. Cancel the Task, clean up.
#
# Wire-format building lives entirely in Python: each `http.response.start`
# stages headers; the first `http.response.body` decides Content-Length vs
# Transfer-Encoding: chunked based on whether the app declared a length and
# whether more body chunks are coming. Subsequent chunks are wrapped in
# chunked-encoding frames if needed. Zig just writes raw bytes.


def _encode_chunk(body: bytes) -> bytes:
    """RFC 7230 chunked-encoding frame for a single non-empty chunk."""
    return f"{len(body):x}\r\n".encode("ascii") + body + b"\r\n"


# Module-level free list for `_HttpState` instances. `_HttpState` has 13
# slots; recycling instead of constructing fresh saves the slot-allocation
# step (~200 B of GC churn) per request and reuses the `outgoing` list
# (one less `list` object created per request). Capped to keep idle pool
# memory bounded — beyond `_HTTP_POOL_MAX` the GC reclaims naturally.
#
# v1.2.2: bumped 32 → 128. With max_concurrent_connections defaulting to
# 1024, bursts above 32 reused to fall back to fresh `_HttpState`
# allocations. 128 covers realistic concurrency curves while idle pool
# RAM stays bounded (~128 × 600 B = 75 KiB).
_http_state_pool: list["_HttpState"] = []
_HTTP_POOL_MAX = 128

# Soft backpressure threshold. After an `await send()` chain has appended
# more than this many bytes to `outgoing`, the next send yields back to the
# event loop (one `await asyncio.sleep(0)`). The Zig main loop pumps the
# loop and harvests bytes via `http_dispatch_drain`, capping per-task
# accumulated outgoing memory at ~one threshold's worth. Apps streaming
# many small chunks at once (server-sent events, log tails) used to pin
# arbitrary RAM here; now they don't.
_HTTP_SEND_YIELD_BYTES = 64 * 1024

# Hard cap on per-WS connection outgoing buffer. A slow consumer with a
# fast producer used to grow `outgoing` without bound. Above the cap we
# mark the connection closed; the bridge tears it down on the next pump.
_WS_OUTGOING_MAX_BYTES = 1024 * 1024

# v1.7.1 WebSocket upgrade pump budget. Channels' `AuthMiddlewareStack`
# does an async session lookup on every connect — the consumer's task
# parks on the first `await`, and saltare's single-tick `_pump_once()`
# returned before the lookup resolved (visible to operators as
# `ws-reject ... code=0 reason=`). We now spin the loop up to this many
# seconds of wall clock so async middleware gets a chance to decide.
# 2 s covers cold-start Django ORM lookups comfortably; bursts past
# this are real bugs or DB latency, not legitimate connects, and a
# timeout-mapped 408 is the right answer there.
_WS_UPGRADE_DEADLINE_S = 2.0

# v1.7.1 WebSocket post-accept pump. After the consumer calls `accept()`
# its `connect()` coroutine usually keeps running (group_add, initial DB
# fetch, send initial frame); each step is an `await` that parks the
# task. We want to surface those follow-up sends to the wire BEFORE
# handing control back to the bridge — otherwise the client sees
# `WebSocket connected` but never receives the initial state. We watch
# `_WsState.outgoing_bytes` as a progress signal: this many consecutive
# ticks with no growth = task parked on `receive_queue.get()`, no more
# work pending. 3 × 1 ms ≈ 3 ms tail latency added to every connect, in
# exchange for correctness under Channels' standard pattern.
_WS_QUIET_TICKS_BEFORE_RETURN = 3


def _acquire_http_state(
    app: Any,
    scope: dict[str, Any],
    initial_body: bytes,
    more_body: bool,
    keep_alive: bool,
) -> "_HttpState":
    if _http_state_pool:
        s = _http_state_pool.pop()
        s.reset(app, scope, initial_body, more_body, keep_alive)
        return s
    return _HttpState(app, scope, initial_body, more_body, keep_alive)


def _release_http_state(s: "_HttpState") -> None:
    if len(_http_state_pool) < _HTTP_POOL_MAX:
        # `task` and `out_headers` are released-by-reset on the next
        # acquire; we don't have to wipe them now. Just append.
        _http_state_pool.append(s)
    # v1.3: optional periodic gen-0 sweep. Cheap (~tens of µs), keeps
    # short-lived cyclic objects from accumulating in gen-1. No-op when
    # disabled (`gc_collect_every_n_requests=0`).
    if _gc_collect_every_n:
        global _dispatch_counter
        _dispatch_counter += 1
        if _dispatch_counter >= _gc_collect_every_n:
            _dispatch_counter = 0
            import gc as _gc
            _gc.collect(0)


class _HttpState:
    __slots__ = (
        # Single-slot mailbox: holds the next request event for the app's
        # `await receive()`. None when the queue is empty.
        "_pending_event",
        # When the app awaits receive() and there is no pending event, we
        # park it on this Future. The next `push_body` / `push_disconnect`
        # resolves it. Replaces v0.12's `asyncio.Queue` per request — saves
        # ~300 B of GC churn (Queue + internal deque + getters list) for
        # the typical request that does receive() once and is done.
        "_recv_future",
        "outgoing",
        # Running byte total of `outgoing` since the last drain. Drives the
        # `_HTTP_SEND_YIELD_BYTES` backpressure check in `_send` so a busy
        # streaming app yields back to the loop instead of pinning RAM.
        "_outgoing_bytes",
        "task",
        "status",
        "out_headers",
        "headers_sent",
        "chunked",
        "explicit_cl",
        "ka",
        "headers_done",
        "body_done",
        # ASGI HTTP trailers (`http.response.trailers`). True when the
        # app declared `trailers=True` on `http.response.start`. We then
        # delay the chunked terminator until the app emits the trailer
        # event (or finishes without one — RFC 7230 allows zero
        # trailers).
        "wants_trailers",
        # True once the first `http.response.trailers` event arrives —
        # we've written the `0\r\n` opener for the trailer section and
        # subsequent trailer events just append more header lines.
        "_trailer_started",
        # v1.3 X-Request-ID + Server-Timing support. Both default off
        # (and stay zero-cost when disabled at the module level).
        "_request_id",
        "_start_ns",
        # v1.3: HEAD requests get the same headers as GET but the body
        # is suppressed (RFC 7230 §3.3.3). Set in `http_dispatch_start`.
        "_is_head",
        # v1.4 sendfile path. When the app emits a `saltare.sendfile`
        # message, we stage headers but no body bytes — Zig opens the
        # file and `sendfile(2)`s it directly to the socket. Read by
        # the bridge via `http_dispatch_pop_sendfile()` after the
        # initial dispatch completes.
        "_sendfile_path",
        # v1.4 negotiated response encoding. b"" = identity (no
        # compression). b"gzip" / b"br" / b"zstd" otherwise. Picked at
        # request entry from `Accept-Encoding` and the operator-set
        # encoder flags. Used by `_send` to compress single-shot bodies
        # (and stream-init for chunked-streaming gzip) before headers
        # are emitted.
        "_negotiated_encoding",
        # v1.4 W3C Trace Context echo. Held as bytes (matches header
        # casing exactly when echoed back). Empty = no traceparent on
        # this request, no echo needed.
        "_traceparent_echo",
        # v1.4 streaming response gzip. Held as a `zlib.compressobj` (or
        # None when not streaming-compressed). When set, body chunks are
        # routed through `co.compress + co.flush(Z_SYNC_FLUSH)` before
        # the chunked transfer-encoding wrapper. The final chunk uses
        # `Z_FINISH` to flush the gzip trailer.
        "_gzip_co",
        # Cumulative pre/post-encode byte totals for the streaming
        # gzip path. Fired into `_core.compression_metric_inc` when
        # the stream closes (`more_body=False`).
        "_gzip_bytes_in",
        "_gzip_bytes_out",
        # v1.6 streaming brotli + zstd. Handles are opaque ints
        # holding `BrotliEncoderState*` / `ZSTD_CCtx*` cast to int.
        # 0 = no streaming compressor for this codec on this response.
        # `_codec_bytes_*` track cumulative ratios for /metrics.
        "_brotli_handle",
        "_zstd_handle",
        "_codec_bytes_in",
        "_codec_bytes_out",
    )

    def __init__(
        self,
        app: Any,
        scope: dict[str, Any],
        initial_body: bytes,
        more_body: bool,
        keep_alive: bool,
    ) -> None:
        # Initial request event sits in the mailbox; receive() pops it.
        self._pending_event: dict[str, Any] | None = {
            "type": "http.request",
            "body": initial_body,
            "more_body": more_body,
        }
        self._recv_future: asyncio.Future | None = None
        # Wire bytes produced by the app, drained by the I/O loop.
        self.outgoing: list[bytes] = []
        self._outgoing_bytes: int = 0
        self.wants_trailers: bool = False
        self._trailer_started: bool = False
        self._request_id: bytes = b""
        self._start_ns: int = 0
        self._is_head: bool = False
        self._sendfile_path: str = ""
        self._negotiated_encoding: bytes = b""
        self._traceparent_echo: bytes = b""
        self._gzip_co: Any = None
        self._gzip_bytes_in: int = 0
        self._gzip_bytes_out: int = 0
        self._brotli_handle: int = 0
        self._zstd_handle: int = 0
        self._codec_bytes_in: int = 0
        self._codec_bytes_out: int = 0
        # Filled in when http.response.start arrives.
        self.status: int = 500
        self.out_headers: list[tuple[bytes, bytes]] = []
        self.headers_sent: bool = False
        self.headers_done: bool = False
        # True once a body chunk with more_body=False has been processed.
        # _finalize_if_needed checks this to avoid emitting a duplicate
        # chunked terminator when the app already sent its last chunk.
        self.body_done: bool = False
        # Decided when the first http.response.body is observed (we need to
        # know if more chunks are coming to pick Content-Length vs chunked).
        self.chunked: bool = False
        self.explicit_cl: bool = False
        self.ka: bool = bool(keep_alive)

        loop = _ensure_loop()
        # `self._receive` and `self._send` are bound methods; they replace
        # the per-`__init__` closures used through v1.1. Bound methods
        # are about half the size of a closure (no per-instance cell
        # for the captured `self`) and they share the same underlying
        # compiled function across every instance — so for pooled
        # `_HttpState`s we don't even rebuild the compiled code.
        self.task: asyncio.Task = loop.create_task(
            app(scope, self._receive, self._send)
        )
        # The initial request event is already in `_pending_event`; the
        # app will pick it up on its first `await receive()`.

    async def _receive(self) -> dict[str, Any]:
        # Fast path: an event is already in the mailbox.
        ev = self._pending_event
        if ev is not None:
            self._pending_event = None
            return ev
        # Park on a Future; the next push_* will resolve it. Re-creating
        # the Future per await is unavoidable because asyncio's contract
        # is one-shot — but it's cheaper than a Queue + deque + getters.
        loop = asyncio.get_running_loop()
        self._recv_future = loop.create_future()
        try:
            return await self._recv_future
        finally:
            self._recv_future = None

    async def _send(self, message: dict[str, Any]) -> None:
        mtype = message.get("type")
        if mtype == "saltare.sendfile":
            # v1.4 ASGI extension. App emits this in lieu of
            # `http.response.start` + `http.response.body` to ask the
            # server to push a file directly via `sendfile(2)`. Zig
            # opens the file, fstat()s for the size, writes status +
            # headers (with `Content-Length` from the stat), then
            # `sendfile`s the body — bytes never enter Python.
            #
            # Required keys: path. Optional: status (default 200),
            # headers (default []). saltare adds `Content-Length`
            # from `fstat`; the app SHOULD NOT pre-declare one.
            if self.headers_done or self.headers_sent:
                return  # ASGI violation; can't switch mid-response
            path = message.get("path", "")
            if not isinstance(path, str) or not path:
                return
            self._sendfile_path = path
            self.status = int(message.get("status", 200))
            self.out_headers = list(message.get("headers", []))
            # We mark headers + body done so the dispatch loop returns
            # immediately; the actual headers + sendfile happen on
            # the Zig side after `http_dispatch_pop_sendfile()`.
            self.headers_done = True
            self.headers_sent = True
            self.body_done = True
            return
        if mtype == "http.response.start":
            if self.headers_done:
                return  # ASGI: ignore double-start
            self.status = int(message.get("status", 500))
            self.out_headers = list(message.get("headers", []))
            self.explicit_cl = any(
                name.lower() == b"content-length"
                for name, _ in self.out_headers
            )
            # ASGI 2.4: app may set `trailers=True` on the start message
            # to indicate it'll emit `http.response.trailers` after the
            # final body chunk. We force chunked transfer-encoding in
            # that case (Content-Length is incompatible with trailers).
            self.wants_trailers = bool(message.get("trailers", False))
            self.headers_done = True
        elif mtype == "http.response.trailers":
            # Trailers come AFTER all body chunks (the app must have
            # already sent body with `more_body=False`). We emit
            # `0\r\n<trailer headers>\r\n` to terminate the chunked
            # stream with trailer fields.
            if not self.headers_sent or not self.chunked:
                return  # ASGI violation
            trailer_headers = message.get("headers") or []
            more_trailers = bool(message.get("more_trailers", False))
            parts: list[bytes] = []
            # First trailer event prepends `0\r\n` to open the trailer
            # section. Subsequent events just append more header lines.
            if not self._trailer_started:
                parts.append(b"0\r\n")
                self._trailer_started = True
            for name, value in trailer_headers:
                parts.append(name + b": " + value + b"\r\n")
            if not more_trailers:
                parts.append(_CRLF)
                self.body_done = True
            joined = b"".join(parts)
            self.outgoing.append(joined)
            self._outgoing_bytes += len(joined)
        elif mtype == "http.response.body":
            chunk = message.get("body", b"") or b""
            more = bool(message.get("more_body", False))
            if not self.headers_sent:
                if not self.headers_done:
                    return  # ASGI violation; bail without crashing
                if not self._is_head and self._negotiated_encoding:
                    if not more and chunk and len(chunk) >= _response_gzip_min_bytes:
                        # Single-shot path: encode in one go, rewrite
                        # headers, no streaming state needed.
                        chunk = self._maybe_compress_response(chunk)
                    elif not more and chunk:
                        # Body smaller than the threshold — skip metric
                        # for visibility ("are we leaving compressible
                        # bytes on the table?" answerable from /metrics).
                        from saltare import _core as _c
                        _c.compression_metric_skip("small_body")
                    elif more and self._negotiated_encoding == b"gzip":
                        # Streaming gzip: per-chunk Z_SYNC_FLUSH +
                        # Z_FINISH at end.
                        self._maybe_init_streaming_gzip()
                    elif more and self._negotiated_encoding == b"br":
                        # v1.6 streaming brotli via libbrotli encoder
                        # state held across `_send` calls.
                        self._maybe_init_streaming_brotli()
                    elif more and self._negotiated_encoding == b"zstd":
                        # v1.6 streaming zstd via libzstd CCtx.
                        self._maybe_init_streaming_zstd()
                # HEAD: same headers as GET but no body. Force single-
                # shot mode (no chunked) and use the first chunk's
                # length as Content-Length unless the app explicitly
                # declared one.
                if self._is_head:
                    self._emit_headers(
                        streaming=False,
                        complete_body_len=len(chunk) if not self.explicit_cl else None,
                    )
                else:
                    self._emit_headers(
                        streaming=more,
                        complete_body_len=None if more else len(chunk),
                    )
                self.headers_sent = True
            if self._gzip_co is not None and not self._is_head:
                # Streaming gzip path. Z_SYNC_FLUSH per intermediate chunk
                # so decompressors see decoded bytes promptly; Z_FINISH on
                # the final chunk flushes the gzip trailer (CRC + isize).
                import zlib as _zlib
                self._gzip_bytes_in += len(chunk)
                if more:
                    encoded = self._gzip_co.compress(chunk) + self._gzip_co.flush(_zlib.Z_SYNC_FLUSH)
                else:
                    encoded = self._gzip_co.compress(chunk) + self._gzip_co.flush(_zlib.Z_FINISH)
                self._gzip_bytes_out += len(encoded)
                chunk = encoded
                if not more:
                    # End of stream — record the cumulative ratio.
                    from saltare import _core as _c
                    _c.compression_metric_inc("gzip", self._gzip_bytes_in, self._gzip_bytes_out)
            elif self._brotli_handle and not self._is_head:
                from saltare import _core as _c
                self._codec_bytes_in += len(chunk)
                encoded = _c.brotli_stream_compress(self._brotli_handle, chunk, not more) or b""
                self._codec_bytes_out += len(encoded)
                chunk = encoded
                if not more:
                    _c.brotli_stream_destroy(self._brotli_handle)
                    _c.compression_metric_inc("br", self._codec_bytes_in, self._codec_bytes_out)
                    self._brotli_handle = 0
            elif self._zstd_handle and not self._is_head:
                from saltare import _core as _c
                self._codec_bytes_in += len(chunk)
                encoded = _c.zstd_stream_compress(self._zstd_handle, chunk, not more) or b""
                self._codec_bytes_out += len(encoded)
                chunk = encoded
                if not more:
                    _c.zstd_stream_destroy(self._zstd_handle)
                    _c.compression_metric_inc("zstd", self._codec_bytes_in, self._codec_bytes_out)
                    self._zstd_handle = 0
            if chunk and not self._is_head:
                if self.chunked:
                    framed = _encode_chunk(chunk)
                    self.outgoing.append(framed)
                    self._outgoing_bytes += len(framed)
                else:
                    self.outgoing.append(chunk)
                    self._outgoing_bytes += len(chunk)
            if not more:
                if self._is_head:
                    # HEAD: no body, no chunked terminator.
                    self.body_done = True
                elif self.chunked:
                    if self.wants_trailers:
                        # Defer the chunked terminator until the app
                        # emits `http.response.trailers` (or finishes
                        # without one — handled in `_finalize_if_needed`).
                        # body_done stays False so finalize closes us.
                        pass
                    else:
                        self.outgoing.append(_CHUNKED_TERMINATOR)
                        self._outgoing_bytes += len(_CHUNKED_TERMINATOR)
                        self.body_done = True
                else:
                    self.body_done = True
            # Backpressure: if a streaming app has accumulated more than
            # `_HTTP_SEND_YIELD_BYTES` since the last drain, hand control
            # back to the event loop. The Zig main loop's stalled-pump
            # path harvests via `http_dispatch_drain`, which clears
            # `_outgoing_bytes` and lets us keep producing without
            # pinning unbounded RAM. Skipped on the final chunk so a
            # one-shot response never pays the yield cost.
            if more and self._outgoing_bytes >= _HTTP_SEND_YIELD_BYTES:
                await asyncio.sleep(0)
        # Ignored message types (http.response.trailers etc.) silently drop.

    def _maybe_init_streaming_gzip(self) -> None:
        """Set up streaming gzip when the response is chunked + the request
        accepted gzip. Builds a `zlib.compressobj` (wbits=31 for gzip wrap),
        rewrites `out_headers` to drop CL/CE, append `Content-Encoding:
        gzip` + `Vary: Accept-Encoding`, and clears `explicit_cl` so the
        chunked path is engaged in `_emit_headers`.

        Bails silently when the content-type is non-compressible or the app
        already set Content-Encoding."""
        ctype = b""
        for name, value in self.out_headers:
            if name.lower() == b"content-type":
                ctype = value
                break
        if not _is_gzippable_content_type(ctype):
            return
        for name, _value in self.out_headers:
            if name.lower() == b"content-encoding":
                return
        import zlib as _zlib
        try:
            co = _zlib.compressobj(_response_gzip_level, _zlib.DEFLATED, 31)
        except Exception:
            return
        # Rewrite headers identical to the single-shot path.
        new_headers: list[tuple[bytes, bytes]] = []
        have_vary = False
        for name, value in self.out_headers:
            ln = name.lower()
            if ln == b"content-length" or ln == b"content-encoding":
                continue
            if ln == b"vary":
                if b"accept-encoding" not in value.lower():
                    value = value + b", Accept-Encoding"
                have_vary = True
            new_headers.append((name, value))
        new_headers.append((b"content-encoding", b"gzip"))
        if not have_vary:
            new_headers.append((b"vary", b"Accept-Encoding"))
        self.out_headers = new_headers
        self.explicit_cl = False
        self._gzip_co = co

    def _maybe_init_streaming_brotli(self) -> None:
        """v1.6 streaming brotli. Mirrors `_maybe_init_streaming_gzip`
        but uses `_core.brotli_stream_*` (libbrotli encoder state via
        Zig handle). Bails silently on non-compressible content-type
        or libbrotli-not-loadable."""
        if not self._compressible_for_streaming():
            return
        from saltare import _core as _c
        handle = _c.brotli_stream_create(_response_brotli_quality)
        if handle is None:
            from saltare import _core as _c2
            _c2.compression_metric_skip("encoder_unavailable")
            return
        self._brotli_handle = handle
        self._rewrite_headers_for_streaming(b"br")

    def _maybe_init_streaming_zstd(self) -> None:
        """v1.6 streaming zstd via libzstd CCtx."""
        if not self._compressible_for_streaming():
            return
        from saltare import _core as _c
        handle = _c.zstd_stream_create(_response_zstd_level)
        if handle is None:
            from saltare import _core as _c2
            _c2.compression_metric_skip("encoder_unavailable")
            return
        self._zstd_handle = handle
        self._rewrite_headers_for_streaming(b"zstd")

    def _compressible_for_streaming(self) -> bool:
        """True iff the response Content-Type is in the compressible
        set AND the app didn't already declare a `Content-Encoding`."""
        ctype = b""
        for name, value in self.out_headers:
            if name.lower() == b"content-type":
                ctype = value
                break
        if not _is_gzippable_content_type(ctype):
            return False
        for name, _value in self.out_headers:
            if name.lower() == b"content-encoding":
                return False
        return True

    def _rewrite_headers_for_streaming(self, encoding: bytes) -> None:
        """Drop CL / pre-existing CE, append `Content-Encoding: <enc>`
        + `Vary: Accept-Encoding`. Common to all streaming codecs."""
        new_headers: list[tuple[bytes, bytes]] = []
        have_vary = False
        for name, value in self.out_headers:
            ln = name.lower()
            if ln == b"content-length" or ln == b"content-encoding":
                continue
            if ln == b"vary":
                if b"accept-encoding" not in value.lower():
                    value = value + b", Accept-Encoding"
                have_vary = True
            new_headers.append((name, value))
        new_headers.append((b"content-encoding", encoding))
        if not have_vary:
            new_headers.append((b"vary", b"Accept-Encoding"))
        self.out_headers = new_headers
        self.explicit_cl = False

    def _maybe_compress_response(self, chunk: bytes) -> bytes:
        """Single-shot encode `chunk` according to `self._negotiated_encoding`
        (b"gzip" / b"br" / b"zstd"). Mutates `self.out_headers` to drop
        any pre-existing Content-Length / Content-Encoding and to append
        `Content-Encoding: <enc>` + `Vary: Accept-Encoding`.

        Returns the (possibly unchanged) chunk. Falls through silently
        on libload failure (no encode applied; client sees raw body —
        legal because the encoding was an offered preference)."""
        enc = self._negotiated_encoding
        if not enc:
            return chunk
        ctype = b""
        for name, value in self.out_headers:
            if name.lower() == b"content-type":
                ctype = value
                break
        from saltare import _core
        if not _is_gzippable_content_type(ctype):
            _core.compression_metric_skip("non_compressible")
            return chunk
        # Skip if app already encoded it (e.g. upstream brotli or
        # nginx-side encoding).
        for name, _value in self.out_headers:
            if name.lower() == b"content-encoding":
                _core.compression_metric_skip("non_compressible")
                return chunk
        if enc == b"gzip":
            encoded = _core.gzip_encode(chunk, _response_gzip_level)
        elif enc == b"br":
            encoded = _core.brotli_encode(chunk, _response_brotli_quality)
        elif enc == b"zstd":
            encoded = _core.zstd_encode(chunk, _response_zstd_level)
        else:
            return chunk
        if encoded is None:
            _core.compression_metric_skip("encoder_unavailable")
            return chunk
        if len(encoded) >= len(chunk):
            _core.compression_metric_skip("not_smaller")
            return chunk
        _core.compression_metric_inc(enc.decode("ascii"), len(chunk), len(encoded))
        # Rewrite headers: drop CL / CE, append our own + Vary.
        new_headers: list[tuple[bytes, bytes]] = []
        have_vary = False
        for name, value in self.out_headers:
            ln = name.lower()
            if ln == b"content-length" or ln == b"content-encoding":
                continue
            if ln == b"vary":
                if b"accept-encoding" not in value.lower():
                    value = value + b", Accept-Encoding"
                have_vary = True
            new_headers.append((name, value))
        new_headers.append((b"content-encoding", enc))
        if not have_vary:
            new_headers.append((b"vary", b"Accept-Encoding"))
        self.out_headers = new_headers
        # We dropped the app's CL — `_emit_headers` will re-emit one
        # from `complete_body_len`.
        self.explicit_cl = False
        return encoded

    def reset(
        self,
        app: Any,
        scope: dict[str, Any],
        initial_body: bytes,
        more_body: bool,
        keep_alive: bool,
    ) -> None:
        """Reuse this `_HttpState` for a new request after pulling it from
        the module-level pool. Every slot is rewritten so nothing leaks
        from the previous request. Identical effect to constructing a
        fresh instance, just without the slot-allocation churn."""
        self._pending_event = {
            "type": "http.request",
            "body": initial_body,
            "more_body": bool(more_body),
        }
        self._recv_future = None
        # Reuse the existing list — `clear()` is in-place; no new list
        # allocation. Marginal but cumulative across requests.
        self.outgoing.clear()
        self._outgoing_bytes = 0
        self.wants_trailers = False
        self._trailer_started = False
        self._request_id = b""
        self._start_ns = 0
        self._is_head = False
        self._sendfile_path = ""
        self._negotiated_encoding = b""
        self._traceparent_echo = b""
        # If a previous use left an encoder handle live (defensive —
        # `_send` should always finalise it), free it before reset.
        if self._brotli_handle:
            from saltare import _core as _c
            _c.brotli_stream_destroy(self._brotli_handle)
        if self._zstd_handle:
            from saltare import _core as _c
            _c.zstd_stream_destroy(self._zstd_handle)
        self._gzip_co = None
        self._gzip_bytes_in = 0
        self._gzip_bytes_out = 0
        self._brotli_handle = 0
        self._zstd_handle = 0
        self._codec_bytes_in = 0
        self._codec_bytes_out = 0
        self.status = 500
        self.out_headers = []
        self.headers_sent = False
        self.headers_done = False
        self.body_done = False
        self.chunked = False
        self.explicit_cl = False
        self.ka = bool(keep_alive)

        loop = _ensure_loop()
        self.task = loop.create_task(app(scope, self._receive, self._send))

    def _emit_headers(
        self, streaming: bool, complete_body_len: int | None
    ) -> None:
        parts: list[bytes] = [
            _status_line(self.status),
            _SERVER_LINE,
            _CONNECTION_KEEPALIVE_LINE if self.ka else _CONNECTION_CLOSE_LINE,
        ]
        # v1.3: optional X-Request-ID + Server-Timing. Both gates are
        # module-level and read once per response — when off, two
        # `is None`/`if not` checks per request.
        if self._request_id and _request_id_header is not None:
            parts.append(_request_id_header + b": " + self._request_id + b"\r\n")
        if self._traceparent_echo:
            parts.append(b"traceparent: " + self._traceparent_echo + b"\r\n")
        if _hsts_header_line:
            parts.append(_hsts_header_line)
        if _server_timing_enabled and self._start_ns:
            import time
            elapsed_ms = (time.monotonic_ns() - self._start_ns) / 1_000_000.0
            parts.append(
                f"server-timing: total;dur={elapsed_ms:.2f}\r\n".encode("ascii")
            )

        if streaming:
            if self.explicit_cl:
                # App declared length: trust it and emit raw.
                self.chunked = False
            else:
                # Streaming with no declared length → chunked encoding.
                self.chunked = True
        else:
            # Single-shot (more_body=False on the first body chunk).
            if not self.explicit_cl:
                parts.append(
                    f"content-length: {complete_body_len or 0}\r\n".encode("ascii")
                )

        for name, value in self.out_headers:
            lname = name.lower()
            # saltare owns Connection and (when chunked) Transfer-Encoding.
            if lname == b"connection":
                continue
            if self.chunked and lname == b"transfer-encoding":
                continue
            parts.append(name + b": " + value + b"\r\n")

        if self.chunked:
            parts.append(_TRANSFER_ENCODING_CHUNKED_LINE)

        parts.append(_CRLF)
        self.outgoing.extend(parts)

    def push_body(self, body: bytes, more_body: bool) -> None:
        self._deliver({"type": "http.request", "body": body, "more_body": more_body})

    def push_disconnect(self) -> None:
        self._deliver({"type": "http.disconnect"})

    def _deliver(self, event: dict[str, Any]) -> None:
        """Hand `event` to the app's pending `await receive()`. If a Future
        is parked we resolve it directly (the app resumes on the next loop
        tick); otherwise the event sits in the mailbox until receive() is
        called. Mirrors the old `asyncio.Queue.put_nowait` semantics
        without the queue."""
        fut = self._recv_future
        if fut is not None and not fut.done():
            fut.set_result(event)
        else:
            self._pending_event = event

    def drain(self) -> bytes:
        if not self.outgoing:
            return b""
        out = b"".join(self.outgoing)
        self.outgoing.clear()
        self._outgoing_bytes = 0
        return out


def _finalize_if_needed(handle: int, s: _HttpState) -> bytes:
    """If the app finished without ever emitting headers/body, synthesize
    a 500 so the wire is a valid HTTP response. Otherwise, if it sent
    headers but never sent a final more_body=False, close out the chunked
    stream. Returns extra wire bytes to append."""
    extra = b""
    if not s.headers_sent:
        # App returned without responding at all → 500.
        extra = _build_wire(
            500,
            [(b"content-type", b"text/plain; charset=utf-8")],
            b"Internal Server Error\n",
            keep_alive=False,
        )
    elif s.chunked and not s.body_done:
        # App finished but didn't close the chunked stream cleanly.
        # If a trailer section was opened (`_trailer_started`), we just
        # need the section-terminator `\r\n`. Otherwise emit the full
        # `0\r\n\r\n` terminator.
        if s._trailer_started:
            extra = _CRLF
        else:
            extra = _CHUNKED_TERMINATOR
    return extra


def http_dispatch_start(
    app: Any,
    method: str,
    raw_path: bytes,
    decoded_path: bytes,
    query_string: bytes,
    raw_headers: list[tuple[bytes, bytes]],
    initial_body: bytes,
    more_body: int,
    server_host: str,
    server_port: int,
    keep_alive: int,
    scheme: str,
) -> tuple[int, bytes, bool]:
    """Begin a streaming dispatch. Returns (handle, initial_chunks, done).

    handle:         opaque int Zig keeps for subsequent push_body / tick / abort calls.
    initial_chunks: any wire bytes the app produced before suspending. For
                    fast non-streaming apps this is the *full* response.
    done:           True if the Task finished in this initial pump.
    """
    state_obj = _ensure_state()

    try:
        path = decoded_path.decode("utf-8")
    except UnicodeDecodeError:
        return (
            0,
            _build_wire(400, [], b"path is not valid UTF-8\n", keep_alive=False),
            True,
        )

    # Header names are already lowercased by the bridge (`buildHeadersList`
    # lowercases in-place in Zig before building the PyBytes list), so the
    # dispatcher can iterate `raw_headers` directly without an extra
    # `.lower()` pass and the per-header tuple rebuild it forced.
    headers = raw_headers
    effective_scheme = scheme
    effective_client: tuple[str, int] | None = None
    effective_server: tuple[str, int] = (server_host, server_port)

    if _proxy_headers_enabled:
        effective_scheme, effective_client, effective_server = _apply_proxy_headers(
            headers, scheme, server_host, server_port,
        )

    # v1.3: synthesise the request ID up front so the app sees it in
    # scope (as `scope["x-request-id"]`) AND `_emit_headers` can echo
    # it as a response header. Generating in Python (vs Zig + bridge
    # marshal) keeps the code path simple; `os.urandom(8).hex()` is a
    # ~200 ns syscall on a sane Linux box.
    req_id_bytes: bytes = b""
    if _request_id_header is not None:
        import os as _os
        req_id_bytes = _os.urandom(8).hex().encode("ascii")

    scope: dict[str, Any] = {
        "type": "http",
        "asgi": _ASGI_HTTP_SUB,
        "http_version": "1.1",
        "method": method,
        "scheme": effective_scheme,
        "path": path,
        "raw_path": raw_path,
        "query_string": query_string,
        "headers": headers,
        "server": effective_server,
        "client": effective_client,
        "root_path": "",
        # ASGI 3.0 — shared lifespan state + extensions marker dict.
        # Both are required reads by uvicorn-compatible middleware
        # (Django Channels' `AuthMiddlewareStack`, FastAPI lifespan
        # helpers, custom auth that stashes a session pool in state
        # during startup).
        "state": state_obj.asgi_state,
        "extensions": _SCOPE_EXTENSIONS,
    }
    if req_id_bytes:
        # ASGI extension key — apps grab it via scope["x-request-id"].
        # Stored as str (decoded) for ergonomic Python access.
        scope["x-request-id"] = req_id_bytes.decode("ascii")

    # v1.4 W3C Trace Context. When opt-in via `set_traceparent_propagation`
    # we surface `traceparent` (and `tracestate` if present) on `scope`
    # for downstream handlers / OpenTelemetry instrumentations to pick up
    # without parsing headers themselves, and we'll echo `traceparent`
    # on the response in `_emit_headers`. We don't validate the format
    # (32-hex-trace-id + 16-hex-span-id + flags) — invalid values are
    # passed through unchanged so the app can decide.
    traceparent_bytes: bytes = b""
    if _traceparent_propagation:
        for name, value in headers:
            if name == b"traceparent":
                # W3C says traceparent is a fixed 55 chars
                # (`00-<32hex>-<16hex>-<2hex>`). Length cap defends
                # the response-header echo path against an
                # adversarial client trying to bloat the response or
                # smuggle bytes — anything past 256 B we still
                # surface on `scope` for the app to inspect, but
                # we don't echo it back.
                if len(value) <= 256:
                    traceparent_bytes = value
                try:
                    scope["traceparent"] = value.decode("ascii")
                except UnicodeDecodeError:
                    pass
            elif name == b"tracestate":
                try:
                    scope["tracestate"] = value.decode("ascii")
                except UnicodeDecodeError:
                    pass

    # v1.4 zlib wiring — pre-dispatch peek at the headers for the two
    # negotiation decisions:
    #   1. `Accept-Encoding: ...gzip...` → flag the state so single-shot
    #      responses get gzipped before headers are emitted.
    #   2. `Content-Encoding: gzip` (with `more_body=False`) → decompress
    #      the body in place; strip the encoding header from `scope` so
    #      the app sees the decompressed bytes as if uncompressed.
    negotiated_encoding = b""
    if _response_gzip_enabled or _response_brotli_enabled or _response_zstd_enabled:
        for name, value in headers:
            if name == b"accept-encoding":
                negotiated_encoding = _negotiate_encoding(value)
                break
    if (
        _request_decompress_enabled
        and not more_body
        and initial_body
    ):
        for i, (name, value) in enumerate(headers):
            if name == b"content-encoding":
                if value.strip().lower() == b"gzip":
                    from saltare import _core
                    decoded = _core.gunzip(initial_body, _request_decompress_cap)
                    if decoded is None:
                        # Either libz unavailable or payload exceeded the
                        # cap / was malformed. The latter cases are far
                        # more common — return 413 (over cap is the
                        # expected guard) rather than guessing.
                        return (
                            0,
                            _build_wire(
                                413, [], b"compressed body exceeds cap or invalid\n",
                                keep_alive=False,
                            ),
                            True,
                        )
                    initial_body = decoded
                    # Strip Content-Encoding so the app doesn't try to
                    # double-decode; rebuild the headers list with that
                    # one entry removed.
                    headers = headers[:i] + headers[i + 1 :]
                    scope["headers"] = headers
                break

    handle = state_obj.next_http_handle
    state_obj.next_http_handle += 1

    s = _acquire_http_state(app, scope, initial_body, bool(more_body), bool(keep_alive))
    s._request_id = req_id_bytes
    s._is_head = (method == "HEAD")
    s._negotiated_encoding = negotiated_encoding
    s._traceparent_echo = traceparent_bytes
    if _server_timing_enabled:
        import time as _time
        s._start_ns = _time.monotonic_ns()
    state_obj.http_states[handle] = s

    try:
        _pump_once()
    except BaseException:
        _print_exception_lazy(*sys.exc_info())

    chunks = s.drain()
    done = s.task.done()

    if done:
        # Surface any task exception so it isn't silently swallowed.
        if not s.task.cancelled():
            exc = s.task.exception()
            if exc is not None:
                _print_exception_lazy(type(exc), exc, exc.__traceback__)
                # If we never emitted a response, give the client a 500.
                if not s.headers_sent:
                    chunks = chunks + _build_wire(
                        500,
                        [(b"content-type", b"text/plain; charset=utf-8")],
                        b"Internal Server Error\n",
                        keep_alive=False,
                    )
                    state_obj.http_states.pop(handle, None)
                    _release_http_state(s)
                    return (handle, chunks, True)
        chunks += _finalize_if_needed(handle, s)
        # Stash any sendfile request before releasing the state — the
        # bridge calls `http_dispatch_pop_sendfile(handle)` AFTER the
        # state has been released back to the pool. Pool reset would
        # otherwise zero `_sendfile_path` and the bridge would see an
        # empty path → fall through to the normal write path → close
        # without writing anything.
        if s._sendfile_path:
            _pending_sendfiles[handle] = (s._sendfile_path, s.status, s.out_headers, bool(s.ka))
        state_obj.http_states.pop(handle, None)
        _release_http_state(s)

    return (handle, chunks, done)


# v1.4 sendfile stash. `http_dispatch_pop_sendfile` is called AFTER
# the state has been released to the pool; the path needs to live
# somewhere keyed by handle. Plain dict (handle → tuple); cleared by
# the pop fn so it doesn't grow unbounded.
_pending_sendfiles: dict[int, tuple[str, int, list[tuple[bytes, bytes]], bool]] = {}


def http_dispatch_push_body(
    handle: int, body: bytes, more_body: int
) -> tuple[bytes, bool]:
    """Push more request-body bytes into the running Task. Pumps once and
    returns (chunks, done)."""
    state_obj = _ensure_state()
    s = state_obj.http_states.get(handle)
    if s is None or s.task.done():
        return (b"", True)

    s.push_body(body, bool(more_body))

    try:
        _pump_once()
    except BaseException:
        _print_exception_lazy(*sys.exc_info())

    chunks = s.drain()
    done = s.task.done()

    if done:
        if not s.task.cancelled():
            exc = s.task.exception()
            if exc is not None:
                _print_exception_lazy(type(exc), exc, exc.__traceback__)
        chunks += _finalize_if_needed(handle, s)
        state_obj.http_states.pop(handle, None)
        _release_http_state(s)

    return (chunks, done)


def http_dispatch_drain(handle: int) -> tuple[bytes, bool]:
    """Return any wire bytes the request's Task has emitted since the last
    drain, *without* pumping the asyncio loop. Used by the Zig server loop
    after a global pump to harvest output from each stalled connection
    without paying the per-connection pump cost.

    Returns (chunks, done). When `done`, the handle is freed.
    """
    state_obj = _ensure_state()
    s = state_obj.http_states.get(handle)
    if s is None or s.task.done():
        # Either never existed (stale handle) or already finished. If
        # finished but state still around (race), drain it now.
        if s is not None and s.task.done():
            chunks = s.drain()
            if not s.task.cancelled():
                exc = s.task.exception()
                if exc is not None:
                    _print_exception_lazy(type(exc), exc, exc.__traceback__)
            chunks += _finalize_if_needed(handle, s)
            state_obj.http_states.pop(handle, None)
            _release_http_state(s)
            return (chunks, True)
        return (b"", True)

    chunks = s.drain()
    done = s.task.done()

    if done:
        if not s.task.cancelled():
            exc = s.task.exception()
            if exc is not None:
                _print_exception_lazy(type(exc), exc, exc.__traceback__)
        chunks += _finalize_if_needed(handle, s)
        state_obj.http_states.pop(handle, None)
        _release_http_state(s)

    return (chunks, done)


def http_dispatch_pop_sendfile(handle: int) -> tuple[str, int, list[tuple[bytes, bytes]], bool]:
    """v1.4: query whether a completed dispatch resolved to a
    `saltare.sendfile` ASGI extension. Returns `(path, status,
    headers, keep_alive)`. `path` is empty when the app didn't ask
    for sendfile — caller should fall back to the normal write path.
    Called by the bridge once after `http_dispatch_start`/`drain`
    returned `done=True`."""
    return _pending_sendfiles.pop(handle, ("", 0, [], False))


def http_dispatch_abort(handle: int) -> None:
    """Connection went away mid-stream. Cancel the Task and free state."""
    state_obj = _ensure_state()
    # Defensive cleanup — if the bridge stashed a sendfile request but
    # the connection dropped before serveSendfile pulled it out, the
    # stash entry would otherwise leak forever (handle counter never
    # rolls back). Pop unconditionally; absent key is fine.
    _pending_sendfiles.pop(handle, None)
    s = state_obj.http_states.pop(handle, None)
    if s is None:
        return

    if not s.task.done():
        s.push_disconnect()
        try:
            _pump_once()
        except BaseException:
            pass
    if not s.task.done():
        s.task.cancel()
        try:
            _pump_once()
        except BaseException:
            pass


def _build_wire(
    status: int,
    headers: list[tuple[bytes, bytes]],
    body: bytes,
    *,
    keep_alive: bool,
) -> bytes:
    """Build a single-shot HTTP/1.1 response. Used for synthesized error
    responses (saltare-emitted 4xx/5xx); the streaming dispatcher emits
    its own wire bytes incrementally."""
    parts: list[bytes] = [
        _status_line(status),
        _SERVER_LINE,
        _CONNECTION_KEEPALIVE_LINE if keep_alive else _CONNECTION_CLOSE_LINE,
    ]

    has_content_length = False
    for name, value in headers:
        if name.lower() == b"connection":
            continue
        if name.lower() == b"content-length":
            has_content_length = True
        parts.append(name + b": " + value + b"\r\n")

    if not has_content_length:
        parts.append(f"content-length: {len(body)}\r\n".encode("ascii"))

    parts.append(_CRLF)
    parts.append(body)
    return b"".join(parts)
