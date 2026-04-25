//! 공용 TestNative — WindowManager.Native vtable stub + 호출 기록용.
//!
//! 여러 테스트 파일(window_manager_test, event_sink_test, window_stack_test, …)이
//! 같은 stub을 반복 정의했던 것을 한 곳으로 모음.

const std = @import("std");
const window = @import("window");

pub const TestNative = struct {
    next_handle: u64 = 1000,
    create_calls: usize = 0,
    destroy_calls: usize = 0,
    set_title_calls: usize = 0,
    set_bounds_calls: usize = 0,
    set_visible_calls: usize = 0,
    focus_calls: usize = 0,
    last_title: ?[]const u8 = null,
    last_bounds: ?window.Bounds = null,
    /// 마지막 createWindow에 전달된 옵션의 sub-struct/parent_id 캡처 (Phase 3 매핑 검증용).
    /// 슬라이스 멤버(title/url/background_color)는 얕은 복사 — caller가 src 수명 보장.
    last_appearance: ?window.Appearance = null,
    last_constraints: ?window.Constraints = null,
    last_parent_id: ?u32 = null,
    last_create_bounds: ?window.Bounds = null,
    /// true이면 다음 create_window 호출이 error.NativeFailure 반환 후 자동 리셋.
    fail_next_create: bool = false,
    /// destroyWindow 콜백 도중 WM 상태 관찰용. 세팅 시 해당 WM에서 handle을 역조회해
    /// observed_destroyed_during_destroy에 기록 (CefNative의 DoClose 재진입 시나리오 시뮬레이션).
    observe_wm: ?*const window.WindowManager = null,
    observed_destroyed_during_destroy: ?bool = null,

    pub fn asNative(self: *TestNative) window.Native {
        return .{ .vtable = &vtable, .ctx = self };
    }

    const vtable: window.Native.VTable = .{
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

    fn createWindow(ctx: ?*anyopaque, opts: *const window.CreateOptions) anyerror!u64 {
        const self = fromCtx(ctx);
        if (self.fail_next_create) {
            self.fail_next_create = false;
            return error.NativeFailure;
        }
        self.create_calls += 1;
        self.last_appearance = opts.appearance;
        self.last_constraints = opts.constraints;
        self.last_parent_id = opts.parent_id;
        self.last_create_bounds = opts.bounds;
        const handle = self.next_handle;
        self.next_handle += 1;
        return handle;
    }

    fn destroyWindow(ctx: ?*anyopaque, handle: u64) void {
        const self = fromCtx(ctx);
        self.destroy_calls += 1;
        if (self.observe_wm) |wm| {
            if (wm.findByNativeHandle(handle)) |id| {
                if (wm.get(id)) |w| self.observed_destroyed_during_destroy = w.destroyed;
            }
        }
    }

    fn setTitle(ctx: ?*anyopaque, _: u64, title: []const u8) void {
        const self = fromCtx(ctx);
        self.set_title_calls += 1;
        self.last_title = title;
    }

    fn setBounds(ctx: ?*anyopaque, _: u64, bounds: window.Bounds) void {
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
