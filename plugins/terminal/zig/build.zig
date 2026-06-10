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

    // forkpty/openpty 는 POSIX. macOS 는 libSystem(libc) 에 포함돼 별도 링크 불필요,
    // Linux 는 libutil(-lutil) 분리. Windows 는 conpty TODO — app.zig 가 빌드 분기로
    // "unsupported" 를 반환하므로 여기선 추가 링크 없음.
    if (target.result.os.tag == .linux) {
        lib.root_module.linkSystemLibrary("util", .{});
    }

    b.installArtifact(lib);
}
