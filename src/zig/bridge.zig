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
threadlocal var g_dispatch: ?*py.PyObject = null;
threadlocal var g_lifespan_startup: ?*py.PyObject = null;
threadlocal var g_lifespan_shutdown: ?*py.PyObject = null;
threadlocal var g_ws_open: ?*py.PyObject = null;
threadlocal var g_ws_event: ?*py.PyObject = null;
threadlocal var g_ws_disconnect: ?*py.PyObject = null;
threadlocal var g_server_host: ?*py.PyObject = null;
threadlocal var g_server_port: c_int = 0;
/// "http" or "https" — built once at init so dispatch doesn't reallocate.
threadlocal var g_scheme: ?*py.PyObject = null;

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

    g_dispatch = py.PyObject_GetAttrString(mod, "dispatch") orelse return false;
    g_lifespan_startup = py.PyObject_GetAttrString(mod, "lifespan_startup") orelse return false;
    g_lifespan_shutdown = py.PyObject_GetAttrString(mod, "lifespan_shutdown") orelse return false;
    g_ws_open = py.PyObject_GetAttrString(mod, "ws_open") orelse return false;
    g_ws_event = py.PyObject_GetAttrString(mod, "ws_event") orelse return false;
    g_ws_disconnect = py.PyObject_GetAttrString(mod, "ws_disconnect") orelse return false;

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
    return true;
}

/// Caller (module.zig) must hold the GIL.
pub fn shutdown() void {
    if (g_dispatch) |d| {
        py.Py_DecRef(d);
        g_dispatch = null;
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

/// Run one ASGI dispatch and return the wire response as a freshly allocated
/// buffer. Returns `null` on failure (Python exception was printed to stderr).
/// Caller (server.zig) must NOT hold the GIL — we re-acquire it here.
pub fn dispatch(
    req: http.Request,
    body: []const u8,
    keep_alive: bool,
    allocator: std.mem.Allocator,
) ?[]u8 {
    const gstate = py.PyGILState_Ensure();
    defer py.PyGILState_Release(gstate);

    const result = callDispatch(req, body, keep_alive) orelse {
        py.PyErr_Print();
        return null;
    };
    defer py.Py_DecRef(result);

    var resp_ptr: [*c]u8 = undefined;
    var resp_len: py.Py_ssize_t = 0;
    if (py.PyBytes_AsStringAndSize(result, @ptrCast(&resp_ptr), &resp_len) != 0) {
        py.PyErr_Clear();
        return null;
    }

    const len: usize = @intCast(resp_len);
    const buf = allocator.alloc(u8, len) catch return null;
    @memcpy(buf, resp_ptr[0..len]);
    return buf;
}

fn callDispatch(req: http.Request, body: []const u8, keep_alive: bool) ?*py.PyObject {
    // Split the request-target into raw_path and query_string at the first '?'.
    const q_idx = std.mem.indexOfScalar(u8, req.target, '?');
    const raw_path = if (q_idx) |i| req.target[0..i] else req.target;
    const query = if (q_idx) |i| req.target[i + 1 ..] else "";

    const headers_obj = buildHeadersList(req.headers) orelse return null;
    defer py.Py_DecRef(headers_obj);

    // Args: (app, method, raw_path, query, headers, body, host, port, keep_alive, scheme)
    return py.PyObject_CallFunction(
        g_dispatch.?,
        "Os#y#y#Oy#OiiO",
        g_app.?,
        @as([*c]const u8, @ptrCast(req.method.ptr)),
        @as(py.Py_ssize_t, @intCast(req.method.len)),
        @as([*c]const u8, @ptrCast(raw_path.ptr)),
        @as(py.Py_ssize_t, @intCast(raw_path.len)),
        @as([*c]const u8, @ptrCast(query.ptr)),
        @as(py.Py_ssize_t, @intCast(query.len)),
        headers_obj,
        @as([*c]const u8, @ptrCast(body.ptr)),
        @as(py.Py_ssize_t, @intCast(body.len)),
        g_server_host.?,
        g_server_port,
        @as(c_int, if (keep_alive) 1 else 0),
        g_scheme.?,
    );
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

    const result = py.PyObject_CallFunction(
        g_ws_open.?,
        "Os#y#y#OOiO",
        g_app.?,
        @as([*c]const u8, @ptrCast(req.method.ptr)),
        @as(py.Py_ssize_t, @intCast(req.method.len)),
        @as([*c]const u8, @ptrCast(raw_path.ptr)),
        @as(py.Py_ssize_t, @intCast(raw_path.len)),
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
pub fn wsEvent(handle: c_long, opcode: u8, payload: []const u8, allocator: std.mem.Allocator) ?WsTick {
    const gstate = py.PyGILState_Ensure();
    defer py.PyGILState_Release(gstate);

    const result = py.PyObject_CallFunction(
        g_ws_event.?,
        "liy#",
        handle,
        @as(c_int, @intCast(opcode)),
        @as([*c]const u8, @ptrCast(payload.ptr)),
        @as(py.Py_ssize_t, @intCast(payload.len)),
    ) orelse {
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
    if (py.PyTuple_Size(result) != 4) return null;

    const handle_obj = py.PyTuple_GetItem(result, 0);
    const accepted_obj = py.PyTuple_GetItem(result, 1);
    const frames_obj = py.PyTuple_GetItem(result, 2);
    const done_obj = py.PyTuple_GetItem(result, 3);
    if (handle_obj == null or accepted_obj == null or frames_obj == null or done_obj == null) {
        return null;
    }

    const handle = py.PyLong_AsLong(handle_obj);
    const accepted = py.PyObject_IsTrue(accepted_obj) == 1;
    const done = py.PyObject_IsTrue(done_obj) == 1;
    const frames = copyBytes(frames_obj.?, allocator) orelse return null;

    return .{ .handle = handle, .accepted = accepted, .frames = frames, .done = done };
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

fn buildHeadersList(headers: []const http.Header) ?*py.PyObject {
    const list = py.PyList_New(@intCast(headers.len)) orelse return null;
    for (headers, 0..) |hdr, i| {
        const name_obj = py.PyBytes_FromStringAndSize(
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
