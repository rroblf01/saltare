"""Single-worker Granian launcher used by the bench harness.

Granian (Rust + Python ASGI server, https://github.com/emmett-framework/granian)
is the closest peer to saltare in design — Rust I/O loop driving a Python
ASGI app. Useful as a third reference point alongside uvicorn so the
saltare-vs-uvicorn comparison isn't taken in isolation.

Granian is an optional dep; the harness only invokes this launcher when
`benchmarks.bench` is run with `--include-granian` (and granian is
installed in the bench image — see Dockerfile bench stage).
"""

import os

# Import FastAPI app at the launcher's module level so the bench harness
# (which reads RSS from this process — granian's master) sees the same
# FastAPI/pydantic footprint that saltare's single-process serve carries.
# Without this, the master is a tiny supervisor (~37 MiB) and the worker
# subprocess (where the app actually runs) is the real comparison point.
# Keep it simple: load it here so RSS reads are apples-to-apples.
from benchmarks.app import app as _app  # noqa: F401


def main() -> None:
    # Imported lazily so the bench harness can detect "granian not
    # installed" via subprocess exit rather than crashing at import time.
    from granian import Granian
    from granian.constants import Interfaces

    port = int(os.environ.get("BENCH_PORT", "8000"))
    Granian(
        target="benchmarks.app:app",
        address="127.0.0.1",
        port=port,
        interface=Interfaces.ASGI,
        workers=int(os.environ.get("BENCH_WORKERS", "1")),
        log_level="warning",
    ).serve()


if __name__ == "__main__":
    main()
