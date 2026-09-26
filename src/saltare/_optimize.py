"""Process-level RAM posture: re-exec under `python -OO`.

Kept in its own module, with no import-time side effects, because two
very different callers need it and they must not interfere:

  - `saltare.cli` calls `_reexec_if_wanted()` at import time, gated on
    argv so it only fires for a real `saltare` CLI invocation.
  - `saltare.optimize_process()` is the explicit opt-in for people who
    embed the server in their own script.

Having the logic here rather than in `cli.py` is what makes the second
caller possible: `saltare/__init__.py` re-exports the public function, and
importing that must not drag in `cli.py` (whose module body re-execs).

Why this is worth 1.4 MiB. Measured on a FastAPI app, a running saltare
server sits at 49.61 MiB RSS; the same app under `-OO` with
`MALLOC_ARENA_MAX=1` sits at 48.20. CPython discards every docstring and
`assert` under `-OO`, and FastAPI, Starlette and pydantic carry a lot of
them. For a server whose entire pitch is minimum RAM that is 2.8% of the
floor for free, but it only happens if the process is *started* with the
flag — `mallopt()` in `PyInit__core` cannot undo docstrings that are
already resident.

The arena half is belt-and-braces. `PyInit__core` already calls
`mallopt(M_ARENA_MAX, 1)`, which bounds arenas created from that point on;
setting the environment variable additionally covers the allocations
CPython makes during its own bootstrap, before any extension is imported.
"""

from __future__ import annotations

import os
import sys

#: Set in the re-exec'd environment so a second call cannot loop.
_REEXEC_MARKER = "SALTARE_REEXECED"

#: User-facing escape hatch. Some applications read `__doc__` at runtime,
#: or ship their own `-O`-sensitive asserts, and must keep docstrings.
_OPT_OUT_ENV = "SALTARE_NO_OPTIMIZE"

_TRUTHY = frozenset({"1", "true", "yes", "on"})


def already_optimized() -> bool:
    """True when the process is already running with the RAM posture we
    want, so a re-exec would be pointless or would loop."""
    if sys.flags.optimize >= 2:
        return True
    if os.environ.get(_REEXEC_MARKER) == "1":
        return True
    return os.environ.get(_OPT_OUT_ENV, "").lower() in _TRUTHY


def optimized_env() -> dict[str, str]:
    """The environment for the re-exec'd process.

    Uses `setdefault` for the two that are preferences rather than
    requirements: an operator who deliberately set `MALLOC_ARENA_MAX=2`
    for a threaded deployment should keep it, and `PYTHONFAULTHANDLER` is
    a debugging aid an operator may have opinions about. `PYTHONOPTIMIZE`
    is a plain assignment because that is the entire point of the re-exec.
    """
    env = os.environ.copy()
    env[_REEXEC_MARKER] = "1"
    env["PYTHONOPTIMIZE"] = "2"
    # Bound glibc's per-thread arenas before CPython makes its first
    # allocation. Doing it here beats calling mallopt() mid-process,
    # because the bootstrap allocations stay in one arena too.
    env.setdefault("MALLOC_ARENA_MAX", "1")
    # Free, and it turns a segfault in a native extension from a silent
    # death into a stack trace on stderr.
    env.setdefault("PYTHONFAULTHANDLER", "1")
    return env


def can_reexec_interactive() -> bool:
    """False when there is no script on disk to re-run.

    A re-exec restarts the process from `argv`. Under `python -c ...`,
    `python -` (stdin) or an interactive REPL, `sys.argv[0]` is not a
    re-runnable file — re-execing would either fail or drop the user into
    a fresh interpreter, losing their session. Callers check this and
    decline rather than doing something surprising.
    """
    argv0 = sys.argv[0] if sys.argv else ""
    if not argv0 or argv0.startswith("-"):
        return False
    if not os.path.isfile(argv0):
        return False
    return True


def _reexec_if_wanted(argv: list[str]) -> None:
    """Replace this process with `python -OO <argv>`. Returns only if it
    declined or if exec failed."""
    if already_optimized():
        return
    os.execvpe(sys.executable, [sys.executable, "-OO"] + argv, optimized_env())
