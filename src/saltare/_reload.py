"""Auto-reload supervisor for development.

Lifecycle:
  - Parent (this module) spawns a saltare child (`sys.executable` +
    `sys.argv` with `_SALTARE_RELOAD_CHILD=1` in env).
  - Parent polls the configured watch dirs for mtime / set changes
    every `poll_interval` seconds.
  - Detected change → SIGTERM the child (graceful drain via the
    same SIGTERM path operators use in production), wait, respawn.

We deliberately ship a poll-based watcher (no `inotify` dependency)
so the wheel keeps zero runtime extras and the watcher works inside
containers / on filesystems where inotify isn't propagated (overlayfs,
9p, NFS). Default poll interval (0.5 s) is small enough that edits
feel instant in a normal IDE flow but cheap enough to ignore — the
walk over a typical project (a few hundred .py files) takes < 1 ms.

Reload is dev-only. Production should run without `--reload` and
let your supervisor (systemd, k8s) handle restart.
"""

from __future__ import annotations

import fnmatch
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

_RELOAD_ENV_FLAG = "_SALTARE_RELOAD_CHILD"
_DEFAULT_POLL_SECS = 0.5
_DEFAULT_INCLUDES: tuple[str, ...] = ("*.py",)
# Common transient / generated paths we never want to reload on.
_DEFAULT_EXCLUDES: tuple[str, ...] = (
    "*/.git/*",
    "*/__pycache__/*",
    "*.pyc",
    "*.pyo",
    "*/.venv/*",
    "*/venv/*",
    "*/node_modules/*",
    "*/.mypy_cache/*",
    "*/.pytest_cache/*",
    "*/.ruff_cache/*",
)


def is_reload_child() -> bool:
    """True when the current process was spawned by the reload supervisor.
    Used by `saltare.run()` to short-circuit the "supervise" branch on
    the second invocation (in the child) so we just run the server."""
    return os.environ.get(_RELOAD_ENV_FLAG) == "1"


def _matches(path: str, patterns: tuple[str, ...]) -> bool:
    return any(fnmatch.fnmatch(path, pat) for pat in patterns)


def _snapshot(
    dirs: tuple[str, ...],
    includes: tuple[str, ...],
    excludes: tuple[str, ...],
) -> dict[str, int]:
    """Walk `dirs`, return {path: mtime_ns} for every file that
    matches `includes` and not `excludes`. Used to detect changes
    by simple dict comparison between consecutive ticks."""
    snap: dict[str, int] = {}
    for d in dirs:
        root = Path(d).resolve()
        if not root.exists():
            continue
        for path in root.rglob("*"):
            if not path.is_file():
                continue
            spath = str(path)
            if not _matches(spath, includes):
                continue
            if _matches(spath, excludes):
                continue
            try:
                snap[spath] = path.stat().st_mtime_ns
            except OSError:
                # File may have vanished mid-walk (rename storms during
                # `git checkout`). Skip; next tick will pick it up.
                continue
    return snap


def _diff(old: dict[str, int], new: dict[str, int]) -> list[str]:
    """List files that changed between two snapshots."""
    out = [p for p in new if new[p] != old.get(p)]
    out.extend(p for p in old if p not in new)
    return out


def _purge_pycache(dirs: tuple[str, ...]) -> None:
    """Delete `__pycache__` directories under each watched root.

    Why: PYTHONOPTIMIZE=2 (saltare's default re-exec) writes
    `.opt-2.pyc` keyed by *second-resolution* source mtime. An edit
    within 1 s of the first import leaves the cached pyc with the
    same mtime stamp as the edited source — Python serves the stale
    bytecode. Blowing away the cache before respawn guarantees the
    new child compiles from disk, which is what the user wanted when
    they hit save."""
    import shutil
    for d in dirs:
        root = Path(d).resolve()
        if not root.exists():
            continue
        for cache in root.rglob("__pycache__"):
            try:
                shutil.rmtree(cache, ignore_errors=True)
            except OSError:
                pass


def _spawn(env: dict[str, str]) -> subprocess.Popen[bytes]:
    """Re-exec saltare with the same argv. The child sees the env flag
    and runs the actual server."""
    return subprocess.Popen([sys.executable, *sys.argv], env=env)


def _terminate(child: subprocess.Popen[bytes], grace_secs: float = 5.0) -> None:
    """SIGTERM the child + wait. SIGKILL if it doesn't exit in `grace_secs`.
    Mirrors the saltare-in-prod shutdown pattern: signal → drain →
    fall back to force-kill."""
    if child.poll() is not None:
        return
    try:
        child.send_signal(signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        child.wait(timeout=grace_secs)
    except subprocess.TimeoutExpired:
        sys.stderr.write(
            f"saltare reload: child {child.pid} did not exit in "
            f"{grace_secs}s; SIGKILL\n"
        )
        try:
            child.kill()
        except ProcessLookupError:
            pass
        try:
            child.wait(timeout=2.0)
        except subprocess.TimeoutExpired:
            pass


def supervise(
    reload_dirs: tuple[str, ...] = (".",),
    includes: tuple[str, ...] = _DEFAULT_INCLUDES,
    excludes: tuple[str, ...] = _DEFAULT_EXCLUDES,
    poll_secs: float = _DEFAULT_POLL_SECS,
) -> int:
    """Parent reload loop. Returns the child's last exit code on a
    clean parent shutdown (Ctrl-C / SIGTERM). Never returns under
    normal use — the child is what serves traffic."""
    env = os.environ.copy()
    env[_RELOAD_ENV_FLAG] = "1"
    snap = _snapshot(reload_dirs, includes, excludes)
    sys.stderr.write(
        f"saltare reload: watching {len(snap)} file(s) under "
        f"{', '.join(reload_dirs)} (poll {poll_secs}s)\n"
    )
    child = _spawn(env)

    # Forward SIGTERM (systemd / docker / k8s graceful shutdown) to the
    # child so the dev-mode supervisor exits the same way prod does.
    # Without this the parent dies mid-loop and orphans the child;
    # PID-1 cleanup in containers usually catches it but the shutdown
    # path is racy and the access-log line for the in-flight request
    # never makes it to stderr. The handler raises KeyboardInterrupt
    # so we share the cleanup code path with Ctrl-C.
    def _on_sigterm(_signum: int, _frame: object) -> None:
        raise KeyboardInterrupt
    try:
        signal.signal(signal.SIGTERM, _on_sigterm)
    except (ValueError, OSError):
        # Non-main thread or unsupported on this platform — best effort.
        pass

    last_exit = 0
    try:
        while True:
            time.sleep(poll_secs)
            if child.poll() is not None:
                last_exit = child.returncode
                if last_exit not in (0, -signal.SIGTERM, -signal.SIGINT):
                    sys.stderr.write(
                        f"saltare reload: child exited with code {last_exit}; "
                        f"waiting for next file change to retry\n"
                    )
                    # Wait for a code change before respawning so a
                    # syntax-error crash doesn't restart-loop the screen.
                    while True:
                        time.sleep(poll_secs)
                        new_snap = _snapshot(reload_dirs, includes, excludes)
                        if _diff(snap, new_snap):
                            snap = new_snap
                            break
                _purge_pycache(reload_dirs)
                child = _spawn(env)
                continue
            new_snap = _snapshot(reload_dirs, includes, excludes)
            changed = _diff(snap, new_snap)
            if changed:
                head = changed[:3]
                tail = "" if len(changed) <= 3 else f" (+{len(changed) - 3} more)"
                sys.stderr.write(
                    f"saltare reload: change detected in "
                    f"{', '.join(os.path.basename(p) for p in head)}{tail}; "
                    f"restarting\n"
                )
                _terminate(child)
                _purge_pycache(reload_dirs)
                child = _spawn(env)
                snap = new_snap
    except KeyboardInterrupt:
        sys.stderr.write("saltare reload: shutting down\n")
        _terminate(child)
        return last_exit
    finally:
        # Belt and braces — always clean up the child on exit.
        if child.poll() is None:
            _terminate(child)
