"""PEP 684 groundwork (v1.11): the native `_core` extension uses multi-phase
initialisation, which is the prerequisite for loading it under a
sub-interpreter at all (single-phase extensions are rejected there).

This proves the gateway: `saltare._core` imports cleanly inside a *shared-GIL*
sub-interpreter (legacy `Py_NewInterpreter` semantics). Per-interpreter-GIL
(own-GIL) hosting is a later phase — it additionally requires the
`Py_mod_multiple_interpreters` / `Py_mod_gil` slots and making all
process-global state in the Zig core per-interpreter first.

The test is best-effort: it skips when run against the source tree (no built
`_core`) or on interpreters whose sub-interpreter C-API isn't exposed the way
we drive it here (pre-3.12, or API-shape drift).
"""

from __future__ import annotations

import importlib.util

import pytest


def _have_core() -> bool:
    try:
        return importlib.util.find_spec("saltare._core") is not None
    except ModuleNotFoundError:
        return False


@pytest.mark.skipif(not _have_core(), reason="needs the built _core extension (installed wheel)")
def test_core_imports_in_shared_gil_subinterpreter():
    try:
        import _interpreters  # CPython 3.13+ low-level sub-interpreter API
    except ImportError:
        pytest.skip("low-level _interpreters API unavailable on this Python")

    # "legacy" = a sub-interpreter that shares the main GIL (the classic
    # Py_NewInterpreter()). That's exactly what multi-phase init unlocks;
    # own-GIL ("isolated") is intentionally not supported yet.
    try:
        iid = _interpreters.create("legacy")
    except Exception:  # noqa: BLE001 - API shape differs across versions
        pytest.skip("_interpreters.create('legacy') not supported here")

    script = "import saltare._core as c; assert c.version()"
    try:
        runner = getattr(_interpreters, "run_string", None) or getattr(_interpreters, "exec", None)
        if runner is None:
            pytest.skip("no _interpreters.run_string/exec on this Python")
        # Raises if the sub-interpreter script raised (e.g. ImportError when
        # the extension is single-phase). No raise == the gateway works.
        runner(iid, script)
    finally:
        try:
            _interpreters.destroy(iid)
        except Exception:  # noqa: BLE001
            pass


def _own_gil_interpreters_module():
    """The PEP 734 high-level module, which creates OWN-GIL interpreters.
    Its name/location moved across versions; try the known spellings."""
    for name in ("concurrent.interpreters", "interpreters"):
        try:
            import importlib
            return importlib.import_module(name)
        except ImportError:
            continue
    return None


@pytest.mark.skipif(not _have_core(), reason="needs the built _core extension (installed wheel)")
def test_core_imports_in_own_gil_subinterpreter():
    """v1.11 declares Py_MOD_PER_INTERPRETER_GIL_SUPPORTED (3.12+). This is
    the real PEP 684 gateway: a PEP 734 interpreter has its OWN GIL, and
    CPython refuses to import an extension there unless it declares support.
    Proves the slot is honoured end to end."""
    interpreters = _own_gil_interpreters_module()
    if interpreters is None:
        pytest.skip("PEP 734 interpreters module unavailable on this Python")
    interp = interpreters.create()  # own-GIL interpreter
    try:
        # .exec raises interpreters.ExecutionFailed if the sub-interpreter
        # script raised. A clean run means own-GIL import works.
        interp.exec("import saltare._core as c; assert c.version()")
    finally:
        try:
            interp.close()
        except Exception:  # noqa: BLE001
            pass


def _free_port() -> int:
    import socket

    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]
    finally:
        s.close()


@pytest.mark.skipif(not _have_core(), reason="needs the built _core extension (installed wheel)")
def test_full_server_runs_in_own_gil_subinterpreter():
    """The PEP 684 payoff proof: not just *importing* `_core` under an
    own-GIL interpreter, but running the *entire* saltare serve stack there
    — event loop, dispatcher, asyncio, an ASGI app — serving a real HTTP
    request, then shutting down cleanly from the *main* interpreter.

    This is the runtime validation that import-only tests can't give and
    that justifies the eventual sub-interpreter worker spawner: it confirms
    the per-`Runtime` state isolation (v1.11 phase 2) actually holds when a
    server runs in a separate interpreter, and that the process-global
    shutdown flag (`_core.request_shutdown`) crosses the interpreter
    boundary to stop it. The spawner, once built, does exactly this per
    worker thread instead of `fork()`.
    """
    interpreters = _own_gil_interpreters_module()
    if interpreters is None:
        pytest.skip("PEP 734 interpreters module unavailable on this Python")

    import socket
    import threading
    import time

    from saltare import _core  # main interp: flips the process-global drain flag

    if not hasattr(_core, "request_shutdown"):
        pytest.skip("_core lacks request_shutdown on this build")

    port = _free_port()
    server_script = f"""
import saltare
async def app(scope, receive, send):
    if scope["type"] == "lifespan":
        while True:
            m = await receive()
            if m["type"] == "lifespan.startup":
                await send({{"type": "lifespan.startup.complete"}})
            elif m["type"] == "lifespan.shutdown":
                await send({{"type": "lifespan.shutdown.complete"}})
                return
        return
    await send({{"type": "http.response.start", "status": 200,
                 "headers": [(b"content-type", b"text/plain")]}})
    await send({{"type": "http.response.body", "body": b"owngil-ok"}})
saltare.run(app, host="127.0.0.1", port={port}, workers=1)
"""

    interp = interpreters.create()
    errbox: list[str] = []

    def run_server():
        try:
            interp.exec(server_script)
        except Exception as e:  # noqa: BLE001 - surface to the assertion below
            errbox.append(repr(e))

    t = threading.Thread(target=run_server, daemon=True)
    t.start()
    try:
        # Wait (bounded) for the sub-interpreter's server to bind, then
        # send one real request.
        body = b""
        deadline = time.monotonic() + 10.0
        while time.monotonic() < deadline:
            try:
                conn = socket.create_connection(("127.0.0.1", port), timeout=1.0)
            except OSError:
                time.sleep(0.1)
                continue
            try:
                conn.sendall(b"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
                while True:
                    chunk = conn.recv(4096)
                    if not chunk:
                        break
                    body += chunk
            finally:
                conn.close()
            break

        assert b"200 OK" in body, f"no 200 from own-GIL server: {body!r} err={errbox}"
        assert b"owngil-ok" in body, f"wrong body from own-GIL server: {body!r}"
    finally:
        # Cross-interpreter shutdown: the drain flag lives in the shared .so
        # data segment, so flipping it from the main interpreter stops the
        # sub-interpreter's serve loop.
        _core.request_shutdown()
        t.join(timeout=10.0)
        try:
            interp.close()
        except Exception:  # noqa: BLE001 - best-effort teardown
            pass

    assert not t.is_alive(), "own-GIL server thread did not stop after request_shutdown"
    assert not errbox, f"sub-interpreter raised: {errbox}"
