const std = @import("std");
const events = @import("events");

// ============================================
// EventBus 통합 테스트 (on/emit/off/once 전체 흐름)
// ============================================

var received_count: usize = 0;
var received_data: [256]u8 = undefined;
var received_len: usize = 0;

fn resetState() void {
    received_count = 0;
    received_len = 0;
}

fn countCallback(_: [*:0]const u8) void {
    received_count += 1;
}

fn dataCallback(data: [*:0]const u8) void {
    const s = std.mem.span(data);
    const len = @min(s.len, received_data.len);
    @memcpy(received_data[0..len], s[0..len]);
    received_len = len;
    received_count += 1;
}

// C ABI 콜백 (백엔드 시뮬레이션)
var c_received_count: usize = 0;
var c_received_channel: [128]u8 = undefined;
var c_received_channel_len: usize = 0;

fn cCallback(event_name: [*c]const u8, data: [*c]const u8, arg: ?*anyopaque) callconv(.c) void {
    _ = data;
    _ = arg;
    const name = std.mem.span(@as([*:0]const u8, @ptrCast(event_name)));
    const len = @min(name.len, c_received_channel.len);
    @memcpy(c_received_channel[0..len], name[0..len]);
    c_received_channel_len = len;
    c_received_count += 1;
}

test "EventBus full lifecycle: on → emit → off → emit" {
    resetState();
    var bus = events.EventBus.init(std.testing.allocator);
    defer bus.deinit();

    const id = bus.on("test", countCallback);
    bus.emit("test", "data1");
    try std.testing.expectEqual(@as(usize, 1), received_count);

    bus.emit("test", "data2");
    try std.testing.expectEqual(@as(usize, 2), received_count);

    bus.off(id);
    bus.emit("test", "data3");
    try std.testing.expectEqual(@as(usize, 2), received_count); // off 후 안 불림
}

test "EventBus once fires exactly once" {
    resetState();
    var bus = events.EventBus.init(std.testing.allocator);
    defer bus.deinit();

    _ = bus.once("one-shot", countCallback);
    bus.emit("one-shot", "a");
    bus.emit("one-shot", "b");
    bus.emit("one-shot", "c");
    try std.testing.expectEqual(@as(usize, 1), received_count);
}

test "EventBus data is passed correctly" {
    resetState();
    var bus = events.EventBus.init(std.testing.allocator);
    defer bus.deinit();

    _ = bus.on("data-test", dataCallback);
    bus.emit("data-test", "{\"msg\":\"hello\"}");
    try std.testing.expectEqualStrings("{\"msg\":\"hello\"}", received_data[0..received_len]);
}

test "EventBus C ABI callback" {
    c_received_count = 0;
    c_received_channel_len = 0;
    var bus = events.EventBus.init(std.testing.allocator);
    defer bus.deinit();

    _ = bus.onC("backend-event", cCallback, null);
    bus.emit("backend-event", "{}");
    try std.testing.expectEqual(@as(usize, 1), c_received_count);
    try std.testing.expectEqualStrings("backend-event", c_received_channel[0..c_received_channel_len]);
}

test "EventBus mixed Zig + C callbacks" {
    resetState();
    c_received_count = 0;
    var bus = events.EventBus.init(std.testing.allocator);
    defer bus.deinit();

    _ = bus.on("mixed", countCallback);
    _ = bus.onC("mixed", cCallback, null);

    bus.emit("mixed", "data");

    try std.testing.expectEqual(@as(usize, 1), received_count); // Zig
    try std.testing.expectEqual(@as(usize, 1), c_received_count); // C
}

test "EventBus offAll clears all listeners" {
    resetState();
    c_received_count = 0;
    var bus = events.EventBus.init(std.testing.allocator);
    defer bus.deinit();

    _ = bus.on("clear-me", countCallback);
    _ = bus.on("clear-me", countCallback);
    _ = bus.onC("clear-me", cCallback, null);

    bus.offAll("clear-me");
    bus.emit("clear-me", "data");

    try std.testing.expectEqual(@as(usize, 0), received_count);
    try std.testing.expectEqual(@as(usize, 0), c_received_count);
}

test "EventBus multiple channels independent" {
    resetState();
    c_received_count = 0;
    var bus = events.EventBus.init(std.testing.allocator);
    defer bus.deinit();

    _ = bus.on("ch-a", countCallback);
    _ = bus.onC("ch-b", cCallback, null);

    bus.emit("ch-a", "only-a");
    try std.testing.expectEqual(@as(usize, 1), received_count);
    try std.testing.expectEqual(@as(usize, 0), c_received_count);

    bus.emit("ch-b", "only-b");
    try std.testing.expectEqual(@as(usize, 1), received_count); // ch-a 안 바뀜
    try std.testing.expectEqual(@as(usize, 1), c_received_count);
}

test "EventBus stress: many listeners" {
    var bus = events.EventBus.init(std.testing.allocator);
    defer bus.deinit();

    var ids: [32]u64 = undefined;
    for (&ids, 0..) |*id, i| {
        _ = i;
        id.* = bus.on("stress", countCallback);
    }

    resetState();
    bus.emit("stress", "data");
    try std.testing.expectEqual(@as(usize, 32), received_count);

    // off 절반
    for (ids[0..16]) |id| {
        bus.off(id);
    }

    resetState();
    bus.emit("stress", "data");
    try std.testing.expectEqual(@as(usize, 16), received_count);
}
