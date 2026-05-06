# Pick a sensible default manylinux image based on the host arch so Apple
# Silicon users get a native arm64 build (no Rosetta/qemu emulation).
HOST_ARCH := $(shell uname -m)
ifneq (,$(filter $(HOST_ARCH),arm64 aarch64))
    DEFAULT_MANYLINUX = manylinux_2_28_aarch64
else
    DEFAULT_MANYLINUX = manylinux_2_28_x86_64
endif

PYTHON_TAG    ?= cp314-cp314
MANYLINUX_TAG ?= $(DEFAULT_MANYLINUX)
ZIG_VERSION   ?= 0.16.0

# Derive the Docker --platform flag from the manylinux tag so cross-arch
# builds (e.g. building x86_64 on Apple Silicon) work explicitly via emulation
# instead of failing with a confusing platform mismatch warning.
ifneq (,$(findstring aarch64,$(MANYLINUX_TAG)))
    DOCKER_PLATFORM ?= linux/arm64
else
    DOCKER_PLATFORM ?= linux/amd64
endif

DOCKER_BUILD_ARGS = \
    --platform=$(DOCKER_PLATFORM) \
    --build-arg PYTHON_TAG=$(PYTHON_TAG) \
    --build-arg MANYLINUX_TAG=$(MANYLINUX_TAG) \
    --build-arg ZIG_VERSION=$(ZIG_VERSION)

.PHONY: help build test bench benchmark valgrind production-image build-local install-zig clean

help:
	@echo "Targets (no Zig on host):"
	@echo "  build              Build a wheel via Docker -> dist/"
	@echo "  test               Build wheel, install it in a clean image, run pytest"
	@echo "  bench              Build wheel, install it + uvicorn + granian, run RAM benchmark"
	@echo "  valgrind           Run pytest under valgrind --leak-check=full"
	@echo "  production-image   Build saltare-prod (jemalloc + MALLOC_ARENA_MAX=2)"
	@echo ""
	@echo "Targets (Zig on host):"
	@echo "  build-local        pip install -e '.[dev]'"
	@echo ""
	@echo "Other:"
	@echo "  install-zig        Download pinned Zig into /opt/zig"
	@echo "  clean              Remove build artifacts"
	@echo ""
	@echo "Defaults: PYTHON_TAG=$(PYTHON_TAG)  MANYLINUX_TAG=$(MANYLINUX_TAG)  PLATFORM=$(DOCKER_PLATFORM)"
	@echo "Override: make test PYTHON_TAG=cp310-cp310 MANYLINUX_TAG=manylinux_2_28_x86_64"

build:
	DOCKER_BUILDKIT=1 docker build \
		--target=export \
		--output=dist \
		$(DOCKER_BUILD_ARGS) \
		.

test:
	DOCKER_BUILDKIT=1 docker build \
		--target=tester \
		$(DOCKER_BUILD_ARGS) \
		.

bench:
	DOCKER_BUILDKIT=1 docker build \
		--target=bench \
		--tag=saltare-bench \
		--load \
		$(DOCKER_BUILD_ARGS) \
		.
	docker run --rm --platform=$(DOCKER_PLATFORM) saltare-bench

# Alias: typing `make benchmark` is more discoverable than `make bench`.
benchmark: bench

# Run pytest under valgrind so the C-API boundary in src/zig/bridge.zig
# (Py_INCREF / Py_DECREF symmetry, PyBytes ownership) gets independent
# verification beyond the smoke tests. Heavy: pytest under valgrind takes
# 10-30× longer than the unmonitored run, so this is a manual target,
# not a CI gate. Output goes to valgrind.log; --error-exitcode=1 causes a
# non-zero exit if any suppressible-untracked leaks are detected.
valgrind:
	DOCKER_BUILDKIT=1 docker build \
		--target=tester \
		--tag=saltare-valgrind-runner \
		--load \
		$(DOCKER_BUILD_ARGS) \
		.
	docker run --rm --platform=$(DOCKER_PLATFORM) \
		--entrypoint=/bin/bash \
		saltare-valgrind-runner \
		-c "dnf install -y valgrind && \
		    valgrind --leak-check=full --error-exitcode=1 \
		             --suppressions=/test-suite/tests/valgrind.supp \
		             python -m pytest -q tests"

# Production image with jemalloc preloaded + MALLOC_ARENA_MAX=2 baked in.
# See Dockerfile.production for the rationale.
production-image:
	DOCKER_BUILDKIT=1 docker build \
		--file=Dockerfile.production \
		--target=production \
		--tag=saltare-prod \
		--load \
		$(DOCKER_BUILD_ARGS) \
		.

build-local:
	pip install -e ".[dev]"

install-zig:
	./scripts/install-zig.sh

clean:
	rm -rf build/ dist/ wheelhouse/ zig-out/ zig-cache/ .zig-cache/ _skbuild/
	find . -type d -name __pycache__ -prune -exec rm -rf {} +
	find . -type d -name "*.egg-info" -prune -exec rm -rf {} +
