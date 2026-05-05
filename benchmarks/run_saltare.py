"""Single-worker saltare launcher used by the bench harness."""

import os

from benchmarks.app import app
from saltare import run


def main() -> None:
    port = int(os.environ.get("BENCH_PORT", "8000"))
    run(app, host="127.0.0.1", port=port)


if __name__ == "__main__":
    main()
