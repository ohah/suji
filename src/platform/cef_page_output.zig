//! Page output helpers — PDF print callback + CDP screenshot capture.
//! CefNative keeps browser table ownership; this module owns output callbacks/pending slots.
const std = @import("std");
const runtime = @import("runtime");
const window_mod = @import("window");
const logger = @import("logger");
const util = @import("util");
const cef = @import("cef.zig");
const cef_browser_ipc = @import("cef_browser_ipc.zig");
const cef_page_output_constants = @import("cef_page_output_constants.zig");

const c = cef.c;
const log = logger.module("cef");

fn fromCtx(ctx: ?*anyopaque) *cef.CefNative {
    return @ptrCast(@alignCast(ctx.?));
}

fn assertUiThread() void {
    std.debug.assert(c.cef_currently_on(c.TID_UI) == 1);
}

pub const PDF_PATH_STACK_BUF = cef_page_output_constants.PDF_PATH_STACK_BUF;
pub const EVENT_PDF_PRINT_FINISHED = cef_page_output_constants.EVENT_PDF_PRINT_FINISHED;
pub const EVENT_PAGE_CAPTURED = cef_page_output_constants.EVENT_PAGE_CAPTURED;

pub fn printToPDFImpl(ctx: ?*anyopaque, handle: u64, path: []const u8) void {
    assertUiThread();
    const self = fromCtx(ctx);
    const entry = self.browsers.get(handle) orelse return;
    const host = cef.asPtr(c.cef_browser_host_t, entry.browser.get_host.?(entry.browser)) orelse return;
    printToPDF(host, path);
}

/// CDP Page.captureScreenshot — 결과는 observer → window:page-captured.
/// clip 지정 시 CDP `params.clip`{x,y,width,height,scale:1} 로 부분 영역만.
pub fn capturePageImpl(ctx: ?*anyopaque, handle: u64, path: []const u8, clip: ?window_mod.CaptureClip) void {
    assertUiThread();
    const self = fromCtx(ctx);
    const entry = self.browsers.getPtr(handle) orelse return;
    const host = cef.asPtr(c.cef_browser_host_t, entry.browser.get_host.?(entry.browser)) orelse return;
    capturePage(host, &entry.devtools_reg, handle, path, clip);
}

/// 글로벌 cef_pdf_print_callback_t — 매 print 마다 alloc하면 ref-counted 수명 추적
/// 부담. 콜백 자체는 stateless (path/success를 인자로 받음) → 글로벌 단일로 안전.
/// 동시 print 여러 개 호출 시 EventBus emit이 각자 독립으로 발화 (path가 인자에 포함).
var g_pdf_callback: c.cef_pdf_print_callback_t = undefined;
var g_pdf_callback_initialized: bool = false;

fn ensurePdfCallback() void {
    if (g_pdf_callback_initialized) return;
    cef.zeroCefStruct(c.cef_pdf_print_callback_t, &g_pdf_callback);
    cef.initBaseRefCounted(&g_pdf_callback.base);
    g_pdf_callback.on_pdf_print_finished = &onPdfPrintFinished;
    g_pdf_callback_initialized = true;
}

pub fn printToPDF(host: *c.cef_browser_host_t, path: []const u8) void {
    var path_buf: [PDF_PATH_STACK_BUF]u8 = undefined;
    // ⚠️ deferred(cefDeferResponse)는 IPC 핸들러가 이 함수 *호출 후* 등록하므로(window_ipc
    // handlePrintToPDF), 여기서 동기적으로 emit 해봤자 아직 슬롯이 없어 deferred 를 못 푼다
    // — 그 극단 엣지(path 초과/미지원, CEF 표준에선 도달 불가)의 hang 을 제대로 막으려면
    // vtable 에 "async 시작 여부" bool 을 전파해 핸들러가 즉시 실패 응답하게 해야 한다
    // (docs/audit-windows-followups.md C 후속). 무효한 동기 emit 은 스퓨리어스 이벤트만
    // 내므로 두지 않는다.
    const path_z = cef.nullTerminateOrTruncate(path, &path_buf) orelse {
        log.warn("print_to_pdf: path {d} bytes > {d} stack buf — dropped", .{ path.len, PDF_PATH_STACK_BUF });
        return;
    };

    var cef_path: c.cef_string_t = .{};
    cef.setCefString(&cef_path, path_z);
    defer cef.clearCefString(&cef_path); // setCefString UTF-16 해제(성공/실패 모두 — 누수 방지)

    var settings: c.cef_pdf_print_settings_t = undefined;
    cef.zeroCefStruct(c.cef_pdf_print_settings_t, &settings);

    ensurePdfCallback();
    const print = host.print_to_pdf orelse return;
    print(host, &cef_path, &settings, &g_pdf_callback);
}

/// PDF 인쇄 완료/실패 — deferred Promise resolve + `window:pdf-print-finished` emit.
/// PDF 는 글로벌 stateless 콜백이라 완료 시 browser_handle 을 모름 → cefCompletePending
/// 에 0 전달(= (kind,path) 매칭, 기존 동작 보존).
fn emitPdfFinished(path: []const u8, ok: bool) void {
    var escaped_buf: [PDF_PATH_STACK_BUF]u8 = undefined;
    const escaped_n = window_mod.escapeJsonChars(path, &escaped_buf);

    // 1) deferred Promise resolve — print_to_pdf 호출자가 await invoke 로 받는 응답.
    // `ok:true` 는 IPC dispatch 성공, `success` 는 실 PDF 작성 결과.
    var resp_buf: [PDF_PATH_STACK_BUF + 160]u8 = undefined;
    var rw = std.Io.Writer.fixed(&resp_buf);
    rw.print(
        "{{\"from\":\"zig-core\",\"cmd\":\"print_to_pdf\",\"ok\":true,\"path\":\"{s}\",\"success\":{}}}",
        .{ escaped_buf[0..escaped_n], ok },
    ) catch return;
    _ = cef_browser_ipc.cefCompletePending(.print, 0, path, rw.buffered());

    // 2) EventBus emit — 다른 SDK/백엔드 구독자 호환 보존.
    const emit = cef_browser_ipc.emitCallback() orelse return;
    var payload_buf: [PDF_PATH_STACK_BUF + 64]u8 = undefined;
    var w = std.Io.Writer.fixed(&payload_buf);
    w.print("{{\"path\":\"{s}\",\"success\":{}}}", .{ escaped_buf[0..escaped_n], ok }) catch return;
    emit(null, EVENT_PDF_PRINT_FINISHED, w.buffered());
}

/// CEF print_to_pdf 완료 콜백 — deferred Promise resolve + `window:pdf-print-finished` emit.
fn onPdfPrintFinished(_: [*c]c.cef_pdf_print_callback_t, path: [*c]const c.cef_string_t, ok: c_int) callconv(.c) void {
    var path_buf: [PDF_PATH_STACK_BUF]u8 = undefined;
    const path_str: []const u8 = if (path) |p| cef.cefStringToUtf8(p, &path_buf) else "";
    emitPdfFinished(path_str, ok != 0);
}

/// `window:page-captured`{path,success} 발화 + deferred Promise resolve.
/// handle = 캡처를 요청한 창(0 이 아니면 완료 매칭에 사용 — cross-window 오라우팅 방지).
fn emitPageCaptured(handle: u64, path: []const u8, ok: bool) void {
    var esc: [PDF_PATH_STACK_BUF]u8 = undefined;
    const en = window_mod.escapeJsonChars(path, &esc);

    // 1) deferred Promise resolve. `ok:true` = IPC 성공, `success` = 캡처 결과.
    var resp_buf: [PDF_PATH_STACK_BUF + 160]u8 = undefined;
    var rw = std.Io.Writer.fixed(&resp_buf);
    rw.print(
        "{{\"from\":\"zig-core\",\"cmd\":\"capture_page\",\"ok\":true,\"path\":\"{s}\",\"success\":{}}}",
        .{ esc[0..en], ok },
    ) catch return;
    _ = cef_browser_ipc.cefCompletePending(.capture, handle, path, rw.buffered());

    // 2) EventBus emit.
    const emit = cef_browser_ipc.emitCallback() orelse return;
    var payload: [PDF_PATH_STACK_BUF + 64]u8 = undefined;
    var w = std.Io.Writer.fixed(&payload);
    w.print("{{\"path\":\"{s}\",\"success\":{}}}", .{ esc[0..en], ok }) catch return;
    emit(null, EVENT_PAGE_CAPTURED, w.buffered());
}

/// capture 요청-결과 상관용 고정 슬롯(저빈도, CEF UI 스레드 단일 → lock 불필요).
const CapturePending = struct {
    id: c_int = 0,
    used: bool = false,
    /// 창 close 시 purge 키 (PR #54 review #1). capturePageImpl 가 handle 로 채움.
    browser_handle: u64 = 0,
    path_buf: [PDF_PATH_STACK_BUF]u8 = undefined,
    path_len: usize = 0,
};
var g_capture_pending = [_]CapturePending{.{}} ** 16;
var g_capture_next_id: c_int = 1;
var g_devtools_observer: c.cef_dev_tools_message_observer_t = undefined;
var g_devtools_observer_initialized: bool = false;

pub fn purgeCapturePendingForBrowser(handle: u64) void {
    if (handle == 0) return;
    for (&g_capture_pending) |*s| {
        if (s.used and s.browser_handle == handle) s.used = false;
    }
}

/// CDP Page.captureScreenshot — 결과는 observer → window:page-captured.
/// clip 지정 시 CDP `params.clip`{x,y,width,height,scale:1} 로 부분 영역만.
pub fn capturePage(host: *c.cef_browser_host_t, devtools_reg: *?*c.cef_registration_t, handle: u64, path: []const u8, clip: ?window_mod.CaptureClip) void {
    // ⚠️ deferred(cefDeferResponse)는 IPC 핸들러가 이 함수 *호출 후* 등록하므로(window_ipc
    // handleCapturePage), 여기서 동기적으로 emitPageCaptured 해도 아직 슬롯이 없어 deferred
    // 를 못 푼다(스퓨리어스 이벤트만). 극단 엣지(observer/send 미지원=CEF 표준 도달 불가,
    // 풀 16 동시=비현실)의 hang 을 제대로 막으려면 vtable 에 "async 시작 여부"를 전파해야
    // 한다(docs/audit-windows-followups.md C 후속). 풀-full 발화는 pre-existing(이미 무효).
    ensureDevToolsObserver();
    if (devtools_reg.* == null) {
        const add = host.add_dev_tools_message_observer orelse return;
        devtools_reg.* = cef.asPtr(c.cef_registration_t, add(host, &g_devtools_observer));
    }

    // pending 슬롯 확보. 가득(16 동시 미완료 — 저빈도라 비현실적)이면
    // 진행 중 요청 덮어쓰지 말고 즉시 실패 발화(SDK Promise leak 방지).
    const id = g_capture_next_id;
    g_capture_next_id +%= 1;
    if (g_capture_next_id == 0) g_capture_next_id = 1;
    var slot: ?*CapturePending = null;
    for (&g_capture_pending) |*s| {
        if (!s.used) {
            slot = s;
            break;
        }
    }
    // 슬롯 풀(16 동시 미완료 — 비현실) — 동기 emit 은 deferred 등록 *전* 이라 무효
    // (위 주석 참조)라 발화하지 않는다(C.1 후속에서 vtable bool 로 근본 해결).
    const sl = slot orelse return;
    const n = @min(path.len, sl.path_buf.len);
    @memcpy(sl.path_buf[0..n], path[0..n]);
    sl.path_len = n;
    sl.id = id;
    sl.browser_handle = handle;
    sl.used = true;

    var msg: [256]u8 = undefined;
    const m: ?[]u8 = if (clip) |cl| (std.fmt.bufPrint(
        &msg,
        "{{\"id\":{d},\"method\":\"Page.captureScreenshot\",\"params\":{{\"clip\":{{\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d},\"scale\":1}}}}}}",
        .{ id, cl.x, cl.y, cl.width, cl.height },
    ) catch null) else (std.fmt.bufPrint(
        &msg,
        "{{\"id\":{d},\"method\":\"Page.captureScreenshot\",\"params\":{{}}}}",
        .{id},
    ) catch null);
    if (m) |built| {
        if (host.send_dev_tools_message) |send| {
            _ = send(host, built.ptr, built.len);
            return;
        }
    }
    // 메시지 빌드/전송 불가(CEF 표준에선 도달 불가) — 예약한 슬롯을 회수해 슬롯 누수를
    // 막는다(동기 emit 은 deferred 등록 전이라 무효 → 생략, 위 주석 참조).
    sl.used = false;
}

fn devtoolsObserverNoopMsg(_: [*c]c.cef_dev_tools_message_observer_t, _: [*c]c.cef_browser_t, _: ?*const anyopaque, _: usize) callconv(.c) c_int {
    return 0; // 0 = 다른 observer 도 메시지 수신(consume 안 함)
}

fn devtoolsObserverNoopEvent(_: [*c]c.cef_dev_tools_message_observer_t, _: [*c]c.cef_browser_t, _: [*c]const c.cef_string_t, _: ?*const anyopaque, _: usize) callconv(.c) void {}

fn devtoolsObserverNoopAttach(_: [*c]c.cef_dev_tools_message_observer_t, _: [*c]c.cef_browser_t) callconv(.c) void {}

/// CDP 메서드 결과 — Page.captureScreenshot 응답({"data":"<base64 png>"}).
fn onDevToolsMethodResult(
    _: [*c]c.cef_dev_tools_message_observer_t,
    _: [*c]c.cef_browser_t,
    message_id: c_int,
    success: c_int,
    result: ?*const anyopaque,
    result_size: usize,
) callconv(.c) void {
    // 우리 capture 요청인지 message_id 로 식별 (아니면 무시).
    var slot: ?*CapturePending = null;
    for (&g_capture_pending) |*s| {
        if (s.used and s.id == message_id) {
            slot = s;
            break;
        }
    }
    const p = slot orelse return;
    defer p.used = false;
    const capture_handle = p.browser_handle;
    const path = p.path_buf[0..p.path_len];

    const ok = blk: {
        if (success == 0) break :blk false;
        const res_ptr = result orelse break :blk false;
        const json: []const u8 = @as([*]const u8, @ptrCast(res_ptr))[0..result_size];
        // base64 는 JSON-special/backslash 무함 → extractJsonString 으로 충분.
        const b64 = util.extractJsonString(json, "data") orelse break :blk false;
        const dec_size = std.base64.standard.Decoder.calcSizeForSlice(b64) catch break :blk false;
        if (dec_size > 32 * 1024 * 1024) break :blk false; // pathological 가드
        const alloc = std.heap.page_allocator;
        const raw = alloc.alloc(u8, dec_size) catch break :blk false;
        defer alloc.free(raw);
        std.base64.standard.Decoder.decode(raw, b64) catch break :blk false;
        var pbuf: [PDF_PATH_STACK_BUF]u8 = undefined;
        const path_z = cef.nullTerminateOrTruncate(path, &pbuf) orelse break :blk false;
        const io = runtime.io;
        var f = std.Io.Dir.cwd().createFile(io, path_z, .{}) catch break :blk false;
        defer f.close(io);
        var wbuf: [4096]u8 = undefined;
        var fw = f.writer(io, &wbuf);
        fw.interface.writeAll(raw) catch break :blk false;
        fw.interface.flush() catch break :blk false;
        break :blk true;
    };

    emitPageCaptured(capture_handle, path, ok);
}

fn ensureDevToolsObserver() void {
    if (g_devtools_observer_initialized) return;
    cef.zeroCefStruct(c.cef_dev_tools_message_observer_t, &g_devtools_observer);
    cef.initBaseRefCounted(&g_devtools_observer.base);
    g_devtools_observer.on_dev_tools_message = &devtoolsObserverNoopMsg;
    g_devtools_observer.on_dev_tools_method_result = &onDevToolsMethodResult;
    g_devtools_observer.on_dev_tools_event = &devtoolsObserverNoopEvent;
    g_devtools_observer.on_dev_tools_agent_attached = &devtoolsObserverNoopAttach;
    g_devtools_observer.on_dev_tools_agent_detached = &devtoolsObserverNoopAttach;
    g_devtools_observer_initialized = true;
}
