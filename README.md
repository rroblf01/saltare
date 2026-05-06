# saltare

Low-RAM ASGI HTTP server with a **Zig backbone**. An alternative to uvicorn for FastAPI deployments where memory budget matters more than raw throughput.

> **Status: pre-alpha (v0.12.0).** HTTP/1.1 (chunked, keep-alive, pipelining), ASGI lifespan, TLS, WebSockets, idle timeouts, and **streaming response bodies** are all in. Apps that emit `more_body=True` chunks now stream through the bridge instead of buffering in Python; auto-chunked encoding is added when no Content-Length is declared. Production-readiness gaps remaining for v1.0: resource caps (max body, max conns), graceful shutdown, observability, multi-worker.

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
   saltare CLI                                   epoll accept loop
                                                 HTTP/1.1 parser
                                                 chunked decoder
                                                 TLS via OpenSSL
                                                 WebSocket framing
                                                 timer wheel (idle
                                                   timeouts)
                                                 │
                          dispatch_request ◄─────┘
   app(scope, receive, send) ─────────────────►  send()/receive()
                                                 backed by Zig sockets
```

## Benchmarks

Run with `make bench` (Docker; no Zig or Python needed on the host). The harness boots each server with the same FastAPI app, takes a `/proc/<pid>/status` reading at idle, drives a load with `httpx`, and samples VmRSS every 10 ms during the load to capture peaks.

Results on Apple Silicon (manylinux_2_28_aarch64, CPython 3.14, FastAPI 0.115+, uvicorn 0.46 plain — no `[standard]` extras), v0.12.0:

### Sequential — 1 client, 1000 requests

| server  | idle RSS  | RSS after load | peak RSS  | reqs ok | rps  |
|---------|-----------|----------------|-----------|---------|------|
| saltare | 45.56 MiB |      45.70 MiB | 45.71 MiB |    1000 | 2286 |
| uvicorn | 45.00 MiB |      45.04 MiB | 45.04 MiB |    1000 | 2878 |

### Concurrent — 100 clients × 20 requests (2000 total)

| server  | idle RSS  | RSS after load | peak RSS  | reqs ok | rps  |
|---------|-----------|----------------|-----------|---------|------|
| saltare | 41.74 MiB |      42.04 MiB | 42.05 MiB |    2000 | 3810 |
| uvicorn | 44.99 MiB |      45.46 MiB | 45.46 MiB |    2000 | 3954 |

### Idle keep-alive — 500 connections held open

| server  | idle RSS  | RSS after load | peak RSS  | reqs ok | conn rate |
|---------|-----------|----------------|-----------|---------|-----------|
| saltare | 42.04 MiB |      43.13 MiB | 43.13 MiB |     500 | 2190      |
| uvicorn | 44.99 MiB |      50.37 MiB | 50.37 MiB |     500 | 2772      |

**Read this honestly:**

- The **idle keep-alive workload is where saltare's architectural advantage becomes visible**: 500 idle connections cost saltare **+1.09 MiB** (~2 KiB/conn) vs uvicorn's **+5.38 MiB** (~11 KiB/conn). That's still a **~5× per-connection memory saving** for a realistic workload (clients that hold connections open between bursts of activity).
- The reason: saltare's `pool.zig` returns the 16 KiB read buffer to a shared free list as soon as a keep-alive connection goes idle. uvicorn's asyncio Transport keeps its per-connection buffers and Protocol/Task state alive for the lifetime of the socket.
- **Throughput parity (concurrent):** saltare 3810 rps vs uvicorn 3954 rps — within ~4%. The remaining gap is primarily `httptools` (uvicorn's tuned C parser) and uvicorn's tighter asyncio integration vs the bridge-driven dispatch.
- **v0.12 streaming dispatch cost a few percent on sequential.** Every HTTP request now runs as a long-lived asyncio Task with a per-request `recv_queue` and `outgoing` list — that's the price of supporting `more_body=True` and auto-chunked output. Sequential RPS dropped from ~2599 (v0.11) to 2286 (v0.12); concurrent and idle-keepalive workloads were largely unaffected because they were already gated by other costs.
- The new architecture pays off as soon as response sizes go up: a streaming endpoint that emits 10 MiB across 100 chunks now keeps RSS flat instead of buffering the whole 10 MiB in Python `bytes` before flushing — a saving the bench harness above doesn't measure (its FastAPI app returns ~30 bytes).
- The ~42 MiB floor is Python + FastAPI itself. No userland server can shrink that without changing what the user app loads. Python 3.14 raises this floor a few MiB versus 3.12 because 3.14 imports more stdlib eagerly.

**Where saltare's architectural win shows up most:** long-lived idle connections (the WebSocket and keep-alive workloads above), very high concurrency (10k+ open sockets), and now **large streamed responses** (file downloads, SSE, JSON over MB).

## Roadmap

- [x] **v0.1.0** — Build pipeline. `saltare._core` extension built with Zig via `scikit-build-core`. Listening socket + accept loop in Zig. Single fixed HTTP response. Local Docker build + cibuildwheel CI.
- [x] **v0.2.0** — HTTP/1.1 request parser in Zig (request line, headers, `Content-Length` framing). Server echoes method + target back so the parser is observable end-to-end. Zero allocations per request.
- [x] **v0.3.0** — ASGI dispatcher. Persistent `asyncio` loop reused across requests; per-request `loop.run_until_complete`. Zig calls into Python via the C API only at dispatch time. FastAPI runs end-to-end (path params, JSON bodies, 404). No lifespan, no keep-alive, no streaming yet.
- [x] **v0.4.0** — Non-blocking event loop (epoll on Linux). Per-connection state machine in Zig with heap-allocated structs. Multiple connections progress in parallel; ASGI dispatch is the GIL serialization point. macOS (kqueue) raises `@compileError` until v0.4.x.
- [x] **v0.5.0** — HTTP/1.1 keep-alive. Persistent connections reset their state machine in place (read buffer compacted, write buffer freed, epoll switched back to read interest). Pipelined requests handled inline without an extra epoll round-trip.
- [x] **v0.6.0** — Pooled read buffers. Idle keep-alive connections release their 16 KiB read buffer back to a shared pool; the next read event re-acquires one. RSS now scales with **in-flight requests**, not with **open connections**. Result: ~5× less per-connection memory than uvicorn at idle.
- [x] **v0.7.0** — ASGI lifespan protocol. The dispatcher creates a long-lived asyncio Task that drives the app through `lifespan.startup` before the I/O loop accepts connections, and through `lifespan.shutdown` after it stops. Apps using `FastAPI(lifespan=...)` now get their startup/shutdown hooks executed. Apps that raise on lifespan scope (no support) are tolerated.
- [x] **v0.8.0** — Chunked Transfer-Encoding for *request* bodies. Decoder runs in place over the read buffer; resumable across kernel reads. Streaming *response* bodies (true chunked output) still buffer in Python and emit Content-Length — that lands when the dispatcher gets a callback path back into Zig.
- [x] **v0.9.0** — TLS termination via OpenSSL. Pass `ssl_certfile=` and `ssl_keyfile=` to `saltare.run()` to serve HTTPS. The connection state machine gains a `handshaking` phase; `doRead`/`doWrite` route through SSL_read/SSL_write and translate WANT_READ/WANT_WRITE into epoll interest changes. SSL_pending drained between keep-alive cycles. `auditwheel` bundles libssl/libcrypto into the wheel — self-contained, no host OpenSSL dependency. Single-cert/single-key, server-only (no mTLS, no SNI, no ALPN).
- [x] **v0.10.0** — WebSockets. RFC 6455 handshake, single-frame text/binary messages, ping auto-pong, close echo. Frames unmasked in place over the existing 16 KiB read buffer; outbound frames concatenated onto the same `write_buf` that HTTP responses use. Out of scope: continuation frames, message-level fragmentation, per-message deflate.
- [x] **v0.11.0** — Per-connection idle timeouts via a hashed timer wheel (`src/zig/timer.zig`). Four configurable deadlines (`header_timeout`, `keep_alive_timeout`, `body_timeout`, `write_timeout`) with defaults of 5/5/30/30 seconds. Slowloris and slow-body attacks are now reaped instead of holding `Connection` structs indefinitely. Wheel uses 128 buckets of 1 second; nodes are intrusive in `Connection` (24 B / conn) so arming and cancelling are allocation-free O(1). WS connections are exempt — long-lived idle sockets are expected there; ping/pong-driven WS keepalive lands post-v0.11.
- [x] **v0.12.0** — Streaming response bodies. Each HTTP request runs as a long-lived asyncio Task with its own `recv_queue` and `outgoing` list; the app's `send({type: "http.response.body", more_body: True/False})` calls flow chunk-by-chunk through the bridge into Zig's `write_buf` instead of being buffered into a single Python `bytes`. When the app does not declare a Content-Length, saltare adds `Transfer-Encoding: chunked` automatically. Concurrency uses a global "stalled list" of connections whose Task is parked on framework-internal awaits (e.g. FastAPI middleware chains): the main loop runs one global asyncio pump per iteration to advance every parked Task in lockstep, then drains each one — no per-connection multi-pumping, no level-triggered EPOLLOUT spin. Request bodies are still capped to the 16 KiB read buffer (request-side streaming lands in v0.12.x).
- [ ] **v0.13.0** — Caps configurable (max body, max concurrent connections, max keepalive_requests, max write buffer) + 413/431 + `Expect: 100-continue`.
- [ ] **v0.14.0** — Graceful shutdown with in-flight drain on SIGTERM + robust ASGI exception isolation.
- [ ] **v0.15.0** — Metrics endpoint + access log opt-in + proxy headers + Unix domain sockets.
- [ ] **v0.16.0** — RAM polish: `malloc_trim` after lifespan startup, adaptive read buffer, `MADV_DONTNEED` on idle pool buffers.
- [ ] **v1.0.0** — Multi-worker (fork / `SO_REUSEPORT`) + production deployment guide.

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

For HTTPS, pass a certificate and private key (PEM, both required together):

```python
import saltare
from main import app

saltare.run(app, host="0.0.0.0", port=443,
            ssl_certfile="/etc/letsencrypt/live/example.com/fullchain.pem",
            ssl_keyfile="/etc/letsencrypt/live/example.com/privkey.pem")
```

Both per-request HTTP dispatch and ASGI lifespan startup/shutdown are wired up: `FastAPI(lifespan=...)` and the older `@app.on_event("startup")` work as expected.

### Streaming responses

Apps can emit response bodies in chunks via the standard ASGI `more_body` flag — saltare flushes each chunk to the wire as soon as the app produces it instead of buffering the full response in Python:

```python
async def streaming_endpoint(scope, receive, send):
    await receive()
    await send({"type": "http.response.start", "status": 200,
                "headers": [(b"content-type", b"text/plain")]})
    for chunk in produce_chunks():        # arbitrary length, no upfront size needed
        await send({"type": "http.response.body", "body": chunk, "more_body": True})
    await send({"type": "http.response.body", "body": b"", "more_body": False})
```

When the app does not declare a `Content-Length`, saltare adds `Transfer-Encoding: chunked` automatically. Apps that do declare a `Content-Length` get raw bytes streamed (no chunked framing). FastAPI's `StreamingResponse` and Starlette's SSE helpers both work without changes.

### Idle timeouts

Every connection is bounded by four deadlines, all configurable in seconds:

```python
saltare.run(
    app,
    header_timeout=5,        # accept → headers parsed
    keep_alive_timeout=5,    # between requests on a kept-alive conn
    body_timeout=30,         # headers parsed → body fully received
    write_timeout=30,        # max time held in the writing state
)
```

The same flags are exposed on the CLI (`--header-timeout`, `--keep-alive-timeout`, `--body-timeout`, `--write-timeout`). Defaults match the values above. WebSocket connections are exempt — long-lived idle WS sockets are expected, and ping/pong-driven keepalive lands post-v0.11.

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
│   │   ├── server.zig    # epoll accept loop + per-connection state machine
│   │   ├── eventloop.zig # epoll wrapper (Linux; kqueue TBD)
│   │   ├── http.zig      # zero-alloc HTTP/1.1 parser + chunked decoder
│   │   ├── pool.zig      # 16 KiB read-buffer free-list
│   │   ├── timer.zig     # hashed timer wheel for idle timeouts
│   │   ├── tls.zig       # OpenSSL wrapper (handshake, read/write, pending)
│   │   ├── ws.zig        # WebSocket framing (RFC 6455)
│   │   └── bridge.zig    # GIL-aware Python <-> Zig request dispatch
│   └── saltare/
│       ├── __init__.py   # public Python API: run(), __version__
│       ├── cli.py        # `saltare app:app --host ... --port ...`
│       ├── _dispatcher.py # asyncio loop + ASGI scope build / lifespan / WS
│       ├── __main__.py
│       └── _core.pyi     # type stubs for the native module
├── benchmarks/           # `make bench` harness comparing saltare vs uvicorn
├── tests/                # pytest suite (HTTP, keepalive, chunked, lifespan,
│                         #   TLS, WebSocket, timeouts)
└── .github/workflows/
    └── release.yml       # cibuildwheel + PyPI publish on tag
```

## License

MIT
