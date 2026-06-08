//! Window visual controls for CefNative.
//! Opacity/background/shadow vtable entries plus the Windows HWND helpers they need.
const std = @import("std");
const builtin = @import("builtin");
const cef = @import("cef.zig");
const cef_views_delegate = @import("cef_views_delegate.zig");

const c = cef.c;
const is_macos = builtin.os.tag == .macos;
const is_linux = builtin.os.tag == .linux;
const is_windows = builtin.os.tag == .windows;
const views_native_window_options_platform = is_macos or is_linux;

const objc = cef.objc;
const msgSendVoidBool = cef.msgSendVoidBool;
const cefColorFromHex = cef_views_delegate.cefColorFromHex;
const applyViewsBackgroundColor = cef_views_delegate.applyViewsBackgroundColor;

fn fromCtx(ctx: ?*anyopaque) *cef.CefNative {
    return @ptrCast(@alignCast(ctx.?));
}

fn assertUiThread() void {
    std.debug.assert(c.cef_currently_on(c.TID_UI) == 1);
}

fn nsWindowFor(self: *cef.CefNative, handle: u64) ?*anyopaque {
    const entry = self.browsers.get(handle) orelse return null;
    return entry.ns_window;
}

pub fn setOpacityImpl(ctx: ?*anyopaque, handle: u64, opacity: f64) void {
    assertUiThread();
    if (comptime is_windows) {
        const self = fromCtx(ctx);
        const entry_ptr = self.browsers.getPtr(handle) orelse return;
        const hwnd = cef.windowsEntryHwnd(entry_ptr) orelse return;
        win_window.setLayeredOpacity(hwnd, opacity);
        return;
    }
    if (!comptime is_macos) return;
    const ns = nsWindowFor(fromCtx(ctx), handle) orelse return;
    const sel = objc.sel_registerName("setAlphaValue:");
    const fn_ptr: *const fn (?*anyopaque, ?*anyopaque, f64) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    fn_ptr(ns, @ptrCast(sel), opacity);
}

pub fn getOpacityImpl(ctx: ?*anyopaque, handle: u64) f64 {
    if (comptime is_windows) {
        const self = fromCtx(ctx);
        const entry_ptr = self.browsers.getPtr(handle) orelse return 1;
        const hwnd = cef.windowsEntryHwnd(entry_ptr) orelse return 1;
        return win_window.getLayeredOpacity(hwnd);
    }
    if (!comptime is_macos) return 1;
    const ns = nsWindowFor(fromCtx(ctx), handle) orelse return 1;
    const sel = objc.sel_registerName("alphaValue");
    const fn_ptr: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) f64 = @ptrCast(&objc.objc_msgSend);
    return fn_ptr(ns, @ptrCast(sel));
}

pub fn setBackgroundColorImpl(ctx: ?*anyopaque, handle: u64, hex: []const u8) void {
    assertUiThread();
    const self = fromCtx(ctx);
    if (comptime views_native_window_options_platform) {
        if (self.browsers.get(handle)) |entry| {
            if (entry.views_window) |views_window| {
                if (cefColorFromHex(hex)) |color| {
                    applyViewsBackgroundColor(views_window, entry.browser_view, color);
                }
                if (comptime is_macos) {
                    if (nsWindowFor(self, handle)) |ns| cef.applyBackgroundColor(ns, hex);
                }
                return;
            }
        }
    }
    if (!comptime is_macos) return;
    const ns = nsWindowFor(self, handle) orelse return;
    cef.applyBackgroundColor(ns, hex);
}

pub fn setHasShadowImpl(ctx: ?*anyopaque, handle: u64, has: bool) void {
    assertUiThread();
    if (comptime is_windows) {
        const self = fromCtx(ctx);
        const entry_ptr = self.browsers.getPtr(handle) orelse return;
        const hwnd = cef.windowsEntryHwnd(entry_ptr) orelse return;
        win_window.setShadow(hwnd, has);
        return;
    }
    if (!comptime is_macos) return;
    const ns = nsWindowFor(fromCtx(ctx), handle) orelse return;
    msgSendVoidBool(ns, "setHasShadow:", has);
}

pub fn hasShadowImpl(ctx: ?*anyopaque, handle: u64) bool {
    if (comptime is_windows) {
        const self = fromCtx(ctx);
        const entry_ptr = self.browsers.getPtr(handle) orelse return false;
        const hwnd = cef.windowsEntryHwnd(entry_ptr) orelse return false;
        return win_window.hasShadow(hwnd);
    }
    if (!comptime is_macos) return false;
    const ns = nsWindowFor(fromCtx(ctx), handle) orelse return false;
    return cef.msgSendBool(ns, "hasShadow");
}

// Win32 Window helpers for opacity (layered window) and DWM shadow.
const win_window = if (builtin.os.tag == .windows) struct {
    const GWL_EXSTYLE: i32 = -20;
    const WS_EX_LAYERED: i32 = 0x00080000;
    const LWA_ALPHA: u32 = 0x00000002;

    extern "user32" fn GetWindowLongPtrW(hWnd: ?*anyopaque, nIndex: i32) callconv(.winapi) isize;
    extern "user32" fn SetWindowLongPtrW(hWnd: ?*anyopaque, nIndex: i32, dwNewLong: isize) callconv(.winapi) isize;
    extern "user32" fn SetLayeredWindowAttributes(hwnd: ?*anyopaque, crKey: u32, bAlpha: u8, dwFlags: u32) callconv(.winapi) i32;
    extern "user32" fn GetLayeredWindowAttributes(hwnd: ?*anyopaque, pcrKey: ?*u32, pbAlpha: ?*u8, pdwFlags: ?*u32) callconv(.winapi) i32;

    /// opacity 0.0~1.0 -> 0~255 byte. WS_EX_LAYERED extended style is applied idempotently.
    fn setLayeredOpacity(hwnd: ?*anyopaque, opacity: f64) void {
        if (hwnd == null) return;
        const clamped = if (opacity < 0) @as(f64, 0) else if (opacity > 1) @as(f64, 1) else opacity;
        const alpha: u8 = @intFromFloat(@round(clamped * 255.0));
        const cur = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
        if ((cur & WS_EX_LAYERED) == 0) {
            _ = SetWindowLongPtrW(hwnd, GWL_EXSTYLE, cur | WS_EX_LAYERED);
        }
        _ = SetLayeredWindowAttributes(hwnd, 0, alpha, LWA_ALPHA);
    }

    fn getLayeredOpacity(hwnd: ?*anyopaque) f64 {
        if (hwnd == null) return 1;
        const cur = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
        if ((cur & WS_EX_LAYERED) == 0) return 1;
        var alpha: u8 = 255;
        if (GetLayeredWindowAttributes(hwnd, null, &alpha, null) == 0) return 1;
        return @as(f64, @floatFromInt(alpha)) / 255.0;
    }

    extern "dwmapi" fn DwmSetWindowAttribute(hwnd: ?*anyopaque, dwAttribute: u32, pvAttribute: *const anyopaque, cbAttribute: u32) callconv(.winapi) i32;
    extern "dwmapi" fn DwmGetWindowAttribute(hwnd: ?*anyopaque, dwAttribute: u32, pvAttribute: *anyopaque, cbAttribute: u32) callconv(.winapi) i32;
    const DWMWA_NCRENDERING_ENABLED: u32 = 1;
    const DWMWA_NCRENDERING_POLICY: u32 = 2;
    const DWMNCRP_USEWINDOWSTYLE: u32 = 0;
    const DWMNCRP_DISABLED: u32 = 1;

    fn setShadow(hwnd: ?*anyopaque, has: bool) void {
        if (hwnd == null) return;
        const policy: u32 = if (has) DWMNCRP_USEWINDOWSTYLE else DWMNCRP_DISABLED;
        _ = DwmSetWindowAttribute(hwnd, DWMWA_NCRENDERING_POLICY, &policy, @sizeOf(u32));
    }

    fn hasShadow(hwnd: ?*anyopaque) bool {
        if (hwnd == null) return false;
        var enabled: u32 = 0;
        if (DwmGetWindowAttribute(hwnd, DWMWA_NCRENDERING_ENABLED, &enabled, @sizeOf(u32)) != 0) return false;
        return enabled != 0;
    }
} else struct {};
