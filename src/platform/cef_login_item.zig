//! app.getLoginItemSettings / setLoginItemSettings (Electron) — 로그인 시 앱 자동 실행.
//! macOS: ~/Library/LaunchAgents/<label>.plist (LaunchAgent RunAtLoad),
//! Linux: ~/.config/autostart/<label>.desktop (XDG autostart).
//! Windows: 후속(honest false — 레지스트리 Run 키 미구현, plugins/autostart 와 동일 경계).
//! plugins/autostart/zig 의 검증된 로직을 코어(runtime.io)로 포팅 — 네이티브는 bool 만,
//! Electron 필드(openAtLogin/wasOpenedAtLogin/…) JSON 조립은 dispatch(main.zig)가 담당.
//!
//! ⚠️ macOS 는 plist 작성/삭제만 — `launchctl load` 미호출이라 enable 은 다음 로그인부터
//! 발효(autostart 플러그인과 동일). label 은 config.app.name → sanitize, 기본 "suji-app".
const std = @import("std");
const builtin = @import("builtin");
const runtime = @import("runtime");

const is_macos = builtin.os.tag == .macos;
const is_linux = builtin.os.tag == .linux;
const supported = is_macos or is_linux;

/// label sanitize — path 분리자/traversal 차단 (autostart sanitizeLabel 동등).
fn sanitizeLabel(raw: []const u8) []const u8 {
    if (raw.len == 0 or raw.len > 128) return "suji-app";
    if (std.mem.indexOf(u8, raw, "..") != null) return "suji-app";
    for (raw) |c| if (c == '/' or c == '\\' or c == 0) return "suji-app";
    return raw;
}

/// autostart 항목 파일 경로 (스택 buf). 미지원 OS / HOME 부재면 null.
fn entryPath(buf: []u8, label: []const u8) ?[]const u8 {
    const home = runtime.env("HOME") orelse return null;
    if (is_macos)
        return std.fmt.bufPrint(buf, "{s}/Library/LaunchAgents/{s}.plist", .{ home, label }) catch null;
    if (is_linux) {
        if (runtime.env("XDG_CONFIG_HOME")) |cfg| if (cfg.len > 0)
            return std.fmt.bufPrint(buf, "{s}/autostart/{s}.desktop", .{ cfg, label }) catch null;
        return std.fmt.bufPrint(buf, "{s}/.config/autostart/{s}.desktop", .{ home, label }) catch null;
    }
    return null;
}

/// 항목 파일 내용 (plist / desktop). 스택 buf.
fn entryContent(buf: []u8, label: []const u8, exe: []const u8) ?[]const u8 {
    if (is_macos) return std.fmt.bufPrint(buf,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\  <key>Label</key><string>{s}</string>
        \\  <key>ProgramArguments</key><array><string>{s}</string></array>
        \\  <key>RunAtLoad</key><true/>
        \\</dict>
        \\</plist>
        \\
    , .{ label, exe }) catch null;
    if (is_linux) return std.fmt.bufPrint(buf,
        \\[Desktop Entry]
        \\Type=Application
        \\Name={s}
        \\Exec={s}
        \\X-GNOME-Autostart-enabled=true
        \\
    , .{ label, exe }) catch null;
    return null;
}

/// 로그인 자동 실행 켜짐 여부 (Electron `getLoginItemSettings().openAtLogin`). 항목 파일 존재 검사.
pub fn loginItemEnabled(app_name: []const u8) bool {
    if (!comptime supported) return false;
    const label = sanitizeLabel(app_name);
    var path_buf: [1024]u8 = undefined;
    const path = entryPath(&path_buf, label) orelse return false;
    std.Io.Dir.cwd().access(runtime.io, path, .{}) catch return false;
    return true;
}

/// 로그인 자동 실행 설정 (Electron `setLoginItemSettings({openAtLogin})`).
/// enable=true 면 항목 파일 작성, false 면 삭제(부재 시 멱등 no-op).
pub fn setLoginItem(app_name: []const u8, enable: bool) bool {
    if (!comptime supported) return false;
    const label = sanitizeLabel(app_name);
    var path_buf: [1024]u8 = undefined;
    const path = entryPath(&path_buf, label) orelse return false;
    if (!enable) {
        std.Io.Dir.cwd().deleteFile(runtime.io, path) catch {};
        return true;
    }
    var exe_buf: [4096]u8 = undefined;
    const exe = if (std.process.executablePath(runtime.io, &exe_buf)) |n| exe_buf[0..n] else |_| return false;
    var content_buf: [2048]u8 = undefined;
    const content = entryContent(&content_buf, label, exe) orelse return false;
    // 디렉토리 보장 (LaunchAgents / autostart 가 없을 수 있음).
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |sep|
        std.Io.Dir.cwd().createDirPath(runtime.io, path[0..sep]) catch {};
    var file = std.Io.Dir.cwd().createFile(runtime.io, path, .{}) catch return false;
    defer file.close(runtime.io);
    var fw_buf: [1024]u8 = undefined;
    var fw = file.writer(runtime.io, &fw_buf);
    fw.interface.writeAll(content) catch return false;
    fw.interface.flush() catch return false;
    return true;
}
