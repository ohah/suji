//! packaged 환경(macOS `.app` / Windows `.suji-packaged` sentinel)에서 plugin·
//! backend dylib 경로를 계산하는 공용 헬퍼. plugin_loader + backend_lifecycle 가
//! 동일한 layout(`<exe_dir>/{plugins,backends}/<name>/<dylib>`) 을 거친다.

const std = @import("std");
const builtin = @import("builtin");
const runtime = @import("runtime");

/// packaged(.app/sentinel) 면 실제 실행파일이 있는 디렉토리(`@executable_path`)를,
/// 아니면(dev) null 을 반환. is-packaged 판정(sentinel 위치는 macOS=Contents/Resources,
/// else=exe dir)을 단일 출처로 둔다 — exeDir/pythonHome 가 반환 디렉토리만 다를 뿐
/// 같은 판정을 공유. caller free.
fn packagedRealExeDir(allocator: std.mem.Allocator) ?[]const u8 {
    var exe_buf: [1024]u8 = undefined;
    const ep_len = std.process.executablePath(runtime.io, &exe_buf) catch return null;
    const dir = std.fs.path.dirname(exe_buf[0..ep_len]) orelse return null;

    const sentinel = if (comptime builtin.os.tag == .macos) blk: {
        // <exe_dir>=<app>.app/Contents/MacOS → sentinel 은 sibling Resources 에.
        const contents = std.fs.path.dirname(dir) orelse return null;
        break :blk std.fmt.allocPrint(allocator, "{s}/Resources/.suji-packaged", .{contents}) catch return null;
    } else std.fmt.allocPrint(allocator, "{s}/.suji-packaged", .{dir}) catch return null;
    defer allocator.free(sentinel);
    std.Io.Dir.cwd().access(runtime.io, sentinel, .{}) catch return null;

    return allocator.dupe(u8, dir) catch null;
}

/// packaged 면 backend/plugin dylib 이 사는 디렉토리(macOS=Contents/Resources,
/// else=exe dir), dev 면 null. caller free.
pub fn exeDir(allocator: std.mem.Allocator) ?[]const u8 {
    const dir = packagedRealExeDir(allocator) orelse return null;
    defer allocator.free(dir);
    if (comptime builtin.os.tag == .macos) {
        const contents = std.fs.path.dirname(dir) orelse return null;
        return std.fmt.allocPrint(allocator, "{s}/Resources", .{contents}) catch null;
    }
    return allocator.dupe(u8, dir) catch null;
}

/// packaged 면 번들 CPython home(`<real-exe-dir>/python`)을 반환.
/// addInstallPythonRuntimeStep(Linux/Windows) + bundle_macos(macOS) 가 stdlib 을
/// 실 실행파일 옆 `python/lib/pythonX.Y` 로 둔다. libpython 은 `@executable_path`
/// 로, stdlib 은 PYTHONHOME 로 같은 디렉토리에서 로드되므로 exeDir() 와 달리 macOS
/// 도 Contents/MacOS(실 바이너리 위치)를 기준으로 한다. dev(sentinel 없음)면 null →
/// python.zig 가 python_config 의 staging 경로(run-python-e2e 실증)를 쓴다.
pub fn pythonHome(allocator: std.mem.Allocator) ?[]const u8 {
    const dir = packagedRealExeDir(allocator) orelse return null;
    defer allocator.free(dir);
    return std.fmt.allocPrint(allocator, "{s}/python", .{dir}) catch null;
}

/// packaged 환경에서 backend dylib 의 alleged 경로 — packageWindows 가 배치한
/// `<exe_dir>/backends/<be_name>/<dylib basename>`. dylib basename 은 lang 별
/// known (Zig: backend.dll, Rust: rust_backend.dll, Go: backend.dll).
/// Node 면 entry directory 경로 반환 (caller 가 main.js 로 join).
pub fn backendDylibPath(
    allocator: std.mem.Allocator,
    exe_dir: []const u8,
    be_name: []const u8,
    lang: []const u8,
) !?[]const u8 {
    const basename: ?[]const u8 = if (std.mem.eql(u8, lang, "node"))
        null // Node: 디렉토리만 반환
    else if (std.mem.eql(u8, lang, "zig"))
        switch (builtin.os.tag) {
            .windows => "backend.dll",
            .linux => "libbackend.so",
            else => "libbackend.dylib",
        }
    else if (std.mem.eql(u8, lang, "rust"))
        switch (builtin.os.tag) {
            .windows => "rust_backend.dll",
            .linux => "librust_backend.so",
            else => "librust_backend.dylib",
        }
    else if (std.mem.eql(u8, lang, "go"))
        switch (builtin.os.tag) {
            .windows => "backend.dll",
            .linux => "libbackend.so",
            else => "libbackend.dylib",
        }
    else
        return null;

    if (basename) |b| {
        return try std.fmt.allocPrint(allocator, "{s}/backends/{s}/{s}", .{ exe_dir, be_name, b });
    }
    return try std.fmt.allocPrint(allocator, "{s}/backends/{s}", .{ exe_dir, be_name });
}
