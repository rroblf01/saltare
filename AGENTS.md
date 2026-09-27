# AGENTS.md

## What this is

`saltare` — a low-RAM ASGI HTTP server for Python with a Zig backbone. The Zig core
owns the I/O loop (epoll/kqueue), HTTP/1.1 + HTTP/2 parsing, TLS, WebSockets and the
pre-fork supervisor; a thin Python layer owns one persistent `asyncio` loop and turns
each parsed request into exactly one ASGI dispatch.

**Project goal: minimum RAM and maximum req/sec — the bar is "clearly better than
uvicorn".** Every change is judged against that. Opt-in features must cost **zero RAM
when off** (early-out before any allocation), and the hot path must not regress the
benchmarks in the README.

## Build & test

Use the venv. **Never install anything into the OS.**

```bash
uv pip install -e . --no-deps --no-build-isolation   # rebuild the Zig core (~6 s)
.venv/bin/python -m pytest -q                        # full suite
.venv/bin/python -m pytest -q tests/test_smoke.py::test_version_string
.venv/bin/python -m pytest -q -p no:cacheprovider    # .pytest_cache may be unwritable
```

- Build chain is `scikit-build-core → CMakeLists.txt → zig build`. `CMakeLists.txt` shells
  out to `zig`, passing `-Dpython-include` and `-Dext-suffix`; there is no pure-Python path.
- `make test` / `make build` / `make bench` run everything in Docker (no Zig on the host).
  `make valgrind` = pytest under valgrind, 10–30× slower, a manual pre-tag gate.
- `make check-macos` cross-compile-checks every Zig module that does not need a macOS
  `Python.h` against `aarch64-macos`. Run it after touching platform code: with no
  macOS runner in the matrix it is the only Darwin check left, so it is not optional.
  It still skips `module.zig` and `server.zig` (they import `bridge.zig`). To force `server.zig` through
  anyway, symlink `src/zig/*.zig` into a scratch dir beside a root file that
  `export fn`s a wrapper calling `server.run(...)`. Merely *referencing* the function
  is not enough: Zig will not generate the body, and the check then passes on a 1.8 KB
  stub object while proving nothing.
- **Zig unit tests are run per file**, not via make or CI:
  `zig test --cache-dir /tmp/zc --global-cache-dir /tmp/zg src/zig/h2.zig`
  The repo-root `.zig-cache/` is root-owned, so a bare `zig test` dies with
  `failed to check cache: manifest_create AccessDenied`. Always pass writable cache dirs.
- No linter, formatter or typechecker is configured. **Do not add one, and do not run
  `zig fmt`** — `server.zig`, `h2.zig`, `bridge.zig` and `h2_static.zig` are already not
  `zig fmt` clean, so it would bury any real change in noise.

## Platform support: Linux is the released target

**macOS is not released.** The kqueue backend (`eventloop_kqueue.zig`) is in the tree
and cross-compiles, but there is no macOS wheel, no macOS CI job, and nothing macOS
in the release gate. Treat macOS as **unvalidated source**: `module.zig` and
`server.zig` are excluded from `make check-macos` (they import `bridge.zig`, which
needs a macOS `Python.h`), so nothing in CI compiles them for Darwin at all. Anything
touching the Darwin path needs a real Mac, which is the next release's job.

`src/zig/eventloop.zig` still picks a backend at comptime — `eventloop_epoll.zig` or
`eventloop_kqueue.zig` — and re-exports it, so `server.zig` stays platform-agnostic and
the hot path has **no branch on the OS**. Adding a third target means adding a backend
with the same five methods (`init`/`add`/`modify`/`remove`/`wait`), the same `Event`
shape, the same `runtime: ?*anyopaque` field, and one `comptime` arm.

When touching platform code, the recurring macOS differences are: no
`SOCK_NONBLOCK`/`SOCK_CLOEXEC` (use `socketNonBlock`/`acceptOne`), no `TCP_KEEPIDLE`
(it is `TCP_KEEPALIVE`), no `TCP_USER_TIMEOUT`, `madvise` wants `MADV_FREE` rather
than `MADV_DONTNEED`, `sendfile(2)` takes the offset by value and only honours it on
the first call, and there is no `prctl` or `/proc`. A top-level `@cImport` of a header
that does not exist on the other platform breaks the build *before any of our own code
runs* — that is how `sys/prctl.h` and `sys/sendfile.h` had to go.

## Adding or changing a server option — check which layer first

`run()` takes ~78 kwargs but only ~52 reach `_core.serve` **positionally**, parsed in
`src/zig/module.zig` by a single `PyArg_ParseTuple` format string. Argument order *is*
the contract. The rest never cross the C ABI — they are wired via
`_dispatcher.set_*` setters (compression, HSTS, proxy-headers, WS upgrade/compression,
tracemalloc already covered that way), via `workers=0 → min(cpu,4)` normalization, or
via `_reload.supervise` (`reload*`, which forces `workers=1`).

- **Zig-backed option** (timeouts, limits, sockets, TLS, paths served from Zig): touch all four,
  **appended at the end, never inserted in the middle** (a past release segfaulted from a
  `PyObject_CallFunction` arg-count mismatch; misalignment type-checks fine and corrupts
  memory at runtime):
  1. `src/saltare/__init__.py` — kwarg + docstring + positional arg to `_core.serve(...)`
  2. `src/saltare/cli.py` — argparse flag + `run(...)` kwarg (flat parser, no subcommands;
     `--check-config FILE` is a *flag*, not a subcommand)
  3. `src/zig/module.zig` — format-string char + matching out-param + the `g_*` config global
  4. `src/saltare/_core.pyi` — the stub
- **Python-only option** (dispatcher tuning, reload supervisor): `__init__.py` + `cli.py` +
  the `_dispatcher.set_*` / `_reload` call. Do **not** extend the `PyArg_ParseTuple` string
  for these — every unused positional slot still shifts the ABI.

## Zig changes need a reinstall; Python changes do not

The editable install is scikit-build-core's redirecting finder created with
`rebuild=False`, so importing `saltare._core` never rebuilds. `saltare._core` resolves to
a `.so` inside `.venv/.../site-packages/saltare/`, not to `src/`.

- Edits under `src/saltare/` take effect on the next process start.
- Edits under `src/zig/` are **invisible until you reinstall** (`uv pip install -e .`).
  Zig's build cache is content-addressed, so `touch`ing a `.zig` file is a no-op — make a
  real edit or you will "verify" a stale binary.
- `cmake --build build/<tag>` alone does not help: `cmake --install` targets a temporary
  wheel-staging directory, not the venv.

## Zig state model — don't break it

Config globals (`g_timeouts`, `g_limits`, `g_obs`, `g_tls_ctx`, `g_listen_fd`,
`g_server_line`) are **set once** before the loop and read-only inside `serveLoop()`.
Metrics are atomics, intentionally process-global so `/metrics` unifies across pre-fork
workers. State that genuinely cannot be shared across interpreters lives in the per-serve
`Runtime` struct. Keep that split; the PEP 684 declaration in `module.zig` is only sound
because of it.

OpenSSL, zlib, brotli and zstd are **`dlopen`'d lazily**, never linked at build time —
that is what keeps the wheel small and keeps plain-HTTP deployments from mapping ~2 MiB
of libssl. A missing shared library is a startup warning plus identity fallback, not an
error. The dlopen candidate lists are "first one that loads"; add a platform's soname
there rather than introducing a link-time dependency.

## Testing quirks

- `tests/conftest.py` has an **autouse** fixture calling `_core.request_shutdown()` after
  every test, waiting up to 3 s for leaked daemon threads. It exists because accumulated
  server threads race on cross-thread globals in `server.zig` and segfault (reproduced as
  exit 139 on cp313-musllinux). Never remove it.
- There is **no shared server fixture**. Each test module defines its own
  `_serve_in_background(app, port, **kwargs)` that spawns `saltare.run` in a daemon thread
  and polls a TCP connect with a 2 s deadline. Copy the local one.
- WebSocket tests run together in one process since v1.12 (the v0.10 teardown crash no
  longer reproduces — `conftest.py` drain fixture + centralised `destroy()` fixed the
  overlap). If a WS teardown segfault ever returns, re-adding skips is cheaper than
  re-deriving it; see the `test_websocket.py` docstring for the history.
- TLS tests shell out to the `openssl` CLI to mint a self-signed cert per test.
- `tests/test_cli_unit.py` loads `cli.py` by path with a mocked `saltare` module and
  restores `sys.modules["saltare"]` afterwards — do not drop that restore.
- Silent suite loss: `tests/test_http2.py` skips wholesale without `h2` installed, and
  `@pytest.mark.flaky` reruns are no-ops without `pytest-rerunfailures`. Both live in
  the `dev` dependency group / extra — keep them installed or you will "pass" with
  coverage missing.
- New feature coverage lands in a new `tests/test_v<NN>*.py` module whose docstring states
  which edge cases it targets.
- Tests are timing-sensitive: most modules scale their deadline by
  `_TIMING_FACTOR = 4.0 if platform.machine() in {"aarch64", "arm64"} else ...`
  (the else-branch varies: 2.0 in older modules, 1.0 in newer ones — copy the local one).

## Version bumps

One source of truth for the runtime version: `pub const VERSION` in `src/zig/server.zig`
— it feeds both `_core.version()` and the default `Server:` header. A bump touches all six:

- `src/zig/server.zig` (`VERSION`)
- `pyproject.toml` (`[project] version`)
- `build.zig.zon` (`.version` — tracks the release; nothing reads it, so a mismatch is pure confusion)
- `tests/test_smoke.py` (two hardcoded version asserts)
- `tests/test_cli_unit.py` (the mocked `__version__`)
- `CHANGELOG.md` and the README status block

## Conventions

- `CHANGELOG.md` is a **decision record**, not a diff summary. Releases carry "Not built —
  and why" sections with measurements explaining rejected alternatives. Match that.
- `README.md` is the user-facing doc and documents every CLI flag. A new user-visible flag
  needs a README section.
- Comments explain *why* and cite the milestone that introduced the behaviour
  (`// v1.9: ...`). The density is deliberate; match it.
- `src/saltare/cli.py` **re-execs the process as `python -OO -m saltare` at import time**
  (module-level `_ensure_optimized()`), injecting `PYTHONOPTIMIZE=2`,
  `MALLOC_ARENA_MAX=1` and `PYTHONFAULTHANDLER=1`. It is gated on
  `_is_saltare_main_entry()`, whose argv[0] check must stay exact — a loose
  `"saltare" in arg0` substring test hijacked `pytest` when the checkout lived under a
  directory named `saltare`. Opt out with `SALTARE_NO_OPTIMIZE=1`.
- `socket()` calls use `SOCK_NONBLOCK | SOCK_CLOEXEC`, and `accept` goes through
  `accept4` when available. SIGPIPE is ignored via `signal()`.
- Release: tag `v<X.Y.Z>` and push. CI is three files, and the split is the point:
  - `ci.yml` — push to `main` and pull requests. Builds wheels with cibuildwheel and
    tests them. **No publish job exists in this file.**
  - `build-and-test.yml` — the actual matrix (`build_wheels`, `test_wheels`,
    `build_sdist`), `on: workflow_call`. Called by both of the others so
    the matrix is defined once and cannot drift.
  - `release.yml` — tag pushes only. Calls `build-and-test`, then publishes to PyPI via
    Trusted Publishing.

  There is no macOS job in any of the three, and no macOS wheel.

  A branch push therefore cannot reach PyPI *structurally*, not just via a condition.
  Before this split the pipeline was tag-only, so a push to `main` ran nothing at all.
  Only publish when the whole suite is green.
