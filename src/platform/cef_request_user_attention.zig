//! app.requestUserAttention — cef.zig 에서 분리(동작 무변경).
//! macOS NSApplication dock bounce request/cancel bridge.
const builtin = @import("builtin");
const cef = @import("cef.zig");

const is_macos = builtin.os.tag == .macos;

const objc = cef.objc;
const getClass = cef.getClass;
const msgSend = cef.msgSend;

// ============================================
// app.requestUserAttention — dock bounce (Electron `app.requestUserAttention`)
// ============================================
// 반환된 request_id로 cancel 가능 (NSApp 내부 큐). 호출 시점에 앱이 이미 active면
// NSApp가 0을 반환 (no-op) — wrapper도 0 그대로 노출. Linux/Windows는 후속.

/// NSRequestUserAttentionType — `<AppKit/NSApplication.h>`.
const kNSCriticalRequest: c_long = 0; // 활성화될 때까지 반복 바운스
const kNSInformationalRequest: c_long = 10; // 1회 바운스

/// dock 아이콘 바운스 시작. 0이면 no-op (앱이 이미 active). 아니면 cancel용 request_id.
pub fn appRequestUserAttention(critical: bool) u32 {
    if (!comptime is_macos) return 0;
    const NSApplication = getClass("NSApplication") orelse return 0;
    const app = msgSend(NSApplication, "sharedApplication") orelse return 0;
    const sel = objc.sel_registerName("requestUserAttention:");
    const f: *const fn (?*anyopaque, ?*anyopaque, c_long) callconv(.c) c_long = @ptrCast(&objc.objc_msgSend);
    const id = f(app, @ptrCast(sel), if (critical) kNSCriticalRequest else kNSInformationalRequest);
    return if (id > 0) @intCast(id) else 0;
}

/// dock 바운스 취소. NSApp `cancelUserAttentionRequest:`가 void라 stale/never-issued
/// nonzero id도 true 반환 — id == 0만 false (guard). 사용자는 stale 검증 불가.
pub fn appCancelUserAttentionRequest(id: u32) bool {
    if (!comptime is_macos) return false;
    if (id == 0) return false;
    const NSApplication = getClass("NSApplication") orelse return false;
    const app = msgSend(NSApplication, "sharedApplication") orelse return false;
    const sel = objc.sel_registerName("cancelUserAttentionRequest:");
    const f: *const fn (?*anyopaque, ?*anyopaque, c_long) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    f(app, @ptrCast(sel), @intCast(id));
    return true;
}
