//! Linux GTK open/save file dialog backend.

const std = @import("std");
const builtin = @import("builtin");
const runtime = @import("runtime");
const util = @import("util");
const dialog_types = @import("cef_dialog_types.zig");
const dialog_response = @import("cef_dialog_response.zig");

const is_linux = builtin.os.tag == .linux;

const MAX_DIALOG_PATHS = dialog_types.MAX_DIALOG_PATHS;
const FileFilter = dialog_types.FileFilter;
const OpenDialogOpts = dialog_types.OpenDialogOpts;
const SaveDialogOpts = dialog_types.SaveDialogOpts;
const writeCanceledResponse = dialog_response.writeCanceledResponse;
const writeSaveCanceledResponse = dialog_response.writeSaveCanceledResponse;
const writeSaveSuccessResponse = dialog_response.writeSaveSuccessResponse;

fn nullTerminateOrTruncate(src: []const u8, buf: []u8) ?[:0]const u8 {
    if (src.len >= buf.len) return null;
    @memcpy(buf[0..src.len], src);
    buf[src.len] = 0;
    return buf[0..src.len :0];
}

pub fn showOpen(opts: OpenDialogOpts, response_buf: []u8) []const u8 {
    if (!comptime is_linux) return writeCanceledResponse(response_buf, true);
    return file_dlg.showOpen(opts, response_buf);
}

pub fn showSave(opts: SaveDialogOpts, response_buf: []u8) []const u8 {
    if (!comptime is_linux) return writeSaveCanceledResponse(response_buf, true);
    return file_dlg.showSave(opts, response_buf);
}

const file_dlg = if (is_linux) struct {
    const GTK_RESPONSE_ACCEPT: c_int = -3;
    const GTK_FILE_CHOOSER_ACTION_OPEN: c_int = 0;
    const GTK_FILE_CHOOSER_ACTION_SAVE: c_int = 1;
    const GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER: c_int = 2;

    const GSList = extern struct {
        data: ?*anyopaque,
        next: ?*GSList,
    };

    extern "c" fn suji_gtk_init_check() callconv(.c) c_int;
    extern "c" fn suji_gtk_file_chooser_dialog_new(action: c_int, title: ?[*:0]const u8, accept_label: [*:0]const u8) callconv(.c) ?*anyopaque;
    extern "c" fn suji_gtk_dialog_auto_cancel(dialog: ?*anyopaque, delay_ms: u32) callconv(.c) void;

    extern "c" fn gtk_dialog_run(dialog: ?*anyopaque) callconv(.c) c_int;
    extern "c" fn gtk_widget_destroy(widget: ?*anyopaque) callconv(.c) void;
    extern "c" fn gtk_file_chooser_set_select_multiple(chooser: ?*anyopaque, select_multiple: c_int) callconv(.c) void;
    extern "c" fn gtk_file_chooser_set_show_hidden(chooser: ?*anyopaque, show_hidden: c_int) callconv(.c) void;
    extern "c" fn gtk_file_chooser_set_create_folders(chooser: ?*anyopaque, create_folders: c_int) callconv(.c) void;
    extern "c" fn gtk_file_chooser_set_do_overwrite_confirmation(chooser: ?*anyopaque, do_overwrite_confirmation: c_int) callconv(.c) void;
    extern "c" fn gtk_file_chooser_set_current_folder(chooser: ?*anyopaque, filename: [*:0]const u8) callconv(.c) c_int;
    extern "c" fn gtk_file_chooser_set_current_name(chooser: ?*anyopaque, name: [*:0]const u8) callconv(.c) void;
    extern "c" fn gtk_file_chooser_set_filename(chooser: ?*anyopaque, filename: [*:0]const u8) callconv(.c) c_int;
    extern "c" fn gtk_file_chooser_get_filename(chooser: ?*anyopaque) callconv(.c) ?[*:0]u8;
    extern "c" fn gtk_file_chooser_get_filenames(chooser: ?*anyopaque) callconv(.c) ?*GSList;
    extern "c" fn gtk_file_filter_new() callconv(.c) ?*anyopaque;
    extern "c" fn gtk_file_filter_set_name(filter: ?*anyopaque, name: [*:0]const u8) callconv(.c) void;
    extern "c" fn gtk_file_filter_add_pattern(filter: ?*anyopaque, pattern: [*:0]const u8) callconv(.c) void;
    extern "c" fn gtk_file_chooser_add_filter(chooser: ?*anyopaque, filter: ?*anyopaque) callconv(.c) void;
    extern "c" fn g_free(mem: ?*anyopaque) callconv(.c) void;
    extern "c" fn g_slist_free(list: ?*GSList) callconv(.c) void;

    fn gtkAvailable() bool {
        return suji_gtk_init_check() != 0;
    }

    fn boolInt(v: bool) c_int {
        return if (v) 1 else 0;
    }

    fn maybeAutoCancel(dialog: ?*anyopaque) void {
        const value = runtime.env("SUJI_E2E_LINUX_DIALOG_AUTO_CLOSE") orelse return;
        if (std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "true")) {
            suji_gtk_dialog_auto_cancel(dialog, 50);
        }
    }

    fn applyDefaultPathOpen(dialog: ?*anyopaque, default_path: []const u8) void {
        if (default_path.len == 0) return;
        var path_buf: [4096]u8 = undefined;
        const path_z = nullTerminateOrTruncate(default_path, &path_buf) orelse return;
        if (default_path[default_path.len - 1] == '/') {
            _ = gtk_file_chooser_set_current_folder(dialog, path_z.ptr);
        } else {
            _ = gtk_file_chooser_set_filename(dialog, path_z.ptr);
        }
    }

    fn applyDefaultPathSave(dialog: ?*anyopaque, default_path: []const u8) void {
        if (default_path.len == 0) return;
        if (std.mem.lastIndexOfScalar(u8, default_path, '/')) |slash_idx| {
            const dir = default_path[0..slash_idx];
            const name = default_path[slash_idx + 1 ..];
            if (dir.len > 0) {
                var dir_buf: [4096]u8 = undefined;
                if (nullTerminateOrTruncate(dir, &dir_buf)) |dir_z| _ = gtk_file_chooser_set_current_folder(dialog, dir_z.ptr);
            }
            if (name.len > 0) {
                var name_buf: [512]u8 = undefined;
                if (nullTerminateOrTruncate(name, &name_buf)) |name_z| gtk_file_chooser_set_current_name(dialog, name_z.ptr);
            }
        } else {
            var name_buf: [512]u8 = undefined;
            if (nullTerminateOrTruncate(default_path, &name_buf)) |name_z| gtk_file_chooser_set_current_name(dialog, name_z.ptr);
        }
    }

    fn applyFilters(dialog: ?*anyopaque, filters: []const FileFilter) void {
        for (filters) |filter| {
            const gtk_filter = gtk_file_filter_new() orelse continue;
            var name_buf: [256]u8 = undefined;
            const name = if (filter.name.len > 0) filter.name else "Files";
            if (nullTerminateOrTruncate(name, &name_buf)) |name_z| gtk_file_filter_set_name(gtk_filter, name_z.ptr);

            var added = false;
            for (filter.extensions) |ext_raw| {
                if (ext_raw.len == 0) continue;
                var pattern_buf: [256]u8 = undefined;
                const pattern = if (std.mem.eql(u8, ext_raw, "*"))
                    "*"
                else if (std.mem.startsWith(u8, ext_raw, "*."))
                    ext_raw
                else if (std.mem.startsWith(u8, ext_raw, "."))
                    std.fmt.bufPrint(&pattern_buf, "*{s}", .{ext_raw}) catch continue
                else
                    std.fmt.bufPrint(&pattern_buf, "*.{s}", .{ext_raw}) catch continue;
                var pattern_z_buf: [256]u8 = undefined;
                if (nullTerminateOrTruncate(pattern, &pattern_z_buf)) |pattern_z| {
                    gtk_file_filter_add_pattern(gtk_filter, pattern_z.ptr);
                    added = true;
                }
            }
            if (added) gtk_file_chooser_add_filter(dialog, gtk_filter);
        }
    }

    fn appendEscapedPath(w: *std.Io.Writer, first: *bool, path: []const u8) !void {
        var esc_buf: [8192]u8 = undefined;
        const esc_n = util.escapeJsonStrFull(path, &esc_buf) orelse return;
        if (!first.*) try w.writeByte(',');
        first.* = false;
        try w.print("\"{s}\"", .{esc_buf[0..esc_n]});
    }

    fn writeOpenFilenameResponse(response_buf: []u8, filename: ?[*:0]u8) []const u8 {
        const raw = filename orelse return writeCanceledResponse(response_buf, true);
        defer g_free(@ptrCast(raw));
        var w: std.Io.Writer = .fixed(response_buf);
        w.writeAll("{\"canceled\":false,\"filePaths\":[") catch return writeCanceledResponse(response_buf, true);
        var first = true;
        appendEscapedPath(&w, &first, std.mem.span(raw)) catch return writeCanceledResponse(response_buf, true);
        w.writeAll("]}") catch return writeCanceledResponse(response_buf, true);
        return w.buffered();
    }

    fn writeOpenFilenamesResponse(response_buf: []u8, list: ?*GSList) []const u8 {
        const head = list orelse return writeCanceledResponse(response_buf, true);
        defer g_slist_free(head);
        var w: std.Io.Writer = .fixed(response_buf);
        w.writeAll("{\"canceled\":false,\"filePaths\":[") catch return writeCanceledResponse(response_buf, true);
        var first = true;
        var count: usize = 0;
        var node: ?*GSList = head;
        while (node) |n| : (node = n.next) {
            defer if (n.data) |data| g_free(data);
            if (count >= MAX_DIALOG_PATHS) break;
            const cstr: [*:0]u8 = @ptrCast(n.data orelse continue);
            appendEscapedPath(&w, &first, std.mem.span(cstr)) catch return writeCanceledResponse(response_buf, true);
            count += 1;
        }
        w.writeAll("]}") catch return writeCanceledResponse(response_buf, true);
        return w.buffered();
    }

    fn showOpen(opts: OpenDialogOpts, response_buf: []u8) []const u8 {
        if (!gtkAvailable()) return writeCanceledResponse(response_buf, true);
        const action: c_int = if (opts.can_choose_directories and !opts.can_choose_files)
            GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER
        else
            GTK_FILE_CHOOSER_ACTION_OPEN;
        var title_buf: [512]u8 = undefined;
        const title_z: ?[:0]const u8 = if (opts.title.len > 0) nullTerminateOrTruncate(opts.title, &title_buf) else null;
        var accept_buf: [128]u8 = undefined;
        const accept_z: [:0]const u8 = if (opts.button_label.len > 0)
            (nullTerminateOrTruncate(opts.button_label, &accept_buf) orelse "_Open")
        else
            "_Open";
        const dialog = suji_gtk_file_chooser_dialog_new(action, if (title_z) |z| z.ptr else null, accept_z.ptr) orelse
            return writeCanceledResponse(response_buf, true);
        defer gtk_widget_destroy(dialog);

        gtk_file_chooser_set_select_multiple(dialog, boolInt(opts.allows_multiple_selection));
        gtk_file_chooser_set_show_hidden(dialog, boolInt(opts.shows_hidden_files));
        gtk_file_chooser_set_create_folders(dialog, boolInt(opts.can_create_directories));
        applyDefaultPathOpen(dialog, opts.default_path);
        applyFilters(dialog, opts.filters);

        maybeAutoCancel(dialog);
        if (gtk_dialog_run(dialog) != GTK_RESPONSE_ACCEPT) return writeCanceledResponse(response_buf, true);
        if (opts.allows_multiple_selection) return writeOpenFilenamesResponse(response_buf, gtk_file_chooser_get_filenames(dialog));
        return writeOpenFilenameResponse(response_buf, gtk_file_chooser_get_filename(dialog));
    }

    fn showSave(opts: SaveDialogOpts, response_buf: []u8) []const u8 {
        if (!gtkAvailable()) return writeSaveCanceledResponse(response_buf, true);
        var title_buf: [512]u8 = undefined;
        const title_z: ?[:0]const u8 = if (opts.title.len > 0) nullTerminateOrTruncate(opts.title, &title_buf) else null;
        var accept_buf: [128]u8 = undefined;
        const accept_z: [:0]const u8 = if (opts.button_label.len > 0)
            (nullTerminateOrTruncate(opts.button_label, &accept_buf) orelse "_Save")
        else
            "_Save";
        const dialog = suji_gtk_file_chooser_dialog_new(GTK_FILE_CHOOSER_ACTION_SAVE, if (title_z) |z| z.ptr else null, accept_z.ptr) orelse
            return writeSaveCanceledResponse(response_buf, true);
        defer gtk_widget_destroy(dialog);

        gtk_file_chooser_set_show_hidden(dialog, boolInt(opts.shows_hidden_files));
        gtk_file_chooser_set_create_folders(dialog, boolInt(opts.can_create_directories));
        gtk_file_chooser_set_do_overwrite_confirmation(dialog, boolInt(opts.show_overwrite_confirmation));
        applyDefaultPathSave(dialog, opts.default_path);
        applyFilters(dialog, opts.filters);

        maybeAutoCancel(dialog);
        if (gtk_dialog_run(dialog) != GTK_RESPONSE_ACCEPT) return writeSaveCanceledResponse(response_buf, true);
        const raw = gtk_file_chooser_get_filename(dialog) orelse return writeSaveCanceledResponse(response_buf, true);
        defer g_free(@ptrCast(raw));
        return writeSaveSuccessResponse(response_buf, std.mem.span(raw));
    }
} else struct {};
