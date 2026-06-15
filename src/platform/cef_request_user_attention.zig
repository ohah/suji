//! app.requestUserAttention — cef.zig 에서 분리(동작 무변경).
//! macOS NSApplication dock bounce / Windows 메인 창 taskbar FlashWindowEx.
const builtin = @import("builtin");
const cef = @import("cef.zig");

const is_macos = builtin.os.tag == .macos;
const is_windows = builtin.os.tag == .windows;

const objc = cef.objc;
const getClass = cef.getClass;
const msgSend = cef.msgSend;

// ============================================
// app.requestUserAttention — dock bounce (Electron `app.requestUserAttention`)
// ============================================
// 반환된 request_id로 cancel 가능 (NSApp 내부 큐). 호출 시점에 앱이 이미 active면
// NSApp가 0을 반환 (no-op) — wrapper도 0 그대로 노출. Linux는 후속.

/// NSRequestUserAttentionType — `<AppKit/NSApplication.h>`.
const kNSCriticalRequest: c_long = 0; // 활성화될 때까지 반복 바운스
const kNSInformationalRequest: c_long = 10; // 1회 바운스

// Windows: 메인 top-level 창을 FlashWindowEx 로 taskbar flash(앱-레벨 attention 개념이
// 없어 per-window 로 근사 — Electron 도 BrowserWindow.flashFrame 과 동일 메커니즘).
const win_attn = if (is_windows) struct {
    const FLASHW_STOP: u32 = 0;
    const FLASHW_ALL: u32 = 3; // caption + tray
    const FLASHW_TIMERNOFG: u32 = 12; // foreground 될 때까지 반복
    const FLASHWINFO = extern struct {
        cbSize: u32,
        hwnd: ?*anyopaque,
        dwFlags: u32,
        uCount: u32,
        dwTimeout: u32,
    };
    extern "user32" fn FlashWindowEx(pfwi: *const FLASHWINFO) callconv(.winapi) i32;

    /// 메인(첫 top-level) 창 HWND. 창이 없으면 null.
    fn mainHwnd() ?*anyopaque {
        var handles: [1]?*anyopaque = undefined;
        if (cef.collectTopLevelNativeWindowHandles(&handles) == 0) return null;
        return handles[0];
    }

    fn flash(critical: bool) bool {
        const hwnd = mainHwnd() orelse return false;
        var info = FLASHWINFO{
            .cbSize = @sizeOf(FLASHWINFO),
            .hwnd = hwnd,
            // critical: foreground 될 때까지 반복. informational: 3회 flash 후 정지.
            .dwFlags = if (critical) FLASHW_ALL | FLASHW_TIMERNOFG else FLASHW_ALL,
            .uCount = if (critical) 0 else 3,
            .dwTimeout = 0,
        };
        _ = FlashWindowEx(&info);
        return true;
    }

    fn stop() void {
        const hwnd = mainHwnd() orelse return;
        var info = FLASHWINFO{ .cbSize = @sizeOf(FLASHWINFO), .hwnd = hwnd, .dwFlags = FLASHW_STOP, .uCount = 0, .dwTimeout = 0 };
        _ = FlashWindowEx(&info);
    }
} else struct {};

/// dock 바운스(macOS) / taskbar flash(Windows) 시작. 0=no-op. 아니면 cancel용 id.
/// Windows 는 FlashWindowEx 에 cancelable id 가 없어 sentinel 1 반환(cancel=메인 창 FLASHW_STOP).
pub fn appRequestUserAttention(critical: bool) u32 {
    if (comptime is_windows) return if (win_attn.flash(critical)) 1 else 0;
    if (!comptime is_macos) return 0;
    const NSApplication = getClass("NSApplication") orelse return 0;
    const app = msgSend(NSApplication, "sharedApplication") orelse return 0;
    const sel = objc.sel_registerName("requestUserAttention:");
    const f: *const fn (?*anyopaque, ?*anyopaque, c_long) callconv(.c) c_long = @ptrCast(&objc.objc_msgSend);
    const id = f(app, @ptrCast(sel), if (critical) kNSCriticalRequest else kNSInformationalRequest);
    return if (id > 0) @intCast(id) else 0;
}

/// dock 바운스(macOS) / taskbar flash(Windows) 취소. id == 0 이면 false (guard).
/// macOS NSApp `cancelUserAttentionRequest:`/Windows FLASHW_STOP 모두 void라 stale id 도 true.
pub fn appCancelUserAttentionRequest(id: u32) bool {
    if (id == 0) return false;
    if (comptime is_windows) {
        win_attn.stop();
        return true;
    }
    if (!comptime is_macos) return false;
    const NSApplication = getClass("NSApplication") orelse return false;
    const app = msgSend(NSApplication, "sharedApplication") orelse return false;
    const sel = objc.sel_registerName("cancelUserAttentionRequest:");
    const f: *const fn (?*anyopaque, ?*anyopaque, c_long) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    f(app, @ptrCast(sel), @intCast(id));
    return true;
}
