const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const py_include = b.option(
        []const u8,
        "python-include",
        "Absolute path to the directory containing Python.h",
    ) orelse {
        std.debug.print(
            "error: -Dpython-include=<path-to-python-headers> is required\n",
            .{},
        );
        std.process.exit(1);
    };

    const ext_suffix = b.option(
        []const u8,
        "ext-suffix",
        "Python extension suffix from sysconfig (e.g. .cpython-312-darwin.so)",
    ) orelse ".so";

    // Zig 0.15+ build API: configure a Module first, then attach it to a
    // Compile step via addLibrary(). addSharedLibrary() is gone.
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/zig/module.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize != .Debug,
        .link_libc = true,
    });
    root_module.addIncludePath(.{ .cwd_relative = py_include });

    const lib = b.addLibrary(.{
        .name = "saltare_core",
        .root_module = root_module,
        .linkage = .dynamic,
    });

    // CPython resolves extension symbols at dlopen time, so the .so must be
    // linked with unresolved-symbol tolerance. On Linux that's the default for
    // shared libraries; on macOS we must opt in explicitly.
    if (target.result.os.tag == .macos) {
        lib.linker_allow_shlib_undefined = true;
    }

    // Ship the artifact under the Python-canonical filename
    // (e.g. _core.cpython-312-darwin.so) inside the install lib/ dir.
    const final_name = b.fmt("_core{s}", .{ext_suffix});
    const install_step = b.addInstallFileWithDir(
        lib.getEmittedBin(),
        .lib,
        final_name,
    );
    b.getInstallStep().dependOn(&install_step.step);
}
