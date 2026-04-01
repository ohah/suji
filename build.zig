const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const webview_dep = b.dependency("webview", .{
        .target = target,
        .optimize = optimize,
    });

    // TOML 지원은 백로그 (현재 JSON만)
    // const toml_dep = b.dependency("toml", .{ .target = target, .optimize = optimize });

    // 공통 모듈
    const util_module = b.createModule(.{
        .root_source_file = b.path("src/core/util.zig"),
        .target = target,
        .optimize = optimize,
    });

    const events_module = b.createModule(.{
        .root_source_file = b.path("src/core/events.zig"),
        .target = target,
        .optimize = optimize,
    });
    events_module.addImport("util", util_module);

    const loader_module = b.createModule(.{
        .root_source_file = b.path("src/backends/loader.zig"),
        .target = target,
        .optimize = optimize,
    });
    loader_module.addImport("events", events_module);

    // 외부 패키지용 모듈 export (사용자가 @import("suji")로 가져감)
    _ = b.addModule("suji", .{
        .root_source_file = b.path("src/core/app.zig"),
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
    root_module.addImport("events", events_module);
    root_module.addImport("util", util_module);

    // CEF 헤더 + 라이브러리 경로
    const home = std.posix.getenv("HOME") orelse "/tmp";
    const cef_include = std.fmt.allocPrint(b.allocator, "{s}/.suji/cef/macos-arm64", .{home}) catch @panic("OOM");
    root_module.addIncludePath(.{ .cwd_relative = cef_include });
    const cef_fw_path = std.fmt.allocPrint(b.allocator, "{s}/.suji/cef/macos-arm64/Release", .{home}) catch @panic("OOM");
    root_module.addFrameworkPath(.{ .cwd_relative = cef_fw_path });
    root_module.linkFramework("Chromium Embedded Framework", .{});
    // root_module.addImport("toml", toml_dep.module("toml"));

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

    // Unit tests
    const test_step = b.step("test", "Run unit tests");

    // Loader tests
    const loader_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/loader_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const test_loader = b.createModule(.{
        .root_source_file = b.path("src/backends/loader.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_loader.addImport("events", events_module);
    loader_test_mod.addImport("loader", test_loader);
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
    ipc_module.addImport("events", events_module);
    const ipc_loader_mod = b.createModule(.{
        .root_source_file = b.path("src/backends/loader.zig"),
        .target = target,
        .optimize = optimize,
    });
    ipc_loader_mod.addImport("events", events_module);
    ipc_module.addImport("loader", ipc_loader_mod);
    ipc_test_mod.addImport("ipc", ipc_module);
    ipc_test_mod.addImport("webview", webview_dep.module("webview"));

    const ipc_test = b.addTest(.{ .root_module = ipc_test_mod });
    ipc_test.linkLibrary(webview_dep.artifact("webviewStatic"));
    test_step.dependOn(&b.addRunArtifact(ipc_test).step);

    // Config tests
    const config_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/config_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const config_module = b.createModule(.{
        .root_source_file = b.path("src/core/config.zig"),
        .target = target,
        .optimize = optimize,
    });
    // config_module.addImport("toml", toml_dep.module("toml"));
    config_test_mod.addImport("config", config_module);
    // Events tests
    const events_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/events_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    events_test_mod.addImport("events", events_module);
    const events_test = b.addTest(.{ .root_module = events_test_mod });
    test_step.dependOn(&b.addRunArtifact(events_test).step);

    // App tests
    const app_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/app_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    app_test_mod.addImport("app", b.createModule(.{
        .root_source_file = b.path("src/core/app.zig"),
        .target = target,
        .optimize = optimize,
    }));
    const app_test = b.addTest(.{ .root_module = app_test_mod });
    test_step.dependOn(&b.addRunArtifact(app_test).step);

    const config_test = b.addTest(.{ .root_module = config_test_mod });
    test_step.dependOn(&b.addRunArtifact(config_test).step);

    // Routing tests
    const routing_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/routing_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const routing_loader = b.createModule(.{
        .root_source_file = b.path("src/backends/loader.zig"),
        .target = target,
        .optimize = optimize,
    });
    routing_loader.addImport("events", events_module);
    routing_test_mod.addImport("loader", routing_loader);
    const routing_test = b.addTest(.{ .root_module = routing_test_mod });
    test_step.dependOn(&b.addRunArtifact(routing_test).step);

    // Events integration tests
    const events_int_mod = b.createModule(.{
        .root_source_file = b.path("tests/events_integration_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    events_int_mod.addImport("events", events_module);
    const events_int_test = b.addTest(.{ .root_module = events_int_mod });
    test_step.dependOn(&b.addRunArtifact(events_int_test).step);

    // State plugin tests
    const state_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/state_plugin_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const state_loader = b.createModule(.{
        .root_source_file = b.path("src/backends/loader.zig"),
        .target = target,
        .optimize = optimize,
    });
    state_loader.addImport("events", events_module);
    state_test_mod.addImport("loader", state_loader);
    state_test_mod.addImport("events", events_module);
    const state_test = b.addTest(.{ .root_module = state_test_mod });
    test_step.dependOn(&b.addRunArtifact(state_test).step);

    // Asset server tests
    const asset_server_module = b.createModule(.{
        .root_source_file = b.path("src/core/asset_server.zig"),
        .target = target,
        .optimize = optimize,
    });
    const asset_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/asset_server_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    asset_test_mod.addImport("asset_server", asset_server_module);
    const asset_test = b.addTest(.{ .root_module = asset_test_mod });
    test_step.dependOn(&b.addRunArtifact(asset_test).step);
}
