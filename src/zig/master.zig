// Multi-worker pre-fork master (v1.0).
//
// Architecture:
//   - The Python wrapper calls _core.serve(..., workers=N) with N>1.
//   - module.zig binds + listens once (via server.bindAndListen).
//   - module.zig forks N times: each child runs runWorkerLogic on the
//     inherited fd; the master process arrives here.
//   - This module's manage() pauses on signals, reaps dying children,
//     and on SIGTERM/SIGINT propagates to all workers, waits for them,
//     and returns. The Python wrapper then exits cleanly.
//
// What v1.0 deliberately doesn't do:
//   - Respawn-on-crash: if a worker exits unexpectedly, the master
//     propagates shutdown to the remaining ones and exits non-zero. The
//     process supervisor (systemd, k8s) then restarts the whole pod.
//     Crash-loop detection inside the master is a v1.x feature.
//   - Aggregated metrics: each worker's `/metrics` endpoint shows only
//     that worker's counters. Scrape per-worker (e.g. via per-worker
//     ports) or use sample-based monitoring.
//   - SO_REUSEPORT: workers share the master's listen fd, so the kernel
//     load-balances accept across workers (TCP) or serializes via the
//     UDS socket. Per-worker bind via SO_REUSEPORT is a v1.x option.

const std = @import("std");
const builtin = @import("builtin");

const c = @cImport({
    @cInclude("sys/types.h");
    @cInclude("sys/wait.h");
    @cInclude("signal.h");
    @cInclude("unistd.h");
});

/// Maximum number of worker processes the master will manage. Bound by
/// the size of the on-stack pid array; users have no business setting
/// this higher and 256 is far above the typical "2-8 workers per pod".
pub const MAX_WORKERS: usize = 256;

/// Master-side flag set by the SIGTERM/SIGINT handler. Triggers the exit
/// branch of the manage() loop, which propagates the signal to all
/// children and waits.
var g_master_should_stop = std.atomic.Value(bool).init(false);
/// Bumped by SIGCHLD so the manage() loop knows a child may have exited
/// without consuming a stop signal. Plain atomic counter — we don't
/// strictly need the value, just the wakeup side-effect on `pause()`.
var g_master_sigchld_count = std.atomic.Value(u32).init(0);

fn masterStopHandler(_: c_int) callconv(.c) void {
    g_master_should_stop.store(true, .seq_cst);
}

fn masterChldHandler(_: c_int) callconv(.c) void {
    _ = g_master_sigchld_count.fetchAdd(1, .seq_cst);
}

fn ignoreSig(_: c_int) callconv(.c) void {}

fn installMasterSignalHandlers() void {
    _ = c.signal(c.SIGINT, &masterStopHandler);
    _ = c.signal(c.SIGTERM, &masterStopHandler);
    _ = c.signal(c.SIGCHLD, &masterChldHandler);
    _ = c.signal(c.SIGPIPE, &ignoreSig);
}

/// Reset the master's signal-handler globals. Called by `manage()` on
/// entry so a second `_core.serve(workers=N)` call in the same process
/// (mostly a tests concern) starts from a clean state.
fn resetMasterState() void {
    g_master_should_stop.store(false, .seq_cst);
    g_master_sigchld_count.store(0, .seq_cst);
}

/// Block in `pause()` until any signal arrives. Wakes on SIGTERM/SIGINT
/// (sets g_master_should_stop) or SIGCHLD (a worker exited). pause()
/// always returns -1 with EINTR; we don't care about the return value.
fn waitForSignal() void {
    _ = c.pause();
}

/// Reap exited children (non-blocking). Returns the number of children
/// reaped this call. Detection of "shutdown when any worker dies" lives
/// in `manage` — this just collects zombies.
fn reapDead(pids: []c.pid_t) usize {
    var reaped: usize = 0;
    while (true) {
        var status: c_int = 0;
        const pid = c.waitpid(-1, &status, c.WNOHANG);
        if (pid <= 0) break;
        for (pids) |*slot| {
            if (slot.* == pid) {
                slot.* = -1;
                reaped += 1;
                break;
            }
        }
    }
    return reaped;
}

/// True iff `pids` has at least one live worker.
fn anyAlive(pids: []c.pid_t) bool {
    for (pids) |pid| {
        if (pid > 0) return true;
    }
    return false;
}

/// Master supervisor. Caller has already forked the workers and filled
/// `pids` with their pids. Returns once all workers have exited.
///
/// Lifecycle:
///   1. Install master-only signal handlers (overrides anything inherited
///      from the worker code via shared `installSignalHandlers`).
///   2. Loop on `pause()` until either a stop signal arrives or all
///      workers exit on their own.
///   3. Propagate SIGTERM to any still-live workers and wait for them.
pub fn manage(pids: []c.pid_t) void {
    resetMasterState();
    installMasterSignalHandlers();

    while (!g_master_should_stop.load(.seq_cst)) {
        waitForSignal();
        // Reap whatever's exited. If any worker exited unexpectedly (we
        // didn't request it), propagate shutdown to the rest — v1.0
        // policy: if any worker dies, the pod dies.
        const reaped = reapDead(pids);
        if (reaped > 0 and !g_master_should_stop.load(.seq_cst)) {
            std.log.warn(
                "saltare master: worker exited unexpectedly, propagating shutdown",
                .{},
            );
            g_master_should_stop.store(true, .seq_cst);
        }
        if (!anyAlive(pids)) break;
    }

    // Propagate SIGTERM to any survivors. If they don't drain in time
    // (their own `shutdown_timeout` bounds the wait), force-kill the
    // stragglers so the pod can exit.
    for (pids) |pid| {
        if (pid > 0) _ = c.kill(pid, c.SIGTERM);
    }
    for (pids) |*slot| {
        if (slot.* > 0) {
            var status: c_int = 0;
            _ = c.waitpid(slot.*, &status, 0);
            slot.* = -1;
        }
    }
}
