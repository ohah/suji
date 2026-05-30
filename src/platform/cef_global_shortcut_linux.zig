//! Linux X11 Global Shortcut backend.

const std = @import("std");
const builtin = @import("builtin");
const gs_types = @import("cef_global_shortcut_types.zig");
const gs_state = @import("cef_global_shortcut_state.zig");
const linux_parse = @import("cef_global_shortcut_linux_parse.zig");

const GLOBAL_SHORTCUT_STR_MAX = gs_types.GLOBAL_SHORTCUT_STR_MAX;
const GlobalShortcutStatus = gs_types.GlobalShortcutStatus;

pub fn prepare() void {
    if (comptime builtin.os.tag == .linux) linux_gs.prepare();
}

pub fn register(accel: []const u8, click: []const u8) GlobalShortcutStatus {
    if (comptime builtin.os.tag != .linux) return .os_reject;
    return linux_gs.register(accel, click);
}

pub fn unregister(accel: []const u8) bool {
    if (comptime builtin.os.tag != .linux) return false;
    return linux_gs.unregister(accel);
}

pub fn unregisterAll() void {
    if (comptime builtin.os.tag == .linux) linux_gs.unregisterAll();
}

pub fn isRegistered(accel: []const u8) bool {
    if (comptime builtin.os.tag != .linux) return false;
    return linux_gs.isRegistered(accel);
}

// ============================================
// Linux globalShortcut FFI — X11 XGrabKey + event thread.
// ============================================
// Wayland compositor-global shortcuts have no stable compositor-independent API.
// DISPLAY가 있는 X11/XWayland 세션에서만 활성화하고, DISPLAY 부재/키 매핑 실패는
// os_reject/parse_failed로 graceful degrade.
const linux_gs = if (builtin.os.tag == .linux) struct {
    const Display = anyopaque;
    const Window = c_ulong;

    const KeyPress: c_int = 2;
    const GrabModeAsync: c_int = 1;
    const LockMask = linux_parse.LockMask;
    const Mod2Mask = linux_parse.Mod2Mask;
    const IgnoredModifierMasks = linux_parse.IgnoredModifierMasks;

    const XKeyEvent = extern struct {
        type_: c_int,
        serial: c_ulong,
        send_event: c_int,
        display: ?*Display,
        window: Window,
        root: Window,
        subwindow: Window,
        time: c_ulong,
        x: c_int,
        y: c_int,
        x_root: c_int,
        y_root: c_int,
        state: c_uint,
        keycode: c_uint,
        same_screen: c_int,
    };
    const XEvent = extern union {
        type_: c_int,
        xkey: XKeyEvent,
        pad: [24]c_long,
    };
    const XErrorEvent = extern struct {
        type_: c_int,
        display: ?*Display,
        resourceid: c_ulong,
        serial: c_ulong,
        error_code: u8,
        request_code: u8,
        minor_code: u8,
    };
    const XErrorHandler = ?*const fn (display: ?*Display, event: *XErrorEvent) callconv(.c) c_int;

    extern "X11" fn XInitThreads() callconv(.c) c_int;
    extern "X11" fn XOpenDisplay(display_name: ?[*:0]const u8) callconv(.c) ?*Display;
    extern "X11" fn XCloseDisplay(display: ?*Display) callconv(.c) c_int;
    extern "X11" fn XDefaultRootWindow(display: ?*Display) callconv(.c) Window;
    extern "X11" fn XKeysymToKeycode(display: ?*Display, keysym: linux_parse.KeySym) callconv(.c) u8;
    extern "X11" fn XGrabKey(display: ?*Display, keycode: c_int, modifiers: c_uint, grab_window: Window, owner_events: c_int, pointer_mode: c_int, keyboard_mode: c_int) callconv(.c) c_int;
    extern "X11" fn XUngrabKey(display: ?*Display, keycode: c_int, modifiers: c_uint, grab_window: Window) callconv(.c) c_int;
    extern "X11" fn XNextEvent(display: ?*Display, event_return: *XEvent) callconv(.c) c_int;
    extern "X11" fn XSync(display: ?*Display, discard: c_int) callconv(.c) c_int;
    extern "X11" fn XSetErrorHandler(handler: XErrorHandler) callconv(.c) XErrorHandler;

    const Parsed = struct {
        mods: c_uint,
        keycode: u8,
    };
    pub const Slot = struct {
        used: bool = false,
        keycode: u8 = 0,
        mods: c_uint = 0,
        accel: [GLOBAL_SHORTCUT_STR_MAX]u8 = undefined,
        accel_len: usize = 0,
        click: [GLOBAL_SHORTCUT_STR_MAX]u8 = undefined,
        click_len: usize = 0,
    };

    const CAPACITY: usize = 64;
    pub var slots: [CAPACITY]Slot = [_]Slot{.{}} ** CAPACITY;
    var display: ?*Display = null;
    var root_window: Window = 0;
    var started: std.atomic.Value(bool) = .init(false);
    var init_lock: std.atomic.Value(bool) = .init(false);
    var xlib_threads_ready: std.atomic.Value(bool) = .init(false);
    var xlib_threads_lock: std.atomic.Value(bool) = .init(false);
    var slots_lock: std.atomic.Value(bool) = .init(false);
    var x_error_seen: std.atomic.Value(bool) = .init(false);

    fn spinLock(flag: *std.atomic.Value(bool)) void {
        while (flag.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn spinUnlock(flag: *std.atomic.Value(bool)) void {
        flag.store(false, .release);
    }

    fn xErrorHandler(_: ?*Display, _: *XErrorEvent) callconv(.c) c_int {
        x_error_seen.store(true, .release);
        return 0;
    }

    pub fn prepare() void {
        _ = ensureXlibThreads();
    }

    fn ensureXlibThreads() bool {
        if (xlib_threads_ready.load(.acquire)) return true;
        spinLock(&xlib_threads_lock);
        defer spinUnlock(&xlib_threads_lock);
        if (xlib_threads_ready.load(.acquire)) return true;
        if (XInitThreads() == 0) return false;
        xlib_threads_ready.store(true, .release);
        return true;
    }

    fn ensureRunning() bool {
        if (started.load(.acquire) and display != null) return true;
        if (!ensureXlibThreads()) return false;
        spinLock(&init_lock);
        defer spinUnlock(&init_lock);
        if (started.load(.acquire) and display != null) return true;

        const dpy = XOpenDisplay(null) orelse return false;
        display = dpy;
        root_window = XDefaultRootWindow(dpy);

        const thread = std.Thread.spawn(.{}, eventLoop, .{}) catch {
            _ = XCloseDisplay(dpy);
            display = null;
            root_window = 0;
            return false;
        };
        thread.detach();
        started.store(true, .release);
        return true;
    }

    fn eventLoop() void {
        const dpy = display orelse return;
        var ev: XEvent = undefined;
        while (true) {
            if (XNextEvent(dpy, &ev) != 0) continue;
            if (ev.type_ == KeyPress) handleKeyPress(ev.xkey.keycode, ev.xkey.state);
        }
    }

    fn normalizeMods(state: c_uint) c_uint {
        return state & ~(LockMask | Mod2Mask);
    }

    fn handleKeyPress(keycode: c_uint, state: c_uint) void {
        const mods = normalizeMods(state);
        var accel_copy: [GLOBAL_SHORTCUT_STR_MAX]u8 = undefined;
        var click_copy: [GLOBAL_SHORTCUT_STR_MAX]u8 = undefined;
        var accel_len: usize = 0;
        var click_len: usize = 0;

        spinLock(&slots_lock);
        for (&slots) |*s| {
            if (!s.used) continue;
            if (@as(c_uint, s.keycode) == keycode and s.mods == mods) {
                @memcpy(accel_copy[0..s.accel_len], s.accel[0..s.accel_len]);
                @memcpy(click_copy[0..s.click_len], s.click[0..s.click_len]);
                accel_len = s.accel_len;
                click_len = s.click_len;
                break;
            }
        }
        spinUnlock(&slots_lock);

        if (accel_len > 0) {
            gs_state.emit(accel_copy[0..accel_len], click_copy[0..click_len]);
        }
    }

    fn parse(accel: []const u8) ?Parsed {
        const dpy = display orelse return null;
        const parsed = linux_parse.parseKeysym(accel) orelse return null;
        const keycode = XKeysymToKeycode(dpy, parsed.keysym);
        if (keycode == 0) return null;
        return .{ .mods = parsed.mods, .keycode = keycode };
    }

    fn findSlot(accel: []const u8) ?usize {
        for (&slots, 0..) |*s, i| {
            if (s.used and std.mem.eql(u8, s.accel[0..s.accel_len], accel)) return i;
        }
        return null;
    }

    fn freeSlot() ?usize {
        for (&slots, 0..) |*s, i| if (!s.used) return i;
        return null;
    }

    fn grab(dpy: ?*Display, keycode: u8, mods: c_uint) bool {
        x_error_seen.store(false, .release);
        const prev_handler = XSetErrorHandler(&xErrorHandler);
        for (IgnoredModifierMasks) |ignored| {
            _ = XGrabKey(dpy, @intCast(keycode), mods | ignored, root_window, 1, GrabModeAsync, GrabModeAsync);
        }
        _ = XSync(dpy, 0);
        _ = XSetErrorHandler(prev_handler);
        return !x_error_seen.load(.acquire);
    }

    fn ungrab(dpy: ?*Display, keycode: u8, mods: c_uint) void {
        for (IgnoredModifierMasks) |ignored| {
            _ = XUngrabKey(dpy, @intCast(keycode), mods | ignored, root_window);
        }
        _ = XSync(dpy, 0);
    }

    fn register(accel: []const u8, click: []const u8) GlobalShortcutStatus {
        if (accel.len > GLOBAL_SHORTCUT_STR_MAX or click.len > GLOBAL_SHORTCUT_STR_MAX) return .too_long;
        if (!ensureRunning()) return .os_reject;
        const parsed = parse(accel) orelse return .parse;
        const dpy = display orelse return .os_reject;

        spinLock(&slots_lock);
        defer spinUnlock(&slots_lock);
        if (findSlot(accel) != null) return .duplicate;
        const idx = freeSlot() orelse return .capacity;

        if (!grab(dpy, parsed.keycode, parsed.mods)) {
            ungrab(dpy, parsed.keycode, parsed.mods);
            return .os_reject;
        }
        var s = &slots[idx];
        s.used = true;
        s.keycode = parsed.keycode;
        s.mods = parsed.mods;
        @memcpy(s.accel[0..accel.len], accel);
        s.accel_len = accel.len;
        @memcpy(s.click[0..click.len], click);
        s.click_len = click.len;
        return .ok;
    }

    fn unregister(accel: []const u8) bool {
        const dpy = display orelse return false;
        spinLock(&slots_lock);
        defer spinUnlock(&slots_lock);
        const idx = findSlot(accel) orelse return false;
        var s = &slots[idx];
        ungrab(dpy, s.keycode, s.mods);
        s.used = false;
        s.accel_len = 0;
        s.click_len = 0;
        return true;
    }

    fn unregisterAll() void {
        const dpy = display orelse return;
        spinLock(&slots_lock);
        defer spinUnlock(&slots_lock);
        for (&slots) |*s| {
            if (!s.used) continue;
            ungrab(dpy, s.keycode, s.mods);
            s.used = false;
            s.accel_len = 0;
            s.click_len = 0;
        }
    }

    fn isRegistered(accel: []const u8) bool {
        spinLock(&slots_lock);
        defer spinUnlock(&slots_lock);
        return findSlot(accel) != null;
    }
} else struct {};
