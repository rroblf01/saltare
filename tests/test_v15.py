"""v1.5 feature tests:

  - /debug/dispatch JSON snapshot endpoint (with + without token)
  - SIGHUP hot config reload from a key=value file
  - /metrics compression counters when an encoder is enabled
  - process_* Prometheus metrics
"""

from __future__ import annotations

import os
import signal
import socket
import subprocess
import sys
import tempfile
import textwrap
import threading
import time
from typing import Any

import httpx
import pytest

import platform as _platform
_TIMING_FACTOR: float = 4.0 if _platform.machine() in {"aarch64", "arm64"} else 1.0


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


async def _lifespan_drain(receive, send):
    while True:
        msg = await receive()
        if msg["type"] == "lifespan.startup":
            await send({"type": "lifespan.startup.complete"})
        elif msg["type"] == "lifespan.shutdown":
            await send({"type": "lifespan.shutdown.complete"})
            return


def _serve(app: Any, port: int, **kwargs) -> None:
    from saltare import run
    threading.Thread(
        target=run,
        args=(app,),
        kwargs={"host": "127.0.0.1", "port": port, **kwargs},
        daemon=True,
    ).start()
    deadline = time.monotonic() + 3.0 * _TIMING_FACTOR
    while time.monotonic() < deadline:
        try:
            with socket.socket() as s:
                s.settimeout(0.2)
                s.connect(("127.0.0.1", port))
                return
        except (ConnectionRefusedError, socket.timeout, OSError):
            time.sleep(0.05)
    pytest.fail(f"server never came up on 127.0.0.1:{port}")


async def _hello(scope, receive, send):
    if scope["type"] == "lifespan":
        await _lifespan_drain(receive, send)
        return
    await receive()
    await send({"type": "http.response.start", "status": 200,
                "headers": [(b"content-type", b"text/plain")]})
    await send({"type": "http.response.body", "body": b"ok", "more_body": False})


# ---------------------------------------------------------------------------
# /debug/dispatch
# ---------------------------------------------------------------------------


def test_dispatch_endpoint_returns_json_snapshot():
    port = _free_port()
    _serve(_hello, port, dispatch_path="/debug/dispatch")
    # Drive a couple of regular requests so the counters are non-zero.
    httpx.get(f"http://127.0.0.1:{port}/", timeout=2.0 * _TIMING_FACTOR)
    httpx.get(f"http://127.0.0.1:{port}/", timeout=2.0 * _TIMING_FACTOR)
    r = httpx.get(f"http://127.0.0.1:{port}/debug/dispatch",
                  timeout=2.0 * _TIMING_FACTOR)
    assert r.status_code == 200
    assert r.headers["content-type"].startswith("application/json")
    import json
    data = json.loads(r.text)
    # Required keys per the documented snapshot shape.
    for key in ("open_conns", "in_flight", "requests_total",
                "responses_4xx", "responses_5xx",
                "bytes_sent", "bytes_received",
                "rl_table_size", "draining", "rss_bytes"):
        assert key in data, f"missing key {key!r}"
    assert data["requests_total"] >= 2  # at least our two probes


def test_dispatch_endpoint_token_auth():
    port = _free_port()
    _serve(_hello, port, dispatch_path="/debug/dispatch", dispatch_token="s3cr3t")
    # No header → 401.
    r = httpx.get(f"http://127.0.0.1:{port}/debug/dispatch",
                  timeout=2.0 * _TIMING_FACTOR)
    assert r.status_code == 401
    # Wrong token → 401.
    r = httpx.get(f"http://127.0.0.1:{port}/debug/dispatch",
                  headers={"Authorization": "Bearer nope"},
                  timeout=2.0 * _TIMING_FACTOR)
    assert r.status_code == 401
    # Correct token → 200 + JSON.
    r = httpx.get(f"http://127.0.0.1:{port}/debug/dispatch",
                  headers={"Authorization": "Bearer s3cr3t"},
                  timeout=2.0 * _TIMING_FACTOR)
    assert r.status_code == 200
    assert "requests_total" in r.text


# ---------------------------------------------------------------------------
# /metrics compression counters + process_* metrics
# ---------------------------------------------------------------------------


_BIG_JSON = (b'{"items": [' + b'"x",' * 4000 + b'"end"]}')


async def _big_json(scope, receive, send):
    if scope["type"] == "lifespan":
        await _lifespan_drain(receive, send)
        return
    await receive()
    await send({"type": "http.response.start", "status": 200,
                "headers": [(b"content-type", b"application/json")]})
    await send({"type": "http.response.body", "body": _BIG_JSON, "more_body": False})


def test_metrics_includes_compression_counters_when_gzip_on():
    port = _free_port()
    _serve(_big_json, port, response_gzip=True, metrics_path="/metrics")
    # Trigger one compressed response.
    httpx.get(f"http://127.0.0.1:{port}/",
              headers={"Accept-Encoding": "gzip"},
              timeout=2.0 * _TIMING_FACTOR)
    r = httpx.get(f"http://127.0.0.1:{port}/metrics",
                  timeout=2.0 * _TIMING_FACTOR)
    assert r.status_code == 200
    body = r.text
    assert 'saltare_response_compression_total{encoding="gzip"}' in body
    assert 'saltare_response_compression_bytes_in_total{encoding="gzip"}' in body
    assert 'saltare_response_compression_bytes_out_total{encoding="gzip"}' in body


def test_metrics_includes_process_metrics():
    port = _free_port()
    _serve(_hello, port, metrics_path="/metrics")
    r = httpx.get(f"http://127.0.0.1:{port}/metrics",
                  timeout=2.0 * _TIMING_FACTOR)
    body = r.text
    assert "process_open_fds" in body
    assert "process_start_time_seconds" in body
    assert "process_cpu_seconds_total" in body
    assert "saltare_process_resident_memory_bytes" in body


# ---------------------------------------------------------------------------
# SIGHUP runtime config reload
# ---------------------------------------------------------------------------


@pytest.mark.flaky(reruns=2, reruns_delay=1)
def test_sighup_runtime_config_reload(tmp_path):
    """SIGHUP re-reads the config file and applies recognised keys.
    Verified by parsing the supervisor's stderr."""
    cfg = tmp_path / "runtime.cfg"
    cfg.write_text("rate_limit_per_sec=42\naccess_log=true\n")
    port = _free_port()

    # Run via subprocess so we can send SIGHUP to a real PID and read stderr.
    proc = subprocess.Popen(
        [
            sys.executable, "-m", "saltare",
            "tests.test_v15:_hello",
            "--host", "127.0.0.1", "--port", str(port),
            "--runtime-config-path", str(cfg),
            "--shutdown-timeout", "1",
        ],
        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
        cwd=os.getcwd(),
    )
    try:
        # Wait for listen.
        deadline = time.monotonic() + 6.0 * _TIMING_FACTOR
        while time.monotonic() < deadline:
            try:
                with socket.socket() as s:
                    s.settimeout(0.2)
                    s.connect(("127.0.0.1", port))
                    break
            except (ConnectionRefusedError, socket.timeout, OSError):
                time.sleep(0.05)
        else:
            raise AssertionError("server never bound")

        # Edit the file + send SIGHUP.
        cfg.write_text("rate_limit_per_sec=99\nmax_connections_per_ip=8\n")
        proc.send_signal(signal.SIGHUP)
        time.sleep(0.4 * _TIMING_FACTOR)
    finally:
        proc.send_signal(signal.SIGINT)
        try:
            _, err = proc.communicate(timeout=5.0)
        except subprocess.TimeoutExpired:
            proc.kill()
            _, err = proc.communicate(timeout=2.0)

    err_text = err.decode("utf-8", "replace")
    assert "saltare: SIGHUP: applied" in err_text, err_text
