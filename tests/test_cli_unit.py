"""Unit tests for cli.py — pure-Python CLI functions.

These tests do NOT need the Zig native extension. They exercise
the argument parser, config checker, app loader, and helpers.
"""

from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path

import pytest


# ---------------------------------------------------------------------------
# Load cli as a standalone module, mocking saltare so the
# `from saltare import __version__, run` line succeeds.
# ---------------------------------------------------------------------------

import importlib.util as _util
import types as _types

_SRC = os.path.join(os.path.dirname(__file__), "..", "src", "saltare", "cli.py")

if os.path.exists(_SRC):
    # Load from source (no _core dependency needed)
    _mock_saltare = _types.ModuleType("saltare")
    _mock_saltare.__version__ = "1.11.0"

    def _mock_run(**kwargs):
        pass

    _mock_saltare.run = _mock_run

    import sys as _sys
    _orig_saltare = _sys.modules.get("saltare")
    _sys.modules["saltare"] = _mock_saltare

    _spec = _util.spec_from_file_location("saltare.cli", _SRC)
    CLI = _util.module_from_spec(_spec)
    _spec.loader.exec_module(CLI)

    # Restore the real saltare so subsequent test files in the
    # same pytest process don't import the mock instead.
    if _orig_saltare is not None:
        _sys.modules["saltare"] = _orig_saltare
    else:
        _sys.modules.pop("saltare", None)
else:
    # Fall back to installed package (wheel has _core)
    import saltare.cli as _CLI
    CLI = _CLI


# ===================================================================
# _is_saltare_main_entry
# ===================================================================


class TestIsSaltareMainEntry:
    def test_not_main_entry_in_test(self):
        """When running under pytest, sys.argv[0] is pytest's script."""
        assert CLI._is_saltare_main_entry() is False

    def test_console_script_name(self):
        old_argv = sys.argv
        try:
            sys.argv = ["saltare", "myapp:app"]
            assert CLI._is_saltare_main_entry() is True
        finally:
            sys.argv = old_argv

    def test_main_py_invocation(self):
        old_argv = sys.argv
        try:
            sys.argv = ["/path/to/saltare/__main__.py", "myapp:app"]
            assert CLI._is_saltare_main_entry() is True
        finally:
            sys.argv = old_argv

    def test_main_py_without_saltare_in_path(self):
        old_argv = sys.argv
        try:
            sys.argv = ["/some/other/__main__.py"]
            assert CLI._is_saltare_main_entry() is False
        finally:
            sys.argv = old_argv

    def test_foreign_main_py_under_saltare_dir_is_not_entry(self):
        """Regression: the project / venv may live under a directory whose
        name contains "saltare" (e.g. cloned into ~/code/saltare). A naive
        `"saltare" in arg0` substring check then matched *any* `python -m
        <tool>` run from that tree — pytest, build, mypy — and re-execed it
        as the saltare CLI, which died parsing the foreign tool's argv.
        Only the saltare package's own __main__.py (parent dir == saltare)
        is a real entry point."""
        old_argv = sys.argv
        try:
            sys.argv = ["/home/me/saltare/.venv/lib/python3.14/site-packages/pytest/__main__.py"]
            assert CLI._is_saltare_main_entry() is False
        finally:
            sys.argv = old_argv

    def test_empty_argv(self):
        old_argv = sys.argv
        try:
            sys.argv = []
            assert CLI._is_saltare_main_entry() is False
        finally:
            sys.argv = old_argv

    def test_saltare_script_py_windows(self):
        old_argv = sys.argv
        try:
            sys.argv = ["saltare-script.py", "myapp:app"]
            assert CLI._is_saltare_main_entry() is True
        finally:
            sys.argv = old_argv


# ===================================================================
# _check_config
# ===================================================================


class TestCheckConfig:
    def test_empty_file(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".conf", delete=False) as f:
            f.write("")
            path = f.name
        try:
            rc = CLI._check_config(path)
            assert rc == 0
        finally:
            os.unlink(path)

    def test_commented_file(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".conf", delete=False) as f:
            f.write("# this is a comment\n# another\n")
            path = f.name
        try:
            rc = CLI._check_config(path)
            assert rc == 0
        finally:
            os.unlink(path)

    def test_valid_int_keys(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".conf", delete=False) as f:
            f.write("rate_limit_per_sec=100\n")
            f.write("rate_limit_burst=200\n")
            f.write("max_connections_per_ip=50\n")
            f.write("max_connection_lifetime_secs=3600\n")
            path = f.name
        try:
            rc = CLI._check_config(path)
            assert rc == 0
        finally:
            os.unlink(path)

    def test_valid_bool_keys(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".conf", delete=False) as f:
            f.write("access_log=true\n")
            path = f.name
        try:
            rc = CLI._check_config(path)
            assert rc == 0
        finally:
            os.unlink(path)

    def test_bool_values(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".conf", delete=False) as f:
            f.write("access_log=true\n")
            path = f.name
        try:
            rc = CLI._check_config(path)
            assert rc == 0
        finally:
            os.unlink(path)

    @pytest.mark.parametrize("val", ["true", "false", "1", "0", "yes", "no"])
    def test_all_bool_formats(self, val):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".conf", delete=False) as f:
            f.write(f"access_log={val}\n")
            path = f.name
        try:
            rc = CLI._check_config(path)
            assert rc == 0
        finally:
            os.unlink(path)

    def test_unknown_key(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".conf", delete=False) as f:
            f.write("nonexistent_key=42\n")
            path = f.name
        try:
            rc = CLI._check_config(path)
            assert rc == 1
        finally:
            os.unlink(path)

    def test_bad_int_value(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".conf", delete=False) as f:
            f.write("rate_limit_per_sec=notanumber\n")
            path = f.name
        try:
            rc = CLI._check_config(path)
            assert rc == 1
        finally:
            os.unlink(path)

    def test_bad_bool_value(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".conf", delete=False) as f:
            f.write("access_log=maybe\n")
            path = f.name
        try:
            rc = CLI._check_config(path)
            assert rc == 1
        finally:
            os.unlink(path)

    def test_missing_separator(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".conf", delete=False) as f:
            f.write("rate_limit_per_sec\n")
            path = f.name
        try:
            rc = CLI._check_config(path)
            assert rc == 1
        finally:
            os.unlink(path)

    def test_mixed_valid_and_invalid(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".conf", delete=False) as f:
            f.write("rate_limit_per_sec=100\n")
            f.write("unknown_key=42\n")
            path = f.name
        try:
            rc = CLI._check_config(path)
            assert rc == 1
        finally:
            os.unlink(path)

    def test_nonexistent_file(self):
        rc = CLI._check_config("/nonexistent/config.conf")
        assert rc == 1

    def test_whitespace_lines_ignored(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".conf", delete=False) as f:
            f.write("  \n")
            f.write("\t\n")
            f.write("rate_limit_per_sec=100\n")
            path = f.name
        try:
            rc = CLI._check_config(path)
            assert rc == 0
        finally:
            os.unlink(path)

    def test_key_with_spaces(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".conf", delete=False) as f:
            f.write("  rate_limit_per_sec  =  100  \n")
            path = f.name
        try:
            rc = CLI._check_config(path)
            assert rc == 0
        finally:
            os.unlink(path)


# ===================================================================
# _load_app
# ===================================================================


class TestLoadApp:
    def test_loads_module_attr(self):
        """Load a stdlib module that definitely exists and has an attr."""
        app = CLI._load_app("os:getcwd")
        assert callable(app)

    def test_module_not_found(self):
        with pytest.raises(SystemExit):
            CLI._load_app("nonexistent_module:nonexistent_attr")

    def test_attr_not_found(self):
        with pytest.raises(SystemExit):
            CLI._load_app("os:nonexistent_attr")

    def test_missing_colon(self):
        with pytest.raises(SystemExit, match="expected 'module:attribute'"):
            CLI._load_app("justamodule")

    def test_empty_module(self):
        with pytest.raises(SystemExit, match="expected 'module:attribute'"):
            CLI._load_app(":attr")

    def test_empty_attr(self):
        with pytest.raises(SystemExit, match="expected 'module:attribute'"):
            CLI._load_app("module:")


# ===================================================================
# _RUNTIME_CONFIG_KEYS
# ===================================================================


class TestRuntimeConfigKeys:
    def test_has_expected_keys(self):
        assert "rate_limit_per_sec" in CLI._RUNTIME_CONFIG_KEYS
        assert "rate_limit_burst" in CLI._RUNTIME_CONFIG_KEYS
        assert "max_connections_per_ip" in CLI._RUNTIME_CONFIG_KEYS
        assert "max_connection_lifetime_secs" in CLI._RUNTIME_CONFIG_KEYS
        assert "access_log" in CLI._RUNTIME_CONFIG_KEYS

    def test_types_are_correct(self):
        assert CLI._RUNTIME_CONFIG_KEYS["rate_limit_per_sec"] is int
        assert CLI._RUNTIME_CONFIG_KEYS["rate_limit_burst"] is int
        assert CLI._RUNTIME_CONFIG_KEYS["max_connections_per_ip"] is int
        assert CLI._RUNTIME_CONFIG_KEYS["max_connection_lifetime_secs"] is int
        assert CLI._RUNTIME_CONFIG_KEYS["access_log"] is bool


# ===================================================================
# main() smoke tests — test the CLI entry point with various argv
# ===================================================================


class TestMain:
    def test_requires_app(self):
        with pytest.raises(SystemExit):
            CLI.main([])

    def test_help_requests_exit_zero(self):
        with pytest.raises(SystemExit, match="0"):
            CLI.main(["--help"])

    def test_version(self):
        with pytest.raises(SystemExit, match="0"):
            CLI.main(["--version"])

    def test_check_config_nonexistent(self):
        with pytest.raises(SystemExit, match="1"):
            CLI.main(["--check-config", "/nonexistent/conf"])

    def test_no_app_errors(self):
        with pytest.raises(SystemExit, match="2"):
            CLI.main(["--port", "8080"])
