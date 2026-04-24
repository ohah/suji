const std = @import("std");
const runtime = @import("runtime");

const Dir = std.Io.Dir;

/// macOS .app 번들 생성
///
/// 구조:
/// {name}.app/
/// ├── Contents/
/// │   ├── Info.plist
/// │   ├── MacOS/
/// │   │   └── {name}              ← 메인 바이너리
/// │   ├── Frameworks/
/// │   │   ├── Chromium Embedded Framework.framework/
/// │   │   ├── {name} Helper.app/
/// │   │   ├── {name} Helper (GPU).app/
/// │   │   ├── {name} Helper (Renderer).app/
/// │   │   └── {name} Helper (Plugin).app/
/// │   └── Resources/
/// │       └── frontend/           ← 프론트엔드 빌드 결과
pub fn createBundle(
    allocator: std.mem.Allocator,
    name: []const u8,
    version: []const u8,
    identifier: []const u8,
    exe_path: []const u8,
    frontend_dist: []const u8,
) !void {
    const app_name = try std.fmt.allocPrint(allocator, "{s}.app", .{name});
    defer allocator.free(app_name);

    std.debug.print("[suji] creating bundle: {s}\n", .{app_name});

    // 디렉토리 생성
    const dirs = [_][]const u8{
        "Contents",
        "Contents/MacOS",
        "Contents/Frameworks",
        "Contents/Resources",
        "Contents/Resources/frontend",
    };
    for (dirs) |dir| {
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ app_name, dir });
        defer allocator.free(path);
        Dir.cwd().createDirPath(runtime.io, path) catch {};
    }

    // 1. Info.plist 생성
    try writeInfoPlist(allocator, app_name, name, version, identifier);

    // 2. 메인 바이너리 복사
    try copyFile(allocator, exe_path, try std.fmt.allocPrint(allocator, "{s}/Contents/MacOS/{s}", .{ app_name, name }));

    // 3. CEF 프레임워크 복사
    try copyCefFramework(allocator, app_name);

    // 4. Helper 앱 생성
    const helper_types = [_][]const u8{ "", " (GPU)", " (Renderer)", " (Plugin)" };
    for (helper_types) |suffix| {
        try createHelperApp(allocator, app_name, name, suffix, identifier);
    }

    // 5. GPU 라이브러리를 MacOS/ 옆에 심링크 (libGLESv2 등)
    try symlinkGpuLibs(allocator, app_name);

    // 6. 프론트엔드 dist 복사
    try copyDir(allocator, frontend_dist, try std.fmt.allocPrint(allocator, "{s}/Contents/Resources/frontend", .{app_name}));

    // 7. 메인 바이너리 install_name_tool
    try fixMainBinaryRpath(allocator, app_name, name);

    // 8. 코드서명
    try codesignBundle(allocator, app_name, name);

    std.debug.print("[suji] bundle created: {s}\n", .{app_name});
}

fn writeInfoPlist(allocator: std.mem.Allocator, app_name: []const u8, name: []const u8, version: []const u8, identifier: []const u8) !void {
    const path = try std.fmt.allocPrint(allocator, "{s}/Contents/Info.plist", .{app_name});
    defer allocator.free(path);

    const plist = try std.fmt.allocPrint(allocator,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\  <key>CFBundleDisplayName</key>
        \\  <string>{s}</string>
        \\  <key>CFBundleExecutable</key>
        \\  <string>{s}</string>
        \\  <key>CFBundleIdentifier</key>
        \\  <string>{s}</string>
        \\  <key>CFBundleVersion</key>
        \\  <string>{s}</string>
        \\  <key>CFBundleShortVersionString</key>
        \\  <string>{s}</string>
        \\  <key>CFBundlePackageType</key>
        \\  <string>APPL</string>
        \\  <key>CFBundleInfoDictionaryVersion</key>
        \\  <string>6.0</string>
        \\  <key>NSHighResolutionCapable</key>
        \\  <true/>
        \\  <key>NSSupportsAutomaticGraphicsSwitching</key>
        \\  <true/>
        \\</dict>
        \\</plist>
    , .{ name, name, identifier, version, version });
    defer allocator.free(plist);

    {
        const io = runtime.io;
        var file = try Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        var buf: [4096]u8 = undefined;
        var fw = file.writer(io, &buf);
        try fw.interface.writeAll(plist);
        try fw.interface.flush();
    }
}

fn copyCefFramework(allocator: std.mem.Allocator, app_name: []const u8) !void {
    const home = runtime.env("HOME") orelse "/tmp";
    const src = try std.fmt.allocPrint(allocator, "{s}/.suji/cef/macos-arm64/Release/Chromium Embedded Framework.framework", .{home});
    defer allocator.free(src);
    const dst = try std.fmt.allocPrint(allocator, "{s}/Contents/Frameworks/Chromium Embedded Framework.framework", .{app_name});
    defer allocator.free(dst);

    std.debug.print("[suji] copying CEF framework...\n", .{});
    // APFS clone (-c) で instant copy, fallback to regular cp
    runCmd(allocator, &.{ "cp", "-Rc", src, dst }) catch {
        try runCmd(allocator, &.{ "cp", "-R", src, dst });
    };
}

fn createHelperApp(allocator: std.mem.Allocator, app_name: []const u8, name: []const u8, suffix: []const u8, identifier: []const u8) !void {
    const helper_name = try std.fmt.allocPrint(allocator, "{s} Helper{s}", .{ name, suffix });
    defer allocator.free(helper_name);
    const helper_app = try std.fmt.allocPrint(allocator, "{s}/Contents/Frameworks/{s}.app", .{ app_name, helper_name });
    defer allocator.free(helper_app);
    const helper_macos = try std.fmt.allocPrint(allocator, "{s}/Contents/MacOS", .{helper_app});
    defer allocator.free(helper_macos);

    Dir.cwd().createDirPath(runtime.io, helper_macos) catch {};

    // Helper 바이너리 = 메인 바이너리 hardlink (codesign은 hardlink OK, symlink 거부)
    const helper_exe = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ helper_macos, helper_name });
    defer allocator.free(helper_exe);
    const main_src = try std.fmt.allocPrint(allocator, "{s}/Contents/MacOS/{s}", .{ app_name, name });
    defer allocator.free(main_src);
    runCmd(allocator, &.{ "ln", main_src, helper_exe }) catch {
        try runCmd(allocator, &.{ "cp", main_src, helper_exe });
    };
    try runCmd(allocator, &.{ "chmod", "+x", helper_exe });

    // Helper Info.plist
    const helper_id = try std.fmt.allocPrint(allocator, "{s}.helper{s}", .{ identifier, suffix });
    defer allocator.free(helper_id);
    const plist_path = try std.fmt.allocPrint(allocator, "{s}/Contents/Info.plist", .{helper_app});
    defer allocator.free(plist_path);

    const plist = try std.fmt.allocPrint(allocator,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\  <key>CFBundleExecutable</key>
        \\  <string>{s}</string>
        \\  <key>CFBundleIdentifier</key>
        \\  <string>{s}</string>
        \\  <key>CFBundlePackageType</key>
        \\  <string>APPL</string>
        \\</dict>
        \\</plist>
    , .{ helper_name, helper_id });
    defer allocator.free(plist);

    {
        const io = runtime.io;
        var file = try Dir.cwd().createFile(io, plist_path, .{});
        defer file.close(io);
        var buf: [4096]u8 = undefined;
        var fw = file.writer(io, &buf);
        try fw.interface.writeAll(plist);
        try fw.interface.flush();
    }
}

fn symlinkGpuLibs(allocator: std.mem.Allocator, app_name: []const u8) !void {
    // CEF가 실행 파일 옆에서 GPU 라이브러리를 찾음
    const libs = [_][]const u8{ "libEGL.dylib", "libGLESv2.dylib", "libvk_swiftshader.dylib", "vk_swiftshader_icd.json" };
    for (libs) |lib| {
        const target = try std.fmt.allocPrintSentinel(allocator, "../Frameworks/Chromium Embedded Framework.framework/Libraries/{s}", .{lib}, 0);
        defer allocator.free(target);
        const link = try std.fmt.allocPrintSentinel(allocator, "{s}/Contents/MacOS/{s}", .{ app_name, lib }, 0);
        defer allocator.free(link);
        const rc = std.c.symlink(target.ptr, link.ptr);
        if (rc != 0) {
            const errno = std.posix.errno(rc);
            if (errno == .EXIST) continue;
            return error.SymlinkFailed;
        }
    }
}

fn fixMainBinaryRpath(allocator: std.mem.Allocator, app_name: []const u8, name: []const u8) !void {
    const exe = try std.fmt.allocPrint(allocator, "{s}/Contents/MacOS/{s}", .{ app_name, name });
    defer allocator.free(exe);

    const home = runtime.env("HOME") orelse "/tmp";
    const old_path = try std.fmt.allocPrint(allocator, "{s}/.suji/cef/macos-arm64/Release/Chromium Embedded Framework.framework/Chromium Embedded Framework", .{home});
    defer allocator.free(old_path);

    runCmd(allocator, &.{
        "install_name_tool", "-change",
        old_path,
        "@executable_path/../Frameworks/Chromium Embedded Framework.framework/Chromium Embedded Framework",
        exe,
    }) catch |err| {
        std.debug.print("[suji] install_name_tool warning: {}\n", .{err});
    };
}

fn codesignBundle(allocator: std.mem.Allocator, app_name: []const u8, name: []const u8) !void {
    std.debug.print("[suji] code signing...\n", .{});

    // 1. CEF 프레임워크
    const fw = try std.fmt.allocPrint(allocator, "{s}/Contents/Frameworks/Chromium Embedded Framework.framework", .{app_name});
    defer allocator.free(fw);
    try codesign(allocator, fw);

    // 2. Helper 앱들
    const suffixes = [_][]const u8{ "", " (GPU)", " (Renderer)", " (Plugin)" };
    for (suffixes) |suffix| {
        const helper = try std.fmt.allocPrint(allocator, "{s}/Contents/Frameworks/{s} Helper{s}.app", .{ app_name, name, suffix });
        defer allocator.free(helper);
        try codesign(allocator, helper);
    }

    // 3. 메인 바이너리
    const exe = try std.fmt.allocPrint(allocator, "{s}/Contents/MacOS/{s}", .{ app_name, name });
    defer allocator.free(exe);
    try codesign(allocator, exe);

    // 4. 전체 앱 번들
    try codesign(allocator, app_name);
}

fn codesign(allocator: std.mem.Allocator, path: []const u8) !void {
    // entitlements 파일은 suji 바이너리와 같은 디렉토리에 위치
    var exe_buf: [1024]u8 = undefined;
    const exe_len = std.process.executablePath(runtime.io, &exe_buf) catch {
        try runCmd(allocator, &.{ "codesign", "--force", "--sign", "-", path });
        return;
    };
    const exe_path = exe_buf[0..exe_len];
    const exe_dir = std.fs.path.dirname(std.fs.path.dirname(std.fs.path.dirname(exe_path) orelse "") orelse "") orelse "";
    const entitlements = try std.fmt.allocPrint(allocator, "{s}/macos-entitlements.plist", .{exe_dir});
    defer allocator.free(entitlements);

    runCmd(allocator, &.{ "codesign", "--force", "--sign", "-", "--entitlements", entitlements, path }) catch {
        // entitlements 없으면 entitlements 없이 서명
        try runCmd(allocator, &.{ "codesign", "--force", "--sign", "-", path });
    };
}

fn copyFile(allocator: std.mem.Allocator, src: []const u8, dst: []const u8) !void {
    defer allocator.free(dst);
    try runCmd(allocator, &.{ "cp", src, dst });
    try runCmd(allocator, &.{ "chmod", "+x", dst });
}

fn copyDir(allocator: std.mem.Allocator, src: []const u8, dst: []const u8) !void {
    defer allocator.free(dst);
    runCmd(allocator, &.{ "cp", "-R", src, dst }) catch |err| {
        std.debug.print("[suji] copy dir warning: {}\n", .{err});
    };
}

fn runCmd(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    _ = allocator;
    var child = try std.process.spawn(runtime.io, .{ .argv = argv });
    const result = try child.wait(runtime.io);
    switch (result) {
        .exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
}
