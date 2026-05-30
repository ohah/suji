//! CEF Views WebContentsView overlay path.
//! Creation and overlay-specific bounds/visibility/z-order operations live here.

const window_mod = @import("window");
const cef_views_delegate = @import("cef_views_delegate.zig");
const cef_initial_load = @import("cef_initial_load.zig");
const cef = @import("cef.zig");

const c = cef.c;
const releaseCefBase = cef_views_delegate.releaseCefBase;
const releaseBrowserViewRef = cef_views_delegate.releaseBrowserViewRef;
const releaseOverlayRef = cef_views_delegate.releaseOverlayRef;
const createViewsBrowserDelegate = cef_views_delegate.createViewsBrowserDelegate;

pub fn create(
    self: *cef.CefNative,
    host_handle: u64,
    host_entry: *cef.CefNative.BrowserEntry,
    opts: *const window_mod.CreateViewOptions,
) anyerror!u64 {
    const host_window = host_entry.views_window orelse return error.HostHasNoViewsWindow;

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
    errdefer releaseBrowserViewRef(browser_view);

    var rect: c.cef_rect_t = .{
        .x = opts.bounds.x,
        .y = opts.bounds.y,
        .width = @intCast(opts.bounds.width),
        .height = @intCast(opts.bounds.height),
    };
    if (browser_view.base.base.add_ref) |add_ref| add_ref(&browser_view.base.base);
    errdefer releaseBrowserViewRef(browser_view);
    const overlay = cef.asPtr(
        c.cef_overlay_controller_t,
        host_window.add_overlay_view.?(host_window, &browser_view.base, c.CEF_DOCKING_MODE_CUSTOM, 0),
    ) orelse return error.BrowserCreationFailed;
    errdefer releaseOverlayRef(overlay);
    overlay.set_bounds.?(overlay, &rect);
    overlay.set_visible.?(overlay, 1);

    const br = browser_delegate.created_browser orelse blk: {
        const get_browser = browser_view.get_browser orelse return error.BrowserCreationFailed;
        break :blk cef.asPtr(c.cef_browser_t, get_browser(browser_view)) orelse return error.BrowserCreationFailed;
    };
    const handle: u64 = @intCast(br.get_identifier.?(br));

    var entry: cef.CefNative.BrowserEntry = .{
        .browser = br,
        .ns_window = null,
        .browser_view = browser_view,
        .overlay_controller = overlay,
        .views_browser_delegate = browser_delegate,
        .views_parent_handle = host_handle,
    };
    cef_initial_load.rememberInitialUrl(&entry, url_z);

    self.browsers.put(handle, entry) catch return error.OutOfMemory;
    return handle;
}

pub fn destroy(entry: *cef.CefNative.BrowserEntry) void {
    const overlay = entry.overlay_controller orelse return;
    overlay.set_visible.?(overlay, 0);
    overlay.destroy.?(overlay);
    const br = entry.browser;
    const host = cef.asPtr(c.cef_browser_host_t, br.get_host.?(br));
    if (host) |h| h.close_browser.?(h, 1);
}

pub fn setBounds(entry: cef.CefNative.BrowserEntry, bounds: window_mod.Bounds) void {
    const overlay = entry.overlay_controller orelse return;
    var rect: c.cef_rect_t = .{
        .x = bounds.x,
        .y = bounds.y,
        .width = @intCast(bounds.width),
        .height = @intCast(bounds.height),
    };
    overlay.set_bounds.?(overlay, &rect);
}

pub fn setVisible(entry: cef.CefNative.BrowserEntry, visible: bool) void {
    const overlay = entry.overlay_controller orelse return;
    overlay.set_visible.?(overlay, if (visible) 1 else 0);
    const host = cef.asPtr(c.cef_browser_host_t, entry.browser.get_host.?(entry.browser));
    if (host) |h| h.was_hidden.?(h, if (visible) 0 else 1);
}

pub fn reorder(self: *cef.CefNative, host_handle: u64, entry: *cef.CefNative.BrowserEntry) void {
    const overlay = entry.overlay_controller orelse return;
    const host_entry = self.browsers.get(host_handle) orelse return;
    const host_window = host_entry.views_window orelse return;
    const browser_view = entry.browser_view orelse return;
    const bounds = overlay.get_bounds.?(overlay);
    const visible = overlay.is_visible.?(overlay);

    overlay.destroy.?(overlay);
    releaseOverlayRef(overlay);
    entry.overlay_controller = null;

    if (browser_view.base.base.add_ref) |add_ref| add_ref(&browser_view.base.base);
    const replacement = cef.asPtr(
        c.cef_overlay_controller_t,
        host_window.add_overlay_view.?(host_window, &browser_view.base, c.CEF_DOCKING_MODE_CUSTOM, 0),
    ) orelse {
        releaseBrowserViewRef(browser_view);
        return;
    };
    entry.overlay_controller = replacement;
    var rect = bounds;
    replacement.set_bounds.?(replacement, &rect);
    replacement.set_visible.?(replacement, visible);
}
