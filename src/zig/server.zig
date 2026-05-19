// Saltare network core (v0.11).
//
// Single-threaded non-blocking event loop on top of epoll, with HTTP/1.1
// keep-alive, a shared pool for read buffers, and per-connection idle
// timeouts driven by a hashed timer wheel. RSS scales with the number of
// *in-flight* requests rather than the number of *open keep-alive
// connections*; slow / stuck clients cannot pin Connection structs in
// memory because the timer wheel reaps them.
//
// Out of scope (planned for later):
//   - write-buffer size cap / streaming response bodies (v0.12+)
//   - multi-worker (v1.0)
//   - kqueue backend for macOS — see eventloop.zig's compileError

const std = @import("std");
const builtin = @import("builtin");
const http = @import("http.zig");
const bridge = @import("bridge.zig");
const eventloop = @import("eventloop.zig");
const pool_mod = @import("pool.zig");
const tls = @import("tls.zig");
const ws = @import("ws.zig");
const timer = @import("timer.zig");

const c = @cImport({
    // sys/types.h first so musl's `bits/types/struct_timespec.h` /
    // `bits/types/struct_stat.h` get pulled in transitively. Without
    // this, Zig's translate-c reports both as opaque under musllinux
    // (glibc inlines them in time.h / sys/stat.h directly).
    @cInclude("sys/types.h");
    @cInclude("sys/socket.h");
    @cInclude("netinet/in.h");
    @cInclude("netinet/tcp.h");
    @cInclude("sys/un.h");
    @cInclude("sys/resource.h");
    @cInclude("sys/sendfile.h");
    @cInclude("sys/stat.h");
    @cInclude("unistd.h");
    @cInclude("signal.h");
    @cInclude("fcntl.h");
    @cInclude("time.h");
    @cInclude("arpa/inet.h");
    @cInclude("dirent.h");
});

// accept4 is a Linux/glibc extension. Defining _GNU_SOURCE in the @cImport
// would expose it but also pulls in glibc's `__CONST_SOCKADDR_ARG`
// transparent-union magic, which breaks `bind()` translation. Declaring
// the prototype ourselves keeps the rest of the cimport clean.
extern fn accept4(
    sockfd: c_int,
    addr: ?*anyopaque,
    addrlen: ?*c_uint,
    flags: c_int,
) c_int;

// glibc-only. `extern fn` would fail to resolve at .so load time on
// musl (musllinux wheel target), so we look up the symbol via
// `dlsym(RTLD_DEFAULT, ...)` lazily; missing → no-op.
const dl_server = @cImport({
    @cInclude("dlfcn.h");
});
const MallocTrim = *const fn (usize) callconv(.c) c_int;
var g_malloc_trim_server: ?MallocTrim = null;
var g_malloc_trim_probed: bool = false;
fn malloc_trim(pad: usize) c_int {
    if (!g_malloc_trim_probed) {
        g_malloc_trim_probed = true;
        const sym = dl_server.dlsym(null, "malloc_trim");
        if (sym != null) g_malloc_trim_server = @ptrCast(@alignCast(sym));
    }
    if (g_malloc_trim_server) |fp| return fp(pad);
    return 0; // musl path: no-op, succeed silently
}

const SERVER_HEADER = "saltare/1.6.0";

/// Per-connection deadlines, in seconds. Set by `run()` for the duration of
/// one `serve()` call. Defaults match what the Python `saltare.run()`
/// wrapper passes when the user provides nothing.
pub const Timeouts = struct {
    /// From accept (or TLS handshake start) to "headers fully parsed".
    /// Bounds the slowloris window.
    header_secs: u32 = 5,
    /// Between requests on a keep-alive connection. After this many seconds
    /// of inactivity following a response, the connection is closed.
    keep_alive_secs: u32 = 5,
    /// From "headers parsed" to "body fully received". Bounds slow-body
    /// attacks (drip-feeding chunked or Content-Length bodies).
    body_secs: u32 = 30,
    /// Maximum time spent in the .writing state. A client that won't drain
    /// the response (won't read its socket) cannot pin a write buffer
    /// indefinitely.
    write_secs: u32 = 30,
    /// Maximum seconds the I/O loop will keep running after SIGTERM/SIGINT
    /// before forcing exit. Used for k8s/systemd rolling deploys: in-flight
    /// requests get to finish; after this many seconds, the process exits
    /// regardless. Idle keep-alive connections drain via `keep_alive_secs`.
    shutdown_secs: u32 = 30,
    /// Server-side WebSocket keepalive interval. Every this many seconds
    /// saltare sends an empty `ping` frame to each open WS connection. If
    /// no inbound frame (including the resulting `pong`) is observed in
    /// `2 * ws_keepalive_secs`, the connection is torn down. Bounds the
    /// RAM cost of long-lived WS sockets that have silently disconnected
    /// (e.g. NAT timeouts, mobile network drops).
    ws_keepalive_secs: u32 = 20,
};

/// Optional observability hooks. Each off by default so the v0.15 release
/// doesn't change the RAM floor for users who don't ask for it.
pub const Observability = struct {
    /// If non-null, requests whose path equals this string are intercepted
    /// in Zig and answered with a Prometheus-format text dump of saltare's
    /// counters. The user app never sees the request. A common choice:
    /// "/metrics".
    metrics_path: ?[]const u8 = null,
    /// If non-null, requests whose path equals this string get a fixed
    /// 200 OK + body "ok\n" answered entirely from Zig — no Python
    /// dispatch, no FastAPI overhead. v1.3 addition for k8s liveness /
    /// readiness probes that hit hard, often (every few seconds), and
    /// don't need the full ASGI stack to serve. A common choice: "/healthz".
    health_path: ?[]const u8 = null,
    /// If true, every completed request emits a one-line JSON record to
    /// stderr (method, path, status, bytes_sent, latency_us, user_agent).
    /// Off by default — when off, zero work happens per request.
    access_log: bool = false,
    /// If non-null, JSON access-log lines go to this file path instead
    /// of stderr. The file is opened with `O_WRONLY | O_APPEND |
    /// O_CREAT | O_CLOEXEC` and the fd is closed at server shutdown.
    /// External log rotation (logrotate's `copytruncate`, or
    /// `mv + reload`) won't be picked up — saltare doesn't reopen mid-
    /// run. Best-effort: any open() failure logs once to stderr and
    /// falls back to stderr writes.
    access_log_path: ?[]const u8 = null,
    /// v1.6 access-log path-filter list. Each entry is matched exactly
    /// against `req.target` (request-line target, including query string
    /// if present); a hit skips the log line for that request. Useful
    /// for muting noisy probes (`/metrics`, `/healthz`, `/favicon.ico`,
    /// `/admin/drain`, `/debug/dispatch`) without losing app-traffic
    /// visibility. Empty slice = no filtering (every request logged).
    /// The CSV is split at run() time and stored as a slice of slices;
    /// per-request cost is one linear scan, bounded by the entry count
    /// (typically <10).
    access_log_exclude: []const []const u8 = &.{},
    /// v1.7 — when true, emit a single stderr line every time a WS
    /// upgrade is rejected (the app emitted `websocket.close` before
    /// `websocket.accept`, or its `connect` coroutine raised). Line
    /// shape: `saltare: ws-reject path=<url> code=<int> reason=<...>`.
    /// Operational diagnostic for Channels' Origin/Host/Auth middleware
    /// rejecting connects — without it operators couldn't see *why*.
    /// Off by default (zero overhead when off).
    ws_reject_log: bool = false,
    /// If true, the dispatcher honours `X-Forwarded-For` /
    /// `X-Forwarded-Proto` from the request to populate `scope["client"]`
    /// and `scope["scheme"]`. Only enable behind a trusted reverse proxy
    /// that strips client-supplied X-Forwarded-* headers — otherwise
    /// clients can spoof their address.
    proxy_headers: bool = false,
    /// If true, OPTIONS requests bearing an `Origin` header are answered
    /// from Zig with permissive CORS headers (`Access-Control-Allow-
    /// Origin: *`, common methods + headers). Skips Python dispatch for
    /// preflight requests, which is useful for browser-heavy SPAs that
    /// fire one preflight per cross-origin route. Off by default; only
    /// enable if your app's CORS policy actually IS permissive — Zig
    /// doesn't read your app's allow-list.
    cors_preflight_allow_all: bool = false,
    /// If true, the first line of every accepted connection is parsed
    /// as a HAProxy PROXY-protocol v1 header (`PROXY TCP4 src dst sport
    /// dport\r\n`) OR a v2 binary header (`\r\n\r\n\0\r\nQUIT\n` +
    /// 12-byte signature + variable payload). Auto-detects via the
    /// first 12 bytes. The src address replaces the TCP peer for rate
    /// limiting + access logging — required when saltare sits behind a
    /// L4 load balancer (AWS NLB / ALB, HAProxy, GCP TCP LB) that
    /// won't add HTTP headers like `X-Forwarded-For`. Connections
    /// that don't start with a valid header get closed immediately.
    proxy_protocol: bool = false,
    /// Optional override for the `Server:` response header. `null`
    /// keeps the saltare default (`saltare/<version>`); empty string
    /// omits the header entirely (useful for white-label deployments
    /// or to hide the server identity). The override is built once
    /// at server start and stored in `g_server_line`; per-response
    /// cost is a single `{s}` substitution.
    server_header: ?[]const u8 = null,
    /// If true, saltare issues an internal `GET /` to the user app
    /// after `lifespan.startup` completes — warms FastAPI route
    /// compilation, pydantic validators, etc. — so the first real
    /// client request doesn't pay the cold-start cost. Skipped if
    /// the app responds non-2xx (we don't want a buggy startup to
    /// look like a successful warm).
    startup_request: bool = false,
    /// If non-null, requests to this path return a top-N tracemalloc
    /// dump (Python heap allocations grouped by source line). Setting
    /// this also auto-enables `tracemalloc.start()` at startup so the
    /// snapshots are populated. Diagnostic only — leak hunts in
    /// long-running deployments. The user app never sees the request.
    tracemalloc_path: ?[]const u8 = null,
    /// If true, GET / HEAD requests for `/favicon.ico` are answered
    /// from Zig with `204 No Content`. Browsers spam this path on
    /// every page load; without this flag every hit serialises through
    /// FastAPI's routing for a 404. Costs zero RAM when off.
    favicon_204: bool = false,
    /// v1.4 Prometheus latency histogram. When true, `/metrics` emits
    /// `saltare_request_duration_seconds_bucket` with fixed buckets
    /// (1ms..60s) plus `_sum` / `_count`. Buckets cost 16 × u64
    /// counters = 128 B per worker; off by default since most ops
    /// only need the existing counter set.
    latency_histogram: bool = false,
    /// v1.5 dispatch introspection endpoint. When set (e.g.
    /// `/debug/dispatch`) saltare answers with a JSON snapshot of
    /// in-flight dispatch state: open connections, in-flight requests,
    /// stalled list, draining flag, RSS, rate-limit table size. Same
    /// info as the SIGUSR1 dump but reachable from a probe / curl;
    /// useful in containers where signals are awkward.
    dispatch_path: ?[]const u8 = null,
    /// v1.5 dispatch endpoint shared-secret. When non-null, the
    /// `/debug/dispatch` endpoint requires `Authorization: Bearer
    /// <token>` and 401s otherwise. Cheap defense-in-depth for
    /// network namespaces where the operator can't fully gate the
    /// route via a sidecar / istio policy.
    dispatch_token: ?[]const u8 = null,
    /// v1.5 hot-reload runtime config. When set, on `SIGHUP` saltare
    /// re-reads this file and atomically swaps a small subset of
    /// `Limits` / `Observability` fields without a process restart.
    /// Format is `key=value` lines (one per line, `#` for comments):
    ///
    ///     rate_limit_per_sec=100
    ///     rate_limit_burst=200
    ///     max_connections_per_ip=50
    ///     access_log=true
    ///
    /// Unknown keys / parse errors log a warning and keep the previous
    /// value. The connection-handler hot path reads these via plain
    /// loads on `g_limits` / `g_obs`, so the swap is observed on the
    /// next request without locking.
    runtime_config_path: ?[]const u8 = null,
    /// v1.6 graceful-drain endpoint. POST/PUT to this path flips the
    /// worker into the same drain mode SIGTERM triggers: stop accepting,
    /// let in-flight finish, exit cleanly. Pair with `health_path` so
    /// k8s readiness probes start failing as soon as the drain begins;
    /// the kubelet stops routing traffic before the existing connections
    /// time out. Defense-in-depth: GET on the same path returns the
    /// current draining state without flipping it (idempotent probe
    /// for monitoring). Off by default. No Python dispatch.
    drain_path: ?[]const u8 = null,
};

/// Resource ceilings that turn the architectural RAM win into a guaranteed
/// upper bound under adversarial load. Set by `run()`; checked at accept
/// time, parse time, and keep-alive reset.
pub const Limits = struct {
    /// Maximum declared body size for a single HTTP request, in bytes. A
    /// `Content-Length` (or end-of-chunked-decode) larger than this gets a
    /// 413 response and the connection is closed. Defaults to 1 MiB; in
    /// v0.13 the read buffer (16 KiB) is the practical hard ceiling
    /// regardless of this value — request body streaming lifts that in a
    /// later milestone.
    max_request_body: usize = 1024 * 1024,
    /// Maximum number of accepted connections held open at once. Beyond
    /// this we accept the kernel's connection (we have to, to drain the
    /// listen backlog) and immediately close it; client sees a TCP RST.
    max_concurrent_connections: u32 = 1024,
    /// Maximum number of HTTP requests served on a single keep-alive
    /// connection before saltare forces `Connection: close`. Recycles
    /// CPython's pymalloc arenas by amortising any per-request fragmentation
    /// across many shorter-lived TCP connections.
    max_keepalive_requests: u32 = 1000,
    /// Per-IP request rate ceiling (requests / second). Zero disables.
    /// When set, each request's source IP is tracked in a bounded
    /// hash table; bursts beyond `rate_limit_burst` consecutive requests
    /// in less than `1/rate_limit_per_sec` seconds get a 429 response
    /// from Zig before the user app sees them. Token bucket: refilled at
    /// `rate_limit_per_sec` tokens / second up to `rate_limit_burst`.
    rate_limit_per_sec: u32 = 0,
    rate_limit_burst: u32 = 100,
    /// Per-IP open-connection ceiling. Zero disables. When set, a peer
    /// that already holds this many connections gets a TCP-level close
    /// at accept time (no HTTP response — the kernel sends a RST). The
    /// per-IP table is shared with the rate limiter; both share the
    /// 4096-entry cap.
    max_connections_per_ip: u32 = 0,
    /// `listen(2)` backlog. Default 256 covers most setups; bursty
    /// public-facing servers behind no L4 LB may want 1024+ to absorb
    /// SYN bursts without dropping. Capped by `net.core.somaxconn` —
    /// the kernel silently truncates if you ask for more.
    listen_backlog: c_int = 256,
    /// TCP keepalive cadence (seconds). All zero-or-negative values
    /// fall back to the kernel default (usually 7200/75/9 — way too
    /// long for mobile clients). Setting them tightens dead-conn
    /// detection: idle conns send the first probe after `tcp_keepidle`
    /// seconds, then a probe every `tcp_keepintvl`, and give up after
    /// `tcp_keepcnt` unanswered probes. `SO_KEEPALIVE` is set
    /// unconditionally on every accepted socket.
    tcp_keepidle: i32 = 0,
    tcp_keepintvl: i32 = 0,
    tcp_keepcnt: i32 = 0,
    /// `TCP_USER_TIMEOUT` (Linux). Maximum milliseconds an in-flight
    /// write can stay un-acked before the kernel tears the connection
    /// down. More aggressive than keepalive: keepalive only fires on
    /// idle conns, USER_TIMEOUT also caps stuck writes. Zero =
    /// kernel default (effectively infinite). Recommended on flaky
    /// network paths (mobile, satellite).
    tcp_user_timeout_ms: i32 = 0,
    /// If true, raise the soft `RLIMIT_NOFILE` to the hard limit at
    /// startup so saltare can saturate `max_concurrent_connections`
    /// without fighting the user's default-1024 fd cap. No-op on macOS.
    auto_raise_nofile: bool = false,
    /// Hard ceiling on a single connection's wall-clock lifetime, in
    /// seconds. Zero disables. When set, a connection past this age
    /// is closed at the start of its next request — protects against
    /// long-lived connections accumulating per-conn state in the
    /// app or pinning Python heap fragments. Stricter than
    /// `max_keepalive_requests`, which is request-count based.
    max_connection_lifetime_secs: u32 = 0,
    /// `TCP_FASTOPEN` server-side queue length. Zero disables. When
    /// set, the kernel issues TFO cookies; subsequent connections
    /// from the same client carry payload in the SYN, saving 1 RTT.
    /// Linux ≥ 3.7. Recommended value: same as `listen_backlog` (256).
    /// Wins are visible only when clients themselves opt into TFO.
    tcp_fastopen_qlen: c_int = 0,
    /// Maximum length of the request-target (path + query). Zero = no
    /// explicit cap (still implicitly bounded by the read-buffer). Any
    /// request whose request-line target exceeds this gets a 414 URI
    /// Too Long. Defends apps that do unbounded path-based dispatch
    /// against pathological clients sending multi-KiB URIs.
    max_request_uri: u32 = 8192,
    /// Maximum bytes of the entire request head section (request-line
    /// + all headers + CRLFs, up to and including the terminating
    /// blank line). Zero = no explicit cap. Larger heads are rejected
    /// with 431 before allocating the large pool buffer. Tighter than
    /// the implicit pool-buffer ceiling (~64 KiB). RFC 7230 §3.2.5.
    max_request_head_bytes: u32 = 0,
};

// ---------------------------------------------------------------------------
// Per-IP token-bucket rate limiter (v1.3). Single-threaded, bounded size.
// Each entry is (peer [16]u8, tokens f32, last_refill_ns i64) → ~32 B per
// tracked IP. Cap at 4096 entries; once full we evict the oldest. Lookups
// + inserts are O(N) linear scan over the array — fast at this size, no
// hash table allocation noise. The IO loop is single-threaded, so no
// locking. Active only when `g_limits.rate_limit_per_sec > 0`.
const RateLimitEntry = struct {
    peer: [16]u8,
    tokens: f32,
    last_refill_ns: i64,
    /// Number of currently-open connections from this peer. Maintained
    /// by `acceptAll` (++) and `Connection.destroy` (--). Used by the
    /// `max_connections_per_ip` cap; safe to ignore when the cap is 0.
    open_conns: u32,
};

const RATE_LIMIT_MAX_IPS: usize = 4096;
var g_rl_entries: [RATE_LIMIT_MAX_IPS]RateLimitEntry = undefined;
var g_rl_count: usize = 0;

fn rateLimitReset() void {
    g_rl_count = 0;
}

/// Encode an IPv4 or IPv6 peer address into a uniform 16-byte key. v4
/// maps to the v4-in-v6 form (top 80 bits zero, then 0xFFFF, then the
/// v4 32 bits) so a v4 client and a v6 client with the same numeric ID
/// don't collide. Returns null on AF_UNIX (UDS connections — rate
/// limiting on a Unix socket would limit by what, the kernel's user? —
/// out of scope).
fn peerKey(addr_storage: *const c.struct_sockaddr_storage) ?[16]u8 {
    const sa: *const c.struct_sockaddr = @ptrCast(@alignCast(addr_storage));
    var key: [16]u8 = std.mem.zeroes([16]u8);
    if (sa.sa_family == c.AF_INET) {
        const sin: *const c.struct_sockaddr_in = @ptrCast(@alignCast(addr_storage));
        // v4-mapped: ::ffff:a.b.c.d → bytes 10-11 = 0xff,0xff; bytes 12-15 = v4.
        key[10] = 0xff;
        key[11] = 0xff;
        const src: [*]const u8 = @ptrCast(&sin.sin_addr.s_addr);
        @memcpy(key[12..16], src[0..4]);
        return key;
    }
    if (sa.sa_family == c.AF_INET6) {
        const sin6: *const c.struct_sockaddr_in6 = @ptrCast(@alignCast(addr_storage));
        const src: [*]const u8 = @ptrCast(&sin6.sin6_addr);
        @memcpy(&key, src[0..16]);
        return key;
    }
    return null;
}

/// Parse the leftmost address in an X-Forwarded-For header value into a
/// 16-byte key matching the v4-mapped form `peerKey` produces. Tolerates
/// surrounding whitespace and bracketed IPv6 (`[::1]`). Returns null if
/// no parseable address is found — caller falls back to TCP peer IP.
fn parseFirstForwardedIp(value: []const u8) ?[16]u8 {
    // Take the substring before the first comma — that's the originating
    // client per RFC 7239 / de-facto X-Forwarded-For convention.
    var slice = value;
    if (std.mem.indexOfScalar(u8, slice, ',')) |i| slice = slice[0..i];
    slice = std.mem.trim(u8, slice, " \t");
    if (slice.len == 0) return null;
    // Strip optional IPv6 brackets.
    if (slice.len >= 2 and slice[0] == '[' and slice[slice.len - 1] == ']') {
        slice = slice[1 .. slice.len - 1];
    }

    var nul_buf: [64]u8 = undefined;
    if (slice.len >= nul_buf.len) return null;
    @memcpy(nul_buf[0..slice.len], slice);
    nul_buf[slice.len] = 0;

    var key: [16]u8 = std.mem.zeroes([16]u8);
    // Decide v4 vs v6 by presence of a colon — matches `isIpv6`.
    if (std.mem.indexOfScalar(u8, slice, ':') == null) {
        var v4_addr: c.struct_in_addr = undefined;
        if (c.inet_pton(c.AF_INET, &nul_buf[0], &v4_addr) != 1) return null;
        key[10] = 0xff;
        key[11] = 0xff;
        const src: [*]const u8 = @ptrCast(&v4_addr.s_addr);
        @memcpy(key[12..16], src[0..4]);
        return key;
    }
    var v6_addr: c.struct_in6_addr = undefined;
    if (c.inet_pton(c.AF_INET6, &nul_buf[0], &v6_addr) != 1) return null;
    const src: [*]const u8 = @ptrCast(&v6_addr);
    @memcpy(&key, src[0..16]);
    return key;
}

/// Find or create the rate-limit entry for `peer`. Returns a pointer
/// into `g_rl_entries`; never null (LRU-evicts on overflow). Inlined
/// callers are `rateLimitAllow` and the per-IP connection-cap path.
fn rateLimitGetEntry(peer: *const [16]u8, now_ns: i64) *RateLimitEntry {
    for (g_rl_entries[0..g_rl_count]) |*entry| {
        if (std.mem.eql(u8, &entry.peer, peer)) return entry;
    }
    if (g_rl_count < RATE_LIMIT_MAX_IPS) {
        g_rl_entries[g_rl_count] = .{
            .peer = peer.*,
            .tokens = @floatFromInt(g_limits.rate_limit_burst),
            .last_refill_ns = now_ns,
            .open_conns = 0,
        };
        const idx = g_rl_count;
        g_rl_count += 1;
        return &g_rl_entries[idx];
    }
    var oldest_idx: usize = 0;
    var oldest_ns: i64 = g_rl_entries[0].last_refill_ns;
    for (g_rl_entries[1..], 1..) |entry, i| {
        if (entry.last_refill_ns < oldest_ns) {
            oldest_ns = entry.last_refill_ns;
            oldest_idx = i;
        }
    }
    g_rl_entries[oldest_idx] = .{
        .peer = peer.*,
        .tokens = @floatFromInt(g_limits.rate_limit_burst),
        .last_refill_ns = now_ns,
        .open_conns = 0,
    };
    return &g_rl_entries[oldest_idx];
}

/// Per-IP connection acquire result. `over_cap == true` means the
/// caller should reject the new socket (peer already at the cap);
/// `entry_idx == 0xFFFF` means the limiter is disabled.
const PerIpAcquire = struct { entry_idx: u16, over_cap: bool };

/// Bump the per-peer connection counter at accept time.
fn perIpConnAcquire(peer: *const [16]u8, now_ns: i64) PerIpAcquire {
    const cap = g_limits.max_connections_per_ip;
    if (cap == 0) return .{ .entry_idx = 0xFFFF, .over_cap = false };
    const entry = rateLimitGetEntry(peer, now_ns);
    const idx_usize: usize = @intFromPtr(entry) -% @intFromPtr(&g_rl_entries[0]);
    const idx: u16 = @intCast(idx_usize / @sizeOf(RateLimitEntry));
    if (entry.open_conns >= cap) return .{ .entry_idx = idx, .over_cap = true };
    entry.open_conns += 1;
    return .{ .entry_idx = idx, .over_cap = false };
}

/// Drop a connection from the per-peer counter. No-op when index is
/// the sentinel (cap was disabled, UDS, or table evicted the slot).
fn perIpConnRelease(entry_idx: u16) void {
    if (entry_idx == 0xFFFF) return;
    const idx: usize = entry_idx;
    if (idx >= g_rl_count) return;
    if (g_rl_entries[idx].open_conns > 0) g_rl_entries[idx].open_conns -= 1;
}

/// Returns true if the request is allowed; false if it should be 429'd.
/// Implements a per-peer token bucket: refilled at `rate_per_sec` tokens
/// per second up to a `burst` ceiling. Each allowed request consumes one
/// token. New peers get a fresh `burst` allocation. When the table is
/// full, evicts the entry with the oldest `last_refill_ns` (rough LRU).
fn rateLimitAllow(peer: *const [16]u8, now_ns: i64) bool {
    const rate = g_limits.rate_limit_per_sec;
    if (rate == 0) return true;
    const burst: f32 = @floatFromInt(g_limits.rate_limit_burst);
    const rate_f: f32 = @floatFromInt(rate);

    // Linear scan. At 4096 entries this is one cache line every few
    // iterations; well under a microsecond on modern hardware.
    for (g_rl_entries[0..g_rl_count]) |*entry| {
        if (!std.mem.eql(u8, &entry.peer, peer)) continue;
        const elapsed_ns = now_ns - entry.last_refill_ns;
        const refill = rate_f * @as(f32, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
        entry.tokens = @min(burst, entry.tokens + refill);
        entry.last_refill_ns = now_ns;
        if (entry.tokens < 1.0) return false;
        entry.tokens -= 1.0;
        return true;
    }

    // Not in table. Insert (or evict + insert).
    if (g_rl_count < RATE_LIMIT_MAX_IPS) {
        g_rl_entries[g_rl_count] = .{
            .peer = peer.*,
            .tokens = burst - 1.0,
            .last_refill_ns = now_ns,
            .open_conns = 0,
        };
        g_rl_count += 1;
        return true;
    }
    // Evict oldest. Linear scan again — tolerable at 4096.
    var oldest_idx: usize = 0;
    var oldest_ns: i64 = g_rl_entries[0].last_refill_ns;
    for (g_rl_entries[1..], 1..) |entry, i| {
        if (entry.last_refill_ns < oldest_ns) {
            oldest_ns = entry.last_refill_ns;
            oldest_idx = i;
        }
    }
    g_rl_entries[oldest_idx] = .{
        .peer = peer.*,
        .tokens = burst - 1.0,
        .last_refill_ns = now_ns,
        .open_conns = 0,
    };
    return true;
}

// SIGUSR1 stats-dump request flag. The signal handler sets it; the main
// loop polls it once per iteration and emits a one-line JSON record on
// stderr. Operational diagnostic — `kill -USR1 $(pidof saltare)` to
// snapshot connection / RAM state without an HTTP probe.
var g_dump_stats: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
// SIGHUP request flag for run-time config reopen — reserved for v1.4.
// Currently unused; setting it does nothing.

// Counters driven by the maintenance tick (idle GC + malloc_trim).
var g_idle_ticks: u32 = 0;
const IDLE_GC_TICKS: u32 = 30; // 30 × 100 ms = 3 s of zero events
// Once this many consecutive idle ticks have passed since the last
// maintenance pass, run a GC + malloc_trim to recover heap fragmentation
// accumulated during the previous burst. Re-armed after each maintenance.
// Cheap when triggered (a few hundred microseconds for a small heap);
// skipped when traffic is steady so we never pay it on the hot path.

// Listener fd bookkeeping for the signal-driven shutdown.
var g_listen_fd: std.atomic.Value(c_int) = std.atomic.Value(c_int).init(-1);
var g_should_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
/// Set to true by the signal handler on SIGTERM/SIGINT. Triggers the main
/// loop's graceful-drain path: stop accepting new connections, wait for
/// in-flight requests to finish, exit cleanly. A second signal arriving
/// while already draining promotes to immediate force-exit.
var g_draining: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Set by `run()`. Connections look these up at every state transition to
/// arm the appropriate timeout.
var g_timeouts: Timeouts = .{};

/// Set by `run()`. Caps checked at accept / parse / keep-alive reset.
var g_limits: Limits = .{};

/// Set by `run()`. Looked up at every dispatch (metrics_path) and every
/// completed request (access_log). When `metrics_path == null` and
/// `access_log == false` the v0.14-equivalent fast paths run unchanged.
var g_obs: Observability = .{};

/// Access-log fd. 2 = stderr (default). When `access_log_path` is set,
/// run() open()'s the file and stores the fd here. Reset back to 2 on
/// run() exit so a follow-up serve() call doesn't write to a freed fd.
var g_access_log_fd: c_int = 2;

/// Pre-formatted `Server:` line emitted on every response. Default is
/// `"Server: saltare/<version>\r\n"`. Setting `obs.server_header` at
/// run() time replaces it (empty string → omit). Stored as a slice
/// into either the comptime default literal or a heap allocation
/// owned by run(); the latter is freed at run() exit.
var g_server_line: []const u8 = "Server: " ++ SERVER_HEADER ++ "\r\n";
var g_server_line_owned: ?[]u8 = null;

/// Number of accepted connections currently alive (i.e. created but not
/// yet destroyed). Atomic for paranoia even though the I/O loop is
/// single-threaded — keeps the pattern uniform with `g_listen_fd`.
var g_active_conns: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

// ---------------------------------------------------------------------------
// Metrics counters. All single-threaded writes from the I/O loop, atomic for
// future-proofing (multi-worker may share these via shared memory).

var g_in_flight: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
var g_total_requests: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var g_total_bytes_sent: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var g_total_bytes_received: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var g_total_4xx: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var g_total_5xx: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

// v1.4 Prometheus latency histogram. Le-buckets in seconds, encoded as
// nanoseconds for cheap integer compare against `monoNs() - request_start_ns`.
// `+Inf` is implicit (every observation increments `g_total_requests` already).
// Each bucket counts observations ≤ that bound (Prometheus cumulative
// semantics). 14 fixed buckets — covers 1 ms .. 60 s, plenty for ASGI.
const LATENCY_BUCKET_NS = [_]i64{
    1_000_000, 5_000_000, 10_000_000, 25_000_000, 50_000_000,
    100_000_000, 250_000_000, 500_000_000, 1_000_000_000,
    2_500_000_000, 5_000_000_000, 10_000_000_000, 30_000_000_000,
    60_000_000_000,
};
const LATENCY_BUCKET_LE_S = [_][]const u8{
    "0.001", "0.005", "0.01", "0.025", "0.05",
    "0.1",   "0.25",  "0.5",  "1",     "2.5",
    "5",     "10",    "30",   "60",
};
var g_latency_buckets: [LATENCY_BUCKET_NS.len]std.atomic.Value(u64) = blk: {
    var arr: [LATENCY_BUCKET_NS.len]std.atomic.Value(u64) = undefined;
    for (&arr) |*slot| slot.* = std.atomic.Value(u64).init(0);
    break :blk arr;
};
var g_latency_sum_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

// v1.5 response-compression metrics. The dispatcher (Python) calls
// `_core.compression_metric_inc(encoding, bytes_in, bytes_out)` after
// every successful encode and `_core.compression_metric_skip(reason)`
// when a candidate response is passed through identity. Atomics live
// in Zig so the `/metrics` scrape path doesn't acquire the GIL.
//
// Encoding is one of `gzip` / `br` / `zstd`; skip-reason is one of
// `small_body` (under min-bytes), `non_compressible` (content-type
// not in the whitelist), `encoder_unavailable` (libbrotli/libzstd
// missing), `not_smaller` (encoded payload was bigger than raw).
pub var g_comp_bytes_in_gzip: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
pub var g_comp_bytes_out_gzip: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
pub var g_comp_count_gzip: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
pub var g_comp_bytes_in_br: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
pub var g_comp_bytes_out_br: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
pub var g_comp_count_br: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
pub var g_comp_bytes_in_zstd: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
pub var g_comp_bytes_out_zstd: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
pub var g_comp_count_zstd: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
pub var g_comp_skip_small: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
pub var g_comp_skip_noncomp: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
pub var g_comp_skip_unavail: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
pub var g_comp_skip_not_smaller: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

// v1.6 TLS observability. Incremented in `doHandshake` on success.
// `g_tls_session_reuse_total` tracks how many of those handshakes
// short-circuited via the OpenSSL session cache — direct evidence of
// whether `--tls-session-cache-size` is paying its keep. Always emitted
// when TLS is enabled (g_tls_ctx != null) regardless of whether the
// session cache flag was set, so a zero counter is itself informative.
pub var g_tls_handshakes_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
pub var g_tls_session_reuse_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

// v1.6 PROXY-protocol counters. Same shape as TLS: only emitted when
// `proxy_protocol` is on, so a missing line on /metrics confirms the
// feature is off. `accepted` counts headers that parsed cleanly;
// `rejected` counts connections closed because the first 12 bytes
// didn't match either a v1 ASCII line or a v2 binary signature.
pub var g_proxy_proto_accepted_v1_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
pub var g_proxy_proto_accepted_v2_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
pub var g_proxy_proto_rejected_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

pub fn compressionMetricInc(encoding: []const u8, bytes_in: u64, bytes_out: u64) void {
    if (std.mem.eql(u8, encoding, "gzip")) {
        _ = g_comp_bytes_in_gzip.fetchAdd(bytes_in, .seq_cst);
        _ = g_comp_bytes_out_gzip.fetchAdd(bytes_out, .seq_cst);
        _ = g_comp_count_gzip.fetchAdd(1, .seq_cst);
    } else if (std.mem.eql(u8, encoding, "br")) {
        _ = g_comp_bytes_in_br.fetchAdd(bytes_in, .seq_cst);
        _ = g_comp_bytes_out_br.fetchAdd(bytes_out, .seq_cst);
        _ = g_comp_count_br.fetchAdd(1, .seq_cst);
    } else if (std.mem.eql(u8, encoding, "zstd")) {
        _ = g_comp_bytes_in_zstd.fetchAdd(bytes_in, .seq_cst);
        _ = g_comp_bytes_out_zstd.fetchAdd(bytes_out, .seq_cst);
        _ = g_comp_count_zstd.fetchAdd(1, .seq_cst);
    }
}

/// v1.6: Python-callable graceful-shutdown trigger. Pytest fixtures use
/// it to tear down test-spawned daemon threads cleanly between tests —
/// before this hook, each `_serve()` helper left its `_core.serve()`
/// thread running until process exit, accumulating dozens of concurrent
/// servers that race on shared globals (g_obs, atomics, listen fd). The
/// race only surfaces under stricter allocators (musllinux on cibuildwheel),
/// but it was always present. Same effect as SIGTERM: drains in-flight,
/// exits the I/O loop, lets `serve()` return so the host thread terminates.
pub fn requestShutdown() void {
    g_draining.store(true, .seq_cst);
}

pub fn compressionMetricSkip(reason: []const u8) void {
    if (std.mem.eql(u8, reason, "small_body")) {
        _ = g_comp_skip_small.fetchAdd(1, .seq_cst);
    } else if (std.mem.eql(u8, reason, "non_compressible")) {
        _ = g_comp_skip_noncomp.fetchAdd(1, .seq_cst);
    } else if (std.mem.eql(u8, reason, "encoder_unavailable")) {
        _ = g_comp_skip_unavail.fetchAdd(1, .seq_cst);
    } else if (std.mem.eql(u8, reason, "not_smaller")) {
        _ = g_comp_skip_not_smaller.fetchAdd(1, .seq_cst);
    }
}

fn resetMetrics() void {
    g_in_flight.store(0, .seq_cst);
    g_total_requests.store(0, .seq_cst);
    g_total_bytes_sent.store(0, .seq_cst);
    g_total_bytes_received.store(0, .seq_cst);
    g_total_4xx.store(0, .seq_cst);
    g_total_5xx.store(0, .seq_cst);
    for (&g_latency_buckets) |*slot| slot.store(0, .seq_cst);
    g_latency_sum_ns.store(0, .seq_cst);
    g_tls_handshakes_total.store(0, .seq_cst);
    g_tls_session_reuse_total.store(0, .seq_cst);
    g_proxy_proto_accepted_v1_total.store(0, .seq_cst);
    g_proxy_proto_accepted_v2_total.store(0, .seq_cst);
    g_proxy_proto_rejected_total.store(0, .seq_cst);
}

/// Set by `run` when TLS is enabled. Lives only for the duration of one
/// `serve()` call. Each accepted connection wraps its fd with a fresh SSL
/// derived from this context.
var g_tls_ctx: ?*tls.Ctx = null;
/// v1.5: kTLS — when set, sendfile-over-HTTPS is allowed because
/// OpenSSL has handed cipher state to the kernel and the socket fd
/// emits TLS records on raw `sendfile(2)`/`write(2)`. Plain-HTTP +
/// userspace-TLS deployments leave this at `false` (no behaviour
/// change vs v1.4).
var g_ktls_enabled: bool = false;

/// Head of the doubly-linked list of stalled connections. A connection is
/// stalled when its in-flight HTTP dispatch's Task is parked on something
/// not driven by socket I/O (typically: framework setup chains spanning
/// multiple awaits). Reset to null by `run()`.
var g_stalled_head: ?*Connection = null;

/// CLOCK_MONOTONIC nanoseconds. Wraps the libc call inline so the cost
/// of a metrics scrape is dominated by the formatting, not by Zig
/// indirection. Off the hot path when `access_log` is off (we only call
/// it on request start/end then).
///
/// Zig's translate-c reports `struct timespec` as opaque under
/// musllinux (musl's `time.h` only forward-declares it; the body
/// lives in `bits/types/struct_timespec.h` and isn't always pulled
/// in transitively). Manylinux/glibc inlines it directly. The
/// extern struct + `clock_gettime` declaration below works on both
/// libcs — same x86_64 layout: `time_t` is `c_long`, `tv_nsec` is
/// `c_long`.
const Timespec = extern struct {
    tv_sec: c_long,
    tv_nsec: c_long,
};
extern fn clock_gettime(clk_id: c_int, tp: *Timespec) c_int;
const CLOCK_MONOTONIC_COMPAT: c_int = 1;

fn monoNs() i64 {
    var ts: Timespec = undefined;
    _ = clock_gettime(CLOCK_MONOTONIC_COMPAT, &ts);
    return @as(i64, @intCast(ts.tv_sec)) * std.time.ns_per_s + @as(i64, @intCast(ts.tv_nsec));
}

/// Parse the status code out of a wire response prefix `"HTTP/1.x NNN ..."`.
/// Returns 0 if the prefix isn't recognisable. We read the status from the
/// raw bytes (not from a Python-side struct field) so the metrics counters
/// and the access log don't need a bridge round-trip.
fn parseStatus(chunks: []const u8) u16 {
    if (chunks.len < 12) return 0;
    if (!std.mem.startsWith(u8, chunks, "HTTP/1.")) return 0;
    if (chunks[8] != ' ') return 0;
    return std.fmt.parseInt(u16, chunks[9..12], 10) catch 0;
}

/// Bounded JSON builder backed by a stack buffer. The access log is
/// strictly bounded by request metadata (method, path, status, headers
/// like User-Agent), so a 4 KiB buffer covers every realistic case
/// without allocations. Overflow is silent — we'd rather drop a single
/// log line than fail a request.
const LogBuf = struct {
    buf: [4096]u8 = undefined,
    pos: usize = 0,
    overflow: bool = false,

    fn appendByte(self: *LogBuf, b: u8) void {
        if (self.overflow) return;
        if (self.pos >= self.buf.len) {
            self.overflow = true;
            return;
        }
        self.buf[self.pos] = b;
        self.pos += 1;
    }

    fn appendSlice(self: *LogBuf, s: []const u8) void {
        if (self.overflow) return;
        if (self.pos + s.len > self.buf.len) {
            self.overflow = true;
            return;
        }
        @memcpy(self.buf[self.pos .. self.pos + s.len], s);
        self.pos += s.len;
    }

    fn printFmt(self: *LogBuf, comptime fmt: []const u8, args: anytype) void {
        if (self.overflow) return;
        const out = std.fmt.bufPrint(self.buf[self.pos..], fmt, args) catch {
            self.overflow = true;
            return;
        };
        self.pos += out.len;
    }

    /// Append a JSON-quoted string. Strict escaping of `"`, `\`, control
    /// chars, and any non-ASCII byte (rendered `\u00XX`) so user-supplied
    /// header values can never break the line format.
    fn appendJsonString(self: *LogBuf, raw: []const u8) void {
        self.appendByte('"');
        for (raw) |byte| {
            switch (byte) {
                '"' => self.appendSlice("\\\""),
                '\\' => self.appendSlice("\\\\"),
                '\n' => self.appendSlice("\\n"),
                '\r' => self.appendSlice("\\r"),
                '\t' => self.appendSlice("\\t"),
                0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F, 0x7F...0xFF => {
                    var b6: [6]u8 = undefined;
                    const out = std.fmt.bufPrint(&b6, "\\u00{x:0>2}", .{byte}) catch unreachable;
                    self.appendSlice(out);
                },
                else => self.appendByte(byte),
            }
        }
        self.appendByte('"');
    }
};

// Local time helpers. `localtime_r` is POSIX, available on glibc + musl.
// We use it to render the access-log timestamp in the operator's local
// timezone — matches what they see on the host machine without forcing
// a UTC mental translation. `struct tm` layout is x86_64 / aarch64
// stable across both libcs; we only read the date/time fields.
const Tm = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
    tm_gmtoff: c_long,
    tm_zone: ?[*:0]const u8,
};
extern fn localtime_r(t: *const c_long, result: *Tm) ?*Tm;

fn emitAccessLog(conn: *Connection) void {
    const req = conn.parsed orelse return;

    // v1.6 path filter — skip the log line when the request-target matches
    // an operator-supplied exclude entry exactly. Linear scan; the list is
    // typically <10 entries (the Zig-intercepted endpoints).
    for (g_obs.access_log_exclude) |skip_path| {
        if (std.mem.eql(u8, req.target, skip_path)) return;
    }

    var log: LogBuf = .{};

    // v1.6.1: human-readable line format —
    //     DD/MM/YYYY:HH:MM:SS [METHOD] [URL] [STATUS] [BYTES]
    // Replaces the v0.15 JSON shape. Easier to grep / awk / paste into
    // an issue; status / bytes are still parseable with `sed`.
    var unix_now: c_long = @intCast(c.time(null));
    var tm: Tm = undefined;
    if (localtime_r(&unix_now, &tm) != null) {
        log.printFmt("{d:0>2}/{d:0>2}/{d}:{d:0>2}:{d:0>2}:{d:0>2} ", .{
            @as(u32, @intCast(tm.tm_mday)),
            @as(u32, @intCast(tm.tm_mon + 1)),
            @as(u32, @intCast(tm.tm_year + 1900)),
            @as(u32, @intCast(tm.tm_hour)),
            @as(u32, @intCast(tm.tm_min)),
            @as(u32, @intCast(tm.tm_sec)),
        });
    }
    log.appendByte('[');
    log.appendSlice(req.method);
    log.appendSlice("] [");
    log.appendSlice(req.target);
    log.printFmt("] [{d}] [{d}]\n", .{ conn.response_status, conn.bytes_sent });

    if (!log.overflow) {
        // Single write(2) keeps the line atomic from the kernel's view —
        // partial interleaving with other workers' lines is impossible
        // even without explicit locking.
        _ = c.write(g_access_log_fd, &log.buf, log.pos);
    }
}

fn updateStatusCounters(status: u16) void {
    if (status >= 400 and status < 500) _ = g_total_4xx.fetchAdd(1, .seq_cst);
    if (status >= 500 and status < 600) _ = g_total_5xx.fetchAdd(1, .seq_cst);
}

/// End-of-request hook: decrement the in-flight gauge if dispatch was ever
/// started, bump status-class counters, emit the access log line. Safe to
/// call from any "the response just finished" path (drain to close, drain
/// to keep-alive reset, sendStatus → close). Idempotent: a second call on
/// the same connection is a no-op because `request_in_flight` is cleared.
fn finishRequest(conn: *Connection) void {
    if (conn.request_in_flight) {
        _ = g_in_flight.fetchSub(1, .seq_cst);
        conn.request_in_flight = false;
    }
    updateStatusCounters(conn.response_status);
    if (g_obs.latency_histogram and conn.request_start_ns != 0) {
        const elapsed = monoNs() - conn.request_start_ns;
        if (elapsed >= 0) {
            _ = g_latency_sum_ns.fetchAdd(@intCast(elapsed), .seq_cst);
            for (LATENCY_BUCKET_NS, 0..) |bound, i| {
                if (elapsed <= bound) {
                    _ = g_latency_buckets[i].fetchAdd(1, .seq_cst);
                }
            }
        }
    }
    if (g_obs.access_log and conn.parsed != null) emitAccessLog(conn);
}

/// Read the cgroup memory limit (in bytes) from cgroup v2's
/// `/sys/fs/cgroup/memory.max` or v1's `memory.limit_in_bytes`. v2 is
/// preferred because k8s ≥ 1.25 / Docker default to it. Returns null
/// when no limit is set ("max" in v2, or absent file). v1.4 helper —
/// used to auto-tune `max_concurrent_connections` when the operator
/// didn't configure one explicitly.
fn readCgroupMemoryLimitBytes() ?u64 {
    if (comptime builtin.os.tag != .linux) return null;
    const paths = [_][:0]const u8{
        "/sys/fs/cgroup/memory.max",
        "/sys/fs/cgroup/memory/memory.limit_in_bytes",
    };
    for (paths) |path| {
        const fd = c.open(path.ptr, c.O_RDONLY);
        if (fd < 0) continue;
        defer _ = c.close(fd);
        var buf: [64]u8 = undefined;
        const n = c.read(fd, &buf, buf.len - 1);
        if (n <= 0) continue;
        var len: usize = @intCast(n);
        while (len > 0 and (buf[len - 1] == '\n' or buf[len - 1] == ' ')) len -= 1;
        const txt = buf[0..len];
        // v2 reports "max" when no cap is set.
        if (std.mem.eql(u8, txt, "max")) continue;
        // v1 reports a giant number (~int64 max) when no cap.
        const value = std.fmt.parseInt(u64, txt, 10) catch continue;
        if (value >= std.math.maxInt(u64) / 2) continue;
        return value;
    }
    return null;
}

/// Read VmRSS (resident set) from `/proc/self/status`. Best-effort: any
/// parse failure returns 0 so the metric still renders. Linux-only; on
/// macOS the comptime branch in `serveMetrics` skips it. Uses libc
/// directly because Zig 0.16's `std.posix.open` is absent.
fn readVmRssBytes() u64 {
    const fd = c.open("/proc/self/status", c.O_RDONLY);
    if (fd < 0) return 0;
    defer _ = c.close(fd);
    var buf: [4096]u8 = undefined;
    const n = c.read(fd, &buf, buf.len);
    if (n <= 0) return 0;
    const data = buf[0..@intCast(n)];
    const idx = std.mem.indexOf(u8, data, "VmRSS:") orelse return 0;
    const tail = data[idx + "VmRSS:".len ..];
    var start: usize = 0;
    while (start < tail.len and (tail[start] == ' ' or tail[start] == '\t')) start += 1;
    var num_end: usize = start;
    while (num_end < tail.len and std.ascii.isDigit(tail[num_end])) num_end += 1;
    const kib = std.fmt.parseInt(u64, tail[start..num_end], 10) catch return 0;
    return kib * 1024;
}

/// Count open file descriptors by listing `/proc/self/fd`. Linux-only.
/// Best-effort: returns 0 on any error. Used by the `/metrics`
/// `process_open_fds` gauge.
fn readOpenFds() u64 {
    if (comptime builtin.os.tag != .linux) return 0;
    const dir = c.opendir("/proc/self/fd") orelse return 0;
    defer _ = c.closedir(dir);
    var count: u64 = 0;
    while (c.readdir(dir)) |entry| {
        const name_ptr: [*:0]const u8 = @ptrCast(&entry.*.d_name[0]);
        const name = std.mem.span(name_ptr);
        if (name.len == 0 or name[0] == '.') continue; // skip . and ..
        count += 1;
    }
    // -1 for the opendir fd itself which is in the listing.
    return if (count > 0) count - 1 else 0;
}

/// CPU time consumed (user + kernel) since process start, in seconds.
/// Reads `/proc/self/stat` field 14 (utime) + 15 (stime), both in
/// clock ticks. `_SC_CLK_TCK` (typically 100) converts to seconds.
/// Linux-only.
fn readCpuSeconds() f64 {
    if (comptime builtin.os.tag != .linux) return 0.0;
    const fd = c.open("/proc/self/stat", c.O_RDONLY);
    if (fd < 0) return 0.0;
    defer _ = c.close(fd);
    var buf: [4096]u8 = undefined;
    const n = c.read(fd, &buf, buf.len);
    if (n <= 0) return 0.0;
    const data = buf[0..@intCast(n)];
    // Field separators are spaces, but the comm field (field 2) can
    // contain spaces inside parens. Skip past the closing paren first.
    const close_paren = std.mem.lastIndexOfScalar(u8, data, ')') orelse return 0.0;
    const tail = data[close_paren + 2 ..]; // skip ") "
    var iter = std.mem.tokenizeScalar(u8, tail, ' ');
    // After the comm + state field, utime is field 14 in the original
    // numbering which is field 12 of `tail`.
    var idx: usize = 0;
    var utime: u64 = 0;
    var stime: u64 = 0;
    while (iter.next()) |tok| : (idx += 1) {
        // tail starts at the state char (field 3 in original).
        if (idx == 11) utime = std.fmt.parseInt(u64, tok, 10) catch return 0.0;
        if (idx == 12) {
            stime = std.fmt.parseInt(u64, tok, 10) catch return 0.0;
            break;
        }
    }
    const ticks = utime + stime;
    const hz: u64 = @intCast(c.sysconf(c._SC_CLK_TCK));
    if (hz == 0) return 0.0;
    return @as(f64, @floatFromInt(ticks)) / @as(f64, @floatFromInt(hz));
}

/// Process start time as seconds-since-epoch. Mirrors Prometheus
/// client convention `process_start_time_seconds`. Linux-only.
fn readStartTimeSeconds() f64 {
    return @as(f64, @floatFromInt(g_process_start_unix_secs.load(.seq_cst)));
}

var g_process_start_unix_secs: std.atomic.Value(i64) = std.atomic.Value(i64).init(0);

/// Build a Prometheus-format text dump of saltare's counters and write it
/// to the connection. Bypasses the bridge entirely — the user app never
/// sees the request, so there's no Python overhead per scrape.
fn serveMetrics(loop: *eventloop.Loop, conn: *Connection) void {
    var body_buf: [8192]u8 = undefined;
    var body_len: usize = 0;

    const sections = .{
        .{ "# HELP saltare_open_connections Currently accepted connections held open.\n", {} },
        .{ "# TYPE saltare_open_connections gauge\n", {} },
    };
    _ = sections;

    // Build body via repeated bufPrint cursor.
    const w = struct {
        buf: []u8,
        pos: *usize,

        fn write(self: @This(), comptime fmt: []const u8, args: anytype) void {
            const out = std.fmt.bufPrint(self.buf[self.pos.*..], fmt, args) catch return;
            self.pos.* += out.len;
        }
    }{ .buf = &body_buf, .pos = &body_len };

    const open_conns = g_active_conns.load(.seq_cst);
    const in_flight = g_in_flight.load(.seq_cst);
    const total_reqs = g_total_requests.load(.seq_cst);
    const total_4xx = g_total_4xx.load(.seq_cst);
    const total_5xx = g_total_5xx.load(.seq_cst);
    const total_bytes_sent = g_total_bytes_sent.load(.seq_cst);
    const total_bytes_recv = g_total_bytes_received.load(.seq_cst);
    const rss_bytes: u64 = if (comptime builtin.os.tag == .linux) readVmRssBytes() else 0;

    w.write(
        \\# HELP saltare_open_connections Currently accepted connections held open.
        \\# TYPE saltare_open_connections gauge
        \\saltare_open_connections {d}
        \\# HELP saltare_in_flight_requests HTTP requests being dispatched right now.
        \\# TYPE saltare_in_flight_requests gauge
        \\saltare_in_flight_requests {d}
        \\# HELP saltare_requests_total HTTP requests fully served since startup.
        \\# TYPE saltare_requests_total counter
        \\saltare_requests_total {d}
        \\# HELP saltare_responses_4xx_total Total 4xx responses emitted.
        \\# TYPE saltare_responses_4xx_total counter
        \\saltare_responses_4xx_total {d}
        \\# HELP saltare_responses_5xx_total Total 5xx responses emitted.
        \\# TYPE saltare_responses_5xx_total counter
        \\saltare_responses_5xx_total {d}
        \\# HELP saltare_bytes_sent_total Bytes written to client sockets.
        \\# TYPE saltare_bytes_sent_total counter
        \\saltare_bytes_sent_total {d}
        \\# HELP saltare_bytes_received_total Bytes read from client sockets.
        \\# TYPE saltare_bytes_received_total counter
        \\saltare_bytes_received_total {d}
        \\# HELP saltare_process_resident_memory_bytes RSS of the worker, from /proc/self/status (Linux only; 0 elsewhere).
        \\# TYPE saltare_process_resident_memory_bytes gauge
        \\saltare_process_resident_memory_bytes {d}
        \\# HELP process_open_fds Open file descriptors. Prom client convention.
        \\# TYPE process_open_fds gauge
        \\process_open_fds {d}
        \\# HELP process_start_time_seconds Seconds since epoch when the process started.
        \\# TYPE process_start_time_seconds gauge
        \\process_start_time_seconds {d}
        \\# HELP saltare_health_state 0=healthy, 1=draining (SIGTERM received).
        \\# TYPE saltare_health_state gauge
        \\saltare_health_state {d}
        \\
    , .{
        open_conns,
        in_flight,
        total_reqs,
        total_4xx,
        total_5xx,
        total_bytes_sent,
        total_bytes_recv,
        rss_bytes,
        readOpenFds(),
        @as(i64, @intFromFloat(readStartTimeSeconds())),
        @as(u32, if (g_draining.load(.seq_cst)) 1 else 0),
    });

    // process_cpu_seconds_total — separate format to keep float precision.
    {
        const cpu_secs = readCpuSeconds();
        const whole: u64 = @intFromFloat(cpu_secs);
        const frac: u64 = @intFromFloat((cpu_secs - @as(f64, @floatFromInt(whole))) * 1_000_000.0);
        w.write(
            "# HELP process_cpu_seconds_total CPU time used by this process (user + kernel) in seconds.\n" ++
                "# TYPE process_cpu_seconds_total counter\n" ++
                "process_cpu_seconds_total {d}.{d:0>6}\n",
            .{ whole, frac },
        );
    }

    // v1.4 latency histogram. Emitted only when the operator opted in;
    // saves 14 bucket lines + sum + count + 2 HELP/TYPE lines (~700 B
    // wire) per scrape on installs that don't need it.
    if (g_obs.latency_histogram) {
        w.write(
            \\# HELP saltare_request_duration_seconds Wall-clock request latency, in seconds.
            \\# TYPE saltare_request_duration_seconds histogram
            \\
        , .{});
        for (LATENCY_BUCKET_LE_S, 0..) |le, i| {
            const count = g_latency_buckets[i].load(.seq_cst);
            w.write("saltare_request_duration_seconds_bucket{{le=\"{s}\"}} {d}\n", .{ le, count });
        }
        const sum_ns = g_latency_sum_ns.load(.seq_cst);
        // Count == total_reqs (every finished request increments both).
        w.write("saltare_request_duration_seconds_bucket{{le=\"+Inf\"}} {d}\n", .{total_reqs});
        // Render sum as fixed seconds with 6-decimal precision (microsecond
        // resolution). Avoids pulling in a float fmt path; integer math.
        const sum_us = sum_ns / 1000;
        w.write("saltare_request_duration_seconds_sum {d}.{d:0>6}\n", .{ sum_us / 1_000_000, sum_us % 1_000_000 });
        w.write("saltare_request_duration_seconds_count {d}\n", .{total_reqs});
    }

    // v1.5 response-compression metrics. Always emitted when the
    // operator opted into any encoder; the labels are populated only
    // by the codec that ran, so a gzip-only deployment shows zero
    // counters for `br` / `zstd`. Same shape as nginx's stub_status:
    // helps verify "is the feature actually doing work" at a glance.
    if (g_obs.metrics_path != null and (
        g_comp_count_gzip.load(.seq_cst) +
        g_comp_count_br.load(.seq_cst) +
        g_comp_count_zstd.load(.seq_cst) +
        g_comp_skip_small.load(.seq_cst) +
        g_comp_skip_noncomp.load(.seq_cst) +
        g_comp_skip_unavail.load(.seq_cst) +
        g_comp_skip_not_smaller.load(.seq_cst)) > 0)
    {
        w.write(
            \\# HELP saltare_response_compression_total Successful response encodes by codec.
            \\# TYPE saltare_response_compression_total counter
            \\saltare_response_compression_total{{encoding="gzip"}} {d}
            \\saltare_response_compression_total{{encoding="br"}} {d}
            \\saltare_response_compression_total{{encoding="zstd"}} {d}
            \\# HELP saltare_response_compression_bytes_in_total Pre-encode body bytes.
            \\# TYPE saltare_response_compression_bytes_in_total counter
            \\saltare_response_compression_bytes_in_total{{encoding="gzip"}} {d}
            \\saltare_response_compression_bytes_in_total{{encoding="br"}} {d}
            \\saltare_response_compression_bytes_in_total{{encoding="zstd"}} {d}
            \\# HELP saltare_response_compression_bytes_out_total Post-encode body bytes.
            \\# TYPE saltare_response_compression_bytes_out_total counter
            \\saltare_response_compression_bytes_out_total{{encoding="gzip"}} {d}
            \\saltare_response_compression_bytes_out_total{{encoding="br"}} {d}
            \\saltare_response_compression_bytes_out_total{{encoding="zstd"}} {d}
            \\# HELP saltare_response_compression_skipped_total Encode-candidate responses passed through identity.
            \\# TYPE saltare_response_compression_skipped_total counter
            \\saltare_response_compression_skipped_total{{reason="small_body"}} {d}
            \\saltare_response_compression_skipped_total{{reason="non_compressible"}} {d}
            \\saltare_response_compression_skipped_total{{reason="encoder_unavailable"}} {d}
            \\saltare_response_compression_skipped_total{{reason="not_smaller"}} {d}
            \\
        , .{
            g_comp_count_gzip.load(.seq_cst),
            g_comp_count_br.load(.seq_cst),
            g_comp_count_zstd.load(.seq_cst),
            g_comp_bytes_in_gzip.load(.seq_cst),
            g_comp_bytes_in_br.load(.seq_cst),
            g_comp_bytes_in_zstd.load(.seq_cst),
            g_comp_bytes_out_gzip.load(.seq_cst),
            g_comp_bytes_out_br.load(.seq_cst),
            g_comp_bytes_out_zstd.load(.seq_cst),
            g_comp_skip_small.load(.seq_cst),
            g_comp_skip_noncomp.load(.seq_cst),
            g_comp_skip_unavail.load(.seq_cst),
            g_comp_skip_not_smaller.load(.seq_cst),
        });
    }

    // v1.6 TLS observability. Emitted whenever TLS is configured for
    // this worker (g_tls_ctx != null), even at zero counts — a healthy
    // tls_handshakes_total at non-zero requests_total proves connections
    // are actually doing TLS, not falling through to plaintext.
    if (g_tls_ctx != null) {
        w.write(
            \\# HELP saltare_tls_handshakes_total Successful TLS handshakes since startup.
            \\# TYPE saltare_tls_handshakes_total counter
            \\saltare_tls_handshakes_total {d}
            \\# HELP saltare_tls_session_reuse_total Handshakes that reused a cached session (RFC 5077 / 8446 PSK).
            \\# TYPE saltare_tls_session_reuse_total counter
            \\saltare_tls_session_reuse_total {d}
            \\
        , .{
            g_tls_handshakes_total.load(.seq_cst),
            g_tls_session_reuse_total.load(.seq_cst),
        });
    }

    // v1.6 PROXY-protocol counters. Emitted only when the operator has
    // `--proxy-protocol` enabled — a missing line on /metrics confirms
    // the feature is off, not just inactive.
    if (g_obs.proxy_protocol) {
        w.write(
            \\# HELP saltare_proxy_protocol_accepted_total Connections that arrived with a parsed PROXY-protocol header.
            \\# TYPE saltare_proxy_protocol_accepted_total counter
            \\saltare_proxy_protocol_accepted_total{{version="v1"}} {d}
            \\saltare_proxy_protocol_accepted_total{{version="v2"}} {d}
            \\
        , .{
            g_proxy_proto_accepted_v1_total.load(.seq_cst),
            g_proxy_proto_accepted_v2_total.load(.seq_cst),
        });
    }

    // v1.6 OpenMetrics EOF marker (RFC for OpenMetrics 1.0). Both
    // Prometheus 2.x scrape paths accept it; OpenMetrics-strict tooling
    // (openmetrics-client, m3) requires it. Cheap — three bytes.
    w.write("# EOF\n", .{});

    var head_buf: [512]u8 = undefined;
    const head = std.fmt.bufPrint(
        &head_buf,
        "HTTP/1.1 200 OK\r\n" ++
            "{s}" ++
            "Content-Type: text/plain; version=0.0.4\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Connection: keep-alive\r\n" ++
            "\r\n",
        .{ g_server_line, body_len },
    ) catch {
        sendStatus(loop, conn, 500, "Internal Server Error");
        return;
    };

    const total_len = head.len + body_len;
    const heap = conn.allocator.alloc(u8, total_len) catch {
        sendStatus(loop, conn, 503, "Service Unavailable");
        return;
    };
    @memcpy(heap[0..head.len], head);
    @memcpy(heap[head.len..], body_buf[0..body_len]);

    if (conn.write_buf.len > 0) conn.allocator.free(conn.write_buf);
    conn.write_buf = heap;
    conn.write_pos = 0;
    conn.state = .writing;
    conn.keep_alive = conn.parsed.?.wantsKeepAlive();
    conn.response_status = 200;
    conn.armTimer(g_timeouts.write_secs);

    loop.modify(conn.fd, @ptrCast(conn), false, true) catch {
        loop.remove(conn.fd);
        conn.destroy();
        return;
    };
    doWrite(loop, conn);
}

/// Fixed-body 200 response intercepted in Zig — used for the health
/// endpoint so k8s-style probes don't pay the full ASGI dispatch cost.
/// `keep_alive` follows the request's preference; `body` is copied into
/// the heap-allocated wire buffer along with the status line.
fn serveFixedBody(
    loop: *eventloop.Loop,
    conn: *Connection,
    status: u16,
    reason: []const u8,
    content_type: []const u8,
    body: []const u8,
    extra_headers: []const u8,
) void {
    const ka = conn.parsed.?.wantsKeepAlive();
    const conn_line: []const u8 = if (ka) "keep-alive" else "close";
    var head_buf: [768]u8 = undefined;
    const head = std.fmt.bufPrint(
        &head_buf,
        "HTTP/1.1 {d} {s}\r\n" ++
            "{s}" ++
            "Content-Type: {s}\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Connection: {s}\r\n" ++
            "{s}" ++
            "\r\n",
        .{ status, reason, g_server_line, content_type, body.len, conn_line, extra_headers },
    ) catch {
        sendStatus(loop, conn, 500, "Internal Server Error");
        return;
    };

    const total_len = head.len + body.len;
    const heap = conn.allocator.alloc(u8, total_len) catch {
        sendStatus(loop, conn, 503, "Service Unavailable");
        return;
    };
    @memcpy(heap[0..head.len], head);
    @memcpy(heap[head.len..], body);

    if (conn.write_buf.len > 0) conn.allocator.free(conn.write_buf);
    conn.write_buf = heap;
    conn.write_pos = 0;
    conn.state = .writing;
    conn.keep_alive = ka;
    conn.response_status = status;
    conn.armTimer(g_timeouts.write_secs);

    loop.modify(conn.fd, @ptrCast(conn), false, true) catch {
        loop.remove(conn.fd);
        conn.destroy();
        return;
    };
    doWrite(loop, conn);
}

/// Cheap liveness/readiness probe. Always 200, body "ok\n". The user app
/// never sees the request — k8s `httpGet` probes that fire every few
/// seconds don't serialise through Python at all.
fn serveHealth(loop: *eventloop.Loop, conn: *Connection) void {
    serveFixedBody(loop, conn, 200, "OK", "text/plain; charset=utf-8", "ok\n", "");
}

/// Browsers fetch `/favicon.ico` on first page load. Without this
/// intercept, every hit serialises through Python's routing for a 404
/// (or, worse, a multi-millisecond FastAPI 404 page). 204 + empty body
/// + a 24h `Cache-Control: max-age` so the browser doesn't keep asking.
fn serveFavicon(loop: *eventloop.Loop, conn: *Connection) void {
    serveFixedBody(
        loop, conn, 204, "No Content", "image/x-icon", "",
        "Cache-Control: public, max-age=86400\r\n",
    );
}

/// v1.4: serve a file via `sendfile(2)`. Opens the file, fstat's
/// for size, writes the response head (status line + caller-supplied
/// headers + `Content-Length: <size>` + `Connection: ...`), then
/// hands off to a streaming sendfile loop that runs in `doWriteSendfile`.
/// Falls back to a 500 on any open()/fstat() error. TLS connections
/// can't use sendfile (the kernel writes plaintext), so we 500
/// gracefully there too.
fn serveSendfile(loop: *eventloop.Loop, conn: *Connection, sf: bridge.SendfileRequest) void {
    if (conn.ssl != null and !g_ktls_enabled) {
        // sendfile + userspace TLS don't compose. With kTLS the kernel
        // applies TLS records on the socket so the regular sendfile(2)
        // syscall just works — see `--ktls`. Without kTLS the app
        // should fall back to chunked body for HTTPS endpoints.
        return sendStatus(loop, conn, 500, "Internal Server Error");
    }
    // kTLS path: we still need to flush any plaintext OpenSSL has
    // buffered (handshake state). On a fresh connection right after
    // the handshake, OpenSSL has already pushed cipher state into
    // the kernel — the socket fd is now a kTLS socket, so sendfile
    // emits TLS records directly. We write the head via SSL_write
    // so OpenSSL's bookkeeping stays consistent, then sendfile() the
    // body via the bare fd (kernel encrypts on the way out).

    var path_buf: [4096]u8 = undefined;
    if (sf.path.len >= path_buf.len) {
        return sendStatus(loop, conn, 500, "Internal Server Error");
    }
    @memcpy(path_buf[0..sf.path.len], sf.path);
    path_buf[sf.path.len] = 0;
    const fd = c.open(@as([*c]const u8, @ptrCast(&path_buf[0])), c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) {
        return sendStatus(loop, conn, 404, "Not Found");
    }
    // `struct stat` is opaque under translate-c on musllinux (musl
    // splits it across bits/types files). `lseek(SEEK_END)` returns
    // the same size info without touching the struct, works on both
    // libcs identically. SEEK_SET back so subsequent sendfile starts
    // at offset 0 — actually we pass `&offset` to sendfile and start
    // from 0 explicitly below, so the lseek is just a getter here.
    const size_off = c.lseek(fd, 0, c.SEEK_END);
    if (size_off < 0) {
        _ = c.close(fd);
        return sendStatus(loop, conn, 500, "Internal Server Error");
    }
    const size: u64 = @intCast(size_off);

    const reason: []const u8 = switch (sf.status) {
        200 => "OK",
        206 => "Partial Content",
        else => "OK",
    };
    const conn_line: []const u8 = if (sf.keep_alive) "keep-alive" else "close";

    var head_buf: [1024]u8 = undefined;
    const head = std.fmt.bufPrint(
        &head_buf,
        "HTTP/1.1 {d} {s}\r\n" ++
            "{s}" ++
            "{s}" ++
            "Content-Length: {d}\r\n" ++
            "Connection: {s}\r\n" ++
            "\r\n",
        .{ sf.status, reason, g_server_line, sf.headers_block, size, conn_line },
    ) catch {
        _ = c.close(fd);
        return sendStatus(loop, conn, 500, "Internal Server Error");
    };

    // Write head synchronously (small + fits MTU). For huge headers
    // we'd need to buffer + epoll, but headers always fit < 1 KiB.
    var written: usize = 0;
    while (written < head.len) {
        const r = c.write(conn.fd, @ptrCast(head[written..].ptr), head.len - written);
        if (r < 0) {
            // EINTR: retry, no progress lost. Anything else: drop.
            if (std.posix.errno(r) == .INTR) continue;
            _ = c.close(fd);
            loop.remove(conn.fd);
            conn.destroy();
            return;
        }
        if (r == 0) {
            _ = c.close(fd);
            loop.remove(conn.fd);
            conn.destroy();
            return;
        }
        written += @intCast(r);
    }

    // RFC 7230 §3.3.3: HEAD response has the same headers as GET but
    // MUST NOT include a body. Skip the sendfile loop entirely —
    // emitting the body bytes after the head would corrupt the
    // pipeline on keep-alive (the client would parse them as the
    // start of the next response).
    const is_head = std.mem.eql(u8, conn.parsed.?.method, "HEAD");
    if (is_head) {
        _ = c.close(fd);
        conn.bytes_sent = 0;
        conn.response_status = sf.status;
        conn.keep_alive = sf.keep_alive;
        finishRequest(conn);
        if (sf.keep_alive) {
            keepAliveReset(loop, conn);
        } else {
            loop.remove(conn.fd);
            conn.destroy();
        }
        return;
    }

    // sendfile in a loop until the whole file is on the wire. For
    // very large files this should yield to the event loop; for v1.4
    // we keep it synchronous (the loop handles other connections in
    // between when the socket buffer back-pressures). Future v1.4.x
    // could split into a state-machine sendfile to share the I/O loop.
    var offset: c.off_t = 0;
    var remaining: usize = @intCast(size);
    while (remaining > 0) {
        const sent = c.sendfile(conn.fd, fd, &offset, remaining);
        if (sent < 0) {
            const err = std.posix.errno(sent);
            // EINTR: a signal hit between syscall entry and any data
            // transfer. Retry transparently — no progress to lose.
            // SIGCHLD / SIGUSR1 / a wheel timer firing all land here
            // and would otherwise drop the connection.
            if (err == .INTR) continue;
            // EAGAIN/EWOULDBLOCK on full socket buffer — yield.
            if (err == .AGAIN) {
                // Wait for the socket to be writable. We register
                // the fd for EPOLLOUT and re-enter sendfile on the
                // next event. Simpler v1.4 impl: block here briefly
                // since most files complete in 1-2 syscalls.
                _ = c.close(fd);
                loop.remove(conn.fd);
                conn.destroy();
                return;
            }
            _ = c.close(fd);
            loop.remove(conn.fd);
            conn.destroy();
            return;
        }
        if (sent == 0) break;
        remaining -= @intCast(sent);
    }
    _ = c.close(fd);

    _ = g_total_bytes_sent.fetchAdd(size, .seq_cst);
    conn.bytes_sent = size;
    conn.response_status = sf.status;
    conn.keep_alive = sf.keep_alive;
    finishRequest(conn);
    if (sf.keep_alive) {
        keepAliveReset(loop, conn);
    } else {
        loop.remove(conn.fd);
        conn.destroy();
    }
}

/// Serve a tracemalloc dump (top-N Python allocations grouped by
/// `lineno`). Allocates a body via the bridge, copies into a heap
/// response, and sends. Body is ~few KiB for typical N=30. The user
/// app never sees this path.
fn serveTracemalloc(loop: *eventloop.Loop, conn: *Connection) void {
    const body = bridge.tracemallocDump(conn.allocator);
    defer if (body.len > 0) conn.allocator.free(body);
    const safe_body: []const u8 = if (body.len > 0) body else "tracemalloc not available\n";
    serveFixedBody(loop, conn, 200, "OK", "text/plain; charset=utf-8", safe_body, "");
}

/// v1.5 dispatch introspection. Renders the same fields as the
/// SIGUSR1 stats dump as a single-line JSON document. Bypasses
/// Python entirely (no GIL acquired) so even a deadlocked dispatcher
/// answers the probe.
fn serveDispatch(loop: *eventloop.Loop, conn: *Connection) void {
    // Optional Bearer-token gate. When `dispatch_token` is set, any
    // request without `Authorization: Bearer <token>` matching gets a
    // 401. Constant-time compare avoids leaking length info; the token
    // is short so the cost is trivial.
    if (g_obs.dispatch_token) |expected| {
        const auth = conn.parsed.?.header("authorization") orelse {
            return sendStatus(loop, conn, 401, "Unauthorized");
        };
        const prefix = "Bearer ";
        if (!std.ascii.startsWithIgnoreCase(auth, prefix)) {
            return sendStatus(loop, conn, 401, "Unauthorized");
        }
        const presented = std.mem.trim(u8, auth[prefix.len..], " \t");
        if (presented.len != expected.len) {
            return sendStatus(loop, conn, 401, "Unauthorized");
        }
        var diff: u8 = 0;
        for (presented, expected) |a, b| diff |= a ^ b;
        if (diff != 0) {
            return sendStatus(loop, conn, 401, "Unauthorized");
        }
    }
    var body_buf: [768]u8 = undefined;
    const open_conns = g_active_conns.load(.seq_cst);
    const in_flight = g_in_flight.load(.seq_cst);
    const total_reqs = g_total_requests.load(.seq_cst);
    const total_4xx = g_total_4xx.load(.seq_cst);
    const total_5xx = g_total_5xx.load(.seq_cst);
    const total_bytes_sent = g_total_bytes_sent.load(.seq_cst);
    const total_bytes_recv = g_total_bytes_received.load(.seq_cst);
    const draining: u32 = if (g_draining.load(.seq_cst)) 1 else 0;
    const rss_bytes: u64 = if (comptime builtin.os.tag == .linux) readVmRssBytes() else 0;
    const body = std.fmt.bufPrint(
        &body_buf,
        "{{\"open_conns\":{d},\"in_flight\":{d}," ++
            "\"requests_total\":{d},\"responses_4xx\":{d},\"responses_5xx\":{d}," ++
            "\"bytes_sent\":{d},\"bytes_received\":{d}," ++
            "\"rl_table_size\":{d}," ++
            "\"draining\":{d},\"rss_bytes\":{d}}}\n",
        .{
            open_conns,    in_flight, total_reqs, total_4xx, total_5xx,
            total_bytes_sent, total_bytes_recv,
            g_rl_count,
            draining, rss_bytes,
        },
    ) catch {
        sendStatus(loop, conn, 500, "Internal Server Error");
        return;
    };
    serveFixedBody(loop, conn, 200, "OK", "application/json; charset=utf-8", body, "");
}

/// v1.6 graceful-drain endpoint. POST/PUT flips `g_draining` to true;
/// the main loop notices on the next iteration and behaves identically
/// to a SIGTERM-driven drain (stops accepting, lets in-flight finish,
/// exits when shutdown_timeout elapses or all conns close). GET is an
/// idempotent probe — returns the current state without flipping.
/// Other verbs return 405 so a curl typo doesn't accidentally drain.
fn serveDrainEndpoint(loop: *eventloop.Loop, conn: *Connection) void {
    const req = conn.parsed.?;
    if (std.mem.eql(u8, req.method, "POST") or std.mem.eql(u8, req.method, "PUT")) {
        const was_draining = g_draining.swap(true, .seq_cst);
        const body = if (was_draining)
            "{\"draining\":true,\"changed\":false}\n"
        else
            "{\"draining\":true,\"changed\":true}\n";
        return serveFixedBody(loop, conn, 200, "OK", "application/json; charset=utf-8", body, "");
    }
    if (std.mem.eql(u8, req.method, "GET") or std.mem.eql(u8, req.method, "HEAD")) {
        const draining = g_draining.load(.seq_cst);
        const body = if (draining)
            "{\"draining\":true}\n"
        else
            "{\"draining\":false}\n";
        return serveFixedBody(loop, conn, 200, "OK", "application/json; charset=utf-8", body, "");
    }
    serveFixedBody(loop, conn, 405, "Method Not Allowed", "text/plain; charset=utf-8", "method not allowed\n", "Allow: GET, HEAD, POST, PUT\r\n");
}

/// CORS preflight intercept. Answers OPTIONS-with-Origin from Zig with a
/// permissive policy (`*` origins, common methods + headers, 24h cache).
/// The user app never sees preflight requests — useful for SPA workloads
/// where every cross-origin route triggers one. Strictly stricter
/// allowlists must still be done in the app (we don't read its CORS
/// config).
fn serveCorsPreflight(loop: *eventloop.Loop, conn: *Connection) void {
    const cors_headers =
        "Access-Control-Allow-Origin: *\r\n" ++
        "Access-Control-Allow-Methods: GET, POST, PUT, PATCH, DELETE, OPTIONS\r\n" ++
        "Access-Control-Allow-Headers: Content-Type, Authorization, X-Requested-With\r\n" ++
        "Access-Control-Max-Age: 86400\r\n";
    serveFixedBody(loop, conn, 204, "No Content", "text/plain; charset=utf-8", "", cors_headers);
}

fn linkStalled(conn: *Connection) void {
    if (conn.stalled) return;
    conn.stalled = true;
    conn.stalled_prev = null;
    conn.stalled_next = g_stalled_head;
    if (g_stalled_head) |h| h.stalled_prev = conn;
    g_stalled_head = conn;
}

fn unlinkStalled(conn: *Connection) void {
    if (!conn.stalled) return;
    if (conn.stalled_prev) |p| {
        p.stalled_next = conn.stalled_next;
    } else {
        g_stalled_head = conn.stalled_next;
    }
    if (conn.stalled_next) |n| n.stalled_prev = conn.stalled_prev;
    conn.stalled = false;
    conn.stalled_next = null;
    conn.stalled_prev = null;
}

// Sentinel pointer used as `event.data.ptr` for the listening socket so the
// event loop can tell it apart from connection events without a hashmap.
var listener_marker: u8 = 0;

fn isListenerEvent(data: ?*anyopaque) bool {
    return data == @as(*anyopaque, @ptrCast(&listener_marker));
}

fn onSignal(_: c_int) callconv(.c) void {
    // First signal: enter graceful-drain mode (stop accepting, let
    // in-flight finish). Second signal (or the shutdown deadline elapsing):
    // force immediate exit.
    if (g_draining.swap(true, .seq_cst)) {
        g_should_stop.store(true, .seq_cst);
    }
    // Wake the I/O loop. SHUT_RD on the listener returns EAGAIN-ish on the
    // next accept and triggers an EPOLLIN/EPOLLERR event so `loop.wait`
    // returns; main loop then sees `g_draining` and acts.
    const fd = g_listen_fd.load(.seq_cst);
    if (fd >= 0) {
        _ = c.shutdown(fd, c.SHUT_RD);
    }
}

fn ignoreSignal(_: c_int) callconv(.c) void {}

fn onUsr1(_: c_int) callconv(.c) void {
    g_dump_stats.store(true, .seq_cst);
}

fn installSignalHandlers() void {
    // Translate-c rejects SIG_ERR / SIG_IGN sentinel values; see memory note.
    _ = c.signal(c.SIGINT, &onSignal);
    _ = c.signal(c.SIGTERM, &onSignal);
    _ = c.signal(c.SIGPIPE, &ignoreSignal);
    _ = c.signal(c.SIGUSR1, &onUsr1);
    _ = c.signal(c.SIGHUP, &onHup);
}

/// SIGHUP → main loop will re-parse `runtime_config_path`.
var g_runtime_reload_pending: std.atomic.Value(bool) =
    std.atomic.Value(bool).init(false);

fn onHup(_: c_int) callconv(.c) void {
    g_runtime_reload_pending.store(true, .seq_cst);
}

/// Parse one `key=value` line and apply to the live limits/obs.
/// Returns true if the key was recognised.
fn applyRuntimeKey(key: []const u8, value: []const u8) bool {
    if (std.mem.eql(u8, key, "rate_limit_per_sec")) {
        const v = std.fmt.parseInt(u32, value, 10) catch return false;
        g_limits.rate_limit_per_sec = v;
        return true;
    }
    if (std.mem.eql(u8, key, "rate_limit_burst")) {
        const v = std.fmt.parseInt(u32, value, 10) catch return false;
        g_limits.rate_limit_burst = v;
        return true;
    }
    if (std.mem.eql(u8, key, "max_connections_per_ip")) {
        const v = std.fmt.parseInt(u32, value, 10) catch return false;
        g_limits.max_connections_per_ip = v;
        return true;
    }
    if (std.mem.eql(u8, key, "max_connection_lifetime_secs")) {
        const v = std.fmt.parseInt(u32, value, 10) catch return false;
        g_limits.max_connection_lifetime_secs = v;
        return true;
    }
    if (std.mem.eql(u8, key, "access_log")) {
        g_obs.access_log = std.mem.eql(u8, value, "true") or
            std.mem.eql(u8, value, "1") or
            std.mem.eql(u8, value, "yes");
        return true;
    }
    return false;
}

/// Re-read `runtime_config_path` and apply any recognised keys. Runs
/// only on the I/O loop thread (after observing `g_runtime_reload_pending`)
/// so direct writes to `g_limits` / `g_obs` are safe — workers read these
/// fields via plain loads on the same thread on every request.
fn reloadRuntimeConfig() void {
    const path_z = if (g_obs.runtime_config_path) |p| p else return;
    var path_buf: [4096]u8 = undefined;
    if (path_z.len >= path_buf.len) return;
    @memcpy(path_buf[0..path_z.len], path_z);
    path_buf[path_z.len] = 0;
    const fd = c.open(@as([*c]const u8, @ptrCast(&path_buf[0])), c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) {
        var err_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&err_buf, "saltare: SIGHUP: cannot open {s}\n", .{path_z}) catch return;
        _ = c.write(2, msg.ptr, msg.len);
        return;
    }
    defer _ = c.close(fd);
    var buf: [4096]u8 = undefined;
    const n = c.read(fd, &buf, buf.len);
    if (n <= 0) return;
    const text = buf[0..@intCast(n)];
    var applied: u32 = 0;
    var unknown: u32 = 0;
    var iter = std.mem.splitScalar(u8, text, '\n');
    while (iter.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (applyRuntimeKey(key, value)) {
            applied += 1;
        } else {
            unknown += 1;
        }
    }
    var msg_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &msg_buf,
        "saltare: SIGHUP: applied {d} key(s), {d} unknown\n",
        .{ applied, unknown },
    ) catch return;
    _ = c.write(2, msg.ptr, msg.len);
}

/// Emit a one-line JSON snapshot of saltare's runtime state on stderr.
/// Triggered by `SIGUSR1`; never throws (best-effort `write(2)`).
/// Format: `{"event":"saltare.stats","open_conns":N,"in_flight":M,...}`.
fn dumpStats() void {
    const open_conns = g_active_conns.load(.seq_cst);
    const in_flight = g_in_flight.load(.seq_cst);
    const total_reqs = g_total_requests.load(.seq_cst);
    const rss_kib: u64 = if (comptime builtin.os.tag == .linux) (readVmRssBytes() / 1024) else 0;
    const draining = g_draining.load(.seq_cst);
    var buf: [512]u8 = undefined;
    const out = std.fmt.bufPrint(
        &buf,
        "{{\"event\":\"saltare.stats\",\"open_conns\":{d},\"in_flight\":{d}," ++
            "\"requests_total\":{d},\"rss_kib\":{d},\"rl_table_size\":{d}," ++
            "\"draining\":{}}}\n",
        .{ open_conns, in_flight, total_reqs, rss_kib, g_rl_count, draining },
    ) catch return;
    _ = c.write(2, out.ptr, out.len);
}

fn parseIpv4(host: []const u8, port: u16) !c.struct_sockaddr_in {
    var bytes: [4]u8 = undefined;
    var idx: usize = 0;
    var iter = std.mem.splitScalar(u8, host, '.');
    while (iter.next()) |octet| {
        if (idx >= 4) return error.InvalidAddress;
        bytes[idx] = std.fmt.parseInt(u8, octet, 10) catch return error.InvalidAddress;
        idx += 1;
    }
    if (idx != 4) return error.InvalidAddress;

    var addr: c.struct_sockaddr_in = std.mem.zeroes(c.struct_sockaddr_in);
    addr.sin_family = @intCast(c.AF_INET);
    addr.sin_port = std.mem.nativeToBig(u16, port);
    addr.sin_addr.s_addr = @bitCast(bytes);
    return addr;
}

/// Detect IPv6 by presence of any colon. Bracketed notation (`[::1]`) is
/// also accepted and stripped — common in Docker / reverse-proxy configs.
inline fn isIpv6(host: []const u8) bool {
    return std.mem.indexOfScalar(u8, host, ':') != null;
}

/// Parse a textual IPv6 address into a `sockaddr_in6`. Uses libc's
/// `inet_pton(AF_INET6, ...)` so we get the full RFC 5952 grammar (`::`,
/// IPv4-mapped, etc.) without reinventing it. Brackets are stripped if
/// present.
fn parseIpv6(host: []const u8, port: u16) !c.struct_sockaddr_in6 {
    var stripped = host;
    if (stripped.len >= 2 and stripped[0] == '[' and stripped[stripped.len - 1] == ']') {
        stripped = stripped[1 .. stripped.len - 1];
    }

    // inet_pton wants a NUL-terminated string. Stack-buffer it; v6
    // textual form is bounded at 45 chars + NUL (with a dotted-quad
    // suffix), so a 64-byte buffer is more than enough.
    var nul_buf: [64]u8 = undefined;
    if (stripped.len >= nul_buf.len) return error.InvalidAddress;
    @memcpy(nul_buf[0..stripped.len], stripped);
    nul_buf[stripped.len] = 0;

    var addr: c.struct_sockaddr_in6 = std.mem.zeroes(c.struct_sockaddr_in6);
    addr.sin6_family = @intCast(c.AF_INET6);
    addr.sin6_port = std.mem.nativeToBig(u16, port);
    if (c.inet_pton(c.AF_INET6, &nul_buf[0], &addr.sin6_addr) != 1) {
        return error.InvalidAddress;
    }
    return addr;
}

const ConnState = enum {
    /// PROXY-protocol v1 line still being read. Only entered when
    /// `proxy_protocol=True`; transitions to `.handshaking` (TLS) or
    /// `.reading` (plain) once the line is fully parsed.
    proxy_pending,
    /// TLS handshake in progress. Plaintext connections start in `.reading`.
    handshaking,
    reading,
    writing,
};

const Protocol = enum { http, websocket };

const Connection = struct {
    fd: c_int,
    state: ConnState,

    /// Peer IP (v4-in-v6 mapped) captured at accept time. Used by the
    /// rate limiter. [16]u8 instead of u128 so the struct keeps a
    /// 8-byte alignment (u128 forces 16-byte align, which breaks the
    /// `@fieldParentPtr("timer_node", ...)` upcast in `fireExpired`).
    peer_key: [16]u8,
    /// True when peer_key is populated. False for UDS connections
    /// (where rate-limiting by peer IP makes no sense) and for the
    /// brief moment between Connection.create and the accept path
    /// stamping the address.
    has_peer_key: bool,
    /// Index into `g_rl_entries` for the per-IP connection counter.
    /// `0xFFFF` (= u16 max) means "no entry" (cap disabled, UDS, or
    /// table evicted). On `Connection.destroy` we decrement by index;
    /// the index is stable as long as we never compact the array, and
    /// we never do.
    rl_entry_idx: u16,

    /// Borrowed from the pool while a request is in flight, returned to the
    /// pool when the connection goes idle (between keep-alive requests).
    /// Null means "no request in progress, no buffer reserved".
    read_buf: ?*pool_mod.Buffer,
    read_total: usize,

    // Filled in once the head is fully parsed. `parsed.headers` slices into
    // the active read_buf's `headers` array; both are owned by the pool
    // buffer and freed together by `releaseBuffer`. `parsed` MUST be
    // cleared before releasing the buffer.
    parsed: ?http.Request,
    body_offset: usize,
    /// For Content-Length requests: the declared body size.
    /// For chunked requests: set after decoding finishes to the decoded length.
    body_len: usize,

    // Chunked-decoder state. Used only when `parsed.?.is_chunked` is true.
    // Both offsets are relative to `body_offset` (i.e., into `data[body_offset..]`).
    chunk_state: http.ChunkState,
    chunk_consumed: usize,
    chunk_decoded: usize,

    // Allocated by bridge.dispatch (or sendStatus); freed in `destroy` or
    // when transitioning back to .reading on keep-alive.
    write_buf: []u8,
    write_pos: usize,

    /// Set by `dispatch` based on the request's Connection header / version.
    /// Drives whether `doWrite` resets for the next request or closes.
    keep_alive: bool,

    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,

    /// Set when accept() handed us a TLS-bound fd. Null for plaintext.
    ssl: ?*tls.Ssl,

    /// Started as `.http`. Switches to `.websocket` after a successful
    /// upgrade handshake; from then on we parse WS frames instead of HTTP.
    protocol: Protocol,
    /// Opaque handle returned by Python's `ws_open` for the upgraded
    /// connection. 0 while protocol == .http.
    ws_handle: c_long,

    /// Embedded directly so arming / cancelling is allocation-free. The
    /// wheel manages an intrusive doubly-linked list through this field.
    timer_node: timer.Node,
    /// Pointer to the run()-local wheel, so destroy() can cancel the timer
    /// without needing the wheel passed through every call site.
    wheel: *timer.Wheel,

    /// Opaque handle into Python's `_dispatcher.http_states` for the
    /// in-flight request. Zero between requests.
    dispatch_handle: c_long,
    /// True while the asyncio Task driving the request is alive. Cleared
    /// when the Task completes or the connection is torn down.
    dispatch_active: bool,
    /// Linked-list pointers for the global "stalled" list of connections
    /// whose Task is parked waiting on something that's not socket I/O
    /// (typically: still chaining through framework setup awaits). The
    /// main loop walks this list after each `loop.wait` and runs one
    /// global asyncio pump to advance every stalled Task in lockstep.
    stalled_next: ?*Connection,
    stalled_prev: ?*Connection,
    stalled: bool,

    /// Number of HTTP requests fully served on this connection so far.
    /// Compared against `g_limits.max_keepalive_requests` at the start of
    /// each new request; once the cap is hit, `keep_alive` is forced false
    /// to recycle the connection.
    keepalive_request_count: u32,

    // Per-request metrics state. Reset at dispatch start, read by the
    // access-log emit path right before keepAliveReset / close. None of
    // these cost a syscall when access_log is off.
    /// HTTP status code of the in-flight or just-finished response. 0
    /// before we've parsed any wire bytes for this request.
    response_status: u16,
    /// Bytes successfully written to the socket for this request, summed
    /// across all chunks of a streamed response.
    bytes_sent: u64,
    /// CLOCK_MONOTONIC nanoseconds at request start (after parse-success);
    /// used to compute latency for the access log. 0 when access_log off.
    request_start_ns: i64,
    /// True when the dispatch path incremented `g_in_flight` for this
    /// request and `finishRequest` therefore needs to symmetrically
    /// decrement it. False on early sendStatus paths (parse errors).
    request_in_flight: bool,

    /// CLOCK_MONOTONIC ns of the last inbound activity on this connection.
    /// Updated on every successful WebSocket frame parse; used by the
    /// WS keepalive logic in `fireExpired` to decide whether to send a
    /// ping or tear down a silently-dead connection.
    last_activity_ns: i64,

    /// CLOCK_MONOTONIC ns at accept time. Used by `max_connection_lifetime_secs`
    /// to force-close connections past their wall-clock budget — protects
    /// against per-conn state accumulation in long-lived clients beyond
    /// what `max_keepalive_requests` (request-count based) catches.
    accepted_ns: i64,

    // WebSocket fragmentation reassembly (RFC 6455 §5.4). Initial frame
    // with FIN=0 saves its opcode here; subsequent continuation frames
    // append to `ws_frag_buf`. The final continuation (FIN=1, opcode=0)
    // delivers the reassembled message and frees the buffer. Capped to
    // 1 MiB so a slow producer can't OOM us.
    ws_frag_opcode: u8,
    /// rsv1 of the first frame in a fragmented message — RFC 7692
    /// per-message-deflate sets it on the start frame only; the
    /// reassembled message inherits the flag.
    ws_frag_rsv1: bool,
    ws_frag_buf: ?[]u8,
    ws_frag_len: usize,
    /// v1.6 WS per-message-deflate negotiated for this connection.
    /// Set in `startWebSocket` when the client offered the extension
    /// and the dispatcher accepted. Used to pass the rsv1 hint to
    /// the bridge on every inbound message.
    ws_pmd_active: bool,

    // v1.4: request-body streaming state. When the declared
    // `Content-Length` exceeds the read buffer's available space,
    // `dispatch()` fires immediately with the body bytes already
    // received plus `more_body=True`, then leaves the connection
    // in `.body_streaming` so subsequent reads push more chunks
    // into the running ASGI task via `bridge.httpDispatchPushBody`.
    // `body_streaming_consumed` tracks bytes already pushed so we
    // know when to send the final `more_body=False`.
    body_streaming: bool,
    body_streaming_consumed: usize,

    fn create(
        allocator: std.mem.Allocator,
        pool: *pool_mod.Pool,
        fd: c_int,
        wheel: *timer.Wheel,
    ) !*Connection {
        const conn = try allocator.create(Connection);
        conn.* = .{
            .fd = fd,
            .state = .reading,
            .peer_key = std.mem.zeroes([16]u8),
            .has_peer_key = false,
            .rl_entry_idx = 0xFFFF,
            .read_buf = null,
            .read_total = 0,
            .parsed = null,
            .body_offset = 0,
            .body_len = 0,
            .chunk_state = http.ChunkState.init(),
            .chunk_consumed = 0,
            .chunk_decoded = 0,
            .write_buf = &.{},
            .write_pos = 0,
            .keep_alive = false,
            .allocator = allocator,
            .pool = pool,
            .ssl = null,
            .protocol = .http,
            .ws_handle = 0,
            .timer_node = .{ .next = null, .prev = null, .bucket = 0, .armed = false },
            .wheel = wheel,
            .dispatch_handle = 0,
            .dispatch_active = false,
            .stalled_next = null,
            .stalled_prev = null,
            .stalled = false,
            .keepalive_request_count = 0,
            .response_status = 0,
            .bytes_sent = 0,
            .request_start_ns = 0,
            .request_in_flight = false,
            .last_activity_ns = 0,
            .accepted_ns = monoNs(),
            .ws_frag_opcode = 0,
            .ws_frag_rsv1 = false,
            .ws_frag_buf = null,
            .ws_frag_len = 0,
            .ws_pmd_active = false,
            .body_streaming = false,
            .body_streaming_consumed = 0,
        };
        return conn;
    }

    fn destroy(self: *Connection) void {
        // NOTE: WebSocket teardown (notifying Python) must be done by
        // `wsTeardown` BEFORE calling destroy. We don't acquire the GIL
        // here — destroy is called from many paths (including non-WS)
        // and forcing a GIL acquisition was a footgun in tests.
        self.wheel.cancel(&self.timer_node);
        unlinkStalled(self);
        if (self.dispatch_active and self.dispatch_handle != 0) {
            // Re-acquires the GIL; cancels the asyncio Task and frees the
            // per-request state on the Python side.
            bridge.httpDispatchAbort(self.dispatch_handle);
            self.dispatch_active = false;
            self.dispatch_handle = 0;
        }
        if (self.ssl) |s| tls.freeSsl(s);
        if (self.read_buf) |b| self.pool.release(b, monoNs());
        if (self.write_buf.len > 0) self.allocator.free(self.write_buf);
        if (self.ws_frag_buf) |b| self.allocator.free(b);
        _ = c.close(self.fd);
        // Pair the per-IP connection counter inc'd at accept (no-op
        // when the cap was disabled or the peer is UDS).
        perIpConnRelease(self.rl_entry_idx);
        // Pair with the increment in acceptAll. Subtract before destroying
        // so `g_active_conns` reflects the soon-to-be-freed slot.
        _ = g_active_conns.fetchSub(1, .seq_cst);
        self.allocator.destroy(self);
    }

    inline fn armTimer(self: *Connection, seconds: u32) void {
        self.wheel.arm(&self.timer_node, seconds);
    }

    inline fn cancelTimer(self: *Connection) void {
        self.wheel.cancel(&self.timer_node);
    }

    fn ensureBuffer(self: *Connection) !void {
        if (self.read_buf == null) {
            self.read_buf = try self.pool.acquire();
        }
    }

    fn releaseBuffer(self: *Connection) void {
        if (self.read_buf) |b| {
            self.pool.release(b, monoNs());
            self.read_buf = null;
        }
    }

    /// Swap the connection's small buffer for a large one, copying the
    /// in-flight read bytes across. Called from `doReadHttp` when a small
    /// buffer fills before the headers fit, and from `dispatch()` when
    /// `body_offset + body_len` would overflow the small data block but
    /// fits in the large one. The caller must not have called `parse()`
    /// successfully yet — `parsed.headers` would otherwise dangle (the
    /// headers array lives inside the buffer struct).
    fn upgradeBuffer(self: *Connection) !void {
        const old = self.read_buf orelse return;
        if (old.data.len == pool_mod.LARGE_DATA_SIZE) return; // already large
        const large = try self.pool.acquireLarge();
        @memcpy(large.data[0..self.read_total], old.data[0..self.read_total]);
        self.pool.release(old, monoNs());
        self.read_buf = large;
    }
};

/// Detect systemd socket activation per the `sd_listen_fds(3)`
/// protocol. Returns `fd 3` (the first inherited socket) when:
///   1. `LISTEN_PID` env equals our pid (so we don't pick up a fd
///      meant for a parent that re-execed us);
///   2. `LISTEN_FDS` is set to a positive number (we use the first).
/// On match, the env vars are cleared so children we fork later don't
/// inherit them and re-resolve the same fd. Returns null when not
/// running under systemd socket activation.
fn detectSystemdSocket() ?c_int {
    const pid_z = std.c.getenv("LISTEN_PID") orelse return null;
    const fds_z = std.c.getenv("LISTEN_FDS") orelse return null;
    const pid_str = std.mem.span(@as([*:0]const u8, @ptrCast(pid_z)));
    const fds_str = std.mem.span(@as([*:0]const u8, @ptrCast(fds_z)));
    const expected_pid = std.fmt.parseInt(c.pid_t, pid_str, 10) catch return null;
    if (expected_pid != c.getpid()) return null;
    const n_fds = std.fmt.parseInt(c_int, fds_str, 10) catch return null;
    if (n_fds < 1) return null;
    // sd_listen_fds reserves fds [3, 3 + n_fds). We accept the first.
    const fd: c_int = 3;
    // Best-effort: clear so forked workers don't re-detect.
    _ = unsetenvC("LISTEN_PID");
    _ = unsetenvC("LISTEN_FDS");
    _ = unsetenvC("LISTEN_FDNAMES");
    return fd;
}

extern fn unsetenv(name: [*:0]const u8) c_int;
inline fn unsetenvC(name: [*:0]const u8) c_int {
    return unsetenv(name);
}

/// Public wrapper used by the multi-worker master to bind the listen
/// socket once before forking. Workers later receive this fd via
/// `run(..., inherited_listen_fd=fd)`.
pub fn bindAndListen(host: []const u8, port: u16, uds_path: ?[]const u8) !c_int {
    if (uds_path) |p| return bindUnixSocket(p);
    return bindTcpSocket(host, port);
}

fn bindTcpSocket(host: []const u8, port: u16) !c_int {
    if (isIpv6(host)) return bindTcpSocketV6(host, port);

    const addr = try parseIpv4(host, port);
    const fd = c.socket(
        c.AF_INET,
        c.SOCK_STREAM | c.SOCK_NONBLOCK | c.SOCK_CLOEXEC,
        c.IPPROTO_TCP,
    );
    if (fd < 0) return error.SocketFailed;
    errdefer _ = c.close(fd);

    var yes: c_int = 1;
    if (c.setsockopt(fd, c.SOL_SOCKET, c.SO_REUSEADDR, @ptrCast(&yes), @sizeOf(c_int)) != 0) {
        return error.SetsockoptFailed;
    }
    if (c.bind(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) != 0) return error.BindFailed;
    // TCP_FASTOPEN: opt-in. Kernel needs `net.ipv4.tcp_fastopen` set
    // to a value that includes server-side support (3 enables both).
    if (g_limits.tcp_fastopen_qlen > 0) {
        var qlen = g_limits.tcp_fastopen_qlen;
        _ = c.setsockopt(fd, c.IPPROTO_TCP, c.TCP_FASTOPEN, @ptrCast(&qlen), @sizeOf(c_int));
    }
    if (c.listen(fd, g_limits.listen_backlog) != 0) return error.ListenFailed;
    return fd;
}

fn bindTcpSocketV6(host: []const u8, port: u16) !c_int {
    const addr = try parseIpv6(host, port);
    const fd = c.socket(
        c.AF_INET6,
        c.SOCK_STREAM | c.SOCK_NONBLOCK | c.SOCK_CLOEXEC,
        c.IPPROTO_TCP,
    );
    if (fd < 0) return error.SocketFailed;
    errdefer _ = c.close(fd);

    var yes: c_int = 1;
    if (c.setsockopt(fd, c.SOL_SOCKET, c.SO_REUSEADDR, @ptrCast(&yes), @sizeOf(c_int)) != 0) {
        return error.SetsockoptFailed;
    }
    // IPV6_V6ONLY=0 would dual-bind v4/v6 on Linux but the kernel default
    // varies by distro; explicit IPV6_V6ONLY=1 is safer. Users who want
    // v4 traffic can run a second listener.
    if (c.setsockopt(fd, c.IPPROTO_IPV6, c.IPV6_V6ONLY, @ptrCast(&yes), @sizeOf(c_int)) != 0) {
        return error.SetsockoptFailed;
    }
    if (c.bind(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) != 0) return error.BindFailed;
    // TCP_FASTOPEN: opt-in. Kernel needs `net.ipv4.tcp_fastopen` set
    // to a value that includes server-side support (3 enables both).
    if (g_limits.tcp_fastopen_qlen > 0) {
        var qlen = g_limits.tcp_fastopen_qlen;
        _ = c.setsockopt(fd, c.IPPROTO_TCP, c.TCP_FASTOPEN, @ptrCast(&qlen), @sizeOf(c_int));
    }
    if (c.listen(fd, g_limits.listen_backlog) != 0) return error.ListenFailed;
    return fd;
}

/// Bind a Unix domain socket at `path` for AF_UNIX accept(). Caller is
/// responsible for unlinking the path on shutdown (run() does this in a
/// defer block). v0.15: server-only; no abstract namespace, no SO_PEERCRED
/// auth. Behind nginx on the same host, this avoids the localhost TCP
/// stack entirely.
fn bindUnixSocket(path: []const u8) !c_int {
    if (path.len == 0 or path.len >= @sizeOf(@TypeOf(@as(c.struct_sockaddr_un, undefined).sun_path))) {
        return error.InvalidAddress;
    }
    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_NONBLOCK | c.SOCK_CLOEXEC, 0);
    if (fd < 0) return error.SocketFailed;
    errdefer _ = c.close(fd);

    var addr: c.struct_sockaddr_un = std.mem.zeroes(c.struct_sockaddr_un);
    addr.sun_family = c.AF_UNIX;
    @memcpy(addr.sun_path[0..path.len], path);
    addr.sun_path[path.len] = 0;

    // Best-effort: remove a leftover socket file from a previous run that
    // exited without unlinking. The bind would otherwise fail EADDRINUSE.
    {
        var z: [108]u8 = undefined;
        @memcpy(z[0..path.len], path);
        z[path.len] = 0;
        _ = std.c.unlink(@ptrCast(&z));
    }

    if (c.bind(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) != 0) return error.BindFailed;
    // TCP_FASTOPEN: opt-in. Kernel needs `net.ipv4.tcp_fastopen` set
    // to a value that includes server-side support (3 enables both).
    if (g_limits.tcp_fastopen_qlen > 0) {
        var qlen = g_limits.tcp_fastopen_qlen;
        _ = c.setsockopt(fd, c.IPPROTO_TCP, c.TCP_FASTOPEN, @ptrCast(&qlen), @sizeOf(c_int));
    }
    if (c.listen(fd, g_limits.listen_backlog) != 0) return error.ListenFailed;
    return fd;
}

pub fn run(
    host: []const u8,
    port: u16,
    tls_ctx: ?*tls.Ctx,
    timeouts: Timeouts,
    limits: Limits,
    obs: Observability,
    uds_path: ?[]const u8,
    inherited_listen_fd: ?c_int,
    ktls: bool,
) !void {
    g_tls_ctx = tls_ctx;
    defer g_tls_ctx = null;
    g_ktls_enabled = ktls;
    defer g_ktls_enabled = false;
    g_timeouts = timeouts;
    defer g_timeouts = .{};
    g_limits = limits;
    defer g_limits = .{};
    g_obs = obs;
    defer g_obs = .{};

    // v1.4: cgroup memory awareness. When we're inside a memory-
    // limited cgroup (typical k8s `resources.limits.memory`), use
    // `memory.max` as a soft input to `max_concurrent_connections`.
    // Heuristic: assume ~50 KiB worst-case per concurrent request
    // (Python state + pool buffer + scratch) and never go above
    // 4× the floor estimate. If the operator set a non-default
    // `max_concurrent_connections` we leave it alone.
    if (limits.max_concurrent_connections == 1024) {
        if (readCgroupMemoryLimitBytes()) |limit_bytes| {
            // Reserve 64 MiB for Python heap + libs floor; budget
            // the rest at 50 KiB per concurrent.
            const floor_bytes: u64 = 64 * 1024 * 1024;
            if (limit_bytes > floor_bytes + (50 * 1024)) {
                const budget = (limit_bytes - floor_bytes) / (50 * 1024);
                const cap_u32: u32 = if (budget > 65535) 65535 else @intCast(budget);
                if (cap_u32 < 1024) {
                    g_limits.max_concurrent_connections = if (cap_u32 < 16) 16 else cap_u32;
                    std.log.info(
                        "saltare: cgroup memory.max={d} MiB → max_concurrent_connections={d}",
                        .{ limit_bytes / (1024 * 1024), g_limits.max_concurrent_connections },
                    );
                }
            }
        }
    }

    // v1.3: optionally raise the fd soft limit to the hard limit so
    // saltare can saturate `max_concurrent_connections` without
    // bumping into the user's default 1024 fd cap. No-op on
    // non-Linux.
    if (limits.auto_raise_nofile and comptime builtin.os.tag == .linux) {
        var rl: c.struct_rlimit = undefined;
        if (c.getrlimit(c.RLIMIT_NOFILE, &rl) == 0) {
            if (rl.rlim_cur < rl.rlim_max) {
                rl.rlim_cur = rl.rlim_max;
                _ = c.setrlimit(c.RLIMIT_NOFILE, &rl);
            }
        }
    }

    // v1.3: optional `Server:` header override. Empty string omits
    // the header entirely. Default null = comptime saltare/<ver> line.
    if (obs.server_header) |sh| {
        if (sh.len == 0) {
            g_server_line = "";
        } else {
            const total = sh.len + "Server: \r\n".len;
            const buf = std.heap.c_allocator.alloc(u8, total) catch unreachable;
            const written = std.fmt.bufPrint(buf, "Server: {s}\r\n", .{sh}) catch unreachable;
            g_server_line_owned = buf;
            g_server_line = written;
        }
    }
    defer {
        g_server_line = "Server: " ++ SERVER_HEADER ++ "\r\n";
        if (g_server_line_owned) |b| {
            std.heap.c_allocator.free(b);
            g_server_line_owned = null;
        }
    }

    // Access log fd. Default = stderr. If a path was supplied, open()
    // it append-mode and route writes there. Failure falls back to
    // stderr with a single warning to stderr — we don't refuse to
    // serve over a log-write target.
    if (obs.access_log_path) |path_slice| {
        var path_buf: [4096]u8 = undefined;
        if (path_slice.len < path_buf.len) {
            @memcpy(path_buf[0..path_slice.len], path_slice);
            path_buf[path_slice.len] = 0;
            const fd = c.open(
                @as([*c]const u8, @ptrCast(&path_buf[0])),
                c.O_WRONLY | c.O_APPEND | c.O_CREAT | c.O_CLOEXEC,
                @as(c_uint, 0o640),
            );
            if (fd >= 0) {
                g_access_log_fd = fd;
            } else {
                std.log.warn("saltare: access_log_path open failed; falling back to stderr", .{});
            }
        }
    }
    defer if (g_access_log_fd != 2) {
        _ = c.close(g_access_log_fd);
        g_access_log_fd = 2;
    };
    g_active_conns.store(0, .seq_cst);
    defer g_active_conns.store(0, .seq_cst);
    // Clear any drain flag a prior test/process left set (e.g. a pytest
    // fixture that called `_core.request_shutdown()` while no worker
    // was running — without this reset the next `serve()` would enter
    // the main loop, immediately observe drain, and exit before binding).
    g_draining.store(false, .seq_cst);
    resetMetrics();
    rateLimitReset();

    // Multi-worker (v1.0): the master process binds + listens, then forks
    // N children that inherit the fd. When `inherited_listen_fd` is set we
    // skip bind/listen and use that fd directly. UDS unlink on shutdown
    // is the master's responsibility, not the worker's — workers shouldn't
    // remove the socket the master also serves.
    //
    // v1.3: also detect systemd socket activation. systemd's
    // `sd_listen_fds` protocol passes inherited sockets via fd 3..3+N
    // and signals it via `LISTEN_PID=<our_pid>` + `LISTEN_FDS=N`. We
    // accept exactly one socket; multiple fds is out of scope here.
    // The fd is treated as already-bound + listening; we don't try to
    // re-bind it. Skipped when `inherited_listen_fd` is set (multi-
    // worker master already bound) or `uds_path` is supplied (explicit
    // UDS path takes precedence).
    const sd_fd: ?c_int = if (inherited_listen_fd != null or uds_path != null) null else detectSystemdSocket();
    const owns_listen_fd = inherited_listen_fd == null and sd_fd == null;
    const listen_fd: c_int = if (inherited_listen_fd) |fd|
        fd
    else if (sd_fd) |fd|
        fd
    else if (uds_path) |path|
        try bindUnixSocket(path)
    else
        try bindTcpSocket(host, port);
    errdefer if (owns_listen_fd) {
        _ = c.close(listen_fd);
    };
    defer if (owns_listen_fd and uds_path != null) {
        var z: [108]u8 = undefined;
        const path = uds_path.?;
        const len = @min(path.len, z.len - 1);
        @memcpy(z[0..len], path[0..len]);
        z[len] = 0;
        _ = std.c.unlink(@ptrCast(&z));
    };

    g_listen_fd.store(listen_fd, .seq_cst);
    defer g_listen_fd.store(-1, .seq_cst);

    installSignalHandlers();
    // Record process start time for `process_start_time_seconds`.
    g_process_start_unix_secs.store(@intCast(c.time(null)), .seq_cst);

    var loop = try eventloop.Loop.init();
    defer loop.deinit();

    try loop.add(listen_fd, @ptrCast(&listener_marker), true, false);

    const allocator = std.heap.c_allocator;
    var rb_pool = pool_mod.Pool.init(allocator);
    defer rb_pool.deinit();

    var wheel = try timer.Wheel.init();

    if (uds_path) |path| {
        std.log.info("saltare listening on unix:{s}", .{path});
    } else {
        std.log.info("saltare listening on {s}:{d}", .{ host, port });
    }

    const tick_ctx = TickCtx{ .loop = &loop };

    // Drain bookkeeping: stamp the moment we first see g_draining so the
    // main loop can compare against shutdown_secs without re-reading the
    // wall clock from the signal handler. -1 means "not yet draining".
    var drain_started_sec: i64 = -1;

    while (!g_should_stop.load(.seq_cst)) {
        if (g_draining.load(.seq_cst) and drain_started_sec < 0) {
            // First time we observe drain mode: stop accepting (remove
            // the listener from epoll so we don't even see EPOLLIN for
            // backlog connections), and stamp the deadline.
            drain_started_sec = @intCast(wheel.nowSec());
            loop.remove(listen_fd);
            std.log.info("saltare draining: {d}s timeout, {d} active conns", .{
                timeouts.shutdown_secs,
                g_active_conns.load(.seq_cst),
            });
        }

        if (drain_started_sec >= 0) {
            // Drain exit conditions:
            //   - all connections gone → clean shutdown
            //   - shutdown_secs elapsed → force exit (in-flight clipped)
            if (g_active_conns.load(.seq_cst) == 0) break;
            const elapsed = @as(i64, @intCast(wheel.nowSec())) - drain_started_sec;
            if (elapsed >= @as(i64, @intCast(timeouts.shutdown_secs))) {
                std.log.warn("saltare drain deadline reached, {d} conns still in flight", .{
                    g_active_conns.load(.seq_cst),
                });
                break;
            }
        }

        // When connections are parked on framework setup chains we need to
        // drive the asyncio loop forward without sleeping for the full
        // 100 ms poll budget — otherwise a stalled batch of FastAPI
        // requests would each take 100 ms per await to unblock.
        const wait_timeout: c_int = if (g_stalled_head != null) 0 else 100;
        const events = loop.wait(wait_timeout);
        var saw_event = false;
        for (events) |ev| {
            if (g_should_stop.load(.seq_cst)) break;
            saw_event = true;
            if (isListenerEvent(ev.data)) {
                // Skip listener events while draining — we already removed
                // it from epoll above; this is just paranoia for any final
                // event already in flight.
                if (drain_started_sec < 0) {
                    acceptAll(&loop, listen_fd, allocator, &rb_pool, &wheel);
                }
            } else if (ev.data) |raw| {
                const conn: *Connection = @ptrCast(@alignCast(raw));
                handleConnEvent(&loop, conn, ev);
            }
        }

        // SIGUSR1 stats dump — triggered by the operator via `kill -USR1`.
        // Single-line JSON to stderr; never throws.
        if (g_dump_stats.swap(false, .seq_cst)) dumpStats();
        if (g_runtime_reload_pending.swap(false, .seq_cst)) reloadRuntimeConfig();

        // Sweep expired connections. With a 100 ms epoll poll, the worst-
        // case lag past a 1 s deadline is one bucket; granularity of all
        // four configurable timeouts is therefore ±1 s.
        wheel.tick(wheel.nowSec(), tick_ctx, fireExpired);

        // Hint long-idle pool buffers to the kernel via MADV_DONTNEED so
        // RSS recovers after a traffic peak. Cost: O(free_list_size)
        // pointer-chase per loop iteration. Linux only; macOS no-ops.
        rb_pool.sweepIdle(monoNs());

        // Idle maintenance: when the loop has been quiet for ~3 seconds
        // (30 ticks of 100 ms with no events and nothing in-flight),
        // run a Python `gc.collect(2)` + `malloc_trim(0)` to release
        // fragmentation accumulated during the previous burst. Cheap
        // when nothing's accumulated, expensive enough during a peak
        // that gating it on idle-only matters. Skipped during graceful
        // drain so we don't spend time GC'ing on the way out.
        if (saw_event or g_in_flight.load(.seq_cst) > 0 or drain_started_sec >= 0) {
            g_idle_ticks = 0;
        } else {
            g_idle_ticks += 1;
            if (g_idle_ticks == IDLE_GC_TICKS) {
                bridge.idleMaintenance();
                if (comptime builtin.os.tag == .linux) {
                    _ = malloc_trim(0);
                }
            }
        }

        // Drive any stalled HTTP dispatches forward. One global asyncio
        // pump advances every parked Task by one step; we then walk the
        // stalled list and harvest each one's output. Connections that
        // got chunks transition back to .writing; those still parked
        // re-link themselves on the next stall path.
        if (g_stalled_head != null) drainStalled(&loop);
    }

    g_stalled_head = null;
    g_draining.store(false, .seq_cst);
    if (owns_listen_fd) {
        _ = c.close(listen_fd);
    }
}

fn drainStalled(loop: *eventloop.Loop) void {
    bridge.httpGlobalPump();

    // Snapshot the head — connections may unlink themselves as we iterate
    // (transition back to .writing or get destroyed by an error path).
    var node = g_stalled_head;
    while (node) |conn| {
        const next = conn.stalled_next;
        unlinkStalled(conn);
        // The Task may have produced wire bytes; harvest them. If it's
        // still parked, doWrite's stall path will re-link us.
        if (conn.dispatch_active and conn.dispatch_handle != 0) {
            // Switch back to WANT_WRITE; doWrite will drain + try writing.
            // If there's nothing to write yet and the Task is still
            // parked, doWrite re-stalls (re-links + flips back to
            // WANT_READ).
            conn.state = .writing;
            loop.modify(conn.fd, @ptrCast(conn), false, true) catch {
                loop.remove(conn.fd);
                conn.destroy();
                node = next;
                continue;
            };
            doWrite(loop, conn);
        }
        node = next;
    }
}

const TickCtx = struct { loop: *eventloop.Loop };

fn fireExpired(ctx: TickCtx, node: *timer.Node) void {
    const conn: *Connection = @fieldParentPtr("timer_node", node);
    if (conn.protocol == .websocket) {
        // WS keepalive: a fire means either "send a ping" or "we've
        // gone too long without any inbound frame, give up". The cutoff
        // is twice the ping interval — one missed pong is a network
        // hiccup, two is a dead connection.
        const idle_ns = monoNs() - conn.last_activity_ns;
        const close_threshold = @as(i64, @intCast(g_timeouts.ws_keepalive_secs)) * 2 * std.time.ns_per_s;
        if (conn.last_activity_ns != 0 and idle_ns >= close_threshold) {
            wsTeardown(ctx.loop, conn);
            return;
        }
        // Send ping, re-arm for the next interval. The ping is the
        // smallest legal WS control frame (no payload, FIN=1).
        sendControlFrame(conn, .ping, "") catch {
            wsTeardown(ctx.loop, conn);
            return;
        };
        flushOutbound(ctx.loop, conn);
        conn.armTimer(g_timeouts.ws_keepalive_secs);
        return;
    }
    ctx.loop.remove(conn.fd);
    conn.destroy();
}

fn acceptAll(
    loop: *eventloop.Loop,
    listen_fd: c_int,
    allocator: std.mem.Allocator,
    p: *pool_mod.Pool,
    wheel: *timer.Wheel,
) void {
    while (true) {
        var addr_storage: c.struct_sockaddr_storage = undefined;
        var addr_len: c_uint = @sizeOf(c.struct_sockaddr_storage);
        const client = accept4(
            listen_fd,
            @ptrCast(&addr_storage),
            &addr_len,
            c.SOCK_NONBLOCK | c.SOCK_CLOEXEC,
        );
        if (client < 0) return; // EAGAIN: drained the backlog

        // Bound the number of in-flight connections. We have to accept the
        // socket to drain the kernel backlog, but if we're already at the
        // configured cap we close it immediately — the client sees a
        // server-side connection close (no orderly HTTP response, since
        // we haven't read anything yet).
        if (g_active_conns.load(.seq_cst) >= g_limits.max_concurrent_connections) {
            _ = c.close(client);
            continue;
        }
        _ = g_active_conns.fetchAdd(1, .seq_cst);

        const conn = Connection.create(allocator, p, client, wheel) catch {
            _ = c.close(client);
            _ = g_active_conns.fetchSub(1, .seq_cst);
            continue;
        };
        if (peerKey(&addr_storage)) |key| {
            conn.peer_key = key;
            conn.has_peer_key = true;
            // Per-IP connection cap. Decision is taken now, before
            // SSL handshake or any Python work — over-cap peers pay
            // the cheapest possible cost (a TCP RST). Skipped when
            // `proxy_protocol` is on — the real client IP isn't
            // known yet (TCP peer is the proxy); the cap is re-checked
            // after the PROXY header is parsed.
            if (!g_obs.proxy_protocol) {
                const acq = perIpConnAcquire(&conn.peer_key, monoNs());
                if (acq.over_cap) {
                    conn.destroy();
                    continue;
                }
                conn.rl_entry_idx = acq.entry_idx;
            }
        }
        // Disable Nagle: most ASGI responses are a single small chunk,
        // so coalescing 40 ms before flushing only adds latency. Best-
        // effort — failure isn't worth tearing the connection down. UDS
        // sockets ignore this option (TCP-only setsockopt).
        var tcp_nodelay: c_int = 1;
        _ = c.setsockopt(
            client,
            c.IPPROTO_TCP,
            c.TCP_NODELAY,
            @ptrCast(&tcp_nodelay),
            @sizeOf(c_int),
        );
        // SO_KEEPALIVE: kernel sends periodic probes on idle connections
        // so dead peers (NAT timeouts, mobile-network drops, hard
        // crashes) don't hold a Connection struct hostage for the full
        // `keep_alive_secs` window. Default kernel cadence is generous
        // (~2 hours idle then probes), but it's strictly better than
        // nothing and the wakeup is free for live connections.
        _ = c.setsockopt(
            client,
            c.SOL_SOCKET,
            c.SO_KEEPALIVE,
            @ptrCast(&tcp_nodelay),
            @sizeOf(c_int),
        );
        // Tunable keepalive cadence — only set the values the operator
        // explicitly opted into. Kernel defaults (7200 s idle, 75 s
        // interval, 9 probes) are usually fine for LAN traffic but too
        // generous for mobile / NAT-heavy fronts.
        if (g_limits.tcp_keepidle > 0) {
            var v = g_limits.tcp_keepidle;
            _ = c.setsockopt(client, c.IPPROTO_TCP, c.TCP_KEEPIDLE, @ptrCast(&v), @sizeOf(c_int));
        }
        if (g_limits.tcp_keepintvl > 0) {
            var v = g_limits.tcp_keepintvl;
            _ = c.setsockopt(client, c.IPPROTO_TCP, c.TCP_KEEPINTVL, @ptrCast(&v), @sizeOf(c_int));
        }
        if (g_limits.tcp_keepcnt > 0) {
            var v = g_limits.tcp_keepcnt;
            _ = c.setsockopt(client, c.IPPROTO_TCP, c.TCP_KEEPCNT, @ptrCast(&v), @sizeOf(c_int));
        }
        if (g_limits.tcp_user_timeout_ms > 0) {
            var v: c_uint = @intCast(g_limits.tcp_user_timeout_ms);
            _ = c.setsockopt(client, c.IPPROTO_TCP, c.TCP_USER_TIMEOUT, @ptrCast(&v), @sizeOf(c_uint));
        }

        // For TLS: attach a fresh SSL session to the new fd and start the
        // handshake on the next event. SSL_accept will signal WANT_READ on
        // an empty socket, which is exactly what we need.
        if (g_tls_ctx) |ctx| {
            if (tls.newSsl(ctx, client)) |ssl| {
                conn.ssl = ssl;
                conn.state = .handshaking;
            } else {
                conn.destroy();
                continue;
            }
        }

        // PROXY protocol v1 handshake. Read the line plaintext from
        // the socket BEFORE TLS is started (the LB sends it as the
        // first thing after the TCP handshake). State transitions to
        // .handshaking / .reading once parsed.
        if (g_obs.proxy_protocol) {
            conn.state = .proxy_pending;
        }

        loop.add(client, @ptrCast(conn), true, false) catch {
            conn.destroy();
            continue;
        };

        // Slowloris guard: bound the time spent reaching "headers parsed"
        // (or, for TLS, finishing the handshake before headers).
        conn.armTimer(g_timeouts.header_secs);
    }
}

fn handleConnEvent(loop: *eventloop.Loop, conn: *Connection, ev: eventloop.Event) void {
    if (ev.closed) {
        if (conn.protocol == .websocket) {
            wsTeardown(loop, conn);
        } else {
            loop.remove(conn.fd);
            conn.destroy();
        }
        return;
    }
    // For TLS, OpenSSL's renegotiation can flip what kind of event it wants
    // (read vs write) mid-stream. We always advance based on `state`, not on
    // which event woke us — the connRead / connWrite helpers map back to
    // EPOLL interest after each call.
    switch (conn.state) {
        .proxy_pending => if (ev.readable or ev.writable) doProxyV1(loop, conn),
        .handshaking => doHandshake(loop, conn),
        .reading => if (ev.readable or ev.writable) doRead(loop, conn),
        .writing => if (ev.readable or ev.writable) doWrite(loop, conn),
    }
}

/// PROXY-protocol v2 binary signature: 12 bytes the LB sends before
/// any other byte. Lets us auto-detect v1 (text) vs v2 from the first
/// 12 bytes — v1 starts `"PROXY "`, v2 starts with this signature.
const PROXY_V2_SIG = "\r\n\r\n\x00\r\nQUIT\n";

/// Read + parse the PROXY-protocol v1 (text) or v2 (binary) header.
/// Called repeatedly from the main loop until the header completes.
/// Once parsed, replaces `conn.peer_key` with the source-side address
/// from the header, re-checks the per-IP connection cap, and
/// transitions to `.handshaking` (TLS) or `.reading` (plain). Bytes
/// received past the PROXY header are kept in `read_buf` for the HTTP
/// parser to consume on the next iteration. We use the regular
/// `read_buf` pool rather than a per-conn dedicated buffer so a
/// connection that never sends the PROXY line costs no extra RAM.
fn doProxyV1(loop: *eventloop.Loop, conn: *Connection) void {
    conn.ensureBuffer() catch {
        loop.remove(conn.fd);
        conn.destroy();
        return;
    };
    const data = conn.read_buf.?.data;

    // Read more if needed. v1 max = 107 bytes; v2 = 16 + payload (max
    // 255 + extras). Read up to 256 bytes and parse what we have.
    const READ_CAP: usize = 256;
    while (conn.read_total < READ_CAP) {
        const remaining = data[conn.read_total..@min(data.len, READ_CAP)];
        if (remaining.len == 0) break;
        const cret = c.read(conn.fd, @ptrCast(remaining.ptr), remaining.len);
        if (cret == 0) {
            loop.remove(conn.fd);
            conn.destroy();
            return;
        }
        if (cret < 0) return; // EAGAIN
        conn.read_total += @intCast(cret);
        // Stop reading early when we have a complete header.
        if (conn.read_total >= PROXY_V2_SIG.len and
            std.mem.eql(u8, data[0..PROXY_V2_SIG.len], PROXY_V2_SIG))
        {
            // v2 — need 16 header bytes + payload length.
            if (conn.read_total < 16) continue;
            const len_hi: usize = data[14];
            const len_lo: usize = data[15];
            const total = 16 + (len_hi << 8) + len_lo;
            if (conn.read_total >= total) break;
            if (total > READ_CAP) {
                loop.remove(conn.fd);
                conn.destroy();
                return;
            }
        } else {
            // v1 — terminator is \r\n.
            if (std.mem.indexOfPos(u8, data[0..conn.read_total], 0, "\r\n") != null) break;
            if (conn.read_total >= 108) break;
        }
    }

    var consumed: usize = 0;
    if (conn.read_total >= PROXY_V2_SIG.len and
        std.mem.eql(u8, data[0..PROXY_V2_SIG.len], PROXY_V2_SIG))
    {
        // PROXY v2 binary header: 12-byte sig, ver+cmd byte, fam+proto
        // byte, 2-byte length, then variable-length address block.
        if (conn.read_total < 16) {
            loop.remove(conn.fd);
            conn.destroy();
            return;
        }
        const ver_cmd = data[12];
        const fam_proto = data[13];
        const len_hi: usize = data[14];
        const len_lo: usize = data[15];
        const payload_len = (len_hi << 8) + len_lo;
        const total = 16 + payload_len;
        if (conn.read_total < total) {
            loop.remove(conn.fd);
            conn.destroy();
            return;
        }
        // ver_cmd: high nibble = version (must be 2), low = command
        // (0 LOCAL — health-check, ignore addr; 1 PROXY).
        if ((ver_cmd >> 4) != 2) {
            loop.remove(conn.fd);
            conn.destroy();
            return;
        }
        const cmd = ver_cmd & 0x0F;
        const family = fam_proto >> 4;
        if (cmd == 1) {
            // Real PROXY connection. Decode src by family.
            // family 1 = AF_INET, 2 = AF_INET6.
            if (family == 1 and payload_len >= 12) {
                var key: [16]u8 = std.mem.zeroes([16]u8);
                key[10] = 0xff;
                key[11] = 0xff;
                @memcpy(key[12..16], data[16..20]); // src IPv4
                conn.peer_key = key;
                conn.has_peer_key = true;
            } else if (family == 2 and payload_len >= 36) {
                var key: [16]u8 = undefined;
                @memcpy(&key, data[16..32]); // src IPv6
                conn.peer_key = key;
                conn.has_peer_key = true;
            }
            // family 0 (UNSPEC) or 3 (AF_UNIX): keep TCP peer.
        }
        consumed = total;
        _ = g_proxy_proto_accepted_v2_total.fetchAdd(1, .seq_cst);
    } else {
        // PROXY v1 text format.
        const buf = data[0..conn.read_total];
        const crlf = std.mem.indexOfPos(u8, buf, 0, "\r\n") orelse {
            if (conn.read_total < 107) return; // keep reading
            loop.remove(conn.fd);
            conn.destroy();
            return;
        };
        const line = buf[0..crlf];

        if (line.len < 6 or !std.mem.eql(u8, line[0..6], "PROXY ")) {
            loop.remove(conn.fd);
            conn.destroy();
            return;
        }

        var it = std.mem.tokenizeScalar(u8, line[6..], ' ');
        const family = it.next() orelse {
            loop.remove(conn.fd);
            conn.destroy();
            return;
        };
        if (std.mem.eql(u8, family, "UNKNOWN")) {
            // No reliable client IP; keep TCP peer.
        } else if (std.mem.eql(u8, family, "TCP4") or std.mem.eql(u8, family, "TCP6")) {
            const src_str = it.next() orelse {
                loop.remove(conn.fd);
                conn.destroy();
                return;
            };
            if (parseFirstForwardedIp(src_str)) |key| {
                conn.peer_key = key;
                conn.has_peer_key = true;
            }
        } else {
            loop.remove(conn.fd);
            conn.destroy();
            return;
        }
        consumed = crlf + 2;
        _ = g_proxy_proto_accepted_v1_total.fetchAdd(1, .seq_cst);
    }

    // Re-check the per-IP connection cap now that we know the real
    // client. Skipped at accept-time when proxy_protocol is on.
    if (g_limits.max_connections_per_ip > 0 and conn.has_peer_key) {
        const acq = perIpConnAcquire(&conn.peer_key, monoNs());
        if (acq.over_cap) {
            loop.remove(conn.fd);
            conn.destroy();
            return;
        }
        conn.rl_entry_idx = acq.entry_idx;
    }

    // Compact the read buffer past the PROXY header. Subsequent bytes
    // (the HTTP request, if any has arrived already) start at index 0.
    const leftover = conn.read_total - consumed;
    if (leftover > 0) {
        std.mem.copyForwards(u8, data[0..leftover], data[consumed .. consumed + leftover]);
    }
    conn.read_total = leftover;

    // Transition to the next phase. TLS connections do the handshake
    // first; plaintext go straight to reading HTTP.
    if (conn.ssl != null) {
        conn.state = .handshaking;
        doHandshake(loop, conn);
    } else {
        conn.state = .reading;
        // If the HTTP request arrived in the same packet as the PROXY
        // line, kick the parser immediately — there's no edge-trigger
        // event coming.
        if (leftover > 0) doReadHttp(loop, conn);
    }
}

fn doHandshake(loop: *eventloop.Loop, conn: *Connection) void {
    const ssl = conn.ssl.?;
    switch (tls.handshake(ssl)) {
        .ok => {
            // v1.6: count completed TLS handshakes + session reuses for
            // /metrics. A second .ok event for the same connection would
            // be the rare TLS-renegotiation case; we don't try to filter
            // it out — the counter is a rate, not an exact handshake-per-
            // accept tally.
            _ = g_tls_handshakes_total.fetchAdd(1, .seq_cst);
            if (tls.sessionReused(ssl)) {
                _ = g_tls_session_reuse_total.fetchAdd(1, .seq_cst);
            }
            conn.state = .reading;
            loop.modify(conn.fd, @ptrCast(conn), true, false) catch {
                loop.remove(conn.fd);
                conn.destroy();
            };
        },
        .want_read => {
            loop.modify(conn.fd, @ptrCast(conn), true, false) catch {
                loop.remove(conn.fd);
                conn.destroy();
            };
        },
        .want_write => {
            loop.modify(conn.fd, @ptrCast(conn), false, true) catch {
                loop.remove(conn.fd);
                conn.destroy();
            };
        },
        .closed, .fatal => {
            loop.remove(conn.fd);
            conn.destroy();
        },
    }
}

/// Plaintext or TLS read. Returns one of:
///   - .ok with `n` bytes appended to `buf`
///   - .would_block / .want_read: caller should keep epoll on read
///   - .want_write: caller should switch epoll to write (TLS renegotiation)
///   - .closed / .fatal: caller should close the connection
const IoStatus = enum { ok, would_block, want_read, want_write, closed, fatal };

fn connRead(conn: *Connection, buf: []u8) struct { status: IoStatus, n: usize } {
    if (conn.ssl) |ssl| {
        const r = tls.read(ssl, buf);
        return .{
            .status = switch (r.status) {
                .ok => .ok,
                .want_read => .want_read,
                .want_write => .want_write,
                .closed => .closed,
                .fatal => .fatal,
            },
            .n = r.n,
        };
    }
    const cret = c.read(conn.fd, @ptrCast(buf.ptr), buf.len);
    if (cret == 0) return .{ .status = .closed, .n = 0 };
    if (cret < 0) return .{ .status = .would_block, .n = 0 };
    return .{ .status = .ok, .n = @intCast(cret) };
}

fn connWrite(conn: *Connection, buf: []const u8) struct { status: IoStatus, n: usize } {
    if (conn.ssl) |ssl| {
        const r = tls.write(ssl, buf);
        return .{
            .status = switch (r.status) {
                .ok => .ok,
                .want_read => .want_read,
                .want_write => .want_write,
                .closed => .closed,
                .fatal => .fatal,
            },
            .n = r.n,
        };
    }
    const cret = c.write(conn.fd, @ptrCast(buf.ptr), buf.len);
    if (cret == 0) return .{ .status = .closed, .n = 0 };
    if (cret < 0) return .{ .status = .would_block, .n = 0 };
    return .{ .status = .ok, .n = @intCast(cret) };
}

/// Honour `Expect: 100-continue` by writing the interim response straight
/// to the socket. Called between parse-success and body-wait. Synchronous —
/// the 25-byte preamble effectively never returns EAGAIN on a fresh
/// connection. Returns false on any I/O failure so the caller can tear
/// the connection down.
fn sendContinue(conn: *Connection) bool {
    const preamble = "HTTP/1.1 100 Continue\r\n\r\n";
    var written: usize = 0;
    while (written < preamble.len) {
        const r = connWrite(conn, preamble[written..]);
        switch (r.status) {
            .ok => written += r.n,
            else => return false,
        }
    }
    return true;
}

/// True iff the request advertised `Expect: 100-continue` (case-insensitive,
/// surrounding whitespace tolerated). RFC 7231 §5.1.1.
fn wantsExpectContinue(req: http.Request) bool {
    const v = req.header("expect") orelse return false;
    const trimmed = std.mem.trim(u8, v, " \t");
    return std.ascii.eqlIgnoreCase(trimmed, "100-continue");
}

fn epollWantRead(loop: *eventloop.Loop, conn: *Connection) void {
    loop.modify(conn.fd, @ptrCast(conn), true, false) catch {
        loop.remove(conn.fd);
        conn.destroy();
    };
}

fn epollWantWrite(loop: *eventloop.Loop, conn: *Connection) void {
    loop.modify(conn.fd, @ptrCast(conn), false, true) catch {
        loop.remove(conn.fd);
        conn.destroy();
    };
}

fn doRead(loop: *eventloop.Loop, conn: *Connection) void {
    conn.ensureBuffer() catch {
        // For WS we don't have a clean status path — just close.
        if (conn.protocol == .websocket) {
            loop.remove(conn.fd);
            conn.destroy();
            return;
        }
        sendStatus(loop, conn, 503, "Service Unavailable");
        return;
    };

    switch (conn.protocol) {
        .http => doReadHttp(loop, conn),
        .websocket => doReadWs(loop, conn),
    }
}

fn doReadHttp(loop: *eventloop.Loop, conn: *Connection) void {
    // v1.4: when the connection is mid-body-streaming, route reads
    // to the push-more-body path instead of trying to re-parse
    // headers. Headers + status are already in flight on the Python
    // side; we just feed it more bytes.
    if (conn.body_streaming) {
        return streamReceiveMore(loop, conn);
    }
    var data = conn.read_buf.?.data;

    while (true) {
        const remaining = data[conn.read_total..];
        if (remaining.len == 0) {
            // Buffer full and we still don't have a complete head. If we're
            // on the small buffer, upgrade to the large one and keep going;
            // otherwise the headers genuinely don't fit (431).
            if (conn.parsed == null and data.len < pool_mod.LARGE_DATA_SIZE) {
                conn.upgradeBuffer() catch {
                    sendStatus(loop, conn, 503, "Service Unavailable");
                    return;
                };
                data = conn.read_buf.?.data;
                continue;
            }
            sendStatus(loop, conn, 431, "Request Header Fields Too Large");
            return;
        }

        const r = connRead(conn, remaining);
        switch (r.status) {
            .ok => {},
            .would_block, .want_read => {
                if (conn.ssl != null) epollWantRead(loop, conn);
                return;
            },
            .want_write => {
                epollWantWrite(loop, conn);
                return;
            },
            .closed, .fatal => {
                loop.remove(conn.fd);
                conn.destroy();
                return;
            },
        }
        conn.read_total += r.n;

        // v1.4 explicit head-bytes cap. The implicit ceiling is the
        // pool buffer size (~16 KiB small / 64 KiB large); this lets
        // operators tighten that further. Fires before we even try
        // to parse, so malicious clients sending header-storms get
        // dropped without waiting for the parser.
        if (conn.parsed == null and g_limits.max_request_head_bytes > 0 and
            conn.read_total > g_limits.max_request_head_bytes)
        {
            sendStatus(loop, conn, 431, "Request Header Fields Too Large");
            return;
        }

        if (conn.parsed == null) {
            if (http.parse(data[0..conn.read_total], &conn.read_buf.?.headers)) |req| {
                // v1.4 414 URI Too Long. Cheaper to check here (post-parse)
                // than mid-parse — the request line was already isolated.
                if (g_limits.max_request_uri > 0 and req.target.len > g_limits.max_request_uri) {
                    sendStatus(loop, conn, 414, "URI Too Long");
                    return;
                }
                conn.parsed = req;
                conn.body_offset = req.body_offset;
                if (req.is_chunked) {
                    conn.chunk_state = http.ChunkState.init();
                    conn.chunk_consumed = 0;
                    conn.chunk_decoded = 0;
                } else {
                    conn.body_len = req.content_length orelse 0;
                    if (conn.body_len > g_limits.max_request_body) {
                        sendStatus(loop, conn, 413, "Content Too Large");
                        return;
                    }
                    if (conn.body_offset + conn.body_len > data.len) {
                        // The declared body doesn't fit the current buffer.
                        // v1.4 changes default behaviour: if the body
                        // exceeds the LARGE_DATA_SIZE buffer ceiling,
                        // engage streaming dispatch instead of 413'ing.
                        // Apps see chunked `more_body=True` events and
                        // RAM stays bounded by the dispatcher's
                        // backpressure threshold (64 KiB), not the
                        // declared body length.
                        if (data.len < pool_mod.LARGE_DATA_SIZE and
                            conn.body_offset + conn.body_len <= pool_mod.LARGE_DATA_SIZE)
                        {
                            // Body fits in the large buffer — upgrade
                            // and continue buffering as before.
                            conn.parsed = null;
                            conn.upgradeBuffer() catch {
                                sendStatus(loop, conn, 503, "Service Unavailable");
                                return;
                            };
                            data = conn.read_buf.?.data;
                            const reparsed = http.parse(data[0..conn.read_total], &conn.read_buf.?.headers) catch {
                                sendStatus(loop, conn, 400, "Bad Request");
                                return;
                            };
                            conn.parsed = reparsed;
                            conn.body_offset = reparsed.body_offset;
                            conn.body_len = reparsed.content_length orelse 0;
                        }
                        // else: body too big for any buffer → fall
                        // through to dispatch below. The streaming path
                        // engages because `read_total - body_offset <
                        // body_len` will be true.
                    }
                }
                // Honour `Expect: 100-continue` by writing the interim
                // response immediately so the client sends the body. We do
                // this *after* the body-size cap check so we never invite
                // the client to send a body we won't accept.
                if (wantsExpectContinue(req)) {
                    if (!sendContinue(conn)) {
                        loop.remove(conn.fd);
                        conn.destroy();
                        return;
                    }
                }
                // Headers parsed: switch from header_timeout to body_timeout.
                // If the body is already complete in this iteration, dispatch
                // will arm write_timeout and overwrite this — harmless.
                conn.armTimer(g_timeouts.body_secs);
            } else |err| switch (err) {
                error.Incomplete => continue,
                else => {
                    std.log.warn("parse failed: {s}", .{@errorName(err)});
                    sendStatus(loop, conn, 400, "Bad Request");
                    return;
                },
            }
        }

        // Body phase. Two paths: chunked Transfer-Encoding decodes in place,
        // Content-Length just waits for `body_len` more bytes.
        if (conn.parsed.?.is_chunked) {
            const body_buf = data[conn.body_offset..];
            const body_buf_len = conn.read_total - conn.body_offset;
            switch (http.decodeChunkedInPlace(
                body_buf,
                body_buf_len,
                &conn.chunk_state,
                &conn.chunk_consumed,
                &conn.chunk_decoded,
            )) {
                .needs_more => {
                    // For chunked we can't know the final size up-front;
                    // bound the in-progress decoded length against the cap
                    // so a slow drip-stream can't exceed our budget.
                    if (conn.chunk_decoded > g_limits.max_request_body) {
                        sendStatus(loop, conn, 413, "Content Too Large");
                        return;
                    }
                    continue;
                },
                .done => {
                    conn.body_len = conn.chunk_decoded;
                    if (conn.body_len > g_limits.max_request_body) {
                        sendStatus(loop, conn, 413, "Content Too Large");
                        return;
                    }
                    dispatch(loop, conn);
                    return;
                },
                .invalid => {
                    std.log.warn("chunked decode failed", .{});
                    sendStatus(loop, conn, 400, "Bad Request");
                    return;
                },
            }
        } else {
            if (conn.read_total >= conn.body_offset + conn.body_len) {
                // Whole body buffered → fully-buffered dispatch.
                dispatch(loop, conn);
                return;
            }
            // v1.4: if the body won't fit the buffer, stream it.
            // We engage streaming as soon as we know the buffer is
            // smaller than the declared body — that's the only case
            // the buffered path can't handle.
            if (conn.body_offset + conn.body_len > data.len) {
                dispatchStreaming(loop, conn);
                return;
            }
            // else: loop and read more
        }
    }
}

fn dispatch(loop: *eventloop.Loop, conn: *Connection) void {
    dispatchWithBody(loop, conn, false);
}

/// v1.4 body-streaming entry point. Called from `doReadHttp` when the
/// declared `Content-Length` doesn't fit the read buffer. Passes the
/// bytes received so far + `more_body=true`; subsequent reads on this
/// connection push more chunks via `streamReceiveMore`.
fn dispatchStreaming(loop: *eventloop.Loop, conn: *Connection) void {
    conn.body_streaming = true;
    conn.body_streaming_consumed = conn.read_total - conn.body_offset;
    dispatchWithBody(loop, conn, true);
}

/// Push subsequent body bytes into the running ASGI task. Called by
/// the read path while `conn.body_streaming` is true. Reads what's
/// available, calls `bridge.httpDispatchPushBody`, advances
/// `body_streaming_consumed`. When the consumed counter hits the
/// declared `body_len`, sends a final `more_body=False` and clears
/// the streaming flag so the connection can transition to writing
/// (the dispatch task itself drives the response, exactly like the
/// fully-buffered path).
fn streamReceiveMore(loop: *eventloop.Loop, conn: *Connection) void {
    const data = conn.read_buf.?.data;
    // Reuse the buffer head as a scratch landing zone — the bytes
    // we already pushed don't need to stick around. read_total
    // always reflects "bytes currently in the buffer not yet pushed".
    while (true) {
        const remaining_buf = data[conn.read_total..];
        if (remaining_buf.len == 0) {
            // Buffer full of un-pushed bytes — push everything and
            // reset the buffer.
            const chunk = data[0..conn.read_total];
            const expected_more = (conn.body_streaming_consumed + chunk.len) < conn.body_len;
            const tick = bridge.httpDispatchPushBody(conn.dispatch_handle, chunk, expected_more, conn.allocator) orelse {
                loop.remove(conn.fd);
                conn.destroy();
                return;
            };
            conn.body_streaming_consumed += chunk.len;
            conn.read_total = 0;
            // Apply enforced cap.
            if (conn.body_streaming_consumed > g_limits.max_request_body) {
                if (tick.chunks.len > 0) conn.allocator.free(tick.chunks);
                return sendStatus(loop, conn, 413, "Content Too Large");
            }
            // If push produced wire bytes (rare — most apps await
            // full body before sending) hand them to the writer.
            if (tick.chunks.len > 0) {
                if (conn.write_buf.len > 0) conn.allocator.free(conn.write_buf);
                conn.write_buf = tick.chunks;
                conn.write_pos = 0;
                conn.dispatch_active = !tick.done;
                conn.state = .writing;
                conn.body_streaming = false;
                conn.armTimer(g_timeouts.write_secs);
                loop.modify(conn.fd, @ptrCast(conn), false, true) catch {
                    loop.remove(conn.fd);
                    conn.destroy();
                    return;
                };
                doWrite(loop, conn);
                return;
            }
            // No output yet — keep reading.
            if (!expected_more) {
                // Body fully delivered; switch to writing/stalled.
                conn.body_streaming = false;
                conn.state = .writing;
                conn.armTimer(g_timeouts.write_secs);
                loop.modify(conn.fd, @ptrCast(conn), false, true) catch {
                    loop.remove(conn.fd);
                    conn.destroy();
                    return;
                };
                doWrite(loop, conn);
                return;
            }
            continue;
        }

        const r = connRead(conn, remaining_buf);
        switch (r.status) {
            .ok => conn.read_total += r.n,
            .would_block, .want_read => {
                if (conn.ssl != null) epollWantRead(loop, conn);
                return;
            },
            .want_write => {
                epollWantWrite(loop, conn);
                return;
            },
            .closed, .fatal => {
                loop.remove(conn.fd);
                conn.destroy();
                return;
            },
        }

        // Push whatever just arrived plus any leftover.
        const chunk = data[0..conn.read_total];
        const next_consumed = conn.body_streaming_consumed + chunk.len;
        const more_body = next_consumed < conn.body_len;
        const tick = bridge.httpDispatchPushBody(conn.dispatch_handle, chunk, more_body, conn.allocator) orelse {
            loop.remove(conn.fd);
            conn.destroy();
            return;
        };
        conn.body_streaming_consumed = next_consumed;
        conn.read_total = 0;
        if (conn.body_streaming_consumed > g_limits.max_request_body) {
            if (tick.chunks.len > 0) conn.allocator.free(tick.chunks);
            return sendStatus(loop, conn, 413, "Content Too Large");
        }

        if (tick.chunks.len > 0) {
            if (conn.write_buf.len > 0) conn.allocator.free(conn.write_buf);
            conn.write_buf = tick.chunks;
            conn.write_pos = 0;
            conn.dispatch_active = !tick.done;
            conn.state = .writing;
            conn.body_streaming = false;
            conn.armTimer(g_timeouts.write_secs);
            loop.modify(conn.fd, @ptrCast(conn), false, true) catch {
                loop.remove(conn.fd);
                conn.destroy();
                return;
            };
            doWrite(loop, conn);
            return;
        }

        if (!more_body) {
            conn.body_streaming = false;
            conn.state = .writing;
            conn.armTimer(g_timeouts.write_secs);
            loop.modify(conn.fd, @ptrCast(conn), false, true) catch {
                loop.remove(conn.fd);
                conn.destroy();
                return;
            };
            doWrite(loop, conn);
            return;
        }
        // else: keep reading more chunks.
    }
}

fn dispatchWithBody(loop: *eventloop.Loop, conn: *Connection, more_body: bool) void {
    const req = conn.parsed.?;

    // RFC 7230 §5.4: HTTP/1.1 requests MUST carry a non-empty Host
    // header. A missing or empty value is a 400. HTTP/1.0 has no such
    // requirement (predates virtual hosting). Cheap check here so user
    // apps don't have to defend against malformed requests.
    if (req.version_minor >= 1) {
        const host = req.header("host") orelse {
            return sendStatus(loop, conn, 400, "Bad Request");
        };
        if (std.mem.trim(u8, host, " \t").len == 0) {
            return sendStatus(loop, conn, 400, "Bad Request");
        }
    }

    if (req.isWebSocketUpgrade()) {
        return startWebSocket(loop, conn);
    }

    // Per-request metrics bookkeeping. Cheap atomics; no Python touched.
    _ = g_total_requests.fetchAdd(1, .seq_cst);
    _ = g_in_flight.fetchAdd(1, .seq_cst);
    conn.request_in_flight = true;
    conn.bytes_sent = 0;
    conn.response_status = 0;
    conn.request_start_ns = if (g_obs.access_log or g_obs.latency_histogram) monoNs() else 0;

    // Approximate request bytes received: header bytes parsed + declared
    // body length. Misses bytes from rejected (413, 400) requests but is
    // good enough for the Prometheus counter.
    _ = g_total_bytes_received.fetchAdd(
        conn.body_offset + conn.body_len,
        .seq_cst,
    );

    // Internal endpoints (only when explicitly opted in).
    if (g_obs.metrics_path) |path| {
        if (std.mem.eql(u8, req.target, path)) {
            return serveMetrics(loop, conn);
        }
    }
    if (g_obs.health_path) |path| {
        if (std.mem.eql(u8, req.target, path)) {
            return serveHealth(loop, conn);
        }
    }
    if (g_obs.tracemalloc_path) |path| {
        if (std.mem.eql(u8, req.target, path)) {
            return serveTracemalloc(loop, conn);
        }
    }
    if (g_obs.dispatch_path) |path| {
        if (std.mem.eql(u8, req.target, path)) {
            return serveDispatch(loop, conn);
        }
    }
    if (g_obs.drain_path) |path| {
        if (std.mem.eql(u8, req.target, path)) {
            return serveDrainEndpoint(loop, conn);
        }
    }
    if (g_obs.cors_preflight_allow_all and
        std.mem.eql(u8, req.method, "OPTIONS") and
        req.header("origin") != null)
    {
        return serveCorsPreflight(loop, conn);
    }
    if (g_obs.favicon_204 and
        std.mem.eql(u8, req.target, "/favicon.ico") and
        (std.mem.eql(u8, req.method, "GET") or std.mem.eql(u8, req.method, "HEAD")))
    {
        return serveFavicon(loop, conn);
    }

    // Per-IP rate limit. Cheap when disabled (single u32 compare). When
    // `proxy_headers` is enabled and the request carries an X-Forwarded-
    // For, we rate-limit by the leftmost forwarded address rather than
    // the TCP peer IP — otherwise every request behind a reverse proxy
    // gets bucketed under the proxy's IP and the limit is meaningless.
    if (g_limits.rate_limit_per_sec > 0) {
        var rl_key: [16]u8 = undefined;
        var rl_have_key = false;
        if (g_obs.proxy_headers) {
            // X-Real-IP (single IP) wins over X-Forwarded-For (chain),
            // matching the Python-side ASGI scope-build precedence.
            if (req.header("x-real-ip")) |xri| {
                if (parseFirstForwardedIp(xri)) |xri_key| {
                    rl_key = xri_key;
                    rl_have_key = true;
                }
            }
            if (!rl_have_key) {
                if (req.header("x-forwarded-for")) |xff| {
                    if (parseFirstForwardedIp(xff)) |xff_key| {
                        rl_key = xff_key;
                        rl_have_key = true;
                    }
                }
            }
        }
        if (!rl_have_key and conn.has_peer_key) {
            rl_key = conn.peer_key;
            rl_have_key = true;
        }
        if (rl_have_key) {
            if (!rateLimitAllow(&rl_key, monoNs())) {
                return sendStatus(loop, conn, 429, "Too Many Requests");
            }
        }
    }

    const data = conn.read_buf.?.data;
    // For fully-buffered requests, body slice is `[body_offset,
    // body_offset+body_len)`. For streaming, only what we've already
    // received: `[body_offset, read_total)`.
    const body_end = if (more_body) conn.read_total else conn.body_offset + conn.body_len;
    const body = data[conn.body_offset..body_end];
    var keep_alive = req.wantsKeepAlive();
    // Recycle the connection once we've served `max_keepalive_requests` on
    // it. Forces this response's `Connection: close` and bypasses the
    // keep-alive reset path. Helps bound CPython arena fragmentation that
    // accumulates over very long-lived connections.
    if (conn.keepalive_request_count + 1 >= g_limits.max_keepalive_requests) {
        keep_alive = false;
    }
    // Wall-clock connection lifetime cap. Stricter than the request-
    // count cap above — bounds RAM held by per-conn state in
    // pathological clients that hold a connection open for hours.
    if (g_limits.max_connection_lifetime_secs > 0) {
        const age_ns = monoNs() - conn.accepted_ns;
        const cap_ns = @as(i64, @intCast(g_limits.max_connection_lifetime_secs)) * std.time.ns_per_s;
        if (age_ns >= cap_ns) keep_alive = false;
    }

    // v1.4: `more_body=true` means the dispatcher should expect
    // subsequent `http_dispatch_push_body` calls — body streaming
    // is engaged. For fully-buffered requests this stays false (the
    // app sees the whole body in one event).
    const start = bridge.httpDispatchStart(req, body, more_body, keep_alive, conn.allocator) orelse {
        sendStatus(loop, conn, 500, "Internal Server Error");
        return;
    };

    conn.dispatch_handle = start.handle;
    conn.dispatch_active = !start.done;
    conn.keep_alive = keep_alive;

    if (start.done) {
        // v1.4: app may have emitted `saltare.sendfile` instead of
        // `http.response.body` — Zig opens the file, sendfile(2)s
        // the body straight to the socket without bouncing bytes
        // through Python.
        if (bridge.httpDispatchPopSendfile(start.handle, conn.allocator)) |sf| {
            defer conn.allocator.free(sf.path);
            defer conn.allocator.free(sf.headers_block);
            // We've already taken responsibility for the dispatch
            // task — clear the bridge handle so destroy() doesn't
            // try to abort it.
            conn.dispatch_handle = 0;
            conn.dispatch_active = false;
            if (start.chunks.len > 0) conn.allocator.free(start.chunks);
            return serveSendfile(loop, conn, sf);
        }
    }

    if (start.chunks.len == 0 and start.done) {
        // App returned without producing wire bytes. Python should have
        // synthesized a 500 (chunks empty would be a bug there). Close.
        loop.remove(conn.fd);
        conn.destroy();
        return;
    }

    if (start.chunks.len > 0) {
        if (conn.write_buf.len > 0) conn.allocator.free(conn.write_buf);
        conn.write_buf = start.chunks;
        conn.write_pos = 0;
        // First chunks of a streaming response always begin with the wire
        // status line. Parse it once so the access log + status counters
        // see the right code.
        if (conn.response_status == 0) {
            conn.response_status = parseStatus(start.chunks);
        }
    }

    conn.state = .writing;
    conn.armTimer(g_timeouts.write_secs);

    loop.modify(conn.fd, @ptrCast(conn), false, true) catch {
        loop.remove(conn.fd);
        conn.destroy();
        return;
    };

    doWrite(loop, conn);
}

/// Validate the WebSocket upgrade request, ask the Python ws_open to start
/// the coroutine, and (if accepted) build the 101 Switching Protocols
/// response. After writing, the connection enters `.websocket` mode.
fn startWebSocket(loop: *eventloop.Loop, conn: *Connection) void {
    const req = conn.parsed.?;

    const opened = bridge.wsOpen(req, conn.allocator) orelse {
        sendStatus(loop, conn, 500, "Internal Server Error");
        return;
    };
    // Subprotocol + extensions buffers owned by us; free in every
    // exit branch.
    defer if (opened.subprotocol.len > 0) conn.allocator.free(opened.subprotocol);
    defer if (opened.extensions.len > 0) conn.allocator.free(opened.extensions);
    // v1.7: close_reason is empty in the accept path; defer-free here so
    // the reject-branch's explicit free + this defer never double-up
    // (the reject branch sets reason.len = 0 before returning by freeing
    // and not nulling, but we early-return before this defer runs).
    defer if (opened.close_reason.len > 0) conn.allocator.free(opened.close_reason);
    conn.ws_pmd_active = opened.pmd_active;

    if (!opened.accepted) {
        // App rejected by closing without accepting.
        // v1.7: map the WebSocket close code (RFC 6455 §7.4 — apps
        // typically use 4xxx Private codes) to a meaningful HTTP status
        // so clients see something better than a flat 403. Channels'
        // AuthMiddleware uses 4003 (Origin reject), 4001 (auth), etc.
        const status_code: u16 = switch (opened.close_code) {
            4001 => 401,
            4002 => 402,
            4003 => 403,
            4004 => 404,
            4008 => 408,
            4029 => 429,
            else => 403,
        };
        const reason_text: []const u8 = switch (status_code) {
            401 => "Unauthorized",
            402 => "Payment Required",
            404 => "Not Found",
            408 => "Request Timeout",
            429 => "Too Many Requests",
            else => "Forbidden",
        };
        if (g_obs.ws_reject_log) {
            // Single write(2) keeps the line atomic. 4 KiB headroom for
            // path + reason — well past any realistic combination.
            var line_buf: [4096]u8 = undefined;
            const line = std.fmt.bufPrint(
                &line_buf,
                "saltare: ws-reject path={s} code={d} reason={s}\n",
                .{ req.target, opened.close_code, opened.close_reason },
            ) catch line_buf[0..0];
            if (line.len > 0) _ = c.write(2, line.ptr, line.len);
        }
        if (opened.frames.len > 0) conn.allocator.free(opened.frames);
        // close_reason + subprotocol + extensions freed by the defer
        // chain above. Don't free here or we'd double-free at return.
        sendStatus(loop, conn, status_code, reason_text);
        return;
    }

    const client_key = req.header("sec-websocket-key") orelse {
        if (opened.frames.len > 0) conn.allocator.free(opened.frames);
        // Already accepted by Python — make sure it's torn down.
        const final = bridge.wsDisconnect(opened.handle, 1002, conn.allocator);
        if (final.len > 0) conn.allocator.free(final);
        sendStatus(loop, conn, 400, "Bad Request");
        return;
    };
    const trimmed_key = std.mem.trim(u8, client_key, " \t");

    var accept_buf: [28]u8 = undefined;
    const accept = ws.computeAccept(trimmed_key, &accept_buf);

    var resp_buf: [768]u8 = undefined;
    var resp_pos: usize = 0;
    const base = std.fmt.bufPrint(
        resp_buf[resp_pos..],
        "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: {s}\r\n" ++
            "{s}",
        .{ accept, g_server_line },
    ) catch {
        if (opened.frames.len > 0) conn.allocator.free(opened.frames);
        loop.remove(conn.fd);
        conn.destroy();
        return;
    };
    resp_pos += base.len;
    if (opened.subprotocol.len > 0) {
        const line = std.fmt.bufPrint(
            resp_buf[resp_pos..],
            "Sec-WebSocket-Protocol: {s}\r\n",
            .{opened.subprotocol},
        ) catch {
            if (opened.frames.len > 0) conn.allocator.free(opened.frames);
            loop.remove(conn.fd);
            conn.destroy();
            return;
        };
        resp_pos += line.len;
    }
    if (opened.extensions.len > 0) {
        const line = std.fmt.bufPrint(
            resp_buf[resp_pos..],
            "Sec-WebSocket-Extensions: {s}\r\n",
            .{opened.extensions},
        ) catch {
            if (opened.frames.len > 0) conn.allocator.free(opened.frames);
            loop.remove(conn.fd);
            conn.destroy();
            return;
        };
        resp_pos += line.len;
    }
    @memcpy(resp_buf[resp_pos..resp_pos + 2], "\r\n");
    resp_pos += 2;
    const resp = resp_buf[0..resp_pos];

    // Concatenate 101 + any frames the app emitted between accept and the
    // first await receive() (e.g. an immediate `websocket.send`).
    const total = resp.len + opened.frames.len;
    const heap = conn.allocator.alloc(u8, total) catch {
        if (opened.frames.len > 0) conn.allocator.free(opened.frames);
        loop.remove(conn.fd);
        conn.destroy();
        return;
    };
    @memcpy(heap[0..resp.len], resp);
    if (opened.frames.len > 0) {
        @memcpy(heap[resp.len..], opened.frames);
        conn.allocator.free(opened.frames);
    }

    if (conn.write_buf.len > 0) conn.allocator.free(conn.write_buf);
    conn.write_buf = heap;
    conn.write_pos = 0;
    conn.state = .writing;
    conn.protocol = .websocket;
    conn.ws_handle = opened.handle;
    // If the app already finished (called close right after accept), close
    // after we drain the frames; otherwise stay alive.
    conn.keep_alive = !opened.done;
    // Replace the HTTP-phase timer with the WebSocket keepalive cadence.
    // `fireExpired`'s WS branch handles ping-or-teardown logic.
    conn.last_activity_ns = monoNs();
    conn.armTimer(g_timeouts.ws_keepalive_secs);

    loop.modify(conn.fd, @ptrCast(conn), false, true) catch {
        loop.remove(conn.fd);
        conn.destroy();
        return;
    };

    doWrite(loop, conn);
}

fn doWrite(loop: *eventloop.Loop, conn: *Connection) void {
    while (true) {
        // Drain whatever's currently in write_buf.
        while (conn.write_pos < conn.write_buf.len) {
            const remaining = conn.write_buf[conn.write_pos..];
            const r = connWrite(conn, remaining);
            switch (r.status) {
                .ok => {
                    conn.write_pos += r.n;
                    conn.bytes_sent += r.n;
                    _ = g_total_bytes_sent.fetchAdd(r.n, .seq_cst);
                },
                .would_block, .want_write => {
                    if (conn.ssl != null) epollWantWrite(loop, conn);
                    return;
                },
                .want_read => {
                    epollWantRead(loop, conn);
                    return;
                },
                .closed, .fatal => {
                    loop.remove(conn.fd);
                    conn.destroy();
                    return;
                },
            }
        }

        if (conn.protocol == .websocket) {
            wsAfterWrite(loop, conn);
            return;
        }

        // HTTP path: if a streaming dispatch is still active, pull the next
        // batch of wire bytes the app produced. Loops until the Task either
        // hands us new chunks (and we keep writing), declares itself done
        // (and we move on to keep-alive / close), or stalls (no chunks, not
        // done — kept in .writing state, level-triggered EPOLLOUT will wake
        // us back into doWrite when the kernel sees the socket writable).
        if (!conn.dispatch_active) break;

        if (conn.write_buf.len > 0) {
            conn.allocator.free(conn.write_buf);
            conn.write_buf = &.{};
        }
        conn.write_pos = 0;

        // Drain only — the global pump in the main loop is responsible for
        // advancing the asyncio Task. If chunks have been emitted since the
        // last drain, write them.
        const tick = bridge.httpDispatchDrain(conn.dispatch_handle, conn.allocator) orelse {
            loop.remove(conn.fd);
            conn.destroy();
            return;
        };

        if (tick.chunks.len > 0) {
            conn.write_buf = tick.chunks;
            conn.write_pos = 0;
            conn.dispatch_active = !tick.done;
            // First chunk of the response holds the status line.
            if (conn.response_status == 0) {
                conn.response_status = parseStatus(tick.chunks);
            }
            continue;
        }

        if (tick.done) {
            conn.dispatch_active = false;
            conn.dispatch_handle = 0;
            break;
        }

        // No chunks, not done: Task is parked on something not driven by
        // socket I/O. Park the connection on the global stalled list and
        // switch off WANT_WRITE so the kernel doesn't fire EPOLLOUT in a
        // tight loop. The main loop's per-iteration global pump will
        // advance the Task; subsequent drains here will harvest its output.
        linkStalled(conn);
        loop.modify(conn.fd, @ptrCast(conn), true, false) catch {
            loop.remove(conn.fd);
            conn.destroy();
        };
        return;
    }

    // write_buf fully drained AND dispatch is no longer active.
    finishRequest(conn);
    if (conn.keep_alive) {
        keepAliveReset(loop, conn);
    } else {
        loop.remove(conn.fd);
        conn.destroy();
    }
}

// ---------------------------------------------------------------------------
// WebSocket frame handling. After a successful upgrade the connection lives
// in `protocol == .websocket`; doRead routes here. Frames are unmasked in
// place, dispatched to the Python coroutine via bridge.wsEvent, and any
// response frames are queued on `write_buf` for doWrite to drain.

fn doReadWs(loop: *eventloop.Loop, conn: *Connection) void {
    const data = conn.read_buf.?.data;

    while (true) {
        // Try to parse a frame from what's already buffered.
        const buf_view = data[0..conn.read_total];
        const parsed = ws.parseHeader(buf_view);

        switch (parsed) {
            .invalid => {
                wsTeardown(loop, conn);
                return;
            },
            .ok => |hdr| {
                if (!hdr.masked) {
                    // RFC 6455: client→server frames MUST be masked.
                    wsTeardown(loop, conn);
                    return;
                }
                const total = hdr.header_len + hdr.payload_len;
                if (total > data.len) {
                    // Frame bigger than our buffer. Will retry as
                    // fragmentation handler if it's the start of a
                    // legit fragmented message.
                    wsTeardown(loop, conn);
                    return;
                }
                if (conn.read_total >= total) {
                    const payload = data[hdr.header_len..total];
                    ws.unmask(payload, hdr.mask_key);
                    // Inbound frame counts as activity for the keepalive
                    // gate — including pongs from earlier server pings.
                    conn.last_activity_ns = monoNs();
                    // RFC 6455 §5.4: fragmented messages span multiple
                    // frames. Control frames (opcode ≥ 8) interleave
                    // and aren't allowed to be fragmented.
                    const is_control = (hdr.opcode_raw & 0x08) != 0;
                    if (!is_control) {
                        if (!hdr.fin) {
                            // First or middle fragment.
                            if (handleWsFragment(conn, hdr, payload)) {
                                // Compact and continue.
                            } else {
                                wsTeardown(loop, conn);
                                return;
                            }
                            // Compact and read more.
                            const leftover = conn.read_total - total;
                            if (leftover > 0) {
                                std.mem.copyForwards(u8, data[0..leftover], data[total..total + leftover]);
                            }
                            conn.read_total = leftover;
                            continue;
                        }
                        if (hdr.opcode_raw == 0) {
                            // Final continuation: assemble + deliver.
                            if (!handleWsFragment(conn, hdr, payload)) {
                                wsTeardown(loop, conn);
                                return;
                            }
                            const assembled_op = conn.ws_frag_opcode;
                            const assembled = conn.ws_frag_buf.?[0..conn.ws_frag_len];
                            // Hand off to wsDeliverToApp; it copies
                            // bytes to the Python side, so freeing
                            // after is safe.
                            wsDeliverToApp(loop, conn, assembled_op, assembled, conn.ws_frag_rsv1);
                            conn.allocator.free(conn.ws_frag_buf.?);
                            conn.ws_frag_buf = null;
                            conn.ws_frag_len = 0;
                            conn.ws_frag_opcode = 0;
                            conn.ws_frag_rsv1 = false;
                            const leftover2 = conn.read_total - total;
                            if (leftover2 > 0) {
                                std.mem.copyForwards(u8, data[0..leftover2], data[total..total + leftover2]);
                            }
                            conn.read_total = leftover2;
                            if (conn.protocol != .websocket) return;
                            if (conn.state == .writing) return;
                            continue;
                        }
                        // Single-frame text/binary (FIN=1, opcode 1|2).
                    }
                    handleWsFrame(loop, conn, hdr, payload);
                    if (conn.protocol != .websocket) return;

                    // Compact: shift any bytes past this frame to the start.
                    const leftover = conn.read_total - total;
                    if (leftover > 0) {
                        var i: usize = 0;
                        while (i < leftover) : (i += 1) {
                            data[i] = data[total + i];
                        }
                    }
                    conn.read_total = leftover;

                    // If handling produced output, flushOutbound will have
                    // flipped state to .writing — bail out and let epoll
                    // wake us up when the socket is writable.
                    if (conn.state == .writing) return;
                    continue;
                }
                // Need more bytes — fall through to read.
            },
            .needs_more => {},
        }

        const remaining = data[conn.read_total..];
        if (remaining.len == 0) {
            // No room left and still no complete frame.
            wsTeardown(loop, conn);
            return;
        }
        const r = connRead(conn, remaining);
        switch (r.status) {
            .ok => conn.read_total += r.n,
            .would_block, .want_read => {
                if (conn.ssl != null) epollWantRead(loop, conn);
                return;
            },
            .want_write => {
                epollWantWrite(loop, conn);
                return;
            },
            .closed, .fatal => {
                wsTeardown(loop, conn);
                return;
            },
        }
    }
}

/// RFC 6455 §5.4 fragmentation reassembly. Returns false on protocol
/// violation (continuation without start, oversize, etc.) — caller
/// tears down the connection. Successful return appends `payload` to
/// the per-conn fragment buffer and tracks the original opcode.
fn handleWsFragment(conn: *Connection, hdr: ws.Header, payload: []u8) bool {
    const WS_FRAG_MAX: usize = 1024 * 1024; // 1 MiB cap
    if (hdr.opcode_raw == 0) {
        // Continuation frame — must follow a start.
        if (conn.ws_frag_buf == null) return false;
    } else if (hdr.opcode_raw == 1 or hdr.opcode_raw == 2) {
        // Start of a new fragmented message — must NOT follow another
        // unfinished start.
        if (conn.ws_frag_buf != null) return false;
        const buf = conn.allocator.alloc(u8, @max(payload.len, 4096)) catch return false;
        conn.ws_frag_buf = buf;
        conn.ws_frag_len = 0;
        conn.ws_frag_opcode = hdr.opcode_raw;
        conn.ws_frag_rsv1 = hdr.rsv1;
    } else {
        return false;
    }
    const new_len = conn.ws_frag_len + payload.len;
    if (new_len > WS_FRAG_MAX) return false;
    var buf = conn.ws_frag_buf.?;
    if (new_len > buf.len) {
        const grown = conn.allocator.realloc(buf, @min(WS_FRAG_MAX, new_len * 2)) catch return false;
        conn.ws_frag_buf = grown;
        buf = grown;
    }
    @memcpy(buf[conn.ws_frag_len .. conn.ws_frag_len + payload.len], payload);
    conn.ws_frag_len = new_len;
    return true;
}

fn handleWsFrame(loop: *eventloop.Loop, conn: *Connection, hdr: ws.Header, payload: []u8) void {
    switch (hdr.opcode) {
        .text => wsDeliverToApp(loop, conn, 0x1, payload, hdr.rsv1),
        .binary => wsDeliverToApp(loop, conn, 0x2, payload, hdr.rsv1),
        .close => {
            // Echo close + tear down.
            sendCloseFrame(conn, 1000) catch {};
            conn.keep_alive = false;
            flushOutbound(loop, conn);
        },
        .ping => {
            // Auto-pong with the same payload (v0.10 doesn't surface pings
            // to the application).
            sendControlFrame(conn, .pong, payload) catch {};
            flushOutbound(loop, conn);
        },
        .pong => {}, // Unsolicited pongs are ignored.
        else => wsTeardown(loop, conn),
    }
}

fn wsDeliverToApp(loop: *eventloop.Loop, conn: *Connection, opcode: u8, payload: []const u8, rsv1: bool) void {
    const tick = bridge.wsEvent(conn.ws_handle, opcode, payload, rsv1, conn.allocator) orelse {
        wsTeardown(loop, conn);
        return;
    };

    queueFrames(conn, tick.frames);
    if (tick.done) conn.keep_alive = false;

    flushOutbound(loop, conn);
}

/// Append `frames` (transferred ownership) onto the connection's write
/// buffer. If write_buf is currently being drained, we concatenate; if not,
/// we replace.
fn queueFrames(conn: *Connection, frames: []u8) void {
    // Convention: empty slice means "no allocation made" (see copyBytes).
    if (frames.len == 0) return;
    if (conn.write_buf.len == conn.write_pos) {
        if (conn.write_buf.len > 0) conn.allocator.free(conn.write_buf);
        conn.write_buf = frames;
        conn.write_pos = 0;
        return;
    }

    const remaining_old = conn.write_buf[conn.write_pos..];
    const combined = conn.allocator.alloc(u8, remaining_old.len + frames.len) catch {
        conn.allocator.free(frames);
        return;
    };
    @memcpy(combined[0..remaining_old.len], remaining_old);
    @memcpy(combined[remaining_old.len..], frames);
    conn.allocator.free(conn.write_buf);
    conn.allocator.free(frames);
    conn.write_buf = combined;
    conn.write_pos = 0;
}

fn flushOutbound(loop: *eventloop.Loop, conn: *Connection) void {
    if (conn.write_buf.len > conn.write_pos) {
        if (conn.state != .writing) {
            conn.state = .writing;
            loop.modify(conn.fd, @ptrCast(conn), false, true) catch {
                wsTeardown(loop, conn);
                return;
            };
        }
        doWrite(loop, conn);
        return;
    }

    if (!conn.keep_alive) {
        wsTeardown(loop, conn);
    }
}

fn sendCloseFrame(conn: *Connection, code: u16) !void {
    const payload = [_]u8{ @intCast((code >> 8) & 0xFF), @intCast(code & 0xFF) };
    const frame_size = ws.frameSize(payload.len);
    const buf = try conn.allocator.alloc(u8, frame_size);
    _ = try ws.writeFrame(buf, .close, &payload);
    queueFrames(conn, buf);
}

fn sendControlFrame(conn: *Connection, opcode: ws.Opcode, payload: []const u8) !void {
    const frame_size = ws.frameSize(payload.len);
    const buf = try conn.allocator.alloc(u8, frame_size);
    _ = try ws.writeFrame(buf, opcode, payload);
    queueFrames(conn, buf);
}

fn wsAfterWrite(loop: *eventloop.Loop, conn: *Connection) void {
    if (conn.write_buf.len > 0) conn.allocator.free(conn.write_buf);
    conn.write_buf = &.{};
    conn.write_pos = 0;

    // First call after the handshake we still hold the parsed HTTP request
    // (so startWebSocket could read its headers). Compact past the upgrade
    // head and reset the HTTP request slots. Subsequent calls happen from
    // inside doReadWs's loop — that loop will compact the consumed frame
    // itself and keep going, so we MUST NOT recurse into doReadWs from
    // here on the non-first path or we'll re-process the same frame.
    const first_call = conn.parsed != null;
    if (first_call) {
        const data = conn.read_buf.?.data;
        const consumed_end = conn.body_offset + conn.body_len;
        const leftover = conn.read_total - consumed_end;
        if (leftover > 0) {
            var i: usize = 0;
            while (i < leftover) : (i += 1) {
                data[i] = data[consumed_end + i];
            }
        }
        conn.read_total = leftover;
        conn.parsed = null;
        conn.body_offset = 0;
        conn.body_len = 0;
    }

    if (!conn.keep_alive) {
        wsTeardown(loop, conn);
        return;
    }

    conn.state = .reading;
    loop.modify(conn.fd, @ptrCast(conn), true, false) catch {
        wsTeardown(loop, conn);
        return;
    };

    // Only on the first call may we have bytes the outer code hasn't seen
    // (frames piggybacked on the upgrade request). On later calls the
    // outer doReadWs loop is already in charge of draining the buffer.
    if (first_call and conn.read_total > 0) {
        doReadWs(loop, conn);
        return;
    }

    // For TLS: OpenSSL may have already decrypted the next frame; only
    // surface this on the first call for the same reason.
    if (first_call) {
        if (conn.ssl) |s| {
            if (tls.pending(s) > 0) doReadWs(loop, conn);
        }
    }
}

fn wsTeardown(loop: *eventloop.Loop, conn: *Connection) void {
    if (conn.ws_handle != 0) {
        const final = bridge.wsDisconnect(conn.ws_handle, 1006, conn.allocator);
        if (final.len > 0) conn.allocator.free(final);
        conn.ws_handle = 0;
    }
    loop.remove(conn.fd);
    conn.destroy();
}

/// Reset connection state for the next keep-alive request. If pipelined
/// bytes are sitting in the buffer past the consumed body, keep the buffer
/// and compact them to the front. Otherwise release the buffer to the pool
/// — the connection is truly idle and shouldn't tie up 16 KiB until the
/// peer sends more bytes.
fn keepAliveReset(loop: *eventloop.Loop, conn: *Connection) void {
    // For chunked requests we consumed up to `chunk_consumed` raw bytes of
    // chunked encoding (not `body_len`, which is the *decoded* length and
    // is always shorter).
    const consumed_end = if (conn.parsed != null and conn.parsed.?.is_chunked)
        conn.body_offset + conn.chunk_consumed
    else
        conn.body_offset + conn.body_len;
    const leftover = conn.read_total - consumed_end;

    // Clear the parsed-request slots BEFORE potentially releasing the read
    // buffer (which since v0.12.1 also owns the headers slice the parsed
    // request points into). After this point conn.parsed.headers must not
    // be accessed.
    conn.parsed = null;
    conn.body_offset = 0;
    conn.body_len = 0;
    conn.chunk_state = http.ChunkState.init();
    conn.chunk_consumed = 0;
    conn.chunk_decoded = 0;

    if (leftover > 0) {
        const data = conn.read_buf.?.data;
        // Forward in-place copy: dest_start (0) < src_start (consumed_end),
        // so a left-to-right loop handles overlap correctly.
        var i: usize = 0;
        while (i < leftover) : (i += 1) {
            data[i] = data[consumed_end + i];
        }
        conn.read_total = leftover;
    } else {
        // Idle: hand the buffer back so RSS isn't held hostage by an idle
        // keep-alive connection. This also frees the headers array bundled
        // into the same Buffer (v0.12.1).
        conn.releaseBuffer();
        conn.read_total = 0;
    }

    if (conn.write_buf.len > 0) {
        conn.allocator.free(conn.write_buf);
        conn.write_buf = &.{};
    }
    conn.write_pos = 0;
    conn.state = .reading;
    conn.keep_alive = false;
    // Streaming dispatch is finished by the time we reach keepAliveReset
    // (doWrite only falls through here once tick.done is true). Python has
    // already popped the per-request state; clear our handle.
    conn.dispatch_handle = 0;
    conn.dispatch_active = false;
    // One more request fully served on this connection. The cap is checked
    // in dispatch() on the *next* request via `keepalive_request_count + 1
    // >= max_keepalive_requests`, so we never reach this point past the cap.
    conn.keepalive_request_count += 1;
    // Idle keep-alive deadline. If pipelined bytes are present we'll re-arm
    // to header_timeout / body_timeout below as soon as they're observed.
    conn.armTimer(g_timeouts.keep_alive_secs);

    loop.modify(conn.fd, @ptrCast(conn), true, false) catch {
        loop.remove(conn.fd);
        conn.destroy();
        return;
    };

    if (leftover > 0) {
        // We already have data for the next request — restart the
        // header-phase clock instead of leaving the keep-alive deadline
        // running, which would unfairly count this request's parsing
        // window against the previous one's idle window.
        conn.armTimer(g_timeouts.header_secs);
        tryParsePipelined(loop, conn);
        return;
    }

    // For TLS: even with no plaintext leftover, OpenSSL may have already
    // received and decrypted the next request into its own buffer. epoll
    // won't tell us about that — drain explicitly.
    if (conn.ssl) |ssl| {
        if (tls.pending(ssl) > 0) {
            doRead(loop, conn);
        }
    }
}

fn tryParsePipelined(loop: *eventloop.Loop, conn: *Connection) void {
    const data = conn.read_buf.?.data;
    if (http.parse(data[0..conn.read_total], &conn.read_buf.?.headers)) |req| {
        if (g_limits.max_request_uri > 0 and req.target.len > g_limits.max_request_uri) {
            sendStatus(loop, conn, 414, "URI Too Long");
            return;
        }
        conn.parsed = req;
        conn.body_offset = req.body_offset;
        // Pipelined parse succeeded — same transition as in doReadHttp.
        conn.armTimer(g_timeouts.body_secs);
        if (req.is_chunked) {
            conn.chunk_state = http.ChunkState.init();
            conn.chunk_consumed = 0;
            conn.chunk_decoded = 0;
            // Try to decode whatever bytes we already have past the head.
            const body_buf = data[conn.body_offset..];
            const body_buf_len = conn.read_total - conn.body_offset;
            switch (http.decodeChunkedInPlace(
                body_buf,
                body_buf_len,
                &conn.chunk_state,
                &conn.chunk_consumed,
                &conn.chunk_decoded,
            )) {
                .needs_more => {
                    if (conn.chunk_decoded > g_limits.max_request_body) {
                        sendStatus(loop, conn, 413, "Content Too Large");
                        return;
                    }
                },
                .done => {
                    conn.body_len = conn.chunk_decoded;
                    if (conn.body_len > g_limits.max_request_body) {
                        sendStatus(loop, conn, 413, "Content Too Large");
                        return;
                    }
                    dispatch(loop, conn);
                },
                .invalid => sendStatus(loop, conn, 400, "Bad Request"),
            }
        } else {
            conn.body_len = req.content_length orelse 0;
            if (conn.body_len > g_limits.max_request_body) {
                sendStatus(loop, conn, 413, "Content Too Large");
                return;
            }
            if (conn.body_offset + conn.body_len > data.len) {
                if (data.len < pool_mod.LARGE_DATA_SIZE and
                    conn.body_offset + conn.body_len <= pool_mod.LARGE_DATA_SIZE)
                {
                    // Same upgrade dance as in doReadHttp.
                    conn.parsed = null;
                    conn.upgradeBuffer() catch {
                        sendStatus(loop, conn, 503, "Service Unavailable");
                        return;
                    };
                    const big = conn.read_buf.?.data;
                    const reparsed = http.parse(big[0..conn.read_total], &conn.read_buf.?.headers) catch {
                        sendStatus(loop, conn, 400, "Bad Request");
                        return;
                    };
                    conn.parsed = reparsed;
                    conn.body_offset = reparsed.body_offset;
                    conn.body_len = reparsed.content_length orelse 0;
                } else {
                    sendStatus(loop, conn, 413, "Content Too Large");
                    return;
                }
            }
            if (wantsExpectContinue(req)) {
                if (!sendContinue(conn)) {
                    loop.remove(conn.fd);
                    conn.destroy();
                    return;
                }
            }
            if (conn.read_total >= conn.body_offset + conn.body_len) {
                dispatch(loop, conn);
            }
            // else: need more body bytes; wait for next read event.
        }
    } else |err| switch (err) {
        error.Incomplete => {}, // wait for more
        else => {
            std.log.warn("pipelined parse failed: {s}", .{@errorName(err)});
            sendStatus(loop, conn, 400, "Bad Request");
        },
    }
}

fn sendStatus(loop: *eventloop.Loop, conn: *Connection, code: u16, reason: []const u8) void {
    var stack_buf: [512]u8 = undefined;
    const formatted = std.fmt.bufPrint(
        &stack_buf,
        "HTTP/1.1 {d} {s}\r\n" ++
            "{s}" ++
            "Content-Length: 0\r\n" ++
            "Connection: close\r\n" ++
            "\r\n",
        .{ code, reason, g_server_line },
    ) catch {
        loop.remove(conn.fd);
        conn.destroy();
        return;
    };

    const heap = conn.allocator.alloc(u8, formatted.len) catch {
        loop.remove(conn.fd);
        conn.destroy();
        return;
    };
    @memcpy(heap, formatted);

    if (conn.write_buf.len > 0) conn.allocator.free(conn.write_buf);
    conn.write_buf = heap;
    conn.write_pos = 0;
    conn.state = .writing;
    // Errors always close — parser/state may be stale, can't safely keep-alive.
    conn.keep_alive = false;
    // Make the access log + status counters see this code, even on early-
    // error paths that never reach the streaming dispatch tick.
    conn.response_status = code;
    conn.armTimer(g_timeouts.write_secs);

    loop.modify(conn.fd, @ptrCast(conn), false, true) catch {
        loop.remove(conn.fd);
        conn.destroy();
        return;
    };
    doWrite(loop, conn);
}
