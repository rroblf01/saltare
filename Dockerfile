# Local-development & quick-iteration build image.
#
# Produces a single auditwheel-repaired Linux wheel (Python 3.12 by default).
# For full multi-version, multi-arch release builds use cibuildwheel via
# the GitHub Actions workflow — this Dockerfile is only the "I don't have
# Zig installed locally and just want a wheel" escape hatch.
#
# Targets:
#   builder  builds the wheel into /dist
#   tester   installs the wheel and runs pytest (no host Python needed)
#   export   scratch image with just the wheel(s); pair with --output=dist
#
# Usage:
#   docker build --target=export --output=dist .
#   docker build --target=tester .

# syntax=docker/dockerfile:1.7

ARG MANYLINUX_TAG=manylinux_2_28_x86_64

FROM quay.io/pypa/${MANYLINUX_TAG} AS builder

ARG ZIG_VERSION=0.16.0
ARG PYTHON_TAG=cp312-cp312

ENV ZIG_VERSION=${ZIG_VERSION}
ENV PATH=/opt/python/${PYTHON_TAG}/bin:/usr/local/bin:${PATH}

WORKDIR /tmp/saltare-build
COPY scripts/install-zig.sh /tmp/install-zig.sh
RUN bash /tmp/install-zig.sh && rm /tmp/install-zig.sh

WORKDIR /io
COPY . .

RUN pip install --upgrade pip build \
 && python -m build --wheel --outdir /tmp/dirty-wheels \
 && auditwheel repair /tmp/dirty-wheels/saltare-*.whl -w /dist

# ---------------------------------------------------------------------------
# Run the test suite against the *installed* wheel, in a fresh stage.
# The build args here can be overridden the same way as for `builder`.
FROM quay.io/pypa/${MANYLINUX_TAG} AS tester

ARG PYTHON_TAG=cp312-cp312
ENV PATH=/opt/python/${PYTHON_TAG}/bin:${PATH}

COPY --from=builder /dist /dist
COPY tests /test-suite/tests
COPY pyproject.toml /test-suite/pyproject.toml

# Running from /test-suite (not /io) guarantees that `import saltare` resolves
# to the installed wheel, never to the source tree.
RUN pip install --upgrade pip \
 && pip install /dist/saltare-*.whl pytest httpx \
 && cd /test-suite && pytest -q tests

# ---------------------------------------------------------------------------
# Minimal export stage: `--output=dist` lets BuildKit copy /dist out of the image.
FROM scratch AS export
COPY --from=builder /dist /
