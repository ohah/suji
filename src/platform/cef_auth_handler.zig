//! app:certificate-error / app:login / app:select-client-certificate — CEF request_handler
//! deferred 콜백. cef_session_permission(prompt/media) 패턴 복제 — pending pool + emit +
//! UI-thread RespondTask(off-UI 워커 → cef_post_task(TID_UI)로 cont).
//! ⚠️ 실 TLS 에러/basic auth/client cert 검증은 헤드리스 불가 — 빌드+wire 검증(정직 경계).
const std = @import("std");
const cef = @import("cef.zig");

const util = @import("util");
const c = cef.c;
const cefStringToUtf8 = cef.cefStringToUtf8;
const c_allocator = std.heap.c_allocator;

/// emit 콜백 — main 이 주입(채널별 emit). (channel_cstr, info_json) C ABI. info 에 id 포함.
pub const AuthEmitFn = *const fn (channel: [*:0]const u8, info_ptr: [*]const u8, info_len: usize) callconv(.c) void;
var g_emit_fn: ?AuthEmitFn = null;
pub fn setAuthEmitHandler(fn_ptr: AuthEmitFn) void {
    g_emit_fn = fn_ptr;
}

const MAX_PENDING: usize = 32;
var g_next_id: std.atomic.Value(u64) = .init(1);
fn nextId() u64 {
    return g_next_id.fetchAdd(1, .monotonic);
}

// 간단 스핀락 (cef_session_permission g_lock 동형 — pending 배열 보호).
var g_lock: std.atomic.Value(bool) = .init(false);
fn lock() void {
    while (g_lock.swap(true, .acquire)) {}
}
fn unlock() void {
    g_lock.store(false, .release);
}

/// CEF 콜백 ref 해제 + return 0 — hold(add_ref) 후 early-return(push/emit/json 실패) 공용.
fn releaseCb(base: *c.cef_base_ref_counted_t) c_int {
    if (base.release) |rel| _ = rel(base);
    return 0;
}

// ============================================================
// certificate-error — cef_callback_t (cont=허용 / cancel=거부)
// ============================================================
const PendingCert = struct { id: u64, cb: *c.cef_callback_t };
var g_cert: [MAX_PENDING]PendingCert = undefined;
var g_cert_count: usize = 0;

fn certPush(id: u64, cb: *c.cef_callback_t) bool {
    lock();
    defer unlock();
    if (g_cert_count >= MAX_PENDING) return false;
    g_cert[g_cert_count] = .{ .id = id, .cb = cb };
    g_cert_count += 1;
    return true;
}
fn certTake(id: u64) ?*c.cef_callback_t {
    lock();
    defer unlock();
    var i: usize = 0;
    while (i < g_cert_count) : (i += 1) {
        if (g_cert[i].id == id) {
            const cb = g_cert[i].cb;
            g_cert[i] = g_cert[g_cert_count - 1];
            g_cert_count -= 1;
            return cb;
        }
    }
    return null;
}

fn certContAndRelease(cb: *c.cef_callback_t, allow: bool) void {
    if (allow) {
        if (cb.cont) |fp| fp(cb);
    } else {
        if (cb.cancel) |fp| fp(cb);
    }
    if (cb.base.release) |rel| _ = rel(&cb.base);
}

const CertTask = struct {
    task: c.cef_task_t = undefined,
    allocator: std.mem.Allocator,
    ref_count: std.atomic.Value(u32) = .init(1),
    callback: *c.cef_callback_t,
    allow: bool,
};
fn certTaskFromBase(base: ?*c.cef_base_ref_counted_t) ?*CertTask {
    return @ptrCast(@alignCast(base orelse return null));
}
fn certTaskFromSelf(self: ?*c._cef_task_t) ?*CertTask {
    return @ptrCast(@alignCast(self orelse return null));
}
fn certTaskAddRef(base: ?*c.cef_base_ref_counted_t) callconv(.c) void {
    const t = certTaskFromBase(base) orelse return;
    _ = t.ref_count.fetchAdd(1, .acq_rel);
}
fn certTaskRelease(base: ?*c.cef_base_ref_counted_t) callconv(.c) i32 {
    const t = certTaskFromBase(base) orelse return 0;
    if (t.ref_count.fetchSub(1, .acq_rel) != 1) return 0;
    t.allocator.destroy(t);
    return 1;
}
fn certTaskHasOneRef(base: ?*c.cef_base_ref_counted_t) callconv(.c) i32 {
    const t = certTaskFromBase(base) orelse return 0;
    return if (t.ref_count.load(.acquire) == 1) 1 else 0;
}
fn certTaskHasAtLeastOneRef(base: ?*c.cef_base_ref_counted_t) callconv(.c) i32 {
    const t = certTaskFromBase(base) orelse return 0;
    return if (t.ref_count.load(.acquire) >= 1) 1 else 0;
}
fn certTaskExecute(self: ?*c._cef_task_t) callconv(.c) void {
    const t = certTaskFromSelf(self) orelse return;
    certContAndRelease(t.callback, t.allow);
}

/// certificate-error 결정 적용. UI 스레드면 즉시 cont/cancel, 워커면 UI 로 post. 없는 id=false.
pub fn certificateErrorRespond(id: u64, allow: bool) bool {
    const cb = certTake(id) orelse return false;
    if (c.cef_currently_on(c.TID_UI) == 1) {
        certContAndRelease(cb, allow);
        return true;
    }
    const t = c_allocator.create(CertTask) catch {
        if (cb.base.release) |rel| _ = rel(&cb.base);
        return false;
    };
    t.* = .{ .allocator = c_allocator, .callback = cb, .allow = allow };
    @memset(std.mem.asBytes(&t.task), 0);
    t.task.base.size = @sizeOf(c.cef_task_t);
    t.task.base.add_ref = &certTaskAddRef;
    t.task.base.release = &certTaskRelease;
    t.task.base.has_one_ref = &certTaskHasOneRef;
    t.task.base.has_at_least_one_ref = &certTaskHasAtLeastOneRef;
    t.task.execute = &certTaskExecute;
    if (c.cef_post_task(c.TID_UI, &t.task) != 1) {
        _ = certTaskRelease(&t.task.base);
        if (cb.base.release) |rel| _ = rel(&cb.base);
        return false;
    }
    return true;
}

/// cef_request_handler_t.on_certificate_error — TLS 인증서 검증 실패. 1=callback hold(deferred).
/// 핸들러 미설정/pool 가득/emit 실패 시 0(기본 거부 — CEF 에러 페이지).
pub fn onCertificateError(
    _: ?*c._cef_request_handler_t,
    _: ?*c._cef_browser_t,
    cert_error: c.cef_errorcode_t,
    request_url: [*c]const c.cef_string_t,
    _: ?*c._cef_sslinfo_t,
    callback: ?*c._cef_callback_t,
) callconv(.c) c_int {
    const emit = g_emit_fn orelse return 0;
    const cb = callback orelse return 0;
    // hold past 동기 핸들러 반환 — add_ref(respond 의 release 와 짝). 모든 early-return-0 에서 release.
    if (cb.base.add_ref) |ar| ar(&cb.base);
    const id = nextId();
    if (!certPush(id, cb)) return releaseCb(&cb.base);
    var url_buf: [2048]u8 = undefined;
    const url = if (request_url != null) cefStringToUtf8(request_url, &url_buf) else "";
    var esc: [2100]u8 = undefined;
    const en = util.escapeJsonStrFull(url, &esc) orelse {
        _ = certTake(id);
        return releaseCb(&cb.base);
    };
    var info: [2300]u8 = undefined;
    const json = std.fmt.bufPrint(&info, "{{\"id\":{d},\"url\":\"{s}\",\"errorCode\":{d}}}", .{ id, esc[0..en], @as(i64, cert_error) }) catch {
        _ = certTake(id);
        return releaseCb(&cb.base);
    };
    emit("app:certificate-error", json.ptr, json.len);
    return 1; // hold — certificateErrorRespond 가 cont/cancel
}

// ============================================================
// login (HTTP basic auth) — cef_auth_callback_t (cont(user,pass) / cancel)
// ============================================================
const PendingAuth = struct { id: u64, cb: *c.cef_auth_callback_t };
var g_auth: [MAX_PENDING]PendingAuth = undefined;
var g_auth_count: usize = 0;

fn authPush(id: u64, cb: *c.cef_auth_callback_t) bool {
    lock();
    defer unlock();
    if (g_auth_count >= MAX_PENDING) return false;
    g_auth[g_auth_count] = .{ .id = id, .cb = cb };
    g_auth_count += 1;
    return true;
}
fn authTake(id: u64) ?*c.cef_auth_callback_t {
    lock();
    defer unlock();
    var i: usize = 0;
    while (i < g_auth_count) : (i += 1) {
        if (g_auth[i].id == id) {
            const cb = g_auth[i].cb;
            g_auth[i] = g_auth[g_auth_count - 1];
            g_auth_count -= 1;
            return cb;
        }
    }
    return null;
}

fn authContAndRelease(cb: *c.cef_auth_callback_t, user: []const u8, pass: []const u8, ok: bool) void {
    if (ok) {
        if (cb.cont) |fp| {
            var user_cef: c.cef_string_t = std.mem.zeroes(c.cef_string_t);
            var pass_cef: c.cef_string_t = std.mem.zeroes(c.cef_string_t);
            _ = c.cef_string_utf8_to_utf16(user.ptr, user.len, &user_cef);
            _ = c.cef_string_utf8_to_utf16(pass.ptr, pass.len, &pass_cef);
            fp(cb, &user_cef, &pass_cef);
            if (user_cef.dtor) |d| d(user_cef.str);
            if (pass_cef.dtor) |d| d(pass_cef.str);
        }
    } else {
        if (cb.cancel) |fp| fp(cb);
    }
    if (cb.base.release) |rel| _ = rel(&cb.base);
}

const AuthTask = struct {
    task: c.cef_task_t = undefined,
    allocator: std.mem.Allocator,
    ref_count: std.atomic.Value(u32) = .init(1),
    callback: *c.cef_auth_callback_t,
    user: [256]u8 = undefined,
    user_len: usize = 0,
    pass: [256]u8 = undefined,
    pass_len: usize = 0,
    ok: bool = false,
};
fn authTaskFromBase(base: ?*c.cef_base_ref_counted_t) ?*AuthTask {
    return @ptrCast(@alignCast(base orelse return null));
}
fn authTaskFromSelf(self: ?*c._cef_task_t) ?*AuthTask {
    return @ptrCast(@alignCast(self orelse return null));
}
fn authTaskAddRef(base: ?*c.cef_base_ref_counted_t) callconv(.c) void {
    const t = authTaskFromBase(base) orelse return;
    _ = t.ref_count.fetchAdd(1, .acq_rel);
}
fn authTaskRelease(base: ?*c.cef_base_ref_counted_t) callconv(.c) i32 {
    const t = authTaskFromBase(base) orelse return 0;
    if (t.ref_count.fetchSub(1, .acq_rel) != 1) return 0;
    t.allocator.destroy(t);
    return 1;
}
fn authTaskHasOneRef(base: ?*c.cef_base_ref_counted_t) callconv(.c) i32 {
    const t = authTaskFromBase(base) orelse return 0;
    return if (t.ref_count.load(.acquire) == 1) 1 else 0;
}
fn authTaskHasAtLeastOneRef(base: ?*c.cef_base_ref_counted_t) callconv(.c) i32 {
    const t = authTaskFromBase(base) orelse return 0;
    return if (t.ref_count.load(.acquire) >= 1) 1 else 0;
}
fn authTaskExecute(self: ?*c._cef_task_t) callconv(.c) void {
    const t = authTaskFromSelf(self) orelse return;
    authContAndRelease(t.callback, t.user[0..t.user_len], t.pass[0..t.pass_len], t.ok);
}

/// login(basic auth) 결정 — ok=true 면 cont(user,pass), false 면 cancel. UI/워커 분기.
pub fn loginRespond(id: u64, user: []const u8, pass: []const u8, ok: bool) bool {
    const cb = authTake(id) orelse return false;
    if (c.cef_currently_on(c.TID_UI) == 1) {
        authContAndRelease(cb, user, pass, ok);
        return true;
    }
    const t = c_allocator.create(AuthTask) catch {
        if (cb.base.release) |rel| _ = rel(&cb.base);
        return false;
    };
    t.* = .{ .allocator = c_allocator, .callback = cb, .ok = ok };
    t.user_len = @min(user.len, t.user.len);
    t.pass_len = @min(pass.len, t.pass.len);
    @memcpy(t.user[0..t.user_len], user[0..t.user_len]);
    @memcpy(t.pass[0..t.pass_len], pass[0..t.pass_len]);
    @memset(std.mem.asBytes(&t.task), 0);
    t.task.base.size = @sizeOf(c.cef_task_t);
    t.task.base.add_ref = &authTaskAddRef;
    t.task.base.release = &authTaskRelease;
    t.task.base.has_one_ref = &authTaskHasOneRef;
    t.task.base.has_at_least_one_ref = &authTaskHasAtLeastOneRef;
    t.task.execute = &authTaskExecute;
    if (c.cef_post_task(c.TID_UI, &t.task) != 1) {
        _ = authTaskRelease(&t.task.base);
        if (cb.base.release) |rel| _ = rel(&cb.base);
        return false;
    }
    return true;
}

/// cef_request_handler_t.get_auth_credentials — HTTP basic/proxy auth. 1=callback hold(deferred).
pub fn getAuthCredentials(
    _: ?*c._cef_request_handler_t,
    _: ?*c._cef_browser_t,
    origin_url: [*c]const c.cef_string_t,
    is_proxy: c_int,
    host: [*c]const c.cef_string_t,
    port: c_int,
    realm: [*c]const c.cef_string_t,
    scheme: [*c]const c.cef_string_t,
    callback: ?*c._cef_auth_callback_t,
) callconv(.c) c_int {
    const emit = g_emit_fn orelse return 0;
    const cb = callback orelse return 0;
    if (cb.base.add_ref) |ar| ar(&cb.base);
    const id = nextId();
    if (!authPush(id, cb)) return releaseCb(&cb.base);
    var ub: [1024]u8 = undefined;
    var hb: [256]u8 = undefined;
    var rb: [256]u8 = undefined;
    var sb: [64]u8 = undefined;
    const url = if (origin_url != null) cefStringToUtf8(origin_url, &ub) else "";
    const host_s = if (host != null) cefStringToUtf8(host, &hb) else "";
    const realm_s = if (realm != null) cefStringToUtf8(realm, &rb) else "";
    const scheme_s = if (scheme != null) cefStringToUtf8(scheme, &sb) else "";
    var ue: [1100]u8 = undefined;
    var he: [300]u8 = undefined;
    var ree: [300]u8 = undefined;
    var se: [100]u8 = undefined;
    const un = util.escapeJsonStrFull(url, &ue) orelse return failAuth(id);
    const hn = util.escapeJsonStrFull(host_s, &he) orelse return failAuth(id);
    const rn = util.escapeJsonStrFull(realm_s, &ree) orelse return failAuth(id);
    const sn = util.escapeJsonStrFull(scheme_s, &se) orelse return failAuth(id);
    var info: [3000]u8 = undefined;
    const json = std.fmt.bufPrint(&info, "{{\"id\":{d},\"url\":\"{s}\",\"isProxy\":{},\"host\":\"{s}\",\"port\":{d},\"realm\":\"{s}\",\"scheme\":\"{s}\"}}", .{ id, ue[0..un], is_proxy != 0, he[0..hn], port, ree[0..rn], se[0..sn] }) catch return failAuth(id);
    emit("app:login", json.ptr, json.len);
    return 1;
}
fn failAuth(id: u64) c_int {
    if (authTake(id)) |cb| {
        if (cb.base.release) |rel| _ = rel(&cb.base);
    }
    return 0;
}

// ============================================================
// select-client-certificate — cef_select_client_certificate_callback_t (select(cert))
// ============================================================
const MAX_CERTS: usize = 16;
const PendingClientCert = struct {
    id: u64,
    cb: *c.cef_select_client_certificate_callback_t,
    certs: [MAX_CERTS]?*c.cef_x509_certificate_t = .{null} ** MAX_CERTS,
    count: usize = 0,
};
var g_client: [MAX_PENDING]PendingClientCert = undefined;
var g_client_count: usize = 0;

fn clientPush(p: PendingClientCert) bool {
    lock();
    defer unlock();
    if (g_client_count >= MAX_PENDING) return false;
    g_client[g_client_count] = p;
    g_client_count += 1;
    return true;
}
fn clientTake(id: u64) ?PendingClientCert {
    lock();
    defer unlock();
    var i: usize = 0;
    while (i < g_client_count) : (i += 1) {
        if (g_client[i].id == id) {
            const p = g_client[i];
            g_client[i] = g_client[g_client_count - 1];
            g_client_count -= 1;
            return p;
        }
    }
    return null;
}

/// select(certs[index]) 또는 select(null), 우리가 add_ref 한 모든 certs release.
fn clientSelectAndRelease(p: PendingClientCert, index: i64) void {
    const cb = p.cb;
    const selected: ?*c.cef_x509_certificate_t = if (index >= 0 and index < @as(i64, @intCast(p.count))) p.certs[@intCast(index)] else null;
    if (cb.select) |fp| fp(cb, selected);
    var i: usize = 0;
    while (i < p.count) : (i += 1) {
        if (p.certs[i]) |cert| {
            if (cert.base.release) |rel| _ = rel(&cert.base);
        }
    }
    if (cb.base.release) |rel| _ = rel(&cb.base);
}

/// select 호출 없이 certs + cb ref 만 해제 — off-UI fallback / emit 실패(callback hold 취소) 용.
/// cef_session_permission 의 "off-UI cont 미보장" 규칙 동형(select 는 UI 스레드만).
fn clientReleaseOnly(p: PendingClientCert) void {
    var i: usize = 0;
    while (i < p.count) : (i += 1) {
        if (p.certs[i]) |cert| {
            if (cert.base.release) |rel| _ = rel(&cert.base);
        }
    }
    if (p.cb.base.release) |rel| _ = rel(&p.cb.base);
}

const ClientCertTask = struct {
    task: c.cef_task_t = undefined,
    allocator: std.mem.Allocator,
    ref_count: std.atomic.Value(u32) = .init(1),
    pending: PendingClientCert,
    index: i64,
};
fn clientTaskFromBase(base: ?*c.cef_base_ref_counted_t) ?*ClientCertTask {
    return @ptrCast(@alignCast(base orelse return null));
}
fn clientTaskFromSelf(self: ?*c._cef_task_t) ?*ClientCertTask {
    return @ptrCast(@alignCast(self orelse return null));
}
fn clientTaskAddRef(base: ?*c.cef_base_ref_counted_t) callconv(.c) void {
    const t = clientTaskFromBase(base) orelse return;
    _ = t.ref_count.fetchAdd(1, .acq_rel);
}
fn clientTaskRelease(base: ?*c.cef_base_ref_counted_t) callconv(.c) i32 {
    const t = clientTaskFromBase(base) orelse return 0;
    if (t.ref_count.fetchSub(1, .acq_rel) != 1) return 0;
    t.allocator.destroy(t);
    return 1;
}
fn clientTaskHasOneRef(base: ?*c.cef_base_ref_counted_t) callconv(.c) i32 {
    const t = clientTaskFromBase(base) orelse return 0;
    return if (t.ref_count.load(.acquire) == 1) 1 else 0;
}
fn clientTaskHasAtLeastOneRef(base: ?*c.cef_base_ref_counted_t) callconv(.c) i32 {
    const t = clientTaskFromBase(base) orelse return 0;
    return if (t.ref_count.load(.acquire) >= 1) 1 else 0;
}
fn clientTaskExecute(self: ?*c._cef_task_t) callconv(.c) void {
    const t = clientTaskFromSelf(self) orelse return;
    clientSelectAndRelease(t.pending, t.index);
}

/// client cert 선택 (index<0 또는 범위밖 = select(null)=기본). UI/워커 분기.
pub fn selectClientCertificateRespond(id: u64, index: i64) bool {
    const p = clientTake(id) orelse return false;
    if (c.cef_currently_on(c.TID_UI) == 1) {
        clientSelectAndRelease(p, index);
        return true;
    }
    const t = c_allocator.create(ClientCertTask) catch {
        clientReleaseOnly(p); // off-UI — select 미보장(UI 스레드만), certs+cb release 만
        return false;
    };
    t.* = .{ .allocator = c_allocator, .pending = p, .index = index };
    @memset(std.mem.asBytes(&t.task), 0);
    t.task.base.size = @sizeOf(c.cef_task_t);
    t.task.base.add_ref = &clientTaskAddRef;
    t.task.base.release = &clientTaskRelease;
    t.task.base.has_one_ref = &clientTaskHasOneRef;
    t.task.base.has_at_least_one_ref = &clientTaskHasAtLeastOneRef;
    t.task.execute = &clientTaskExecute;
    if (c.cef_post_task(c.TID_UI, &t.task) != 1) {
        const saved = t.pending;
        _ = clientTaskRelease(&t.task.base);
        clientReleaseOnly(saved);
        return false;
    }
    return true;
}

/// cef_request_handler_t.on_select_client_certificate — client cert 요구. 1=callback hold(deferred).
pub fn onSelectClientCertificate(
    _: ?*c._cef_request_handler_t,
    _: ?*c._cef_browser_t,
    is_proxy: c_int,
    host: [*c]const c.cef_string_t,
    port: c_int,
    certificates_count: usize,
    certificates: [*c]const ?*c.cef_x509_certificate_t,
    callback: ?*c._cef_select_client_certificate_callback_t,
) callconv(.c) c_int {
    const emit = g_emit_fn orelse return 0;
    const cb = callback orelse return 0;
    if (certificates_count == 0) return 0; // cert 없음 → CEF 기본
    // callback + 각 cert hold(add_ref) — clientReleaseOnly/clientSelectAndRelease 가 짝 release.
    if (cb.base.add_ref) |ar| ar(&cb.base);
    var p: PendingClientCert = .{ .id = nextId(), .cb = cb };
    p.count = @min(certificates_count, MAX_CERTS);
    var i: usize = 0;
    while (i < p.count) : (i += 1) {
        const cert = certificates[i];
        p.certs[i] = cert;
        if (cert) |ct| {
            if (ct.base.add_ref) |ar| ar(&ct.base);
        }
    }
    if (!clientPush(p)) {
        clientReleaseOnly(p); // certs + cb release(select 안 함) — return 0 = CEF 기본
        return 0;
    }
    var hb: [256]u8 = undefined;
    var he: [300]u8 = undefined;
    const host_s = if (host != null) cefStringToUtf8(host, &hb) else "";
    var info: [512]u8 = undefined;
    const hn = util.escapeJsonStrFull(host_s, &he) orelse {
        _ = clientTake(p.id);
        clientReleaseOnly(p);
        return 0;
    };
    const json = std.fmt.bufPrint(&info, "{{\"id\":{d},\"isProxy\":{},\"host\":\"{s}\",\"port\":{d},\"certCount\":{d}}}", .{ p.id, is_proxy != 0, he[0..hn], port, p.count }) catch {
        _ = clientTake(p.id);
        clientReleaseOnly(p);
        return 0;
    };
    emit("app:select-client-certificate", json.ptr, json.len);
    return 1;
}
