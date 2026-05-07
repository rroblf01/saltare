// Hashed timer wheel for per-connection idle/state deadlines.
//
// Used by server.zig to enforce header / keep-alive / body / write timeouts
// without paying per-connection epoll timer fds (those would 2x our fd
// budget) or a per-connection min-heap entry (allocates).
//
// Each connection embeds a `Node` directly in its struct. Arming is O(1)
// (push to bucket head); cancelling is O(1) (intrusive doubly-linked list
// unlink); ticking is O(K) where K is the number of expirations in the
// current bucket.
//
// Granularity is 1 second. Maximum direct timeout is BUCKETS-1 seconds; we
// clamp longer values silently. With BUCKETS=128 that's ~2 minutes, which
// covers all current configurable timeouts.

const std = @import("std");

// musl's `time.h` forward-declares `struct timespec` and puts the
// definition behind feature gates Zig's translate-c misses. Same
// fix as in server.zig — manual extern declaration that works on
// both libcs (x86_64 timespec is `c_long, c_long`).
const Timespec = extern struct {
    tv_sec: c_long,
    tv_nsec: c_long,
};
extern fn clock_gettime(clk_id: c_int, tp: *Timespec) c_int;
const CLOCK_MONOTONIC: c_int = 1;

/// Monotonic seconds since some unspecified epoch. We don't use std.time
/// here because Zig 0.16's std.time was trimmed down significantly (see
/// the project's Zig 0.16 quirks notes); libc clock_gettime is the
/// stable, portable path.
fn monoSec() i64 {
    var ts: Timespec = undefined;
    _ = clock_gettime(CLOCK_MONOTONIC, &ts);
    return @intCast(ts.tv_sec);
}

/// Buckets in the wheel. Each represents a 1-second slot. Memory cost of
/// the wheel itself is BUCKETS * sizeof(?*Node) ≈ 1 KiB at 128 buckets.
pub const BUCKETS: usize = 128;

/// One slot in the intrusive doubly-linked free-list for a bucket. Embed
/// inside the owning struct (e.g. Connection).
pub const Node = struct {
    next: ?*Node,
    prev: ?*Node,
    bucket: u8,
    armed: bool,

    pub fn reset(self: *Node) void {
        self.* = .{ .next = null, .prev = null, .bucket = 0, .armed = false };
    }
};

pub const Wheel = struct {
    buckets: [BUCKETS]?*Node,
    /// Index of the bucket representing "now". Advances by 1 per tick.
    cursor: usize,
    /// Monotonic seconds when the wheel was created. We measure elapsed
    /// time as `monoSec() - start_sec`; CLOCK_MONOTONIC isn't affected by
    /// NTP, so this is jump-free.
    start_sec: i64,
    /// Seconds since the wheel started; matches how many times the cursor
    /// has advanced. Stored explicitly so `tick()` can catch up after a
    /// long event-loop iteration.
    elapsed_secs: u64,

    pub fn init() !Wheel {
        var w = Wheel{
            .buckets = undefined,
            .cursor = 0,
            .start_sec = monoSec(),
            .elapsed_secs = 0,
        };
        for (&w.buckets) |*b| b.* = null;
        return w;
    }

    /// Monotonic seconds since `init`.
    pub fn nowSec(self: *const Wheel) u64 {
        const now = monoSec();
        if (now <= self.start_sec) return 0;
        return @intCast(now - self.start_sec);
    }

    /// Schedule `node` to fire `seconds` from now. If the node was already
    /// armed, the previous arming is cancelled first. Values larger than
    /// BUCKETS-1 are clamped.
    pub fn arm(self: *Wheel, node: *Node, seconds: u32) void {
        if (node.armed) self.unlink(node);
        const offset_u32: u32 = if (seconds >= BUCKETS) @intCast(BUCKETS - 1) else seconds;
        const offset: usize = @intCast(offset_u32);
        const idx = (self.cursor + offset) % BUCKETS;
        node.bucket = @intCast(idx);
        node.armed = true;
        node.prev = null;
        node.next = self.buckets[idx];
        if (self.buckets[idx]) |head| head.prev = node;
        self.buckets[idx] = node;
    }

    /// Remove `node` from its bucket. Safe to call on a node that isn't armed.
    pub fn cancel(self: *Wheel, node: *Node) void {
        if (!node.armed) return;
        self.unlink(node);
    }

    fn unlink(self: *Wheel, node: *Node) void {
        if (node.prev) |p| {
            p.next = node.next;
        } else {
            self.buckets[node.bucket] = node.next;
        }
        if (node.next) |n| n.prev = node.prev;
        node.armed = false;
        node.next = null;
        node.prev = null;
    }

    /// Advance the wheel up to wall-clock `now_sec` and fire every node
    /// found in the buckets we sweep over. The fire callback receives
    /// `ctx` (a pointer the caller chooses) and the expired node — the
    /// caller's job is to recover the owning struct and tear it down.
    ///
    /// Each node is unlinked before `fire` runs, so it is safe for `fire`
    /// to call back into `cancel` on the same node (e.g., during destroy).
    pub fn tick(
        self: *Wheel,
        now_sec: u64,
        ctx: anytype,
        comptime fire: fn (@TypeOf(ctx), *Node) void,
    ) void {
        // Walk one bucket per elapsed second. If many seconds elapsed (event
        // loop was slow), we sweep them all so timeouts don't accumulate.
        while (self.elapsed_secs < now_sec) {
            self.elapsed_secs += 1;
            self.cursor = (self.cursor + 1) % BUCKETS;
            var node = self.buckets[self.cursor];
            self.buckets[self.cursor] = null;
            while (node) |n| {
                const next = n.next;
                n.armed = false;
                n.next = null;
                n.prev = null;
                fire(ctx, n);
                node = next;
            }
        }
    }
};
