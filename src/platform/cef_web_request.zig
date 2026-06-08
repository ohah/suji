//! session.webRequest API — cef.zig 에서 분리(동작 무변경).
//! URL glob blocklist + async onBeforeRequest listener + CEF resource callbacks.
const std = @import("std");
const util = @import("util");
const cef = @import("cef.zig");

const c = cef.c;
const zeroCefStruct = cef.zeroCefStruct;
const initBaseRefCounted = cef.initBaseRefCounted;
const cefUserfreeToUtf8 = cef.cefUserfreeToUtf8;
const cefStringToUtf8 = cef.cefStringToUtf8;

// ============================================
// CEF Request Handler — webRequest URL filter (Electron `session.webRequest`)
// ============================================
// blocked_urls 글롭 패턴 매칭 시 OnBeforeResourceLoad가 RV_CANCEL 반환.
// `webRequest:before-request` (URL/method) + `webRequest:completed` (URL/status/error)
// 두 채널을 EventBus로 비동기 emit. 패턴 list는 process global + mutex.

pub const WebRequestEmitFn = *const fn (channel: [*:0]const u8, payload: [*:0]const u8) callconv(.c) void;
var g_webrequest_emit_fn: ?WebRequestEmitFn = null;

pub fn setWebRequestEmitHandler(fn_ptr: WebRequestEmitFn) void {
    g_webrequest_emit_fn = fn_ptr;
}

pub fn emitWebRequestPayload(channel_cstr: [*:0]const u8, payload_cstr: [*:0]const u8) void {
    const emit = g_webrequest_emit_fn orelse return;
    emit(channel_cstr, payload_cstr);
}

/// 매번 alloc 피하기 위해 fixed-size pool. 패턴 1개당 ≤ 256 bytes, 32개까지.
const MAX_WEB_REQUEST_PATTERNS: usize = 32;
const MAX_WEB_REQUEST_PATTERN_LEN: usize = 256;

/// Generic glob 패턴 pool — set/match. blocked + listener filter 두 인스턴스로 사용.
/// 각자 자기 lock + count(atomic)로 fast path는 lock-free.
/// Zig 0.16에서 std.Thread.Mutex 제거 — IO thread read/IPC write 짧은 critical section은
/// atomic spinlock으로 충분.
const UrlGlobPool = struct {
    patterns: [MAX_WEB_REQUEST_PATTERNS][MAX_WEB_REQUEST_PATTERN_LEN]u8 = undefined,
    lens: [MAX_WEB_REQUEST_PATTERNS]usize = .{0} ** MAX_WEB_REQUEST_PATTERNS,
    count: usize = 0,
    lock_flag: std.atomic.Value(bool) = .init(false),

    fn lock(self: *UrlGlobPool) void {
        while (self.lock_flag.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }
    fn unlock(self: *UrlGlobPool) void {
        self.lock_flag.store(false, .release);
    }

    /// 패턴 list 전체 교체 (atomic). 빈 list = 모든 요청 통과. count는 atomic store —
    /// `matchesAny`의 fast path가 spinlock 없이 검사 가능.
    fn set(self: *UrlGlobPool, items: []const []const u8) usize {
        self.lock();
        defer self.unlock();
        const n = @min(items.len, MAX_WEB_REQUEST_PATTERNS);
        for (0..n) |i| {
            const p = items[i];
            const len = @min(p.len, MAX_WEB_REQUEST_PATTERN_LEN);
            @memcpy(self.patterns[i][0..len], p[0..len]);
            self.lens[i] = len;
        }
        @atomicStore(usize, &self.count, n, .release);
        return n;
    }

    fn matchesAny(self: *UrlGlobPool, url: []const u8) bool {
        // Fast path — 패턴 없는 보통의 앱은 spinlock 회피.
        if (@atomicLoad(usize, &self.count, .acquire) == 0) return false;
        self.lock();
        defer self.unlock();
        for (0..self.count) |i| {
            const pat = self.patterns[i][0..self.lens[i]];
            if (util.matchGlob(pat, url)) return true;
        }
        return false;
    }
};

var g_blocked_url_pool: UrlGlobPool = .{};

pub fn webRequestSetBlockedUrls(patterns: []const []const u8) usize {
    return g_blocked_url_pool.set(patterns);
}

// ============================================
// webRequest dynamic listener — RV_CONTINUE_ASYNC pending callback storage.
// ============================================
// Electron `session.webRequest.onBeforeRequest({urls}, listener)` — listener가 callback
// (decision)으로 cancel 결정. CEF는 OnBeforeResourceLoad에서 RV_CONTINUE_ASYNC 반환
// → callback->cont/cancel을 외부에서 호출할 때까지 요청 hold. listener 응답 IPC가
// resolve(id, cancel)로 callback 결정.
//
// 주의: 네이티브는 listener 응답까지 hold (단일스레드·무 CEF-task 라 설계상 유지).
// timeout fallback 은 caller(=JS SDK `webRequest.onBeforeRequest`)가 이행 —
// listener 미응답/throw 시 timeoutMs 후 web_request_resolve(allow) 자동 송신해
// 이 hold 를 해제(cookie SDK 타임아웃 선례 동형).

var g_listener_url_pool: UrlGlobPool = .{};

const MAX_PENDING_CALLBACKS: usize = 256;

const PendingCallback = struct {
    id: u64,
    callback: *c._cef_callback_t,
};

var g_pending_callbacks: [MAX_PENDING_CALLBACKS]PendingCallback = undefined;
var g_pending_count: usize = 0;
var g_pending_lock: std.atomic.Value(bool) = .init(false);
var g_request_id_counter: std.atomic.Value(u64) = .init(0);
/// pool overflow drop 카운터 (diagnostics) — 256 동시 pending 초과 시 RV_CONTINUE fallback.
var g_pending_drops: std.atomic.Value(u64) = .init(0);

fn pendingLock() void {
    while (g_pending_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
        std.atomic.spinLoopHint();
    }
}
fn pendingUnlock() void {
    g_pending_lock.store(false, .release);
}

/// listener filter pattern 등록. blocklist와 별도 — 이 filter에 매칭되면
/// `webRequest:will-request` 이벤트 발화 + RV_CONTINUE_ASYNC. 빈 list = listener 없음.
pub fn webRequestSetListenerFilter(patterns: []const []const u8) usize {
    return g_listener_url_pool.set(patterns);
}

/// 진단용 — pending pool overflow drop 카운터. 0이 정상.
pub fn webRequestPendingDrops() u64 {
    return g_pending_drops.load(.monotonic);
}

/// CEF callback을 pending pool에 저장 후 id 반환. caller가 add_ref 보장.
/// 가득 차면 0 (resolve 안 된 채로 buffer overflow 방지).
fn pendingPush(callback: *c._cef_callback_t) u64 {
    pendingLock();
    defer pendingUnlock();
    if (g_pending_count >= MAX_PENDING_CALLBACKS) return 0;
    const id = g_request_id_counter.fetchAdd(1, .monotonic) + 1;
    g_pending_callbacks[g_pending_count] = .{ .id = id, .callback = callback };
    g_pending_count += 1;
    return id;
}

/// pending pool에서 id로 callback 추출 (consume). 없으면 null.
fn pendingTake(id: u64) ?*c._cef_callback_t {
    pendingLock();
    defer pendingUnlock();
    var i: usize = 0;
    while (i < g_pending_count) : (i += 1) {
        if (g_pending_callbacks[i].id == id) {
            const cb = g_pending_callbacks[i].callback;
            g_pending_callbacks[i] = g_pending_callbacks[g_pending_count - 1];
            g_pending_count -= 1;
            return cb;
        }
    }
    return null;
}

/// json[from..] 에서 다음 `"..."`(escape 인지)의 inner raw slice + 닫는 따옴표 다음 위치.
const StrTok = struct { raw: []const u8, end: usize };
fn nextJsonString(json: []const u8, from: usize) ?StrTok {
    var i = from;
    while (i < json.len and json[i] != '"') : (i += 1) {}
    if (i >= json.len) return null;
    const start = i + 1;
    var j = start;
    while (j < json.len) : (j += 1) {
        if (json[j] == '\\') {
            j += 1;
            continue;
        }
        if (json[j] == '"') return .{ .raw = json[start..j], .end = j + 1 };
    }
    return null;
}

/// Electron onBeforeSendHeaders — requestHeaders `{"k":"v",...}` 를 request 에 적용(overwrite).
/// 평면 string→string 객체라 따옴표 토큰을 key/value 교대로 스캔(`:`/`,`/`{}` 무시). 키/값은
/// unescape. 최대 64개, 키 256/값 4096 초과는 skip. cef_request_t.set_header_by_name.
/// **반드시 OnBeforeResourceLoad 동기 구간에서 호출** — CEF 는 RV_CONTINUE_ASYNC 반환 후의
/// request 수정을 무시한다(echo-server e2e 로 실증). 그래서 declarative(set_request_headers)
/// 경로에서만 사용하고, async listener resolve 경로에서는 헤더 수정 불가(정직 경계).
fn applyRequestHeaders(request: *c._cef_request_t, json: []const u8) void {
    const set_header = request.set_header_by_name orelse return;
    var pos: usize = 0;
    var applied: usize = 0;
    while (applied < 64) : (applied += 1) {
        const key_tok = nextJsonString(json, pos) orelse break;
        const val_tok = nextJsonString(json, key_tok.end) orelse break;
        pos = val_tok.end;
        var key_buf: [256]u8 = undefined;
        var val_buf: [4096]u8 = undefined;
        const kn = util.unescapeJsonStr(key_tok.raw, &key_buf) orelse continue;
        const vn = util.unescapeJsonStr(val_tok.raw, &val_buf) orelse continue;
        if (kn == 0) continue;
        var key_cs: c.cef_string_t = .{};
        var val_cs: c.cef_string_t = .{};
        cef.setCefString(&key_cs, key_buf[0..kn]);
        cef.setCefString(&val_cs, val_buf[0..vn]);
        set_header(request, &key_cs, &val_cs, 1); // overwrite=1
        if (key_cs.dtor) |d| d(key_cs.str);
        if (val_cs.dtor) |d| d(val_cs.str);
    }
}

/// listener 응답 — id로 pending callback 찾아 cont/cancel. 없는 id면 false.
pub fn webRequestResolve(id: u64, cancel_request: bool) bool {
    const cb = pendingTake(id) orelse return false;
    if (cancel_request) {
        if (cb.cancel) |fp| fp(cb);
    } else {
        if (cb.cont) |fp| fp(cb);
    }
    if (cb.base.release) |rel| _ = rel(&cb.base);
    return true;
}

// ============================================
// onBeforeSendHeaders — declarative 요청 헤더 주입(동기, OnBeforeResourceLoad).
// ============================================
// CEF 가 async resolve 후 request 수정을 무시하므로(echo e2e 실증), per-request JS 콜백
// 대신 선언적: setRequestHeaders(urls, headers) 로 URL glob 매칭 요청에 동기 적용.
var g_request_headers_url_pool: UrlGlobPool = .{};
var g_request_headers_buf: [8192]u8 = undefined;
var g_request_headers_len: usize = 0;
var g_request_headers_lock: std.atomic.Value(bool) = .init(false);

/// Electron `session.webRequest.onBeforeSendHeaders` 의 declarative 변형 — urls glob 매칭
/// 요청에 headers_json `{"k":"v",...}` 를 동기 적용(overwrite). 빈 patterns = 해제.
/// 반환값은 등록된 patterns 개수. headers_json 은 8KB 초과 시 truncate(정상 헤더엔 충분).
pub fn webRequestSetRequestHeaders(patterns: []const []const u8, headers_json: []const u8) usize {
    while (g_request_headers_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    defer g_request_headers_lock.store(false, .release);
    const n = @min(headers_json.len, g_request_headers_buf.len);
    @memcpy(g_request_headers_buf[0..n], headers_json[0..n]);
    g_request_headers_len = n;
    return g_request_headers_url_pool.set(patterns);
}

var g_resource_request_handler: c.cef_resource_request_handler_t = undefined;
var g_resource_request_handler_initialized: bool = false;

fn ensureResourceRequestHandler() void {
    if (g_resource_request_handler_initialized) return;
    zeroCefStruct(c.cef_resource_request_handler_t, &g_resource_request_handler);
    initBaseRefCounted(&g_resource_request_handler.base);
    g_resource_request_handler.on_before_resource_load = &onBeforeResourceLoad;
    g_resource_request_handler.on_resource_load_complete = &onResourceLoadComplete;
    g_resource_request_handler_initialized = true;
}

pub fn getResourceRequestHandler(
    _: ?*c._cef_request_handler_t,
    _: ?*c._cef_browser_t,
    _: ?*c._cef_frame_t,
    _: ?*c._cef_request_t,
    _: c_int,
    _: c_int,
    _: [*c]const c.cef_string_t,
    disable_default_handling: [*c]c_int,
) callconv(.c) ?*c._cef_resource_request_handler_t {
    if (disable_default_handling != null) disable_default_handling.* = 0;
    ensureResourceRequestHandler();
    return &g_resource_request_handler;
}

fn emitWebRequestEvent(channel_cstr: [*:0]const u8, url: []const u8, extra_json: []const u8) void {
    const emit = g_webrequest_emit_fn orelse return;
    // responseHeaders(completed) 가 수 KB 가 될 수 있어 넉넉히.
    var payload_buf: [16384]u8 = undefined;
    var url_esc_buf: [2048]u8 = undefined;
    const url_esc_n = util.escapeJsonStrFull(url, &url_esc_buf) orelse return;
    const payload = std.fmt.bufPrintZ(
        &payload_buf,
        "{{\"url\":\"{s}\"{s}{s}}}",
        .{ url_esc_buf[0..url_esc_n], if (extra_json.len > 0) "," else "", extra_json },
    ) catch return;
    emit(channel_cstr, payload.ptr);
}

/// buf 에 s 를 append, n 갱신. 초과 시 false(미변경).
fn appendStr(buf: []u8, n: *usize, s: []const u8) bool {
    if (n.* + s.len > buf.len) return false;
    @memcpy(buf[n.*..][0..s.len], s);
    n.* += s.len;
    return true;
}

/// response 헤더맵 → `{"k":"v",...}` JSON 을 buf 에 작성, 슬라이스 반환. 마지막 1바이트는
/// 닫는 '}' 예약(brace 항상 보장). 한 헤더가 안 들어가면 거기서 멈추고 객체를 닫는다
/// (graceful truncation — 유효 JSON 유지). 키/값 cef_string 은 escape + dtor 해제.
fn buildResponseHeadersJson(resp: *c.cef_response_t, buf: []u8) []const u8 {
    const work = buf[0 .. buf.len - 1]; // '}' 1바이트 예약
    var n: usize = 0;
    _ = appendStr(work, &n, "{");
    const get_map = resp.get_header_map orelse {
        buf[n] = '}';
        return buf[0 .. n + 1];
    };
    const map = c.cef_string_multimap_alloc();
    if (map == null) {
        buf[n] = '}';
        return buf[0 .. n + 1];
    }
    defer c.cef_string_multimap_free(map);
    get_map(resp, map);
    const size = c.cef_string_multimap_size(map);
    var first = true;
    var i: usize = 0;
    while (i < size) : (i += 1) {
        var key_cs: c.cef_string_t = .{};
        var val_cs: c.cef_string_t = .{};
        const has_key = c.cef_string_multimap_key(map, i, &key_cs) == 1;
        const has_val = c.cef_string_multimap_value(map, i, &val_cs) == 1;
        defer {
            if (key_cs.dtor) |d| d(key_cs.str);
            if (val_cs.dtor) |d| d(val_cs.str);
        }
        if (!has_key or !has_val) continue;
        var k_utf8: [256]u8 = undefined;
        var v_utf8: [2048]u8 = undefined;
        var k_esc: [512]u8 = undefined;
        var v_esc: [4096]u8 = undefined;
        const ke = util.escapeJsonStrFull(cefStringToUtf8(&key_cs, &k_utf8), &k_esc) orelse continue;
        const ve = util.escapeJsonStrFull(cefStringToUtf8(&val_cs, &v_utf8), &v_esc) orelse continue;
        const checkpoint = n;
        var ok = true;
        if (!first) ok = ok and appendStr(work, &n, ",");
        ok = ok and appendStr(work, &n, "\"");
        ok = ok and appendStr(work, &n, k_esc[0..ke]);
        ok = ok and appendStr(work, &n, "\":\"");
        ok = ok and appendStr(work, &n, v_esc[0..ve]);
        ok = ok and appendStr(work, &n, "\"");
        if (!ok) {
            n = checkpoint; // 이 헤더가 안 들어가면 되돌리고 객체 닫기
            break;
        }
        first = false;
    }
    buf[n] = '}';
    return buf[0 .. n + 1];
}

fn onBeforeResourceLoad(
    _: ?*c._cef_resource_request_handler_t,
    _: ?*c._cef_browser_t,
    _: ?*c._cef_frame_t,
    request: ?*c._cef_request_t,
    callback: ?*c._cef_callback_t,
) callconv(.c) c.cef_return_value_t {
    const req = request orelse return c.RV_CONTINUE;
    const get_url = req.get_url orelse return c.RV_CONTINUE;
    var url_buf: [2048]u8 = undefined;
    const url = cefUserfreeToUtf8(get_url(req), &url_buf);
    if (url.len == 0) return c.RV_CONTINUE;

    // 1. blocklist 우선 — 매칭되면 비동기 listener 거치지 않고 즉시 cancel.
    if (g_blocked_url_pool.matchesAny(url)) {
        emitWebRequestEvent("webRequest:before-request", url, "");
        return c.RV_CANCEL;
    }

    // 1b. onBeforeSendHeaders (declarative) — URL 매칭 시 요청 헤더를 **동기** 적용.
    // CEF 는 RV_CONTINUE_ASYNC 후 수정을 무시하므로 반드시 여기(반환 전)서 적용해야 한다.
    if (g_request_headers_url_pool.matchesAny(url)) {
        while (g_request_headers_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
        defer g_request_headers_lock.store(false, .release);
        if (g_request_headers_len > 0) applyRequestHeaders(req, g_request_headers_buf[0..g_request_headers_len]);
    }

    // 2. listener filter 매칭 — async pending. add_ref 후 pool에 저장 + JS listener emit.
    if (callback) |cb| {
        if (g_listener_url_pool.matchesAny(url)) {
            if (cb.base.add_ref) |add_ref| _ = add_ref(&cb.base);
            const id = pendingPush(cb);
            if (id == 0) {
                // pending pool 가득 — fallback to 즉시 release + 통과 + drop 카운터 증가.
                _ = g_pending_drops.fetchAdd(1, .monotonic);
                if (cb.base.release) |rel| _ = rel(&cb.base);
                emitWebRequestEvent("webRequest:before-request", url, "");
                return c.RV_CONTINUE;
            }
            var extra_buf: [64]u8 = undefined;
            const extra = std.fmt.bufPrint(&extra_buf, "\"id\":{d}", .{id}) catch "";
            emitWebRequestEvent("webRequest:will-request", url, extra);
            return c.RV_CONTINUE_ASYNC;
        }
    }

    // 3. 일반 — fire-and-forget before-request 이벤트만.
    emitWebRequestEvent("webRequest:before-request", url, "");
    return c.RV_CONTINUE;
}

fn onResourceLoadComplete(
    _: ?*c._cef_resource_request_handler_t,
    _: ?*c._cef_browser_t,
    _: ?*c._cef_frame_t,
    request: ?*c._cef_request_t,
    response: ?*c._cef_response_t,
    status: c.cef_urlrequest_status_t,
    received_content_length: i64,
) callconv(.c) void {
    const req = request orelse return;
    const get_url = req.get_url orelse return;
    var url_buf: [2048]u8 = undefined;
    const url = cefUserfreeToUtf8(get_url(req), &url_buf);
    if (url.len == 0) return;

    var status_code: c_int = 0;
    var status_text_buf: [256]u8 = undefined;
    var status_text: []const u8 = "";
    var headers_buf: [12288]u8 = undefined;
    var headers_json: []const u8 = "{}";
    if (response) |resp| {
        if (resp.get_status) |get_status| status_code = get_status(resp);
        if (resp.get_status_text) |get_status_text| status_text = cefUserfreeToUtf8(get_status_text(resp), &status_text_buf);
        headers_json = buildResponseHeadersJson(resp, &headers_buf);
    }
    var st_esc: [512]u8 = undefined;
    const st_n = util.escapeJsonStrFull(status_text, &st_esc) orelse 0;
    // Electron onHeadersReceived 패리티 — statusText + responseHeaders 를 completed 에 포함.
    var extra_buf: [13312]u8 = undefined;
    const extra = std.fmt.bufPrint(
        &extra_buf,
        "\"statusCode\":{d},\"requestStatus\":{d},\"receivedBytes\":{d},\"statusText\":\"{s}\",\"responseHeaders\":{s}",
        .{ status_code, @as(i32, @intCast(status)), received_content_length, st_esc[0..st_n], headers_json },
    ) catch return;
    emitWebRequestEvent("webRequest:completed", url, extra);
}
