const std = @import("std");

pub const SourceId = struct {
    screen: bool,
    id: u32,
};

/// Parse Suji desktopCapturer source ids.
///
/// The public wire format is intentionally strict:
///   - screen:<displayId>:0
///   - window:<windowNumber>:0
///
/// The trailing zero is reserved for future thumbnail/index variants. Accepting
/// arbitrary suffixes would make malformed renderer input reach native capture.
pub fn parseSourceId(source_id: []const u8) ?SourceId {
    const c1 = std.mem.indexOfScalar(u8, source_id, ':') orelse return null;
    const kind = source_id[0..c1];
    const rest = source_id[c1 + 1 ..];
    const c2 = std.mem.indexOfScalar(u8, rest, ':') orelse return null;
    if (std.mem.indexOfScalar(u8, rest[c2 + 1 ..], ':') != null) return null;
    if (!std.mem.eql(u8, rest[c2 + 1 ..], "0")) return null;

    const raw_id = rest[0..c2];
    if (raw_id.len == 0) return null;
    const num = std.fmt.parseInt(u32, raw_id, 10) catch return null;
    if (std.mem.eql(u8, kind, "screen")) return .{ .screen = true, .id = num };
    if (std.mem.eql(u8, kind, "window")) return .{ .screen = false, .id = num };
    return null;
}

test "parseSourceId accepts documented screen/window ids" {
    const screen = parseSourceId("screen:123:0") orelse return error.ExpectedScreenSource;
    try std.testing.expect(screen.screen);
    try std.testing.expectEqual(@as(u32, 123), screen.id);

    const window = parseSourceId("window:456:0") orelse return error.ExpectedWindowSource;
    try std.testing.expect(!window.screen);
    try std.testing.expectEqual(@as(u32, 456), window.id);
}

test "parseSourceId rejects malformed or future-reserved suffixes" {
    inline for (.{
        "",
        "screen",
        "screen:",
        "screen::0",
        "screen:1",
        "screen:1:",
        "screen:1:1",
        "screen:1:0:extra",
        "window:1:999",
        "tab:1:0",
        "screen:-1:0",
        "screen:4294967296:0",
        "screen:notnum:0",
    }) |bad| {
        try std.testing.expect(parseSourceId(bad) == null);
    }
}
