"""saltare launcher used by the bench harness. Reads `BENCH_PORT` and
`BENCH_WORKERS` (default 1) from the env so the harness can request
either single-worker or multi-worker mode without forking the script."""

import os

from benchmarks.app import app
from saltare import run


def main() -> None:
    port = int(os.environ.get("BENCH_PORT", "8000"))
    workers = int(os.environ.get("BENCH_WORKERS", "1"))
    run(app, host="127.0.0.1", port=port, workers=workers)


if __name__ == "__main__":
    main()
