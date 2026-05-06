// Read-buffer + headers-storage pool.
//
// Each accepted connection used to hold a permanent 16 KiB read buffer for
// its lifetime. With keep-alive (v0.5), idle connections sat with their
// buffers reserved for seconds or minutes, so RSS scaled with *open
// connections*, not with *in-flight requests*. The pool was introduced in
// v0.6 to release the read buffer back to a free list as soon as a
// connection went idle.
//
// v0.12.1 extends this to the headers slice array. Previously
// `Connection.headers_storage: [64]Header` (~2 KiB inline) lived for the
// connection's entire lifetime, even when idle — only the read buffer was
// pooled. Now the headers array is bundled into the same `Buffer` and
// released atomically with the read data, dropping idle-connection cost
// from ~2 KiB to ~250 B.
//
// Caller contract: the `headers` slice is valid as long as the buffer is
// held (i.e. until the next `release`). `Connection.parsed` references
// must be cleared before releasing.

const std = @import("std");
const http = @import("http.zig");

/// Number of bytes available for raw socket reads. Same as the historical
/// total buffer size — keeping it at 16 KiB preserves request capacity;
/// the headers array now lives next to it, increasing the per-active-buffer
/// allocation by ~2 KiB (net-zero vs the v0.6–v0.12 layout, where the
/// headers were in the Connection struct anyway).
pub const READ_DATA_SIZE: usize = 16 * 1024;

/// A pool node. Callers receive `*Buffer` and read/write via the `data`
/// field, parse into the `headers` field; the `next` field is for the
/// pool's intrusive free-list and is ignored while the buffer is in use.
pub const Buffer = struct {
    next: ?*Buffer,
    headers: [http.max_headers]http.Header,
    data: [READ_DATA_SIZE]u8,
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
