//! CefNative-owned CEF ref-counted object release helpers.

const cef = @import("cef.zig");
const cef_views_delegate = @import("cef_views_delegate.zig");

const c = cef.c;

pub fn releaseReg(reg_opt: ?*c.cef_registration_t) void {
    const reg = reg_opt orelse return;
    if (reg.base.release) |rel| _ = rel(&reg.base);
}

pub fn releaseDevToolsReg(entry: *cef.CefNative.BrowserEntry) void {
    releaseReg(entry.devtools_reg);
    entry.devtools_reg = null;
}

pub fn releaseViewsEntry(entry: *cef.CefNative.BrowserEntry) void {
    if (entry.overlay_controller) |overlay| {
        cef_views_delegate.releaseOverlayRef(overlay);
        entry.overlay_controller = null;
    }
    if (entry.views_window) |views_window| {
        cef_views_delegate.releaseWindowRef(views_window);
        entry.views_window = null;
    }
    if (entry.views_window_delegate) |delegate| {
        cef_views_delegate.releaseCefBase(&delegate.delegate.base.base.base);
        entry.views_window_delegate = null;
    } else if (entry.browser_view) |browser_view| {
        cef_views_delegate.releaseBrowserViewRef(browser_view);
    }
    entry.browser_view = null;
    if (entry.views_browser_delegate) |delegate| {
        cef_views_delegate.releaseCefBase(&delegate.delegate.base.base);
        entry.views_browser_delegate = null;
    }
}
