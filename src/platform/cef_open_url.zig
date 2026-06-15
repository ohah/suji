//! app.on('open-url') — macOS deep-link 수신 (NSAppleEventManager kAEGetURL Apple Event).
//! deepLinkSchemes(suji.json → CFBundleURLTypes)로 등록된 scheme(myapp://)으로 앱이 열리면 발화.
//! SujiQuitTarget(cef_mac_app_menu) 패턴 — objc dynamic class(objc_allocateClassPair) + Apple Event handler.
//! ⚠️ 실 deep-link 검증은 .app 번들 + URL scheme 등록 + 실제 열기 필요(헤드리스 불가, 빌드+wire 검증 — 정직 경계).
const builtin = @import("builtin");
const cef = @import("cef.zig");

const is_macos = builtin.os.tag == .macos;
const objc = cef.objc;
const getClass = cef.getClass;
const msgSend = cef.msgSend;
const nsStringToUtf8Buf = cef.nsStringToUtf8Buf;

// Apple Event 4-char codes: kInternetEventClass='GURL', kAEGetURL='GURL', keyDirectObject='----'.
const kInternetEventClass: u32 = 0x4755524C; // 'GURL'
const kAEGetURL: u32 = 0x4755524C; // 'GURL'
const keyDirectObject: u32 = 0x2D2D2D2D; // '----'

/// open-url emit 콜백 — main 이 주입(emit "app:open-url"). C ABI.
pub const OpenURLFn = *const fn (url_ptr: [*]const u8, url_len: usize) callconv(.c) void;
var g_open_url_handler: ?OpenURLFn = null;
var g_open_url_target: ?*anyopaque = null;

/// kAEGetURL Apple Event 핸들러 (self, _cmd, event, replyEvent). event 의 직접객체 = URL 문자열.
fn sujiOpenURLImpl(_: ?*anyopaque, _: ?*anyopaque, event: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const handler = g_open_url_handler orelse return;
    // event paramDescriptorForKeyword:keyDirectObject → stringValue.
    const param_fn: *const fn (?*anyopaque, ?*anyopaque, u32) callconv(.c) ?*anyopaque = @ptrCast(&objc.objc_msgSend);
    const desc = param_fn(event, @ptrCast(objc.sel_registerName("paramDescriptorForKeyword:")), keyDirectObject) orelse return;
    const url_obj = msgSend(desc, "stringValue") orelse return;
    var buf: [4096]u8 = undefined;
    const url = nsStringToUtf8Buf(url_obj, &buf);
    if (url.len == 0) return;
    handler(url.ptr, url.len);
}

/// open-url 핸들러 설치 (Electron `app.on('open-url')`). main 이 emit 콜백 주입 후 1회 호출.
/// NSAppleEventManager 에 kInternetEventClass/kAEGetURL 핸들러 등록. macOS only(no-op). 멱등.
pub fn installOpenURLHandler(handler: OpenURLFn) void {
    g_open_url_handler = handler;
    if (!comptime is_macos) return;
    if (g_open_url_target != null) return;
    const NSObject = getClass("NSObject") orelse return;
    const sel = objc.sel_registerName("handleGetURLEvent:withReplyEvent:");
    // 새 클래스 생성 성공 시에만 메서드 추가 + 등록 — 이미 등록된 클래스(재호출 fallback)에
    // 재-registerClassPair 하면 abort 위험(objc 제약). "v@:@@"=void, self, _cmd, event, replyEvent.
    const cls = if (objc.objc_allocateClassPair(NSObject, "SujiOpenURLTarget", 0)) |new_cls| blk: {
        _ = objc.class_addMethod(new_cls, @ptrCast(sel), @ptrCast(&sujiOpenURLImpl), "v@:@@");
        objc.objc_registerClassPair(new_cls);
        break :blk new_cls;
    } else getClass("SujiOpenURLTarget") orelse return;
    const alloc = msgSend(cls, "alloc") orelse return;
    const instance = msgSend(alloc, "init") orelse return;
    g_open_url_target = instance;
    const NSAppleEventManager = getClass("NSAppleEventManager") orelse return;
    const mgr = msgSend(NSAppleEventManager, "sharedAppleEventManager") orelse return;
    // setEventHandler:andSelector:forEventClass:andEventID:
    const set_fn: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque, ?*anyopaque, u32, u32) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    set_fn(mgr, @ptrCast(objc.sel_registerName("setEventHandler:andSelector:forEventClass:andEventID:")), instance, @ptrCast(sel), kInternetEventClass, kAEGetURL);
}
