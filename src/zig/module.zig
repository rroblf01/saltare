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

const server = @import("server.zig");
const bridge = @import("bridge.zig");

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
    return py.PyUnicode_FromString("0.7.0");
}

fn saltareServe(_: ?*py.PyObject, args: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    var app: ?*py.PyObject = null;
    var host_z: [*c]const u8 = null;
    var port: c_int = 0;

    if (py.PyArg_ParseTuple(args, "Osi", &app, &host_z, &port) == 0) {
        return null;
    }

    if (port < 0 or port > 65535) {
        py.PyErr_SetString(py.PyExc_ValueError, "port must be in [0, 65535]");
        return null;
    }

    const host = std.mem.span(host_z);

    if (!bridge.init(app.?, host, port)) {
        // Either ImportError on saltare._dispatcher or a reference allocation
        // failure. In both cases an exception is already set.
        return null;
    }

    // ASGI lifespan startup. If the app explicitly fails (e.g. raises
    // lifespan.startup.failed), refuse to serve.
    if (!bridge.lifespanStartup()) {
        bridge.shutdown();
        py.PyErr_SetString(py.PyExc_RuntimeError, "saltare: lifespan startup failed");
        return null;
    }

    // Release the GIL: the I/O loop is pure Zig and only re-acquires the
    // GIL once per request, inside bridge.dispatch.
    const tstate = py.PyEval_SaveThread();
    server.run(host, @intCast(port)) catch |err| {
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

    // Drive the lifespan shutdown event before tearing down the bridge —
    // we still need g_lifespan_shutdown alive for the call.
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
