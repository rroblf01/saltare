"""Smoke tests: verify the native extension is built and callable."""

from __future__ import annotations

import socket
import threading
import time

import httpx
import pytest


def test_version_string() -> None:
    import saltare

    assert isinstance(saltare.__version__, str)
    assert saltare.__version__.count(".") >= 1


def test_core_exports() -> None:
    from saltare import _core

    assert callable(_core.version)
    assert callable(_core.serve)
    assert _core.version() == "0.1.0"


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def test_stub_server_responds() -> None:
    """Run the v0 stub server in a thread and check it returns HTTP 200."""
    from saltare import _core

    port = _free_port()
    thread = threading.Thread(
        target=_core.serve,
        args=("127.0.0.1", port),
        daemon=True,
    )
    thread.start()

    # Wait for the listener to be ready.
    deadline = time.monotonic() + 2.0
    while time.monotonic() < deadline:
        try:
            response = httpx.get(f"http://127.0.0.1:{port}/", timeout=1.0)
            break
        except httpx.ConnectError:
            time.sleep(0.05)
    else:
        pytest.fail("stub server never became ready")

    assert response.status_code == 200
    assert b"saltare" in response.content
