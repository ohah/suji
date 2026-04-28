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

    // 런타임 컨텍스트 (io/gpa/environ_map 전역 저장소)
    const runtime_module = b.createModule(.{
        .root_source_file = b.path("src/runtime.zig"),
        .target = target,
        .optimize = optimize,
    });

    const events_module = b.createModule(.{
        .root_source_file = b.path("src/core/events.zig"),
        .target = target,
        .optimize = optimize,
    });
    events_module.addImport("util", util_module);
    events_module.addImport("runtime", runtime_module);

    const loader_module = b.createModule(.{
        .root_source_file = b.path("src/backends/loader.zig"),
        .target = target,
        .optimize = optimize,
    });
    loader_module.addImport("events", events_module);
    loader_module.addImport("runtime", runtime_module);

    // 외부 패키지용 모듈 export (사용자가 @import("suji")로 가져감)
    const suji_module = b.addModule("suji", .{
        .root_source_file = b.path("src/core/app.zig"),
        .target = target,
        .optimize = optimize,
    });
    suji_module.addImport("events", events_module);
    suji_module.addImport("util", util_module);

    // window / event_sink / window_stack 모듈 (root_module과 테스트가 공유)
    const window_module = b.createModule(.{
        .root_source_file = b.path("src/core/window.zig"),
        .target = target,
        .optimize = optimize,
    });
    const event_sink_module = b.createModule(.{
        .root_source_file = b.path("src/core/event_sink.zig"),
        .target = target,
        .optimize = optimize,
    });
    event_sink_module.addImport("events", events_module);
    event_sink_module.addImport("window", window_module);
    const window_stack_module = b.createModule(.{
        .root_source_file = b.path("src/core/window_stack.zig"),
        .target = target,
        .optimize = optimize,
    });
    window_stack_module.addImport("events", events_module);
    window_stack_module.addImport("window", window_module);
    window_stack_module.addImport("event_sink", event_sink_module);
    const window_ipc_module = b.createModule(.{
        .root_source_file = b.path("src/core/window_ipc.zig"),
        .target = target,
        .optimize = optimize,
    });
    window_ipc_module.addImport("window", window_module);
    window_ipc_module.addImport("util", util_module);
    const logger_module = b.createModule(.{
        .root_source_file = b.path("src/core/logger.zig"),
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
    root_module.addImport("runtime", runtime_module);
    root_module.addImport("window", window_module);
    root_module.addImport("event_sink", event_sink_module);
    root_module.addImport("window_stack", window_stack_module);
    root_module.addImport("window_ipc", window_ipc_module);
    root_module.addImport("logger", logger_module);

    // CEF 헤더 + 라이브러리 경로 (OS/arch별)
    const os_tag = @import("builtin").os.tag;
    const home: []const u8 = blk: {
        const env = &b.graph.environ_map;
        if (os_tag == .windows) {
            break :blk env.get("USERPROFILE") orelse "C:\\Users\\Default";
        }
        break :blk env.get("HOME") orelse "/tmp";
    };
    const cef_platform = switch (os_tag) {
        .macos => "macos-arm64",
        .linux => "linux-x86_64",
        .windows => "windows-x86_64",
        else => @compileError("unsupported OS"),
    };

    const cef_base = std.fmt.allocPrint(b.allocator, "{s}/.suji/cef/{s}", .{ home, cef_platform }) catch @panic("OOM");
    root_module.addIncludePath(.{ .cwd_relative = cef_base });
    root_module.link_libcpp = true;

    if (os_tag == .macos) {
        // macOS: CEF framework + Objective-C
        const cef_fw_path = std.fmt.allocPrint(b.allocator, "{s}/Release", .{cef_base}) catch @panic("OOM");
        root_module.addFrameworkPath(.{ .cwd_relative = cef_fw_path });
        root_module.linkFramework("Chromium Embedded Framework", .{});
        root_module.linkSystemLibrary("objc", .{});
        root_module.linkFramework("Cocoa", .{});
        // dialog.m — sheet completion handler (^block) wrapper. ARC 필수 — `__bridge` 캐스트
        // 안전성 + completion handler block 자동 autorelease.
        // Zig는 ObjC block을 직접 못 만들어서 .m 파일 통해 NSAlert/NSSavePanel
        // beginSheetModalForWindow:completionHandler: 호출.
        root_module.addCSourceFile(.{
            .file = b.path("src/platform/dialog.m"),
            .flags = &[_][]const u8{"-fobjc-arc"},
        });
        // notification.m — UNUserNotificationCenter wrapper (block completion handlers
        // for requestAuthorizationWithOptions / addNotificationRequest + delegate).
        root_module.addCSourceFile(.{
            .file = b.path("src/platform/notification.m"),
            .flags = &[_][]const u8{"-fobjc-arc"},
        });
        root_module.linkFramework("UserNotifications", .{});
        // global_shortcut.m — Carbon RegisterEventHotKey wrapper. Carbon is deprecated for
        // most uses but the Hot Key API is still the only no-permission system-wide path
        // (NSEvent.addGlobalMonitorForEvents requires accessibility). Same approach Electron uses.
        root_module.addCSourceFile(.{
            .file = b.path("src/platform/global_shortcut.m"),
            .flags = &[_][]const u8{"-fobjc-arc"},
        });
        root_module.linkFramework("Carbon", .{});
        // IOKit — IOPMAssertionCreateWithName / Release (powerSaveBlocker).
        root_module.linkFramework("IOKit", .{});
        // Security — Keychain Services (safeStorage).
        root_module.linkFramework("Security", .{});
        // window_lifecycle.m — NSWindowDelegate (resize/focus/blur/move) → C callback.
        root_module.addCSourceFile(.{
            .file = b.path("src/platform/window_lifecycle.m"),
            .flags = &[_][]const u8{"-fobjc-arc"},
        });
        // power_monitor.m — NSWorkspace 전원 알림 옵저버 (powerMonitor).
        root_module.addCSourceFile(.{
            .file = b.path("src/platform/power_monitor.m"),
            .flags = &[_][]const u8{"-fobjc-arc"},
        });
    } else if (os_tag == .linux) {
        // Linux: CEF 공유 라이브러리 + GTK
        const cef_lib_path = std.fmt.allocPrint(b.allocator, "{s}/Release", .{cef_base}) catch @panic("OOM");
        root_module.addLibraryPath(.{ .cwd_relative = cef_lib_path });
        root_module.linkSystemLibrary("cef", .{});
        root_module.linkSystemLibrary("gtk-3", .{});
        root_module.linkSystemLibrary("gdk-3.0", .{});
        root_module.linkSystemLibrary("X11", .{});
    } else if (os_tag == .windows) {
        // Windows: CEF DLL + Win32
        const cef_lib_path = std.fmt.allocPrint(b.allocator, "{s}/Release", .{cef_base}) catch @panic("OOM");
        root_module.addLibraryPath(.{ .cwd_relative = cef_lib_path });
        root_module.linkSystemLibrary("libcef", .{});
        root_module.linkSystemLibrary("user32", .{});
        root_module.linkSystemLibrary("gdi32", .{});
        root_module.linkSystemLibrary("shell32", .{});
    }

    // libnode (Node.js 임베딩) — 선택적
    const node_path = std.fmt.allocPrint(b.allocator, "{s}/.suji/node/24.14.1", .{home}) catch @panic("OOM");
    const node_available = blk: {
        const dylib = std.fmt.allocPrint(b.allocator, "{s}/libnode.dylib", .{node_path}) catch break :blk false;
        std.Io.Dir.accessAbsolute(b.graph.io, dylib, .{}) catch break :blk false;
        break :blk true;
    };
    // Node.js 지원 (libnode가 설치된 경우만)
    root_module.addIncludePath(b.path("src/platform/node"));
    const node_options = b.addOptions();
    node_options.addOption(bool, "node_enabled", node_available);
    root_module.addImport("node_config", node_options.createModule());
    if (node_available) {
        const node_include = std.fmt.allocPrint(b.allocator, "{s}/include", .{node_path}) catch @panic("OOM");
        root_module.addIncludePath(.{ .cwd_relative = node_include });
    }

    const exe = b.addExecutable(.{
        .name = "suji",
        .root_module = root_module,
    });

    if (node_available) {
        // bridge.cc를 C++ 오브젝트로 컴파일 + 링크
        root_module.addCSourceFile(.{
            .file = b.path("src/platform/node/bridge.cc"),
            .flags = &.{"-std=c++20"},
        });
        root_module.addLibraryPath(.{ .cwd_relative = node_path });
        root_module.linkSystemLibrary("node", .{});
    }

    if (os_tag == .macos) {
        exe.headerpad_max_install_names = true;
    }

    // 플랫폼별 post-install 처리
    const install_artifact = b.addInstallArtifact(exe, .{});

    if (os_tag == .macos) {
        // macOS: CEF 프레임워크 로드 경로 수정 + GPU 라이브러리 심링크 + ad-hoc 코드서명
        const suji_bin = b.getInstallPath(.bin, "suji");
        const bin_dir = b.getInstallPath(.bin, "");
        // dev binary는 ad-hoc 서명만 (entitlements 없이) — Mac App Sandbox 활성 plist는
        // dev에서 trace trap 유발. bundle_macos가 production .app 만들 때 helper별
        // entitlements 부착 (sandbox 활성).

        const fix_rpath = b.addSystemCommand(&.{
            "install_name_tool",                                                                                "-change",
            "@executable_path/../Frameworks/Chromium Embedded Framework.framework/Chromium Embedded Framework",
        });
        const cef_fw_abs = std.fmt.allocPrint(b.allocator, "{s}/Release/Chromium Embedded Framework.framework/Chromium Embedded Framework", .{cef_base}) catch @panic("OOM");
        fix_rpath.addArg(cef_fw_abs);
        fix_rpath.addArg(suji_bin);
        fix_rpath.step.dependOn(&install_artifact.step);

        // CEF GPU 서브프로세스가 `@executable_path/libGLESv2.dylib` 등을 찾으므로
        // zig-out/bin/ 옆에 CEF Framework의 Libraries를 절대 경로 심링크로 노출.
        // bundle_macos.zig의 symlinkGpuLibs와 동일 역할 (번들 vs dev 빌드 두 경로 모두 필요).
        const cef_libs_dir = std.fmt.allocPrint(b.allocator, "{s}/Release/Chromium Embedded Framework.framework/Libraries", .{cef_base}) catch @panic("OOM");
        const gpu_assets = [_][]const u8{ "libEGL.dylib", "libGLESv2.dylib", "libvk_swiftshader.dylib", "vk_swiftshader_icd.json" };
        var prev_step: *std.Build.Step = &fix_rpath.step;
        for (gpu_assets) |asset| {
            const src = std.fmt.allocPrint(b.allocator, "{s}/{s}", .{ cef_libs_dir, asset }) catch @panic("OOM");
            const dst = std.fmt.allocPrint(b.allocator, "{s}/{s}", .{ bin_dir, asset }) catch @panic("OOM");
            const symlink_cmd = b.addSystemCommand(&.{ "ln", "-sfh", src, dst });
            symlink_cmd.step.dependOn(prev_step);
            prev_step = &symlink_cmd.step;
        }

        const codesign = b.addSystemCommand(&.{
            "codesign", "--force", "--sign", "-", "--deep",
        });
        codesign.addArg(suji_bin);
        codesign.step.dependOn(prev_step);
        b.getInstallStep().dependOn(&codesign.step);

        const sign_step = b.step("sign", "Ad-hoc codesign for macOS");
        sign_step.dependOn(&codesign.step);
    } else {
        b.getInstallStep().dependOn(&install_artifact.step);
    }

    const run_cmd = b.addRunArtifact(exe);
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
    test_loader.addImport("runtime", runtime_module);
    loader_test_mod.addImport("loader", test_loader);
    const loader_test = b.addTest(.{ .root_module = loader_test_mod });
    dependOnTestWithProjectCwd(b, test_step, loader_test);

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
    config_module.addImport("window", window_module);
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
    const app_test_app_mod = b.createModule(.{
        .root_source_file = b.path("src/core/app.zig"),
        .target = target,
        .optimize = optimize,
    });
    app_test_app_mod.addImport("events", events_module);
    app_test_app_mod.addImport("util", util_module);
    app_test_mod.addImport("app", app_test_app_mod);
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
    routing_loader.addImport("runtime", runtime_module);
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

    // 공용 TestNative (window.Native stub)
    const test_native_module = b.createModule(.{
        .root_source_file = b.path("tests/test_native.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_native_module.addImport("window", window_module);

    // WindowManager 단위 테스트 (CEF 없음, 순수 로직)
    const window_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/window_manager_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    window_test_mod.addImport("window", window_module);
    window_test_mod.addImport("test_native", test_native_module);
    const window_test = b.addTest(.{ .root_module = window_test_mod });
    dependOnTestWithProjectCwd(b, test_step, window_test);

    // EventBusSink 어댑터 단위 테스트
    const event_sink_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/event_sink_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    event_sink_test_mod.addImport("event_sink", event_sink_module);
    event_sink_test_mod.addImport("events", events_module);
    event_sink_test_mod.addImport("window", window_module);
    event_sink_test_mod.addImport("test_native", test_native_module);
    const event_sink_test = b.addTest(.{ .root_module = event_sink_test_mod });
    test_step.dependOn(&b.addRunArtifact(event_sink_test).step);

    // WindowStack — WM + EventBusSink 배선 묶음
    const window_stack_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/window_stack_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    window_stack_test_mod.addImport("window_stack", window_stack_module);
    window_stack_test_mod.addImport("events", events_module);
    window_stack_test_mod.addImport("window", window_module);
    window_stack_test_mod.addImport("event_sink", event_sink_module);
    window_stack_test_mod.addImport("test_native", test_native_module);
    const window_stack_test = b.addTest(.{ .root_module = window_stack_test_mod });
    test_step.dependOn(&b.addRunArtifact(window_stack_test).step);

    // window_ipc — create_window 커맨드 핸들러
    const window_ipc_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/window_ipc_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    window_ipc_test_mod.addImport("window_ipc", window_ipc_module);
    window_ipc_test_mod.addImport("window", window_module);
    window_ipc_test_mod.addImport("test_native", test_native_module);
    const window_ipc_test = b.addTest(.{ .root_module = window_ipc_test_mod });
    test_step.dependOn(&b.addRunArtifact(window_ipc_test).step);

    // logger — 구조화 로깅
    const logger_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/logger_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    logger_test_mod.addImport("logger", logger_module);
    const logger_test = b.addTest(.{ .root_module = logger_test_mod });
    test_step.dependOn(&b.addRunArtifact(logger_test).step);

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
    state_loader.addImport("runtime", runtime_module);
    state_test_mod.addImport("loader", state_loader);
    state_test_mod.addImport("events", events_module);
    const state_test = b.addTest(.{ .root_module = state_test_mod });
    const state_test_run = b.addRunArtifact(state_test);
    state_test_run.setCwd(b.path("."));
    // state_plugin 테스트는 별도 스텝 (dylib 빌드 필요)
    const state_test_step = b.step("test-state", "Run state plugin tests (requires built dylib)");
    state_test_step.dependOn(&state_test_run.step);

    // State plugin Rust 래퍼 통합 테스트
    // Rust bridge dylib를 cargo로 빌드한 뒤 Zig 테스트에서 로드.
    const rust_wrapper_mod = b.createModule(.{
        .root_source_file = b.path("tests/state_rust_wrapper_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    rust_wrapper_mod.addImport("loader", state_loader);
    const rust_wrapper_test = b.addTest(.{ .root_module = rust_wrapper_mod });
    const rust_wrapper_run = b.addRunArtifact(rust_wrapper_test);
    rust_wrapper_run.setCwd(b.path("."));

    const cargo_build_rust_bridge = b.addSystemCommand(&.{ "cargo", "build" });
    cargo_build_rust_bridge.setCwd(b.path("tests/fixtures/state_rust_bridge"));
    rust_wrapper_run.step.dependOn(&cargo_build_rust_bridge.step);

    const rust_wrapper_step = b.step("test-state-rust", "Run Rust wrapper integration tests (builds Rust bridge + requires state dylib)");
    rust_wrapper_step.dependOn(&rust_wrapper_run.step);

    // State plugin Go 래퍼 통합 테스트
    const go_wrapper_mod = b.createModule(.{
        .root_source_file = b.path("tests/state_go_wrapper_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    go_wrapper_mod.addImport("loader", state_loader);
    const go_wrapper_test = b.addTest(.{ .root_module = go_wrapper_mod });
    const go_wrapper_run = b.addRunArtifact(go_wrapper_test);
    go_wrapper_run.setCwd(b.path("."));

    const go_bridge_lib = switch (target.result.os.tag) {
        .macos => "libbackend.dylib",
        .linux => "libbackend.so",
        .windows => "backend.dll",
        else => "libbackend.dylib",
    };
    const go_build = b.addSystemCommand(&.{
        "go", "build", "-buildmode=c-shared", "-o", go_bridge_lib, "main.go",
    });
    go_build.setCwd(b.path("tests/fixtures/state_go_bridge"));
    // macOS: Homebrew LLVM과 충돌 회피 (examples/multi-backend/backends/go와 동일)
    if (target.result.os.tag == .macos) {
        go_build.setEnvironmentVariable("CC", "/usr/bin/clang");
    }
    go_build.setEnvironmentVariable("CGO_ENABLED", "1");
    go_wrapper_run.step.dependOn(&go_build.step);

    const go_wrapper_step = b.step("test-state-go", "Run Go wrapper integration tests (builds Go bridge + requires state dylib)");
    go_wrapper_step.dependOn(&go_wrapper_run.step);

    // Watcher + hot reload tests
    const watcher_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/watcher_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const watcher_module = b.createModule(.{
        .root_source_file = b.path("src/platform/watcher.zig"),
        .target = target,
        .optimize = optimize,
    });
    watcher_module.addImport("runtime", runtime_module);
    const watcher_loader = b.createModule(.{
        .root_source_file = b.path("src/backends/loader.zig"),
        .target = target,
        .optimize = optimize,
    });
    watcher_loader.addImport("events", events_module);
    watcher_loader.addImport("runtime", runtime_module);
    watcher_test_mod.addImport("watcher", watcher_module);
    watcher_test_mod.addImport("loader", watcher_loader);
    const watcher_test = b.addTest(.{ .root_module = watcher_test_mod });
    test_step.dependOn(&b.addRunArtifact(watcher_test).step);

    // Node.js tests (stub + NodeRuntime 구조체).
    // 테스트는 libnode 링크 없이 돌려야 하므로 node_config를 항상 false로 고정.
    // (node_enabled=true면 bridge가 @cImport로 C 심볼을 요구 → bridge.cc 없이는 link fail)
    const node_test_opts = b.addOptions();
    node_test_opts.addOption(bool, "node_enabled", false);
    const node_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/node_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const node_module = b.createModule(.{
        .root_source_file = b.path("src/platform/node.zig"),
        .target = target,
        .optimize = optimize,
    });
    node_module.addImport("node_config", node_test_opts.createModule());
    node_module.addIncludePath(b.path("src/platform/node"));
    node_test_mod.addImport("node", node_module);
    const node_test = b.addTest(.{ .root_module = node_test_mod });
    dependOnTestWithProjectCwd(b, test_step, node_test);

    // CEF IPC tests (순수 함수 — CEF 런타임 불필요)
    const cef_ipc_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/cef_ipc_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const cef_ipc_test = b.addTest(.{ .root_module = cef_ipc_test_mod });
    test_step.dependOn(&b.addRunArtifact(cef_ipc_test).step);

    // CEF drag region hit-test tests (CEF 런타임/헤더 불필요) — 테스트는 src 파일에 인라인.
    const cef_drag_region_test_mod = b.createModule(.{
        .root_source_file = b.path("src/platform/cef_drag_region.zig"),
        .target = target,
        .optimize = optimize,
    });
    const cef_drag_region_test = b.addTest(.{ .root_module = cef_drag_region_test_mod });
    test_step.dependOn(&b.addRunArtifact(cef_drag_region_test).step);
}

/// 정적 검증 테스트(`std.Io.Dir.cwd().readFileAlloc`)는 cwd가 build root여야
/// 동작. zig 0.16 zig build test는 cwd를 .zig-cache 등으로 띄울 수 있어 명시 필요.
fn dependOnTestWithProjectCwd(b: *std.Build, test_step: *std.Build.Step, t: *std.Build.Step.Compile) void {
    const r = b.addRunArtifact(t);
    r.setCwd(b.path("."));
    test_step.dependOn(&r.step);
}
