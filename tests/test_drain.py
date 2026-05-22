"""Tests for Connection Draining improvements in v1.9.

Tests:
- drain_path parameter configuration
- drain_wait_seconds parameter
"""

from __future__ import annotations

import inspect
import os

import pytest


class TestDrainConfiguration:
    """Test drain configuration via function parameters."""

    def test_drain_path_parameter_exists(self):
        """Verify drain_path parameter in run()."""
        from saltare import run
        sig = inspect.signature(run)
        assert "drain_path" in sig.parameters

    def test_drain_wait_seconds_parameter_exists(self):
        """Verify drain_wait_seconds parameter in run()."""
        from saltare import run
        sig = inspect.signature(run)
        assert "drain_wait_seconds" in sig.parameters

    def test_drain_wait_seconds_default(self):
        """Verify default value is 5 seconds."""
        from saltare import run
        sig = inspect.signature(run)
        param = sig.parameters["drain_wait_seconds"]
        assert param.default == 5

    def test_cli_has_drain_wait_arg(self):
        """Verify CLI has --drain-wait-seconds argument."""
        import saltare.cli as cli_mod
        import ast
        src = inspect.getsource(cli_mod)
        assert "--drain-wait-seconds" in src

    def test_cli_has_drain_path_arg(self):
        """Verify CLI has --drain-path argument."""
        import saltare.cli as cli_mod
        import ast
        src = inspect.getsource(cli_mod)
        assert "--drain-path" in src


if __name__ == "__main__":
    pytest.main([__file__, "-v"])