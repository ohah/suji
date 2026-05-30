//! Linux GTK Clipboard backend.

const std = @import("std");
const builtin = @import("builtin");
const clip_types = @import("cef_clipboard_types.zig");

const is_linux = builtin.os.tag == .linux;
const CLIPBOARD_MAX_TEXT = clip_types.CLIPBOARD_MAX_TEXT;

pub fn readType(buf: []u8, type_cstr: [*:0]const u8) []const u8 {
    if (comptime !is_linux) return buf[0..0];
    if (linux_clip.isHtmlType(type_cstr)) return linux_clip.readHtml(buf);
    if (!linux_clip.isTextType(type_cstr)) return buf[0..0];
    return linux_clip.readText(buf);
}

pub fn writeType(text: []const u8, type_cstr: [*:0]const u8) bool {
    if (comptime !is_linux) return false;
    if (linux_clip.isHtmlType(type_cstr)) return linux_clip.writeHtml(text);
    if (!linux_clip.isTextType(type_cstr)) return false;
    return linux_clip.writeText(text);
}

pub fn clear() void {
    if (comptime is_linux) linux_clip.clear();
}

pub fn has(type_cstr: [*:0]const u8) bool {
    if (comptime !is_linux) return false;
    if (linux_clip.isHtmlType(type_cstr)) return linux_clip.hasHtml();
    return linux_clip.isTextType(type_cstr) and linux_clip.hasText();
}

pub fn availableFormats(out_buf: []u8) []const u8 {
    if (comptime !is_linux) {
        const empty = "[]";
        const n = @min(empty.len, out_buf.len);
        @memcpy(out_buf[0..n], empty[0..n]);
        return out_buf[0..n];
    }
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
