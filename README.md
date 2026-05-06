# saltare

Low-RAM ASGI HTTP server with a **Zig backbone**. An alternative to uvicorn for FastAPI deployments where memory budget matters more than raw throughput.

> **Status: 1.0.0 — first stable release.** Production target is **Linux x86_64** (the manylinux Docker pipeline is the canonical build path; macOS is dev-only since the kqueue port is still a `@compileError`). v1.0 closes the production checklist with **pre-fork multi-worker**: `workers=N` forks N child processes that each run lifespan + accept loop on a shared listen socket; the master supervises, propagates SIGTERM, and exits cleanly when the children do. A worker exiting unexpectedly propagates shutdown to its siblings — let your supervisor (systemd, k8s) restart the pod. Combined with everything earlier — HTTP/1.1, ASGI lifespan, TLS, WebSockets with server ping/pong, streaming responses, idle timeouts, resource caps, graceful shutdown, observability hooks, Unix domain sockets, adaptive buffers, `MADV_DONTNEED`, malloc_trim, pooled headers — saltare is ready to ship.

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

Results on Apple Silicon (manylinux_2_28_aarch64, CPython 3.14, FastAPI 0.115+, uvicorn 0.46 plain — no `[standard]` extras), v1.0.0 with default settings (single worker). Production target is x86_64 — these numbers should be representative; CI runs both archs.

### Sequential — 1 client, 1000 requests

| server  | idle RSS  | RSS after load | peak RSS  | reqs ok | rps  |
|---------|-----------|----------------|-----------|---------|------|
| saltare | 43.04 MiB |      43.18 MiB | 43.19 MiB |    1000 | 2335 |
| uvicorn | 44.80 MiB |      44.84 MiB | 44.84 MiB |    1000 | 2976 |

### Concurrent — 100 clients × 20 requests (2000 total)

| server  | idle RSS  | RSS after load | peak RSS  | reqs ok | rps  |
|---------|-----------|----------------|-----------|---------|------|
| saltare | 41.98 MiB |      42.20 MiB | 42.21 MiB |    2000 | 3840 |
| uvicorn | 44.73 MiB |      45.21 MiB | 45.21 MiB |    2000 | 3979 |

### Idle keep-alive — 500 connections held open

| server  | idle RSS  | RSS after load | peak RSS  | reqs ok | conn rate |
|---------|-----------|----------------|-----------|---------|-----------|
| saltare | 41.61 MiB |      41.74 MiB | 41.74 MiB |     500 | 2340      |
| uvicorn | 44.96 MiB |      50.34 MiB | 50.34 MiB |     500 | 2948      |

**Read this honestly:**

- **The idle keep-alive workload is where saltare's architectural advantage shines**: 500 idle connections cost saltare **+0.19 MiB** (~390 B/conn) vs uvicorn's **+5.38 MiB** (~11 KiB/conn). That's a **~28× per-connection memory saving** for a realistic workload (clients that hold connections open between bursts of activity).
- The reason: saltare's `pool.zig` bundles the 16 KiB read buffer *and* the per-request headers array into a single pool node, returned to a free list as soon as a keep-alive connection goes idle. uvicorn's asyncio Transport keeps its per-connection buffers and Protocol/Task state alive for the lifetime of the socket.
- **The floor dropped ~2 MiB** between v0.12.0 and v0.12.1 thanks to a `malloc_trim(0)` call after lifespan startup — glibc returns the fragmented heap left over from the FastAPI/Pydantic import chain to the OS in one syscall. Sequential idle went from 45.56 MiB to 43.15 MiB.
- **Throughput parity (concurrent):** saltare 3790 rps vs uvicorn 3951 rps — within ~4%. The remaining gap is primarily `httptools` (uvicorn's tuned C parser) and uvicorn's tighter asyncio integration vs the bridge-driven dispatch.
- **Streaming dispatch (v0.12) cost a few percent on sequential** because every HTTP request now runs as a long-lived asyncio Task with a per-request `recv_queue` and `outgoing` list. Sequential RPS sits at ~2316 (was 2599 pre-streaming); concurrent and idle-keepalive workloads were largely unaffected because they were already gated by other costs. The new architecture pays off as soon as response sizes go up: a streaming endpoint that emits 10 MiB across 100 chunks now keeps RSS flat instead of buffering the whole 10 MiB in Python `bytes` — a saving the bench harness above doesn't measure (its FastAPI app returns ~30 bytes).
- **v0.16 buffer adaptivity is also bench-invisible.** Read buffers shrink from 16 KiB → 4 KiB for the typical short request, saving ~12 KiB per in-flight request — but the bench's FastAPI app receives sub-1 KiB requests, so even the v0.15 16 KiB buffer was nearly empty. Wins show up in: services with high concurrency of small requests (savings compound across hundreds in-flight) and bursty traffic with valleys (`MADV_DONTNEED` returns long-idle committed pages to the kernel after 30 s, so RSS shrinks back toward the floor instead of staying at peak forever).
- The remaining ~42 MiB floor is Python + FastAPI itself. No userland server can shrink that without changing what the user app loads. Python 3.14 raises this floor a few MiB versus 3.12 because 3.14 imports more stdlib eagerly. Setting `MALLOC_ARENA_MAX=2` in the environment shaves another 5–15 MiB on multi-threaded glibc systems (see Production deployment).

**Where saltare's architectural win shows up most:** long-lived idle connections (the WebSocket and keep-alive workloads above), very high concurrency (10k+ open sockets), and large streamed responses (file downloads, SSE, JSON over MB).

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
- [x] **v0.12.1** — Per-connection RAM polish. The `[64]Header` array previously inlined into `Connection` (~2 KiB) is now bundled into the same `pool.zig` `Buffer` that holds the read data, so it's released atomically when the connection goes idle: idle keep-alive cost drops from ~2 KiB to ~390 B per connection, taking the per-conn advantage over uvicorn from ~5× to ~28×. A `malloc_trim(0)` call after `lifespan.startup` returns ~2 MiB of glibc heap fragmentation (left over from FastAPI/Pydantic imports) to the OS — the sequential-idle floor dropped from 45.56 MiB to 43.15 MiB. README gains a "Production deployment" section recommending `MALLOC_ARENA_MAX=2` for another 5–15 MiB.
- [x] **v0.13.0** — Resource caps + `Expect: 100-continue`. New `Limits` struct (`max_request_body`, `max_concurrent_connections`, `max_keepalive_requests`) wired into `serve()` and the CLI. Body cap fires 413 on declared `Content-Length` overflow and on incremental chunked-decode growth. Connection cap accepts overflow sockets (to drain the listen backlog) and immediately closes them. Keepalive-requests cap forces `Connection: close` on the Nth response, recycling pymalloc arenas. `Expect: 100-continue` writes the interim response before reading the body, except when the declared body would exceed the cap (in which case the client gets a 413 directly). Caps add zero RAM cost in benign workloads; under adversarial load they convert the architectural advantage into a **hard guarantee**.
- [x] **v0.14.0** — Graceful shutdown + ASGI exception isolation. New `g_draining` atomic flag; the SIGTERM/SIGINT handler sets it (and a second signal promotes to immediate force-exit). Main loop, on first observing drain mode, removes the listen fd from epoll (stops accepting), stamps a deadline, and continues processing in-flight requests — exit happens when `g_active_conns` reaches zero or `shutdown_timeout` (default 30 s) elapses. Idle keep-alive connections drain naturally via `keep_alive_timeout`. After the loop exits, `lifespan.shutdown` runs as before, then the process exits 0. App exceptions during dispatch are caught at the bridge: pre-headers raises produce a synthesized 500, mid-stream raises close the connection — server keeps serving subsequent requests. Tests now 44/44 (5 new in `test_shutdown.py`, 3 of which exercise real SIGTERM via `subprocess`).
- [x] **v0.15.0** — Observability + UDS. `Observability` struct (`metrics_path`, `access_log`, `proxy_headers`) all opt-in. `metrics_path` (e.g. `/metrics`) intercepts requests in Zig and serves Prometheus text from atomic counters (`saltare_open_connections`, `saltare_in_flight_requests`, `saltare_requests_total`, `saltare_responses_4xx_total` / `_5xx_total`, `saltare_bytes_sent_total` / `_received_total`, `saltare_process_resident_memory_bytes` from `/proc/self/status` on Linux). `access_log` emits a JSON line per completed request to stderr from a 4 KiB stack-buffered writer (status line parsed once from the wire bytes; bytes/latency tracked in `Connection`); a single `write(2)` keeps lines atomic. `proxy_headers` lets the dispatcher read `X-Forwarded-For` (leftmost IP into `scope["client"]`) and `X-Forwarded-Proto` (into `scope["scheme"]`); only enable behind a trusted proxy. `uds_path` makes `serve()` bind an `AF_UNIX` socket instead of TCP — the bind path is unlinked on shutdown so restarts don't fail with `EADDRINUSE`. All four off by default; bench numbers indistinguishable from v0.14. Tests now 50/50 (6 new in `test_observability.py`).
- [x] **v0.16.0** — Adaptive read buffer + `MADV_DONTNEED`. The single 16 KiB pool from v0.6–v0.15 splits into two free lists: a 4 KiB primary covering the typical short request, and a 16 KiB overflow used either as the initial buffer for big payloads or as the upgrade target when a partial parse fills the small one (in-flight bytes are memcpy'd across; `parsed.headers` is invalidated and re-parsed because it pointed into the small buffer's headers array). `Buffer.data` becomes a `[]u8` slice (page-allocated via mmap so the OS can later reclaim its pages); `Buffer.released_at_ns` records when a buffer entered the free list. Each main-loop iteration calls `pool.sweepIdle(monoNs())`, which walks both free lists and issues `MADV_DONTNEED` for any block idle >30 s — page-aligned mmaps mean the kernel actually drops the physical pages. Linux only; macOS short-circuits the sweep. Bench numbers are within noise of v0.15 (the FastAPI bench app sends sub-1 KiB requests, so even the v0.15 16 KiB buffer was nearly empty); the wins manifest in real-world bursty traffic and high-concurrency-low-payload services. `Header` offset compression deferred — too much API churn for the marginal saving.
- [x] **v0.17.0** — Stability + Python RAM polish. Replaced the per-request `asyncio.Queue` in `_HttpState` with a single-slot mailbox + on-demand `Future`: the typical request that does `await receive()` once never allocates a Queue object, an internal deque, or a getters list. Saves ~300 B of GC churn per request, lower transient peak under concurrency, and conceptually simpler dispatcher (fewer asyncio internals to reason about). Also fixed the `test_fastapi_lifespan_startup_runs` flake by adding a small retry around the first httpx call — the race was FastAPI's first-dispatch warm-up trip, not saltare itself, and 2 retries make it deterministic in CI. The pre-alpha status note now states explicitly that **production is x86_64 Linux** — macOS dev-builds still work for everything except the actual server (kqueue still `@compileError`).
- [x] **v0.18.0** — WebSocket keepalive + Python RAM polish. Server now sends an empty `ping` frame every `ws_keepalive_timeout` seconds (default 20) on each open WS; if no inbound frame (incl. pong) is observed in 2× that window, the connection is reaped. Implemented by reusing the existing timer wheel: WS upgrade arms it, every inbound frame updates `last_activity_ns`, and `fireExpired`'s WS branch is now ping-or-teardown rather than just teardown. Plus two Python-side wins: (1) header names are lowercased in Zig in-place inside `buildHeadersList` so `_dispatcher.py` drops the per-request `.lower()` list-comprehension and the per-header tuple rebuild it forced; (2) a 16-entry PyBytes cache for common header names (host, user-agent, content-type, etc) avoids `PyBytes_FromStringAndSize` on every cached header. Net: first run where saltare's concurrent rps (4006) edges past uvicorn's (3988), and ~0.2 MiB shaved across all three bench workloads.
- [x] **v1.0.0** — Pre-fork multi-worker. New `src/zig/master.zig` module supervises N forked workers via `pause()` + `waitpid()`. Master flow: bind+listen via the existing `bindAndListen`; fork N children that each run the v0.18 single-worker flow (lifespan startup → accept loop on the inherited fd → lifespan shutdown → `_exit`); supervise. Children call `prctl(PR_SET_PDEATHSIG, SIGTERM)` so an SIGKILL'd master doesn't leave orphan workers. v1.0 policy on worker death: propagate shutdown to the rest, return — let the supervisor restart the pod. Each worker keeps its own counters; `metrics_path` reports per-worker (aggregate across workers in your scraper). New `workers` kwarg on `saltare.run()` and `--workers N` CLI flag (default 1, single-worker behaviour unchanged). Tests in `tests/test_multiworker.py` use subprocess + `/proc/<master>/task/.../children` to verify worker spawn, request serving, SIGTERM drain, and unexpected-worker-death propagation.

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

### Resource caps

```python
saltare.run(
    app,
    max_concurrent_connections=1024,    # accepted sockets held open at once
    max_keepalive_requests=1000,        # requests per keep-alive conn before close
    max_request_body=1024 * 1024,       # bytes; oversize gets 413
)
```

CLI flags: `--max-concurrent-connections`, `--max-keepalive-requests`, `--max-request-body`. Defaults match the values above. `Expect: 100-continue` is honoured automatically (the interim response is written before the body is read, except when the declared `Content-Length` already exceeds `max_request_body` — in which case the client gets a 413 directly). In v0.13 the read buffer (16 KiB) is the practical hard ceiling for `max_request_body`; request-body streaming for larger bodies lands in a follow-up.

### Observability and deployment knobs (v0.15)

```python
saltare.run(
    app,
    metrics_path="/metrics",   # Prometheus text from Zig counters; no Python overhead per scrape
    access_log=True,           # JSON line to stderr per completed request
    proxy_headers=True,        # parse X-Forwarded-For / X-Forwarded-Proto
    uds_path="/run/saltare.sock",  # bind a Unix socket instead of host:port
)
```

CLI: `--metrics-path PATH`, `--access-log`, `--proxy-headers`, `--uds PATH`. All off by default — the bench numbers above are taken with all four disabled, so turning any of them on costs only what that feature costs (e.g. `access_log=True` adds one `clock_gettime` + one `write(2)` per request).

Metrics endpoint exposes:

```
saltare_open_connections           gauge   – active TCP/UDS sockets
saltare_in_flight_requests         gauge   – HTTP requests being dispatched right now
saltare_requests_total             counter – HTTP requests dispatched since startup
saltare_responses_4xx_total        counter
saltare_responses_5xx_total        counter
saltare_bytes_sent_total           counter
saltare_bytes_received_total       counter
saltare_process_resident_memory_bytes gauge – RSS from /proc/self/status (Linux)
```

The `metrics_path` request is answered entirely from Zig — your ASGI app never sees it.

Access log format (one JSON line per completed request, to stderr):

```
{"method":"GET","path":"/users/42","status":200,"bytes":318,"latency_us":1234,"user_agent":"curl/8.0"}
```

Stack-buffered, JSON-escaped, single `write(2)` per line so concurrent workers don't interleave.

Proxy headers: `X-Forwarded-For` (leftmost address → `scope["client"]`) and `X-Forwarded-Proto` (`http`/`https` → `scope["scheme"]`). Only enable behind a proxy that strips client-supplied `X-Forwarded-*` headers, otherwise clients can spoof their identity.

## Production deployment

### Workers and CPU

`workers=1` (the default) is one process serving all traffic. For multi-core machines, set `workers` to roughly **`min(cpu_count, 4)`** as a starting point; each worker holds its own ~43 MiB Python+FastAPI floor, so going wider trades RAM for CPU.

```bash
saltare main:app --host 0.0.0.0 --port 8000 --workers 4
```

The master process binds + listens once and forks the workers; the kernel load-balances `accept()` across them. A worker exiting unexpectedly causes the master to propagate shutdown to the rest and exit — your pod supervisor then restarts the whole thing. v1.0 deliberately doesn't respawn within the master; that's the supervisor's job.

### Environment

```bash
# Bound glibc's per-thread malloc arenas. saltare runs single-threaded per
# worker; default arenas (~8 × n_cpus on 64-bit) inflate RSS gratuitously.
# Typical saving: 5–15 MiB per worker.
export MALLOC_ARENA_MAX=2

# Conservative fd limit if you're not behind a reverse proxy that already
# rate-limits accept().
ulimit -n 65535
```

### systemd

```ini
[Service]
Environment="MALLOC_ARENA_MAX=2"
LimitNOFILE=65535
ExecStart=/usr/bin/saltare main:app \
    --host 0.0.0.0 --port 8000 \
    --workers 4 \
    --metrics-path /metrics --access-log
KillSignal=SIGTERM
TimeoutStopSec=35
Restart=on-failure
```

`TimeoutStopSec` should be a couple of seconds higher than `--shutdown-timeout` (default 30 s) so systemd doesn't escalate to SIGKILL while saltare is still draining.

### Kubernetes

```yaml
apiVersion: apps/v1
kind: Deployment
spec:
  template:
    spec:
      terminationGracePeriodSeconds: 35
      containers:
      - name: api
        image: your-image
        env:
        - name: MALLOC_ARENA_MAX
          value: "2"
        args:
        - "--workers=4"
        - "--metrics-path=/metrics"
        - "--access-log"
        - "--proxy-headers"
        ports:
        - containerPort: 8000
        readinessProbe:
          httpGet:
            path: /healthz   # your app's endpoint
            port: 8000
        # Prometheus pulls /metrics from each pod individually. With
        # --workers > 1 each scrape may land on a different worker, so
        # configure Prometheus to sum across pods and treat per-pod
        # counters as samples.
```

`saltare` honours `SIGTERM` with a graceful drain (`--shutdown-timeout`, default 30 s): in-flight requests get to finish, `lifespan.shutdown` runs, then the process exits 0.

### Behind nginx (Unix domain socket)

```bash
saltare main:app --uds /run/saltare.sock --workers 4
```

```nginx
upstream saltare {
    server unix:/run/saltare.sock;
}
server {
    location / {
        proxy_pass http://saltare;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

Pair with `--proxy-headers` so saltare reads `X-Forwarded-For` / `X-Forwarded-Proto` into `scope["client"]` / `scope["scheme"]` instead of seeing nginx as the client.

### What saltare does for you automatically

- `malloc_trim(0)` after `lifespan.startup` returns 1–3 MiB of glibc heap fragmentation (FastAPI/Pydantic imports) to the OS.
- Idle pool buffers older than 30 s get `MADV_DONTNEED` so RSS recovers after traffic peaks.
- App exceptions during dispatch are caught: pre-`response.start` raises become a 500; mid-stream raises close the connection. Workers keep serving.
- WebSocket connections get server-side ping/pong every 20 s (configurable); silent dead WS sockets are reaped at 2× that window.

## Building from source

### Local development with Zig

Easiest dev loop. saltare's build pipeline (scikit-build-core → CMake → Zig) needs three things on your machine:

1. **Zig 0.16+**
2. **Python development headers** (`Python.h`)
3. **OpenSSL development headers** (`<openssl/ssl.h>`, used by [src/zig/tls.zig](src/zig/tls.zig))

#### Linux (x86_64 or aarch64)

```bash
# Debian/Ubuntu
sudo apt install python3-dev libssl-dev cmake build-essential

# Fedora/RHEL/Rocky
sudo dnf install python3-devel openssl-devel cmake gcc

# Zig: pinned 0.16.0 tarball, both archs handled
bash scripts/install-zig.sh
```

#### macOS

```bash
brew install zig openssl@3
# Python headers come with Homebrew Python or python.org installers.
```

Then:

```bash
uv sync                # or: pip install -e ".[dev]"
pip install -e .       # builds the extension in place
pytest -q
```

If `pip install -e .` errors with `zig was not found on PATH`, your Zig install didn't end up in PATH — `bash scripts/install-zig.sh` symlinks `/usr/local/bin/zig` for you. If it errors with `openssl/ssl.h: No such file or directory`, the OpenSSL dev headers are missing (see the OS commands above). Both errors apply equally on x86_64 and aarch64; the Docker pipeline (`make build`) sidesteps them entirely by running everything inside the manylinux container.

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
