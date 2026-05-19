// Runtime Python <-> Zig bridge for per-request ASGI dispatch.
//
// Owns a small set of long-lived PyObject references:
//   - g_app:          the user's ASGI callable
//   - g_dispatch:     saltare._dispatcher.dispatch
//   - g_server_host:  pre-built str so we don't reallocate per request
//
// In v0.4 the I/O loop runs non-blocking on a single thread with the GIL
// released. Once per request, `dispatch` re-acquires the GIL via
// PyGILState_Ensure, calls into Python to produce the wire response,
// copies the resulting bytes into a Zig-owned buffer, and returns it.
// The server.zig event loop then writes those bytes non-blocking.

const std = @import("std");
const http = @import("http.zig");

pub const py = @cImport({
    // Required since Python 3.13 for any '#' length-prefixed format code
    // (s#, y#, ...). Must be defined before <Python.h> is included.
    @cDefine("PY_SSIZE_T_CLEAN", "1");
    @cInclude("Python.h");
});

// Per-thread bridge state. Keeping these threadlocal avoids
// cross-contamination when multiple `serve()` calls run in different
// daemon threads (most visible in tests): `bridge.init` would otherwise
// DECREF references that another running daemon is still using and
// trigger use-after-free segfaults during cleanup.
threadlocal var g_app: ?*py.PyObject = null;
threadlocal var g_http_start: ?*py.PyObject = null;
threadlocal var g_http_push: ?*py.PyObject = null;
threadlocal var g_http_drain: ?*py.PyObject = null;
threadlocal var g_http_pump: ?*py.PyObject = null;
threadlocal var g_http_abort: ?*py.PyObject = null;
threadlocal var g_lifespan_startup: ?*py.PyObject = null;
threadlocal var g_lifespan_shutdown: ?*py.PyObject = null;
threadlocal var g_ws_open: ?*py.PyObject = null;
threadlocal var g_ws_event: ?*py.PyObject = null;
threadlocal var g_ws_drain: ?*py.PyObject = null;
threadlocal var g_ws_drain_all: ?*py.PyObject = null;
threadlocal var g_ws_disconnect: ?*py.PyObject = null;
threadlocal var g_tracemalloc_dump: ?*py.PyObject = null;
threadlocal var g_tracemalloc_init: ?*py.PyObject = null;
threadlocal var g_http_pop_sendfile: ?*py.PyObject = null;
threadlocal var g_server_host: ?*py.PyObject = null;
threadlocal var g_server_port: c_int = 0;
/// "http" or "https" — built once at init so dispatch doesn't reallocate.
threadlocal var g_scheme: ?*py.PyObject = null;

/// PyBytes cache for HTTP header names that show up on essentially every
/// request. Each PyBytes is built once at `init()`, IncRef'd into the
/// per-request headers list, and freed at `shutdown()`. Saves a
/// `PyBytes_FromStringAndSize` allocation per cached header per request.
/// Names must be lowercase — incoming names are lowercased in Zig before
/// the lookup so the cache is hit-or-miss without case-folding.
const COMMON_HEADER_NAMES = [_][]const u8{
    "host",
    "user-agent",
    "accept",
    "accept-encoding",
    "accept-language",
    "content-type",
    "content-length",
    "connection",
    "cookie",
    "referer",
    "origin",
    "cache-control",
    "transfer-encoding",
    "expect",
    "x-forwarded-for",
    "x-forwarded-proto",
};
threadlocal var g_common_header_cache: [COMMON_HEADER_NAMES.len]?*py.PyObject =
    .{null} ** COMMON_HEADER_NAMES.len;

/// Caller (module.zig) must hold the GIL.
/// Acquires the references we need to dispatch requests.
pub fn init(
    app: *py.PyObject,
    server_host: []const u8,
    server_port: c_int,
    is_tls: bool,
) bool {
    // Idempotent: if a previous serve() call left state behind (test reuse),
    // drop it before installing the new app.
    shutdown();

    py.Py_IncRef(app);
    g_app = app;

    const mod = py.PyImport_ImportModule("saltare._dispatcher") orelse return false;
    defer py.Py_DecRef(mod);

    g_http_start = py.PyObject_GetAttrString(mod, "http_dispatch_start") orelse return false;
    g_http_push = py.PyObject_GetAttrString(mod, "http_dispatch_push_body") orelse return false;
    g_http_drain = py.PyObject_GetAttrString(mod, "http_dispatch_drain") orelse return false;
    g_http_pump = py.PyObject_GetAttrString(mod, "http_global_pump") orelse return false;
    g_http_abort = py.PyObject_GetAttrString(mod, "http_dispatch_abort") orelse return false;
    g_lifespan_startup = py.PyObject_GetAttrString(mod, "lifespan_startup") orelse return false;
    g_lifespan_shutdown = py.PyObject_GetAttrString(mod, "lifespan_shutdown") orelse return false;
    g_ws_open = py.PyObject_GetAttrString(mod, "ws_open") orelse return false;
    g_ws_event = py.PyObject_GetAttrString(mod, "ws_event") orelse return false;
    g_ws_drain = py.PyObject_GetAttrString(mod, "ws_drain") orelse return false;
    g_ws_drain_all = py.PyObject_GetAttrString(mod, "ws_drain_all") orelse return false;
    g_ws_disconnect = py.PyObject_GetAttrString(mod, "ws_disconnect") orelse return false;
    // Optional: only present when tracemalloc_path is configured. Failing
    // here would be fatal; we tolerate absence by clearing the error.
    g_tracemalloc_dump = py.PyObject_GetAttrString(mod, "dump_tracemalloc");
    if (g_tracemalloc_dump == null) py.PyErr_Clear();
    g_tracemalloc_init = py.PyObject_GetAttrString(mod, "init_tracemalloc");
    if (g_tracemalloc_init == null) py.PyErr_Clear();
    g_http_pop_sendfile = py.PyObject_GetAttrString(mod, "http_dispatch_pop_sendfile");
    if (g_http_pop_sendfile == null) py.PyErr_Clear();

    g_server_host = py.PyUnicode_FromStringAndSize(
        @as([*c]const u8, @ptrCast(server_host.ptr)),
        @as(py.Py_ssize_t, @intCast(server_host.len)),
    );
    if (g_server_host == null) return false;

    const scheme = if (is_tls) "https" else "http";
    g_scheme = py.PyUnicode_FromStringAndSize(
        @as([*c]const u8, @ptrCast(scheme.ptr)),
        @as(py.Py_ssize_t, @intCast(scheme.len)),
    );
    if (g_scheme == null) return false;

    g_server_port = server_port;

    // Pre-build PyBytes for common header names. Hot path for every
    // request — saves ~10 PyBytes allocations per request when most of
    // the headers are well-known names.
    for (COMMON_HEADER_NAMES, 0..) |name, idx| {
        const obj = py.PyBytes_FromStringAndSize(
            @as([*c]const u8, @ptrCast(name.ptr)),
            @as(py.Py_ssize_t, @intCast(name.len)),
        );
        if (obj == null) return false;
        g_common_header_cache[idx] = obj;
    }

    return true;
}

/// Caller (module.zig) must hold the GIL.
pub fn shutdown() void {
    if (g_http_start) |s| {
        py.Py_DecRef(s);
        g_http_start = null;
    }
    if (g_http_push) |p| {
        py.Py_DecRef(p);
        g_http_push = null;
    }
    if (g_http_drain) |d| {
        py.Py_DecRef(d);
        g_http_drain = null;
    }
    if (g_http_pump) |p| {
        py.Py_DecRef(p);
        g_http_pump = null;
    }
    if (g_http_abort) |a| {
        py.Py_DecRef(a);
        g_http_abort = null;
    }
    if (g_lifespan_startup) |s| {
        py.Py_DecRef(s);
        g_lifespan_startup = null;
    }
    if (g_lifespan_shutdown) |s| {
        py.Py_DecRef(s);
        g_lifespan_shutdown = null;
    }
    if (g_ws_open) |o| {
        py.Py_DecRef(o);
        g_ws_open = null;
    }
    if (g_ws_event) |e| {
        py.Py_DecRef(e);
        g_ws_event = null;
    }
    if (g_ws_drain) |d| {
        py.Py_DecRef(d);
        g_ws_drain = null;
    }
    if (g_ws_drain_all) |d| {
        py.Py_DecRef(d);
        g_ws_drain_all = null;
    }
    if (g_ws_disconnect) |d| {
        py.Py_DecRef(d);
        g_ws_disconnect = null;
    }
    if (g_app) |a| {
        py.Py_DecRef(a);
        g_app = null;
    }
    if (g_server_host) |h| {
        py.Py_DecRef(h);
        g_server_host = null;
    }
    if (g_scheme) |s| {
        py.Py_DecRef(s);
        g_scheme = null;
    }
    for (&g_common_header_cache) |*slot| {
        if (slot.*) |obj| {
            py.Py_DecRef(obj);
            slot.* = null;
        }
    }
}

/// Drive the ASGI app's lifespan startup. Caller (module.zig) holds the GIL.
/// Returns true on success or if the app doesn't support lifespan; false on
/// explicit startup failure or timeout. The Python helper handles all the
/// asyncio orchestration.
pub fn lifespanStartup() bool {
    const result = py.PyObject_CallOneArg(g_lifespan_startup.?, g_app.?) orelse {
        py.PyErr_Print();
        return false;
    };
    defer py.Py_DecRef(result);
    return py.PyObject_IsTrue(result) == 1;
}

/// Drive the ASGI app's lifespan shutdown. Best-effort. Caller holds the GIL.
pub fn lifespanShutdown() void {
    const result = py.PyObject_CallNoArgs(g_lifespan_shutdown.?) orelse {
        py.PyErr_Print();
        return;
    };
    py.Py_DecRef(result);
}

// ---------------------------------------------------------------------------
// HTTP streaming dispatch (v0.12). Each request is driven by an asyncio.Task
// in Python that we pump through these four entry points. The Python side
// owns wire-format building (status line, headers, chunked framing); Zig
// just shovels raw bytes between sockets and the bridge.

pub const HttpStart = struct {
    /// Opaque handle Python uses to look up the per-request state. Pass
    /// back to push_body / tick / abort. Zero is "never started".
    handle: c_long,
    /// Owned by allocator; caller must free. Empty slice if no chunks yet.
    chunks: []u8,
    /// True if the Task finished synchronously in this initial pump. For
    /// fast non-streaming apps this is the common case.
    done: bool,
};

pub const HttpTick = struct {
    chunks: []u8,
    done: bool,
};

/// Caller (server.zig) does NOT hold the GIL. We re-acquire here.
pub fn httpDispatchStart(
    req: http.Request,
    initial_body: []const u8,
    more_body: bool,
    keep_alive: bool,
    allocator: std.mem.Allocator,
) ?HttpStart {
    const gstate = py.PyGILState_Ensure();
    defer py.PyGILState_Release(gstate);

    const q_idx = std.mem.indexOfScalar(u8, req.target, '?');
    const raw_path = if (q_idx) |i| req.target[0..i] else req.target;
    const query = if (q_idx) |i| req.target[i + 1 ..] else "";

    const headers_obj = buildHeadersList(req.headers) orelse return null;
    defer py.Py_DecRef(headers_obj);

    // v1.3: percent-decode the path in Zig instead of having Python call
    // `urllib.parse.unquote_to_bytes`. Drops the urllib import (saves
    // a couple hundred KiB of stdlib mappings) plus a per-request Python-
    // level pass over the path. Common case (no '%' in the path) skips
    // the allocation entirely and reuses raw_path's buffer.
    var decoded_buf_owned: ?[]u8 = null;
    defer if (decoded_buf_owned) |b| allocator.free(b);
    const decoded_path: []const u8 = if (http.needsUrlDecode(raw_path)) blk: {
        const buf = allocator.alloc(u8, raw_path.len) catch break :blk raw_path;
        decoded_buf_owned = buf;
        const n = http.urlDecode(raw_path, buf);
        break :blk buf[0..n];
    } else raw_path;

    // Args: (app, method, raw_path, decoded_path, query, headers,
    //        initial_body, more_body, host, port, keep_alive, scheme)
    const result = py.PyObject_CallFunction(
        g_http_start.?,
        "Os#y#y#y#Oy#iOiiO",
        g_app.?,
        @as([*c]const u8, @ptrCast(req.method.ptr)),
        @as(py.Py_ssize_t, @intCast(req.method.len)),
        @as([*c]const u8, @ptrCast(raw_path.ptr)),
        @as(py.Py_ssize_t, @intCast(raw_path.len)),
        @as([*c]const u8, @ptrCast(decoded_path.ptr)),
        @as(py.Py_ssize_t, @intCast(decoded_path.len)),
        @as([*c]const u8, @ptrCast(query.ptr)),
        @as(py.Py_ssize_t, @intCast(query.len)),
        headers_obj,
        @as([*c]const u8, @ptrCast(initial_body.ptr)),
        @as(py.Py_ssize_t, @intCast(initial_body.len)),
        @as(c_int, if (more_body) 1 else 0),
        g_server_host.?,
        g_server_port,
        @as(c_int, if (keep_alive) 1 else 0),
        g_scheme.?,
    ) orelse {
        py.PyErr_Print();
        return null;
    };
    defer py.Py_DecRef(result);

    return extractHttpStart(result, allocator);
}

pub fn httpDispatchPushBody(
    handle: c_long,
    body: []const u8,
    more_body: bool,
    allocator: std.mem.Allocator,
) ?HttpTick {
    const gstate = py.PyGILState_Ensure();
    defer py.PyGILState_Release(gstate);

    const result = py.PyObject_CallFunction(
        g_http_push.?,
        "ly#i",
        handle,
        @as([*c]const u8, @ptrCast(body.ptr)),
        @as(py.Py_ssize_t, @intCast(body.len)),
        @as(c_int, if (more_body) 1 else 0),
    ) orelse {
        py.PyErr_Print();
        return null;
    };
    defer py.Py_DecRef(result);

    return extractHttpTick(result, allocator);
}

/// Drain wire bytes the request's Task has emitted *without* pumping the
/// asyncio loop. Use this after `httpGlobalPump` has advanced every Task in
/// flight by one step — it harvests the per-connection output without
/// paying the per-handle pump cost N times.
pub fn httpDispatchDrain(handle: c_long, allocator: std.mem.Allocator) ?HttpTick {
    const gstate = py.PyGILState_Ensure();
    defer py.PyGILState_Release(gstate);

    const result = py.PyObject_CallFunction(g_http_drain.?, "l", handle) orelse {
        py.PyErr_Print();
        return null;
    };
    defer py.Py_DecRef(result);

    return extractHttpTick(result, allocator);
}

/// Run one iteration of the asyncio loop, advancing every in-flight Task by
/// one step. The Zig main loop calls this once per iteration whenever the
/// stalled list is non-empty; per-Task work is then done by `httpDispatchDrain`.
pub fn httpGlobalPump() void {
    const gstate = py.PyGILState_Ensure();
    defer py.PyGILState_Release(gstate);

    const result = py.PyObject_CallNoArgs(g_http_pump.?) orelse {
        py.PyErr_Clear();
        return;
    };
    py.Py_DecRef(result);
}

pub const SendfileRequest = struct {
    /// File path the app asked us to sendfile. Empty = no sendfile.
    path: []u8,
    status: u16,
    keep_alive: bool,
    /// Pre-formatted response headers ready to write to the wire,
    /// minus the `Content-Length` (Zig adds that from `fstat`) and
    /// minus the trailing `\r\n` terminator. Owned by `allocator`.
    headers_block: []u8,
};

/// v1.4: after a dispatch completes (`done=true`), check whether the
/// app emitted `saltare.sendfile`. Returns null when no sendfile was
/// requested (caller writes the response normally). Otherwise returns
/// the path, status, keep-alive flag, and a pre-formatted header
/// block — server.zig opens the file, fstat()s for size, writes the
/// status line + this header block + `Content-Length` + final `\r\n`,
/// then `sendfile(2)`s the body.
pub fn httpDispatchPopSendfile(handle: c_long, allocator: std.mem.Allocator) ?SendfileRequest {
    if (g_http_pop_sendfile == null) return null;
    const gstate = py.PyGILState_Ensure();
    defer py.PyGILState_Release(gstate);
    const result = py.PyObject_CallFunction(g_http_pop_sendfile.?, "l", handle) orelse {
        py.PyErr_Clear();
        return null;
    };
    defer py.Py_DecRef(result);
    if (py.PyTuple_Size(result) != 4) return null;
    const path_obj = py.PyTuple_GetItem(result, 0) orelse return null;
    var path_len: py.Py_ssize_t = 0;
    const path_ptr = py.PyUnicode_AsUTF8AndSize(path_obj, &path_len);
    if (path_ptr == null or path_len == 0) return null;

    const status_obj = py.PyTuple_GetItem(result, 1) orelse return null;
    const headers_obj = py.PyTuple_GetItem(result, 2) orelse return null;
    const ka_obj = py.PyTuple_GetItem(result, 3) orelse return null;

    const status_long = py.PyLong_AsLong(status_obj);
    const status_u16: u16 = @intCast(status_long);
    const keep_alive = py.PyObject_IsTrue(ka_obj) == 1;

    // Copy path into caller-owned memory.
    const plen: usize = @intCast(path_len);
    const path_buf = allocator.alloc(u8, plen) catch return null;
    @memcpy(path_buf, path_ptr[0..plen]);

    // Build headers block: each header as `Name: Value\r\n`. Caller
    // appends `Content-Length: <fstat-size>\r\n\r\n` after.
    var hb: std.ArrayList(u8) = .empty;
    defer hb.deinit(allocator);
    const n_headers = py.PyList_Size(headers_obj);
    var i: py.Py_ssize_t = 0;
    while (i < n_headers) : (i += 1) {
        const tup = py.PyList_GetItem(headers_obj, i) orelse break;
        if (py.PyTuple_Size(tup) != 2) continue;
        const name_obj = py.PyTuple_GetItem(tup, 0) orelse continue;
        const value_obj = py.PyTuple_GetItem(tup, 1) orelse continue;
        var nlen: py.Py_ssize_t = 0;
        var vlen: py.Py_ssize_t = 0;
        const nptr = py.PyBytes_AsString(name_obj);
        nlen = py.PyBytes_Size(name_obj);
        const vptr = py.PyBytes_AsString(value_obj);
        vlen = py.PyBytes_Size(value_obj);
        if (nptr == null or vptr == null) continue;
        // Skip Content-Length / Transfer-Encoding / Connection — Zig owns these.
        if (std.ascii.eqlIgnoreCase(nptr[0..@intCast(nlen)], "content-length")) continue;
        if (std.ascii.eqlIgnoreCase(nptr[0..@intCast(nlen)], "transfer-encoding")) continue;
        if (std.ascii.eqlIgnoreCase(nptr[0..@intCast(nlen)], "connection")) continue;
        hb.appendSlice(allocator, nptr[0..@intCast(nlen)]) catch {
            allocator.free(path_buf);
            return null;
        };
        hb.appendSlice(allocator, ": ") catch {};
        hb.appendSlice(allocator, vptr[0..@intCast(vlen)]) catch {};
        hb.appendSlice(allocator, "\r\n") catch {};
    }
    const headers_block = hb.toOwnedSlice(allocator) catch {
        allocator.free(path_buf);
        return null;
    };

    return .{
        .path = path_buf,
        .status = status_u16,
        .keep_alive = keep_alive,
        .headers_block = headers_block,
    };
}

/// Issue an internal `GET /` against the user app once lifespan startup
/// finished. Warms FastAPI route compilation / pydantic validators /
/// JIT caches so the first real client request doesn't pay the cold-
/// start cliff. Best-effort — any exception in the app is swallowed.
pub fn prewarmApp() void {
    const gstate = py.PyGILState_Ensure();
    defer py.PyGILState_Release(gstate);
    const mod = py.PyImport_ImportModule("saltare._dispatcher") orelse {
        py.PyErr_Clear();
        return;
    };
    defer py.Py_DecRef(mod);
    const fn_obj = py.PyObject_GetAttrString(mod, "prewarm_app") orelse {
        py.PyErr_Clear();
        return;
    };
    defer py.Py_DecRef(fn_obj);
    const result = py.PyObject_CallFunction(fn_obj, "O", g_app.?) orelse {
        py.PyErr_Clear();
        return;
    };
    py.Py_DecRef(result);
}

/// Run `gc.collect(2)` + `gc.freeze()` once. The server calls this from
/// its idle-maintenance tick to release reference cycles accumulated
/// during the previous traffic burst, then re-freezes the surviving
/// objects so the next cyclic-GC sweep doesn't dirty CoW pages in
/// multi-worker setups. Best-effort — any error clears.
pub fn idleMaintenance() void {
    const gstate = py.PyGILState_Ensure();
    defer py.PyGILState_Release(gstate);
    const gc_module = py.PyImport_ImportModule("gc") orelse {
        py.PyErr_Clear();
        return;
    };
    defer py.Py_DecRef(gc_module);
    if (py.PyObject_CallMethod(gc_module, "collect", "i", @as(c_int, 2))) |result| {
        py.Py_DecRef(result);
    } else {
        py.PyErr_Clear();
    }
    if (py.PyObject_CallMethod(gc_module, "freeze", null)) |result| {
        py.Py_DecRef(result);
    } else {
        py.PyErr_Clear();
    }
}

/// Start Python's tracemalloc tracker. Called once at server startup
/// when `tracemalloc_path` is configured. Idempotent — safe to call
/// even if tracemalloc was already started by something else.
pub fn tracemallocInit() void {
    if (g_tracemalloc_init == null) return;
    const gstate = py.PyGILState_Ensure();
    defer py.PyGILState_Release(gstate);
    const result = py.PyObject_CallNoArgs(g_tracemalloc_init.?) orelse {
        py.PyErr_Clear();
        return;
    };
    py.Py_DecRef(result);
}

/// Build a top-N tracemalloc snapshot text dump. Returns the bytes
/// (caller-owned, via `allocator`). Empty slice on error.
pub fn tracemallocDump(allocator: std.mem.Allocator) []u8 {
    if (g_tracemalloc_dump == null) return &[_]u8{};
    const gstate = py.PyGILState_Ensure();
    defer py.PyGILState_Release(gstate);
    const result = py.PyObject_CallNoArgs(g_tracemalloc_dump.?) orelse {
        py.PyErr_Clear();
        return &[_]u8{};
    };
    defer py.Py_DecRef(result);
    return copyBytes(result, allocator) orelse &[_]u8{};
}

pub fn httpDispatchAbort(handle: c_long) void {
    const gstate = py.PyGILState_Ensure();
    defer py.PyGILState_Release(gstate);

    const result = py.PyObject_CallFunction(g_http_abort.?, "l", handle) orelse {
        py.PyErr_Clear();
        return;
    };
    py.Py_DecRef(result);
}

fn extractHttpStart(result: *py.PyObject, allocator: std.mem.Allocator) ?HttpStart {
    if (py.PyTuple_Size(result) != 3) return null;

    const handle_obj = py.PyTuple_GetItem(result, 0);
    const chunks_obj = py.PyTuple_GetItem(result, 1);
    const done_obj = py.PyTuple_GetItem(result, 2);
    if (handle_obj == null or chunks_obj == null or done_obj == null) return null;

    const handle = py.PyLong_AsLong(handle_obj);
    const done = py.PyObject_IsTrue(done_obj) == 1;
    const chunks = copyBytes(chunks_obj.?, allocator) orelse return null;

    return .{ .handle = handle, .chunks = chunks, .done = done };
}

fn extractHttpTick(result: *py.PyObject, allocator: std.mem.Allocator) ?HttpTick {
    if (py.PyTuple_Size(result) != 2) return null;

    const chunks_obj = py.PyTuple_GetItem(result, 0);
    const done_obj = py.PyTuple_GetItem(result, 1);
    if (chunks_obj == null or done_obj == null) return null;

    const done = py.PyObject_IsTrue(done_obj) == 1;
    const chunks = copyBytes(chunks_obj.?, allocator) orelse return null;

    return .{ .chunks = chunks, .done = done };
}

// ---------------------------------------------------------------------------
// WebSocket dispatch helpers. Mirror the (handle, accepted, frames, done)
// return shape of the Python ws_open / ws_event / ws_disconnect functions.
// `frames` is a single Python `bytes` containing zero or more already-encoded
// server-side WS frames concatenated.

pub const WsOpen = struct {
    handle: c_long,
    accepted: bool,
    /// Owned by `allocator` once returned; caller must free.
    frames: []u8,
    done: bool,
    /// Subprotocol the app picked via `accept(subprotocol=...)`. Owned
    /// by `allocator` (zero-length means none — caller checks
    /// `subprotocol.len > 0`). Server.zig echoes this in the
    /// `Sec-WebSocket-Protocol` 101-response header.
    subprotocol: []u8,
    /// v1.6 negotiated WebSocket extension token to echo as the
    /// `Sec-WebSocket-Extensions` 101-response header. Currently
    /// only `permessage-deflate; ...` per RFC 7692. Empty = none.
    /// Owned by `allocator`.
    extensions: []u8,
    /// True iff per-message-deflate was negotiated. Server.zig flips
    /// `conn.ws_pmd_active` so subsequent rsv1 hints flow correctly.
    pmd_active: bool,
    /// v1.7 — close code the consumer emitted via `websocket.close`
    /// before accepting. 0 = the app never called `close()` (just
    /// hung up / never returned `accept`). Server.zig maps non-zero
    /// codes to an HTTP status on the reject path (4003 → 403,
    /// 4001 → 401, 4004 → 404, 4029 → 429, anything else → 403).
    close_code: u16,
    /// v1.7 — `reason` string from the `websocket.close` event. Owned
    /// by `allocator`; empty when absent. Used by `--ws-reject-log`.
    close_reason: []u8,
};

pub const WsTick = struct {
    /// Owned by `allocator`; caller must free.
    frames: []u8,
    done: bool,
};

/// Caller (server.zig) does NOT hold the GIL. We re-acquire here.
pub fn wsOpen(req: http.Request, allocator: std.mem.Allocator) ?WsOpen {
    const gstate = py.PyGILState_Ensure();
    defer py.PyGILState_Release(gstate);

    const q_idx = std.mem.indexOfScalar(u8, req.target, '?');
    const raw_path = if (q_idx) |i| req.target[0..i] else req.target;
    const query = if (q_idx) |i| req.target[i + 1 ..] else "";

    const headers_obj = buildHeadersList(req.headers) orelse return null;
    defer py.Py_DecRef(headers_obj);

    var decoded_buf_owned: ?[]u8 = null;
    defer if (decoded_buf_owned) |b| allocator.free(b);
    const decoded_path: []const u8 = if (http.needsUrlDecode(raw_path)) blk: {
        const buf = allocator.alloc(u8, raw_path.len) catch break :blk raw_path;
        decoded_buf_owned = buf;
        const n = http.urlDecode(raw_path, buf);
        break :blk buf[0..n];
    } else raw_path;

    const result = py.PyObject_CallFunction(
        g_ws_open.?,
        "Os#y#y#y#OOiO",
        g_app.?,
        @as([*c]const u8, @ptrCast(req.method.ptr)),
        @as(py.Py_ssize_t, @intCast(req.method.len)),
        @as([*c]const u8, @ptrCast(raw_path.ptr)),
        @as(py.Py_ssize_t, @intCast(raw_path.len)),
        @as([*c]const u8, @ptrCast(decoded_path.ptr)),
        @as(py.Py_ssize_t, @intCast(decoded_path.len)),
        @as([*c]const u8, @ptrCast(query.ptr)),
        @as(py.Py_ssize_t, @intCast(query.len)),
        headers_obj,
        g_server_host.?,
        g_server_port,
        g_scheme.?,
    ) orelse {
        py.PyErr_Print();
        return null;
    };
    defer py.Py_DecRef(result);

    return extractWsOpen(result, allocator);
}

/// Push one WebSocket text/binary frame into the running coroutine and pump
/// the Python loop. Returns the encoded frames the app produced, plus a
/// `done` flag if the coroutine has finished. `opcode` is 0x1 (text) or 0x2.
pub fn wsEvent(handle: c_long, opcode: u8, payload: []const u8, rsv1: bool, allocator: std.mem.Allocator) ?WsTick {
    const gstate = py.PyGILState_Ensure();
    defer py.PyGILState_Release(gstate);

    const result = py.PyObject_CallFunction(
        g_ws_event.?,
        "liy#i",
        handle,
        @as(c_int, @intCast(opcode)),
        @as([*c]const u8, @ptrCast(payload.ptr)),
        @as(py.Py_ssize_t, @intCast(payload.len)),
        @as(c_int, if (rsv1) 1 else 0),
    ) orelse {
        py.PyErr_Print();
        return null;
    };
    defer py.Py_DecRef(result);

    return extractWsTick(result, allocator);
}

pub const WsDrainEntry = struct {
    handle: c_long,
    /// Owned by allocator; caller frees.
    frames: []u8,
    done: bool,
};

/// v1.7.1 — batched server-initiated drain. Single GIL hop +
/// single Python call returns the entries for every WS conn that
/// has bytes to flush OR has hit a terminal state. Caller frees
/// each `frames` slice (and the outer slice itself). Returns null
/// on call failure; returns an empty slice when nothing to flush
/// (caller can ignore safely — no allocation in that case).
pub fn wsDrainAll(allocator: std.mem.Allocator) ?[]WsDrainEntry {
    const gstate = py.PyGILState_Ensure();
    defer py.PyGILState_Release(gstate);

    const result = py.PyObject_CallObject(g_ws_drain_all.?, null) orelse {
        py.PyErr_Print();
        return null;
    };
    defer py.Py_DecRef(result);

    const n = py.PyList_Size(result);
    if (n <= 0) return &.{};
    const entries = allocator.alloc(WsDrainEntry, @intCast(n)) catch return null;
    var i: py.Py_ssize_t = 0;
    while (i < n) : (i += 1) {
        const tup = py.PyList_GetItem(result, i);
        if (tup == null) {
            // Free anything we already populated and bail.
            var k: usize = 0;
            while (k < @as(usize, @intCast(i))) : (k += 1) {
                if (entries[k].frames.len > 0) allocator.free(entries[k].frames);
            }
            allocator.free(entries);
            return null;
        }
        const handle_obj = py.PyTuple_GetItem(tup, 0);
        const frames_obj = py.PyTuple_GetItem(tup, 1);
        const done_obj = py.PyTuple_GetItem(tup, 2);
        const handle = py.PyLong_AsLong(handle_obj);
        const done = py.PyObject_IsTrue(done_obj) == 1;
        const frames = copyBytes(frames_obj.?, allocator) orelse {
            var k: usize = 0;
            while (k < @as(usize, @intCast(i))) : (k += 1) {
                if (entries[k].frames.len > 0) allocator.free(entries[k].frames);
            }
            allocator.free(entries);
            return null;
        };
        entries[@intCast(i)] = .{ .handle = handle, .frames = frames, .done = done };
    }
    return entries;
}

/// v1.7.1 — server-initiated drain. Pulls any bytes the consumer
/// queued since the last tick (typically from `channel_layer.group_send`
/// → consumer handler → `await self.send(...)`) without pushing any
/// inbound event. The asyncio loop should already have been pumped
/// (`httpGlobalPump`) before this call so the consumer task ran to
/// its next park. Returns (frames, done) like `wsEvent`.
pub fn wsDrain(handle: c_long, allocator: std.mem.Allocator) ?WsTick {
    const gstate = py.PyGILState_Ensure();
    defer py.PyGILState_Release(gstate);

    const result = py.PyObject_CallFunction(g_ws_drain.?, "l", handle) orelse {
        py.PyErr_Print();
        return null;
    };
    defer py.Py_DecRef(result);
    return extractWsTick(result, allocator);
}

/// Tell Python the connection is gone (clean close, peer reset, etc.). Drains
/// any final frames the coroutine produces during teardown.
pub fn wsDisconnect(handle: c_long, code: u16, allocator: std.mem.Allocator) []u8 {
    const gstate = py.PyGILState_Ensure();
    defer py.PyGILState_Release(gstate);

    const result = py.PyObject_CallFunction(
        g_ws_disconnect.?,
        "li",
        handle,
        @as(c_int, code),
    ) orelse {
        py.PyErr_Clear();
        return &.{};
    };
    defer py.Py_DecRef(result);

    return copyBytes(result, allocator) orelse &.{};
}

fn extractWsOpen(result: *py.PyObject, allocator: std.mem.Allocator) ?WsOpen {
    if (py.PyTuple_Size(result) != 9) return null;

    const handle_obj = py.PyTuple_GetItem(result, 0);
    const accepted_obj = py.PyTuple_GetItem(result, 1);
    const frames_obj = py.PyTuple_GetItem(result, 2);
    const done_obj = py.PyTuple_GetItem(result, 3);
    const sub_obj = py.PyTuple_GetItem(result, 4);
    const ext_obj = py.PyTuple_GetItem(result, 5);
    const pmd_obj = py.PyTuple_GetItem(result, 6);
    const close_code_obj = py.PyTuple_GetItem(result, 7);
    const close_reason_obj = py.PyTuple_GetItem(result, 8);
    if (handle_obj == null or accepted_obj == null or frames_obj == null or
        done_obj == null or sub_obj == null or ext_obj == null or pmd_obj == null or
        close_code_obj == null or close_reason_obj == null) {
        return null;
    }

    const handle = py.PyLong_AsLong(handle_obj);
    const accepted = py.PyObject_IsTrue(accepted_obj) == 1;
    const done = py.PyObject_IsTrue(done_obj) == 1;
    const pmd_active = py.PyObject_IsTrue(pmd_obj) == 1;
    const frames = copyBytes(frames_obj.?, allocator) orelse return null;

    // Subprotocol arrives as a Python `str` (empty when the app didn't
    // pick one). Translate to bytes via PyUnicode_AsUTF8AndSize so we
    // don't need a roundtrip through `bytes`.
    var sub_len: py.Py_ssize_t = 0;
    const sub_ptr = py.PyUnicode_AsUTF8AndSize(sub_obj.?, &sub_len);
    var subprotocol: []u8 = &.{};
    if (sub_ptr != null and sub_len > 0) {
        const len: usize = @intCast(sub_len);
        const buf = allocator.alloc(u8, len) catch {
            allocator.free(frames);
            return null;
        };
        @memcpy(buf, sub_ptr[0..len]);
        subprotocol = buf;
    }

    var ext_len: py.Py_ssize_t = 0;
    const ext_ptr = py.PyUnicode_AsUTF8AndSize(ext_obj.?, &ext_len);
    var extensions: []u8 = &.{};
    if (ext_ptr != null and ext_len > 0) {
        const len: usize = @intCast(ext_len);
        const buf = allocator.alloc(u8, len) catch {
            allocator.free(frames);
            if (subprotocol.len > 0) allocator.free(subprotocol);
            return null;
        };
        @memcpy(buf, ext_ptr[0..len]);
        extensions = buf;
    }

    // v1.7 close code (int) + reason (str). Reason is owned-by-allocator
    // (empty when absent). Code is clamped to u16; WebSocket close codes
    // live in 1000–4999 per RFC 6455 §7.4.
    const code_raw = py.PyLong_AsLong(close_code_obj);
    const close_code: u16 = if (code_raw > 0 and code_raw <= 65535)
        @intCast(code_raw)
    else
        0;
    var reason_len: py.Py_ssize_t = 0;
    const reason_ptr = py.PyUnicode_AsUTF8AndSize(close_reason_obj.?, &reason_len);
    var close_reason: []u8 = &.{};
    if (reason_ptr != null and reason_len > 0) {
        const len: usize = @intCast(reason_len);
        const buf = allocator.alloc(u8, len) catch {
            allocator.free(frames);
            if (subprotocol.len > 0) allocator.free(subprotocol);
            if (extensions.len > 0) allocator.free(extensions);
            return null;
        };
        @memcpy(buf, reason_ptr[0..len]);
        close_reason = buf;
    }

    return .{
        .handle = handle,
        .accepted = accepted,
        .frames = frames,
        .done = done,
        .subprotocol = subprotocol,
        .extensions = extensions,
        .pmd_active = pmd_active,
        .close_code = close_code,
        .close_reason = close_reason,
    };
}

fn extractWsTick(result: *py.PyObject, allocator: std.mem.Allocator) ?WsTick {
    if (py.PyTuple_Size(result) != 2) return null;

    const frames_obj = py.PyTuple_GetItem(result, 0);
    const done_obj = py.PyTuple_GetItem(result, 1);
    if (frames_obj == null or done_obj == null) return null;

    const done = py.PyObject_IsTrue(done_obj) == 1;
    const frames = copyBytes(frames_obj.?, allocator) orelse return null;

    return .{ .frames = frames, .done = done };
}

fn copyBytes(obj: *py.PyObject, allocator: std.mem.Allocator) ?[]u8 {
    var ptr: [*c]u8 = undefined;
    var len: py.Py_ssize_t = 0;
    if (py.PyBytes_AsStringAndSize(obj, @ptrCast(&ptr), &len) != 0) {
        py.PyErr_Clear();
        return null;
    }
    const n: usize = @intCast(len);
    // Empty result: return a static empty slice. Callers know not to free
    // zero-length results (no allocation was made).
    if (n == 0) return &[_]u8{};
    const buf = allocator.alloc(u8, n) catch return null;
    @memcpy(buf, ptr[0..n]);
    return buf;
}

/// Look up a (lowercased) header name in the common-name cache. On hit,
/// returns an IncRef'd reference the caller can pass to PyTuple_SetItem
/// (which steals it). On miss, returns null and the caller falls back
/// to allocating a fresh PyBytes. Linear scan over ~16 entries — well
/// below the cost of allocating a PyBytes object.
fn lookupCachedHeaderName(name: []const u8) ?*py.PyObject {
    for (COMMON_HEADER_NAMES, 0..) |candidate, idx| {
        if (std.mem.eql(u8, name, candidate)) {
            const cached = g_common_header_cache[idx] orelse return null;
            py.Py_IncRef(cached);
            return cached;
        }
    }
    return null;
}

fn buildHeadersList(headers: []const http.Header) ?*py.PyObject {
    const list = py.PyList_New(@intCast(headers.len)) orelse return null;
    for (headers, 0..) |hdr, i| {
        // ASGI requires lowercase header names. We lowercase in place
        // (the bytes live in the connection's read buffer, owned by
        // this request) so Python doesn't need to call `.lower()` on
        // every header — saving ~50 B per header in transient bytes
        // allocations and avoiding the per-header tuple rebuild that
        // a list-comprehension `.lower()` would force.
        const mut_name = @constCast(hdr.name);
        for (mut_name) |*b| {
            b.* = std.ascii.toLower(b.*);
        }
        const name_obj = lookupCachedHeaderName(hdr.name) orelse py.PyBytes_FromStringAndSize(
            @as([*c]const u8, @ptrCast(hdr.name.ptr)),
            @as(py.Py_ssize_t, @intCast(hdr.name.len)),
        ) orelse {
            py.Py_DecRef(list);
            return null;
        };
        const value_obj = py.PyBytes_FromStringAndSize(
            @as([*c]const u8, @ptrCast(hdr.value.ptr)),
            @as(py.Py_ssize_t, @intCast(hdr.value.len)),
        ) orelse {
            py.Py_DecRef(name_obj);
            py.Py_DecRef(list);
            return null;
        };
        const tuple = py.PyTuple_New(2) orelse {
            py.Py_DecRef(name_obj);
            py.Py_DecRef(value_obj);
            py.Py_DecRef(list);
            return null;
        };
        // PyTuple_SetItem and PyList_SetItem steal the reference.
        _ = py.PyTuple_SetItem(tuple, 0, name_obj);
        _ = py.PyTuple_SetItem(tuple, 1, value_obj);
        _ = py.PyList_SetItem(list, @intCast(i), tuple);
    }
    return list;
}
