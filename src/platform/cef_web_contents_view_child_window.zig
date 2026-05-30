//! macOS child-window WebContentsView path.
//! Keeps NSWindow attach/detach and child top-level CefWindow handling separate
//! from the generic WebContentsView vtable glue.

const builtin = @import("builtin");
const window_mod = @import("window");
const cef_views_delegate = @import("cef_views_delegate.zig");
const cef_initial_load = @import("cef_initial_load.zig");
const cef = @import("cef.zig");

const c = cef.c;
const is_macos = builtin.os.tag == .macos;

const releaseCefBase = cef_views_delegate.releaseCefBase;
const releaseBrowserViewRef = cef_views_delegate.releaseBrowserViewRef;
const releaseWindowRef = cef_views_delegate.releaseWindowRef;
const viewsWindowRememberBounds = cef_views_delegate.viewsWindowRememberBounds;
const viewsWindowIsMinimized = cef_views_delegate.viewsWindowIsMinimized;
const viewsWindowIsMaximized = cef_views_delegate.viewsWindowIsMaximized;
const createViewsBrowserDelegate = cef_views_delegate.createViewsBrowserDelegate;
const createViewsWindowDelegate = cef_views_delegate.createViewsWindowDelegate;

fn detach(self: *cef.CefNative, entry: *cef.CefNative.BrowserEntry) void {
    if (!comptime is_macos) return;
    const child_window = entry.child_ns_window orelse return;
    if (entry.child_window_parent_handle) |parent_handle| {
        if (self.browsers.get(parent_handle)) |parent_entry| {
            if (parent_entry.ns_window) |parent_window| {
                cef.detachMacChildWindow(parent_window, child_window);
            }
        }
    }
    cef.orderMacWindowOut(child_window);
    entry.child_window_visible = false;
}

pub fn close(self: *cef.CefNative, entry: *cef.CefNative.BrowserEntry) void {
    if (!comptime is_macos) return;
    if (entry.views_window != null) return;
    const child_window = entry.child_ns_window orelse return;
    detach(self, entry);
    cef.closeMacWindow(child_window);
    entry.child_ns_window = null;
    entry.child_window_parent_handle = null;
}

pub fn create(
    self: *cef.CefNative,
    host_handle: u64,
    host_entry: *cef.CefNative.BrowserEntry,
    opts: *const window_mod.CreateViewOptions,
) anyerror!u64 {
    if (!is_macos) return error.NotSupportedOnPlatform;
    const parent_window = host_entry.ns_window orelse return error.HostHasNoNSWindow;
    const child_frame = cef.childWindowFrameForBounds(parent_window, opts.bounds) orelse return error.NSViewAllocFailed;

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

    const browser_delegate = try createViewsBrowserDelegate(self.allocator);
    errdefer releaseCefBase(&browser_delegate.delegate.base.base);

    const browser_view = cef.asPtr(
        c.cef_browser_view_t,
        c.cef_browser_view_create(&self.client, &cef_url, &browser_settings, null, null, &browser_delegate.delegate),
    ) orelse return error.BrowserCreationFailed;
    var browser_view_owned_by_delegate = false;
    errdefer if (!browser_view_owned_by_delegate) releaseBrowserViewRef(browser_view);

    const child_opts: window_mod.CreateOptions = .{
        .title = "Suji WebContentsView",
        .url = opts.url,
        .bounds = .{
            .x = @intFromFloat(child_frame.x),
            .y = @intFromFloat(child_frame.y),
            .width = @intFromFloat(child_frame.width),
            .height = @intFromFloat(child_frame.height),
        },
        .appearance = .{ .frame = false },
        .constraints = .{ .resizable = false },
    };
    const window_delegate = try createViewsWindowDelegate(self.allocator, browser_view, &child_opts, null);
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
    const child_window = cef.cefViewsHandleToNSWindow(@ptrCast(views_window.get_window_handle.?(views_window))) orelse
        return error.HostHasNoNSWindow;
    cef.setMacWindowFrameRaw(child_window, child_frame);
    cef.msgSendVoidBool(child_window, "setHasShadow:", false);
    cef.setMacWindowTitle(child_window, "Suji WebContentsView");
    window_delegate.handle = handle;
    if (views_window.base.base.get_bounds) |get_bounds| {
        viewsWindowRememberBounds(window_delegate, get_bounds(&views_window.base.base));
    }
    window_delegate.last_minimized = viewsWindowIsMinimized(views_window);
    window_delegate.last_maximized = viewsWindowIsMaximized(views_window);

    var entry: cef.CefNative.BrowserEntry = .{
        .browser = br,
        .ns_window = null,
        .child_ns_window = child_window,
        .child_window_parent_handle = host_handle,
        .views_window = views_window,
        .browser_view = browser_view,
        .views_window_delegate = window_delegate,
        .views_browser_delegate = browser_delegate,
    };
    cef_initial_load.rememberInitialUrl(&entry, url_z);

    self.browsers.put(handle, entry) catch {
        views_window.close.?(views_window);
        return error.OutOfMemory;
    };

    cef.attachMacChildWindow(parent_window, child_window);
    cef.orderMacWindowFront(child_window);
    return handle;
}

pub fn destroy(self: *cef.CefNative, entry: *cef.CefNative.BrowserEntry) void {
    const child_window = entry.child_ns_window orelse return;
    detach(self, entry);
    if (entry.views_window) |views_window| {
        views_window.close.?(views_window);
        return;
    }
    entry.child_ns_window = null;
    entry.child_window_parent_handle = null;
    cef.closeMacWindow(child_window);
}

pub fn setBounds(self: *cef.CefNative, entry: cef.CefNative.BrowserEntry, bounds: window_mod.Bounds) void {
    const child_window = entry.child_ns_window orelse return;
    const parent_handle = entry.child_window_parent_handle orelse return;
    const parent_entry = self.browsers.get(parent_handle) orelse return;
    const parent_window = parent_entry.ns_window orelse return;
    const frame = cef.childWindowFrameForBounds(parent_window, bounds) orelse return;
    cef.setMacWindowFrameRaw(child_window, frame);
}

pub fn setVisible(self: *cef.CefNative, view_handle: u64, entry: cef.CefNative.BrowserEntry, visible: bool) void {
    const child_window = entry.child_ns_window orelse return;
    const parent_handle = entry.child_window_parent_handle orelse return;
    const parent_entry = self.browsers.get(parent_handle) orelse return;
    const parent_window = parent_entry.ns_window orelse return;
    if (visible) {
        cef.attachMacChildWindow(parent_window, child_window);
        cef.orderMacWindowFront(child_window);
    } else {
        cef.detachMacChildWindow(parent_window, child_window);
        cef.orderMacWindowOut(child_window);
    }
    if (self.browsers.getPtr(view_handle)) |mutable_entry| {
        mutable_entry.child_window_visible = visible;
    }
    const host = cef.asPtr(c.cef_browser_host_t, entry.browser.get_host.?(entry.browser));
    if (host) |h| h.was_hidden.?(h, if (visible) 0 else 1);
}

pub fn reorder(self: *cef.CefNative, host_handle: u64, entry: *cef.CefNative.BrowserEntry) void {
    const child_window = entry.child_ns_window orelse return;
    const host_entry = self.browsers.get(host_handle) orelse return;
    const parent_window = host_entry.ns_window orelse return;
    if (!entry.child_window_visible) {
        cef.orderMacWindowOut(child_window);
        return;
    }
    cef.detachMacChildWindow(parent_window, child_window);
    cef.attachMacChildWindow(parent_window, child_window);
    cef.orderMacWindowFront(child_window);
}
