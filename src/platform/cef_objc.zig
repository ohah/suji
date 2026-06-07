//! Shared macOS Objective-C bridge helpers used by CEF domain modules.
const std = @import("std");
const builtin = @import("builtin");

const is_macos = builtin.os.tag == .macos;

// Zig 0.16 translate-c가 objc/runtime.h의 block pointer(^) 문법을 파싱하지 못해서
// 필요한 심볼만 직접 extern 선언.
pub const objc = if (is_macos) struct {
    pub extern "c" fn sel_registerName(name: [*:0]const u8) ?*anyopaque;
    pub extern "c" fn objc_getClass(name: [*:0]const u8) ?*anyopaque;
    pub extern "c" fn objc_msgSend() void; // 호출부에서 구체 시그니처로 @ptrCast
    pub extern "c" fn class_addMethod(
        cls: ?*anyopaque,
        sel: ?*anyopaque,
        imp: *const fn () callconv(.c) void,
        types: [*:0]const u8,
    ) u8;
    pub extern "c" fn class_getMethodImplementation(cls: ?*anyopaque, name: ?*anyopaque) *const fn () callconv(.c) void;
    pub extern "c" fn objc_allocateClassPair(superclass: ?*anyopaque, name: [*:0]const u8, extra_bytes: usize) ?*anyopaque;
    pub extern "c" fn objc_registerClassPair(cls: ?*anyopaque) void;
    /// AppKit 시스템 비프 (NSGraphics.h). Cocoa 프레임워크 링크로 자동 가용.
    pub extern "c" fn NSBeep() void;
} else struct {
    // 비-macOS 스텁 — 이 심볼을 쓰는 헬퍼는 전부 macOS 전용(is_macos
    // runtime/comptime 가드)이라 비-macOS 에선 호출 안 됨. 크로스 컴파일만
    // 통과시키면 되므로 unreachable 본문.
    pub fn sel_registerName(_: [*:0]const u8) ?*anyopaque {
        unreachable;
    }
    pub fn objc_getClass(_: [*:0]const u8) ?*anyopaque {
        unreachable;
    }
    pub fn objc_msgSend() void {
        unreachable;
    }
    pub fn class_addMethod(_: ?*anyopaque, _: ?*anyopaque, _: *const fn () callconv(.c) void, _: [*:0]const u8) u8 {
        unreachable;
    }
    pub fn class_getMethodImplementation(_: ?*anyopaque, _: ?*anyopaque) *const fn () callconv(.c) void {
        unreachable;
    }
    pub fn objc_allocateClassPair(_: ?*anyopaque, _: [*:0]const u8, _: usize) ?*anyopaque {
        unreachable;
    }
    pub fn objc_registerClassPair(_: ?*anyopaque) void {
        unreachable;
    }
    pub fn NSBeep() void {
        unreachable;
    }
};

/// URL 또는 path 길이 한도 (null terminator 포함). 4KB는 macOS NSString이 무난하게 처리 가능.
pub const SHELL_MAX_PATH: usize = 4096;

pub fn msgSend(target: anytype, sel_name: [:0]const u8) ?*anyopaque {
    const sel = objc.sel_registerName(sel_name.ptr);
    const func: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque = @ptrCast(&objc.objc_msgSend);
    return func(@ptrCast(target), @ptrCast(sel));
}

pub fn getClass(name: [:0]const u8) ?*anyopaque {
    return @ptrCast(objc.objc_getClass(name.ptr));
}

pub fn msgSendVoid1(target: ?*anyopaque, sel_name: [:0]const u8, arg: ?*anyopaque) void {
    const sel = objc.sel_registerName(sel_name.ptr);
    const func: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    func(target, @ptrCast(sel), arg);
}

/// 2-arg pointer 버전 — `setObject:forKey:` (NSDictionary) 등 (object, key) 시그니처 setter용.
pub fn msgSendVoid2(target: ?*anyopaque, sel_name: [:0]const u8, a1: ?*anyopaque, a2: ?*anyopaque) void {
    const sel = objc.sel_registerName(sel_name.ptr);
    const func: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    func(target, @ptrCast(sel), a1, a2);
}

/// BOOL 인자(u8 0/1) 버전 — setOpaque:/setHasShadow: 등 Objective-C BOOL setter용.
pub fn msgSendVoidBool(target: ?*anyopaque, sel_name: [:0]const u8, arg: bool) void {
    const sel = objc.sel_registerName(sel_name.ptr);
    const func: *const fn (?*anyopaque, ?*anyopaque, u8) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    func(target, @ptrCast(sel), if (arg) 1 else 0);
}

/// `[ns_win performSelector:@selector(makeKeyAndOrderFront:) withObject:nil afterDelay:0]`.
/// onBeforeClose 시점엔 AppKit이 close-time 비동기 focus 재할당을 미루고 있어
/// 즉시 makeKey가 덮어써짐 — afterDelay:0으로 다음 런루프 틱에 예약하면 안정.
pub fn deferMakeKeyAndOrderFront(ns_win: *anyopaque) void {
    if (!comptime is_macos) return;
    const sel_perform = objc.sel_registerName("performSelector:withObject:afterDelay:");
    const sel_make_key = objc.sel_registerName("makeKeyAndOrderFront:");
    const f: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque, ?*anyopaque, f64) callconv(.c) void =
        @ptrCast(&objc.objc_msgSend);
    f(ns_win, @ptrCast(sel_perform), @ptrCast(sel_make_key), null, 0.0);
}

pub fn activateNSApp() void {
    const cls = getClass("NSApplication") orelse return;
    const app = msgSend(cls, "sharedApplication") orelse return;

    _ = msgSend(app, "finishLaunching");

    const sel = objc.sel_registerName("activateIgnoringOtherApps:");
    const func: *const fn (?*anyopaque, ?*anyopaque, u8) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    func(app, @ptrCast(sel), 1);
}

/// `[ns_obj utf8String]`을 caller 스택 버퍼에 복사 — 공통 패턴(NSString-from-Zig-slice).
/// 성공 시 NSString*, 실패 시 null. text 길이가 capacity(null terminator 포함)를 넘으면 null.
pub fn nsStringFromSliceWithCapacity(text: []const u8, comptime capacity: usize) ?*anyopaque {
    if (text.len + 1 > capacity) return null;
    var stack_buf: [capacity]u8 = undefined;
    @memcpy(stack_buf[0..text.len], text);
    stack_buf[text.len] = 0;
    const cstr: [*:0]const u8 = @ptrCast(&stack_buf);
    const NSString = getClass("NSString") orelse return null;
    const strFn: *const fn (?*anyopaque, ?*anyopaque, [*:0]const u8) callconv(.c) ?*anyopaque =
        @ptrCast(&objc.objc_msgSend);
    return strFn(NSString, @ptrCast(objc.sel_registerName("stringWithUTF8String:")), cstr);
}

/// Shell/path용 NSString helper. URL/path는 4KB cap 유지.
pub fn nsStringFromSlice(text: []const u8) ?*anyopaque {
    return nsStringFromSliceWithCapacity(text, SHELL_MAX_PATH);
}

var g_empty_ns_string: ?*anyopaque = null;

/// 모든 NSMenuItem keyEquivalent에서 공유하는 `@""`. 메뉴 아이템마다 빈 NSString을 새로 만드는
/// 비용 회피.
pub fn emptyNSString() ?*anyopaque {
    if (g_empty_ns_string) |s| return s;
    const s = nsStringFromSlice("") orelse return null;
    g_empty_ns_string = s;
    return s;
}

/// 컴파일타임 cstring 리터럴용 NSString primitive. 동적 텍스트는 `nsStringFromSlice`(NUL-term
/// 자동) 사용 — `nsStringFromCstr`는 `[*:0]`이 이미 보장된 케이스(IOPM 같은 외부 API에 넘기는
/// 고정 문자열)에서 `nsStringFromSlice`의 4KB 스택 버퍼 비용 회피용.
pub fn nsStringFromCstr(cstr: [*:0]const u8) ?*anyopaque {
    const NSString = getClass("NSString") orelse return null;
    const fn_ptr: *const fn (?*anyopaque, ?*anyopaque, [*:0]const u8) callconv(.c) ?*anyopaque = @ptrCast(&objc.objc_msgSend);
    return fn_ptr(NSString, @ptrCast(objc.sel_registerName("stringWithUTF8String:")), cstr);
}

pub fn nsStringToUtf8Buf(ns_str: ?*anyopaque, out: []u8) []const u8 {
    const utf8_fn: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) ?[*:0]const u8 = @ptrCast(&objc.objc_msgSend);
    const cstr = utf8_fn(ns_str, @ptrCast(objc.sel_registerName("UTF8String"))) orelse return out[0..0];
    const len = std.mem.span(cstr).len;
    const n = @min(len, out.len);
    @memcpy(out[0..n], cstr[0..n]);
    return out[0..n];
}

/// NSMenuItem.tag 읽기 — checkbox 식별 용도.
pub fn menuItemTag(item: *anyopaque) i64 {
    const f: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) i64 = @ptrCast(&objc.objc_msgSend);
    return f(item, @ptrCast(objc.sel_registerName("tag")));
}

/// NSMenuItem.state 토글 (0 ↔ 1). checkbox 클릭 시 호출.
pub fn toggleMenuItemState(item: *anyopaque) void {
    const stateFn: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) i64 = @ptrCast(&objc.objc_msgSend);
    const setStateFn: *const fn (?*anyopaque, ?*anyopaque, i64) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    const current = stateFn(item, @ptrCast(objc.sel_registerName("state")));
    setStateFn(item, @ptrCast(objc.sel_registerName("setState:")), if (current == 0) 1 else 0);
}

/// NSMenuItem.representedObject (NSString*)에서 UTF-8 slice 추출. menu/tray click target에서
/// click name 디스패치용.
pub fn representedObjectUtf8(item: *anyopaque) ?[]const u8 {
    const repObjFn: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque = @ptrCast(&objc.objc_msgSend);
    const ns_str = repObjFn(item, @ptrCast(objc.sel_registerName("representedObject"))) orelse return null;
    const utf8Fn: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) ?[*:0]const u8 = @ptrCast(&objc.objc_msgSend);
    const cstr = utf8Fn(ns_str, @ptrCast(objc.sel_registerName("UTF8String"))) orelse return null;
    return std.mem.span(cstr);
}

/// path → NSURL fileURLWithPath: 변환. 존재 검증 통과 시만 NSURL 반환, 아니면 null.
/// shellOpenPath / showItemInFolder / securityScopedBookmark가 공유.
pub fn nsFileUrlIfExists(path: []const u8) ?*anyopaque {
    if (!comptime is_macos) return null;
    const ns_path = nsStringFromSlice(path) orelse return null;

    const NSFileManager = getClass("NSFileManager") orelse return null;
    const fm = msgSend(NSFileManager, "defaultManager") orelse return null;
    const existsFn: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) u8 =
        @ptrCast(&objc.objc_msgSend);
    if (existsFn(fm, @ptrCast(objc.sel_registerName("fileExistsAtPath:")), ns_path) == 0) return null;

    const NSURL = getClass("NSURL") orelse return null;
    const fileUrlFn: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque =
        @ptrCast(&objc.objc_msgSend);
    return fileUrlFn(NSURL, @ptrCast(objc.sel_registerName("fileURLWithPath:")), ns_path);
}

/// menu/tray click target에 공통 사용하는 ObjC method impl signature: `(self, _cmd, sender)`.
pub const ObjcSenderImpl = *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) void;

/// NSObject 서브클래스 + 단일 selector method 등록 + 인스턴스 alloc/init.
/// menu/tray click target 같은 stateless ObjC target에 공통 사용.
pub fn ensureSimpleObjcTarget(
    cache: *?*anyopaque,
    class_name: [:0]const u8,
    sel_name: [:0]const u8,
    impl: ObjcSenderImpl,
) ?*anyopaque {
    if (cache.*) |existing| return existing;
    if (!comptime is_macos) return null;
    const NSObject = getClass("NSObject") orelse return null;
    const cls = objc.objc_allocateClassPair(NSObject, class_name.ptr, 0) orelse
        getClass(class_name) orelse return null;
    const sel = objc.sel_registerName(sel_name.ptr);
    _ = objc.class_addMethod(cls, @ptrCast(sel), @ptrCast(impl), "v@:@");
    objc.objc_registerClassPair(cls);
    const alloc = msgSend(cls, "alloc") orelse return null;
    const instance = msgSend(alloc, "init") orelse return null;
    cache.* = instance;
    return instance;
}

pub fn setMenuItemEnabled(item: *anyopaque, enabled: bool) void {
    const f: *const fn (?*anyopaque, ?*anyopaque, u8) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    f(item, @ptrCast(objc.sel_registerName("setEnabled:")), if (enabled) 1 else 0);
}

/// Electron MenuItem.visible=false → NSMenuItem.setHidden:(메뉴에 존재하되 숨김).
pub fn setMenuItemHidden(item: *anyopaque, hidden: bool) void {
    const f: *const fn (?*anyopaque, ?*anyopaque, u8) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    f(item, @ptrCast(objc.sel_registerName("setHidden:")), if (hidden) 1 else 0);
}

pub fn setMenuItemState(item: *anyopaque, checked: bool) void {
    const f: *const fn (?*anyopaque, ?*anyopaque, i64) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    f(item, @ptrCast(objc.sel_registerName("setState:")), if (checked) 1 else 0);
}

pub fn setMenuItemTag(item: *anyopaque, tag: i64) void {
    const f: *const fn (?*anyopaque, ?*anyopaque, i64) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    f(item, @ptrCast(objc.sel_registerName("setTag:")), tag);
}
