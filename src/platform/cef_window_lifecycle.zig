//! Window lifecycle events — cef.zig 에서 분리(동작 무변경). CEF Views callbacks와
//! macOS NSWindowDelegate bridge가 `window:*` lifecycle 이벤트를 main.zig EventBus로 라우팅한다.
const std = @import("std");
const builtin = @import("builtin");
const logger = @import("logger");

const is_macos = builtin.os.tag == .macos;
const log = logger.module("cef");

// ============================================
// Window lifecycle events (Electron BrowserWindow events 대응) — 비-macOS는 stub.
// ============================================

pub const WindowResizedHandler = *const fn (handle: u64, x: f64, y: f64, width: f64, height: f64) void;
pub const WindowMovedHandler = *const fn (handle: u64, x: f64, y: f64) void;
pub const WindowFocusHandler = *const fn (handle: u64) void;
pub const WindowBlurHandler = *const fn (handle: u64) void;
pub const WindowSimpleHandler = *const fn (handle: u64) void;
/// will-resize 동기 콜백. handler가 proposed_w/proposed_h 포인터를 mutate 가능 —
/// listener가 preventDefault 시 curr 값으로 덮어쓰면 cancellation.
pub const WindowWillResizeHandler = *const fn (handle: u64, curr_w: f64, curr_h: f64, proposed_w: *f64, proposed_h: *f64) void;

// 11개 lifecycle handler globals — 같은 파일의 C 트램폴린 (`windowMinimizeC` 등)만
// 참조. 외부 노출 없음 → `pub` 제거로 모듈 표면 정리.
pub var g_window_resized_handler: ?WindowResizedHandler = null;
pub var g_window_moved_handler: ?WindowMovedHandler = null;
pub var g_window_focus_handler: ?WindowFocusHandler = null;
pub var g_window_blur_handler: ?WindowBlurHandler = null;
pub var g_window_minimize_handler: ?WindowSimpleHandler = null;
pub var g_window_restore_handler: ?WindowSimpleHandler = null;
pub var g_window_maximize_handler: ?WindowSimpleHandler = null;
pub var g_window_unmaximize_handler: ?WindowSimpleHandler = null;
pub var g_window_enter_fullscreen_handler: ?WindowSimpleHandler = null;
pub var g_window_leave_fullscreen_handler: ?WindowSimpleHandler = null;
pub var g_window_will_resize_handler: ?WindowWillResizeHandler = null;

fn windowResizedC(handle: u64, x: f64, y: f64, width: f64, height: f64) callconv(.c) void {
    if (g_window_resized_handler) |h| h(handle, x, y, width, height);
}
fn windowMovedC(handle: u64, x: f64, y: f64) callconv(.c) void {
    if (g_window_moved_handler) |h| h(handle, x, y);
}
fn windowFocusC(handle: u64) callconv(.c) void {
    if (g_window_focus_handler) |h| h(handle);
}
fn windowBlurC(handle: u64) callconv(.c) void {
    if (g_window_blur_handler) |h| h(handle);
}
fn windowMinimizeC(handle: u64) callconv(.c) void {
    if (g_window_minimize_handler) |h| h(handle);
}
fn windowRestoreC(handle: u64) callconv(.c) void {
    if (g_window_restore_handler) |h| h(handle);
}
fn windowMaximizeC(handle: u64) callconv(.c) void {
    if (g_window_maximize_handler) |h| h(handle);
}
fn windowUnmaximizeC(handle: u64) callconv(.c) void {
    if (g_window_unmaximize_handler) |h| h(handle);
}
fn windowEnterFullscreenC(handle: u64) callconv(.c) void {
    if (g_window_enter_fullscreen_handler) |h| h(handle);
}
fn windowLeaveFullscreenC(handle: u64) callconv(.c) void {
    if (g_window_leave_fullscreen_handler) |h| h(handle);
}
fn windowWillResizeC(handle: u64, curr_w: f64, curr_h: f64, proposed_w: *f64, proposed_h: *f64) callconv(.c) void {
    if (g_window_will_resize_handler) |h| h(handle, curr_w, curr_h, proposed_w, proposed_h);
}

pub const WindowLifecycleHandlers = struct {
    resized: WindowResizedHandler,
    moved: WindowMovedHandler,
    focus: WindowFocusHandler,
    blur: WindowBlurHandler,
    minimize: WindowSimpleHandler,
    restore: WindowSimpleHandler,
    maximize: WindowSimpleHandler,
    unmaximize: WindowSimpleHandler,
    enter_fullscreen: WindowSimpleHandler,
    leave_fullscreen: WindowSimpleHandler,
    will_resize: WindowWillResizeHandler,
};

pub fn setWindowLifecycleHandlers(h: WindowLifecycleHandlers) void {
    // handler 변수 set 은 모든 OS — CEF Views 콜백(on_window_bounds_changed 등)이
    // Windows/Linux 에서도 emit 하지만, 기존엔 macOS 가드로 handler 가 null 이라
    // payload 가 frontend 에 도달 못 했음. 가드 해제로 cross-platform window 이벤트
    // 활성화. macOS 전용 NSWindowDelegate native callback bridge 만 가드 유지.
    g_window_resized_handler = h.resized;
    g_window_moved_handler = h.moved;
    g_window_focus_handler = h.focus;
    g_window_blur_handler = h.blur;
    g_window_minimize_handler = h.minimize;
    g_window_restore_handler = h.restore;
    g_window_maximize_handler = h.maximize;
    g_window_unmaximize_handler = h.unmaximize;
    g_window_enter_fullscreen_handler = h.enter_fullscreen;
    g_window_leave_fullscreen_handler = h.leave_fullscreen;
    g_window_will_resize_handler = h.will_resize;
    if (!comptime is_macos) return;
    const cbs: SujiWindowLifecycleCallbacks = .{
        .resized = &windowResizedC,
        .moved = &windowMovedC,
        .focus = &windowFocusC,
        .blur = &windowBlurC,
        .minimize = &windowMinimizeC,
        .restore = &windowRestoreC,
        .maximize = &windowMaximizeC,
        .unmaximize = &windowUnmaximizeC,
        .enter_fullscreen = &windowEnterFullscreenC,
        .leave_fullscreen = &windowLeaveFullscreenC,
        .will_resize = &windowWillResizeC,
    };
    suji_window_lifecycle_set_callbacks(&cbs);
}

pub fn attachWindowLifecycle(ns_window: ?*anyopaque, handle: u64) void {
    if (!comptime is_macos) return;
    if (suji_window_lifecycle_attach(ns_window, handle) == 0) {
        log.warn("attachWindowLifecycle failed for handle={d} (capacity {d} reached or null window)", .{ handle, 64 });
    }
}

pub fn detachWindowLifecycle(ns_window: ?*anyopaque) void {
    if (!comptime is_macos) return;
    suji_window_lifecycle_detach(ns_window);
}

// window_lifecycle.m — NSWindowDelegate. struct로 묶어 silent mis-routing 차단
// (6개가 동일 시그니처 `*const fn (u64) callconv(.c) void`).
const SujiWindowLifecycleCallbacks = extern struct {
    resized: *const fn (u64, f64, f64, f64, f64) callconv(.c) void,
    moved: *const fn (u64, f64, f64) callconv(.c) void,
    focus: *const fn (u64) callconv(.c) void,
    blur: *const fn (u64) callconv(.c) void,
    minimize: *const fn (u64) callconv(.c) void,
    restore: *const fn (u64) callconv(.c) void,
    maximize: *const fn (u64) callconv(.c) void,
    unmaximize: *const fn (u64) callconv(.c) void,
    enter_fullscreen: *const fn (u64) callconv(.c) void,
    leave_fullscreen: *const fn (u64) callconv(.c) void,
    will_resize: *const fn (u64, f64, f64, *f64, *f64) callconv(.c) void,
};
// window_lifecycle.m 은 macOS 전용(build.zig 가 macOS 호스트에서만 컴파일).
// 비-macOS 는 그 C 심볼이 없어 링크 실패 → @extern(명시 .name)은 macOS,
// 비-macOS 는 callconv(.c) unreachable 스텁 포인터로. 이 경로는 전부
// macOS 전용 — 모든 호출자(callOnNs/callOnNsBool/setFullscreenImpl/
// setWindowLifecycleHandlers/attach/detach)가 !comptime is_macos early-return
// 이라 비-macOS 런타임 미도달. 호출부 무변경 위해 동명 const(fn 포인터).
const wl_stub = struct {
    fn voidNs(_: ?*anyopaque) callconv(.c) void {
        unreachable;
    }
    fn i32Ns(_: ?*anyopaque) callconv(.c) i32 {
        unreachable;
    }
    fn attach(_: ?*anyopaque, _: u64) callconv(.c) i32 {
        unreachable;
    }
    fn setFs(_: ?*anyopaque, _: i32) callconv(.c) void {
        unreachable;
    }
    fn setCb(_: *const SujiWindowLifecycleCallbacks) callconv(.c) void {
        unreachable;
    }
};
const suji_window_lifecycle_set_callbacks: *const fn (*const SujiWindowLifecycleCallbacks) callconv(.c) void =
    if (is_macos) @extern(*const fn (*const SujiWindowLifecycleCallbacks) callconv(.c) void, .{ .name = "suji_window_lifecycle_set_callbacks" }) else &wl_stub.setCb;
const suji_window_lifecycle_attach: *const fn (?*anyopaque, u64) callconv(.c) i32 =
    if (is_macos) @extern(*const fn (?*anyopaque, u64) callconv(.c) i32, .{ .name = "suji_window_lifecycle_attach" }) else &wl_stub.attach;
const suji_window_lifecycle_detach: *const fn (?*anyopaque) callconv(.c) void =
    if (is_macos) @extern(*const fn (?*anyopaque) callconv(.c) void, .{ .name = "suji_window_lifecycle_detach" }) else &wl_stub.voidNs;
pub const suji_window_lifecycle_minimize: *const fn (?*anyopaque) callconv(.c) void =
    if (is_macos) @extern(*const fn (?*anyopaque) callconv(.c) void, .{ .name = "suji_window_lifecycle_minimize" }) else &wl_stub.voidNs;
pub const suji_window_lifecycle_deminiaturize: *const fn (?*anyopaque) callconv(.c) void =
    if (is_macos) @extern(*const fn (?*anyopaque) callconv(.c) void, .{ .name = "suji_window_lifecycle_deminiaturize" }) else &wl_stub.voidNs;
pub const suji_window_lifecycle_maximize: *const fn (?*anyopaque) callconv(.c) void =
    if (is_macos) @extern(*const fn (?*anyopaque) callconv(.c) void, .{ .name = "suji_window_lifecycle_maximize" }) else &wl_stub.voidNs;
pub const suji_window_lifecycle_unmaximize: *const fn (?*anyopaque) callconv(.c) void =
    if (is_macos) @extern(*const fn (?*anyopaque) callconv(.c) void, .{ .name = "suji_window_lifecycle_unmaximize" }) else &wl_stub.voidNs;
pub const suji_window_lifecycle_set_fullscreen: *const fn (?*anyopaque, i32) callconv(.c) void =
    if (is_macos) @extern(*const fn (?*anyopaque, i32) callconv(.c) void, .{ .name = "suji_window_lifecycle_set_fullscreen" }) else &wl_stub.setFs;
pub const suji_window_lifecycle_is_minimized: *const fn (?*anyopaque) callconv(.c) i32 =
    if (is_macos) @extern(*const fn (?*anyopaque) callconv(.c) i32, .{ .name = "suji_window_lifecycle_is_minimized" }) else &wl_stub.i32Ns;
pub const suji_window_lifecycle_is_maximized: *const fn (?*anyopaque) callconv(.c) i32 =
    if (is_macos) @extern(*const fn (?*anyopaque) callconv(.c) i32, .{ .name = "suji_window_lifecycle_is_maximized" }) else &wl_stub.i32Ns;
pub const suji_window_lifecycle_is_fullscreen: *const fn (?*anyopaque) callconv(.c) i32 =
    if (is_macos) @extern(*const fn (?*anyopaque) callconv(.c) i32, .{ .name = "suji_window_lifecycle_is_fullscreen" }) else &wl_stub.i32Ns;
