//! Power-save blocker — cef.zig 에서 분리(동작 무변경). macOS IOPMAssertion,
//! Linux XScreenSaverSuspend, Windows Power Request API.
const std = @import("std");
const builtin = @import("builtin");
const cef = @import("cef.zig");

const is_macos = builtin.os.tag == .macos;
const is_linux = builtin.os.tag == .linux;
const is_windows = builtin.os.tag == .windows;

const nsStringFromCstr = cef.nsStringFromCstr;

pub const PowerSaveBlockerType = enum { prevent_app_suspension, prevent_display_sleep };

extern "c" fn IOPMAssertionCreateWithName(
    assertion_type: ?*anyopaque,
    assertion_level: u32,
    name: ?*anyopaque,
    out_id: *u32,
) c_int;
extern "c" fn IOPMAssertionRelease(assertion_id: u32) c_int;

/// IOKit/IOPMLib.h:433 — assertion ON. OFF는 0이지만 OFF로 create하는 의미가 없어 미정의.
const kIOPMAssertionLevelOn: u32 = 255;

const linux_power_save = if (is_linux) struct {
    extern "c" fn XOpenDisplay(display_name: ?[*:0]const u8) callconv(.c) ?*anyopaque;
    extern "c" fn XCloseDisplay(display: ?*anyopaque) callconv(.c) c_int;
    extern "c" fn XScreenSaverSuspend(display: ?*anyopaque, should_suspend: c_int) callconv(.c) void;
} else struct {};

const win_power_request = if (is_windows) struct {
    const w = std.os.windows;

    const DETAILED_REASON_CONTEXT = extern struct {
        LocalizedReasonModule: ?*anyopaque,
        LocalizedReasonId: u32,
        ReasonStringCount: u32,
        ReasonStrings: ?*?[*:0]u16,
    };

    const REASON_CONTEXT = extern struct {
        Version: u32,
        Flags: u32,
        Reason: extern union {
            Detailed: DETAILED_REASON_CONTEXT,
            SimpleReasonString: ?[*:0]u16,
        },
    };

    extern "kernel32" fn PowerCreateRequest(Context: *const REASON_CONTEXT) callconv(.winapi) w.HANDLE;
    extern "kernel32" fn PowerSetRequest(PowerRequest: w.HANDLE, RequestType: c_int) callconv(.winapi) w.BOOL;
    extern "kernel32" fn PowerClearRequest(PowerRequest: w.HANDLE, RequestType: c_int) callconv(.winapi) w.BOOL;

    const POWER_REQUEST_CONTEXT_VERSION: u32 = 0;
    const POWER_REQUEST_CONTEXT_SIMPLE_STRING: u32 = 0x1;
    const PowerRequestDisplayRequired: c_int = 0;
    const PowerRequestSystemRequired: c_int = 1;
} else struct {};

const max_power_save_blockers = 64;

const PowerSaveBlockerEntry = struct {
    id: u32 = 0,
    typ: PowerSaveBlockerType = .prevent_display_sleep,
    handle_bits: usize = 0,
};

var power_save_lock_flag: std.atomic.Value(bool) = .init(false);
var power_save_next_id: u32 = 1;
var power_save_entries = [_]PowerSaveBlockerEntry{.{}} ** max_power_save_blockers;
var linux_power_save_display: ?*anyopaque = null;

fn powerSaveLock() void {
    while (power_save_lock_flag.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
        std.atomic.spinLoopHint();
    }
}

fn powerSaveUnlock() void {
    power_save_lock_flag.store(false, .release);
}

fn powerSaveEntryExistsLocked(id: u32) bool {
    for (power_save_entries) |entry| {
        if (entry.id == id) return true;
    }
    return false;
}

fn powerSaveAnyActiveLocked() bool {
    for (power_save_entries) |entry| {
        if (entry.id != 0) return true;
    }
    return false;
}

fn powerSaveFreeSlotLocked() ?usize {
    for (&power_save_entries, 0..) |*entry, i| {
        if (entry.id == 0) return i;
    }
    return null;
}

fn powerSaveAllocIdLocked() u32 {
    var candidate = power_save_next_id;
    var attempts: usize = 0;
    while (attempts < max_power_save_blockers + 1) : (attempts += 1) {
        if (candidate == 0) candidate = 1;
        if (!powerSaveEntryExistsLocked(candidate)) {
            power_save_next_id = candidate +% 1;
            if (power_save_next_id == 0) power_save_next_id = 1;
            return candidate;
        }
        candidate +%= 1;
    }
    return 0;
}

fn powerSaveInsertLocked(typ: PowerSaveBlockerType, handle_bits: usize) u32 {
    const slot = powerSaveFreeSlotLocked() orelse return 0;
    const id = powerSaveAllocIdLocked();
    if (id == 0) return 0;
    power_save_entries[slot] = .{ .id = id, .typ = typ, .handle_bits = handle_bits };
    return id;
}

fn powerSaveRemoveLocked(id: u32) ?PowerSaveBlockerEntry {
    if (id == 0) return null;
    for (&power_save_entries) |*entry| {
        if (entry.id == id) {
            const removed = entry.*;
            entry.* = .{};
            return removed;
        }
    }
    return null;
}

fn linuxPowerSaveApplyLocked(active: bool) bool {
    if (!comptime is_linux) return false;
    if (active) {
        if (linux_power_save_display == null) {
            linux_power_save_display = linux_power_save.XOpenDisplay(null) orelse return false;
        }
        linux_power_save.XScreenSaverSuspend(linux_power_save_display, 1);
        return true;
    }

    if (linux_power_save_display) |display| {
        linux_power_save.XScreenSaverSuspend(display, 0);
        _ = linux_power_save.XCloseDisplay(display);
        linux_power_save_display = null;
    }
    return true;
}

fn windowsPowerSaveStart(typ: PowerSaveBlockerType) u32 {
    if (!comptime is_windows) return 0;

    var reason_buf: [64]u16 = undefined;
    const reason_len = std.unicode.utf8ToUtf16Le(reason_buf[0 .. reason_buf.len - 1], "Suji powerSaveBlocker") catch return 0;
    reason_buf[reason_len] = 0;
    const reason = reason_buf[0..reason_len :0];
    var context = win_power_request.REASON_CONTEXT{
        .Version = win_power_request.POWER_REQUEST_CONTEXT_VERSION,
        .Flags = win_power_request.POWER_REQUEST_CONTEXT_SIMPLE_STRING,
        .Reason = .{ .SimpleReasonString = reason.ptr },
    };

    const handle = win_power_request.PowerCreateRequest(&context);
    if (@intFromPtr(handle) == 0 or handle == std.os.windows.INVALID_HANDLE_VALUE) return 0;

    const system_ok = win_power_request.PowerSetRequest(handle, win_power_request.PowerRequestSystemRequired).toBool();
    const display_ok = typ != .prevent_display_sleep or win_power_request.PowerSetRequest(handle, win_power_request.PowerRequestDisplayRequired).toBool();
    if (!system_ok or !display_ok) {
        if (display_ok and typ == .prevent_display_sleep) {
            _ = win_power_request.PowerClearRequest(handle, win_power_request.PowerRequestDisplayRequired);
        }
        if (system_ok) {
            _ = win_power_request.PowerClearRequest(handle, win_power_request.PowerRequestSystemRequired);
        }
        std.os.windows.CloseHandle(handle);
        return 0;
    }

    powerSaveLock();
    defer powerSaveUnlock();
    const id = powerSaveInsertLocked(typ, @intFromPtr(handle));
    if (id == 0) {
        if (typ == .prevent_display_sleep) {
            _ = win_power_request.PowerClearRequest(handle, win_power_request.PowerRequestDisplayRequired);
        }
        _ = win_power_request.PowerClearRequest(handle, win_power_request.PowerRequestSystemRequired);
        std.os.windows.CloseHandle(handle);
    }
    return id;
}

fn windowsPowerSaveStop(id: u32) bool {
    if (!comptime is_windows) return false;

    powerSaveLock();
    const removed = powerSaveRemoveLocked(id);
    powerSaveUnlock();

    const entry = removed orelse return false;
    const handle: std.os.windows.HANDLE = @ptrFromInt(entry.handle_bits);
    var ok = true;
    if (entry.typ == .prevent_display_sleep) {
        ok = win_power_request.PowerClearRequest(handle, win_power_request.PowerRequestDisplayRequired).toBool() and ok;
    }
    ok = win_power_request.PowerClearRequest(handle, win_power_request.PowerRequestSystemRequired).toBool() and ok;
    std.os.windows.CloseHandle(handle);
    return ok;
}

/// powerSaveBlocker 시작 — 0이면 실패 (id는 1+).
pub fn powerSaveBlockerStart(t: PowerSaveBlockerType) u32 {
    if (comptime is_linux) {
        powerSaveLock();
        defer powerSaveUnlock();
        const was_active = powerSaveAnyActiveLocked();
        if (!was_active and !linuxPowerSaveApplyLocked(true)) return 0;
        const id = powerSaveInsertLocked(t, 0);
        if (id == 0 and !was_active) _ = linuxPowerSaveApplyLocked(false);
        return id;
    }

    if (comptime is_windows) return windowsPowerSaveStart(t);

    if (!comptime is_macos) return 0;
    const type_str: [*:0]const u8 = switch (t) {
        .prevent_app_suspension => "PreventUserIdleSystemSleep",
        .prevent_display_sleep => "PreventUserIdleDisplaySleep",
    };
    const ns_type = nsStringFromCstr(type_str) orelse return 0;
    const ns_name = nsStringFromCstr("Suji powerSaveBlocker") orelse return 0;
    var id: u32 = 0;
    const r = IOPMAssertionCreateWithName(ns_type, kIOPMAssertionLevelOn, ns_name, &id);
    return if (r == 0) id else 0;
}

pub fn powerSaveBlockerStop(id: u32) bool {
    if (comptime is_linux) {
        powerSaveLock();
        defer powerSaveUnlock();
        _ = powerSaveRemoveLocked(id) orelse return false;
        if (!powerSaveAnyActiveLocked()) return linuxPowerSaveApplyLocked(false);
        return true;
    }

    if (comptime is_windows) return windowsPowerSaveStop(id);

    if (!comptime is_macos) return false;
    if (id == 0) return false;
    return IOPMAssertionRelease(id) == 0;
}
