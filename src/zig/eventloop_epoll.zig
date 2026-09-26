// epoll backend for the non-blocking server.
//
// Split out of eventloop.zig in v1.12 so the Linux and macOS backends
// could live side by side. eventloop.zig picks one at comptime and
// re-exports it, which is why this file's `Loop` is the *only* `Loop`
// server.zig ever sees — it never learns which platform it is on, and
// the layout and the call sites are byte-identical across both.
//
// Original note kept: the v0.4 event loop ran epoll only, with macOS
// (kqueue) deferred. kqueue now lives in eventloop_kqueue.zig.

const std = @import("std");
const builtin = @import("builtin");

const c = @cImport({
    @cInclude("sys/epoll.h");
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

// 64 keeps the per-wait stack footprint low (~1 KiB raw + 1 KiB cooked).
// Saturating it just means epoll_wait returns sooner — the next iteration
// drains the rest. Picked over 128 after the v1.2.2 audit found the larger
// array spent most iterations less than half full while still costing
// ~10 KiB stack per loop step.
pub const max_events_per_wait = 64;

pub const Loop = struct {
    epfd: c_int,
    raw_events: [max_events_per_wait]c.struct_epoll_event = undefined,
    out_events: [max_events_per_wait]Event = undefined,
    // v1.11 PEP 684 groundwork: opaque pointer to the owning serve()'s
    // per-interpreter `Runtime` (server.zig). Held as `?*anyopaque` to avoid
    // a circular import on the Connection type. Set once right after init.
    runtime: ?*anyopaque = null,

    pub fn init() !Loop {
        const fd = c.epoll_create1(c.EPOLL_CLOEXEC);
        if (fd < 0) return error.EpollCreateFailed;
        return Loop{ .epfd = fd };
    }

    pub fn deinit(self: *Loop) void {
        _ = c.close(self.epfd);
    }

    pub fn add(self: *Loop, fd: c_int, data: ?*anyopaque, want_read: bool, want_write: bool) !void {
        var ev: c.struct_epoll_event = std.mem.zeroes(c.struct_epoll_event);
        if (want_read) ev.events |= c.EPOLLIN;
        if (want_write) ev.events |= c.EPOLLOUT;
        ev.events |= c.EPOLLRDHUP;
        ev.data.ptr = data;
        if (c.epoll_ctl(self.epfd, c.EPOLL_CTL_ADD, fd, &ev) != 0) {
            return error.EpollCtlFailed;
        }
    }

    pub fn modify(self: *Loop, fd: c_int, data: ?*anyopaque, want_read: bool, want_write: bool) !void {
        var ev: c.struct_epoll_event = std.mem.zeroes(c.struct_epoll_event);
        if (want_read) ev.events |= c.EPOLLIN;
        if (want_write) ev.events |= c.EPOLLOUT;
        ev.events |= c.EPOLLRDHUP;
        ev.data.ptr = data;
        if (c.epoll_ctl(self.epfd, c.EPOLL_CTL_MOD, fd, &ev) != 0) {
            return error.EpollCtlFailed;
        }
    }

    pub fn remove(self: *Loop, fd: c_int) void {
        // Best-effort: errors on remove are typically benign (already gone).
        _ = c.epoll_ctl(self.epfd, c.EPOLL_CTL_DEL, fd, null);
    }

    pub fn wait(self: *Loop, timeout_ms: c_int) []const Event {
        const n = c.epoll_wait(self.epfd, &self.raw_events, max_events_per_wait, timeout_ms);
        if (n <= 0) return self.out_events[0..0]; // EINTR or timeout

        const count: usize = @intCast(n);
        for (self.raw_events[0..count], 0..) |raw, i| {
            self.out_events[i] = .{
                .data = raw.data.ptr,
                .readable = (raw.events & c.EPOLLIN) != 0,
                .writable = (raw.events & c.EPOLLOUT) != 0,
                .closed = (raw.events & (c.EPOLLRDHUP | c.EPOLLHUP | c.EPOLLERR)) != 0,
            };
        }
        return self.out_events[0..count];
    }
};
