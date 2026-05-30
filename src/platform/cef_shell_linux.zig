//! Linux backend for Electron-compatible shell APIs.

const std = @import("std");
const builtin = @import("builtin");

/// URL 또는 path 길이 한도 (null terminator 포함).
const SHELL_MAX_PATH: usize = 4096;

const impl = if (builtin.os.tag == .linux) struct {
    extern "c" fn g_file_new_for_path(path: [*:0]const u8) callconv(.c) ?*anyopaque;
    extern "c" fn g_file_query_exists(file: ?*anyopaque, cancellable: ?*anyopaque) callconv(.c) c_int;
    extern "c" fn g_file_get_uri(file: ?*anyopaque) callconv(.c) ?[*:0]u8;
    extern "c" fn g_file_trash(file: ?*anyopaque, cancellable: ?*anyopaque, err_out: ?*?*anyopaque) callconv(.c) c_int;
    extern "c" fn g_app_info_launch_default_for_uri(uri: [*:0]const u8, context: ?*anyopaque, err_out: ?*?*anyopaque) callconv(.c) c_int;
    extern "c" fn g_bus_get_sync(bus_type: c_int, cancellable: ?*anyopaque, err_out: ?*?*anyopaque) callconv(.c) ?*anyopaque;
    extern "c" fn g_dbus_connection_call_sync(connection: ?*anyopaque, bus_name: [*:0]const u8, object_path: [*:0]const u8, interface_name: [*:0]const u8, method_name: [*:0]const u8, parameters: ?*anyopaque, reply_type: ?*anyopaque, flags: c_int, timeout_msec: c_int, cancellable: ?*anyopaque, err_out: ?*?*anyopaque) callconv(.c) ?*anyopaque;
    extern "c" fn g_variant_new_strv(strv: [*]const ?[*:0]const u8, length: isize) callconv(.c) ?*anyopaque;
    extern "c" fn g_variant_new_string(string: [*:0]const u8) callconv(.c) ?*anyopaque;
    extern "c" fn g_variant_new_tuple(children: [*]const ?*anyopaque, n_children: usize) callconv(.c) ?*anyopaque;
    extern "c" fn g_variant_unref(value: ?*anyopaque) callconv(.c) void;
    extern "c" fn gdk_display_get_default() callconv(.c) ?*anyopaque;
    extern "c" fn gdk_display_beep(display: ?*anyopaque) callconv(.c) void;
    extern "c" fn g_object_unref(object: ?*anyopaque) callconv(.c) void;
    extern "c" fn g_error_free(err: ?*anyopaque) callconv(.c) void;
    extern "c" fn g_free(mem: ?*anyopaque) callconv(.c) void;

    const G_BUS_TYPE_SESSION: c_int = 2;
    const G_DBUS_CALL_FLAGS_NONE: c_int = 0;

    fn toZText(text: []const u8, buf: *[SHELL_MAX_PATH]u8) ?[*:0]const u8 {
        if (text.len == 0 or text.len + 1 > buf.len) return null;
        if (std.mem.indexOfScalar(u8, text, 0) != null) return null;
        @memcpy(buf[0..text.len], text);
        buf[text.len] = 0;
        return @ptrCast(buf);
    }

    fn urlIsValid(url: []const u8) bool {
        if (url.len == 0 or url.len + 1 > SHELL_MAX_PATH) return false;
        if (std.mem.indexOfScalar(u8, url, 0) != null) return false;
        for (url) |b| if (b < 0x20 or b == 0x7f) return false;

        const colon = std.mem.indexOfScalar(u8, url, ':') orelse return false;
        if (colon == 0) return false;
        for (url[0..colon]) |b| {
            const is_alpha = (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z');
            const is_digit = b >= '0' and b <= '9';
            const is_mark = b == '+' or b == '-' or b == '.';
            if (!(is_alpha or is_digit or is_mark)) return false;
        }
        const first = url[0];
        return (first >= 'a' and first <= 'z') or (first >= 'A' and first <= 'Z');
    }

    /// GIO default-app launch for URI schemes. Returns false when no handler is
    /// registered, URI validation fails, or the desktop environment rejects it.
    pub fn openExternal(url: []const u8) bool {
        if (!urlIsValid(url)) return false;
        var uri_buf: [SHELL_MAX_PATH]u8 = undefined;
        const uri_z = toZText(url, &uri_buf) orelse return false;
        return launchUri(uri_z);
    }

    fn launchUri(uri_z: [*:0]const u8) bool {
        var gerr: ?*anyopaque = null;
        const ok = g_app_info_launch_default_for_uri(uri_z, null, &gerr) != 0;
        if (gerr) |err| g_error_free(err);
        return ok;
    }

    fn fileUriIfExists(path: []const u8) ?[*:0]u8 {
        var path_buf: [SHELL_MAX_PATH]u8 = undefined;
        const path_z = toZText(path, &path_buf) orelse return null;
        const file = g_file_new_for_path(path_z) orelse return null;
        defer g_object_unref(file);
        if (g_file_query_exists(file, null) == 0) return null;
        return g_file_get_uri(file);
    }

    /// Convert an existing path to a file:// URI with GFile and launch the
    /// registered default application for that MIME type.
    pub fn openPath(path: []const u8) bool {
        const uri = fileUriIfExists(path) orelse return false;
        defer g_free(@ptrCast(uri));
        return launchUri(uri);
    }

    /// Ask the active file manager to reveal/select an existing item via the
    /// freedesktop FileManager1 D-Bus interface.
    pub fn showItemInFolder(path: []const u8) bool {
        const uri = fileUriIfExists(path) orelse return false;
        defer g_free(@ptrCast(uri));

        var bus_err: ?*anyopaque = null;
        const connection = g_bus_get_sync(G_BUS_TYPE_SESSION, null, &bus_err) orelse {
            if (bus_err) |err| g_error_free(err);
            return false;
        };
        defer g_object_unref(connection);

        const uri_const: [*:0]const u8 = @ptrCast(uri);
        const uris = [_:null]?[*:0]const u8{uri_const};
        const uri_array = g_variant_new_strv(&uris, 1) orelse return false;
        const startup_id = g_variant_new_string("") orelse {
            g_variant_unref(uri_array);
            return false;
        };
        const children = [_]?*anyopaque{ uri_array, startup_id };
        const parameters = g_variant_new_tuple(&children, children.len) orelse {
            g_variant_unref(uri_array);
            g_variant_unref(startup_id);
            return false;
        };

        var call_err: ?*anyopaque = null;
        const reply = g_dbus_connection_call_sync(
            connection,
            "org.freedesktop.FileManager1",
            "/org/freedesktop/FileManager1",
            "org.freedesktop.FileManager1",
            "ShowItems",
            parameters,
            null,
            G_DBUS_CALL_FLAGS_NONE,
            3000,
            null,
            &call_err,
        ) orelse {
            if (call_err) |err| g_error_free(err);
            return false;
        };
        g_variant_unref(reply);
        return true;
    }

    pub fn beep() void {
        const display = gdk_display_get_default() orelse return;
        gdk_display_beep(display);
    }

    /// GIO `g_file_trash` follows the freedesktop trash spec and moves the item
    /// into the user's Trash when supported by the filesystem.
    pub fn trashItem(path: []const u8) bool {
        var path_buf: [SHELL_MAX_PATH]u8 = undefined;
        const path_z = toZText(path, &path_buf) orelse return false;
        const file = g_file_new_for_path(path_z) orelse return false;
        defer g_object_unref(file);

        var gerr: ?*anyopaque = null;
        const ok = g_file_trash(file, null, &gerr) != 0;
        if (gerr) |err| g_error_free(err);
        return ok;
    }
} else struct {
    pub fn openExternal(_: []const u8) bool {
        return false;
    }
    pub fn showItemInFolder(_: []const u8) bool {
        return false;
    }
    pub fn beep() void {}
    pub fn openPath(_: []const u8) bool {
        return false;
    }
    pub fn trashItem(_: []const u8) bool {
        return false;
    }
};

pub const openExternal = impl.openExternal;
pub const showItemInFolder = impl.showItemInFolder;
pub const beep = impl.beep;
pub const openPath = impl.openPath;
pub const trashItem = impl.trashItem;
