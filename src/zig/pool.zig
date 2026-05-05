// Read-buffer pool.
//
// Each accepted connection used to hold a permanent 16 KiB read buffer for
// its lifetime. With keep-alive (v0.5), idle connections sat with their
// buffers reserved for seconds or minutes, so RSS scaled with *open
// connections*, not with *in-flight requests*.
//
// This pool decouples the two: callers acquire a buffer when they actually
// need to read, and release it back when the connection becomes truly idle
// (between keep-alive requests). Buffers are recycled via an intrusive
// free-list — no allocation per acquire after warmup.

const std = @import("std");

/// Per-connection read buffer size. Same value the v0.5 server hard-coded
/// inline; centralised here so the pool and Connection structs stay aligned.
pub const BUFFER_SIZE: usize = 16 * 1024;

/// A pool node. Callers receive `*Buffer` and read/write via the `data`
/// field; the `next` field is for the pool's intrusive free-list and is
/// ignored while the buffer is in use.
pub const Buffer = struct {
    next: ?*Buffer,
    data: [BUFFER_SIZE]u8,
};

pub const Pool = struct {
    free_list: ?*Buffer,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Pool {
        return .{ .free_list = null, .allocator = allocator };
    }

    /// Frees every buffer still in the free list. Buffers in use by live
    /// connections are not tracked here — they're released by Connection
    /// destructors and walk back through `release`.
    pub fn deinit(self: *Pool) void {
        var current = self.free_list;
        while (current) |b| {
            const next = b.next;
            self.allocator.destroy(b);
            current = next;
        }
        self.free_list = null;
    }

    pub fn acquire(self: *Pool) !*Buffer {
        if (self.free_list) |b| {
            self.free_list = b.next;
            return b;
        }
        const new_buf = try self.allocator.create(Buffer);
        new_buf.next = null;
        return new_buf;
    }

    pub fn release(self: *Pool, buf: *Buffer) void {
        buf.next = self.free_list;
        self.free_list = buf;
    }
};
