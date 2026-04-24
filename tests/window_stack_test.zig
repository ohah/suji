//! WindowStack 테스트 — WM + EventBusSink 묶음 초기화/수명/전역 등록 검증.

const std = @import("std");
const events = @import("events");
const window = @import("window");
const event_sink = @import("event_sink");
const ws_mod = @import("window_stack");
const TestNative = @import("test_native").TestNative;

const WindowStack = ws_mod.WindowStack;

// 인스턴스 기반 EventBus 리스너 기록 (전역 X)
const BusRecorder = struct {
    events_by_name: std.StringHashMap(usize) = undefined,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) BusRecorder {
        return .{
            .events_by_name = std.StringHashMap(usize).init(allocator),
            .allocator = allocator,
        };
    }
    fn deinit(self: *BusRecorder) void {
        var it = self.events_by_name.iterator();
        while (it.next()) |e| self.allocator.free(e.key_ptr.*);
        self.events_by_name.deinit();
    }
    fn count(self: *const BusRecorder, event_name: []const u8) usize {
        return self.events_by_name.get(event_name) orelse 0;
    }
    fn callback(event_name: [*c]const u8, _: [*c]const u8, arg: ?*anyopaque) callconv(.c) void {
        const self: *BusRecorder = @ptrCast(@alignCast(arg.?));
        const name = std.mem.span(event_name);
        const gop = self.events_by_name.getOrPut(name) catch return;
        if (!gop.found_existing) {
            const key = self.allocator.dupe(u8, name) catch return;
            gop.key_ptr.* = key;
            gop.value_ptr.* = 0;
        }
        gop.value_ptr.* += 1;
    }
};

// ============================================
// 기본 init/deinit 수명
// ============================================

test "init with TestNative produces usable WindowManager" {
    var native = TestNative{};
    var bus = events.EventBus.init(std.testing.allocator, std.testing.io);
    defer bus.deinit();

    var stack: WindowStack = undefined;
    stack.init(std.testing.allocator, std.testing.io, native.asNative(), &bus);
    defer stack.deinit();

    const id = try stack.manager.create(.{});
    try std.testing.expect(id > 0);
    try std.testing.expectEqual(@as(usize, 1), native.create_calls);
}

test "deinit with multiple windows does not leak" {
    // testing allocator가 leak 감지
    var native = TestNative{};
    var bus = events.EventBus.init(std.testing.allocator, std.testing.io);
    defer bus.deinit();

    var stack: WindowStack = undefined;
    stack.init(std.testing.allocator, std.testing.io, native.asNative(), &bus);
    defer stack.deinit();

    _ = try stack.manager.create(.{ .name = "a" });
    _ = try stack.manager.create(.{ .name = "b" });
    _ = try stack.manager.create(.{ .name = "c" });
    // stack.deinit()이 WM + sink 모두 정리
}

// ============================================
// sink-manager 배선 — create 이벤트가 EventBus로 흘러감
// ============================================

test "create() emits window:created through EventBus" {
    var native = TestNative{};
    var bus = events.EventBus.init(std.testing.allocator, std.testing.io);
    defer bus.deinit();
    var rec = BusRecorder.init(std.testing.allocator);
    defer rec.deinit();

    var stack: WindowStack = undefined;
    stack.init(std.testing.allocator, std.testing.io, native.asNative(), &bus);
    defer stack.deinit();

    _ = bus.onC(window.events.created, BusRecorder.callback, &rec);

    _ = try stack.manager.create(.{});
    _ = try stack.manager.create(.{});

    try std.testing.expectEqual(@as(usize, 2), rec.count(window.events.created));
}

test "close() emits window:close then window:closed through EventBus" {
    var native = TestNative{};
    var bus = events.EventBus.init(std.testing.allocator, std.testing.io);
    defer bus.deinit();
    var rec = BusRecorder.init(std.testing.allocator);
    defer rec.deinit();

    var stack: WindowStack = undefined;
    stack.init(std.testing.allocator, std.testing.io, native.asNative(), &bus);
    defer stack.deinit();

    _ = bus.onC(window.events.close, BusRecorder.callback, &rec);
    _ = bus.onC(window.events.closed, BusRecorder.callback, &rec);

    const id = try stack.manager.create(.{});
    const destroyed = try stack.manager.close(id);

    try std.testing.expect(destroyed);
    try std.testing.expectEqual(@as(usize, 1), rec.count(window.events.close));
    try std.testing.expectEqual(@as(usize, 1), rec.count(window.events.closed));
}

// ============================================
// cancelable 리스너 — preventDefault가 EventBus 경유로도 먹힘
// ============================================

const PreventCtx = struct { prevent: bool };
fn preventCallback(_: []const u8, ev: *window.SujiEvent, ctx: ?*anyopaque) void {
    const self: *PreventCtx = @ptrCast(@alignCast(ctx.?));
    if (self.prevent) ev.preventDefault();
}

test "cancelable listener registered via sink blocks wm.close" {
    var native = TestNative{};
    var bus = events.EventBus.init(std.testing.allocator, std.testing.io);
    defer bus.deinit();

    var stack: WindowStack = undefined;
    stack.init(std.testing.allocator, std.testing.io, native.asNative(), &bus);
    defer stack.deinit();

    var pc = PreventCtx{ .prevent = true };
    _ = try stack.sink.onCancelable(window.events.close, preventCallback, &pc);

    const id = try stack.manager.create(.{});
    const destroyed = try stack.manager.close(id);
    try std.testing.expect(!destroyed);
    try std.testing.expectEqual(@as(usize, 0), native.destroy_calls);
}

// ============================================
// 전역 등록
// ============================================

test "setGlobal exposes manager; clearGlobal resets" {
    var native = TestNative{};
    var bus = events.EventBus.init(std.testing.allocator, std.testing.io);
    defer bus.deinit();

    var stack: WindowStack = undefined;
    stack.init(std.testing.allocator, std.testing.io, native.asNative(), &bus);
    defer stack.deinit();

    try std.testing.expect(window.WindowManager.global == null);

    stack.setGlobal();
    try std.testing.expect(window.WindowManager.global == &stack.manager);

    WindowStack.clearGlobal();
    try std.testing.expect(window.WindowManager.global == null);
}

test "setGlobal twice with different stacks swaps reference" {
    var native1 = TestNative{};
    var native2 = TestNative{};
    var bus = events.EventBus.init(std.testing.allocator, std.testing.io);
    defer bus.deinit();

    var s1: WindowStack = undefined;
    s1.init(std.testing.allocator, std.testing.io, native1.asNative(), &bus);
    defer s1.deinit();

    var s2: WindowStack = undefined;
    s2.init(std.testing.allocator, std.testing.io, native2.asNative(), &bus);
    defer s2.deinit();

    s1.setGlobal();
    try std.testing.expect(window.WindowManager.global == &s1.manager);

    s2.setGlobal();
    try std.testing.expect(window.WindowManager.global == &s2.manager);

    WindowStack.clearGlobal();
}

// ============================================
// deinit 순서 — manager deinit이 sink보다 먼저 (destroyAll 경로가 sink 참조)
// ============================================

test "manager.destroyAll during deinit emits through sink without UAF" {
    var native = TestNative{};
    var bus = events.EventBus.init(std.testing.allocator, std.testing.io);
    defer bus.deinit();
    var rec = BusRecorder.init(std.testing.allocator);
    defer rec.deinit();

    var stack: WindowStack = undefined;
    stack.init(std.testing.allocator, std.testing.io, native.asNative(), &bus);

    _ = bus.onC(window.events.closed, BusRecorder.callback, &rec);

    _ = try stack.manager.create(.{});
    _ = try stack.manager.create(.{});
    try stack.manager.destroyAll();

    // destroyAll은 각 창마다 window:closed 발화 → sink → EventBus
    try std.testing.expectEqual(@as(usize, 2), rec.count(window.events.closed));

    stack.deinit();
    // deinit 후 BusRecorder는 lifetime 안에 있어야 (test deinit은 별도 단계)
}
