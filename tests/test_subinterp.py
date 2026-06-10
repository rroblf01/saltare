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
