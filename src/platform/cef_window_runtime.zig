//! Runtime window operations for CefNative.
//! Destroy/show-hide/focus/title/bounds vtable entries.
const std = @import("std");
const builtin = @import("builtin");
const window_mod = @import("window");
const logger = @import("logger");
const cef = @import("cef.zig");
const cef_views_delegate = @import("cef_views_delegate.zig");
const cef_window_lifecycle = @import("cef_window_lifecycle.zig");

const c = cef.c;
const is_macos = builtin.os.tag == .macos;
const log = logger.module("cef");

fn fromCtx(ctx: ?*anyopaque) *cef.CefNative {
    return @ptrCast(@alignCast(ctx.?));
}

fn assertUiThread() void {
    std.debug.assert(c.cef_currently_on(c.TID_UI) == 1);
}

fn getHost(self: *cef.CefNative, handle: u64) ?*c.cef_browser_host_t {
    const entry = self.browsers.get(handle) orelse return null;
    const br = entry.browser;
    return cef.asPtr(c.cef_browser_host_t, br.get_host.?(br));
}

pub fn destroyWindow(ctx: ?*anyopaque, handle: u64) void {
    const self = fromCtx(ctx);
    assertUiThread();
    log.debug("CefNative.destroyWindow handle={d}", .{handle});
    const entry = self.browsers.get(handle) orelse {
        log.warn("CefNative.destroyWindow: handle={d} not in table", .{handle});
        return;
    };
    if (entry.views_window) |views_window| {
        views_window.close.?(views_window);
        return;
    }
    cef_window_lifecycle.detachWindowLifecycle(entry.ns_window);
    if (comptime is_macos) {
        // macOS: NSWindow close deallocates the content/browser view, which then
        // cascades into CEF cleanup and OnBeforeClose.
        cef.closeMacWindow(entry.ns_window);
    } else {
        const br = entry.browser;
        const host = cef.asPtr(c.cef_browser_host_t, br.get_host.?(br));
        if (host) |h| h.close_browser.?(h, 1);
    }
}

pub fn setVisible(ctx: ?*anyopaque, handle: u64, visible: bool) void {
    const self = fromCtx(ctx);
    assertUiThread();
    if (self.browsers.get(handle)) |entry| {
        if (entry.views_window) |views_window| {
            if (visible) views_window.show.?(views_window) else views_window.hide.?(views_window);
            return;
        }
    }
    const host = getHost(self, handle) orelse return;
    host.was_hidden.?(host, if (visible) 0 else 1);
}

pub fn focus(ctx: ?*anyopaque, handle: u64) void {
    const self = fromCtx(ctx);
    assertUiThread();
    if (self.browsers.get(handle)) |entry| {
        if (entry.views_window) |views_window| {
            views_window.activate.?(views_window);
            return;
        }
    }
    const host = getHost(self, handle) orelse return;
    host.set_focus.?(host, 1);
}

// Electron BrowserWindow.blur() — focus 대칭. Views 창은 deactivate, 아니면 browser
// host 포커스 해제(set_focus(0)). NSWindow obj-c 불요(focus 와 동일 경로).
pub fn blur(ctx: ?*anyopaque, handle: u64) void {
    const self = fromCtx(ctx);
    assertUiThread();
    if (self.browsers.get(handle)) |entry| {
        if (entry.views_window) |views_window| {
            views_window.deactivate.?(views_window);
            return;
        }
    }
    const host = getHost(self, handle) orelse return;
    host.set_focus.?(host, 0);
}

pub fn setTitle(ctx: ?*anyopaque, handle: u64, title: []const u8) void {
    assertUiThread();
    const self = fromCtx(ctx);
    const entry = self.browsers.get(handle) orelse return;
    if (entry.views_window) |views_window| {
        var title_buf: [512]u8 = undefined;
        const title_z = cef.nullTerminateOrTruncate(title, &title_buf) orelse return;
        var cef_title: c.cef_string_t = .{};
        cef.setCefString(&cef_title, title_z);
        views_window.set_title.?(views_window, &cef_title);
        return;
    }
    if (!is_macos) return;
    const ns_window = entry.ns_window orelse return;
    cef.setMacWindowTitle(ns_window, title);
}

pub fn setBounds(ctx: ?*anyopaque, handle: u64, bounds: window_mod.Bounds) void {
    assertUiThread();
    const self = fromCtx(ctx);
    const entry = self.browsers.getPtr(handle) orelse return;
    if (entry.views_window) |views_window| {
        var rect: c.cef_rect_t = .{
            .x = bounds.x,
            .y = bounds.y,
            .width = @intCast(bounds.width),
            .height = @intCast(bounds.height),
        };
        views_window.base.base.set_bounds.?(&views_window.base.base, &rect);
        if (entry.views_window_delegate) |delegate| cef_views_delegate.viewsWindowEmitBoundsChanged(delegate, rect);
        return;
    }
    if (!is_macos) return;
    const ns_window = entry.ns_window orelse return;
    cef.setMacWindowBounds(ns_window, bounds);
}

pub fn getBounds(ctx: ?*anyopaque, handle: u64) window_mod.Bounds {
    assertUiThread();
    const self = fromCtx(ctx);
    const entry = self.browsers.getPtr(handle) orelse return .{};
    // CEF Views 창은 get_bounds 가 top-left 원점 cef_rect_t 반환(set_bounds 와 동일
    // 좌표계) → 변환 불필요. setBounds 와 대칭.
    if (entry.views_window) |views_window| {
        if (views_window.base.base.get_bounds) |get_bounds| {
            const rect = get_bounds(&views_window.base.base);
            return .{
                .x = rect.x,
                .y = rect.y,
                .width = @intCast(@max(rect.width, 0)),
                .height = @intCast(@max(rect.height, 0)),
            };
        }
    }
    if (is_macos) {
        if (entry.ns_window) |ns_window| return cef.getMacWindowBounds(ns_window);
    }
    return .{};
}

// ── min/max 콘텐츠 크기 (Electron setMinimumSize/setMaximumSize) ──
// 단일 출처 = delegate.constraints (CEF Views can_resize/get_minimum_size 콜백이 읽는 값).
// 런타임 setter 는 ① delegate.constraints 갱신 → ② macOS NSWindow 즉시 적용 →
// ③ invalidate_layout 으로 CEF 재-layout 유도(전 플랫폼). getter 는 delegate 값 반환
// (결정적 — getBounds 의 live OS 질의와 달리 추적값. Electron 도 설정값 반환).

pub fn setMinimumSizeImpl(ctx: ?*anyopaque, handle: u64, w: u32, h: u32) void {
    assertUiThread();
    const self = fromCtx(ctx);
    const entry = self.browsers.getPtr(handle) orelse return;
    if (entry.views_window_delegate) |delegate| {
        delegate.constraints.min_width = w;
        delegate.constraints.min_height = h;
    }
    if (is_macos) {
        if (entry.ns_window) |ns| cef.setMacContentMinSize(ns, w, h);
    }
    if (entry.views_window) |vw| {
        if (vw.base.base.invalidate_layout) |inv| inv(&vw.base.base);
    }
}

pub fn getMinimumSizeImpl(ctx: ?*anyopaque, handle: u64) window_mod.Bounds {
    const self = fromCtx(ctx);
    const entry = self.browsers.getPtr(handle) orelse return .{};
    if (entry.views_window_delegate) |delegate| {
        return .{ .width = delegate.constraints.min_width, .height = delegate.constraints.min_height };
    }
    return .{};
}

pub fn setMaximumSizeImpl(ctx: ?*anyopaque, handle: u64, w: u32, h: u32) void {
    assertUiThread();
    const self = fromCtx(ctx);
    const entry = self.browsers.getPtr(handle) orelse return;
    if (entry.views_window_delegate) |delegate| {
        delegate.constraints.max_width = w;
        delegate.constraints.max_height = h;
    }
    if (is_macos) {
        if (entry.ns_window) |ns| cef.setMacContentMaxSize(ns, w, h);
    }
    if (entry.views_window) |vw| {
        if (vw.base.base.invalidate_layout) |inv| inv(&vw.base.base);
    }
}

pub fn getMaximumSizeImpl(ctx: ?*anyopaque, handle: u64) window_mod.Bounds {
    const self = fromCtx(ctx);
    const entry = self.browsers.getPtr(handle) orelse return .{};
    if (entry.views_window_delegate) |delegate| {
        return .{ .width = delegate.constraints.max_width, .height = delegate.constraints.max_height };
    }
    return .{};
}

// ── 창 capability 토글 (Electron setResizable/setMinimizable/setMaximizable/setClosable) ──
// 단일 출처 = delegate.constraints (CEF Views can_resize/can_minimize/can_maximize/can_close
// 콜백이 읽음). setter: ① delegate constraints 갱신 ② macOS NSWindow styleMask 비트/zoom 버튼
// 즉시 적용(min/max 동일 belt-and-suspenders) ③ invalidate_layout. getter: delegate 값(결정적).
// macOS styleMask 비트: Resizable=1<<3, Closable=1<<1, Miniaturizable=1<<2.

fn invalidateLayout(entry: *cef.CefNative.BrowserEntry) void {
    if (entry.views_window) |vw| {
        if (vw.base.base.invalidate_layout) |inv| inv(&vw.base.base);
    }
}

pub fn setResizableImpl(ctx: ?*anyopaque, handle: u64, on: bool) void {
    assertUiThread();
    const entry = fromCtx(ctx).browsers.getPtr(handle) orelse return;
    if (entry.views_window_delegate) |d| d.constraints.resizable = on;
    if (is_macos) {
        if (entry.ns_window) |ns| cef.setMacStyleMaskBit(ns, 1 << 3, on);
    }
    invalidateLayout(entry);
}
pub fn isResizableImpl(ctx: ?*anyopaque, handle: u64) bool {
    const entry = fromCtx(ctx).browsers.getPtr(handle) orelse return true;
    return if (entry.views_window_delegate) |d| d.constraints.resizable else true;
}

pub fn setMinimizableImpl(ctx: ?*anyopaque, handle: u64, on: bool) void {
    assertUiThread();
    const entry = fromCtx(ctx).browsers.getPtr(handle) orelse return;
    if (entry.views_window_delegate) |d| d.constraints.minimizable = on;
    if (is_macos) {
        if (entry.ns_window) |ns| cef.setMacStyleMaskBit(ns, 1 << 2, on);
    }
    invalidateLayout(entry);
}
pub fn isMinimizableImpl(ctx: ?*anyopaque, handle: u64) bool {
    const entry = fromCtx(ctx).browsers.getPtr(handle) orelse return true;
    return if (entry.views_window_delegate) |d| d.constraints.minimizable else true;
}

pub fn setMaximizableImpl(ctx: ?*anyopaque, handle: u64, on: bool) void {
    assertUiThread();
    const entry = fromCtx(ctx).browsers.getPtr(handle) orelse return;
    if (entry.views_window_delegate) |d| d.constraints.maximizable = on;
    if (is_macos) {
        // macOS 는 maximizable styleMask 비트 없음 → zoom(green) 버튼 enable/disable.
        if (entry.ns_window) |ns| cef.setMacZoomButtonEnabled(ns, on);
    }
    invalidateLayout(entry);
}
pub fn isMaximizableImpl(ctx: ?*anyopaque, handle: u64) bool {
    const entry = fromCtx(ctx).browsers.getPtr(handle) orelse return true;
    return if (entry.views_window_delegate) |d| d.constraints.maximizable else true;
}

pub fn setClosableImpl(ctx: ?*anyopaque, handle: u64, on: bool) void {
    assertUiThread();
    const entry = fromCtx(ctx).browsers.getPtr(handle) orelse return;
    if (entry.views_window_delegate) |d| d.constraints.closable = on;
    if (is_macos) {
        if (entry.ns_window) |ns| cef.setMacStyleMaskBit(ns, 1 << 1, on);
    }
    invalidateLayout(entry);
}
pub fn isClosableImpl(ctx: ?*anyopaque, handle: u64) bool {
    const entry = fromCtx(ctx).browsers.getPtr(handle) orelse return true;
    return if (entry.views_window_delegate) |d| d.constraints.closable else true;
}

// ── 창 모드 토글 (Electron setMovable/setFocusable/setEnabled/setFullScreenable/setKiosk) ──
// tracked constraints 단일 출처(getter 결정적) + best-effort 네이티브. movable/focusable/
// enabled/fullscreenable/kiosk 는 layout 무관이라 invalidate_layout 불필요.
// 정직 경계: focusable=tracked-only(클린 네이티브 토글 부재), enabled=macOS ignoresMouseEvents
// (마우스만)/Win32 EnableWindow(정확)/Linux tracked, fullscreenable=macOS collectionBehavior
// (실효)/그 외 tracked, kiosk=CEF Views fullscreen best-effort(presentation-options 미포함).

const is_windows = builtin.os.tag == .windows;
const win_enable = if (is_windows) struct {
    extern "user32" fn EnableWindow(hWnd: ?*anyopaque, bEnable: i32) callconv(.winapi) i32;
} else struct {};

pub fn setMovableImpl(ctx: ?*anyopaque, handle: u64, on: bool) void {
    assertUiThread();
    const entry = fromCtx(ctx).browsers.getPtr(handle) orelse return;
    if (entry.views_window_delegate) |d| d.constraints.movable = on;
    if (is_macos) {
        if (entry.ns_window) |ns| cef.setMacMovable(ns, on);
    }
}
pub fn isMovableImpl(ctx: ?*anyopaque, handle: u64) bool {
    const entry = fromCtx(ctx).browsers.getPtr(handle) orelse return true;
    return if (entry.views_window_delegate) |d| d.constraints.movable else true;
}

pub fn setFocusableImpl(ctx: ?*anyopaque, handle: u64, on: bool) void {
    assertUiThread();
    const entry = fromCtx(ctx).browsers.getPtr(handle) orelse return;
    // tracked-only — macOS/Win/Linux 모두 런타임 focusable 토글의 클린 API 부재(정직 경계).
    if (entry.views_window_delegate) |d| d.constraints.focusable = on;
}
pub fn isFocusableImpl(ctx: ?*anyopaque, handle: u64) bool {
    const entry = fromCtx(ctx).browsers.getPtr(handle) orelse return true;
    return if (entry.views_window_delegate) |d| d.constraints.focusable else true;
}

pub fn setEnabledImpl(ctx: ?*anyopaque, handle: u64, on: bool) void {
    assertUiThread();
    const entry = fromCtx(ctx).browsers.getPtr(handle) orelse return;
    if (entry.views_window_delegate) |d| d.constraints.enabled = on;
    if (is_macos) {
        // enabled=true → ignoresMouseEvents=false (입력 허용). 마우스만(키보드 미포함, 정직).
        if (entry.ns_window) |ns| cef.setMacIgnoresMouseEvents(ns, !on);
    } else if (is_windows) {
        if (cef.windowsEntryHwnd(entry)) |hwnd| _ = win_enable.EnableWindow(hwnd, if (on) 1 else 0);
    }
}
pub fn isEnabledImpl(ctx: ?*anyopaque, handle: u64) bool {
    const entry = fromCtx(ctx).browsers.getPtr(handle) orelse return true;
    return if (entry.views_window_delegate) |d| d.constraints.enabled else true;
}

pub fn setFullscreenableImpl(ctx: ?*anyopaque, handle: u64, on: bool) void {
    assertUiThread();
    const entry = fromCtx(ctx).browsers.getPtr(handle) orelse return;
    if (entry.views_window_delegate) |d| d.constraints.fullscreenable = on;
    if (is_macos) {
        // NSWindowCollectionBehaviorFullScreenPrimary = 1<<7.
        if (entry.ns_window) |ns| cef.setMacCollectionBehaviorBit(ns, 1 << 7, on);
    }
}
pub fn isFullscreenableImpl(ctx: ?*anyopaque, handle: u64) bool {
    const entry = fromCtx(ctx).browsers.getPtr(handle) orelse return true;
    return if (entry.views_window_delegate) |d| d.constraints.fullscreenable else true;
}

pub fn setKioskImpl(ctx: ?*anyopaque, handle: u64, on: bool) void {
    assertUiThread();
    const entry = fromCtx(ctx).browsers.getPtr(handle) orelse return;
    if (entry.views_window_delegate) |d| d.constraints.kiosk = on;
    // best-effort: CEF Views 전체화면 flag-set(presentation-options=dock/menu 숨김은 follow-up).
    // 현재 상태와 같으면 redundant 전환 skip(setFullscreenImpl 동일 가드).
    if (entry.views_window) |vw| {
        if (cef_views_delegate.viewsWindowIsFullscreen(vw) == on) return;
        if (vw.set_fullscreen) |set_fs| set_fs(vw, @intFromBool(on));
    }
}
pub fn isKioskImpl(ctx: ?*anyopaque, handle: u64) bool {
    const entry = fromCtx(ctx).browsers.getPtr(handle) orelse return false;
    return if (entry.views_window_delegate) |d| d.constraints.kiosk else false;
}

// Electron getContentBounds() — 콘텐츠 영역(타이틀바/프레임 제외). CEF Views 는
// get_client_area_bounds_in_screen(top-left) 직접 제공, 아니면 macOS NSWindow 변환.
pub fn getContentBounds(ctx: ?*anyopaque, handle: u64) window_mod.Bounds {
    assertUiThread();
    const self = fromCtx(ctx);
    const entry = self.browsers.getPtr(handle) orelse return .{};
    if (entry.views_window) |views_window| {
        if (views_window.get_client_area_bounds_in_screen) |get_client| {
            const rect = get_client(views_window);
            return .{
                .x = rect.x,
                .y = rect.y,
                .width = @intCast(@max(rect.width, 0)),
                .height = @intCast(@max(rect.height, 0)),
            };
        }
    }
    if (is_macos) {
        if (entry.ns_window) |ns_window| return cef.getMacWindowContentBounds(ns_window);
    }
    return .{};
}

// Electron setContentBounds() — 콘텐츠 영역을 원하는 사각형으로. CEF Views 는
// frame↔content inset(get_bounds vs get_client_area_bounds_in_screen)을 구해 프레임으로
// 환산 후 set_bounds(전 플랫폼). 비-Views 는 macOS frameRectForContentRect.
pub fn setContentBounds(ctx: ?*anyopaque, handle: u64, content: window_mod.Bounds) void {
    assertUiThread();
    const self = fromCtx(ctx);
    const entry = self.browsers.getPtr(handle) orelse return;
    if (entry.views_window) |views_window| {
        const view = &views_window.base.base;
        if (view.get_bounds != null and views_window.get_client_area_bounds_in_screen != null and view.set_bounds != null) {
            const frame = view.get_bounds.?(view);
            const cont = views_window.get_client_area_bounds_in_screen.?(views_window);
            // 콘텐츠 사각형 → 프레임 사각형(inset 적용).
            var rect: c.cef_rect_t = .{
                .x = content.x - (cont.x - frame.x),
                .y = content.y - (cont.y - frame.y),
                .width = @as(c_int, @intCast(content.width)) + (frame.width - cont.width),
                .height = @as(c_int, @intCast(content.height)) + (frame.height - cont.height),
            };
            view.set_bounds.?(view, &rect);
            if (entry.views_window_delegate) |delegate| cef_views_delegate.viewsWindowEmitBoundsChanged(delegate, rect);
            return;
        }
    }
    if (!is_macos) return;
    const ns_window = entry.ns_window orelse return;
    cef.setMacWindowContentBounds(ns_window, content);
}
