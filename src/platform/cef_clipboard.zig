//! Clipboard API — cef.zig 에서 분리(동작 무변경). NSPasteboard(macOS) /
//! GTK Clipboard(Linux) / Win32 Clipboard(Windows). main.zig 의 __core__ 디스패치는
//! cef.clipboard* 를 호출하며, cef.zig 가 이 파일의 pub fn 을 re-export 한다.
//!
//! macOS ObjC 브리징 헬퍼(objc/getClass/msgSend/nsString*)는 cef.zig 의 공유
//! 구현을 alias 로 재사용 — 옮긴 블록의 호출부는 한 글자도 바뀌지 않는다.
const std = @import("std");
const builtin = @import("builtin");
const util = @import("util");
const cef = @import("cef.zig");
const clip_types = @import("cef_clipboard_types.zig");
const cef_clipboard_linux = @import("cef_clipboard_linux.zig");
const cef_clipboard_windows = @import("cef_clipboard_windows.zig");

const is_macos = builtin.os.tag == .macos;
const is_linux = builtin.os.tag == .linux;

// 공유 ObjC 브리징(cef.zig) alias — 호출부 무변경용.
const objc = cef.objc;
const getClass = cef.getClass;
const msgSend = cef.msgSend;
const nsStringFromCstr = cef.nsStringFromCstr;
const nsStringFromSlice = cef.nsStringFromSlice;
const nsStringFromSliceWithCapacity = cef.nsStringFromSliceWithCapacity;
const nsStringToUtf8Buf = cef.nsStringToUtf8Buf;
// CoreFoundation CFData (macOS) — image/tiff/buffer 경로.
const CFDataCreate = cef.CFDataCreate;
const CFDataGetBytePtr = cef.CFDataGetBytePtr;
const CFDataGetLength = cef.CFDataGetLength;
const CFRelease = cef.CFRelease;

/// 클립보드 텍스트용 NSString (cap = CLIPBOARD_MAX_TEXT+1). clipboard 전용이라
/// cef.zig 에서 함께 이동.
fn nsStringFromClipboardText(text: []const u8) ?*anyopaque {
    return nsStringFromSliceWithCapacity(text, CLIPBOARD_MAX_TEXT + 1);
}

// macOS: NSPasteboard generalPasteboard, UTI 기반 (public.utf8-plain-text 등).
// Linux: GTK clipboard plain text (X11/Wayland backend는 GTK가 선택).
// Windows: OpenClipboard/SetClipboardData/GetClipboardData + GlobalAlloc/Lock.
//   plain text → CF_UNICODETEXT (UTF-16LE), HTML → CF_HTML "HTML Format".
//   UTI ↔ CF format 매핑은 cfFormatFor*.
// 기타: no-op (readText는 빈 문자열, write/clear는 false 반환).

const CLIPBOARD_MAX_TEXT = clip_types.CLIPBOARD_MAX_TEXT;
const PASTEBOARD_TYPE_STRING = clip_types.PASTEBOARD_TYPE_STRING;
const PASTEBOARD_TYPE_HTML = clip_types.PASTEBOARD_TYPE_HTML;
const PASTEBOARD_TYPE_RTF = clip_types.PASTEBOARD_TYPE_RTF;

/// generalPasteboard에서 주어진 type의 string 추출 — 빈 slice면 missing/non-string.
fn clipboardReadType(buf: []u8, type_cstr: [*:0]const u8) []const u8 {
    if (comptime builtin.os.tag == .windows) {
        return cef_clipboard_windows.readType(buf, type_cstr);
    }
    if (comptime is_linux) {
        return cef_clipboard_linux.readType(buf, type_cstr);
    }
    if (!comptime is_macos) return buf[0..0];
    const NSPasteboard = getClass("NSPasteboard") orelse return buf[0..0];
    const pb = msgSend(NSPasteboard, "generalPasteboard") orelse return buf[0..0];
    const ns_type = nsStringFromCstr(type_cstr) orelse return buf[0..0];
    const stringForType: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque =
        @ptrCast(&objc.objc_msgSend);
    const ns_str = stringForType(pb, @ptrCast(objc.sel_registerName("stringForType:")), ns_type) orelse return buf[0..0];
    return nsStringToUtf8Buf(ns_str, buf);
}

/// generalPasteboard에 주어진 type으로 text 쓰기 — clearContents 호출 (다른 type 함께 제거).
fn clipboardWriteType(text: []const u8, type_cstr: [*:0]const u8) bool {
    if (comptime builtin.os.tag == .windows) {
        return cef_clipboard_windows.writeType(text, type_cstr);
    }
    if (comptime is_linux) {
        return cef_clipboard_linux.writeType(text, type_cstr);
    }
    if (!comptime is_macos) return false;
    const NSPasteboard = getClass("NSPasteboard") orelse return false;
    const pb = msgSend(NSPasteboard, "generalPasteboard") orelse return false;
    _ = msgSend(pb, "clearContents");
    return pbSetString(pb, text, type_cstr); // 단일-타입 = clear + 1회 set.
}

/// 시스템 클립보드에서 plain text 읽기 — buf에 복사 후 slice 반환. 비어 있거나
/// non-text content면 빈 슬라이스. buf보다 긴 텍스트는 잘림.
pub fn clipboardReadText(buf: []u8) []const u8 {
    return clipboardReadType(buf, PASTEBOARD_TYPE_STRING);
}

/// 시스템 클립보드에 plain text 쓰기. clear 후 setString:forType: 호출. 성공 시 true.
pub fn clipboardWriteText(text: []const u8) bool {
    return clipboardWriteType(text, PASTEBOARD_TYPE_STRING);
}

/// 시스템 클립보드 비우기 (clearContents).
pub fn clipboardClear() void {
    if (comptime builtin.os.tag == .windows) {
        cef_clipboard_windows.clear();
        return;
    }
    if (comptime is_linux) {
        cef_clipboard_linux.clear();
        return;
    }
    if (!comptime is_macos) return;
    const NSPasteboard = getClass("NSPasteboard") orelse return;
    const pb = msgSend(NSPasteboard, "generalPasteboard") orelse return;
    _ = msgSend(pb, "clearContents");
}

/// (macOS) 이미 clear 된 pasteboard 에 setString:forType: 1회 — clear 안 함. 다중-타입
/// atomic write(bookmark/write/clipboardWriteType) 의 빌딩블록. nsString 변환 실패 시 false
/// (빈 문자열은 유효 NSString 이라 성공 — 호출부가 .len 으로 skip 판단).
fn pbSetString(pb: *anyopaque, text: []const u8, type_cstr: [*:0]const u8) bool {
    const ns_text = nsStringFromClipboardText(text) orelse return false;
    const ns_type = nsStringFromCstr(type_cstr) orelse return false;
    const setFn: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) u8 =
        @ptrCast(&objc.objc_msgSend);
    return setFn(pb, @ptrCast(objc.sel_registerName("setString:forType:")), ns_text, ns_type) != 0;
}

/// Electron `clipboard.writeBookmark(title, url)` — macOS NSPasteboard public.url(+url-name).
/// macOS only(bookmark 포맷은 macOS/Win 고유) — Win/Linux false(honest 경계).
pub fn clipboardWriteBookmark(title: []const u8, url: []const u8) bool {
    if (!comptime is_macos) return false;
    const NSPasteboard = getClass("NSPasteboard") orelse return false;
    const pb = msgSend(NSPasteboard, "generalPasteboard") orelse return false;
    _ = msgSend(pb, "clearContents");
    const url_ok = pbSetString(pb, url, "public.url");
    // url-name(title)은 best-effort — 실패해도 url 만 성공하면 true.
    _ = pbSetString(pb, title, "public.url-name");
    return url_ok;
}

/// Electron `clipboard.writeFindText(text)` — macOS Find pasteboard("Apple Find Pasteboard").
/// cross-app find. macOS only(Win/Linux 개념 없음 → false).
pub fn clipboardWriteFindText(text: []const u8) bool {
    if (!comptime is_macos) return false;
    const NSPasteboard = getClass("NSPasteboard") orelse return false;
    const ns_name = nsStringFromCstr("Apple Find Pasteboard") orelse return false;
    const nameFn: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque =
        @ptrCast(&objc.objc_msgSend);
    const pb = nameFn(NSPasteboard, @ptrCast(objc.sel_registerName("pasteboardWithName:")), ns_name) orelse return false;
    _ = msgSend(pb, "clearContents");
    return pbSetString(pb, text, PASTEBOARD_TYPE_STRING);
}

/// Electron `clipboard.readFindText()` — macOS Find pasteboard("Apple Find Pasteboard") 읽기.
/// writeFindText 대칭. macOS only(Win/Linux 개념 없음 → 빈 slice). non-text면 빈 slice.
pub fn clipboardReadFindText(buf: []u8) []const u8 {
    if (!comptime is_macos) return buf[0..0];
    const NSPasteboard = getClass("NSPasteboard") orelse return buf[0..0];
    const ns_name = nsStringFromCstr("Apple Find Pasteboard") orelse return buf[0..0];
    const nameFn: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque =
        @ptrCast(&objc.objc_msgSend);
    const pb = nameFn(NSPasteboard, @ptrCast(objc.sel_registerName("pasteboardWithName:")), ns_name) orelse return buf[0..0];
    const ns_type = nsStringFromCstr(PASTEBOARD_TYPE_STRING) orelse return buf[0..0];
    const stringForType: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque =
        @ptrCast(&objc.objc_msgSend);
    const ns_str = stringForType(pb, @ptrCast(objc.sel_registerName("stringForType:")), ns_type) orelse return buf[0..0];
    return nsStringToUtf8Buf(ns_str, buf);
}

/// Electron `clipboard.write({text,html,rtf})` — 여러 포맷 atomic write(clear 1회).
/// 빈 문자열 필드는 skip. macOS=실 atomic; Win/Linux=best-effort 단일 포맷(text 우선,
/// 멀티-포맷 atomic 미지원 — honest 경계). 하나라도 쓰면 true.
pub fn clipboardWriteMulti(text: []const u8, html: []const u8, rtf: []const u8) bool {
    if (comptime builtin.os.tag == .windows or is_linux) {
        if (text.len > 0) return clipboardWriteType(text, PASTEBOARD_TYPE_STRING);
        if (html.len > 0) return clipboardWriteType(html, PASTEBOARD_TYPE_HTML);
        if (rtf.len > 0) return clipboardWriteType(rtf, PASTEBOARD_TYPE_RTF);
        return false;
    }
    if (!comptime is_macos) return false;
    const NSPasteboard = getClass("NSPasteboard") orelse return false;
    const pb = msgSend(NSPasteboard, "generalPasteboard") orelse return false;
    _ = msgSend(pb, "clearContents");
    var any = false;
    if (text.len > 0 and pbSetString(pb, text, PASTEBOARD_TYPE_STRING)) any = true;
    if (html.len > 0 and pbSetString(pb, html, PASTEBOARD_TYPE_HTML)) any = true;
    if (rtf.len > 0 and pbSetString(pb, rtf, PASTEBOARD_TYPE_RTF)) any = true;
    return any;
}

/// 클립보드에 PNG 바이트 쓰기 (Electron `clipboard.writeImage`). clipboardWriteBuffer wrapper.
pub fn clipboardWriteImagePng(png_bytes: []const u8) bool {
    return clipboardWriteBuffer(png_bytes, "public.png");
}

/// 클립보드에서 PNG 바이트 읽기 (Electron `clipboard.readImage`). clipboardReadBuffer wrapper.
/// out_buf 부족 시 잘린 garbage 대신 빈 slice (clipboardReadBuffer 동작과 동일).
pub fn clipboardReadImagePng(out_buf: []u8) []const u8 {
    return clipboardReadBuffer(out_buf, "public.png");
}

/// 클립보드에 TIFF 바이트 쓰기 (NSPasteboard `public.tiff`). PNG 와 동형 — TIFF 는
/// 바이너리라 텍스트 RTF 가 아니라 CFData 기반 clipboardWriteBuffer wrapper.
pub fn clipboardWriteTiff(tiff_bytes: []const u8) bool {
    return clipboardWriteBuffer(tiff_bytes, "public.tiff");
}

/// 클립보드에서 TIFF 바이트 읽기 (`public.tiff`). out_buf 부족 시 빈 slice.
pub fn clipboardReadTiff(out_buf: []u8) []const u8 {
    return clipboardReadBuffer(out_buf, "public.tiff");
}

/// 클립보드에 주어진 type이 있는지 (Electron `clipboard.has(format)`).
/// type_cstr는 NSPasteboard UTI ("public.utf8-plain-text" / "public.html" 등).
pub fn clipboardHas(type_cstr: [*:0]const u8) bool {
    if (comptime builtin.os.tag == .windows) return cef_clipboard_windows.has(type_cstr);
    if (comptime is_linux) return cef_clipboard_linux.has(type_cstr);
    if (!comptime is_macos) return false;
    const NSPasteboard = getClass("NSPasteboard") orelse return false;
    const pb = msgSend(NSPasteboard, "generalPasteboard") orelse return false;
    const ns_type = nsStringFromCstr(type_cstr) orelse return false;
    const stringForType: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque =
        @ptrCast(&objc.objc_msgSend);
    return stringForType(pb, @ptrCast(objc.sel_registerName("stringForType:")), ns_type) != null;
}

/// 클립보드에 등록된 모든 type을 JSON 배열로 빌드 (Electron `clipboard.availableFormats`).
/// macOS는 UTI 이름을 그대로 반환 (e.g. "public.utf8-plain-text", "public.html").
pub fn clipboardAvailableFormats(out_buf: []u8) []const u8 {
    if (comptime is_linux) return cef_clipboard_linux.availableFormats(out_buf);
    if (comptime builtin.os.tag == .windows) return cef_clipboard_windows.availableFormats(out_buf);
    if (!comptime is_macos) {
        const empty = "[]";
        const n = @min(empty.len, out_buf.len);
        @memcpy(out_buf[0..n], empty[0..n]);
        return out_buf[0..n];
    }
    var w: std.Io.Writer = .fixed(out_buf);
    w.writeByte('[') catch return out_buf[0..1];

    const NSPasteboard = getClass("NSPasteboard") orelse {
        w.writeByte(']') catch {};
        return w.buffered();
    };
    const pb = msgSend(NSPasteboard, "generalPasteboard") orelse {
        w.writeByte(']') catch {};
        return w.buffered();
    };
    const types = msgSend(pb, "types") orelse {
        w.writeByte(']') catch {};
        return w.buffered();
    };
    const count_fn: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) usize = @ptrCast(&objc.objc_msgSend);
    const count = count_fn(types, @ptrCast(objc.sel_registerName("count")));

    // 콤마는 루프 인덱스(i>0)가 아니라 "실제로 쓴 항목이 있는가"(wrote)로 찍는다 —
    // 선행 type 이 skip(빈 이름/디코드 실패)되면 i>0 은 선행/이중 콤마(malformed JSON)를
    // 만든다. 콤마는 escape 성공 후에만 찍어 escape 실패로 인한 trailing 콤마도 막는다.
    var wrote = false;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const obj_fn: *const fn (?*anyopaque, ?*anyopaque, usize) callconv(.c) ?*anyopaque = @ptrCast(&objc.objc_msgSend);
        const type_obj = obj_fn(types, @ptrCast(objc.sel_registerName("objectAtIndex:")), i) orelse continue;
        var name_buf: [256]u8 = undefined;
        const name = nsStringToUtf8Buf(type_obj, &name_buf);
        if (name.len == 0) continue;
        var esc_buf: [512]u8 = undefined;
        const esc_n = util.escapeJsonStrFull(name, &esc_buf) orelse continue;
        if (wrote) w.writeByte(',') catch break;
        w.print("\"{s}\"", .{esc_buf[0..esc_n]}) catch break;
        wrote = true;
    }
    // 오버플로로 loop 를 빠져나와도 닫는 ']' 를 best-effort 로 써 valid JSON 을 보존.
    w.writeByte(']') catch {};
    return w.buffered();
}

/// 클립보드 HTML 읽기 (Electron `clipboard.readHTML`). 동일 cap (CLIPBOARD_MAX_TEXT).
pub fn clipboardReadHtml(buf: []u8) []const u8 {
    return clipboardReadType(buf, PASTEBOARD_TYPE_HTML);
}

/// 클립보드 HTML 쓰기 (Electron `clipboard.writeHTML`). 다른 type (text)도 함께 지움.
pub fn clipboardWriteHtml(html: []const u8) bool {
    return clipboardWriteType(html, PASTEBOARD_TYPE_HTML);
}

/// 클립보드 RTF 읽기 (Electron `clipboard.readRTF`). NSString 기반 — non-RTF면 빈 slice.
pub fn clipboardReadRtf(buf: []u8) []const u8 {
    return clipboardReadType(buf, PASTEBOARD_TYPE_RTF);
}

/// 클립보드 RTF 쓰기 (Electron `clipboard.writeRTF`). 다른 type 지움.
pub fn clipboardWriteRtf(rtf: []const u8) bool {
    return clipboardWriteType(rtf, PASTEBOARD_TYPE_RTF);
}

/// 클립보드 임의 UTI raw bytes 쓰기 (Electron `clipboard.writeBuffer(format, buffer)`).
/// type_str: UTI ("public.png", "public.html", 등). bytes는 raw — caller가 base64 decode 후 전달.
pub fn clipboardWriteBuffer(bytes: []const u8, type_str: []const u8) bool {
    if (!comptime is_macos) return false;
    if (bytes.len == 0) return false;
    const NSPasteboard = getClass("NSPasteboard") orelse return false;
    const pb = msgSend(NSPasteboard, "generalPasteboard") orelse return false;
    _ = msgSend(pb, "clearContents");

    const data = CFDataCreate(null, bytes.ptr, @intCast(bytes.len)) orelse return false;
    defer CFRelease(data);

    const ns_type = nsStringFromSlice(type_str) orelse return false;
    const setFn: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) u8 =
        @ptrCast(&objc.objc_msgSend);
    return setFn(pb, @ptrCast(objc.sel_registerName("setData:forType:")), data, ns_type) != 0;
}

/// 클립보드 임의 UTI raw bytes 읽기 (Electron `clipboard.readBuffer(format)`).
/// out_buf 부족 또는 type missing 시 빈 slice (truncation 회피).
pub fn clipboardReadBuffer(out_buf: []u8, type_str: []const u8) []const u8 {
    if (!comptime is_macos) return out_buf[0..0];
    const NSPasteboard = getClass("NSPasteboard") orelse return out_buf[0..0];
    const pb = msgSend(NSPasteboard, "generalPasteboard") orelse return out_buf[0..0];
    const ns_type = nsStringFromSlice(type_str) orelse return out_buf[0..0];
    const dataFn: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque =
        @ptrCast(&objc.objc_msgSend);
    const data = dataFn(pb, @ptrCast(objc.sel_registerName("dataForType:")), ns_type) orelse return out_buf[0..0];

    const ptr = CFDataGetBytePtr(data);
    const len: usize = @intCast(CFDataGetLength(data));
    if (len > out_buf.len) return out_buf[0..0];
    @memcpy(out_buf[0..len], ptr[0..len]);
    return out_buf[0..len];
}
