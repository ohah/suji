const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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
    root_module.link_libcpp = true;
    // macOS: Objective-C 런타임 (NSWindow, NSApp 등)
    root_module.linkSystemLibrary("objc", .{});
    root_module.linkFramework("Cocoa", .{});
    // root_module.addImport("toml", toml_dep.module("toml"));

    const exe = b.addExecutable(.{
        .name = "suji",
        .root_module = root_module,
    });
    // install_name_tool용 헤더 패딩
    exe.headerpad_max_install_names = true;

    // macOS: CEF 프레임워크 로드 경로 수정 + ad-hoc 코드서명
    // 주의: installArtifact가 바이너리를 복사한 후에 실행해야 함
    const install_artifact = b.addInstallArtifact(exe, .{});

    const fix_rpath = b.addSystemCommand(&.{
        "install_name_tool", "-change",
        "@executable_path/../Frameworks/Chromium Embedded Framework.framework/Chromium Embedded Framework",
    });
    const cef_fw_abs = std.fmt.allocPrint(b.allocator, "{s}/.suji/cef/macos-arm64/Release/Chromium Embedded Framework.framework/Chromium Embedded Framework", .{home}) catch @panic("OOM");
    fix_rpath.addArg(cef_fw_abs);
    fix_rpath.addArg("zig-out/bin/suji");
    fix_rpath.step.dependOn(&install_artifact.step);

    const codesign = b.addSystemCommand(&.{
        "codesign", "--force", "--sign", "-",
        "--entitlements", "macos-entitlements.plist",
        "--deep",
        "zig-out/bin/suji",
    });
    codesign.step.dependOn(&fix_rpath.step);

    b.getInstallStep().dependOn(&codesign.step);

    const sign_step = b.step("sign", "Ad-hoc codesign for macOS");
    sign_step.dependOn(&codesign.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(&codesign.step);
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
    const state_test_run = b.addRunArtifact(state_test);
    state_test_run.setCwd(b.path("."));
    test_step.dependOn(&state_test_run.step);

    // CEF IPC tests (순수 함수 — CEF 런타임 불필요)
    const cef_ipc_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/cef_ipc_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const cef_ipc_test = b.addTest(.{ .root_module = cef_ipc_test_mod });
    test_step.dependOn(&b.addRunArtifact(cef_ipc_test).step);
}
