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

add_custom_command(
    OUTPUT "${CORE_LIB_PATH}"
    COMMAND ${CMAKE_COMMAND} -E make_directory "${ZIG_OUT_DIR}"
    COMMAND ${ZIG_EXECUTABLE} build
        "-Doptimize=${ZIG_OPTIMIZE}"
        "-Dpython-include=${Python_INCLUDE_DIRS}"
        "-Dext-suffix=${PY_EXT_SUFFIX}"
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
