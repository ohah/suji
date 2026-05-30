//! powerMonitor API — cef.zig 에서 분리(동작 무변경).
//! OS idle time + suspend/resume/lock event bridge.
const std = @import("std");
const builtin = @import("builtin");

const is_macos = builtin.os.tag == .macos;
const is_linux = builtin.os.tag == .linux;
const is_windows = builtin.os.tag == .windows;

// ============================================
// powerMonitor — 유휴 시간 (Electron `powerMonitor.getSystemIdleTime`)
// ============================================
// `CGEventSourceSecondsSinceLastEventType` (ApplicationServices) — 마지막 input 이후 초.
// HID system state + 모든 event type (~0). Cocoa가 ApplicationServices transitively 포함.

extern "c" fn CGEventSourceSecondsSinceLastEventType(state: c_int, event_type: u32) f64;

const linux_xss = if (is_linux) struct {
    const XScreenSaverInfo = extern struct {
        window: c_ulong,
        state: c_int,
        kind: c_int,
        til_or_since: c_ulong,
        idle: c_ulong,
        event_mask: c_ulong,
    };

    extern "c" fn XOpenDisplay(display_name: ?[*:0]const u8) callconv(.c) ?*anyopaque;
    extern "c" fn XDefaultRootWindow(display: ?*anyopaque) callconv(.c) c_ulong;
    extern "c" fn XCloseDisplay(display: ?*anyopaque) callconv(.c) c_int;
    extern "c" fn XFree(data: ?*anyopaque) callconv(.c) c_int;
    extern "c" fn XScreenSaverAllocInfo() callconv(.c) ?*XScreenSaverInfo;
    extern "c" fn XScreenSaverQueryInfo(display: ?*anyopaque, drawable: c_ulong, saver_info: *XScreenSaverInfo) callconv(.c) c_int;
} else struct {};

const win_idle = if (is_windows) struct {
    const w = std.os.windows;
    const LASTINPUTINFO = extern struct {
        cbSize: u32,
        dwTime: u32,
    };

    extern "user32" fn GetLastInputInfo(plii: *LASTINPUTINFO) callconv(.winapi) w.BOOL;
    extern "kernel32" fn GetTickCount() callconv(.winapi) u32;
} else struct {};

/// 시스템 유휴 시간 (초). 활성 입력이 발생할 때마다 0으로 리셋.
pub fn powerMonitorIdleSeconds() f64 {
    if (comptime is_linux) {
        const display = linux_xss.XOpenDisplay(null) orelse return 0;
        defer _ = linux_xss.XCloseDisplay(display);

        const info = linux_xss.XScreenSaverAllocInfo() orelse return 0;
        defer _ = linux_xss.XFree(info);

        const root = linux_xss.XDefaultRootWindow(display);
        if (linux_xss.XScreenSaverQueryInfo(display, root, info) == 0) return 0;
        return @as(f64, @floatFromInt(info.idle)) / 1000.0;
    }

    if (comptime is_windows) {
        var info = win_idle.LASTINPUTINFO{
            .cbSize = @sizeOf(win_idle.LASTINPUTINFO),
            .dwTime = 0,
        };
        if (!win_idle.GetLastInputInfo(&info).toBool()) return 0;
        const elapsed_ms = win_idle.GetTickCount() -% info.dwTime;
        return @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;
    }

    if (!comptime is_macos) return 0;
    // kCGEventSourceStateHIDSystemState = 1, kCGAnyInputEventType = ~0 (uint32_max).
    return CGEventSourceSecondsSinceLastEventType(1, 0xFFFFFFFF);
}

// ============================================
// powerMonitor — OS 전원/잠금 이벤트 옵저버 (Electron `powerMonitor` 동등).
// ============================================
// macOS: NSWorkspace notification observer (power_monitor.m).
// Linux: logind/ScreenSaver DBus signals (power_monitor_linux.c).
// Windows: WM_POWERBROADCAST + WTS session messages (power_monitor_win.c).
// 각 플랫폼 bridge가 C 콜백으로 dispatch하고 Zig 측에서는 EventBus emit.

extern "c" fn suji_power_monitor_install(cb: *const fn (event: [*:0]const u8) callconv(.c) void) void;
extern "c" fn suji_power_monitor_uninstall() void;
extern "c" fn suji_power_monitor_linux_install(cb: *const fn (event: [*:0]const u8) callconv(.c) void) void;
extern "c" fn suji_power_monitor_linux_uninstall() void;
extern "c" fn suji_power_monitor_windows_install(cb: *const fn (event: [*:0]const u8) callconv(.c) void) void;
extern "c" fn suji_power_monitor_windows_uninstall() void;

pub fn powerMonitorInstall(cb: *const fn (event: [*:0]const u8) callconv(.c) void) void {
    if (comptime is_linux) return suji_power_monitor_linux_install(cb);
    if (comptime is_windows) return suji_power_monitor_windows_install(cb);
    if (comptime is_macos) return suji_power_monitor_install(cb);
}

pub fn powerMonitorUninstall() void {
    if (comptime is_linux) return suji_power_monitor_linux_uninstall();
    if (comptime is_windows) return suji_power_monitor_windows_uninstall();
    if (comptime is_macos) return suji_power_monitor_uninstall();
}

/// 화면 잠금 상태 — lock-screen/unlock-screen 이벤트로 갱신(main.zig power
/// 콜백). getSystemIdleState 가 "locked" 판정에 사용(Electron 동등 상태값).
/// 이벤트 콜백(임의 스레드)과 idle-state IPC(다른 스레드) 간 atomic.
var g_screen_locked: std.atomic.Value(bool) = .init(false);

pub fn powerMonitorSetScreenLocked(v: bool) void {
    g_screen_locked.store(v, .monotonic);
}

pub fn powerMonitorScreenLocked() bool {
    return g_screen_locked.load(.monotonic);
}
