// Python C-API entry point for the `saltare._core` extension.
//
// We deliberately keep this file thin: it owns the module/method table and
// argument parsing, and delegates real work to sibling modules
// (`server.zig` for the I/O loop, ...).

const std = @import("std");
const builtin = @import("builtin");

const py = @cImport({
    @cInclude("Python.h");
});

const server = @import("server.zig");

// CPython's `Py_None` macro just takes the address of the global
// `_Py_NoneStruct`. Declaring it `extern` lets us return Py_None without
// fighting macro translation across Python versions.
extern var _Py_NoneStruct: py.PyObject;

inline fn pyReturnNone() ?*py.PyObject {
    py.Py_IncRef(&_Py_NoneStruct);
    return &_Py_NoneStruct;
}

fn saltareVersion(_: ?*py.PyObject, _: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    return py.PyUnicode_FromString("0.1.0");
}

fn saltareServe(_: ?*py.PyObject, args: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    var host_z: [*c]const u8 = null;
    var port: c_int = 0;

    if (py.PyArg_ParseTuple(args, "si", &host_z, &port) == 0) {
        return null;
    }

    if (port < 0 or port > 65535) {
        py.PyErr_SetString(py.PyExc_ValueError, "port must be in [0, 65535]");
        return null;
    }

    const host = std.mem.span(host_z);

    // Release the GIL: the I/O loop is pure Zig and never touches Python state.
    const tstate = py.PyEval_SaveThread();
    server.run(host, @intCast(port)) catch |err| {
        py.PyEval_RestoreThread(tstate);
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

    // Allow the Python signal handler to fire any pending KeyboardInterrupt
    // we caught with our own SIGINT trap.
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
        .ml_doc = "serve(host: str, port: int) -> None. Bind and serve until SIGINT/SIGTERM.",
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
