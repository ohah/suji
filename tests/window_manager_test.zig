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
    return WindowManager.init(std.testing.allocator, native.asNative());
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
