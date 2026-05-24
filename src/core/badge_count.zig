const std = @import("std");

pub fn countFromWire(value: ?i64) u32 {
    const n = value orelse 0;
    if (n <= 0) return 0;
    if (n > std.math.maxInt(u32)) return std.math.maxInt(u32);
    return @intCast(n);
}

pub fn countFromLabel(label: []const u8) u32 {
    if (label.len == 0) return 0;
    return std.fmt.parseInt(u32, label, 10) catch 0;
}

pub fn labelForCount(count: u32, buf: []u8) ?[]const u8 {
    if (count == 0) return "";
    return std.fmt.bufPrint(buf, "{d}", .{count}) catch null;
}

test "countFromWire clamps missing, negative, and overflow values" {
    try std.testing.expectEqual(@as(u32, 0), countFromWire(null));
    try std.testing.expectEqual(@as(u32, 0), countFromWire(-1));
    try std.testing.expectEqual(@as(u32, 7), countFromWire(7));
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), countFromWire(std.math.maxInt(i64)));
}

test "countFromLabel parses numeric dock labels only" {
    try std.testing.expectEqual(@as(u32, 0), countFromLabel(""));
    try std.testing.expectEqual(@as(u32, 42), countFromLabel("42"));
    try std.testing.expectEqual(@as(u32, 0), countFromLabel("a42"));
}

test "labelForCount converts zero to clear label" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("", labelForCount(0, &buf).?);
    try std.testing.expectEqualStrings("12", labelForCount(12, &buf).?);
}
