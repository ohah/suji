//! Linux freedesktop D-Bus notification backend.

const std = @import("std");
const builtin = @import("builtin");
const cef = @import("cef.zig");

const is_linux = builtin.os.tag == .linux;
const writeCStr = cef.writeCStr;

pub fn isSupported() bool {
    if (comptime !is_linux) return false;
    return linux_notify.isSupported();
}

pub fn requestPermission() bool {
    if (comptime !is_linux) return false;
    return linux_notify.requestPermission();
}

pub fn show(id: []const u8, title: []const u8, body: []const u8, silent: bool) bool {
    if (comptime !is_linux) return false;
    return linux_notify.show(id, title, body, silent);
}

pub fn close(id: []const u8) bool {
    if (comptime !is_linux) return false;
    return linux_notify.close(id);
}

const linux_notify = if (is_linux) struct {
    extern "c" fn g_bus_get_sync(bus_type: c_int, cancellable: ?*anyopaque, err_out: ?*?*anyopaque) callconv(.c) ?*anyopaque;
    extern "c" fn g_dbus_connection_call_sync(connection: ?*anyopaque, bus_name: [*:0]const u8, object_path: [*:0]const u8, interface_name: [*:0]const u8, method_name: [*:0]const u8, parameters: ?*anyopaque, reply_type: ?*anyopaque, flags: c_int, timeout_msec: c_int, cancellable: ?*anyopaque, err_out: ?*?*anyopaque) callconv(.c) ?*anyopaque;
    extern "c" fn g_variant_new_string(string: [*:0]const u8) callconv(.c) ?*anyopaque;
    extern "c" fn g_variant_new_uint32(value: u32) callconv(.c) ?*anyopaque;
    extern "c" fn g_variant_new_int32(value: i32) callconv(.c) ?*anyopaque;
    extern "c" fn g_variant_new_boolean(value: c_int) callconv(.c) ?*anyopaque;
    extern "c" fn g_variant_new_variant(value: ?*anyopaque) callconv(.c) ?*anyopaque;
    extern "c" fn g_variant_new_dict_entry(key: ?*anyopaque, value: ?*anyopaque) callconv(.c) ?*anyopaque;
    extern "c" fn g_variant_new_strv(strv: [*]const ?[*:0]const u8, length: isize) callconv(.c) ?*anyopaque;
    extern "c" fn g_variant_new_array(child_type: ?*anyopaque, children: ?[*]const ?*anyopaque, n_children: usize) callconv(.c) ?*anyopaque;
    extern "c" fn g_variant_new_tuple(children: [*]const ?*anyopaque, n_children: usize) callconv(.c) ?*anyopaque;
    extern "c" fn g_variant_get_child_value(value: ?*anyopaque, index_: usize) callconv(.c) ?*anyopaque;
    extern "c" fn g_variant_get_uint32(value: ?*anyopaque) callconv(.c) u32;
    extern "c" fn g_variant_unref(value: ?*anyopaque) callconv(.c) void;
    extern "c" fn g_variant_type_new(type_string: [*:0]const u8) callconv(.c) ?*anyopaque;
    extern "c" fn g_variant_type_free(type_: ?*anyopaque) callconv(.c) void;
    extern "c" fn g_object_unref(object: ?*anyopaque) callconv(.c) void;
    extern "c" fn g_error_free(err: ?*anyopaque) callconv(.c) void;

    const G_BUS_TYPE_SESSION: c_int = 2;
    const G_DBUS_CALL_FLAGS_NONE: c_int = 0;
    const NOTIFY_TIMEOUT_MS: c_int = 3000;

    const Entry = struct {
        used: bool = false,
        id_len: usize = 0,
        id: [64]u8 = [_]u8{0} ** 64,
        dbus_id: u32 = 0,
    };
    var entries: [64]Entry = [_]Entry{.{}} ** 64;

    fn call(method: [*:0]const u8, parameters: ?*anyopaque, timeout_msec: c_int) ?*anyopaque {
        var bus_err: ?*anyopaque = null;
        const connection = g_bus_get_sync(G_BUS_TYPE_SESSION, null, &bus_err) orelse {
            if (bus_err) |err| g_error_free(err);
            return null;
        };
        defer g_object_unref(connection);

        var call_err: ?*anyopaque = null;
        return g_dbus_connection_call_sync(
            connection,
            "org.freedesktop.Notifications",
            "/org/freedesktop/Notifications",
            "org.freedesktop.Notifications",
            method,
            parameters,
            null,
            G_DBUS_CALL_FLAGS_NONE,
            timeout_msec,
            null,
            &call_err,
        ) orelse {
            if (call_err) |err| g_error_free(err);
            return null;
        };
    }

    fn isSupported() bool {
        const reply = call("GetServerInformation", null, 1000) orelse return false;
        g_variant_unref(reply);
        return true;
    }

    fn requestPermission() bool {
        // The freedesktop notification spec has no permission prompt; service
        // reachability is the closest synchronous support signal.
        return @This().isSupported();
    }

    fn findEntry(id: []const u8) ?*Entry {
        for (&entries) |*entry| {
            if (entry.used and std.mem.eql(u8, entry.id[0..entry.id_len], id)) {
                return entry;
            }
        }
        return null;
    }

    fn remember(id: []const u8, dbus_id: u32) bool {
        if (id.len == 0 or id.len > 63) return false;
        if (findEntry(id)) |entry| {
            entry.dbus_id = dbus_id;
            return true;
        }

        var free_slot: ?*Entry = null;
        for (&entries) |*entry| {
            if (!entry.used and free_slot == null) free_slot = entry;
        }
        const slot = free_slot orelse return false;
        slot.used = true;
        slot.id_len = id.len;
        @memcpy(slot.id[0..id.len], id);
        slot.id[id.len] = 0;
        slot.dbus_id = dbus_id;
        return true;
    }

    fn makeHints(silent: bool, hint_entry_type: ?*anyopaque) ?*anyopaque {
        if (!silent) return g_variant_new_array(hint_entry_type, null, 0);
        // Floating refs — 일부 alloc 실패 시 g_variant_new_tuple/array 가 sink 하기
        // 전까지 남은 floating ref 는 호출자가 unref 해야 한다(GLib doc). 여기서는
        // 4 단계 의존이라 마지막 array 호출이 모두 sink 하는 path 만 안전 — 중간
        // 실패 시 g_variant_unref 로 명시 해제.
        const key = g_variant_new_string("suppress-sound") orelse return null;
        const bool_value = g_variant_new_boolean(1) orelse {
            g_variant_unref(key);
            return null;
        };
        const variant_value = g_variant_new_variant(bool_value) orelse {
            g_variant_unref(bool_value);
            g_variant_unref(key);
            return null;
        };
        const entry = g_variant_new_dict_entry(key, variant_value) orelse {
            g_variant_unref(variant_value);
            // variant_value 가 bool_value 를 sink/own — bool_value 별도 unref 안 함.
            g_variant_unref(key);
            return null;
        };
        const hint_entries = [_]?*anyopaque{entry};
        const arr = g_variant_new_array(hint_entry_type, &hint_entries, hint_entries.len);
        if (arr == null) g_variant_unref(entry);
        return arr;
    }

    fn show(id: []const u8, title: []const u8, body: []const u8, silent: bool) bool {
        var id_buf: [64]u8 = undefined;
        var title_buf: [4096]u8 = undefined;
        var body_buf: [4096]u8 = undefined;
        _ = writeCStr(id, &id_buf) orelse return false;
        const title_z = writeCStr(title, &title_buf) orelse return false;
        const body_z = writeCStr(body, &body_buf) orelse return false;

        const hint_entry_type = g_variant_type_new("{sv}") orelse return false;
        defer g_variant_type_free(hint_entry_type);

        // 8 자식 floating ref 를 누적 — 중간 실패 시 collected 된 것 unref.
        var collected: [8]?*anyopaque = [_]?*anyopaque{null} ** 8;
        var n: usize = 0;
        const cleanupOnFail = struct {
            fn run(items: *[8]?*anyopaque, count: usize) void {
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    if (items[i]) |v| g_variant_unref(v);
                }
            }
        }.run;

        const no_actions = [_]?[*:0]const u8{null};
        collected[n] = g_variant_new_string("Suji") orelse {
            cleanupOnFail(&collected, n);
            return false;
        };
        n += 1;
        collected[n] = g_variant_new_uint32(0) orelse {
            cleanupOnFail(&collected, n);
            return false;
        };
        n += 1;
        collected[n] = g_variant_new_string("") orelse {
            cleanupOnFail(&collected, n);
            return false;
        };
        n += 1;
        collected[n] = g_variant_new_string(title_z) orelse {
            cleanupOnFail(&collected, n);
            return false;
        };
        n += 1;
        collected[n] = g_variant_new_string(body_z) orelse {
            cleanupOnFail(&collected, n);
            return false;
        };
        n += 1;
        collected[n] = g_variant_new_strv(&no_actions, 0) orelse {
            cleanupOnFail(&collected, n);
            return false;
        };
        n += 1;
        collected[n] = makeHints(silent, hint_entry_type) orelse {
            cleanupOnFail(&collected, n);
            return false;
        };
        n += 1;
        collected[n] = g_variant_new_int32(-1) orelse {
            cleanupOnFail(&collected, n);
            return false;
        };
        n += 1;

        const parameters = g_variant_new_tuple(&collected, n) orelse {
            cleanupOnFail(&collected, n);
            return false;
        };
        const reply = call("Notify", parameters, NOTIFY_TIMEOUT_MS) orelse return false;
        defer g_variant_unref(reply);

        const child = g_variant_get_child_value(reply, 0) orelse return false;
        defer g_variant_unref(child);
        const dbus_id = g_variant_get_uint32(child);
        return remember(id, dbus_id);
    }

    fn close(id: []const u8) bool {
        const entry = findEntry(id) orelse return false;
        const dbus_id = entry.dbus_id;
        const child = g_variant_new_uint32(dbus_id) orelse return false;
        const children = [_]?*anyopaque{child};
        const parameters = g_variant_new_tuple(&children, children.len) orelse {
            g_variant_unref(child);
            return false;
        };
        const reply = call("CloseNotification", parameters, NOTIFY_TIMEOUT_MS) orelse return false;
        g_variant_unref(reply);
        entry.used = false;
        return true;
    }
} else struct {};
