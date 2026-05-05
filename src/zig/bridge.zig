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

var g_app: ?*py.PyObject = null;
var g_dispatch: ?*py.PyObject = null;
var g_lifespan_startup: ?*py.PyObject = null;
var g_lifespan_shutdown: ?*py.PyObject = null;
var g_server_host: ?*py.PyObject = null;
var g_server_port: c_int = 0;

/// Caller (module.zig) must hold the GIL.
/// Acquires the references we need to dispatch requests.
pub fn init(app: *py.PyObject, server_host: []const u8, server_port: c_int) bool {
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

    g_server_host = py.PyUnicode_FromStringAndSize(
        @as([*c]const u8, @ptrCast(server_host.ptr)),
        @as(py.Py_ssize_t, @intCast(server_host.len)),
    );
    if (g_server_host == null) return false;

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
    if (g_app) |a| {
        py.Py_DecRef(a);
        g_app = null;
    }
    if (g_server_host) |h| {
        py.Py_DecRef(h);
        g_server_host = null;
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

    // Args: (app, method, raw_path, query_string, headers, body, host, port, keep_alive)
    return py.PyObject_CallFunction(
        g_dispatch.?,
        "Os#y#y#Oy#Oii",
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
    );
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
