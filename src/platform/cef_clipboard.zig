//! Clipboard API — cef.zig 에서 분리(동작 무변경). NSPasteboard(macOS) /
//! GTK Clipboard(Linux) / Win32 Clipboard(Windows). main.zig 의 __core__ 디스패치는
//! cef.clipboard* 를 호출하며, cef.zig 가 이 파일의 pub fn 을 re-export 한다.
//!
//! macOS ObjC 브리징 헬퍼(objc/getClass/msgSend/nsString*)는 cef.zig 의 공유
//! 구현을 alias 로 재사용 — 옮긴 블록의 호출부는 한 글자도 바뀌지 않는다.
const std = @import("std");
const builtin = @import("builtin");
const util = @import("util");
const clipboard_cf_html = @import("clipboard_cf_html.zig");
const cef = @import("cef.zig");

const is_macos = builtin.os.tag == .macos;
const is_linux = builtin.os.tag == .linux;
const is_windows = builtin.os.tag == .windows;

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

const PASTEBOARD_TYPE_STRING: [*:0]const u8 = "public.utf8-plain-text";

/// 클립보드 텍스트 최대 길이 (null terminator 포함). main.zig IPC handler가 동일 cap을
/// 사용하므로 여기 한도를 넘는 입력은 caller 단에서 이미 잘려 있음.
const CLIPBOARD_MAX_TEXT: usize = 16384;

const linux_clip = if (is_linux) struct {
    const GDK_SELECTION_CLIPBOARD: usize = 69;
    const TARGET_HTML: [*:0]const u8 = "text/html";
    const GtkTargetEntry = extern struct {
        target: [*:0]const u8,
        flags: u32,
        info: u32,
    };

    extern "c" fn gtk_clipboard_get(selection: ?*anyopaque) callconv(.c) ?*anyopaque;
    extern "c" fn gtk_clipboard_set_text(clipboard: ?*anyopaque, text: [*]const u8, len: c_int) callconv(.c) void;
    extern "c" fn gtk_clipboard_set_with_data(clipboard: ?*anyopaque, targets: [*]const GtkTargetEntry, n_targets: u32, get_func: *const fn (?*anyopaque, ?*anyopaque, u32, ?*anyopaque) callconv(.c) void, clear_func: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void, user_data: ?*anyopaque) callconv(.c) c_int;
    extern "c" fn gtk_clipboard_wait_for_text(clipboard: ?*anyopaque) callconv(.c) ?[*:0]u8;
    extern "c" fn gtk_clipboard_wait_for_contents(clipboard: ?*anyopaque, target: ?*anyopaque) callconv(.c) ?*anyopaque;
    extern "c" fn gtk_clipboard_clear(clipboard: ?*anyopaque) callconv(.c) void;
    extern "c" fn gtk_clipboard_store(clipboard: ?*anyopaque) callconv(.c) void;
    extern "c" fn gtk_clipboard_wait_is_text_available(clipboard: ?*anyopaque) callconv(.c) c_int;
    extern "c" fn gtk_selection_data_set(selection_data: ?*anyopaque, type_: ?*anyopaque, format: c_int, data: [*]const u8, length: c_int) callconv(.c) void;
    extern "c" fn gtk_selection_data_get_data(selection_data: ?*anyopaque) callconv(.c) ?[*]const u8;
    extern "c" fn gtk_selection_data_get_length(selection_data: ?*anyopaque) callconv(.c) c_int;
    extern "c" fn gtk_selection_data_free(selection_data: ?*anyopaque) callconv(.c) void;
    extern "c" fn gdk_atom_intern(atom_name: [*:0]const u8, only_if_exists: c_int) callconv(.c) ?*anyopaque;
    extern "c" fn g_free(mem: ?*anyopaque) callconv(.c) void;

    var html_storage: [CLIPBOARD_MAX_TEXT]u8 = undefined;
    var html_len: usize = 0;

    fn selectionAtom() ?*anyopaque {
        return @as(?*anyopaque, @ptrFromInt(GDK_SELECTION_CLIPBOARD));
    }

    fn clipboard() ?*anyopaque {
        return gtk_clipboard_get(selectionAtom());
    }

    fn isTextType(type_cstr: [*:0]const u8) bool {
        return std.mem.eql(u8, std.mem.span(type_cstr), "public.utf8-plain-text");
    }

    fn isHtmlType(type_cstr: [*:0]const u8) bool {
        const t = std.mem.span(type_cstr);
        return std.mem.eql(u8, t, "public.html") or std.mem.eql(u8, t, "text/html");
    }

    fn supportsType(type_cstr: [*:0]const u8) bool {
        return isTextType(type_cstr) or isHtmlType(type_cstr);
    }

    fn htmlAtom() ?*anyopaque {
        return gdk_atom_intern(TARGET_HTML, 0);
    }

    fn readText(buf: []u8) []const u8 {
        const cb = clipboard() orelse return buf[0..0];
        const raw = gtk_clipboard_wait_for_text(cb) orelse return buf[0..0];
        defer g_free(@ptrCast(raw));
        const text = std.mem.span(raw);
        const n = @min(text.len, buf.len);
        @memcpy(buf[0..n], text[0..n]);
        return buf[0..n];
    }

    fn writeText(text: []const u8) bool {
        if (text.len > std.math.maxInt(c_int)) return false;
        const cb = clipboard() orelse return false;
        gtk_clipboard_set_text(cb, text.ptr, @intCast(text.len));
        gtk_clipboard_store(cb);
        return true;
    }

    fn htmlGet(_: ?*anyopaque, selection_data: ?*anyopaque, _: u32, _: ?*anyopaque) callconv(.c) void {
        if (html_len == 0) return;
        const atom = htmlAtom() orelse return;
        gtk_selection_data_set(selection_data, atom, 8, html_storage[0..html_len].ptr, @intCast(html_len));
    }

    fn htmlClear(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
        html_len = 0;
    }

    fn writeHtml(html: []const u8) bool {
        if (html.len == 0 or html.len > html_storage.len or html.len > std.math.maxInt(c_int)) return false;
        const cb = clipboard() orelse return false;
        @memcpy(html_storage[0..html.len], html);
        html_len = html.len;
        const targets = [_]GtkTargetEntry{.{ .target = TARGET_HTML, .flags = 0, .info = 0 }};
        if (gtk_clipboard_set_with_data(cb, &targets, targets.len, &htmlGet, &htmlClear, null) == 0) {
            html_len = 0;
            return false;
        }
        gtk_clipboard_store(cb);
        return true;
    }

    fn readHtml(buf: []u8) []const u8 {
        const cb = clipboard() orelse return buf[0..0];
        const atom = htmlAtom() orelse return buf[0..0];
        const selection = gtk_clipboard_wait_for_contents(cb, atom) orelse return buf[0..0];
        defer gtk_selection_data_free(selection);
        const len = gtk_selection_data_get_length(selection);
        if (len <= 0) return buf[0..0];
        const data = gtk_selection_data_get_data(selection) orelse return buf[0..0];
        const n = @min(@as(usize, @intCast(len)), buf.len);
        @memcpy(buf[0..n], data[0..n]);
        return buf[0..n];
    }

    fn clear() void {
        const cb = clipboard() orelse return;
        gtk_clipboard_clear(cb);
        gtk_clipboard_store(cb);
        html_len = 0;
    }

    fn hasText() bool {
        const cb = clipboard() orelse return false;
        return gtk_clipboard_wait_is_text_available(cb) != 0;
    }

    fn hasHtml() bool {
        var tmp: [1]u8 = undefined;
        return readHtml(&tmp).len > 0;
    }
} else struct {};

// ============================================
// Win32 Clipboard FFI (Windows only)
// ============================================
const win_clip = if (builtin.os.tag == .windows) struct {
    const CF_UNICODETEXT: u32 = 13;
    const GMEM_MOVEABLE: u32 = 0x0002;
    const CF_HTML_NAME_W = std.unicode.utf8ToUtf16LeStringLiteral(clipboard_cf_html.format_name);

    extern "user32" fn OpenClipboard(hWndNewOwner: ?*anyopaque) callconv(.winapi) i32;
    extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;

    /// Win32 OpenClipboard 는 single-owner. 동시 호출 contention 시 false 반환.
    /// e2e stress (Promise.all 50회) 같은 케이스에서 짧은 backoff 로 최대 ~50ms 재시도.
    fn openClipboardRetry() bool {
        var attempt: u32 = 0;
        while (attempt < 10) : (attempt += 1) {
            if (OpenClipboard(null) != 0) return true;
            Sleep(5);
        }
        return false;
    }
    extern "user32" fn CloseClipboard() callconv(.winapi) i32;
    extern "user32" fn EmptyClipboard() callconv(.winapi) i32;
    extern "user32" fn SetClipboardData(uFormat: u32, hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;
    extern "user32" fn GetClipboardData(uFormat: u32) callconv(.winapi) ?*anyopaque;
    extern "user32" fn IsClipboardFormatAvailable(format: u32) callconv(.winapi) i32;
    extern "user32" fn RegisterClipboardFormatW(lpszFormat: [*:0]const u16) callconv(.winapi) u32;
    extern "kernel32" fn GlobalAlloc(uFlags: u32, dwBytes: usize) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GlobalFree(hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GlobalLock(hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GlobalUnlock(hMem: ?*anyopaque) callconv(.winapi) i32;
    extern "kernel32" fn GlobalSize(hMem: ?*anyopaque) callconv(.winapi) usize;

    fn isTextType(type_cstr: [*:0]const u8) bool {
        return std.mem.eql(u8, std.mem.span(type_cstr), "public.utf8-plain-text");
    }

    fn isHtmlType(type_cstr: [*:0]const u8) bool {
        const t = std.mem.span(type_cstr);
        return std.mem.eql(u8, t, "public.html") or std.mem.eql(u8, t, "text/html");
    }

    fn htmlFormat() u32 {
        return RegisterClipboardFormatW(CF_HTML_NAME_W.ptr);
    }

    /// UTI → Win32 CF format. 다른 UTI 는 0 반환 (caller skip).
    fn cfFormatForUti(type_cstr: [*:0]const u8) u32 {
        if (isTextType(type_cstr)) return CF_UNICODETEXT;
        if (isHtmlType(type_cstr)) return htmlFormat();
        return 0;
    }

    /// UTF-16LE clipboard 읽어 buf 에 UTF-8 로 복사. 빈 slice = missing/empty/too-large.
    fn readUnicodeText(buf: []u8) []const u8 {
        if (!openClipboardRetry()) return buf[0..0];
        defer _ = CloseClipboard();
        const handle = GetClipboardData(CF_UNICODETEXT) orelse return buf[0..0];
        const locked = GlobalLock(handle) orelse return buf[0..0];
        defer _ = GlobalUnlock(handle);
        // null-terminated UTF-16. 길이는 nul 까지.
        const wide_ptr: [*:0]const u16 = @ptrCast(@alignCast(locked));
        const wide_slice = std.mem.span(wide_ptr);
        const n = std.unicode.utf16LeToUtf8(buf, wide_slice) catch return buf[0..0];
        return buf[0..n];
    }

    /// UTF-8 을 UTF-16LE 로 변환 후 CF_UNICODETEXT 로 쓴다. true = 성공.
    fn writeUnicodeText(text: []const u8) bool {
        // utf-16 길이 계산 + null terminator
        const wide_len = std.unicode.calcUtf16LeLen(text) catch return false;
        const bytes = (wide_len + 1) * @sizeOf(u16);
        const hmem = GlobalAlloc(GMEM_MOVEABLE, bytes) orelse return false;
        const locked = GlobalLock(hmem) orelse {
            _ = GlobalFree(hmem);
            return false;
        };
        const wide_ptr: [*]u16 = @ptrCast(@alignCast(locked));
        const written = std.unicode.utf8ToUtf16Le(wide_ptr[0..wide_len], text) catch {
            _ = GlobalUnlock(hmem);
            _ = GlobalFree(hmem);
            return false;
        };
        wide_ptr[written] = 0; // null terminator
        _ = GlobalUnlock(hmem);

        if (!openClipboardRetry()) {
            _ = GlobalFree(hmem);
            return false;
        }
        defer _ = CloseClipboard();
        _ = EmptyClipboard();
        const set_ok = SetClipboardData(CF_UNICODETEXT, hmem);
        if (set_ok == null) {
            _ = GlobalFree(hmem);
            return false;
        }
        // 성공 시 ownership 은 system. GlobalFree 호출 안 함.
        return true;
    }

    fn readHtml(buf: []u8) []const u8 {
        const format = htmlFormat();
        if (format == 0) return buf[0..0];
        if (!openClipboardRetry()) return buf[0..0];
        defer _ = CloseClipboard();
        const handle = GetClipboardData(format) orelse return buf[0..0];
        const size = GlobalSize(handle);
        if (size == 0) return buf[0..0];
        const locked = GlobalLock(handle) orelse return buf[0..0];
        defer _ = GlobalUnlock(handle);
        const bytes: [*]const u8 = @ptrCast(locked);
        const fragment = clipboard_cf_html.readFragment(bytes[0..size]) orelse return buf[0..0];
        const n = @min(fragment.len, buf.len);
        @memcpy(buf[0..n], fragment[0..n]);
        return buf[0..n];
    }

    fn writeHtml(html: []const u8) bool {
        if (html.len == 0) return false;
        var doc_buf: [CLIPBOARD_MAX_TEXT + clipboard_cf_html.max_overhead]u8 = undefined;
        const doc = clipboard_cf_html.writeDocument(&doc_buf, html) orelse return false;
        const format = htmlFormat();
        if (format == 0) return false;
        const hmem = GlobalAlloc(GMEM_MOVEABLE, doc.len + 1) orelse return false;
        const locked = GlobalLock(hmem) orelse {
            _ = GlobalFree(hmem);
            return false;
        };
        const dst: [*]u8 = @ptrCast(locked);
        @memcpy(dst[0..doc.len], doc);
        dst[doc.len] = 0;
        _ = GlobalUnlock(hmem);

        if (!openClipboardRetry()) {
            _ = GlobalFree(hmem);
            return false;
        }
        defer _ = CloseClipboard();
        _ = EmptyClipboard();
        const set_ok = SetClipboardData(format, hmem);
        if (set_ok == null) {
            _ = GlobalFree(hmem);
            return false;
        }
        return true;
    }

    fn emptyClipboard() void {
        if (!openClipboardRetry()) return;
        defer _ = CloseClipboard();
        _ = EmptyClipboard();
    }

    fn hasFormat(type_cstr: [*:0]const u8) bool {
        const cf = cfFormatForUti(type_cstr);
        if (cf == 0) return false;
        return IsClipboardFormatAvailable(cf) != 0;
    }
} else struct {};

/// generalPasteboard에서 주어진 type의 string 추출 — 빈 slice면 missing/non-string.
fn clipboardReadType(buf: []u8, type_cstr: [*:0]const u8) []const u8 {
    if (comptime builtin.os.tag == .windows) {
        if (win_clip.isHtmlType(type_cstr)) return win_clip.readHtml(buf);
        if (!win_clip.isTextType(type_cstr)) return buf[0..0];
        return win_clip.readUnicodeText(buf);
    }
    if (comptime is_linux) {
        if (linux_clip.isHtmlType(type_cstr)) return linux_clip.readHtml(buf);
        if (!linux_clip.isTextType(type_cstr)) return buf[0..0];
        return linux_clip.readText(buf);
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
        if (win_clip.isHtmlType(type_cstr)) return win_clip.writeHtml(text);
        if (!win_clip.isTextType(type_cstr)) return false;
        return win_clip.writeUnicodeText(text);
    }
    if (comptime is_linux) {
        if (linux_clip.isHtmlType(type_cstr)) return linux_clip.writeHtml(text);
        if (!linux_clip.isTextType(type_cstr)) return false;
        return linux_clip.writeText(text);
    }
    if (!comptime is_macos) return false;
    const NSPasteboard = getClass("NSPasteboard") orelse return false;
    const pb = msgSend(NSPasteboard, "generalPasteboard") orelse return false;
    _ = msgSend(pb, "clearContents");

    const ns_text = nsStringFromClipboardText(text) orelse return false;
    const ns_type = nsStringFromCstr(type_cstr) orelse return false;
    const setFn: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) u8 =
        @ptrCast(&objc.objc_msgSend);
    return setFn(pb, @ptrCast(objc.sel_registerName("setString:forType:")), ns_text, ns_type) != 0;
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
        win_clip.emptyClipboard();
        return;
    }
    if (comptime is_linux) {
        linux_clip.clear();
        return;
    }
    if (!comptime is_macos) return;
    const NSPasteboard = getClass("NSPasteboard") orelse return;
    const pb = msgSend(NSPasteboard, "generalPasteboard") orelse return;
    _ = msgSend(pb, "clearContents");
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
    if (comptime builtin.os.tag == .windows) return win_clip.hasFormat(type_cstr);
    if (comptime is_linux) {
        if (linux_clip.isHtmlType(type_cstr)) return linux_clip.hasHtml();
        return linux_clip.isTextType(type_cstr) and linux_clip.hasText();
    }
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
    if (comptime is_linux) {
        var w: std.Io.Writer = .fixed(out_buf);
        w.writeByte('[') catch return w.buffered();
        var wrote = false;
        if (linux_clip.hasText()) {
            w.writeAll("\"public.utf8-plain-text\"") catch return w.buffered();
            wrote = true;
        }
        if (linux_clip.hasHtml()) {
            if (wrote) w.writeByte(',') catch return w.buffered();
            w.writeAll("\"public.html\"") catch return w.buffered();
        }
        w.writeByte(']') catch return w.buffered();
        return w.buffered();
    }
    if (comptime builtin.os.tag == .windows) {
        var w: std.Io.Writer = .fixed(out_buf);
        w.writeByte('[') catch return w.buffered();
        var wrote = false;
        if (win_clip.IsClipboardFormatAvailable(win_clip.CF_UNICODETEXT) != 0) {
            w.writeAll("\"public.utf8-plain-text\"") catch return w.buffered();
            wrote = true;
        }
        const html_format = win_clip.htmlFormat();
        if (html_format != 0 and win_clip.IsClipboardFormatAvailable(html_format) != 0) {
            if (wrote) w.writeByte(',') catch return w.buffered();
            w.writeAll("\"public.html\"") catch return w.buffered();
        }
        w.writeByte(']') catch return w.buffered();
        return w.buffered();
    }
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

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const obj_fn: *const fn (?*anyopaque, ?*anyopaque, usize) callconv(.c) ?*anyopaque = @ptrCast(&objc.objc_msgSend);
        const type_obj = obj_fn(types, @ptrCast(objc.sel_registerName("objectAtIndex:")), i) orelse continue;
        var name_buf: [256]u8 = undefined;
        const name = nsStringToUtf8Buf(type_obj, &name_buf);
        if (name.len == 0) continue;
        if (i > 0) w.writeByte(',') catch return w.buffered();
        var esc_buf: [512]u8 = undefined;
        const esc_n = util.escapeJsonStrFull(name, &esc_buf) orelse continue;
        w.print("\"{s}\"", .{esc_buf[0..esc_n]}) catch return w.buffered();
    }
    w.writeByte(']') catch return w.buffered();
    return w.buffered();
}

const PASTEBOARD_TYPE_HTML: [*:0]const u8 = "public.html";

/// 클립보드 HTML 읽기 (Electron `clipboard.readHTML`). 동일 cap (CLIPBOARD_MAX_TEXT).
pub fn clipboardReadHtml(buf: []u8) []const u8 {
    return clipboardReadType(buf, PASTEBOARD_TYPE_HTML);
}

/// 클립보드 HTML 쓰기 (Electron `clipboard.writeHTML`). 다른 type (text)도 함께 지움.
pub fn clipboardWriteHtml(html: []const u8) bool {
    return clipboardWriteType(html, PASTEBOARD_TYPE_HTML);
}

const PASTEBOARD_TYPE_RTF: [*:0]const u8 = "public.rtf";

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
