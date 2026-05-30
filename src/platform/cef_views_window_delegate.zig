//! CEF Views Window delegate.
//! CefWindowDelegate ref-counting, lifecycle/bounds callbacks, and
//! Views-owned window option application.

const std = @import("std");
const window_mod = @import("window");
const cef_window_options = @import("cef_window_options.zig");
const cef_window_lifecycle = @import("cef_window_lifecycle.zig");
const cef_views_window_delegate_state = @import("cef_views_window_delegate_state.zig");
const cef = @import("cef.zig");

const c = cef.c;
const asPtr = cef.asPtr;
const setCefString = cef.setCefString;

pub const ViewsWindowDelegate = cef_views_window_delegate_state.ViewsWindowDelegate;
pub const releaseCefBase = cef_views_window_delegate_state.releaseCefBase;
pub const releaseBrowserViewRef = cef_views_window_delegate_state.releaseBrowserViewRef;
pub const releaseWindowRef = cef_views_window_delegate_state.releaseWindowRef;
pub const releaseOverlayRef = cef_views_window_delegate_state.releaseOverlayRef;
pub const viewsWindowRememberBounds = cef_views_window_delegate_state.viewsWindowRememberBounds;
pub const viewsWindowEmitBoundsChanged = cef_views_window_delegate_state.viewsWindowEmitBoundsChanged;
pub const viewsWindowIsMinimized = cef_views_window_delegate_state.viewsWindowIsMinimized;
pub const viewsWindowIsMaximized = cef_views_window_delegate_state.viewsWindowIsMaximized;
pub const viewsWindowIsFullscreen = cef_views_window_delegate_state.viewsWindowIsFullscreen;
pub const cefColorFromHex = cef_views_window_delegate_state.cefColorFromHex;
pub const applyViewsBackgroundColor = cef_views_window_delegate_state.applyViewsBackgroundColor;

const viewsWindowFromBase = cef_views_window_delegate_state.viewsWindowFromBase;
const viewsWindowFromSelf = cef_views_window_delegate_state.viewsWindowFromSelf;
const viewsWindowFromViewDelegate = cef_views_window_delegate_state.viewsWindowFromViewDelegate;
const retainWindowRef = cef_views_window_delegate_state.retainWindowRef;
const viewsInitialBackgroundColor = cef_views_window_delegate_state.viewsInitialBackgroundColor;
const views_native_window_options_platform = cef_views_window_delegate_state.views_native_window_options_platform;

fn viewsWindowAddRef(base: ?*c.cef_base_ref_counted_t) callconv(.c) void {
    const d = viewsWindowFromBase(base) orelse return;
    _ = d.ref_count.fetchAdd(1, .acq_rel);
}

fn viewsWindowRelease(base: ?*c.cef_base_ref_counted_t) callconv(.c) i32 {
    const d = viewsWindowFromBase(base) orelse return 0;
    if (d.ref_count.fetchSub(1, .acq_rel) != 1) return 0;
    releaseBrowserViewRef(d.browser_view);
    d.browser_view = null;
    releaseWindowRef(d.parent_window);
    d.parent_window = null;
    d.allocator.destroy(d);
    return 1;
}

fn viewsWindowHasOneRef(base: ?*c.cef_base_ref_counted_t) callconv(.c) i32 {
    const d = viewsWindowFromBase(base) orelse return 0;
    return if (d.ref_count.load(.acquire) == 1) 1 else 0;
}

fn viewsWindowHasAtLeastOneRef(base: ?*c.cef_base_ref_counted_t) callconv(.c) i32 {
    const d = viewsWindowFromBase(base) orelse return 0;
    return if (d.ref_count.load(.acquire) >= 1) 1 else 0;
}

fn viewsWindowPreferredSize(
    self: ?*c._cef_view_delegate_t,
    view: ?*c._cef_view_t,
) callconv(.c) c.cef_size_t {
    const d = viewsWindowFromViewDelegate(self) orelse return .{ .width = 800, .height = 600 };
    if (view) |v| releaseCefBase(&v.base);
    return .{ .width = @intCast(d.bounds.width), .height = @intCast(d.bounds.height) };
}

fn viewsWindowMinimumSize(
    self: ?*c._cef_view_delegate_t,
    view: ?*c._cef_view_t,
) callconv(.c) c.cef_size_t {
    const d = viewsWindowFromViewDelegate(self) orelse return .{ .width = 0, .height = 0 };
    if (view) |v| releaseCefBase(&v.base);
    return .{
        .width = @intCast(d.constraints.min_width),
        .height = @intCast(d.constraints.min_height),
    };
}

fn viewsWindowMaximumSize(
    self: ?*c._cef_view_delegate_t,
    view: ?*c._cef_view_t,
) callconv(.c) c.cef_size_t {
    const d = viewsWindowFromViewDelegate(self) orelse return .{ .width = 0, .height = 0 };
    if (view) |v| releaseCefBase(&v.base);
    return .{
        .width = @intCast(d.constraints.max_width),
        .height = @intCast(d.constraints.max_height),
    };
}

fn viewsWindowInitialBounds(
    self: ?*c._cef_window_delegate_t,
    window: ?*c._cef_window_t,
) callconv(.c) c.cef_rect_t {
    const d = viewsWindowFromSelf(self) orelse return .{ .x = 0, .y = 0, .width = 800, .height = 600 };
    releaseWindowRef(@ptrCast(window));
    const bounds: c.cef_rect_t = .{
        .x = d.bounds.x,
        .y = d.bounds.y,
        .width = @intCast(d.bounds.width),
        .height = @intCast(d.bounds.height),
    };
    viewsWindowRememberBounds(d, bounds);
    return bounds;
}

fn viewsWindowInitialShowState(
    self: ?*c._cef_window_delegate_t,
    window: ?*c._cef_window_t,
) callconv(.c) c.cef_show_state_t {
    _ = self;
    releaseWindowRef(@ptrCast(window));
    return c.CEF_SHOW_STATE_NORMAL;
}

fn viewsWindowIsFrameless(
    self: ?*c._cef_window_delegate_t,
    window: ?*c._cef_window_t,
) callconv(.c) i32 {
    const d = viewsWindowFromSelf(self) orelse return 0;
    releaseWindowRef(@ptrCast(window));
    return if (cef_window_options.viewsFrameless(d.appearance.frame, d.appearance.transparent)) 1 else 0;
}

fn viewsWindowStandardButtons(
    self: ?*c._cef_window_delegate_t,
    window: ?*c._cef_window_t,
) callconv(.c) i32 {
    const d = viewsWindowFromSelf(self) orelse return 1;
    releaseWindowRef(@ptrCast(window));
    return if (cef_window_options.viewsStandardButtons(d.appearance.frame, d.appearance.transparent)) 1 else 0;
}

fn viewsWindowCanResize(
    self: ?*c._cef_window_delegate_t,
    window: ?*c._cef_window_t,
) callconv(.c) i32 {
    const d = viewsWindowFromSelf(self) orelse return 1;
    releaseWindowRef(@ptrCast(window));
    return if (cef_window_options.viewsCanResize(d.constraints.resizable)) 1 else 0;
}

fn viewsWindowCanMaximize(
    self: ?*c._cef_window_delegate_t,
    window: ?*c._cef_window_t,
) callconv(.c) i32 {
    const d = viewsWindowFromSelf(self) orelse return 1;
    releaseWindowRef(@ptrCast(window));
    return if (d.constraints.resizable) 1 else 0;
}

fn viewsWindowCanMinimize(_: ?*c._cef_window_delegate_t, window: ?*c._cef_window_t) callconv(.c) i32 {
    releaseWindowRef(@ptrCast(window));
    return 1;
}

fn viewsWindowGetParentWindow(
    self: ?*c._cef_window_delegate_t,
    window: ?*c._cef_window_t,
    is_menu: ?*c_int,
    can_activate_menu: ?*c_int,
) callconv(.c) ?*c._cef_window_t {
    const d = viewsWindowFromSelf(self) orelse {
        releaseWindowRef(@ptrCast(window));
        return null;
    };
    releaseWindowRef(@ptrCast(window));
    if (is_menu) |ptr| ptr.* = 0;
    if (can_activate_menu) |ptr| ptr.* = 1;
    const parent = d.parent_window orelse return null;
    _ = retainWindowRef(parent);
    return parent;
}

fn viewsWindowIsModalDialog(_: ?*c._cef_window_delegate_t, window: ?*c._cef_window_t) callconv(.c) i32 {
    releaseWindowRef(@ptrCast(window));
    return 0;
}

fn viewsWindowAcceptsFirstMouse(_: ?*c._cef_window_delegate_t, window: ?*c._cef_window_t) callconv(.c) c.cef_state_t {
    releaseWindowRef(@ptrCast(window));
    return c.STATE_ENABLED;
}

fn viewsWindowCanClose(
    self: ?*c._cef_window_delegate_t,
    window: ?*c._cef_window_t,
) callconv(.c) i32 {
    const d = viewsWindowFromSelf(self) orelse {
        releaseWindowRef(@ptrCast(window));
        return 1;
    };
    var can_close: i32 = 1;
    if (d.browser_view) |bv| {
        if (bv.get_browser) |get_browser| {
            if (asPtr(c.cef_browser_t, get_browser(bv))) |browser| {
                if (asPtr(c.cef_browser_host_t, browser.get_host.?(browser))) |host| {
                    can_close = host.try_close_browser.?(host);
                    releaseCefBase(&host.base);
                }
                releaseCefBase(&browser.base);
            }
        }
    }
    releaseWindowRef(@ptrCast(window));
    return can_close;
}

fn viewsWindowRuntimeStyle(_: ?*c._cef_window_delegate_t) callconv(.c) c.cef_runtime_style_t {
    return c.CEF_RUNTIME_STYLE_ALLOY;
}

fn viewsWindowActivationChanged(
    self: ?*c._cef_window_delegate_t,
    window: ?*c._cef_window_t,
    active: c_int,
) callconv(.c) void {
    const d = viewsWindowFromSelf(self) orelse {
        releaseWindowRef(@ptrCast(window));
        return;
    };
    releaseWindowRef(@ptrCast(window));
    if (d.handle == 0) return;
    if (active != 0) {
        if (cef_window_lifecycle.g_window_focus_handler) |h| h(d.handle);
    } else {
        if (cef_window_lifecycle.g_window_blur_handler) |h| h(d.handle);
    }
}

fn viewsWindowBoundsChanged(
    self: ?*c._cef_window_delegate_t,
    window: ?*c._cef_window_t,
    new_bounds: ?*const c.cef_rect_t,
) callconv(.c) void {
    const d = viewsWindowFromSelf(self) orelse {
        releaseWindowRef(@ptrCast(window));
        return;
    };
    const win: *c.cef_window_t = @ptrCast(window orelse return);
    defer releaseWindowRef(win);
    // new_bounds 가 null 이면 CEF teardown 중 — vtable 호출 위험하니 state 체크 스킵.
    const bounds = new_bounds orelse return;
    // OS-initiated minimize/maximize/restore 감지 — CEF window 의 is_minimized
    // /is_maximized 가 bounds-change 직전에 변경된다. delegate 의 last_* 와 비교해
    // transition 만 이벤트 발화. SDK 호출(minimizeImpl 등)은 별도로 가드되어 중복
    // 방지된다(handle == 0 이거나 last_* 가 already-set).
    if (d.handle != 0) {
        const is_min = viewsWindowIsMinimized(win);
        const is_max = viewsWindowIsMaximized(win);
        if (is_min and !d.last_minimized) {
            d.last_minimized = true;
            d.last_maximized = false;
            if (cef_window_lifecycle.g_window_minimize_handler) |h| h(d.handle);
        } else if (!is_min and d.last_minimized) {
            d.last_minimized = false;
            if (cef_window_lifecycle.g_window_restore_handler) |h| h(d.handle);
        }
        if (is_max and !d.last_maximized and !is_min) {
            d.last_maximized = true;
            if (cef_window_lifecycle.g_window_maximize_handler) |h| h(d.handle);
        } else if (!is_max and d.last_maximized and !is_min) {
            d.last_maximized = false;
            if (cef_window_lifecycle.g_window_unmaximize_handler) |h| h(d.handle);
        }
    }
    viewsWindowEmitBoundsChanged(d, bounds.*);
}

fn viewsWindowFullscreenTransition(
    self: ?*c._cef_window_delegate_t,
    window: ?*c._cef_window_t,
    is_completed: c_int,
) callconv(.c) void {
    const d = viewsWindowFromSelf(self) orelse {
        releaseWindowRef(@ptrCast(window));
        return;
    };
    const win: *c.cef_window_t = @ptrCast(window orelse return);
    defer releaseWindowRef(win);
    if (is_completed == 0) return;

    const is_fullscreen = viewsWindowIsFullscreen(win);
    if (is_fullscreen == d.last_fullscreen) return;
    d.last_fullscreen = is_fullscreen;
    if (d.handle == 0) return;

    if (is_fullscreen) {
        if (cef_window_lifecycle.g_window_enter_fullscreen_handler) |h| h(d.handle);
    } else {
        if (cef_window_lifecycle.g_window_leave_fullscreen_handler) |h| h(d.handle);
    }
}

fn viewsWindowOnCreated(self: ?*c._cef_window_delegate_t, window: ?*c._cef_window_t) callconv(.c) void {
    const d = viewsWindowFromSelf(self) orelse return;
    const win: *c.cef_window_t = @ptrCast(window orelse return);

    if (win.base.base.base.add_ref) |add_ref| add_ref(&win.base.base.base);
    d.cef_window = win;
    d.last_minimized = viewsWindowIsMinimized(win);
    d.last_maximized = viewsWindowIsMaximized(win);
    d.last_fullscreen = viewsWindowIsFullscreen(win);

    const bg_color = if (comptime views_native_window_options_platform) viewsInitialBackgroundColor(d.appearance) else null;
    if (bg_color) |color| applyViewsBackgroundColor(win, d.browser_view, color);

    if (d.browser_view) |bv| {
        if (bv.base.base.add_ref) |add_ref| add_ref(&bv.base.base);
        if (win.base.set_to_fill_layout) |set_fill| _ = set_fill(&win.base);
        win.base.add_child_view.?(&win.base, &bv.base);
    }

    if (d.title_len > 0) {
        var title: c.cef_string_t = .{};
        setCefString(&title, d.title_buf[0..d.title_len]);
        win.set_title.?(win, &title);
    }
    if (d.constraints.always_on_top) win.set_always_on_top.?(win, 1);
    win.show.?(win);
    if (d.constraints.fullscreen) win.set_fullscreen.?(win, 1);

    releaseWindowRef(win);
}

fn viewsWindowOnDestroyed(self: ?*c._cef_window_delegate_t, window: ?*c._cef_window_t) callconv(.c) void {
    const d = viewsWindowFromSelf(self) orelse {
        releaseWindowRef(@ptrCast(window));
        return;
    };
    releaseWindowRef(d.cef_window);
    d.cef_window = null;
    releaseWindowRef(@ptrCast(window));
}

fn viewsWindowOnClosing(_: ?*c._cef_window_delegate_t, window: ?*c._cef_window_t) callconv(.c) void {
    releaseWindowRef(@ptrCast(window));
}

pub fn createViewsWindowDelegate(
    allocator: std.mem.Allocator,
    browser_view: *c.cef_browser_view_t,
    opts: *const window_mod.CreateOptions,
    parent_window: ?*c.cef_window_t,
) !*ViewsWindowDelegate {
    const d = try allocator.create(ViewsWindowDelegate);
    d.* = .{
        .allocator = allocator,
        .browser_view = browser_view,
        .parent_window = retainWindowRef(parent_window),
        .bounds = opts.bounds,
        .appearance = opts.appearance,
        .constraints = opts.constraints,
    };
    @memset(std.mem.asBytes(&d.delegate), 0);
    d.delegate.base.base.base.size = @sizeOf(c.cef_window_delegate_t);
    d.delegate.base.base.base.add_ref = &viewsWindowAddRef;
    d.delegate.base.base.base.release = &viewsWindowRelease;
    d.delegate.base.base.base.has_one_ref = &viewsWindowHasOneRef;
    d.delegate.base.base.base.has_at_least_one_ref = &viewsWindowHasAtLeastOneRef;
    d.delegate.on_window_created = &viewsWindowOnCreated;
    d.delegate.on_window_closing = &viewsWindowOnClosing;
    d.delegate.on_window_destroyed = &viewsWindowOnDestroyed;
    d.delegate.on_window_activation_changed = &viewsWindowActivationChanged;
    d.delegate.on_window_bounds_changed = &viewsWindowBoundsChanged;
    d.delegate.on_window_fullscreen_transition = &viewsWindowFullscreenTransition;
    d.delegate.get_initial_bounds = &viewsWindowInitialBounds;
    d.delegate.get_initial_show_state = &viewsWindowInitialShowState;
    d.delegate.is_frameless = &viewsWindowIsFrameless;
    d.delegate.with_standard_window_buttons = &viewsWindowStandardButtons;
    d.delegate.can_resize = &viewsWindowCanResize;
    d.delegate.can_maximize = &viewsWindowCanMaximize;
    d.delegate.can_minimize = &viewsWindowCanMinimize;
    d.delegate.get_parent_window = &viewsWindowGetParentWindow;
    d.delegate.is_window_modal_dialog = &viewsWindowIsModalDialog;
    d.delegate.accepts_first_mouse = &viewsWindowAcceptsFirstMouse;
    d.delegate.can_close = &viewsWindowCanClose;
    d.delegate.get_window_runtime_style = &viewsWindowRuntimeStyle;
    d.delegate.base.base.get_preferred_size = &viewsWindowPreferredSize;
    d.delegate.base.base.get_minimum_size = &viewsWindowMinimumSize;
    d.delegate.base.base.get_maximum_size = &viewsWindowMaximumSize;

    const n = @min(opts.title.len, d.title_buf.len);
    @memcpy(d.title_buf[0..n], opts.title[0..n]);
    d.title_len = n;
    return d;
}
