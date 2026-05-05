// Runtime Python <-> Zig bridge for per-request ASGI dispatch.
//
// Owns a small set of long-lived PyObject references:
//   - g_app:          the user's ASGI callable
//   - g_dispatch:     saltare._dispatcher.dispatch
//   - g_server_host:  pre-built str so we don't reallocate per request
//
// The I/O loop in server.zig runs with the GIL released. Once per request,
// `handleRequest` re-acquires the GIL via PyGILState_Ensure, calls into
// Python to produce the wire response, writes it to the socket, then
// releases the GIL again.

const std = @import("std");
const http = @import("http.zig");

pub const py = @cImport({
    // Required since Python 3.13 for any '#' length-prefixed format code
    // (s#, y#, ...). Must be defined before <Python.h> is included.
    @cDefine("PY_SSIZE_T_CLEAN", "1");
    @cInclude("Python.h");
});

const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("unistd.h");
});

var g_app: ?*py.PyObject = null;
var g_dispatch: ?*py.PyObject = null;
var g_server_host: ?*py.PyObject = null;
var g_server_port: c_int = 0;

const FALLBACK_500 =
    "HTTP/1.1 500 Internal Server Error\r\n" ++
    "server: saltare/0.3.0\r\n" ++
    "connection: close\r\n" ++
    "content-length: 0\r\n" ++
    "\r\n";

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
    if (g_app) |a| {
        py.Py_DecRef(a);
        g_app = null;
    }
    if (g_server_host) |h| {
        py.Py_DecRef(h);
        g_server_host = null;
    }
}

/// Run one ASGI dispatch and write the wire response to `client`.
/// Caller (server.zig) does NOT hold the GIL — we re-acquire it here.
pub fn handleRequest(client: c_int, req: http.Request, body: []const u8) void {
    const gstate = py.PyGILState_Ensure();
    defer py.PyGILState_Release(gstate);

    const result = callDispatch(req, body) orelse {
        py.PyErr_Print();
        writeAll(client, FALLBACK_500);
        return;
    };
    defer py.Py_DecRef(result);

    var resp_ptr: [*c]u8 = undefined;
    var resp_len: py.Py_ssize_t = 0;
    if (py.PyBytes_AsStringAndSize(result, @ptrCast(&resp_ptr), &resp_len) != 0) {
        py.PyErr_Clear();
        writeAll(client, FALLBACK_500);
        return;
    }

    writeAll(client, resp_ptr[0..@intCast(resp_len)]);
}

fn callDispatch(req: http.Request, body: []const u8) ?*py.PyObject {
    // Split the request-target into raw_path and query_string at the first '?'.
    const q_idx = std.mem.indexOfScalar(u8, req.target, '?');
    const raw_path = if (q_idx) |i| req.target[0..i] else req.target;
    const query = if (q_idx) |i| req.target[i + 1 ..] else "";

    const headers_obj = buildHeadersList(req.headers) orelse return null;
    defer py.Py_DecRef(headers_obj);

    // Args: (app, method, raw_path, query_string, headers, body, host, port)
    return py.PyObject_CallFunction(
        g_dispatch.?,
        "Os#y#y#Oy#Oi",
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

fn writeAll(client: c_int, data: []const u8) void {
    var written: usize = 0;
    while (written < data.len) {
        const remaining = data[written..];
        const n = c.write(client, @ptrCast(remaining.ptr), remaining.len);
        if (n <= 0) return;
        written += @intCast(n);
    }
}
