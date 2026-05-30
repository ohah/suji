//! Shell API — cef.zig 에서 분리(동작 무변경). NSWorkspace(macOS) /
//! GIO(Linux) / Win32 ShellExecute(Windows). main.zig 의 __core__ 디스패치는
//! cef.shell* 를 호출하며, cef.zig 가 이 파일의 pub fn 을 re-export 한다.
const std = @import("std");
const builtin = @import("builtin");
const linux_shell = @import("cef_shell_linux.zig");
const windows_shell = @import("cef_shell_windows.zig");
const cef = @import("cef.zig");

const is_macos = builtin.os.tag == .macos;
const is_linux = builtin.os.tag == .linux;

const objc = cef.objc;
const getClass = cef.getClass;
const msgSend = cef.msgSend;
const msgSendVoid1 = cef.msgSendVoid1;
const nsStringFromSlice = cef.nsStringFromSlice;
const nsFileUrlIfExists = cef.nsFileUrlIfExists;

// Linux는 GIO 기반으로 검증 가능한 surface부터 채운다. 기본 URI 핸들러는
// Actions에서 임시 x-scheme-handler를 등록해 end-to-end로 검증한다.

/// 시스템 기본 핸들러로 URL 열기 (Electron `shell.openExternal`). http(s) → 기본 브라우저,
/// mailto: → 메일 앱 등. URL syntax invalid 또는 scheme 누락이면 false (LaunchServices에
/// 보내면 -50 OS dialog 발생하므로 사전 차단).
pub fn shellOpenExternal(url: []const u8) bool {
    if (comptime builtin.os.tag == .windows) return windows_shell.openExternal(url);
    if (comptime is_linux) return linux_shell.openExternal(url);
    if (!comptime is_macos) return false;
    const ns_url_str = nsStringFromSlice(url) orelse return false;
    const NSURL = getClass("NSURL") orelse return false;
    const urlFn: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque =
        @ptrCast(&objc.objc_msgSend);
    const ns_url = urlFn(NSURL, @ptrCast(objc.sel_registerName("URLWithString:")), ns_url_str) orelse return false;

    // scheme 검사 — URLWithString은 relative URL("noschemejustwords")도 통과시키지만
    // openURL:에 넘기면 macOS가 "해당 프로그램을 열 수 없습니다 (-50)" 시스템 알림.
    const scheme = msgSend(ns_url, "scheme") orelse return false;
    const utf8Fn: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) ?[*:0]const u8 =
        @ptrCast(&objc.objc_msgSend);
    const scheme_cstr = utf8Fn(scheme, @ptrCast(objc.sel_registerName("UTF8String"))) orelse return false;
    if (std.mem.span(scheme_cstr).len == 0) return false;

    const NSWorkspace = getClass("NSWorkspace") orelse return false;
    const ws = msgSend(NSWorkspace, "sharedWorkspace") orelse return false;
    const openFn: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) u8 =
        @ptrCast(&objc.objc_msgSend);
    return openFn(ws, @ptrCast(objc.sel_registerName("openURL:")), ns_url) != 0;
}

/// Finder에서 항목 reveal — 부모 폴더가 열리고 해당 파일/폴더 선택 (Electron `shell.showItemInFolder`).
/// 존재하지 않는 경로는 NSFileManager.fileExistsAtPath: 사전 검증으로 차단 (없는 경로를
/// activateFileViewerSelectingURLs:에 넘기면 macOS -50 dialog). 존재하면 file:// URL로
/// modern API `activateFileViewerSelectingURLs:` 호출 (deprecated `selectFile:inFileViewerRootedAtPath:`
/// 대체).
pub fn shellShowItemInFolder(path: []const u8) bool {
    if (comptime builtin.os.tag == .windows) return windows_shell.showItemInFolder(path);
    if (comptime is_linux) return linux_shell.showItemInFolder(path);
    if (!comptime is_macos) return false;
    const ns_url = nsFileUrlIfExists(path) orelse return false;

    const NSArray = getClass("NSArray") orelse return false;
    const arrayFn: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque =
        @ptrCast(&objc.objc_msgSend);
    const ns_arr = arrayFn(NSArray, @ptrCast(objc.sel_registerName("arrayWithObject:")), ns_url) orelse return false;

    const NSWorkspace = getClass("NSWorkspace") orelse return false;
    const ws = msgSend(NSWorkspace, "sharedWorkspace") orelse return false;
    msgSendVoid1(ws, "activateFileViewerSelectingURLs:", ns_arr);
    return true;
}

/// 시스템 비프음 (Electron `shell.beep`). NSBeep — AppKit C symbol.
pub fn shellBeep() void {
    if (comptime builtin.os.tag == .windows) {
        windows_shell.beep();
        return;
    }
    if (comptime is_linux) {
        linux_shell.beep();
        return;
    }
    if (!comptime is_macos) return;
    objc.NSBeep();
}

/// 파일 기본 앱으로 열기 (Electron `shell.openPath` — `openExternal`은 URL용,
/// 이건 로컬 파일/폴더 path용). 존재하지 않는 경로는 false.
pub fn shellOpenPath(path: []const u8) bool {
    if (comptime builtin.os.tag == .windows) return windows_shell.openPath(path);
    if (comptime is_linux) return linux_shell.openPath(path);
    if (!comptime is_macos) return false;
    const ns_url = nsFileUrlIfExists(path) orelse return false;
    const NSWorkspace = getClass("NSWorkspace") orelse return false;
    const ws = msgSend(NSWorkspace, "sharedWorkspace") orelse return false;
    const openFn: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) u8 =
        @ptrCast(&objc.objc_msgSend);
    return openFn(ws, @ptrCast(objc.sel_registerName("openURL:")), ns_url) != 0;
}

/// 휴지통으로 이동 (Electron `shell.trashItem`). 동기 — NSFileManager
/// `trashItemAtURL:resultingItemURL:error:` BOOL 반환. 존재하지 않는 경로/권한 부족 등
/// 은 false. resultingItemURL/error는 nil 전달 (caller가 결과 path 필요 없음).
pub fn shellTrashItem(path: []const u8) bool {
    if (comptime builtin.os.tag == .windows) return windows_shell.trashItem(path);
    if (comptime is_linux) return linux_shell.trashItem(path);
    if (!comptime is_macos) return false;
    const ns_path = nsStringFromSlice(path) orelse return false;

    const NSURL = getClass("NSURL") orelse return false;
    const fileUrlFn: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque =
        @ptrCast(&objc.objc_msgSend);
    const ns_url = fileUrlFn(NSURL, @ptrCast(objc.sel_registerName("fileURLWithPath:")), ns_path) orelse return false;

    const NSFileManager = getClass("NSFileManager") orelse return false;
    const fm = msgSend(NSFileManager, "defaultManager") orelse return false;
    const trashFn: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) u8 =
        @ptrCast(&objc.objc_msgSend);
    const ok = trashFn(fm, @ptrCast(objc.sel_registerName("trashItemAtURL:resultingItemURL:error:")), ns_url, null, null);
    return ok != 0;
}
