"""Unit tests for _reload.py — pure-Python reload supervisor functions.

These tests do NOT need the Zig native extension. They exercise
the file-watching, snapshot, and diff logic used by --reload.
"""

from __future__ import annotations

import os
import tempfile
from pathlib import Path

import pytest


# ---------------------------------------------------------------------------
# Load _reload as a standalone module
# ---------------------------------------------------------------------------

import importlib.util as _util

_SRC = os.path.join(os.path.dirname(__file__), "..", "src", "saltare", "_reload.py")
if os.path.exists(_SRC):
    _spec = _util.spec_from_file_location("_reload_test", _SRC)
    R = _util.module_from_spec(_spec)
    _spec.loader.exec_module(R)
else:
    import saltare._reload as _R
    R = _R


# ===================================================================
# is_reload_child
# ===================================================================


class TestIsReloadChild:
    def test_default_false(self):
        assert R.is_reload_child() is False

    def test_true_when_env_set(self):
        key = R._RELOAD_ENV_FLAG
        old = os.environ.pop(key, None)
        try:
            os.environ[key] = "1"
            assert R.is_reload_child() is True
        finally:
            if old is not None:
                os.environ[key] = old
            else:
                os.environ.pop(key, None)

    def test_false_when_env_is_not_1(self):
        key = R._RELOAD_ENV_FLAG
        old = os.environ.pop(key, None)
        try:
            os.environ[key] = "0"
            assert R.is_reload_child() is False
            os.environ[key] = ""
            assert R.is_reload_child() is False
        finally:
            if old is not None:
                os.environ[key] = old
            else:
                os.environ.pop(key, None)


# ===================================================================
# _matches
# ===================================================================


class TestMatches:
    def test_simple_py_file(self):
        assert R._matches("/path/to/file.py", ("*.py",)) is True

    def test_txt_not_matching_py(self):
        assert R._matches("/path/to/file.txt", ("*.py",)) is False

    def test_git_dir_excluded(self):
        excludes = R._DEFAULT_EXCLUDES
        assert R._matches("/project/.git/objects/abc123", excludes) is True

    def test_pycache_excluded(self):
        excludes = R._DEFAULT_EXCLUDES
        assert R._matches("/project/__pycache__/foo.cpython.py", excludes) is True

    def test_venv_excluded(self):
        excludes = R._DEFAULT_EXCLUDES
        assert R._matches("/project/.venv/lib/python3.x/site.py", excludes) is True

    def test_matches_any_of_multiple_patterns(self):
        assert R._matches("foo.py", ("*.py", "*.txt")) is True
        assert R._matches("foo.txt", ("*.py", "*.txt")) is True
        assert R._matches("foo.md", ("*.py", "*.txt")) is False


# ===================================================================
# _diff
# ===================================================================


class TestDiff:
    def test_no_changes(self):
        old = {"a.py": 100, "b.py": 200}
        new = {"a.py": 100, "b.py": 200}
        assert R._diff(old, new) == []

    def test_file_modified(self):
        old = {"a.py": 100}
        new = {"a.py": 101}
        assert R._diff(old, new) == ["a.py"]

    def test_file_added(self):
        old = {"a.py": 100}
        new = {"a.py": 100, "b.py": 200}
        assert R._diff(old, new) == ["b.py"]

    def test_file_removed(self):
        old = {"a.py": 100, "b.py": 200}
        new = {"a.py": 100}
        assert R._diff(old, new) == ["b.py"]

    def test_empty_old(self):
        old = {}
        new = {"a.py": 100}
        assert R._diff(old, new) == ["a.py"]

    def test_empty_new(self):
        old = {"a.py": 100}
        new = {}
        assert R._diff(old, new) == ["a.py"]


# ===================================================================
# _snapshot (uses temp dirs)
# ===================================================================


class TestSnapshot:
    def test_empty_directory(self):
        with tempfile.TemporaryDirectory() as td:
            snap = R._snapshot((td,), ("*.py",), ())
            assert snap == {}

    def test_single_py_file(self):
        with tempfile.TemporaryDirectory() as td:
            Path(td, "app.py").write_text("x")
            snap = R._snapshot((td,), ("*.py",), ())
            assert len(snap) == 1
            key = next(iter(snap))
            assert key.endswith("app.py")
            assert isinstance(snap[key], int)

    def test_non_matching_include_excluded(self):
        with tempfile.TemporaryDirectory() as td:
            Path(td, "app.py").write_text("x")
            Path(td, "readme.md").write_text("x")
            snap = R._snapshot((td,), ("*.py",), ())
            assert len(snap) == 1
            assert all(p.endswith(".py") for p in snap)

    def test_exclude_filters_out(self):
        with tempfile.TemporaryDirectory() as td:
            Path(td, "app.py").write_text("x")
            os.makedirs(os.path.join(td, "__pycache__"))
            Path(td, "__pycache__", "app.cpython.py").write_text("x")
            snap = R._snapshot((td,), ("*.py",), R._DEFAULT_EXCLUDES)
            # Only app.py should match; __pycache__/app.cpython.py is excluded
            assert len(snap) == 1
            assert "__pycache__" not in list(snap.keys())[0]

    def test_nonexistent_directory_skipped(self):
        snap = R._snapshot(("/nonexistent/path",), ("*.py",), ())
        assert snap == {}

    def test_nested_files(self):
        with tempfile.TemporaryDirectory() as td:
            Path(td, "app.py").write_text("x")
            os.makedirs(os.path.join(td, "subdir"))
            Path(td, "subdir", "mod.py").write_text("x")
            snap = R._snapshot((td,), ("*.py",), ())
            assert len(snap) == 2

    def test_multiple_directories(self):
        with tempfile.TemporaryDirectory() as td1, tempfile.TemporaryDirectory() as td2:
            Path(td1, "a.py").write_text("x")
            Path(td2, "b.py").write_text("x")
            snap = R._snapshot((td1, td2), ("*.py",), ())
            assert len(snap) == 2


# ===================================================================
# _purge_pycache (basic smoke)
# ===================================================================


class TestPurgePycache:
    def test_removes_pycache_dirs(self):
        with tempfile.TemporaryDirectory() as td:
            cache_dir = os.path.join(td, "__pycache__")
            os.makedirs(cache_dir)
            Path(cache_dir, "mod.cpython.py").write_text("x")
            assert os.path.isdir(cache_dir)
            R._purge_pycache((td,))
            assert not os.path.isdir(cache_dir)

    def test_no_pycache_is_noop(self):
        with tempfile.TemporaryDirectory() as td:
            Path(td, "app.py").write_text("x")
            R._purge_pycache((td,))  # should not raise


# ===================================================================
# _terminate (basic smoke with real subprocess)
# ===================================================================


class TestTerminate:
    def test_terminates_child_process(self):
        import subprocess
        import signal
        import sys
        child = subprocess.Popen(
            [sys.executable, "-c", "import time; time.sleep(60)"],
        )
        assert child.poll() is None  # still alive
        R._terminate(child, grace_secs=2.0)
        assert child.poll() is not None

    def test_already_exited_is_noop(self):
        import subprocess
        import sys
        child = subprocess.Popen([sys.executable, "-c", ""])
        child.wait()
        R._terminate(child)  # should not raise

    def test_kills_on_timeout(self):
        import subprocess
        import sys
        # A process that ignores SIGTERM
        child = subprocess.Popen(
            [sys.executable, "-c",
             "import signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)"],
        )
        R._terminate(child, grace_secs=0.1)
        assert child.poll() is not None


# ===================================================================
# Default constants
# ===================================================================


class TestDefaults:
    def test_default_includes(self):
        assert "*.py" in R._DEFAULT_INCLUDES

    def test_default_excludes_cover_common_patterns(self):
        excludes = R._DEFAULT_EXCLUDES
        assert any("*/.git/*" in e for e in excludes)
        assert any("*/__pycache__/*" in e for e in excludes)
        assert any("*.pyc" in e for e in excludes)
        assert any("*.pyo" in e for e in excludes)

    def test_poll_secs_default(self):
        assert R._DEFAULT_POLL_SECS == 0.5
