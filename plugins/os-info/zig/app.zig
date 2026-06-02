const std = @import("std");
const builtin = @import("builtin");
const suji = @import("suji");

// os-info plugin — Electron `os` / Tauri `os` 패리티. 시스템 정보 조회.
//   os:info → { platform, arch, family, version, hostname, eol, nodeArch }
// 단일 라운드트립으로 전체를 반환하고, JS/Node 래퍼가 개별 접근자(platform()/arch()/…)로 노출.
pub const app = suji.app()
    .named("os")
    .handle("os:info", osInfo);

/// Electron os.platform() 동등 — Node 스타일 토큰 (darwin/linux/win32).
fn nodePlatform() []const u8 {
    return switch (builtin.os.tag) {
        .macos => "darwin",
        .linux => "linux",
        .windows => "win32",
        else => "unknown",
    };
}

/// Suji platform() 동등 — friendly 토큰 (macos/linux/windows).
fn sujiPlatform() []const u8 {
    return switch (builtin.os.tag) {
        .macos => "macos",
        .linux => "linux",
        .windows => "windows",
        else => "other",
    };
}

/// Node os.arch() 동등 (arm64/x64/...).
fn nodeArch() []const u8 {
    return switch (builtin.cpu.arch) {
        .aarch64, .aarch64_be => "arm64",
        .x86_64 => "x64",
        .x86 => "ia32",
        .arm, .armeb => "arm",
        else => @tagName(builtin.cpu.arch),
    };
}

/// 실제 EOL 바이트 (CR+LF / LF). JSON 출력 시 valueAlloc 가 이스케이프(SDK 패턴).
fn eol() []const u8 {
    return if (builtin.os.tag == .windows) "\r\n" else "\n";
}

fn osInfo(req: suji.Request) suji.Response {
    // POSIX: uname 으로 release(version)/nodename(hostname)/machine 획득.
    // Windows: uname 부재 → 정적 값만 (version/hostname 빈 문자열, 후속 보강).
    var version_buf: [256]u8 = undefined;
    var host_buf: [256]u8 = undefined;
    var version: []const u8 = "";
    var hostname: []const u8 = "";

    if (builtin.os.tag == .macos or builtin.os.tag == .linux) {
        const u = std.posix.uname();
        const rel = std.mem.sliceTo(&u.release, 0);
        const node = std.mem.sliceTo(&u.nodename, 0);
        version = std.fmt.bufPrint(&version_buf, "{s}", .{rel}) catch "";
        hostname = std.fmt.bufPrint(&host_buf, "{s}", .{node}) catch "";
    }

    // platform/arch/family/sujiPlatform 은 고정 안전 토큰(이스케이프 불요). version/hostname
    // (uname)·eol(제어문자)은 valueAlloc 로 JSON 이스케이프(http/log 플러그인 동일 패턴).
    const version_json = std.json.Stringify.valueAlloc(req.arena, std.json.Value{ .string = version }, .{}) catch return req.err("format error");
    const host_json = std.json.Stringify.valueAlloc(req.arena, std.json.Value{ .string = hostname }, .{}) catch return req.err("format error");
    const eol_json = std.json.Stringify.valueAlloc(req.arena, std.json.Value{ .string = eol() }, .{}) catch return req.err("format error");
    const json = std.fmt.allocPrint(
        req.arena,
        "{{\"platform\":\"{s}\",\"sujiPlatform\":\"{s}\",\"arch\":\"{s}\",\"family\":\"{s}\",\"version\":{s},\"hostname\":{s},\"eol\":{s}}}",
        .{ nodePlatform(), sujiPlatform(), nodeArch(), @tagName(builtin.os.tag), version_json, host_json, eol_json },
    ) catch return req.err("format error");
    return req.okRaw(json);
}

comptime {
    _ = suji.exportApp(app);
}
