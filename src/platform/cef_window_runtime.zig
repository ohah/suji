//! Runtime window operations for CefNative.
//! Destroy/show-hide/focus/title/bounds vtable entries.
const std = @import("std");
const builtin = @import("builtin");
const window_mod = @import("window");
const logger = @import("logger");
const cef = @import("cef.zig");
const cef_views_delegate = @import("cef_views_delegate.zig");
const cef_window_lifecycle = @import("cef_window_lifecycle.zig");

const c = cef.c;
const is_macos = builtin.os.tag == .macos;
const log = logger.module("cef");

fn fromCtx(ctx: ?*anyopaque) *cef.CefNative {
    return @ptrCast(@alignCast(ctx.?));
}

fn assertUiThread() void {
    std.debug.assert(c.cef_currently_on(c.TID_UI) == 1);
}

fn getHost(self: *cef.CefNative, handle: u64) ?*c.cef_browser_host_t {
    const entry = self.browsers.get(handle) orelse return null;
    const br = entry.browser;
    return cef.asPtr(c.cef_browser_host_t, br.get_host.?(br));
}

pub fn destroyWindow(ctx: ?*anyopaque, handle: u64) void {
    const self = fromCtx(ctx);
    assertUiThread();
    log.debug("CefNative.destroyWindow handle={d}", .{handle});
    const entry = self.browsers.get(handle) orelse {
        log.warn("CefNative.destroyWindow: handle={d} not in table", .{handle});
        return;
    };
    if (entry.views_window) |views_window| {
        views_window.close.?(views_window);
        return;
    }
    cef_window_lifecycle.detachWindowLifecycle(entry.ns_window);
    if (comptime is_macos) {
        // macOS: NSWindow close deallocates the content/browser view, which then
        // cascades into CEF cleanup and OnBeforeClose.
        cef.closeMacWindow(entry.ns_window);
    } else {
        const br = entry.browser;
        const host = cef.asPtr(c.cef_browser_host_t, br.get_host.?(br));
        if (host) |h| h.close_browser.?(h, 1);
    }
}

pub fn setVisible(ctx: ?*anyopaque, handle: u64, visible: bool) void {
    const self = fromCtx(ctx);
    assertUiThread();
    if (self.browsers.get(handle)) |entry| {
        if (entry.views_window) |views_window| {
            if (visible) views_window.show.?(views_window) else views_window.hide.?(views_window);
            return;
        }
    }
    const host = getHost(self, handle) orelse return;
    host.was_hidden.?(host, if (visible) 0 else 1);
}

pub fn focus(ctx: ?*anyopaque, handle: u64) void {
    const self = fromCtx(ctx);
    assertUiThread();
    if (self.browsers.get(handle)) |entry| {
        if (entry.views_window) |views_window| {
            views_window.activate.?(views_window);
            return;
        }
    }
    const host = getHost(self, handle) orelse return;
    host.set_focus.?(host, 1);
}

pub fn setTitle(ctx: ?*anyopaque, handle: u64, title: []const u8) void {
    assertUiThread();
    const self = fromCtx(ctx);
    const entry = self.browsers.get(handle) orelse return;
    if (entry.views_window) |views_window| {
        var title_buf: [512]u8 = undefined;
        const title_z = cef.nullTerminateOrTruncate(title, &title_buf) orelse return;
        var cef_title: c.cef_string_t = .{};
        cef.setCefString(&cef_title, title_z);
        views_window.set_title.?(views_window, &cef_title);
        return;
    }
    if (!is_macos) return;
    const ns_window = entry.ns_window orelse return;
    cef.setMacWindowTitle(ns_window, title);
}

pub fn setBounds(ctx: ?*anyopaque, handle: u64, bounds: window_mod.Bounds) void {
    assertUiThread();
    const self = fromCtx(ctx);
    const entry = self.browsers.getPtr(handle) orelse return;
    if (entry.views_window) |views_window| {
        var rect: c.cef_rect_t = .{
            .x = bounds.x,
            .y = bounds.y,
            .width = @intCast(bounds.width),
            .height = @intCast(bounds.height),
        };
        views_window.base.base.set_bounds.?(&views_window.base.base, &rect);
        if (entry.views_window_delegate) |delegate| cef_views_delegate.viewsWindowEmitBoundsChanged(delegate, rect);
        return;
    }
    if (!is_macos) return;
    const ns_window = entry.ns_window orelse return;
    cef.setMacWindowBounds(ns_window, bounds);
}
