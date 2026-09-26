# Changelog

## 1.12.0

**Theme: the server runs on macOS.** After being epoll-only since v0.4, saltare
now has a kqueue backend and ships `macosx_11_0_arm64` wheels. The release
also pays down a category of debt this repo had accumulated — features
with a README section, a CLI flag, and no test that ever reached them —
because two of the gaps turned out to be real bugs.

### macOS arm64

- **kqueue event loop** (`src/zig/eventloop_kqueue.zig`, new). The epoll
  implementation moved verbatim to `eventloop_epoll.zig`; `eventloop.zig`
  now picks a backend at comptime and re-exports the winner, which is why
  `server.zig` is **unchanged** by the port. It imported `"eventloop.zig"`
  and used only `Loop`, `Loop.init` and the `add`/`modify`/`remove`/
  `wait`/`deinit` methods plus the `runtime` field, so the re-export hands
  it literally the backend's own type: same layout, no vtable, no tag
  check, and **not one branch on the OS in the event path**. That mattered
  enough to rule out the obvious alternative — one `Loop` with a union and
  a branch per method — against a project whose goal is minimum RAM and
  maximum req/sec. 113 call sites in `server.zig` were left alone.

  Three real differences the backend absorbs, none of which leak upward:
  kqueue interest is *per-filter* rather than a bitmask, so dropping an
  interest is an explicit `EV_DELETE` where epoll's `EPOLL_CTL_MOD` would
  replace the whole mask in one call; hangups arrive as `EV_EOF` on a
  filter rather than `EPOLLRDHUP`/`EPOLLHUP` bits; and the timeout is a
  `struct timespec` or `NULL`, not milliseconds. Both are level-triggered,
  so the connection state machine's discipline about only arming write
  interest when a write actually blocks carries over unchanged.

- **The Linux-isms**, each verified against the headers Zig bundles for
  Darwin rather than from memory:
  - `SOCK_NONBLOCK` and `SOCK_CLOEXEC` are Linux extensions to `socket(2)`
    and Darwin defines neither, so this was a **compile** failure, not a
    runtime one. New `socketNonBlock()` / `acceptOne()` helpers keep a
    single call site and reach the same end state through `fcntl(2)`.
  - `TCP_KEEPIDLE` is Linux's name for what Darwin calls `TCP_KEEPALIVE`.
    `TCP_KEEPINTVL` and `TCP_KEEPCNT` keep their names on both.
  - `TCP_USER_TIMEOUT` has no portable equivalent and is skipped off Linux.
    The keepalive cadence above still bounds how long a dead peer is held.
  - `pool.zig`'s `madvise` advice moves to `MADV_FREE`, the Darwin call that
    actually returns pages. The sweep used to be a no-op off Linux, so
    long-idle pool buffers held their pages on macOS — quietly undoing part
    of the reason they exist.
  - `sys/sendfile.h` is no longer cimport'd. The two `sendfile(2)`
    signatures are incompatible and, more importantly, Linux takes a
    **pointer** to the offset and advances it for you, while Darwin takes
    the offset **by value** and only honours it on the first call of a
    stream. `sendFileChunk()` normalises both into "give me the next chunk
    from this offset", so the caller's loop is identical on either platform.
  - `sys/prctl.h` is no longer cimport'd either; `prctl` is declared by
    hand, the same way `accept4` already was. A top-level `@cImport` of a
    header the other platform lacks fails the build *before any of our own
    code runs*, which is how these two had to go.
  - `dlopen` gained the `.dylib` names for libssl, libz, libbrotli and
    libzstd. Each list is already "first one that loads", so this is purely
    additive — and without it TLS and every compression codec are silent
    no-ops on macOS: `newContext` fails, the server starts in plain-HTTP
    mode, and the only signal is a stderr warning.

- **`process_*` metrics stop being hardcoded 0 off Linux.** Resident
  memory, open fds and CPU seconds read through
  `proc_pidinfo(PROC_PIDTASKINFO)`, `proc_pidinfo(PROC_PIDLISTFDS)` and
  `getrusage`. On a server whose pitch is RAM and observability, three
  series that are permanently zero in `/metrics` is the worst failure mode
  available: in a dashboard it is indistinguishable from a process using
  no memory at all. `libproc.h` is deliberately *not* cimport'd — it
  transitively includes the Mach headers, and Zig's `translate-c` dies on
  their static assertions over descriptor types it models as `opaque`.
  `sys/proc_info.h` declares everything needed on its own, so only
  `proc_pidinfo` is hand-declared; it lives in libSystem, so nothing extra
  is linked.

- **Verification.** `make check-macos` cross-compile-checks the 17 Zig
  modules that do not need a macOS `Python.h` against `aarch64-macos`, and
  is wired into the local loop so a Darwin-only compile error surfaces in
  seconds rather than on a Mac. `server.zig` cannot be fully checked from
  Linux (`bridge.zig` needs a macOS `Python.h`), so it was forced through
  by `export fn`-ing wrappers that actually *call* `run()` and
  `bindAndListen()` — merely referencing them is not enough, Zig will not
  generate the body and the check silently passes on a 1.8 KB stub. That
  found and fixed **seven** compile errors before a wheel was ever built:
  the two `SOCK_*` flags, a missing `fcntl.h`, a variadic literal needing a
  cast, `ident` being `usize` rather than `c_int`, a nonexistent `ext` field
  in `struct kevent`, `kevent`'s arity, and `accept(2)`'s concrete
  `struct sockaddr *` parameter. `module.zig` is the one file still
  unverifiable locally, so the new `test_macos` CI job — and the
  `publish` gate that depends on it — is its real coverage.

### Fixed

Both of these were found by writing the tests the features never had.
Neither would have been caught by the existing suite.

- **A request arriving in the same packet as a PROXY-protocol header hung
  until the header timeout** (`server.zig`). Present since v1.3. An L4
  load balancer that coalesces the PROXY header and the client's request
  into one segment produced a connection that was never answered.
  `doProxyV1` compacted the leftover request bytes to offset 0 and then
  called `doReadHttp`, but `doReadHttp`'s loop always attempts a read
  *before* it parses and bails out on `EAGAIN` — so with the request head
  already in the buffer, `connRead` returned `EAGAIN` and the function
  returned without ever parsing it. No further read event was coming,
  because those bytes were in userspace rather than the kernel. Fixed by
  using `tryParsePipelined`, the codebase's existing entry point for "a
  request is already fully buffered" (`keepAliveReset` uses it for the same
  reason). A PROXY header split across reads still works, because
  `tryParsePipelined` leaves the connection registered for read when the
  head turns out to be incomplete.

- **Synthesized 500 responses carried no `Server-Timing` and no
  `X-Request-ID`** (`_dispatcher.py`). A 500 emitted because an app raised
  is built by `_build_wire`, a different function from the one that
  assembles normal response heads, so it skipped every optional header. The
  request that blew up — the one whose duration and identity you want when
  reading a trace — was the one request with neither. Both 500 paths now
  share a single `_observability_header_lines()` helper with
  `_emit_headers`, so the paths cannot drift apart again. The helper
  early-returns a shared empty tuple when every optional header is off,
  which is the default, so the common path allocates nothing beyond the
  status line it already built.

### Test debt paid

61 new tests, all for features that were documented and shipped but
untested. Each was checked for *discriminating power*, not just coverage —
a test that passes whether or not the feature works is worse than no test,
because it looks like coverage.

- **PROXY protocol v1 + v2** (21 tests). Zero coverage for a feature that
  rewrites the connection's peer address, which is the address the per-IP
  rate limiter, the per-IP connection cap and the access log all key on.
  The rate limiter is the black-box observable, since `rateLimitAllow` keys
  on `conn.peer_key`; the discriminating case is two connections claiming
  *different* sources, which must get independent buckets. Also covers
  `UNKNOWN` and v2 `LOCAL` falling back to the TCP peer, one-write vs split
  framing, malformed headers, and the documented
  `saltare_proxy_protocol_accepted_total` counters.
- **mTLS** (7 tests). `ssl_ca_file` + `ssl_verify_client` had none, and it
  is the feature most likely to be misconfigured in production since it
  decides whether a client may connect at all. Pins the full matrix,
  including that an unreadable `ssl_ca_file` aborts startup rather than
  leaving the server up with verification silently off. One assertion is
  deliberately weak in shape but strict in meaning: a rejection under
  TLS 1.3 arrives as a *successful* handshake followed by a dropped
  connection, because the client certificate is verified after the server
  has already sent its Finished, so the invariant is "not served" rather
  than "raised SSLError".
- **`Server-Timing` / `X-Request-ID`** (12 tests). Previously only the
  setters were called. Includes the 500-path regression above and a check
  that a custom `request_id_header` name is honoured without the default
  leaking.
- **WebSocket permessage-deflate over the wire** (13 tests). The existing
  coverage drove `_pmd_deflate`/`_pmd_inflate` directly, which proves the
  codecs round-trip but not that the server *applies* them: nothing checked
  the extension token in the 101 head, the RSV1 bit on frames the server
  emits, or the `ws_compression_level` / `ws_compression_server_takeover`
  kwargs, which no test passed at all. Uses raw sockets rather than the
  `websockets` library on purpose — the five permanently-skipped tests in
  `tests/test_websocket.py` exist because multiple WS tests in one pytest
  process hit a daemon-thread teardown segfault, and raw sockets avoid it.
- **Operational knobs** (17 tests). `max_connection_lifetime` was present
  in `test_cli_unit.py`, which proves the flag parses and nothing else.
  Covers the lifetime cap, `access_log_path` (asserted by content, since an
  fd opened but never written is the obvious silent failure),
  `http_pool_max` across its range, `startup_request`, `auto_raise_nofile`,
  `tls_session_cache_size`, `ktls` degradation, and the documented 500 for
  `sendfile` over HTTPS without kTLS. The pure socket-tuning knobs are
  deliberately absent — their effect is in the kernel, so a test would be
  asserting on the kernel.
- **Platform** (7 tests). The platform gate itself, and the documented
  per-platform degradations, so "works everywhere" is not claimed for
  something that quietly no-ops.

Suite: **467 passing**, 7 skipped, from 368.

### Where the RAM actually goes — and the one lever left

Before optimising anything it is worth knowing what the floor is made of.
Measured on this host, a running server with the FastAPI benchmark app:

| component | RSS | share |
|---|---:|---:|
| CPython 3.14 interpreter | 15.20 MiB | 31% |
| `import fastapi` (starlette, pydantic, pydantic-core) | 29.38 MiB | 59% |
| building the app (routes, validators) | 2.25 MiB | 5% |
| **saltare running** | **2.78 MiB** | **6%** |

So the answer to "is there RAM left to save" is mostly *not in the
server*. saltare's own cost is 2.78 MiB, of which the Zig core's
zero-initialised globals (`.bss` 129 KiB + `.tbss` 256 KiB) are 385 KiB —
there is no large static allocation left to attack. Per-connection cost is
~1 KiB: 500 idle keep-alive connections add 0.5 MiB in total. The
remaining 94% is CPython plus the framework's import, and the only lever a
server has over that is not mapping libraries it does not need — which is
why OpenSSL and the codecs are `dlopen`'d rather than linked.

### Added: `saltare.optimize_process()` — 1.06 MiB, free

The one measurable win left, and it was a gap rather than an optimisation.
v1.3 made the CLI re-exec itself under `python -OO` with
`MALLOC_ARENA_MAX=1`, worth ~1.4 MiB once FastAPI's docstrings are
resident. But that re-exec is deliberately gated on saltare being the
genuine main entry — the gate exists because a naive argv check once
hijacked `pytest` and other tools launched from a directory whose name
contained "saltare" — so **anybody embedding the server in their own
script got none of it**. That is exactly the `saltare.contrib.django`
audience and the programmatic case the macOS work was partly for.

`optimize_process()` is the explicit opt-in: it re-execs *your* script
under `-OO` instead. Measured end to end with a real entry-point script
serving the FastAPI benchmark app, three samples each with no overlap in
the distributions:

| | RSS | optimize level |
|---|---:|---:|
| without | 49.63 MiB | 0 |
| with | **48.57 MiB** | 2 |

The mechanics moved to `saltare/_optimize.py`, which has no import-time
side effects, so the CLI and the new public function share one
implementation rather than two that can drift. It declines under
`python -c` / `python -` / the REPL (no script to re-run), when already
optimized, when `SALTARE_REEXECED=1` (so a second call cannot loop), and
when `SALTARE_NO_OPTIMIZE=1`. `MALLOC_ARENA_MAX` and `PYTHONFAULTHANDLER`
are applied with `setdefault` so an operator's deliberate values survive;
`PYTHONOPTIMIZE` is forced, since that is the entire point.

It returns `None` in every case, deliberately: `os.execvpe` does not
return when it succeeds, so a "did it happen" return value would be
unobservable in the only case that matters. (The first draft returned
`bool` and was wrong — it reported `False` on the stubbed-exec path, which
is what surfaced the issue.)

`tests/test_cli_unit.py` needed one line. It loads `cli.py` by path with a
mocked `saltare` module in `sys.modules`, and resolving the new
`from saltare import _optimize` needs `__path__` on that mock. Without it
the import raised, the mock was never restored, and every test module
collected after it failed. Pointing the mock at the real package
directory fixes it and keeps it working as `cli.py` grows further imports
instead of needing a new mock attribute each time.

### Performance verified, not assumed

The v1.12 changes touch the response hot path — `_emit_headers` now shares
one helper with the 500 path — so throughput and RSS were measured rather
than assumed. Method: alternating A/B against v1.11.0 (`0f77a05`) with a
full Zig rebuild between every switch, so machine drift cancels instead of
accumulating, five samples per version, FastAPI via `benchmarks/bench.py`.

| metric | 1.11.0 | 1.12.0 | verdict |
|---|---:|---:|---|
| idle RSS | 50.86 MiB | 50.81 MiB | unchanged (−0.05) |
| sequential rps (median) | 1056 | 1147 | +8.6 %, inside noise |
| uvicorn sequential rps (control) | 1163 | 1159 | −0.3 %, host was stable |

The rps delta is **not** a result: the pooled standard deviation across both
versions is ~8 %, and 4 of 5 HEAD runs beat the BASE median while only 1 of 5
BASE runs beat the HEAD median. The honest reading is that the port and the
dispatcher refactor are performance-neutral, with RAM flat to within 0.05 MiB
and throughput flat within the measurement band.

Two caveats recorded so the numbers are not misread later:

- These were taken with **glibc's default allocator**. The published tables
  in the README are taken with mimalloc preloaded (the `bench` stage of the
  Dockerfile sets `LD_PRELOAD=libmimalloc.so.2`), which is worth roughly
  4–5 MiB of floor. That is why this host reads ~50.6 MiB idle where the
  README's v1.11.0 row reads 46.5 MiB — an allocator and host difference, not
  a regression, and the A/B above confirms it since 1.11.0 measures the same
  50.86 MiB here.
- On **this** host saltare's throughput advantage over uvicorn does **not**
  reproduce: it is roughly level on concurrent load and behind on sequential
  (+3 % / −24 % against uvicorn 0.54, versus the README's published lead).
  The RAM advantage reproduces clearly and at the published magnitude:
  3.1 MiB leaner at peak under sequential load, 3.9 MiB under concurrent
  load, and 8.2 MiB on the idle-keepalive workload where uvicorn's per-
  connection allocations dominate. The published rps numbers were measured on
  a different host with mimalloc in place; whether the throughput gap can be
  closed on a clean allocator is worth its own investigation and is not
  something this release claims to have solved.

### Build & CI

- **CI was not running the HTTP/2 suite at all.** `tests/test_http2.py`
  skips itself at module level via `importorskip("h2.connection")`, so a
  missing `h2` cannot fail the job — it just drops the whole suite,
  including the v1.11 flow-control coverage. Both runners (the `test_wheels`
  job and the Dockerfile `test-env` stage) installed everything from
  pyproject's cibuildwheel `test-requires` *except* `h2`. Added to both.
- **The Zig unit test suite was broken and nobody was running it.** Four of
  six files failed. `http.zig` did not even compile: the chunked-decode
  resume test copied a 12-byte tail into a 13-byte range, which Zig 0.16
  rejects. The WINDOW_UPDATE overflow test was asserting against
  `connection_window` after v1.11 moved peer updates onto the *send*
  window, so the production check correctly never fired. Worth recording
  how that one nearly went the wrong way: "fixing" it by relaxing the
  assertion would have locked in a real RFC 7540 §6.9.1 violation. Three
  tests were added around the refactored path.
- **`py.typed` now ships.** Without it type checkers ignored `_core.pyi`
  entirely and reported `saltare._core` as an untyped missing import. The
  stub had also drifted: `_core.serve` takes 54 positional args and the stub
  declared 47, stopping at `runtime_config_path`.
- **`uv sync` now produces a working dev environment.** It pruned
  `scikit-build-core` from the venv, because `[build-system].requires` is
  not a project dependency — so the next `uv pip install -e .` had no build
  backend and the Zig rebuild loop was broken after any sync. It also does
  not install extras, which is why a bare sync left you without pytest. A
  PEP 735 `[dependency-groups] dev` now carries the build backend and the
  test deps. It also pins `h2` and `pytest-rerunfailures`, which had only
  ever been in cibuildwheel's `test-requires`, so a clean sync silently
  lost the HTTP/2 suite and turned every `@pytest.mark.flaky` rerun into a
  no-op.
- The `openssl-devel` / `openssl-dev` installs in the Linux `before-all`
  hooks are gone. They have been dead weight since v1.3 made TLS
  dlopen-based; the comments claiming the build fails without them were
  wrong.

### Not built — and why (decision record)

- **x86_64 macOS wheels — declined.** They would have to be a Rosetta build
  on an arm64 runner, or a separate Intel runner for a platform with
  negligible usage. The distribution targets are Linux servers plus
  Apple-Silicon developer machines, and the `saltare.contrib.django`
  integration is the local-dev case that motivated macOS support in the
  first place — `manage.py runserver` replacing wsgiref — which is arm64 by
  definition on any current Mac.
- **`PR_SET_PDEATHSIG` equivalent on macOS — declined, documented instead.**
  The substitutes are a kqueue `EVFILT_PROC` watch on the parent pid or a
  Dispatch Source, and both require `master.zig` to own a kqueue descriptor
  and poll it. That is a larger change than a tidiness knob justifies.
  The consequence is real and stated plainly: a `SIGKILL`ed master can
  leave workers behind on macOS until their own idle timeouts fire — the
  same exposure a single-worker deployment already has when it is
  `SIGKILL`ed. `setProcName` is likewise a no-op there; Darwin's
  `setprogname(3)` only affects argv-adjacent reporting and is not worth a
  dependency for a cosmetic `ps` label.
- **kTLS on macOS — not attempted.** Kernel TLS offload is Linux-specific.
  The flag is accepted and ignored, and the sendfile-over-HTTPS path
  returns its documented 500, which is covered by a test.
- **cgroup-aware `max_concurrent_connections` on macOS — not applicable.**
  There is no cgroup; the reader returns null and the configured default is
  used. Harmless, and now pinned by a test.
- **Benchmarks on macOS — not run.** `benchmarks/bench.py` reads
  `/proc/<pid>/status` and `/proc/<pid>/smaps_rollup`, which do not exist
  on Darwin. The harness would need a Mach-based sampler to produce
  comparable numbers, and the RAM story this project is measured on is a
  Linux server story. The macOS wheels exist for developer machines, not
  as a benchmark target.

## 1.11.0

### HTTP/2 response framing — now real, was a stub

Before this release, `http2=True` over TLS never actually spoke HTTP/2. Two bugs hid each other: (1) the TLS layer advertised ALPN with `SSL_CTX_set_alpn_protos` — the *client*-offer API, a no-op on a server — so `h2` never negotiated and every "HTTP/2" connection silently fell back to HTTP/1.1; (2) the dispatch path that *would* have run had a `PyObject_CallFunction` format string with four `y#` byte-strings where the code passed five, so the first real HTTP/2 request would have segfaulted. The request-side HPACK decoder and frame parser were solid (v1.9/v1.10), but the response side emitted HTTP/1.1 bytes and `h2_encoder.zig` was dead code. This release makes the wire real, verified against the `h2` sans-IO client (GET, POST-with-body, and a 60 KiB multi-frame response):

- **Server-side ALPN selection** (`tls.zig`) — register `SSL_CTX_set_alpn_select_cb` to pick `h2` from the client's offer, gated on `http2=True` (the flag is now plumbed through `_core.serve` → `newContext`; it was previously declared on `run()` but never passed to the core). An h2-capable client against an `http2=false` server cleanly negotiates HTTP/1.1.
- **HTTP/1.1→HTTP/2 response transcoder** (`h2_response.zig`, new) — rather than teach the large, well-tested dispatcher a second wire format, a resumable state machine transcodes the HTTP/1.1 response bytes it already produces into HTTP/2 frames: status line → `:status` HPACK pseudo-header, header names lowercased, hop-by-hop headers (`connection`, `keep-alive`, `transfer-encoding`, `upgrade`, `proxy-connection`) dropped per RFC 7540 §8.1.2.2, chunked bodies de-framed, body split into DATA frames bounded by the peer's `SETTINGS_MAX_FRAME_SIZE`, and `END_STREAM` placed on the final frame. All the existing machinery (streaming, gzip, sendfile, content negotiation) is untouched. The previously-orphaned `h2_encoder.zig` now backs it. Unit-tested (`zig test`) against the real HPACK decoder + frame parser, plus the `h2`-client conformance tests.
- **Server connection preface** (`server.zig`, `h2.zig`) — emit the server's own SETTINGS frame as the connection preface (RFC 7540 §3.5) instead of a premature SETTINGS ACK (the old code ACK'd before any peer SETTINGS existed, which strict clients reject).
- **Write-path routing + per-stream lifecycle** (`server.zig`) — `.http2` connections now route writable events to `doWrite` (response frames queued in `write_buf` were never flushed before — the event dispatch sent every wake to the reader), carry a per-stream transcoder freed in `finishRequest`, and reset for the next stream in `.http2` instead of flipping to the HTTP/1.1 keep-alive path. `more_body` for the request body is now derived from the stream's `END_STREAM` (was hardcoded false, so a POST body never reached the app).
- **Outbound flow control** (RFC 7540 §6.9) — the server never sends more response DATA than the peer's stream and connection receive windows allow. The transcoder is seeded with the peer's `SETTINGS_INITIAL_WINDOW_SIZE`, decrements the stream and (shared) connection send windows as it emits DATA, and holds the rest when a window is exhausted; the peer's `WINDOW_UPDATE` frames grow the windows and resume sending. A stream is considered complete only when END_STREAM has actually gone out — not merely when the dispatcher finished — so flow-control-blocked bodies are never dropped. Verified by a conformance test that advertises a 1 KiB client window and pulls a 50 KiB body through dozens of WINDOW_UPDATE rounds. (Peer `WINDOW_UPDATE` was previously misrouted to the inbound receive window, where it was a harmless no-op; it now correctly grows the send window.)
- **Still serial**: one dispatch in flight per connection (no concurrent stream multiplexing), as before — a separate piece of work from the response framing landed here.

**Theme**: PEP 684 (per-interpreter GIL) support — `_core` can now be hosted in own-GIL sub-interpreters, verified end to end by running a full server in one. **But the measurement that motivated this work refuted its premise: sub-interpreter workers cost *more* RAM than saltare's pre-fork model, not less.** This release lands the capability (multi-phase init, per-interpreter state isolation, a re-entrant loop, the per-interpreter-GIL declaration, and a proven own-GIL serve path) and the measurement — and on the strength of that measurement, **does not** build the sub-interpreter worker spawner. Fork stays the multi-worker model.

The original hypothesis: pre-fork (`master.zig`) runs N OS processes each a full CPython; CPython's refcount writes dirty CoW-shared pages, so RSS diverges per worker; sub-interpreters (one process, N own-GIL interpreters) would share the interpreter's static/immortal objects and save several MiB of Pss per worker. The measurement (`benchmarks/` PSS comparison, CPython 3.14, trivial ASGI app) says the opposite:

| Workers | Sub-interpreters (one process) | Pre-fork (CoW) |
|--------:|-------------------------------:|---------------:|
| 2 | 37.1 MiB | 25.7 MiB |
| 4 | 59.0 MiB | 29.9 MiB |
| 8 | 101.6 MiB | 38.5 MiB |

Fork is **1.4×–2.6× leaner, and the gap widens with N**. Why: saltare already calls `gc.freeze()` before forking, which immortalises the bootstrap object graph so worker refcount writes never dirty those shared pages — CoW stays near-total (~2 MiB private per worker). Sub-interpreters *cannot* share the Python object graph — per-interpreter isolation is the entire point of own-GIL — so each re-imports `saltare`, `asyncio`, and the app from scratch (~12 MiB per worker). The optimisation saltare already shipped (`freeze()`) is exactly what makes the sub-interpreter RAM case a loss. Sub-interpreters also forfeit fork's crash isolation (one worker segfault would take down all of them in a shared process). The capability is kept (it has non-RAM uses: fork-unsafe deployments, eventual Windows support, faster worker spin-up), but it is not promoted to a worker model.

### Default-on

- **`_core` now uses multi-phase initialisation** (`module.zig`) — `PyInit__core` returns `PyModuleDef_Init(&def)` with a `Py_mod_exec` slot and `m_size = 0`, replacing the single-phase `PyModule_Create2`. Single-phase extensions are *rejected* by sub-interpreters, so this is the prerequisite for everything that follows. Single-interpreter behaviour is unchanged (full suite green); the new capability is that `saltare._core` can now be imported inside a **shared-GIL** sub-interpreter (`Py_NewInterpreter` / legacy `_interpreters` semantics). Verified by `tests/test_subinterp.py` on CPython 3.14.
- **Per-interpreter runtime state** (`server.zig`, `eventloop.zig`) — the event-loop state that genuinely cannot be shared across interpreters now lives in a per-serve `Runtime` struct instead of file-scope globals: the stalled-connection list (`stalled_head`), the live-WebSocket list (`ws_head`), and the loop-timing counters (`idle_ticks`, `last_ws_pump_ns`). These were mutated without atomics, so sharing them across two interpreter threads would have raced. The owning `Loop` carries an opaque `runtime` pointer and every `Connection` carries a `*Runtime`, so both loop-driven paths and `Connection.destroy` (which has no `loop`) reach it. No behaviour change for the single-interpreter / pre-fork paths (full suite green). The metrics atomics and read-only config stay process-global on purpose — atomics are thread-safe and sharing them yields *unified* process-wide `/metrics` (better than per-worker counters), and config is set once before any worker thread starts.
- **Re-entrant event loop** (`server.zig`) — `run()` is split into config-application + bind/listen (done once) and a new `serveLoop(listen_fd)` that owns its `Loop`, `Runtime`, buffer pool and timer wheel as locals and only *reads* shared set-once config and atomics. The single-worker and pre-fork paths call it once; an own-GIL sub-interpreter spawner will eventually call it once per thread. An audit confirmed every remaining global it touches (`g_tls_ctx`, `g_ktls_enabled`, `g_timeouts`/`g_limits`/`g_obs`, `g_server_line`, `g_access_log_fd`) is written only during run()'s set-once config phase and read-only inside the loop. No behaviour change for existing paths (full suite green).
- **Per-interpreter-GIL declared** (`module.zig`) — with the racy state isolated, the loop re-entrant, and the remaining globals confirmed atomic-or-set-once, `_core` now declares `Py_mod_multiple_interpreters = Py_MOD_PER_INTERPRETER_GIL_SUPPORTED` and `Py_mod_gil = Py_MOD_GIL_USED` (version-gated via `PY_VERSION_HEX`: the first on 3.12+, the second on 3.13+). This is the gateway CPython checks before importing an extension into an **own-GIL** interpreter. Verified end to end by `tests/test_subinterp.py`, which imports `saltare._core` inside a PEP 734 own-GIL interpreter on CPython 3.14. The declaration is honest for the worker model: shared mutable state is limited to thread-safe metric atomics and config applied once before any worker, read-only inside `serveLoop()`.

  **Known limitation (scope of the declaration):** the config globals (`g_timeouts`, `g_limits`, `g_obs`, `g_tls_ctx`, `g_listen_fd`, `g_server_line`) are set-once, not per-`Runtime`. The declaration is sound for **one `serve()` per process** (the only supported model — single worker, or pre-fork workers inheriting the already-applied config). It is *not* safe for two own-GIL interpreters in the same process to each call `serve()` with different config: the second would clobber the first's listen fd / timeouts / TLS context. Moving config into `Runtime` too would close that gap, but it is deliberately left undone — the v1.11 measurement showed sub-interpreter *workers* cost more RAM than fork (and FastAPI/pydantic can't even load in a sub-interpreter, see below), so there is no multi-serve-per-process driver to justify it. The declaration stays because it is true for the supported model and costs nothing at runtime.

### Fixed

- **Spurious `-OO` re-exec when the project lives under a "saltare"-named directory** (`cli.py`) — `_is_saltare_main_entry()` gated the startup re-exec (`python -OO -m saltare`) on a naive `"saltare" in arg0` substring check of `sys.argv[0]`. When the repo or venv sits under a directory whose name contains "saltare" (e.g. a clone at `~/code/saltare`), *any* `python -m <tool>` launched from that tree — `pytest`, `build`, `mypy` — had an argv[0] like `…/saltare/.venv/.../pytest/__main__.py` that matched, so saltare re-execed the foreign tool as its own CLI and died with `error: unrecognized arguments` (exit 2). The check now requires the `__main__.py`'s **parent directory** to be exactly `saltare`, which matches the real `python -m saltare` entry (`…/site-packages/saltare/__main__.py`) and nothing else. Regression test in `tests/test_cli_unit.py`. Surfaced when the suite was first run natively from a `saltare/`-rooted checkout (the Docker build runs under a non-"saltare" prefix, which is why CI never tripped it).

### Not built — and why (decision record)

- **Interpreter-thread spawner — declined.** The plan was: for `workers>1` on Python 3.12+, spawn N threads each running an own-GIL interpreter + `serveLoop()` on a shared listen fd, replacing `fork()`. The serve path was proven to work in an own-GIL interpreter (see tests), so it was *buildable* — the measurement above says it shouldn't be built. It would regress multi-worker RAM 1.4×–2.6× and drop crash isolation, in exchange for nothing saltare needs today. A second, independent blocker: the most common ASGI stack can't even run in a sub-interpreter — `import fastapi` fails there with `ImportError: module pydantic_core._pydantic_core does not support loading in subinterpreters` (pydantic-core, like many Rust/C extensions, is not per-interpreter-GIL safe). So sub-interpreter workers are not just heavier, they are unavailable to most real apps. Revisit only if a non-RAM driver appears (a fork-unsafe dependency, Windows support, or a cold-start-latency target), and even then as an opt-in alongside fork, never the default. The phase-1/2 groundwork (multi-phase init, per-`Runtime` state, re-entrant `serveLoop`, the per-interpreter-GIL slots) is what makes that future opt-in a small step rather than a rewrite.

### Fixed (cont.)

- **Stale `Server:` header version** (`_dispatcher.py`, `server.zig`) — the default `Server` header was a hardcoded `b"saltare/1.9.0"` in `_dispatcher.py` (and `"saltare/1.6.0"` in `server.zig`), both drifted from the real package version. The Python default now derives from `_core.version()`; the Zig core gained a single `pub const VERSION` (`server.zig`) that both `version()` and the default header build from, so the string has one source of truth and can't drift again.

### Tests

- `tests/test_subinterp.py` — proves `_core` imports in both a **shared-GIL** sub-interpreter (low-level `_interpreters` legacy) and an **own-GIL** sub-interpreter (PEP 734 `interpreters.create()`), and that a **full saltare server runs end to end inside an own-GIL interpreter** — binds, serves a real HTTP request, and is shut down cleanly from the main interpreter via the cross-interpreter `request_shutdown` flag. Skips on source-only runs and where the sub-interpreter API isn't exposed.
- `tests/test_cli_unit.py` — regression for the `-OO` re-exec misfire under a `saltare`-named project directory.
- `tests/test_http2.py` — `TestHttp2RealClientConformance` drives the server with the real `h2` sans-IO client over TLS+ALPN and asserts valid HTTP/2 frames (HEADERS + DATA, not HTTP/1.1 bytes) for GET, POST-with-body, a 60 KiB multi-frame response, and a 50 KiB body pulled through a 1 KiB flow-control window. `h2_response.zig` carries `zig test` unit tests that decode its output with the real HPACK decoder, including the flow-control hold/resume path.
- Full suite: 368 passed, 6 skipped (CPython 3.14, native Zig 0.16 build).

## 1.10.0

**Theme**: HTTP/2 HPACK correctness + protocol-robustness bug fixes (HTTP/2 framing, WebSocket framing, permessage-deflate context takeover, ASGI lifespan).

This release fixes a batch of latent correctness/DoS bugs surfaced by an audit. Several were unreachable by the existing test suite because the HTTP/2 tests mocked the bridge and never exercised the real Zig codec — every fix below ships with a regression test that does.

### HPACK (RFC 7541) — was broken for real HTTP/2 clients

The v1.9 HPACK implementation could not interoperate with real clients (browsers, curl, python-h2), which Huffman-encode header strings by default. Rewritten and verified against the RFC 7541 Appendix C vectors:

- **New `src/zig/huffman.zig`** — the canonical static Huffman table (generated from the authoritative `hpack` table, validated as a proper prefix code and against RFC 7541 §C.4 wire vectors) plus decode/encode. The old decoder ignored the Huffman bit entirely and returned raw Huffman bytes as if literal.
- **Decoder rewrite** (`h2.zig`) — correct RFC 7541 §5.1 prefix-integer decoding (the old code mis-parsed multi-byte lengths and double-advanced the cursor), Huffman string decoding, and a **working dynamic table** with owned copies and RFC-correct indexing/eviction. The previous dynamic table was a no-op that only bumped a size counter, so any cross-request header indexing silently dropped headers — and the index math (`62 - index`) underflowed and could panic.
- **Encoder rewrite** (`h2_encoder.zig`) — emits Indexed Header Fields with the `0x80` high bit and integer-encoded string lengths. The old encoder wrote string lengths as a single byte (truncating/panicking on any value ≥ 128 bytes — `Set-Cookie`, `Location`, CSP) and emitted malformed indexed-field representations. (Still not wired into the response path — see below — but now correct, with an encode→decode round-trip test.)

### HTTP/2 framing robustness

- **Flow-control window overflow** (`h2.zig`) — `WINDOW_UPDATE` now rejects increments that would push a window past 2³¹-1 (`FLOW_CONTROL_ERROR`) instead of wrapping a `u32` / panicking in safe builds. Connection-level flow control is now tracked, and DATA frames replenish both the stream and connection windows so large uploads keep flowing.
- **`MAX_CONCURRENT_STREAMS` enforced** — a new stream over the cap is refused with `RST_STREAM(REFUSED_STREAM)` instead of being created unbounded (HEADERS-flood DoS).
- **CONTINUATION frames assembled** — HEADERS without `END_HEADERS` now accumulate CONTINUATION fragments (bounded by a 64 KiB header-block cap) before HPACK-decoding, and a non-CONTINUATION frame mid-block is a connection error. Previously CONTINUATION bytes were silently dropped (header truncation) with no flood bound (CVE-2024-27316 class).
- **SETTINGS validation** — a payload not a multiple of 6, or an ACK with a non-empty payload, is a `FRAME_SIZE_ERROR`; `MAX_FRAME_SIZE`/`INITIAL_WINDOW_SIZE` are range-checked.
- **Connection preface consumed** (`server.zig`) — the 24-byte preface is now shifted out of the read buffer, so the client's initial SETTINGS frame (which usually arrives in the same segment) is processed instead of being mis-parsed as a frame. A partial preface now waits for more bytes instead of tearing down the connection.
- **Frame loop fixed** — frames whose handler returns nothing (WINDOW_UPDATE, PRIORITY, in-progress CONTINUATION, unknown types) no longer stop the loop and strand following frames; a partial frame at the buffer tail is kept rather than killing the connection.

> **Note on HTTP/2 scope.** The HTTP/2 *response* path still emits HTTP/1.1-shaped bytes (`http2_dispatch_start` delegates to the HTTP/1.1 dispatch), so end-to-end HTTP/2 responses are not yet wire-complete — that remains feature work, not covered here. These fixes harden the request-parsing/framing side and make the HPACK codec correct.

### WebSocket framing (RFC 6455)

- **RSV / control-frame validation** (`ws.zig`) — reject RSV2/RSV3 (and RSV1 when permessage-deflate wasn't negotiated, checked in `server.zig`), fragmented control frames (FIN=0), oversized control frames, and a 64-bit length with its MSB set (which also prevents `header_len + payload_len` from overflowing `usize`).
- **Inbound close code echoed** (`server.zig`) — the peer's close code is validated (RFC 6455 §7.4.1) and echoed back; a malformed/reserved code or 1-byte payload replies `1002`. Previously every close echoed a hardcoded `1000`.

### WebSocket permessage-deflate (RFC 7692)

- **Context takeover actually works** (`_dispatcher.py`) — `_pmd_deflate`/`_pmd_inflate` now return the compressor/decompressor so the caller persists it across messages when takeover is negotiated. Previously the compressor was recreated every message while the negotiated token told the client to keep context, corrupting the client's decode from the second message on (the shipped `--ws-compression-server-takeover` flag was unusable).
- **Negotiation matches behaviour** — `_pmd_negotiate` now returns the negotiated server/client takeover flags, honours a client's `server_no_context_takeover`, and echoes a token consistent with the actual codec behaviour.

### ASGI lifespan

- **Clearer handling of an unexpected startup message** (`_dispatcher.py`) — when an app that isn't lifespan-aware replies with an unexpected first message (e.g. `http.response.start` because it didn't check `scope["type"]`), saltare now logs it explicitly and continues serving with lifespan disabled (uvicorn `lifespan="auto"` semantics), instead of the previous silent pass-through.

### Tests

- New Zig unit tests: `huffman.zig` (prefix-code validity, all-256-byte round-trip, RFC §C.4 vectors, embedded-EOS rejection), `h2.zig` (RFC §C.4 request sequence with Huffman + cross-request dynamic indexing, long-literal integer continuation, SETTINGS validation, WINDOW_UPDATE overflow, `MAX_CONCURRENT_STREAMS`, CONTINUATION reassembly), `h2_encoder.zig` (encode→decode round-trip incl. ≥ 300-byte values), `ws.zig` (fragmented/oversized control frames, RSV2/3, 64-bit MSB length).
- New/updated Python tests: server-takeover round-trip + negotiation-token consistency in `test_ws_compression.py`, lifespan unexpected-message handling in `test_dispatcher_unit.py`. Existing PMD unit tests updated to the new `(compressor, bytes)` / 4-tuple signatures.

### Deferred to v1.10+

- **HTTP/2 response framing** — emit real HEADERS/DATA frames (wire-complete end-to-end HTTP/2) using the now-correct HPACK encoder; multiplexed streams.
- **`abi3` / limited-API wheel** — a single wheel per (libc, arch) instead of one per CPython ABI, to roughly halve release CI wall time.
- Items carried over from 1.9.0 below.

## 1.9.0

**Theme**: HTTP/2 dispatch integration + Connection HTTP/WS union + WebSocket compression config.

### Default-on

- **`Connection` struct HTTP/WS tagged union.** `WsState` struct holding all 10 WebSocket-only fields (handle, frag_*, pmd_active, list_next, log_path, last_activity_ns) stored in `data: union(Protocol) { http: void, websocket: WsState }`. HTTP connections pay **zero bytes for WebSocket state** (~52 B saved per HTTP conn, ~52 KiB at 1024 idle connections). The union tag replaces the separate `protocol` enum field — all ~52 access sites updated. Frag buffer freed inside the websocket arm of `destroy()` before the union transitions to `.http`. Was deferred from v1.8.0; 116-site mechanical refactor now complete.
- **Six pre-existing test file fixes.** `test_cli_unit`, `test_dispatcher_unit`, `test_reload_unit`, `test_v16`, `test_ws_compression`, and `test_drain` failed in Docker because they assumed source-tree layout (`../src/saltare/`). Fixed by falling back to installed package when source files aren't available, wrapping `_brotli_available()` / `_zstd_available()` in try/except `ImportError`, and converting version checks to `1.9.0`.

### Opt-in flags

- **`--http2` flag** — enables HTTP/2 support via ALPN `h2` on every TLS handshake. When a client negotiates HTTP/2, requests are dispatched through `bridge.http2DispatchStart` → `_dispatcher.py` → existing ASGI dispatch with `http_version="2"` in the scope. The Python `http2_dispatch_start` signature was fixed to match the bridge's 14-arg call (`Oiiy#y#y#y#Oy#iOiO`), adding `reserved`, `method`/`scheme`/`path` as raw bytes, and a `server_scheme` fallback. Internal Zig HTTP/2 framing (`src/zig/h2.zig`) handles connection preface, SETTINGS, DATA, HEADERS, PING, RST_STREAM, GOAWAY, and WINDOW_UPDATE. Also exposed as `http2=True` kwarg on `saltare.run()`. Off by default; zero cost when off.
- **WebSocket per-message-deflate configuration** — `--ws-compression-level INT`, `--ws-compression-server-takeover BOOL`, `--ws-pump-interval-ms INT` for fine-tuning WebSocket compression behaviour. The pump-interval flag replaces the hardcoded 50 ms tick cadence for live-WS asyncio loop pumps (`--ws-pump-interval-ms`, floor 10 ms).

### Tests

360 total (+221 from v1.8.0's 139). New file `tests/test_http2.py` covers:

- **HTTP/2 dispatch unit tests** — `http2_dispatch_start` bridge wiring: basic dispatch, PushBody, Drain, edge cases (negative stream_id, reserved non-zero, stale dispatch handle).
- **HTTP/2 server integration** — HTTP/1.1 client with `http2=True` flag, TLS with ALPN `h2` negotiation, `--http2` via CLI, `http_version="2"` in ASGI scope.
- **HTTP/2 configuration** — `bad_http2_path` returns 404, `no_http2_path` keeps `http_version="1.1"`.

All 6 pre-existing test failures fixed. WS lifecycle, channels, and observability suites unchanged.

### Bench

No bench delta — every v1.9 opt-in addition (HTTP/2 dispatch, ALPN, WS compression config) costs zero RAM when off; the hot path is unchanged from v1.8. The Connection union reclaims ~52 KiB at full 1024 conns — within bench noise at the 500-conn idle workload. Benchmarks re-run and README tables updated.

### Deferred to v1.10+

- **Free-threaded Python (`cp314t`)** evaluation — measure RSS + rps with GIL gone.
- **Static-link OpenSSL build** — alternative wheel that embeds libssl/libcrypto for environments without system OpenSSL.
- **io_uring event loop** (~2-3 weeks) — replaces epoll on hot path.
- **Sub-interpreters (PEP 684)** (~4-6 weeks) — ~10 MiB Pss multi-worker saving.

## 1.8.0

**Theme**: header memory compression + edge-case test coverage.

### Default-on

- **Header offset compression.** `http.Header` was two `[]const u8`
  slices = 32 B per header; each pool buffer holds `[max_headers]Header`
  = 32 × 32 B = **1 KiB per Buffer**. Replaced with four `u16` offsets
  into the buffer's data slice — 8 B per header, 256 B per Buffer.
  Saves **768 B per active in-flight request**; at the default
  `max_concurrent_connections=1024` that's **~770 KiB reclaimed at
  the peak of in-flight occupancy**. `Request` gains a
  `data: []const u8` reference and accessor methods (`method()`,
  `target()`, `header.nameSlice(data)`, `header.valueSlice(data)`)
  so callsites stay readable.
- u16 imposes a 64 KiB ceiling on the head section, well above
  saltare's existing pool-buffer cap (4 KiB small / 16 KiB overflow)
  — no real-world request loses fidelity.
- **Bench impact**: the existing 100-concurrent benchmark workload
  only fills ~100 of the 1024 connection slots, so the visible
  delta sits inside the run-to-run noise floor (~ ±0.5 MiB). The
  win is **proportional to active in-flight count** and shows up
  on deployments with 1k+ simultaneous in-flight requests; benchmark
  rerun with `--high-conc-idle 1000` makes it visible.

### Tests

139 total (+17 from v1.7.2's 122). New file
[tests/test_v18_edge.py](tests/test_v18_edge.py) covers gaps that
header compression makes most worth verifying:

- **Header compression edges**: long header value (~3 KiB),
  near-`max_headers=32` count, empty value preserved.
- **Pipelined HTTP requests** on one TCP socket — parser must
  compact past each consumed head and re-parse cleanly.
- **WebSocket binary echo** at varying sizes (small / >126 7-bit /
  16-bit extended) — exercises the two length-prefix variants
  that fit the pool buffer.
- **HSTS** rendering combinations: `max-age` only, `max-age=0`
  suppresses entirely (RFC 6797 §6.1.1).
- **Drain endpoint verb matrix** (GET / HEAD / PUT / DELETE / PATCH /
  OPTIONS) — POST/PUT 200, GET/HEAD 200, everything else 405.
- **Method case-sensitivity** (RFC 7230 §3.1.1): `get /favicon.ico`
  must NOT match saltare's `GET`-gated favicon intercept.
- **Header injection guard**: NUL byte in a header name produces 400
  (RFC 7230 §3.2.6 tchar validation), defending downstream proxies
  against `Header\0Smuggled: x` smuggling.

### Deferred to v1.9+ / v2.0

- **`Connection` struct HTTP/WS union** — would save ~50 KiB at
  1024 conns. 116 call sites to rewrite for marginal RAM. Trade-off
  failed the cost/benefit cut for 1.8.0.
- **Sub-interpreters (PEP 684)** for ~10 MiB Pss-multi-worker — 4-6
  weeks of dedicated work, drops cp310/cp311. v2.0 milestone.

## 1.7.2

**Theme**: WebSocket lifecycle correctness + test coverage.

v1.7.1 wired the multi-tick + periodic-pump runtime that made
Channels apps work end-to-end. v1.7.2 closes the lifecycle-leak
window that opened on socket-level errors (peer RST mid-write,
abrupt TCP FIN) and grows the test surface so future refactors
can't silently regress the WS path.

### Default-on

- **WS teardown centralised into `Connection.destroy()`.** Every
  destroy callsite (timer expiry, `doWrite` `.closed`/`.fatal`,
  peer RST, server shutdown drain) now emits the `WS-CLOSE`
  access-log line, calls `bridge.wsDisconnect` to cancel the
  Python consumer task, decrements `g_ws_conns`, and unlinks
  from `g_ws_head`. Was: `doWrite`'s error arm called
  `conn.destroy()` directly, leaking `_WsState` + asyncio Task
  forever and printing a `WS-CONNECT` with no matching
  `WS-CLOSE` for every dropped connection. Real leak under
  churn.
- **`Connection.ws_log_path` cache.** `wsAfterWrite` clears
  `conn.parsed` to reuse the buffer between WS frames, so the
  post-upgrade `WS-CLOSE` line emitted from `destroy()` would
  otherwise see `parsed == null` and skip the log entirely.
  Saltare now `dup()`s the request target at upgrade time and
  reads it back from this cache; freed by `destroy()` after the
  close line is written.
- **`wsTeardown` simplified to `loop.remove + destroy`.** The
  `bridge.wsDisconnect` call + log emit moved into `destroy()`
  (above); `wsTeardown` is now a thin epoll-unregister wrapper
  retained for the explicit close-frame path that still needs
  `loop.remove` before destroy.

### Tests

122 total (+13 from v1.7.1's 109). `tests/test_ws_lifecycle.py`
covers the invariants v1.7.2 protects:

- Close-code → HTTP status forwarding (parametrised: 4001→401,
  4002→402, 4003→403, 4004→404, 4008→408, 4029→429, fallthrough
  4500→403).
- Post-accept initial state push reaches the wire (Phase 2 of the
  upgrade pump).
- `--ws-handshake-timeout` cancels a consumer that never
  accepts/closes (verifies the cancel + 4xx response without
  hanging the test for 60 s on the consumer's `asyncio.sleep`).
- Abrupt-disconnect-doesn't-break-server (open 20 WS, drop TCP
  FIN on all, verify a fresh WS still upgrades + delivers the
  welcome frame).
- `WS-CONNECT` / `WS-CLOSE` access-log symmetry (subprocess test
  capturing stderr — confirms the centralised-destroy fix).
- `--ws-reject-log` line carries `code=4003 reason=...`.
- N sequential connect+close cycles keep the server responsive.

Also added a small `_WsClient` helper that buffers reads — the
naive `recv(4096)` in earlier tests stranded the welcome frame
because saltare coalesces the 101 head and the first server-
pushed frame into one `write(2)`.

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
