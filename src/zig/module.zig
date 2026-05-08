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
const zlib_mod = @import("zlib.zig");
const brotli_mod = @import("brotli.zig");
const zstd_mod = @import("zstd.zig");

const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("sys/types.h");
    @cInclude("sys/wait.h");
    @cInclude("sys/prctl.h");
    @cInclude("signal.h");
});

/// Set the process short-name visible in `ps -e -o comm`, `top`,
/// `htop`. Linux-only (glibc `prctl(PR_SET_NAME)`); silently no-ops
/// elsewhere. Truncated to 15 chars. v1.3 cosmetic helper for ops.
fn setProcName(name: []const u8) void {
    if (comptime builtin.os.tag != .linux) return;
    var buf: [16]u8 = std.mem.zeroes([16]u8);
    const n = @min(name.len, 15);
    @memcpy(buf[0..n], name[0..n]);
    _ = c.prctl(
        c.PR_SET_NAME,
        @as(c_ulong, @intFromPtr(&buf)),
        @as(c_ulong, 0),
        @as(c_ulong, 0),
        @as(c_ulong, 0),
    );
}

// glibc-only. We guard the call site with `builtin.os.tag == .linux` so the
// extern reference is dead-code-eliminated on macOS / non-glibc targets and
// the symbol is never resolved at link time on those platforms.
//
// musl libc is the special case: musllinux wheels are linked against musl,
// which doesn't ship `mallopt` / `malloc_trim`. The extern fn declaration
// would still resolve at load time and ImportError the .so. Resolve via
// `dlsym(RTLD_DEFAULT, ...)` at first use; if NULL (musl), the wrapper
// no-ops. Same applies to `malloc_trim`.
const dl = @cImport({
    @cInclude("dlfcn.h");
});

const Mallopt = *const fn (c_int, c_int) callconv(.c) c_int;
const MallocTrim = *const fn (usize) callconv(.c) c_int;
var g_mallopt: ?Mallopt = null;
var g_malloc_trim: ?MallocTrim = null;
var g_libc_probed: bool = false;

fn probeLibc() void {
    if (g_libc_probed) return;
    g_libc_probed = true;
    // RTLD_DEFAULT = NULL on both glibc + musl. translate-c sometimes
    // omits this preprocessor define so we pass null explicitly.
    const mp = dl.dlsym(null, "mallopt");
    if (mp != null) g_mallopt = @ptrCast(@alignCast(mp));
    const mt = dl.dlsym(null, "malloc_trim");
    if (mt != null) g_malloc_trim = @ptrCast(@alignCast(mt));
}

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
    probeLibc();
    const mp = g_mallopt orelse return; // musl: no mallopt, silent skip
    _ = mp(M_ARENA_MAX, 1);
    _ = mp(M_TRIM_THRESHOLD, 64 * 1024);
    _ = mp(M_TOP_PAD, 64 * 1024);
    _ = mp(M_MMAP_THRESHOLD, 64 * 1024);
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
    return py.PyUnicode_FromString("1.6.0");
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
    var tcp_user_timeout_ms: c_int = 0;
    var auto_raise_nofile_flag: c_int = 0;
    var max_conn_lifetime: c_uint = 0;
    var tls_session_cache: c_uint = 0;
    var startup_request_flag: c_int = 0;
    var server_header_z: [*c]const u8 = null;
    var ssl_ca_z: [*c]const u8 = null;
    var ssl_verify_client_flag: c_int = 0;
    var tcp_fastopen_qlen: c_int = 0;
    var gc_collect_every_n: c_uint = 0;
    var max_request_uri: c_uint = 8192;
    var max_request_head_bytes: c_uint = 0;
    var latency_histogram_flag: c_int = 0;
    var dispatch_path_z: [*c]const u8 = null;
    var runtime_config_path_z: [*c]const u8 = null;
    var dispatch_token_z: [*c]const u8 = null;
    var ktls_flag: c_int = 0;
    var drain_path_z: [*c]const u8 = null;

    if (py.PyArg_ParseTuple(
        args,
        "Osizz|IIIIIIKIzziIIziIIziiIziiiiiiiIIizziiIIIizzziz",
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
        &tcp_user_timeout_ms,
        &auto_raise_nofile_flag,
        &max_conn_lifetime,
        &tls_session_cache,
        &startup_request_flag,
        &server_header_z,
        &ssl_ca_z,
        &ssl_verify_client_flag,
        &tcp_fastopen_qlen,
        &gc_collect_every_n,
        &max_request_uri,
        &max_request_head_bytes,
        &latency_histogram_flag,
        &dispatch_path_z,
        &runtime_config_path_z,
        &dispatch_token_z,
        &ktls_flag,
        &drain_path_z,
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
        .tcp_user_timeout_ms = tcp_user_timeout_ms,
        .auto_raise_nofile = auto_raise_nofile_flag != 0,
        .max_connection_lifetime_secs = @intCast(max_conn_lifetime),
        .tcp_fastopen_qlen = tcp_fastopen_qlen,
        .max_request_uri = @intCast(max_request_uri),
        .max_request_head_bytes = @intCast(max_request_head_bytes),
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
        .server_header = if (server_header_z != null) std.mem.span(server_header_z) else null,
        .startup_request = startup_request_flag != 0,
        .latency_histogram = latency_histogram_flag != 0,
        .dispatch_path = if (dispatch_path_z != null) std.mem.span(dispatch_path_z) else null,
        .runtime_config_path = if (runtime_config_path_z != null) std.mem.span(runtime_config_path_z) else null,
        .dispatch_token = if (dispatch_token_z != null) std.mem.span(dispatch_token_z) else null,
        .drain_path = if (drain_path_z != null) std.mem.span(drain_path_z) else null,
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
        tls_ctx = tls.newContext(ssl_cert_z, ssl_key_z, tls_session_cache, ssl_ca_z, ssl_verify_client_flag != 0, ktls_flag != 0) catch |err| {
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
        return runMultiWorker(app.?, host, port, ssl_cert_z, ssl_key_z, both_set, tls_ctx, timeouts, limits, obs, uds_path, listen_fd, workers, ktls_flag != 0);
    }

    // Single-worker path. Identical to v0.18 except `inherited_listen_fd`
    // is now an explicit `null` instead of an absent argument.
    setProcName("saltare");
    return runSingleWorker(app.?, host, port, both_set, tls_ctx, timeouts, limits, obs, uds_path, null, ktls_flag != 0);
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
    ktls: bool,
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

    // v1.3: optional pre-warm. Drives a synthetic GET / through the
    // app so the first real client doesn't pay cold-start latency.
    if (obs.startup_request) {
        bridge.prewarmApp();
    }

    // Importing FastAPI/Starlette/Pydantic and running lifespan startup
    // leaves glibc's malloc heap fragmented — many short-lived allocations
    // mixed with long-lived objects pin pages that have only a few live
    // bytes. malloc_trim(0) returns those mostly-empty pages to the OS.
    // Typically saves 1–3 MiB at the cost of a few microseconds, called
    // exactly once per `serve()` invocation. No-op on non-glibc systems.
    if (comptime builtin.os.tag == .linux) {
        probeLibc();
        if (g_malloc_trim) |mt| _ = mt(0);
    }

    // Freeze the GC's tracking. Single-worker case: minor CPU win
    // (smaller per-cycle scans). Multi-worker children that inherit
    // from a master who already froze: their first GC sweep won't
    // dirty any of the master's CoW pages.
    freezePython();

    const tstate = py.PyEval_SaveThread();
    server.run(host, @intCast(port), tls_ctx, timeouts, limits, obs, uds_path, inherited_listen_fd, ktls) catch |err| {
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
    ktls: bool,
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
    setProcName("saltare:master");

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
            // Operational ergonomics: rename in `ps` / `top` so
            // operators see `saltare:wkr0` instead of the full
            // `python -OO -m saltare main:app ...` command line.
            var name_buf: [16]u8 = undefined;
            const wname = std.fmt.bufPrint(&name_buf, "saltare:wkr{d}", .{spawned}) catch "saltare:wkr";
            setProcName(wname);
            const result = runSingleWorker(app, host, port, is_tls, tls_ctx, timeouts, limits, obs, uds_path, listen_fd, ktls);
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

/// gzip_encode(payload: bytes, level: int = 6) -> bytes | None.
/// Returns None when libz can't be loaded (musl images without libz, etc.).
/// Used by the Python dispatcher to compress response bodies when the
/// client negotiated `Accept-Encoding: gzip`. Lazy-loads libz on first
/// call — plain-HTTP / no-compression deployments never pay the lib mapping.
fn saltareGzipEncode(_: ?*py.PyObject, args: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    var src_ptr: [*c]const u8 = null;
    var src_len: py.Py_ssize_t = 0;
    var level: c_int = 6;
    if (py.PyArg_ParseTuple(args, "y#|i", &src_ptr, &src_len, &level) == 0) return null;
    const src = src_ptr[0..@intCast(src_len)];
    // Release the GIL: zlib's deflate path is pure CPU and can be 100s of µs
    // for non-trivial bodies; letting other threads run during compression
    // matters when free-threaded Python lands.
    const save = py.PyEval_SaveThread();
    const out = zlib_mod.gzipEncode(src, std.heap.c_allocator, level);
    py.PyEval_RestoreThread(save);
    if (out == null) return pyReturnNone();
    defer std.heap.c_allocator.free(out.?);
    return py.PyBytes_FromStringAndSize(@ptrCast(out.?.ptr), @intCast(out.?.len));
}

/// brotli_encode(payload: bytes, quality: int = 4) -> bytes | None.
/// Lazy-loads libbrotlienc + libbrotlidec; returns None on miss. Used
/// when client sends `Accept-Encoding: br`.
fn saltareBrotliEncode(_: ?*py.PyObject, args: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    var src_ptr: [*c]const u8 = null;
    var src_len: py.Py_ssize_t = 0;
    var quality: c_int = brotli_mod.DEFAULT_QUALITY;
    if (py.PyArg_ParseTuple(args, "y#|i", &src_ptr, &src_len, &quality) == 0) return null;
    const src = src_ptr[0..@intCast(src_len)];
    const save = py.PyEval_SaveThread();
    const out = brotli_mod.brotliEncode(src, std.heap.c_allocator, quality);
    py.PyEval_RestoreThread(save);
    if (out == null) return pyReturnNone();
    defer std.heap.c_allocator.free(out.?);
    return py.PyBytes_FromStringAndSize(@ptrCast(out.?.ptr), @intCast(out.?.len));
}

/// brotli_decode(payload: bytes, max_size: int) -> bytes | None.
fn saltareBrotliDecode(_: ?*py.PyObject, args: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    var src_ptr: [*c]const u8 = null;
    var src_len: py.Py_ssize_t = 0;
    var max_size: c_ulonglong = 0;
    if (py.PyArg_ParseTuple(args, "y#K", &src_ptr, &src_len, &max_size) == 0) return null;
    const src = src_ptr[0..@intCast(src_len)];
    const save = py.PyEval_SaveThread();
    const out = brotli_mod.brotliDecode(src, std.heap.c_allocator, @intCast(max_size));
    py.PyEval_RestoreThread(save);
    if (out == null) return pyReturnNone();
    defer std.heap.c_allocator.free(out.?);
    return py.PyBytes_FromStringAndSize(@ptrCast(out.?.ptr), @intCast(out.?.len));
}

/// zstd_encode(payload: bytes, level: int = 3) -> bytes | None.
fn saltareZstdEncode(_: ?*py.PyObject, args: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    var src_ptr: [*c]const u8 = null;
    var src_len: py.Py_ssize_t = 0;
    var level: c_int = zstd_mod.DEFAULT_LEVEL;
    if (py.PyArg_ParseTuple(args, "y#|i", &src_ptr, &src_len, &level) == 0) return null;
    const src = src_ptr[0..@intCast(src_len)];
    const save = py.PyEval_SaveThread();
    const out = zstd_mod.zstdEncode(src, std.heap.c_allocator, level);
    py.PyEval_RestoreThread(save);
    if (out == null) return pyReturnNone();
    defer std.heap.c_allocator.free(out.?);
    return py.PyBytes_FromStringAndSize(@ptrCast(out.?.ptr), @intCast(out.?.len));
}

/// zstd_decode(payload: bytes, max_size: int) -> bytes | None.
fn saltareZstdDecode(_: ?*py.PyObject, args: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    var src_ptr: [*c]const u8 = null;
    var src_len: py.Py_ssize_t = 0;
    var max_size: c_ulonglong = 0;
    if (py.PyArg_ParseTuple(args, "y#K", &src_ptr, &src_len, &max_size) == 0) return null;
    const src = src_ptr[0..@intCast(src_len)];
    const save = py.PyEval_SaveThread();
    const out = zstd_mod.zstdDecode(src, std.heap.c_allocator, @intCast(max_size));
    py.PyEval_RestoreThread(save);
    if (out == null) return pyReturnNone();
    defer std.heap.c_allocator.free(out.?);
    return py.PyBytes_FromStringAndSize(@ptrCast(out.?.ptr), @intCast(out.?.len));
}

// v1.6 streaming brotli/zstd. Python dispatcher creates one
// encoder per response, feeds chunks, calls finish on the last one.
// Handle is the raw `BrotliEncoderState*` / `ZSTD_CCtx*` cast to int.

// Pointer ↔ Python int via unsigned long long. PyLong_FromVoidPtr is a
// macro under translate-c which sometimes doesn't surface as a callable;
// the explicit ULL path works on every CPython we target.
inline fn ptrToPyLong(p: ?*anyopaque) ?*py.PyObject {
    const u: c_ulonglong = @intCast(@intFromPtr(p));
    return py.PyLong_FromUnsignedLongLong(u);
}
inline fn pyLongToPtr(obj: ?*py.PyObject) ?*anyopaque {
    if (obj == null) return null;
    const u = py.PyLong_AsUnsignedLongLong(obj);
    if (u == 0) return null;
    return @ptrFromInt(@as(usize, @intCast(u)));
}

fn saltareBrotliStreamCreate(_: ?*py.PyObject, args: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    var quality: c_int = brotli_mod.DEFAULT_QUALITY;
    if (py.PyArg_ParseTuple(args, "|i", &quality) == 0) return null;
    const handle = brotli_mod.streamCreate(quality);
    if (handle == null) return pyReturnNone();
    return ptrToPyLong(handle);
}

fn saltareBrotliStreamCompress(_: ?*py.PyObject, args: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    var handle_obj: ?*py.PyObject = null;
    var src_ptr: [*c]const u8 = null;
    var src_len: py.Py_ssize_t = 0;
    var finish: c_int = 0;
    if (py.PyArg_ParseTuple(args, "Oy#p", &handle_obj, &src_ptr, &src_len, &finish) == 0) return null;
    const handle = pyLongToPtr(handle_obj) orelse return pyReturnNone();
    const src = src_ptr[0..@intCast(src_len)];
    const save = py.PyEval_SaveThread();
    const out = brotli_mod.streamCompress(handle, src, std.heap.c_allocator, finish != 0);
    py.PyEval_RestoreThread(save);
    if (out == null) return pyReturnNone();
    defer std.heap.c_allocator.free(out.?);
    return py.PyBytes_FromStringAndSize(@ptrCast(out.?.ptr), @intCast(out.?.len));
}

fn saltareBrotliStreamDestroy(_: ?*py.PyObject, args: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    var handle_obj: ?*py.PyObject = null;
    if (py.PyArg_ParseTuple(args, "O", &handle_obj) == 0) return null;
    const handle = pyLongToPtr(handle_obj);
    if (handle) |h| brotli_mod.streamDestroy(h);
    return pyReturnNone();
}

fn saltareZstdStreamCreate(_: ?*py.PyObject, args: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    var level: c_int = zstd_mod.DEFAULT_LEVEL;
    if (py.PyArg_ParseTuple(args, "|i", &level) == 0) return null;
    const handle = zstd_mod.streamCreate(level);
    if (handle == null) return pyReturnNone();
    return ptrToPyLong(handle);
}

fn saltareZstdStreamCompress(_: ?*py.PyObject, args: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    var handle_obj: ?*py.PyObject = null;
    var src_ptr: [*c]const u8 = null;
    var src_len: py.Py_ssize_t = 0;
    var finish: c_int = 0;
    if (py.PyArg_ParseTuple(args, "Oy#p", &handle_obj, &src_ptr, &src_len, &finish) == 0) return null;
    const handle = pyLongToPtr(handle_obj) orelse return pyReturnNone();
    const src = src_ptr[0..@intCast(src_len)];
    const save = py.PyEval_SaveThread();
    const out = zstd_mod.streamCompress(handle, src, std.heap.c_allocator, finish != 0);
    py.PyEval_RestoreThread(save);
    if (out == null) return pyReturnNone();
    defer std.heap.c_allocator.free(out.?);
    return py.PyBytes_FromStringAndSize(@ptrCast(out.?.ptr), @intCast(out.?.len));
}

fn saltareZstdStreamDestroy(_: ?*py.PyObject, args: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    var handle_obj: ?*py.PyObject = null;
    if (py.PyArg_ParseTuple(args, "O", &handle_obj) == 0) return null;
    const handle = pyLongToPtr(handle_obj);
    if (handle) |h| zstd_mod.streamDestroy(h);
    return pyReturnNone();
}

/// gunzip(payload: bytes, max_size: int) -> bytes | None.
/// Decompresses a gzip-wrapped (RFC 1952) payload. `max_size` caps the
/// output (zip-bomb defense — return None on overflow). Returns None when
/// libz can't be loaded or the payload is malformed. Used by the Python
/// dispatcher to decompress request bodies with `Content-Encoding: gzip`.
fn saltareGunzip(_: ?*py.PyObject, args: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    var src_ptr: [*c]const u8 = null;
    var src_len: py.Py_ssize_t = 0;
    var max_size: c_ulonglong = 0;
    if (py.PyArg_ParseTuple(args, "y#K", &src_ptr, &src_len, &max_size) == 0) return null;
    const src = src_ptr[0..@intCast(src_len)];
    const save = py.PyEval_SaveThread();
    const out = zlib_mod.gunzip(src, std.heap.c_allocator, @intCast(max_size));
    py.PyEval_RestoreThread(save);
    if (out == null) return pyReturnNone();
    defer std.heap.c_allocator.free(out.?);
    return py.PyBytes_FromStringAndSize(@ptrCast(out.?.ptr), @intCast(out.?.len));
}

/// compression_metric_inc(encoding: str, bytes_in: int, bytes_out: int).
/// Called by the Python dispatcher after each successful response encode.
fn saltareCompressionMetricInc(_: ?*py.PyObject, args: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    var enc_z: [*c]const u8 = null;
    var bytes_in: c_ulonglong = 0;
    var bytes_out: c_ulonglong = 0;
    if (py.PyArg_ParseTuple(args, "sKK", &enc_z, &bytes_in, &bytes_out) == 0) return null;
    server.compressionMetricInc(std.mem.span(enc_z), @intCast(bytes_in), @intCast(bytes_out));
    return pyReturnNone();
}

/// compression_metric_skip(reason: str). Called by the Python
/// dispatcher when a candidate response was passed through identity.
fn saltareCompressionMetricSkip(_: ?*py.PyObject, args: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    var reason_z: [*c]const u8 = null;
    if (py.PyArg_ParseTuple(args, "s", &reason_z) == 0) return null;
    server.compressionMetricSkip(std.mem.span(reason_z));
    return pyReturnNone();
}

/// request_shutdown() -> None. Equivalent to a SIGTERM: flips the
/// global drain flag so the I/O loop stops accepting, finishes
/// in-flight requests, and lets `serve()` return. Used by the pytest
/// conftest fixture to tear down test-spawned servers between tests.
fn saltareRequestShutdown(_: ?*py.PyObject, _: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    server.requestShutdown();
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
    .{
        .ml_name = "gzip_encode",
        .ml_meth = @ptrCast(&saltareGzipEncode),
        .ml_flags = py.METH_VARARGS,
        .ml_doc = "gzip_encode(payload: bytes, level: int = 6) -> bytes | None. None when libz can't load.",
    },
    .{
        .ml_name = "gunzip",
        .ml_meth = @ptrCast(&saltareGunzip),
        .ml_flags = py.METH_VARARGS,
        .ml_doc = "gunzip(payload: bytes, max_size: int) -> bytes | None. None on libz miss / overflow.",
    },
    .{
        .ml_name = "brotli_encode",
        .ml_meth = @ptrCast(&saltareBrotliEncode),
        .ml_flags = py.METH_VARARGS,
        .ml_doc = "brotli_encode(payload: bytes, quality: int = 4) -> bytes | None. None when libbrotli is absent.",
    },
    .{
        .ml_name = "brotli_decode",
        .ml_meth = @ptrCast(&saltareBrotliDecode),
        .ml_flags = py.METH_VARARGS,
        .ml_doc = "brotli_decode(payload: bytes, max_size: int) -> bytes | None.",
    },
    .{
        .ml_name = "zstd_encode",
        .ml_meth = @ptrCast(&saltareZstdEncode),
        .ml_flags = py.METH_VARARGS,
        .ml_doc = "zstd_encode(payload: bytes, level: int = 3) -> bytes | None. None when libzstd is absent.",
    },
    .{
        .ml_name = "zstd_decode",
        .ml_meth = @ptrCast(&saltareZstdDecode),
        .ml_flags = py.METH_VARARGS,
        .ml_doc = "zstd_decode(payload: bytes, max_size: int) -> bytes | None.",
    },
    .{
        .ml_name = "brotli_stream_create",
        .ml_meth = @ptrCast(&saltareBrotliStreamCreate),
        .ml_flags = py.METH_VARARGS,
        .ml_doc = "brotli_stream_create(quality: int = 4) -> int | None. Streaming encoder handle.",
    },
    .{
        .ml_name = "brotli_stream_compress",
        .ml_meth = @ptrCast(&saltareBrotliStreamCompress),
        .ml_flags = py.METH_VARARGS,
        .ml_doc = "brotli_stream_compress(handle: int, chunk: bytes, finish: bool) -> bytes | None.",
    },
    .{
        .ml_name = "brotli_stream_destroy",
        .ml_meth = @ptrCast(&saltareBrotliStreamDestroy),
        .ml_flags = py.METH_VARARGS,
        .ml_doc = "brotli_stream_destroy(handle: int) -> None. Frees the encoder.",
    },
    .{
        .ml_name = "zstd_stream_create",
        .ml_meth = @ptrCast(&saltareZstdStreamCreate),
        .ml_flags = py.METH_VARARGS,
        .ml_doc = "zstd_stream_create(level: int = 3) -> int | None. Streaming CCtx handle.",
    },
    .{
        .ml_name = "zstd_stream_compress",
        .ml_meth = @ptrCast(&saltareZstdStreamCompress),
        .ml_flags = py.METH_VARARGS,
        .ml_doc = "zstd_stream_compress(handle: int, chunk: bytes, finish: bool) -> bytes | None.",
    },
    .{
        .ml_name = "zstd_stream_destroy",
        .ml_meth = @ptrCast(&saltareZstdStreamDestroy),
        .ml_flags = py.METH_VARARGS,
        .ml_doc = "zstd_stream_destroy(handle: int) -> None. Frees the CCtx.",
    },
    .{
        .ml_name = "compression_metric_inc",
        .ml_meth = @ptrCast(&saltareCompressionMetricInc),
        .ml_flags = py.METH_VARARGS,
        .ml_doc = "compression_metric_inc(encoding: str, bytes_in: int, bytes_out: int) -> None.",
    },
    .{
        .ml_name = "compression_metric_skip",
        .ml_meth = @ptrCast(&saltareCompressionMetricSkip),
        .ml_flags = py.METH_VARARGS,
        .ml_doc = "compression_metric_skip(reason: str) -> None.",
    },
    .{
        .ml_name = "request_shutdown",
        .ml_meth = @ptrCast(&saltareRequestShutdown),
        .ml_flags = py.METH_NOARGS,
        .ml_doc = "request_shutdown() -> None. Trigger graceful shutdown (test cleanup helper).",
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
