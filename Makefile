# Pick a sensible default manylinux image based on the host arch so Apple
# Silicon users get a native arm64 build (no Rosetta/qemu emulation).
HOST_ARCH := $(shell uname -m)
ifneq (,$(filter $(HOST_ARCH),arm64 aarch64))
    DEFAULT_MANYLINUX = manylinux_2_28_aarch64
else
    DEFAULT_MANYLINUX = manylinux_2_28_x86_64
endif

PYTHON_TAG    ?= cp312-cp312
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

.PHONY: help build test build-local test-host install-zig clean

help:
	@echo "Targets (no Zig on host):"
	@echo "  build         Build a wheel via Docker -> dist/"
	@echo "  test          Build wheel, install it in a clean image, run pytest"
	@echo ""
	@echo "Targets (Zig on host):"
	@echo "  build-local   pip install -e '.[dev]'"
	@echo "  test-host     pytest -q against the host install"
	@echo ""
	@echo "Other:"
	@echo "  install-zig   Download pinned Zig into /opt/zig"
	@echo "  clean         Remove build artifacts"
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

build-local:
	pip install -e ".[dev]"

test-host:
	pytest -q

install-zig:
	./scripts/install-zig.sh

clean:
	rm -rf build/ dist/ wheelhouse/ zig-out/ zig-cache/ .zig-cache/ _skbuild/
	find . -type d -name __pycache__ -prune -exec rm -rf {} +
	find . -type d -name "*.egg-info" -prune -exec rm -rf {} +
