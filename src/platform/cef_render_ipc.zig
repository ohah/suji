//! Renderer-side IPC state and delivery helpers.
//! Keeps `cef_render_handler.zig` focused on V8 binding/vtable setup.

const std = @import("std");
const cef = @import("cef.zig");

const c = cef.c;
const asPtr = cef.asPtr;
const setCefString = cef.setCefString;
const getArgString = cef.getArgString;
const CEF_IPC_BUF_LEN = cef.CEF_IPC_BUF_LEN;

// 시퀀스 카운터 (요청-응답 매칭)
var g_seq_counter: u32 = 0;

// 렌더러 V8 컨텍스트 (onContextCreated에서 저장, 이벤트 디스패치용)
var g_renderer_context: ?*c.cef_v8_context_t = null;

// 펜딩 컨텍스트 저장소 (렌더러 프로세스, 싱글 스레드)
// Promise는 JS 측에서 관리 (_pending 맵), 네이티브는 컨텍스트만 보관
const MAX_PENDING: usize = 256;
var g_pending_contexts: [MAX_PENDING]?*c.cef_v8_context_t = [_]?*c.cef_v8_context_t{null} ** MAX_PENDING;

pub fn rememberRendererContext(ctx: *c.cef_v8_context_t) void {
    g_renderer_context = ctx;
}

pub fn nextSeqId() u32 {
    const seq_id = g_seq_counter;
    g_seq_counter +%= 1;
    return seq_id;
}

pub fn rememberPendingContext(seq_id: u32, ctx: ?*c.cef_v8_context_t) void {
    const slot = seq_id % MAX_PENDING;
    g_pending_contexts[slot] = ctx;
}

pub fn clearPendingContext(seq_id: u32) void {
    const slot = seq_id % MAX_PENDING;
    g_pending_contexts[slot] = null;
}

/// invoke 응답 처리 → JS _nextResolve/_nextReject 호출
pub fn handleRendererResponse(msg: *c._cef_process_message_t) i32 {
    const args = asPtr(c.cef_list_value_t, msg.get_argument_list.?(msg)) orelse return 0;

    const seq_id: u32 = @intCast(args.get_int.?(args, 0));
    const success = args.get_int.?(args, 1) == 1;

    var result_buf: [CEF_IPC_BUF_LEN]u8 = undefined; // 송신과 동일 64KB(16KB 고정이면 큰 응답 잘림)
    const result = getArgString(args, 2, &result_buf);

    const slot = seq_id % MAX_PENDING;
    const pending_ctx = g_pending_contexts[slot];
    g_pending_contexts[slot] = null;

    var called = deliverRendererResponse(pending_ctx, seq_id, success, result);
    if (!called) {
        const fallback_ctx = g_renderer_context;
        if (pending_ctx == null or fallback_ctx != pending_ctx) {
            called = deliverRendererResponse(fallback_ctx, seq_id, success, result);
        }
    }
    if (cef.traceIpcEnabled()) {
        std.debug.print("[suji:ipc] renderer_resp seq={d} success={} result_len={d} delivered={}\n", .{ seq_id, success, result.len, called });
    }

    return if (called) 1 else 0;
}

/// 청크 응답 — JS _nextChunk 로 누적(재조립은 JS 담당, Zig 은 무상태 전달).
pub fn handleRendererChunk(msg: *c._cef_process_message_t) i32 {
    const args = asPtr(c.cef_list_value_t, msg.get_argument_list.?(msg)) orelse return 0;
    const seq_id: u32 = @intCast(args.get_int.?(args, 0));
    const idx = args.get_int.?(args, 1);
    const total = args.get_int.?(args, 2);
    var data_buf: [CEF_IPC_BUF_LEN]u8 = undefined;
    const data = getArgString(args, 3, &data_buf);
    const slot = seq_id % MAX_PENDING;
    const ctx = g_pending_contexts[slot] orelse g_renderer_context orelse return 0;
    return if (callSujiChunk(ctx, seq_id, idx, total, data)) 1 else 0;
}

/// 청크 완료 — JS _chunkComplete 가 join → resolve. pending slot 소비.
pub fn handleRendererComplete(msg: *c._cef_process_message_t) i32 {
    const args = asPtr(c.cef_list_value_t, msg.get_argument_list.?(msg)) orelse return 0;
    const seq_id: u32 = @intCast(args.get_int.?(args, 0));
    const success = args.get_int.?(args, 1) == 1;
    const slot = seq_id % MAX_PENDING;
    const ctx = g_pending_contexts[slot] orelse g_renderer_context orelse return 0;
    g_pending_contexts[slot] = null;
    return if (callSujiComplete(ctx, seq_id, success)) 1 else 0;
}

/// 메인에서 푸시된 이벤트 → JS __dispatch__ 호출
pub fn handleRendererEvent(msg: *c._cef_process_message_t) i32 {
    const args = asPtr(c.cef_list_value_t, msg.get_argument_list.?(msg)) orelse return 0;

    var event_buf: [256]u8 = undefined;
    const event = getArgString(args, 0, &event_buf);

    var data_buf: [CEF_IPC_BUF_LEN]u8 = undefined;
    const data = getArgString(args, 1, &data_buf);

    // 저장된 렌더러 컨텍스트 사용 (onContextCreated에서 저장)
    // cef_v8_context_get_current_context()는 메시지 핸들러에서 유효하지 않을 수 있음
    const ctx = g_renderer_context orelse return 0;
    _ = ctx.enter.?(ctx);

    // data를 hex-escape하여 injection 방지
    var hex_buf: [16384]u8 = undefined;
    const hex_data = jsonToHexEscape(data, &hex_buf);
    var js_buf: [33000]u8 = undefined;
    const js = std.fmt.bufPrint(&js_buf, "window.__suji__.__dispatch__(\"{s}\",JSON.parse(decodeURIComponent('{s}')))", .{ event, hex_data }) catch {
        _ = ctx.exit.?(ctx);
        return 0;
    };

    var code_str: c.cef_string_t = .{};
    setCefString(&code_str, js);
    var empty_url: c.cef_string_t = .{};
    setCefString(&empty_url, "");
    var retval: ?*c.cef_v8_value_t = null;
    var exception: ?*c.cef_v8_exception_t = null;
    _ = ctx.eval.?(ctx, &code_str, &empty_url, 0, &retval, &exception);

    _ = ctx.exit.?(ctx);
    return 1;
}

/// JSON 문자열을 URI percent-encode (single-quote/backslash injection 방지)
fn jsonToHexEscape(src: []const u8, buf: []u8) []const u8 {
    const hex = "0123456789ABCDEF";
    var o: usize = 0;
    for (src) |ch| {
        if (o + 3 > buf.len) break;
        if ((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '-' or ch == '_' or ch == '.' or ch == '~') {
            buf[o] = ch;
            o += 1;
        } else {
            buf[o] = '%';
            buf[o + 1] = hex[ch >> 4];
            buf[o + 2] = hex[ch & 0x0f];
            o += 3;
        }
    }
    return buf[0..o];
}

pub fn currentOrLastRendererContext() ?*c.cef_v8_context_t {
    return asPtr(c.cef_v8_context_t, c.cef_v8_context_get_current_context()) orelse g_renderer_context;
}

/// V8 컨텍스트의 프레임으로 ProcessMessage 전송 (렌더러 → 브라우저)
pub fn sendToBrowserFromContext(ctx: ?*c.cef_v8_context_t, msg: *c.cef_process_message_t) bool {
    const cctx = ctx orelse return false;
    if (cctx.is_valid) |is_valid| {
        if (is_valid(cctx) != 1) return false;
    }
    const frame = blk: {
        if (cctx.get_browser) |get_browser| {
            if (asPtr(c.cef_browser_t, get_browser(cctx))) |browser| {
                if (browser.get_main_frame) |get_main_frame| {
                    if (asPtr(c.cef_frame_t, get_main_frame(browser))) |main_frame| {
                        break :blk main_frame;
                    }
                }
            }
        }
        break :blk asPtr(c.cef_frame_t, cctx.get_frame.?(cctx)) orelse return false;
    };
    frame.send_process_message.?(frame, c.PID_BROWSER, msg);
    return true;
}

pub fn sendToBrowser(msg: *c.cef_process_message_t) bool {
    return sendToBrowserFromContext(currentOrLastRendererContext(), msg);
}

pub fn traceRendererInvokeSendFailed(channel: []const u8) void {
    if (cef.traceIpcEnabled()) {
        std.debug.print("[suji:ipc] renderer_invoke_send_failed channel={s}\n", .{channel});
    }
}

pub fn traceRendererEmitSendFailed(event: []const u8) void {
    if (cef.traceIpcEnabled()) {
        std.debug.print("[suji:ipc] renderer_emit_send_failed event={s}\n", .{event});
    }
}

fn deliverRendererResponse(ctx: ?*c.cef_v8_context_t, seq_id: u32, success: bool, result: []const u8) bool {
    const cctx = ctx orelse return false;
    return callSujiResponseCallback(cctx, seq_id, success, result);
}

fn callSujiResponseCallback(ctx: *c._cef_v8_context_t, seq_id: u32, success: bool, result: []const u8) bool {
    _ = ctx.enter.?(ctx);
    defer _ = ctx.exit.?(ctx);

    const global = asPtr(c.cef_v8_value_t, ctx.get_global.?(ctx)) orelse return false;

    var suji_key: c.cef_string_t = .{};
    setCefString(&suji_key, "__suji__");
    const suji_obj = asPtr(c.cef_v8_value_t, global.get_value_bykey.?(global, &suji_key)) orelse return false;

    var fn_key: c.cef_string_t = .{};
    setCefString(&fn_key, if (success) "_nextResolve" else "_nextReject");
    const callback = asPtr(c.cef_v8_value_t, suji_obj.get_value_bykey.?(suji_obj, &fn_key)) orelse return false;

    var result_str: c.cef_string_t = .{};
    setCefString(&result_str, result);
    var call_args = [_][*c]c.cef_v8_value_t{
        c.cef_v8_value_create_int(@intCast(seq_id)),
        c.cef_v8_value_create_string(&result_str),
    };
    if (call_args[0] == null or call_args[1] == null) return false;

    _ = callback.execute_function.?(callback, suji_obj, call_args.len, &call_args);
    return true;
}

fn callSujiChunk(ctx: *c._cef_v8_context_t, seq_id: u32, idx: i32, total: i32, data: []const u8) bool {
    _ = ctx.enter.?(ctx);
    defer _ = ctx.exit.?(ctx);
    const global = asPtr(c.cef_v8_value_t, ctx.get_global.?(ctx)) orelse return false;
    var suji_key: c.cef_string_t = .{};
    setCefString(&suji_key, "__suji__");
    const suji_obj = asPtr(c.cef_v8_value_t, global.get_value_bykey.?(global, &suji_key)) orelse return false;
    var fn_key: c.cef_string_t = .{};
    setCefString(&fn_key, "_nextChunk");
    const callback = asPtr(c.cef_v8_value_t, suji_obj.get_value_bykey.?(suji_obj, &fn_key)) orelse return false;
    var data_str: c.cef_string_t = .{};
    setCefString(&data_str, data);
    var call_args = [_][*c]c.cef_v8_value_t{
        c.cef_v8_value_create_int(@intCast(seq_id)),
        c.cef_v8_value_create_int(idx),
        c.cef_v8_value_create_int(total),
        c.cef_v8_value_create_string(&data_str),
    };
    if (call_args[0] == null or call_args[1] == null or call_args[2] == null or call_args[3] == null) return false;
    _ = callback.execute_function.?(callback, suji_obj, call_args.len, &call_args);
    return true;
}

fn callSujiComplete(ctx: *c._cef_v8_context_t, seq_id: u32, success: bool) bool {
    _ = ctx.enter.?(ctx);
    defer _ = ctx.exit.?(ctx);
    const global = asPtr(c.cef_v8_value_t, ctx.get_global.?(ctx)) orelse return false;
    var suji_key: c.cef_string_t = .{};
    setCefString(&suji_key, "__suji__");
    const suji_obj = asPtr(c.cef_v8_value_t, global.get_value_bykey.?(global, &suji_key)) orelse return false;
    var fn_key: c.cef_string_t = .{};
    setCefString(&fn_key, "_chunkComplete");
    const callback = asPtr(c.cef_v8_value_t, suji_obj.get_value_bykey.?(suji_obj, &fn_key)) orelse return false;
    var call_args = [_][*c]c.cef_v8_value_t{
        c.cef_v8_value_create_int(@intCast(seq_id)),
        c.cef_v8_value_create_int(if (success) 1 else 0),
    };
    if (call_args[0] == null or call_args[1] == null) return false;
    _ = callback.execute_function.?(callback, suji_obj, call_args.len, &call_args);
    return true;
}
