#!/usr/bin/env bash
# Download a pinned Zig toolchain and put `zig` on PATH.
#
# Used by both:
#   - the local `Dockerfile` (manylinux container)
#   - cibuildwheel's `before-all` on Linux and macOS
#
# Override ZIG_VERSION via env if you need to bump.

set -euo pipefail

ZIG_VERSION="${ZIG_VERSION:-0.16.0}"
INSTALL_DIR="${ZIG_INSTALL_DIR:-/opt/zig}"

uname_s="$(uname -s)"
uname_m="$(uname -m)"

case "${uname_s}" in
    Linux)  zig_os="linux"  ;;
    Darwin) zig_os="macos"  ;;
    *) echo "unsupported OS: ${uname_s}" >&2; exit 1 ;;
esac

case "${uname_m}" in
    x86_64|amd64)         zig_arch="x86_64"  ;;
    aarch64|arm64)        zig_arch="aarch64" ;;
    *) echo "unsupported arch: ${uname_m}" >&2; exit 1 ;;
esac

mkdir -p "${INSTALL_DIR}"

# Zig changed its tarball naming convention around the 0.15 release (arch
# moved before os). Try both forms so the script keeps working regardless of
# which side of that change the pinned ZIG_VERSION lives on.
candidates=(
    "https://ziglang.org/download/${ZIG_VERSION}/zig-${zig_arch}-${zig_os}-${ZIG_VERSION}.tar.xz"
    "https://ziglang.org/download/${ZIG_VERSION}/zig-${zig_os}-${zig_arch}-${ZIG_VERSION}.tar.xz"
)

tmpfile="$(mktemp -t zig.XXXXXX.tar.xz)"
trap 'rm -f "${tmpfile}"' EXIT

downloaded=""
for url in "${candidates[@]}"; do
    echo "Trying ${url}"
    if curl -fSL --retry 3 --retry-delay 2 -o "${tmpfile}" "${url}"; then
        downloaded="${url}"
        break
    fi
done

if [ -z "${downloaded}" ]; then
    echo "Could not download Zig ${ZIG_VERSION} for ${zig_os}/${zig_arch}." >&2
    echo "Tried:" >&2
    printf '  %s\n' "${candidates[@]}" >&2
    exit 1
fi

echo "Installing from ${downloaded}"
tar -xJ -C "${INSTALL_DIR}" --strip-components=1 -f "${tmpfile}"

if [ -w /usr/local/bin ]; then
    ln -sf "${INSTALL_DIR}/zig" /usr/local/bin/zig
else
    sudo ln -sf "${INSTALL_DIR}/zig" /usr/local/bin/zig
fi

zig version
