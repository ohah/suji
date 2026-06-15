//! app.getLoginItemSettings / setLoginItemSettings (Electron) — 로그인 시 앱 자동 실행.
//! macOS: ~/Library/LaunchAgents/<label>.plist (LaunchAgent RunAtLoad),
//! Linux: ~/.config/autostart/<label>.desktop (XDG autostart).
//! Windows: HKCU\Software\Microsoft\Windows\CurrentVersion\Run REG_SZ 값(name=label,
//!   data=exe 경로). enable=set / disable=delete(멱등) / enabled=query. 다음 로그온부터 발효.
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
const is_windows = builtin.os.tag == .windows;
const supported = is_macos or is_linux or is_windows;

// Windows: HKCU\…\Run REG_SZ 값. cef_native_theme.zig 와 동일 advapi32 패턴.
const win_login = if (is_windows) struct {
    const HKEY_CURRENT_USER: usize = 0x80000001;
    const KEY_SET_VALUE: u32 = 0x0002;
    const REG_SZ: u32 = 1;
    const RRF_RT_REG_SZ: u32 = 0x00000002;
    const ERROR_FILE_NOT_FOUND: i32 = 2;
    const RUN_KEY = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\CurrentVersion\\Run");

    extern "advapi32" fn RegOpenKeyExW(hkey: usize, lpSubKey: ?[*:0]const u16, ulOptions: u32, samDesired: u32, phkResult: *usize) callconv(.winapi) i32;
    extern "advapi32" fn RegSetValueExW(hkey: usize, lpValueName: ?[*:0]const u16, Reserved: u32, dwType: u32, lpData: *const anyopaque, cbData: u32) callconv(.winapi) i32;
    extern "advapi32" fn RegDeleteValueW(hkey: usize, lpValueName: ?[*:0]const u16) callconv(.winapi) i32;
    extern "advapi32" fn RegGetValueW(hkey: usize, lpSubKey: ?[*:0]const u16, lpValue: ?[*:0]const u16, dwFlags: u32, pdwType: ?*u32, pvData: ?*anyopaque, pcbData: ?*u32) callconv(.winapi) i32;
    extern "advapi32" fn RegCloseKey(hkey: usize) callconv(.winapi) i32;

    /// utf8 → utf16le NUL-종단(buf). 과길이/실패 시 null.
    fn toW(buf: []u16, s: []const u8) ?[:0]const u16 {
        const n = std.unicode.utf8ToUtf16Le(buf, s) catch return null;
        if (n >= buf.len) return null;
        buf[n] = 0;
        return buf[0..n :0];
    }

    /// Run 값 존재 여부(데이터 불요 — RRF_RT_REG_SZ 로 타입만 맞춰 query).
    fn enabled(label: []const u8) bool {
        var name_buf: [256]u16 = undefined;
        const name = toW(&name_buf, label) orelse return false;
        return RegGetValueW(HKEY_CURRENT_USER, RUN_KEY.ptr, name.ptr, RRF_RT_REG_SZ, null, null, null) == 0;
    }

    /// enable=set REG_SZ(data=exe), disable=delete(부재 시 멱등 성공).
    fn set(label: []const u8, exe: []const u8, enable: bool) bool {
        var hkey: usize = 0;
        if (RegOpenKeyExW(HKEY_CURRENT_USER, RUN_KEY.ptr, 0, KEY_SET_VALUE, &hkey) != 0) return false;
        defer _ = RegCloseKey(hkey);
        var name_buf: [256]u16 = undefined;
        const name = toW(&name_buf, label) orelse return false;
        if (!enable) {
            const rc = RegDeleteValueW(hkey, name.ptr);
            return rc == 0 or rc == ERROR_FILE_NOT_FOUND;
        }
        var data_buf: [2048]u16 = undefined;
        const data = toW(&data_buf, exe) orelse return false;
        const cb: u32 = @intCast((data.len + 1) * 2); // NUL 포함 바이트
        return RegSetValueExW(hkey, name.ptr, 0, REG_SZ, @ptrCast(data.ptr), cb) == 0;
    }
} else struct {};

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
    if (comptime is_windows) return win_login.enabled(label);
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
    if (comptime is_windows) {
        if (!enable) return win_login.set(label, "", false);
        var exe_buf: [4096]u8 = undefined;
        const exe = if (std.process.executablePath(runtime.io, &exe_buf)) |n| exe_buf[0..n] else |_| return false;
        return win_login.set(label, exe, true);
    }
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

// Windows HKCU\…\Run 레지스트리 round-trip 검증(set/enabled/delete) — runtime.io 비의존
// (win_login 은 순수 advapi32). 고유 테스트 레이블 + defer 정리로 비파괴. macOS/Linux skip
// (그쪽 경로는 runtime.io 초기화가 필요한 파일 I/O 라 별도 e2e/수동 검증 영역).
test "login item (Windows): HKCU Run registry set/enabled/delete round-trip" {
    if (!comptime is_windows) return error.SkipZigTest;
    const label = "suji-core-logintest-zz9";
    _ = win_login.set(label, "", false); // 이전 잔존 제거
    defer _ = win_login.set(label, "", false); // 항상 정리(테스트 후 레지스트리 클린)

    try std.testing.expect(!win_login.enabled(label)); // 초기 미설정
    try std.testing.expect(win_login.set(label, "C:\\Temp\\suji-logintest.exe", true)); // 설정
    try std.testing.expect(win_login.enabled(label)); // 설정 확인
    try std.testing.expect(win_login.set(label, "", false)); // 해제
    try std.testing.expect(!win_login.enabled(label)); // 해제 확인
    try std.testing.expect(win_login.set(label, "", false)); // 멱등(부재 delete 성공)
}
