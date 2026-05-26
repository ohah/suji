//! Linux/Windows 데스크톱 패키징 (zero-native tooling/package.zig 패리티).
//!
//! macOS 는 bundle_macos.zig(.app/.dmg)가 담당. 이쪽은 CEF self-contained
//! 바이너리를 OS 표준 레이아웃으로 배치 후 아카이브:
//! - Linux : <name>-<ver>-linux-<arch>/{bin/<name>, resources/frontend,
//!           <name>.desktop} → tar.gz. 선택적 Debian .deb(`--deb`)와
//!           AppImage(`--appimage`)도 생성.
//! - Windows: <name>-<ver>-windows-<arch>/{bin/<name>.exe,
//!           resources/frontend} → zip. 선택적 signtool 서명 훅.
//!
//! release.yml 이 OS 별 네이티브 러너에서 호출(suji build 가 host os 분기).

const std = @import("std");
const runtime = @import("runtime");
const builtin = @import("builtin");
const proc = @import("core/proc.zig");

const Dir = std.Io.Dir;

fn archName() []const u8 {
    return switch (builtin.cpu.arch) {
        .aarch64 => "arm64",
        .x86_64 => "x64",
        else => @tagName(builtin.cpu.arch),
    };
}

fn debArchName() []const u8 {
    return switch (builtin.cpu.arch) {
        .x86_64 => "amd64",
        .aarch64 => "arm64",
        .arm => "armhf",
        else => @tagName(builtin.cpu.arch),
    };
}

const runCmd = proc.run;

fn writeFile(path: []const u8, content: []const u8) !void {
    const io = runtime.io;
    var f = try Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    var buf: [4096]u8 = undefined;
    var w = f.writer(io, &buf);
    try w.interface.writeAll(content);
    try w.interface.flush();
}

/// 공통: stage 디렉토리에 bin/<exe> + resources/frontend 배치.
/// 반환: stage 디렉토리 경로 (caller free).
fn stageCommon(
    allocator: std.mem.Allocator,
    stage: []const u8,
    exe_name: []const u8,
    exe_path: []const u8,
    frontend_dist: []const u8,
) !void {
    const bin_dir = try std.fmt.allocPrint(allocator, "{s}/bin", .{stage});
    defer allocator.free(bin_dir);
    // resources/ 만 만들고 frontend 는 cp 가 생성 — 미리 만들면 cp -R 가
    // dist 를 그 안에 중첩(resources/frontend/<dist>/...)시킴.
    const res_parent = try std.fmt.allocPrint(allocator, "{s}/resources", .{stage});
    defer allocator.free(res_parent);
    const res_dir = try std.fmt.allocPrint(allocator, "{s}/frontend", .{res_parent});
    defer allocator.free(res_dir);
    runCmd(&.{ "rm", "-rf", stage }) catch {};
    Dir.cwd().createDirPath(runtime.io, bin_dir) catch {};
    Dir.cwd().createDirPath(runtime.io, res_parent) catch {};

    const bin_dst = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ bin_dir, exe_name });
    defer allocator.free(bin_dst);
    try runCmd(&.{ "cp", exe_path, bin_dst });
    try runCmd(&.{ "chmod", "+x", bin_dst });
    // frontend dist 가 없을 수도(빌드 실패) — best-effort. dst 미존재라
    // cp -R 가 dist 내용을 resources/frontend 로 그대로 복사.
    runCmd(&.{ "cp", "-R", frontend_dist, res_dir }) catch {};
}

fn isDebPackageChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= '0' and c <= '9') or
        c == '+' or c == '-' or c == '.';
}

fn isAsciiAlnum(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9');
}

fn asciiLower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + ('a' - 'A') else c;
}

/// Debian package name: lowercase [a-z0-9+-.], starts with alnum.
/// Invalid runs collapse to one `-`; hostile/empty names get a stable prefix.
pub fn sanitizeDebPackageName(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    var last_dash = false;
    for (name) |raw| {
        const c = asciiLower(raw);
        if (isDebPackageChar(c)) {
            try out.append(allocator, c);
            last_dash = c == '-';
        } else if (!last_dash) {
            try out.append(allocator, '-');
            last_dash = true;
        }
    }

    while (out.items.len > 0 and !isAsciiAlnum(out.items[0])) {
        _ = out.orderedRemove(0);
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == '-') {
        _ = out.pop();
    }
    if (out.items.len < 2) {
        out.clearRetainingCapacity();
        try out.appendSlice(allocator, "suji-app");
    }

    return out.toOwnedSlice(allocator);
}

fn controlLineSafe(allocator: std.mem.Allocator, value: []const u8, fallback: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    var last_space = false;
    for (value) |c| {
        const next: ?u8 = if (c == '\r' or c == '\n' or c == '\t')
            ' '
        else if (c < 32 or c == 127)
            null
        else
            c;
        if (next) |n| {
            if (n == ' ') {
                if (!last_space and out.items.len > 0) try out.append(allocator, n);
                last_space = true;
            } else {
                try out.append(allocator, n);
                last_space = false;
            }
        }
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') _ = out.pop();
    if (out.items.len == 0) try out.appendSlice(allocator, fallback);
    return out.toOwnedSlice(allocator);
}

fn shellSingleQuote(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    try out.append(allocator, '\'');
    for (value) |c| {
        if (c == '\'') {
            try out.appendSlice(allocator, "'\\''");
        } else {
            try out.append(allocator, c);
        }
    }
    try out.append(allocator, '\'');
    return out.toOwnedSlice(allocator);
}

pub fn renderDesktopEntry(
    allocator: std.mem.Allocator,
    display_name: []const u8,
    exec: []const u8,
    icon: []const u8,
) ![]u8 {
    const safe_name = try controlLineSafe(allocator, display_name, "Suji App");
    defer allocator.free(safe_name);
    const safe_exec = try controlLineSafe(allocator, exec, "suji");
    defer allocator.free(safe_exec);
    const safe_icon = try controlLineSafe(allocator, icon, "app-icon");
    defer allocator.free(safe_icon);

    return std.fmt.allocPrint(allocator,
        \\[Desktop Entry]
        \\Type=Application
        \\Name={s}
        \\Exec={s}
        \\Icon={s}
        \\Categories=Utility;
        \\
    , .{ safe_name, safe_exec, safe_icon });
}

pub fn renderDebControl(
    allocator: std.mem.Allocator,
    package_name: []const u8,
    version: []const u8,
    arch: []const u8,
    app_name: []const u8,
) ![]u8 {
    const safe_version = try controlLineSafe(allocator, version, "0.1.0");
    defer allocator.free(safe_version);
    const safe_arch = try controlLineSafe(allocator, arch, "amd64");
    defer allocator.free(safe_arch);
    const safe_app_name = try controlLineSafe(allocator, app_name, "Suji App");
    defer allocator.free(safe_app_name);

    return std.fmt.allocPrint(allocator,
        \\Package: {s}
        \\Version: {s}
        \\Section: utils
        \\Priority: optional
        \\Architecture: {s}
        \\Maintainer: Suji Packager <noreply@suji.dev>
        \\Description: {s} desktop application
        \\
    , .{ package_name, safe_version, safe_arch, safe_app_name });
}

pub fn renderAppRun(allocator: std.mem.Allocator, exe_name: []const u8) ![]u8 {
    const quoted_exe = try shellSingleQuote(allocator, exe_name);
    defer allocator.free(quoted_exe);

    return std.fmt.allocPrint(allocator,
        \\#!/bin/sh
        \\set -eu
        \\APPDIR="${{APPDIR:-$(dirname "$(readlink -f "$0")")}}"
        \\APP_EXEC={s}
        \\exec "$APPDIR/usr/bin/$APP_EXEC" run "$@"
        \\
    , .{quoted_exe});
}

const default_app_icon_svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128">
    \\  <rect width="128" height="128" rx="24" fill="#1f7a5c"/>
    \\  <path d="M34 72c10 18 50 18 60 0" fill="none" stroke="#ffffff" stroke-width="12" stroke-linecap="round"/>
    \\  <circle cx="45" cy="50" r="8" fill="#ffffff"/>
    \\  <circle cx="83" cy="50" r="8" fill="#ffffff"/>
    \\</svg>
    \\
;

/// Linux: stage + .desktop + tar.gz. 반환 아카이브 경로(caller free).
pub fn packageLinux(
    allocator: std.mem.Allocator,
    name: []const u8,
    version: []const u8,
    exe_path: []const u8,
    frontend_dist: []const u8,
) ![]const u8 {
    const stage = try std.fmt.allocPrint(allocator, "{s}-{s}-linux-{s}", .{ name, version, archName() });
    defer allocator.free(stage);
    try stageCommon(allocator, stage, name, exe_path, frontend_dist);

    const exec = try std.fmt.allocPrint(allocator, "bin/{s}", .{name});
    defer allocator.free(exec);
    const desktop = try renderDesktopEntry(allocator, name, exec, "app-icon");
    defer allocator.free(desktop);
    const desktop_path = try std.fmt.allocPrint(allocator, "{s}/{s}.desktop", .{ stage, name });
    defer allocator.free(desktop_path);
    try writeFile(desktop_path, desktop);

    const archive = try std.fmt.allocPrint(allocator, "{s}.tar.gz", .{stage});
    errdefer allocator.free(archive);
    std.debug.print("[suji] packaging linux: {s}\n", .{archive});
    try runCmd(&.{ "tar", "czf", archive, stage });
    std.debug.print("[suji] packaged: {s}\n", .{archive});
    return archive;
}

pub fn stageLinuxAppDirAt(
    allocator: std.mem.Allocator,
    app_dir: []const u8,
    name: []const u8,
    exe_path: []const u8,
    frontend_dist: []const u8,
) !void {
    const package_name = try sanitizeDebPackageName(allocator, name);
    defer allocator.free(package_name);

    runCmd(&.{ "rm", "-rf", app_dir }) catch {};
    const bin_dir = try std.fmt.allocPrint(allocator, "{s}/usr/bin", .{app_dir});
    defer allocator.free(bin_dir);
    const resources_dir = try std.fmt.allocPrint(allocator, "{s}/usr/resources", .{app_dir});
    defer allocator.free(resources_dir);
    try Dir.cwd().createDirPath(runtime.io, bin_dir);
    try Dir.cwd().createDirPath(runtime.io, resources_dir);

    const bin_dst = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ bin_dir, name });
    defer allocator.free(bin_dst);
    try runCmd(&.{ "cp", exe_path, bin_dst });
    try runCmd(&.{ "chmod", "+x", bin_dst });

    const frontend_dst = try std.fmt.allocPrint(allocator, "{s}/frontend", .{resources_dir});
    defer allocator.free(frontend_dst);
    runCmd(&.{ "cp", "-R", frontend_dist, frontend_dst }) catch {};

    const app_run = try renderAppRun(allocator, name);
    defer allocator.free(app_run);
    const app_run_path = try std.fmt.allocPrint(allocator, "{s}/AppRun", .{app_dir});
    defer allocator.free(app_run_path);
    try writeFile(app_run_path, app_run);
    try runCmd(&.{ "chmod", "+x", app_run_path });

    const desktop = try renderDesktopEntry(allocator, name, "AppRun", "app-icon");
    defer allocator.free(desktop);
    const desktop_path = try std.fmt.allocPrint(allocator, "{s}/{s}.desktop", .{ app_dir, package_name });
    defer allocator.free(desktop_path);
    try writeFile(desktop_path, desktop);

    const icon_path = try std.fmt.allocPrint(allocator, "{s}/app-icon.svg", .{app_dir});
    defer allocator.free(icon_path);
    try writeFile(icon_path, default_app_icon_svg);
    const dir_icon_path = try std.fmt.allocPrint(allocator, "{s}/.DirIcon", .{app_dir});
    defer allocator.free(dir_icon_path);
    try writeFile(dir_icon_path, default_app_icon_svg);
}

/// Linux AppImage. Requires appimagetool via SUJI_APPIMAGETOOL or PATH.
pub fn packageLinuxAppImage(
    allocator: std.mem.Allocator,
    name: []const u8,
    version: []const u8,
    exe_path: []const u8,
    frontend_dist: []const u8,
) ![]const u8 {
    return packageLinuxAppImageAt(allocator, ".", name, version, exe_path, frontend_dist);
}

pub fn packageLinuxAppImageAt(
    allocator: std.mem.Allocator,
    output_dir: []const u8,
    name: []const u8,
    version: []const u8,
    exe_path: []const u8,
    frontend_dist: []const u8,
) ![]const u8 {
    const package_name = try sanitizeDebPackageName(allocator, name);
    defer allocator.free(package_name);
    const arch = archName();

    Dir.cwd().createDirPath(runtime.io, output_dir) catch {};
    const app_dir = try std.fmt.allocPrint(allocator, "{s}/{s}-{s}-linux-{s}.AppDir", .{ output_dir, package_name, version, arch });
    defer allocator.free(app_dir);
    try stageLinuxAppDirAt(allocator, app_dir, name, exe_path, frontend_dist);

    const archive = try std.fmt.allocPrint(allocator, "{s}/{s}-{s}-linux-{s}.AppImage", .{ output_dir, package_name, version, arch });
    errdefer allocator.free(archive);
    runCmd(&.{ "rm", "-f", archive }) catch {};
    const appimage_tool = runtime.env("SUJI_APPIMAGETOOL") orelse "appimagetool";
    std.debug.print("[suji] packaging linux appimage: {s}\n", .{archive});
    try runCmd(&.{ appimage_tool, app_dir, archive });
    try runCmd(&.{ "chmod", "+x", archive });
    std.debug.print("[suji] packaged: {s}\n", .{archive});
    return archive;
}

/// Linux Debian package. 반환 .deb 경로(caller free).
pub fn packageLinuxDeb(
    allocator: std.mem.Allocator,
    name: []const u8,
    version: []const u8,
    exe_path: []const u8,
    frontend_dist: []const u8,
) ![]const u8 {
    return packageLinuxDebAt(allocator, ".", name, version, exe_path, frontend_dist);
}

/// 테스트/호출자가 output_dir를 고정할 수 있는 .deb 생성 경로.
pub fn packageLinuxDebAt(
    allocator: std.mem.Allocator,
    output_dir: []const u8,
    name: []const u8,
    version: []const u8,
    exe_path: []const u8,
    frontend_dist: []const u8,
) ![]const u8 {
    const package_name = try sanitizeDebPackageName(allocator, name);
    defer allocator.free(package_name);
    const deb_arch = debArchName();

    Dir.cwd().createDirPath(runtime.io, output_dir) catch {};
    const work = try std.fmt.allocPrint(allocator, "{s}/.{s}-{s}-{s}.deb.work", .{ output_dir, package_name, version, deb_arch });
    defer allocator.free(work);
    runCmd(&.{ "rm", "-rf", work }) catch {};
    defer runCmd(&.{ "rm", "-rf", work }) catch {};

    const debian_dir = try std.fmt.allocPrint(allocator, "{s}/control", .{work});
    defer allocator.free(debian_dir);
    const data_dir = try std.fmt.allocPrint(allocator, "{s}/data", .{work});
    defer allocator.free(data_dir);
    const app_root = try std.fmt.allocPrint(allocator, "{s}/opt/{s}", .{ data_dir, package_name });
    defer allocator.free(app_root);
    const app_bin = try std.fmt.allocPrint(allocator, "{s}/bin", .{app_root});
    defer allocator.free(app_bin);
    const app_resources = try std.fmt.allocPrint(allocator, "{s}/resources", .{app_root});
    defer allocator.free(app_resources);
    const desktop_dir = try std.fmt.allocPrint(allocator, "{s}/usr/share/applications", .{data_dir});
    defer allocator.free(desktop_dir);

    try Dir.cwd().createDirPath(runtime.io, debian_dir);
    try Dir.cwd().createDirPath(runtime.io, app_bin);
    try Dir.cwd().createDirPath(runtime.io, app_resources);
    try Dir.cwd().createDirPath(runtime.io, desktop_dir);

    const bin_dst = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ app_bin, name });
    defer allocator.free(bin_dst);
    try runCmd(&.{ "cp", exe_path, bin_dst });
    try runCmd(&.{ "chmod", "+x", bin_dst });

    const frontend_dst = try std.fmt.allocPrint(allocator, "{s}/frontend", .{app_resources});
    defer allocator.free(frontend_dst);
    runCmd(&.{ "cp", "-R", frontend_dist, frontend_dst }) catch {};

    const control = try renderDebControl(allocator, package_name, version, deb_arch, name);
    defer allocator.free(control);
    const control_path = try std.fmt.allocPrint(allocator, "{s}/control", .{debian_dir});
    defer allocator.free(control_path);
    try writeFile(control_path, control);

    const desktop_exec = try std.fmt.allocPrint(allocator, "/opt/{s}/bin/{s}", .{ package_name, name });
    defer allocator.free(desktop_exec);
    const desktop = try renderDesktopEntry(allocator, name, desktop_exec, package_name);
    defer allocator.free(desktop);
    const desktop_path = try std.fmt.allocPrint(allocator, "{s}/{s}.desktop", .{ desktop_dir, package_name });
    defer allocator.free(desktop_path);
    try writeFile(desktop_path, desktop);

    const debian_binary = try std.fmt.allocPrint(allocator, "{s}/debian-binary", .{work});
    defer allocator.free(debian_binary);
    try writeFile(debian_binary, "2.0\n");

    const control_tar = try std.fmt.allocPrint(allocator, "{s}/control.tar.gz", .{work});
    defer allocator.free(control_tar);
    const data_tar = try std.fmt.allocPrint(allocator, "{s}/data.tar.gz", .{work});
    defer allocator.free(data_tar);
    try runCmd(&.{ "tar", "czf", control_tar, "-C", debian_dir, "." });
    try runCmd(&.{ "tar", "czf", data_tar, "-C", data_dir, "." });

    const archive = try std.fmt.allocPrint(allocator, "{s}/{s}_{s}_{s}.deb", .{ output_dir, package_name, version, deb_arch });
    errdefer allocator.free(archive);
    runCmd(&.{ "rm", "-f", archive }) catch {};
    std.debug.print("[suji] packaging linux deb: {s}\n", .{archive});
    try runCmd(&.{ "ar", "qc", archive, debian_binary, control_tar, data_tar });
    std.debug.print("[suji] packaged: {s}\n", .{archive});
    return archive;
}

/// Windows: stage(bin/<name>.exe) + 선택적 signtool 서명 + zip.
/// sign_tool_args 비어있으면 서명 생략(zero-native 와 동일 — 호스트 위임).
/// 반환 아카이브 경로(caller free).
/// Windows 패키지 — flat layout (모든 DLL + .pak/.dat 이 .exe 옆에 있어야 CEF
/// 로더가 찾는다. macOS .app 같이 nested 구조 못 씀). exe_path 의 부모 디렉토리
/// (보통 zig-out/bin) 가 이미 build.zig 의 copy step 으로 CEF/Node runtime
/// 전부 stage 돼 있어서, 그 디렉토리를 통째로 복사.
///
/// 산출: <name>-<ver>-windows-<arch>/
///   ├── <name>.exe (renamed from suji.exe)
///   ├── libcef.dll, libnode.dll, etc. (~30 DLL)
///   ├── locales/ (CEF i18n)
///   ├── resources/frontend/ (dist 빌드)
///   └── *.pak, *.dat, *.bin (CEF data)
///
/// Linux 와 달리 Windows 는 bash/cp/zip 의존 제거 — PowerShell Compress-Archive
/// 가 OS native. signtool 도 정식 Windows 도구로 PATH 에 있어야.
pub fn packageWindows(
    allocator: std.mem.Allocator,
    name: []const u8,
    version: []const u8,
    exe_path: []const u8,
    frontend_dist: []const u8,
    sign_cert: ?[]const u8,
    sign_password: ?[]const u8,
) ![]const u8 {
    const stage = try std.fmt.allocPrint(allocator, "{s}-{s}-windows-{s}", .{ name, version, archName() });
    defer allocator.free(stage);
    const exe_name = try std.fmt.allocPrint(allocator, "{s}.exe", .{name});
    defer allocator.free(exe_name);

    // 1) 기존 stage 정리.
    Dir.cwd().deleteTree(runtime.io, stage) catch {};
    try Dir.cwd().createDirPath(runtime.io, stage);

    // 2) exe_path 의 부모 디렉토리 = build artifacts dir (zig-out/bin). 그 안의
    // 모든 파일을 stage 로 복사 — CEF DLL/Resources, Node DLL 전부 포함.
    const exe_dir = std.fs.path.dirname(exe_path) orelse {
        std.debug.print("[suji] cannot resolve exe directory\n", .{});
        return error.InvalidExePath;
    };
    try copyDirContents(allocator, exe_dir, stage);

    // 3) suji.exe → <name>.exe rename (config.app.name 사용).
    if (!std.mem.eql(u8, exe_name, "suji.exe")) {
        const suji_in_stage = try std.fmt.allocPrint(allocator, "{s}/suji.exe", .{stage});
        defer allocator.free(suji_in_stage);
        const renamed = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ stage, exe_name });
        defer allocator.free(renamed);
        Dir.cwd().rename(suji_in_stage, Dir.cwd(), renamed, runtime.io) catch |err| {
            std.debug.print("[suji] rename suji.exe → {s} failed: {s}\n", .{ exe_name, @errorName(err) });
        };
    }

    // 4) frontend dist → resources/frontend/.
    const res_dir = try std.fmt.allocPrint(allocator, "{s}/resources/frontend", .{stage});
    defer allocator.free(res_dir);
    try Dir.cwd().createDirPath(runtime.io, res_dir);
    copyDirContents(allocator, frontend_dist, res_dir) catch |err| {
        // best-effort — frontend build 실패해도 진행 (사용자가 별도 fix).
        std.debug.print("[suji] frontend dist copy failed: {s}\n", .{@errorName(err)});
    };

    // 5) 선택적 Authenticode 서명 (signtool.exe — Windows SDK).
    if (sign_cert) |cert| {
        const exe_in_stage = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ stage, exe_name });
        defer allocator.free(exe_in_stage);
        std.debug.print("[suji] signing windows exe (signtool)...\n", .{});
        try runCmd(&.{
            "signtool",   "sign",
            "/fd",        "SHA256",
            "/f",         cert,
            "/p",         sign_password orelse "",
            "/tr",        "http://timestamp.digicert.com",
            "/td",        "SHA256",
            exe_in_stage,
        });
    }

    // 6) PowerShell Compress-Archive 로 .zip 생성. zip(.exe) 의존 제거.
    const archive = try std.fmt.allocPrint(allocator, "{s}.zip", .{stage});
    errdefer allocator.free(archive);
    std.debug.print("[suji] packaging windows: {s}\n", .{archive});
    Dir.cwd().deleteFile(runtime.io, archive) catch {};
    if (builtin.os.tag == .windows) {
        const ps_cmd = try std.fmt.allocPrint(
            allocator,
            "Compress-Archive -Path '{s}' -DestinationPath '{s}' -Force",
            .{ stage, archive },
        );
        defer allocator.free(ps_cmd);
        try runCmd(&.{ "powershell", "-NoProfile", "-Command", ps_cmd });
    } else {
        // 비-Windows host 에서 cross-package (예: WSL/Linux CI 가 Windows 산출물 만듦).
        runCmd(&.{ "zip", "-r", archive, stage }) catch {
            std.debug.print("[suji] zip command not found; install zip or run on Windows host\n", .{});
            return error.ZipFailed;
        };
    }
    std.debug.print("[suji] packaged: {s}\n", .{archive});
    return archive;
}

/// 디렉토리 contents 를 다른 디렉토리로 재귀 복사 (cross-platform, no shell).
/// dst 는 호출 전 생성돼 있어야.
fn copyDirContents(allocator: std.mem.Allocator, src: []const u8, dst: []const u8) !void {
    const io = runtime.io;
    var src_dir = Dir.cwd().openDir(io, src, .{ .iterate = true }) catch |err| {
        std.debug.print("[suji] open dir '{s}' failed: {s}\n", .{ src, @errorName(err) });
        return err;
    };
    defer src_dir.close(io);
    var it = src_dir.iterate();
    while (try it.next(io)) |entry| {
        const src_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ src, entry.name });
        defer allocator.free(src_path);
        const dst_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dst, entry.name });
        defer allocator.free(dst_path);
        switch (entry.kind) {
            .directory => {
                try Dir.cwd().createDirPath(io, dst_path);
                try copyDirContents(allocator, src_path, dst_path);
            },
            .file, .sym_link => {
                Dir.cwd().copyFile(src_path, Dir.cwd(), dst_path, io, .{}) catch |err| {
                    std.debug.print("[suji] copy '{s}' → '{s}' failed: {s}\n", .{ src_path, dst_path, @errorName(err) });
                };
            },
            else => {},
        }
    }
}
