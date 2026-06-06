//! Window state controls for CefNative.
//! Minimize/restore/maximize/fullscreen and matching state queries.
const std = @import("std");
const builtin = @import("builtin");
const cef = @import("cef.zig");
const cef_views_delegate = @import("cef_views_delegate.zig");
const cef_window_lifecycle = @import("cef_window_lifecycle.zig");

const c = cef.c;
const is_macos = builtin.os.tag == .macos;

const viewsWindowIsMinimized = cef_views_delegate.viewsWindowIsMinimized;
const viewsWindowIsMaximized = cef_views_delegate.viewsWindowIsMaximized;
const viewsWindowIsFullscreen = cef_views_delegate.viewsWindowIsFullscreen;

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

fn callOnNs(ctx: ?*anyopaque, handle: u64, comptime native_fn: anytype) void {
    if (!comptime is_macos) return;
    assertUiThread();
    const ns = nsWindowFor(fromCtx(ctx), handle) orelse return;
    native_fn(ns);
}

fn callOnNsBool(ctx: ?*anyopaque, handle: u64, comptime native_fn: anytype) bool {
    if (!comptime is_macos) return false;
    assertUiThread();
    const ns = nsWindowFor(fromCtx(ctx), handle) orelse return false;
    return native_fn(ns) != 0;
}

pub fn minimizeImpl(ctx: ?*anyopaque, handle: u64) void {
    const self = fromCtx(ctx);
    assertUiThread();
    if (self.browsers.get(handle)) |entry| {
        if (entry.views_window) |views_window| {
            const delegate = entry.views_window_delegate;
            const was_minimized = if (delegate) |d|
                d.last_minimized or viewsWindowIsMinimized(views_window)
            else
                viewsWindowIsMinimized(views_window);
            if (views_window.minimize) |minimize| {
                minimize(views_window);
                if (delegate) |d| {
                    d.last_minimized = true;
                    d.last_maximized = false;
                }
                if (!was_minimized) {
                    if (cef_window_lifecycle.g_window_minimize_handler) |h| h(handle);
                }
            }
            return;
        }
    }
    callOnNs(ctx, handle, cef_window_lifecycle.suji_window_lifecycle_minimize);
}

pub fn restoreWindowImpl(ctx: ?*anyopaque, handle: u64) void {
    const self = fromCtx(ctx);
    assertUiThread();
    if (self.browsers.get(handle)) |entry| {
        if (entry.views_window) |views_window| {
            const delegate = entry.views_window_delegate;
            const was_minimized = if (delegate) |d|
                d.last_minimized or viewsWindowIsMinimized(views_window)
            else
                viewsWindowIsMinimized(views_window);
            if (views_window.restore) |restore| {
                restore(views_window);
                if (delegate) |d| d.last_minimized = false;
                if (was_minimized) {
                    if (cef_window_lifecycle.g_window_restore_handler) |h| h(handle);
                }
            }
            return;
        }
    }
    callOnNs(ctx, handle, cef_window_lifecycle.suji_window_lifecycle_deminiaturize);
}

pub fn maximizeImpl(ctx: ?*anyopaque, handle: u64) void {
    const self = fromCtx(ctx);
    assertUiThread();
    if (self.browsers.get(handle)) |entry| {
        if (entry.views_window) |views_window| {
            const delegate = entry.views_window_delegate;
            const was_maximized = if (delegate) |d|
                d.last_maximized or viewsWindowIsMaximized(views_window)
            else
                viewsWindowIsMaximized(views_window);
            if (was_maximized) return;
            if (views_window.maximize) |maximize| {
                maximize(views_window);
                if (delegate) |d| {
                    d.last_maximized = true;
                    d.last_minimized = false;
                }
                if (cef_window_lifecycle.g_window_maximize_handler) |h| h(handle);
            }
            return;
        }
    }
    callOnNs(ctx, handle, cef_window_lifecycle.suji_window_lifecycle_maximize);
}

pub fn unmaximizeImpl(ctx: ?*anyopaque, handle: u64) void {
    const self = fromCtx(ctx);
    assertUiThread();
    if (self.browsers.get(handle)) |entry| {
        if (entry.views_window) |views_window| {
            const delegate = entry.views_window_delegate;
            const was_maximized = if (delegate) |d|
                d.last_maximized or viewsWindowIsMaximized(views_window)
            else
                viewsWindowIsMaximized(views_window);
            if (!was_maximized) return;
            if (views_window.restore) |restore| {
                restore(views_window);
                if (delegate) |d| d.last_maximized = false;
                if (cef_window_lifecycle.g_window_unmaximize_handler) |h| h(handle);
            }
            return;
        }
    }
    callOnNs(ctx, handle, cef_window_lifecycle.suji_window_lifecycle_unmaximize);
}

pub fn setFullscreenImpl(ctx: ?*anyopaque, handle: u64, flag: bool) void {
    const self = fromCtx(ctx);
    assertUiThread();
    if (self.browsers.get(handle)) |entry| {
        if (entry.views_window) |views_window| {
            const is_fullscreen = viewsWindowIsFullscreen(views_window);
            if (is_fullscreen == flag) return;
            if (views_window.set_fullscreen) |set_fullscreen| {
                set_fullscreen(views_window, @intFromBool(flag));
            }
            return;
        }
    }
    if (!comptime is_macos) return;
    const ns = nsWindowFor(self, handle) orelse return;
    cef_window_lifecycle.suji_window_lifecycle_set_fullscreen(ns, @intFromBool(flag));
}

pub fn isMinimizedImpl(ctx: ?*anyopaque, handle: u64) bool {
    const self = fromCtx(ctx);
    assertUiThread();
    if (self.browsers.get(handle)) |entry| {
        if (entry.views_window) |views_window| {
            if (entry.views_window_delegate) |delegate| {
                return delegate.last_minimized or viewsWindowIsMinimized(views_window);
            }
            return viewsWindowIsMinimized(views_window);
        }
    }
    return callOnNsBool(ctx, handle, cef_window_lifecycle.suji_window_lifecycle_is_minimized);
}

pub fn isMaximizedImpl(ctx: ?*anyopaque, handle: u64) bool {
    const self = fromCtx(ctx);
    assertUiThread();
    if (self.browsers.get(handle)) |entry| {
        if (entry.views_window) |views_window| {
            if (entry.views_window_delegate) |delegate| {
                return delegate.last_maximized or viewsWindowIsMaximized(views_window);
            }
            return viewsWindowIsMaximized(views_window);
        }
    }
    return callOnNsBool(ctx, handle, cef_window_lifecycle.suji_window_lifecycle_is_maximized);
}

pub fn isFullscreenImpl(ctx: ?*anyopaque, handle: u64) bool {
    const self = fromCtx(ctx);
    assertUiThread();
    if (self.browsers.get(handle)) |entry| {
        if (entry.views_window) |views_window| return viewsWindowIsFullscreen(views_window);
    }
    return callOnNsBool(ctx, handle, cef_window_lifecycle.suji_window_lifecycle_is_fullscreen);
}

// Electron BrowserWindow.isVisible() — CEF view-level is_visible(cef_view_t), 비-Views 는
// NSWindow isVisible 폴백.
pub fn isVisibleImpl(ctx: ?*anyopaque, handle: u64) bool {
    const self = fromCtx(ctx);
    assertUiThread();
    if (self.browsers.get(handle)) |entry| {
        if (entry.views_window) |views_window| {
            return views_window.base.base.is_visible.?(&views_window.base.base) != 0;
        }
    }
    return callOnNsBool(ctx, handle, cef_window_lifecycle.suji_window_lifecycle_is_visible);
}

// Electron BrowserWindow.isFocused() — CEF window is_active, 비-Views 는 NSWindow isKeyWindow.
pub fn isFocusedImpl(ctx: ?*anyopaque, handle: u64) bool {
    const self = fromCtx(ctx);
    assertUiThread();
    if (self.browsers.get(handle)) |entry| {
        if (entry.views_window) |views_window| return views_window.is_active.?(views_window) != 0;
    }
    return callOnNsBool(ctx, handle, cef_window_lifecycle.suji_window_lifecycle_is_focused);
}

// Electron BrowserWindow.isAlwaysOnTop() — CEF window is_always_on_top, 비-Views 는 NSWindow level.
pub fn isAlwaysOnTopImpl(ctx: ?*anyopaque, handle: u64) bool {
    const self = fromCtx(ctx);
    assertUiThread();
    if (self.browsers.get(handle)) |entry| {
        if (entry.views_window) |views_window| return views_window.is_always_on_top.?(views_window) != 0;
    }
    return callOnNsBool(ctx, handle, cef_window_lifecycle.suji_window_lifecycle_is_always_on_top);
}

// Electron BrowserWindow.setAlwaysOnTop(flag) — CEF window set_always_on_top, 비-Views 는 NSWindow level.
pub fn setAlwaysOnTopImpl(ctx: ?*anyopaque, handle: u64, on_top: bool) void {
    const self = fromCtx(ctx);
    assertUiThread();
    if (self.browsers.get(handle)) |entry| {
        if (entry.views_window) |views_window| {
            views_window.set_always_on_top.?(views_window, if (on_top) 1 else 0);
            return;
        }
    }
    if (!is_macos) return;
    const ns = nsWindowFor(self, handle) orelse return;
    cef_window_lifecycle.suji_window_lifecycle_set_always_on_top(ns, if (on_top) 1 else 0);
}
