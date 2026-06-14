//! Windows Win32 backend for Electron-compatible screen APIs.

const std = @import("std");
const builtin = @import("builtin");
const screen_model = @import("screen_model.zig");

const impl = if (builtin.os.tag == .windows) struct {
    const RECT = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
    const POINT = extern struct { x: i32, y: i32 };
    const MONITORINFO = extern struct {
        cbSize: u32 = @sizeOf(MONITORINFO),
        rcMonitor: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
        rcWork: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
        dwFlags: u32 = 0,
    };
    const MONITORINFOF_PRIMARY: u32 = 1;
    const MONITOR_DEFAULTTONULL: u32 = 0;

    extern "user32" fn EnumDisplayMonitors(
        hdc: ?*anyopaque,
        lprcClip: ?*RECT,
        lpfnEnum: *const fn (?*anyopaque, ?*anyopaque, *RECT, isize) callconv(.winapi) i32,
        dwData: isize,
    ) callconv(.winapi) i32;
    extern "user32" fn GetMonitorInfoW(hMonitor: ?*anyopaque, lpmi: *MONITORINFO) callconv(.winapi) i32;
    extern "user32" fn GetCursorPos(lpPoint: *POINT) callconv(.winapi) i32;
    extern "user32" fn MonitorFromPoint(pt: POINT, dwFlags: u32) callconv(.winapi) ?*anyopaque;
    extern "shcore" fn GetDpiForMonitor(hmon: ?*anyopaque, dpi_type: u32, dpi_x: *u32, dpi_y: *u32) callconv(.winapi) i32;

    /// MONITORINFO 한 entry 의 JSON 필드 (`{"index":0,"isPrimary":true,...}`) 를 writer 에 쓴다.
    fn writeDisplay(w: *std.Io.Writer, hmon: ?*anyopaque, index: usize) bool {
        var info: MONITORINFO = .{};
        if (GetMonitorInfoW(hmon, &info) == 0) return false;
        var dpi_x: u32 = 96;
        var dpi_y: u32 = 96;
        _ = GetDpiForMonitor(hmon, 0, &dpi_x, &dpi_y); // 0 = MDT_EFFECTIVE_DPI
        const scale: f64 = @as(f64, @floatFromInt(dpi_x)) / 96.0;
        const is_primary = (info.dwFlags & MONITORINFOF_PRIMARY) != 0;
        w.print(
            "{{\"index\":{d},\"isPrimary\":{},\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d},\"visibleX\":{d},\"visibleY\":{d},\"visibleWidth\":{d},\"visibleHeight\":{d},\"scaleFactor\":{d}}}",
            .{
                index,                                      is_primary,
                info.rcMonitor.left,                        info.rcMonitor.top,
                info.rcMonitor.right - info.rcMonitor.left, info.rcMonitor.bottom - info.rcMonitor.top,
                info.rcWork.left,                           info.rcWork.top,
                info.rcWork.right - info.rcWork.left,       info.rcWork.bottom - info.rcWork.top,
                scale,
            },
        ) catch return false;
        return true;
    }

    const EnumCtx = struct {
        writer: *std.Io.Writer,
        index: usize = 0,
    };

    fn enumProc(hmon: ?*anyopaque, _: ?*anyopaque, _: *RECT, lparam: isize) callconv(.winapi) i32 {
        const ctx: *EnumCtx = @ptrFromInt(@as(usize, @intCast(lparam)));
        if (ctx.index > 0) ctx.writer.writeByte(',') catch return 0;
        if (!writeDisplay(ctx.writer, hmon, ctx.index)) return 0;
        ctx.index += 1;
        return 1;
    }

    pub fn getAllDisplays(out_buf: []u8) []const u8 {
        var w: std.Io.Writer = .fixed(out_buf);
        w.writeByte('[') catch return out_buf[0..1];
        var ctx: EnumCtx = .{ .writer = &w };
        _ = EnumDisplayMonitors(null, null, &enumProc, @intCast(@intFromPtr(&ctx)));
        w.writeByte(']') catch return w.buffered();
        return w.buffered();
    }

    pub fn cursorPoint() [2]f64 {
        var p: POINT = .{ .x = 0, .y = 0 };
        if (GetCursorPos(&p) == 0) return .{ 0, 0 };
        return .{ @floatFromInt(p.x), @floatFromInt(p.y) };
    }

    /// 연결된 모니터 수 (EnumDisplayMonitors). screen 변경 이벤트의 count-diff 용.
    pub fn displayCount() i32 {
        const CountCtx = struct { n: i32 = 0 };
        const proc = struct {
            fn cb(_: ?*anyopaque, _: ?*anyopaque, _: *RECT, lp: isize) callconv(.winapi) i32 {
                const ctx: *CountCtx = @ptrFromInt(@as(usize, @intCast(lp)));
                ctx.n += 1;
                return 1;
            }
        }.cb;
        var ctx: CountCtx = .{};
        _ = EnumDisplayMonitors(null, null, &proc, @intCast(@intFromPtr(&ctx)));
        return ctx.n;
    }

    pub fn displayNearestPoint(x: f64, y: f64) i32 {
        const p: POINT = .{ .x = @intFromFloat(x), .y = @intFromFloat(y) };
        // macOS `screenGetDisplayNearestPoint` 는 contained-only (못 찾으면 -1).
        // Win32 MONITOR_DEFAULTTONULL 도 동일 시멘틱.
        const hmon = MonitorFromPoint(p, MONITOR_DEFAULTTONULL) orelse return -1;
        const FindCtx = struct {
            target: ?*anyopaque,
            index: i32 = -1,
            iter: i32 = 0,
        };
        const find_cb = struct {
            fn cb(h: ?*anyopaque, _: ?*anyopaque, _: *RECT, lp: isize) callconv(.winapi) i32 {
                const ctx: *FindCtx = @ptrFromInt(@as(usize, @intCast(lp)));
                if (h == ctx.target) {
                    ctx.index = ctx.iter;
                    return 0;
                }
                ctx.iter += 1;
                return 1;
            }
        }.cb;
        var ctx: FindCtx = .{ .target = hmon };
        _ = EnumDisplayMonitors(null, null, &find_cb, @intCast(@intFromPtr(&ctx)));
        return ctx.index;
    }

    const BoundsCtx = struct {
        list: *[32]screen_model.DisplayBounds,
        len: usize = 0,
    };
    fn boundsEnumProc(hmon: ?*anyopaque, _: ?*anyopaque, _: *RECT, lparam: isize) callconv(.winapi) i32 {
        const ctx: *BoundsCtx = @ptrFromInt(@as(usize, @intCast(lparam)));
        if (ctx.len >= ctx.list.len) return 0;
        var info: MONITORINFO = .{};
        // getAllDisplays 의 enumProc 는 writeDisplay 실패(GetMonitorInfoW==0) 시 0(중단)
        // 반환 → 동일하게 중단해야 두 열거가 같은 부분집합/순서 = index 정합.
        if (GetMonitorInfoW(hmon, &info) == 0) return 0;
        ctx.list[ctx.len] = .{
            .x = info.rcMonitor.left,
            .y = info.rcMonitor.top,
            .width = info.rcMonitor.right - info.rcMonitor.left,
            .height = info.rcMonitor.bottom - info.rcMonitor.top,
        };
        ctx.len += 1;
        return 1;
    }

    // getAllDisplays 와 동일한 EnumDisplayMonitors 순서로 DisplayBounds 열거 →
    // 공유 screen_model.matchingDisplayIndex (index 가 getAllDisplays 와 일치).
    pub fn displayMatching(x: f64, y: f64, w: f64, h: f64) i32 {
        var list: [32]screen_model.DisplayBounds = undefined;
        var ctx: BoundsCtx = .{ .list = &list };
        _ = EnumDisplayMonitors(null, null, &boundsEnumProc, @intCast(@intFromPtr(&ctx)));
        return screen_model.matchingDisplayIndex(list[0..ctx.len], x, y, w, h);
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

    pub fn displayCount() i32 {
        return 0;
    }
};

pub const getAllDisplays = impl.getAllDisplays;
pub const cursorPoint = impl.cursorPoint;
pub const displayNearestPoint = impl.displayNearestPoint;
pub const displayMatching = impl.displayMatching;
pub const displayCount = impl.displayCount;
