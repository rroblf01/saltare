// Saltare network core (v0 stub).
//
// Today: a single-threaded blocking accept loop that returns a fixed HTTP/1.1
// response to every client. This exists to validate the build pipeline and
// the Python <-> Zig boundary end-to-end.
//
// Why libc directly: Zig 0.16 reshuffled std.net / std.posix.socket out of
// the stdlib in favour of the new std.Io abstraction. We keep the surface
// stable (and easy to reason about) by talking to POSIX through libc via
// @cImport. Future iterations replace `handleConnection` with:
//   1. An HTTP/1.1 parser.
//   2. ASGI scope construction.
//   3. A non-blocking event loop (epoll on Linux, kqueue on macOS).
//   4. The Python ASGI dispatcher.

const std = @import("std");

const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("netinet/in.h");
    @cInclude("unistd.h");
    @cInclude("signal.h");
});

const BODY: []const u8 = "Hello from saltare (Zig stub backend)\n";

const RESPONSE = std.fmt.comptimePrint(
    "HTTP/1.1 200 OK\r\n" ++
        "Server: saltare/0.1.0\r\n" ++
        "Content-Type: text/plain; charset=utf-8\r\n" ++
        "Content-Length: {d}\r\n" ++
        "Connection: close\r\n" ++
        "\r\n" ++
        "{s}",
    .{ BODY.len, BODY },
);

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

    std.log.info("saltare stub listening on {s}:{d}", .{ host, port });

    while (!g_should_stop.load(.seq_cst)) {
        const client = c.accept(sock, null, null);
        if (client < 0) {
            // accept will fail with EINVAL/EBADF after our shutdown wakeup.
            if (g_should_stop.load(.seq_cst)) break;
            continue; // EINTR or transient: retry
        }

        handleConnection(client) catch |err| {
            std.log.warn("connection failed: {s}", .{@errorName(err)});
        };
    }

    _ = c.close(sock);
}

fn handleConnection(client: c_int) !void {
    defer _ = c.close(client);

    // v0 stub: drain whatever the client sent in one read and discard it.
    // The real parser will live in `http.zig`.
    var buf: [8192]u8 = undefined;
    _ = c.read(client, @ptrCast(&buf), buf.len);

    var written: usize = 0;
    while (written < RESPONSE.len) {
        const remaining = RESPONSE[written..];
        const n = c.write(client, @ptrCast(remaining.ptr), remaining.len);
        if (n <= 0) return;
        written += @intCast(n);
    }
}
