"""Long-form soak: bombard a saltare worker for `--duration` seconds at
`--rps`, sample RSS every 5 s, fail on excessive drift.

Designed to catch slow leaks the regular bench can't see. The 1000-request
short bench misses anything under 1 KiB/req leak rate; this loop runs
hundreds of thousands of requests so a 100-byte/req leak drifts visibly.

Drift gate: RSS at minute 5 is the baseline; anything more than +20 MiB
above baseline by the end is a fail. Inflated baseline tolerates the
first-load Python heap settling.

Usage (typical pre-tag):
    python -m benchmarks.soak --duration=1800 --rps=200

Override via Makefile:
    make soak SOAK_SECS=3600 SOAK_RPS=500
"""

from __future__ import annotations

import argparse
import os
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.request


def _proc_rss_kib(pid: int) -> int:
    try:
        with open(f"/proc/{pid}/status") as f:
            for line in f:
                if line.startswith("VmRSS:"):
                    return int(line.split()[1])
    except OSError:
        pass
    return 0


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _drive(port: int, rps: int, stop: threading.Event) -> None:
    interval = 1.0 / rps if rps > 0 else 0.0
    url = f"http://127.0.0.1:{port}/"
    sent = 0
    err = 0
    next_tick = time.monotonic()
    while not stop.is_set():
        try:
            with urllib.request.urlopen(url, timeout=2.0) as r:
                r.read()
            sent += 1
        except Exception:
            err += 1
        next_tick += interval
        delay = next_tick - time.monotonic()
        if delay > 0:
            time.sleep(delay)
    print(f"soak driver: sent={sent} errors={err}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--duration", type=int, default=1800,
                    help="seconds of sustained load (default 1800 = 30 min)")
    ap.add_argument("--rps", type=int, default=200,
                    help="requests per second from the driver")
    ap.add_argument("--drift-mib", type=int, default=20,
                    help="post-warmup RSS drift threshold (MiB; fail above)")
    ap.add_argument("--warmup-secs", type=int, default=300,
                    help="seconds before fixing the baseline RSS")
    args = ap.parse_args()

    port = _free_port()
    proc = subprocess.Popen(
        [sys.executable, "-m", "benchmarks.run_saltare"],
        env={**os.environ, "BENCH_PORT": str(port), "BENCH_WORKERS": "1"},
        stdout=subprocess.DEVNULL, stderr=sys.stderr,
    )

    try:
        # Wait for listen.
        for _ in range(40):
            try:
                with socket.socket() as s:
                    s.settimeout(0.25)
                    s.connect(("127.0.0.1", port))
                    break
            except (ConnectionRefusedError, socket.timeout, OSError):
                time.sleep(0.25)
        else:
            print("saltare never bound", file=sys.stderr)
            return 1

        stop = threading.Event()
        driver = threading.Thread(target=_drive, args=(port, args.rps, stop), daemon=True)
        driver.start()

        start = time.monotonic()
        baseline_kib = 0
        peak_kib = 0
        while True:
            elapsed = time.monotonic() - start
            if elapsed >= args.duration:
                break
            rss_kib = _proc_rss_kib(proc.pid)
            peak_kib = max(peak_kib, rss_kib)
            if elapsed >= args.warmup_secs and baseline_kib == 0:
                baseline_kib = rss_kib
                print(f"soak baseline at +{int(elapsed)}s: {baseline_kib / 1024:.2f} MiB")
            print(f"  +{int(elapsed):4d}s  rss={rss_kib / 1024:.2f} MiB  peak={peak_kib / 1024:.2f} MiB")
            time.sleep(5)

        stop.set()
        driver.join(timeout=5)

        # Sanity: did we ever set the baseline? If duration < warmup,
        # fall back to peak as a coarse proxy.
        if baseline_kib == 0:
            baseline_kib = peak_kib
        drift_mib = (peak_kib - baseline_kib) / 1024
        print(f"soak summary: baseline={baseline_kib / 1024:.2f} MiB  "
              f"peak={peak_kib / 1024:.2f} MiB  drift={drift_mib:+.2f} MiB  "
              f"threshold={args.drift_mib} MiB")
        if drift_mib > args.drift_mib:
            print("FAIL: RSS drift exceeded threshold", file=sys.stderr)
            return 1
        print("OK")
        return 0
    finally:
        proc.send_signal(signal.SIGTERM)
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()


if __name__ == "__main__":
    sys.exit(main())
