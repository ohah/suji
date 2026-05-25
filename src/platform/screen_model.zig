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
