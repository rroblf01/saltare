// Saltare network core (v0.4).
//
// Single-threaded non-blocking event loop on top of epoll. Connections
// progress through a small state machine (reading -> writing -> close).
// I/O happens with the GIL released; the bridge re-acquires the GIL only
// for the synchronous ASGI dispatch step. Multiple connections can be
// in different states simultaneously — the dispatch is the serialization
// point (same constraint as any GIL-bound Python server).
//
// Out of scope (planned for later):
//   - keep-alive, chunked Transfer-Encoding, streaming bodies (v0.5)
//   - TLS (v0.6), WebSockets (v0.7), multi-worker (v1.0)
//   - kqueue backend for macOS — see eventloop.zig's compileError

const std = @import("std");
const http = @import("http.zig");
const bridge = @import("bridge.zig");
const eventloop = @import("eventloop.zig");

const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("netinet/in.h");
    @cInclude("unistd.h");
    @cInclude("signal.h");
    @cInclude("fcntl.h");
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

const SERVER_HEADER = "saltare/0.4.0";

// Per-connection read buffer. Holds head + body. Bigger requests get 413/431.
const READ_BUFFER_SIZE = 16 * 1024;

// Listener fd bookkeeping for the signal-driven shutdown.
var g_listen_fd: std.atomic.Value(c_int) = std.atomic.Value(c_int).init(-1);
var g_should_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

// Sentinel pointer used as `event.data.ptr` for the listening socket so the
// event loop can tell it apart from connection events without a hashmap.
var listener_marker: u8 = 0;

fn isListenerEvent(data: ?*anyopaque) bool {
    return data == @as(*anyopaque, @ptrCast(&listener_marker));
}

fn onSignal(_: c_int) callconv(.c) void {
    g_should_stop.store(true, .seq_cst);
    const fd = g_listen_fd.load(.seq_cst);
    if (fd >= 0) {
        _ = c.shutdown(fd, c.SHUT_RDWR);
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

const ConnState = enum { reading, writing };

const Connection = struct {
    fd: c_int,
    state: ConnState,
    read_buf: [READ_BUFFER_SIZE]u8,
    read_total: usize,

    // Filled in once the head is fully parsed.
    parsed: ?http.Request,
    headers_storage: [http.max_headers]http.Header,
    body_offset: usize,
    body_len: usize,

    // Allocated by bridge.dispatch (or sendStatus); freed in `destroy`.
    write_buf: []u8,
    write_pos: usize,

    allocator: std.mem.Allocator,

    fn create(allocator: std.mem.Allocator, fd: c_int) !*Connection {
        const conn = try allocator.create(Connection);
        conn.* = .{
            .fd = fd,
            .state = .reading,
            .read_buf = undefined,
            .read_total = 0,
            .parsed = null,
            .headers_storage = undefined,
            .body_offset = 0,
            .body_len = 0,
            .write_buf = &.{},
            .write_pos = 0,
            .allocator = allocator,
        };
        return conn;
    }

    fn destroy(self: *Connection) void {
        if (self.write_buf.len > 0) self.allocator.free(self.write_buf);
        _ = c.close(self.fd);
        self.allocator.destroy(self);
    }
};

pub fn run(host: []const u8, port: u16) !void {
    const addr = try parseIpv4(host, port);

    const listen_fd = c.socket(
        c.AF_INET,
        c.SOCK_STREAM | c.SOCK_NONBLOCK | c.SOCK_CLOEXEC,
        c.IPPROTO_TCP,
    );
    if (listen_fd < 0) return error.SocketFailed;
    errdefer _ = c.close(listen_fd);

    var yes: c_int = 1;
    if (c.setsockopt(
        listen_fd,
        c.SOL_SOCKET,
        c.SO_REUSEADDR,
        @ptrCast(&yes),
        @sizeOf(c_int),
    ) != 0) return error.SetsockoptFailed;

    if (c.bind(listen_fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) != 0) {
        return error.BindFailed;
    }
    if (c.listen(listen_fd, 256) != 0) return error.ListenFailed;

    g_listen_fd.store(listen_fd, .seq_cst);
    defer g_listen_fd.store(-1, .seq_cst);

    installSignalHandlers();

    var loop = try eventloop.Loop.init();
    defer loop.deinit();

    try loop.add(listen_fd, @ptrCast(&listener_marker), true, false);

    const allocator = std.heap.c_allocator;

    std.log.info("saltare listening on {s}:{d}", .{ host, port });

    while (!g_should_stop.load(.seq_cst)) {
        const events = loop.wait(100); // 100 ms poll → bounds shutdown latency
        for (events) |ev| {
            if (g_should_stop.load(.seq_cst)) break;
            if (isListenerEvent(ev.data)) {
                acceptAll(&loop, listen_fd, allocator);
            } else if (ev.data) |raw| {
                const conn: *Connection = @ptrCast(@alignCast(raw));
                handleConnEvent(&loop, conn, ev);
            }
        }
    }

    _ = c.close(listen_fd);
}

fn acceptAll(loop: *eventloop.Loop, listen_fd: c_int, allocator: std.mem.Allocator) void {
    while (true) {
        const client = accept4(listen_fd, null, null, c.SOCK_NONBLOCK | c.SOCK_CLOEXEC);
        if (client < 0) return; // EAGAIN: drained the backlog

        const conn = Connection.create(allocator, client) catch {
            _ = c.close(client);
            continue;
        };

        loop.add(client, @ptrCast(conn), true, false) catch {
            conn.destroy();
            continue;
        };
    }
}

fn handleConnEvent(loop: *eventloop.Loop, conn: *Connection, ev: eventloop.Event) void {
    if (ev.closed) {
        loop.remove(conn.fd);
        conn.destroy();
        return;
    }
    switch (conn.state) {
        .reading => if (ev.readable) doRead(loop, conn),
        .writing => if (ev.writable) doWrite(loop, conn),
    }
}

fn doRead(loop: *eventloop.Loop, conn: *Connection) void {
    while (true) {
        const remaining = conn.read_buf[conn.read_total..];
        if (remaining.len == 0) {
            sendStatus(loop, conn, 431, "Request Header Fields Too Large");
            return;
        }

        const n = c.read(conn.fd, @ptrCast(remaining.ptr), remaining.len);
        if (n == 0) {
            // Peer closed before sending a complete request.
            loop.remove(conn.fd);
            conn.destroy();
            return;
        }
        if (n < 0) {
            // Almost always EAGAIN under non-blocking I/O. If it's a real
            // error, the next epoll cycle delivers EPOLLERR/EPOLLHUP.
            return;
        }
        conn.read_total += @intCast(n);

        if (conn.parsed == null) {
            if (http.parse(conn.read_buf[0..conn.read_total], &conn.headers_storage)) |req| {
                conn.parsed = req;
                conn.body_offset = req.body_offset;
                conn.body_len = req.content_length orelse 0;
                if (conn.body_offset + conn.body_len > conn.read_buf.len) {
                    sendStatus(loop, conn, 413, "Content Too Large");
                    return;
                }
            } else |err| switch (err) {
                error.Incomplete => continue,
                else => {
                    std.log.warn("parse failed: {s}", .{@errorName(err)});
                    sendStatus(loop, conn, 400, "Bad Request");
                    return;
                },
            }
        }

        if (conn.read_total >= conn.body_offset + conn.body_len) {
            dispatch(loop, conn);
            return;
        }
        // else: loop and read more
    }
}

fn dispatch(loop: *eventloop.Loop, conn: *Connection) void {
    const req = conn.parsed.?;
    const body = conn.read_buf[conn.body_offset .. conn.body_offset + conn.body_len];

    const response = bridge.dispatch(req, body, conn.allocator) orelse {
        sendStatus(loop, conn, 500, "Internal Server Error");
        return;
    };

    conn.write_buf = response;
    conn.write_pos = 0;
    conn.state = .writing;

    loop.modify(conn.fd, @ptrCast(conn), false, true) catch {
        loop.remove(conn.fd);
        conn.destroy();
        return;
    };

    // Try to drain immediately — small responses usually finish in one shot
    // and we close without waiting for an EPOLLOUT round-trip.
    doWrite(loop, conn);
}

fn doWrite(loop: *eventloop.Loop, conn: *Connection) void {
    while (conn.write_pos < conn.write_buf.len) {
        const remaining = conn.write_buf[conn.write_pos..];
        const n = c.write(conn.fd, @ptrCast(remaining.ptr), remaining.len);
        if (n < 0) return; // EAGAIN: wait for next EPOLLOUT
        if (n == 0) {
            loop.remove(conn.fd);
            conn.destroy();
            return;
        }
        conn.write_pos += @intCast(n);
    }
    // Done writing — close.
    loop.remove(conn.fd);
    conn.destroy();
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

    // Heap-copy so write_buf has the same lifetime as the connection.
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

    loop.modify(conn.fd, @ptrCast(conn), false, true) catch {
        loop.remove(conn.fd);
        conn.destroy();
        return;
    };
    doWrite(loop, conn);
}
