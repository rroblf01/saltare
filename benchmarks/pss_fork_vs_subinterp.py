"""PSS comparison: pre-fork workers vs own-GIL sub-interpreter workers.

This is the measurement that settled the v1.11 PEP 684 question. The
hypothesis was that hosting `workers>1` as own-GIL sub-interpreters (one
process, N interpreters) would save per-worker RAM versus pre-fork (N OS
processes). The data refuted it: fork is 1.4x-2.6x leaner and the gap
widens with N, because saltare already calls `gc.freeze()` before forking
(so CoW keeps the shared object graph un-dirtied), while sub-interpreters
cannot share the Python heap at all and re-import everything per worker.

Run (needs a built `_core` and CPython 3.13+ for `concurrent.interpreters`):

    python -m benchmarks.pss_fork_vs_subinterp 4

It prints the total Pss (KiB) for both models at the given worker count,
plus the single-process baseline. Pss (proportional set size) divides each
shared page by the number of sharers, so it is the fair way to compare a
CoW process tree against a single multi-interpreter process.
"""

from __future__ import annotations

import os
import sys
import threading
import time

# A trivial ASGI app — the per-worker cost we care about is the imported
# module heap (saltare + asyncio + the app), not request handling.
_APP = """
import saltare
async def app(scope, receive, send):
    if scope["type"] == "lifespan":
        while True:
            m = await receive()
            if m["type"] == "lifespan.startup":
                await send({"type": "lifespan.startup.complete"})
            elif m["type"] == "lifespan.shutdown":
                await send({"type": "lifespan.shutdown.complete"})
                return
        return
    await send({"type": "http.response.start", "status": 200, "headers": []})
    await send({"type": "http.response.body", "body": b"x"})
"""


def _pss_kb(pid: int) -> int:
    try:
        with open(f"/proc/{pid}/smaps_rollup") as f:
            for line in f:
                if line.startswith("Pss:"):
                    return int(line.split()[1])
    except OSError:
        return 0
    return 0


def _tree_pss_kb(root: int) -> int:
    """Pss of `root` plus every descendant process."""
    total = _pss_kb(root)
    try:
        entries = os.listdir("/proc")
    except OSError:
        return total
    for pid in entries:
        if not pid.isdigit():
            continue
        try:
            with open(f"/proc/{pid}/stat") as f:
                data = f.read()
            # comm is parenthesised and may contain spaces; fields after the
            # closing paren are: state, ppid, ...
            after = data[data.rfind(")") + 1:].split()
            ppid = int(after[1])
        except (OSError, IndexError, ValueError):
            continue
        if ppid == root:
            total += _tree_pss_kb(int(pid))
    return total


def measure_baseline() -> int:
    ns: dict = {}
    exec(_APP, ns)  # noqa: S102 - controlled literal above
    time.sleep(0.3)
    return _pss_kb(os.getpid())


def measure_subinterp(n: int) -> int:
    from concurrent import interpreters

    import saltare._core as core

    threads = []
    interps = []
    for i in range(n):
        ip = interpreters.create()
        interps.append(ip)
        script = _APP + f'\nsaltare.run(app, host="127.0.0.1", port={18000 + i}, workers=1)\n'
        t = threading.Thread(target=lambda s=script, p=ip: p.exec(s), daemon=True)
        t.start()
        threads.append(t)
    time.sleep(2.0)
    total = _tree_pss_kb(os.getpid())
    core.request_shutdown()
    for t in threads:
        t.join(timeout=5)
    for ip in interps:
        try:
            ip.close()
        except Exception:  # noqa: BLE001 - best-effort teardown
            pass
    return total


def measure_fork(n: int) -> int:
    import saltare
    import saltare._core as core

    ns: dict = {}
    exec(_APP, ns)  # noqa: S102

    th = threading.Thread(
        target=lambda: saltare.run(ns["app"], host="127.0.0.1", port=19000, workers=n),
        daemon=True,
    )
    th.start()
    time.sleep(2.5)
    total = _tree_pss_kb(os.getpid())
    core.request_shutdown()
    th.join(timeout=5)
    return total


def main() -> None:
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 4
    print(f"baseline (1 process):        {measure_baseline():>8} KiB")
    print(f"fork ({n} workers, CoW):       {measure_fork(n):>8} KiB")
    print(f"sub-interpreter ({n} workers): {measure_subinterp(n):>8} KiB")


if __name__ == "__main__":
    main()
