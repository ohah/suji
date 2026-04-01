const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const util_mod = b.createModule(.{
        .root_source_file = b.path("../../../src/core/util.zig"),
        .target = target,
        .optimize = optimize,
    });

    const suji_mod = b.createModule(.{
        .root_source_file = b.path("../../../src/core/app.zig"),
        .target = target,
        .optimize = optimize,
    });
    suji_mod.addImport("util", util_mod);

    const lib = b.addLibrary(.{
        .name = "backend",
        .root_module = b.createModule(.{
            .root_source_file = b.path("app.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
        .linkage = .dynamic,
    });
    lib.root_module.addImport("suji", suji_mod);

    b.installArtifact(lib);
}
