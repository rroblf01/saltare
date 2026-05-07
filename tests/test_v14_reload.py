"""v1.4 --reload supervisor tests.

The supervisor is parent/child; we exercise it via the public CLI in
a subprocess so the env-flag and respawn paths are real. Tests use
short poll intervals to keep wall-clock cost low.
"""

from __future__ import annotations

import os
import signal
import socket
import subprocess
import sys
import tempfile
import textwrap
import time
from pathlib import Path

import pytest


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


# Timing budgets are tuned for native x86_64. CI runners that build
# aarch64 wheels under QEMU emulation are 3-5× slower; multiply
# everything by `_TIMING_FACTOR` so the same tests pass on both.
import platform as _platform
_TIMING_FACTOR: float = 4.0 if _platform.machine() in {"aarch64", "arm64"} else 1.0


def _wait_listening(port: int, timeout_s: float = 6.0) -> bool:
    timeout_s *= _TIMING_FACTOR
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        try:
            with socket.socket() as s:
                s.settimeout(0.2)
                s.connect(("127.0.0.1", port))
                return True
        except (ConnectionRefusedError, socket.timeout, OSError):
            time.sleep(0.05)
    return False


def _http_get_body(port: int, path: str = "/") -> bytes:
    import http.client
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=2.0)
    conn.request("GET", path)
    resp = conn.getresponse()
    body = resp.read()
    conn.close()
    return body


@pytest.fixture
def app_dir():
    """Temporary directory with a minimal saltare app file."""
    with tempfile.TemporaryDirectory() as d:
        d_path = Path(d)
        (d_path / "myapp.py").write_text(textwrap.dedent("""
            VERSION = b"v1"
            async def app(scope, receive, send):
                if scope["type"] == "lifespan":
                    while True:
                        m = await receive()
                        if m["type"] == "lifespan.startup":
                            await send({"type": "lifespan.startup.complete"})
                        elif m["type"] == "lifespan.shutdown":
                            await send({"type": "lifespan.shutdown.complete"}); return
                    return
                await receive()
                await send({"type": "http.response.start", "status": 200,
                            "headers": [(b"content-type", b"text/plain")]})
                await send({"type": "http.response.body", "body": VERSION, "more_body": False})
        """))
        yield d_path


def test_reload_supervisor_respawns_on_change(app_dir):
    """Touching the watched file makes the supervisor SIGTERM the
    child + respawn; the new child serves the updated source."""
    port = _free_port()
    proc = subprocess.Popen(
        [
            sys.executable, "-m", "saltare", "myapp:app",
            "--host", "127.0.0.1", "--port", str(port),
            "--reload",
            "--reload-dir", str(app_dir),
            "--reload-poll-secs", "0.1",
            # Trim saltare's drain so the supervisor's SIGTERM →
            # respawn cycle runs in seconds, not the prod 30-second
            # default. Otherwise the old child holds the listen
            # socket and the new child never gets a chance to bind.
            # On QEMU-emulated aarch64 in CI everything is 3-5× slower,
            # so give drain a bit more headroom there.
            "--shutdown-timeout", "3" if _TIMING_FACTOR > 1 else "1",
        ],
        cwd=str(app_dir),
        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
    )
    try:
        assert _wait_listening(port), "saltare child never listened"
        assert _http_get_body(port) == b"v1"
        # Mutate the source — supervisor should pick this up within
        # a couple of poll intervals and respawn. The supervisor
        # itself purges `__pycache__` between respawns to avoid the
        # `.opt-2.pyc` mtime-race; the test relies on that
        # behaviour, no manual cleanup needed here.
        target = app_dir / "myapp.py"
        contents = target.read_text().replace(b'b"v1"'.decode(), b'b"v2"'.decode())
        target.write_text(contents)
        # Give the supervisor: poll-detect (~0.1 s) + SIGTERM + child
        # drain + respawn + rebind. 12 s is generous for native hosts;
        # QEMU-aarch64 multiplies by `_TIMING_FACTOR`.
        deadline = time.monotonic() + 12.0 * _TIMING_FACTOR
        body = b""
        while time.monotonic() < deadline:
            try:
                if _wait_listening(port, timeout_s=0.3):
                    body = _http_get_body(port)
                    if body == b"v2":
                        break
            except (ConnectionRefusedError, OSError):
                pass
            time.sleep(0.1)
        if body != b"v2":
            # Surface supervisor stderr so CI failures are debuggable.
            err = b""
            try:
                proc.send_signal(signal.SIGINT)
                _, err = proc.communicate(timeout=2.0)
            except subprocess.TimeoutExpired:
                proc.kill()
                _, err = proc.communicate(timeout=2.0)
            raise AssertionError(
                f"reload didn't pick up the new VERSION (got {body!r}).\n"
                f"--- saltare stderr ---\n{err.decode('utf-8', 'replace')}"
            )
    finally:
        proc.send_signal(signal.SIGINT)
        try:
            proc.wait(timeout=4.0)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()


def test_reload_child_env_flag_is_set():
    """The child process must see `_SALTARE_RELOAD_CHILD=1` so its
    `saltare.run()` skips the supervise branch."""
    from saltare import _reload
    # Direct check on the helper.
    assert _reload.is_reload_child() is False
    os.environ["_SALTARE_RELOAD_CHILD"] = "1"
    try:
        assert _reload.is_reload_child() is True
    finally:
        del os.environ["_SALTARE_RELOAD_CHILD"]
