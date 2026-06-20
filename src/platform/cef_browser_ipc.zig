//! CEF browser-process IPC — cef.zig 에서 분리(동작 무변경).
//! renderer가 보낸 `suji:invoke`/`suji:emit` 처리와 deferred Promise 응답 슬롯을 담당한다.
const std = @import("std");
const window_mod = @import("window");
const window_ipc = @import("window_ipc");
const cef = @import("cef.zig");
const cef_page_output_constants = @import("cef_page_output_constants.zig");

const c = cef.c;
const asPtr = cef.asPtr;
const setCefString = cef.setCefString;
const cefUserfreeToUtf8 = cef.cefUserfreeToUtf8;
const getArgString = cef.getArgString;
const CEF_IPC_BUF_LEN = cef.CEF_IPC_BUF_LEN;
const PDF_PATH_STACK_BUF = cef_page_output_constants.PDF_PATH_STACK_BUF;

/// IPC 핸들러 콜백 — 메인 프로세스에서 백엔드 호출용
/// channel, data를 받아 response_buf에 JSON 응답을 쓰고 슬라이스 반환.
/// 에러 시 null 반환.
pub const InvokeCallback = *const fn (channel: []const u8, data: []const u8, response_buf: []u8) ?[]const u8;
/// target=null: 모든 창으로 브로드캐스트. non-null: 해당 window id에만.
pub const EmitCallback = *const fn (target: ?u32, event: []const u8, data: []const u8) void;

var g_invoke_callback: ?InvokeCallback = null;
var g_emit_callback: ?EmitCallback = null;
var g_quit_after_next_response: bool = false;

/// 메인 프로세스에서 IPC 핸들러 등록
pub fn setInvokeHandler(cb: InvokeCallback) void {
    g_invoke_callback = cb;
}

pub fn setEmitHandler(cb: EmitCallback) void {
    g_emit_callback = cb;
}

pub fn emitCallback() ?EmitCallback {
    return g_emit_callback;
}

/// Frontend IPC handlers that must return a final response before quitting can
/// request this; browser IPC delivery calls quit immediately after send.
pub fn quitAfterNextResponse() void {
    g_quit_after_next_response = true;
}

// ============================================
// Deferred IPC response — Promise-style 직접 응답 (issue #16)
//
// 기본 IPC: handleBrowserInvoke → 핸들러 동기 응답 → sendInvokeResponse 즉시.
// 일부 핸들러(print_to_pdf/capture_page)는 CDP 콜백을 기다려야 결과를 안다.
// 이전 디자인: ack 즉시 + 별도 EventBus 이벤트(`window:pdf-print-finished` 등) →
//   SDK 가 path 매칭 listener 로 await. 콜백 미발화 경로(#16)에서 listener leak.
// 새 디자인: 핸들러가 `cefDeferResponse(path)` 호출 → 호출 컨텍스트(seq_id,
//   browser, frame) 를 path 키로 보관 + handleBrowserInvoke 는 sendInvokeResponse
//   skip. CDP 콜백에서 `cefCompletePending(path, result)` → 보관된 컨텍스트로
//   응답 송신. EventBus emit 은 그대로(다른 구독자 호환).
// ============================================

/// invoke 핸들러 실행 동안 set — 호출 컨텍스트(응답 송신용).
/// CEF IPC 가 UI 스레드 단일이라 thread_local 불필요(같은 스레드에서 직렬화).
const CallCtx = struct {
    browser: ?*c._cef_browser_t,
    frame: ?*c._cef_frame_t,
    seq_id: i32,
    /// sender browser 의 stable u64 식별자 (br.get_identifier). 창 close 시
    /// onBeforeClose 가 이 핸들로 매칭 슬롯을 purge — dangling 포인터 deref 차단.
    browser_handle: u64,
    deferred: bool,
};
var g_current_call_ctx: ?CallCtx = null;

const PendingResp = struct {
    in_use: bool = false,
    browser: ?*c._cef_browser_t = null,
    frame: ?*c._cef_frame_t = null,
    seq_id: i32 = 0,
    /// print vs capture — 같은 path 교차충돌(PR #54 review #3) 방지 위해 매칭에 포함.
    kind: window_ipc.DeferKind = .print,
    /// 창 close 시 purge 키 (PR #54 review #1, UAF). 0 은 실 browser 아님(CEF id >= 1).
    browser_handle: u64 = 0,
    path_buf: [PDF_PATH_STACK_BUF]u8 = undefined,
    path_len: usize = 0,
};
/// CapturePending 과 동등한 16 슬롯 — 동시 deferred 16 까지. 가득 차면 신규 defer
/// 를 refuse(handler 가 success:false fallback) — 진행 중 슬롯을 evict·재사용하지
/// 않아 evicted op 의 late CDP 가 새 occupant 와 (kind,path) 오매칭하는 race 회피
/// (max code-review #57 후속). pool 은 onBeforeClose purge + SDK 타임아웃으로 bound.
/// 헤드리스 e2e 도 동시 8 미만이라 정상 경로는 refuse 미발생.
var g_pending_responses = [_]PendingResp{.{}} ** 16;

/// 핸들러가 호출: 응답을 보류하고 (kind, path) 키로 컨텍스트 보관. 컨텍스트
/// 미설정/path 무효/슬롯 풀이면 false → 호출자(handler)가 success:false fallback.
/// 슬롯 풀 시 evict 하지 않고 refuse — 진행 중 슬롯을 재사용하면 evicted op 의
/// 늦은 CDP 콜백이 새 occupant 와 (kind,path) 오매칭할 수 있어 회피.
pub fn cefDeferResponse(kind: window_ipc.DeferKind, path: []const u8) bool {
    if (path.len == 0 or path.len > PDF_PATH_STACK_BUF) return false;
    var ctx = g_current_call_ctx orelse return false;

    var target: ?*PendingResp = null;
    for (&g_pending_responses) |*slot| {
        if (!slot.in_use) {
            target = slot;
            break;
        }
    }
    // 빈 슬롯 없음(16 동시 미완료 — 비현실적) → refuse. 호출자(handler)가
    // success:false fallback 송신. evict·재사용 안 함(cross-resolve race 회피).
    const slot = target orelse return false;

    slot.in_use = true;
    slot.browser = ctx.browser;
    slot.frame = ctx.frame;
    slot.seq_id = ctx.seq_id;
    slot.kind = kind;
    slot.browser_handle = ctx.browser_handle;
    @memcpy(slot.path_buf[0..path.len], path);
    slot.path_len = path.len;
    ctx.deferred = true;
    g_current_call_ctx = ctx;
    return true;
}

/// CDP 콜백 등에서 호출: (kind, path) 매칭 pending 에 응답 송신.
/// `result_json` 은 응답 본문. EventBus emit 은 호출자가 별도로 진행 — 이 함수는
/// **deferred Promise resolve 만** 담당. kind 매칭으로 print↔capture 교차충돌 방지.
pub fn cefCompletePending(kind: window_ipc.DeferKind, browser_handle: u64, path: []const u8, result_json: []const u8) bool {
    for (&g_pending_responses) |*slot| {
        if (!slot.in_use) continue;
        if (slot.kind != kind) continue;
        // browser_handle != 0 이면 창까지 매칭해 동일 path 의 cross-window capture 응답이
        // 엉뚱한 렌더러로 라우팅되는 것을 막는다. PDF 는 글로벌 콜백이라 완료 시 handle 을
        // 모르므로 0 을 전달 → (kind,path) 만 매칭(기존 동작 보존).
        if (browser_handle != 0 and slot.browser_handle != browser_handle) continue;
        const stored = slot.path_buf[0..slot.path_len];
        if (!std.mem.eql(u8, stored, path)) continue;
        sendInvokeResponse(slot.browser, slot.frame, slot.seq_id, true, result_json);
        slot.in_use = false;
        slot.path_len = 0;
        slot.browser = null;
        slot.frame = null;
        slot.browser_handle = 0;
        return true;
    }
    return false;
}

/// 닫히는 browser 의 deferred slot 정리(PR #54 review #1, UAF). 곧 freed 될
/// browser/frame 포인터를 deref 하지 않고 in_use=false + null 클리어. 렌더러가
/// 창과 함께 사라지므로 wire 송신 없이 Promise 는 컨텍스트 파괴로 settle.
/// onBeforeClose 에서 cn.purge 직후 호출 — 같은 CEF UI 스레드라 lock 불필요.
pub fn purgeDeferredResponsesForBrowser(handle: u64) void {
    if (handle == 0) return; // 0 은 실 browser 아님 — mass-purge 방지
    for (&g_pending_responses) |*slot| {
        if (!slot.in_use or slot.browser_handle != handle) continue;
        slot.in_use = false;
        slot.path_len = 0;
        slot.browser = null;
        slot.frame = null;
        slot.browser_handle = 0;
    }
}

/// 메인 프로세스: 렌더러에서 온 메시지 처리
pub fn onBrowserProcessMessageReceived(
    _: ?*c._cef_client_t,
    browser: ?*c._cef_browser_t,
    frame: ?*c._cef_frame_t,
    _: c.cef_process_id_t,
    message: ?*c._cef_process_message_t,
) callconv(.c) i32 {
    const msg = message orelse return 0;
    const name_userfree = msg.get_name.?(msg);
    var name_buf: [64]u8 = undefined;
    const msg_name = cefUserfreeToUtf8(name_userfree, &name_buf);
    if (cef.traceIpcEnabled()) {
        std.debug.print("[suji:ipc] browser_msg name={s}\n", .{msg_name});
    }

    if (std.mem.eql(u8, msg_name, "suji:invoke")) {
        return handleBrowserInvoke(browser, frame, msg);
    } else if (std.mem.eql(u8, msg_name, "suji:emit")) {
        return handleBrowserEmit(msg);
    }
    return 0;
}

/// 메인 프로세스: invoke 요청 처리 → 백엔드 호출 → 응답 반환
fn handleBrowserInvoke(
    browser: ?*c._cef_browser_t,
    frame: ?*c._cef_frame_t,
    msg: *c._cef_process_message_t,
) i32 {
    const args = asPtr(c.cef_list_value_t, msg.get_argument_list.?(msg)) orelse return 0;

    // args[0] = seq_id (int), args[1] = channel (string), args[2] = data (string)
    const seq_id = args.get_int.?(args, 0);

    var ch_buf: [256]u8 = undefined;
    const channel = getArgString(args, 1, &ch_buf);

    var data_buf: [CEF_IPC_BUF_LEN]u8 = undefined;
    const data = getArgString(args, 2, &data_buf);
    if (cef.traceIpcEnabled()) {
        std.debug.print("[suji:ipc] recv seq={d} channel={s} data_len={d}\n", .{ seq_id, channel, data.len });
    }

    // Phase 2.5 — wire 레벨 sender 컨텍스트(__window/__window_name/__window_url/__window_main_frame)
    // 자동 주입. 이미 __window가 박혀있는 요청(cross-hop)은 보존.
    var injected_buf: [CEF_IPC_BUF_LEN]u8 = undefined;
    var url_extract_buf: [2048]u8 = undefined;
    const data_to_backend: []const u8 = blk: {
        const br = browser orelse break :blk data;
        const native_handle: u64 = @intCast(br.get_identifier.?(br));
        const wm = window_mod.WindowManager.global orelse break :blk data;
        const win_id = wm.findByNativeHandle(native_handle) orelse break :blk data;
        const win_name: ?[]const u8 = if (wm.get(win_id)) |w| w.name else null;
        // sender 창의 main frame URL. 읽기 실패는 non-fatal — null로 대체.
        const win_url: ?[]const u8 = cef.getMainFrameUrl(br, &url_extract_buf);
        const is_main: ?bool = if (frame) |f| cef.frameIsMain(f) else null;
        break :blk window_ipc.injectWindowField(data, .{
            .window_id = win_id,
            .window_name = win_name,
            .window_url = win_url,
            .is_main_frame = is_main,
        }, &injected_buf) orelse data;
    };

    // 핸들러가 deferred 응답을 등록할 수 있도록 컨텍스트 노출(`cefDeferResponse`).
    // browser_handle 은 창 close 시 purge 키 (UAF 방지). browser 없으면 0(실 핸들 아님).
    const sender_handle: u64 = if (browser) |br| @intCast(br.get_identifier.?(br)) else 0;
    g_current_call_ctx = .{ .browser = browser, .frame = frame, .seq_id = seq_id, .browser_handle = sender_handle, .deferred = false };
    defer g_current_call_ctx = null;

    // 백엔드 호출 — 재사용 큰 힙(4MB)으로 받아 큰 응답을 안 자른다. 송신은 sendInvokeResponse
    // 가 32KB 청크로 분할(작은 건 단일). 콜백 시그니처·핸들러는 전부 그대로.
    const response_buf = responseBuf() orelse return 0;
    var success: bool = false;
    var result: []const u8 = "\"no handler\"";

    if (g_invoke_callback) |cb| {
        if (cb(channel, data_to_backend, response_buf)) |resp| {
            result = resp;
            success = true;
        } else {
            result = "\"backend error\"";
        }
    }

    // 핸들러가 deferred 응답 등록했다면 sendInvokeResponse skip — pending 컨텍스트
    // 에 보관됐고, CDP 콜백 등에서 cefCompletePending 으로 송신될 것.
    const deferred = if (g_current_call_ctx) |ctx| ctx.deferred else false;
    if (cef.traceIpcEnabled()) {
        std.debug.print("[suji:ipc] resp seq={d} success={} result_len={d} deferred={}\n", .{ seq_id, success, result.len, deferred });
    }

    if (!deferred) {
        sendInvokeResponse(browser, frame, seq_id, success, result);
    }
    if (g_quit_after_next_response) {
        g_quit_after_next_response = false;
        cef.quit();
    }
    return 1;
}

// 단일 CefProcessMessage 가 안전히 싣는 청크 크기. 큰 응답은 N개로 쪼개 보내 무제한 지원.
const RESP_CHUNK_LEN: usize = 32 * 1024;

// 백엔드 응답 수용 버퍼(재사용). 콜백이 여기 write → 32KB 청크로 송신. 브라우저 IPC 는 단일
// 스레드라 재사용 안전. lazy alloc(첫 큰 호출 때만). 이 이상(>4MB)은 localhost http 권장.
const RESP_BUF_LEN: usize = 4 * 1024 * 1024;
var g_response_buf: ?[]u8 = null;
fn responseBuf() ?[]u8 {
    if (g_response_buf) |b| return b;
    const b = std.heap.c_allocator.alloc(u8, RESP_BUF_LEN) catch return null;
    g_response_buf = b;
    return b;
}

fn sendInvokeResponse(browser: ?*c._cef_browser_t, frame: ?*c._cef_frame_t, seq_id: i32, success: bool, result: []const u8) void {
    const f = frame orelse blk: {
        const br = browser orelse return;
        break :blk asPtr(c.cef_frame_t, br.get_main_frame.?(br)) orelse return;
    };

    // 작은 응답: 기존 단일 suji:response (회귀 없음).
    if (result.len <= RESP_CHUNK_LEN) {
        sendResponseSingle(f, seq_id, success, result);
        return;
    }

    // 큰 응답: suji:response-chunk ×N → suji:response-complete. JS(_chunks)가 재조립.
    const total: i32 = @intCast((result.len + RESP_CHUNK_LEN - 1) / RESP_CHUNK_LEN);
    var idx: i32 = 0;
    var off: usize = 0;
    while (off < result.len) {
        const end = @min(off + RESP_CHUNK_LEN, result.len);
        sendResponseChunk(f, seq_id, idx, total, result[off..end]);
        off = end;
        idx += 1;
    }
    sendResponseComplete(f, seq_id, success);
}

fn sendResponseSingle(f: *c.cef_frame_t, seq_id: i32, success: bool, result: []const u8) void {
    var resp_name: c.cef_string_t = .{};
    setCefString(&resp_name, "suji:response");
    const resp_msg = asPtr(c.cef_process_message_t, c.cef_process_message_create(&resp_name)) orelse return;

    const resp_args = asPtr(c.cef_list_value_t, resp_msg.get_argument_list.?(resp_msg)) orelse return;
    _ = resp_args.set_int.?(resp_args, 0, seq_id);
    _ = resp_args.set_int.?(resp_args, 1, if (success) 1 else 0);

    var result_str: c.cef_string_t = .{};
    setCefString(&result_str, result);
    _ = resp_args.set_string.?(resp_args, 2, &result_str);

    f.send_process_message.?(f, c.PID_RENDERER, resp_msg);
}

fn sendResponseChunk(f: *c.cef_frame_t, seq_id: i32, idx: i32, total: i32, data: []const u8) void {
    var name: c.cef_string_t = .{};
    setCefString(&name, "suji:response-chunk");
    const msg = asPtr(c.cef_process_message_t, c.cef_process_message_create(&name)) orelse return;
    const args = asPtr(c.cef_list_value_t, msg.get_argument_list.?(msg)) orelse return;
    _ = args.set_int.?(args, 0, seq_id);
    _ = args.set_int.?(args, 1, idx);
    _ = args.set_int.?(args, 2, total);
    var data_str: c.cef_string_t = .{};
    setCefString(&data_str, data);
    _ = args.set_string.?(args, 3, &data_str);
    f.send_process_message.?(f, c.PID_RENDERER, msg);
}

fn sendResponseComplete(f: *c.cef_frame_t, seq_id: i32, success: bool) void {
    var name: c.cef_string_t = .{};
    setCefString(&name, "suji:response-complete");
    const msg = asPtr(c.cef_process_message_t, c.cef_process_message_create(&name)) orelse return;
    const args = asPtr(c.cef_list_value_t, msg.get_argument_list.?(msg)) orelse return;
    _ = args.set_int.?(args, 0, seq_id);
    _ = args.set_int.?(args, 1, if (success) 1 else 0);
    f.send_process_message.?(f, c.PID_RENDERER, msg);
}

/// 메인 프로세스: emit 처리 → EventBus
fn handleBrowserEmit(msg: *c._cef_process_message_t) i32 {
    const args = asPtr(c.cef_list_value_t, msg.get_argument_list.?(msg)) orelse return 0;

    var ev_buf: [256]u8 = undefined;
    const event = getArgString(args, 0, &ev_buf);

    var data_buf: [CEF_IPC_BUF_LEN]u8 = undefined;
    const data = getArgString(args, 1, &data_buf);

    // 3번째 인자 — 선택적 target window id. 없으면(0/미설정) 브로드캐스트.
    const target: ?u32 = blk: {
        const size = args.get_size.?(args);
        if (size < 3) break :blk null;
        const ty = args.get_type.?(args, 2);
        if (ty != c.VTYPE_INT) break :blk null;
        const v = args.get_int.?(args, 2);
        if (v <= 0) break :blk null;
        break :blk @intCast(v);
    };

    std.debug.print("[suji] IPC emit: event={s} target={?}\n", .{ event, target });

    if (g_emit_callback) |cb| {
        cb(target, event, data);
    }
    return 1;
}
