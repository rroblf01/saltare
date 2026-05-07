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
    @cInclude("sys/socket.h");
    @cInclude("netinet/in.h");
    @cInclude("netinet/tcp.h");
    @cInclude("sys/un.h");
    @cInclude("unistd.h");
    @cInclude("signal.h");
    @cInclude("fcntl.h");
    @cInclude("time.h");
    @cInclude("arpa/inet.h");
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

const SERVER_HEADER = "saltare/1.3.0";

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
    /// If non-null, requests to this path return a top-N tracemalloc
    /// dump (Python heap allocations grouped by source line). Setting
    /// this also auto-enables `tracemalloc.start()` at startup so the
    /// snapshots are populated. Diagnostic only — leak hunts in
    /// long-running deployments. The user app never sees the request.
    tracemalloc_path: ?[]const u8 = null,
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
    };
    return true;
}

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

fn resetMetrics() void {
    g_in_flight.store(0, .seq_cst);
    g_total_requests.store(0, .seq_cst);
    g_total_bytes_sent.store(0, .seq_cst);
    g_total_bytes_received.store(0, .seq_cst);
    g_total_4xx.store(0, .seq_cst);
    g_total_5xx.store(0, .seq_cst);
}

/// Set by `run` when TLS is enabled. Lives only for the duration of one
/// `serve()` call. Each accepted connection wraps its fd with a fresh SSL
/// derived from this context.
var g_tls_ctx: ?*tls.Ctx = null;

/// Head of the doubly-linked list of stalled connections. A connection is
/// stalled when its in-flight HTTP dispatch's Task is parked on something
/// not driven by socket I/O (typically: framework setup chains spanning
/// multiple awaits). Reset to null by `run()`.
var g_stalled_head: ?*Connection = null;

/// CLOCK_MONOTONIC nanoseconds. Wraps the libc call inline so the cost
/// of a metrics scrape is dominated by the formatting, not by Zig
/// indirection. Off the hot path when `access_log` is off (we only call
/// it on request start/end then).
fn monoNs() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
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

fn emitAccessLog(conn: *Connection) void {
    const req = conn.parsed orelse return;

    var log: LogBuf = .{};

    log.appendSlice("{\"method\":");
    log.appendJsonString(req.method);
    log.appendSlice(",\"path\":");
    log.appendJsonString(req.target);
    log.printFmt(",\"status\":{d},\"bytes\":{d}", .{ conn.response_status, conn.bytes_sent });

    const latency_us: i64 = if (conn.request_start_ns != 0)
        @divTrunc(monoNs() - conn.request_start_ns, 1000)
    else
        0;
    log.printFmt(",\"latency_us\":{d}", .{latency_us});

    const ua_raw = req.header("user-agent") orelse "";
    const trimmed_ua = std.mem.trim(u8, ua_raw, " \t");
    log.appendSlice(",\"user_agent\":");
    log.appendJsonString(trimmed_ua);
    log.appendSlice("}\n");

    if (!log.overflow) {
        // Single write(2) keeps the line atomic from the kernel's view —
        // partial interleaving with other workers' lines is impossible
        // even without explicit locking.
        _ = c.write(2, &log.buf, log.pos);
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
    if (g_obs.access_log and conn.parsed != null) emitAccessLog(conn);
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

/// Build a Prometheus-format text dump of saltare's counters and write it
/// to the connection. Bypasses the bridge entirely — the user app never
/// sees the request, so there's no Python overhead per scrape.
fn serveMetrics(loop: *eventloop.Loop, conn: *Connection) void {
    var body_buf: [2048]u8 = undefined;
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
    });

    var head_buf: [256]u8 = undefined;
    const head = std.fmt.bufPrint(
        &head_buf,
        "HTTP/1.1 200 OK\r\n" ++
            "Server: " ++ SERVER_HEADER ++ "\r\n" ++
            "Content-Type: text/plain; version=0.0.4\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Connection: keep-alive\r\n" ++
            "\r\n",
        .{body_len},
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
    var head_buf: [512]u8 = undefined;
    const head = std.fmt.bufPrint(
        &head_buf,
        "HTTP/1.1 {d} {s}\r\n" ++
            "Server: " ++ SERVER_HEADER ++ "\r\n" ++
            "Content-Type: {s}\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Connection: {s}\r\n" ++
            "{s}" ++
            "\r\n",
        .{ status, reason, content_type, body.len, conn_line, extra_headers },
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

fn installSignalHandlers() void {
    // Translate-c rejects SIG_ERR / SIG_IGN sentinel values; see memory note.
    _ = c.signal(c.SIGINT, &onSignal);
    _ = c.signal(c.SIGTERM, &onSignal);
    _ = c.signal(c.SIGPIPE, &ignoreSignal);
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
        _ = c.close(self.fd);
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
    if (c.listen(fd, 256) != 0) return error.ListenFailed;
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
    if (c.listen(fd, 256) != 0) return error.ListenFailed;
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
    if (c.listen(fd, 256) != 0) return error.ListenFailed;
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
) !void {
    g_tls_ctx = tls_ctx;
    defer g_tls_ctx = null;
    g_timeouts = timeouts;
    defer g_timeouts = .{};
    g_limits = limits;
    defer g_limits = .{};
    g_obs = obs;
    defer g_obs = .{};
    g_active_conns.store(0, .seq_cst);
    defer g_active_conns.store(0, .seq_cst);
    resetMetrics();
    rateLimitReset();

    // Multi-worker (v1.0): the master process binds + listens, then forks
    // N children that inherit the fd. When `inherited_listen_fd` is set we
    // skip bind/listen and use that fd directly. UDS unlink on shutdown
    // is the master's responsibility, not the worker's — workers shouldn't
    // remove the socket the master also serves.
    const owns_listen_fd = inherited_listen_fd == null;
    const listen_fd: c_int = if (inherited_listen_fd) |fd|
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
        for (events) |ev| {
            if (g_should_stop.load(.seq_cst)) break;
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
        // Sweep expired connections. With a 100 ms epoll poll, the worst-
        // case lag past a 1 s deadline is one bucket; granularity of all
        // four configurable timeouts is therefore ±1 s.
        wheel.tick(wheel.nowSec(), tick_ctx, fireExpired);

        // Hint long-idle pool buffers to the kernel via MADV_DONTNEED so
        // RSS recovers after a traffic peak. Cost: O(free_list_size)
        // pointer-chase per loop iteration. Linux only; macOS no-ops.
        rb_pool.sweepIdle(monoNs());

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
        .handshaking => doHandshake(loop, conn),
        .reading => if (ev.readable or ev.writable) doRead(loop, conn),
        .writing => if (ev.readable or ev.writable) doWrite(loop, conn),
    }
}

fn doHandshake(loop: *eventloop.Loop, conn: *Connection) void {
    const ssl = conn.ssl.?;
    switch (tls.handshake(ssl)) {
        .ok => {
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

        if (conn.parsed == null) {
            if (http.parse(data[0..conn.read_total], &conn.read_buf.?.headers)) |req| {
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
                        // If we're still on small and the large would
                        // accommodate it, upgrade. Otherwise 413.
                        if (data.len < pool_mod.LARGE_DATA_SIZE and
                            conn.body_offset + conn.body_len <= pool_mod.LARGE_DATA_SIZE)
                        {
                            // parsed.headers points into the small buffer's
                            // headers array; clear it before swapping
                            // buffers so we don't keep a dangling slice.
                            // We re-parse against the new buffer below.
                            conn.parsed = null;
                            conn.upgradeBuffer() catch {
                                sendStatus(loop, conn, 503, "Service Unavailable");
                                return;
                            };
                            data = conn.read_buf.?.data;
                            // Re-parse into the new (large) buffer's headers
                            // array. The bytes are already there from the
                            // upgrade copy.
                            const reparsed = http.parse(data[0..conn.read_total], &conn.read_buf.?.headers) catch {
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
                dispatch(loop, conn);
                return;
            }
            // else: loop and read more
        }
    }
}

fn dispatch(loop: *eventloop.Loop, conn: *Connection) void {
    const req = conn.parsed.?;

    if (req.isWebSocketUpgrade()) {
        return startWebSocket(loop, conn);
    }

    // Per-request metrics bookkeeping. Cheap atomics; no Python touched.
    _ = g_total_requests.fetchAdd(1, .seq_cst);
    _ = g_in_flight.fetchAdd(1, .seq_cst);
    conn.request_in_flight = true;
    conn.bytes_sent = 0;
    conn.response_status = 0;
    conn.request_start_ns = if (g_obs.access_log) monoNs() else 0;

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
    if (g_obs.cors_preflight_allow_all and
        std.mem.eql(u8, req.method, "OPTIONS") and
        req.header("origin") != null)
    {
        return serveCorsPreflight(loop, conn);
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
            if (req.header("x-forwarded-for")) |xff| {
                if (parseFirstForwardedIp(xff)) |xff_key| {
                    rl_key = xff_key;
                    rl_have_key = true;
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
    const body = data[conn.body_offset .. conn.body_offset + conn.body_len];
    var keep_alive = req.wantsKeepAlive();
    // Recycle the connection once we've served `max_keepalive_requests` on
    // it. Forces this response's `Connection: close` and bypasses the
    // keep-alive reset path. Helps bound CPython arena fragmentation that
    // accumulates over very long-lived connections.
    if (conn.keepalive_request_count + 1 >= g_limits.max_keepalive_requests) {
        keep_alive = false;
    }

    // v0.12 narrows scope to fully-buffered request bodies → more_body=false.
    // Streaming requests will lift this constraint in a follow-up; the
    // bridge already accepts the more_body flag.
    const start = bridge.httpDispatchStart(req, body, false, keep_alive, conn.allocator) orelse {
        sendStatus(loop, conn, 500, "Internal Server Error");
        return;
    };

    conn.dispatch_handle = start.handle;
    conn.dispatch_active = !start.done;
    conn.keep_alive = keep_alive;

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

    if (!opened.accepted) {
        // App rejected by closing without accepting.
        if (opened.frames.len > 0) conn.allocator.free(opened.frames);
        sendStatus(loop, conn, 403, "Forbidden");
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

    var resp_buf: [512]u8 = undefined;
    const resp = std.fmt.bufPrint(
        &resp_buf,
        "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: {s}\r\n" ++
            "Server: " ++ SERVER_HEADER ++ "\r\n" ++
            "\r\n",
        .{accept},
    ) catch {
        if (opened.frames.len > 0) conn.allocator.free(opened.frames);
        loop.remove(conn.fd);
        conn.destroy();
        return;
    };

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
                if (!hdr.fin or !hdr.masked) {
                    // Continuation frames and unmasked client frames are
                    // out of scope for v0.10 — close with protocol error.
                    wsTeardown(loop, conn);
                    return;
                }
                const total = hdr.header_len + hdr.payload_len;
                if (total > data.len) {
                    // Frame bigger than our buffer.
                    wsTeardown(loop, conn);
                    return;
                }
                if (conn.read_total >= total) {
                    const payload = data[hdr.header_len..total];
                    ws.unmask(payload, hdr.mask_key);
                    // Inbound frame counts as activity for the keepalive
                    // gate — including pongs from earlier server pings.
                    conn.last_activity_ns = monoNs();
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

fn handleWsFrame(loop: *eventloop.Loop, conn: *Connection, hdr: ws.Header, payload: []u8) void {
    switch (hdr.opcode) {
        .text => wsDeliverToApp(loop, conn, 0x1, payload),
        .binary => wsDeliverToApp(loop, conn, 0x2, payload),
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

fn wsDeliverToApp(loop: *eventloop.Loop, conn: *Connection, opcode: u8, payload: []const u8) void {
    const tick = bridge.wsEvent(conn.ws_handle, opcode, payload, conn.allocator) orelse {
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
    var stack_buf: [256]u8 = undefined;
    const formatted = std.fmt.bufPrint(
        &stack_buf,
        "HTTP/1.1 {d} {s}\r\n" ++
            "Server: " ++ SERVER_HEADER ++ "\r\n" ++
            "Content-Length: 0\r\n" ++
            "Connection: close\r\n" ++
            "\r\n",
        .{ code, reason },
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
