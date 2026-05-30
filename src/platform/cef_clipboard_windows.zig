//! Windows Win32 Clipboard backend.

const std = @import("std");
const builtin = @import("builtin");
const clipboard_cf_html = @import("clipboard_cf_html.zig");
const clip_types = @import("cef_clipboard_types.zig");

const is_windows = builtin.os.tag == .windows;
const CLIPBOARD_MAX_TEXT = clip_types.CLIPBOARD_MAX_TEXT;

pub fn readType(buf: []u8, type_cstr: [*:0]const u8) []const u8 {
    if (comptime !is_windows) return buf[0..0];
    if (win_clip.isHtmlType(type_cstr)) return win_clip.readHtml(buf);
    if (!win_clip.isTextType(type_cstr)) return buf[0..0];
    return win_clip.readUnicodeText(buf);
}

pub fn writeType(text: []const u8, type_cstr: [*:0]const u8) bool {
    if (comptime !is_windows) return false;
    if (win_clip.isHtmlType(type_cstr)) return win_clip.writeHtml(text);
    if (!win_clip.isTextType(type_cstr)) return false;
    return win_clip.writeUnicodeText(text);
}

pub fn clear() void {
    if (comptime is_windows) win_clip.emptyClipboard();
}

pub fn has(type_cstr: [*:0]const u8) bool {
    if (comptime !is_windows) return false;
    return win_clip.hasFormat(type_cstr);
}

pub fn availableFormats(out_buf: []u8) []const u8 {
    if (comptime !is_windows) {
        const empty = "[]";
        const n = @min(empty.len, out_buf.len);
        @memcpy(out_buf[0..n], empty[0..n]);
        return out_buf[0..n];
    }
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

const win_clip = if (is_windows) struct {
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
