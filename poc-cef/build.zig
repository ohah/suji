const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // CEF path
    const home = std.posix.getenv("HOME") orelse "/tmp";
    const cef_dir = std.fmt.allocPrint(b.allocator, "{s}/.suji/cef/macos-arm64", .{home}) catch return;
    const cef_real = std.fs.cwd().realpathAlloc(b.allocator, cef_dir) catch {
        std.debug.print("CEF not found at {s}\n", .{cef_dir});
        return;
    };

    const exe = b.addExecutable(.{
        .name = "suji-cef-poc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    // CEF platform module
    const cef_module = b.createModule(.{
        .root_source_file = b.path("../src/platform/cef.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    cef_module.addIncludePath(.{ .cwd_relative = cef_real });
    exe.root_module.addImport("cef", cef_module);

    // CEF include path
    exe.addIncludePath(.{ .cwd_relative = cef_real });

    // CEF framework linking (macOS)
    const fw_path = std.fmt.allocPrint(b.allocator, "{s}/Release", .{cef_real}) catch return;
    exe.root_module.addRPathSpecial(fw_path);
    exe.addFrameworkPath(.{ .cwd_relative = fw_path });
    exe.linkFramework("Chromium Embedded Framework");

    // Cocoa framework (macOS 창 관리에 필요)
    exe.linkFramework("Cocoa");

    b.installArtifact(exe);

    // macOS: ad-hoc 코드 서명 (키체인 팝업 방지)
    const codesign = b.addSystemCommand(&.{ "codesign", "--force", "--sign", "-", "zig-out/bin/suji-cef-poc" });
    codesign.step.dependOn(b.getInstallStep());

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(&codesign.step);
    const run_step = b.step("run", "Run CEF POC");
    run_step.dependOn(&run_cmd.step);
}
