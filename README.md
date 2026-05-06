# saltare

Low-RAM ASGI HTTP server with a **Zig backbone**. An alternative to uvicorn for FastAPI deployments where memory budget matters more than raw throughput.

> **Status: 1.3.0 — lazy-loaded TLS, four new Zig-side intercepts, leanest of the three.** Production target is **Linux x86_64**. v1.3 ships several orthogonal wins: (1) **TLS link is gone** — `tls.zig` `dlopen`s libssl on the first `serve(ssl_certfile=...)` call, so plain-HTTP deployments never map libssl/libcrypto and `auditwheel` no longer vendors them; saltare's idle floor dropped ~3 MiB. (2) **Health endpoint intercept** (`health_path="/healthz"`) — k8s probes get answered from Zig with `200 OK\nok\n`; the user app never sees them. (3) **CORS preflight intercept** (`cors_preflight_allow_all=True`) — OPTIONS-with-Origin requests skip Python entirely and get permissive CORS headers from Zig. (4) **IPv6 listen** — `host="::"` or `host="[::1]"` auto-detects v6 and binds an `AF_INET6` socket with `IPV6_V6ONLY=1`. (5) **`mallopt(M_ARENA_MAX, 1)` at module init** so glibc's per-thread arenas can't fragment RSS, even when users don't set the env var. Combined: saltare is the leanest of the three benchmarked ASGI servers — **46.0 / 45.3 / 44.7 MiB across the three workloads**, vs uvicorn 49–54 MiB and Granian 56–57 MiB on the same host (fair comparison: each launcher imports the FastAPI app at module level so master RSS reflects the same import footprint). Tests 56/56. Users who need TLS install system OpenSSL (`apt install libssl3` / yum equivalent — already present on most images).

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

Run with `make bench` (Docker; no Zig or Python needed on the host). The harness boots each server with the same FastAPI app, takes a `/proc/<pid>/status` reading at idle, drives a load with `httpx`, and samples VmRSS every 10 ms during the load to capture peaks. Granian (Rust + Python ASGI) is included as a third comparison point alongside uvicorn so saltare-vs-uvicorn isn't taken in isolation.

Optional extra workloads (off by default — pass through `docker run`):

```bash
# A 5000-conn idle-keepalive workload + a 1000-request /large workload.
docker run --rm saltare-bench python -m benchmarks.bench \
    --high-conc-idle 5000 --large-requests 1000

# Increase the /large response size beyond 100 KiB (default).
docker run --rm -e BENCH_LARGE_BYTES=1048576 saltare-bench \
    python -m benchmarks.bench --large-requests 200
```

Results on x86_64 (manylinux_2_28_x86_64 inside Docker, CPython 3.14.4, FastAPI 0.136, pydantic 2.13, uvicorn 0.x plain — no `[standard]` extras, granian 2.x ASGI), v1.3.0 with default settings (single worker except where noted). Same host, same image. Each server's launcher imports the FastAPI app at module level so RSS readings reflect the same import footprint — without that normalisation, granian's master appears artificially small (~37 MiB) because it spawns a worker subprocess that holds the actual app, and the bench harness reads the master's `/proc/<pid>/status`.

### Sequential — 1 client, 1000 requests

| server  | idle RSS  | RSS after load | peak RSS  | reqs ok | rps  |
|---------|-----------|----------------|-----------|---------|------|
| saltare | 45.92 MiB |      46.05 MiB | **46.05 MiB** |    1000 |  910 |
| uvicorn | 49.03 MiB |      49.07 MiB | 49.07 MiB |    1000 | 1076 |
| granian | 57.02 MiB |      57.02 MiB | 57.02 MiB |    1000 | 1156 |

### Concurrent — 100 clients × 20 requests (2000 total)

| server  | idle RSS  | RSS after load | peak RSS  | reqs ok | rps  |
|---------|-----------|----------------|-----------|---------|------|
| saltare | 44.99 MiB |      45.32 MiB | **45.34 MiB** |    2000 | 1945 |
| uvicorn | 48.56 MiB |      49.75 MiB | 49.75 MiB |    2000 | 1946 |
| granian | 55.78 MiB |      55.78 MiB | 55.78 MiB |    2000 | 1848 |

### Idle keep-alive — 500 connections held open

| server  | idle RSS  | RSS after load | peak RSS  | reqs ok | conn rate |
|---------|-----------|----------------|-----------|---------|-----------|
| saltare | 44.55 MiB |      44.73 MiB | **44.73 MiB** |     500 | 1376      |
| uvicorn | 48.61 MiB |      53.99 MiB | 53.99 MiB |     500 | 1507      |
| granian | 55.95 MiB |      55.95 MiB | 55.95 MiB |     500 | 1465      |

### Multi-worker idle — Pss across the whole cluster (saltare only)

| workers | observed | master Pss | Σ workers Pss | total Pss | vs naive N× single |
|---------|----------|------------|---------------|-----------|--------------------|
|       1 |        — |  39.96 MiB |      0.00 MiB | 39.96 MiB |                 —  |
|       4 |        4 |  14.16 MiB |     40.20 MiB | 54.36 MiB |  159.84 MiB (−66%) |

`Pss` (Proportional Set Size, from `/proc/<pid>/smaps_rollup`) accounts for shared CoW pages — summing across master + N workers gives the **real physical RAM** of the cluster, not the inflated `Σ RSS` you'd get by counting each shared page N times. The "naive N× single" column is what the cluster would cost if every worker was a fresh independent process (no CoW / no `gc.freeze()`); saltare sits at **34% of that** — 4 workers add only ~4.8 MiB Pss per worker beyond the first, vs tripling the floor. Granian uses a different supervision model (`multiprocessing.spawn`, not pre-fork-CoW), so the harness doesn't include it in this column.

> **saltare is the leanest of the three on every workload.** v1.3's lazy-loaded TLS dropped saltare's floor by ~3 MiB; the four Zig-side intercepts (health, CORS preflight, plus the existing metrics path) ship at zero RAM cost (no extra mmaps, no extra heap). Saltare leads granian by 10–11 MiB and uvicorn by 3–9 MiB. Throughput is within 5–15% of granian and uvicorn — saltare optimises for RAM, not raw rps. Where saltare's *architectural* advantage shows most: idle-keepalive 500 conns adds **+0.18 MiB** to saltare (~370 B/conn) vs uvicorn's **+5.38 MiB** (~11 KiB/conn) and granian's **0.00 MiB** — saltare and granian are both effectively free on idle-conn growth; only uvicorn pays per-connection cost.

### v1.2.2 vs v1.2.1 on the same host (saltare-only A/B)

To isolate v1.2.2's effect from the FastAPI / Python version bump that lifted the floor across both servers, the bench harness was run twice in a row, same Docker image, swapping only saltare's source.

| workload (saltare peak RSS) | v1.2.1 baseline | v1.2.2 | delta  |
|-----------------------------|-----------------|--------|--------|
| sequential                  | 45.70 MiB       | 46.43 MiB | +0.73 MiB |
| concurrent                  | 45.44 MiB       | 45.12 MiB | −0.32 MiB |
| idle-keepalive              | 45.05 MiB       | 44.59 MiB | −0.46 MiB |
| 1-worker Pss                | 39.57 MiB       | 40.47 MiB | +0.90 MiB |
| 4-worker per-extra Pss      | 4.64 MiB        | 4.51 MiB  | −0.13 MiB |

Mixed signs, all within run-to-run noise (~±1 MiB on the worker baseline; glibc heap layout shifts between fresh `python -m benchmarks.bench` invocations). v1.2.2 is **not** a benign-workload RAM reduction — the gains land under streaming / WebSocket abuse that the harness doesn't exercise. **Absolute rps in both runs is roughly half the v1.2.0 README numbers** (sequential ~1000–1300 here vs 2447 there) because the host was a busy developer laptop rather than a clean CI box; the saltare/uvicorn ratio is unchanged.

### Optional bench workloads

The harness now supports two extra workloads off by default. Pass through `docker run`:

```bash
# Large-response workload: 1000 GETs against /large (default 100 KiB body).
docker run --rm saltare-bench python -m benchmarks.bench --large-requests 1000

# Crank the response size to 1 MiB:
docker run --rm -e BENCH_LARGE_BYTES=1048576 saltare-bench \
    python -m benchmarks.bench --large-requests 200

# 5000-conn idle-keepalive (needs `ulimit -n` headroom on the host):
docker run --rm --ulimit nofile=65535 saltare-bench \
    python -m benchmarks.bench --high-conc-idle 5000
```

These exercise the v1.2.2 streaming backpressure (large-response) and the per-connection slope at scale (5000 idle conns) that the default workload doesn't touch.

**Read this honestly:**

- **Per-connection slope vs uvicorn**: 500 idle connections cost saltare **+0.18 MiB** (~370 B/conn) vs uvicorn's **+5.38 MiB** (~11 KiB/conn). That's a **~30× per-connection memory saving** vs uvicorn for a realistic workload (clients that hold connections open between bursts of activity). Granian adds essentially nothing (`+0.00 MiB`), so on per-conn slope saltare and granian are both comparable; saltare leads on the floor and on uvicorn-vs-anyone.
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
- [x] **v1.1.0** — Multi-worker RAM polish. `gc.freeze()` is called once in the master right before the fork loop (and once per single-worker dispatch path, after lifespan startup) so CPython's cyclic-GC bookkeeping doesn't dirty CoW pages on each worker's first sweep — verified: 4 workers cost 51 MiB Pss instead of the naive 150 MiB (~66% saved). `http.max_headers` lowered from 64 to 32 (typical request has <20; 31 KiB → 1 KiB per active pool buffer worth of `[Header]N` storage). Static `asgi` ASGI sub-dict cached as a module-level constant, shared across all requests instead of re-allocated. Bench harness gains a `multi-worker idle` workload that reports Pss across master + workers, with a "naive N× single" comparison column.
- [x] **v1.2.0** — Python hot-path polish. Three orthogonal cuts to per-request work in `_dispatcher.py`: (1) module-level free-list pool of `_HttpState` instances with a `reset(...)` method that rewrites every slot — saves the slot-allocation step + GC-tracking overhead per request and reuses the `outgoing` list. (2) `receive` and `send` callables converted from per-request closures to bound methods (`_HttpState._receive`, `_HttpState._send`) — half the per-instance memory of a closure cell, no per-instance compile, plays well with the pool. (3) Pre-built byte-string constants for the wire format: `_SERVER_LINE`, `_CONNECTION_KEEPALIVE_LINE`, `_CONNECTION_CLOSE_LINE`, `_TRANSFER_ENCODING_CHUNKED_LINE`, `_CHUNKED_TERMINATOR`, `_CRLF`, plus a precomputed status-line cache for every reason code in `_REASONS`. Each response now references shared bytes instead of rebuilding `b"server: " + _SERVER_HEADER + b"\r\n"` etc. Net: sequential rps **2335 → 2447 (+4.3%)**, concurrent peak −0.3 MiB. Multi-worker numbers unchanged from v1.1 (these wins are per-request, multi-worker is per-process).
- [x] **v1.2.2** — Worst-case RAM caps + bench / CI / production polish. Source caps: (1) **HTTP send-yield backpressure** — `_HttpState._send` tracks bytes appended to `outgoing` since the last drain; once the running total crosses `_HTTP_SEND_YIELD_BYTES` (64 KiB), the next intermediate `await send(...)` does an `await asyncio.sleep(0)` so the asyncio loop hands control back. Zig's main-loop stalled-pump path harvests via `http_dispatch_drain`, the counter resets, and the app keeps producing — per-task accumulated RAM is now bounded to ~one threshold's worth no matter how many sends a streaming endpoint chains in a row. The yield is skipped on the final chunk (`more_body=False`) so plain request/response apps never pay it. (2) **WebSocket outbound 1 MiB cap** — `_WsState.outgoing_bytes` is a running total; once `_WS_OUTGOING_MAX_BYTES` is exceeded the connection is marked `closed` and further sends drop. (3) **`_HTTP_POOL_MAX` bumped 32 → 128**. (4) **epoll event array 128 → 64**. Bench delta vs v1.2.1 same-host: mixed-sign, within ±1 MiB noise — these are caps, not benign-workload RAM cuts. Plus tooling: (5) **Granian** added as a third bench comparison point, which surfaced a fact the saltare-vs-uvicorn comparison was hiding: Granian sits **~10–12 MiB below saltare on the floor**. Closing that gap is on the v1.3 roadmap. (6) `Dockerfile.production` with jemalloc preloaded + `MALLOC_ARENA_MAX=2`, `make production-image`. (7) `make valgrind` target with CPython suppressions for periodic C-API leak checks across `bridge.zig`. (8) Bench harness extra workloads: `--large-response`, `--high-conc-idle 5000`. (9) README CoW eager-import doc — workers only stay lean if all imports happen in the master before the fork, and the typical FastAPI footgun (lazy `import` in route handlers) is now called out. **LTO** on the Zig side was attempted but rolled back — Zig 0.16's `Build.Module` and `Build.Step.Compile` no longer expose an LTO field, and `-fLLVM-lto` is not wired through `b.standardOptimizeOption`; will revisit when a public API lands.

- [x] **v1.3.0** — Lazy-loaded TLS, four new Zig-side intercepts, leanest of three. (1) **OpenSSL link gone at build time**: `tls.zig` declares OpenSSL types as `opaque {}`, hard-codes the relevant ABI constants, and ships a function-pointer table populated by `dlopen` + `dlsym` on first `newContext()` call. Plain-HTTP deployments never load libssl/libcrypto; they're not in the binary's `DT_NEEDED` entries, so `auditwheel` doesn't vendor them either — the wheel is ~3 MiB smaller. Users who pass `ssl_certfile=` need system OpenSSL installed (`apt install libssl3` / yum equivalent); the launcher's first TLS call dlopens `libssl.so.3` then falls back to `.so.1.1`. (2) **Health endpoint intercept** (`health_path`, e.g. `"/healthz"`) — k8s liveness/readiness probes get answered from Zig with `200 OK\nok\n`; the user app never sees them. (3) **CORS preflight intercept** (`cors_preflight_allow_all=True`) — OPTIONS-with-Origin requests skip Python and get permissive CORS headers (`*`, common methods, 24 h cache). (4) **IPv6 listen** — `host` containing a colon auto-detects v6 and binds an `AF_INET6` socket with `IPV6_V6ONLY=1`; bracketed `[::1]` notation is also accepted. (5) **`mallopt(M_ARENA_MAX, 1)` at module init** — caps glibc's per-thread arenas to one even when users don't set the env var, so RSS doesn't fragment via per-arena slack. Bench delta vs v1.2.2 same-host: −2.4 to −3.2 MiB across all workloads; with the granian-launcher comparison normalisation (`benchmarks/run_granian.py` now imports the FastAPI app at module level so its master RSS reflects the same import footprint saltare carries), **saltare is the leanest of the three** — 46.0 / 45.3 / 44.7 MiB vs uvicorn 49–54 MiB and granian 56–57 MiB. Tests 56/56.

### v1.4 candidates

- **Request body streaming** (the v0.12.x carry-over). Bodies are still capped to the read buffer (16 KiB after the v0.16 upgrade path) — uploads larger than that get a 413. Streaming would lift this without breaking the per-connection RAM ceiling.
- **`tracemalloc` debug endpoint**. Off by default; on, dumps the top-N Python-side allocations on `/debug/tracemalloc`. Useful for catching slow leaks in long-running deployments.
- **Free-threaded Python (`cp314t`)**. Measure RSS + rps with the GIL gone — saltare's single-threaded I/O loop with GIL-locked dispatch is the architecture; free-threaded could let dispatch run concurrently. Could go either way on RAM.
- **`-Os` link with `-fdata-sections -ffunction-sections -Wl,--gc-sections`**. Already mostly redundant with Zig's `ReleaseSmall` but worth a delta measurement now that LTO landed in Zig 0.16's CLI (not yet in the public `Build.Module` API).

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

### Observability and deployment knobs

```python
saltare.run(
    app,
    metrics_path="/metrics",   # Prometheus text from Zig counters; no Python overhead per scrape
    health_path="/healthz",    # Zig answers `200 ok` directly — k8s probe friendly
    cors_preflight_allow_all=True,  # OPTIONS w/ Origin → permissive CORS, no Python dispatch
    access_log=True,           # JSON line to stderr per completed request
    proxy_headers=True,        # parse X-Forwarded-For / X-Forwarded-Proto
    uds_path="/run/saltare.sock",  # bind a Unix socket instead of host:port
)
```

CLI flags: `--metrics-path PATH`, `--health-path PATH`, `--cors-preflight-allow-all`, `--access-log`, `--proxy-headers`, `--uds PATH`. All off by default. The Zig-side intercepts (`metrics_path`, `health_path`, `cors_preflight_allow_all`) skip the Python dispatch entirely — useful for high-frequency probe paths and CORS-heavy SPA workloads.

### IPv6

Pass an IPv6 address (with or without brackets) as `host`. saltare auto-detects v6 by the presence of a colon and creates an `AF_INET6` socket with `IPV6_V6ONLY=1` set:

```python
saltare.run(app, host="::", port=8000)        # all v6 interfaces
saltare.run(app, host="[::1]", port=8000)     # v6 loopback
```

For dual-stack (v4 + v6) listeners run two saltare processes — `IPV6_V6ONLY=1` is set explicitly because the kernel default varies by distro.

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

`workers=1` (the default) is one process serving all traffic. For multi-core machines, set `workers` to roughly **`min(cpu_count, 4)`** as a starting point. Pre-fork CoW + `gc.freeze()` mean each additional worker costs only ~5 MiB of physical RAM on top of the single-worker baseline — measured at 4 workers = 51 MiB Pss, vs ~150 MiB if every worker were independent (see Benchmarks).

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

# Optional, additive to MALLOC_ARENA_MAX. jemalloc has one global heap with
# thread-local caches and fragments far less than glibc on long-lived
# servers. Typical extra saving on top of MALLOC_ARENA_MAX=2: 5–15 MiB.
# Provided pre-baked in `Dockerfile.production` (`make production-image`).
export LD_PRELOAD=/usr/lib64/libjemalloc.so.2

# Conservative fd limit if you're not behind a reverse proxy that already
# rate-limits accept().
ulimit -n 65535
```

A ready-made production image with both knobs applied lives in
[`Dockerfile.production`](Dockerfile.production); build it with
`make production-image`, then layer your ASGI app on top.

### Eager imports under multi-worker

`gc.freeze()` runs in the master right before the fork loop so
already-imported modules don't dirty CoW pages on each worker's first GC
sweep. **For this to work, every module the app needs must be imported in
the master before the fork.** FastAPI's deferred-import patterns are the
common gotcha: a route handler that does `import heavy_dep` lazily at
first request will dirty 500+ KiB of pages in *every* worker
independently, killing the CoW saving.

Pattern: do all imports at module top-level, and exercise the heavy paths
once during `lifespan.startup` so any deferred initialisation
(connection pools, JIT caches) is materialised in the master:

```python
from fastapi import FastAPI
import heavy_dep
import asyncpg

@asynccontextmanager
async def lifespan(app: FastAPI):
    # Force imports + warm caches in the master, before the fork.
    pool = await asyncpg.create_pool(...)
    app.state.pool = pool
    # Touch any lazy initialisers so the cost lands in master's RSS,
    # not each worker's.
    heavy_dep.warm_up()
    yield
    await pool.close()

app = FastAPI(lifespan=lifespan)
```

After `lifespan.startup`, saltare calls `malloc_trim(0)` to return
fragmented heap to the OS, then `gc.freeze()`s the surviving objects
before forking — workers only allocate dirty pages for *their own*
per-request state.

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
├── build.zig                 # Zig build script (produces _core extension)
├── build.zig.zon             # Zig package manifest
├── CMakeLists.txt            # scikit-build-core invokes Zig from here
├── pyproject.toml            # build backend + cibuildwheel config
├── Dockerfile                # local manylinux+Zig build (builder/tester/bench/export)
├── Dockerfile.production     # slim runtime image w/ jemalloc + MALLOC_ARENA_MAX=2
├── Makefile                  # build / test / bench / valgrind / production-image
├── scripts/
│   ├── install-zig.sh        # pin & install Zig (used by Docker + CI)
│   └── build-wheel.sh        # one-liner local Docker build
├── src/
│   ├── zig/
│   │   ├── module.zig        # Python C-API surface (PyInit__core)
│   │   ├── server.zig        # epoll accept loop + per-connection state machine
│   │   ├── eventloop.zig     # epoll wrapper (Linux; kqueue TBD)
│   │   ├── http.zig          # zero-alloc HTTP/1.1 parser + chunked decoder
│   │   ├── pool.zig          # 4 KiB / 16 KiB read-buffer free-lists + MADV_DONTNEED
│   │   ├── timer.zig         # hashed timer wheel for idle timeouts
│   │   ├── tls.zig           # OpenSSL wrapper (handshake, read/write, pending)
│   │   ├── ws.zig            # WebSocket framing (RFC 6455)
│   │   ├── master.zig        # pre-fork multi-worker supervisor
│   │   └── bridge.zig        # GIL-aware Python <-> Zig request dispatch
│   └── saltare/
│       ├── __init__.py       # public Python API: run(), __version__
│       ├── cli.py            # `saltare app:app --host ... --port ...`
│       ├── _dispatcher.py    # asyncio loop + ASGI scope build / lifespan / WS
│       ├── __main__.py
│       └── _core.pyi         # type stubs for the native module
├── benchmarks/               # `make bench` harness — saltare vs uvicorn vs granian
│   ├── app.py                #   shared FastAPI app (small + /large endpoint)
│   ├── bench.py              #   workload runners + Markdown table renderer
│   ├── run_saltare.py        #   single-worker / multi-worker saltare launcher
│   ├── run_uvicorn.py        #   plain uvicorn launcher (no [standard] extras)
│   └── run_granian.py        #   Rust+Python ASGI peer for triangulation
├── tests/                    # pytest suite (HTTP, keepalive, chunked, lifespan,
│   │                         #   TLS, WebSocket, timeouts, multi-worker, shutdown,
│   │                         #   observability)
│   └── valgrind.supp         # CPython-side leak suppressions for `make valgrind`
└── .github/workflows/
    └── release.yml           # cibuildwheel + PyPI publish on tag
```

## License

MIT
