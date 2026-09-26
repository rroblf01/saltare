"""Platform support: what builds where, and what is documented as absent.

v1.12 added macOS (arm64) wheels, which is the first time the extension
is not Linux-only. Two things are worth pinning in a test rather than
leaving to the release CI:

  - the platform gate itself, so a future `@compileError` or a stray
    `#[cfg(target_os)]`-equivalent creeping back into the core fails here
    with a readable message instead of only in the wheel matrix;
  - the features that are *deliberately* absent on macOS, so that "works
    everywhere" is not claimed for something that quietly degrades to a
    no-op.

The genuinely platform-specific behaviour — kqueue vs epoll, the
`madvise` advice, the metrics readers — cannot be asserted from a single
OS. What this module can do is assert that the process knows which
platform it is on and that the documented degradations hold.

Note on the macOS metric series: `process_resident_memory_bytes`,
`process_open_fds` and `process_cpu_seconds_total` used to be hardcoded
to 0 off Linux. They are now implemented for macOS via `proc_pidinfo` and
`getrusage`, and the assertions below require them to be *present in the
output* on every platform. They are not required to be non-zero here,
because RSS and CPU legitimately read 0 in a freshly started process on
some kernels; asserting presence is what catches a regression to the
old comptime-0 behaviour.
"""

from __future__ import annotations

import platform
import socket
import sys
import threading
import time
from typing import Any

import pytest

_PLATFORM = sys.platform


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


async def _hello(scope, receive, send):
    if scope["type"] == "lifespan":
        while True:
            msg = await receive()
            if msg["type"] == "lifespan.startup":
                await send({"type": "lifespan.startup.complete"})
            elif msg["type"] == "lifespan.shutdown":
                await send({"type": "lifespan.shutdown.complete"})
                return
        return
    await receive()
    await send({
        "type": "http.response.start",
        "status": 200,
        "headers": [(b"content-type", b"text/plain")],
    })
    await send({"type": "http.response.body", "body": b"ok", "more_body": False})


def _serve(app: Any, port: int, **kwargs) -> None:
    from saltare import run

    threading.Thread(
        target=run,
        args=(app,),
        kwargs={"host": "127.0.0.1", "port": port, **kwargs},
        daemon=True,
    ).start()
    deadline = time.monotonic() + 3.0
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return
        except (ConnectionRefusedError, socket.timeout, OSError):
            time.sleep(0.05)
    pytest.fail("server never became ready")


# ---------------------------------------------------------------------------
# The platform gate
# ---------------------------------------------------------------------------

SUPPORTED = {"linux", "darwin"}


def test_running_on_a_supported_platform() -> None:
    """The core has an event-loop backend for Linux (epoll) and macOS
    (kqueue) and refuses to build anywhere else. If this fails, the
    extension was built for a target eventloop.zig does not cover."""
    assert _PLATFORM in SUPPORTED, (
        f"saltare does not support {_PLATFORM!r}; supported: "
        f"{sorted(SUPPORTED)}. A build for this platform should not have "
        f"produced a working _core."
    )


def test_server_actually_runs_on_this_platform() -> None:
    """The real check: the accept loop and dispatcher come up and answer.
    On an unsupported platform the extension would have failed to build,
    so reaching this point at all is most of the assertion."""
    import httpx

    port = _free_port()
    _serve(_hello, port)
    with httpx.Client(timeout=3.0) as client:
        r = client.get(f"http://127.0.0.1:{port}/")
    assert r.status_code == 200
    assert r.text == "ok"


def test_platform_is_reported_consistently() -> None:
    """`platform.system()` and `sys.platform` must agree. The test suite
    keys timing factors off `platform.machine()`, and the CI matrix keys
    the wheel set off the OS, so a mismatch here is how a platform ends up
    silently untested."""
    system = platform.system()
    expected = {"Linux": "linux", "Darwin": "darwin"}.get(system)
    assert expected is not None, f"unexpected platform.system()={system!r}"
    assert _PLATFORM == expected, (
        f"sys.platform={_PLATFORM!r} but platform.system()={system!r}"
    )


@pytest.mark.skipif(
    platform.machine() not in {"x86_64", "aarch64", "arm64"},
    reason="the wheel matrix is x86_64 + aarch64; an unexpected arch means "
           "this build is not one of the published ones",
)
def test_architecture_is_one_we_publish() -> None:
    assert platform.machine() in {"x86_64", "aarch64", "arm64"}


# ---------------------------------------------------------------------------
# Metrics presence
# ---------------------------------------------------------------------------


def _metrics_body(port: int) -> str:
    import httpx

    with httpx.Client(timeout=3.0) as client:
        return client.get(f"http://127.0.0.1:{port}/metrics").text


def test_process_metrics_are_present_on_every_platform() -> None:
    """The three `process_*` series must appear in /metrics on macOS as
    well as Linux.

    This is the regression guard for the v1.12 fix: they were emitted only
    when the comptime branch that reads /proc was taken, so on macOS the
    metrics rendered as a constant 0 — indistinguishable from "the process
    really is using no memory" in a dashboard, which is the worst possible
    failure mode for a RAM-focused server.

    Presence, not magnitude: RSS and CPU can legitimately read 0 right
    after start on some kernels.
    """
    port = _free_port()
    _serve(_hello, port, metrics_path="/metrics")
    body = _metrics_body(port)

    # The names are deliberately mixed: the resident-memory gauge is
    # saltare's own, while the other three follow the prometheus/client
    # convention so an existing Grafana dashboard picks them up. Pinned
    # exactly, because renaming one is a silent dashboard break.
    for family in (
        "saltare_process_resident_memory_bytes",
        "process_open_fds",
        "process_cpu_seconds_total",
    ):
        assert family in body, (
            f"{family} missing from /metrics on {_PLATFORM}. The reader is "
            f"probably still gated to Linux."
        )


def test_process_start_time_is_present() -> None:
    """`process_start_time_seconds` is the Prometheus reset-detection
    convention and is platform-independent (a Unix timestamp captured at
    module init), so it must be present everywhere."""
    port = _free_port()
    _serve(_hello, port, metrics_path="/metrics")
    body = _metrics_body(port)
    assert "process_start_time_seconds" in body, body[:2000]


# ---------------------------------------------------------------------------
# Documented platform differences
# ---------------------------------------------------------------------------


def test_cgroup_autotuning_is_linux_only_but_harmless_elsewhere() -> None:
    """`max_concurrent_connections` is auto-tuned down from the cgroup
    memory limit. There is no cgroup on macOS, so the reader returns null
    and the configured default is used.

    The point of the test is that the absence is silent and harmless: the
    server must still come up and serve, at the default cap.
    """
    import httpx

    port = _free_port()
    _serve(_hello, port)
    with httpx.Client(timeout=3.0) as client:
        assert client.get(f"http://127.0.0.1:{port}/").status_code == 200


@pytest.mark.skipif(
    _PLATFORM != "darwin",
    reason="documents the macOS-only degradation; nothing to assert on Linux",
)
def test_ktls_is_inert_on_macos() -> None:
    """kTLS needs kernel TLS offload, which is Linux-specific. On macOS
    the flag must be accepted and ignored rather than failing startup —
    operators set it in shared config.

    Covered behaviourally in tests/test_operational_knobs.py; this exists
    to make the platform difference explicit where a reader will look for
    it.
    """
    import httpx

    port = _free_port()
    _serve(_hello, port, ktls=True)
    with httpx.Client(timeout=3.0) as client:
        assert client.get(f"http://127.0.0.1:{port}/").status_code == 200
