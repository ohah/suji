//! CEF message-loop lifecycle — cef.zig 에서 분리(동작 무변경).
//! Public `run`/`shutdown`/`quit` lifecycle functions live here.
const std = @import("std");
const builtin = @import("builtin");
const cef = @import("cef.zig");
const cef_browser_ipc = @import("cef_browser_ipc.zig");
const cef_devtools = @import("cef_devtools.zig");
const cef_objc = @import("cef_objc.zig");

const c = cef.c;
const is_macos = builtin.os.tag == .macos;

/// 메시지 루프 실행 (블로킹)
pub fn run() void {
    if (comptime is_macos) cef_objc.activateNSApp();
    std.debug.print("[suji] CEF running\n", .{});
    c.cef_run_message_loop();
}

/// CEF 종료
pub fn shutdown() void {
    // c.cef_shutdown은 메시지 루프 drain 중 잔여 OnBeforeClose 콜백을 발화시킬 수 있음 —
    // 그 시점에 devtools_to_inspectee가 살아있어야 안전한 lookup/remove 가능.
    c.cef_shutdown();
    cef_devtools.deinitAfterShutdown();
    std.debug.print("[suji] CEF shutdown\n", .{});
}

/// 메시지 루프 종료 요청. 매핑된 DevTools와 등록된 모든 창을 force-close 후 quit.
///
/// DevTools 떠 있을 때 cef_quit_message_loop만 호출하면 macOS NSApp 런루프가
/// DevTools pending 이벤트에 매여 quit이 늦거나 무시됨. close_browser(1)은 force라
/// cancelable `window:close` 이벤트는 발화 X — 명시적 quit 요청이라 의도적.
///
/// **명시적 idempotent**: 두 번째 호출은 즉시 no-op. user code(suji.on("window:all-closed"))
/// + 코어 자동 quit(`app.quitOnAllWindowsClosed: true`) 두 경로가 동시에 발화해도 안전.
var g_quit_called: bool = false;
pub const quitAfterNextResponse = cef_browser_ipc.quitAfterNextResponse;

/// Electron `app.on('before-quit')` 훅 — quit 직전 1회 호출(main 이 주입해
/// `app:before-quit` 이벤트를 EventBus 로 발신). 모든 quit 경로(Cmd+Q, suji.quit,
/// window:all-closed 자동 quit, IPC quit)가 cef.quit() 를 거치므로 단일 chokepoint.
pub const BeforeQuitFn = *const fn () callconv(.c) void;
var g_before_quit_fn: ?BeforeQuitFn = null;
pub fn setBeforeQuitHandler(fn_ptr: BeforeQuitFn) void {
    g_before_quit_fn = fn_ptr;
}

pub fn quit() void {
    if (g_quit_called) return;
    g_quit_called = true;

    // before-quit 알림(idempotent guard 안 — 정확히 1회). in-process(백엔드) listener 는
    // 동기 실행, 렌더러는 best-effort(quit 진행 전 짧은 윈도). preventDefault(취소)는
    // IPC 비동기 모델상 미지원 — window:close 렌더러 경계와 동일(정직 경계).
    if (g_before_quit_fn) |f| f();

    cef_devtools.closeMappedDevToolsBeforeQuit();

    if (cef.globalNative()) |native| {
        var it = native.browsers.iterator();
        while (it.next()) |entry| {
            const br = entry.value_ptr.*.browser;
            const host = cef.asPtr(c.cef_browser_host_t, br.get_host.?(br)) orelse continue;
            host.close_browser.?(host, 1);
        }
    }

    c.cef_quit_message_loop();
}
