cmake_minimum_required(VERSION 3.20)
project(saltare LANGUAGES C)

# scikit-build-core injects Python_EXECUTABLE / Python_INCLUDE_DIRS via
# find_package(Python). We need Development.Module so that Python.h is located
# but we deliberately avoid linking libpython on Linux (the interpreter
# provides the symbols at dlopen time).
find_package(Python 3.10 COMPONENTS Interpreter Development.Module REQUIRED)

find_program(ZIG_EXECUTABLE zig)
if(NOT ZIG_EXECUTABLE)
    message(FATAL_ERROR
        "zig was not found on PATH. "
        "Install Zig 0.14+ locally, or build via the provided Docker pipeline. "
        "See README.md for instructions.")
endif()

execute_process(
    COMMAND ${Python_EXECUTABLE} -c "import sysconfig; print(sysconfig.get_config_var('EXT_SUFFIX'))"
    OUTPUT_VARIABLE PY_EXT_SUFFIX
    OUTPUT_STRIP_TRAILING_WHITESPACE
    COMMAND_ERROR_IS_FATAL ANY
)

set(ZIG_OUT_DIR "${CMAKE_CURRENT_BINARY_DIR}/zig-out")
set(ZIG_CACHE_DIR "${CMAKE_CURRENT_BINARY_DIR}/zig-cache")
set(CORE_LIB_NAME "_core${PY_EXT_SUFFIX}")
set(CORE_LIB_PATH "${ZIG_OUT_DIR}/lib/${CORE_LIB_NAME}")

file(GLOB_RECURSE ZIG_SOURCES CONFIGURE_DEPENDS
    "${CMAKE_CURRENT_SOURCE_DIR}/src/zig/*.zig"
)

# Pick a Zig optimization mode. ReleaseSmall favours code size which is the
# right trade-off for an embedded extension whose hot path is I/O bound.
set(ZIG_OPTIMIZE "ReleaseSmall" CACHE STRING "Zig optimize mode")

# v1.12: Zig does not read MACOSX_DEPLOYMENT_TARGET. cibuildwheel sets it —
# in pyproject.toml's [tool.cibuildwheel.macos] and again in the workflow —
# expecting it to pin the wheel's minimum macOS, and it silently did nothing.
# The extension linked against whatever the runner's SDK defaulted to (14.8 on
# macos-14), and delocate then refused to tag the wheel macosx_11_0_arm64
# because the .so advertised a higher minimum than the filename claimed.
#
# Zig 0.16 has no -Dmacosx-deployment-target, so the version has to go in the
# target triple. Verified by compiling aarch64-macos.11.0 and reading
# LC_BUILD_VERSION out of the object: minos 11.0.0 with the version pinned,
# 13.0.0 without. build.zig already uses b.standardTargetOptions, so -Dtarget
# is the supported channel and needs no change there.
#
# Read the value that is already declared rather than adding a second knob
# that could disagree with the one cibuildwheel exports.
set(SALTARE_ZIG_TARGET_ARGS "")
if(APPLE)
    set(_saltare_deployment_target "$ENV{MACOSX_DEPLOYMENT_TARGET}")
    if(NOT _saltare_deployment_target)
        set(_saltare_deployment_target "11.0")
    endif()
    if(CMAKE_HOST_SYSTEM_PROCESSOR MATCHES "^(arm64|aarch64)$")
        set(_saltare_arch "aarch64")
    else()
        set(_saltare_arch "x86_64")
    endif()
    set(SALTARE_ZIG_TARGET_ARGS "-Dtarget=${_saltare_arch}-macos.${_saltare_deployment_target}")
    message(STATUS "saltare: macOS deployment target ${_saltare_deployment_target} (${_saltare_arch})")
endif()

add_custom_command(
    OUTPUT "${CORE_LIB_PATH}"
    COMMAND ${CMAKE_COMMAND} -E make_directory "${ZIG_OUT_DIR}"
    COMMAND ${ZIG_EXECUTABLE} build
        "-Doptimize=${ZIG_OPTIMIZE}"
        "-Dpython-include=${Python_INCLUDE_DIRS}"
        "-Dext-suffix=${PY_EXT_SUFFIX}"
        ${SALTARE_ZIG_TARGET_ARGS}
        --cache-dir "${ZIG_CACHE_DIR}"
        --prefix "${ZIG_OUT_DIR}"
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
    DEPENDS ${ZIG_SOURCES}
            "${CMAKE_CURRENT_SOURCE_DIR}/build.zig"
            "${CMAKE_CURRENT_SOURCE_DIR}/build.zig.zon"
    COMMENT "Building saltare native core with Zig (${ZIG_OPTIMIZE})"
    VERBATIM
)

add_custom_target(saltare_core ALL DEPENDS "${CORE_LIB_PATH}")

install(FILES "${CORE_LIB_PATH}" DESTINATION saltare)
