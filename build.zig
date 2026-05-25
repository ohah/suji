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
    loader_module.addImport("util", util_module);

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
    const auto_updater_module = b.createModule(.{
        .root_source_file = b.path("src/core/auto_updater.zig"),
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
    root_module.addImport("auto_updater", auto_updater_module);

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
    // Node bridge C++ ABI는 플랫폼별 libnode와 맞춰야 한다. macOS만 Zig의
    // libc++ 경로를 쓰고, Linux/Windows는 외부 g++로 만든 object와 libstdc++
    // 경로를 명시한다.
    root_module.link_libcpp = (os_tag == .macos);

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
        // ImageIO — CGImageDestination* (desktopCapturer 썸네일 PNG 인코딩).
        root_module.linkFramework("ImageIO", .{});
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
        // nativetheme.m — NSApp.effectiveAppearance KVO 옵저버 (nativeTheme:updated).
        root_module.addCSourceFile(.{
            .file = b.path("src/platform/nativetheme.m"),
            .flags = &[_][]const u8{"-fobjc-arc"},
        });
    } else if (os_tag == .linux) {
        // Linux: CEF 공유 라이브러리 + GTK
        const cef_lib_path = std.fmt.allocPrint(b.allocator, "{s}/Release", .{cef_base}) catch @panic("OOM");
        root_module.addLibraryPath(.{ .cwd_relative = cef_lib_path });
        root_module.addRPath(.{ .cwd_relative = cef_lib_path });
        root_module.linkSystemLibrary("cef", .{});
        root_module.linkSystemLibrary("gtk-3", .{});
        root_module.linkSystemLibrary("gdk-3.0", .{});
        root_module.linkSystemLibrary("X11", .{});
        // XScreenSaver — powerMonitor idle time.
        root_module.linkSystemLibrary("Xss", .{});
        // power_monitor_linux.c — DBus power/session events via dlopen(libdbus-1.so.3).
        root_module.addCSourceFile(.{
            .file = b.path("src/platform/power_monitor_linux.c"),
            .flags = &[_][]const u8{},
        });
        // badge_linux.c — optional libunity launcher badge via dlopen.
        root_module.addCSourceFile(.{
            .file = b.path("src/platform/badge_linux.c"),
            .flags = &[_][]const u8{},
        });
        root_module.linkSystemLibrary("pthread", .{});
        root_module.linkSystemLibrary("dl", .{});
        // libsecret + GLib — safeStorage Linux backend.
        root_module.linkSystemLibrary("secret-1", .{});
        root_module.linkSystemLibrary("glib-2.0", .{});
    } else if (os_tag == .windows) {
        // Windows: CEF DLL + Win32
        const cef_lib_path = std.fmt.allocPrint(b.allocator, "{s}/Release", .{cef_base}) catch @panic("OOM");
        root_module.addLibraryPath(.{ .cwd_relative = cef_lib_path });
        root_module.linkSystemLibrary("libcef", .{});
        root_module.linkSystemLibrary("user32", .{});
        root_module.linkSystemLibrary("gdi32", .{});
        root_module.linkSystemLibrary("shell32", .{});
        // Credential Manager — safeStorage persistent OS-protected secrets.
        root_module.linkSystemLibrary("advapi32", .{});
        // shcore — GetDpiForMonitor (screen.getAllDisplays scaleFactor).
        root_module.linkSystemLibrary("shcore", .{});
        // comdlg32 — GetOpenFileNameW/GetSaveFileNameW (dialog showOpen/Save).
        root_module.linkSystemLibrary("comdlg32", .{});
        // Power Request API — powerSaveBlocker sleep/display inhibition handles.
        root_module.linkSystemLibrary("kernel32", .{});
        // power_monitor_win.c — WM_POWERBROADCAST + WTS session lock/unlock events.
        root_module.addCSourceFile(.{
            .file = b.path("src/platform/power_monitor_win.c"),
            .flags = &[_][]const u8{},
        });
        // badge_win.c — taskbar overlay icon via ITaskbarList3.
        root_module.addCSourceFile(.{
            .file = b.path("src/platform/badge_win.c"),
            .flags = &[_][]const u8{},
        });
        root_module.linkSystemLibrary("wtsapi32", .{});
        root_module.linkSystemLibrary("ole32", .{});
    }

    // libnode (Node.js 임베딩) — 선택적. OS별 dynamic lib 확장자가 달라
    // (macOS: .dylib, Linux: .so, Windows: .dll) 각각 검사.
    //
    // Windows 는 mingw-w64 ABI libnode (MSYS2 mingw-w64-x86_64-nodejs 패키지)
    // 필요 — 공식 Node.js Windows 빌드는 MSVC ABI 라 zig clang(mingw/Itanium)
    // 으로 만든 bridge.cc 와 C++ name mangling 불일치 + MSVC CRT 와 mingw libc
    // CFG 심볼 충돌. MSYS2 패키지에서 가져온 mingw libnode 는 zig 와 동일 ABI
    // (`_ZN2v86Object3NewEPNS_7IsolateE` Itanium mangling) 라 link 가능.
    const node_path = std.fmt.allocPrint(b.allocator, "{s}/.suji/node/24.14.1", .{home}) catch @panic("OOM");
    const node_lib_name: []const u8 = switch (os_tag) {
        .macos => "libnode.dylib",
        .windows => "libnode.dll",
        else => "libnode.so",
    };
    const node_available = blk: {
        const lib_path = std.fmt.allocPrint(b.allocator, "{s}/{s}", .{ node_path, node_lib_name }) catch break :blk false;
        std.Io.Dir.accessAbsolute(b.graph.io, lib_path, .{}) catch break :blk false;
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

    var gpp_bridge_step: ?*std.Build.Step = null;
    if (node_available) {
        if (os_tag == .windows) {
            // Windows: bridge.cc 를 외부 mingw g++ 로 컴파일. zig 의 clang/libcxx
            // (`std::__1::vector`) 와 mingw libnode 의 libstdc++ (`std::vector`)
            // mangling/STL layout 불일치 회피. g++ 16.1+ 필요 (`C:\mingw-w64-16\
            // mingw64\bin\g++.exe` — winlibs build).
            const bridge_obj = b.cache_root.join(b.allocator, &.{ "bridge-mingw", "bridge.o" }) catch @panic("OOM");
            const obj_dir = std.fs.path.dirname(bridge_obj) orelse @panic("path");
            const node_include = std.fmt.allocPrint(b.allocator, "{s}/include", .{node_path}) catch @panic("OOM");
            const ps_script = std.fmt.allocPrint(
                b.allocator,
                \\$ErrorActionPreference = 'Stop'
                \\$gpp = 'C:\mingw-w64-16\mingw64\bin\g++.exe'
                \\if (-not (Test-Path $gpp)) {{ throw "mingw g++ 16+ missing at $gpp. winlibs gcc 16.1.0 MSVCRT zip 풀어두기." }}
                \\New-Item -ItemType Directory -Force -Path '{s}' | Out-Null
                \\& $gpp -c -std=c++20 -I $env:SUJI_NODE_INC -I $env:SUJI_BRIDGE_INC $env:SUJI_BRIDGE_SRC -o '{s}'
                \\if ($LASTEXITCODE -ne 0) {{ throw "g++ failed: exit $LASTEXITCODE" }}
            ,
                .{ obj_dir, bridge_obj },
            ) catch @panic("OOM");
            const gpp_step = b.addSystemCommand(&.{
                "pwsh", "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", ps_script,
            });
            gpp_step.setEnvironmentVariable("SUJI_NODE_INC", node_include);
            gpp_step.setEnvironmentVariable("SUJI_BRIDGE_INC", b.path("src/platform/node").getPath(b));
            gpp_step.setEnvironmentVariable("SUJI_BRIDGE_SRC", b.path("src/platform/node/bridge.cc").getPath(b));
            gpp_bridge_step = &gpp_step.step;

            root_module.addObjectFile(.{ .cwd_relative = bridge_obj });
            const import_lib = std.fmt.allocPrint(b.allocator, "{s}/libnode.dll.a", .{node_path}) catch @panic("OOM");
            root_module.addObjectFile(.{ .cwd_relative = import_lib });

            // mingw libstdc++ / libgcc / winpthread import lib 직접 명시.
            // (linkSystemLibrary 는 mingw 의 `libNAME.dll.a` 패턴 자동 매칭 안 함).
            // winpthread 는 `x86_64-w64-mingw32/lib/` subdir 에 있어 path 별도.
            const mingw_lib = "C:\\mingw-w64-16\\mingw64\\lib";
            const mingw_target_lib = "C:\\mingw-w64-16\\mingw64\\x86_64-w64-mingw32\\lib";
            const libs_main = [_][]const u8{ "libstdc++.dll.a", "libgcc_s.a" };
            for (libs_main) |lib_name| {
                const lib_path = std.fmt.allocPrint(b.allocator, "{s}\\{s}", .{ mingw_lib, lib_name }) catch @panic("OOM");
                root_module.addObjectFile(.{ .cwd_relative = lib_path });
            }
            const libs_target = [_][]const u8{"libwinpthread.dll.a"};
            for (libs_target) |lib_name| {
                const lib_path = std.fmt.allocPrint(b.allocator, "{s}\\{s}", .{ mingw_target_lib, lib_name }) catch @panic("OOM");
                root_module.addObjectFile(.{ .cwd_relative = lib_path });
            }
        } else if (os_tag == .linux) {
            // Linux official libnode is built with libstdc++. Compiling bridge.cc
            // with Zig clang/libc++ emits std::__1 symbols and fails to link.
            const bridge_obj = b.cache_root.join(b.allocator, &.{ "bridge-linux", "bridge.o" }) catch @panic("OOM");
            const obj_dir = std.fs.path.dirname(bridge_obj) orelse @panic("path");
            const node_include = std.fmt.allocPrint(b.allocator, "{s}/include", .{node_path}) catch @panic("OOM");
            const mkdir_step = b.addSystemCommand(&.{ "mkdir", "-p", obj_dir });
            const gpp_step = b.addSystemCommand(&.{
                "g++",
                "-c",
                "-std=c++20",
                "-I",
                node_include,
                "-I",
                b.path("src/platform/node").getPath(b),
                b.path("src/platform/node/bridge.cc").getPath(b),
                "-o",
                bridge_obj,
            });
            gpp_step.step.dependOn(&mkdir_step.step);
            gpp_bridge_step = &gpp_step.step;

            root_module.addObjectFile(.{ .cwd_relative = bridge_obj });
            root_module.addLibraryPath(.{ .cwd_relative = node_path });
            root_module.linkSystemLibrary("node", .{});
            // `linkSystemLibrary("stdc++")` is treated by Zig as the target
            // C++ runtime and becomes libc++. Pass the actual GNU libstdc++
            // soname file instead of a library name so Zig does not rewrite it.
            const libstdcxx_path = blk: {
                const candidates = [_][]const u8{
                    "/usr/lib/x86_64-linux-gnu/libstdc++.so.6",
                    "/usr/lib64/libstdc++.so.6",
                    "/usr/lib/libstdc++.so.6",
                };
                for (candidates) |candidate| {
                    std.Io.Dir.accessAbsolute(b.graph.io, candidate, .{}) catch continue;
                    break :blk candidate;
                }
                @panic("libstdc++.so.6 not found; install the GNU libstdc++ runtime");
            };
            root_module.addObjectFile(.{ .cwd_relative = libstdcxx_path });
            const libgcc_s_path = blk: {
                const candidates = [_][]const u8{
                    "/lib/x86_64-linux-gnu/libgcc_s.so.1",
                    "/usr/lib/x86_64-linux-gnu/libgcc_s.so.1",
                    "/lib64/libgcc_s.so.1",
                    "/usr/lib64/libgcc_s.so.1",
                    "/usr/lib/libgcc_s.so.1",
                };
                for (candidates) |candidate| {
                    std.Io.Dir.accessAbsolute(b.graph.io, candidate, .{}) catch continue;
                    break :blk candidate;
                }
                @panic("libgcc_s.so.1 not found; install the GNU libgcc runtime");
            };
            root_module.addObjectFile(.{ .cwd_relative = libgcc_s_path });
        } else {
            root_module.addCSourceFile(.{
                .file = b.path("src/platform/node/bridge.cc"),
                .flags = &.{"-std=c++20"},
            });
            root_module.addLibraryPath(.{ .cwd_relative = node_path });
            root_module.linkSystemLibrary("node", .{});
        }
    }

    const exe = b.addExecutable(.{
        .name = "suji",
        .root_module = root_module,
    });

    // Windows: bridge.o 는 mingw g++ 가 미리 만들어야 (addObjectFile 의존성
    // 자동 추론 안 됨).
    if (gpp_bridge_step) |s| exe.step.dependOn(s);

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
        const copy_cef_runtime = addInstallCefRuntimeStep(b, os_tag, cef_base, b.getInstallPath(.bin, ""));
        copy_cef_runtime.dependOn(&install_artifact.step);
        b.getInstallStep().dependOn(copy_cef_runtime);

        // Windows: libnode.dll + mingw runtime + libnode deps 를 zig-out/bin/
        // 옆으로 복사. libnode 는 libnode.dll.a 의 import descriptor 가 가리키는
        // dll 로 runtime resolve. mingw runtime (libstdc++-6 / libgcc_s_seh-1 /
        // libwinpthread-1) 은 bridge.o 가 의존. libnode 자체가 또 OpenSSL/ICU/
        // c-ares/zlib 동적 의존 — 누락 시 STATUS_DLL_NOT_FOUND.
        // mingw + libnode deps DLL 출처는 MSYS2 mingw64 pkg 들을 미리
        // C:\msys2-deps\mingw64\bin\ 에 풀어두는 것을 가정 (run-libnode
        // setup script 가 자동화).
        if (node_available and os_tag == .windows) {
            const bin_dir_w = b.getInstallPath(.bin, "");
            const copy_dlls = b.addSystemCommand(&.{
                "pwsh", "-NoLogo", "-NoProfile", "-NonInteractive", "-Command",
                \\$ErrorActionPreference = 'Stop'
                \\New-Item -ItemType Directory -Force -Path $env:SUJI_BIN_DIR | Out-Null
                \\Copy-Item -Force -LiteralPath $env:SUJI_NODE_SRC -Destination $env:SUJI_BIN_DIR
                \\$mingw_bin = 'C:\mingw-w64-16\mingw64\bin'
                \\foreach ($d in @('libstdc++-6.dll', 'libgcc_s_seh-1.dll', 'libwinpthread-1.dll')) {
                \\  $src = Join-Path $mingw_bin $d
                \\  if (Test-Path $src) { Copy-Item -Force -LiteralPath $src -Destination $env:SUJI_BIN_DIR }
                \\  else { throw "missing mingw runtime DLL: $src (install winlibs gcc 16.1.0 MSVCRT zip to C:\mingw-w64-16\)" }
                \\}
                \\# libnode 가 dynamic load 하는 mingw 패키지 deps
                \\$deps_bin = $env:LOCALAPPDATA + '\Temp\msys2-deps\mingw64\bin'
                \\foreach ($d in @('libcares-2.dll', 'libcrypto-3-x64.dll', 'libssl-3-x64.dll',
                \\                  'libicudt78.dll', 'libicuin78.dll', 'libicuuc78.dll',
                \\                  'zlib1.dll')) {
                \\  $src = Join-Path $deps_bin $d
                \\  if (Test-Path $src) { Copy-Item -Force -LiteralPath $src -Destination $env:SUJI_BIN_DIR }
                \\  else { throw "missing libnode dep DLL: $src (MSYS2 mingw-w64-x86_64-{c-ares,openssl,icu,zlib} 패키지 압축 풀어두기)" }
                \\}
                ,
            });
            // Windows: SUJI_NODE_SRC 는 PowerShell Copy-Item -LiteralPath 에
            // 들어가므로 backslash 통일. node_path 가 forward-slash 포함이라
            // mut copy 후 / → \ 치환.
            const src_mixed = std.fmt.allocPrint(b.allocator, "{s}\\{s}", .{ node_path, node_lib_name }) catch @panic("OOM");
            std.mem.replaceScalar(u8, src_mixed, '/', '\\');
            const node_src = src_mixed;
            copy_dlls.setEnvironmentVariable("SUJI_NODE_SRC", node_src);
            copy_dlls.setEnvironmentVariable("SUJI_BIN_DIR", bin_dir_w);
            copy_dlls.step.dependOn(&install_artifact.step);
            b.getInstallStep().dependOn(&copy_dlls.step);
        }
    }

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run Suji CLI");
    run_step.dependOn(&run_cmd.step);

    // ============================================================
    // 임베드 코어 라이브러리 (CEF 무관 C ABI)
    //   src/embed.zig — BackendRegistry + EventBus 만 감싼다.
    //   CEF/Cocoa/Node 일절 링크하지 않음 → 헤드리스 테스트 / 모바일 호스트
    //   / 시스템 WebView 호스트가 정적·동적 링크로 코어를 구동.
    // ============================================================
    const embed_module = b.createModule(.{
        .root_source_file = b.path("src/embed.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true, // c_allocator (suji_core_* 경로)
    });
    embed_module.addImport("loader", loader_module);
    embed_module.addImport("events", events_module);
    embed_module.addImport("util", util_module);

    // Android JNI 호스트(.so, -shared)에 정적 .a 링크 시 zig std threadlocal
    // (Io.Threaded) Local-Exec TLS reloc 이 -shared 비호환(R_AARCH64_TLSLE_*).
    // 동적 .so 면 TLSDESC 라 회피. iOS(Mach-O)는 정적 .a 그대로 OK.
    const lib_dynamic = b.option(bool, "lib-dynamic", "Build embed core as dynamic .so (Android JNI; --libc 로 Bionic 제공 필요)") orelse false;
    const embed_lib = b.addLibrary(.{
        .name = "suji_core",
        .root_module = embed_module,
        .linkage = if (lib_dynamic) .dynamic else .static,
    });
    const embed_lib_step = b.step("lib", "Build CEF-free embeddable core library (static; -Dlib-dynamic=.so)");
    embed_lib_step.dependOn(&b.addInstallArtifact(embed_lib, .{}).step);

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
    test_loader.addImport("util", util_module);
    loader_test_mod.addImport("loader", test_loader);
    const loader_test = b.addTest(.{ .root_module = loader_test_mod });
    dependOnTestWithProjectCwd(b, test_step, loader_test);

    // Embed C ABI 헤드리스 통합 테스트 (CEF 무관)
    const embed_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/embed_abi_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const test_embed = b.createModule(.{
        .root_source_file = b.path("src/embed.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // loader_test 블록의 test_loader 모듈 인스턴스 재사용 (별도 test exe = 별도
    // 프로세스라 loader 전역 상태 공유 문제 없음).
    test_embed.addImport("loader", test_loader);
    test_embed.addImport("events", events_module);
    test_embed.addImport("util", util_module);
    embed_test_mod.addImport("embed", test_embed);
    embed_test_mod.addImport("loader", test_loader);
    const embed_test = b.addTest(.{ .root_module = embed_test_mod });
    test_step.dependOn(&b.addRunArtifact(embed_test).step);

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
    config_module.addImport("runtime", runtime_module);
    config_module.addImport("util", util_module);
    // config_module.addImport("toml", toml_dep.module("toml"));
    config_test_mod.addImport("config", config_module);

    // crash_reporter cfg renderer tests
    const crash_reporter_test_mod = b.createModule(.{
        .root_source_file = b.path("src/core/crash_reporter.zig"),
        .target = target,
        .optimize = optimize,
    });
    const crash_reporter_test = b.addTest(.{ .root_module = crash_reporter_test_mod });
    test_step.dependOn(&b.addRunArtifact(crash_reporter_test).step);
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

    // release_opts tests (서명모드/플래그 파싱 — std-only, 전 OS)
    const release_opts_module = b.createModule(.{
        .root_source_file = b.path("src/core/release_opts.zig"),
        .target = target,
        .optimize = optimize,
    });
    const release_opts_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/release_opts_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    release_opts_test_mod.addImport("release_opts", release_opts_module);
    const release_opts_test = b.addTest(.{ .root_module = release_opts_test_mod });
    test_step.dependOn(&b.addRunArtifact(release_opts_test).step);

    // Desktop packaging tests (.deb metadata + real ar archive on Unix).
    const package_desktop_module = b.createModule(.{
        .root_source_file = b.path("src/package_desktop.zig"),
        .target = target,
        .optimize = optimize,
    });
    package_desktop_module.addImport("runtime", runtime_module);
    const package_desktop_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/package_desktop_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    package_desktop_test_mod.addImport("package_desktop", package_desktop_module);
    package_desktop_test_mod.addImport("runtime", runtime_module);
    const package_desktop_test = b.addTest(.{ .root_module = package_desktop_test_mod });
    test_step.dependOn(&b.addRunArtifact(package_desktop_test).step);

    // Release workflow contract tests (YAML structure/docs guard — no GitHub API).
    const release_workflow_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/release_workflow_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const release_workflow_test = b.addTest(.{ .root_module = release_workflow_test_mod });
    dependOnTestWithProjectCwd(b, test_step, release_workflow_test);

    // init tests (suji init — BackendLang/FrontendTemplate 파싱 + create-vite 매핑)
    const init_module = b.createModule(.{
        .root_source_file = b.path("src/core/init.zig"),
        .target = target,
        .optimize = optimize,
    });
    init_module.addImport("runtime", runtime_module);
    const init_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/init_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    init_test_mod.addImport("init", init_module);
    const init_test = b.addTest(.{ .root_module = init_test_mod });
    test_step.dependOn(&b.addRunArtifact(init_test).step);

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
    routing_loader.addImport("util", util_module);
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

    // autoUpdater — manifest version checks + SHA-256 verification primitives.
    const auto_updater_test = b.addTest(.{ .root_module = auto_updater_module });
    test_step.dependOn(&b.addRunArtifact(auto_updater_test).step);

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
    state_loader.addImport("util", util_module);
    state_test_mod.addImport("loader", state_loader);
    state_test_mod.addImport("events", events_module);
    const state_test = b.addTest(.{ .root_module = state_test_mod });
    const state_test_run = b.addRunArtifact(state_test);
    state_test_run.setCwd(b.path("."));
    // state_plugin 테스트는 별도 스텝 (dylib 빌드 필요)
    const state_test_step = b.step("test-state", "Run state plugin tests (requires built dylib)");
    state_test_step.dependOn(&state_test_run.step);

    // SQLite plugin tests (state 와 동형 — 별도 스텝, dylib 빌드 필요)
    const sqlite_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/sqlite_plugin_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const sqlite_loader = b.createModule(.{
        .root_source_file = b.path("src/backends/loader.zig"),
        .target = target,
        .optimize = optimize,
    });
    sqlite_loader.addImport("events", events_module);
    sqlite_loader.addImport("runtime", runtime_module);
    sqlite_loader.addImport("util", util_module);
    sqlite_test_mod.addImport("loader", sqlite_loader);
    const sqlite_test = b.addTest(.{ .root_module = sqlite_test_mod });
    const sqlite_test_run = b.addRunArtifact(sqlite_test);
    sqlite_test_run.setCwd(b.path("."));
    const sqlite_test_step = b.step("test-sqlite", "Run SQLite plugin tests (requires built dylib)");
    sqlite_test_step.dependOn(&sqlite_test_run.step);

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
    watcher_loader.addImport("util", util_module);
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

    // CEF Views platform policy tests (CEF 런타임/헤더 불필요).
    const cef_views_policy_test_mod = b.createModule(.{
        .root_source_file = b.path("src/platform/cef_views_policy.zig"),
        .target = target,
        .optimize = optimize,
    });
    const cef_views_policy_test = b.addTest(.{ .root_module = cef_views_policy_test_mod });
    test_step.dependOn(&b.addRunArtifact(cef_views_policy_test).step);

    // CEF command-line policy tests (CEF 런타임/헤더 불필요).
    const cef_command_line_policy_test_mod = b.createModule(.{
        .root_source_file = b.path("src/platform/cef_command_line_policy.zig"),
        .target = target,
        .optimize = optimize,
    });
    const cef_command_line_policy_test = b.addTest(.{ .root_module = cef_command_line_policy_test_mod });
    test_step.dependOn(&b.addRunArtifact(cef_command_line_policy_test).step);

    // safeStorage target key tests (CEF 런타임/OS secure store 불필요).
    const safe_storage_test_mod = b.createModule(.{
        .root_source_file = b.path("src/platform/safe_storage.zig"),
        .target = target,
        .optimize = optimize,
    });
    const safe_storage_test = b.addTest(.{ .root_module = safe_storage_test_mod });
    test_step.dependOn(&b.addRunArtifact(safe_storage_test).step);
}

/// Linux/Windows CEF expects required runtime assets in the executable
/// directory for subprocess startup paths. Keep dev `zig build` output
/// self-contained enough for E2E without requiring callers to mirror CEF's
/// distribution layout manually.
fn addInstallCefRuntimeStep(b: *std.Build, os_tag: std.Target.Os.Tag, cef_base: []const u8, bin_dir: []const u8) *std.Build.Step {
    if (os_tag == .windows) {
        const copy = b.addSystemCommand(&.{
            "pwsh",
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            \\$ErrorActionPreference = 'Stop'
            \\$cefBase = $env:SUJI_CEF_BASE
            \\$binDir = $env:SUJI_BIN_DIR
            \\if ([string]::IsNullOrWhiteSpace($cefBase) -or [string]::IsNullOrWhiteSpace($binDir)) {
            \\  throw 'SUJI_CEF_BASE and SUJI_BIN_DIR must be set'
            \\}
            \\New-Item -ItemType Directory -Force -Path $binDir | Out-Null
            \\New-Item -ItemType Directory -Force -Path (Join-Path $binDir 'locales') | Out-Null
            \\$releaseFiles = @(
            \\  'chrome_elf.dll',
            \\  'd3dcompiler_47.dll',
            \\  'dxcompiler.dll',
            \\  'dxil.dll',
            \\  'libcef.dll',
            \\  'libEGL.dll',
            \\  'libGLESv2.dll',
            \\  'v8_context_snapshot.bin',
            \\  'vk_swiftshader.dll',
            \\  'vk_swiftshader_icd.json',
            \\  'vulkan-1.dll'
            \\)
            \\foreach ($file in $releaseFiles) {
            \\  $src = Join-Path (Join-Path $cefBase 'Release') $file
            \\  if (Test-Path $src) { Copy-Item $src $binDir -Force }
            \\}
            \\$resourceFiles = @(
            \\  'chrome_100_percent.pak',
            \\  'chrome_200_percent.pak',
            \\  'resources.pak',
            \\  'icudtl.dat'
            \\)
            \\foreach ($file in $resourceFiles) {
            \\  $src = Join-Path (Join-Path $cefBase 'Resources') $file
            \\  if (Test-Path $src) { Copy-Item $src $binDir -Force }
            \\}
            \\$locales = Join-Path (Join-Path $cefBase 'Resources') 'locales'
            \\if (Test-Path $locales) {
            \\  Copy-Item (Join-Path $locales '*') (Join-Path $binDir 'locales') -Recurse -Force -ErrorAction SilentlyContinue
            \\}
            ,
        });
        copy.setEnvironmentVariable("SUJI_CEF_BASE", cef_base);
        copy.setEnvironmentVariable("SUJI_BIN_DIR", bin_dir);
        return &copy.step;
    }

    const copy = b.addSystemCommand(&.{
        "sh",
        "-c",
        \\set -eu
        \\cef_base="$1"
        \\bin_dir="$2"
        \\mkdir -p "$bin_dir/locales"
        \\copy_or_link() {
        \\  src="$1"
        \\  dst="$2"
        \\  [ -e "$src" ] || return 0
        \\  ln -sf "$src" "$dst" 2>/dev/null || cp -f "$src" "$dst"
        \\}
        \\for file in \
        \\  chrome-sandbox \
        \\  libcef.so \
        \\  libEGL.so \
        \\  libGLESv2.so \
        \\  libvk_swiftshader.so \
        \\  libvulkan.so.1 \
        \\  v8_context_snapshot.bin \
        \\  vk_swiftshader_icd.json; do
        \\  copy_or_link "$cef_base/Release/$file" "$bin_dir/$file"
        \\done
        \\for file in \
        \\  chrome_100_percent.pak \
        \\  chrome_200_percent.pak \
        \\  resources.pak \
        \\  icudtl.dat; do
        \\  copy_or_link "$cef_base/Resources/$file" "$bin_dir/$file"
        \\done
        \\# libcef resolves ICU resources relative to its module directory before
        \\# cef_settings_t resource paths are fully in play. Keep these beside
        \\# Release/libcef.so as well as beside the app binary.
        \\for file in \
        \\  chrome_100_percent.pak \
        \\  chrome_200_percent.pak \
        \\  resources.pak \
        \\  icudtl.dat; do
        \\  copy_or_link "$cef_base/Resources/$file" "$cef_base/Release/$file"
        \\done
        \\if [ -d "$cef_base/Resources/locales" ]; then
        \\  cp -R "$cef_base/Resources/locales/." "$bin_dir/locales/"
        \\fi
        ,
        "install-cef-runtime",
        cef_base,
        bin_dir,
    });
    return &copy.step;
}

/// 정적 검증 테스트(`std.Io.Dir.cwd().readFileAlloc`)는 cwd가 build root여야
/// 동작. zig 0.16 zig build test는 cwd를 .zig-cache 등으로 띄울 수 있어 명시 필요.
fn dependOnTestWithProjectCwd(b: *std.Build, test_step: *std.Build.Step, t: *std.Build.Step.Compile) void {
    const r = b.addRunArtifact(t);
    r.setCwd(b.path("."));
    test_step.dependOn(&r.step);
}
