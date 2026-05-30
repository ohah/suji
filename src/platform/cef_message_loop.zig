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

pub fn quit() void {
    if (g_quit_called) return;
    g_quit_called = true;

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
