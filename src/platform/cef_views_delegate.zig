//! CEF Views delegate facade.
//! BrowserView and Window delegates live in sibling modules; this file keeps
//! existing `cef_views_delegate.*` imports stable.

const cef_views_browser_delegate = @import("cef_views_browser_delegate.zig");
const cef_views_window_delegate = @import("cef_views_window_delegate.zig");

pub const ViewsBrowserViewDelegate = cef_views_browser_delegate.ViewsBrowserViewDelegate;
pub const createViewsBrowserDelegate = cef_views_browser_delegate.createViewsBrowserDelegate;

pub const ViewsWindowDelegate = cef_views_window_delegate.ViewsWindowDelegate;
pub const releaseCefBase = cef_views_window_delegate.releaseCefBase;
pub const releaseBrowserViewRef = cef_views_window_delegate.releaseBrowserViewRef;
pub const releaseWindowRef = cef_views_window_delegate.releaseWindowRef;
pub const releaseOverlayRef = cef_views_window_delegate.releaseOverlayRef;
pub const viewsWindowRememberBounds = cef_views_window_delegate.viewsWindowRememberBounds;
pub const viewsWindowEmitBoundsChanged = cef_views_window_delegate.viewsWindowEmitBoundsChanged;
pub const viewsWindowIsMinimized = cef_views_window_delegate.viewsWindowIsMinimized;
pub const viewsWindowIsMaximized = cef_views_window_delegate.viewsWindowIsMaximized;
pub const viewsWindowIsFullscreen = cef_views_window_delegate.viewsWindowIsFullscreen;
pub const cefColorFromHex = cef_views_window_delegate.cefColorFromHex;
pub const applyViewsBackgroundColor = cef_views_window_delegate.applyViewsBackgroundColor;
pub const createViewsWindowDelegate = cef_views_window_delegate.createViewsWindowDelegate;
