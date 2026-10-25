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

    // Zig 0.17 removed @cImport; C headers are now pulled in through
    // `zig translate-c` (see src/zig/c/*.c). Each unique @cImport block
    // from the 0.16 sources became one small .c file there.
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/zig/module.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize != .debug,
        .link_libc = true,
    });
    root_module.addIncludePath(.{ .cwd_relative = py_include });

    // Helper: translate one .c file into a module and register it under
    // `name` so Zig sources can do `@import(name)`.
    const Translate = struct {
        fn add(
            b2: *std.Build,
            root: *std.Build.Module,
            name: []const u8,
            c_path: []const u8,
            target2: std.Build.ResolvedTarget,
            optimize2: std.builtin.Optimize,
            py_inc: []const u8,
            needs_py: bool,
        ) void {
            const tc = b2.addTranslateC(.{
                .root_source_file = b2.path(c_path),
                .target = target2,
                .optimize = optimize2,
                .link_libc = true,
            });
            if (needs_py) tc.addIncludePath(.{ .cwd_relative = py_inc });
            const mod = tc.createModule();
            root.addImport(name, mod);
        }
    };

    // Common modules available on every platform.
    Translate.add(b, root_module, "py", "src/zig/c/py.c", target, optimize, py_include, true);
    Translate.add(b, root_module, "dlfcn", "src/zig/c/dlfcn.c", target, optimize, py_include, false);
    Translate.add(b, root_module, "module_sys", "src/zig/c/module_sys.c", target, optimize, py_include, false);
    Translate.add(b, root_module, "server_c", "src/zig/c/server.c", target, optimize, py_include, false);
    Translate.add(b, root_module, "master_c", "src/zig/c/master.c", target, optimize, py_include, false);
    Translate.add(b, root_module, "pool_c", "src/zig/c/pool.c", target, optimize, py_include, false);

    // Platform-specific modules.
    if (target.result.os.tag == .linux) {
        Translate.add(b, root_module, "epoll_c", "src/zig/c/epoll.c", target, optimize, py_include, false);
    }
    if (target.result.os.tag == .macos) {
        Translate.add(b, root_module, "kqueue_c", "src/zig/c/kqueue.c", target, optimize, py_include, false);
        Translate.add(b, root_module, "procstats_darwin_c", "src/zig/c/procstats_darwin.c", target, optimize, py_include, false);
    }

    // libdl on Linux for dlopen/dlsym.
    if (target.result.os.tag == .linux) {
        root_module.linkSystemLibrary("dl", .{});
    }

    const lib = b.addLibrary(.{
        .name = "saltare_core",
        .root_module = root_module,
        .linkage = .dynamic,
    });

    if (target.result.os.tag == .macos) {
        lib.linker_allow_shlib_undefined = true;
    }

    const final_name = b.fmt("_core{s}", .{ext_suffix});
    const install_step = b.addInstallFileWithDir(
        lib.getEmittedBin(),
        .lib,
        final_name,
    );
    b.getInstallStep().dependOn(&install_step.step);
}
