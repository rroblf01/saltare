# Local-development & quick-iteration build image.
#
# Targets:
#   builder  builds the wheel into /dist
#   tester   installs the wheel and runs pytest
#   export   scratch image with just the wheel(s); pair with --output=dist
#
# Cache boundaries (top to bottom = least to most frequently invalidated):
#   1. zig-toolchain   only changes when Zig version or install script changes
#   2. build-env       only changes when manylinux / Python tag / build deps change
#   3. test-env        adds pytest + httpx; rarely invalidated
#   4. builder         re-runs when any source file in the build set changes
#   5. tester          re-runs when wheel changes OR tests/ changes
#
# Usage:
#   docker build --target=export --output=dist .
#   docker build --target=tester .

# syntax=docker/dockerfile:1.7

ARG MANYLINUX_TAG=manylinux_2_28_x86_64
ARG PYTHON_TAG=cp314-cp314
ARG ZIG_VERSION=0.16.0

# ---------------------------------------------------------------------------
# Stage 1: Zig toolchain. Cache invalidates only when Zig version or the
# install script changes.
FROM quay.io/pypa/${MANYLINUX_TAG} AS zig-toolchain
ARG ZIG_VERSION
ENV ZIG_VERSION=${ZIG_VERSION}
COPY scripts/install-zig.sh /tmp/install-zig.sh
RUN bash /tmp/install-zig.sh && rm /tmp/install-zig.sh

# ---------------------------------------------------------------------------
# Stage 2: Python build environment. Cache invalidates per Python tag.
FROM zig-toolchain AS build-env
ARG PYTHON_TAG
ENV PATH=/opt/python/${PYTHON_TAG}/bin:/usr/local/bin:${PATH}
# v1.3: OpenSSL is `dlopen`'d at runtime, so we don't need the headers
# (-devel) at build time anymore. The runtime libs (`libssl.so.x`) are
# already on the manylinux image; tests + bench find them via the dlopen
# fallback chain. Plain-HTTP deployments need no OpenSSL at all.
RUN pip install --upgrade pip build

# ---------------------------------------------------------------------------
# Stage 3: Test environment. Adds pytest+httpx once; the wheel install gets a
# separate layer below so it can invalidate independently.
FROM build-env AS test-env
RUN pip install pytest httpx fastapi websockets

# ---------------------------------------------------------------------------
# Stage 4: Build the wheel. Re-runs only when build inputs change. We copy
# files individually instead of `COPY . .` so test-only edits don't bust this
# layer.
FROM build-env AS builder
WORKDIR /io
COPY pyproject.toml CMakeLists.txt build.zig build.zig.zon README.md LICENSE ./
COPY src ./src
RUN python -m build --wheel --outdir /tmp/dirty-wheels \
 && auditwheel repair /tmp/dirty-wheels/saltare-*.whl -w /dist \
 && python -OO -c "import compileall, glob; compileall.compile_dir('src/saltare', force=True, quiet=1, optimize=2)" || true

# ---------------------------------------------------------------------------
# Stage 5: Run the test suite against the *installed* wheel. Wheel install,
# tests copy, and pytest run are split into separate RUN/COPY layers so
# changing only `tests/` doesn't reinstall the wheel.
FROM test-env AS tester
WORKDIR /test-suite
COPY --from=builder /dist /dist
RUN pip install --no-deps /dist/saltare-*.whl
COPY pyproject.toml ./
COPY tests ./tests
RUN pytest -q tests

# ---------------------------------------------------------------------------
# Stage 6: RAM benchmark. Installs the saltare wheel + uvicorn (plain, no
# [standard] extras for a fair comparison) + granian (Rust-based ASGI peer)
# into the test-env image and runs `benchmarks.bench` to print a Markdown
# comparison table. Granian is included so saltare-vs-uvicorn isn't taken
# in isolation; both are low-level alternatives to asyncio-based servers.
FROM test-env AS bench
COPY --from=builder /dist /dist
RUN pip install --no-deps /dist/saltare-*.whl \
 && pip install uvicorn granian
WORKDIR /work
COPY benchmarks /work/benchmarks
# Default invocation: --include-granian so the table has all three servers.
# Override with `docker run ... saltare-bench python -m benchmarks.bench [flags]`.
CMD ["python", "-m", "benchmarks.bench", "--include-granian"]

# ---------------------------------------------------------------------------
# Stage 7: Minimal export. `--output=dist` lets BuildKit copy /dist out.
FROM scratch AS export
COPY --from=builder /dist /
