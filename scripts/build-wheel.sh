#!/usr/bin/env bash
# Build a Linux wheel locally without installing Zig on the host.
#
# Defaults: manylinux_2_28_x86_64 + CPython 3.12. Override via env:
#   PYTHON_TAG=cp310-cp310 ./scripts/build-wheel.sh
#   MANYLINUX_TAG=manylinux_2_28_aarch64 ./scripts/build-wheel.sh
#
# Output: ./dist/saltare-*.whl

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

PYTHON_TAG="${PYTHON_TAG:-cp314-cp314}"
MANYLINUX_TAG="${MANYLINUX_TAG:-manylinux_2_28_x86_64}"
ZIG_VERSION="${ZIG_VERSION:-0.16.0}"

mkdir -p dist

DOCKER_BUILDKIT=1 docker build \
    --target=export \
    --output=dist \
    --build-arg "PYTHON_TAG=${PYTHON_TAG}" \
    --build-arg "MANYLINUX_TAG=${MANYLINUX_TAG}" \
    --build-arg "ZIG_VERSION=${ZIG_VERSION}" \
    .

echo
echo "Built wheel(s):"
ls -1 dist/*.whl
