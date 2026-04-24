//! EventBusSink 테스트 — WindowManager.EventSink ↔ EventBus 어댑터 검증.

const std = @import("std");
const events = @import("events");
const window = @import("window");
const sink_mod = @import("event_sink");
const TestNative = @import("test_native").TestNative;

const EventBusSink = sink_mod.EventBusSink;
const EventBus = events.EventBus;

// ============================================
// 테스트 유틸 — EventBus 리스너 호출 기록 (인스턴스 기반, 전역 X)
// ============================================

const BusRecorder = struct {
    call_count: usize = 0,
    last_data: [256]u8 = undefined,
    last_data_len: usize = 0,

    /// EventBus.onC는 C ABI 콜백 + ctx를 지원. 전역 상태 없이 인스턴스당 기록.
    fn callback(
        _: [*c]const u8,
        data: [*c]const u8,
        arg: ?*anyopaque,
    ) callconv(.c) void {
        const self: *BusRecorder = @ptrCast(@alignCast(arg.?));
        const s = std.mem.span(data);
        const n = @min(s.len, self.last_data.len);
        @memcpy(self.last_data[0..n], s[0..n]);
        self.last_data_len = n;
        self.call_count += 1;
    }

    fn recordedData(self: *const BusRecorder) []const u8 {
        return self.last_data[0..self.last_data_len];
    }
};

// ============================================
// Cancelable 리스너 테스트 유틸
// ============================================

const CancelRecorder = struct {
    called: usize = 0,
    last_data: [256]u8 = undefined,
    last_data_len: usize = 0,
    prevent: bool = false,

    fn callback(data: []const u8, ev: *window.SujiEvent, ctx: ?*anyopaque) void {
        const self: *CancelRecorder = @ptrCast(@alignCast(ctx.?));
        self.called += 1;
        const n = @min(data.len, self.last_data.len);
        @memcpy(self.last_data[0..n], data[0..n]);
        self.last_data_len = n;
        if (self.prevent) ev.preventDefault();
    }

    fn recordedData(self: *const CancelRecorder) []const u8 {
        return self.last_data[0..self.last_data_len];
    }
};

// 각 테스트가 자기 allocator로 새 bus 생성 (전역 상태 회피)
fn newBus() EventBus {
    return EventBus.init(std.testing.allocator, std.testing.io);
}

fn newSink(bus: *EventBus) EventBusSink {
    return EventBusSink.init(std.testing.allocator, std.testing.io, bus);
}

// ============================================
// init / deinit 수명 관리
// ============================================

test "init starts with empty cancelable registry" {
    var bus = newBus();
    defer bus.deinit();
    var sink = newSink(&bus);
    defer sink.deinit();

    try std.testing.expectEqual(@as(usize, 0), sink.cancelable.count());
    try std.testing.expectEqual(@as(u64, 1), sink.next_id);
}

test "deinit with registered listeners frees all memory" {
    // testing allocator가 누수 감지
    var bus = newBus();
    defer bus.deinit();
    var sink = newSink(&bus);
    defer sink.deinit();

    var rec = CancelRecorder{};
    _ = try sink.onCancelable("a", CancelRecorder.callback, &rec);
    _ = try sink.onCancelable("b", CancelRecorder.callback, &rec);
    _ = try sink.onCancelable("a", CancelRecorder.callback, &rec);
    // deinit에서 key들과 ArrayList 모두 해제되어야
}

// ============================================
// emit 라우팅 (일반 이벤트)
// ============================================

test "emit routes event to EventBus listeners" {
    var bus = newBus();
    defer bus.deinit();
    var sink = newSink(&bus);
    defer sink.deinit();

    var rec = BusRecorder{};
    _ = bus.onC(window.events.created, BusRecorder.callback, &rec);

    sink.asSink().emit(window.events.created, "{\"windowId\":42}");

    try std.testing.expectEqual(@as(usize, 1), rec.call_count);
    try std.testing.expectEqualStrings("{\"windowId\":42}", rec.recordedData());
}

// ============================================
// emit_cancelable — 리스너 없음
// ============================================

test "emit_cancelable with no cancelable listener: EventBus still receives, ev stays false" {
    var bus = newBus();
    defer bus.deinit();
    var sink = newSink(&bus);
    defer sink.deinit();

    var rec = BusRecorder{};
    _ = bus.onC(window.events.close, BusRecorder.callback, &rec);

    var ev: window.SujiEvent = .{};
    sink.asSink().emitCancelable(window.events.close, "{\"windowId\":1}", &ev);

    try std.testing.expect(!ev.default_prevented);
    try std.testing.expectEqual(@as(usize, 1), rec.call_count);
}

// ============================================
// cancelable 리스너 호출 + 데이터 전달
// ============================================

test "cancelable listener receives data matching what was emitted" {
    var bus = newBus();
    defer bus.deinit();
    var sink = newSink(&bus);
    defer sink.deinit();

    var rec = CancelRecorder{};
    _ = try sink.onCancelable(window.events.close, CancelRecorder.callback, &rec);

    var ev: window.SujiEvent = .{};
    sink.asSink().emitCancelable(window.events.close, "{\"windowId\":7}", &ev);

    try std.testing.expectEqual(@as(usize, 1), rec.called);
    try std.testing.expectEqualStrings("{\"windowId\":7}", rec.recordedData());
    try std.testing.expect(!ev.default_prevented);
}

// ============================================
// preventDefault 경로
// ============================================

test "cancelable listener calling preventDefault marks ev" {
    var bus = newBus();
    defer bus.deinit();
    var sink = newSink(&bus);
    defer sink.deinit();

    var rec = CancelRecorder{ .prevent = true };
    _ = try sink.onCancelable(window.events.close, CancelRecorder.callback, &rec);

    var ev: window.SujiEvent = .{};
    sink.asSink().emitCancelable(window.events.close, "{}", &ev);

    try std.testing.expect(ev.default_prevented);
}

// ============================================
// 여러 리스너 — 모두 호출, 하나만 prevent 해도 ev 세팅
// ============================================

test "multiple cancelable listeners all called; any preventDefault marks ev" {
    var bus = newBus();
    defer bus.deinit();
    var sink = newSink(&bus);
    defer sink.deinit();

    var r1 = CancelRecorder{};
    var r2 = CancelRecorder{ .prevent = true };
    var r3 = CancelRecorder{};
    _ = try sink.onCancelable(window.events.close, CancelRecorder.callback, &r1);
    _ = try sink.onCancelable(window.events.close, CancelRecorder.callback, &r2);
    _ = try sink.onCancelable(window.events.close, CancelRecorder.callback, &r3);

    var ev: window.SujiEvent = .{};
    sink.asSink().emitCancelable(window.events.close, "{}", &ev);

    // 모두 호출됨 (r2의 preventDefault가 뒤 리스너 실행을 막지 않음)
    try std.testing.expectEqual(@as(usize, 1), r1.called);
    try std.testing.expectEqual(@as(usize, 1), r2.called);
    try std.testing.expectEqual(@as(usize, 1), r3.called);
    try std.testing.expect(ev.default_prevented);
}

// ============================================
// Electron 동등: cancelable 리스너가 막아도 EventBus는 호출됨
// ============================================

test "EventBus listeners receive event regardless of preventDefault" {
    var bus = newBus();
    defer bus.deinit();
    var sink = newSink(&bus);
    defer sink.deinit();

    var bus_rec = BusRecorder{};
    _ = bus.onC(window.events.close, BusRecorder.callback, &bus_rec);

    var rec = CancelRecorder{ .prevent = true };
    _ = try sink.onCancelable(window.events.close, CancelRecorder.callback, &rec);

    var ev: window.SujiEvent = .{};
    sink.asSink().emitCancelable(window.events.close, "{\"windowId\":3}", &ev);

    try std.testing.expect(ev.default_prevented);
    try std.testing.expectEqual(@as(usize, 1), bus_rec.call_count);
}

// ============================================
// offCancelable
// ============================================

test "offCancelable removes listener; not called on subsequent emit" {
    var bus = newBus();
    defer bus.deinit();
    var sink = newSink(&bus);
    defer sink.deinit();

    var rec = CancelRecorder{};
    const id = try sink.onCancelable(window.events.close, CancelRecorder.callback, &rec);
    sink.offCancelable(id);

    var ev: window.SujiEvent = .{};
    sink.asSink().emitCancelable(window.events.close, "{}", &ev);
    try std.testing.expectEqual(@as(usize, 0), rec.called);
}

test "offCancelable on unknown id is silent no-op" {
    var bus = newBus();
    defer bus.deinit();
    var sink = newSink(&bus);
    defer sink.deinit();
    sink.offCancelable(9999); // crash 없어야
}

// ============================================
// 이벤트 스코프 격리
// ============================================

test "cancelable listener is event-name scoped" {
    var bus = newBus();
    defer bus.deinit();
    var sink = newSink(&bus);
    defer sink.deinit();

    var rec = CancelRecorder{ .prevent = true };
    _ = try sink.onCancelable(window.events.close, CancelRecorder.callback, &rec);

    var ev: window.SujiEvent = .{};
    sink.asSink().emitCancelable(window.events.created, "{}", &ev);
    try std.testing.expectEqual(@as(usize, 0), rec.called);
    try std.testing.expect(!ev.default_prevented);
}

// ============================================
// id 유일성
// ============================================

test "onCancelable returns unique incrementing ids" {
    var bus = newBus();
    defer bus.deinit();
    var sink = newSink(&bus);
    defer sink.deinit();

    var rec = CancelRecorder{};
    const id1 = try sink.onCancelable("a", CancelRecorder.callback, &rec);
    const id2 = try sink.onCancelable("b", CancelRecorder.callback, &rec);
    const id3 = try sink.onCancelable("a", CancelRecorder.callback, &rec);
    try std.testing.expect(id1 != id2);
    try std.testing.expect(id2 != id3);
    try std.testing.expect(id1 != id3);
}

// ============================================
// WindowManager 통합 — 실제 wm.close() 경로로 preventDefault 확인
// ============================================

test "integration: cancelable listener preventDefault blocks wm.close()" {
    var bus = newBus();
    defer bus.deinit();
    var sink = newSink(&bus);
    defer sink.deinit();
    var native = TestNative{};
    var wm = window.WindowManager.init(std.testing.allocator, std.testing.io, native.asNative());
    defer wm.deinit();
    wm.setEventSink(sink.asSink());

    var rec = CancelRecorder{ .prevent = true };
    _ = try sink.onCancelable(window.events.close, CancelRecorder.callback, &rec);

    const id = try wm.create(.{});
    const destroyed = try wm.close(id);

    try std.testing.expect(!destroyed);
    try std.testing.expectEqual(@as(usize, 1), rec.called);
    try std.testing.expectEqual(@as(usize, 0), native.destroy_calls);
    try std.testing.expect(!wm.get(id).?.destroyed);
}

test "integration: without preventDefault, wm.close() proceeds and emits window:closed" {
    var bus = newBus();
    defer bus.deinit();
    var sink = newSink(&bus);
    defer sink.deinit();
    var native = TestNative{};
    var wm = window.WindowManager.init(std.testing.allocator, std.testing.io, native.asNative());
    defer wm.deinit();
    wm.setEventSink(sink.asSink());

    var bus_rec = BusRecorder{};
    _ = bus.onC(window.events.closed, BusRecorder.callback, &bus_rec);

    const id = try wm.create(.{});
    const destroyed = try wm.close(id);

    try std.testing.expect(destroyed);
    try std.testing.expectEqual(@as(usize, 1), native.destroy_calls);
    try std.testing.expect(wm.get(id).?.destroyed);
    try std.testing.expectEqual(@as(usize, 1), bus_rec.call_count);
}

// ============================================
// 동시성 — onCancelable + emitCancelable 레이스
// ============================================

const ConcurrentArgs = struct {
    sink: *EventBusSink,
    rec: *CancelRecorder,
    iterations: usize,
};

fn concurrentRegister(args: ConcurrentArgs) void {
    var i: usize = 0;
    while (i < args.iterations) : (i += 1) {
        const id = args.sink.onCancelable(window.events.close, CancelRecorder.callback, args.rec) catch continue;
        args.sink.offCancelable(id);
    }
}

fn concurrentEmit(args: ConcurrentArgs) void {
    var i: usize = 0;
    while (i < args.iterations) : (i += 1) {
        var ev: window.SujiEvent = .{};
        args.sink.asSink().emitCancelable(window.events.close, "{}", &ev);
    }
}

test "concurrent onCancelable + emitCancelable is mutex-safe" {
    var bus = newBus();
    defer bus.deinit();
    var sink = newSink(&bus);
    defer sink.deinit();

    var rec = CancelRecorder{};
    const iter = 200;
    const args = ConcurrentArgs{ .sink = &sink, .rec = &rec, .iterations = iter };

    const t1 = try std.Thread.spawn(.{}, concurrentRegister, .{args});
    const t2 = try std.Thread.spawn(.{}, concurrentEmit, .{args});
    const t3 = try std.Thread.spawn(.{}, concurrentEmit, .{args});
    t1.join();
    t2.join();
    t3.join();

    // crash/panic 없으면 성공. 정확한 call count는 non-deterministic
    // (리스너가 register→off 사이에 있을 때만 emit이 잡음)
}
