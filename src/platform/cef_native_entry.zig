//! CefNative browser table entry types.

const cef = @import("cef.zig");
const drag_region = @import("cef_drag_region.zig");
const cef_views_delegate = @import("cef_views_delegate.zig");

const c = cef.c;

/// sender 창 URL 캐시 사이즈. 일반적인 URL은 < 200 byte, query string 포함해도
/// 256이면 충분. 초과 시 캐시는 비워두고 invoke 핫경로에서 frame.get_url로 폴백.
pub const URL_CACHE_LEN: usize = 256;

pub const BrowserEntry = struct {
    browser: *c.cef_browser_t,
    /// macOS: NSWindow 포인터 (destroyWindow에서 close 메시지 송신용).
    /// Linux/Windows: null (CEF가 자체 창 관리).
    /// CEF Views child WebContentsView는 별도 attached NSWindow라 child_ns_window에 set.
    ns_window: ?*anyopaque,
    /// Phase 17-B: CEF Views가 만든 child WebContentsView NSWindow.
    /// host NSWindow에 attach해서 한 창처럼 보이게 하되, browser lifecycle은
    /// child CefWindow가 관리한다.
    child_ns_window: ?*anyopaque = null,
    child_window_parent_handle: ?u64 = null,
    child_window_visible: bool = true,
    /// Phase 17-B: CEF Views top-level/child window.
    views_window: ?*c.cef_window_t = null,
    /// Main or child CefBrowserView. Top-level ownership is held by the
    /// window delegate; overlay views hold one entry-owned reference.
    browser_view: ?*c.cef_browser_view_t = null,
    /// Child WebContentsView overlay controller in a CefWindow host.
    overlay_controller: ?*c.cef_overlay_controller_t = null,
    views_window_delegate: ?*cef_views_delegate.ViewsWindowDelegate = null,
    views_browser_delegate: ?*cef_views_delegate.ViewsBrowserViewDelegate = null,
    views_parent_handle: ?u64 = null,
    /// 캐시된 main frame URL (OnAddressChange 콜백에서만 갱신).
    /// 매 invoke마다 frame.get_url alloc/free를 피하기 위함. len=0이면 미캐싱(폴백).
    url_cache_buf: [URL_CACHE_LEN]u8 = undefined,
    url_cache_len: usize = 0,
    /// CEF Views BrowserView can briefly commit about:blank before the
    /// requested startup URL is accepted. Keep the requested URL while the
    /// initial navigation is pending so delayed UI-thread retries do not
    /// overwrite a later, legitimate navigation.
    initial_url_buf: [2048]u8 = undefined,
    initial_url_len: usize = 0,
    initial_load_pending: bool = false,
    /// set_user_agent 로 적용한 UA override 보관(get_user_agent 가 반환).
    /// CEF 는 per-browser UA getter 미제공 -> 설정값을 inline 추적
    /// (url_cache 와 동일 패턴 — alloc/free 불필요). len=0=미설정(기본).
    ua_buf: [2048]u8 = undefined,
    ua_len: usize = 0,
    /// CEF가 계산한 `-webkit-app-region` rectangle들. browser id별로 보관하고
    /// macOS NSWindow.sendEvent:에서 native drag hit-test에 사용.
    drag_regions: []drag_region.DragRegion = &.{},
    /// `window:ready-to-show`는 main frame 첫 로드 완료시 1회만 발화 (Electron 호환).
    /// 이후 reload/navigate에서는 발화 X — caller는 `did-finish-load` 패턴이 필요하면
    /// load_url 응답을 직접 사용.
    ready_to_show_fired: bool = false,
    /// capture_page 용 DevTools observer 등록 핸들. 브라우저별 1회 lazy
    /// 등록 후 보관(살아있어야 observer 유지 — CEF 가 registration 소멸
    /// 시 자동 해제). 브라우저 제거 시 release.
    devtools_reg: ?*c.cef_registration_t = null,
};
