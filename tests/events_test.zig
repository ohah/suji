const std = @import("std");
const events = @import("events");

var last_data: [256]u8 = undefined;
var last_data_len: usize = 0;
var call_count: usize = 0;

fn testCallback(data: [*:0]const u8) void {
    const s = std.mem.span(data);
    const len = @min(s.len, last_data.len);
    @memcpy(last_data[0..len], s[0..len]);
    last_data_len = len;
    call_count += 1;
}

fn resetState() void {
    last_data_len = 0;
    call_count = 0;
}

test "EventBus init and deinit" {
    var bus = events.EventBus.init(std.testing.allocator);
    defer bus.deinit();
}

test "EventBus on and emit" {
    resetState();
    var bus = events.EventBus.init(std.testing.allocator);
    defer bus.deinit();

    _ = bus.on("test", testCallback);
    bus.emit("test", "hello");

    try std.testing.expectEqual(@as(usize, 1), call_count);
    try std.testing.expectEqualStrings("hello", last_data[0..last_data_len]);
}

test "EventBus multiple listeners" {
    resetState();
    var bus = events.EventBus.init(std.testing.allocator);
    defer bus.deinit();

    _ = bus.on("test", testCallback);
    _ = bus.on("test", testCallback);
    bus.emit("test", "data");

    try std.testing.expectEqual(@as(usize, 2), call_count);
}

test "EventBus off removes listener" {
    resetState();
    var bus = events.EventBus.init(std.testing.allocator);
    defer bus.deinit();

    const id = bus.on("test", testCallback);
    bus.off(id);
    bus.emit("test", "data");

    try std.testing.expectEqual(@as(usize, 0), call_count);
}

test "EventBus once fires only once" {
    resetState();
    var bus = events.EventBus.init(std.testing.allocator);
    defer bus.deinit();

    _ = bus.once("test", testCallback);
    bus.emit("test", "first");
    bus.emit("test", "second");

    try std.testing.expectEqual(@as(usize, 1), call_count);
    try std.testing.expectEqualStrings("first", last_data[0..last_data_len]);
}

test "EventBus offAll" {
    resetState();
    var bus = events.EventBus.init(std.testing.allocator);
    defer bus.deinit();

    _ = bus.on("test", testCallback);
    _ = bus.on("test", testCallback);
    bus.offAll("test");
    bus.emit("test", "data");

    try std.testing.expectEqual(@as(usize, 0), call_count);
}

test "EventBus different events" {
    resetState();
    var bus = events.EventBus.init(std.testing.allocator);
    defer bus.deinit();

    _ = bus.on("a", testCallback);
    _ = bus.on("b", testCallback);

    bus.emit("a", "data-a");
    try std.testing.expectEqual(@as(usize, 1), call_count);

    bus.emit("b", "data-b");
    try std.testing.expectEqual(@as(usize, 2), call_count);
}

test "EventBus emit nonexistent event" {
    var bus = events.EventBus.init(std.testing.allocator);
    defer bus.deinit();

    // 리스너 없는 이벤트 발행 — 크래시 안 남
    bus.emit("nonexistent", "data");
}
