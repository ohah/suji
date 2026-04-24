//! window_ipc 테스트 — handleCreateWindow가 WM.create를 올바르게 호출하고
//! 유효한 JSON 응답을 생성하는지 검증.

const std = @import("std");
const window = @import("window");
const TestNative = @import("test_native").TestNative;
const ipc = @import("window_ipc");

fn newWm(native: *TestNative) window.WindowManager {
    return window.WindowManager.init(std.testing.allocator, std.testing.io, native.asNative());
}

test "handleCreateWindow calls wm.create with title + url + bounds" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();

    var buf: [256]u8 = undefined;
    const resp = ipc.handleCreateWindow(.{
        .title = "My Window",
        .url = "https://example.com",
        .width = 600,
        .height = 400,
    }, &buf, &wm).?;

    try std.testing.expectEqual(@as(usize, 1), native.create_calls);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"cmd\":\"create_window\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"windowId\":1") != null);
}

test "handleCreateWindow applies defaults when fields omitted" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();

    var buf: [256]u8 = undefined;
    _ = ipc.handleCreateWindow(.{}, &buf, &wm).?;

    const w = wm.get(1).?;
    try std.testing.expectEqualStrings("New Window", w.title);
    try std.testing.expectEqual(@as(?[]const u8, null), w.name);
    try std.testing.expectEqual(@as(u32, 800), w.bounds.width);
    try std.testing.expectEqual(@as(u32, 600), w.bounds.height);
}

test "handleCreateWindow returns JSON with valid windowId (parsable)" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();

    var buf: [256]u8 = undefined;
    const resp = ipc.handleCreateWindow(.{ .title = "x" }, &buf, &wm).?;

    const Parsed = struct { windowId: u32, cmd: []const u8, from: []const u8 };
    const parsed = try std.json.parseFromSlice(
        Parsed,
        std.testing.allocator,
        resp,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    try std.testing.expect(parsed.value.windowId > 0);
    try std.testing.expectEqualStrings("create_window", parsed.value.cmd);
    try std.testing.expectEqualStrings("zig-core", parsed.value.from);
}

test "handleCreateWindow with name honors singleton (duplicate returns same id)" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();

    var buf1: [256]u8 = undefined;
    var buf2: [256]u8 = undefined;
    _ = ipc.handleCreateWindow(.{ .name = "about" }, &buf1, &wm).?;
    _ = ipc.handleCreateWindow(.{ .name = "about" }, &buf2, &wm).?;

    // native.create는 1회만
    try std.testing.expectEqual(@as(usize, 1), native.create_calls);
}

test "handleCreateWindow returns null on native failure" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();

    native.fail_next_create = true;
    var buf: [256]u8 = undefined;
    const resp = ipc.handleCreateWindow(.{}, &buf, &wm);
    try std.testing.expect(resp == null);
    try std.testing.expectEqual(@as(usize, 0), native.create_calls);
}

test "handleCreateWindow rejects small buffer WITHOUT creating window" {
    // 고아 윈도우 방지 invariant: 응답 버퍼가 작으면 wm.create를 호출하지 않는다.
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();

    var tiny: [3]u8 = undefined;
    const resp = ipc.handleCreateWindow(.{}, &tiny, &wm);
    try std.testing.expect(resp == null);
    try std.testing.expectEqual(@as(usize, 0), native.create_calls);
}
