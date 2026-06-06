//! Linux X11 backend for Electron-compatible screen APIs.

const std = @import("std");
const builtin = @import("builtin");
const screen_model = @import("screen_model.zig");

const impl = if (builtin.os.tag == .linux) struct {
    extern "c" fn XOpenDisplay(display_name: ?[*:0]const u8) callconv(.c) ?*anyopaque;
    extern "c" fn XCloseDisplay(display: ?*anyopaque) callconv(.c) c_int;
    extern "c" fn XDefaultScreen(display: ?*anyopaque) callconv(.c) c_int;
    extern "c" fn XScreenCount(display: ?*anyopaque) callconv(.c) c_int;
    extern "c" fn XDisplayWidth(display: ?*anyopaque, screen_number: c_int) callconv(.c) c_int;
    extern "c" fn XDisplayHeight(display: ?*anyopaque, screen_number: c_int) callconv(.c) c_int;
    extern "c" fn XRootWindow(display: ?*anyopaque, screen_number: c_int) callconv(.c) c_ulong;
    extern "c" fn XQueryPointer(
        display: ?*anyopaque,
        window: c_ulong,
        root_return: *c_ulong,
        child_return: *c_ulong,
        root_x_return: *c_int,
        root_y_return: *c_int,
        win_x_return: *c_int,
        win_y_return: *c_int,
        mask_return: *c_uint,
    ) callconv(.c) c_int;

    fn writeEmptyJsonArray(out_buf: []u8) []const u8 {
        const empty = "[]";
        const n = @min(empty.len, out_buf.len);
        @memcpy(out_buf[0..n], empty[0..n]);
        return out_buf[0..n];
    }

    fn displayBounds(display: ?*anyopaque, screen_number: c_int) ?screen_model.DisplayBounds {
        const width = XDisplayWidth(display, screen_number);
        const height = XDisplayHeight(display, screen_number);
        if (width <= 0 or height <= 0) return null;
        return .{ .x = 0, .y = 0, .width = width, .height = height };
    }

    pub fn getAllDisplays(out_buf: []u8) []const u8 {
        const display = XOpenDisplay(null) orelse return writeEmptyJsonArray(out_buf);
        defer _ = XCloseDisplay(display);

        const count = XScreenCount(display);
        if (count <= 0) return writeEmptyJsonArray(out_buf);
        const primary = XDefaultScreen(display);

        var w = std.Io.Writer.fixed(out_buf);
        w.writeByte('[') catch return out_buf[0..1];
        var first = true;
        var idx: c_int = 0;
        while (idx < count) : (idx += 1) {
            const b = displayBounds(display, idx) orelse continue;
            if (!first) w.writeByte(',') catch return w.buffered();
            first = false;
            w.print(
                "{{\"index\":{d},\"isPrimary\":{},\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d},\"visibleX\":{d},\"visibleY\":{d},\"visibleWidth\":{d},\"visibleHeight\":{d},\"scaleFactor\":{d}}}",
                .{
                    idx,           idx == primary,
                    b.x,           b.y,
                    b.width,       b.height,
                    b.x,           b.y,
                    b.width,       b.height,
                    @as(f64, 1.0),
                },
            ) catch return w.buffered();
        }
        w.writeByte(']') catch return w.buffered();
        return w.buffered();
    }

    pub fn cursorPoint() [2]f64 {
        const display = XOpenDisplay(null) orelse return .{ 0, 0 };
        defer _ = XCloseDisplay(display);

        const screen = XDefaultScreen(display);
        const root = XRootWindow(display, screen);
        var root_return: c_ulong = 0;
        var child_return: c_ulong = 0;
        var root_x: c_int = 0;
        var root_y: c_int = 0;
        var win_x: c_int = 0;
        var win_y: c_int = 0;
        var mask: c_uint = 0;
        if (XQueryPointer(display, root, &root_return, &child_return, &root_x, &root_y, &win_x, &win_y, &mask) == 0)
            return .{ 0, 0 };
        return .{ @floatFromInt(root_x), @floatFromInt(root_y) };
    }

    pub fn displayNearestPoint(x: f64, y: f64) i32 {
        const display = XOpenDisplay(null) orelse return -1;
        defer _ = XCloseDisplay(display);

        const count = XScreenCount(display);
        if (count <= 0) return -1;

        var displays: [32]screen_model.DisplayBounds = undefined;
        var len: usize = 0;
        var idx: c_int = 0;
        while (idx < count and len < displays.len) : (idx += 1) {
            if (displayBounds(display, idx)) |b| {
                displays[len] = b;
                len += 1;
            }
        }
        return screen_model.containedDisplayIndex(displays[0..len], x, y);
    }

    pub fn displayMatching(x: f64, y: f64, w: f64, h: f64) i32 {
        const display = XOpenDisplay(null) orelse return -1;
        defer _ = XCloseDisplay(display);

        const count = XScreenCount(display);
        if (count <= 0) return -1;

        var displays: [32]screen_model.DisplayBounds = undefined;
        var len: usize = 0;
        var idx: c_int = 0;
        while (idx < count and len < displays.len) : (idx += 1) {
            if (displayBounds(display, idx)) |b| {
                displays[len] = b;
                len += 1;
            }
        }
        return screen_model.matchingDisplayIndex(displays[0..len], x, y, w, h);
    }
} else struct {
    pub fn getAllDisplays(out_buf: []u8) []const u8 {
        const empty = "[]";
        const n = @min(empty.len, out_buf.len);
        @memcpy(out_buf[0..n], empty[0..n]);
        return out_buf[0..n];
    }

    pub fn cursorPoint() [2]f64 {
        return .{ 0, 0 };
    }

    pub fn displayNearestPoint(_: f64, _: f64) i32 {
        return -1;
    }

    pub fn displayMatching(_: f64, _: f64, _: f64, _: f64) i32 {
        return -1;
    }
};

pub const getAllDisplays = impl.getAllDisplays;
pub const cursorPoint = impl.cursorPoint;
pub const displayNearestPoint = impl.displayNearestPoint;
pub const displayMatching = impl.displayMatching;
