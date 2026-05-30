//! Linux X11 globalShortcut accelerator parser.

const std = @import("std");
const builtin = @import("builtin");

pub const KeySym = c_ulong;

pub const ShiftMask: c_uint = 1 << 0;
pub const LockMask: c_uint = 1 << 1;
pub const ControlMask: c_uint = 1 << 2;
pub const Mod1Mask: c_uint = 1 << 3; // Alt
pub const Mod2Mask: c_uint = 1 << 4; // usually NumLock
pub const Mod4Mask: c_uint = 1 << 6; // Super/Meta
pub const IgnoredModifierMasks = [_]c_uint{ 0, LockMask, Mod2Mask, LockMask | Mod2Mask };

const XK_BackSpace: KeySym = 0xff08;
const XK_Tab: KeySym = 0xff09;
const XK_Return: KeySym = 0xff0d;
const XK_Escape: KeySym = 0xff1b;
const XK_Delete: KeySym = 0xffff;
const XK_Insert: KeySym = 0xff63;
const XK_Home: KeySym = 0xff50;
const XK_End: KeySym = 0xff57;
const XK_PageUp: KeySym = 0xff55;
const XK_PageDown: KeySym = 0xff56;
const XK_Left: KeySym = 0xff51;
const XK_Up: KeySym = 0xff52;
const XK_Right: KeySym = 0xff53;
const XK_Down: KeySym = 0xff54;
const XK_F1: KeySym = 0xffbe;

pub const Parsed = struct {
    mods: c_uint,
    keysym: KeySym,
};

pub fn parseKeysym(accel: []const u8) ?Parsed {
    if (comptime builtin.os.tag != .linux) return null;
    return parser.parseKeysym(accel);
}

const parser = if (builtin.os.tag == .linux) struct {
    extern "X11" fn XStringToKeysym(string: [*:0]const u8) callconv(.c) KeySym;

    fn parseKeysym(accel: []const u8) ?Parsed {
        var mods: c_uint = 0;
        var keysym: KeySym = 0;
        var has_key = false;
        var it = std.mem.tokenizeScalar(u8, accel, '+');
        while (it.next()) |raw| {
            var lower_buf: [32]u8 = undefined;
            if (raw.len + 1 > lower_buf.len) return null;
            for (raw, 0..) |ch, i| lower_buf[i] = std.ascii.toLower(ch);
            const part = lower_buf[0..raw.len];
            if (std.mem.eql(u8, part, "ctrl") or std.mem.eql(u8, part, "control") or
                std.mem.eql(u8, part, "cmdorctrl") or std.mem.eql(u8, part, "commandorcontrol"))
            {
                mods |= ControlMask;
            } else if (std.mem.eql(u8, part, "cmd") or std.mem.eql(u8, part, "command") or
                std.mem.eql(u8, part, "meta") or std.mem.eql(u8, part, "super"))
            {
                mods |= Mod4Mask;
            } else if (std.mem.eql(u8, part, "shift")) {
                mods |= ShiftMask;
            } else if (std.mem.eql(u8, part, "alt") or std.mem.eql(u8, part, "option")) {
                mods |= Mod1Mask;
            } else {
                if (has_key) return null;
                keysym = keysymFromName(part) orelse return null;
                has_key = true;
            }
        }
        if (!has_key) return null;
        return .{ .mods = mods, .keysym = keysym };
    }

    fn keysymFromName(name: []const u8) ?KeySym {
        if (name.len == 1) {
            const ch = name[0];
            if (ch >= 'a' and ch <= 'z') return @as(KeySym, ch - 'a' + 'A');
            if (ch >= '0' and ch <= '9') return @as(KeySym, ch);
        }
        if (name.len >= 2 and name[0] == 'f') {
            const num = std.fmt.parseInt(u32, name[1..], 10) catch return null;
            if (num >= 1 and num <= 24) return XK_F1 + @as(KeySym, num - 1);
        }
        if (std.mem.eql(u8, name, "space")) return 0x20;
        if (std.mem.eql(u8, name, "enter") or std.mem.eql(u8, name, "return")) return XK_Return;
        if (std.mem.eql(u8, name, "escape") or std.mem.eql(u8, name, "esc")) return XK_Escape;
        if (std.mem.eql(u8, name, "tab")) return XK_Tab;
        if (std.mem.eql(u8, name, "backspace")) return XK_BackSpace;
        if (std.mem.eql(u8, name, "delete") or std.mem.eql(u8, name, "forwarddelete")) return XK_Delete;
        if (std.mem.eql(u8, name, "insert")) return XK_Insert;
        if (std.mem.eql(u8, name, "home")) return XK_Home;
        if (std.mem.eql(u8, name, "end")) return XK_End;
        if (std.mem.eql(u8, name, "pageup")) return XK_PageUp;
        if (std.mem.eql(u8, name, "pagedown")) return XK_PageDown;
        if (std.mem.eql(u8, name, "up")) return XK_Up;
        if (std.mem.eql(u8, name, "down")) return XK_Down;
        if (std.mem.eql(u8, name, "left")) return XK_Left;
        if (std.mem.eql(u8, name, "right")) return XK_Right;

        var key_name: [32]u8 = undefined;
        if (name.len + 1 > key_name.len) return null;
        @memcpy(key_name[0..name.len], name);
        key_name[name.len] = 0;
        const sym = XStringToKeysym(@ptrCast(key_name[0..name.len :0].ptr));
        if (sym == 0) return null;
        return sym;
    }
} else struct {};
