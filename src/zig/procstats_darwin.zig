// Process-level stats for macOS.
//
// v1.12. The Linux versions of these read /proc, which does not exist on
// Darwin, so `process_resident_memory_bytes`, `process_open_fds` and
// `process_cpu_seconds_total` all reported a hard 0 there — three
// permanently-zero series in /metrics, on a server whose selling point
// includes the observability. The Darwin answers are:
//
//   RSS        proc_pidinfo(PROC_PIDTASKINFO).pti_resident_size
//   open fds   proc_pidinfo(PROC_PIDLISTFDS), counting entries
//   cpu time   getrusage(RUSAGE_SELF) → ru_utime + ru_stime
//
// All three avoid <libproc.h>, which is not an accident. libproc is the
// natural home for proc_pidinfo, but it transitively includes the Mach
// headers, and Zig's translate-c cannot digest those: they carry static
// assertions on the size of descriptor types it models as `opaque`, and
// the build dies inside cimport.zig before any of our code runs.
// sys/proc_info.h declares every struct and flavor constant needed here on
// its own, so the one function we need is declared by hand — it lives in
// libSystem, so it resolves at link time with nothing extra to ship.
//
// getrusage is preferred over any task_info equivalent for CPU time
// because it needs only sys/resource.h — already included by server.zig —
// and returns a single value in one call. Its scope is process-wide rather
// than thread-wide, which is the same scope the Linux /proc/self/stat read
// has.
//
// Kept in its own file because sys/proc_info.h must not enter server.zig's
// cimport: it does not exist on Linux, and a top-level @cImport is what
// makes a build fail before any of our own code runs. server.zig reaches
// this module only from inside a comptime OS check, so on Linux nothing
// here is ever analyzed.

const std = @import("std");
const builtin = @import("builtin");

const c = @cImport({
    @cInclude("sys/proc_info.h");
    @cInclude("sys/resource.h");
    @cInclude("sys/types.h");
    @cInclude("unistd.h");
});

/// From <libproc.h>, which we cannot include (see the note above).
extern fn proc_pidinfo(
    pid: c_int,
    flavor: c_int,
    arg: u64,
    buffer: ?*anyopaque,
    buffersize: c_int,
) c_int;

/// Resident set size in bytes. Best-effort: 0 on any failure, matching
/// the Linux parser's contract of never breaking the /metrics render.
pub fn rssBytes() u64 {
    var info: c.struct_proc_taskinfo = undefined;
    const bytes = proc_pidinfo(
        c.getpid(),
        c.PROC_PIDTASKINFO,
        0,
        @ptrCast(&info),
        @sizeOf(c.struct_proc_taskinfo),
    );
    if (bytes < @sizeOf(c.struct_proc_taskinfo)) return 0;
    return @intCast(info.pti_resident_size);
}

/// Number of open file descriptors.
///
/// proc_pidinfo with PROC_PIDLISTFDS returns the descriptors in
/// caller-provided chunks; asking for a large enough buffer in one call is
/// the cheap path, and if the process outgrows it we report the lower
/// bound rather than looping. A few thousand descriptors is far past the
/// default RLIMIT_NOFILE, so the truncation case means an operator has
/// explicitly raised the limit and would rather see an undercount than a
/// per-scrape allocation storm.
pub fn openFds() u64 {
    // Enough for a generous RLIMIT_NOFILE. Each entry is a
    // `struct proc_fdinfo`, 64 bytes on arm64.
    const max_entries = 4096;
    var buf: [max_entries * 64]u8 align(@alignOf(c.struct_proc_fdinfo)) = undefined;

    const bytes = proc_pidinfo(
        c.getpid(),
        c.PROC_PIDLISTFDS,
        0,
        @ptrCast(&buf),
        @intCast(buf.len),
    );
    if (bytes <= 0) return 0;
    const used: usize = @intCast(bytes);
    const entry_size = @sizeOf(c.proc_fdinfo);
    return used / entry_size;
}

/// CPU seconds consumed (user + kernel) since process start.
pub fn cpuSeconds() f64 {
    var usage: c.struct_rusage = undefined;
    if (c.getrusage(c.RUSAGE_SELF, &usage) != 0) return 0.0;
    const user = @as(f64, @floatFromInt(usage.ru_utime.tv_sec)) +
        @as(f64, @floatFromInt(usage.ru_utime.tv_usec)) / 1_000_000.0;
    const sys = @as(f64, @floatFromInt(usage.ru_stime.tv_sec)) +
        @as(f64, @floatFromInt(usage.ru_stime.tv_usec)) / 1_000_000.0;
    return user + sys;
}
