"""Measure RSS for saltare and uvicorn under identical load.

Both servers run the same FastAPI app from `benchmarks.app`. For each:
  1. Spawn the server as a subprocess.
  2. Wait until it accepts connections.
  3. Read VmRSS / VmHWM from /proc/<pid>/status (idle baseline).
  4. Fire N sequential GET / requests with httpx (default keep-alive client).
  5. Read VmRSS / VmHWM again (post-load).
  6. Terminate the subprocess.

Sequential by design: in v0.3 saltare is single-threaded blocking, so a
concurrent benchmark would mostly measure queueing delay. Concurrent
load tests become meaningful starting at v0.4 (epoll/kqueue).
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import time
from dataclasses import dataclass

import httpx


@dataclass
class Sample:
    vm_rss_kib: int
    vm_hwm_kib: int
    vm_size_kib: int


def read_status(pid: int) -> Sample:
    rss = hwm = size = 0
    with open(f"/proc/{pid}/status") as f:
        for line in f:
            if line.startswith("VmRSS:"):
                rss = int(line.split()[1])
            elif line.startswith("VmHWM:"):
                hwm = int(line.split()[1])
            elif line.startswith("VmSize:"):
                size = int(line.split()[1])
    return Sample(rss, hwm, size)


def wait_ready(port: int, timeout: float = 5.0) -> None:
    deadline = time.monotonic() + timeout
    last_err: Exception | None = None
    while time.monotonic() < deadline:
        try:
            httpx.get(f"http://127.0.0.1:{port}/", timeout=0.5)
            return
        except (
            httpx.ConnectError,
            httpx.ReadTimeout,
            httpx.RemoteProtocolError,
        ) as e:
            last_err = e
            time.sleep(0.05)
    raise RuntimeError(
        f"server on port {port} never became ready: {last_err!r}"
    )


@dataclass
class Result:
    name: str
    idle: Sample
    after_load: Sample
    requests_completed: int
    elapsed_seconds: float


def run_benchmark(name: str, module: str, port: int, n_requests: int) -> Result:
    env = {**os.environ, "BENCH_PORT": str(port), "PYTHONUNBUFFERED": "1"}
    proc = subprocess.Popen(
        [sys.executable, "-m", module],
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        wait_ready(port)
        # Settle a moment so startup transients don't skew the idle reading.
        time.sleep(0.5)
        idle = read_status(proc.pid)

        completed = 0
        t0 = time.monotonic()
        with httpx.Client(timeout=5.0) as client:
            for _ in range(n_requests):
                r = client.get(f"http://127.0.0.1:{port}/")
                if r.status_code == 200:
                    completed += 1
        elapsed = time.monotonic() - t0

        time.sleep(0.3)
        after = read_status(proc.pid)
        return Result(name, idle, after, completed, elapsed)
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5.0)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()


def fmt_mib(kib: int) -> str:
    return f"{kib / 1024:.2f} MiB"


def render(results: list[Result]) -> None:
    print()
    print("# RAM benchmark — same FastAPI app, same Python interpreter, same load")
    print()
    print("| server  | idle RSS  | RSS after load | peak RSS  | reqs ok | rps   |")
    print("|---------|-----------|----------------|-----------|---------|-------|")
    for r in results:
        rps = r.requests_completed / r.elapsed_seconds if r.elapsed_seconds else 0.0
        print(
            f"| {r.name:<7s} | "
            f"{fmt_mib(r.idle.vm_rss_kib):>9s} | "
            f"{fmt_mib(r.after_load.vm_rss_kib):>14s} | "
            f"{fmt_mib(r.after_load.vm_hwm_kib):>9s} | "
            f"{r.requests_completed:>7d} | "
            f"{rps:>5.0f} |"
        )
    print()

    if len(results) >= 2:
        a, b = results[0], results[1]
        if b.after_load.vm_rss_kib:
            ratio = a.after_load.vm_rss_kib / b.after_load.vm_rss_kib
            delta_kib = b.after_load.vm_rss_kib - a.after_load.vm_rss_kib
            print(
                f"# {a.name} uses {ratio:.2f}x the RSS of {b.name} after load "
                f"(delta: {delta_kib / 1024:+.2f} MiB; "
                f"negative means {a.name} is leaner)"
            )
            print()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--requests", type=int, default=1000)
    args = parser.parse_args()

    print(f"\nN = {args.requests} sequential GET / requests per server\n")

    results = [
        run_benchmark(
            "saltare",
            module="benchmarks.run_saltare",
            port=18001,
            n_requests=args.requests,
        ),
        run_benchmark(
            "uvicorn",
            module="benchmarks.run_uvicorn",
            port=18002,
            n_requests=args.requests,
        ),
    ]

    render(results)


if __name__ == "__main__":
    main()
