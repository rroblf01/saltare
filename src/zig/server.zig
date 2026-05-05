// Saltare network core.
//
// v0.3: parses HTTP, reads body up to Content-Length, hands the request off
// to bridge.zig which re-acquires the GIL and calls into Python's ASGI
// dispatcher. Still single-threaded, blocking accept loop.
//
// Why libc directly: Zig 0.16 reshuffled std.net / std.posix.socket out of
// the stdlib in favour of the new std.Io abstraction. We keep the surface
// stable (and easy to reason about) by talking to POSIX through libc via
// @cImport. Future iterations:
//   - v0.4: non-blocking event loop (epoll on Linux, kqueue on macOS).
//   - v0.5: lifespan, keep-alive, chunked transfer.

const std = @import("std");
const http = @import("http.zig");
const bridge = @import("bridge.zig");

const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("netinet/in.h");
    @cInclude("unistd.h");
    @cInclude("signal.h");
});

const SERVER_HEADER = "saltare/0.3.0";

// Caps for the read path. The same buffer holds head and body; if a request
// doesn't fit we return 413/431. Generous enough for typical FastAPI
// traffic and small enough to keep the per-connection footprint tight.
const READ_BUFFER_SIZE = 16 * 1024;

// Shared state with the signal handler. The handler must remain
// async-signal-safe, so it only touches an atomic flag and issues a
// single `shutdown(2)` on the listening fd to wake `accept`.
var g_listen_fd: std.atomic.Value(c_int) = std.atomic.Value(c_int).init(-1);
var g_should_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

fn onSignal(_: c_int) callconv(.c) void {
    g_should_stop.store(true, .seq_cst);
    const fd = g_listen_fd.load(.seq_cst);
    if (fd >= 0) {
        _ = c.shutdown(fd, c.SHUT_RDWR);
    }
}

fn ignoreSignal(_: c_int) callconv(.c) void {}

fn installSignalHandlers() void {
    // Zig 0.16's translate-c rejects SIG_ERR / SIG_IGN at comptime because
    // their sentinel addresses (-1, 1) fail the function-pointer alignment
    // check. We work around it by:
    //   - dropping the SIG_ERR return-value check (signal() failing on these
    //     standard signals is so exotic that aborting is worse than ignoring);
    //   - replacing SIG_IGN with a no-op handler. Functionally identical for
    //     SIGPIPE: the handler runs and returns, the syscall returns EPIPE.
    _ = c.signal(c.SIGINT, &onSignal);
    _ = c.signal(c.SIGTERM, &onSignal);
    _ = c.signal(c.SIGPIPE, &ignoreSignal);
}

/// Parse a dotted-quad IPv4 string into a sockaddr_in. The v0 stub only
/// needs IPv4; IPv6 will land alongside the proper event loop.
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

    // std.mem.zeroes covers macOS's extra `sin_len` field portably.
    var addr: c.struct_sockaddr_in = std.mem.zeroes(c.struct_sockaddr_in);
    addr.sin_family = @intCast(c.AF_INET);
    addr.sin_port = std.mem.nativeToBig(u16, port);
    addr.sin_addr.s_addr = @bitCast(bytes);
    return addr;
}

pub fn run(host: []const u8, port: u16) !void {
    const addr = try parseIpv4(host, port);

    const sock = c.socket(c.AF_INET, c.SOCK_STREAM, c.IPPROTO_TCP);
    if (sock < 0) return error.SocketFailed;
    errdefer _ = c.close(sock);

    var yes: c_int = 1;
    if (c.setsockopt(
        sock,
        c.SOL_SOCKET,
        c.SO_REUSEADDR,
        @ptrCast(&yes),
        @sizeOf(c_int),
    ) != 0) return error.SetsockoptFailed;

    if (c.bind(sock, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) != 0) {
        return error.BindFailed;
    }
    if (c.listen(sock, 128) != 0) return error.ListenFailed;

    g_listen_fd.store(sock, .seq_cst);
    defer g_listen_fd.store(-1, .seq_cst);

    installSignalHandlers();

    std.log.info("saltare listening on {s}:{d}", .{ host, port });

    while (!g_should_stop.load(.seq_cst)) {
        const client = c.accept(sock, null, null);
        if (client < 0) {
            if (g_should_stop.load(.seq_cst)) break;
            continue;
        }
        handleConnection(client);
    }

    _ = c.close(sock);
}

fn handleConnection(client: c_int) void {
    defer _ = c.close(client);

    var read_buf: [READ_BUFFER_SIZE]u8 = undefined;
    var headers_buf: [http.max_headers]http.Header = undefined;
    var read_total: usize = 0;

    // Phase 1: read until we have the full head section.
    const req = blk: while (true) {
        const remaining_buf = read_buf[read_total..];
        if (remaining_buf.len == 0) {
            sendStatus(client, 431, "Request Header Fields Too Large");
            return;
        }
        const n = c.read(client, @ptrCast(remaining_buf.ptr), remaining_buf.len);
        if (n <= 0) return;
        read_total += @intCast(n);

        if (http.parse(read_buf[0..read_total], &headers_buf)) |parsed| {
            break :blk parsed;
        } else |err| switch (err) {
            error.Incomplete => continue,
            else => {
                std.log.warn("parse failed: {s}", .{@errorName(err)});
                sendStatus(client, 400, "Bad Request");
                return;
            },
        }
    };

    // Phase 2: read the body up to Content-Length. Anything bigger than what
    // fits in the read buffer is rejected for now; v0.4 will buffer properly.
    const cl = req.content_length orelse 0;
    if (req.body_offset + cl > read_buf.len) {
        sendStatus(client, 413, "Content Too Large");
        return;
    }
    while (read_total < req.body_offset + cl) {
        const remaining = read_buf[read_total..];
        const n = c.read(client, @ptrCast(remaining.ptr), remaining.len);
        if (n <= 0) {
            sendStatus(client, 400, "Bad Request");
            return;
        }
        read_total += @intCast(n);
    }
    const body = read_buf[req.body_offset .. req.body_offset + cl];

    bridge.handleRequest(client, req, body);
}

fn sendStatus(client: c_int, code: u16, reason: []const u8) void {
    var buf: [256]u8 = undefined;
    const resp = std.fmt.bufPrint(
        &buf,
        "HTTP/1.1 {d} {s}\r\n" ++
            "Server: " ++ SERVER_HEADER ++ "\r\n" ++
            "Content-Length: 0\r\n" ++
            "Connection: close\r\n" ++
            "\r\n",
        .{ code, reason },
    ) catch return;

    var written: usize = 0;
    while (written < resp.len) {
        const remaining = resp[written..];
        const n = c.write(client, @ptrCast(remaining.ptr), remaining.len);
        if (n <= 0) return;
        written += @intCast(n);
    }
}
