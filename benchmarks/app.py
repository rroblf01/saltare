"""Identical FastAPI app for both saltare and uvicorn benchmarks.

Endpoints:
  /            — tiny JSON response (~30 B). The reference workload.
  /large       — fixed-size JSON response. Size controlled by env var
                 BENCH_LARGE_BYTES (default 100 KiB). Used by the
                 `large-response` workload to stress per-response RAM.
"""

from __future__ import annotations

import os

from fastapi import FastAPI
from fastapi.responses import PlainTextResponse

app = FastAPI()

_LARGE_BYTES = int(os.environ.get("BENCH_LARGE_BYTES", str(100 * 1024)))
# Pre-built once at import time so the response path is just a memcpy
# (matches what a real serializer would do under cache-hit conditions).
_LARGE_PAYLOAD = ("a" * _LARGE_BYTES).encode("ascii")


@app.get("/")
def root() -> dict[str, str]:
    return {"hello": "world"}


@app.get("/large", response_class=PlainTextResponse)
def large() -> bytes:
    return _LARGE_PAYLOAD
