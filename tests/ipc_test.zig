const std = @import("std");
const ipc = @import("ipc");

test "parseJsonStrings single string" {
    const raw = "[\"hello\"]";
    var bufs: ipc.Bridge.ParseBufs = undefined;
    const result = try ipc.Bridge.parseJsonStrings(raw, &bufs, 1);
    const args = result.args();

    try std.testing.expectEqual(@as(usize, 1), args.len);
    try std.testing.expectEqualStrings("hello", args[0]);
}

test "parseJsonStrings two strings" {
    const raw = "[\"rust\",\"{\\\"cmd\\\":\\\"ping\\\"}\"]";
    var bufs: ipc.Bridge.ParseBufs = undefined;
    const result = try ipc.Bridge.parseJsonStrings(raw, &bufs, 2);
    const args = result.args();

    try std.testing.expectEqual(@as(usize, 2), args.len);
    try std.testing.expectEqualStrings("rust", args[0]);
    try std.testing.expectEqualStrings("{\"cmd\":\"ping\"}", args[1]);
}

test "parseJsonStrings three strings" {
    const raw = "[\"go\",\"rust\",\"{\\\"cmd\\\":\\\"relay\\\"}\"]";
    var bufs: ipc.Bridge.ParseBufs = undefined;
    const result = try ipc.Bridge.parseJsonStrings(raw, &bufs, 3);
    const args = result.args();

    try std.testing.expectEqual(@as(usize, 3), args.len);
    try std.testing.expectEqualStrings("go", args[0]);
    try std.testing.expectEqualStrings("rust", args[1]);
    try std.testing.expectEqualStrings("{\"cmd\":\"relay\"}", args[2]);
}

test "parseJsonStrings max limit" {
    const raw = "[\"a\",\"b\",\"c\",\"d\",\"e\"]";
    var bufs: ipc.Bridge.ParseBufs = undefined;

    // max=2이면 2개만 파싱
    const result = try ipc.Bridge.parseJsonStrings(raw, &bufs, 2);
    const args = result.args();
    try std.testing.expectEqual(@as(usize, 2), args.len);
    try std.testing.expectEqualStrings("a", args[0]);
    try std.testing.expectEqualStrings("b", args[1]);
}

test "parseJsonStrings empty returns error" {
    const raw = "[]";
    var bufs: ipc.Bridge.ParseBufs = undefined;
    const result = ipc.Bridge.parseJsonStrings(raw, &bufs, 2);
    try std.testing.expectError(error.InvalidArgs, result);
}

test "parseJsonStrings escaped characters" {
    const raw = "[\"hello\\nworld\"]";
    var bufs: ipc.Bridge.ParseBufs = undefined;
    const result = try ipc.Bridge.parseJsonStrings(raw, &bufs, 1);
    const args = result.args();

    try std.testing.expectEqual(@as(usize, 1), args.len);
    try std.testing.expectEqualStrings("hello\nworld", args[0]);
}

test "parseJsonStrings escaped quotes" {
    const raw = "[\"he said \\\"hi\\\"\"]";
    var bufs: ipc.Bridge.ParseBufs = undefined;
    const result = try ipc.Bridge.parseJsonStrings(raw, &bufs, 1);
    const args = result.args();

    try std.testing.expectEqualStrings("he said \"hi\"", args[0]);
}

test "parseJsonStrings escaped backslash" {
    const raw = "[\"path\\\\to\\\\file\"]";
    var bufs: ipc.Bridge.ParseBufs = undefined;
    const result = try ipc.Bridge.parseJsonStrings(raw, &bufs, 1);
    const args = result.args();

    try std.testing.expectEqualStrings("path\\to\\file", args[0]);
}

test "ParseResult struct" {
    var pr = ipc.Bridge.ParseResult{};
    pr.slices[0] = "hello";
    pr.slices[1] = "world";
    pr.count = 2;

    const args = pr.args();
    try std.testing.expectEqual(@as(usize, 2), args.len);
    try std.testing.expectEqualStrings("hello", args[0]);
    try std.testing.expectEqualStrings("world", args[1]);
}

test "ParseResult empty" {
    const pr = ipc.Bridge.ParseResult{};
    const args = pr.args();
    try std.testing.expectEqual(@as(usize, 0), args.len);
}
