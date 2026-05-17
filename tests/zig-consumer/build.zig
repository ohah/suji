const std = @import("std");

// suji 를 패키지 의존성으로 소비하는 최소 외부 프로젝트(회귀 가드).
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const suji = b.dependency("suji", .{ .target = target, .optimize = optimize });

    const lib = b.addLibrary(.{
        .name = "suji_consumer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("app.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
        .linkage = .dynamic,
    });
    lib.root_module.addImport("suji", suji.module("suji"));
    b.installArtifact(lib);
}
