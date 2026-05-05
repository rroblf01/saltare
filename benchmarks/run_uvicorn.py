"""Single-worker uvicorn launcher used by the bench harness."""

import os

import uvicorn

from benchmarks.app import app


def main() -> None:
    port = int(os.environ.get("BENCH_PORT", "8000"))
    uvicorn.run(app, host="127.0.0.1", port=port, log_level="warning")


if __name__ == "__main__":
    main()
