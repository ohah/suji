//! Shared CEF utility helpers — kept small and re-exported by cef.zig.
const std = @import("std");
const runtime = @import("runtime");
const cef = @import("cef.zig");

const c = cef.c;

/// `[]const u8` → null-terminated `[:0]const u8` 복사. buf 부족 시 null 반환.
/// CEF API(load_url/execute_java_script)에 전달하기 전에 필요.
pub fn nullTerminateOrTruncate(src: []const u8, buf: []u8) ?[:0]const u8 {
    if (src.len >= buf.len) return null;
    @memcpy(buf[0..src.len], src);
    buf[src.len] = 0;
    return buf[0..src.len :0];
}

/// Zig slice → null-terminated C string in caller-supplied buffer.
/// 슬라이스 길이+1 > buf.len이면 null. notification/global_shortcut 등 .m extern 호출 공통.
pub fn writeCStr(slice: []const u8, buf: []u8) ?[*:0]const u8 {
    if (slice.len + 1 > buf.len) return null;
    @memcpy(buf[0..slice.len], slice);
    buf[slice.len] = 0;
    return @ptrCast(buf.ptr);
}

/// [*c]T → ?*T 변환 (CEF 함수 포인터 반환값용)
pub fn asPtr(comptime T: type, p: anytype) ?*T {
    if (p == null) return null;
    return @ptrCast(p);
}

pub fn zeroCefStruct(comptime T: type, ptr: *T) void {
    @memset(std.mem.asBytes(ptr), 0);
    // CEF 구조체는 base.size 또는 직접 size 필드에 sizeof를 설정해야 함
    if (@hasField(T, "base")) {
        ptr.base.size = @sizeOf(T);
    } else if (@hasField(T, "size")) {
        ptr.size = @sizeOf(T);
    }
}

// TODO: setCefString은 UTF-16 메모리를 할당하지만 cef_string_clear로 해제하지 않음.
//       프로세스 라이프타임 문자열이라 실질적 누수 없으나, 동적 문자열 사용 시 해제 필요.
pub fn setCefString(dest: *c.cef_string_t, src: []const u8) void {
    _ = c.cef_string_utf8_to_utf16(src.ptr, src.len, dest);
}

/// setCefString 이 할당한 UTF-16 버퍼를 cef_string_t.dtor 로 해제하고 구조체를 비운다.
/// **요청마다 새로 만드는 동적 cef_string_t** 는 사용 후 반드시 호출(누수 방지).
pub fn clearCefString(s: *c.cef_string_t) void {
    if (s.dtor) |d| d(s.str);
    s.* = .{};
}

/// CEF URL fallback — 빈 url은 페이지 로드 skip → OnLoadEnd/OnTitleChange 미발화로 이어져
/// `window:ready-to-show` / `page-title-updated` 라이프사이클 이벤트가 안 옴. about:blank
/// 로 강제해 일관 동작 보장. (`page-title-updated`가 "about:blank" 페이로드로 1회 발화 —
/// 사용자 코드가 필요하면 listener에서 필터.)
pub fn setUrlOrBlank(dest: *c.cef_string_t, url_z: []const u8) void {
    setCefString(dest, if (url_z.len > 0) url_z else "about:blank");
}

pub fn isAboutBlankUrl(url: []const u8) bool {
    return std.mem.eql(u8, url, "about:blank");
}

/// CefListValue에서 문자열 인자를 UTF-8로 추출
pub fn getArgString(args: *c.cef_list_value_t, index: usize, buf: []u8) []const u8 {
    return cefUserfreeToUtf8(args.get_string.?(args, index), buf);
}

pub fn traceIpcEnabled() bool {
    const v = runtime.env("SUJI_TRACE_IPC") orelse return false;
    return v.len > 0 and !std.mem.eql(u8, v, "0");
}

pub fn traceDragRegionEnabled() bool {
    const v = runtime.env("SUJI_TRACE_DRAG_REGION") orelse return false;
    return v.len > 0 and !std.mem.eql(u8, v, "0");
}

/// CEF 문자열 → UTF-8 (스택 버퍼에 복사)
pub fn cefStringToUtf8(cef_str: *const c.cef_string_t, buf: []u8) []const u8 {
    var utf8: c.cef_string_utf8_t = .{ .str = null, .length = 0, .dtor = null };
    _ = c.cef_string_utf16_to_utf8(cef_str.str, cef_str.length, &utf8);
    if (utf8.str == null or utf8.length == 0) return buf[0..0];
    const len = @min(utf8.length, buf.len);
    @memcpy(buf[0..len], utf8.str[0..len]);
    if (utf8.dtor) |dtor| dtor(utf8.str);
    return buf[0..len];
}

/// cef_string_userfree_t → UTF-8 (스택 버퍼에 복사, userfree 해제)
pub fn cefUserfreeToUtf8(userfree: c.cef_string_userfree_t, buf: []u8) []const u8 {
    if (userfree == null) return buf[0..0];
    const result = cefStringToUtf8(userfree, buf);
    c.cef_string_userfree_utf16_free(userfree);
    return result;
}

/// 브라우저의 main frame URL 추출 — Phase 2.5 `event.window.url` 원천.
/// 실패(프레임 없음/URL 빈 문자열)는 null → 호출자가 wire 필드 생략.
/// **캐시 우선** — OnAddressChange가 갱신한 BrowserEntry.url_cache를 먼저 보고,
/// 없을 때만 frame.get_url(alloc + UTF8 변환 + free)로 폴백. 매 invoke마다 호출되는 핫경로.
pub fn getMainFrameUrl(browser: *c.cef_browser_t, buf: []u8) ?[]const u8 {
    // 1) 캐시 시도
    if (cef.globalNative()) |native| {
        const handle: u64 = @intCast(browser.get_identifier.?(browser));
        if (native.browsers.getPtr(handle)) |entry| {
            if (entry.url_cache_len > 0) {
                return entry.url_cache_buf[0..entry.url_cache_len];
            }
        }
    }
    // 2) 폴백 — 캐시 미스 (초기 로드 전 / URL 길이 초과 / native 미등록)
    const frame = asPtr(c.cef_frame_t, browser.get_main_frame.?(browser)) orelse return null;
    const get_url = frame.get_url orelse return null;
    const userfree = get_url(frame);
    if (userfree == null) return null;
    const url = cefUserfreeToUtf8(userfree, buf);
    if (url.len == 0) return null;
    return url;
}

/// CEF cef_frame_t.is_main의 Zig friendly 래퍼 (C int → bool, vtable null-safe).
pub fn frameIsMain(frame: *c.cef_frame_t) ?bool {
    const fn_ptr = frame.is_main orelse return null;
    return fn_ptr(frame) == 1;
}

pub fn initBaseRefCounted(base: *c.cef_base_ref_counted_t) void {
    base.add_ref = &addRef;
    base.release = &release;
    base.has_one_ref = &hasOneRef;
    base.has_at_least_one_ref = &hasAtLeastOneRef;
}

// TODO: no-op 참조 카운팅 — 글로벌 스태틱 객체에는 안전하지만,
//       동적 CEF 객체(멀티 브라우저 등) 사용 시 실제 ref counting 구현 필요.
fn addRef(_: ?*c.cef_base_ref_counted_t) callconv(.c) void {}
fn release(_: ?*c.cef_base_ref_counted_t) callconv(.c) i32 {
    return 1;
}
fn hasOneRef(_: ?*c.cef_base_ref_counted_t) callconv(.c) i32 {
    return 1;
}
fn hasAtLeastOneRef(_: ?*c.cef_base_ref_counted_t) callconv(.c) i32 {
    return 1;
}
