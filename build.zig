const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const webview_dep = b.dependency("webview", .{
        .target = target,
        .optimize = optimize,
    });

    // 공통 모듈
    const loader_module = b.createModule(.{
        .root_source_file = b.path("src/backends/loader.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Suji CLI
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    root_module.addImport("webview", webview_dep.module("webview"));
    root_module.addImport("loader", loader_module);

    const exe = b.addExecutable(.{
        .name = "suji",
        .root_module = root_module,
    });

    // webview C++ 라이브러리 링크
    exe.linkLibrary(webview_dep.artifact("webviewStatic"));

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run Suji CLI");
    run_step.dependOn(&run_cmd.step);

    // Bind test
    const bind_test_module = b.createModule(.{
        .root_source_file = b.path("poc/webview-test/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    bind_test_module.addImport("webview", webview_dep.module("webview"));

    const bind_test = b.addExecutable(.{
        .name = "bind-test",
        .root_module = bind_test_module,
    });
    bind_test.linkLibrary(webview_dep.artifact("webviewStatic"));
    b.installArtifact(bind_test);

    const bind_test_cmd = b.addRunArtifact(bind_test);
    bind_test_cmd.step.dependOn(b.getInstallStep());
    const bind_test_step = b.step("bind-test", "Run webview bind test");
    bind_test_step.dependOn(&bind_test_cmd.step);

    // Unit tests
    const test_step = b.step("test", "Run unit tests");

    // Loader tests
    const loader_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/loader_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    loader_test_mod.addImport("loader", b.createModule(.{
        .root_source_file = b.path("src/backends/loader.zig"),
        .target = target,
        .optimize = optimize,
    }));
    const loader_test = b.addTest(.{ .root_module = loader_test_mod });
    test_step.dependOn(&b.addRunArtifact(loader_test).step);

    // IPC tests
    const ipc_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/ipc_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const ipc_module = b.createModule(.{
        .root_source_file = b.path("src/core/ipc.zig"),
        .target = target,
        .optimize = optimize,
    });
    ipc_module.addImport("webview", webview_dep.module("webview"));
    ipc_module.addImport("loader", b.createModule(.{
        .root_source_file = b.path("src/backends/loader.zig"),
        .target = target,
        .optimize = optimize,
    }));
    ipc_test_mod.addImport("ipc", ipc_module);
    ipc_test_mod.addImport("webview", webview_dep.module("webview"));

    const ipc_test = b.addTest(.{ .root_module = ipc_test_mod });
    ipc_test.linkLibrary(webview_dep.artifact("webviewStatic"));
    test_step.dependOn(&b.addRunArtifact(ipc_test).step);
}
