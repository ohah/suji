const std = @import("std");

pub fn copyToSentinel(buf: []u8, value: []const u8) ?[:0]u8 {
    if (value.len >= buf.len) return null;
    if (std.mem.indexOfScalar(u8, value, 0) != null) return null;
    @memcpy(buf[0..value.len], value);
    buf[value.len] = 0;
    return buf[0..value.len :0];
}

pub fn buildTargetUtf8(buf: []u8, service: []const u8, account: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(
        buf,
        "suji.safeStorage/{d}:{s}/{d}:{s}",
        .{ service.len, service, account.len, account },
    ) catch null;
}

pub fn buildTargetUtf16(buf: []u16, service: []const u8, account: []const u8) ?[:0]u16 {
    if (buf.len == 0) return null;
    var utf8_buf: [1024]u8 = undefined;
    const target = buildTargetUtf8(&utf8_buf, service, account) orelse return null;
    const len = std.unicode.utf8ToUtf16Le(buf[0 .. buf.len - 1], target) catch return null;
    buf[len] = 0;
    return buf[0..len :0];
}

pub fn buildLabel(buf: []u8, service: []const u8, account: []const u8) ?[:0]u8 {
    if (std.mem.indexOfScalar(u8, service, 0) != null) return null;
    if (std.mem.indexOfScalar(u8, account, 0) != null) return null;
    const label = std.fmt.bufPrint(buf, "Suji safeStorage ({s}/{s})", .{ service, account }) catch return null;
    if (label.len >= buf.len) return null;
    buf[label.len] = 0;
    return buf[0..label.len :0];
}

test "safeStorage sentinel copy rejects embedded NUL and undersized buffers" {
    var buf: [8]u8 = undefined;
    const ok = copyToSentinel(&buf, "value").?;
    try std.testing.expectEqualStrings("value", ok);
    try std.testing.expectEqual(@as(u8, 0), buf[ok.len]);
    try std.testing.expect(copyToSentinel(&buf, "12345678") == null);
    try std.testing.expect(copyToSentinel(&buf, "a\x00b") == null);
}

test "safeStorage target uses length-prefixed service/account namespace" {
    var buf: [128]u8 = undefined;
    const a = buildTargetUtf8(&buf, "svc", "acc").?;
    try std.testing.expectEqualStrings("suji.safeStorage/3:svc/3:acc", a);

    const b = buildTargetUtf8(&buf, "svc/with/slash", "a:b").?;
    try std.testing.expectEqualStrings("suji.safeStorage/14:svc/with/slash/3:a:b", b);
}

test "safeStorage target rejects undersized buffers" {
    var buf: [8]u8 = undefined;
    try std.testing.expect(buildTargetUtf8(&buf, "svc", "acc") == null);
}

test "safeStorage target converts to sentinel-terminated UTF-16" {
    var buf: [128]u16 = undefined;
    const target = buildTargetUtf16(&buf, "한글", "acc").?;
    try std.testing.expectEqual(@as(u16, 0), buf[target.len]);

    var utf8_buf: [128]u8 = undefined;
    const len = try std.unicode.utf16LeToUtf8(&utf8_buf, target);
    try std.testing.expectEqualStrings("suji.safeStorage/6:한글/3:acc", utf8_buf[0..len]);
}

test "safeStorage label is sentinel-terminated and rejects embedded NUL" {
    var buf: [128]u8 = undefined;
    const label = buildLabel(&buf, "svc", "acc").?;
    try std.testing.expectEqualStrings("Suji safeStorage (svc/acc)", label);
    try std.testing.expectEqual(@as(u8, 0), buf[label.len]);
    try std.testing.expect(buildLabel(&buf, "svc\x00x", "acc") == null);
    try std.testing.expect(buildLabel(&buf, "svc", "acc\x00x") == null);
}
