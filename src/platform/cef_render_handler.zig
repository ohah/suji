//! CEF render process/V8 handler — cef.zig 에서 분리(동작 무변경).
//! renderer-side `window.__suji__` 바인딩, invoke/emit 송신, 응답/이벤트 delivery를 담당한다.
const std = @import("std");
const cef = @import("cef.zig");
const cef_render_bootstrap = @import("cef_render_bootstrap.zig");
const cef_render_ipc = @import("cef_render_ipc.zig");

const c = cef.c;
const asPtr = cef.asPtr;
const zeroCefStruct = cef.zeroCefStruct;
const initBaseRefCounted = cef.initBaseRefCounted;
const setCefString = cef.setCefString;
const cefStringToUtf8 = cef.cefStringToUtf8;
const cefUserfreeToUtf8 = cef.cefUserfreeToUtf8;
const CEF_IPC_BUF_LEN = cef.CEF_IPC_BUF_LEN;

var g_render_handler: c.cef_render_process_handler_t = undefined;
var g_render_handler_initialized: bool = false;

// V8 핸들러 (invoke, emit 함수용)
var g_v8_handler: c.cef_v8_handler_t = undefined;

pub fn initRenderHandler() void {
    if (g_render_handler_initialized) return;
    zeroCefStruct(c.cef_render_process_handler_t, &g_render_handler);
    initBaseRefCounted(&g_render_handler.base);
    g_render_handler.on_context_created = &onContextCreated;
    g_render_handler.on_process_message_received = &onRendererProcessMessageReceived;

    zeroCefStruct(c.cef_v8_handler_t, &g_v8_handler);
    initBaseRefCounted(&g_v8_handler.base);
    g_v8_handler.execute = &v8Execute;

    g_render_handler_initialized = true;
}

pub fn getRenderProcessHandler(_: ?*c._cef_app_t) callconv(.c) ?*c._cef_render_process_handler_t {
    if (cef.cefDebug()) std.debug.print("[cef-debug] getRenderProcessHandler called oncreate_set={} init={}\n", .{ g_render_handler.on_context_created != null, g_render_handler_initialized });
    return &g_render_handler;
}

/// V8 컨텍스트 생성 시 window.__suji__ 바인딩
fn onContextCreated(
    _: ?*c._cef_render_process_handler_t,
    _: ?*c._cef_browser_t,
    _: ?*c._cef_frame_t,
    context: ?*c._cef_v8_context_t,
) callconv(.c) void {
    if (cef.cefDebug()) std.debug.print("[cef-debug] onContextCreated ENTRY ctx_null={}\n", .{context == null});
    const ctx = context orelse return;
    cef_render_ipc.rememberRendererContext(ctx);
    const global = asPtr(c.cef_v8_value_t, ctx.get_global.?(ctx)) orelse return;

    // window.__suji__ 오브젝트 생성
    const suji_obj = asPtr(c.cef_v8_value_t, c.cef_v8_value_create_object(null, null)) orelse return;

    // invoke, emit 함수 바인딩 (on/off/__dispatch__는 JS로 주입)
    var invoke_name: c.cef_string_t = .{};
    setCefString(&invoke_name, "invoke");
    const invoke_fn = asPtr(c.cef_v8_value_t, c.cef_v8_value_create_function(&invoke_name, &g_v8_handler)) orelse return;

    var emit_name: c.cef_string_t = .{};
    setCefString(&emit_name, "emit");
    const emit_fn = asPtr(c.cef_v8_value_t, c.cef_v8_value_create_function(&emit_name, &g_v8_handler)) orelse return;

    _ = suji_obj.set_value_bykey.?(suji_obj, &invoke_name, invoke_fn, c.V8_PROPERTY_ATTRIBUTE_NONE);
    _ = suji_obj.set_value_bykey.?(suji_obj, &emit_name, emit_fn, c.V8_PROPERTY_ATTRIBUTE_NONE);

    // window.__suji__ = suji_obj
    var suji_key: c.cef_string_t = .{};
    setCefString(&suji_key, "__suji__");
    _ = global.set_value_bykey.?(global, &suji_key, suji_obj, c.V8_PROPERTY_ATTRIBUTE_NONE);

    // JS 헬퍼: _listeners, on, off, __dispatch__ 주입
    cef_render_bootstrap.injectJsHelpers(ctx);

    std.debug.print("[suji] V8 context created: window.__suji__ bound\n", .{});
}

/// V8 함수 실행 콜백 (invoke, emit, on)
fn v8Execute(
    _: ?*c._cef_v8_handler_t,
    name_ptr: [*c]const c.cef_string_t,
    _: ?*c._cef_v8_value_t,
    arguments_count: usize,
    arguments: [*c]const ?*c.cef_v8_value_t,
    retval: ?*?*c.cef_v8_value_t,
    _: ?*c.cef_string_t,
) callconv(.c) i32 {
    var fn_name_buf: [32]u8 = undefined;
    const fn_name = cefStringToUtf8(name_ptr, &fn_name_buf);

    if (std.mem.eql(u8, fn_name, "invoke")) {
        return v8HandleInvoke(arguments_count, arguments, retval);
    } else if (std.mem.eql(u8, fn_name, "emit")) {
        return v8HandleEmit(arguments_count, arguments);
    }
    return 0;
}

/// raw invoke(channel, json_request) → Promise
/// JS 래퍼가 {cmd: channel, ...data}를 조립해서 json_request로 전달.
/// 1인자: invoke(json_request) — 자동 라우팅
/// 2인자: invoke(target, json_request) — 명시적 백엔드 지정
fn v8HandleInvoke(
    argc: usize,
    argv: [*c]const ?*c.cef_v8_value_t,
    retval: ?*?*c.cef_v8_value_t,
) i32 {
    if (argc < 1) return 0;

    var channel_buf: [256]u8 = undefined;
    var channel: []const u8 = "";
    var request_buf: [CEF_IPC_BUF_LEN]u8 = undefined;
    var request: []const u8 = "{}";

    if (argc >= 2) {
        // 2인자: invoke(target_or_channel, json_request)
        const arg0 = argv[0] orelse return 0;
        channel = cefUserfreeToUtf8(arg0.get_string_value.?(arg0), &channel_buf);
        const arg1 = argv[1] orelse return 0;
        if (arg1.is_string.?(arg1) == 1) {
            request = cefUserfreeToUtf8(arg1.get_string_value.?(arg1), &request_buf);
        }
    } else {
        // 1인자: invoke(json_request) — cmd 필드에서 채널 추출
        const arg0 = argv[0] orelse return 0;
        if (arg0.is_string.?(arg0) == 1) {
            request = cefUserfreeToUtf8(arg0.get_string_value.?(arg0), &request_buf);
            // {"cmd":"ping",...} 에서 cmd 추출
            channel = extractCmd(request) orelse "";
        }
    }
    if (channel.len == 0) return 0;
    const ctx = cef_render_ipc.currentOrLastRendererContext() orelse {
        cef_render_ipc.traceRendererInvokeSendFailed(channel);
        return 0;
    };

    // 시퀀스 ID 할당 (JS에서 Promise 관리)
    const seq_id = cef_render_ipc.nextSeqId();

    // CefProcessMessage 생성하여 메인 프로세스에 전송
    var msg_name: c.cef_string_t = .{};
    setCefString(&msg_name, "suji:invoke");
    const msg = asPtr(c.cef_process_message_t, c.cef_process_message_create(&msg_name)) orelse return 0;

    const args = asPtr(c.cef_list_value_t, msg.get_argument_list.?(msg)) orelse return 0;
    _ = args.set_int.?(args, 0, @intCast(seq_id));

    var ch_str: c.cef_string_t = .{};
    setCefString(&ch_str, channel);
    _ = args.set_string.?(args, 1, &ch_str);

    // JS에서 이미 {cmd: channel, ...data}로 조립된 JSON을 그대로 전달
    var req_str: c.cef_string_t = .{};
    setCefString(&req_str, request);
    _ = args.set_string.?(args, 2, &req_str);

    // 컨텍스트 저장 (응답 시 callback delivery에 필요)
    cef_render_ipc.rememberPendingContext(seq_id, ctx);
    if (!cef_render_ipc.sendToBrowserFromContext(ctx, msg)) {
        cef_render_ipc.clearPendingContext(seq_id);
        cef_render_ipc.traceRendererInvokeSendFailed(channel);
        return 0;
    }
    if (cef.traceIpcEnabled()) {
        std.debug.print("[suji:ipc] renderer_invoke_sent seq={d} channel={s}\n", .{ seq_id, channel });
    }

    // Promise 반환
    // seq_id를 JS에 반환 (JS가 이걸로 Promise를 _pending에 등록)
    if (retval) |rv| {
        rv.* = c.cef_v8_value_create_int(@intCast(seq_id));
    }
    return 1;
}

/// emit(event, data, target?) → void
/// target은 선택적 window id. JS 레이어가 `suji.send(..., {to: id})`에서 정수로 전달.
fn v8HandleEmit(argc: usize, argv: [*c]const ?*c.cef_v8_value_t) i32 {
    if (argc < 1) return 0;

    const event_v8 = argv[0] orelse return 0;
    var event_buf: [256]u8 = undefined;
    const event_userfree = event_v8.get_string_value.?(event_v8);
    const event = cefUserfreeToUtf8(event_userfree, &event_buf);

    var data_buf: [CEF_IPC_BUF_LEN]u8 = undefined;
    var data: []const u8 = "{}";
    if (argc >= 2) {
        const data_v8 = argv[1];
        if (data_v8 != null and data_v8.?.is_string.?(data_v8) == 1) {
            const data_userfree = data_v8.?.get_string_value.?(data_v8);
            data = cefUserfreeToUtf8(data_userfree, &data_buf);
        }
    }

    // 3번째 인자: 선택적 target window id. number가 아니거나 < 1이면 브로드캐스트로 취급.
    var target: i32 = 0;
    if (argc >= 3) {
        const t_v8 = argv[2];
        if (t_v8 != null and t_v8.?.is_int.?(t_v8) == 1) {
            target = t_v8.?.get_int_value.?(t_v8);
        } else if (t_v8 != null and t_v8.?.is_uint.?(t_v8) == 1) {
            target = @intCast(t_v8.?.get_uint_value.?(t_v8));
        }
    }

    // CefProcessMessage로 메인 프로세스에 전송
    var msg_name: c.cef_string_t = .{};
    setCefString(&msg_name, "suji:emit");
    const msg = asPtr(c.cef_process_message_t, c.cef_process_message_create(&msg_name)) orelse return 0;

    const args = asPtr(c.cef_list_value_t, msg.get_argument_list.?(msg)) orelse return 0;

    var ev_str: c.cef_string_t = .{};
    setCefString(&ev_str, event);
    _ = args.set_string.?(args, 0, &ev_str);

    var data_str: c.cef_string_t = .{};
    setCefString(&data_str, data);
    _ = args.set_string.?(args, 1, &data_str);

    if (target > 0) {
        _ = args.set_int.?(args, 2, target);
    }

    if (!cef_render_ipc.sendToBrowser(msg)) {
        cef_render_ipc.traceRendererEmitSendFailed(event);
        return 0;
    }
    if (cef.traceIpcEnabled()) {
        std.debug.print("[suji:ipc] renderer_emit_sent event={s}\n", .{event});
    }
    return 1;
}

/// 렌더러 프로세스: 메인에서 온 응답/이벤트 처리
fn onRendererProcessMessageReceived(
    _: ?*c._cef_render_process_handler_t,
    _: ?*c._cef_browser_t,
    _: ?*c._cef_frame_t,
    _: c.cef_process_id_t,
    message: ?*c._cef_process_message_t,
) callconv(.c) i32 {
    const msg = message orelse return 0;
    const name_userfree = msg.get_name.?(msg);
    var name_buf: [64]u8 = undefined;
    const msg_name = cefUserfreeToUtf8(name_userfree, &name_buf);

    if (std.mem.eql(u8, msg_name, "suji:response")) {
        return cef_render_ipc.handleRendererResponse(msg);
    } else if (std.mem.eql(u8, msg_name, "suji:response-chunk")) {
        return cef_render_ipc.handleRendererChunk(msg);
    } else if (std.mem.eql(u8, msg_name, "suji:response-complete")) {
        return cef_render_ipc.handleRendererComplete(msg);
    } else if (std.mem.eql(u8, msg_name, "suji:event")) {
        return cef_render_ipc.handleRendererEvent(msg);
    }
    return 0;
}

/// JSON에서 "cmd":"value" 추출
fn extractCmd(json: []const u8) ?[]const u8 {
    const pattern = "\"cmd\":\"";
    const idx = std.mem.indexOf(u8, json, pattern) orelse return null;
    const start = idx + pattern.len;
    const end = std.mem.indexOfPos(u8, json, start, "\"") orelse return null;
    return json[start..end];
}
