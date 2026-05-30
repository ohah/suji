//! Browser-level navigation, JavaScript dispatch, and zoom helpers.

const window_mod = @import("window");
const cef = @import("cef.zig");
const cef_web_contents = @import("cef_web_contents.zig");

const c = cef.c;

pub fn navigate(url: [:0]const u8) void {
    const browser = cef.currentBrowser() orelse return;
    const frame = cef.asPtr(c.cef_frame_t, browser.get_main_frame.?(browser)) orelse return;
    var cef_url: c.cef_string_t = .{};
    cef.setCefString(&cef_url, url);
    frame.load_url.?(frame, &cef_url);
}

/// Execute JavaScript from the main process into renderer windows.
/// target=null broadcasts to all live browsers; target=winId dispatches only to
/// the WindowManager entry with that id. Missing mappings are silent no-ops.
pub fn evalJs(target: ?u32, js: [:0]const u8) void {
    const native = cef.globalNative() orelse {
        if (cef.currentBrowser()) |br| cef_web_contents.evalJsOnBrowser(br, js);
        return;
    };
    if (target) |win_id| {
        const wm = window_mod.WindowManager.global orelse return;
        const win = wm.get(win_id) orelse return;
        const entry = native.browsers.get(win.native_handle) orelse return;
        cef_web_contents.evalJsOnBrowser(entry.browser, js);
        return;
    }
    var it = native.browsers.valueIterator();
    while (it.next()) |entry| {
        cef_web_contents.evalJsOnBrowser(entry.browser, js);
    }
}

pub fn zoomChange(browser: *c.cef_browser_t, delta: f64) void {
    const host = cef.asPtr(c.cef_browser_host_t, browser.get_host.?(browser)) orelse return;
    const current = host.get_zoom_level.?(host);
    host.set_zoom_level.?(host, current + delta);
}

pub fn zoomSet(browser: *c.cef_browser_t, level: f64) void {
    const host = cef.asPtr(c.cef_browser_host_t, browser.get_host.?(browser)) orelse return;
    host.set_zoom_level.?(host, level);
}
