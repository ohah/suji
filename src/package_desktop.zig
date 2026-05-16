//! Linux/Windows 데스크톱 패키징 (zero-native tooling/package.zig 패리티).
//!
//! macOS 는 bundle_macos.zig(.app/.dmg)가 담당. 이쪽은 CEF self-contained
//! 바이너리를 OS 표준 레이아웃으로 배치 후 아카이브:
//! - Linux : <name>-<ver>-linux-<arch>/{bin/<name>, resources/frontend,
//!           <name>.desktop} → tar.gz
//! - Windows: <name>-<ver>-windows-<arch>/{bin/<name>.exe,
//!           resources/frontend} → zip. 선택적 signtool 서명 훅.
//!
//! release.yml 이 OS 별 네이티브 러너에서 호출(suji build 가 host os 분기).

const std = @import("std");
const runtime = @import("runtime");
const builtin = @import("builtin");

const Dir = std.Io.Dir;

fn archName() []const u8 {
    return switch (builtin.cpu.arch) {
        .aarch64 => "arm64",
        .x86_64 => "x64",
        else => @tagName(builtin.cpu.arch),
    };
}

fn runCmd(argv: []const []const u8) !void {
    var child = try std.process.spawn(runtime.io, .{ .argv = argv });
    switch (try child.wait(runtime.io)) {
        .exited => |c| if (c != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
}

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
    const res_dir = try std.fmt.allocPrint(allocator, "{s}/resources/frontend", .{stage});
    defer allocator.free(res_dir);
    runCmd(&.{ "rm", "-rf", stage }) catch {};
    Dir.cwd().createDirPath(runtime.io, bin_dir) catch {};
    Dir.cwd().createDirPath(runtime.io, res_dir) catch {};

    const bin_dst = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ bin_dir, exe_name });
    defer allocator.free(bin_dst);
    try runCmd(&.{ "cp", exe_path, bin_dst });
    try runCmd(&.{ "chmod", "+x", bin_dst });
    // frontend dist 가 없을 수도(빌드 실패) — best-effort.
    runCmd(&.{ "cp", "-R", frontend_dist, res_dir }) catch {};
}

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

    const desktop = try std.fmt.allocPrint(allocator,
        \\[Desktop Entry]
        \\Type=Application
        \\Name={s}
        \\Exec=bin/{s}
        \\Icon=app-icon
        \\Categories=Utility;
        \\
    , .{ name, name });
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

/// Windows: stage(bin/<name>.exe) + 선택적 signtool 서명 + zip.
/// sign_tool_args 비어있으면 서명 생략(zero-native 와 동일 — 호스트 위임).
/// 반환 아카이브 경로(caller free).
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
    try stageCommon(allocator, stage, exe_name, exe_path, frontend_dist);

    // 선택적 Authenticode 서명 (signtool, PFX cert + password). CI secret 주입.
    if (sign_cert) |cert| {
        const exe_in_stage = try std.fmt.allocPrint(allocator, "{s}/bin/{s}", .{ stage, exe_name });
        defer allocator.free(exe_in_stage);
        std.debug.print("[suji] signing windows exe (signtool)...\n", .{});
        try runCmd(&.{
            "signtool",                        "sign",
            "/fd",                             "SHA256",
            "/f",                              cert,
            "/p",                              sign_password orelse "",
            "/tr",                             "http://timestamp.digicert.com",
            "/td",                             "SHA256",
            exe_in_stage,
        });
    }

    const archive = try std.fmt.allocPrint(allocator, "{s}.zip", .{stage});
    errdefer allocator.free(archive);
    std.debug.print("[suji] packaging windows: {s}\n", .{archive});
    try runCmd(&.{ "zip", "-r", archive, stage });
    std.debug.print("[suji] packaged: {s}\n", .{archive});
    return archive;
}
