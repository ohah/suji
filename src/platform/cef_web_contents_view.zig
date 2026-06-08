//! WebContentsView glue for CefNative.
//! CEF Views child-window/overlay creation, visibility, bounds, z-order, and teardown.
const std = @import("std");
const builtin = @import("builtin");
const runtime = @import("runtime");
const window_mod = @import("window");
const logger = @import("logger");
const cef_views_policy = @import("cef_views_policy.zig");
const cef_views_delegate = @import("cef_views_delegate.zig");
const cef_web_contents_view_child_window = @import("cef_web_contents_view_child_window.zig");
const cef_web_contents_view_overlay = @import("cef_web_contents_view_overlay.zig");
const cef = @import("cef.zig");

const c = cef.c;
const log = logger.module("cef");
const cef_views_platform: cef_views_policy.Platform = switch (builtin.os.tag) {
    .macos => .macos,
    .linux => .linux,
    .windows => .windows,
    else => .unsupported,
};

fn fromCtx(ctx: ?*anyopaque) *cef.CefNative {
    return @ptrCast(@alignCast(ctx.?));
}

fn assertUiThread() void {
    std.debug.assert(c.cef_currently_on(c.TID_UI) == 1);
}

pub fn createView(ctx: ?*anyopaque, host_handle: u64, opts: *const window_mod.CreateViewOptions) anyerror!u64 {
    const self = fromCtx(ctx);
    assertUiThread();
    const host_entry = self.browsers.getPtr(host_handle) orelse return error.HostNotFound;
    if (host_entry.views_window == null) {
        log.warn("create_view: CEF Views host required; native fallback does not support WebContentsView", .{});
        return error.NotSupportedOnPlatform;
    }
    return switch (cef_views_policy.childViewPath(
        cef_views_platform,
        runtime.env("SUJI_CEF_VIEWS_CHILD_OVERLAY"),
    )) {
        .child_window => cef_web_contents_view_child_window.create(self, host_handle, host_entry, opts),
        .overlay => cef_web_contents_view_overlay.create(self, host_handle, host_entry, opts),
        .unsupported => {
            log.warn("create_view: CEF Views WebContentsView unsupported on this platform", .{});
            return error.NotSupportedOnPlatform;
        },
    };
}

pub fn closeChildViewWindow(self: *cef.CefNative, entry: *cef.CefNative.BrowserEntry) void {
    cef_web_contents_view_child_window.close(self, entry);
}

pub fn destroyView(ctx: ?*anyopaque, view_handle: u64) void {
    const self = fromCtx(ctx);
    assertUiThread();
    const entry = self.browsers.getPtr(view_handle) orelse return;
    if (entry.child_ns_window != null) {
        cef_web_contents_view_child_window.destroy(self, entry);
        return;
    }
    if (entry.overlay_controller != null) {
        cef_web_contents_view_overlay.destroy(entry);
        return;
    }
    if (entry.views_parent_handle != null) {
        if (entry.views_parent_handle) |parent_handle| {
            if (self.browsers.get(parent_handle)) |parent_entry| {
                if (parent_entry.views_window) |host_window| {
                    if (entry.browser_view) |browser_view| {
                        host_window.base.remove_child_view.?(&host_window.base, &browser_view.base);
                    }
                }
            }
        }
        const br = entry.browser;
        const host = cef.asPtr(c.cef_browser_host_t, br.get_host.?(br));
        if (host) |h| h.close_browser.?(h, 1);
        return;
    }
}

pub fn setViewBounds(ctx: ?*anyopaque, view_handle: u64, bounds: window_mod.Bounds) void {
    const self = fromCtx(ctx);
    assertUiThread();
    if (self.browsers.get(view_handle)) |entry| {
        if (entry.child_ns_window != null) {
            cef_web_contents_view_child_window.setBounds(self, entry, bounds);
            return;
        }
        if (entry.overlay_controller != null) {
            cef_web_contents_view_overlay.setBounds(entry, bounds);
            return;
        }
        if (entry.views_parent_handle != null) {
            const browser_view = entry.browser_view orelse return;
            var rect: c.cef_rect_t = .{
                .x = bounds.x,
                .y = bounds.y,
                .width = @intCast(bounds.width),
                .height = @intCast(bounds.height),
            };
            browser_view.base.set_bounds.?(&browser_view.base, &rect);
            return;
        }
    }
}

/// Electron `View.setBackgroundColor(color)` — view 의 cef_view_t 배경색(로드 중 표시).
/// "#RRGGBB[AA]". 모든 variant 의 browser_view(cef_view_t)에 set_background_color.
/// window setBackgroundColor 와 동일 파서(cefColorFromHex) — 잘못된 hex 는 no-op.
pub fn setViewBackgroundColor(ctx: ?*anyopaque, view_handle: u64, hex: []const u8) void {
    const self = fromCtx(ctx);
    assertUiThread();
    const entry = self.browsers.get(view_handle) orelse return;
    const browser_view = entry.browser_view orelse return;
    const set_bg = browser_view.base.set_background_color orelse return;
    const color = cef_views_delegate.cefColorFromHex(hex) orelse return;
    set_bg(&browser_view.base, color);
}

pub fn setViewVisible(ctx: ?*anyopaque, view_handle: u64, visible: bool) void {
    const self = fromCtx(ctx);
    assertUiThread();
    if (self.browsers.get(view_handle)) |entry| {
        if (entry.child_ns_window != null) {
            cef_web_contents_view_child_window.setVisible(self, view_handle, entry, visible);
            return;
        }
        if (entry.overlay_controller != null) {
            cef_web_contents_view_overlay.setVisible(entry, visible);
            return;
        }
        if (entry.views_parent_handle != null) {
            const browser_view = entry.browser_view orelse return;
            browser_view.base.set_visible.?(&browser_view.base, if (visible) 1 else 0);
            const host = cef.asPtr(c.cef_browser_host_t, entry.browser.get_host.?(entry.browser));
            if (host) |h| h.was_hidden.?(h, if (visible) 0 else 1);
            return;
        }
    }
}

pub fn reorderView(ctx: ?*anyopaque, host_handle: u64, view_handle: u64, index_in_host: u32) void {
    const self = fromCtx(ctx);
    assertUiThread();
    _ = index_in_host;
    if (self.browsers.getPtr(view_handle)) |entry| {
        if (entry.child_ns_window != null) {
            cef_web_contents_view_child_window.reorder(self, host_handle, entry);
            return;
        }
        if (entry.overlay_controller != null) {
            cef_web_contents_view_overlay.reorder(self, host_handle, entry);
            return;
        }
        if (entry.views_parent_handle != null) {
            const host_entry = self.browsers.get(host_handle) orelse return;
            const host_window = host_entry.views_window orelse return;
            const browser_view = entry.browser_view orelse return;
            host_window.base.remove_child_view.?(&host_window.base, &browser_view.base);
            host_window.base.add_child_view.?(&host_window.base, &browser_view.base);
            return;
        }
    }
}
