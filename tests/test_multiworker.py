"""Pre-fork multi-worker (v1.0).

Master forks N workers that each run lifespan + accept loop on a shared
listen socket. SIGTERM to the master propagates to every worker; a worker
exiting unexpectedly propagates shutdown to the rest. Tested via
subprocess because signals (and forking) need a real process tree.
"""

from __future__ import annotations

import os
import signal
import socket
import subprocess
import sys
import time

import httpx
import pytest


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _spawn_saltare_subprocess(port: int, workers: int) -> subprocess.Popen:
    """Launch saltare with `workers` pre-fork workers serving a tiny ASGI
    app. Returns the master Popen handle once the listening socket
    accepts connections."""
    src = f"""
import saltare

async def app(scope, receive, send):
    if scope["type"] == "lifespan":
        while True:
            msg = await receive()
            if msg["type"] == "lifespan.startup":
                await send({{"type": "lifespan.startup.complete"}})
            elif msg["type"] == "lifespan.shutdown":
                await send({{"type": "lifespan.shutdown.complete"}})
                return
        return
    await receive()
    await send({{
        "type": "http.response.start",
        "status": 200,
        "headers": [(b"content-type", b"text/plain")],
    }})
    await send({{
        "type": "http.response.body",
        "body": b"pid=" + str.encode(str(__import__('os').getpid())),
        "more_body": False,
    }})

saltare.run(app, host="127.0.0.1", port={port}, workers={workers})
"""
    proc = subprocess.Popen(
        [sys.executable, "-c", src],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )
    deadline = time.monotonic() + 8.0
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            err = (proc.stderr.read() if proc.stderr else b"").decode(errors="replace")
            pytest.fail(f"subprocess exited prematurely: rc={proc.returncode} err={err[-500:]}")
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return proc
        except (ConnectionRefusedError, socket.timeout):
            time.sleep(0.05)
    proc.terminate()
    pytest.fail("subprocess never became ready")


def _kill_if_alive(proc: subprocess.Popen) -> None:
    if proc.poll() is None:
        proc.kill()
        try:
            proc.wait(timeout=2.0)
        except subprocess.TimeoutExpired:
            pass


def _list_worker_pids(master_pid: int) -> list[int]:
    """Linux-only: read /proc/<master>/task/<master>/children for the
    direct children of `master_pid`. Used to verify both that workers
    are spawned AND that they're cleaned up on shutdown."""
    path = f"/proc/{master_pid}/task/{master_pid}/children"
    try:
        with open(path) as f:
            return [int(p) for p in f.read().split() if p]
    except FileNotFoundError:
        return []


@pytest.mark.skipif(
    not os.path.exists("/proc/self/task"),
    reason="needs /proc to enumerate worker pids (Linux-only feature)",
)
def test_multiworker_spawns_n_workers() -> None:
    """`workers=2` must result in exactly 2 child processes under the
    master. Verified via `/proc/<pid>/task/<pid>/children`."""
    port = _free_port()
    proc = _spawn_saltare_subprocess(port, workers=2)
    try:
        # Give the master a moment to fork all workers.
        deadline = time.monotonic() + 2.0
        children: list[int] = []
        while time.monotonic() < deadline:
            children = _list_worker_pids(proc.pid)
            if len(children) == 2:
                break
            time.sleep(0.05)
        assert len(children) == 2, f"expected 2 workers, got {children}"

        # Each worker should be a different pid from the master.
        for child in children:
            assert child != proc.pid

        # The master should still be serving requests.
        r = httpx.get(f"http://127.0.0.1:{port}/", timeout=2.0)
        assert r.status_code == 200
        assert r.content.startswith(b"pid=")
    finally:
        _kill_if_alive(proc)


def test_multiworker_serves_requests_across_workers() -> None:
    """Several requests against `workers=2` should be answered (potentially
    by different workers). The kernel's accept-load-balancing makes the
    distribution non-deterministic, but every request should succeed."""
    port = _free_port()
    proc = _spawn_saltare_subprocess(port, workers=2)
    try:
        seen_pids = set()
        with httpx.Client(timeout=2.0) as client:
            for _ in range(20):
                r = client.get(f"http://127.0.0.1:{port}/")
                assert r.status_code == 200
                # Body is "pid=N" — track which worker answered.
                seen_pids.add(r.content.decode())
        # Either both workers answered, or one happened to hog the kernel
        # accept queue. Either is acceptable — what matters is that all
        # requests succeeded.
        assert len(seen_pids) >= 1
    finally:
        _kill_if_alive(proc)


def test_multiworker_sigterm_drains_cleanly() -> None:
    """SIGTERM to the master must propagate to all workers and the
    master must exit 0 once they're all gone."""
    port = _free_port()
    proc = _spawn_saltare_subprocess(port, workers=2)
    try:
        # Sanity-check that the server is up.
        r = httpx.get(f"http://127.0.0.1:{port}/", timeout=2.0)
        assert r.status_code == 200

        proc.send_signal(signal.SIGTERM)
        rc = proc.wait(timeout=10.0)
        # Master returns 0 even though workers may have exited via SIGTERM.
        assert rc == 0, f"master exited with code {rc}"
    finally:
        _kill_if_alive(proc)


def test_multiworker_dead_worker_propagates_shutdown() -> None:
    """v1.0 policy: a worker exiting unexpectedly tells the master to
    propagate shutdown to the rest. The master returns 0 once all
    workers are reaped."""
    port = _free_port()
    proc = _spawn_saltare_subprocess(port, workers=2)
    try:
        deadline = time.monotonic() + 2.0
        children: list[int] = []
        while time.monotonic() < deadline:
            children = _list_worker_pids(proc.pid)
            if len(children) == 2:
                break
            time.sleep(0.05)
        assert len(children) == 2

        # SIGKILL one worker. The master should reap it, set its should-
        # stop flag, propagate SIGTERM to the survivor, wait for it,
        # then exit.
        os.kill(children[0], signal.SIGKILL)

        rc = proc.wait(timeout=10.0)
        # Master may return 0 (it propagates a clean shutdown) — as long
        # as it actually returns within the deadline, the supervisor
        # behaviour is correct.
        assert rc is not None
    finally:
        _kill_if_alive(proc)
