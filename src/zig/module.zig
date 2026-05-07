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
const master_mod = @import("master.zig");

const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("sys/types.h");
    @cInclude("sys/wait.h");
    @cInclude("sys/prctl.h");
    @cInclude("signal.h");
});

// glibc-only. We guard the call site with `builtin.os.tag == .linux` so the
// extern reference is dead-code-eliminated on macOS / non-glibc targets and
// the symbol is never resolved at link time on those platforms.
extern fn malloc_trim(pad: usize) c_int;
extern fn mallopt(param: c_int, value: c_int) c_int;

// glibc <malloc.h> macros — values are stable ABI.
const M_ARENA_MAX: c_int = -8;
const M_TRIM_THRESHOLD: c_int = -1;
const M_TOP_PAD: c_int = -2;
const M_MMAP_THRESHOLD: c_int = -3;

/// Tighten glibc's malloc tuning for our workload — single-threaded I/O
/// loop with bursty allocations and idle valleys. We ask for:
///   - `M_ARENA_MAX = 1`        : one arena (no per-thread spread).
///   - `M_TRIM_THRESHOLD 64K`   : trim heap top to OS as soon as 64 KiB
///     of contiguous free space accumulates (default 128 KiB). Returns
///     pages to the OS aggressively so RSS drops back to floor between
///     bursts.
///   - `M_TOP_PAD 64K`          : keep at most 64 KiB of slack at heap
///     top after each trim (default 128 KiB). Smaller floor at idle.
///   - `M_MMAP_THRESHOLD 64K`   : route allocs ≥ 64 KiB through `mmap`
///     instead of the heap (default 128 KiB). Free returns the pages
///     to the OS immediately rather than parking them in the arena.
///     Trade: a few extra `mmap`/`munmap` syscalls per request peak.
/// All of these are no-ops on non-glibc targets — the extern reference
/// stays cold and the call is dead-code-eliminated under `if (linux)`.
fn capMallocArenas() void {
    if (comptime builtin.os.tag != .linux) return;
    _ = mallopt(M_ARENA_MAX, 1);
    _ = mallopt(M_TRIM_THRESHOLD, 64 * 1024);
    _ = mallopt(M_TOP_PAD, 64 * 1024);
    _ = mallopt(M_MMAP_THRESHOLD, 64 * 1024);
}

/// Move every currently-tracked Python object to the GC's "permanent
/// generation" so future cycles never re-trace them. This is a free CPU
/// win single-worker, but the real reason it's here is multi-worker
/// CoW: without freeze(), the very first cyclic-GC sweep in each forked
/// worker writes to the GC's bookkeeping pages, breaking sharing with
/// the master and inflating per-pod RSS. Caller must hold the GIL.
fn freezePython() void {
    const gc_module = py.PyImport_ImportModule("gc") orelse {
        py.PyErr_Clear();
        return;
    };
    defer py.Py_DecRef(gc_module);
    const result = py.PyObject_CallMethod(gc_module, "freeze", null) orelse {
        py.PyErr_Clear();
        return;
    };
    py.Py_DecRef(result);
}

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
    return py.PyUnicode_FromString("1.2.0");
}

fn saltareServe(_: ?*py.PyObject, args: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    var app: ?*py.PyObject = null;
    var host_z: [*c]const u8 = null;
    var port: c_int = 0;
    // `z` accepts None (passed as NULL) or str. The Python wrapper always
    // passes 5 positional args; missing TLS files come through as None.
    var ssl_cert_z: [*c]const u8 = null;
    var ssl_key_z: [*c]const u8 = null;
    // Timeouts (seconds) + caps. Optional in PyArg, but the Python wrapper
    // always forwards explicit values; defaults here only matter for direct
    // _core.serve callers (tests, debugging).
    var header_to: c_uint = 5;
    var keep_alive_to: c_uint = 5;
    var body_to: c_uint = 30;
    var write_to: c_uint = 30;
    var max_concurrent: c_uint = 1024;
    var max_keepalive: c_uint = 1000;
    var max_body: c_ulonglong = 1024 * 1024;
    var shutdown_to: c_uint = 30;
    var uds_path_z: [*c]const u8 = null;
    var metrics_path_z: [*c]const u8 = null;
    var access_log_flag: c_int = 0;
    var ws_keepalive_to: c_uint = 20;
    var workers: c_uint = 1;
    var health_path_z: [*c]const u8 = null;
    var cors_preflight_flag: c_int = 0;
    var rate_limit_per_sec: c_uint = 0;
    var rate_limit_burst: c_uint = 100;
    var tracemalloc_path_z: [*c]const u8 = null;
    var proxy_headers_flag: c_int = 0;
    var favicon_204_flag: c_int = 0;
    var max_conn_per_ip: c_uint = 0;
    var access_log_path_z: [*c]const u8 = null;
    var listen_backlog: c_int = 256;
    var tcp_keepidle: c_int = 0;
    var tcp_keepintvl: c_int = 0;
    var tcp_keepcnt: c_int = 0;
    var proxy_protocol_flag: c_int = 0;

    if (py.PyArg_ParseTuple(
        args,
        "Osizz|IIIIIIKIzziIIziIIziiIziiiii",
        &app,
        &host_z,
        &port,
        &ssl_cert_z,
        &ssl_key_z,
        &header_to,
        &keep_alive_to,
        &body_to,
        &write_to,
        &max_concurrent,
        &max_keepalive,
        &max_body,
        &shutdown_to,
        &uds_path_z,
        &metrics_path_z,
        &access_log_flag,
        &ws_keepalive_to,
        &workers,
        &health_path_z,
        &cors_preflight_flag,
        &rate_limit_per_sec,
        &rate_limit_burst,
        &tracemalloc_path_z,
        &proxy_headers_flag,
        &favicon_204_flag,
        &max_conn_per_ip,
        &access_log_path_z,
        &listen_backlog,
        &tcp_keepidle,
        &tcp_keepintvl,
        &tcp_keepcnt,
        &proxy_protocol_flag,
    ) == 0) {
        return null;
    }

    if (workers == 0 or workers > master_mod.MAX_WORKERS) {
        py.PyErr_SetString(py.PyExc_ValueError, "workers must be in [1, 256]");
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
        .shutdown_secs = @intCast(shutdown_to),
        .ws_keepalive_secs = @intCast(ws_keepalive_to),
    };
    const limits = server.Limits{
        .max_request_body = @intCast(max_body),
        .max_concurrent_connections = @intCast(max_concurrent),
        .max_keepalive_requests = @intCast(max_keepalive),
        .rate_limit_per_sec = @intCast(rate_limit_per_sec),
        .rate_limit_burst = @intCast(rate_limit_burst),
        .max_connections_per_ip = @intCast(max_conn_per_ip),
        .listen_backlog = listen_backlog,
        .tcp_keepidle = tcp_keepidle,
        .tcp_keepintvl = tcp_keepintvl,
        .tcp_keepcnt = tcp_keepcnt,
    };
    const obs = server.Observability{
        .metrics_path = if (metrics_path_z != null) std.mem.span(metrics_path_z) else null,
        .health_path = if (health_path_z != null) std.mem.span(health_path_z) else null,
        .tracemalloc_path = if (tracemalloc_path_z != null) std.mem.span(tracemalloc_path_z) else null,
        .access_log = access_log_flag != 0,
        .access_log_path = if (access_log_path_z != null) std.mem.span(access_log_path_z) else null,
        // The Python dispatcher consumes this for `scope["client"]` and
        // `scope["scheme"]`. Zig also reads it to use the X-Forwarded-For
        // address as the rate-limit key when set, so requests behind a
        // trusted proxy aren't all coalesced into the proxy's TCP peer IP.
        .proxy_headers = proxy_headers_flag != 0,
        .cors_preflight_allow_all = cors_preflight_flag != 0,
        .favicon_204 = favicon_204_flag != 0,
        .proxy_protocol = proxy_protocol_flag != 0,
    };
    const uds_path = if (uds_path_z != null) std.mem.span(uds_path_z) else null;

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

    if (workers > 1) {
        // Multi-worker (v1.0): master binds once, forks N children that
        // each run lifespan + accept loop, then supervises with pause()
        // and waitpid(). Lifespan is per-worker — each child gets its
        // own asyncio loop, its own DB connections, etc. The master
        // never imports the user app's behaviour, only its references.
        const listen_fd = server.bindAndListen(host, @intCast(port), uds_path) catch |err| {
            var msg_buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrintZ(&msg_buf, "saltare bind failed: {s}", .{@errorName(err)}) catch "saltare bind failed";
            py.PyErr_SetString(py.PyExc_RuntimeError, msg.ptr);
            return null;
        };
        return runMultiWorker(app.?, host, port, ssl_cert_z, ssl_key_z, both_set, tls_ctx, timeouts, limits, obs, uds_path, listen_fd, workers);
    }

    // Single-worker path. Identical to v0.18 except `inherited_listen_fd`
    // is now an explicit `null` instead of an absent argument.
    return runSingleWorker(app.?, host, port, both_set, tls_ctx, timeouts, limits, obs, uds_path, null);
}

/// Run lifespan + I/O loop + lifespan-shutdown in this process. Used for
/// both the single-worker entry point and (after fork) each worker child.
fn runSingleWorker(
    app: *py.PyObject,
    host: []const u8,
    port: c_int,
    is_tls: bool,
    tls_ctx: ?*tls.Ctx,
    timeouts: server.Timeouts,
    limits: server.Limits,
    obs: server.Observability,
    uds_path: ?[]const u8,
    inherited_listen_fd: ?c_int,
) ?*py.PyObject {
    if (!bridge.init(app, host, port, is_tls)) {
        return null;
    }

    // Auto-enable tracemalloc tracking when the operator opted in via
    // `tracemalloc_path`. Initialising before lifespan means we capture
    // imports + warm-up allocations in the snapshot too.
    if (obs.tracemalloc_path != null) {
        bridge.tracemallocInit();
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

    // Freeze the GC's tracking. Single-worker case: minor CPU win
    // (smaller per-cycle scans). Multi-worker children that inherit
    // from a master who already froze: their first GC sweep won't
    // dirty any of the master's CoW pages.
    freezePython();

    const tstate = py.PyEval_SaveThread();
    server.run(host, @intCast(port), tls_ctx, timeouts, limits, obs, uds_path, inherited_listen_fd) catch |err| {
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

/// Multi-worker master: forks `workers` children, each running
/// `runSingleWorker` against the master's bound `listen_fd`, then
/// supervises them via `master_mod.manage`. Returns once every child
/// has exited. The master never serves traffic itself.
fn runMultiWorker(
    app: *py.PyObject,
    host: []const u8,
    port: c_int,
    ssl_cert_z: [*c]const u8,
    ssl_key_z: [*c]const u8,
    is_tls: bool,
    tls_ctx: ?*tls.Ctx,
    timeouts: server.Timeouts,
    limits: server.Limits,
    obs: server.Observability,
    uds_path: ?[]const u8,
    listen_fd: c_int,
    workers: c_uint,
) ?*py.PyObject {
    _ = ssl_cert_z;
    _ = ssl_key_z;

    var pids: [master_mod.MAX_WORKERS]c.pid_t = undefined;
    const n: usize = @intCast(workers);
    for (0..n) |i| pids[i] = -1;

    // Freeze BEFORE the fork loop so each child inherits the master's
    // already-frozen permanent generation. The user's app, FastAPI's
    // routing tables, Pydantic's compiled schemas — all get marked
    // perma-shared, so the first GC cycle in each worker doesn't dirty
    // pages the kernel could otherwise keep CoW'd across all workers.
    freezePython();

    var spawned: usize = 0;
    while (spawned < n) : (spawned += 1) {
        const pid = c.fork();
        if (pid < 0) {
            // Fork failed mid-way: terminate any children we already
            // forked, then surface the error.
            for (pids[0..spawned]) |p| {
                if (p > 0) _ = c.kill(p, c.SIGTERM);
            }
            for (pids[0..spawned]) |p| {
                if (p > 0) {
                    var status: c_int = 0;
                    _ = c.waitpid(p, &status, 0);
                }
            }
            _ = c.close(listen_fd);
            py.PyErr_SetString(py.PyExc_RuntimeError, "saltare: fork() failed during worker spawn");
            return null;
        }
        if (pid == 0) {
            // Child. Tell the kernel to send SIGTERM if the master goes
            // away unexpectedly (so an SIGKILL'd master doesn't leave
            // orphan workers behind, which would then take the full
            // shutdown_timeout to notice the world ended).
            if (comptime builtin.os.tag == .linux) {
                _ = c.prctl(c.PR_SET_PDEATHSIG, @as(c_ulong, c.SIGTERM), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0));
            }
            const result = runSingleWorker(app, host, port, is_tls, tls_ctx, timeouts, limits, obs, uds_path, listen_fd);
            // Child must exit — we don't return up the Python call stack.
            // Use the conventional `_exit` to skip atexit handlers (which
            // might double-flush stdio with the master).
            std.c._exit(if (result == null) 1 else 0);
        }
        pids[spawned] = pid;
    }

    // Master supervises. Release the GIL so any incidental Python work
    // in the master process (there shouldn't be any) doesn't deadlock.
    const tstate = py.PyEval_SaveThread();
    master_mod.manage(pids[0..n]);
    py.PyEval_RestoreThread(tstate);

    _ = c.close(listen_fd);

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
    // Cap glibc malloc arenas as early as possible so the Python heap
    // stays in one arena from here on. Skips on non-glibc targets.
    capMallocArenas();
    module_def.m_name = "_core";
    module_def.m_doc = "Saltare native core (Zig backbone).";
    module_def.m_size = -1;
    module_def.m_methods = @ptrCast(&methods[0]);
    return py.PyModule_Create2(&module_def, py.PYTHON_API_VERSION);
}
