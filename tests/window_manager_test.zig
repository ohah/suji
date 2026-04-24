//! WindowManager 단위 테스트 — CEF 없이 순수 로직만.
//!
//! Native vtable을 TestNative stub으로 주입해서 플랫폼 조작 없이 WindowManager
//! 동작을 검증한다. docs/WINDOW_API.md의 "TDD 전략 1단계" 참조.

const std = @import("std");
const window = @import("window");

const WindowManager = window.WindowManager;
const Native = window.Native;
const CreateOptions = window.CreateOptions;
const Bounds = window.Bounds;

// ============================================
// TestNative — 플랫폼 호출 기록용 stub
// ============================================

const TestNative = struct {
    next_handle: u64 = 1000,
    create_calls: usize = 0,
    destroy_calls: usize = 0,
    set_title_calls: usize = 0,
    set_bounds_calls: usize = 0,
    set_visible_calls: usize = 0,
    focus_calls: usize = 0,
    last_title: ?[]const u8 = null,
    last_bounds: ?Bounds = null,
    fail_next_create: bool = false,

    fn asNative(self: *TestNative) Native {
        return .{
            .vtable = &vtable,
            .ctx = self,
        };
    }

    const vtable: Native.VTable = .{
        .create_window = createWindow,
        .destroy_window = destroyWindow,
        .set_title = setTitle,
        .set_bounds = setBounds,
        .set_visible = setVisible,
        .focus = focus,
    };

    fn fromCtx(ctx: ?*anyopaque) *TestNative {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn createWindow(ctx: ?*anyopaque, _: *const CreateOptions) anyerror!u64 {
        const self = fromCtx(ctx);
        if (self.fail_next_create) {
            self.fail_next_create = false;
            return error.NativeFailure;
        }
        self.create_calls += 1;
        const handle = self.next_handle;
        self.next_handle += 1;
        return handle;
    }

    fn destroyWindow(ctx: ?*anyopaque, _: u64) void {
        fromCtx(ctx).destroy_calls += 1;
    }

    fn setTitle(ctx: ?*anyopaque, _: u64, title: []const u8) void {
        const self = fromCtx(ctx);
        self.set_title_calls += 1;
        self.last_title = title;
    }

    fn setBounds(ctx: ?*anyopaque, _: u64, bounds: Bounds) void {
        const self = fromCtx(ctx);
        self.set_bounds_calls += 1;
        self.last_bounds = bounds;
    }

    fn setVisible(ctx: ?*anyopaque, _: u64, _: bool) void {
        fromCtx(ctx).set_visible_calls += 1;
    }

    fn focus(ctx: ?*anyopaque, _: u64) void {
        fromCtx(ctx).focus_calls += 1;
    }
};

fn newManager(native: *TestNative) WindowManager {
    return WindowManager.init(std.testing.allocator, std.testing.io, native.asNative());
}

// ============================================
// init / deinit
// ============================================

test "WindowManager init starts empty" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();
    try std.testing.expectEqual(@as(usize, 0), wm.windows.count());
    try std.testing.expectEqual(@as(u32, 1), wm.next_id);
}

// ============================================
// create — 기본 동작 / id monotonic
// ============================================

test "create returns id=1 for first window" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();

    const id = try wm.create(.{});
    try std.testing.expectEqual(@as(u32, 1), id);
    try std.testing.expectEqual(@as(usize, 1), native.create_calls);
}

test "create yields monotonic ids (no reuse after destroy)" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();

    const id1 = try wm.create(.{});
    const id2 = try wm.create(.{});
    try std.testing.expectEqual(@as(u32, 1), id1);
    try std.testing.expectEqual(@as(u32, 2), id2);

    try wm.destroy(id1);
    const id3 = try wm.create(.{});
    // id1 재사용되면 안 됨 — monotonic 정책
    try std.testing.expectEqual(@as(u32, 3), id3);
}

test "create stores bounds and title" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();

    const id = try wm.create(.{
        .title = "Hello",
        .bounds = .{ .x = 100, .y = 200, .width = 1024, .height = 768 },
    });
    const win = wm.get(id).?;
    try std.testing.expectEqualStrings("Hello", win.title);
    try std.testing.expectEqual(@as(i32, 100), win.bounds.x);
    try std.testing.expectEqual(@as(u32, 1024), win.bounds.width);
}

test "create propagates native failure as NativeCreateFailed" {
    var native = TestNative{ .fail_next_create = true };
    var wm = newManager(&native);
    defer wm.deinit();

    try std.testing.expectError(window.Error.NativeCreateFailed, wm.create(.{}));
    try std.testing.expectEqual(@as(u32, 1), wm.next_id); // 실패 시 id 증가 X
    try std.testing.expectEqual(@as(usize, 0), wm.windows.count());
}

// ============================================
// name 싱글턴 정책
// ============================================

test "create with same name returns existing id (singleton)" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();

    const id1 = try wm.create(.{ .name = "settings" });
    const id2 = try wm.create(.{ .name = "settings", .force_new = false });
    try std.testing.expectEqual(id1, id2);
    // 두 번째 호출은 native.create 호출하지 않음
    try std.testing.expectEqual(@as(usize, 1), native.create_calls);
}

test "create with forceNew=true creates separate window even with same name" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();

    const id1 = try wm.create(.{ .name = "panel" });
    const id2 = try wm.create(.{ .name = "panel", .force_new = true });
    try std.testing.expect(id1 != id2);
    try std.testing.expectEqual(@as(usize, 2), native.create_calls);
}

test "fromName returns id for named window" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();

    const id = try wm.create(.{ .name = "about" });
    try std.testing.expectEqual(@as(?u32, id), wm.fromName("about"));
    try std.testing.expectEqual(@as(?u32, null), wm.fromName("nonexistent"));
}

test "fromName returns null after destroy" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();

    const id = try wm.create(.{ .name = "temp" });
    try wm.destroy(id);
    try std.testing.expectEqual(@as(?u32, null), wm.fromName("temp"));
}

// ============================================
// destroy / destroyed 창 동작
// ============================================

test "destroy calls native and marks window destroyed" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();

    const id = try wm.create(.{});
    try wm.destroy(id);
    try std.testing.expectEqual(@as(usize, 1), native.destroy_calls);
    try std.testing.expect(wm.get(id).?.destroyed);
}

test "destroy of unknown id returns WindowNotFound" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();

    try std.testing.expectError(window.Error.WindowNotFound, wm.destroy(999));
}

test "destroy of already destroyed returns WindowDestroyed" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();

    const id = try wm.create(.{});
    try wm.destroy(id);
    try std.testing.expectError(window.Error.WindowDestroyed, wm.destroy(id));
}

test "setTitle on destroyed window returns WindowDestroyed" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();

    const id = try wm.create(.{});
    try wm.destroy(id);
    try std.testing.expectError(window.Error.WindowDestroyed, wm.setTitle(id, "x"));
}

test "setBounds on destroyed window returns WindowDestroyed" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();

    const id = try wm.create(.{});
    try wm.destroy(id);
    try std.testing.expectError(window.Error.WindowDestroyed, wm.setBounds(id, .{}));
}

// ============================================
// setTitle / setBounds / setVisible / focus
// ============================================

test "setTitle updates window state and calls native" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();

    const id = try wm.create(.{ .title = "Old" });
    try wm.setTitle(id, "New");
    try std.testing.expectEqualStrings("New", wm.get(id).?.title);
    try std.testing.expectEqual(@as(usize, 1), native.set_title_calls);
    try std.testing.expectEqualStrings("New", native.last_title.?);
}

test "setBounds updates state and calls native" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();

    const id = try wm.create(.{});
    try wm.setBounds(id, .{ .x = 50, .y = 60, .width = 400, .height = 300 });
    const win = wm.get(id).?;
    try std.testing.expectEqual(@as(i32, 50), win.bounds.x);
    try std.testing.expectEqual(@as(u32, 400), win.bounds.width);
    try std.testing.expectEqual(@as(u32, 300), native.last_bounds.?.height);
}

test "focus delegates to native" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();

    const id = try wm.create(.{});
    try wm.focus(id);
    try std.testing.expectEqual(@as(usize, 1), native.focus_calls);
}

// ============================================
// destroyAll
// ============================================

test "destroyAll destroys all windows and leaves by_name empty" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();

    _ = try wm.create(.{ .name = "a" });
    _ = try wm.create(.{ .name = "b" });
    _ = try wm.create(.{});

    wm.destroyAll();

    try std.testing.expectEqual(@as(usize, 3), native.destroy_calls);
    try std.testing.expectEqual(@as(?u32, null), wm.fromName("a"));
    try std.testing.expectEqual(@as(?u32, null), wm.fromName("b"));
    var it = wm.windows.iterator();
    while (it.next()) |entry| {
        try std.testing.expect(entry.value_ptr.*.destroyed);
    }
}

// ============================================
// parent_id 관계
// ============================================

test "create stores parent_id (visual relationship only)" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();

    const parent = try wm.create(.{ .name = "main" });
    const child = try wm.create(.{ .name = "dialog", .parent_id = parent });
    try std.testing.expectEqual(@as(?u32, parent), wm.get(child).?.parent_id);
    // 부모 destroy는 자식에게 자동 영향 없음 (시각 관계만)
    try wm.destroy(parent);
    try std.testing.expect(!wm.get(child).?.destroyed);
}

// ============================================
// EventSink — 이벤트 발행 / preventDefault
// ============================================

const Recorded = struct {
    name: []const u8,
    data: []const u8,
    cancelable: bool,
};

const TestSink = struct {
    events: std.ArrayList(Recorded) = .empty,
    /// 취소 가능 이벤트 수신 시 이 이름과 매칭되면 preventDefault 호출
    prevent_for: ?[]const u8 = null,
    buf: [1024 * 16]u8 = undefined,
    used: usize = 0,

    fn asSink(self: *TestSink) window.EventSink {
        return .{ .vtable = &vtable, .ctx = self };
    }

    const vtable: window.EventSink.VTable = .{
        .emit = onEmit,
        .emit_cancelable = onEmitCancelable,
    };

    fn fromCtx(ctx: ?*anyopaque) *TestSink {
        return @ptrCast(@alignCast(ctx.?));
    }

    /// buf에 name/data를 복사해서 수명 안정화 (테스트 내 검증용)
    fn intern(self: *TestSink, s: []const u8) []const u8 {
        const start = self.used;
        @memcpy(self.buf[start .. start + s.len], s);
        self.used += s.len;
        return self.buf[start .. start + s.len];
    }

    /// events.clearRetainingCapacity만으로는 buf는 계속 쌓인다. 긴 테스트에서
    /// buf 오버플로 막기 위해 명시적으로 함께 리셋.
    fn reset(self: *TestSink) void {
        self.events.clearRetainingCapacity();
        self.used = 0;
    }

    fn onEmit(ctx: ?*anyopaque, name: []const u8, data: []const u8) void {
        const self = fromCtx(ctx);
        self.events.append(std.testing.allocator, .{
            .name = self.intern(name),
            .data = self.intern(data),
            .cancelable = false,
        }) catch {};
    }

    fn onEmitCancelable(ctx: ?*anyopaque, name: []const u8, data: []const u8, ev: *window.SujiEvent) void {
        const self = fromCtx(ctx);
        self.events.append(std.testing.allocator, .{
            .name = self.intern(name),
            .data = self.intern(data),
            .cancelable = true,
        }) catch {};
        if (self.prevent_for) |p| {
            if (std.mem.eql(u8, p, name)) ev.preventDefault();
        }
    }

    fn deinit(self: *TestSink) void {
        self.events.deinit(std.testing.allocator);
    }
};

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "create emits window:created with id" {
    var native = TestNative{};
    var sink = TestSink{};
    defer sink.deinit();
    var wm = newManager(&native);
    defer wm.deinit();
    wm.setEventSink(sink.asSink());

    const id = try wm.create(.{});
    try std.testing.expectEqual(@as(usize, 1), sink.events.items.len);
    try std.testing.expectEqualStrings("window:created", sink.events.items[0].name);
    try std.testing.expect(!sink.events.items[0].cancelable);
    // data에 windowId:1 포함
    var buf: [64]u8 = undefined;
    const expected = try std.fmt.bufPrint(&buf, "\"windowId\":{d}", .{id});
    try std.testing.expect(contains(sink.events.items[0].data, expected));
}

test "create with name emits window:created with name field" {
    var native = TestNative{};
    var sink = TestSink{};
    defer sink.deinit();
    var wm = newManager(&native);
    defer wm.deinit();
    wm.setEventSink(sink.asSink());

    _ = try wm.create(.{ .name = "about" });
    try std.testing.expect(contains(sink.events.items[0].data, "\"name\":\"about\""));
}

test "close emits cancelable window:close, then window:closed on success" {
    var native = TestNative{};
    var sink = TestSink{};
    defer sink.deinit();
    var wm = newManager(&native);
    defer wm.deinit();
    wm.setEventSink(sink.asSink());

    const id = try wm.create(.{});
    sink.events.clearRetainingCapacity();

    const destroyed = try wm.close(id);
    try std.testing.expect(destroyed);
    try std.testing.expectEqual(@as(usize, 2), sink.events.items.len);
    try std.testing.expectEqualStrings("window:close", sink.events.items[0].name);
    try std.testing.expect(sink.events.items[0].cancelable);
    try std.testing.expectEqualStrings("window:closed", sink.events.items[1].name);
    try std.testing.expect(!sink.events.items[1].cancelable);
    try std.testing.expect(wm.get(id).?.destroyed);
}

test "close with preventDefault cancels destruction" {
    var native = TestNative{};
    var sink = TestSink{ .prevent_for = "window:close" };
    defer sink.deinit();
    var wm = newManager(&native);
    defer wm.deinit();
    wm.setEventSink(sink.asSink());

    const id = try wm.create(.{});
    sink.events.clearRetainingCapacity();

    const destroyed = try wm.close(id);
    try std.testing.expect(!destroyed);
    // 취소 가능 이벤트만 발화, closed 이벤트는 발화 X
    try std.testing.expectEqual(@as(usize, 1), sink.events.items.len);
    try std.testing.expectEqualStrings("window:close", sink.events.items[0].name);
    try std.testing.expect(!wm.get(id).?.destroyed);
    try std.testing.expectEqual(@as(usize, 0), native.destroy_calls);
}

test "close after preventDefault can be retried" {
    var native = TestNative{};
    var sink = TestSink{ .prevent_for = "window:close" };
    defer sink.deinit();
    var wm = newManager(&native);
    defer wm.deinit();
    wm.setEventSink(sink.asSink());

    const id = try wm.create(.{});
    _ = try wm.close(id); // 취소됨
    try std.testing.expect(!wm.get(id).?.destroyed);

    // 다음 시도 시 preventDefault 해제
    sink.prevent_for = null;
    const ok = try wm.close(id);
    try std.testing.expect(ok);
    try std.testing.expect(wm.get(id).?.destroyed);
}

test "close of destroyed returns WindowDestroyed" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();

    const id = try wm.create(.{});
    try wm.destroy(id);
    try std.testing.expectError(window.Error.WindowDestroyed, wm.close(id));
}

test "destroyAll emits window:closed for each live window" {
    var native = TestNative{};
    var sink = TestSink{};
    defer sink.deinit();
    var wm = newManager(&native);
    defer wm.deinit();
    wm.setEventSink(sink.asSink());

    _ = try wm.create(.{});
    _ = try wm.create(.{});
    _ = try wm.create(.{});
    sink.events.clearRetainingCapacity();

    wm.destroyAll();
    var closed_count: usize = 0;
    for (sink.events.items) |e| {
        if (std.mem.eql(u8, e.name, "window:closed")) closed_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), closed_count);
}

test "WindowManager without sink operates silently" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();
    // sink 없음 — 이벤트 발행 경로에서 crash 없어야

    const id = try wm.create(.{});
    _ = try wm.close(id);
    try std.testing.expect(wm.get(id).?.destroyed);
}

test "destroy does not emit window:closed (only close does)" {
    var native = TestNative{};
    var sink = TestSink{};
    defer sink.deinit();
    var wm = newManager(&native);
    defer wm.deinit();
    wm.setEventSink(sink.asSink());

    const id = try wm.create(.{});
    sink.events.clearRetainingCapacity();

    try wm.destroy(id);
    // destroy()는 강제 파괴, 이벤트 발화 X
    try std.testing.expectEqual(@as(usize, 0), sink.events.items.len);
}

// ============================================
// 동시성 — 같은 name으로 N 스레드 create → singleton 유지
// ============================================

const ConcurrentCreateArgs = struct {
    wm: *WindowManager,
    name: []const u8,
    out: *u32,
};

fn concurrentCreateWorker(args: ConcurrentCreateArgs) void {
    args.out.* = args.wm.create(.{ .name = args.name }) catch 0;
}

test "concurrent create with same name yields single window" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();

    const THREAD_COUNT = 10;
    var threads: [THREAD_COUNT]std.Thread = undefined;
    var results: [THREAD_COUNT]u32 = undefined;

    for (0..THREAD_COUNT) |i| {
        results[i] = 0;
        threads[i] = try std.Thread.spawn(.{}, concurrentCreateWorker, .{ConcurrentCreateArgs{
            .wm = &wm,
            .name = "shared",
            .out = &results[i],
        }});
    }
    for (0..THREAD_COUNT) |i| threads[i].join();

    // 모든 스레드가 같은 id 반환
    const first = results[0];
    try std.testing.expect(first != 0);
    for (results) |r| try std.testing.expectEqual(first, r);

    // 실제 native.create는 1회만
    try std.testing.expectEqual(@as(usize, 1), native.create_calls);
    try std.testing.expectEqual(@as(usize, 1), wm.windows.count());
}

const ConcurrentDistinctArgs = struct {
    wm: *WindowManager,
    idx: usize,
    out: *u32,
};

fn concurrentDistinctWorker(args: ConcurrentDistinctArgs) void {
    var buf: [32]u8 = undefined;
    const name = std.fmt.bufPrint(&buf, "win_{d}", .{args.idx}) catch return;
    args.out.* = args.wm.create(.{ .name = name }) catch 0;
}

test "concurrent create with distinct names yields N windows" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();

    const THREAD_COUNT = 10;
    var threads: [THREAD_COUNT]std.Thread = undefined;
    var results: [THREAD_COUNT]u32 = undefined;

    for (0..THREAD_COUNT) |i| {
        results[i] = 0;
        threads[i] = try std.Thread.spawn(.{}, concurrentDistinctWorker, .{ConcurrentDistinctArgs{
            .wm = &wm,
            .idx = i,
            .out = &results[i],
        }});
    }
    for (0..THREAD_COUNT) |i| threads[i].join();

    // 모두 다른 id
    var seen = std.AutoHashMap(u32, void).init(std.testing.allocator);
    defer seen.deinit();
    for (results) |r| {
        try std.testing.expect(r != 0);
        try std.testing.expect(!seen.contains(r));
        try seen.put(r, {});
    }
    try std.testing.expectEqual(@as(usize, THREAD_COUNT), native.create_calls);
    try std.testing.expectEqual(@as(usize, THREAD_COUNT), wm.windows.count());
}

const MixedCtx = struct {
    wm: *WindowManager,
    existing: u32,
    create_ok: std.atomic.Value(usize) = .init(0),
    set_title_ok: std.atomic.Value(usize) = .init(0),

    fn createRun(self: *MixedCtx) void {
        if (self.wm.create(.{})) |_| {
            _ = self.create_ok.fetchAdd(1, .acq_rel);
        } else |_| {}
    }

    fn setTitleRun(self: *MixedCtx) void {
        if (self.wm.setTitle(self.existing, "bang")) |_| {
            _ = self.set_title_ok.fetchAdd(1, .acq_rel);
        } else |_| {}
    }
};

test "concurrent mixed create + setTitle doesn't crash" {
    // 한 스레드는 새 창을 만들고 다른 스레드는 기존 창 제목을 수정
    // 내부 mutex가 없으면 HashMap corruption/crash 가능
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();

    // 사전 창 1개
    const existing = try wm.create(.{});

    const THREAD_COUNT = 20;
    var threads: [THREAD_COUNT]std.Thread = undefined;
    var ctx = MixedCtx{ .wm = &wm, .existing = existing };

    var i: usize = 0;
    while (i < THREAD_COUNT) : (i += 1) {
        if (i % 2 == 0) {
            threads[i] = try std.Thread.spawn(.{}, MixedCtx.createRun, .{&ctx});
        } else {
            threads[i] = try std.Thread.spawn(.{}, MixedCtx.setTitleRun, .{&ctx});
        }
    }
    for (threads) |t| t.join();

    // 모든 작업이 성공해야 (mutex가 경합을 직렬화하므로 단일 실패도 용납 안 함)
    try std.testing.expectEqual(@as(usize, THREAD_COUNT / 2), ctx.create_ok.load(.acquire));
    try std.testing.expectEqual(@as(usize, THREAD_COUNT / 2), ctx.set_title_ok.load(.acquire));
    // 기존(1) + 새로 만든 10 = 11
    try std.testing.expectEqual(@as(usize, 11), wm.windows.count());
}

// ============================================
// name 정규화 / forceNew 탈취 방지
// ============================================

test "forceNew=true does not hijack existing name ownership" {
    // 첫 창이 name="main" 소유 → forceNew=true로 두 번째 창 생성 시 name 탈취 X
    // 두 번째 창은 익명(Window.name=null), fromName은 첫 창을 유지.
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();

    const id1 = try wm.create(.{ .name = "main" });
    const id2 = try wm.create(.{ .name = "main", .force_new = true });

    try std.testing.expect(id1 != id2);
    // fromName은 여전히 첫 창
    try std.testing.expectEqual(@as(?u32, id1), wm.fromName("main"));
    // 첫 창은 name 유지, 두 번째 창은 익명
    try std.testing.expectEqualStrings("main", wm.get(id1).?.name.?);
    try std.testing.expectEqual(@as(?[]const u8, null), wm.get(id2).?.name);
}

test "empty-string name normalizes to null (no by_name entry)" {
    // name="" → name=null 정규화, by_name 등록 X
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();

    const id = try wm.create(.{ .name = "" });
    try std.testing.expectEqual(@as(?[]const u8, null), wm.get(id).?.name);
    try std.testing.expectEqual(@as(?u32, null), wm.fromName(""));

    // 다음 "" 호출도 싱글턴으로 매칭 X (새 창 생성)
    const id2 = try wm.create(.{ .name = "" });
    try std.testing.expect(id != id2);
}

test "create after destroyAll starts fresh" {
    // destroyAll 뒤에 새 창 생성해도 상태 오염 없음 (by_name 정리, id monotonic)
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();

    const a = try wm.create(.{ .name = "foo" });
    _ = try wm.create(.{ .name = "bar" });
    wm.destroyAll();

    // 이전 name이 재사용 가능해야 함
    const c = try wm.create(.{ .name = "foo" });
    try std.testing.expect(c > a);
    try std.testing.expectEqual(@as(?u32, c), wm.fromName("foo"));
    try std.testing.expectEqual(@as(?u32, null), wm.fromName("bar"));

    // 이전 창들은 destroyed 마킹된 채 맵에 잔존 (get으로 조회 가능)
    try std.testing.expect(wm.get(a).?.destroyed);
}

// ============================================
// 동시성 — 같은 id close race
// ============================================

const CloseRaceCtx = struct {
    wm: *WindowManager,
    id: u32,
    success_count: std.atomic.Value(usize) = .init(0),
    destroyed_count: std.atomic.Value(usize) = .init(0),

    fn run(self: *CloseRaceCtx) void {
        if (self.wm.close(self.id)) |ok| {
            if (ok) _ = self.success_count.fetchAdd(1, .acq_rel);
        } else |err| {
            if (err == window.Error.WindowDestroyed) {
                _ = self.destroyed_count.fetchAdd(1, .acq_rel);
            }
        }
    }
};

test "concurrent close on same id yields exactly one success" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();

    const id = try wm.create(.{});

    const THREAD_COUNT = 16;
    var threads: [THREAD_COUNT]std.Thread = undefined;
    var ctx = CloseRaceCtx{ .wm = &wm, .id = id };

    for (0..THREAD_COUNT) |i| {
        threads[i] = try std.Thread.spawn(.{}, CloseRaceCtx.run, .{&ctx});
    }
    for (threads) |t| t.join();

    // 정확히 한 스레드만 실제로 파괴, 나머지는 WindowDestroyed
    try std.testing.expectEqual(@as(usize, 1), ctx.success_count.load(.acquire));
    try std.testing.expectEqual(@as(usize, THREAD_COUNT - 1), ctx.destroyed_count.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), native.destroy_calls);
    try std.testing.expect(wm.get(id).?.destroyed);
}
