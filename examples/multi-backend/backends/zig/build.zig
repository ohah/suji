const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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

    lib.root_module.addImport("suji", b.createModule(.{
        .root_source_file = b.path("../../../../src/core/app.zig"),
        .target = target,
        .optimize = optimize,
    }));

    b.installArtifact(lib);
}
