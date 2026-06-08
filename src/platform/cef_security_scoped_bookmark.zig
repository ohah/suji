//! Security-scoped bookmarks — cef.zig 에서 분리(동작 무변경).
//! NSURL bookmarkDataWithOptions + security-scoped access lifecycle.
const std = @import("std");
const builtin = @import("builtin");
const cef = @import("cef.zig");

const is_macos = builtin.os.tag == .macos;

const objc = cef.objc;
const getClass = cef.getClass;
const msgSend = cef.msgSend;
const nsStringToUtf8Buf = cef.nsStringToUtf8Buf;
const nsFileUrlIfExists = cef.nsFileUrlIfExists;
const CFDataCreate = cef.CFDataCreate;
const CFDataGetBytePtr = cef.CFDataGetBytePtr;
const CFDataGetLength = cef.CFDataGetLength;
const CFRelease = cef.CFRelease;

// ============================================
// Security-scoped bookmarks (Electron `dialog securityScopedBookmarks` +
// `app.startAccessingSecurityScopedResource`)
// ============================================
// App Sandbox 앱이 사용자 선택 파일/폴더에 *재실행 후에도* 접근하려면 필수.
// create → base64 bookmark 영속화, start → 해소 + 접근 시작(accessId), stop →
// 접근 종료. Electron 은 start 가 stop 클로저를 반환하나 IPC 모델상 함수 전달
// 불가 → opaque accessId + 별도 stop cmd (4 SDK 동형).
//
// ⚠️ 정직 경계: `WithSecurityScope` 의 *실제* 권한 격상은 App Sandbox + bookmarks
// entitlement(`com.apple.security.files.bookmarks.{app,document}-scope`) 하에서만
// 효력. 비-sandbox(기본 빌드)에선 일반 bookmark 로 동작 — create/resolve/path
// round-trip·start/stop 호출은 성공하나 sandbox escapement 는 no-op. MAS 실
// 격상은 `suji build --sandbox` + 실 App Store 환경 필요 = 로컬 미검증.

/// NSURLBookmarkCreationWithSecurityScope (1 << 11) — `<Foundation/NSURL.h>`.
const kNSURLBookmarkCreationWithSecurityScope: c_ulong = 1 << 11;
/// NSURLBookmarkResolutionWithSecurityScope (1 << 10).
const kNSURLBookmarkResolutionWithSecurityScope: c_ulong = 1 << 10;

/// 활성 security-scoped accessId → 해소된 NSURL(retain). slot index+1 = id,
/// 0 = invalid. stop 시 release+clear. 동시 접근 한도 = 풀 크기(초과 시 start
/// 가 0 반환 — 누수 대신 정직 실패).
/// ⚠️ 한계(정직): (1) generation 없음 — stop 후 같은 slot 재사용 시 *낡은* id 가
/// 새 NSURL 을 가리킬 수 있음(ABA). caller 는 stop 이후 id 를 보관/재사용 금지.
/// (2) stop 미호출 id 는 NSURL retain + 접근 grant + slot 1칸을 프로세스 종료까지
/// 점유(Electron stop-클로저 "반드시 호출" 계약과 동일). 둘 다 caller 계약 위반
/// 시에만 발생 — 다른 풀(g_cookie_visitors 등)과 동일 trade-off.
const SCOPED_ACCESS_POOL: usize = 32;
var g_scoped_urls: [SCOPED_ACCESS_POOL]?*anyopaque = [_]?*anyopaque{null} ** SCOPED_ACCESS_POOL;

/// path → security-scoped bookmark. 성공 시 base64 bookmark 를 out 에 기록한
/// slice, 실패 시 빈 slice. (bookmark 바이트엔 JSON-special 없음 — base64 알파벳.)
pub fn securityScopedBookmarkCreate(path: []const u8, out: []u8) []const u8 {
    if (!comptime is_macos) return out[0..0];
    // bookmarkDataWithOptions 는 존재 path 필수 — nsFileUrlIfExists 가 존재검증+NSURL 동시.
    const url = nsFileUrlIfExists(path) orelse return out[0..0];

    const bmFn: *const fn (?*anyopaque, ?*anyopaque, c_ulong, ?*anyopaque, ?*anyopaque, ?*?*anyopaque) callconv(.c) ?*anyopaque =
        @ptrCast(&objc.objc_msgSend);
    const data = bmFn(
        url,
        @ptrCast(objc.sel_registerName("bookmarkDataWithOptions:includingResourceValuesForKeys:relativeToURL:error:")),
        kNSURLBookmarkCreationWithSecurityScope,
        null,
        null,
        null,
    ) orelse return out[0..0];

    const ptr = CFDataGetBytePtr(data);
    const len: usize = @intCast(CFDataGetLength(data));
    if (len == 0) return out[0..0];
    const enc = std.base64.standard.Encoder;
    if (enc.calcSize(len) > out.len) return out[0..0];
    return enc.encode(out, ptr[0..len]);
}

/// 해소 결과 — accessId(0=실패), 해소된 path, 재생성 권장 여부(stale).
pub const ScopedAccess = struct { id: u32, path: []const u8, stale: bool };

/// base64 bookmark → 해소 + 접근 시작. out_path 에 해소된 경로 기록. 실패 시 id=0.
pub fn securityScopedAccessStart(b64: []const u8, out_path: []u8) ScopedAccess {
    const fail = ScopedAccess{ .id = 0, .path = out_path[0..0], .stale = false };
    if (!comptime is_macos) return fail;

    const dec = std.base64.standard.Decoder;
    const raw_len = dec.calcSizeForSlice(b64) catch return fail;
    var raw_buf: [8192]u8 = undefined;
    if (raw_len > raw_buf.len) return fail;
    dec.decode(raw_buf[0..raw_len], b64) catch return fail;

    const data = CFDataCreate(null, raw_buf[0..raw_len].ptr, @intCast(raw_len)) orelse return fail;
    defer CFRelease(data);

    const NSURL = getClass("NSURL") orelse return fail;
    var stale: u8 = 0;
    const resolveFn: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque, c_ulong, ?*anyopaque, *u8, ?*?*anyopaque) callconv(.c) ?*anyopaque =
        @ptrCast(&objc.objc_msgSend);
    const url = resolveFn(
        NSURL,
        @ptrCast(objc.sel_registerName("URLByResolvingBookmarkData:options:relativeToURL:bookmarkDataIsStale:error:")),
        data,
        kNSURLBookmarkResolutionWithSecurityScope,
        null,
        &stale,
        null,
    ) orelse return fail;

    if (!cef.msgSendBool(url, "startAccessingSecurityScopedResource")) return fail;

    const slot = for (&g_scoped_urls, 0..) |*u, i| {
        if (u.* == null) break i;
    } else {
        // 풀 소진 — 접근은 시작됐으니 즉시 stop 후 정직 실패(누수 회피).
        const stopFn: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
        stopFn(url, @ptrCast(objc.sel_registerName("stopAccessingSecurityScopedResource")));
        return fail;
    };
    g_scoped_urls[slot] = msgSend(url, "retain") orelse url;

    const path_obj = msgSend(url, "path");
    const path = if (path_obj) |p| nsStringToUtf8Buf(p, out_path) else out_path[0..0];
    return .{ .id = @intCast(slot + 1), .path = path, .stale = stale != 0 };
}

/// accessId 의 접근 종료 + NSURL release. 유효하지 않은 id 는 false.
pub fn securityScopedAccessStop(id: u32) bool {
    if (!comptime is_macos) return false;
    if (id == 0 or id > SCOPED_ACCESS_POOL) return false;
    const slot = id - 1;
    const url = g_scoped_urls[slot] orelse return false;
    const stopFn: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    stopFn(url, @ptrCast(objc.sel_registerName("stopAccessingSecurityScopedResource")));
    _ = msgSend(url, "release");
    g_scoped_urls[slot] = null;
    return true;
}
