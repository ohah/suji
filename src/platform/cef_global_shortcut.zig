//! Global Shortcut API — cef.zig 에서 분리(동작 무변경). macOS Carbon/media keys,
//! Linux X11 XGrabKey, Windows RegisterHotKey 기반 Electron `globalShortcut` 호환 API.
const std = @import("std");
const builtin = @import("builtin");
const cef = @import("cef.zig");
const gs_types = @import("cef_global_shortcut_types.zig");
const gs_state = @import("cef_global_shortcut_state.zig");
const cef_global_shortcut_linux = @import("cef_global_shortcut_linux.zig");

const is_macos = builtin.os.tag == .macos;
const writeCStr = cef.writeCStr;
const win_pump = cef.win_pump;

// global_shortcut.m — Carbon RegisterEventHotKey wrapper.
// register status: 0=success, -1=capacity, -2=duplicate, -3=parse, -4=os_reject, -5=too_long.
extern "c" fn suji_global_shortcut_set_callback(cb: *const fn ([*:0]const u8, [*:0]const u8) callconv(.c) void) void;
extern "c" fn suji_global_shortcut_register(accelerator: [*:0]const u8, click: [*:0]const u8) i32;
extern "c" fn suji_global_shortcut_unregister(accelerator: [*:0]const u8) i32;
extern "c" fn suji_global_shortcut_unregister_all() void;
extern "c" fn suji_global_shortcut_is_registered(accelerator: [*:0]const u8) i32;

// ============================================
// Global shortcut API — Carbon RegisterEventHotKey / X11 XGrabKey / Win32 RegisterHotKey
// (Electron `globalShortcut.*`)
// ============================================
// macOS: Carbon Hot Key API (system-wide, 권한 불필요). global_shortcut.m이 wrap —
// accelerator 문자열 → modifier mask + virtual key code → RegisterEventHotKey.
// 트리거 시 `globalShortcut:trigger {accelerator, click}` EventBus emit.
// Linux는 X11 XGrabKey + dedicated event thread 경로. Windows는 RegisterHotKey +
// hidden pump window 경로.

pub const GlobalShortcutEmitHandler = gs_state.GlobalShortcutEmitHandler;
pub const GlobalShortcutStatus = gs_types.GlobalShortcutStatus;

const GLOBAL_SHORTCUT_STR_MAX = gs_types.GLOBAL_SHORTCUT_STR_MAX;

fn globalShortcutTriggerC(accel_cstr: [*:0]const u8, click_cstr: [*:0]const u8) callconv(.c) void {
    gs_state.emit(std.mem.span(accel_cstr), std.mem.span(click_cstr));
}

pub fn setGlobalShortcutEmitHandler(handler: GlobalShortcutEmitHandler) void {
    gs_state.setGlobalShortcutEmitHandler(handler);
    if (comptime is_macos) suji_global_shortcut_set_callback(&globalShortcutTriggerC);
    if (comptime builtin.os.tag == .windows) win_pump.ensureRunning();
    if (comptime builtin.os.tag == .linux) cef_global_shortcut_linux.prepare();
}

/// Electron globalShortcut.setSuspended/isSuspended — emit 게이트(전 플랫폼 공용, gs_state).
pub fn globalShortcutSetSuspended(v: bool) void {
    gs_state.setSuspended(v);
}

pub fn globalShortcutIsSuspended() bool {
    return gs_state.isSuspended();
}

// ============================================
// Win32 globalShortcut FFI (Windows only) — RegisterHotKey + accelerator parser.
// ============================================
// 현재 PoC: register/unregister/is_registered/unregister_all + parse_failed 검증.
// 실 키 trigger (WM_HOTKEY → emit) 는 별도 후속 PR — message pump thread 필요.
// e2e (run-global-shortcut) 의 9 케이스는 wire-level register/parse 만 검증하므로
// PoC 만으로도 100% 통과 가능.
pub const win_gs = if (builtin.os.tag == .windows) struct {
    const MOD_ALT: u32 = 1;
    const MOD_CONTROL: u32 = 2;
    const MOD_SHIFT: u32 = 4;
    const MOD_WIN: u32 = 8;
    const MOD_NOREPEAT: u32 = 0x4000;

    pub extern "user32" fn RegisterHotKey(hwnd: ?*anyopaque, id: i32, fsModifiers: u32, vk: u32) callconv(.winapi) i32;
    pub extern "user32" fn UnregisterHotKey(hwnd: ?*anyopaque, id: i32) callconv(.winapi) i32;

    /// (accelerator, click, id) 슬롯. id 는 1-based — RegisterHotKey 의 unique id.
    pub const Slot = struct {
        used: bool = false,
        id: i32 = 0,
        accel: [GLOBAL_SHORTCUT_STR_MAX]u8 = undefined,
        accel_len: usize = 0,
        click: [GLOBAL_SHORTCUT_STR_MAX]u8 = undefined,
        click_len: usize = 0,
    };
    const CAPACITY: usize = 64;
    pub var slots: [CAPACITY]Slot = [_]Slot{.{}} ** CAPACITY;
    var next_id: i32 = 1;
    // ⚠️ 알려진 이슈(Windows env 에서 수정 예정 — docs/audit-windows-followups.md):
    //    slots 는 IPC 스레드 write ↔ pump 스레드(WM_HOTKEY) read 가 무락 공유라 데이터
    //    레이스. Linux 의 slots_lock spinlock 패턴을 미러링하되, submitSync(pump 대기)
    //    구간엔 락을 잡지 않도록 write 블록만 보호 + pump read 보호. 로컬(macOS)에서
    //    comptime-prune 되어 검증 불가하므로 Windows 환경에서 적용·테스트.

    /// "Cmd+Shift+F8" 같은 accelerator → (modifiers, vkey). parse 실패 시 null.
    fn parse(accel: []const u8) ?struct { mods: u32, vk: u32 } {
        var mods: u32 = 0;
        var vk: u32 = 0;
        var has_key = false;
        var it = std.mem.tokenizeScalar(u8, accel, '+');
        while (it.next()) |raw| {
            var lower_buf: [32]u8 = undefined;
            if (raw.len + 1 > lower_buf.len) return null;
            for (raw, 0..) |ch, i| lower_buf[i] = std.ascii.toLower(ch);
            const part = lower_buf[0..raw.len];
            // Modifier 매핑 — Cmd/CmdOrCtrl/Command/Meta/Super → CONTROL on Windows.
            if (std.mem.eql(u8, part, "ctrl") or std.mem.eql(u8, part, "control") or
                std.mem.eql(u8, part, "cmd") or std.mem.eql(u8, part, "command") or
                std.mem.eql(u8, part, "cmdorctrl") or std.mem.eql(u8, part, "commandorcontrol") or
                std.mem.eql(u8, part, "meta") or std.mem.eql(u8, part, "super"))
            {
                mods |= MOD_CONTROL;
            } else if (std.mem.eql(u8, part, "shift")) {
                mods |= MOD_SHIFT;
            } else if (std.mem.eql(u8, part, "alt") or std.mem.eql(u8, part, "option")) {
                mods |= MOD_ALT;
            } else {
                if (has_key) return null; // multiple non-modifier keys
                const code = vkFromName(part) orelse return null;
                vk = code;
                has_key = true;
            }
        }
        if (!has_key) return null; // modifier-only
        return .{ .mods = mods | MOD_NOREPEAT, .vk = vk };
    }

    /// "a"-"z", "0"-"9", "f1"-"f24", "space", "enter", "esc", "tab", "backspace",
    /// "delete", "left/right/up/down", "home/end/pageup/pagedown" 등. 알 수 없는 키 → null.
    fn vkFromName(name: []const u8) ?u32 {
        if (name.len == 1) {
            const ch = name[0];
            if (ch >= 'a' and ch <= 'z') return @as(u32, ch - 'a' + 0x41); // VK_A
            if (ch >= '0' and ch <= '9') return @as(u32, ch - '0' + 0x30); // VK_0
        }
        if (name.len >= 2 and name[0] == 'f') {
            const num = std.fmt.parseInt(u32, name[1..], 10) catch return null;
            if (num >= 1 and num <= 24) return 0x70 + (num - 1); // VK_F1..VK_F24
        }
        // common named keys
        if (std.mem.eql(u8, name, "space")) return 0x20;
        if (std.mem.eql(u8, name, "enter") or std.mem.eql(u8, name, "return")) return 0x0D;
        if (std.mem.eql(u8, name, "escape") or std.mem.eql(u8, name, "esc")) return 0x1B;
        if (std.mem.eql(u8, name, "tab")) return 0x09;
        if (std.mem.eql(u8, name, "backspace")) return 0x08;
        if (std.mem.eql(u8, name, "delete")) return 0x2E;
        if (std.mem.eql(u8, name, "insert")) return 0x2D;
        if (std.mem.eql(u8, name, "home")) return 0x24;
        if (std.mem.eql(u8, name, "end")) return 0x23;
        if (std.mem.eql(u8, name, "pageup")) return 0x21;
        if (std.mem.eql(u8, name, "pagedown")) return 0x22;
        if (std.mem.eql(u8, name, "up")) return 0x26;
        if (std.mem.eql(u8, name, "down")) return 0x28;
        if (std.mem.eql(u8, name, "left")) return 0x25;
        if (std.mem.eql(u8, name, "right")) return 0x27;
        return null;
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

    fn register(accel: []const u8, click: []const u8) GlobalShortcutStatus {
        if (accel.len > GLOBAL_SHORTCUT_STR_MAX or click.len > GLOBAL_SHORTCUT_STR_MAX) return .too_long;
        if (findSlot(accel) != null) return .duplicate;
        const parsed = parse(accel) orelse return .parse;
        const idx = freeSlot() orelse return .capacity;
        const id = next_id;
        // pump thread 에 RegisterHotKey 위임 — WM_HOTKEY 가 pump thread 큐로 전달돼야
        // 우리가 receive 한다.
        const rc = win_pump.submitSync(.{
            .kind = @intFromEnum(win_pump.ReqKind.register),
            .id = id,
            .mods = parsed.mods,
            .vk = parsed.vk,
        });
        if (rc == win_pump.SUBMIT_TIMEOUT) return .timed_out;
        if (rc == win_pump.SUBMIT_FAIL) return .os_reject;
        if (rc == 0) return .os_reject; // RegisterHotKey returned 0 → 실 os reject
        next_id += 1;
        var s = &slots[idx];
        s.used = true;
        s.id = id;
        @memcpy(s.accel[0..accel.len], accel);
        s.accel_len = accel.len;
        @memcpy(s.click[0..click.len], click);
        s.click_len = click.len;
        return .ok;
    }

    fn unregister(accel: []const u8) bool {
        const idx = findSlot(accel) orelse return false;
        var s = &slots[idx];
        _ = win_pump.submitSync(.{ .kind = @intFromEnum(win_pump.ReqKind.unregister), .id = s.id });
        s.used = false;
        s.accel_len = 0;
        s.click_len = 0;
        return true;
    }

    fn unregisterAll() void {
        _ = win_pump.submitSync(.{ .kind = @intFromEnum(win_pump.ReqKind.unregister_all) });
        for (&slots) |*s| {
            s.used = false;
            s.accel_len = 0;
            s.click_len = 0;
        }
    }

    fn isRegistered(accel: []const u8) bool {
        return findSlot(accel) != null;
    }
} else struct {};

pub fn globalShortcutRegister(accelerator: []const u8, click: []const u8) GlobalShortcutStatus {
    if (comptime builtin.os.tag == .windows) return win_gs.register(accelerator, click);
    if (comptime builtin.os.tag == .linux) return cef_global_shortcut_linux.register(accelerator, click);
    if (!comptime is_macos) return .os_reject;
    var accel_buf: [GLOBAL_SHORTCUT_STR_MAX]u8 = undefined;
    var click_buf: [GLOBAL_SHORTCUT_STR_MAX]u8 = undefined;
    const accel_cstr = writeCStr(accelerator, &accel_buf) orelse return .too_long;
    const click_cstr = writeCStr(click, &click_buf) orelse return .too_long;
    return switch (suji_global_shortcut_register(accel_cstr, click_cstr)) {
        0 => .ok,
        -1 => .capacity,
        -2 => .duplicate,
        -3 => .parse,
        -4 => .os_reject,
        -5 => .too_long,
        else => .os_reject,
    };
}

pub fn globalShortcutUnregister(accelerator: []const u8) bool {
    if (comptime builtin.os.tag == .windows) return win_gs.unregister(accelerator);
    if (comptime builtin.os.tag == .linux) return cef_global_shortcut_linux.unregister(accelerator);
    if (!comptime is_macos) return false;
    var accel_buf: [GLOBAL_SHORTCUT_STR_MAX]u8 = undefined;
    const accel_cstr = writeCStr(accelerator, &accel_buf) orelse return false;
    return suji_global_shortcut_unregister(accel_cstr) != 0;
}

pub fn globalShortcutUnregisterAll() void {
    if (comptime builtin.os.tag == .windows) {
        win_gs.unregisterAll();
        return;
    }
    if (comptime builtin.os.tag == .linux) {
        cef_global_shortcut_linux.unregisterAll();
        return;
    }
    if (!comptime is_macos) return;
    suji_global_shortcut_unregister_all();
}

pub fn globalShortcutIsRegistered(accelerator: []const u8) bool {
    if (comptime builtin.os.tag == .windows) return win_gs.isRegistered(accelerator);
    if (comptime builtin.os.tag == .linux) return cef_global_shortcut_linux.isRegistered(accelerator);
    if (!comptime is_macos) return false;
    var accel_buf: [GLOBAL_SHORTCUT_STR_MAX]u8 = undefined;
    const accel_cstr = writeCStr(accelerator, &accel_buf) orelse return false;
    return suji_global_shortcut_is_registered(accel_cstr) != 0;
}
