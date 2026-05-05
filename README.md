# saltare

Low-RAM ASGI HTTP server with a **Zig backbone**. An alternative to uvicorn for FastAPI deployments where memory budget matters more than raw throughput.

> **Status: pre-alpha (v0.1.0).** The build pipeline (Zig → Python C extension → wheel) is wired end-to-end. The server itself currently returns a fixed stub response — the HTTP/1.1 parser and ASGI dispatcher land in the next milestones.

---

## Why

uvicorn is fast and battle-tested, but a typical worker (Python + asyncio + FastAPI + your code) sits around 60–90 MB resident before the first request. A meaningful chunk is asyncio bookkeeping: Transport/Protocol/Task/Future objects per connection, plus Python `bytes` buffers.

saltare keeps these in Zig:

| Layer                | uvicorn               | saltare                     |
| -------------------- | --------------------- | --------------------------- |
| Event loop           | asyncio (Python)      | epoll / kqueue (Zig)        |
| Socket I/O           | asyncio Transport     | direct `read`/`write` (Zig) |
| HTTP/1.1 parser      | `httptools` (C)       | hand-rolled (Zig)           |
| Per-connection state | Python objects (~KB)  | Zig structs (~hundreds B)   |
| ASGI app callable    | Python                | Python (unchanged)          |

Python only wakes up to dispatch a request to the user's ASGI app.

## Architecture

```
                          PyInit__core
                               │
        ┌──────────────────────┴──────────────────────┐
        │                                             │
   [ Python ]                                    [ Zig core ]
   saltare.run(app)        ─── _core.serve ───►  bind / listen
   saltare CLI                                   accept loop
                                                 HTTP/1.1 parser   ── TODO
                                                 ASGI bridge       ── TODO
                                                 │
                          dispatch_request ◄─────┘
   app(scope, receive, send) ─────────────────►  send()/receive()
                                                 awaitables backed
                                                 by Zig sockets
```

## Benchmarks

Run with `make bench` (Docker; no Zig or Python needed on the host). The harness boots each server with the same FastAPI app, takes a `/proc/<pid>/status` reading at idle, drives a load with `httpx`, and samples VmRSS every 10 ms during the load to capture peaks.

Results on Apple Silicon (manylinux_2_28_aarch64, CPython 3.14, FastAPI 0.115+, uvicorn 0.46 plain — no `[standard]` extras), v0.6.0:

### Sequential — 1 client, 1000 requests

| server  | idle RSS  | RSS after load | peak RSS  | reqs ok | rps  |
|---------|-----------|----------------|-----------|---------|------|
| saltare | 43.87 MiB |      43.87 MiB | 43.88 MiB |    1000 | 2599 |
| uvicorn | 44.00 MiB |      44.04 MiB | 44.04 MiB |    1000 | 2889 |

### Concurrent — 100 clients × 20 requests (2000 total)

| server  | idle RSS  | RSS after load | peak RSS  | reqs ok | rps  |
|---------|-----------|----------------|-----------|---------|------|
| saltare | 40.49 MiB |      40.55 MiB | 40.55 MiB |    2000 | 3840 |
| uvicorn | 44.04 MiB |      44.48 MiB | 44.48 MiB |    2000 | 3945 |

### Idle keep-alive — 500 connections held open

| server  | idle RSS  | RSS after load | peak RSS  | reqs ok | conn rate |
|---------|-----------|----------------|-----------|---------|-----------|
| saltare | 40.30 MiB |      41.25 MiB | 41.25 MiB |     500 | 3545      |
| uvicorn | 43.78 MiB |      49.09 MiB | 49.09 MiB |     500 | 2636      |

**Read this honestly:**

- The **idle keep-alive workload is where saltare's architectural advantage becomes visible**: 500 idle connections cost saltare **+0.95 MiB** (~2 KiB/conn) vs uvicorn's **+5.31 MiB** (~10.6 KiB/conn). That's a **~5× per-connection memory saving** in a realistic workload (clients that hold connections open between bursts of activity).
- The reason: saltare's `pool.zig` returns the 16 KiB read buffer to a shared free list as soon as a keep-alive connection goes idle. uvicorn's asyncio Transport keeps its per-connection buffers and Protocol/Task state alive for the lifetime of the socket.
- **Throughput parity (concurrent):** saltare 3840 rps vs uvicorn 3945 rps — within ~3%. The remaining gap is primarily `httptools` (uvicorn's tuned C parser) vs the Zig parser; both are fast.
- The ~40 MiB floor is Python + FastAPI itself. No userland server can shrink that without changing what the user app loads. Python 3.14 raises this floor a few MiB versus 3.12 because 3.14 imports more stdlib eagerly.

**Where saltare's architectural win shows up most:** long-lived connections (planned for v0.7 — WebSockets) and very high concurrency (10k+ open sockets). The current v0.4 benchmark runs short-lived requests; per-connection allocations are barely visible because connections live for milliseconds. Expect the gap to widen as the project moves up the roadmap.

## Roadmap

- [x] **v0.1.0** — Build pipeline. `saltare._core` extension built with Zig via `scikit-build-core`. Listening socket + accept loop in Zig. Single fixed HTTP response. Local Docker build + cibuildwheel CI.
- [x] **v0.2.0** — HTTP/1.1 request parser in Zig (request line, headers, `Content-Length` framing). Server echoes method + target back so the parser is observable end-to-end. Zero allocations per request.
- [x] **v0.3.0** — ASGI dispatcher. Persistent `asyncio` loop reused across requests; per-request `loop.run_until_complete`. Zig calls into Python via the C API only at dispatch time. FastAPI runs end-to-end (path params, JSON bodies, 404). No lifespan, no keep-alive, no streaming yet.
- [x] **v0.4.0** — Non-blocking event loop (epoll on Linux). Per-connection state machine in Zig with heap-allocated structs. Multiple connections progress in parallel; ASGI dispatch is the GIL serialization point. macOS (kqueue) raises `@compileError` until v0.4.x.
- [x] **v0.5.0** — HTTP/1.1 keep-alive. Persistent connections reset their state machine in place (read buffer compacted, write buffer freed, epoll switched back to read interest). Pipelined requests handled inline without an extra epoll round-trip.
- [x] **v0.6.0** — Pooled read buffers. Idle keep-alive connections release their 16 KiB read buffer back to a shared pool; the next read event re-acquires one. RSS now scales with **in-flight requests**, not with **open connections**. Result: ~5× less per-connection memory than uvicorn at idle.
- [ ] **v0.7.0** — Lifespan protocol + chunked Transfer-Encoding (deferred from v0.5.x).
- [ ] **v0.8.0** — TLS (via BoringSSL or stdlib).
- [ ] **v0.9.0** — WebSockets.
- [ ] **v1.0.0** — Multi-worker (fork / `SO_REUSEPORT`).

## Install (once published)

```bash
pip install saltare
```

## Usage

```python
# main.py
from fastapi import FastAPI

app = FastAPI()


@app.get("/")
def root():
    return {"hello": "world"}
```

```bash
saltare main:app --host 0.0.0.0 --port 8000
```

As of v0.3 the `app` is dispatched on every request. Lifespan / startup hooks are not invoked yet, so apps that rely on them (e.g. `@app.on_event("startup")`) will still run their routes but won't have run setup code.

## Building from source

### Local development with Zig

Easiest dev loop. Install Zig 0.16+ on your machine:

```bash
# macOS
brew install zig

# Or grab a tarball
bash scripts/install-zig.sh
```

Then:

```bash
uv sync                # or: pip install -e ".[dev]"
pip install -e .       # builds the extension in place
pytest -q
```

### Docker (no Zig on host)

If you don't want Zig on the host (CI-style builds):

```bash
./scripts/build-wheel.sh
# -> dist/saltare-0.1.0-cp312-cp312-manylinux_2_28_x86_64.whl
```

This invokes `Dockerfile`, which:

1. Pulls `quay.io/pypa/manylinux_2_28_x86_64`.
2. Downloads pinned Zig (`scripts/install-zig.sh`).
3. Builds the wheel and runs `auditwheel repair`.
4. Exports `dist/*.whl` to the host.

Override target via env: `PYTHON_TAG=cp310-cp310 MANYLINUX_TAG=manylinux_2_28_aarch64 ./scripts/build-wheel.sh`.

### Releasing

Tag a version and push:

```bash
git tag v0.1.0 && git push origin v0.1.0
```

`.github/workflows/release.yml` runs cibuildwheel on Linux (x86_64 + aarch64) and macOS (x86_64 + arm64), builds the sdist, and publishes to PyPI via Trusted Publishing.

## Project layout

```
.
├── build.zig             # Zig build script (produces _core extension)
├── build.zig.zon         # Zig package manifest
├── CMakeLists.txt        # scikit-build-core invokes Zig from here
├── pyproject.toml        # build backend + cibuildwheel config
├── Dockerfile            # local manylinux+Zig build
├── scripts/
│   ├── install-zig.sh    # pin & install Zig (used by Docker + CI)
│   └── build-wheel.sh    # one-liner local Docker build
├── src/
│   ├── zig/
│   │   ├── module.zig    # Python C-API surface (PyInit__core)
│   │   └── server.zig    # accept loop, will host parser + ASGI bridge
│   └── saltare/
│       ├── __init__.py   # public Python API: run(), __version__
│       ├── cli.py        # `saltare app:app --host ... --port ...`
│       ├── __main__.py
│       └── _core.pyi     # type stubs for the native module
├── tests/
│   └── test_smoke.py
└── .github/workflows/
    └── release.yml       # cibuildwheel + PyPI publish on tag
```

## License

MIT
