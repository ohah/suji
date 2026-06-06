const std = @import("std");

pub const DisplayBounds = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

pub fn containsPoint(display: DisplayBounds, x: f64, y: f64) bool {
    const left: f64 = @floatFromInt(display.x);
    const top: f64 = @floatFromInt(display.y);
    const right = left + @as(f64, @floatFromInt(display.width));
    const bottom = top + @as(f64, @floatFromInt(display.height));
    return x >= left and x < right and y >= top and y < bottom;
}

pub fn containedDisplayIndex(displays: []const DisplayBounds, x: f64, y: f64) i32 {
    for (displays, 0..) |display, idx| {
        if (containsPoint(display, x, y)) return @intCast(idx);
    }
    return -1;
}

/// rect 와 display 의 교집합 면적(px²). 겹치지 않으면 0.
pub fn intersectionArea(d: DisplayBounds, rx: f64, ry: f64, rw: f64, rh: f64) f64 {
    const dl: f64 = @floatFromInt(d.x);
    const dt: f64 = @floatFromInt(d.y);
    const dr = dl + @as(f64, @floatFromInt(d.width));
    const db = dt + @as(f64, @floatFromInt(d.height));
    const iw = @min(dr, rx + rw) - @max(dl, rx);
    const ih = @min(db, ry + rh) - @max(dt, ry);
    if (iw <= 0 or ih <= 0) return 0;
    return iw * ih;
}

fn centerDist2(d: DisplayBounds, cx: f64, cy: f64) f64 {
    const dcx = @as(f64, @floatFromInt(d.x)) + @as(f64, @floatFromInt(d.width)) / 2;
    const dcy = @as(f64, @floatFromInt(d.y)) + @as(f64, @floatFromInt(d.height)) / 2;
    return (dcx - cx) * (dcx - cx) + (dcy - cy) * (dcy - cy);
}

/// Electron `screen.getDisplayMatching` — rect 와 겹침 면적이 최대인 display index.
/// 겹치는 display 가 없으면 rect 중심에 가장 가까운 display. 빈 목록이면 -1.
/// 전 플랫폼(macOS/Windows/Linux) 공유 — 각 플랫폼은 DisplayBounds 열거만 담당.
pub fn matchingDisplayIndex(displays: []const DisplayBounds, rx: f64, ry: f64, rw: f64, rh: f64) i32 {
    if (displays.len == 0) return -1;
    var best: i32 = 0;
    var best_area: f64 = -1;
    for (displays, 0..) |d, idx| {
        const a = intersectionArea(d, rx, ry, rw, rh);
        if (a > best_area) {
            best_area = a;
            best = @intCast(idx);
        }
    }
    if (best_area > 0) return best;
    // 겹침 없음 → rect 중심 최근접.
    const cx = rx + rw / 2;
    const cy = ry + rh / 2;
    var nearest: i32 = 0;
    var nearest_d2: f64 = centerDist2(displays[0], cx, cy);
    for (displays, 0..) |d, idx| {
        const d2 = centerDist2(d, cx, cy);
        if (d2 < nearest_d2) {
            nearest_d2 = d2;
            nearest = @intCast(idx);
        }
    }
    return nearest;
}

test "containsPoint uses right/bottom exclusive display bounds" {
    const display: DisplayBounds = .{ .x = 0, .y = 0, .width = 100, .height = 80 };
    try std.testing.expect(containsPoint(display, 0, 0));
    try std.testing.expect(containsPoint(display, 99.9, 79.9));
    try std.testing.expect(!containsPoint(display, 100, 40));
    try std.testing.expect(!containsPoint(display, 40, 80));
}

test "containsPoint handles non-zero display origins" {
    const display: DisplayBounds = .{ .x = -320, .y = 120, .width = 320, .height = 200 };
    try std.testing.expect(containsPoint(display, -320, 120));
    try std.testing.expect(containsPoint(display, -1, 319.9));
    try std.testing.expect(!containsPoint(display, 0, 200));
    try std.testing.expect(!containsPoint(display, -100, 320));
}

test "containedDisplayIndex returns first containing display" {
    const displays = [_]DisplayBounds{
        .{ .x = 0, .y = 0, .width = 100, .height = 80 },
        .{ .x = 100, .y = 0, .width = 120, .height = 80 },
    };
    try std.testing.expectEqual(@as(i32, 0), containedDisplayIndex(&displays, 50, 40));
    try std.testing.expectEqual(@as(i32, 1), containedDisplayIndex(&displays, 150, 40));
}

test "containedDisplayIndex returns -1 outside all displays" {
    const displays = [_]DisplayBounds{
        .{ .x = 0, .y = 0, .width = 100, .height = 80 },
    };
    try std.testing.expectEqual(@as(i32, -1), containedDisplayIndex(&displays, -1, 0));
    try std.testing.expectEqual(@as(i32, -1), containedDisplayIndex(&displays, 0, -1));
    try std.testing.expectEqual(@as(i32, -1), containedDisplayIndex(&displays, 100, 0));
}

test "matchingDisplayIndex picks max-overlap, falls back to center-nearest" {
    // 듀얼모니터: 좌 0..1920, 우 1920..3840.
    const dual = [_]DisplayBounds{
        .{ .x = 0, .y = 0, .width = 1920, .height = 1080 },
        .{ .x = 1920, .y = 0, .width = 1920, .height = 1080 },
    };
    // 우측 안의 창 → 1.
    try std.testing.expectEqual(@as(i32, 1), matchingDisplayIndex(&dual, 2000, 100, 400, 300));
    // 좌측 안의 창 → 0.
    try std.testing.expectEqual(@as(i32, 0), matchingDisplayIndex(&dual, 100, 100, 400, 300));
    // 경계 1800..2200: left 겹침 120px, right 280px → 1.
    try std.testing.expectEqual(@as(i32, 1), matchingDisplayIndex(&dual, 1800, 100, 400, 300));
    // 모든 모니터 밖(중심 5050) → right(중심 2880)이 left(960)보다 가까움 → 1.
    try std.testing.expectEqual(@as(i32, 1), matchingDisplayIndex(&dual, 5000, 100, 100, 100));
    // 빈 목록 → -1.
    try std.testing.expectEqual(@as(i32, -1), matchingDisplayIndex(&.{}, 0, 0, 1, 1));
}

test "intersectionArea zero when edges touch (exclusive overlap)" {
    const d: DisplayBounds = .{ .x = 0, .y = 0, .width = 100, .height = 100 };
    try std.testing.expectEqual(@as(f64, 0), intersectionArea(d, 100, 0, 50, 50)); // 우측 경계 접촉
    try std.testing.expectEqual(@as(f64, 2500), intersectionArea(d, 50, 50, 50, 50)); // 우하단 1/4
}
