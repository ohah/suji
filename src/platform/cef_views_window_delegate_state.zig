//! CEF Views Window delegate state and shared helpers.

const std = @import("std");
const builtin = @import("builtin");
const window_mod = @import("window");
const cef_window_lifecycle = @import("cef_window_lifecycle.zig");
const cef = @import("cef.zig");

const c = cef.c;

const is_macos = builtin.os.tag == .macos;
const is_linux = builtin.os.tag == .linux;
pub const views_native_window_options_platform = is_macos or is_linux;

pub const ViewsWindowDelegate = struct {
    delegate: c.cef_window_delegate_t = undefined,
    allocator: std.mem.Allocator,
    ref_count: std.atomic.Value(u32) = .init(1),
    browser_view: ?*c.cef_browser_view_t,
    parent_window: ?*c.cef_window_t = null,
    cef_window: ?*c.cef_window_t = null,
    handle: u64 = 0,
    title_buf: [512]u8 = undefined,
    title_len: usize = 0,
    bounds: window_mod.Bounds,
    appearance: window_mod.Appearance,
    constraints: window_mod.Constraints,
    last_bounds: c.cef_rect_t = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    has_last_bounds: bool = false,
    last_minimized: bool = false,
    last_maximized: bool = false,
    last_fullscreen: bool = false,
};

pub fn viewsWindowFromBase(base: ?*c.cef_base_ref_counted_t) ?*ViewsWindowDelegate {
    return @ptrCast(@alignCast(base orelse return null));
}

pub fn viewsWindowFromSelf(self: ?*c._cef_window_delegate_t) ?*ViewsWindowDelegate {
    return @ptrCast(@alignCast(self orelse return null));
}

pub fn viewsWindowFromViewDelegate(self: ?*c._cef_view_delegate_t) ?*ViewsWindowDelegate {
    return @ptrCast(@alignCast(self orelse return null));
}

pub fn releaseCefBase(base: *c.cef_base_ref_counted_t) void {
    if (base.release) |rel| _ = rel(base);
}

pub fn releaseBrowserViewRef(browser_view: ?*c.cef_browser_view_t) void {
    const bv = browser_view orelse return;
    releaseCefBase(&bv.base.base);
}

pub fn releaseWindowRef(window: ?*c.cef_window_t) void {
    const win = window orelse return;
    releaseCefBase(&win.base.base.base);
}

pub fn retainWindowRef(window: ?*c.cef_window_t) ?*c.cef_window_t {
    const win = window orelse return null;
    if (win.base.base.base.add_ref) |add_ref| add_ref(&win.base.base.base);
    return win;
}

pub fn releaseOverlayRef(controller: ?*c.cef_overlay_controller_t) void {
    const ctrl = controller orelse return;
    releaseCefBase(&ctrl.base);
}

pub fn viewsWindowRememberBounds(d: *ViewsWindowDelegate, bounds: c.cef_rect_t) void {
    d.last_bounds = bounds;
    d.has_last_bounds = true;
}

pub fn viewsWindowEmitBoundsChanged(d: *ViewsWindowDelegate, bounds: c.cef_rect_t) void {
    const had_last = d.has_last_bounds;
    const prev = d.last_bounds;
    viewsWindowRememberBounds(d, bounds);

    if (d.handle == 0) return;
    if (had_last and prev.x == bounds.x and prev.y == bounds.y and
        prev.width == bounds.width and prev.height == bounds.height)
    {
        return;
    }

    const x: f64 = @floatFromInt(bounds.x);
    const y: f64 = @floatFromInt(bounds.y);
    if (!had_last or prev.width != bounds.width or prev.height != bounds.height) {
        const width: f64 = @floatFromInt(bounds.width);
        const height: f64 = @floatFromInt(bounds.height);
        if (cef_window_lifecycle.g_window_resized_handler) |h| h(d.handle, x, y, width, height);
        return;
    }

    if (prev.x != bounds.x or prev.y != bounds.y) {
        if (cef_window_lifecycle.g_window_moved_handler) |h| h(d.handle, x, y);
    }
}

pub fn viewsWindowIsMinimized(window: *c.cef_window_t) bool {
    const is_minimized = window.is_minimized orelse return false;
    return is_minimized(window) != 0;
}

pub fn viewsWindowIsMaximized(window: *c.cef_window_t) bool {
    const is_maximized = window.is_maximized orelse return false;
    return is_maximized(window) != 0;
}

pub fn viewsWindowIsFullscreen(window: *c.cef_window_t) bool {
    const is_fullscreen = window.is_fullscreen orelse return false;
    return is_fullscreen(window) != 0;
}

pub fn cefColorFromHex(hex: []const u8) ?c.cef_color_t {
    if (hex.len < 7 or hex[0] != '#' or (hex.len != 7 and hex.len != 9)) return null;
    const r = std.fmt.parseInt(u8, hex[1..3], 16) catch return null;
    const g = std.fmt.parseInt(u8, hex[3..5], 16) catch return null;
    const b = std.fmt.parseInt(u8, hex[5..7], 16) catch return null;
    const a: u8 = if (hex.len == 9) std.fmt.parseInt(u8, hex[7..9], 16) catch return null else 255;
    return (@as(c.cef_color_t, a) << 24) |
        (@as(c.cef_color_t, r) << 16) |
        (@as(c.cef_color_t, g) << 8) |
        @as(c.cef_color_t, b);
}

pub fn viewsInitialBackgroundColor(appearance: window_mod.Appearance) ?c.cef_color_t {
    if (appearance.transparent) return 0;
    if (appearance.background_color) |hex| return cefColorFromHex(hex);
    return null;
}

pub fn applyViewsBackgroundColor(
    window: ?*c.cef_window_t,
    browser_view: ?*c.cef_browser_view_t,
    color: c.cef_color_t,
) void {
    if (window) |win| {
        if (win.base.base.set_background_color) |set_bg| set_bg(&win.base.base, color);
    }
    if (browser_view) |bv| {
        if (bv.base.set_background_color) |set_bg| set_bg(&bv.base, color);
    }
}
