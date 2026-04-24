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
    var bus = events.EventBus.init(std.testing.allocator, std.testing.io);
    defer bus.deinit();
}

test "EventBus on and emit" {
    resetState();
    var bus = events.EventBus.init(std.testing.allocator, std.testing.io);
    defer bus.deinit();

    _ = bus.on("test", testCallback);
    bus.emit("test", "hello");

    try std.testing.expectEqual(@as(usize, 1), call_count);
    try std.testing.expectEqualStrings("hello", last_data[0..last_data_len]);
}

test "EventBus multiple listeners" {
    resetState();
    var bus = events.EventBus.init(std.testing.allocator, std.testing.io);
    defer bus.deinit();

    _ = bus.on("test", testCallback);
    _ = bus.on("test", testCallback);
    bus.emit("test", "data");

    try std.testing.expectEqual(@as(usize, 2), call_count);
}

test "EventBus off removes listener" {
    resetState();
    var bus = events.EventBus.init(std.testing.allocator, std.testing.io);
    defer bus.deinit();

    const id = bus.on("test", testCallback);
    bus.off(id);
    bus.emit("test", "data");

    try std.testing.expectEqual(@as(usize, 0), call_count);
}

test "EventBus once fires only once" {
    resetState();
    var bus = events.EventBus.init(std.testing.allocator, std.testing.io);
    defer bus.deinit();

    _ = bus.once("test", testCallback);
    bus.emit("test", "first");
    bus.emit("test", "second");

    try std.testing.expectEqual(@as(usize, 1), call_count);
    try std.testing.expectEqualStrings("first", last_data[0..last_data_len]);
}

test "EventBus offAll" {
    resetState();
    var bus = events.EventBus.init(std.testing.allocator, std.testing.io);
    defer bus.deinit();

    _ = bus.on("test", testCallback);
    _ = bus.on("test", testCallback);
    bus.offAll("test");
    bus.emit("test", "data");

    try std.testing.expectEqual(@as(usize, 0), call_count);
}

test "EventBus different events" {
    resetState();
    var bus = events.EventBus.init(std.testing.allocator, std.testing.io);
    defer bus.deinit();

    _ = bus.on("a", testCallback);
    _ = bus.on("b", testCallback);

    bus.emit("a", "data-a");
    try std.testing.expectEqual(@as(usize, 1), call_count);

    bus.emit("b", "data-b");
    try std.testing.expectEqual(@as(usize, 2), call_count);
}

test "EventBus emit nonexistent event" {
    var bus = events.EventBus.init(std.testing.allocator, std.testing.io);
    defer bus.deinit();

    // 리스너 없는 이벤트 발행 — 크래시 안 남
    bus.emit("nonexistent", "data");
}

// ============================================
// 회귀 방지 — 키 소유 이슈 (caller의 stack 버퍼로 등록해도 EventBus가 복사해야)
// ============================================

test "on() copies event_name (caller's ephemeral buffer safe)" {
    resetState();
    var bus = events.EventBus.init(std.testing.allocator, std.testing.io);
    defer bus.deinit();

    // caller가 스택 버퍼에 이름을 만들어 넘김 (실제 C SDK가 하는 패턴: nullTerminate 경유 스택 버퍼)
    {
        var scratch: [64]u8 = undefined;
        const name = "window:all-closed";
        @memcpy(scratch[0..name.len], name);
        _ = bus.on(scratch[0..name.len], testCallback);
        // scratch 버퍼 내용 덮어쓰기 — 만약 bus가 키를 복사 안 했다면 키가 쓰레기가 됨
        @memset(scratch[0..name.len], 0xAA);
    }

    // 원본 문자열로 emit — 키 복사가 정상이면 매칭, 아니면 미매칭
    bus.emit("window:all-closed", "{}");
    try std.testing.expectEqual(@as(usize, 1), call_count);
}

