// Saltare network core (v0.6).
//
// Single-threaded non-blocking event loop on top of epoll, with HTTP/1.1
// keep-alive and a shared pool for read buffers. RSS scales with the number
// of *in-flight* requests rather than the number of *open keep-alive
// connections*: idle connections release their 16 KiB buffer back to the
// pool and reclaim one on the next read event.
//
// Out of scope (planned for later):
//   - lifespan, chunked Transfer-Encoding, streaming bodies (v0.5.x)
//   - TLS (v0.7), WebSockets (v0.8), multi-worker (v1.0)
//   - kqueue backend for macOS — see eventloop.zig's compileError

const std = @import("std");
const http = @import("http.zig");
const bridge = @import("bridge.zig");
const eventloop = @import("eventloop.zig");
const pool_mod = @import("pool.zig");

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

const SERVER_HEADER = "saltare/0.8.0";

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

    /// Borrowed from the pool while a request is in flight, returned to the
    /// pool when the connection goes idle (between keep-alive requests).
    /// Null means "no request in progress, no buffer reserved".
    read_buf: ?*pool_mod.Buffer,
    read_total: usize,

    // Filled in once the head is fully parsed.
    parsed: ?http.Request,
    headers_storage: [http.max_headers]http.Header,
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

    fn create(
        allocator: std.mem.Allocator,
        pool: *pool_mod.Pool,
        fd: c_int,
    ) !*Connection {
        const conn = try allocator.create(Connection);
        conn.* = .{
            .fd = fd,
            .state = .reading,
            .read_buf = null,
            .read_total = 0,
            .parsed = null,
            .headers_storage = undefined,
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
        };
        return conn;
    }

    fn destroy(self: *Connection) void {
        if (self.read_buf) |b| self.pool.release(b);
        if (self.write_buf.len > 0) self.allocator.free(self.write_buf);
        _ = c.close(self.fd);
        self.allocator.destroy(self);
    }

    fn ensureBuffer(self: *Connection) !void {
        if (self.read_buf == null) {
            self.read_buf = try self.pool.acquire();
        }
    }

    fn releaseBuffer(self: *Connection) void {
        if (self.read_buf) |b| {
            self.pool.release(b);
            self.read_buf = null;
        }
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
    var rb_pool = pool_mod.Pool.init(allocator);
    defer rb_pool.deinit();

    std.log.info("saltare listening on {s}:{d}", .{ host, port });

    while (!g_should_stop.load(.seq_cst)) {
        const events = loop.wait(100); // 100 ms poll → bounds shutdown latency
        for (events) |ev| {
            if (g_should_stop.load(.seq_cst)) break;
            if (isListenerEvent(ev.data)) {
                acceptAll(&loop, listen_fd, allocator, &rb_pool);
            } else if (ev.data) |raw| {
                const conn: *Connection = @ptrCast(@alignCast(raw));
                handleConnEvent(&loop, conn, ev);
            }
        }
    }

    _ = c.close(listen_fd);
}

fn acceptAll(
    loop: *eventloop.Loop,
    listen_fd: c_int,
    allocator: std.mem.Allocator,
    p: *pool_mod.Pool,
) void {
    while (true) {
        const client = accept4(listen_fd, null, null, c.SOCK_NONBLOCK | c.SOCK_CLOEXEC);
        if (client < 0) return; // EAGAIN: drained the backlog

        const conn = Connection.create(allocator, p, client) catch {
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
    // Lazy: only claim a buffer from the pool when we actually need to read.
    conn.ensureBuffer() catch {
        sendStatus(loop, conn, 503, "Service Unavailable");
        return;
    };
    const data = &conn.read_buf.?.data;

    while (true) {
        const remaining = data[conn.read_total..];
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
            // Almost always EAGAIN under non-blocking I/O. Real errors will
            // surface via EPOLLERR/EPOLLHUP on the next epoll cycle.
            return;
        }
        conn.read_total += @intCast(n);

        if (conn.parsed == null) {
            if (http.parse(data[0..conn.read_total], &conn.headers_storage)) |req| {
                conn.parsed = req;
                conn.body_offset = req.body_offset;
                if (req.is_chunked) {
                    conn.chunk_state = http.ChunkState.init();
                    conn.chunk_consumed = 0;
                    conn.chunk_decoded = 0;
                } else {
                    conn.body_len = req.content_length orelse 0;
                    if (conn.body_offset + conn.body_len > data.len) {
                        sendStatus(loop, conn, 413, "Content Too Large");
                        return;
                    }
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
                .needs_more => continue,
                .done => {
                    conn.body_len = conn.chunk_decoded;
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
    const data = &conn.read_buf.?.data;
    const body = data[conn.body_offset .. conn.body_offset + conn.body_len];
    const keep_alive = req.wantsKeepAlive();

    const response = bridge.dispatch(req, body, keep_alive, conn.allocator) orelse {
        sendStatus(loop, conn, 500, "Internal Server Error");
        return;
    };

    conn.write_buf = response;
    conn.write_pos = 0;
    conn.state = .writing;
    conn.keep_alive = keep_alive;

    loop.modify(conn.fd, @ptrCast(conn), false, true) catch {
        loop.remove(conn.fd);
        conn.destroy();
        return;
    };

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

    if (conn.keep_alive) {
        keepAliveReset(loop, conn);
    } else {
        loop.remove(conn.fd);
        conn.destroy();
    }
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

    if (leftover > 0) {
        const data = &conn.read_buf.?.data;
        // Forward in-place copy: dest_start (0) < src_start (consumed_end),
        // so a left-to-right loop handles overlap correctly.
        var i: usize = 0;
        while (i < leftover) : (i += 1) {
            data[i] = data[consumed_end + i];
        }
        conn.read_total = leftover;
    } else {
        // Idle: hand the buffer back so RSS isn't held hostage by an idle
        // keep-alive connection.
        conn.releaseBuffer();
        conn.read_total = 0;
    }

    conn.parsed = null;
    conn.body_offset = 0;
    conn.body_len = 0;
    conn.chunk_state = http.ChunkState.init();
    conn.chunk_consumed = 0;
    conn.chunk_decoded = 0;

    if (conn.write_buf.len > 0) {
        conn.allocator.free(conn.write_buf);
        conn.write_buf = &.{};
    }
    conn.write_pos = 0;
    conn.state = .reading;
    conn.keep_alive = false;

    loop.modify(conn.fd, @ptrCast(conn), true, false) catch {
        loop.remove(conn.fd);
        conn.destroy();
        return;
    };

    if (leftover > 0) {
        tryParsePipelined(loop, conn);
    }
}

fn tryParsePipelined(loop: *eventloop.Loop, conn: *Connection) void {
    const data = &conn.read_buf.?.data;
    if (http.parse(data[0..conn.read_total], &conn.headers_storage)) |req| {
        conn.parsed = req;
        conn.body_offset = req.body_offset;
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
                .needs_more => {}, // wait for more bytes
                .done => {
                    conn.body_len = conn.chunk_decoded;
                    dispatch(loop, conn);
                },
                .invalid => sendStatus(loop, conn, 400, "Bad Request"),
            }
        } else {
            conn.body_len = req.content_length orelse 0;
            if (conn.body_offset + conn.body_len > data.len) {
                sendStatus(loop, conn, 413, "Content Too Large");
                return;
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

    loop.modify(conn.fd, @ptrCast(conn), false, true) catch {
        loop.remove(conn.fd);
        conn.destroy();
        return;
    };
    doWrite(loop, conn);
}
