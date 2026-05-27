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

    if (target.result.os.tag == .windows) {
        // WinRT 함수는 모두 combase.dll/shell32.dll 동적 로드(LoadLibraryW +
        // GetProcAddress)로 호출 — MinGW import lib 부재 회피 + graceful
        // degradation (Win7-/no-WinRT 환경 자동 fallback).
        lib.root_module.linkSystemLibrary("kernel32", .{});
    }

    b.installArtifact(lib);
}
