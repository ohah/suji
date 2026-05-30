//! Linux GTK StatusIcon Tray backend.

const std = @import("std");
const builtin = @import("builtin");
const tray_types = @import("cef_tray_types.zig");
const tray_state = @import("cef_tray_state.zig");

const is_linux = builtin.os.tag == .linux;
const TrayMenuItem = tray_types.TrayMenuItem;

fn nullTerminateOrTruncate(src: []const u8, buf: []u8) ?[:0]const u8 {
    if (src.len >= buf.len) return null;
    @memcpy(buf[0..src.len], src);
    buf[src.len] = 0;
    return buf[0..src.len :0];
}

pub fn create(title: []const u8, tooltip: []const u8, icon_path: []const u8) u32 {
    if (!comptime is_linux) return 0;
    return linux_tray.create(title, tooltip, icon_path);
}

pub fn setTitle(tray_id: u32, title: []const u8) bool {
    if (!comptime is_linux) return false;
    return linux_tray.setTitle(tray_id, title);
}

pub fn setTooltip(tray_id: u32, tooltip: []const u8) bool {
    if (!comptime is_linux) return false;
    return linux_tray.setTooltip(tray_id, tooltip);
}

pub fn setMenu(tray_id: u32, items: []const TrayMenuItem) bool {
    if (!comptime is_linux) return false;
    return linux_tray.setMenu(tray_id, items);
}

pub fn destroy(tray_id: u32) bool {
    if (!comptime is_linux) return false;
    return linux_tray.destroy(tray_id);
}

const linux_tray = if (is_linux) struct {
    const MAX_TRAYS: usize = 16;
    const MAX_MENU_ITEMS: usize = 64;
    const MAX_CLICK_BYTES: usize = 256;

    const MenuCallback = struct {
        used: bool = false,
        tray_id: u32 = 0,
        click: [MAX_CLICK_BYTES]u8 = undefined,
        click_len: usize = 0,
    };

    const Entry = struct {
        used: bool = false,
        id: u32 = 0,
        status_icon: ?*anyopaque = null,
        menu: ?*anyopaque = null,
        callbacks: [MAX_MENU_ITEMS]MenuCallback = [_]MenuCallback{.{}} ** MAX_MENU_ITEMS,
    };

    var entries: [MAX_TRAYS]Entry = [_]Entry{.{}} ** MAX_TRAYS;
    var next_id: u32 = 1;

    extern "c" fn suji_gtk_init_check() callconv(.c) c_int;
    extern "c" fn gtk_status_icon_new() callconv(.c) ?*anyopaque;
    extern "c" fn gtk_status_icon_set_from_icon_name(status_icon: ?*anyopaque, icon_name: [*:0]const u8) callconv(.c) void;
    extern "c" fn gtk_status_icon_set_from_file(status_icon: ?*anyopaque, filename: [*:0]const u8) callconv(.c) void;
    extern "c" fn gtk_status_icon_set_title(status_icon: ?*anyopaque, title: [*:0]const u8) callconv(.c) void;
    extern "c" fn gtk_status_icon_set_tooltip_text(status_icon: ?*anyopaque, text: [*:0]const u8) callconv(.c) void;
    extern "c" fn gtk_status_icon_set_visible(status_icon: ?*anyopaque, visible: c_int) callconv(.c) void;
    extern "c" fn gtk_status_icon_position_menu(menu: ?*anyopaque, x: ?*c_int, y: ?*c_int, push_in: ?*c_int, user_data: ?*anyopaque) callconv(.c) void;
    extern "c" fn gtk_menu_new() callconv(.c) ?*anyopaque;
    extern "c" fn gtk_menu_item_new_with_label(label: [*:0]const u8) callconv(.c) ?*anyopaque;
    extern "c" fn gtk_check_menu_item_new_with_label(label: [*:0]const u8) callconv(.c) ?*anyopaque;
    extern "c" fn gtk_check_menu_item_set_active(check_menu_item: ?*anyopaque, is_active: c_int) callconv(.c) void;
    extern "c" fn gtk_separator_menu_item_new() callconv(.c) ?*anyopaque;
    extern "c" fn gtk_menu_item_set_submenu(menu_item: ?*anyopaque, submenu: ?*anyopaque) callconv(.c) void;
    extern "c" fn gtk_menu_shell_append(menu_shell: ?*anyopaque, child: ?*anyopaque) callconv(.c) void;
    extern "c" fn gtk_widget_set_sensitive(widget: ?*anyopaque, sensitive: c_int) callconv(.c) void;
    extern "c" fn gtk_widget_show_all(widget: ?*anyopaque) callconv(.c) void;
    extern "c" fn gtk_widget_destroy(widget: ?*anyopaque) callconv(.c) void;
    extern "c" fn gtk_menu_popup(
        menu: ?*anyopaque,
        parent_menu_shell: ?*anyopaque,
        parent_menu_item: ?*anyopaque,
        func: ?*const anyopaque,
        data: ?*anyopaque,
        button: u32,
        activate_time: u32,
    ) callconv(.c) void;
    extern "c" fn g_signal_connect_data(
        instance: ?*anyopaque,
        detailed_signal: [*:0]const u8,
        c_handler: ?*const anyopaque,
        data: ?*anyopaque,
        destroy_data: ?*const fn (?*anyopaque, ?*anyopaque) callconv(.c) void,
        connect_flags: c_int,
    ) callconv(.c) usize;
    extern "c" fn g_object_unref(object: ?*anyopaque) callconv(.c) void;

    fn gtkAvailable() bool {
        return suji_gtk_init_check() != 0;
    }

    fn findEntry(tray_id: u32) ?*Entry {
        for (&entries) |*entry| {
            if (entry.used and entry.id == tray_id) return entry;
        }
        return null;
    }

    fn freeSlot() ?*Entry {
        for (&entries) |*entry| {
            if (!entry.used) return entry;
        }
        return null;
    }

    fn reserveId() u32 {
        const id = next_id;
        next_id +%= 1;
        if (next_id == 0) next_id = 1;
        return id;
    }

    fn dataForTrayId(tray_id: u32) ?*anyopaque {
        return @ptrFromInt(@as(usize, tray_id));
    }

    fn trayIdFromData(data: ?*anyopaque) u32 {
        const ptr = data orelse return 0;
        return @intCast(@intFromPtr(ptr));
    }

    fn clearCallbacks(entry: *Entry) void {
        for (&entry.callbacks) |*cb| cb.* = .{};
    }

    fn firstFreeCallback(entry: *Entry) ?*MenuCallback {
        for (&entry.callbacks) |*cb| {
            if (!cb.used) return cb;
        }
        return null;
    }

    fn setCallback(cb: *MenuCallback, tray_id: u32, click: []const u8) bool {
        if (click.len > cb.click.len) return false;
        cb.used = true;
        cb.tray_id = tray_id;
        cb.click_len = click.len;
        @memcpy(cb.click[0..click.len], click);
        return true;
    }

    fn menuItemActivateC(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
        const cb: *MenuCallback = @ptrCast(@alignCast(data orelse return));
        if (!cb.used) return;
        tray_state.emit(cb.tray_id, cb.click[0..cb.click_len]);
    }

    fn statusIconActivateC(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
        tray_state.emit(trayIdFromData(data), "");
    }

    fn statusIconPopupC(status_icon: ?*anyopaque, button: u32, activate_time: u32, data: ?*anyopaque) callconv(.c) void {
        const entry = findEntry(trayIdFromData(data)) orelse return;
        const menu = entry.menu orelse return;
        gtk_menu_popup(
            menu,
            null,
            null,
            @ptrCast(&gtk_status_icon_position_menu),
            status_icon,
            button,
            activate_time,
        );
    }

    fn setTitle(tray_id: u32, title: []const u8) bool {
        const entry = findEntry(tray_id) orelse return false;
        var title_buf: [256]u8 = undefined;
        const title_z = nullTerminateOrTruncate(title, &title_buf) orelse return false;
        gtk_status_icon_set_title(entry.status_icon, title_z.ptr);
        return true;
    }

    fn setTooltip(tray_id: u32, tooltip: []const u8) bool {
        const entry = findEntry(tray_id) orelse return false;
        var tooltip_buf: [512]u8 = undefined;
        const tooltip_z = nullTerminateOrTruncate(tooltip, &tooltip_buf) orelse return false;
        gtk_status_icon_set_tooltip_text(entry.status_icon, tooltip_z.ptr);
        return true;
    }

    fn create(title: []const u8, tooltip: []const u8, icon_path: []const u8) u32 {
        if (!gtkAvailable()) return 0;
        const slot = freeSlot() orelse return 0;
        const icon = gtk_status_icon_new() orelse return 0;

        if (icon_path.len > 0) {
            var path_buf: [2048]u8 = undefined;
            const path_z = nullTerminateOrTruncate(icon_path, &path_buf) orelse return 0;
            gtk_status_icon_set_from_file(icon, path_z.ptr);
        } else {
            gtk_status_icon_set_from_icon_name(icon, "application-x-executable");
        }
        gtk_status_icon_set_visible(icon, 1);

        const id = reserveId();
        slot.* = .{
            .used = true,
            .id = id,
            .status_icon = icon,
        };

        _ = g_signal_connect_data(icon, "activate", @ptrCast(&statusIconActivateC), dataForTrayId(id), null, 0);
        _ = g_signal_connect_data(icon, "popup-menu", @ptrCast(&statusIconPopupC), dataForTrayId(id), null, 0);

        if (title.len > 0) _ = @This().setTitle(id, title);
        if (tooltip.len > 0) {
            _ = @This().setTooltip(id, tooltip);
        } else if (title.len > 0) {
            _ = @This().setTooltip(id, title);
        }
        return id;
    }

    fn setMenu(tray_id: u32, items: []const TrayMenuItem) bool {
        const entry = findEntry(tray_id) orelse return false;
        if (!gtkAvailable()) return false;

        if (entry.menu) |old_menu| gtk_widget_destroy(old_menu);
        entry.menu = null;
        clearCallbacks(entry);

        const menu = createTrayGtkMenuFromItems(entry, tray_id, items) orelse return false;
        gtk_widget_show_all(menu);
        entry.menu = menu;
        return true;
    }

    fn createTrayGtkMenuFromItems(entry: *Entry, tray_id: u32, items: []const TrayMenuItem) ?*anyopaque {
        const menu = gtk_menu_new() orelse return null;
        for (items) |item| addTrayGtkMenuItem(entry, menu, tray_id, item);
        return menu;
    }

    fn addTrayGtkMenuItem(entry: *Entry, menu: *anyopaque, item_tray_id: u32, item: TrayMenuItem) void {
        switch (item) {
            .separator => {
                const sep = gtk_separator_menu_item_new() orelse return;
                gtk_menu_shell_append(menu, sep);
            },
            .item => |it| addTrayGtkClickable(entry, menu, item_tray_id, it.label, it.click, it.enabled, null),
            .checkbox => |it| addTrayGtkClickable(entry, menu, item_tray_id, it.label, it.click, it.enabled, it.checked),
            .submenu => |sub| {
                var label_buf: [256]u8 = undefined;
                const label_z = nullTerminateOrTruncate(sub.label, &label_buf) orelse return;
                const menu_item = gtk_menu_item_new_with_label(label_z.ptr) orelse return;
                const submenu = createTrayGtkMenuFromItems(entry, item_tray_id, sub.items) orelse return;
                gtk_menu_item_set_submenu(menu_item, submenu);
                gtk_widget_set_sensitive(menu_item, if (sub.enabled) 1 else 0);
                gtk_menu_shell_append(menu, menu_item);
            },
        }
    }

    fn addTrayGtkClickable(entry: *Entry, menu: *anyopaque, item_tray_id: u32, label: []const u8, click: []const u8, enabled: bool, checked: ?bool) void {
        var label_buf: [256]u8 = undefined;
        const label_z = nullTerminateOrTruncate(label, &label_buf) orelse return;
        const cb = firstFreeCallback(entry) orelse return;
        if (!setCallback(cb, item_tray_id, click)) return;
        const menu_item = if (checked) |state| blk: {
            const check = gtk_check_menu_item_new_with_label(label_z.ptr) orelse return;
            gtk_check_menu_item_set_active(check, if (state) 1 else 0);
            break :blk check;
        } else gtk_menu_item_new_with_label(label_z.ptr) orelse return;
        gtk_widget_set_sensitive(menu_item, if (enabled) 1 else 0);
        _ = g_signal_connect_data(menu_item, "activate", @ptrCast(&menuItemActivateC), cb, null, 0);
        gtk_menu_shell_append(menu, menu_item);
    }

    fn destroy(tray_id: u32) bool {
        const entry = findEntry(tray_id) orelse return false;
        if (entry.menu) |menu| gtk_widget_destroy(menu);
        if (entry.status_icon) |icon| {
            gtk_status_icon_set_visible(icon, 0);
            g_object_unref(icon);
        }
        entry.* = .{};
        return true;
    }
} else struct {};
