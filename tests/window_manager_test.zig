//! WindowManager 단위 테스트 — CEF 없이 순수 로직만.
//!
//! Native vtable을 TestNative stub으로 주입해서 플랫폼 조작 없이 WindowManager
//! 동작을 검증한다. docs/WINDOW_API.md의 "TDD 전략 1단계" 참조.

const std = @import("std");
const window = @import("window");
const TestNative = @import("test_native").TestNative;

const WindowManager = window.WindowManager;
const Native = window.Native;
const CreateOptions = window.CreateOptions;
const Bounds = window.Bounds;

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
// name 검증 — 길이/JSON-unsafe 문자
// ============================================

test "create rejects name with double quote" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();
    try std.testing.expectError(window.Error.InvalidName, wm.create(.{ .name = "a\"b" }));
    try std.testing.expectEqual(@as(usize, 0), native.create_calls);
}

test "create rejects name with backslash" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();
    try std.testing.expectError(window.Error.InvalidName, wm.create(.{ .name = "a\\b" }));
}

test "create rejects name with control character" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();
    try std.testing.expectError(window.Error.InvalidName, wm.create(.{ .name = "a\nb" }));
    try std.testing.expectError(window.Error.InvalidName, wm.create(.{ .name = "a\x00b" }));
}

test "create rejects name exceeding MAX_NAME_LEN" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();
    var buf: [window.MAX_NAME_LEN + 1]u8 = undefined;
    @memset(&buf, 'x');
    try std.testing.expectError(window.Error.InvalidName, wm.create(.{ .name = &buf }));
}

test "create accepts name exactly at MAX_NAME_LEN" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();
    var buf: [window.MAX_NAME_LEN]u8 = undefined;
    @memset(&buf, 'y');
    const id = try wm.create(.{ .name = &buf });
    try std.testing.expect(id >= 1);
}

test "create with empty name is treated as anonymous (no InvalidName)" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();
    // 기존 동작: ""은 null 정규화. 검증이 추가돼도 그대로 익명으로 취급.
    const id = try wm.create(.{ .name = "" });
    try std.testing.expect(id >= 1);
    try std.testing.expectEqual(@as(?u32, null), wm.fromName(""));
}

// ============================================
// Phase 3: frame / transparent / parent_id (외형 옵션)
// ============================================

test "CreateOptions defaults — frame=true, transparent=false, parent_id=null" {
    const opts = window.CreateOptions{};
    try std.testing.expectEqual(true, opts.appearance.frame);
    try std.testing.expectEqual(false, opts.appearance.transparent);
    try std.testing.expectEqual(@as(?u32, null), opts.parent_id);
}

test "CreateOptions Phase 3-D 외형 옵션 defaults" {
    const opts = window.CreateOptions{};
    try std.testing.expectEqual(false, opts.constraints.always_on_top);
    try std.testing.expectEqual(true, opts.constraints.resizable);
    try std.testing.expectEqual(@as(u32, 0), opts.constraints.min_width);
    try std.testing.expectEqual(@as(u32, 0), opts.constraints.min_height);
    try std.testing.expectEqual(@as(u32, 0), opts.constraints.max_width);
    try std.testing.expectEqual(@as(u32, 0), opts.constraints.max_height);
    try std.testing.expectEqual(false, opts.constraints.fullscreen);
    try std.testing.expectEqual(@as(?[]const u8, null), opts.appearance.background_color);
    try std.testing.expectEqual(window.TitleBarStyle.default, opts.appearance.title_bar_style);
}

test "TitleBarStyle enum has 3 variants" {
    const a: window.TitleBarStyle = .default;
    const b: window.TitleBarStyle = .hidden;
    const c: window.TitleBarStyle = .hidden_inset;
    try std.testing.expect(a != b);
    try std.testing.expect(b != c);
    try std.testing.expect(a != c);
}

test "create accepts all Phase 3-D options together (smoke test)" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();
    const id = try wm.create(.{
        .appearance = .{ .background_color = "#1d1d1f", .title_bar_style = .hidden },
        .constraints = .{
            .always_on_top = true,
            .resizable = false,
            .min_width = 320,
            .min_height = 200,
            .max_width = 1920,
            .max_height = 1080,
            .fullscreen = false,
        },
    });
    try std.testing.expect(id >= 1);
}

test "create with min_width=u32 max value — overflow 없이 받아들임" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();
    const id = try wm.create(.{ .constraints = .{ .min_width = std.math.maxInt(u32) } });
    try std.testing.expect(id >= 1);
}

test "create with parent destroy — child position 옵션 보존" {
    // 부모 close → 자식의 parent_id는 그대로 (orphan으로 남아있어도 메타정보 유지).
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();
    const parent_id = try wm.create(.{ .name = "p" });
    const child_id = try wm.create(.{ .parent_id = parent_id });
    try wm.destroy(parent_id);
    const child = wm.get(child_id) orelse return error.MissingChild;
    try std.testing.expect(!child.destroyed);
    try std.testing.expectEqual(@as(?u32, parent_id), child.parent_id);
}

test "create accepts frame=false (frameless) without error" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();
    const id = try wm.create(.{ .appearance = .{ .frame = false } });
    try std.testing.expect(id >= 1);
    try std.testing.expectEqual(@as(usize, 1), native.create_calls);
}

test "create accepts transparent=true without error" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();
    const id = try wm.create(.{ .appearance = .{ .transparent = true } });
    try std.testing.expect(id >= 1);
}

test "create with parent_id: 부모 close해도 자식은 살아있음 (재귀 close X)" {
    // PLAN 핵심 결정: 부모-자식은 시각 관계만, 재귀 close 없음.
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();

    const parent_id = try wm.create(.{ .name = "parent" });
    const child_id = try wm.create(.{ .name = "child", .parent_id = parent_id });
    try std.testing.expect(parent_id != child_id);

    // 부모만 destroy
    try wm.destroy(parent_id);

    // 자식은 여전히 살아있어야
    const child = wm.get(child_id) orelse return error.ChildVanished;
    try std.testing.expect(!child.destroyed);
    try std.testing.expectEqual(parent_id, child.parent_id.?);
}

test "create with parent_id pointing to nonexistent window — 그대로 옵션 보존" {
    // WM은 parent_id 유효성 검증 안 함 (native vtable의 책임).
    // 잘못된 id를 받아도 child window 자체 생성은 성공해야.
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();
    const id = try wm.create(.{ .parent_id = 999 });
    try std.testing.expect(id >= 1);
    try std.testing.expectEqual(@as(?u32, 999), wm.get(id).?.parent_id);
}

test "create with parent_id + force_new=true — singleton 우회 시에도 parent_id 보존" {
    // 같은 name이지만 force_new=true → 새 익명 창 생성. parent_id가 옵션이므로 무시되지 않아야.
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();

    const parent_id = try wm.create(.{ .name = "parent" });
    _ = try wm.create(.{ .name = "child", .parent_id = parent_id });
    const child2_id = try wm.create(.{ .name = "child", .parent_id = parent_id, .force_new = true });

    const child2 = wm.get(child2_id) orelse return error.MissingChild2;
    // forceNew=true는 by_name 등록 안 함 (name 탈취 방지) — Window.name=null이지만 parent_id는 유지.
    try std.testing.expectEqual(@as(?[]const u8, null), child2.name);
    try std.testing.expectEqual(@as(?u32, parent_id), child2.parent_id);
}

test "create child + child destroy — 부모는 영향 없음" {
    // 자식 close → 부모는 그대로. all-closed도 발화 안 됨 (부모가 살아있음).
    var native = TestNative{};
    var sink = TestSink{};
    defer sink.deinit();
    var wm = newManager(&native);
    defer wm.deinit();
    wm.setEventSink(sink.asSink());

    const parent_id = try wm.create(.{ .name = "parent" });
    const child_id = try wm.create(.{ .parent_id = parent_id });
    sink.reset();

    try wm.destroy(child_id);

    // 부모는 살아있고 destroyed=false
    const parent = wm.get(parent_id) orelse return error.ParentVanished;
    try std.testing.expect(!parent.destroyed);
    // child only — closed 1회. all-closed는 발화 X (parent 살아있음).
    try std.testing.expectEqual(@as(usize, 0), countEvents(&sink, window.events.all_closed));
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

test "setVisible/focus on destroyed window returns WindowDestroyed" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();

    const id = try wm.create(.{});
    try wm.destroy(id);
    try std.testing.expectError(window.Error.WindowDestroyed, wm.setVisible(id, false));
    try std.testing.expectError(window.Error.WindowDestroyed, wm.focus(id));
}

test "close/setVisible/focus on unknown id returns WindowNotFound" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();

    try std.testing.expectError(window.Error.WindowNotFound, wm.close(999));
    try std.testing.expectError(window.Error.WindowNotFound, wm.setVisible(999, true));
    try std.testing.expectError(window.Error.WindowNotFound, wm.focus(999));
    try std.testing.expectError(window.Error.WindowNotFound, wm.setTitle(999, "x"));
    try std.testing.expectError(window.Error.WindowNotFound, wm.setBounds(999, .{}));
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

test "setVisible updates state and calls native" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();

    const id = try wm.create(.{});
    try std.testing.expect(wm.get(id).?.state.visible); // 기본값 true
    try wm.setVisible(id, false);
    try std.testing.expect(!wm.get(id).?.state.visible);
    try std.testing.expectEqual(@as(usize, 1), native.set_visible_calls);
    try wm.setVisible(id, true);
    try std.testing.expect(wm.get(id).?.state.visible);
    try std.testing.expectEqual(@as(usize, 2), native.set_visible_calls);
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

    try wm.destroyAll();

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

test "window:created payload includes name when present (Phase 2.5 표준화)" {
    // 표준화: {windowId, name?} — 명명된 창은 name도 함께 emit, 익명은 id만.
    // 플러그인이 wm.get(id) 조회 없이 lifecycle 이벤트만으로 분기 가능.
    var native = TestNative{};
    var sink = TestSink{};
    defer sink.deinit();
    var wm = newManager(&native);
    defer wm.deinit();
    wm.setEventSink(sink.asSink());

    _ = try wm.create(.{ .name = "about" });
    try std.testing.expect(contains(sink.events.items[0].data, "\"windowId\":1"));
    try std.testing.expect(contains(sink.events.items[0].data, "\"name\":\"about\""));
}

test "window:created payload omits name for anonymous windows" {
    var native = TestNative{};
    var sink = TestSink{};
    defer sink.deinit();
    var wm = newManager(&native);
    defer wm.deinit();
    wm.setEventSink(sink.asSink());

    _ = try wm.create(.{});
    try std.testing.expect(contains(sink.events.items[0].data, "\"windowId\":1"));
    try std.testing.expect(!contains(sink.events.items[0].data, "\"name\""));
}

test "window:closed payload preserves name even after destroy (snapshot before destroy)" {
    var native = TestNative{};
    var sink = TestSink{};
    defer sink.deinit();
    var wm = newManager(&native);
    defer wm.deinit();
    wm.setEventSink(sink.asSink());

    const id = try wm.create(.{ .name = "settings" });
    sink.events.clearRetainingCapacity();
    _ = try wm.close(id);

    // close + closed 두 이벤트 모두 name 포함
    var found_close = false;
    var found_closed = false;
    for (sink.events.items) |ev| {
        if (std.mem.eql(u8, ev.name, "window:close") and contains(ev.data, "\"name\":\"settings\"")) {
            found_close = true;
        }
        if (std.mem.eql(u8, ev.name, "window:closed") and contains(ev.data, "\"name\":\"settings\"")) {
            found_closed = true;
        }
    }
    try std.testing.expect(found_close);
    try std.testing.expect(found_closed);
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
    // window:close, window:closed 순서 + (마지막 창이므로) window:all-closed
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

    try wm.destroyAll();
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

test "destroy does not emit window:close or window:closed (silent destruction)" {
    var native = TestNative{};
    var sink = TestSink{};
    defer sink.deinit();
    var wm = newManager(&native);
    defer wm.deinit();
    wm.setEventSink(sink.asSink());

    const id = try wm.create(.{});
    sink.events.clearRetainingCapacity();

    try wm.destroy(id);
    // destroy()는 close/closed를 발화하지 않음 (all-closed는 라이프사이클 이벤트라 별도)
    try std.testing.expectEqual(@as(usize, 0), countEvents(&sink, window.events.close));
    try std.testing.expectEqual(@as(usize, 0), countEvents(&sink, window.events.closed));
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
    try wm.destroyAll();

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

// ============================================
// Event payload 내용 검증
// ============================================

test "close event payloads carry windowId" {
    var native = TestNative{};
    var sink = TestSink{};
    defer sink.deinit();
    var wm = newManager(&native);
    defer wm.deinit();
    wm.setEventSink(sink.asSink());

    const id = try wm.create(.{});
    sink.reset();

    _ = try wm.close(id);

    var buf: [64]u8 = undefined;
    const expected = try std.fmt.bufPrint(&buf, "\"windowId\":{d}", .{id});
    // window:close / window:closed 모두 id 포함
    try std.testing.expect(contains(sink.events.items[0].data, expected));
    try std.testing.expectEqualStrings("window:close", sink.events.items[0].name);
    try std.testing.expect(contains(sink.events.items[1].data, expected));
    try std.testing.expectEqualStrings("window:closed", sink.events.items[1].name);
}

test "destroyAll event payloads carry each windowId" {
    var native = TestNative{};
    var sink = TestSink{};
    defer sink.deinit();
    var wm = newManager(&native);
    defer wm.deinit();
    wm.setEventSink(sink.asSink());

    const id1 = try wm.create(.{});
    const id2 = try wm.create(.{});
    sink.reset();

    try wm.destroyAll();

    // 각 창마다 window:closed 하나씩 + all-closed 1회
    var closed_count: usize = 0;
    var seen1 = false;
    var seen2 = false;
    var buf: [64]u8 = undefined;
    const e1 = try std.fmt.bufPrint(&buf, "\"windowId\":{d}", .{id1});
    var buf2: [64]u8 = undefined;
    const e2 = try std.fmt.bufPrint(&buf2, "\"windowId\":{d}", .{id2});
    for (sink.events.items) |ev| {
        if (std.mem.eql(u8, ev.name, window.events.closed)) {
            closed_count += 1;
            if (contains(ev.data, e1)) seen1 = true;
            if (contains(ev.data, e2)) seen2 = true;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), closed_count);
    try std.testing.expect(seen1);
    try std.testing.expect(seen2);
}

test "destroyAll closed payloads include each window's name (Phase 2.5 표준화)" {
    // 명명된 창과 익명 창 혼합. 명명된 창의 name이 closed payload에 포함돼야.
    var native = TestNative{};
    var sink = TestSink{};
    defer sink.deinit();
    var wm = newManager(&native);
    defer wm.deinit();
    wm.setEventSink(sink.asSink());

    _ = try wm.create(.{ .name = "main" });
    _ = try wm.create(.{}); // 익명
    _ = try wm.create(.{ .name = "popup" });
    sink.reset();

    try wm.destroyAll();

    var found_main = false;
    var found_popup = false;
    var anon_with_no_name: usize = 0; // 익명 창은 name 필드가 없어야
    for (sink.events.items) |ev| {
        if (!std.mem.eql(u8, ev.name, window.events.closed)) continue;
        if (contains(ev.data, "\"name\":\"main\"")) found_main = true;
        if (contains(ev.data, "\"name\":\"popup\"")) found_popup = true;
        if (!contains(ev.data, "\"name\"")) anon_with_no_name += 1;
    }
    try std.testing.expect(found_main);
    try std.testing.expect(found_popup);
    try std.testing.expectEqual(@as(usize, 1), anon_with_no_name);
}

// ============================================
// 재진입 — listener 안에서 WindowManager 메서드 호출
// ============================================

const ReentrantSink = struct {
    wm: *WindowManager,
    target_id: u32 = 0,
    destroy_on_close: bool = false,
    close_events: usize = 0,
    closed_events: usize = 0,

    fn asSink(self: *ReentrantSink) window.EventSink {
        return .{ .vtable = &vtable, .ctx = self };
    }

    const vtable: window.EventSink.VTable = .{
        .emit = onEmit,
        .emit_cancelable = onEmitCancelable,
    };

    fn fromCtx(ctx: ?*anyopaque) *ReentrantSink {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn onEmit(ctx: ?*anyopaque, name: []const u8, _: []const u8) void {
        const self = fromCtx(ctx);
        if (std.mem.eql(u8, name, "window:closed")) self.closed_events += 1;
    }

    fn onEmitCancelable(ctx: ?*anyopaque, name: []const u8, _: []const u8, _: *window.SujiEvent) void {
        const self = fromCtx(ctx);
        if (std.mem.eql(u8, name, "window:close")) {
            self.close_events += 1;
            if (self.destroy_on_close) {
                // listener 안에서 강제 파괴 — close()의 Phase 3 재확인이 WindowDestroyed 반환해야
                _ = self.wm.destroy(self.target_id) catch {};
            }
        }
    }
};

test "close detects reentrant destroy during listener (Phase 3 recheck)" {
    // window:close listener가 wm.destroy(id)를 호출하면 Phase 3에서 이미 destroyed 감지.
    // close()는 Error.WindowDestroyed를 반환하고, window:closed는 발화되지 않아야 한다.
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();

    const id = try wm.create(.{});
    var sink = ReentrantSink{ .wm = &wm, .target_id = id, .destroy_on_close = true };
    wm.setEventSink(sink.asSink());

    const res = wm.close(id);
    try std.testing.expectError(window.Error.WindowDestroyed, res);

    // listener가 한 번 호출됐고 closed 이벤트는 발화 X
    try std.testing.expectEqual(@as(usize, 1), sink.close_events);
    try std.testing.expectEqual(@as(usize, 0), sink.closed_events);
    // native.destroyWindow는 listener 내부의 destroy() 호출에서 1회만
    try std.testing.expectEqual(@as(usize, 1), native.destroy_calls);
    try std.testing.expect(wm.get(id).?.destroyed);
}

// ============================================
// OOM — FailingAllocator로 create 부분 실패 경로 검증
// ============================================

test "create propagates OOM, leaks no memory, and reclaims native handle" {
    // fail_index를 0부터 증가시켜 각 allocation 지점마다 create 실패를 유발.
    // std.testing.allocator가 메모리 누수를 자동 검증하고, native handle은 errdefer로
    // destroyWindow에 회수되어야 한다.
    var native = TestNative{};

    // 먼저 성공 경로에서 필요한 allocation 수를 측정
    var probe = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = std.math.maxInt(usize) });
    var wm_probe = WindowManager.init(probe.allocator(), std.testing.io, native.asNative());
    _ = try wm_probe.create(.{ .name = "x", .title = "Hi" });
    wm_probe.deinit();
    const total_allocs = probe.alloc_index;
    try std.testing.expect(total_allocs > 0);

    native = .{}; // 카운터 리셋

    var i: usize = 0;
    while (i < total_allocs) : (i += 1) {
        var fail = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = i });
        var wm = WindowManager.init(fail.allocator(), std.testing.io, native.asNative());
        defer wm.deinit();

        const before_create = native.create_calls;
        const before_destroy = native.destroy_calls;
        if (wm.create(.{ .name = "x", .title = "Hi" })) |_| {
            // 이 fail_index에서는 실패 지점이 없어서 성공 — 다음 인덱스로
        } else |err| {
            try std.testing.expectEqual(window.Error.OutOfMemory, err);
            // native.createWindow 호출됐다면 handle이 errdefer로 회수되어야 함
            const creates = native.create_calls - before_create;
            const destroys = native.destroy_calls - before_destroy;
            try std.testing.expectEqual(creates, destroys);
        }
    }
}

// ============================================
// JSON escape 버그 재현/회귀
// ============================================

test "window:created payload is valid JSON + validation blocks unsafe/overlong names" {
    // payload에는 name이 들어가지 않으므로 허용된 name에선 항상 valid JSON.
    // 허용되지 않는 name(JSON-unsafe / 과다 길이)은 InvalidName으로 거부되어 애초에
    // payload까지 도달하지 않는다 — 두 경로 모두 wire 무결성을 보장.
    var native = TestNative{};
    var sink = TestSink{};
    defer sink.deinit();
    var wm = newManager(&native);
    defer wm.deinit();
    wm.setEventSink(sink.asSink());

    // 허용 경로: 정상 name + 익명 창. payload는 valid JSON이어야 한다.
    _ = try wm.create(.{ .name = "settings" });
    _ = try wm.create(.{});

    // 거부 경로: 특수문자 + MAX 초과 길이 — 둘 다 InvalidName.
    try std.testing.expectError(window.Error.InvalidName, wm.create(.{ .name = "foo\"bar\\baz\n" }));
    const long = "x" ** (window.MAX_NAME_LEN + 1);
    try std.testing.expectError(window.Error.InvalidName, wm.create(.{ .name = long }));

    const Parsed = struct { windowId: u32 };
    for (sink.events.items) |ev| {
        const parsed = try std.json.parseFromSlice(
            Parsed,
            std.testing.allocator,
            ev.data,
            .{ .ignore_unknown_fields = true },
        );
        defer parsed.deinit();
        try std.testing.expect(parsed.value.windowId > 0);
    }
}

// ============================================
// OOM이 by_name 등록을 조용히 스킵하면 싱글턴 정책이 깨지는 버그 재현
// ============================================

/// 특정 fail_at 인덱스의 alloc 한 번만 실패시키고 이후는 복구되는 allocator.
/// FailingAllocator는 fail_index 이후 계속 실패하지만, 이 테스트는 create가 부분 성공
/// (by_name.put만 실패)하는 상태를 만들기 위해 one-shot 실패가 필요.
const OneShotFail = struct {
    backing: std.mem.Allocator,
    fail_at: usize,
    count: usize = 0,

    fn allocator(self: *OneShotFail) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn ctx(p: *anyopaque) *OneShotFail {
        return @ptrCast(@alignCast(p));
    }

    fn alloc(p: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self = ctx(p);
        defer self.count += 1;
        if (self.count == self.fail_at) return null;
        return self.backing.vtable.alloc(self.backing.ptr, len, alignment, ra);
    }

    fn resize(p: *anyopaque, m: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self = ctx(p);
        return self.backing.vtable.resize(self.backing.ptr, m, alignment, new_len, ra);
    }

    fn remap(p: *anyopaque, m: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self = ctx(p);
        return self.backing.vtable.remap(self.backing.ptr, m, alignment, new_len, ra);
    }

    fn free(p: *anyopaque, m: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self = ctx(p);
        self.backing.vtable.free(self.backing.ptr, m, alignment, ra);
    }
};

test "by_name OOM must not silently break singleton policy" {
    // 회귀 방지: 첫 create 중 어떤 alloc이 실패해도, 이후 같은 name으로의 create가
    // "새 창 생성"으로 빠지면 안 된다. 옵션 두 가지가 유효:
    //   (a) create 자체가 OOM을 반환해서 by_name도 등록 안 됨 → 두 번째 create가 새 창 생성 OK
    //   (b) create가 성공 → by_name이 제대로 등록되어 싱글턴 유지
    // 허용 안 되는 것: create 성공 + by_name 누락 (현재 버그)
    var native = TestNative{};

    // probe로 total_allocs 측정
    var probe = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = std.math.maxInt(usize) });
    var wm_probe = WindowManager.init(probe.allocator(), std.testing.io, native.asNative());
    _ = try wm_probe.create(.{ .name = "singleton" });
    wm_probe.deinit();
    const total = probe.alloc_index;

    var i: usize = 0;
    while (i < total) : (i += 1) {
        var one = OneShotFail{ .backing = std.testing.allocator, .fail_at = i };
        var wm = WindowManager.init(one.allocator(), std.testing.io, native.asNative());
        defer wm.deinit();

        const res = wm.create(.{ .name = "singleton" });
        if (res) |id1| {
            // create 성공 — 반드시 by_name에도 등록돼서 두 번째 create가 싱글턴 반환해야
            const id2 = try wm.create(.{ .name = "singleton" });
            try std.testing.expectEqual(id1, id2);
        } else |_| {
            // OOM 반환 — 정상 실패 경로
        }
    }
}

// ============================================
// destroyAll OOM — 일관된 에러 전파 (half-state 금지)
// ============================================

test "destroyAll returns OOM when capacity reservation fails, leaves windows alive" {
    // destroyAll이 closed_ids.ensureTotalCapacity 실패 시 조용히 스킵하면
    // 창은 파괴됐는데 window:closed 이벤트가 안 발화되는 half-state가 된다.
    // Electron식: OOM은 fatal. 코어는 에러 전파, 호출자(앱)가 abort 결정.
    //
    // 계약: destroyAll이 에러 반환 시 창은 아무것도 파괴하지 않는다 (all-or-nothing).
    var native = TestNative{};
    var sink = TestSink{};
    defer sink.deinit();

    // probe: destroyAll 경로 total_allocs 측정
    var probe = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = std.math.maxInt(usize) });
    var wm_probe = WindowManager.init(probe.allocator(), std.testing.io, native.asNative());
    wm_probe.setEventSink(sink.asSink());
    _ = try wm_probe.create(.{});
    _ = try wm_probe.create(.{});
    const allocs_before = probe.alloc_index;
    try wm_probe.destroyAll();
    const destroyall_allocs = probe.alloc_index - allocs_before;
    wm_probe.deinit();
    sink.reset();

    // destroyAll 경로 첫 alloc 실패 유도
    native = .{};
    var one = OneShotFail{ .backing = std.testing.allocator, .fail_at = allocs_before };
    var wm = WindowManager.init(one.allocator(), std.testing.io, native.asNative());
    defer wm.deinit();
    wm.setEventSink(sink.asSink());

    _ = try wm.create(.{});
    _ = try wm.create(.{});
    sink.reset();

    const res = wm.destroyAll();
    try std.testing.expectError(window.Error.OutOfMemory, res);

    // 창이 실제 파괴되지 않아야 (all-or-nothing)
    try std.testing.expectEqual(@as(usize, 0), native.destroy_calls);
    // 이벤트도 발화 안 됨 (한 창만 부분 발화 금지)
    var closed_count: usize = 0;
    for (sink.events.items) |ev| {
        if (std.mem.eql(u8, ev.name, "window:closed")) closed_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), closed_count);

    _ = destroyall_allocs;
}

// ============================================
// 동시 close + preventDefault — 모든 스레드가 취소돼야 함 (설계 검증)
// ============================================

const ConcurrentPreventCtx = struct {
    wm: *WindowManager,
    id: u32,
    cancelled: std.atomic.Value(usize) = .init(0),
    succeeded: std.atomic.Value(usize) = .init(0),
    errored: std.atomic.Value(usize) = .init(0),

    fn run(self: *ConcurrentPreventCtx) void {
        if (self.wm.close(self.id)) |ok| {
            if (ok) {
                _ = self.succeeded.fetchAdd(1, .acq_rel);
            } else {
                _ = self.cancelled.fetchAdd(1, .acq_rel);
            }
        } else |_| {
            _ = self.errored.fetchAdd(1, .acq_rel);
        }
    }
};

/// 모든 cancelable 이벤트에 preventDefault를 호출하는 thread-safe sink.
/// TestSink는 ArrayList append에 mutex가 없어 동시 발화 테스트에서 crash.
const PreventAllSink = struct {
    fn asSink() window.EventSink {
        return .{ .vtable = &vtable, .ctx = null };
    }
    const vtable: window.EventSink.VTable = .{
        .emit = onEmit,
        .emit_cancelable = onEmitCancelable,
    };
    fn onEmit(_: ?*anyopaque, _: []const u8, _: []const u8) void {}
    fn onEmitCancelable(_: ?*anyopaque, _: []const u8, _: []const u8, ev: *window.SujiEvent) void {
        ev.preventDefault();
    }
};

test "concurrent close with preventDefault cancels on every thread" {
    // 모든 스레드가 같은 id로 close → listener가 항상 preventDefault → 어떤 스레드도
    // 실제 파괴 못 해야 함 (close는 false 반환).
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();
    wm.setEventSink(PreventAllSink.asSink());

    const id = try wm.create(.{});

    const THREAD_COUNT = 16;
    var threads: [THREAD_COUNT]std.Thread = undefined;
    var ctx = ConcurrentPreventCtx{ .wm = &wm, .id = id };

    for (0..THREAD_COUNT) |i| {
        threads[i] = try std.Thread.spawn(.{}, ConcurrentPreventCtx.run, .{&ctx});
    }
    for (threads) |t| t.join();

    try std.testing.expectEqual(@as(usize, THREAD_COUNT), ctx.cancelled.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), ctx.succeeded.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), ctx.errored.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), native.destroy_calls);
    try std.testing.expect(!wm.get(id).?.destroyed);
}

// ============================================
// setTitle OOM — 기존 title 보존 (UAF 방지 invariant)
// ============================================

test "setTitle OOM preserves existing title (no UAF)" {
    var native = TestNative{};

    var probe = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = std.math.maxInt(usize) });
    var wm_probe = WindowManager.init(probe.allocator(), std.testing.io, native.asNative());
    _ = try wm_probe.create(.{ .title = "Original" });
    const after_create = probe.alloc_index;
    wm_probe.deinit();
    native = .{};

    // create 직후 첫 alloc (= setTitle의 dupe) 실패 유도
    var fail = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = after_create });
    var wm = WindowManager.init(fail.allocator(), std.testing.io, native.asNative());
    defer wm.deinit();

    const id = try wm.create(.{ .title = "Original" });
    try std.testing.expectError(window.Error.OutOfMemory, wm.setTitle(id, "New"));
    try std.testing.expectEqualStrings("Original", wm.get(id).?.title);
    try std.testing.expectEqual(@as(usize, 0), native.set_title_calls);
}

// ============================================
// close 에러 경로 — 이벤트 누출 금지
// ============================================

test "close on unknown/destroyed id emits no events" {
    var native = TestNative{};
    var sink = TestSink{};
    defer sink.deinit();
    var wm = newManager(&native);
    defer wm.deinit();
    wm.setEventSink(sink.asSink());

    try std.testing.expectError(window.Error.WindowNotFound, wm.close(9999));
    try std.testing.expectEqual(@as(usize, 0), sink.events.items.len);

    const id = try wm.create(.{});
    try wm.destroy(id);
    sink.reset();

    try std.testing.expectError(window.Error.WindowDestroyed, wm.close(id));
    try std.testing.expectEqual(@as(usize, 0), sink.events.items.len);
}

// ============================================
// 동시성 — destroy() race (close race와 별도 경로 검증)
// ============================================

const DestroyRaceCtx = struct {
    wm: *WindowManager,
    id: u32,
    ok_count: std.atomic.Value(usize) = .init(0),
    destroyed_count: std.atomic.Value(usize) = .init(0),

    fn run(self: *DestroyRaceCtx) void {
        if (self.wm.destroy(self.id)) |_| {
            _ = self.ok_count.fetchAdd(1, .acq_rel);
        } else |err| {
            if (err == window.Error.WindowDestroyed) {
                _ = self.destroyed_count.fetchAdd(1, .acq_rel);
            }
        }
    }
};

test "concurrent destroy on same id yields exactly one success" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();

    const id = try wm.create(.{});

    const THREAD_COUNT = 16;
    var threads: [THREAD_COUNT]std.Thread = undefined;
    var ctx = DestroyRaceCtx{ .wm = &wm, .id = id };

    for (0..THREAD_COUNT) |i| {
        threads[i] = try std.Thread.spawn(.{}, DestroyRaceCtx.run, .{&ctx});
    }
    for (threads) |t| t.join();

    try std.testing.expectEqual(@as(usize, 1), ctx.ok_count.load(.acquire));
    try std.testing.expectEqual(@as(usize, THREAD_COUNT - 1), ctx.destroyed_count.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), native.destroy_calls);
    try std.testing.expect(wm.get(id).?.destroyed);
}

// ============================================
// destroyLocked 순서 invariant — destroyed 마킹이 native.destroyWindow보다 먼저
// (CefNative의 DoClose 재진입 시, WM이 이미 "닫는 중"임을 감지할 수 있어야)
// ============================================

test "destroy marks destroyed before native.destroyWindow callback" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();

    const id = try wm.create(.{});
    native.observe_wm = &wm;

    try wm.destroy(id);
    try std.testing.expectEqual(@as(?bool, true), native.observed_destroyed_during_destroy);
}

test "close marks destroyed before native.destroyWindow callback" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();

    const id = try wm.create(.{});
    native.observe_wm = &wm;

    _ = try wm.close(id);
    try std.testing.expectEqual(@as(?bool, true), native.observed_destroyed_during_destroy);
}

test "destroyAll marks destroyed before native.destroyWindow callback" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();

    _ = try wm.create(.{});
    native.observe_wm = &wm;

    try wm.destroyAll();
    try std.testing.expectEqual(@as(?bool, true), native.observed_destroyed_during_destroy);
}

// ============================================
// tryClose — 외부 트리거(CEF DoClose)용 "물어보기" 경로
// ============================================

test "tryClose on unknown id returns WindowNotFound" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();
    try std.testing.expectError(window.Error.WindowNotFound, wm.tryClose(999));
}

test "tryClose on destroyed id returns WindowDestroyed" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();
    const id = try wm.create(.{});
    try wm.destroy(id);
    try std.testing.expectError(window.Error.WindowDestroyed, wm.tryClose(id));
}

test "tryClose without sink returns true" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();
    const id = try wm.create(.{});
    try std.testing.expect(try wm.tryClose(id));
}

test "tryClose does not call native.destroyWindow nor mark destroyed" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();
    const id = try wm.create(.{});
    _ = try wm.tryClose(id);
    try std.testing.expectEqual(@as(usize, 0), native.destroy_calls);
    try std.testing.expect(!wm.get(id).?.destroyed);
}

test "tryClose with sink emits window:close only (no window:closed)" {
    var native = TestNative{};
    var sink = TestSink{};
    defer sink.deinit();
    var wm = newManager(&native);
    defer wm.deinit();
    wm.setEventSink(sink.asSink());

    const id = try wm.create(.{});
    sink.reset();

    const ok = try wm.tryClose(id);
    try std.testing.expect(ok);
    try std.testing.expectEqual(@as(usize, 1), sink.events.items.len);
    try std.testing.expectEqualStrings(window.events.close, sink.events.items[0].name);
    try std.testing.expect(sink.events.items[0].cancelable);
}

test "tryClose payload includes name for named window (Phase 2.5 표준화)" {
    var native = TestNative{};
    var sink = TestSink{};
    defer sink.deinit();
    var wm = newManager(&native);
    defer wm.deinit();
    wm.setEventSink(sink.asSink());

    const id = try wm.create(.{ .name = "settings" });
    sink.reset();
    _ = try wm.tryClose(id);

    try std.testing.expectEqual(@as(usize, 1), sink.events.items.len);
    try std.testing.expectEqualStrings(window.events.close, sink.events.items[0].name);
    try std.testing.expect(contains(sink.events.items[0].data, "\"name\":\"settings\""));
}

test "tryClose with preventDefault returns false, no destroy, no closed event" {
    var native = TestNative{};
    var sink = TestSink{ .prevent_for = window.events.close };
    defer sink.deinit();
    var wm = newManager(&native);
    defer wm.deinit();
    wm.setEventSink(sink.asSink());

    const id = try wm.create(.{});
    sink.reset();

    const ok = try wm.tryClose(id);
    try std.testing.expect(!ok);
    try std.testing.expectEqual(@as(usize, 0), native.destroy_calls);
    try std.testing.expect(!wm.get(id).?.destroyed);
    // window:close만 발화, window:closed는 발화 X
    var close_count: usize = 0;
    var closed_count: usize = 0;
    for (sink.events.items) |ev| {
        if (std.mem.eql(u8, ev.name, window.events.close)) close_count += 1;
        if (std.mem.eql(u8, ev.name, window.events.closed)) closed_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), close_count);
    try std.testing.expectEqual(@as(usize, 0), closed_count);
}

// ============================================
// markClosedExternal — 외부(CEF OnBeforeClose)가 이미 파괴한 창 통지
// ============================================

test "markClosedExternal on unknown id returns WindowNotFound" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();
    try std.testing.expectError(window.Error.WindowNotFound, wm.markClosedExternal(999));
}

test "markClosedExternal on already destroyed returns WindowDestroyed" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();
    const id = try wm.create(.{});
    try wm.destroy(id);
    try std.testing.expectError(window.Error.WindowDestroyed, wm.markClosedExternal(id));
}

test "markClosedExternal marks destroyed + clears by_name + does not call native" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();

    const id = try wm.create(.{ .name = "main" });
    try wm.markClosedExternal(id);

    try std.testing.expect(wm.get(id).?.destroyed);
    try std.testing.expectEqual(@as(?u32, null), wm.fromName("main"));
    try std.testing.expectEqual(@as(usize, 0), native.destroy_calls);
}

test "markClosedExternal emits window:closed (not window:close)" {
    var native = TestNative{};
    var sink = TestSink{};
    defer sink.deinit();
    var wm = newManager(&native);
    defer wm.deinit();
    wm.setEventSink(sink.asSink());

    const id = try wm.create(.{});
    sink.reset();

    try wm.markClosedExternal(id);
    // close는 발화 X, closed는 1회 (all-closed는 별개)
    try std.testing.expectEqual(@as(usize, 0), countEvents(&sink, window.events.close));
    try std.testing.expectEqual(@as(usize, 1), countEvents(&sink, window.events.closed));
}

test "markClosedExternal payload includes name for named window (Phase 2.5 표준화)" {
    // by_name 제거가 emit 전에 일어나도 name snapshot이 보존돼야 한다는 회귀 방지.
    var native = TestNative{};
    var sink = TestSink{};
    defer sink.deinit();
    var wm = newManager(&native);
    defer wm.deinit();
    wm.setEventSink(sink.asSink());

    const id = try wm.create(.{ .name = "popup" });
    sink.reset();
    try wm.markClosedExternal(id);

    var found = false;
    for (sink.events.items) |ev| {
        if (std.mem.eql(u8, ev.name, window.events.closed) and contains(ev.data, "\"name\":\"popup\"")) {
            found = true;
        }
    }
    try std.testing.expect(found);
}

// ============================================
// findByNativeHandle — CEF 콜백 → WM id 역조회
// ============================================

test "findByNativeHandle returns id for live window" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();
    const id = try wm.create(.{});
    const handle = wm.get(id).?.native_handle;
    try std.testing.expectEqual(@as(?u32, id), wm.findByNativeHandle(handle));
}

test "findByNativeHandle returns id even for destroyed window" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();
    const id = try wm.create(.{});
    const handle = wm.get(id).?.native_handle;
    try wm.destroy(id);
    // destroyed 상태여도 역조회 가능해야 (OnBeforeClose 중복 처리 방지 판단에 필요)
    try std.testing.expectEqual(@as(?u32, id), wm.findByNativeHandle(handle));
}

test "findByNativeHandle returns null for unknown handle" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();
    _ = try wm.create(.{});
    try std.testing.expectEqual(@as(?u32, null), wm.findByNativeHandle(0xDEADBEEF));
}

// ============================================
// 통합 — tryClose + markClosedExternal 조합이 CEF 외부 close 흐름 모사
// ============================================

// ============================================
// window:all-closed — 마지막 창 파괴 시 발화
// ============================================

fn countEvents(sink: *const TestSink, name: []const u8) usize {
    var n: usize = 0;
    for (sink.events.items) |ev| if (std.mem.eql(u8, ev.name, name)) {
        n += 1;
    };
    return n;
}

test "all-closed fires after closing last window via close()" {
    var native = TestNative{};
    var sink = TestSink{};
    defer sink.deinit();
    var wm = newManager(&native);
    defer wm.deinit();
    wm.setEventSink(sink.asSink());

    const id = try wm.create(.{});
    sink.reset();

    _ = try wm.close(id);
    try std.testing.expectEqual(@as(usize, 1), countEvents(&sink, window.events.all_closed));
}

test "all-closed does NOT fire when closing one of multiple windows" {
    var native = TestNative{};
    var sink = TestSink{};
    defer sink.deinit();
    var wm = newManager(&native);
    defer wm.deinit();
    wm.setEventSink(sink.asSink());

    const id1 = try wm.create(.{});
    _ = try wm.create(.{});
    sink.reset();

    _ = try wm.close(id1);
    try std.testing.expectEqual(@as(usize, 0), countEvents(&sink, window.events.all_closed));
}

test "all-closed does NOT fire when close is preventDefault-ed" {
    var native = TestNative{};
    var sink = TestSink{ .prevent_for = window.events.close };
    defer sink.deinit();
    var wm = newManager(&native);
    defer wm.deinit();
    wm.setEventSink(sink.asSink());

    const id = try wm.create(.{});
    sink.reset();

    _ = try wm.close(id);
    try std.testing.expectEqual(@as(usize, 0), countEvents(&sink, window.events.all_closed));
}

test "all-closed fires after destroy() of last window" {
    var native = TestNative{};
    var sink = TestSink{};
    defer sink.deinit();
    var wm = newManager(&native);
    defer wm.deinit();
    wm.setEventSink(sink.asSink());

    const id = try wm.create(.{});
    sink.reset();

    try wm.destroy(id);
    try std.testing.expectEqual(@as(usize, 1), countEvents(&sink, window.events.all_closed));
}

test "all-closed fires after markClosedExternal of last window" {
    var native = TestNative{};
    var sink = TestSink{};
    defer sink.deinit();
    var wm = newManager(&native);
    defer wm.deinit();
    wm.setEventSink(sink.asSink());

    const id = try wm.create(.{});
    sink.reset();

    try wm.markClosedExternal(id);
    try std.testing.expectEqual(@as(usize, 1), countEvents(&sink, window.events.all_closed));
}

test "all-closed fires once after destroyAll" {
    var native = TestNative{};
    var sink = TestSink{};
    defer sink.deinit();
    var wm = newManager(&native);
    defer wm.deinit();
    wm.setEventSink(sink.asSink());

    _ = try wm.create(.{});
    _ = try wm.create(.{});
    _ = try wm.create(.{});
    sink.reset();

    try wm.destroyAll();
    try std.testing.expectEqual(@as(usize, 1), countEvents(&sink, window.events.all_closed));
}

test "all-closed does NOT fire from destroyAll on empty WM" {
    var native = TestNative{};
    var sink = TestSink{};
    defer sink.deinit();
    var wm = newManager(&native);
    defer wm.deinit();
    wm.setEventSink(sink.asSink());

    // 창이 없는 상태에서 destroyAll
    try wm.destroyAll();
    try std.testing.expectEqual(@as(usize, 0), countEvents(&sink, window.events.all_closed));
}

test "all-closed payload is {}" {
    var native = TestNative{};
    var sink = TestSink{};
    defer sink.deinit();
    var wm = newManager(&native);
    defer wm.deinit();
    wm.setEventSink(sink.asSink());

    const id = try wm.create(.{});
    sink.reset();
    _ = try wm.close(id);

    for (sink.events.items) |ev| {
        if (std.mem.eql(u8, ev.name, window.events.all_closed)) {
            try std.testing.expectEqualStrings("{}", ev.data);
            return;
        }
    }
    try std.testing.expect(false); // 찾지 못함
}

test "liveCount reflects non-destroyed windows" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();

    try std.testing.expectEqual(@as(usize, 0), wm.liveCount());
    const a = try wm.create(.{});
    _ = try wm.create(.{});
    try std.testing.expectEqual(@as(usize, 2), wm.liveCount());
    try wm.destroy(a);
    try std.testing.expectEqual(@as(usize, 1), wm.liveCount());
}

test "tryClose then markClosedExternal simulates CEF user-close flow" {
    var native = TestNative{};
    var sink = TestSink{};
    defer sink.deinit();
    var wm = newManager(&native);
    defer wm.deinit();
    wm.setEventSink(sink.asSink());

    const id = try wm.create(.{});
    sink.reset();

    // DoClose 흐름 모사
    const proceed = try wm.tryClose(id);
    try std.testing.expect(proceed);
    // OnBeforeClose 흐름 모사
    try wm.markClosedExternal(id);

    try std.testing.expect(wm.get(id).?.destroyed);
    try std.testing.expectEqual(@as(usize, 0), native.destroy_calls);

    // 순서: close → closed (all-closed는 마지막이 마지막이라 추가로 따라붙음)
    try std.testing.expectEqualStrings(window.events.close, sink.events.items[0].name);
    try std.testing.expect(sink.events.items[0].cancelable);
    try std.testing.expectEqualStrings(window.events.closed, sink.events.items[1].name);
    try std.testing.expect(!sink.events.items[1].cancelable);
}

// ============================================
// Phase 2.5 헬퍼: window.escapeJsonChars (URL 등 wire 주입 전 안전 처리)
// ============================================

test "escapeJsonChars: passthrough for plain ASCII" {
    var buf: [64]u8 = undefined;
    const n = window.escapeJsonChars("http://localhost:5173/", &buf);
    try std.testing.expectEqualStrings("http://localhost:5173/", buf[0..n]);
}

test "escapeJsonChars: \" → \\\" 이스케이프" {
    var buf: [64]u8 = undefined;
    const n = window.escapeJsonChars("a\"b", &buf);
    try std.testing.expectEqualStrings("a\\\"b", buf[0..n]);
}

test "escapeJsonChars: \\ → \\\\ 이스케이프" {
    var buf: [64]u8 = undefined;
    const n = window.escapeJsonChars("a\\b", &buf);
    try std.testing.expectEqualStrings("a\\\\b", buf[0..n]);
}

test "escapeJsonChars: control char (< 0x20) drop" {
    var buf: [64]u8 = undefined;
    const n = window.escapeJsonChars("a\nb\x00c\x01d", &buf);
    // 모든 control char 제거
    try std.testing.expectEqualStrings("abcd", buf[0..n]);
}

test "escapeJsonChars: 빈 문자열 → 0" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), window.escapeJsonChars("", &buf));
}

test "escapeJsonChars: out_buf 1 byte 부족 (이스케이프 케이스) → 0" {
    // `"` 하나 이스케이프하려면 2 바이트 필요. 버퍼 1 바이트면 0 반환.
    var buf: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), window.escapeJsonChars("\"", &buf));
}

test "escapeJsonChars: out_buf 부족 시 (일반 문자) → 0" {
    // 5 char를 3 byte 버퍼에. 4번째 글자에서 needed=1, o+1=4 > 3 → 0.
    var buf: [3]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), window.escapeJsonChars("abcde", &buf));
}

test "escapeJsonChars: 정확히 맞는 크기 OK" {
    var buf: [3]u8 = undefined;
    const n = window.escapeJsonChars("abc", &buf);
    try std.testing.expectEqualStrings("abc", buf[0..n]);
}

test "escapeJsonChars: 이스케이프 + control drop 혼합" {
    var buf: [64]u8 = undefined;
    const n = window.escapeJsonChars("a\"b\nc\\d", &buf);
    // \n drop, " → \", \ → \\
    try std.testing.expectEqualStrings("a\\\"bc\\\\d", buf[0..n]);
}

// ============================================
// Phase 3 — TitleBarStyle.fromString (config + IPC 공유 매핑)
// ============================================

test "TitleBarStyle.fromString: hidden / hiddenInset / 미인식 → default" {
    try std.testing.expectEqual(window.TitleBarStyle.hidden, window.TitleBarStyle.fromString("hidden"));
    try std.testing.expectEqual(window.TitleBarStyle.hidden_inset, window.TitleBarStyle.fromString("hiddenInset"));
    try std.testing.expectEqual(window.TitleBarStyle.default, window.TitleBarStyle.fromString("default"));
    try std.testing.expectEqual(window.TitleBarStyle.default, window.TitleBarStyle.fromString("bogus"));
    try std.testing.expectEqual(window.TitleBarStyle.default, window.TitleBarStyle.fromString(""));
}

// ============================================
// Phase 3 — normalizeConstraints (에러 케이스 정규화)
// ============================================

test "normalizeConstraints: min_width > max_width → max_width 0으로 reset" {
    var c = window.Constraints{ .min_width = 800, .max_width = 400 };
    window.normalizeConstraints(&c);
    try std.testing.expectEqual(@as(u32, 800), c.min_width);
    try std.testing.expectEqual(@as(u32, 0), c.max_width);
}

test "normalizeConstraints: min_height > max_height → max_height 0으로 reset" {
    var c = window.Constraints{ .min_height = 600, .max_height = 200 };
    window.normalizeConstraints(&c);
    try std.testing.expectEqual(@as(u32, 600), c.min_height);
    try std.testing.expectEqual(@as(u32, 0), c.max_height);
}

test "normalizeConstraints: max=0 (제한 없음)이면 min과 무관하게 그대로" {
    var c = window.Constraints{ .min_width = 1000, .min_height = 800 };
    window.normalizeConstraints(&c);
    try std.testing.expectEqual(@as(u32, 0), c.max_width);
    try std.testing.expectEqual(@as(u32, 0), c.max_height);
}

test "normalizeConstraints: min == max는 정상 (변경 없음)" {
    var c = window.Constraints{ .min_width = 500, .max_width = 500 };
    window.normalizeConstraints(&c);
    try std.testing.expectEqual(@as(u32, 500), c.min_width);
    try std.testing.expectEqual(@as(u32, 500), c.max_width);
}

test "normalizeConstraints: 다른 필드(resizable, always_on_top, fullscreen)는 건드리지 않음" {
    var c = window.Constraints{
        .resizable = false,
        .always_on_top = true,
        .fullscreen = true,
        .min_width = 100,
        .max_width = 50,
    };
    window.normalizeConstraints(&c);
    try std.testing.expect(!c.resizable);
    try std.testing.expect(c.always_on_top);
    try std.testing.expect(c.fullscreen);
}

test "create: min > max는 wm.create가 정규화 적용" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();
    _ = try wm.create(.{ .constraints = .{ .min_width = 800, .max_width = 400 } });
    // last_constraints는 native.createWindow에 전달된 (정규화된) 값
    const co = native.last_constraints.?;
    try std.testing.expectEqual(@as(u32, 800), co.min_width);
    try std.testing.expectEqual(@as(u32, 0), co.max_width);
}

test "create: parent_id가 미존재라도 wm 단에서 거부 안 함 (silent — cef가 fail-safe)" {
    // wm은 parent의 존재 여부를 검증하지 않는다. 정책: 자식 창은 그대로 생성, parent attach만 silent fail.
    // 이 동작은 변경하지 않음을 회귀 테스트로 고정.
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();
    const id = try wm.create(.{ .parent_id = 999 });
    try std.testing.expect(id >= 1);
    try std.testing.expectEqual(@as(?u32, 999), native.last_parent_id);
}

// ============================================
// Phase 4-A: webContents (네비/JS) — WM 메서드 단위 검증
// ============================================

test "loadUrl: 살아있는 창에서 native.loadUrl 호출 + URL 캡처" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();
    const id = try wm.create(.{});
    try wm.loadUrl(id, "http://example.com/");
    try std.testing.expectEqual(@as(usize, 1), native.load_url_calls);
    try std.testing.expectEqualStrings("http://example.com/", native.last_loaded_url.?);
}

test "loadUrl: destroy된 창에 호출 시 WindowDestroyed" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();
    const id = try wm.create(.{});
    try wm.destroy(id);
    try std.testing.expectError(window.Error.WindowDestroyed, wm.loadUrl(id, "x"));
    try std.testing.expectEqual(@as(usize, 0), native.load_url_calls);
}

test "reload: ignore_cache 플래그가 native까지 전달" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();
    const id = try wm.create(.{});
    try wm.reload(id, false);
    try std.testing.expectEqual(@as(?bool, false), native.last_reload_ignore_cache);
    try wm.reload(id, true);
    try std.testing.expectEqual(@as(?bool, true), native.last_reload_ignore_cache);
    try std.testing.expectEqual(@as(usize, 2), native.reload_calls);
}

test "executeJavascript: code 문자열이 native까지 전달" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();
    const id = try wm.create(.{});
    try wm.executeJavascript(id, "console.log('hi')");
    try std.testing.expectEqualStrings("console.log('hi')", native.last_executed_js.?);
    try std.testing.expectEqual(@as(usize, 1), native.execute_js_calls);
}

test "getUrl: native가 stub_url 반환하면 그대로 전달, null이면 null" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();
    const id = try wm.create(.{});
    try std.testing.expectEqual(@as(?[]const u8, null), try wm.getUrl(id));
    native.stub_url = "http://localhost/";
    try std.testing.expectEqualStrings("http://localhost/", (try wm.getUrl(id)).?);
}

test "isLoading: native stub_is_loading을 그대로 전달" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();
    const id = try wm.create(.{});
    try std.testing.expect(!(try wm.isLoading(id)));
    native.stub_is_loading = true;
    try std.testing.expect(try wm.isLoading(id));
}

test "Phase 4-A 메서드들: 알 수 없는 id에 호출 시 NotFound" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();
    try std.testing.expectError(window.Error.WindowNotFound, wm.loadUrl(999, "x"));
    try std.testing.expectError(window.Error.WindowNotFound, wm.reload(999, false));
    try std.testing.expectError(window.Error.WindowNotFound, wm.executeJavascript(999, "x"));
    try std.testing.expectError(window.Error.WindowNotFound, wm.getUrl(999));
    try std.testing.expectError(window.Error.WindowNotFound, wm.isLoading(999));
}

// ============================================
// Phase 4-C: DevTools (open/close/is/toggle)
// ============================================

test "openDevTools: native까지 호출 + state true" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();
    const id = try wm.create(.{});
    try wm.openDevTools(id);
    try std.testing.expectEqual(@as(usize, 1), native.open_dev_tools_calls);
    try std.testing.expect(try wm.isDevToolsOpened(id));
}

test "closeDevTools: state false로 전환" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();
    const id = try wm.create(.{});
    native.stub_dev_tools_opened = true;
    try wm.closeDevTools(id);
    try std.testing.expectEqual(@as(usize, 1), native.close_dev_tools_calls);
    try std.testing.expect(!(try wm.isDevToolsOpened(id)));
}

test "toggleDevTools: 호출 시 state 반전" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();
    const id = try wm.create(.{});
    try std.testing.expect(!(try wm.isDevToolsOpened(id)));
    try wm.toggleDevTools(id);
    try std.testing.expect(try wm.isDevToolsOpened(id));
    try wm.toggleDevTools(id);
    try std.testing.expect(!(try wm.isDevToolsOpened(id)));
    try std.testing.expectEqual(@as(usize, 2), native.toggle_dev_tools_calls);
}

test "DevTools 메서드: destroyed 창에 호출 시 WindowDestroyed" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();
    const id = try wm.create(.{});
    try wm.destroy(id);
    try std.testing.expectError(window.Error.WindowDestroyed, wm.openDevTools(id));
    try std.testing.expectError(window.Error.WindowDestroyed, wm.closeDevTools(id));
    try std.testing.expectError(window.Error.WindowDestroyed, wm.toggleDevTools(id));
    try std.testing.expectError(window.Error.WindowDestroyed, wm.isDevToolsOpened(id));
}

test "DevTools 메서드: 알 수 없는 id에 호출 시 WindowNotFound" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();
    try std.testing.expectError(window.Error.WindowNotFound, wm.openDevTools(999));
    try std.testing.expectError(window.Error.WindowNotFound, wm.closeDevTools(999));
    try std.testing.expectError(window.Error.WindowNotFound, wm.toggleDevTools(999));
    try std.testing.expectError(window.Error.WindowNotFound, wm.isDevToolsOpened(999));
}

// ============================================
// 회귀 — F12 / Cmd+Shift+I 단축키가 sender 창(br)에만 토글
// (이전 버그: g_browser 싱글 참조로 항상 main 창만 토글)
//
// 정적 패턴 검증 — onPreKeyEvent body에서 toggleDevTools 호출이 함수 인자
// `br`(sender)을 받아야지, 모듈-레벨 g_browser 같은 싱글 참조면 fail.
// ============================================

test "회귀: DevTools reload sync — F5/Cmd+R가 reloadInspecteeOrSelf 경유 + 매핑 lookup" {
    // OnPreKeyEvent의 reload 분기가 br.reload()를 직접 호출하면 DevTools 안에서
    // self-reload만 됨. reloadInspecteeOrSelf가 매핑 조회로 inspectee를 reload.
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/platform/cef.zig",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(source);

    // 멀티 매핑 기반 — HashMap + lookup 헬퍼.
    try std.testing.expect(std.mem.indexOf(u8, source, "fn reloadInspecteeOrSelf(") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "lookupDevToolsInspectee") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "devtools_to_inspectee") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "pending_devtools_inspectee") != null);

    // OnPreKeyEvent body에서 br.reload 직접 호출 X — 모든 reload 키가 헬퍼 경유.
    const fn_marker = "fn onPreKeyEvent(";
    const fn_start = std.mem.indexOf(u8, source, fn_marker) orelse return error.OnPreKeyEventNotFound;
    const body_end = std.mem.indexOfPos(u8, source, fn_start + fn_marker.len, "\nfn ") orelse source.len;
    const body = source[fn_start..body_end];
    try std.testing.expect(std.mem.indexOf(u8, body, "reloadInspecteeOrSelf(br") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "br.reload.?(br)") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "br.reload_ignore_cache.?(br)") == null);

    // F5(116) 키 처리 추가 — Windows/Linux 호환.
    try std.testing.expect(std.mem.indexOf(u8, body, "key == 116") != null);
}

test "회귀: openDevTools가 pending_devtools_inspectee 세팅 후 show_dev_tools (멀티 매핑 hand-off)" {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/platform/cef.zig",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(source);

    const fn_marker = "fn openDevTools(browser: *c.cef_browser_t)";
    const fn_start = std.mem.indexOf(u8, source, fn_marker) orelse return error.OpenDevToolsNotFound;
    const body_end = std.mem.indexOfPos(u8, source, fn_start + fn_marker.len, "\nfn ") orelse source.len;
    const body = source[fn_start..body_end];

    // pending 세팅이 show_dev_tools 호출 전에 와야 — 다음 onAfterCreated가 새 DevTools를 매핑.
    const set_pos = std.mem.indexOf(u8, body, "pending_devtools_inspectee = @intCast(") orelse return error.PendingSetMissing;
    const show_pos = std.mem.indexOf(u8, body, "show_dev_tools.?(") orelse return error.ShowMissing;
    try std.testing.expect(set_pos < show_pos);
}

test "회귀: onAfterCreated가 pending hand-off로 DevTools 매핑 + onBeforeClose가 매핑 정리" {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/platform/cef.zig",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(source);

    // onAfterCreated body에 pending hand-off 로직
    const ac_marker = "fn onAfterCreated(";
    const ac_start = std.mem.indexOf(u8, source, ac_marker) orelse return error.OnAfterCreatedNotFound;
    const ac_end = std.mem.indexOfPos(u8, source, ac_start + ac_marker.len, "\nfn ") orelse source.len;
    const ac_body = source[ac_start..ac_end];
    try std.testing.expect(std.mem.indexOf(u8, ac_body, "pending_devtools_inspectee") != null);
    try std.testing.expect(std.mem.indexOf(u8, ac_body, "devtools_to_inspectee.put") != null);

    // onBeforeClose body에 map.remove
    const bc_marker = "fn onBeforeClose(";
    const bc_start = std.mem.indexOf(u8, source, bc_marker) orelse return error.OnBeforeCloseNotFound;
    const bc_end = std.mem.indexOfPos(u8, source, bc_start + bc_marker.len, "\nfn ") orelse source.len;
    const bc_body = source[bc_start..bc_end];
    try std.testing.expect(std.mem.indexOf(u8, bc_body, "devtools_to_inspectee.remove") != null);
}

test "회귀: onBeforeClose가 inspectee NSWindow를 makeKeyAndOrderFront — DevTools 닫힐 때 부모 창 키 포커스 복귀" {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/platform/cef.zig",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(source);

    const bc_marker = "fn onBeforeClose(";
    const bc_start = std.mem.indexOf(u8, source, bc_marker) orelse return error.OnBeforeCloseNotFound;
    const bc_end = std.mem.indexOfPos(u8, source, bc_start + bc_marker.len, "\nfn ") orelse source.len;
    const bc_body = source[bc_start..bc_end];

    // onBeforeClose에서 매핑 lookup → inspectee NSWindow에 makeKey 지연 호출.
    // 즉시 호출은 AppKit close-time 비동기 focus 재할당에 덮어써짐 → deferMakeKeyAndOrderFront가
    // performSelector:afterDelay:0으로 다음 런루프 틱에 예약.
    try std.testing.expect(std.mem.indexOf(u8, bc_body, "devtools_to_inspectee.get(handle)") != null);
    try std.testing.expect(std.mem.indexOf(u8, bc_body, "deferMakeKeyAndOrderFront") != null);
    // remove는 lookup 이후에 와야 — get에 hashmap 키가 살아 있어야 lookup 성공.
    const get_pos = std.mem.indexOf(u8, bc_body, "devtools_to_inspectee.get(handle)") orelse return error.GetMissing;
    const remove_pos = std.mem.indexOf(u8, bc_body, "devtools_to_inspectee.remove") orelse return error.RemoveMissing;
    try std.testing.expect(get_pos < remove_pos);
}

test "회귀: cef.quit()은 cef_quit_message_loop 전에 모든 DevTools/browser를 close — DevTools 떠 있어도 quit 동작" {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/platform/cef.zig",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(source);

    const fn_marker = "pub fn quit() void {";
    const fn_start = std.mem.indexOf(u8, source, fn_marker) orelse return error.QuitNotFound;
    const body_end = std.mem.indexOfPos(u8, source, fn_start + fn_marker.len, "\n}") orelse source.len;
    const body = source[fn_start..body_end];

    // DevTools 매핑 iterate + close_dev_tools.
    try std.testing.expect(std.mem.indexOf(u8, body, "devtools_to_inspectee.iterator") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "close_dev_tools") != null);
    // 모든 사용자 browser에 close_browser(force=1).
    try std.testing.expect(std.mem.indexOf(u8, body, "browsers.iterator") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "close_browser") != null);
    // 마지막에 cef_quit_message_loop.
    const close_browser_pos = std.mem.indexOf(u8, body, "close_browser") orelse return error.CloseBrowserMissing;
    const quit_loop_pos = std.mem.indexOf(u8, body, "cef_quit_message_loop") orelse return error.QuitLoopMissing;
    try std.testing.expect(close_browser_pos < quit_loop_pos);
}

test "회귀: F12 핸들러는 sender browser(br)을 toggleDevTools에 전달" {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/platform/cef.zig",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(source);

    const fn_marker = "fn onPreKeyEvent(";
    const fn_start = std.mem.indexOf(u8, source, fn_marker) orelse return error.OnPreKeyEventNotFound;
    const body_end = std.mem.indexOfPos(u8, source, fn_start + fn_marker.len, "\nfn ") orelse source.len;
    const body = source[fn_start..body_end];

    // br = browser 함수 인자 alias.
    try std.testing.expect(std.mem.indexOf(u8, body, "const br = browser orelse return 0;") != null);
    // F12(key==123) 또는 Cmd+I 체크 후 toggleDevTools(br) 호출 — sender 창에만.
    try std.testing.expect(std.mem.indexOf(u8, body, "key == 123") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "toggleDevTools(br)") != null);
    // 회귀 가드: 싱글 글로벌 참조 사용 금지.
    try std.testing.expect(std.mem.indexOf(u8, body, "toggleDevTools(g_browser") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "toggleDevTools(main_browser") == null);
}

test "회귀: Cmd+Q는 NSApp.terminate: 우회 — SujiQuitTarget.sujiQuit: → cef.quit()" {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/platform/cef.zig",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(source);

    // [NSApp terminate:]은 NSApplicationWillTerminate 옵저버에서 CEF SIGTRAP. 절대 사용 금지.
    // Quit 메뉴는 sujiQuit: action + SujiQuitTarget instance를 setTarget:으로 바인딩.
    try std.testing.expect(std.mem.indexOf(u8, source, "\"SujiQuitTarget\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "sujiQuit:") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "ensureQuitTarget") != null);

    // setupMainMenu는 기본 App 메뉴를 helper로 위임하고, helper가 addQuitMenuItem(app_menu)을
    // 호출한다. terminate: 직접 등록 금지.
    const menu_marker = "fn setupMainMenu(";
    const menu_start = std.mem.indexOf(u8, source, menu_marker) orelse return error.SetupMainMenuNotFound;
    const menu_end = std.mem.indexOfPos(u8, source, menu_start + menu_marker.len, "\nfn ") orelse source.len;
    const menu_body = source[menu_start..menu_end];
    try std.testing.expect(std.mem.indexOf(u8, menu_body, "addDefaultAppMenu(menubar)") != null);
    try std.testing.expect(std.mem.indexOf(u8, menu_body, "\"terminate:\"") == null);

    const app_menu_marker = "fn addDefaultAppMenu(";
    const app_menu_start = std.mem.indexOf(u8, source, app_menu_marker) orelse return error.DefaultAppMenuNotFound;
    const app_menu_end = std.mem.indexOfPos(u8, source, app_menu_start + app_menu_marker.len, "\nfn ") orelse source.len;
    const app_menu_body = source[app_menu_start..app_menu_end];
    try std.testing.expect(std.mem.indexOf(u8, app_menu_body, "addQuitMenuItem(app_menu)") != null);
    try std.testing.expect(std.mem.indexOf(u8, app_menu_body, "\"terminate:\"") == null);

    // sujiQuitImpl은 quit() 호출 (cef_quit_message_loop 직접 호출 금지 — 그러면
    // close_browser/close_dev_tools 사전 정리 우회).
    const impl_marker = "fn sujiQuitImpl(";
    const impl_start = std.mem.indexOf(u8, source, impl_marker) orelse return error.SujiQuitImplNotFound;
    const impl_end = std.mem.indexOfPos(u8, source, impl_start + impl_marker.len, "\nfn ") orelse source.len;
    const impl_body = source[impl_start..impl_end];
    try std.testing.expect(std.mem.indexOf(u8, impl_body, "quit()") != null);
    try std.testing.expect(std.mem.indexOf(u8, impl_body, "cef_quit_message_loop") == null);

    // onPreKeyEvent의 Cmd+Q 폴백도 quit() 호출 (cef_quit_message_loop 직접 호출 금지).
    const kbd_marker = "fn onPreKeyEvent(";
    const kbd_start = std.mem.indexOf(u8, source, kbd_marker) orelse return error.OnPreKeyEventNotFound;
    const kbd_end = std.mem.indexOfPos(u8, source, kbd_start + kbd_marker.len, "\nfn ") orelse source.len;
    const kbd_body = source[kbd_start..kbd_end];
    const q_pos = std.mem.indexOf(u8, kbd_body, "key == 'Q'") orelse return error.CmdQNotFound;
    const after_q = kbd_body[q_pos..];
    const next_branch = std.mem.indexOf(u8, after_q, "\n    if (") orelse after_q.len;
    const q_branch = after_q[0..next_branch];
    try std.testing.expect(std.mem.indexOf(u8, q_branch, "quit()") != null);
    try std.testing.expect(std.mem.indexOf(u8, q_branch, "cef_quit_message_loop") == null);
}

test "회귀: cef.shutdown — c.cef_shutdown 후 devtools_to_inspectee.deinit + pending 리셋" {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/platform/cef.zig",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(source);

    const fn_marker = "pub fn shutdown() void {";
    const fn_start = std.mem.indexOf(u8, source, fn_marker) orelse return error.ShutdownNotFound;
    const body_end = std.mem.indexOfPos(u8, source, fn_start + fn_marker.len, "\n}") orelse source.len;
    const body = source[fn_start..body_end];

    // c.cef_shutdown이 deinit보다 먼저 — drain 중 callback이 map에 안전 access.
    const cef_shutdown_pos = std.mem.indexOf(u8, body, "c.cef_shutdown()") orelse return error.CefShutdownMissing;
    const deinit_pos = std.mem.indexOf(u8, body, "devtools_to_inspectee.deinit()") orelse return error.DeinitMissing;
    try std.testing.expect(cef_shutdown_pos < deinit_pos);

    // flag 리셋이 deinit 앞에 와야 freed-map + flag-true 윈도우 차단.
    const flag_pos = std.mem.indexOf(u8, body, "devtools_map_initialized = false") orelse return error.FlagResetMissing;
    try std.testing.expect(flag_pos < deinit_pos);

    // pending도 null로 리셋 — 대칭 정리.
    try std.testing.expect(std.mem.indexOf(u8, body, "pending_devtools_inspectee = null") != null);
}

test "회귀: SujiKeyableWindow subclass — borderless 창도 키 이벤트 받도록 canBecomeKeyWindow 오버라이드" {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/platform/cef.zig",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(source);

    // 클래스 등록 + canBecomeKeyWindow 오버라이드.
    try std.testing.expect(std.mem.indexOf(u8, source, "\"SujiKeyableWindow\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "canBecomeKeyWindow") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "ensureSujiKeyableWindowClass") != null);

    // allocMacWindow가 NSWindow 직접 alloc 대신 SujiKeyableWindow 사용.
    const alloc_marker = "fn allocMacWindow(";
    const alloc_start = std.mem.indexOf(u8, source, alloc_marker) orelse return error.AllocMacWindowNotFound;
    const alloc_end = std.mem.indexOfPos(u8, source, alloc_start + alloc_marker.len, "\nfn ") orelse source.len;
    const alloc_body = source[alloc_start..alloc_end];
    try std.testing.expect(std.mem.indexOf(u8, alloc_body, "ensureSujiKeyableWindowClass") != null);
    try std.testing.expect(std.mem.indexOf(u8, alloc_body, "getClass(\"NSWindow\")") == null);
}

test "회귀: g_devtools_client는 life_span_handler 필수 — 없으면 DevTools 매핑 등록 X" {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/platform/cef.zig",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(source);

    const fn_marker = "fn ensureGlobalHandlers(";
    const fn_start = std.mem.indexOf(u8, source, fn_marker) orelse return error.EnsureGlobalHandlersNotFound;
    const body_end = std.mem.indexOfPos(u8, source, fn_start + fn_marker.len, "\nfn ") orelse source.len;
    const body = source[fn_start..body_end];

    // DevTools client에 keyboard + life_span 둘 다 필수.
    try std.testing.expect(std.mem.indexOf(u8, body, "g_devtools_client.get_keyboard_handler") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "g_devtools_client.get_life_span_handler") != null);
}

test "회귀: onPreKeyEvent에서 sender가 DevTools면 closeDevTools(inspectee) — recursive open 차단" {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/platform/cef.zig",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(source);

    const fn_marker = "fn onPreKeyEvent(";
    const fn_start = std.mem.indexOf(u8, source, fn_marker) orelse return error.OnPreKeyEventNotFound;
    const body_end = std.mem.indexOfPos(u8, source, fn_start + fn_marker.len, "\nfn ") orelse source.len;
    const body = source[fn_start..body_end];

    // is_devtools_key 분기 안에서 sender가 매핑돼있으면(=DevTools front-end)
    // closeDevTools(entry.browser) 호출 후 return 1 — toggleDevTools(br) 도달 X.
    const dt_marker = "is_devtools_key";
    const dt_start = std.mem.indexOf(u8, body, dt_marker) orelse return error.DevToolsKeyMissing;
    const dt_branch_end = std.mem.indexOfPos(u8, body, dt_start, "    if (key == 116)") orelse body.len;
    const dt_branch = body[dt_start..dt_branch_end];

    try std.testing.expect(std.mem.indexOf(u8, dt_branch, "lookupDevToolsInspectee(sender_id)") != null);
    try std.testing.expect(std.mem.indexOf(u8, dt_branch, "closeDevTools(entry.browser)") != null);
    try std.testing.expect(std.mem.indexOf(u8, dt_branch, "toggleDevTools(br)") != null);

    // closeDevTools가 toggleDevTools보다 먼저 — sender DevTools 분기 우선.
    const close_pos = std.mem.indexOf(u8, dt_branch, "closeDevTools(entry.browser)") orelse return error.CloseMissing;
    const toggle_pos = std.mem.indexOf(u8, dt_branch, "toggleDevTools(br)") orelse return error.ToggleMissing;
    try std.testing.expect(close_pos < toggle_pos);
}

test "회귀: Dialog API — cef.zig pub fn + main.zig 라우팅 + NSAlert/NSOpenPanel/NSSavePanel" {
    const cef_src = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/platform/cef.zig",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(cef_src);

    // 4개 pub fn (showMessageBox / showErrorBox / showOpenDialog / showSaveDialog).
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "pub fn showMessageBox(") != null);
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "pub fn showErrorBox(") != null);
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "pub fn showOpenDialog(") != null);
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "pub fn showSaveDialog(") != null);

    // ObjC 클래스 사용.
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "NSAlert") != null);
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "NSOpenPanel") != null);
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "NSSavePanel") != null);
    // runModal 동기 호출 패턴.
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "\"runModal\"") != null);
    // setMessageText/setInformativeText/addButtonWithTitle.
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "setMessageText:") != null);
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "addButtonWithTitle:") != null);
    // suppression button (checkbox).
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "setShowsSuppressionButton:") != null);
    // 응답 형식 — Electron 매칭 ("canceled" + "filePaths"/"filePath").
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "\"canceled\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "\"filePaths\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "\"filePath\":") != null);

    const main_src = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/main.zig",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(main_src);

    // 4개 cmd 라우팅.
    try std.testing.expect(std.mem.indexOf(u8, main_src, "\"dialog_show_message_box\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, main_src, "\"dialog_show_error_box\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, main_src, "\"dialog_show_open_dialog\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, main_src, "\"dialog_show_save_dialog\"") != null);
    // std.json 기반 옵션 파싱 + ignore_unknown_fields (forward-compat).
    try std.testing.expect(std.mem.indexOf(u8, main_src, "std.json.parseFromSlice") != null);
    try std.testing.expect(std.mem.indexOf(u8, main_src, "ignore_unknown_fields = true") != null);
    // properties string array → flag mapping.
    try std.testing.expect(std.mem.indexOf(u8, main_src, "\"openFile\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, main_src, "\"openDirectory\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, main_src, "\"multiSelections\"") != null);

    // showsTagField — Electron API 매칭.
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "setShowsTagField:") != null);
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "shows_tag_field") != null);
    try std.testing.expect(std.mem.indexOf(u8, main_src, "showsTagField") != null);
}

test "회귀: Dialog 옵션 파싱 — std.json filters/properties nested 배열 정상 처리" {
    const main_src = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/main.zig",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(main_src);

    // FileFilterJson struct가 정의됨 — name + extensions 배열.
    try std.testing.expect(std.mem.indexOf(u8, main_src, "const FileFilterJson = struct") != null);
    try std.testing.expect(std.mem.indexOf(u8, main_src, "extensions: []const []const u8") != null);

    // OpenDialogJson / SaveDialogJson에 filters: []const FileFilterJson 포함.
    try std.testing.expect(std.mem.indexOf(u8, main_src, "filters: []const FileFilterJson") != null);
    // OpenDialogJson properties: []const []const u8 (string 배열).
    try std.testing.expect(std.mem.indexOf(u8, main_src, "properties: []const []const u8") != null);

    // convertFilters 헬퍼 — JSON struct → cef.FileFilter slice.
    try std.testing.expect(std.mem.indexOf(u8, main_src, "fn convertFilters(") != null);
    // hasProp 헬퍼 — properties 배열에서 특정 문자열 존재 여부.
    try std.testing.expect(std.mem.indexOf(u8, main_src, "fn hasProp(") != null);
}

test "회귀: dialogParentNSWindow stale windowId — warn 로그 + null 반환 (sheet → free-floating fallback)" {
    const main_src = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/main.zig",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(main_src);

    const fn_marker = "fn dialogParentNSWindow(";
    const fn_start = std.mem.indexOf(u8, main_src, fn_marker) orelse return error.HelperNotFound;
    const body_end = std.mem.indexOfPos(u8, main_src, fn_start + fn_marker.len, "\nfn ") orelse main_src.len;
    const body = main_src[fn_start..body_end];

    // 두 가지 fallback 경로 모두 명시 warn 로그:
    //   1. wm.get(id) failure → "windowId={d} not found"
    //   2. nsWindowForBrowserHandle null → "has no NSWindow"
    try std.testing.expect(std.mem.indexOf(u8, body, "std.log.warn") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "not found in WindowManager") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "has no NSWindow") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "fallback to free-floating") != null);
}

test "회귀: Notification API (Phase 5-C) — UNUserNotificationCenter + .m 파일 + 5 진입점" {
    // .m 파일 존재 + UNUserNotificationCenter API 사용 + delegate.
    const m_src = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/platform/notification.m",
        std.testing.allocator,
        .limited(64 * 1024),
    );
    defer std.testing.allocator.free(m_src);
    try std.testing.expect(std.mem.indexOf(u8, m_src, "UNUserNotificationCenter") != null);
    try std.testing.expect(std.mem.indexOf(u8, m_src, "requestAuthorizationWithOptions:") != null);
    try std.testing.expect(std.mem.indexOf(u8, m_src, "addNotificationRequest:") != null);
    try std.testing.expect(std.mem.indexOf(u8, m_src, "SujiNotificationDelegate") != null);
    try std.testing.expect(std.mem.indexOf(u8, m_src, "didReceiveNotificationResponse:") != null);
    // foreground도 표시 (default 무음 처리 회피).
    try std.testing.expect(std.mem.indexOf(u8, m_src, "willPresentNotification:") != null);
    // foreground silent notification은 sound presentation option을 요청하지 않아야 함.
    try std.testing.expect(std.mem.indexOf(u8, m_src, "notification.request.content.sound ? UNNotificationPresentationOptionSound : 0") != null);
    // 4개 C 함수 export.
    try std.testing.expect(std.mem.indexOf(u8, m_src, "suji_notification_set_click_callback") != null);
    try std.testing.expect(std.mem.indexOf(u8, m_src, "suji_notification_request_permission") != null);
    try std.testing.expect(std.mem.indexOf(u8, m_src, "suji_notification_show") != null);
    try std.testing.expect(std.mem.indexOf(u8, m_src, "suji_notification_close") != null);

    // build.zig에 notification.m + UserNotifications framework.
    const build_src = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "build.zig",
        std.testing.allocator,
        .limited(128 * 1024),
    );
    defer std.testing.allocator.free(build_src);
    try std.testing.expect(std.mem.indexOf(u8, build_src, "src/platform/notification.m") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_src, "linkFramework(\"UserNotifications\"") != null);

    // cef.zig: extern decl + pub fn 4개 + emit handler.
    const cef_src = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/platform/cef.zig",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(cef_src);
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "extern \"c\" fn suji_notification_show(") != null);
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "pub fn notificationIsSupported(") != null);
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "pub fn notificationRequestPermission(") != null);
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "pub fn notificationShow(") != null);
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "pub fn notificationClose(") != null);
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "pub fn setNotificationEmitHandler(") != null);

    // main.zig: 4 cmd + emit handler 등록 + notification:click 이벤트.
    const main_src = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/main.zig",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(main_src);
    try std.testing.expect(std.mem.indexOf(u8, main_src, "\"notification_is_supported\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, main_src, "\"notification_request_permission\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, main_src, "\"notification_show\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, main_src, "\"notification_close\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, main_src, "cef.setNotificationEmitHandler(&notificationEmitHandler)") != null);
    try std.testing.expect(std.mem.indexOf(u8, main_src, "notification:click") != null);

    // 5 SDK 노출.
    const app_src = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/core/app.zig",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(app_src);
    try std.testing.expect(std.mem.indexOf(u8, app_src, "pub const notification = struct") != null);

    const rs_src = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "crates/suji-rs/src/lib.rs",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(rs_src);
    try std.testing.expect(std.mem.indexOf(u8, rs_src, "pub mod notification {") != null);

    const go_src = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "sdks/suji-go/notification/notification.go",
        std.testing.allocator,
        .limited(64 * 1024),
    );
    defer std.testing.allocator.free(go_src);
    try std.testing.expect(std.mem.indexOf(u8, go_src, "func Show(") != null);
    try std.testing.expect(std.mem.indexOf(u8, go_src, "func RequestPermission(") != null);

    const node_src = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "packages/suji-node/src/index.ts",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(node_src);
    try std.testing.expect(std.mem.indexOf(u8, node_src, "export const notification =") != null);

    const ts_src = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "packages/suji-js/src/index.ts",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(ts_src);
    try std.testing.expect(std.mem.indexOf(u8, ts_src, "export const notification =") != null);
    try std.testing.expect(std.mem.indexOf(u8, ts_src, "NotificationOptions") != null);
}

test "회귀: Tray API (Phase 5-B) — NSStatusItem + 메뉴 + click 라우팅 + 5 진입점" {
    const cef_src = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/platform/cef.zig",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(cef_src);

    // 5개 pub fn 노출.
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "pub fn createTray(") != null);
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "pub fn setTrayTitle(") != null);
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "pub fn setTrayTooltip(") != null);
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "pub fn setTrayMenu(") != null);
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "pub fn destroyTray(") != null);
    // NSStatusBar / NSStatusItem + statusItemWithLength: + setMenu:.
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "NSStatusBar") != null);
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "statusItemWithLength:") != null);
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "removeStatusItem:") != null);
    // SujiTrayTarget ObjC subclass + trayMenuClick: selector.
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "\"SujiTrayTarget\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "trayMenuClick:") != null);
    // Click 라우팅: NSMenuItem.tag(trayId) + representedObject(NSString click name).
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "setRepresentedObject:") != null);
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "setTag:") != null);
    // EventBus 연결 — main.zig가 setTrayEmitHandler로 콜백 등록.
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "pub fn setTrayEmitHandler(") != null);

    const main_src = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/main.zig",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(main_src);

    // 5개 cmd 라우팅.
    try std.testing.expect(std.mem.indexOf(u8, main_src, "\"tray_create\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, main_src, "\"tray_set_title\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, main_src, "\"tray_set_tooltip\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, main_src, "\"tray_set_menu\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, main_src, "\"tray_destroy\"") != null);
    // emit 핸들러 등록 — dev/dist 양쪽.
    try std.testing.expect(std.mem.indexOf(u8, main_src, "cef.setTrayEmitHandler(&trayEmitHandler)") != null);
    try std.testing.expect(std.mem.indexOf(u8, main_src, "tray:menu-click") != null);
    // setMenu items 파싱 (separator vs item).
    try std.testing.expect(std.mem.indexOf(u8, main_src, "TraySetMenuJson") != null);
    try std.testing.expect(std.mem.indexOf(u8, main_src, "\"separator\"") != null);

    // 4 SDK 노출 확인.
    const app_src = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/core/app.zig",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(app_src);
    try std.testing.expect(std.mem.indexOf(u8, app_src, "pub const tray = struct") != null);

    const rs_src = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "crates/suji-rs/src/lib.rs",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(rs_src);
    try std.testing.expect(std.mem.indexOf(u8, rs_src, "pub mod tray {") != null);
    try std.testing.expect(std.mem.indexOf(u8, rs_src, "pub fn set_menu(") != null);

    const go_src = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "sdks/suji-go/tray/tray.go",
        std.testing.allocator,
        .limited(64 * 1024),
    );
    defer std.testing.allocator.free(go_src);
    try std.testing.expect(std.mem.indexOf(u8, go_src, "func Create(") != null);
    try std.testing.expect(std.mem.indexOf(u8, go_src, "type MenuItem struct") != null);

    const node_src = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "packages/suji-node/src/index.ts",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(node_src);
    try std.testing.expect(std.mem.indexOf(u8, node_src, "export const tray =") != null);

    const ts_src = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "packages/suji-js/src/index.ts",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(ts_src);
    try std.testing.expect(std.mem.indexOf(u8, ts_src, "export const tray =") != null);
    try std.testing.expect(std.mem.indexOf(u8, ts_src, "TrayMenuItem") != null);
}

test "회귀: Menu API (Phase 5-D) — NSMenu 커스터마이즈 + click 라우팅 + 4 SDK" {
    const cef_src = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/platform/cef.zig",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(cef_src);

    try std.testing.expect(std.mem.indexOf(u8, cef_src, "pub fn setApplicationMenu(") != null);
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "pub fn resetApplicationMenu(") != null);
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "\"SujiAppMenuTarget\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "appMenuClick:") != null);
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "setState:") != null);
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "setRepresentedObject:") != null);

    const main_src = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/main.zig",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(main_src);

    try std.testing.expect(std.mem.indexOf(u8, main_src, "\"menu_set_application_menu\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, main_src, "\"menu_reset_application_menu\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, main_src, "cef.setMenuEmitHandler(&menuEmitHandler)") != null);
    try std.testing.expect(std.mem.indexOf(u8, main_src, "menu:click") != null);
    try std.testing.expect(std.mem.indexOf(u8, main_src, "parseApplicationMenuItem") != null);

    const app_src = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/core/app.zig",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(app_src);
    try std.testing.expect(std.mem.indexOf(u8, app_src, "pub const menu = struct") != null);

    const rs_src = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "crates/suji-rs/src/lib.rs",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(rs_src);
    try std.testing.expect(std.mem.indexOf(u8, rs_src, "pub mod menu {") != null);
    try std.testing.expect(std.mem.indexOf(u8, rs_src, "set_application_menu") != null);

    const go_src = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "sdks/suji-go/menu/menu.go",
        std.testing.allocator,
        .limited(64 * 1024),
    );
    defer std.testing.allocator.free(go_src);
    try std.testing.expect(std.mem.indexOf(u8, go_src, "func SetApplicationMenu(") != null);

    const node_src = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "packages/suji-node/src/index.ts",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(node_src);
    try std.testing.expect(std.mem.indexOf(u8, node_src, "export const menu =") != null);

    const ts_src = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "packages/suji-js/src/index.ts",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(ts_src);
    try std.testing.expect(std.mem.indexOf(u8, ts_src, "export const menu =") != null);
    try std.testing.expect(std.mem.indexOf(u8, ts_src, "MenuCheckboxItem") != null);
}

test "회귀: File System API (Phase 5-F) — core route + Zig/Rust/Go/Node/JS SDK" {
    const main_src = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/main.zig",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(main_src);
    try std.testing.expect(std.mem.indexOf(u8, main_src, "\"fs_read_file\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, main_src, "\"fs_write_file\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, main_src, "\"fs_stat\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, main_src, "\"fs_mkdir\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, main_src, "\"fs_readdir\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, main_src, "handleFsReadFile") != null);

    const app_src = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/core/app.zig",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(app_src);
    try std.testing.expect(std.mem.indexOf(u8, app_src, "pub const fs = struct") != null);
    try std.testing.expect(std.mem.indexOf(u8, app_src, "pub fn readFile(") != null);

    const rs_src = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "crates/suji-rs/src/lib.rs",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(rs_src);
    try std.testing.expect(std.mem.indexOf(u8, rs_src, "pub mod fs {") != null);
    try std.testing.expect(std.mem.indexOf(u8, rs_src, "pub fn read_file(") != null);

    const go_src = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "sdks/suji-go/fs/fs.go",
        std.testing.allocator,
        .limited(64 * 1024),
    );
    defer std.testing.allocator.free(go_src);
    try std.testing.expect(std.mem.indexOf(u8, go_src, "func ReadFile(") != null);
    try std.testing.expect(std.mem.indexOf(u8, go_src, "func ReadDir(") != null);

    const node_src = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "packages/suji-node/src/index.ts",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(node_src);
    try std.testing.expect(std.mem.indexOf(u8, node_src, "export const fs =") != null);

    const ts_src = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "packages/suji-js/src/index.ts",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(ts_src);
    try std.testing.expect(std.mem.indexOf(u8, ts_src, "export const fs =") != null);
    try std.testing.expect(std.mem.indexOf(u8, ts_src, "FsDirEntry") != null);
}

test "회귀: 백엔드 SDK clipboard/shell/dialog 노출 — Zig/Rust/Go/Node 4개 모두" {
    // Zig SDK (src/core/app.zig).
    const app_src = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/core/app.zig",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(app_src);
    try std.testing.expect(std.mem.indexOf(u8, app_src, "pub const clipboard = struct") != null);
    try std.testing.expect(std.mem.indexOf(u8, app_src, "pub const shell = struct") != null);
    try std.testing.expect(std.mem.indexOf(u8, app_src, "pub const dialog = struct") != null);
    try std.testing.expect(std.mem.indexOf(u8, app_src, "\"clipboard_read_text\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, app_src, "\"shell_open_external\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, app_src, "\"dialog_show_message_box\"") != null);

    // Rust SDK.
    const rs_src = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "crates/suji-rs/src/lib.rs",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(rs_src);
    try std.testing.expect(std.mem.indexOf(u8, rs_src, "pub mod clipboard {") != null);
    try std.testing.expect(std.mem.indexOf(u8, rs_src, "pub mod shell {") != null);
    try std.testing.expect(std.mem.indexOf(u8, rs_src, "pub mod dialog {") != null);
    try std.testing.expect(std.mem.indexOf(u8, rs_src, "fn read_text()") != null);
    try std.testing.expect(std.mem.indexOf(u8, rs_src, "fn open_external(") != null);
    try std.testing.expect(std.mem.indexOf(u8, rs_src, "MessageBoxOpts") != null);
    // escape_json_full — \n/\t 보존.
    try std.testing.expect(std.mem.indexOf(u8, rs_src, "fn escape_json_full(") != null);

    // Go SDK — 3개 패키지 디렉토리 존재 + 함수 export.
    const go_clip = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "sdks/suji-go/clipboard/clipboard.go",
        std.testing.allocator,
        .limited(64 * 1024),
    );
    defer std.testing.allocator.free(go_clip);
    try std.testing.expect(std.mem.indexOf(u8, go_clip, "func ReadText()") != null);
    try std.testing.expect(std.mem.indexOf(u8, go_clip, "func WriteText(") != null);

    const go_shell = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "sdks/suji-go/shell/shell.go",
        std.testing.allocator,
        .limited(64 * 1024),
    );
    defer std.testing.allocator.free(go_shell);
    try std.testing.expect(std.mem.indexOf(u8, go_shell, "func OpenExternal(") != null);
    try std.testing.expect(std.mem.indexOf(u8, go_shell, "func Beep()") != null);

    const go_dialog = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "sdks/suji-go/dialog/dialog.go",
        std.testing.allocator,
        .limited(64 * 1024),
    );
    defer std.testing.allocator.free(go_dialog);
    try std.testing.expect(std.mem.indexOf(u8, go_dialog, "func ShowMessageBox(") != null);
    try std.testing.expect(std.mem.indexOf(u8, go_dialog, "type MessageBoxOpts struct") != null);

    // Node SDK.
    const node_src = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "packages/suji-node/src/index.ts",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(node_src);
    try std.testing.expect(std.mem.indexOf(u8, node_src, "export const clipboard =") != null);
    try std.testing.expect(std.mem.indexOf(u8, node_src, "export const shell =") != null);
    try std.testing.expect(std.mem.indexOf(u8, node_src, "export const dialog =") != null);
    try std.testing.expect(std.mem.indexOf(u8, node_src, "MessageBoxOptions") != null);
    try std.testing.expect(std.mem.indexOf(u8, node_src, "OpenDialogOptions") != null);
}

test "회귀: Sheet modal — .m 파일 + extern decl + parent_window 옵션 + windowId 라우팅" {
    // 1. dialog.m 파일 존재 + ObjC block completion handler 사용.
    const m_src = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/platform/dialog.m",
        std.testing.allocator,
        .limited(64 * 1024),
    );
    defer std.testing.allocator.free(m_src);
    try std.testing.expect(std.mem.indexOf(u8, m_src, "beginSheetModalForWindow:") != null);
    try std.testing.expect(std.mem.indexOf(u8, m_src, "completionHandler:^") != null);
    try std.testing.expect(std.mem.indexOf(u8, m_src, "suji_run_sheet_alert") != null);
    try std.testing.expect(std.mem.indexOf(u8, m_src, "suji_run_sheet_save_panel") != null);
    // nested run loop pattern.
    try std.testing.expect(std.mem.indexOf(u8, m_src, "nextEventMatchingMask:") != null);
    try std.testing.expect(std.mem.indexOf(u8, m_src, "sendEvent:") != null);

    // 2. build.zig에 .m 컴파일 룰 (ARC).
    const build_src = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "build.zig",
        std.testing.allocator,
        .limited(128 * 1024),
    );
    defer std.testing.allocator.free(build_src);
    try std.testing.expect(std.mem.indexOf(u8, build_src, "src/platform/dialog.m") != null);
    // ARC 필수 — __bridge 캐스트 + completion handler block 자동 autorelease.
    try std.testing.expect(std.mem.indexOf(u8, build_src, "-fobjc-arc") != null);

    // 3. cef.zig에 extern decl + parent_window 옵션 + nsWindowForBrowserHandle.
    const cef_src = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/platform/cef.zig",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(cef_src);
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "extern \"c\" fn suji_run_sheet_alert(") != null);
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "extern \"c\" fn suji_run_sheet_save_panel(") != null);
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "parent_window: ?*anyopaque") != null);
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "pub fn nsWindowForBrowserHandle(") != null);
    // sheet vs free-floating 분기 — opts.parent_window |parent| 체크.
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "opts.parent_window") != null);

    // 4. main.zig에 windowId JSON 필드 + dialogParentNSWindow 헬퍼.
    const main_src = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/main.zig",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(main_src);
    try std.testing.expect(std.mem.indexOf(u8, main_src, "windowId: ?u32") != null);
    try std.testing.expect(std.mem.indexOf(u8, main_src, "dialogParentNSWindow") != null);

    // 5. JS API에 Electron 두-인자 오버로드.
    const ts_src = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "packages/suji-js/src/index.ts",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(ts_src);
    try std.testing.expect(std.mem.indexOf(u8, ts_src, "splitDialogArgs") != null);
    try std.testing.expect(std.mem.indexOf(u8, ts_src, "MessageBoxOptions | number") != null);
    try std.testing.expect(std.mem.indexOf(u8, ts_src, "OpenDialogOptions | number") != null);
}

test "회귀: Dialog Sync 변종 — JS API의 showMessageBoxSync/showOpenDialogSync/showSaveDialogSync 노출" {
    const ts_src = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "packages/suji-js/src/index.ts",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(ts_src);

    // 3개 sync 변종 노출 — Electron API 호환성.
    try std.testing.expect(std.mem.indexOf(u8, ts_src, "showMessageBoxSync") != null);
    try std.testing.expect(std.mem.indexOf(u8, ts_src, "showOpenDialogSync") != null);
    try std.testing.expect(std.mem.indexOf(u8, ts_src, "showSaveDialogSync") != null);
    // 응답 shape 변환 — sync는 raw value 반환 (number / string[] | undefined / string | undefined).
    try std.testing.expect(std.mem.indexOf(u8, ts_src, "Promise<number>") != null);
    try std.testing.expect(std.mem.indexOf(u8, ts_src, "Promise<string[] | undefined>") != null);
    try std.testing.expect(std.mem.indexOf(u8, ts_src, "Promise<string | undefined>") != null);
}

test "회귀: Shell API — cef.zig pub fn + main.zig 라우팅 + NSWorkspace/NSBeep 사용" {
    const cef_src = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/platform/cef.zig",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(cef_src);

    // 3개 pub fn 노출.
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "pub fn shellOpenExternal(") != null);
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "pub fn shellShowItemInFolder(") != null);
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "pub fn shellBeep() void") != null);
    // NSWorkspace + NSURL 사용. modern API (activateFileViewerSelectingURLs:) 채택,
    // deprecated selectFile:inFileViewerRootedAtPath: 사용 금지.
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "NSWorkspace") != null);
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "URLWithString:") != null);
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "activateFileViewerSelectingURLs:") != null);
    // deprecated selector를 sel_registerName 인자로 등록하면 안 됨 (doc comment에서의
    // 언급은 허용 — 왜 안 쓰는지 설명).
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "sel_registerName(\"selectFile:") == null);
    // 사전 검증 — scheme 검사(openExternal) + fileExistsAtPath:(showItemInFolder)로
    // LaunchServices에 invalid 입력 보내 -50 OS dialog 띄우지 않도록 차단.
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "fileExistsAtPath:") != null);
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "\"scheme\"") != null);
    // NSBeep extern.
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "pub extern \"c\" fn NSBeep") != null);

    const main_src = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/main.zig",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(main_src);

    // 3개 cmd 라우팅.
    try std.testing.expect(std.mem.indexOf(u8, main_src, "\"shell_open_external\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, main_src, "\"shell_show_item_in_folder\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, main_src, "\"shell_beep\"") != null);
}

test "회귀: Clipboard API — cef.zig pub fn + main.zig 라우팅 + JSON escape 사용" {
    const cef_src = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/platform/cef.zig",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(cef_src);

    // 3개 pub fn 노출.
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "pub fn clipboardReadText(") != null);
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "pub fn clipboardWriteText(") != null);
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "pub fn clipboardClear() void") != null);
    // public.utf8-plain-text UTI 사용.
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "public.utf8-plain-text") != null);
    // NSPasteboard generalPasteboard 사용.
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "generalPasteboard") != null);

    const main_src = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/main.zig",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(main_src);

    // 3개 cmd 라우팅.
    try std.testing.expect(std.mem.indexOf(u8, main_src, "\"clipboard_read_text\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, main_src, "\"clipboard_write_text\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, main_src, "\"clipboard_clear\"") != null);
    // read는 escapeJsonStrFull 거쳐 응답 (newline/tab 보존).
    try std.testing.expect(std.mem.indexOf(u8, main_src, "escapeJsonStrFull") != null);
    // write는 unescapeJsonStr로 raw → 실제 바이트 복원 후 NSPasteboard 전달.
    try std.testing.expect(std.mem.indexOf(u8, main_src, "unescapeJsonStr") != null);
}

test "회귀: deferMakeKeyAndOrderFront — performSelector:afterDelay:0으로 다음 런루프 틱 예약" {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/platform/cef.zig",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(source);

    const fn_marker = "fn deferMakeKeyAndOrderFront(";
    const fn_start = std.mem.indexOf(u8, source, fn_marker) orelse return error.DeferFnNotFound;
    const body_end = std.mem.indexOfPos(u8, source, fn_start + fn_marker.len, "\nfn ") orelse source.len;
    const body = source[fn_start..body_end];

    // performSelector:withObject:afterDelay: 셀렉터 등록 + makeKeyAndOrderFront: 셀렉터를
    // 인자로 전달. afterDelay:0.0으로 다음 틱 예약.
    try std.testing.expect(std.mem.indexOf(u8, body, "performSelector:withObject:afterDelay:") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "makeKeyAndOrderFront:") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "0.0") != null);
}

// ============================================
// Phase 4-B: 줌 (level / factor)
// ============================================

test "setZoomLevel: native까지 전달 + getZoomLevel로 읽기" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();
    const id = try wm.create(.{});
    try wm.setZoomLevel(id, 1.5);
    try std.testing.expectEqual(@as(usize, 1), native.set_zoom_level_calls);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), try wm.getZoomLevel(id), 1e-9);
}

test "setZoomFactor: pow(1.2, level) 변환 — factor=1.2 ↔ level=1, factor=1 ↔ level=0" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();
    const id = try wm.create(.{});

    try wm.setZoomFactor(id, 1.0); // 100% → level=0
    try std.testing.expectApproxEqAbs(@as(f64, 0), native.stub_zoom_level, 1e-9);

    try wm.setZoomFactor(id, 1.2); // level=1 (정확히)
    try std.testing.expectApproxEqAbs(@as(f64, 1), native.stub_zoom_level, 1e-9);

    // 역방향 round-trip — getZoomFactor가 setZoomFactor 입력 복원
    try wm.setZoomFactor(id, 1.5);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), try wm.getZoomFactor(id), 1e-9);
}

test "setZoomFactor: factor<=0이면 level=0 (방어적 — log(0) 회피)" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();
    const id = try wm.create(.{});
    native.stub_zoom_level = 5; // 더러운 초기값
    try wm.setZoomFactor(id, 0);
    try std.testing.expectEqual(@as(f64, 0), native.stub_zoom_level);
    try wm.setZoomFactor(id, -1);
    try std.testing.expectEqual(@as(f64, 0), native.stub_zoom_level);
}

test "줌 메서드: destroyed/unknown 가드" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();
    const id = try wm.create(.{});
    try wm.destroy(id);
    try std.testing.expectError(window.Error.WindowDestroyed, wm.setZoomLevel(id, 0));
    try std.testing.expectError(window.Error.WindowDestroyed, wm.getZoomLevel(id));
    try std.testing.expectError(window.Error.WindowNotFound, wm.setZoomLevel(999, 0));
    try std.testing.expectError(window.Error.WindowNotFound, wm.getZoomFactor(999));
}

// ============================================
// Phase 4-E: 편집 (6 trivial) + 검색
// ============================================

test "편집 6 메서드: 각자 호출이 native 카운트만 증가시킴 (cross-call 없음)" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();
    const id = try wm.create(.{});

    try wm.undo(id);
    try wm.redo(id);
    try wm.cut(id);
    try wm.copy(id);
    try wm.paste(id);
    try wm.selectAll(id);

    // 각 필드가 정확히 1회씩 — named struct라 typo 시 컴파일 에러.
    inline for (.{ "undo", "redo", "cut", "copy", "paste", "select_all" }) |name| {
        try std.testing.expectEqual(@as(usize, 1), @field(native.edit_calls, name));
    }
}

test "findInPage: text + forward/matchCase/findNext 플래그 전달" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();
    const id = try wm.create(.{});

    try wm.findInPage(id, "hello", true, true, false);
    try std.testing.expectEqual(@as(usize, 1), native.find_calls);
    try std.testing.expectEqualStrings("hello", native.last_find_text.?);
    try std.testing.expect(native.last_find_forward);
    try std.testing.expect(native.last_find_match_case);
    try std.testing.expect(!native.last_find_next);

    // 두 번째 호출 — find_next true
    try wm.findInPage(id, "hello", true, true, true);
    try std.testing.expect(native.last_find_next);
}

test "stopFindInPage: clear_selection 플래그 전달" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();
    const id = try wm.create(.{});
    try wm.stopFindInPage(id, true);
    try std.testing.expectEqual(@as(usize, 1), native.stop_find_calls);
    try std.testing.expect(native.last_stop_find_clear);
}

test "Phase 4-E 메서드들: destroyed/unknown 가드" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();
    const id = try wm.create(.{});
    try wm.destroy(id);
    try std.testing.expectError(window.Error.WindowDestroyed, wm.undo(id));
    try std.testing.expectError(window.Error.WindowDestroyed, wm.findInPage(id, "x", true, false, false));
    try std.testing.expectError(window.Error.WindowDestroyed, wm.stopFindInPage(id, false));

    try std.testing.expectError(window.Error.WindowNotFound, wm.copy(999));
    try std.testing.expectError(window.Error.WindowNotFound, wm.findInPage(999, "x", true, false, false));
}

// ============================================
// Phase 4-D: 인쇄 (printToPDF — 콜백 async)
// ============================================

test "printToPDF: native에 path 전달" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();
    const id = try wm.create(.{});
    try wm.printToPDF(id, "/tmp/out.pdf");
    try std.testing.expectEqual(@as(usize, 1), native.print_to_pdf_calls);
    try std.testing.expectEqualStrings("/tmp/out.pdf", native.last_print_path.?);
}

test "회귀: cef.zig가 EVENT_PDF_PRINT_FINISHED const 사용 (이벤트 이름 하드코드 차단)" {
    // cef.zig에서 onPdfPrintFinished가 const를 거치지 않고 string literal 직접 쓰면
    // 5 SDK + 문서와 sync 깨질 위험. 한 곳에 const + 사용처에서 const 참조 보장.
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/platform/cef.zig",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(source);

    // const 정의 존재
    try std.testing.expect(std.mem.indexOf(u8, source, "EVENT_PDF_PRINT_FINISHED") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "\"window:pdf-print-finished\"") != null);

    // emit이 const 사용 — string literal 직접 사용은 1번(const 자체 정의)만 OK.
    var literal_count: usize = 0;
    var pos: usize = 0;
    const needle = "\"window:pdf-print-finished\"";
    while (std.mem.indexOfPos(u8, source, pos, needle)) |i| {
        literal_count += 1;
        pos = i + 1;
    }
    try std.testing.expectEqual(@as(usize, 1), literal_count);
}

test "printToPDF: destroyed/unknown 가드" {
    var native = TestNative{};
    var wm = newManager(&native);
    defer wm.deinit();
    const id = try wm.create(.{});
    try wm.destroy(id);
    try std.testing.expectError(window.Error.WindowDestroyed, wm.printToPDF(id, "/tmp/x.pdf"));
    try std.testing.expectError(window.Error.WindowNotFound, wm.printToPDF(999, "/tmp/x.pdf"));
    try std.testing.expectEqual(@as(usize, 0), native.print_to_pdf_calls);
}

test "회귀: 4-C cef.zig openDevTools/closeDevTools/toggleDevTools가 인자 browser 사용" {
    // 헬퍼 분해 후 sender browser(매개변수)를 사용함을 정적 검증 — 만약 실수로
    // g_browser/g_main_browser 같은 글로벌로 바꾸면 멀티 윈도우 회귀.
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/platform/cef.zig",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(source);

    inline for (.{
        "fn openDevTools(browser: *c.cef_browser_t) void {",
        "fn closeDevTools(browser: *c.cef_browser_t) void {",
        "fn toggleDevTools(browser: *c.cef_browser_t) void {",
        "fn hasDevTools(browser: *c.cef_browser_t) bool {",
    }) |sig| {
        try std.testing.expect(std.mem.indexOf(u8, source, sig) != null);
    }
}
