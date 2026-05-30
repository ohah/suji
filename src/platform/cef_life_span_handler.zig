//! CEF life span handler — cef.zig 에서 분리(동작 무변경).
//! browser 생성/종료 콜백을 WindowManager, deferred response, DevTools map 정리와 연결한다.
const window_mod = @import("window");
const logger = @import("logger");
const cef = @import("cef.zig");
const cef_devtools = @import("cef_devtools.zig");

const c = cef.c;
const log = logger.module("cef");
const zeroCefStruct = cef.zeroCefStruct;
const initBaseRefCounted = cef.initBaseRefCounted;

var g_life_span_handler: c.cef_life_span_handler_t = undefined;
var g_life_span_handler_initialized: bool = false;

pub fn initLifeSpanHandler() void {
    if (g_life_span_handler_initialized) return;
    zeroCefStruct(c.cef_life_span_handler_t, &g_life_span_handler);
    initBaseRefCounted(&g_life_span_handler.base);
    g_life_span_handler.on_after_created = &onAfterCreated;
    g_life_span_handler.do_close = &doClose;
    g_life_span_handler.on_before_close = &onBeforeClose;
    g_life_span_handler_initialized = true;
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
