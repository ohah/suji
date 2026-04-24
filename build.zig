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
    _ = b.addModule("suji", .{
        .root_source_file = b.path("src/core/app.zig"),
        .target = target,
        .optimize = optimize,
    });

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
        const entitlements = b.pathFromRoot("macos-entitlements.plist");

        const fix_rpath = b.addSystemCommand(&.{
            "install_name_tool", "-change",
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
            "codesign", "--force", "--sign", "-",
            "--entitlements",
        });
        codesign.addArg(entitlements);
        codesign.addArg("--deep");
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
    test_step.dependOn(&b.addRunArtifact(window_test).step);

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

    // Node.js tests (stub + NodeRuntime 구조체)
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
    node_module.addImport("node_config", node_options.createModule());
    node_module.addIncludePath(b.path("src/platform/node"));
    if (node_available) {
        const node_test_include = std.fmt.allocPrint(b.allocator, "{s}/include", .{node_path}) catch @panic("OOM");
        node_module.addIncludePath(.{ .cwd_relative = node_test_include });
    }
    node_test_mod.addImport("node", node_module);
    const node_test = b.addTest(.{ .root_module = node_test_mod });
    test_step.dependOn(&b.addRunArtifact(node_test).step);

    // CEF IPC tests (순수 함수 — CEF 런타임 불필요)
    const cef_ipc_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/cef_ipc_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const cef_ipc_test = b.addTest(.{ .root_module = cef_ipc_test_mod });
    test_step.dependOn(&b.addRunArtifact(cef_ipc_test).step);
}
