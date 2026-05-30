//! Window creation vtable entry for CefNative.
//! Owns CEF Views and legacy CEF browser creation plus parent-window resolution.
const std = @import("std");
const builtin = @import("builtin");
const window_mod = @import("window");
const logger = @import("logger");
const cef = @import("cef.zig");
const cef_views_delegate = @import("cef_views_delegate.zig");
const cef_initial_load = @import("cef_initial_load.zig");
const cef_window_lifecycle = @import("cef_window_lifecycle.zig");

const c = cef.c;
const is_macos = builtin.os.tag == .macos;
const is_linux = builtin.os.tag == .linux;
const log = logger.module("cef");

const releaseCefBase = cef_views_delegate.releaseCefBase;
const releaseBrowserViewRef = cef_views_delegate.releaseBrowserViewRef;
const releaseWindowRef = cef_views_delegate.releaseWindowRef;
const viewsWindowRememberBounds = cef_views_delegate.viewsWindowRememberBounds;
const viewsWindowIsMinimized = cef_views_delegate.viewsWindowIsMinimized;
const viewsWindowIsMaximized = cef_views_delegate.viewsWindowIsMaximized;
const viewsWindowIsFullscreen = cef_views_delegate.viewsWindowIsFullscreen;
const createViewsBrowserDelegate = cef_views_delegate.createViewsBrowserDelegate;
const createViewsWindowDelegate = cef_views_delegate.createViewsWindowDelegate;
const rememberInitialUrl = cef_initial_load.rememberInitialUrl;
const forceInitialLoadUrl = cef_initial_load.forceInitialLoadUrl;
const scheduleInitialLoadRetries = cef_initial_load.scheduleInitialLoadRetries;

fn fromCtx(ctx: ?*anyopaque) *cef.CefNative {
    return @ptrCast(@alignCast(ctx.?));
}

fn assertUiThread() void {
    std.debug.assert(c.cef_currently_on(c.TID_UI) == 1);
}

fn createWindowWithCefViews(self: *cef.CefNative, opts: *const window_mod.CreateOptions) anyerror!u64 {
    var url_buf: [2048]u8 = undefined;
    const url_z: [:0]const u8 = if (opts.url) |u| blk: {
        if (u.len >= url_buf.len) return error.UrlTooLong;
        @memcpy(url_buf[0..u.len], u);
        url_buf[u.len] = 0;
        break :blk url_buf[0..u.len :0];
    } else self.default_url;

    var cef_url: c.cef_string_t = .{};
    cef.setUrlOrBlank(&cef_url, url_z);

    var browser_settings: c.cef_browser_settings_t = undefined;
    cef.zeroCefStruct(c.cef_browser_settings_t, &browser_settings);
    if (opts.appearance.transparent) browser_settings.background_color = 0;

    const browser_delegate = try createViewsBrowserDelegate(self.allocator);
    errdefer releaseCefBase(&browser_delegate.delegate.base.base);

    const browser_view = cef.asPtr(
        c.cef_browser_view_t,
        c.cef_browser_view_create(&self.client, &cef_url, &browser_settings, null, null, &browser_delegate.delegate),
    ) orelse return error.BrowserCreationFailed;
    var browser_view_owned_by_delegate = false;
    errdefer if (!browser_view_owned_by_delegate) releaseBrowserViewRef(browser_view);

    const parent_views_window: ?*c.cef_window_t = if (comptime is_linux) blk: {
        if (opts.parent_id) |pid| break :blk resolveParentViewsWindow(self, pid);
        break :blk null;
    } else null;

    const window_delegate = try createViewsWindowDelegate(self.allocator, browser_view, opts, parent_views_window);
    browser_view_owned_by_delegate = true;
    errdefer releaseCefBase(&window_delegate.delegate.base.base.base);

    const views_window = cef.asPtr(c.cef_window_t, c.cef_window_create_top_level(&window_delegate.delegate)) orelse
        return error.BrowserCreationFailed;
    errdefer releaseWindowRef(views_window);

    const br = browser_delegate.created_browser orelse blk: {
        const get_browser = browser_view.get_browser orelse return error.BrowserCreationFailed;
        break :blk cef.asPtr(c.cef_browser_t, get_browser(browser_view)) orelse return error.BrowserCreationFailed;
    };
    const handle: u64 = @intCast(br.get_identifier.?(br));
    const ns_window: ?*anyopaque = if (comptime is_macos)
        cef.cefViewsHandleToNSWindow(@ptrCast(views_window.get_window_handle.?(views_window)))
    else
        null;
    cef.applyCefViewsMacWindowOptions(ns_window, opts);
    window_delegate.handle = handle;
    if (views_window.base.base.get_bounds) |get_bounds| {
        viewsWindowRememberBounds(window_delegate, get_bounds(&views_window.base.base));
    }
    window_delegate.last_minimized = viewsWindowIsMinimized(views_window);
    window_delegate.last_maximized = viewsWindowIsMaximized(views_window);
    window_delegate.last_fullscreen = viewsWindowIsFullscreen(views_window);

    var entry: cef.CefNative.BrowserEntry = .{
        .browser = br,
        .ns_window = ns_window,
        .views_window = views_window,
        .browser_view = browser_view,
        .views_window_delegate = window_delegate,
        .views_browser_delegate = browser_delegate,
    };
    rememberInitialUrl(&entry, url_z);

    self.browsers.put(handle, entry) catch return error.OutOfMemory;

    // Do not attach Suji's NSWindowDelegate to CefWindow-owned windows.
    // CEF Views installs its own delegate/forwarding chain; replacing it
    // crashes during AppKit cursor/event forwarding. 17-B lifecycle events
    // must be emitted from CefWindowDelegate callbacks instead.
    if (opts.parent_id) |pid| {
        if (comptime is_macos) {
            if (resolveParentNSWindow(self, pid)) |parent_ns| {
                if (ns_window) |child_ns| cef.attachMacChildWindow(parent_ns, child_ns);
            }
        } else if (comptime is_linux) {
            if (parent_views_window == null) {
                log.warn("createWindow: parent_id={d} 해석 실패 — CEF Views parent attach 스킵", .{pid});
            }
        }
    }
    forceInitialLoadUrl(br, url_z);
    scheduleInitialLoadRetries(self.allocator, handle, url_z);
    return handle;
}

pub fn createWindow(ctx: ?*anyopaque, opts: *const window_mod.CreateOptions) anyerror!u64 {
    const self = fromCtx(ctx);
    assertUiThread();
    if (self.use_views) {
        return createWindowWithCefViews(self, opts);
    }

    var title_buf: [512]u8 = undefined;
    if (opts.title.len >= title_buf.len) return error.TitleTooLong;
    @memcpy(title_buf[0..opts.title.len], opts.title);
    title_buf[opts.title.len] = 0;
    const title_z: [:0]const u8 = title_buf[0..opts.title.len :0];

    var url_buf: [2048]u8 = undefined;
    const url_z: [:0]const u8 = if (opts.url) |u| blk: {
        if (u.len >= url_buf.len) return error.UrlTooLong;
        @memcpy(url_buf[0..u.len], u);
        url_buf[u.len] = 0;
        break :blk url_buf[0..u.len :0];
    } else self.default_url;

    var window_info: c.cef_window_info_t = undefined;
    cef.zeroCefStruct(c.cef_window_info_t, &window_info);
    window_info.runtime_style = c.CEF_RUNTIME_STYLE_ALLOY;
    window_info.bounds = .{
        .x = opts.bounds.x,
        .y = opts.bounds.y,
        .width = @intCast(opts.bounds.width),
        .height = @intCast(opts.bounds.height),
    };
    const ns_window = cef.initWindowInfo(&window_info, cef.WindowInitOpts{
        .title = title_z,
        .width = @intCast(opts.bounds.width),
        .height = @intCast(opts.bounds.height),
        .x = opts.bounds.x,
        .y = opts.bounds.y,
        .appearance = opts.appearance,
        .constraints = opts.constraints,
    });
    cef.setCefString(&window_info.window_name, title_z);

    var cef_url: c.cef_string_t = .{};
    cef.setUrlOrBlank(&cef_url, url_z);

    var browser_settings: c.cef_browser_settings_t = undefined;
    cef.zeroCefStruct(c.cef_browser_settings_t, &browser_settings);
    if (opts.appearance.transparent) browser_settings.background_color = 0;

    const browser = c.cef_browser_host_create_browser_sync(
        &window_info,
        &self.client,
        &cef_url,
        &browser_settings,
        null,
        null,
    );
    if (browser == null) return error.BrowserCreationFailed;
    const br: *c.cef_browser_t = @ptrCast(browser);

    const handle: u64 = @intCast(br.get_identifier.?(br));
    self.browsers.put(handle, .{ .browser = br, .ns_window = ns_window }) catch {
        const host = cef.asPtr(c.cef_browser_host_t, br.get_host.?(br));
        if (host) |h| h.close_browser.?(h, 1);
        return error.OutOfMemory;
    };

    cef_window_lifecycle.attachWindowLifecycle(ns_window, handle);

    if (comptime is_macos) {
        if (opts.parent_id) |pid| {
            if (resolveParentNSWindow(self, pid)) |parent_ns| {
                if (ns_window) |child_ns| cef.attachMacChildWindow(parent_ns, child_ns);
            } else {
                log.warn("createWindow: parent_id={d} 해석 실패 — attach 스킵", .{pid});
            }
        }
    }

    return handle;
}

fn resolveParentNSWindow(self: *cef.CefNative, parent_id: u32) ?*anyopaque {
    const wm = window_mod.WindowManager.global orelse return null;
    const parent_win = wm.get(parent_id) orelse return null;
    const parent_entry = self.browsers.get(parent_win.native_handle) orelse return null;
    return parent_entry.ns_window;
}

fn resolveParentViewsWindow(self: *cef.CefNative, parent_id: u32) ?*c.cef_window_t {
    const wm = window_mod.WindowManager.global orelse return null;
    const parent_win = wm.get(parent_id) orelse return null;
    const parent_entry = self.browsers.get(parent_win.native_handle) orelse return null;
    return parent_entry.views_window;
}
