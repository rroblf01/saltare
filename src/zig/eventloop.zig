// Minimal epoll wrapper for the v0.4 non-blocking server.
//
// Only Linux is supported in this milestone. macOS (kqueue) lands in a
// follow-up; cibuildwheel jobs for macOS will fail at compile time until
// then, which is a deliberate, visible TODO rather than silent breakage.

const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (builtin.os.tag != .linux) {
        @compileError(
            "saltare's v0.4 event loop currently supports Linux only. " ++
                "macOS (kqueue) is on the roadmap; until then, build inside " ++
                "the Docker pipeline.",
        );
    }
}

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

const max_events_per_wait = 128;

pub const Loop = struct {
    epfd: c_int,
    raw_events: [max_events_per_wait]c.struct_epoll_event = undefined,
    out_events: [max_events_per_wait]Event = undefined,

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
