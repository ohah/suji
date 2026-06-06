//! Notification API — cef.zig 에서 분리(동작 무변경). macOS UNUserNotificationCenter,
//! Linux freedesktop D-Bus, Windows Shell_NotifyIcon balloon 기반 Electron `Notification` 호환 API.
const std = @import("std");
const builtin = @import("builtin");
const cef = @import("cef.zig");
const notification_state = @import("cef_notification_state.zig");
const notification_linux = @import("cef_notification_linux.zig");
const notification_windows = @import("cef_notification_windows.zig");

const is_macos = builtin.os.tag == .macos;
const is_linux = builtin.os.tag == .linux;
const writeCStr = cef.writeCStr;

// notification.m — UNUserNotificationCenter wrapper.
extern "c" fn suji_notification_is_supported() i32;
extern "c" fn suji_notification_set_click_callback(cb: *const fn ([*:0]const u8) callconv(.c) void) void;
extern "c" fn suji_notification_request_permission() i32;
extern "c" fn suji_notification_show(id: [*:0]const u8, title: [*:0]const u8, body: [*:0]const u8, silent: i32) i32;
extern "c" fn suji_notification_close(id: [*:0]const u8) void;
extern "c" fn suji_notification_remove_all() void;

// ============================================
// Notification API — UNUserNotificationCenter (Electron `Notification`)
// ============================================
// macOS 10.14+ UNUserNotificationCenter (NSUserNotification deprecated 후 macOS 26 제거).
// 첫 호출 시 OS 권한 다이얼로그 — 그 이후 알림 표시 가능.
// 한계: valid Bundle ID + Info.plist 필요. `suji dev` loose binary는 권한 요청 자체가
// 실패하거나 알림 안 뜰 수 있음. `suji build` .app 번들에서 정상 동작.
//
// click 이벤트는 SujiNotificationDelegate (notification.m)가 C 콜백으로 디스패치 →
// main.zig가 `notification:click {notificationId}` EventBus.emit.

pub const NotificationEmitHandler = notification_state.NotificationEmitHandler;

/// notification.m의 C 콜백 — Zig 측에서 main.zig로 라우팅.
fn notificationClickC(id_cstr: [*:0]const u8) callconv(.c) void {
    notification_state.emit(std.mem.span(id_cstr));
}

/// main.zig가 등록 — 알림 클릭 → EventBus 라우팅.
pub fn setNotificationEmitHandler(handler: NotificationEmitHandler) void {
    notification_state.setNotificationEmitHandler(handler);
    if (comptime is_macos) {
        if (!notificationIsSupported()) return;
        suji_notification_set_click_callback(&notificationClickC);
    }
    // Windows / Linux: handler 만 set, native click delivery 는 각 OS path 에서
    // notification_state.emit 호출 (Windows = win_pump balloon click,
    // Linux = D-Bus ActionInvoked signal — 후자는 후속 PR).
}

pub fn notificationIsSupported() bool {
    if (comptime builtin.os.tag == .windows) return true; // Shell_NotifyIcon balloon
    if (comptime is_linux) return notification_linux.isSupported();
    if (!comptime is_macos) return false;
    return suji_notification_is_supported() != 0;
}

/// 권한 요청 — 첫 호출 시 OS 다이얼로그. 동기 대기.
pub fn notificationRequestPermission() bool {
    if (comptime builtin.os.tag == .windows) return true; // 권한 불필요 (Shell_NotifyIcon)
    if (comptime is_linux) return notification_linux.requestPermission();
    if (!comptime is_macos) return false;
    return suji_notification_request_permission() != 0;
}

/// 알림 표시. id는 caller-controlled 식별자 (close에 사용). 한도: 64 byte.
/// title/body는 4KB stack-alloc 한도.
pub fn notificationShow(id: []const u8, title: []const u8, body: []const u8, silent: bool) bool {
    if (comptime builtin.os.tag == .windows) return notification_windows.win_notify.show(id, title, body, silent);
    if (comptime is_linux) return notification_linux.show(id, title, body, silent);
    if (!comptime is_macos) return false;
    var id_buf: [64]u8 = undefined;
    var t_buf: [4096]u8 = undefined;
    var b_buf: [4096]u8 = undefined;
    const id_cstr = writeCStr(id, &id_buf) orelse return false;
    const t_cstr = writeCStr(title, &t_buf) orelse return false;
    const b_cstr = writeCStr(body, &b_buf) orelse return false;
    return suji_notification_show(id_cstr, t_cstr, b_cstr, if (silent) 1 else 0) != 0;
}

pub fn notificationClose(id: []const u8) bool {
    if (comptime is_linux) return notification_linux.close(id);
    if (comptime builtin.os.tag == .windows) return notification_windows.win_notify.close(id);
    if (!comptime is_macos) return false;
    var id_buf: [64]u8 = undefined;
    const id_cstr = writeCStr(id, &id_buf) orelse return false;
    suji_notification_close(id_cstr);
    return true;
}

/// Electron Notification.removeAll() — 표시된/대기 모든 알림 제거.
/// macOS=UNUserNotificationCenter removeAll* (실동작). Linux/Windows 는 개별 id
/// 추적이 없어 후속(OS 플랫폼 경계) → false.
pub fn notificationRemoveAll() bool {
    if (!comptime is_macos) return false;
    suji_notification_remove_all();
    return true;
}
