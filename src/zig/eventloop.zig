// Event-loop backend selection.
//
// v1.12: the epoll implementation moved to eventloop_epoll.zig and a
// kqueue one was added in eventloop_kqueue.zig. This module picks one at
// comptime and re-exports it, which has two consequences that matter:
//
//   - server.zig is unchanged. It has always imported "eventloop.zig" and
//     used only `Loop`, `Loop.init`, and the add/modify/remove/wait/deinit
//     methods plus the `runtime` field. Because the re-export is a
//     comptime alias, the struct it gets is literally the backend's own
//     type: same layout, same field offsets, no vtable, no tag check.
//
//   - The hot path pays nothing for supporting two platforms. The OS is
//     fixed when the extension is compiled, so there is no runtime
//     dispatch anywhere; the alternative — one `Loop` with a union and a
//     branch in every method — would have cost a predictable branch on
//     every event, against a project whose stated goal is minimum RAM and
//     maximum req/sec.
//
// Previously this file held the epoll code directly and carried a
// `@compileError` for every non-Linux target, which is why macOS wheels
// were impossible: the server could not be built there at all.

const builtin = @import("builtin");

const backend = switch (builtin.os.tag) {
    .linux => @import("eventloop_epoll.zig"),
    .macos => @import("eventloop_kqueue.zig"),
    else => @compileError(
        "saltare supports Linux (epoll) and macOS (kqueue). " ++
            "Other targets have no event-loop backend; build inside the " ++
            "Docker pipeline or add one.",
    ),
};

pub const Event = backend.Event;
pub const Loop = backend.Loop;
pub const max_events_per_wait = backend.max_events_per_wait;
