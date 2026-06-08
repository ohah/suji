//! CEF life span handler — cef.zig 에서 분리(동작 무변경).
//! browser 생성/종료 콜백을 WindowManager, deferred response, DevTools map 정리와 연결한다.
const std = @import("std");
const window_mod = @import("window");
const logger = @import("logger");
const util = @import("util");
const cef = @import("cef.zig");
const cef_devtools = @import("cef_devtools.zig");

const c = cef.c;
const log = logger.module("cef");
const zeroCefStruct = cef.zeroCefStruct;
const initBaseRefCounted = cef.initBaseRefCounted;

// ---- Electron webContents.setWindowOpenHandler — declarative popup 정책 + 이벤트 ----
// CEF on_before_popup 은 동기 콜백(즉시 1=block/0=allow 반환)이라 async JS 핸들러를
// 동기 consult 할 수 없다. 따라서 전역 정책('allow'/'deny')을 동기 적용하고, popup 마다
// `web-contents:new-window` 이벤트({url, frameName, disposition})를 발신해 app 이 관리
// 창으로 직접 열도록 한다(정직 경계 — per-popup 동적 콜백은 CEF 제약상 불가).
pub const WindowOpenEmitFn = *const fn (channel: [*:0]const u8, payload: [*:0]const u8) callconv(.c) void;
var g_window_open_emit_fn: ?WindowOpenEmitFn = null;
var g_window_open_deny: std.atomic.Value(bool) = .init(false);

pub fn setWindowOpenEmitHandler(fn_ptr: WindowOpenEmitFn) void {
    g_window_open_emit_fn = fn_ptr;
}

/// Electron `webContents.setWindowOpenHandler` — deny=true 면 네이티브 popup 차단(전역).
/// 기본 false(allow, 비파괴). popup 마다 web-contents:new-window 이벤트는 정책 무관 발신.
pub fn setWindowOpenDeny(deny: bool) void {
    g_window_open_deny.store(deny, .release);
}

var g_life_span_handler: c.cef_life_span_handler_t = undefined;
var g_life_span_handler_initialized: bool = false;

pub fn initLifeSpanHandler() void {
    if (g_life_span_handler_initialized) return;
    zeroCefStruct(c.cef_life_span_handler_t, &g_life_span_handler);
    initBaseRefCounted(&g_life_span_handler.base);
    g_life_span_handler.on_after_created = &onAfterCreated;
    g_life_span_handler.on_before_popup = &onBeforePopup;
    g_life_span_handler.do_close = &doClose;
    g_life_span_handler.on_before_close = &onBeforeClose;
    g_life_span_handler_initialized = true;
}

/// CEF popup(window.open / target=_blank) 직전 동기 훅 — web-contents:new-window 발신 +
/// 전역 정책 반환(1=block, 0=allow). url/frameName 은 escape 후 페이로드.
fn onBeforePopup(
    _: ?*c._cef_life_span_handler_t,
    _: ?*c._cef_browser_t,
    _: ?*c._cef_frame_t,
    _: c_int,
    target_url: [*c]const c.cef_string_t,
    target_frame_name: [*c]const c.cef_string_t,
    target_disposition: c.cef_window_open_disposition_t,
    _: c_int,
    _: [*c]const c.cef_popup_features_t,
    _: [*c]c.cef_window_info_t,
    _: [*c][*c]c._cef_client_t,
    _: [*c]c.cef_browser_settings_t,
    _: [*c][*c]c._cef_dictionary_value_t,
    _: [*c]c_int,
) callconv(.c) c_int {
    const deny: c_int = if (g_window_open_deny.load(.acquire)) 1 else 0;
    const emit = g_window_open_emit_fn orelse return deny;
    var url_buf: [2048]u8 = undefined;
    const url = if (target_url != null) cef.cefStringToUtf8(target_url, &url_buf) else "";
    var name_buf: [256]u8 = undefined;
    const fname = if (target_frame_name != null) cef.cefStringToUtf8(target_frame_name, &name_buf) else "";
    var url_esc: [4096]u8 = undefined;
    var name_esc: [512]u8 = undefined;
    const ue = util.escapeJsonStrFull(url, &url_esc) orelse return deny;
    const ne = util.escapeJsonStrFull(fname, &name_esc) orelse return deny;
    var payload: [8192]u8 = undefined;
    const p = std.fmt.bufPrintZ(
        &payload,
        "{{\"url\":\"{s}\",\"frameName\":\"{s}\",\"disposition\":{d}}}",
        .{ url_esc[0..ue], name_esc[0..ne], @as(i32, @intCast(target_disposition)) },
    ) catch return deny;
    emit("web-contents:new-window", p.ptr);
    return deny;
}

pub fn getLifeSpanHandler(_: ?*c._cef_client_t) callconv(.c) ?*c._cef_life_span_handler_t {
    initLifeSpanHandler();
    return &g_life_span_handler;
}

fn onAfterCreated(_: ?*c._cef_life_span_handler_t, browser: ?*c._cef_browser_t) callconv(.c) void {
    const br = browser orelse return;
    const id: u64 = @intCast(br.get_identifier.?(br));

    if (cef_devtools.handleAfterCreated(id)) return;

    cef.rememberMainBrowserIfUnset(br);
}

/// CEF가 browser close 요청을 처리할지 물어보는 훅.
/// - WM이 이미 close 중(destroyed=true)이면 통과 (WM 경로가 이미 이벤트 발화함)
/// - 아니면 사용자/OS 기인 close → wm.tryClose로 라우팅해 `window:close` 취소 가능 이벤트 발화
/// 반환: 0 = 진행, 1 = 취소 (브라우저 유지)
fn doClose(_: ?*c._cef_life_span_handler_t, browser: ?*c._cef_browser_t) callconv(.c) i32 {
    const br = browser orelse return 0;
    const handle: u64 = @intCast(br.get_identifier.?(br));
    const wm = window_mod.WindowManager.global orelse {
        log.debug("DoClose handle={d} WM.global=null → proceed", .{handle});
        return 0;
    };
    const id = wm.findByNativeHandle(handle) orelse {
        log.debug("DoClose handle={d} not in WM → proceed", .{handle});
        return 0;
    };
    const w = wm.get(id) orelse return 0;

    if (w.destroyed) {
        log.debug("DoClose id={d} already destroyed (WM-initiated) → proceed", .{id});
        return 0;
    }

    log.debug("DoClose id={d} external close → tryClose", .{id});
    const proceed = wm.tryClose(id) catch |e| {
        log.err("DoClose tryClose failed: {s}", .{@errorName(e)});
        return 0;
    };
    log.debug("DoClose id={d} proceed={}", .{ id, proceed });
    return if (proceed) 0 else 1;
}

fn onBeforeClose(_: ?*c._cef_life_span_handler_t, browser: ?*c._cef_browser_t) callconv(.c) void {
    const br = browser orelse return;
    const handle: u64 = @intCast(br.get_identifier.?(br));
    log.debug("OnBeforeClose handle={d}", .{handle});

    if (cef.globalNative()) |cn| cn.purge(handle);
    // 닫히는 browser 의 deferred-response 슬롯도 정리 — CDP 콜백이 close 후
    // 도착해도 dangling browser/frame 을 deref 하지 않도록(PR #54 review #1, UAF).
    cef.purgePendingResponsesForBrowser(handle);

    cef_devtools.handleBeforeClose(handle);

    var is_view: bool = false;
    notifyWm: {
        const wm = window_mod.WindowManager.global orelse break :notifyWm;
        const id = wm.findByNativeHandle(handle) orelse break :notifyWm;
        const w = wm.get(id) orelse break :notifyWm;
        is_view = (w.kind == .view);
        if (w.destroyed) {
            log.debug("OnBeforeClose id={d} already destroyed — skip markClosedExternal", .{id});
            break :notifyWm;
        }
        log.debug("OnBeforeClose id={d} → markClosedExternal", .{id});
        wm.markClosedExternal(id) catch {};
    }

    // view OnBeforeClose는 host 종속 — main browser와 별개라 quit_message_loop 트리거 X
    // (defense-in-depth: g_browser fallback이 view를 main으로 잘못 인식하는 경로 차단).
    const is_main = !is_view and cef.isMainBrowser(br);
    if (is_main) {
        log.info("main browser closed → quitting message loop", .{});
        c.cef_quit_message_loop();
    } else {
        log.debug("non-main browser closed handle={d} (no quit)", .{handle});
    }
}
