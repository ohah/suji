//! Windows Shell_NotifyIcon Tray backend.

const std = @import("std");
const builtin = @import("builtin");
const tray_types = @import("cef_tray_types.zig");
const win_pump = @import("cef_win_pump.zig").win_pump;

const TrayMenuItem = tray_types.TrayMenuItem;

pub const win_tray = if (builtin.os.tag == .windows) struct {
    pub const NIM_ADD: u32 = 0;
    pub const NIM_MODIFY: u32 = 1;
    pub const NIM_DELETE: u32 = 2;
    const NIF_MESSAGE: u32 = 0x01;
    const NIF_ICON: u32 = 0x02;
    const NIF_TIP: u32 = 0x04;
    const WM_TRAY_CALLBACK: u32 = 0x0400 + 1; // win_pump.WM_TRAY 와 동일

    pub const NOTIFYICONDATAW = extern struct {
        cbSize: u32 = 0,
        hWnd: ?*anyopaque = null,
        uID: u32 = 0,
        uFlags: u32 = 0,
        uCallbackMessage: u32 = 0,
        hIcon: ?*anyopaque = null,
        szTip: [128]u16 = std.mem.zeroes([128]u16),
        dwState: u32 = 0,
        dwStateMask: u32 = 0,
        szInfo: [256]u16 = std.mem.zeroes([256]u16),
        uVersion: u32 = 0,
        szInfoTitle: [64]u16 = std.mem.zeroes([64]u16),
        dwInfoFlags: u32 = 0,
        guidItem: [16]u8 = std.mem.zeroes([16]u8),
        hBalloonIcon: ?*anyopaque = null,
    };

    pub extern "shell32" fn Shell_NotifyIconW(dwMessage: u32, lpData: *NOTIFYICONDATAW) callconv(.winapi) i32;
    extern "user32" fn LoadIconW(hInstance: ?*anyopaque, lpIconName: usize) callconv(.winapi) ?*anyopaque;
    const IDI_APPLICATION: usize = 32512;

    /// id 별 entry — pump hwnd 가 모든 콜백을 받으므로 hwnd 동일. hmenu 는
    /// 옵션(setMenu 호출 후 set, destroyIcon/setMenu rebuild 시 DestroyMenu).
    pub const Entry = struct {
        used: bool = false,
        id: u32 = 0,
        hwnd: ?*anyopaque = null,
        hmenu: ?*anyopaque = null,
    };
    pub var entries: [16]Entry = [_]Entry{.{}} ** 16;
    var next_id: u32 = 1;

    pub fn createIcon(tooltip: []const u8, icon_path: []const u8) u32 {
        _ = icon_path; // Windows tray iconPath parity is intentionally deferred.
        const hwnd = win_pump.pumpHwnd() orelse return 0;
        var slot_idx: usize = 0;
        var found = false;
        for (&entries, 0..) |*e, i| {
            if (!e.used) {
                slot_idx = i;
                found = true;
                break;
            }
        }
        if (!found) return 0;

        var nid: NOTIFYICONDATAW = .{};
        nid.cbSize = @sizeOf(NOTIFYICONDATAW);
        nid.hWnd = hwnd;
        nid.uID = next_id;
        nid.uFlags = NIF_ICON | NIF_TIP | NIF_MESSAGE;
        nid.uCallbackMessage = WM_TRAY_CALLBACK;
        nid.hIcon = LoadIconW(null, IDI_APPLICATION);
        if (tooltip.len > 0) {
            const max_tip = nid.szTip.len - 1;
            const src = if (tooltip.len > max_tip) tooltip[0..max_tip] else tooltip;
            _ = std.unicode.utf8ToUtf16Le(nid.szTip[0..max_tip], src) catch {};
        }
        if (Shell_NotifyIconW(NIM_ADD, &nid) == 0) return 0;
        const id = next_id;
        next_id += 1;
        entries[slot_idx] = .{ .used = true, .id = id, .hwnd = hwnd };
        return id;
    }

    pub fn destroyIcon(tray_id: u32) bool {
        for (&entries) |*e| {
            if (e.used and e.id == tray_id) {
                var nid: NOTIFYICONDATAW = .{};
                nid.cbSize = @sizeOf(NOTIFYICONDATAW);
                nid.hWnd = e.hwnd;
                nid.uID = tray_id;
                _ = Shell_NotifyIconW(NIM_DELETE, &nid);
                // hmenu 가 있으면 pump 스레드에서 DestroyMenu (메뉴 lifecycle 격리).
                if (e.hmenu) |hm| {
                    _ = win_pump.submitSync(.{ .kind = @intFromEnum(win_pump.ReqKind.tray_destroy_menu), .hmenu = hm });
                }
                win_pump.clearMenuIdsForTray(tray_id);
                e.* = .{};
                return true;
            }
        }
        return false;
    }

    /// pump 스레드에서 안전하게 호출 가능 — submitSync 재진입 없이 직접 DestroyMenu.
    /// NIN_BALLOONTIMEOUT 같이 WndProc 안에서 호출되는 경로 전용.
    pub fn destroyIconFromPumpThread(tray_id: u32) bool {
        for (&entries) |*e| {
            if (e.used and e.id == tray_id) {
                var nid: NOTIFYICONDATAW = .{};
                nid.cbSize = @sizeOf(NOTIFYICONDATAW);
                nid.hWnd = e.hwnd;
                nid.uID = tray_id;
                _ = Shell_NotifyIconW(NIM_DELETE, &nid);
                if (e.hmenu) |hm| _ = win_pump.DestroyMenu(hm);
                win_pump.clearMenuIdsForTray(tray_id);
                e.* = .{};
                return true;
            }
        }
        return false;
    }

    /// caller (main thread) 가 호출 → pump 스레드로 proxy. pump executeReq 가
    /// applyTooltipOnPump 호출.
    pub fn setTooltip(tray_id: u32, tooltip: []const u8) bool {
        const rc = win_pump.submitSync(.{
            .kind = @intFromEnum(win_pump.ReqKind.tray_set_tooltip),
            .tray_id = tray_id,
            .ptr = if (tooltip.len > 0) @ptrCast(@constCast(tooltip.ptr)) else null,
            .len = tooltip.len,
        });
        return rc != 0;
    }

    pub fn applyTooltipOnPump(tray_id: u32, ptr: ?*anyopaque, len: usize) bool {
        for (&entries) |*e| {
            if (e.used and e.id == tray_id) {
                var nid: NOTIFYICONDATAW = .{};
                nid.cbSize = @sizeOf(NOTIFYICONDATAW);
                nid.hWnd = e.hwnd;
                nid.uID = tray_id;
                nid.uFlags = NIF_TIP;
                if (ptr != null and len > 0) {
                    const max_tip = nid.szTip.len - 1;
                    const slice: []const u8 = @as([*]const u8, @ptrCast(ptr.?))[0..len];
                    const src = if (slice.len > max_tip) slice[0..max_tip] else slice;
                    _ = std.unicode.utf8ToUtf16Le(nid.szTip[0..max_tip], src) catch {};
                }
                return Shell_NotifyIconW(NIM_MODIFY, &nid) != 0;
            }
        }
        return false;
    }

    /// caller 가 메뉴 items 로 HMENU 빌드 + click_id 매핑 등록 후, pump 가 entry.hmenu swap.
    /// 기존 hmenu 는 pump 가 DestroyMenu.
    pub fn setMenu(tray_id: u32, items: []const TrayMenuItem) bool {
        win_pump.ensureRunning();
        // 기존 click_id 모두 해제 (rebuild 시 새 id 재할당).
        win_pump.clearMenuIdsForTray(tray_id);
        const hmenu = win_pump.CreatePopupMenu() orelse return false;
        for (items) |it| switch (it) {
            .separator => {
                _ = win_pump.AppendMenuW(hmenu, win_pump.MF_SEPARATOR, 0, null);
            },
            .item => |entry| appendMenuClickable(hmenu, tray_id, entry.label, entry.click, entry.enabled, false),
            .checkbox => |entry| appendMenuClickable(hmenu, tray_id, entry.label, entry.click, entry.enabled, entry.checked),
            .submenu => {},
        };
        const rc = win_pump.submitSync(.{
            .kind = @intFromEnum(win_pump.ReqKind.tray_set_menu),
            .tray_id = tray_id,
            .hmenu = hmenu,
        });
        if (rc == 0) {
            _ = win_pump.DestroyMenu(hmenu);
            return false;
        }
        return true;
    }

    pub fn applyMenuOnPump(tray_id: u32, new_hmenu: ?*anyopaque) bool {
        for (&entries) |*e| {
            if (e.used and e.id == tray_id) {
                if (e.hmenu) |old| _ = win_pump.DestroyMenu(old);
                e.hmenu = new_hmenu;
                return true;
            }
        }
        return false;
    }

    fn utf8ToZ16Local(buf: []u16, src: []const u8) ?[*:0]const u16 {
        const len = std.unicode.calcUtf16LeLen(src) catch return null;
        if (len + 1 > buf.len) return null;
        const written = std.unicode.utf8ToUtf16Le(buf[0..len], src) catch return null;
        buf[written] = 0;
        return @ptrCast(buf[0..written :0].ptr);
    }

    fn appendMenuClickable(hmenu: ?*anyopaque, tray_id: u32, label: []const u8, click: []const u8, enabled: bool, checked: bool) void {
        const cmd_id = win_pump.assignMenuId(tray_id, click) orelse return;
        var label_buf: [256]u16 = undefined;
        const label_z = utf8ToZ16Local(&label_buf, label) orelse return;
        var flags = win_pump.MF_STRING;
        if (!enabled) flags |= win_pump.MF_GRAYED;
        if (checked) flags |= win_pump.MF_CHECKED;
        _ = win_pump.AppendMenuW(hmenu, flags, @as(usize, cmd_id), label_z);
    }
} else struct {};
