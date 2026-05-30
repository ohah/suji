//! CEF browser-process global browser/client state — cef.zig 에서 분리(동작 무변경).
//! Main browser tracking, shared DevTools client, and global handler bootstrap live here.
const cef = @import("cef.zig");
const cef_drag_handler = @import("cef_drag_handler.zig");
const cef_keyboard_handler = @import("cef_keyboard_handler.zig");
const cef_life_span_handler = @import("cef_life_span_handler.zig");

const c = cef.c;
const initBaseRefCounted = cef.initBaseRefCounted;
const zeroCefStruct = cef.zeroCefStruct;

var g_devtools_client: c.cef_client_t = undefined;
var g_browser: ?*c.cef_browser_t = null; // 브라우저 참조 (이벤트 푸시용)

pub fn devtoolsClient() *c.cef_client_t {
    return &g_devtools_client;
}

pub fn currentBrowser() ?*c.cef_browser_t {
    return g_browser;
}

pub fn rememberMainBrowserIfUnset(browser: *c.cef_browser_t) void {
    if (g_browser == null) g_browser = browser;
}

pub fn isMainBrowser(browser: *c.cef_browser_t) bool {
    if (g_browser) |main_br| {
        return browser.get_identifier.?(browser) == main_br.get_identifier.?(main_br);
    }
    return true;
}

/// CEF process_message 페이로드 버퍼 한도 (renderer ↔ browser IPC). Clipboard write_text 같은
/// 큰 payload(최대 16KB text + JSON escape overhead)를 수용. 이전엔 8192라 8KB 텍스트도
/// 잘려 응답 undefined.
pub const CEF_IPC_BUF_LEN: usize = 65536;

/// 전역 CEF 핸들러 초기화 (idempotent). CefNative.init에서 호출.
/// life_span_handler / keyboard_handler / devtools client — 모든 브라우저가 공유.
var g_handlers_initialized: bool = false;
pub fn ensureGlobalHandlers() void {
    if (g_handlers_initialized) return;
    cef_life_span_handler.initLifeSpanHandler();
    cef_keyboard_handler.initKeyboardHandler();
    cef_drag_handler.initDragHandler();
    zeroCefStruct(c.cef_client_t, &g_devtools_client);
    initBaseRefCounted(&g_devtools_client.base);
    g_devtools_client.get_keyboard_handler = &cef_keyboard_handler.getKeyboardHandler;
    g_devtools_client.get_drag_handler = &cef_drag_handler.getDragHandler;
    // life_span_handler — DevTools browser의 onAfterCreated/onBeforeClose 콜백.
    // 없으면 DevTools browser 생성/소멸이 우리에게 안 보여 inspectee 매핑 등록/정리 X.
    g_devtools_client.get_life_span_handler = &cef_life_span_handler.getLifeSpanHandler;
    g_handlers_initialized = true;
}
