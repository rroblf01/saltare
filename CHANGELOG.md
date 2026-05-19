# Changelog

## 1.7.1

**Theme**: Django Channels WebSocket runtime — closing the gap with daphne.

v1.7.0 shipped the scope-shape fixes (state, extensions, drop
method, proxy_headers for WS) but Channels apps still didn't work
end-to-end: `AuthMiddlewareStack` parked the consumer task on an
async session lookup, saltare gave up after one tick, and the
consumer's `channel_layer.group_send` deliveries never reached the
wire. v1.7.1 reworks the WS upgrade + steady-state pump so Channels
apps that work under daphne also work under saltare.

### Default-on

- **WS upgrade: two-phase multi-tick pump.** Phase 1 spins
  `_pump_once()` up to `_WS_UPGRADE_DEADLINE_S` (2 s) until the
  consumer accepts / closes / errors — gives `AuthMiddlewareStack`'s
  async session lookup room to settle. Phase 2 (post-accept) keeps
  pumping until the consumer's `connect()` finishes its `group_add`
  + initial-state DB fetch + initial `self.send(...)` chain — was:
  saltare broke out as soon as `accepted=True` and the initial
  state push never reached the client. Quiet-tick heuristic
  (`_WS_QUIET_TICKS_BEFORE_RETURN`) detects the consumer parking
  on `receive_queue.get()` so the pump exits as soon as the
  initial work is done.
- **Periodic asyncio pump for live WS connections.** Daphne keeps
  `loop.run_forever()` in a background thread; saltare's per-event
  pump model was idle between socket events, so
  `channel_layer.group_send` queued a message but the consumer's
  `await receive_queue.get()` never resumed. The main loop now
  ticks the asyncio loop every 50 ms when `g_ws_conns > 0` and
  walks a new `g_ws_head` singly-linked list of live WS conns,
  draining each via `bridge.wsDrain` + `queueFrames` +
  `flushOutbound`. Zero overhead on plain-HTTP deployments
  (gated on `g_ws_conns > 0`).
- **WS-task exception surfacing.** When the consumer task ends with
  an unconsumed exception before `accept()` (Channels middleware
  raising on missing SECRET_KEY / SessionMiddleware misconfig /
  scope key error), saltare now prints the traceback to stderr
  AND stuffs the exception class+message into `close_reason` so
  `--ws-reject-log` carries it. Was: silent 403 with no clue.

### Tests

108 total — same count as v1.7.0. No new tests; the existing
`test_channels.py` (skipped when Channels isn't installed) covers
the integration surface, and the WS-pump fix is exercised by
existing `test_websocket.py` / `test_v16.py` because the new
multi-tick path collapses to a single tick for simple consumers.

## 1.7.0

**Theme**: Django Channels / ASGI 3.0 compliance.

v1.6 served WebSocket upgrades fine in isolation but rejected with
HTTP 403 when the user app was a Channels `ProtocolTypeRouter` with
`AuthMiddlewareStack` in front of it — the consumer never reached
`accept()` because Channels' middleware short-circuited the connect
on missing scope keys. v1.7 closes that gap.

### Default-on (no flag)

- **ASGI 3.0 `state` dict** — `lifespan_startup` now creates a fresh
  empty dict (`state.asgi_state`) and surfaces it as `scope["state"]`
  on the lifespan scope; apps that mutate it (DB connection pools,
  feature-flag caches, etc.) see the *same dict object* on every
  subsequent HTTP and WebSocket scope. Matches uvicorn / hypercorn
  semantics. Channels' `AuthMiddlewareStack` consults this on every
  WS connect.
- **`scope["extensions"]`** — empty `dict` (`_SCOPE_EXTENSIONS`) added
  to HTTP and WS scopes. ASGI 3.0 reserved marker; some middleware
  raises `KeyError` if missing.
- **`scope["client"]` populated on WebSocket upgrades** — the WS
  path now runs the same `_apply_proxy_headers` helper as HTTP, so
  behind nginx / traefik / k8s ingress `scope["client"]` reflects the
  real peer instead of `None`. `scope["scheme"]` honours
  `X-Forwarded-Proto` (`ws` → `wss` when the proxy terminated TLS).
  Channels' `AllowedHostsOriginValidator` was rejecting because of
  the `None` client; that path now works.
- **`method` dropped from WebSocket scope** — it was non-spec
  (ASGI WS scope doesn't include the HTTP request method); strict
  middleware assert-failed on the extra key.
- **`_apply_proxy_headers` helper** factored out of
  `http_dispatch_start` so HTTP and WS share one implementation —
  RFC 7239 `Forwarded:` precedence over X-Real-IP / X-Forwarded-For
  is now identical across both paths.

### Diagnostic polish (rolled into 1.7.0)

- **Consumer close-code → HTTP status forwarding.** When the app
  emits `websocket.close(code=4xxx)` before accepting (Channels'
  AuthMiddleware rejecting on Origin / Host / session), saltare now
  maps the WebSocket close code to a meaningful HTTP status instead
  of a flat 403: `4001 → 401`, `4002 → 402`, `4003 → 403`,
  `4004 → 404`, `4008 → 408`, `4029 → 429`, anything else → 403.
  RFC 6455 §7.4 reserves 4000–4999 for app use; Channels uses
  exactly this range, so a Channels-rejected upgrade now surfaces
  the consumer's real intent at the HTTP layer.
- **`--ws-reject-log`** — opt-in stderr line every time a WS upgrade
  is rejected: `saltare: ws-reject path=/ws/foo code=4003 reason=Origin`.
  Diagnoses Channels' middleware closing connects without attaching
  a debugger. Off by default; zero overhead when off.
- **`tests/test_channels.py`** — integration tests verifying
  `ProtocolTypeRouter({"websocket": URLRouter(...)})` accepts an
  upgrade end-to-end and that consumers using `await self.close(code=4003)`
  produce HTTP 403, `code=4004` produces 404. Skipped automatically
  when `channels` isn't installed in the test environment.

### CI / release pipeline (`release.yml`)

- **Wheel matrix fan-out 2 → 4 jobs.** Was: one job per arch built
  all 10 wheels (5 Python versions × 2 libcs) serially → 11–20 min
  wall. Now: one job per `(libc, arch)` combo builds 5 wheels →
  ~7 min wall on each of 4 parallel runners (well under the
  GitHub-free-tier concurrency cap).
- **Test phase split out** (`CIBW_TEST_SKIP='*'`). cibuildwheel no
  longer reinstalls `pytest httpx fastapi websockets pytest-rerunfailures`
  inside every per-wheel container. A separate `test_wheels` job
  downloads the manylinux x86_64 wheel set and runs `pytest -q tests`
  against cp310 / cp312 / cp314 on lightweight `ubuntu-latest`
  runners. Catches ABI / import regressions without paying the
  per-wheel install tax 20× (5 Python × 4 (libc, arch)).
- **`pip` download cache** via `actions/cache@v4` keyed by
  `pyproject.toml` hash. Build-dep round-trip (`scikit-build-core`,
  `ninja`) skips PyPI on warm caches.
- **`publish` gated on `test_wheels`** — was previously gated only on
  `build_wheels` + `build_sdist`, meaning a broken-but-buildable
  wheel could ship to PyPI. Now the test stage must pass first.
- **manylinux_2_28 + musllinux_1_2 kept.** They're PyPI-compatibility
  tags, not arbitrary container choices; switching to plain
  Ubuntu/Alpine/Debian-slim would produce wheels PyPI rejects.
  Performance work is in matrix shape and the test-stage split,
  not the base image.

### Distribution

- **Regular Dockerfile (bench stage) preloads mimalloc**, matching
  `Dockerfile.production`. The bench numbers below run under the
  same allocator across saltare / uvicorn / granian — the comparison
  is now apples to apples instead of "saltare's `mallopt`-tuned
  glibc vs uvicorn/granian's untuned glibc". mimalloc cuts ~2 MiB
  off granian's peak on the sequential / idle-keepalive workloads;
  saltare's numbers are unchanged within noise (its `mallopt` +
  `MALLOC_ARENA_MAX=1` already drove glibc to behave as aggressively
  as mimalloc — the mimalloc win lives elsewhere, e.g. musl deployments).

## 1.6.1

**Theme**: access-log polish + small ops affordances.

### Default-on

- **Access-log line format changed from JSON to plain text.** The new
  shape is `DD/MM/YYYY:HH:MM:SS [METHOD] [URL] [STATUS] [BYTES]`
  (timestamp in local time). Easier to grep / awk / paste into an
  issue. Fields dropped from the line: `user_agent` and `latency_us`
  (use `--latency-histogram` on `/metrics` for distributions; UA was
  rarely actionable post-mortem).
- **Test isolation fix**: `_core.request_shutdown()` + pytest
  `conftest.py` autouse fixture clean up daemon-thread servers
  between tests. Closes a long-latent race that segfaulted cibuildwheel
  on cp313-musllinux after ~70 accumulated test daemons. `server.run()`
  also resets `g_draining=false` on entry so a fixture call without an
  active worker doesn't stick the next worker in immediate drain.
- **`test_caps::test_max_concurrent_connections_drops_extras`**:
  marked `flaky(reruns=3)` + scaled socket timeouts by `_TIMING_FACTOR`
  (2× on x86_64, 4× on aarch64). Race-condition tolerance for
  QEMU-emulated cibuildwheel runs.

### Opt-in flags

- **`--access-log-exclude PATH`** (repeatable) — exact-match request-
  target filter applied before the log emission. Typical: silence
  noisy probes (`/healthz`, `/metrics`, `/favicon.ico`,
  `/admin/drain`, `/debug/dispatch`) without losing visibility into
  app traffic. Linear scan per request; list size typically <10.

### Tests

108 total — 1 new at [tests/test_observability.py](tests/test_observability.py):
`access_log_exclude` silences listed paths without affecting the
status / body of the response itself.

## 1.6.0

**Theme**: complete the compression matrix + WebSocket extensions +
operational hardening (HSTS, drain endpoint, TLS / PROXY-protocol
observability, OpenMetrics 1.0 conformance).
v1.4 shipped one-shot brotli/zstd; v1.5 shipped streaming gzip;
v1.6 closes the diagonal — brotli + zstd now compress chunked
responses end-to-end, and WebSocket connections that offer
`permessage-deflate` get RFC 7692 compressed frames. v1.6 also
lands the deployment knobs ops asked for: a Strict-Transport-Security
header, an HTTP graceful-drain trigger to pair with k8s rolling
deploys, and per-counter visibility into TLS handshakes / session
reuse and PROXY-protocol acceptance — closing observability gaps
that previously needed external tooling.

### Default-on (no flag)

- **Six v1.5-cycle bug fixes** rolled forward unchanged.

### Opt-in flags (no new flags; existing knobs apply)

- **Streaming brotli** — when `--response-brotli` is on and a response
  emits `more_body=True`, saltare carries a `BrotliEncoderState*`
  across `_send` calls (created via the new lazy-dlopen surface in
  [src/zig/brotli.zig](src/zig/brotli.zig); accessed from Python via
  `_core.brotli_stream_create` / `…compress` / `…destroy`). Per
  intermediate chunk: `BROTLI_OPERATION_FLUSH`. Final chunk:
  `BROTLI_OPERATION_FINISH`. Counters land on
  `saltare_response_compression_total{encoding="br"}` etc.
- **Streaming zstd** — same pattern, libzstd's `ZSTD_CCtx*` carried
  across `_send`. Per chunk: `ZSTD_e_flush`. Final: `ZSTD_e_end`.
  Note: streaming zstd may emit multiple concatenated frames; the
  one-shot `_core.zstd_decode` doesn't handle that, but standard
  zstd clients (curl --compressed, fetch, browsers) do.
- **WebSocket per-message-deflate** (RFC 7692) — when the client's
  upgrade carries `Sec-WebSocket-Extensions: permessage-deflate`,
  saltare:
  - echoes `permessage-deflate; client_no_context_takeover;
    server_no_context_takeover` in the 101 response (no shared
    sliding window across messages — simpler + lower per-conn RAM);
  - sets RSV1 on outbound text/binary frames; payload is raw-deflate
    + `Z_SYNC_FLUSH` minus the trailing 4-byte sync marker (per
    RFC 7692 §7.2.1);
  - inflates inbound frames whose RSV1 is set (`payload + b"\x00\x00\xff\xff"`
    fed to `zlib.decompressobj(-15).decompress(..., max_size=1 MiB)` —
    zip-bomb capped). Malformed compressed frames close the
    connection.
  WS-frame builder in `_dispatcher.py::_build_server_frame` gains an
  `rsv1: bool` parameter; framing for non-pmd connections is
  byte-identical to v1.5.

### Cross-cutting Zig API additions

- [src/zig/brotli.zig](src/zig/brotli.zig): `streamCreate`,
  `streamCompress`, `streamDestroy` + new func-table entries
  (`BrotliEncoderCreateInstance` / `…SetParameter` / `…CompressStream`
  / `…HasMoreOutput` / `…TakeOutput` / `…DestroyInstance`).
- [src/zig/zstd.zig](src/zig/zstd.zig): `streamCreate`, `streamCompress`,
  `streamDestroy` + `ZSTD_createCCtx` / `ZSTD_freeCCtx` /
  `ZSTD_CCtx_setParameter` / `ZSTD_compressStream2` plus
  `ZstdInBuffer` / `ZstdOutBuffer` extern structs.
- [src/zig/ws.zig](src/zig/ws.zig): `Header.rsv1` field surfaced from
  the wire (bit 6 of byte 0).
- [src/zig/server.zig](src/zig/server.zig): `Connection.ws_pmd_active`
  + `ws_frag_rsv1` (fragment-reassembly tracks the start frame's
  rsv1).
- [src/zig/bridge.zig](src/zig/bridge.zig): `WsOpen` extended with
  `extensions: []u8` + `pmd_active: bool`. `wsEvent` signature gains
  `rsv1: bool` (Python side: `ws_event(handle, opcode, payload, rsv1)`).

### Operational additions (v1.6 polish)

- **`--hsts-max-age SECS`** + **`--hsts-include-subdomains`** +
  **`--hsts-preload`** — emits a pre-rendered
  `Strict-Transport-Security` header line on every response. RFC 6797.
  Empty by default (zero per-response cost). Operator-owned: we don't
  gate on `scope["scheme"]` because real deployments terminate TLS at
  a reverse proxy and saltare sees plain HTTP via X-Forwarded-Proto.
- **`--drain-path PATH`** — POST/PUT to PATH (e.g. `/admin/drain`)
  flips the worker into the same graceful-drain mode SIGTERM
  triggers: stop accepting, let in-flight finish, exit cleanly. GET
  is an idempotent state probe; other verbs return 405. Pair with
  `--health-path` so k8s readiness fails before connections drain
  out — closes the v1.5 SIGHUP gap (config reload only, not
  lifecycle). Zig-side intercept; no Python dispatch.
- **TLS metrics on `/metrics`** —
  `saltare_tls_handshakes_total` + `saltare_tls_session_reuse_total`.
  Emitted only when TLS is configured for the worker. Direct
  evidence of whether `--tls-session-cache-size` is paying its
  keep, and a sanity check that connections actually negotiated
  TLS rather than falling through to plaintext. Reused-session
  detection via lazy `dlsym("SSL_session_reused")`.
- **PROXY-protocol counters on `/metrics`** —
  `saltare_proxy_protocol_accepted_total{version="v1|v2"}`. Emitted
  only when `--proxy-protocol` is on. v1 (text) and v2 (binary)
  paths increment independently; either being non-zero confirms the
  L4 LB integration is actually reaching saltare.
- **OpenMetrics `# EOF` marker** — every `/metrics` body ends with
  `# EOF\n`. Prometheus 2.x already accepts it; openmetrics-client /
  m3 / strict OpenMetrics 1.0 tooling required it. Three bytes.

### Tests

108 total — 6 new at [tests/test_v16.py](tests/test_v16.py) for the
compression / WS pmd diagonal (streaming brotli body decoded,
streaming zstd header check, WS pmd handshake echoes the extension,
WS no-pmd doesn't, WS pmd outbound RSV1 + decompresses to the
original, WS pmd inbound inflates a client-compressed frame) plus 5
covering the operational additions: HSTS header rendered with
includeSubDomains + preload, HSTS off when max-age=0, OpenMetrics
EOF marker present on `/metrics`, drain endpoint GET returns the
state without flipping, drain endpoint DELETE returns 405 with an
`Allow:` header.

Brotli + zstd tests skip gracefully when libbrotlienc / libzstd
aren't present in the test image (test-image dnf only lazy-deps
manylinux core + the libs are not vendored to the wheel — the
production Alpine image is where they're bundled).

### Bench

No bench delta vs v1.5 — every new feature is opt-in, and when off
the dispatcher path is byte-identical (`if not self.pmd_active` /
`if not self._brotli_handle` early-outs).

### Deferred to v1.7+

- HTTP/2 + ALPN (~3-4 weeks; nghttp2 + HPACK + multiplex state
  machine).
- io_uring event loop (~2-3 weeks; eventloop.zig rewrite).
- macOS port (~3-5 days; kqueue + Linux-isms).
- OTLP exporter (~2-3 days; protobuf hand-roll).
- HTTP/3 / QUIC (~months; v2.0 territory).



## 1.5.0

**Theme**: operational depth + distribution reach. Saltare now ships
musllinux wheels alongside manylinux, exposes a runtime introspection
endpoint and SIGHUP-driven hot config reload, and surfaces compression
counters on `/metrics`.

### Default-on (no flag)

- **Six v1.4-cycle bug fixes** rolled forward into the v1.5 baseline:
  HEAD body strip in `serveSendfile`, supervisor SIGTERM forwarding,
  `_pending_sendfiles` cleanup on abort, out-of-range encoder param
  warnings, codec-probe safe defaults, sendfile + head-write EINTR
  retry. See [README "Roadmap"](README.md#roadmap) for the catalogue.

### Opt-in flags

- **`--dispatch-path PATH`** — JSON dispatch-state snapshot endpoint
  (typical `/debug/dispatch`). Same fields as the SIGUSR1 stats dump
  but reachable from a probe / curl. No GIL acquired — even a
  deadlocked dispatcher answers the probe. Off by default.
- **`--runtime-config-path FILE`** — `key=value` file re-read on
  `SIGHUP`. Subset of `Limits` / `Observability` is hot-swappable
  without a restart: `rate_limit_per_sec`, `rate_limit_burst`,
  `max_connections_per_ip`, `max_connection_lifetime_secs`,
  `access_log`. Unknown keys + parse errors log a warning and keep
  the previous value. Off by default.

### Default-on (when an encoder is enabled)

- **`process_*` Prometheus metrics** on `/metrics` — `process_open_fds`,
  `process_start_time_seconds`, `process_cpu_seconds_total`. Mirrors
  the conventions Grafana / Prometheus dashboards already understand.
  Read directly from `/proc/self/fd` and `/proc/self/stat` in Zig (no
  GIL on scrape).
- **`--dispatch-token TOKEN`** — Bearer-token gate on
  `/debug/dispatch`. When set, requests without
  `Authorization: Bearer <token>` get 401. Constant-time compare so
  length doesn't leak. Also reads from `SALTARE_DISPATCH_TOKEN` env
  var (preferred in production — keeps the secret out of `ps aux`
  and k8s audit logs).
- **`saltare --check-config FILE`** — dry-run validates a
  `--runtime-config-path` file before sending SIGHUP. Reports
  unknown keys, malformed lines, type errors. Exit 0 on clean
  parse, 1 on any error. Matches the Zig-side recogniser in
  `applyRuntimeKey`.
- **Boot-time warning on `--rate-limit-per-sec < 10`** — defends
  against typo footguns ("ratelimit=1 per second" vs the intended
  "100"). Single stderr line; user can ignore if intentional.
- **TLS smoke under musl** — `scripts/smoke-alpine.sh` now also
  generates a self-signed cert + curl HTTPS, verifying the lazy
  `dlopen("libssl.so.3")` resolves correctly on Alpine before any
  prod traffic touches the deployment.
- **`--ktls`** — kernel-TLS offload via `SSL_OP_ENABLE_KTLS` +
  `SSL_OP_ENABLE_KTLS_TX_ZEROCOPY_SENDFILE`. After the OpenSSL
  handshake, cipher state is pushed into the kernel; subsequent
  writes go straight from kernel buffers to the wire and `sendfile(2)`
  works on TLS sockets. Closes the v1.4 gap where `serveSendfile`
  returned 500 on HTTPS connections. Requires OpenSSL ≥ 3.0 and
  Linux ≥ 4.13 (5.2+ for AES-256-GCM); the option is silently ignored
  on older OpenSSLs (the bit is 0) so the wheel stays portable.
  Off by default — when off, TLS path is unchanged from v1.4 and
  `serveSendfile` keeps returning 500 over HTTPS.
- **`/metrics` response-compression counters** —
  `saltare_response_compression_total{encoding}`,
  `saltare_response_compression_bytes_in_total{encoding}`,
  `saltare_response_compression_bytes_out_total{encoding}`,
  `saltare_response_compression_skipped_total{reason}`. Reasons:
  `small_body`, `non_compressible`, `encoder_unavailable`,
  `not_smaller`. Counters live in Zig (no GIL on scrape).

### Distribution

- **musllinux wheels** added to cibuildwheel matrix
  (`musllinux_1_2_x86_64` + `musllinux_1_2_aarch64`). Alpine-based
  containers and distroless sidecars now have a native wheel.
- **`pytest-rerunfailures`** added to the test extras. The previously
  skipped `test_large_streaming_response_is_complete` runs again with
  3 reruns instead of being permanently disabled — flakiness goes
  through the retry loop on busy hosts but real regressions still
  surface.
### Deferred to v1.5.x

- **Streaming brotli + zstd** — gzip streaming works (per-chunk
  `Z_SYNC_FLUSH`); brotli + zstd streaming need per-codec encoder
  state across `_send` calls. v1.5.x.
- **OpenTelemetry OTLP exporter** — full OTLP needs protobuf
  encoding (or JSON-OTLP), retry/backoff, span correlation. Scope
  is multi-day. v1.5.x.
- **macOS kqueue port** — codebase has Linux-isms beyond `eventloop.zig`
  (epoll constants, `sys/sendfile.h`, `sys/prctl.h`, `MAP_POPULATE`).
  Real port is a v1.6 milestone, not a stub.

### Tests + tooling

96 total: same coverage as v1.4 + 5 new at
[tests/test_v15.py](tests/test_v15.py) (`/debug/dispatch` snapshot,
token-auth path, `/metrics` compression counters when gzip enabled,
`process_*` metrics, SIGHUP runtime reload via subprocess).

New tooling:

- **`scripts/smoke-alpine.sh`** — runs the freshly-built musllinux
  wheel inside an Alpine container, hits `/`, `/metrics`,
  `/debug/dispatch`, fails on any non-2xx. Catches dynamic-linker /
  libc regressions cibuildwheel's manylinux test stage misses.
- **`benchmarks/soak.py`** — sustained-load harness (default 1800 s
  at 200 rps). Samples RSS every 5 s, fails when post-warmup drift
  exceeds `--drift-mib` (default 20 MiB). Wired in `make soak`.
- **`make smoke-alpine`** + **`make soak`** Make targets.

Bench (same host, manylinux_2_28_x86_64, CPython 3.14.4):

```
sequential    : 46.32 MiB  (uvicorn 48.46, granian 56.87)
concurrent    : 45.00 MiB  (uvicorn 49.34, granian 50.83)
idle-keepalive: 45.05 MiB  (uvicorn 53.93, granian 49.86)
4-worker Pss  : 4.77 MiB / extra worker
```

Saltare leanest on every workload. The new operational features cost
zero RAM when off (each is a `null` pointer / atomic-zero counter).

### Tier-1 still pending — v1.6+

- **HTTP/2 + ALPN** via `nghttp2` (multi-week wire-format work).
- **`io_uring` event loop** (Linux ≥ 5.4) — replaces epoll on hot
  path.
- **kTLS** — kernel TLS for sendfile-over-HTTPS.
- **WebSocket per-message-deflate** — handshake negotiation + rsv1
  framing in `ws.zig`. Touches the WS frame builder deeply.



All user-visible changes per release. The headline number is the wheel version
(`pyproject.toml`); the dates are the tag dates. Items marked `default-on`
take effect for every deployment that pulls the new wheel; items marked
`opt-in` need an explicit flag and stay zero-cost when off.

## 1.4.0

**Theme**: lift the body-size ceiling, add a full content-encoding suite
(gzip / brotli / zstd), wire request-shape hardening (414 / 431), and
ship operator-grade observability (W3C Trace Context, Prometheus
latency histogram). All compression codecs use the lazy
`dlopen`-on-first-call pattern — plain-HTTP / no-compression deployments
keep the v1.3 RAM floor unchanged.

### Default-on (no flag)

- **Request body streaming** — dispatcher engages an ASGI streaming
  path when declared `Content-Length` exceeds the read buffer. App
  sees `http.request{body=chunk, more_body=True}` events; per-task
  RAM stays bounded by the 64 KiB backpressure threshold instead of
  the body's declared size. (Was: 413 above 16 KiB.)
- **cgroup-v2 memory awareness** — `max_concurrent_connections` auto-
  tunes from `/sys/fs/cgroup/memory.max` (or v1's
  `memory.limit_in_bytes`) when the operator hasn't set it explicitly.
  Reserves a 64 MiB floor for Python heap + libs, budgets the rest at
  ~50 KiB per concurrent. Logged at startup.
- **mimalloc default** in `Dockerfile.production` (jemalloc fallback
  if mimalloc isn't packaged). ~5 MiB lower steady-state vs glibc.
- **`.pyc` precompile** in the `Dockerfile` builder stage
  (`python -OO -m compileall src/saltare ... optimize=2`). Wheel ships
  with `__pycache__/*.opt-2.pyc` — first-request import latency drops.
- **5-second `tracemalloc` snapshot cache** — `dump_tracemalloc`
  caches the rendered top-30 list; monitoring agents on a 1 s scrape
  no longer block the dispatch loop for 10–50 ms per call.
- **HTTP/1.0 keep-alive** — RFC 7230 §6.3 honoured: `Connection:
  keep-alive` on a 1.0 request keeps the connection open. (Was
  already correct; verified by test in this release.)

### Opt-in flags

- **`saltare.sendfile` ASGI extension** — apps emit
  `{"type": "saltare.sendfile", "path": "/var/www/big.bin", "status":
  200, "headers": [...]}` in lieu of `http.response.start +
  http.response.body`. Zig opens the file, builds the head, and uses
  `sendfile(2)` directly to the socket — bytes never enter Python.
  Plain-HTTP only; TLS path returns 500 (kTLS not wired).
- **`--response-gzip`** — single-shot **and** chunked-streaming gzip.
  Streaming path uses `Z_SYNC_FLUSH` per intermediate chunk +
  `Z_FINISH` at end. `--response-gzip-min-bytes` (default 512),
  `--response-gzip-level` (default 6).
- **`--response-brotli`** — single-shot brotli. Lazy
  `dlopen("libbrotlienc.so.1")`. `--response-brotli-quality 0-11`
  (default 4).
- **`--response-zstd`** — single-shot zstd. Lazy
  `dlopen("libzstd.so.1")`. `--response-zstd-level 1-22` (default 3).
- **`--request-decompression`** — request bodies with
  `Content-Encoding: gzip` are decompressed before the app's first
  `await receive()`. Capped at `--max-request-body` (zip-bomb defense
  → 413 on overflow).
- **`--max-request-uri`** — request-line targets longer than the cap
  return 414 URI Too Long (default 8192).
- **`--max-request-head-bytes`** — total head-section bytes past the
  cap return 431 Request Header Fields Too Large (0 = pool-buffer
  ceiling).
- **`--latency-histogram`** — Prometheus
  `saltare_request_duration_seconds_bucket` with 14 fixed buckets
  (1 ms..60 s) + `_sum` + `_count` on `/metrics`. ~140 B per worker.
- **`--traceparent-propagation`** — W3C Trace Context on
  `scope["traceparent"]` / `scope["tracestate"]` and echoed back on
  the response. Length cap on echo defends against header smuggling.
- **`saltare[django]` extra** — `pip install saltare[django]` pulls
  Django ≥ 4.2 alongside saltare and unlocks
  `saltare.contrib.django`. Adding `"saltare.contrib.django"` to
  `INSTALLED_APPS` (after `django.contrib.staticfiles`) overrides
  `manage.py runserver` so dev traffic flows through saltare's
  epoll/Zig core instead of `wsgiref`. Autoreload, `--noreload`, and
  `STATIC_URL` (via `ASGIStaticFilesHandler` in `DEBUG`) keep
  working. ASGI app resolution: `SALTARE_ASGI_APPLICATION` →
  `ASGI_APPLICATION` → `get_asgi_application()`. Dev-only — production
  still calls the `saltare` CLI directly, no Django dep at runtime.
- **`--reload` autoreload** — parent process supervises a saltare
  child, polls watch dirs for `*.py` mtime changes (default 0.5 s),
  `SIGTERM` + respawn on change. Same shutdown path as production.
  Poll-based (no `inotify` dep) so it works inside containers /
  overlayfs / NFS without surprises. Sensible default excludes
  (`__pycache__`, `.git`, `.venv`, `node_modules`, IDE caches).
  Crash-loop guard: a syntax error in the child waits for the next
  file change before respawn instead of pegging CPU. `--workers > 1`
  is auto-coerced to 1 (reloader + pre-fork supervisor can't share
  the listen socket). `__pycache__` is purged between respawns so
  saltare's `PYTHONOPTIMIZE=2`-baked `.opt-2.pyc` files (keyed by
  second-resolution mtime) don't shadow sub-second edits.
  Implementation: `src/saltare/_reload.py`. Flags: `--reload`,
  `--reload-dir DIR` (repeatable), `--reload-include GLOB`,
  `--reload-exclude GLOB`, `--reload-poll-secs SECS`.

### Compression negotiation

`Accept-Encoding` parsed per RFC 7231 §5.3.4: `q=0` tokens are
dropped, `*` wildcard expands to "any other enabled encoder". When
the request offers multiple acceptable encodings with equal client
weight, server preference is **br > zstd > gzip** (br compresses
tightest for text; zstd is fastest; gzip is the universal fallback).
Disabled encoders are silently skipped — when `--response-brotli` is
on but `libbrotlienc` isn't loadable, the encoder call returns None
and the response is sent identity. A startup-time check warns once
per worker when an enabled codec's library is absent.

### Tests

99 total: 66 core + 10 v1.3 + 8 v1.4 zlib (`tests/test_v14_zlib.py`)
+ 11 v1.4 extras (`tests/test_v14_extras.py`) + 4 v1.4 sendfile
(`tests/test_v14_sendfile.py`). New coverage: 414/431 caps,
traceparent on/off, latency histogram, streaming gzip,
encoder-negotiation logic, `saltare.sendfile` GET/HEAD/404, app
Content-Length override.

### Benchmarks (same host, manylinux_2_28_x86_64, CPython 3.14.4)

```
sequential    : 46.52 MiB  (uvicorn 48.91, granian 52.90)
concurrent    : 45.24 MiB  (uvicorn 49.86, granian 50.26)
idle-keepalive: 45.29 MiB  (uvicorn 54.55, granian 49.78)
4-worker Pss  : 4.72 MiB / extra worker
```

Saltare leanest on every workload. The full compression matrix did
not regress the floor — codecs are dlopen-lazy and stay unmapped
when their flag is off.

### Deferred to v1.4.x

- **WebSocket per-message-deflate** (RFC 7692). HTTP-side zlib infra
  is reusable; missing piece is rsv1 framing + handshake negotiation
  in `ws.zig`.
- **Streaming brotli + zstd** — single-shot only in v1.4. Streaming
  encoders need per-state objects across `_send` calls (analogous to
  the `_gzip_co` design).

## 1.3.0

Lazy-loaded TLS + ~40 operational knobs. See README "Roadmap" → v1.3.0
for the full enumeration.

## 1.2.x and earlier

See README "Roadmap" for per-version details.
