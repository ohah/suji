//! packaged 환경(macOS `.app` / Windows `.suji-packaged` sentinel)에서 plugin·
//! backend dylib 경로를 계산하는 공용 헬퍼. plugin_loader + backend_lifecycle 가
//! 동일한 layout(`<exe_dir>/{plugins,backends}/<name>/<dylib>`) 을 거친다.

const std = @import("std");
const builtin = @import("builtin");
const runtime = @import("runtime");

pub fn exeDir(allocator: std.mem.Allocator) ?[]const u8 {
    var exe_buf: [1024]u8 = undefined;
    const ep_len = std.process.executablePath(runtime.io, &exe_buf) catch return null;
    const ep = exe_buf[0..ep_len];
    const dir = std.fs.path.dirname(ep) orelse return null;

    if (comptime builtin.os.tag == .macos) {
        // <exe_dir>=<app>.app/Contents/MacOS → Resources 가 sibling.
        const contents_dir = std.fs.path.dirname(dir) orelse return null;
        const resources_dir = std.fmt.allocPrint(allocator, "{s}/Resources", .{contents_dir}) catch return null;
        const probe = std.fmt.allocPrint(allocator, "{s}/.suji-packaged", .{resources_dir}) catch {
            allocator.free(resources_dir);
            return null;
        };
        defer allocator.free(probe);
        std.Io.Dir.cwd().access(runtime.io, probe, .{}) catch {
            allocator.free(resources_dir);
            return null;
        };
        return resources_dir;
    }

    const probe = std.fmt.allocPrint(allocator, "{s}/.suji-packaged", .{dir}) catch return null;
    defer allocator.free(probe);
    std.Io.Dir.cwd().access(runtime.io, probe, .{}) catch return null;
    return allocator.dupe(u8, dir) catch null;
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
