"""Integration tests against a real FastAPI application."""

from __future__ import annotations

import socket
import threading
import time

import httpx
import pytest

# FastAPI is a dev/test dep; if missing, skip the whole module.
fastapi = pytest.importorskip("fastapi")


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _wait_ready(port: int, timeout: float = 2.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return
        except (ConnectionRefusedError, socket.timeout):
            time.sleep(0.05)
    pytest.fail("server never became ready")


@pytest.fixture
def fastapi_server() -> int:
    from fastapi import FastAPI

    from saltare import run

    app = FastAPI()

    @app.get("/")
    def root():
        return {"hello": "world"}

    @app.get("/items/{item_id}")
    def item(item_id: int):
        return {"item_id": item_id}

    @app.post("/echo")
    async def echo(payload: dict):
        return {"received": payload}

    port = _free_port()
    threading.Thread(
        target=run,
        args=(app,),
        kwargs={"host": "127.0.0.1", "port": port},
        daemon=True,
    ).start()
    _wait_ready(port)
    return port


def test_get_returns_json(fastapi_server: int) -> None:
    response = httpx.get(f"http://127.0.0.1:{fastapi_server}/", timeout=2.0)
    assert response.status_code == 200
    assert response.json() == {"hello": "world"}


def test_path_parameter(fastapi_server: int) -> None:
    response = httpx.get(f"http://127.0.0.1:{fastapi_server}/items/42", timeout=2.0)
    assert response.status_code == 200
    assert response.json() == {"item_id": 42}


def test_post_json_body(fastapi_server: int) -> None:
    response = httpx.post(
        f"http://127.0.0.1:{fastapi_server}/echo",
        json={"foo": "bar", "n": 7},
        timeout=2.0,
    )
    assert response.status_code == 200
    assert response.json() == {"received": {"foo": "bar", "n": 7}}


def test_unknown_route_returns_404(fastapi_server: int) -> None:
    response = httpx.get(
        f"http://127.0.0.1:{fastapi_server}/nonexistent",
        timeout=2.0,
    )
    assert response.status_code == 404
