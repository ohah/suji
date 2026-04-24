//! EventBusSink: WindowManager.EventSink를 EventBus에 연결하는 어댑터.
//!
//! EventBus는 fire-and-forget 모델(리스너 return 값 없음). WindowManager는 `window:close`
//! 같은 취소 가능 이벤트에 `SujiEvent.preventDefault()`를 지원해야 한다. 두 모델을
//! 결합하기 위해 EventBusSink가 내부 cancelable 리스너 레지스트리를 따로 유지한다.
//!
//! 이벤트 흐름:
//! - WM.sink.emit(name, data)         → EventBus.emit(name, data)
//! - WM.sink.emit_cancelable(...)     → 내부 cancelable 리스너들 (preventDefault 가능)
//!                                      → 그리고 EventBus.emit도 발화 (Electron 동등:
//!                                        일반 리스너는 cancel 여부와 무관하게 관찰)
//!
//! 스레드 모델 (docs/WINDOW_API.md#스레드-모델):
//! - cancelable 리스너 등록/해제/발화는 mutex로 직렬화
//! - 발화 시 snapshot 후 lock 밖에서 콜백 실행 (재진입 안전)

const std = @import("std");
const events = @import("events");
const window = @import("window");

/// cancelable 리스너 콜백 시그니처.
/// listener가 `ev.preventDefault()`를 호출하면 WindowManager는 해당 동작을 취소.
pub const CancelableCallback = *const fn (
    data: []const u8,
    ev: *window.SujiEvent,
    ctx: ?*anyopaque,
) void;

const Listener = struct {
    id: u64,
    callback: CancelableCallback,
    ctx: ?*anyopaque,
};

pub const EventBusSink = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    bus: *events.EventBus,
    /// event_name (allocator-owned dup) → cancelable 리스너 배열
    cancelable: std.StringHashMap(std.ArrayList(Listener)),
    next_id: u64 = 1,
    mutex: std.Io.Mutex = .init,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        bus: *events.EventBus,
    ) EventBusSink {
        return .{
            .allocator = allocator,
            .io = io,
            .bus = bus,
            .cancelable = std.StringHashMap(std.ArrayList(Listener)).init(allocator),
        };
    }

    pub fn deinit(self: *EventBusSink) void {
        var it = self.cancelable.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.cancelable.deinit();
    }

    pub fn asSink(self: *EventBusSink) window.EventSink {
        return .{ .vtable = &vtable, .ctx = self };
    }

    const vtable: window.EventSink.VTable = .{
        .emit = emitAdapter,
        .emit_cancelable = emitCancelableAdapter,
    };

    fn fromCtx(ctx: ?*anyopaque) *EventBusSink {
        return @ptrCast(@alignCast(ctx.?));
    }

    /// cancelable 리스너 등록. 반환된 id로 offCancelable 해제.
    /// event_name은 내부에서 dupe 보관 (caller 수명에 의존하지 않음).
    pub fn onCancelable(
        self: *EventBusSink,
        event_name: []const u8,
        callback: CancelableCallback,
        ctx: ?*anyopaque,
    ) !u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const id = self.next_id;
        const listener = Listener{ .id = id, .callback = callback, .ctx = ctx };

        if (self.cancelable.getPtr(event_name)) |list| {
            try list.append(self.allocator, listener);
        } else {
            const key = try self.allocator.dupe(u8, event_name);
            errdefer self.allocator.free(key);
            var list: std.ArrayList(Listener) = .empty;
            errdefer list.deinit(self.allocator);
            try list.append(self.allocator, listener);
            try self.cancelable.put(key, list);
        }
        self.next_id += 1;
        return id;
    }

    pub fn offCancelable(self: *EventBusSink, listener_id: u64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var it = self.cancelable.iterator();
        while (it.next()) |entry| {
            const list = entry.value_ptr;
            var i: usize = 0;
            while (i < list.items.len) : (i += 1) {
                if (list.items[i].id == listener_id) {
                    _ = list.orderedRemove(i);
                    return;
                }
            }
        }
    }

    fn emitAdapter(ctx: ?*anyopaque, name: []const u8, data: []const u8) void {
        fromCtx(ctx).bus.emit(name, data);
    }

    fn emitCancelableAdapter(
        ctx: ?*anyopaque,
        name: []const u8,
        data: []const u8,
        ev: *window.SujiEvent,
    ) void {
        const self = fromCtx(ctx);
        self.invokeCancelable(name, data, ev);
        // 일반 리스너는 preventDefault 여부와 무관하게 관찰 (Electron 동등)
        self.bus.emit(name, data);
    }

    fn invokeCancelable(
        self: *EventBusSink,
        event_name: []const u8,
        data: []const u8,
        ev: *window.SujiEvent,
    ) void {
        // snapshot 후 lock 밖 실행 — 콜백이 onCancelable/offCancelable 재호출해도 deadlock X.
        // SNAPSHOT_MAX 초과 시 후행 리스너는 이번 발화에서 무시 (debug에선 assert).
        // 64는 EventBus와 동일한 상한. window:close 등에 실제로 이 수준이 붙는 경우는 없음.
        var snapshot: [SNAPSHOT_MAX]Listener = undefined;
        var snapshot_len: usize = 0;
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.cancelable.get(event_name)) |list| {
                std.debug.assert(list.items.len <= SNAPSHOT_MAX);
                snapshot_len = @min(list.items.len, SNAPSHOT_MAX);
                @memcpy(snapshot[0..snapshot_len], list.items[0..snapshot_len]);
            }
        }
        for (snapshot[0..snapshot_len]) |listener| {
            listener.callback(data, ev, listener.ctx);
        }
    }

    const SNAPSHOT_MAX = 64;
};
