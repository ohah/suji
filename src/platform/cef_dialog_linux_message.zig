//! Linux GTK message dialog backend.

const std = @import("std");
const builtin = @import("builtin");
const runtime = @import("runtime");
const dialog_types = @import("cef_dialog_types.zig");

const is_linux = builtin.os.tag == .linux;

const MAX_DIALOG_BUTTONS = dialog_types.MAX_DIALOG_BUTTONS;
const MessageBoxStyle = dialog_types.MessageBoxStyle;
const MessageBoxOpts = dialog_types.MessageBoxOpts;
const MessageBoxResult = dialog_types.MessageBoxResult;

fn nullTerminateOrTruncate(src: []const u8, buf: []u8) ?[:0]const u8 {
    if (src.len >= buf.len) return null;
    @memcpy(buf[0..src.len], src);
    buf[src.len] = 0;
    return buf[0..src.len :0];
}

pub fn showMessageBox(opts: MessageBoxOpts) MessageBoxResult {
    if (!comptime is_linux) return .{};
    return message_dlg.showMessageBox(opts);
}

pub fn showErrorBox(title: []const u8, content: []const u8) void {
    if (!comptime is_linux) return;
    message_dlg.showErrorBox(title, content);
}

const message_dlg = if (is_linux) struct {
    const GTK_DIALOG_RESPONSE_BASE: c_int = 1000;
    const GTK_RESPONSE_CANCEL: c_int = -6;
    const GTK_RESPONSE_DELETE_EVENT: c_int = -4;

    extern "c" fn suji_gtk_init_check() callconv(.c) c_int;
    extern "c" fn suji_gtk_message_dialog_new(message_type: c_int, message: [*:0]const u8) callconv(.c) ?*anyopaque;
    extern "c" fn suji_gtk_message_dialog_set_detail(dialog: ?*anyopaque, detail: [*:0]const u8) callconv(.c) void;
    extern "c" fn suji_gtk_dialog_auto_cancel(dialog: ?*anyopaque, delay_ms: u32) callconv(.c) void;

    extern "c" fn gtk_window_set_title(window: ?*anyopaque, title: [*:0]const u8) callconv(.c) void;
    extern "c" fn gtk_dialog_add_button(dialog: ?*anyopaque, button_text: [*:0]const u8, response_id: c_int) callconv(.c) ?*anyopaque;
    extern "c" fn gtk_dialog_set_default_response(dialog: ?*anyopaque, response_id: c_int) callconv(.c) void;
    extern "c" fn gtk_dialog_run(dialog: ?*anyopaque) callconv(.c) c_int;
    extern "c" fn gtk_widget_destroy(widget: ?*anyopaque) callconv(.c) void;
    extern "c" fn gtk_message_dialog_get_message_area(message_dialog: ?*anyopaque) callconv(.c) ?*anyopaque;
    extern "c" fn gtk_check_button_new_with_label(label: [*:0]const u8) callconv(.c) ?*anyopaque;
    extern "c" fn gtk_toggle_button_set_active(toggle_button: ?*anyopaque, is_active: c_int) callconv(.c) void;
    extern "c" fn gtk_toggle_button_get_active(toggle_button: ?*anyopaque) callconv(.c) c_int;
    extern "c" fn gtk_container_add(container: ?*anyopaque, widget: ?*anyopaque) callconv(.c) void;
    extern "c" fn gtk_widget_show(widget: ?*anyopaque) callconv(.c) void;

    fn gtkAvailable() bool {
        return suji_gtk_init_check() != 0;
    }

    fn boolInt(v: bool) c_int {
        return if (v) 1 else 0;
    }

    fn responseForIndex(i: usize) c_int {
        return GTK_DIALOG_RESPONSE_BASE + @as(c_int, @intCast(i));
    }

    fn indexForResponse(response: c_int, button_count: usize, cancel_id: ?usize) usize {
        if (response >= GTK_DIALOG_RESPONSE_BASE) {
            const idx: usize = @intCast(response - GTK_DIALOG_RESPONSE_BASE);
            if (idx < button_count) return idx;
        }
        if (response == GTK_RESPONSE_CANCEL or response == GTK_RESPONSE_DELETE_EVENT) {
            if (cancel_id) |idx| if (idx < button_count) return idx;
        }
        return 0;
    }

    fn maybeAutoCancel(dialog: ?*anyopaque) void {
        const value = runtime.env("SUJI_E2E_LINUX_DIALOG_AUTO_CLOSE") orelse return;
        if (std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "true")) {
            suji_gtk_dialog_auto_cancel(dialog, 50);
        }
    }

    fn messageType(style: MessageBoxStyle) c_int {
        return switch (style) {
            .info => 0,
            .warning => 1,
            .question => 2,
            .err => 3,
            .none => 4,
        };
    }

    fn showMessageBox(opts: MessageBoxOpts) MessageBoxResult {
        if (!gtkAvailable()) return .{};
        var message_buf: [4096]u8 = undefined;
        const message_z: [:0]const u8 = nullTerminateOrTruncate(opts.message, &message_buf) orelse "";
        const dialog = suji_gtk_message_dialog_new(messageType(opts.style), message_z.ptr) orelse return .{};
        defer gtk_widget_destroy(dialog);

        if (opts.title.len > 0) {
            var title_buf: [512]u8 = undefined;
            if (nullTerminateOrTruncate(opts.title, &title_buf)) |title_z| gtk_window_set_title(dialog, title_z.ptr);
        }
        if (opts.detail.len > 0) {
            var detail_buf: [4096]u8 = undefined;
            if (nullTerminateOrTruncate(opts.detail, &detail_buf)) |detail_z| suji_gtk_message_dialog_set_detail(dialog, detail_z.ptr);
        }

        var button_storage: [MAX_DIALOG_BUTTONS][256]u8 = undefined;
        const button_titles: []const []const u8 = if (opts.buttons.len > 0) opts.buttons else &.{"OK"};
        const button_count = @min(button_titles.len, MAX_DIALOG_BUTTONS);
        for (button_titles[0..button_count], 0..) |title, i| {
            const button_z = nullTerminateOrTruncate(title, &button_storage[i]) orelse continue;
            _ = gtk_dialog_add_button(dialog, button_z.ptr, responseForIndex(i));
        }
        const default_idx = opts.default_id orelse 0;
        if (default_idx < button_count) gtk_dialog_set_default_response(dialog, responseForIndex(default_idx));

        var checkbox: ?*anyopaque = null;
        if (opts.checkbox_label.len > 0) {
            var label_buf: [512]u8 = undefined;
            if (nullTerminateOrTruncate(opts.checkbox_label, &label_buf)) |label_z| {
                checkbox = gtk_check_button_new_with_label(label_z.ptr);
                if (checkbox) |cb| {
                    gtk_toggle_button_set_active(cb, boolInt(opts.checkbox_checked));
                    if (gtk_message_dialog_get_message_area(dialog)) |area| {
                        gtk_container_add(area, cb);
                        gtk_widget_show(cb);
                    }
                }
            }
        }

        maybeAutoCancel(dialog);
        const response = gtk_dialog_run(dialog);
        const checkbox_checked = if (checkbox) |cb| gtk_toggle_button_get_active(cb) != 0 else opts.checkbox_checked;
        return .{
            .response = indexForResponse(response, button_count, opts.cancel_id),
            .checkbox_checked = checkbox_checked,
        };
    }

    fn showErrorBox(title: []const u8, content: []const u8) void {
        _ = @This().showMessageBox(.{
            .style = .err,
            .title = title,
            .message = content,
            .buttons = &.{"OK"},
        });
    }
} else struct {};
