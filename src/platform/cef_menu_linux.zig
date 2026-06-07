//! Linux GTK backend for programmatic context menus.

const std = @import("std");
const builtin = @import("builtin");
const menu_types = @import("cef_menu_types.zig");
const cef_util = @import("cef_util.zig");

const ApplicationMenuItem = menu_types.ApplicationMenuItem;
const MenuEmitHandler = menu_types.MenuEmitHandler;
const nullTerminateOrTruncate = cef_util.nullTerminateOrTruncate;

const impl = if (builtin.os.tag == .linux) struct {
    const MAX_MENU_ITEMS: usize = 64;
    const MAX_CLICK_BYTES: usize = 256;

    const MenuCallback = struct {
        used: bool = false,
        click: [MAX_CLICK_BYTES]u8 = undefined,
        click_len: usize = 0,
    };

    var g_menu_emit_handler: ?MenuEmitHandler = null;
    var current_menu: ?*anyopaque = null;
    var callbacks: [MAX_MENU_ITEMS]MenuCallback = [_]MenuCallback{.{}} ** MAX_MENU_ITEMS;
    var popup_x: c_int = 0;
    var popup_y: c_int = 0;

    extern "c" fn suji_gtk_init_check() callconv(.c) c_int;
    extern "c" fn gtk_menu_new() callconv(.c) ?*anyopaque;
    extern "c" fn gtk_menu_item_new_with_label(label: [*:0]const u8) callconv(.c) ?*anyopaque;
    extern "c" fn gtk_check_menu_item_new_with_label(label: [*:0]const u8) callconv(.c) ?*anyopaque;
    extern "c" fn gtk_check_menu_item_set_active(check_menu_item: ?*anyopaque, is_active: c_int) callconv(.c) void;
    extern "c" fn gtk_separator_menu_item_new() callconv(.c) ?*anyopaque;
    extern "c" fn gtk_menu_item_set_submenu(menu_item: ?*anyopaque, submenu: ?*anyopaque) callconv(.c) void;
    extern "c" fn gtk_menu_shell_append(menu_shell: ?*anyopaque, child: ?*anyopaque) callconv(.c) void;
    extern "c" fn gtk_widget_set_sensitive(widget: ?*anyopaque, sensitive: c_int) callconv(.c) void;
    extern "c" fn gtk_widget_set_visible(widget: ?*anyopaque, visible: c_int) callconv(.c) void;
    extern "c" fn gtk_widget_set_no_show_all(widget: ?*anyopaque, no_show_all: c_int) callconv(.c) void;
    extern "c" fn gtk_widget_show_all(widget: ?*anyopaque) callconv(.c) void;
    extern "c" fn gtk_widget_destroy(widget: ?*anyopaque) callconv(.c) void;
    extern "c" fn gtk_get_current_event_time() callconv(.c) u32;
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

    pub fn setMenuEmitHandler(handler: MenuEmitHandler) void {
        g_menu_emit_handler = handler;
    }

    fn gtkAvailable() bool {
        return suji_gtk_init_check() != 0;
    }

    fn clearCallbacks() void {
        for (&callbacks) |*cb| cb.* = .{};
    }

    fn closeCurrentMenu() void {
        const menu = current_menu orelse {
            clearCallbacks();
            return;
        };
        current_menu = null;
        gtk_widget_destroy(menu);
        clearCallbacks();
    }

    fn firstFreeCallback() ?*MenuCallback {
        for (&callbacks) |*cb| {
            if (!cb.used) return cb;
        }
        return null;
    }

    fn setCallback(cb: *MenuCallback, click: []const u8) bool {
        if (click.len > cb.click.len) return false;
        cb.used = true;
        cb.click_len = click.len;
        @memcpy(cb.click[0..click.len], click);
        return true;
    }

    fn menuItemActivateC(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
        const cb: *MenuCallback = @ptrCast(@alignCast(data orelse return));
        if (!cb.used) return;
        if (g_menu_emit_handler) |emit| emit(cb.click[0..cb.click_len]);
    }

    fn menuDeactivateC(widget: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
        const menu = widget orelse return;
        if (current_menu == null or current_menu.? != menu) return;
        current_menu = null;
        gtk_widget_destroy(menu);
        clearCallbacks();
    }

    fn popupPositionC(_: ?*anyopaque, x: ?*c_int, y: ?*c_int, push_in: ?*c_int, _: ?*anyopaque) callconv(.c) void {
        if (x) |px| px.* = popup_x;
        if (y) |py| py.* = popup_y;
        if (push_in) |p| p.* = 0;
    }

    fn coordToCInt(v: f64) c_int {
        if (std.math.isNan(v)) return 0;
        const min = @as(f64, @floatFromInt(std.math.minInt(c_int)));
        const max = @as(f64, @floatFromInt(std.math.maxInt(c_int)));
        return @intFromFloat(std.math.clamp(v, min, max));
    }

    fn createGtkMenuFromItems(items: []const ApplicationMenuItem) ?*anyopaque {
        const menu = gtk_menu_new() orelse return null;
        for (items) |item| addGtkMenuItem(menu, item);
        return menu;
    }

    fn addGtkMenuItem(menu: *anyopaque, item: ApplicationMenuItem) void {
        switch (item) {
            .separator => {
                const sep = gtk_separator_menu_item_new() orelse return;
                gtk_menu_shell_append(menu, sep);
            },
            .item => |it| addClickable(menu, it.label, it.click, it.enabled, null, it.visible),
            .checkbox => |it| addClickable(menu, it.label, it.click, it.enabled, it.checked, it.visible),
            .submenu => |sub| {
                var label_buf: [256]u8 = undefined;
                const label_z = nullTerminateOrTruncate(sub.label, &label_buf) orelse return;
                const item_widget = gtk_menu_item_new_with_label(label_z.ptr) orelse return;
                const submenu = createGtkMenuFromItems(sub.items) orelse return;
                gtk_menu_item_set_submenu(item_widget, submenu);
                gtk_widget_set_sensitive(item_widget, if (sub.enabled) 1 else 0);
                applyGtkVisible(item_widget, sub.visible);
                gtk_menu_shell_append(menu, item_widget);
            },
        }
    }

    // visible=false → no_show_all 로 gtk_widget_show_all 의 강제표시를 막고 hidden 처리.
    fn applyGtkVisible(widget: *anyopaque, visible: bool) void {
        if (visible) return;
        gtk_widget_set_no_show_all(widget, 1);
        gtk_widget_set_visible(widget, 0);
    }

    fn addClickable(menu: *anyopaque, label: []const u8, click: []const u8, enabled: bool, checked: ?bool, visible: bool) void {
        var label_buf: [256]u8 = undefined;
        const label_z = nullTerminateOrTruncate(label, &label_buf) orelse return;
        const cb = firstFreeCallback() orelse return;
        if (!setCallback(cb, click)) return;
        const item_widget = if (checked) |state| blk: {
            const check = gtk_check_menu_item_new_with_label(label_z.ptr) orelse return;
            gtk_check_menu_item_set_active(check, if (state) 1 else 0);
            break :blk check;
        } else gtk_menu_item_new_with_label(label_z.ptr) orelse return;

        gtk_widget_set_sensitive(item_widget, if (enabled) 1 else 0);
        applyGtkVisible(item_widget, visible);
        _ = g_signal_connect_data(item_widget, "activate", @ptrCast(&menuItemActivateC), cb, null, 0);
        gtk_menu_shell_append(menu, item_widget);
    }

    pub fn popup(items: []const ApplicationMenuItem, x: ?f64, y: ?f64) bool {
        if (!gtkAvailable()) return false;
        closeCurrentMenu();

        const menu = createGtkMenuFromItems(items) orelse return false;
        current_menu = menu;
        _ = g_signal_connect_data(menu, "deactivate", @ptrCast(&menuDeactivateC), null, null, 0);
        gtk_widget_show_all(menu);

        const use_position = x != null and y != null;
        if (use_position) {
            popup_x = coordToCInt(x.?);
            popup_y = coordToCInt(y.?);
        }
        const position_func: ?*const anyopaque = if (use_position) @ptrCast(&popupPositionC) else null;
        gtk_menu_popup(
            menu,
            null,
            null,
            position_func,
            null,
            0,
            gtk_get_current_event_time(),
        );
        return true;
    }
} else struct {
    pub fn setMenuEmitHandler(_: MenuEmitHandler) void {}

    pub fn popup(_: []const ApplicationMenuItem, _: ?f64, _: ?f64) bool {
        return false;
    }
};

pub const setMenuEmitHandler = impl.setMenuEmitHandler;
pub const popup = impl.popup;
