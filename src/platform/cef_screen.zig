//! Screen API — cef.zig 에서 분리(동작 무변경). Electron `screen`의
//! getAllDisplays/getCursorPoint/getDisplayNearestPoint 구현.
const std = @import("std");
const builtin = @import("builtin");
const linux_screen = @import("cef_screen_linux.zig");
const windows_screen = @import("cef_screen_windows.zig");
const screen_model = @import("screen_model.zig");
const cef = @import("cef.zig");

const is_macos = builtin.os.tag == .macos;
const is_linux = builtin.os.tag == .linux;

const objc = cef.objc;
const getClass = cef.getClass;
const msgSend = cef.msgSend;
const NSPoint = cef.NSPoint;
const NSRect = cef.NSRect;

// `screen.getAllDisplays` — 연결된 display의 frame/visibleFrame/scale.
// 결과는 JSON 배열로 직접 빌드.
// macOS: NSScreen, Linux: X11 screen, Windows: EnumDisplayMonitors.
// macOS arm64 ABI: 작은 struct(NSRect 32B)는 일반 objc_msgSend로 반환됨 — _stret 불필요.

/// out_buf에 `[{...},{...}]` JSON 배열을 빌드해 길이 반환.
fn writeEmptyJsonArray(out_buf: []u8) []const u8 {
    const empty = "[]";
    const n = @min(empty.len, out_buf.len);
    @memcpy(out_buf[0..n], empty[0..n]);
    return out_buf[0..n];
}

pub fn screenGetAllDisplays(out_buf: []u8) []const u8 {
    if (comptime builtin.os.tag == .windows) return windows_screen.getAllDisplays(out_buf);
    if (comptime is_linux) return linux_screen.getAllDisplays(out_buf);
    if (!comptime is_macos) return writeEmptyJsonArray(out_buf);
    var w = std.Io.Writer.fixed(out_buf);
    w.writeByte('[') catch return out_buf[0..1];

    const NSScreen = getClass("NSScreen") orelse {
        w.writeByte(']') catch {};
        return w.buffered();
    };
    const screens = msgSend(NSScreen, "screens") orelse {
        w.writeByte(']') catch {};
        return w.buffered();
    };
    const main_screen = msgSend(NSScreen, "mainScreen");

    const count_fn: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) usize = @ptrCast(&objc.objc_msgSend);
    const count = count_fn(screens, @ptrCast(objc.sel_registerName("count")));

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const obj_fn: *const fn (?*anyopaque, ?*anyopaque, usize) callconv(.c) ?*anyopaque = @ptrCast(&objc.objc_msgSend);
        const screen = obj_fn(screens, @ptrCast(objc.sel_registerName("objectAtIndex:")), i) orelse continue;

        const rect_fn: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) NSRect = @ptrCast(&objc.objc_msgSend);
        const f64_fn: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) f64 = @ptrCast(&objc.objc_msgSend);
        const frame = rect_fn(screen, @ptrCast(objc.sel_registerName("frame")));
        const visible = rect_fn(screen, @ptrCast(objc.sel_registerName("visibleFrame")));
        const scale = f64_fn(screen, @ptrCast(objc.sel_registerName("backingScaleFactor")));
        const is_primary = main_screen != null and screen == main_screen.?;

        if (i > 0) w.writeByte(',') catch return w.buffered();
        w.print(
            "{{\"index\":{d},\"isPrimary\":{},\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d},\"visibleX\":{d},\"visibleY\":{d},\"visibleWidth\":{d},\"visibleHeight\":{d},\"scaleFactor\":{d}}}",
            .{
                i,
                is_primary,
                @as(i64, @intFromFloat(frame.x)),
                @as(i64, @intFromFloat(frame.y)),
                @as(i64, @intFromFloat(frame.width)),
                @as(i64, @intFromFloat(frame.height)),
                @as(i64, @intFromFloat(visible.x)),
                @as(i64, @intFromFloat(visible.y)),
                @as(i64, @intFromFloat(visible.width)),
                @as(i64, @intFromFloat(visible.height)),
                scale,
            },
        ) catch return w.buffered();
    }
    w.writeByte(']') catch return w.buffered();
    return w.buffered();
}

/// 마우스 포인터 화면 좌표 (Electron `screen.getCursorScreenPoint`).
/// macOS는 bottom-up 좌표계 (NSEvent.mouseLocation) — y는 main display height에서 반전 필요할 수
/// 있음. caller가 필요 시 변환.
pub fn screenGetCursorPoint() NSPoint {
    if (comptime builtin.os.tag == .windows) {
        const p = windows_screen.cursorPoint();
        return .{ .x = p[0], .y = p[1] };
    }
    if (comptime is_linux) {
        const p = linux_screen.cursorPoint();
        return .{ .x = p[0], .y = p[1] };
    }
    if (!comptime is_macos) return .{ .x = 0, .y = 0 };
    const NSEvent = getClass("NSEvent") orelse return .{ .x = 0, .y = 0 };
    const f: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) NSPoint = @ptrCast(&objc.objc_msgSend);
    return f(NSEvent, @ptrCast(objc.sel_registerName("mouseLocation")));
}

/// 주어진 (x, y) 좌표에 가장 가까운 display index 반환 (Electron `screen.getDisplayNearestPoint`).
/// 1차 단순 접근: point가 frame에 contained된 첫 display, 없으면 -1 반환.
/// caller가 -1이면 mainScreen으로 fallback. y는 macOS bottom-up 좌표.
pub fn screenGetDisplayNearestPoint(x: f64, y: f64) i32 {
    if (comptime builtin.os.tag == .windows) return windows_screen.displayNearestPoint(x, y);
    if (comptime is_linux) return linux_screen.displayNearestPoint(x, y);
    if (!comptime is_macos) return -1;
    const NSScreen = getClass("NSScreen") orelse return -1;
    const screens = msgSend(NSScreen, "screens") orelse return -1;
    const count_fn: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) usize = @ptrCast(&objc.objc_msgSend);
    const count = count_fn(screens, @ptrCast(objc.sel_registerName("count")));

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const obj_fn: *const fn (?*anyopaque, ?*anyopaque, usize) callconv(.c) ?*anyopaque = @ptrCast(&objc.objc_msgSend);
        const screen = obj_fn(screens, @ptrCast(objc.sel_registerName("objectAtIndex:")), i) orelse continue;
        const rect_fn: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) NSRect = @ptrCast(&objc.objc_msgSend);
        const frame = rect_fn(screen, @ptrCast(objc.sel_registerName("frame")));
        if (x >= frame.x and x < frame.x + frame.width and
            y >= frame.y and y < frame.y + frame.height)
        {
            return @intCast(i);
        }
    }
    return -1;
}

/// rect 와 겹침 면적이 최대인 display index (Electron `screen.getDisplayMatching`).
/// 겹침 없으면 중심 최근접. 전 플랫폼 공유 screen_model.matchingDisplayIndex 사용 —
/// 각 플랫폼은 DisplayBounds 열거만(getAllDisplays 와 동일 좌표/순서 → index 일치).
pub fn screenGetDisplayMatching(x: f64, y: f64, w: f64, h: f64) i32 {
    if (comptime builtin.os.tag == .windows) return windows_screen.displayMatching(x, y, w, h);
    if (comptime is_linux) return linux_screen.displayMatching(x, y, w, h);
    if (!comptime is_macos) return -1;
    const NSScreen = getClass("NSScreen") orelse return -1;
    const screens = msgSend(NSScreen, "screens") orelse return -1;
    const count_fn: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) usize = @ptrCast(&objc.objc_msgSend);
    const count = count_fn(screens, @ptrCast(objc.sel_registerName("count")));

    // 캡은 Windows/Linux(32) 와 동일 — getAllDisplays(버퍼 ~34개 수용)와 같은 수준이라
    // 현실적 모니터 수에서 잘림 없이 index 정합 유지.
    var displays: [32]screen_model.DisplayBounds = undefined;
    var len: usize = 0;
    var i: usize = 0;
    while (i < count and len < displays.len) : (i += 1) {
        const obj_fn: *const fn (?*anyopaque, ?*anyopaque, usize) callconv(.c) ?*anyopaque = @ptrCast(&objc.objc_msgSend);
        const screen = obj_fn(screens, @ptrCast(objc.sel_registerName("objectAtIndex:")), i) orelse continue;
        const rect_fn: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) NSRect = @ptrCast(&objc.objc_msgSend);
        const frame = rect_fn(screen, @ptrCast(objc.sel_registerName("frame")));
        displays[len] = .{
            .x = @intFromFloat(frame.x),
            .y = @intFromFloat(frame.y),
            .width = @intFromFloat(frame.width),
            .height = @intFromFloat(frame.height),
        };
        len += 1;
    }
    return screen_model.matchingDisplayIndex(displays[0..len], x, y, w, h);
}
