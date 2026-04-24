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

// ============================================
// Step C — handleSetTitle / handleSetBounds
// ============================================

test "handleSetTitle forwards title to native.setTitle" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();

    _ = try wm.create(.{ .title = "old" });
    var buf: [256]u8 = undefined;
    const resp = ipc.handleSetTitle(.{ .window_id = 1, .title = "new title" }, &buf, &wm).?;

    try std.testing.expectEqual(@as(usize, 1), native.set_title_calls);
    try std.testing.expectEqualStrings("new title", native.last_title.?);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"cmd\":\"set_title\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"ok\":true") != null);
}

test "handleSetTitle on unknown id returns ok:false, does not call native" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();

    var buf: [256]u8 = undefined;
    const resp = ipc.handleSetTitle(.{ .window_id = 999, .title = "x" }, &buf, &wm).?;

    try std.testing.expectEqual(@as(usize, 0), native.set_title_calls);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"ok\":false") != null);
}

test "handleSetBounds forwards bounds to native.setBounds" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();

    _ = try wm.create(.{ .bounds = .{ .width = 100, .height = 100 } });
    var buf: [256]u8 = undefined;
    const resp = ipc.handleSetBounds(.{
        .window_id = 1,
        .x = 10,
        .y = 20,
        .width = 800,
        .height = 600,
    }, &buf, &wm).?;

    try std.testing.expectEqual(@as(usize, 1), native.set_bounds_calls);
    const lb = native.last_bounds.?;
    try std.testing.expectEqual(@as(i32, 10), lb.x);
    try std.testing.expectEqual(@as(i32, 20), lb.y);
    try std.testing.expectEqual(@as(u32, 800), lb.width);
    try std.testing.expectEqual(@as(u32, 600), lb.height);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"ok\":true") != null);
}

test "handleSetBounds rejects small buffer" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();

    var tiny: [3]u8 = undefined;
    const resp = ipc.handleSetBounds(.{ .window_id = 1 }, &tiny, &wm);
    try std.testing.expect(resp == null);
}

test "handleSetBounds on unknown id returns ok:false, does not call native" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();

    var buf: [256]u8 = undefined;
    const resp = ipc.handleSetBounds(.{
        .window_id = 999,
        .width = 800,
        .height = 600,
    }, &buf, &wm).?;

    try std.testing.expectEqual(@as(usize, 0), native.set_bounds_calls);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"ok\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"windowId\":999") != null);
}

test "handleSetTitle rejects small buffer" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();

    var tiny: [3]u8 = undefined;
    const resp = ipc.handleSetTitle(.{ .window_id = 1, .title = "x" }, &tiny, &wm);
    try std.testing.expect(resp == null);
}

test "handleSetTitle on destroyed window returns ok:false" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();

    const id = try wm.create(.{ .title = "living" });
    try wm.destroy(id);

    var buf: [256]u8 = undefined;
    const resp = ipc.handleSetTitle(.{ .window_id = id, .title = "ghost" }, &buf, &wm).?;

    // destroy 후엔 setTitle이 실패해야 한다.
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"ok\":false") != null);
}

test "handleSetBounds on destroyed window returns ok:false" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();

    const id = try wm.create(.{ .title = "living" });
    try wm.destroy(id);

    var buf: [256]u8 = undefined;
    const resp = ipc.handleSetBounds(.{ .window_id = id, .width = 100, .height = 100 }, &buf, &wm).?;

    try std.testing.expect(std.mem.indexOf(u8, resp, "\"ok\":false") != null);
}

test "handleSetTitle response is valid JSON (parsable)" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();

    _ = try wm.create(.{ .title = "x" });
    var buf: [256]u8 = undefined;
    const resp = ipc.handleSetTitle(.{ .window_id = 1, .title = "new" }, &buf, &wm).?;

    const Parsed = struct { windowId: u32, cmd: []const u8, from: []const u8, ok: bool };
    const parsed = try std.json.parseFromSlice(
        Parsed,
        std.testing.allocator,
        resp,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u32, 1), parsed.value.windowId);
    try std.testing.expectEqualStrings("set_title", parsed.value.cmd);
    try std.testing.expectEqualStrings("zig-core", parsed.value.from);
    try std.testing.expect(parsed.value.ok);
}

// ============================================
// Phase 2.5 — injectWindowField (wire 레벨 __window 자동 주입)
// ============================================

test "injectWindowField: inserts into simple object" {
    var buf: [256]u8 = undefined;
    const out = ipc.injectWindowField("{\"cmd\":\"ping\"}", 3, &buf).?;
    try std.testing.expectEqualStrings("{\"cmd\":\"ping\",\"__window\":3}", out);
}

test "injectWindowField: handles empty object (no leading comma)" {
    var buf: [64]u8 = undefined;
    const out = ipc.injectWindowField("{}", 1, &buf).?;
    try std.testing.expectEqualStrings("{\"__window\":1}", out);
}

test "injectWindowField: handles whitespace-only object body" {
    var buf: [64]u8 = undefined;
    const out = ipc.injectWindowField("{  }", 5, &buf).?;
    try std.testing.expectEqualStrings("{  \"__window\":5}", out);
}

test "injectWindowField: already-tagged request is returned as-is (no double-inject)" {
    var buf: [256]u8 = undefined;
    const src = "{\"cmd\":\"ping\",\"__window\":99}";
    const out = ipc.injectWindowField(src, 1, &buf).?;
    try std.testing.expectEqualStrings(src, out);
}

test "injectWindowField: non-object input returned as-is" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("[1,2,3]", ipc.injectWindowField("[1,2,3]", 1, &buf).?);
    try std.testing.expectEqualStrings("42", ipc.injectWindowField("42", 1, &buf).?);
    try std.testing.expectEqualStrings("", ipc.injectWindowField("", 1, &buf).?);
}

test "injectWindowField: trailing whitespace before } still parses" {
    var buf: [64]u8 = undefined;
    const out = ipc.injectWindowField("{\"a\":1}\n  ", 7, &buf).?;
    try std.testing.expectEqualStrings("{\"a\":1,\"__window\":7}", out);
}

test "injectWindowField: returns null when output buffer too small" {
    var tiny: [4]u8 = undefined;
    const out = ipc.injectWindowField("{\"cmd\":\"ping\"}", 1, &tiny);
    try std.testing.expect(out == null);
}
