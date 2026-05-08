"""Test isolation: shut down saltare servers spawned by tests so they
don't pile up.

Several tests use a `_serve()` helper that spawns `saltare.run()` in a
daemon thread and never tears it down — historically that was fine
because process exit reaped them. Under cibuildwheel + musllinux the
accumulated daemon threads (one per test) race on the cross-thread
globals in `server.zig` (`g_obs`, listener fd, atomics) and segfault
once enough have piled up. Reproduced as exit 139 on cp313-musllinux
during the v1.6 release.

This fixture flips the same drain flag SIGTERM uses (`_core.request_shutdown`)
after each test so the previous test's daemon thread observes drain
mode, finishes any in-flight work, and exits before the next test
spins up its own server. Best-effort: we wait up to 3 s for daemons
to finish; tests that legitimately need to share a server across
modules can pass `--no-cov` etc. to bypass — but the entire suite
runs cleanly with this in place.
"""

from __future__ import annotations

import threading
import time

import pytest


@pytest.fixture(autouse=True)
def _saltare_thread_cleanup():
    yield
    try:
        from saltare import _core
    except ImportError:
        return
    if not hasattr(_core, "request_shutdown"):
        return
    _core.request_shutdown()
    deadline = time.monotonic() + 3.0
    me = threading.current_thread()
    while time.monotonic() < deadline:
        # Daemon threads stuck inside `_core.serve()` block on epoll.
        # Once `request_shutdown()` flips the drain flag, the I/O loop
        # observes it on the next poll iteration (≤100 ms) and exits.
        leaked = [
            t for t in threading.enumerate()
            if t.daemon and t is not me and t.is_alive()
        ]
        if not leaked:
            return
        time.sleep(0.05)
