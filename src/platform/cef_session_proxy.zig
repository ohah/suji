//! session.setProxy — CEF preference manager "proxy" preference 설정.
//!
//! Electron `session.setProxy(config)` 대응. Chromium "proxy" pref(ProxyConfig
//! Dictionary) 포맷으로 매핑: {mode, server(=proxyRules), bypass_list(=
//! proxyBypassRules), pac_url(=pacScript)}.
//!
//! "proxy" 는 **request context** preference(네트워크 관장)이므로 전역 preference
//! manager 가 아니라 `cef_request_context_get_global_context`(브라우저 기본 컨텍스트)
//! 에 설정해야 실 요청에 적용된다. request_context 는 preference manager 를 상속
//! (`.base` = cef_preference_manager_t).
//!
//! set_preference 는 **UI 스레드 필수**. 프론트(@suji/api renderer) invoke 는 UI
//! 스레드라 직접 호출하고, 백엔드(Node/Rust/Go/Python/Lua) SDK 는 워커 스레드라
//! UI 스레드로 task post(Electron 도 setProxy 는 main 프로세스=백엔드가 자연 호출자
//! 이므로 백엔드 경로가 핵심). 둘 다 동일 setProxyOnUi 로 수렴.

const std = @import("std");
const cef = @import("cef.zig");

const c = cef.c;
const asPtr = cef.asPtr;
const setCefString = cef.setCefString;

const c_allocator = std.heap.c_allocator;

// setCefString 이 cef_string_utf8_to_utf16 로 할당한 버퍼를 dtor 로 해제(leak 방지).
fn clearCefStr(s: *c.cef_string_t) void {
    if (s.dtor) |d| d(s.str);
    s.* = .{};
}

fn dictSetStr(dict: *c.cef_dictionary_value_t, key: []const u8, val: []const u8) void {
    const set_string = dict.set_string orelse return;
    var k: c.cef_string_t = .{};
    var v: c.cef_string_t = .{};
    setCefString(&k, key);
    setCefString(&v, val);
    _ = set_string(dict, &k, &v); // dict 가 키/값 복사
    clearCefStr(&k);
    clearCefStr(&v);
}

// 실제 proxy pref 설정 — **UI 스레드에서만** 호출(직접 또는 task execute 경유).
fn setProxyOnUi(mode: []const u8, proxy_rules: []const u8, bypass: []const u8, pac_url: []const u8) bool {
    std.debug.assert(c.cef_currently_on(c.TID_UI) == 1);

    // request context = 네트워크/proxy 관장. 전역 컨텍스트의 preference manager(.base)에 설정.
    const ctx = asPtr(c.cef_request_context_t, c.cef_request_context_get_global_context()) orelse return false;
    defer if (ctx.base.base.release) |rel| {
        _ = rel(&ctx.base.base);
    };
    const mgr: *c.cef_preference_manager_t = &ctx.base;
    const set_pref = mgr.set_preference orelse return false;

    // ⚠️ CEF *C API* 컨벤션(C++ doc 과 다름 — 주의): set 메서드(set_dictionary/
    // set_preference)에 cef_xxx_t* 를 넘기면 CToCpp::Wrap 이 우리 ref 를 consume 한다.
    // C++ 헤더 doc 은 "keeps a reference / ownership unchanged"(AddRef)라 적혀 있지만,
    // 그건 C++ 객체 의미론이고 C API 의 Wrap 은 C 측 ref 를 가져간다. 따라서 create
    // 로 받은 dict/value 를 set 후 release 하면 double-free → **0xefefefef UAF 크래시**.
    // (실측: release 시 e2e 가 SIGBUS 0xef 로 죽었고, release 제거 후 통과. doc 만 보고
    //  release 를 "추가"하면 크래시 재발하니 절대 금지.) ctx 만 get_*global* 반환 ref 라 release.
    const dict = asPtr(c.cef_dictionary_value_t, c.cef_dictionary_value_create()) orelse return false;
    dictSetStr(dict, "mode", if (mode.len > 0) mode else "direct");
    if (proxy_rules.len > 0) dictSetStr(dict, "server", proxy_rules);
    if (bypass.len > 0) dictSetStr(dict, "bypass_list", bypass);
    if (pac_url.len > 0) dictSetStr(dict, "pac_url", pac_url);

    const value = asPtr(c.cef_value_t, c.cef_value_create()) orelse return false;
    const set_dict = value.set_dictionary orelse return false;
    _ = set_dict(value, dict); // dict ref 인수됨 — 이후 dict 접근 금지

    var name: c.cef_string_t = .{};
    setCefString(&name, "proxy");
    defer clearCefStr(&name);
    var err: c.cef_string_t = .{};
    defer clearCefStr(&err);
    const ok = set_pref(mgr, &name, value, &err); // value ref 인수됨
    return ok != 0;
}

// ---- off-UI-thread(백엔드 워커) → UI 스레드 post 용 task ----
// cef_initial_load 의 task 패턴 동형(task 가 첫 필드 → base/self == task 주소).
const SetProxyTask = struct {
    task: c.cef_task_t = undefined,
    allocator: std.mem.Allocator,
    ref_count: std.atomic.Value(u32) = .init(1),
    mode: [64]u8 = undefined,
    mode_len: usize = 0,
    rules: [2048]u8 = undefined,
    rules_len: usize = 0,
    bypass: [2048]u8 = undefined,
    bypass_len: usize = 0,
    pac: [2048]u8 = undefined,
    pac_len: usize = 0,
};

fn taskFromBase(base: ?*c.cef_base_ref_counted_t) ?*SetProxyTask {
    return @ptrCast(@alignCast(base orelse return null));
}
fn taskFromSelf(self: ?*c._cef_task_t) ?*SetProxyTask {
    return @ptrCast(@alignCast(self orelse return null));
}
fn taskAddRef(base: ?*c.cef_base_ref_counted_t) callconv(.c) void {
    const t = taskFromBase(base) orelse return;
    _ = t.ref_count.fetchAdd(1, .acq_rel);
}
fn taskRelease(base: ?*c.cef_base_ref_counted_t) callconv(.c) i32 {
    const t = taskFromBase(base) orelse return 0;
    if (t.ref_count.fetchSub(1, .acq_rel) != 1) return 0;
    t.allocator.destroy(t);
    return 1;
}
fn taskHasOneRef(base: ?*c.cef_base_ref_counted_t) callconv(.c) i32 {
    const t = taskFromBase(base) orelse return 0;
    return if (t.ref_count.load(.acquire) == 1) 1 else 0;
}
fn taskHasAtLeastOneRef(base: ?*c.cef_base_ref_counted_t) callconv(.c) i32 {
    const t = taskFromBase(base) orelse return 0;
    return if (t.ref_count.load(.acquire) >= 1) 1 else 0;
}
fn taskExecute(self: ?*c._cef_task_t) callconv(.c) void {
    const t = taskFromSelf(self) orelse return;
    _ = setProxyOnUi(t.mode[0..t.mode_len], t.rules[0..t.rules_len], t.bypass[0..t.bypass_len], t.pac[0..t.pac_len]);
}

/// Electron `session.setProxy`. mode 빈 문자열 → "direct"(프록시 해제). UI 스레드면
/// 즉시 적용 후 결과 반환, 백엔드 워커 스레드면 UI 스레드로 post(fire-and-forget,
/// post 성공 시 true).
pub fn sessionSetProxy(mode: []const u8, proxy_rules: []const u8, bypass: []const u8, pac_url: []const u8) bool {
    if (c.cef_currently_on(c.TID_UI) == 1) {
        return setProxyOnUi(mode, proxy_rules, bypass, pac_url);
    }
    // 백엔드 워커 스레드 — 문자열을 task 에 복사해 UI 스레드로 post.
    if (mode.len > 64 or proxy_rules.len > 2048 or bypass.len > 2048 or pac_url.len > 2048) return false;
    const t = c_allocator.create(SetProxyTask) catch return false;
    t.* = .{
        .allocator = c_allocator,
        .mode_len = mode.len,
        .rules_len = proxy_rules.len,
        .bypass_len = bypass.len,
        .pac_len = pac_url.len,
    };
    @memcpy(t.mode[0..mode.len], mode);
    @memcpy(t.rules[0..proxy_rules.len], proxy_rules);
    @memcpy(t.bypass[0..bypass.len], bypass);
    @memcpy(t.pac[0..pac_url.len], pac_url);
    @memset(std.mem.asBytes(&t.task), 0);
    t.task.base.size = @sizeOf(c.cef_task_t);
    t.task.base.add_ref = &taskAddRef;
    t.task.base.release = &taskRelease;
    t.task.base.has_one_ref = &taskHasOneRef;
    t.task.base.has_at_least_one_ref = &taskHasAtLeastOneRef;
    t.task.execute = &taskExecute;
    if (c.cef_post_task(c.TID_UI, &t.task) != 1) {
        _ = taskRelease(&t.task.base); // post 실패 → 우리 ref 해제(free)
        return false;
    }
    return true; // posted — UI 스레드에서 곧 적용
}
