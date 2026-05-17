const std = @import("std");

// 비-macOS safeStorage(Linux secret-tool / Windows DPAPI) 라운드트립
// 회귀 가드. macOS 는 cef.zig Keychain 이라 이 하니스 대상 아님(@compileError)
// — ci.yml 에서 runner.os != macOS 로만 실행.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sso = b.createModule(.{
        .root_source_file = b.path("../../src/platform/safe_storage_os.zig"),
        .target = target,
        .optimize = optimize,
    });
    const t = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    t.root_module.addImport("safe_storage_os", sso);
    const run = b.addRunArtifact(t);
    b.step("test", "safeStorage round-trip").dependOn(&run.step);
    b.getInstallStep().dependOn(&run.step);
}
