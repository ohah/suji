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
    for (sink.events.items) |ev| if (std.mem.eql(u8, ev.name, name)) { n += 1; };
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
