//! Session cookies/storage — cef.zig 에서 분리(동작 무변경). CEF
//! cookie_manager + visitor, CDP Storage.clearDataForOrigin bridge.
const std = @import("std");
const util = @import("util");
const window_mod = @import("window");
const cef = @import("cef.zig");

const c = cef.c;
const asPtr = cef.asPtr;
const zeroCefStruct = cef.zeroCefStruct;
const setCefString = cef.setCefString;
const clearCefString = cef.clearCefString;
const cefStringToUtf8 = cef.cefStringToUtf8;
const initBaseRefCounted = cef.initBaseRefCounted;

/// 모든 cookie 삭제 (Electron `session.clearStorageData` 동등 부분).
/// callback null → CEF 내부 async. visit/set 등 round-trip은 후속.
pub fn sessionClearCookies() bool {
    const mgr = asPtr(c.cef_cookie_manager_t, c.cef_cookie_manager_get_global_manager(null)) orelse return false;
    defer if (mgr.base.release) |rel| {
        _ = rel(&mgr.base);
    };
    const delete_fn = mgr.delete_cookies orelse return false;
    var empty_url: c.cef_string_t = .{};
    var empty_name: c.cef_string_t = .{};
    _ = delete_fn(mgr, &empty_url, &empty_name, null);
    return true;
}

/// disk store flush (Electron `session.cookies.flushStore`).
pub fn sessionFlushStore() bool {
    const mgr = asPtr(c.cef_cookie_manager_t, c.cef_cookie_manager_get_global_manager(null)) orelse return false;
    defer if (mgr.base.release) |rel| {
        _ = rel(&mgr.base);
    };
    const flush_fn = mgr.flush_store orelse return false;
    _ = flush_fn(mgr, null);
    return true;
}

/// IndexedDB/localStorage/cache 삭제 (Electron `session.clearStorageData`).
/// CEF 는 직접 미제공 → CDP `Storage.clearDataForOrigin`(+ 캐시는
/// `Network.clearBrowserCache`)를 send_dev_tools_message 로. setUserAgent
/// 와 동일한 fire-and-forget(id:1, 응답 미파싱) — clearCookies 와 동형 정책.
///
/// ⚠️ 정직 경계: IndexedDB/localStorage 는 origin-scoped 라 origin 없이
/// "전 origin 일괄 삭제"는 단일 CDP 호출로 불가(Electron 프로필-전역 wipe
/// 정확 복제는 CDP 구조상 불가 — 진짜 제약). 대신 origin 미지정 시 **현재
/// 문서 origin 을 자동 주입**(getMainFrameUrl→util.originFromUrl) — 무인자
/// 호출이 "내 앱 스토리지를 비운다"는 직관대로 동작. file:// 는 authority
/// 가 없어 origin="file://" best-effort(불투명 origin, fire-and-forget이라
/// 허용). 자동 해석 실패(about:/data: 등) 시엔 전역 HTTP 캐시만.
/// storage_types: CDP 콤마구분("all" | "local_storage,indexeddb,..." 등).
pub fn sessionClearStorageData(origin: []const u8, storage_types: []const u8) bool {
    const br = cef.currentBrowser() orelse return false;
    const host = cef.devtoolsHost(br) orelse return false;
    const send = host.send_dev_tools_message orelse return false;

    // origin 미지정 → 현재 문서 origin 자동 해석(앱 자기 스토리지 대상).
    var url_buf: [2048]u8 = undefined;
    const eff_origin: []const u8 = if (origin.len > 0)
        origin
    else if (cef.getMainFrameUrl(br, &url_buf)) |u|
        util.originFromUrl(u) orelse ""
    else
        "";

    if (eff_origin.len > 0) {
        // origin/types escape (origin 은 URL 이라 escape 필수, types 도 방어적).
        var o_esc: [2048]u8 = undefined;
        var t_esc: [512]u8 = undefined;
        const on = window_mod.escapeJsonChars(eff_origin[0..@min(eff_origin.len, 1024)], &o_esc);
        const tn = window_mod.escapeJsonChars(storage_types[0..@min(storage_types.len, 256)], &t_esc);
        var msg: [3072]u8 = undefined;
        const m = std.fmt.bufPrint(
            &msg,
            "{{\"id\":1,\"method\":\"Storage.clearDataForOrigin\",\"params\":{{\"origin\":\"{s}\",\"storageTypes\":\"{s}\"}}}}",
            .{ o_esc[0..on], t_esc[0..tn] },
        ) catch return false;
        _ = send(host, m.ptr, m.len);
    }
    // HTTP/서비스워커 캐시는 origin 무관 전역 — 항상 best-effort.
    const cache_msg = "{\"id\":1,\"method\":\"Network.clearBrowserCache\",\"params\":{}}";
    _ = send(host, cache_msg.ptr, cache_msg.len);
    return true;
}

// ============================================
// Session Cookies — set / get / remove (Electron `session.cookies.*`)
// ============================================
// Electron `session.cookies.set/get/remove` 동등.
//   - set/remove: fire-and-forget, callback null. URL 검증만 sync 반환.
//   - get: visit_url_cookies 비동기 — visitor가 cookies 누적, release(refcount=0) 시
//     `session:cookies-result` 이벤트 발화. JS SDK는 requestId로 promise resolve.
//     동시 visit pool 4개 (in_use 플래그 + atomic acquire).
//
// `cef_basetime_t` ↔ unix epoch second 변환은 cef_time_from_doublet/cef_time_to_basetime
// 페어 사용 (CEF 정식 경로).

fn unixSecToBasetime(sec: f64) c.cef_basetime_t {
    var t: c.cef_time_t = undefined;
    _ = c.cef_time_from_doublet(sec, &t);
    var bt: c.cef_basetime_t = .{ .val = 0 };
    _ = c.cef_time_to_basetime(&t, &bt);
    return bt;
}

fn basetimeToUnixSec(bt: c.cef_basetime_t) f64 {
    var t: c.cef_time_t = undefined;
    _ = c.cef_time_from_basetime(bt, &t);
    var sec: f64 = 0;
    _ = c.cef_time_to_doublet(&t, &sec);
    return sec;
}

/// cookie set — URL 필수, 나머지 옵션. fire-and-forget (callback null).
/// CEF가 URL을 검증해 invalid면 false. set_cookie는 path/domain 빈 문자열은 host
/// cookie로 처리 (Electron 동등).
pub fn sessionSetCookie(
    url: []const u8,
    name: []const u8,
    value: []const u8,
    domain: []const u8,
    path: []const u8,
    secure: bool,
    httponly: bool,
    expires_unix_sec: f64, // 0 → 세션 쿠키
) bool {
    if (url.len == 0 or name.len == 0) return false;
    const mgr = asPtr(c.cef_cookie_manager_t, c.cef_cookie_manager_get_global_manager(null)) orelse return false;
    defer if (mgr.base.release) |rel| {
        _ = rel(&mgr.base);
    };
    const set_fn = mgr.set_cookie orelse return false;

    var cef_url: c.cef_string_t = .{};
    setCefString(&cef_url, url);
    var cookie: c.cef_cookie_t = undefined;
    zeroCefStruct(c.cef_cookie_t, &cookie);
    setCefString(&cookie.name, name);
    setCefString(&cookie.value, value);
    if (domain.len > 0) setCefString(&cookie.domain, domain);
    if (path.len > 0) setCefString(&cookie.path, path);
    cookie.secure = if (secure) 1 else 0;
    cookie.httponly = if (httponly) 1 else 0;
    if (expires_unix_sec > 0) {
        cookie.has_expires = 1;
        cookie.expires = unixSecToBasetime(expires_unix_sec);
    }
    cookie.same_site = c.CEF_COOKIE_SAME_SITE_UNSPECIFIED;
    cookie.priority = c.CEF_COOKIE_PRIORITY_MEDIUM;

    const ret = set_fn(mgr, &cef_url, &cookie, null);
    // set_cookie 가 cef_string_t 내용을 내부 복사하므로 우리가 할당한 UTF-16 버퍼를
    // 모두 해제한다(호출마다 누수 방지 — proxy 와 대칭).
    clearCefString(&cef_url);
    clearCefString(&cookie.name);
    clearCefString(&cookie.value);
    clearCefString(&cookie.domain);
    clearCefString(&cookie.path);
    return ret != 0;
}

/// cookie 삭제 — `delete_cookies(url, name, callback)`. url 비면 모든 도메인 cookie,
/// name 비면 url의 host cookies 모두. clearCookies는 url+name 모두 빈 special case.
pub fn sessionRemoveCookies(url: []const u8, name: []const u8) bool {
    const mgr = asPtr(c.cef_cookie_manager_t, c.cef_cookie_manager_get_global_manager(null)) orelse return false;
    defer if (mgr.base.release) |rel| {
        _ = rel(&mgr.base);
    };
    const delete_fn = mgr.delete_cookies orelse return false;
    var cef_url: c.cef_string_t = .{};
    var cef_name: c.cef_string_t = .{};
    if (url.len > 0) setCefString(&cef_url, url);
    if (name.len > 0) setCefString(&cef_name, name);
    const ret = delete_fn(mgr, &cef_url, &cef_name, null);
    clearCefString(&cef_url); // 할당된 UTF-16 해제(미설정 zeroed 는 dtor null → no-op)
    clearCefString(&cef_name);
    return ret != 0;
}

const COOKIE_VISITOR_POOL_SIZE: usize = 4;
const COOKIE_VISITOR_BUF_LEN: usize = 8 * 1024;

/// CEF cookie_visitor wrapper — base가 첫 필드라 visitor 포인터 = instance 포인터.
/// instance pool로 동시 visit 최대 4개 지원.
///
/// **emit 시점**: visit fn count == total - 1 — CEF는 RefPtr scope마다 add_ref/release
/// pair를 만들어 ref count 0 도달이 여러 번 발생, 종료 신호로 못 씀. cookies 0개 case는
/// visit fn 자체가 호출 안 되므로 SDK 측 1초 timeout으로 빈 결과 반환.
const CookieVisitor = extern struct {
    base: c.cef_cookie_visitor_t,
    request_id: u64,
    buf_len: usize,
    in_use: u8, // atomic: 0=free, 1=in-use
    truncated: u8, // 1이면 buf overflow로 일부 cookie drop
    buf: [COOKIE_VISITOR_BUF_LEN]u8,
};

var g_cookie_visitors: [COOKIE_VISITOR_POOL_SIZE]CookieVisitor = undefined;
var g_cookie_visitors_initialized: bool = false;
var g_cookie_visitors_init_lock: std.atomic.Value(bool) = .init(false);
var g_cookie_request_id_counter: std.atomic.Value(u64) = .init(0);

fn ensureCookieVisitorPool() void {
    // double-checked locking: UI 스레드와 백엔드 워커가 첫 cookie fetch 를 동시에 하면
    // 비원자 bool 체크/세트가 풀을 이중 초기화(데이터 레이스)할 수 있다. io 없는 경로라
    // atomic spinlock(cef_auth_handler g_lock 동형)으로 init 을 직렬화한다.
    if (@atomicLoad(bool, &g_cookie_visitors_initialized, .acquire)) return;
    while (g_cookie_visitors_init_lock.swap(true, .acquire)) std.atomic.spinLoopHint();
    defer g_cookie_visitors_init_lock.store(false, .release);
    if (g_cookie_visitors_initialized) return;
    for (&g_cookie_visitors) |*v| {
        zeroCefStruct(c.cef_cookie_visitor_t, &v.base);
        initBaseRefCounted(&v.base.base);
        v.base.visit = &cookieVisitorVisit;
        v.in_use = 0;
        v.buf_len = 0;
        v.request_id = 0;
        v.truncated = 0;
    }
    @atomicStore(bool, &g_cookie_visitors_initialized, true, .release);
}

fn cookieVisitorVisit(
    self_ptr: ?*c._cef_cookie_visitor_t,
    cookie: ?*const c._cef_cookie_t,
    count: c_int,
    total: c_int,
    _: [*c]c_int,
) callconv(.c) c_int {
    const sp = self_ptr orelse return 0;
    const self: *CookieVisitor = @ptrCast(@alignCast(sp));
    const ck = cookie orelse return 1;
    appendCookieJson(self, ck);
    if (count + 1 >= total) {
        emitCookiesResult(self.request_id, self.buf[0..self.buf_len], self.truncated != 0);
        self.buf_len = 0;
        self.truncated = 0;
        @atomicStore(u8, &self.in_use, 0, .release);
    }
    return 1;
}

fn appendCookieJson(self: *CookieVisitor, ck: *const c._cef_cookie_t) void {
    if (self.truncated != 0) return;
    var name_buf: [256]u8 = undefined;
    var value_buf: [1024]u8 = undefined;
    var domain_buf: [256]u8 = undefined;
    var path_buf: [256]u8 = undefined;
    var name_esc: [512]u8 = undefined;
    var value_esc: [2048]u8 = undefined;
    var domain_esc: [512]u8 = undefined;
    var path_esc: [512]u8 = undefined;
    const name = cefStringToUtf8(&ck.name, &name_buf);
    const value = cefStringToUtf8(&ck.value, &value_buf);
    const domain = cefStringToUtf8(&ck.domain, &domain_buf);
    const path = cefStringToUtf8(&ck.path, &path_buf);
    const name_n = util.escapeJsonStrFull(name, &name_esc) orelse return;
    const value_n = util.escapeJsonStrFull(value, &value_esc) orelse return;
    const domain_n = util.escapeJsonStrFull(domain, &domain_esc) orelse return;
    const path_n = util.escapeJsonStrFull(path, &path_esc) orelse return;
    const expires = if (ck.has_expires != 0) basetimeToUnixSec(ck.expires) else 0;

    const sep = if (self.buf_len > 0) "," else "";
    const entry = std.fmt.bufPrint(
        self.buf[self.buf_len..],
        "{s}{{\"name\":\"{s}\",\"value\":\"{s}\",\"domain\":\"{s}\",\"path\":\"{s}\",\"secure\":{s},\"httponly\":{s},\"expires\":{d}}}",
        .{
            sep,
            name_esc[0..name_n],
            value_esc[0..value_n],
            domain_esc[0..domain_n],
            path_esc[0..path_n],
            if (ck.secure != 0) "true" else "false",
            if (ck.httponly != 0) "true" else "false",
            @as(i64, @intFromFloat(expires)),
        },
    ) catch {
        // 8KB buf overflow — 이 cookie 부터 drop. SDK가 truncated:true 보고 전체 fetch 등 폴백.
        self.truncated = 1;
        return;
    };
    self.buf_len += entry.len;
}

fn emitCookiesResult(request_id: u64, cookies_json: []const u8, truncated: bool) void {
    var payload_buf: [COOKIE_VISITOR_BUF_LEN + 256]u8 = undefined;
    const payload = std.fmt.bufPrintZ(
        &payload_buf,
        "{{\"requestId\":{d},\"cookies\":[{s}],\"truncated\":{s}}}",
        .{ request_id, cookies_json, if (truncated) "true" else "false" },
    ) catch return;
    cef.emitWebRequestPayload("session:cookies-result", payload.ptr);
}

/// cookie get — visit_url_cookies(url) 호출. url 빈 문자열이면 visit_all_cookies.
/// 즉시 request_id 반환 (visitor pool 슬롯 점유). 결과는 `session:cookies-result` 이벤트.
/// 0 = visitor pool 가득 또는 manager null.
pub fn sessionGetCookies(url: []const u8, include_http_only: bool) u64 {
    ensureCookieVisitorPool();
    const mgr = asPtr(c.cef_cookie_manager_t, c.cef_cookie_manager_get_global_manager(null)) orelse return 0;
    defer if (mgr.base.release) |rel| {
        _ = rel(&mgr.base);
    };

    // 빈 슬롯 점유 (atomic CAS).
    var slot: ?*CookieVisitor = null;
    for (&g_cookie_visitors) |*v| {
        if (@cmpxchgWeak(u8, &v.in_use, 0, 1, .acquire, .monotonic) == null) {
            slot = v;
            break;
        }
    }
    const v = slot orelse return 0;
    const id = g_cookie_request_id_counter.fetchAdd(1, .monotonic) + 1;
    v.request_id = id;
    v.buf_len = 0;
    v.truncated = 0;

    var ok: bool = false;
    if (url.len > 0) {
        if (mgr.visit_url_cookies) |visit_url| {
            var cef_url: c.cef_string_t = .{};
            setCefString(&cef_url, url);
            ok = visit_url(mgr, &cef_url, if (include_http_only) 1 else 0, &v.base) != 0;
            clearCefString(&cef_url); // 할당된 UTF-16 해제(누수 방지)
        }
    } else {
        if (mgr.visit_all_cookies) |visit_all| {
            ok = visit_all(mgr, &v.base) != 0;
        }
    }

    if (!ok) {
        // 호출 자체 실패. caller에 id 안 주므로 emit도 dangling — 슬롯만 해제.
        @atomicStore(u8, &v.in_use, 0, .release);
        return 0;
    }
    return id;
}
