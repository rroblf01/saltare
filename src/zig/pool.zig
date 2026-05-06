// Adaptive read-buffer + headers-storage pool (v0.16).
//
// Per-connection buffer history:
//   - v0.5: 16 KiB inline `[16384]u8` per Connection, lifetime-bound.
//   - v0.6: pulled into a single free-list pool — released on idle keep-
//           alive so RSS scales with in-flight, not open, connections.
//   - v0.12.1: bundled the parsed-`Header` array into the same node so
//              both release atomically (idle cost dropped to ~390 B/conn).
//   - v0.16: split the data block into two sizes (4 KiB primary, 16 KiB
//            overflow) with separate free lists, and hint long-idle
//            blocks to the kernel via `MADV_DONTNEED` so RSS recovers
//            after traffic peaks.
//
// Most HTTP requests fit comfortably in 4 KiB of headers + small body.
// Connections start with a small buffer; if a partial parse fills it, the
// caller upgrades to the large size (copying the in-flight bytes across).
// Per-active-request RAM drops from 16 KiB → 4 KiB for the typical case.
//
// Caller contract: `headers` and `data` are valid as long as the buffer is
// held; `Connection.parsed` references both, so `parsed = null` before the
// matching `release()`.

const std = @import("std");
const builtin = @import("builtin");
const http = @import("http.zig");

const c = @cImport({
    @cInclude("sys/mman.h");
});

/// Bytes available for socket reads in the small (default) buffer.
pub const SMALL_DATA_SIZE: usize = 4 * 1024;
/// Bytes available for socket reads in the overflow buffer. Same value as
/// the historical (v0.5–v0.12) fixed buffer — request capacity unchanged.
pub const LARGE_DATA_SIZE: usize = 16 * 1024;

/// Buffers idle in the free list past this many nanoseconds get hinted to
/// the kernel via `MADV_DONTNEED`. Re-using costs a soft fault
/// (microseconds); in exchange RSS drops back toward the floor after a
/// traffic peak ends. 30 s strikes a balance: short-lived dips are
/// tolerated without the soft-fault tax, longer idle periods give the OS
/// pages back. Linux only — macOS skips the call.
pub const IDLE_ADVISE_NS: i64 = 30 * std.time.ns_per_s;

/// A pool node. `data` is a slice (not an inline array) so the same
/// `Buffer` type can hold either a 4 KiB or a 16 KiB block.
pub const Buffer = struct {
    next: ?*Buffer,
    headers: [http.max_headers]http.Header,
    data: []u8,
    /// CLOCK_MONOTONIC ns when this buffer entered the free list. 0 while
    /// the buffer is in use.
    released_at_ns: i64,
    /// True if `MADV_DONTNEED` has been called for `data` since release.
    /// Cleared on the next acquire so the next idle period can re-advise.
    advised: bool,
};

pub const Pool = struct {
    /// Free list of buffers with `data.len == SMALL_DATA_SIZE`.
    small_free: ?*Buffer,
    /// Free list of buffers with `data.len == LARGE_DATA_SIZE`.
    large_free: ?*Buffer,
    /// Used to allocate / free `Buffer` structs (small fixed-size).
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Pool {
        return .{
            .small_free = null,
            .large_free = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Pool) void {
        freeList(self.small_free, self.allocator);
        freeList(self.large_free, self.allocator);
        self.small_free = null;
        self.large_free = null;
    }

    fn freeList(head: ?*Buffer, struct_alloc: std.mem.Allocator) void {
        var current = head;
        while (current) |b| {
            const next = b.next;
            std.heap.page_allocator.free(b.data);
            struct_alloc.destroy(b);
            current = next;
        }
    }

    /// Acquire a small (4 KiB) buffer. Most connections start here.
    pub fn acquire(self: *Pool) !*Buffer {
        return self.acquireSize(SMALL_DATA_SIZE, &self.small_free);
    }

    /// Acquire a large (16 KiB) buffer. Used either as the initial buffer
    /// for connections expected to handle big payloads, or as the upgrade
    /// target when a small buffer fills before parsing succeeds.
    pub fn acquireLarge(self: *Pool) !*Buffer {
        return self.acquireSize(LARGE_DATA_SIZE, &self.large_free);
    }

    fn acquireSize(self: *Pool, size: usize, list: *?*Buffer) !*Buffer {
        if (list.*) |b| {
            list.* = b.next;
            b.next = null;
            b.released_at_ns = 0;
            b.advised = false;
            return b;
        }
        const buf = try self.allocator.create(Buffer);
        // Page allocator → mmap → page-aligned. Required for MADV_DONTNEED
        // to actually release the underlying physical pages.
        buf.data = std.heap.page_allocator.alloc(u8, size) catch |err| {
            self.allocator.destroy(buf);
            return err;
        };
        buf.next = null;
        buf.released_at_ns = 0;
        buf.advised = false;
        return buf;
    }

    /// Return a buffer to the free list. `now_ns` is the moment the
    /// connection went idle, used by `sweepIdle` to decide when to advise.
    /// If the caller doesn't track time, passing 0 keeps the buffer
    /// resident indefinitely.
    pub fn release(self: *Pool, buf: *Buffer, now_ns: i64) void {
        buf.released_at_ns = now_ns;
        if (buf.data.len == LARGE_DATA_SIZE) {
            buf.next = self.large_free;
            self.large_free = buf;
        } else {
            buf.next = self.small_free;
            self.small_free = buf;
        }
    }

    /// Walk the free lists and call `madvise(MADV_DONTNEED)` on every
    /// buffer that has been idle longer than `IDLE_ADVISE_NS`. The page-
    /// aligned data block is released to the kernel; subsequent re-use
    /// costs a soft fault per page touched (microseconds). No-op outside
    /// Linux.
    pub fn sweepIdle(self: *Pool, now_ns: i64) void {
        if (comptime builtin.os.tag != .linux) return;
        adviseList(self.small_free, now_ns);
        adviseList(self.large_free, now_ns);
    }

    fn adviseList(head: ?*Buffer, now_ns: i64) void {
        var node = head;
        while (node) |b| {
            if (!b.advised and b.released_at_ns != 0 and (now_ns - b.released_at_ns) > IDLE_ADVISE_NS) {
                _ = c.madvise(b.data.ptr, b.data.len, c.MADV_DONTNEED);
                b.advised = true;
            }
            node = b.next;
        }
    }
};
