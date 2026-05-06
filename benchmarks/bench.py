"""Measure RSS for saltare and uvicorn under identical load.

Three workloads:

  sequential:     1 client, N requests in a row. Measures the steady-state
                  RAM cost when there's never more than one connection alive.

  concurrent:     C clients × M requests each, fired in C OS threads. Each
                  client opens its own TCP connection. Measures peak RSS
                  while up to C connections are alive AND active at once.

  idle-keepalive: Open N connections, send one request on each, then leave
                  them all idle (open but quiet). Measures the per-connection
                  cost of *holding* a keep-alive connection. This is where
                  saltare's pooled read buffers vs uvicorn's Transport
                  allocations show the biggest contrast.

We poll /proc/<pid>/status every 10 ms to capture peaks rather than relying
on the post-load reading.
"""

from __future__ import annotations

import argparse
import os
import socket
import subprocess
import sys
import threading
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
    try:
        with open(f"/proc/{pid}/status") as f:
            for line in f:
                if line.startswith("VmRSS:"):
                    rss = int(line.split()[1])
                elif line.startswith("VmHWM:"):
                    hwm = int(line.split()[1])
                elif line.startswith("VmSize:"):
                    size = int(line.split()[1])
    except FileNotFoundError:
        pass
    return Sample(rss, hwm, size)


def read_pss_kib(pid: int) -> int:
    """Proportional Set Size for a single process, in KiB. Pss assigns
    each shared page proportionally to the processes mapping it, so
    Σ pss across a process tree is the real physical memory the tree
    uses (RSS would over-count CoW-shared pages N times)."""
    try:
        with open(f"/proc/{pid}/smaps_rollup") as f:
            for line in f:
                if line.startswith("Pss:"):
                    return int(line.split()[1])
    except FileNotFoundError:
        return 0
    return 0


def list_children(master_pid: int) -> list[int]:
    """Read the master's direct children from /proc. Used by the
    multi-worker workload to compute the cluster-wide Pss."""
    path = f"/proc/{master_pid}/task/{master_pid}/children"
    try:
        with open(path) as f:
            return [int(p) for p in f.read().split() if p]
    except FileNotFoundError:
        return []


def cluster_pss_kib(master_pid: int) -> tuple[int, int]:
    """Return (master_pss, sum_workers_pss) in KiB. Reading both
    separately lets us show the CoW-amortised cost: with healthy
    sharing, sum_workers ≪ N × master."""
    master = read_pss_kib(master_pid)
    workers = sum(read_pss_kib(c) for c in list_children(master_pid))
    return master, workers


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
    workload: str
    idle: Sample
    after_load: Sample
    peak_rss_kib: int
    requests_completed: int
    elapsed_seconds: float


def _spawn(module: str, port: int, workers: int = 1) -> subprocess.Popen:
    env = {
        **os.environ,
        "BENCH_PORT": str(port),
        "BENCH_WORKERS": str(workers),
        "PYTHONUNBUFFERED": "1",
    }
    return subprocess.Popen(
        [sys.executable, "-m", module],
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def _terminate(proc: subprocess.Popen) -> None:
    proc.terminate()
    try:
        proc.wait(timeout=5.0)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()


class _PeakSampler:
    """Polls /proc/PID/status while the load runs and records peak VmRSS."""

    def __init__(self, pid: int, interval: float = 0.01) -> None:
        self.pid = pid
        self.interval = interval
        self.peak_rss_kib = 0
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def __enter__(self) -> "_PeakSampler":
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()
        return self

    def __exit__(self, *_: object) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join()

    def _loop(self) -> None:
        while not self._stop.is_set():
            s = read_status(self.pid)
            if s.vm_rss_kib > self.peak_rss_kib:
                self.peak_rss_kib = s.vm_rss_kib
            time.sleep(self.interval)


def run_sequential(name: str, module: str, port: int, n_requests: int) -> Result:
    proc = _spawn(module, port)
    try:
        wait_ready(port)
        time.sleep(0.5)
        idle = read_status(proc.pid)

        completed = 0
        with _PeakSampler(proc.pid) as sampler:
            t0 = time.monotonic()
            with httpx.Client(timeout=5.0) as client:
                for _ in range(n_requests):
                    r = client.get(f"http://127.0.0.1:{port}/")
                    if r.status_code == 200:
                        completed += 1
            elapsed = time.monotonic() - t0

        time.sleep(0.3)
        after = read_status(proc.pid)
        peak = max(sampler.peak_rss_kib, after.vm_rss_kib, idle.vm_rss_kib)
        return Result(name, "sequential", idle, after, peak, completed, elapsed)
    finally:
        _terminate(proc)


def _drain_response(sock: socket.socket) -> None:
    """Read one full HTTP/1.1 response from a raw socket. Saltare and uvicorn
    both emit Content-Length, so we don't need to handle chunked here."""
    sock.settimeout(2.0)
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = sock.recv(4096)
        if not chunk:
            return
        buf += chunk
    head, _, rest = buf.partition(b"\r\n\r\n")
    cl = 0
    for line in head.split(b"\r\n"):
        if line.lower().startswith(b"content-length:"):
            cl = int(line.split(b":", 1)[1].strip())
            break
    while len(rest) < cl:
        chunk = sock.recv(4096)
        if not chunk:
            return
        rest += chunk


def run_idle_keepalive(name: str, module: str, port: int, n_idle: int) -> Result:
    proc = _spawn(module, port)
    try:
        wait_ready(port)
        time.sleep(0.5)
        idle = read_status(proc.pid)

        sockets: list[socket.socket] = []
        try:
            t0 = time.monotonic()
            for _ in range(n_idle):
                s = socket.create_connection(("127.0.0.1", port), timeout=5.0)
                # HTTP/1.1 with no Connection header → keep-alive.
                s.sendall(b"GET / HTTP/1.1\r\nHost: x\r\n\r\n")
                _drain_response(s)
                sockets.append(s)
            elapsed = time.monotonic() - t0

            # Let the server fully transition to "all keep-alive idle".
            time.sleep(0.5)

            with _PeakSampler(proc.pid) as sampler:
                # Observe RSS for a full second while everything is idle.
                time.sleep(1.0)
                snapshot = read_status(proc.pid)
        finally:
            for s in sockets:
                try:
                    s.close()
                except OSError:
                    pass

        peak = max(sampler.peak_rss_kib, snapshot.vm_rss_kib, idle.vm_rss_kib)
        return Result(name, "idle-keepalive", idle, snapshot, peak, n_idle, elapsed)
    finally:
        _terminate(proc)


def run_concurrent(
    name: str,
    module: str,
    port: int,
    concurrency: int,
    requests_per_client: int,
) -> Result:
    proc = _spawn(module, port)
    try:
        wait_ready(port)
        time.sleep(0.5)
        idle = read_status(proc.pid)

        completed = 0
        completed_lock = threading.Lock()

        def hit() -> None:
            local_completed = 0
            with httpx.Client(timeout=10.0) as client:
                for _ in range(requests_per_client):
                    r = client.get(f"http://127.0.0.1:{port}/")
                    if r.status_code == 200:
                        local_completed += 1
            with completed_lock:
                nonlocal completed
                completed += local_completed

        with _PeakSampler(proc.pid) as sampler:
            threads = [threading.Thread(target=hit) for _ in range(concurrency)]
            t0 = time.monotonic()
            for t in threads:
                t.start()
            for t in threads:
                t.join()
            elapsed = time.monotonic() - t0

        time.sleep(0.3)
        after = read_status(proc.pid)
        peak = max(sampler.peak_rss_kib, after.vm_rss_kib, idle.vm_rss_kib)
        return Result(name, "concurrent", idle, after, peak, completed, elapsed)
    finally:
        _terminate(proc)


def fmt_mib(kib: int) -> str:
    return f"{kib / 1024:.2f} MiB"


@dataclass
class MultiWorkerSample:
    workers: int
    master_pss_kib: int
    workers_pss_kib: int
    n_workers_observed: int

    @property
    def total_pss_kib(self) -> int:
        return self.master_pss_kib + self.workers_pss_kib


def run_multi_worker_pss(workers: int, port: int = 18004) -> MultiWorkerSample:
    """Spawn saltare with `workers` pre-fork workers, hold a probe
    connection open, and read Pss across master + every worker. Pss
    proportionally accounts for shared CoW pages, so the total reflects
    the real RAM cost of the cluster — not N × the floor."""
    proc = _spawn("benchmarks.run_saltare", port, workers=workers)
    try:
        wait_ready(port)
        # Give the master time to fork all workers and let the kernel
        # populate /proc/<pid>/smaps_rollup for everyone.
        deadline = time.monotonic() + 3.0
        observed = 0
        while time.monotonic() < deadline:
            observed = len(list_children(proc.pid))
            if observed >= workers:
                break
            time.sleep(0.05)
        # One held-open connection so the workers' accept loops are
        # fully warm and any first-request transient state has been
        # touched. We don't actually send a request — we want the
        # idle-cluster footprint.
        with socket.create_connection(("127.0.0.1", port), timeout=2.0) as s:
            # Hold the conn briefly so smaps stabilises.
            time.sleep(0.5)
            s.close()
        # Final stabilisation pause.
        time.sleep(0.5)
        master_pss, workers_pss = cluster_pss_kib(proc.pid)
        return MultiWorkerSample(
            workers=workers,
            master_pss_kib=master_pss,
            workers_pss_kib=workers_pss,
            n_workers_observed=observed,
        )
    finally:
        _terminate(proc)


def render_multi_worker(samples: list[MultiWorkerSample]) -> None:
    if not samples:
        return
    print("## workload: multi-worker idle (Pss = real physical RAM)")
    print()
    print("| workers | observed | master Pss | sum workers Pss | total Pss | vs naive N× single |")
    print("|---------|----------|------------|-----------------|-----------|--------------------|")
    baseline = next((s for s in samples if s.workers == 1), None)
    for s in samples:
        # The naive comparison: how much RAM the cluster would need if
        # every worker was a fresh independent process (no CoW). Using
        # the workers=1 Pss as the per-process cost. workers=1 itself
        # has no comparison — it IS the baseline.
        if baseline and s.workers > 1 and baseline.total_pss_kib > 0:
            naive_kib = baseline.total_pss_kib * s.workers
            savings_pct = (1 - s.total_pss_kib / naive_kib) * 100
            naive_col = f"{fmt_mib(naive_kib)} (-{savings_pct:.0f}%)"
        else:
            naive_col = "—"
        print(
            f"| {s.workers:>7d} | {s.n_workers_observed:>8d} "
            f"| {fmt_mib(s.master_pss_kib):>10s} "
            f"| {fmt_mib(s.workers_pss_kib):>15s} "
            f"| {fmt_mib(s.total_pss_kib):>9s} "
            f"| {naive_col:>18s} |"
        )
    print()
    if baseline and len(samples) >= 2:
        for s in samples:
            if s.workers <= 1:
                continue
            extra = (s.total_pss_kib - baseline.total_pss_kib) / max(
                s.workers - 1, 1
            )
            print(
                f"  Extra physical RAM per worker beyond the first "
                f"({s.workers} workers): {extra / 1024:+.2f} MiB"
            )
        print()


def render(results: list[Result]) -> None:
    print()
    grouped: dict[str, list[Result]] = {}
    for r in results:
        grouped.setdefault(r.workload, []).append(r)

    for workload, items in grouped.items():
        print(f"## workload: {workload}")
        print()
        print("| server  | idle RSS  | RSS after load | peak RSS  | reqs ok | rps   |")
        print("|---------|-----------|----------------|-----------|---------|-------|")
        for r in items:
            rps = r.requests_completed / r.elapsed_seconds if r.elapsed_seconds else 0.0
            print(
                f"| {r.name:<7s} | "
                f"{fmt_mib(r.idle.vm_rss_kib):>9s} | "
                f"{fmt_mib(r.after_load.vm_rss_kib):>14s} | "
                f"{fmt_mib(r.peak_rss_kib):>9s} | "
                f"{r.requests_completed:>7d} | "
                f"{rps:>5.0f} |"
            )
        print()

        if len(items) >= 2:
            a, b = items[0], items[1]
            if b.peak_rss_kib:
                ratio = a.peak_rss_kib / b.peak_rss_kib
                delta_kib = b.peak_rss_kib - a.peak_rss_kib
                print(
                    f"  {a.name}/{b.name} peak ratio: {ratio:.2f}x "
                    f"(delta: {delta_kib / 1024:+.2f} MiB; "
                    f"negative means {a.name} is leaner)"
                )
                print()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--requests", type=int, default=1000,
                        help="sequential request count")
    parser.add_argument("--concurrency", type=int, default=100,
                        help="parallel clients in the concurrent workload")
    parser.add_argument("--per-client", type=int, default=20,
                        help="requests per client in the concurrent workload")
    parser.add_argument("--idle-connections", type=int, default=500,
                        help="connections held open in the idle-keepalive workload")
    parser.add_argument("--multi-worker-counts", type=str, default="1,4",
                        help="comma-separated worker counts to measure Pss for")
    args = parser.parse_args()

    worker_counts = [int(x) for x in args.multi_worker_counts.split(",") if x]

    print(f"\nsequential:     {args.requests} requests / 1 client")
    print(f"concurrent:     {args.concurrency} clients × {args.per_client} requests")
    print(f"idle-keepalive: {args.idle_connections} keep-alive connections held open")
    print(f"multi-worker:   Pss footprint with {worker_counts} workers\n")

    results: list[Result] = []
    for name, module in (("saltare", "benchmarks.run_saltare"),
                         ("uvicorn", "benchmarks.run_uvicorn")):
        results.append(run_sequential(
            name, module, port=18001, n_requests=args.requests,
        ))
    for name, module in (("saltare", "benchmarks.run_saltare"),
                         ("uvicorn", "benchmarks.run_uvicorn")):
        results.append(run_concurrent(
            name, module, port=18002,
            concurrency=args.concurrency,
            requests_per_client=args.per_client,
        ))
    for name, module in (("saltare", "benchmarks.run_saltare"),
                         ("uvicorn", "benchmarks.run_uvicorn")):
        results.append(run_idle_keepalive(
            name, module, port=18003,
            n_idle=args.idle_connections,
        ))

    render(results)

    # Multi-worker Pss measurement only makes sense for saltare (uvicorn's
    # --workers spawns multiprocessing children with a different sharing
    # profile; out of scope for v1.1's "did our pre-fork CoW work?" check).
    multi_samples: list[MultiWorkerSample] = []
    for n in worker_counts:
        if n < 1:
            continue
        multi_samples.append(run_multi_worker_pss(workers=n, port=18004 + n))
    render_multi_worker(multi_samples)


if __name__ == "__main__":
    main()
