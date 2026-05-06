// Python C-API entry point for the `saltare._core` extension.
//
// Surface:
//   - version() -> str        Native core version (matches the wheel's).
//   - serve(app, host, port)  Bind, accept, dispatch ASGI requests to `app`.
//
// This file owns argument parsing and the GIL save/restore around the I/O
// loop. It delegates per-request work to bridge.zig (Python call) and to
// server.zig (the accept loop and HTTP parsing).

const std = @import("std");
const builtin = @import("builtin");

const server = @import("server.zig");
const bridge = @import("bridge.zig");
const tls = @import("tls.zig");

// glibc-only. We guard the call site with `builtin.os.tag == .linux` so the
// extern reference is dead-code-eliminated on macOS / non-glibc targets and
// the symbol is never resolved at link time on those platforms.
extern fn malloc_trim(pad: usize) c_int;

// Reuse bridge.zig's @cImport translation unit. Distinct @cImport blocks
// produce distinct Zig types for the same C structs, which makes
// `*py.PyObject` from one file fail to coerce to `*py.PyObject` from
// another. Sharing the import keeps the type identity stable.
const py = bridge.py;

// CPython's `Py_None` macro is just the address of the global
// `_Py_NoneStruct`. Declaring it `extern` lets us return Py_None without
// fighting macro translation across Python versions.
extern var _Py_NoneStruct: py.PyObject;

inline fn pyReturnNone() ?*py.PyObject {
    py.Py_IncRef(&_Py_NoneStruct);
    return &_Py_NoneStruct;
}

fn saltareVersion(_: ?*py.PyObject, _: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    return py.PyUnicode_FromString("0.12.1");
}

fn saltareServe(_: ?*py.PyObject, args: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    var app: ?*py.PyObject = null;
    var host_z: [*c]const u8 = null;
    var port: c_int = 0;
    // `z` accepts None (passed as NULL) or str. The Python wrapper always
    // passes 5 positional args; missing TLS files come through as None.
    var ssl_cert_z: [*c]const u8 = null;
    var ssl_key_z: [*c]const u8 = null;
    // Timeouts (seconds). Optional in PyArg, but the Python wrapper always
    // forwards explicit values; defaults here only matter for direct
    // _core.serve callers (tests, debugging).
    var header_to: c_uint = 5;
    var keep_alive_to: c_uint = 5;
    var body_to: c_uint = 30;
    var write_to: c_uint = 30;

    if (py.PyArg_ParseTuple(
        args,
        "Osizz|IIII",
        &app,
        &host_z,
        &port,
        &ssl_cert_z,
        &ssl_key_z,
        &header_to,
        &keep_alive_to,
        &body_to,
        &write_to,
    ) == 0) {
        return null;
    }

    if (port < 0 or port > 65535) {
        py.PyErr_SetString(py.PyExc_ValueError, "port must be in [0, 65535]");
        return null;
    }

    const timeouts = server.Timeouts{
        .header_secs = @intCast(header_to),
        .keep_alive_secs = @intCast(keep_alive_to),
        .body_secs = @intCast(body_to),
        .write_secs = @intCast(write_to),
    };

    const both_set = ssl_cert_z != null and ssl_key_z != null;
    const either_set = ssl_cert_z != null or ssl_key_z != null;
    if (either_set and !both_set) {
        py.PyErr_SetString(
            py.PyExc_ValueError,
            "ssl_certfile and ssl_keyfile must be set together",
        );
        return null;
    }

    const host = std.mem.span(host_z);

    // Stand up the TLS context up front: a bad cert/key should fail at
    // serve() time with a clear Python exception, not at first connection.
    var tls_ctx: ?*tls.Ctx = null;
    if (both_set) {
        tls_ctx = tls.newContext(ssl_cert_z, ssl_key_z) catch |err| {
            var msg_buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrintZ(
                &msg_buf,
                "saltare TLS init failed: {s}",
                .{@errorName(err)},
            ) catch "saltare TLS init failed";
            py.PyErr_SetString(py.PyExc_RuntimeError, msg.ptr);
            return null;
        };
    }
    defer if (tls_ctx) |ctx| tls.freeContext(ctx);

    if (!bridge.init(app.?, host, port, both_set)) {
        return null;
    }

    if (!bridge.lifespanStartup()) {
        bridge.shutdown();
        py.PyErr_SetString(py.PyExc_RuntimeError, "saltare: lifespan startup failed");
        return null;
    }

    // Importing FastAPI/Starlette/Pydantic and running lifespan startup
    // leaves glibc's malloc heap fragmented — many short-lived allocations
    // mixed with long-lived objects pin pages that have only a few live
    // bytes. malloc_trim(0) returns those mostly-empty pages to the OS.
    // Typically saves 1–3 MiB at the cost of a few microseconds, called
    // exactly once per `serve()` invocation. No-op on non-glibc systems.
    if (comptime builtin.os.tag == .linux) {
        _ = malloc_trim(0);
    }

    const tstate = py.PyEval_SaveThread();
    server.run(host, @intCast(port), tls_ctx, timeouts) catch |err| {
        py.PyEval_RestoreThread(tstate);
        bridge.lifespanShutdown();
        bridge.shutdown();
        var msg_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrintZ(
            &msg_buf,
            "saltare server failed: {s}",
            .{@errorName(err)},
        ) catch "saltare server failed";
        py.PyErr_SetString(py.PyExc_RuntimeError, msg.ptr);
        return null;
    };
    py.PyEval_RestoreThread(tstate);

    bridge.lifespanShutdown();
    bridge.shutdown();

    if (py.PyErr_CheckSignals() != 0) return null;
    return pyReturnNone();
}

var methods = [_]py.PyMethodDef{
    .{
        .ml_name = "version",
        .ml_meth = @ptrCast(&saltareVersion),
        .ml_flags = py.METH_NOARGS,
        .ml_doc = "version() -> str. Return the native core version string.",
    },
    .{
        .ml_name = "serve",
        .ml_meth = @ptrCast(&saltareServe),
        .ml_flags = py.METH_VARARGS,
        .ml_doc = "serve(app, host: str, port: int) -> None. Bind and serve until SIGINT/SIGTERM.",
    },
    .{ .ml_name = null, .ml_meth = null, .ml_flags = 0, .ml_doc = null },
};

var module_def: py.PyModuleDef = std.mem.zeroes(py.PyModuleDef);

export fn PyInit__core() ?*py.PyObject {
    module_def.m_name = "_core";
    module_def.m_doc = "Saltare native core (Zig backbone).";
    module_def.m_size = -1;
    module_def.m_methods = @ptrCast(&methods[0]);
    return py.PyModule_Create2(&module_def, py.PYTHON_API_VERSION);
}
