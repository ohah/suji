//! session.setDownloadPath + session:will-download — CEF `cef_download_handler_t`.
//!
//! Electron `session` 의 다운로드 대응. 렌더러가 다운로드를 시작하면 CEF
//! `on_before_download` 가 **UI 스레드**에서 호출된다.
//!   - 항상 `session:will-download` 이벤트({id, url, filename, mimeType, totalBytes})를
//!     EventBus 로 발신(Electron `session.on('will-download')` 동형 — 정보성).
//!   - `setDownloadPath(dir)` 가 설정돼 있으면 `<dir>/<filename>` 로 **무대화상자**
//!     다운로드(Electron `session.setDownloadPath` 동형). 미설정이면 OS 저장 대화상자.
//!
//! permission handler 와 달리 cont 는 **동기 즉시 호출**(app 응답 대기 없음 — 다운로드는
//! 정보성 이벤트). 따라서 pending pool/deferred-callback 불요.
//!
//! `can_download` 는 1(허용) 고정 — 다운로드 활성화(핸들러 미등록 시 CEF 가 다운로드를
//! 무시). 정책적 차단은 범위 밖(Electron will-download preventDefault 미대응 — 후속).
//!
//! 검증: cef.zig(@cImport) 의존이라 standalone unit-test 불가 → ① cef_ipc_test 소스
//! 계약 가드 + ② e2e(setDownloadPath 후 다운로드 트리거 → will-download 이벤트 +
//! 파일이 지정 경로에 생성)로 검증.

const std = @import("std");
const util = @import("util");
const cef = @import("cef.zig");

const c = cef.c;
const zeroCefStruct = cef.zeroCefStruct;
const initBaseRefCounted = cef.initBaseRefCounted;
const cefStringToUtf8 = cef.cefStringToUtf8;
const cefUserfreeToUtf8 = cef.cefUserfreeToUtf8;

// ---- EventBus emit 핸들러(main 이 주입; permission/web_request 동형) ----
pub const DownloadEmitFn = *const fn (channel: [*:0]const u8, payload: [*:0]const u8) callconv(.c) void;
var g_emit_fn: ?DownloadEmitFn = null;

pub fn setDownloadEmitHandler(fn_ptr: DownloadEmitFn) void {
    g_emit_fn = fn_ptr;
}

// ---- 다운로드 디렉토리(session.setDownloadPath) ----
// 비어 있으면 OS 저장 대화상자. UI 스레드(on_before_download)와 setter(프론트=UI /
// 백엔드=워커)가 경쟁하므로 spinlock 보호(permission g_lock 동형).
var g_path_buf: [4096]u8 = undefined;
var g_path_len: usize = 0;
var g_lock: std.atomic.Value(bool) = .init(false);

fn lock() void {
    while (g_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
        std.atomic.spinLoopHint();
    }
}
fn unlock() void {
    g_lock.store(false, .release);
}

/// Electron `session.setDownloadPath(dir)`. 빈 문자열 = 해제(OS 대화상자로 복귀).
/// 경로 초과분은 truncate(4096 한도 — 정상 경로엔 충분).
pub fn setDownloadPath(dir: []const u8) void {
    lock();
    defer unlock();
    const n = @min(dir.len, g_path_buf.len);
    @memcpy(g_path_buf[0..n], dir[0..n]);
    g_path_len = n;
}

/// g_path 가 설정돼 있으면 `<dir><sep><filename>` 를 out 에 쓰고 슬라이스 반환, 없으면 null.
/// out 초과 시 bufPrint 가 error → null(호출부는 OS 대화상자로 fallback).
fn buildSavePath(filename: []const u8, out: []u8) ?[]const u8 {
    lock();
    defer unlock();
    if (g_path_len == 0) return null;
    return std.fmt.bufPrint(out, "{s}{s}{s}", .{ g_path_buf[0..g_path_len], std.fs.path.sep_str, filename }) catch null;
}

fn emitWillDownload(item: *c.cef_download_item_t, filename: []const u8) void {
    const emit = g_emit_fn orelse return;
    const id: u32 = if (item.get_id) |f| f(item) else 0;
    const total: i64 = if (item.get_total_bytes) |f| f(item) else -1;
    var url_buf: [2048]u8 = undefined;
    const url = if (item.get_url) |f| cefUserfreeToUtf8(f(item), &url_buf) else "";
    var mime_buf: [256]u8 = undefined;
    const mime = if (item.get_mime_type) |f| cefUserfreeToUtf8(f(item), &mime_buf) else "";

    var url_esc: [4096]u8 = undefined;
    const ue = util.escapeJsonStrFull(url, &url_esc) orelse return;
    var name_esc: [1024]u8 = undefined;
    const ne = util.escapeJsonStrFull(filename, &name_esc) orelse return;
    var mime_esc: [512]u8 = undefined;
    const me = util.escapeJsonStrFull(mime, &mime_esc) orelse return;

    var payload_buf: [8192]u8 = undefined;
    const payload = std.fmt.bufPrintZ(
        &payload_buf,
        "{{\"id\":{d},\"url\":\"{s}\",\"filename\":\"{s}\",\"mimeType\":\"{s}\",\"totalBytes\":{d}}}",
        .{ id, url_esc[0..ue], name_esc[0..ne], mime_esc[0..me], total },
    ) catch return;
    emit("session:will-download", payload.ptr);
}

// ---- CEF cef_download_handler_t 싱글톤(permission handler 동형) ----
var g_handler: c.cef_download_handler_t = undefined;
var g_handler_initialized: bool = false;

fn ensureHandler() void {
    if (g_handler_initialized) return;
    zeroCefStruct(c.cef_download_handler_t, &g_handler);
    initBaseRefCounted(&g_handler.base);
    g_handler.can_download = &canDownload;
    g_handler.on_before_download = &onBeforeDownload;
    g_handler_initialized = true;
}

pub fn getDownloadHandler(_: ?*c._cef_client_t) callconv(.c) ?*c._cef_download_handler_t {
    ensureHandler();
    return &g_handler;
}

fn canDownload(
    _: ?*c._cef_download_handler_t,
    _: ?*c._cef_browser_t,
    _: [*c]const c.cef_string_t,
    _: [*c]const c.cef_string_t,
) callconv(.c) c_int {
    return 1; // 다운로드 허용(Electron 기본). 정책적 차단은 범위 밖.
}

fn onBeforeDownload(
    _: ?*c._cef_download_handler_t,
    _: ?*c._cef_browser_t,
    download_item: [*c]c._cef_download_item_t,
    suggested_name: [*c]const c.cef_string_t,
    callback: [*c]c._cef_before_download_callback_t,
) callconv(.c) c_int {
    const cb: *c.cef_before_download_callback_t = callback orelse return 0;
    const item: *c.cef_download_item_t = download_item orelse return 0;

    var name_buf: [1024]u8 = undefined;
    const filename = if (suggested_name != null) cefStringToUtf8(suggested_name, &name_buf) else "";
    emitWillDownload(item, filename);

    var path_buf: [5120]u8 = undefined;
    if (buildSavePath(filename, &path_buf)) |full| {
        // setDownloadPath 설정됨 — 무대화상자 다운로드.
        var cs: c.cef_string_t = .{};
        cef.setCefString(&cs, full);
        if (cb.cont) |fp| fp(cb, &cs, 0);
        if (cs.dtor) |d| d(cs.str); // setCefString 이 할당한 utf16 해제(per-download leak 방지)
    } else {
        // 미설정 — OS 저장 대화상자(빈 경로 + show_dialog=1).
        if (cb.cont) |fp| fp(cb, null, 1);
    }
    return 1; // 처리됨
}
