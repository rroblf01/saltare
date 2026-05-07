# Changelog

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
