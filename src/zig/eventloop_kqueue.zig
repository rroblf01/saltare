// kqueue backend for the non-blocking server (macOS / Darwin).
//
// v1.12. Mirrors eventloop_epoll.zig's API exactly — same `Event` shape,
// same `Loop` methods, same `max_events_per_wait` — so eventloop.zig can
// select a backend at comptime and server.zig stays untouched. That is
// the whole point of the split: the hot path gets no branch on the OS and
// the struct layout is identical on both platforms.
//
// Level-triggered like epoll, which is what the connection state machine
// was written against — server.zig explicitly avoids a level-triggered
// EPOLLOUT spin by only arming write interest when a write actually
// blocks, and kqueue needs the same discipline rather than any
// edge-triggered EV_CLEAR.
//
// Differences worth knowing, all handled here rather than leaking up:
//
//   - Interest is per-filter, not a bitmask. epoll's EPOLL_CTL_MOD
//     replaces the whole mask in one call; kqueue has no "set mask", so
//     dropping an interest means an explicit EV_DELETE. Hence
//     `setInterest` below issues a delete-then-add pair.
//
//   - Hangs up differently. epoll reports EPOLLRDHUP/EPOLLHUP/EPOLLERR as
//     bits. kqueue reports EV_EOF as a per-filter flag, and a failed
//     kevent() surfaces as EV_ERROR with the errno in `data`.
//
//   - Timeouts are a `struct timespec` (or NULL for infinite), not an int
//     count of milliseconds. `wait` translates.

const std = @import("std");
const builtin = @import("builtin");

const c = @cImport({
    @cInclude("sys/event.h");
    @cInclude("sys/time.h");
    @cInclude("sys/types.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
});

pub const Event = struct {
    /// User pointer registered when this fd was added (or null for the listener).
    data: ?*anyopaque,
    readable: bool,
    writable: bool,
    /// Hangup or error — caller should close and free.
    closed: bool,
};

// Same budget as the epoll backend, and for the same reason: the arrays
// are stack-resident per `serveLoop` frame, so a larger one costs KiB of
// steady-state stack for no throughput gain. Saturating the array just
// means kevent returns sooner and the next iteration drains the rest.
pub const max_events_per_wait = 64;

pub const Loop = struct {
    kq: c_int,
    out_events: [max_events_per_wait]Event = undefined,
    // v1.11 PEP 684 groundwork: opaque pointer to the owning serve()'s
    // per-interpreter `Runtime` (server.zig). Held as `?*anyopaque` to avoid
    // a circular import on the Connection type. Set once right after init.
    runtime: ?*anyopaque = null,

    pub fn init() !Loop {
        // EV_CLOEXEC is the kqueue analogue of epoll_create1(EPOLL_CLOEXEC):
        // without it a forked/exec'd child would inherit the descriptor.
        const fd = c.kqueue();
        if (fd < 0) return error.KqueueCreateFailed;
        _ = c.fcntl(fd, c.F_SETFD, c.FD_CLOEXEC);
        return Loop{ .kq = fd };
    }

    pub fn deinit(self: *Loop) void {
        _ = c.close(self.kq);
    }

    /// Apply a change list without waiting for events.
    ///
    /// kevent(2) takes explicit counts rather than slice lengths, and a
    /// null `eventlist` with `nevents == 0` means "apply these changes and
    /// return". A null timeout is likewise non-blocking, which is what the
    /// change paths want.
    fn keventApply(self: *Loop, changes: []const c.struct_kevent) void {
        if (changes.len == 0) return;
        _ = c.kevent(
            self.kq,
            changes.ptr,
            @intCast(changes.len),
            null,
            0,
            null,
        );
    }

    /// Set the interest set for `fd` to exactly {read?, write?}.
    ///
    /// kqueue has no EPOLL_CTL_MOD equivalent, so each filter is deleted
    /// before being (re-)added. The delete of an unregistered filter fails
    /// with ENOENT, which is the normal case on the first `add` and is
    /// deliberately ignored. EV_RECEIPT would let us detect per-filter
    /// errors, but the only failure we care about is the connection going
    /// away underneath us, which shows up as EBADF/ENOENT too and is
    /// handled by the caller's `remove`.
    fn setInterest(
        self: *Loop,
        fd: c_int,
        data: ?*anyopaque,
        want_read: bool,
        want_write: bool,
    ) !void {
        var changes: [2]c.struct_kevent = undefined;
        var n: usize = 0;

        if (want_read) {
            changes[n] = .{
                .ident = @intCast(fd),
                .filter = c.EVFILT_READ,
                .flags = c.EV_ADD | c.EV_ENABLE,
                .fflags = 0,
                .data = 0,
                .udata = data,
            };
            n += 1;
        } else {
            changes[n] = .{
                .ident = @intCast(fd),
                .filter = c.EVFILT_READ,
                .flags = c.EV_DELETE,
                .fflags = 0,
                .data = 0,
                .udata = null,
            };
            n += 1;
        }

        if (want_write) {
            changes[n] = .{
                .ident = @intCast(fd),
                .filter = c.EVFILT_WRITE,
                .flags = c.EV_ADD | c.EV_ENABLE,
                .fflags = 0,
                .data = 0,
                .udata = data,
            };
            n += 1;
        } else {
            changes[n] = .{
                .ident = @intCast(fd),
                .filter = c.EVFILT_WRITE,
                .flags = c.EV_DELETE,
                .fflags = 0,
                .data = 0,
                .udata = null,
            };
            n += 1;
        }

        // Per-filter errors are not actionable here: the only failures
        // are EBADF/ENOENT, i.e. the connection went away underneath us,
        // which the caller's `remove` already tolerates.
        self.keventApply(changes[0..n]);
    }

    pub fn add(self: *Loop, fd: c_int, data: ?*anyopaque, want_read: bool, want_write: bool) !void {
        try self.setInterest(fd, data, want_read, want_write);
    }

    pub fn modify(self: *Loop, fd: c_int, data: ?*anyopaque, want_read: bool, want_write: bool) !void {
        try self.setInterest(fd, data, want_read, want_write);
    }

    pub fn remove(self: *Loop, fd: c_int) void {
        // Best-effort, matching the epoll backend: the fd is often already
        // gone, and ENOENT is the expected answer.
        var changes: [2]c.struct_kevent = .{
            .{
                .ident = @intCast(fd),
                .filter = c.EVFILT_READ,
                .flags = c.EV_DELETE,
                .fflags = 0,
                .data = 0,
                .udata = null,
            },
            .{
                .ident = @intCast(fd),
                .filter = c.EVFILT_WRITE,
                .flags = c.EV_DELETE,
                .fflags = 0,
                .data = 0,
                .udata = null,
            },
        };
        self.keventApply(&changes);
    }

    pub fn wait(self: *Loop, timeout_ms: c_int) []const Event {
        // kevent takes a timespec, not milliseconds. A negative timeout
        // means "block forever" in the epoll API; here that is a null
        // pointer.
        var ts: c.struct_timespec = undefined;
        var tsp: ?*const c.struct_timespec = null;
        if (timeout_ms >= 0) {
            ts = .{
                .tv_sec = @intCast(@divFloor(timeout_ms, 1000)),
                .tv_nsec = @intCast(@mod(timeout_ms, 1000) * std.time.ns_per_ms),
            };
            tsp = &ts;
        }

        var raw: [max_events_per_wait]c.struct_kevent = undefined;
        const n = c.kevent(
            self.kq,
            null, // no changes to apply
            0,
            &raw,
            max_events_per_wait,
            tsp,
        );
        if (n <= 0) return self.out_events[0..0]; // EINTR or timeout

        const count: usize = @intCast(n);
        var out: usize = 0;
        for (raw[0..count]) |ev| {
            const is_read = ev.filter == c.EVFILT_READ;
            const is_write = ev.filter == c.EVFILT_WRITE;
            if (!is_read and !is_write) continue; // not ours

            // EV_ERROR means the *changelist* entry failed. With a null
            // changelist this only happens if the kqueue fd itself is
            // broken, in which case `ev.data` carries the errno. Treat it
            // as a hangup so the caller tears the connection down instead
            // of spinning on a dead loop.
            const errored = (ev.flags & c.EV_ERROR) != 0;
            // EV_EOF is kqueue's EPOLLRDHUP equivalent: the peer closed
            // its half. On a write filter it means the socket is gone.
            const eof = (ev.flags & c.EV_EOF) != 0;

            self.out_events[out] = .{
                .data = ev.udata,
                .readable = is_read,
                .writable = is_write,
                .closed = errored or eof,
            };
            out += 1;
        }
        return self.out_events[0..out];
    }
};
