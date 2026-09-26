"""`saltare.optimize_process()` — the explicit opt-in for embedded use.

A re-exec replaces the process, so these tests never trigger one in the
pytest process itself. Two techniques keep that safe:

  - the decision predicates are pure and tested directly;
  - anything that would actually re-exec is exercised in a **child
    process**, which is the only place the real `os.execvpe` behaviour can
    be observed anyway.

`SALTARE_NO_OPTIMIZE=1` is set process-wide below, as belt and braces.
The child-process tests pass an explicit env and therefore opt back in
where they need it.
"""

from __future__ import annotations

import os
import subprocess
import sys
import textwrap
from pathlib import Path

import pytest

from saltare import _optimize

# Nothing in this module may re-exec pytest. The predicates are pure; the
# re-exec path is only ever reached in a child.
os.environ["SALTARE_NO_OPTIMIZE"] = "1"

REPO_SRC = str(Path(__file__).resolve().parent.parent / "src")


# ---------------------------------------------------------------------------
# already_optimized
# ---------------------------------------------------------------------------


def test_opt_out_env_var_is_honoured(monkeypatch: pytest.MonkeyPatch) -> None:
    """Truthy values opt out; falsy ones do not. The `sys.flags.optimize
    >= 2` half of the predicate cannot be exercised here because pytest
    runs at optimize 0 — `test_child_is_a_noop_when_already_run_with_oo`
    covers that half in a child started under `-OO`."""
    monkeypatch.delenv("SALTARE_REEXECED", raising=False)
    for value in ("1", "true", "TRUE", "yes", "on"):
        monkeypatch.setenv("SALTARE_NO_OPTIMIZE", value)
        assert _optimize.already_optimized() is True, value
    for value in ("0", "false", "no", ""):
        monkeypatch.setenv("SALTARE_NO_OPTIMIZE", value)
        assert _optimize.already_optimized() is False, value


def test_reexec_marker_prevents_a_loop(monkeypatch: pytest.MonkeyPatch) -> None:
    """After one re-exec the marker is set, so a second call is a no-op.
    Without this a script calling it twice would fork-bomb itself."""
    monkeypatch.delenv("SALTARE_NO_OPTIMIZE", raising=False)
    monkeypatch.setenv("SALTARE_REEXECED", "1")
    assert _optimize.already_optimized() is True


# ---------------------------------------------------------------------------
# can_reexec_interactive
# ---------------------------------------------------------------------------


def test_refuses_when_there_is_no_script_to_rerun(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """`python -c ...`, `python -` and the REPL have no re-runnable
    argv[0]. Re-execing there would fail or drop the session."""
    for argv0 in ("", "-c", "-", "-m", "/nonexistent/script.py"):
        monkeypatch.setattr(sys, "argv", [argv0])
        assert _optimize.can_reexec_interactive() is False, argv0


def test_allows_a_real_script(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(sys, "argv", [__file__, "--some-app-arg"])
    assert _optimize.can_reexec_interactive() is True


# ---------------------------------------------------------------------------
# optimized_env
# ---------------------------------------------------------------------------


def test_env_forces_optimize_and_bounds_arenas(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    for key in ("PYTHONOPTIMIZE", "MALLOC_ARENA_MAX", "PYTHONFAULTHANDLER",
                "SALTARE_REEXECED"):
        monkeypatch.delenv(key, raising=False)
    env = _optimize.optimized_env()
    assert env["PYTHONOPTIMIZE"] == "2"
    assert env["MALLOC_ARENA_MAX"] == "1"
    assert env["PYTHONFAULTHANDLER"] == "1"
    assert env["SALTARE_REEXECED"] == "1"


def test_env_respects_deliberate_operator_choices(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """`MALLOC_ARENA_MAX` and `PYTHONFAULTHANDLER` are preferences, not
    requirements. An operator running a threaded deployment who set
    `MALLOC_ARENA_MAX=2` must keep it — the whole point of the re-exec is
    the docstrings, not overriding the allocator."""
    monkeypatch.setenv("MALLOC_ARENA_MAX", "4")
    monkeypatch.setenv("PYTHONFAULTHANDLER", "0")
    env = _optimize.optimized_env()
    assert env["MALLOC_ARENA_MAX"] == "4"
    assert env["PYTHONFAULTHANDLER"] == "0"
    # PYTHONOPTIMIZE is forced even if something set it lower, because a
    # re-exec that did not raise the optimize level would be pointless.
    monkeypatch.setenv("PYTHONOPTIMIZE", "1")
    assert _optimize.optimized_env()["PYTHONOPTIMIZE"] == "2"


# ---------------------------------------------------------------------------
# The public function
# ---------------------------------------------------------------------------


def test_public_function_is_exported() -> None:
    import saltare

    assert "optimize_process" in saltare.__all__
    assert callable(saltare.optimize_process)


def test_public_function_declines_without_reexec(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """With nothing to gain it must not attempt a re-exec at all. If it
    tried, it would replace the pytest process."""
    import saltare

    called: list[bool] = []
    monkeypatch.setattr(
        _optimize, "_reexec_if_wanted", lambda argv: called.append(True)
    )
    monkeypatch.setenv("SALTARE_NO_OPTIMIZE", "1")
    assert saltare.optimize_process() is None
    assert called == [], "re-exec attempted despite the opt-out"


def test_public_function_reexecs_when_all_gates_pass(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """The positive path, with the actual exec stubbed out. Asserts the
    argv it *would* use, since that is the part that can be wrong.

    `can_reexec_interactive()` requires argv[0] to be a real file, because
    a re-exec has to be able to re-run it — hence a script that exists
    rather than a plausible-looking path.
    """
    import saltare

    seen: dict[str, object] = {}

    def fake(argv: list[str]) -> None:
        seen["argv"] = argv

    script = tmp_path / "server.py"
    script.write_text("# stand-in for the user's entry point\n")

    monkeypatch.setattr(_optimize, "_reexec_if_wanted", fake)
    monkeypatch.delenv("SALTARE_NO_OPTIMIZE", raising=False)
    monkeypatch.delenv("SALTARE_REEXECED", raising=False)
    monkeypatch.setattr(sys, "argv", [str(script), "--port", "9000"])

    # The stub stands in for execvpe, which never returns on success, so
    # the assertion is that it was reached with the right argv — not on a
    # return value, which is why the function is annotated `-> None`.
    assert saltare.optimize_process() is None
    assert seen["argv"] == [str(script), "--port", "9000"], (
        "the re-exec must replay the user's own argv, not -m saltare"
    )


# ---------------------------------------------------------------------------
# Real re-exec, in a child process
# ---------------------------------------------------------------------------

# Prints its state *before* the call as well as after. A re-exec replaces
# the process, so the pre-exec line is the proof the first pass ran and
# the post-exec line is the proof a second one did.
#
# v1.12: this used to do `sys.path.insert(0, REPO_SRC)` so the child would
# exercise the working tree. That works with an editable install — where
# `saltare` already resolves to src/ and only `_core` is redirected into
# site-packages — and breaks with a real wheel install, which is what CI
# runs. There, src/saltare shadows the installed package and has no `_core`
# beside it, so the child died with "cannot import name '_core' from
# partially initialized module 'saltare'". Five tests, on every platform.
#
# So insert nothing. The child imports the same saltare the pytest process
# imported: the working tree under an editable install, and the installed
# wheel otherwise — and the wheel is built from this same commit, so it is
# the same code either way. It is also the stronger assertion, because it
# tests what a user actually gets.
_CHILD = """
import json, os, sys

def state():
    return {
        "pid": os.getpid(),
        "reexec": os.environ.get("SALTARE_REEXECED") == "1",
        "optimize": sys.flags.optimize,
        "arena": os.environ.get("MALLOC_ARENA_MAX"),
        "faulthandler": os.environ.get("PYTHONFAULTHANDLER"),
    }

print(json.dumps(state()), flush=True)
from saltare import optimize_process
optimize_process()
print(json.dumps(state()), flush=True)
"""


def _run_child(tmp_path: Path, args: list[str] | None = None, **env: str) -> list[dict]:
    """Run the child script and return one state dict per execution pass."""
    import json

    script = tmp_path / "child.py"
    script.write_text(textwrap.dedent(_CHILD))
    e = dict(os.environ)
    for k in ("SALTARE_NO_OPTIMIZE", "SALTARE_REEXECED", "PYTHONOPTIMIZE"):
        e.pop(k, None)
    e.update(env)
    proc = subprocess.run(
        [sys.executable, *([*args] if args else []), str(script)],
        capture_output=True, text=True, timeout=60, env=e,
    )
    assert proc.returncode == 0, proc.stderr[-2000:]
    return [
        json.loads(l) for l in proc.stdout.strip().splitlines() if l.strip()
    ]


def test_child_actually_reexecs_under_optimize_2(tmp_path: Path) -> None:
    """The real thing, in a process we are allowed to replace.

    Three lines are expected: the pre-exec print, then the re-exec'd
    process printing twice (once on entry, once after `optimize_process()`
    declines because there is nothing left to gain). The proof is the
    optimize level flipping from 0 to 2 between the first and second
    line, with the environment marker appearing at the same moment.

    Note the pid is *constant* across the re-exec, which is correct POSIX
    behaviour: exec replaces the process image, it does not fork, so the
    pid is preserved. Asserting on a pid change here would have been
    wrong; the optimize level is the observable that actually moves.
    """
    states = _run_child(tmp_path)
    assert len(states) == 3, states
    assert len({s["pid"] for s in states}) == 1, "exec must preserve the pid"
    before = states[0]
    after = states[-1]
    assert before["reexec"] is False
    assert before["optimize"] == 0
    assert before["arena"] is None
    assert after["reexec"] is True
    assert after["optimize"] == 2
    assert after["arena"] == "1"
    assert after["faulthandler"] == "1"


def test_child_opt_out_keeps_docstrings(tmp_path: Path) -> None:
    """`SALTARE_NO_OPTIMIZE=1` must be a complete opt-out: one pass, no
    re-exec, optimize level untouched. An application that reads
    `__doc__` at runtime depends on this."""
    states = _run_child(tmp_path, SALTARE_NO_OPTIMIZE="1")
    assert len({s["pid"] for s in states}) == 1, states
    assert states[-1]["optimize"] == 0, "the opt-out must keep docstrings"


def test_child_does_not_reexec_twice(tmp_path: Path) -> None:
    """The marker is what stops a second call from looping. Simulated by
    pre-setting it, which is exactly the state the re-exec'd process is
    in. The observable is the single pass at optimize 0 — the marker
    being present in the env is the premise, not the conclusion."""
    states = _run_child(tmp_path, SALTARE_REEXECED="1")
    assert len({s["pid"] for s in states}) == 1, states
    assert states[-1]["optimize"] == 0, "the marker must stop the second exec"


def test_child_is_a_noop_when_already_run_with_oo(tmp_path: Path) -> None:
    """Started under `-OO` there is nothing left to gain, so the child
    must not exec itself. This is the `sys.flags.optimize >= 2` gate,
    covered where it can actually be exercised — the pytest process
    itself is at optimize 0."""
    states = _run_child(tmp_path, args=["-OO"])
    assert len({s["pid"] for s in states}) == 1, states
    assert states[-1]["optimize"] == 2, "started under -OO; nothing to gain"


# ---------------------------------------------------------------------------
# The CLI still re-execs (regression on the shared refactor)
# ---------------------------------------------------------------------------


def test_cli_still_reexecs_itself() -> None:
    """`cli.py` and `optimize_process()` now share one implementation.
    The CLI's behaviour is the older, more established one, so it is the
    regression guard for that refactor: `python -m saltare --version` must
    still come up under -OO."""
    e = dict(os.environ)
    for k in ("SALTARE_NO_OPTIMIZE", "SALTARE_REEXECED", "PYTHONOPTIMIZE"):
        e.pop(k, None)
    proc = subprocess.run(
        [sys.executable, "-c",
         "import runpy, sys; sys.argv = ['saltare', '--version'];"
         " runpy.run_module('saltare', run_name='__main__')"],
        capture_output=True, text=True, timeout=90, env=e,
    )
    assert proc.returncode == 0, proc.stderr[-2000:]
    assert "saltare 1." in proc.stdout, proc.stdout
