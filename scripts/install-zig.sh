#!/usr/bin/env bash
# Download a pinned Zig toolchain and install it under ${INSTALL_DIR}
# (default /opt/zig). Used by:
#   - the local Dockerfile (manylinux container)
#   - cibuildwheel's `before-all` on Linux
#   - the GitHub Actions release workflow (runner host pre-step)
#
# Strategy: prefer PyPI's `ziglang` package (CDN-backed, ~16 s end-to-end
# in our manylinux container) over a direct ziglang.org download
# (canonical but historically slow / unreachable from GitHub Actions and
# Apple-Silicon Docker — we've seen 4–10 min hangs). Direct download
# stays as a fallback for hosts without Python.
#
# Override:
#   ZIG_VERSION         (default 0.16.0)
#   ZIG_INSTALL_DIR     (default /opt/zig)
#   ZIG_SKIP_SYMLINK    (default 0; set 1 to leave /usr/local/bin/zig alone)

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

# Fast path: zig is already on PATH at the right version. Lets a CI
# pre-step (e.g. mounting a cached toolchain into the build container)
# skip the install entirely.
if command -v zig >/dev/null 2>&1; then
    have="$(zig version 2>/dev/null || true)"
    if [ "${have}" = "${ZIG_VERSION}" ]; then
        echo "zig ${ZIG_VERSION} already on PATH at $(command -v zig); skipping install"
        exit 0
    fi
fi

mkdir -p "${INSTALL_DIR}"

direct_download() {
    local url="https://ziglang.org/download/${ZIG_VERSION}/zig-${zig_arch}-${zig_os}-${ZIG_VERSION}.tar.xz"
    local tmpfile
    tmpfile="$(mktemp -t zig.XXXXXX.tar.xz)"
    echo "Trying direct ziglang.org download: ${url}"
    # Short, bounded timeouts: ziglang.org has historically been slow
    # from CI; we'd rather give up quickly and switch to PyPI than burn
    # 5+ minutes per attempt. Single retry covers transient blips.
    if curl -fSL \
            --connect-timeout 10 \
            --max-time 90 \
            --retry 1 --retry-delay 2 \
            -o "${tmpfile}" "${url}"; then
        echo "Extracting ${tmpfile}"
        tar -xJ -C "${INSTALL_DIR}" --strip-components=1 -f "${tmpfile}"
        rm -f "${tmpfile}"
        return 0
    fi
    rm -f "${tmpfile}"
    return 1
}

pypi_install() {
    echo "Installing Zig ${ZIG_VERSION} via PyPI (ziglang package)..."
    # The manylinux base image keeps every cpython under /opt/python/cp*/
    # and intentionally does NOT put a `python3` on PATH. Probe explicitly
    # so the fallback works in that environment as well as on regular
    # hosts where `python3` is available.
    local python=""
    local candidate
    for candidate in /opt/python/cp314-cp314/bin/python \
                     /opt/python/cp313-cp313/bin/python \
                     /opt/python/cp312-cp312/bin/python \
                     /opt/python/cp311-cp311/bin/python \
                     /opt/python/cp310-cp310/bin/python \
                     python3 python; do
        if command -v "${candidate}" >/dev/null 2>&1; then
            python="${candidate}"
            break
        fi
    done
    if [ -z "${python}" ]; then
        echo "  no python on PATH for PyPI install" >&2
        return 1
    fi
    echo "  using python: ${python}"
    local wheel_dir
    wheel_dir="$(mktemp -d -t zig-wheel.XXXXXX)"
    # Show pip's output so a real failure (version unknown, network, etc.)
    # is debuggable from the build log.
    if ! "${python}" -m pip download \
            --no-deps \
            --dest "${wheel_dir}" \
            "ziglang==${ZIG_VERSION}"; then
        echo "  pip download ziglang==${ZIG_VERSION} failed" >&2
        rm -rf "${wheel_dir}"
        return 1
    fi
    local wheel
    wheel="$(ls "${wheel_dir}"/ziglang-*.whl 2>/dev/null | head -n1)"
    if [ -z "${wheel}" ]; then
        echo "  pip download produced no wheel" >&2
        rm -rf "${wheel_dir}"
        return 1
    fi
    # Wheels are zip archives. The ziglang package layout is:
    #   ziglang/zig                 (the binary)
    #   ziglang/lib/                (the std library)
    #   ziglang-X.Y.Z.dist-info/    (metadata, ignored)
    # We strip the leading `ziglang/` so things land directly under
    # ${INSTALL_DIR} matching the tarball layout.
    local tmpdir
    tmpdir="$(mktemp -d -t zig-pypi.XXXXXX)"
    unzip -q "${wheel}" -d "${tmpdir}"
    if [ ! -f "${tmpdir}/ziglang/zig" ]; then
        echo "  ziglang wheel did not contain ziglang/zig" >&2
        rm -rf "${wheel_dir}" "${tmpdir}"
        return 1
    fi
    cp -r "${tmpdir}/ziglang/." "${INSTALL_DIR}/"
    chmod +x "${INSTALL_DIR}/zig"
    rm -rf "${wheel_dir}" "${tmpdir}"
    return 0
}

# Prefer PyPI: in our actual deployment paths (manylinux Docker build,
# GitHub Actions runner) Python is always available and PyPI's CDN is
# substantially more reliable than ziglang.org from CI hosts. Fall back
# to direct download only if PyPI somehow refuses (no python on PATH,
# version not yet published, etc.).
if pypi_install; then
    :
elif direct_download; then
    :
else
    echo "" >&2
    echo "Could not install Zig ${ZIG_VERSION} for ${zig_os}/${zig_arch}." >&2
    echo "Both the PyPI ziglang install and the direct ziglang.org" >&2
    echo "download failed. Most likely a transient network issue —" >&2
    echo "rerunning the job is the right first step." >&2
    exit 1
fi

# In CI we sometimes pre-install Zig on the host and mount it read-only
# into the build container; the symlink step then becomes unnecessary
# noise. ZIG_SKIP_SYMLINK=1 opts out cleanly.
if [ "${ZIG_SKIP_SYMLINK:-0}" != "1" ]; then
    if [ -w /usr/local/bin ]; then
        ln -sf "${INSTALL_DIR}/zig" /usr/local/bin/zig
    else
        sudo ln -sf "${INSTALL_DIR}/zig" /usr/local/bin/zig
    fi
fi

"${INSTALL_DIR}/zig" version
