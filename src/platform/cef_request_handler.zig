//! CEF request handler glue — cef.zig 에서 분리(동작 무변경).
//! resource request callback은 cef_web_request.zig에 위임하고, CEF debug 진단만 함께 보관한다.
const std = @import("std");
const cef = @import("cef.zig");
const cef_web_request = @import("cef_web_request.zig");

const c = cef.c;
const zeroCefStruct = cef.zeroCefStruct;
const initBaseRefCounted = cef.initBaseRefCounted;
const cefUserfreeToUtf8 = cef.cefUserfreeToUtf8;

var g_request_handler: c.cef_request_handler_t = undefined;
var g_request_handler_initialized: bool = false;

fn ensureRequestHandler() void {
    if (g_request_handler_initialized) return;
    zeroCefStruct(c.cef_request_handler_t, &g_request_handler);
    initBaseRefCounted(&g_request_handler.base);
    g_request_handler.get_resource_request_handler = &cef_web_request.getResourceRequestHandler;
    if (cef.cefDebug()) {
        // CEF 디버그 모드 — 렌더러 crash(on_render_process_terminated)/navigation 추적.
        g_request_handler.on_render_process_terminated = &onRenderProcessTerminatedDiag;
        g_request_handler.on_before_browse = &onBeforeBrowseDiag;
    }
    g_request_handler_initialized = true;
}

fn onRenderProcessTerminatedDiag(_: ?*c._cef_request_handler_t, _: ?*c._cef_browser_t, status: c.cef_termination_status_t, error_code: c_int, _: [*c]const c.cef_string_t) callconv(.c) void {
    std.debug.print("[cef-debug] RENDER PROCESS TERMINATED status={d} error_code={d}\n", .{ @as(i32, @intCast(status)), error_code });
}

fn onBeforeBrowseDiag(_: ?*c._cef_request_handler_t, _: ?*c._cef_browser_t, _: ?*c._cef_frame_t, request: ?*c._cef_request_t, _: c_int, _: c_int) callconv(.c) c_int {
    if (request) |req| {
        if (req.get_url) |get_url| {
            var url_buf: [2048]u8 = undefined; // 다른 URL 버퍼와 동일 — 진단 truncation 회피
            const url = cefUserfreeToUtf8(get_url(req), &url_buf);
            std.debug.print("[cef-debug] onBeforeBrowse url={s}\n", .{url});
        }
    }
    return 0; // allow
}

pub fn getRequestHandler(_: ?*c._cef_client_t) callconv(.c) ?*c._cef_request_handler_t {
    ensureRequestHandler();
    return &g_request_handler;
}
