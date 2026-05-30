//! Dock/app badge API — cef.zig 에서 분리(동작 무변경). macOS NSDockTile,
//! Linux Unity LauncherEntry bridge, Windows taskbar overlay bridge.
const std = @import("std");
const builtin = @import("builtin");
const runtime = @import("runtime");
const cef = @import("cef.zig");

const is_macos = builtin.os.tag == .macos;
const is_linux = builtin.os.tag == .linux;
const is_windows = builtin.os.tag == .windows;

const getClass = cef.getClass;
const msgSend = cef.msgSend;
const msgSendVoid1 = cef.msgSendVoid1;
const nsStringFromSlice = cef.nsStringFromSlice;
const nsStringToUtf8Buf = cef.nsStringToUtf8Buf;
const nullTerminateOrTruncate = cef.nullTerminateOrTruncate;

extern "c" fn suji_linux_badge_set_count(desktop_id: [*:0]const u8, count: u32) c_int;
extern "c" fn suji_windows_badge_set_count(hwnd: ?*anyopaque, count: u32) c_int;

/// Dock 아이콘 badge 텍스트 설정. 빈 문자열이면 badge 제거.
pub fn dockSetBadge(text: []const u8) void {
    if (!comptime is_macos) return;
    const NSApp = getClass("NSApplication") orelse return;
    const app = msgSend(NSApp, "sharedApplication") orelse return;
    const dock_tile = msgSend(app, "dockTile") orelse return;
    const ns_str = nsStringFromSlice(text) orelse return;
    msgSendVoid1(dock_tile, "setBadgeLabel:", ns_str);
}

/// 현재 badge 텍스트 (없으면 빈 문자열).
pub fn dockGetBadge(out_buf: []u8) []const u8 {
    if (!comptime is_macos) return out_buf[0..0];
    const NSApp = getClass("NSApplication") orelse return out_buf[0..0];
    const app = msgSend(NSApp, "sharedApplication") orelse return out_buf[0..0];
    const dock_tile = msgSend(app, "dockTile") orelse return out_buf[0..0];
    const ns_str = msgSend(dock_tile, "badgeLabel") orelse return out_buf[0..0];
    return nsStringToUtf8Buf(ns_str, out_buf);
}

fn windowsSetBadgeCount(count: u32) bool {
    if (!comptime is_windows) return false;
    var hwnds: [64]?*anyopaque = undefined;
    const len = cef.collectTopLevelNativeWindowHandles(&hwnds);
    var any_ok = false;
    for (hwnds[0..len]) |hwnd| {
        if (suji_windows_badge_set_count(hwnd, count) != 0) any_ok = true;
    }
    return any_ok;
}

/// Electron `app.setBadgeCount(count)` native backend.
/// macOS는 dock label, Linux는 Unity LauncherEntry(libunity best-effort),
/// Windows는 taskbar overlay icon(ITaskbarList3)로 적용한다.
pub fn appSetBadgeCount(count: u32) bool {
    if (comptime is_macos) {
        var label_buf: [32]u8 = undefined;
        const label = if (count == 0) "" else std.fmt.bufPrint(&label_buf, "{d}", .{count}) catch return false;
        dockSetBadge(label);
        return true;
    }
    if (comptime is_linux) {
        var id_buf: [256]u8 = undefined;
        const desktop_id = runtime.env("SUJI_DESKTOP_ID") orelse "suji.desktop";
        const desktop_id_z = nullTerminateOrTruncate(desktop_id, &id_buf) orelse "suji.desktop";
        return suji_linux_badge_set_count(desktop_id_z.ptr, count) != 0;
    }
    if (comptime is_windows) return windowsSetBadgeCount(count);
    return false;
}
