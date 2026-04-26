const std = @import("std");

pub const DragRegion = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    draggable: bool,
};

pub fn contains(region: DragRegion, x: i32, y: i32) bool {
    return x >= region.x and
        y >= region.y and
        x < region.x + region.width and
        y < region.y + region.height;
}

/// Chromium/CEF reports both drag and no-drag rectangles. Later rectangles win
/// for overlapping areas, which lets no-drag controls carve holes out of a
/// draggable titlebar.
pub fn isPointDraggable(regions: []const DragRegion, x: i32, y: i32) bool {
    var result = false;
    var matched = false;
    for (regions) |region| {
        if (contains(region, x, y)) {
            result = region.draggable;
            matched = true;
        }
    }
    return matched and result;
}

test "isPointDraggable returns false without regions" {
    try std.testing.expect(!isPointDraggable(&.{}, 10, 10));
}

test "isPointDraggable accepts points inside draggable region" {
    const regions = [_]DragRegion{.{ .x = 0, .y = 0, .width = 100, .height = 32, .draggable = true }};
    try std.testing.expect(isPointDraggable(&regions, 20, 10));
    try std.testing.expect(!isPointDraggable(&regions, 100, 10));
    try std.testing.expect(!isPointDraggable(&regions, 20, 32));
}

test "isPointDraggable lets no-drag region override drag region" {
    const regions = [_]DragRegion{
        .{ .x = 0, .y = 0, .width = 200, .height = 40, .draggable = true },
        .{ .x = 160, .y = 4, .width = 32, .height = 28, .draggable = false },
    };
    try std.testing.expect(isPointDraggable(&regions, 20, 10));
    try std.testing.expect(!isPointDraggable(&regions, 170, 10));
}

test "isPointDraggable uses last matching region" {
    const regions = [_]DragRegion{
        .{ .x = 0, .y = 0, .width = 50, .height = 50, .draggable = false },
        .{ .x = 10, .y = 10, .width = 20, .height = 20, .draggable = true },
    };
    try std.testing.expect(isPointDraggable(&regions, 15, 15));
}
