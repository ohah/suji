//! Window display/load/find/print handlers — cef.zig 에서 분리(동작 무변경).
//! URL/title cache, ready-to-show, find-result, and PDF paper-size callbacks.
const std = @import("std");
const cef_pdf_print = @import("cef_pdf_print.zig");
const cef = @import("cef.zig");

const c = cef.c;
const zeroCefStruct = cef.zeroCefStruct;
const initBaseRefCounted = cef.initBaseRefCounted;
const cefStringToUtf8 = cef.cefStringToUtf8;

// ============================================
// CEF Display Handler — URL 변경 콜백 (캐싱용)
// ============================================

var g_display_handler: c.cef_display_handler_t = undefined;
var g_display_handler_initialized: bool = false;

fn ensureDisplayHandler() void {
    if (g_display_handler_initialized) return;
    zeroCefStruct(c.cef_display_handler_t, &g_display_handler);
    initBaseRefCounted(&g_display_handler.base);
    g_display_handler.on_address_change = &onAddressChange;
    g_display_handler.on_title_change = &onTitleChange;
    g_display_handler_initialized = true;
}

pub fn getDisplayHandler(_: ?*c._cef_client_t) callconv(.c) ?*c._cef_display_handler_t {
    ensureDisplayHandler();
    return &g_display_handler;
}

/// main frame URL이 바뀔 때 BrowserEntry.url_cache 갱신.
/// invoke 핫경로의 frame.get_url alloc/free 1회를 절약. iframe 변경은 무시 (main만 캐싱).
fn onAddressChange(
    _: ?*c._cef_display_handler_t,
    browser: ?*c._cef_browser_t,
    frame: ?*c._cef_frame_t,
    url: [*c]const c.cef_string_t,
) callconv(.c) void {
    const br = browser orelse return;
    const f = frame orelse return;
    const u = url orelse return;
    // main frame만 캐싱 — iframe URL은 sender 식별과 무관.
    const is_main = if (f.is_main) |fn_ptr| fn_ptr(f) == 1 else false;
    if (!is_main) return;

    const native = cef.globalNative() orelse return;
    const handle: u64 = @intCast(br.get_identifier.?(br));
    const entry = native.browsers.getPtr(handle) orelse return;

    const utf8_len = cefStringToUtf8(u, &entry.url_cache_buf).len;
    // 256 byte 초과 URL은 캐시 무효화 → 폴백 (frame.get_url) 사용.
    entry.url_cache_len = if (utf8_len > 0 and utf8_len < entry.url_cache_buf.len) utf8_len else 0;
    const current = entry.url_cache_buf[0..utf8_len];
    if (current.len > 0 and !cef.isAboutBlankUrl(current)) {
        entry.initial_load_pending = false;
    }
}

/// 문서 `<title>` 최대 길이 (UTF-8 바이트). 초과 시 cefStringToUtf8가 truncate.
/// main.zig의 windowTitleChangeHandler가 이 상수에서 자체 escape 버퍼(`MAX_TITLE_BYTES * 6 + 64`)
/// 를 도출해 emitBusRaw로 직행 — 256이면 worst-case escape 후 ~1.5KB.
pub const MAX_TITLE_BYTES: usize = 256;

/// 문서 `<title>`이 변경될 때 호출. payload UTF-8 변환 후 main.zig handler로 forward.
fn onTitleChange(
    _: ?*c._cef_display_handler_t,
    browser: ?*c._cef_browser_t,
    title: [*c]const c.cef_string_t,
) callconv(.c) void {
    const br = browser orelse return;
    const t = title orelse return;
    const handler = g_window_title_change_handler orelse return;
    const handle: u64 = @intCast(br.get_identifier.?(br));
    var buf: [MAX_TITLE_BYTES]u8 = undefined;
    const slice = cefStringToUtf8(t, &buf);
    handler(handle, slice);
}

// ============================================
// CEF Load Handler — main frame 첫 로드 완료 → window:ready-to-show
// ============================================

var g_load_handler: c.cef_load_handler_t = undefined;
var g_load_handler_initialized: bool = false;

fn ensureLoadHandler() void {
    if (g_load_handler_initialized) return;
    zeroCefStruct(c.cef_load_handler_t, &g_load_handler);
    initBaseRefCounted(&g_load_handler.base);
    g_load_handler.on_load_end = &onLoadEnd;
    if (cef.cefDebug()) {
        // CEF 디버그 모드 — 렌더러 crash/navigation 추적용 load 콜백.
        g_load_handler.on_load_start = &onLoadStartDiag;
        g_load_handler.on_load_error = &onLoadErrorDiag;
        g_load_handler.on_loading_state_change = &onLoadingStateDiag;
    }
    g_load_handler_initialized = true;
}

fn onLoadStartDiag(_: ?*c._cef_load_handler_t, _: ?*c._cef_browser_t, _: ?*c._cef_frame_t, _: c.cef_transition_type_t) callconv(.c) void {
    std.debug.print("[cef-debug] BROWSER onLoadStart\n", .{});
}

fn onLoadErrorDiag(_: ?*c._cef_load_handler_t, _: ?*c._cef_browser_t, _: ?*c._cef_frame_t, errorCode: c.cef_errorcode_t, _: [*c]const c.cef_string_t, _: [*c]const c.cef_string_t) callconv(.c) void {
    std.debug.print("[cef-debug] BROWSER onLoadError code={d}\n", .{errorCode});
}

fn onLoadingStateDiag(_: ?*c._cef_load_handler_t, _: ?*c._cef_browser_t, isLoading: c_int, _: c_int, _: c_int) callconv(.c) void {
    std.debug.print("[cef-debug] BROWSER onLoadingStateChange isLoading={d}\n", .{isLoading});
}

pub fn getLoadHandler(_: ?*c._cef_client_t) callconv(.c) ?*c._cef_load_handler_t {
    ensureLoadHandler();
    return &g_load_handler;
}

/// main frame이 처음으로 load 완료되는 순간 ready-to-show 1회 발화 (Electron 호환).
/// reload/navigate에선 다시 발화 X — `ready_to_show_fired` 플래그로 멱등성 보장.
fn onLoadEnd(
    _: ?*c._cef_load_handler_t,
    browser: ?*c._cef_browser_t,
    frame: ?*c._cef_frame_t,
    _: c_int,
) callconv(.c) void {
    const br = browser orelse return;
    const f = frame orelse return;
    const is_main = if (f.is_main) |fn_ptr| fn_ptr(f) == 1 else false;
    if (!is_main) return;

    const native = cef.globalNative() orelse return;
    const handle: u64 = @intCast(br.get_identifier.?(br));
    const entry = native.browsers.getPtr(handle) orelse return;
    if (entry.ready_to_show_fired) return;
    entry.ready_to_show_fired = true;
    if (g_window_ready_to_show_handler) |h| h(handle);
}

pub const WindowReadyToShowHandler = *const fn (handle: u64) void;
pub const WindowTitleChangeHandler = *const fn (handle: u64, title: []const u8) void;
pub const WindowFindResultHandler = *const fn (handle: u64, identifier: i32, count: i32, active_match_ordinal: i32, final_update: bool) void;

var g_window_ready_to_show_handler: ?WindowReadyToShowHandler = null;
var g_window_title_change_handler: ?WindowTitleChangeHandler = null;
var g_window_find_result_handler: ?WindowFindResultHandler = null;

pub const WindowDisplayHandlers = struct {
    ready_to_show: ?WindowReadyToShowHandler = null,
    title_change: ?WindowTitleChangeHandler = null,
    find_result: ?WindowFindResultHandler = null,
};

/// main.zig가 ready-to-show / page-title-updated / find-result emit 핸들러를 주입.
/// cef.zig가 EventBus(loader/main)에 직접 의존하지 않도록 한 단계 indirection.
/// lifecycle handlers와 동일하게 struct 패턴 — webContents 라이프사이클 핸들러를 비파괴적
/// 추가 가능 (did-finish-load 등).
pub fn setWindowDisplayHandlers(handlers: WindowDisplayHandlers) void {
    g_window_ready_to_show_handler = handlers.ready_to_show;
    g_window_title_change_handler = handlers.title_change;
    g_window_find_result_handler = handlers.find_result;
}

// ============================================
// CEF Find Handler — 검색 결과 보고 → window:find-result 이벤트 (Electron 호환)
// ============================================

var g_find_handler: c.cef_find_handler_t = undefined;
var g_find_handler_initialized: bool = false;

fn ensureFindHandler() void {
    if (g_find_handler_initialized) return;
    zeroCefStruct(c.cef_find_handler_t, &g_find_handler);
    initBaseRefCounted(&g_find_handler.base);
    g_find_handler.on_find_result = &onFindResult;
    g_find_handler_initialized = true;
}

pub fn getFindHandler(_: ?*c._cef_client_t) callconv(.c) ?*c._cef_find_handler_t {
    ensureFindHandler();
    return &g_find_handler;
}

// ============================================
// CEF Print Handler — Linux PDF 인쇄용 (CEF 요구)
// ============================================
//
// Linux 는 `cef_browser_host_t::print_to_pdf()` 가 `get_pdf_paper_size` 콜백
// 없이는 용지 크기를 못 얻어 PDF 출력이 동작하지 않음(CEF 설계). macOS/Windows
// 는 네이티브 인쇄 경로라 print_handler 자체를 무시 → 등록해도 무영향
// (cefclient 도 전 플랫폼 무조건 등록). Linux 산출은 GitHub Actions
// `run-print-to-pdf.sh`에서 실제 PDF 파일 생성 + `%PDF-` 시그니처까지 검증한다.

var g_print_handler: c.cef_print_handler_t = undefined;
var g_print_handler_initialized: bool = false;

fn ensurePrintHandler() void {
    if (g_print_handler_initialized) return;
    zeroCefStruct(c.cef_print_handler_t, &g_print_handler);
    initBaseRefCounted(&g_print_handler.base);
    g_print_handler.get_pdf_paper_size = &getPdfPaperSize;
    g_print_handler_initialized = true;
}

pub fn getPrintHandler(_: ?*c._cef_client_t) callconv(.c) ?*c._cef_print_handler_t {
    ensurePrintHandler();
    return &g_print_handler;
}

fn getPdfPaperSize(
    _: ?*c._cef_print_handler_t,
    _: ?*c._cef_browser_t,
    device_units_per_inch: c_int,
) callconv(.c) c.cef_size_t {
    // U.S. Letter (8.5 × 11 in) in device units — cefclient 기본값.
    const size = cef_pdf_print.defaultPaperSize(device_units_per_inch);
    return .{
        .width = size.width,
        .height = size.height,
    };
}

/// CEF가 find_in_page 검색 결과를 보고할 때 호출. payload는 main.zig가 final_update 동안만
/// `window:find-result` 발화 (incremental 진행은 noise). handler 주입은 setWindowDisplayHandlers.
fn onFindResult(
    _: ?*c._cef_find_handler_t,
    browser: ?*c._cef_browser_t,
    identifier: c_int,
    count: c_int,
    _: [*c]const c.cef_rect_t,
    active_match_ordinal: c_int,
    final_update: c_int,
) callconv(.c) void {
    const br = browser orelse return;
    const handler = g_window_find_result_handler orelse return;
    const handle: u64 = @intCast(br.get_identifier.?(br));
    handler(handle, identifier, count, active_match_ordinal, final_update != 0);
}
