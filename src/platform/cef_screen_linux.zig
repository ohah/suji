//! Linux X11 backend for Electron-compatible screen APIs.

const std = @import("std");
const builtin = @import("builtin");
const screen_model = @import("screen_model.zig");

const impl = if (builtin.os.tag == .linux) struct {
    extern "c" fn XOpenDisplay(display_name: ?[*:0]const u8) callconv(.c) ?*anyopaque;
    extern "c" fn XCloseDisplay(display: ?*anyopaque) callconv(.c) c_int;
    extern "c" fn XDefaultScreen(display: ?*anyopaque) callconv(.c) c_int;
    extern "c" fn XScreenCount(display: ?*anyopaque) callconv(.c) c_int;
    extern "c" fn XDisplayWidth(display: ?*anyopaque, screen_number: c_int) callconv(.c) c_int;
    extern "c" fn XDisplayHeight(display: ?*anyopaque, screen_number: c_int) callconv(.c) c_int;
    extern "c" fn XRootWindow(display: ?*anyopaque, screen_number: c_int) callconv(.c) c_ulong;
    extern "c" fn XQueryPointer(
        display: ?*anyopaque,
        window: c_ulong,
        root_return: *c_ulong,
        child_return: *c_ulong,
        root_x_return: *c_int,
        root_y_return: *c_int,
        win_x_return: *c_int,
        win_y_return: *c_int,
        mask_return: *c_uint,
    ) callconv(.c) c_int;
    extern "c" fn XNextEvent(display: ?*anyopaque, event: *anyopaque) callconv(.c) c_int;
    extern "c" fn dlopen(name: ?[*:0]const u8, flag: c_int) callconv(.c) ?*anyopaque;
    extern "c" fn dlsym(handle: ?*anyopaque, name: [*:0]const u8) callconv(.c) ?*anyopaque;

    // X11 RandR (libXrandr) — dlopen 으로 동적 로드(build 링크 불요, 미설치 시 graceful no-op).
    const XRRQueryExtensionFn = *const fn (?*anyopaque, *c_int, *c_int) callconv(.c) c_int;
    const XRRSelectInputFn = *const fn (?*anyopaque, c_ulong, c_int) callconv(.c) void;
    const XRRGetMonitorsFn = *const fn (?*anyopaque, c_ulong, c_int, *c_int) callconv(.c) ?*anyopaque;
    const XRRFreeMonitorsFn = *const fn (?*anyopaque) callconv(.c) void;
    const RR_SCREEN_CHANGE_NOTIFY_MASK: c_int = 1; // RRScreenChangeNotifyMask = 1<<0
    const RTLD_NOW: c_int = 2;

    var g_rr_lib: ?*anyopaque = null;
    var g_rr_get_monitors: ?XRRGetMonitorsFn = null;
    var g_rr_free_monitors: ?XRRFreeMonitorsFn = null;
    var g_screen_thread_spawned: std.atomic.Value(bool) = .init(false);
    var g_screen_cb: ?*const fn () callconv(.c) void = null;

    fn writeEmptyJsonArray(out_buf: []u8) []const u8 {
        const empty = "[]";
        const n = @min(empty.len, out_buf.len);
        @memcpy(out_buf[0..n], empty[0..n]);
        return out_buf[0..n];
    }

    fn displayBounds(display: ?*anyopaque, screen_number: c_int) ?screen_model.DisplayBounds {
        const width = XDisplayWidth(display, screen_number);
        const height = XDisplayHeight(display, screen_number);
        if (width <= 0 or height <= 0) return null;
        return .{ .x = 0, .y = 0, .width = width, .height = height };
    }

    pub fn getAllDisplays(out_buf: []u8) []const u8 {
        const display = XOpenDisplay(null) orelse return writeEmptyJsonArray(out_buf);
        defer _ = XCloseDisplay(display);

        const count = XScreenCount(display);
        if (count <= 0) return writeEmptyJsonArray(out_buf);
        const primary = XDefaultScreen(display);

        var w = std.Io.Writer.fixed(out_buf);
        w.writeByte('[') catch return out_buf[0..1];
        var first = true;
        var idx: c_int = 0;
        while (idx < count) : (idx += 1) {
            const b = displayBounds(display, idx) orelse continue;
            if (!first) w.writeByte(',') catch return w.buffered();
            first = false;
            w.print(
                "{{\"index\":{d},\"isPrimary\":{},\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d},\"visibleX\":{d},\"visibleY\":{d},\"visibleWidth\":{d},\"visibleHeight\":{d},\"scaleFactor\":{d}}}",
                .{
                    idx,           idx == primary,
                    b.x,           b.y,
                    b.width,       b.height,
                    b.x,           b.y,
                    b.width,       b.height,
                    @as(f64, 1.0),
                },
            ) catch return w.buffered();
        }
        w.writeByte(']') catch return w.buffered();
        return w.buffered();
    }

    pub fn cursorPoint() [2]f64 {
        const display = XOpenDisplay(null) orelse return .{ 0, 0 };
        defer _ = XCloseDisplay(display);

        const screen = XDefaultScreen(display);
        const root = XRootWindow(display, screen);
        var root_return: c_ulong = 0;
        var child_return: c_ulong = 0;
        var root_x: c_int = 0;
        var root_y: c_int = 0;
        var win_x: c_int = 0;
        var win_y: c_int = 0;
        var mask: c_uint = 0;
        if (XQueryPointer(display, root, &root_return, &child_return, &root_x, &root_y, &win_x, &win_y, &mask) == 0)
            return .{ 0, 0 };
        return .{ @floatFromInt(root_x), @floatFromInt(root_y) };
    }

    pub fn displayNearestPoint(x: f64, y: f64) i32 {
        const display = XOpenDisplay(null) orelse return -1;
        defer _ = XCloseDisplay(display);

        const count = XScreenCount(display);
        if (count <= 0) return -1;

        var displays: [32]screen_model.DisplayBounds = undefined;
        var len: usize = 0;
        var idx: c_int = 0;
        while (idx < count and len < displays.len) : (idx += 1) {
            if (displayBounds(display, idx)) |b| {
                displays[len] = b;
                len += 1;
            }
        }
        return screen_model.containedDisplayIndex(displays[0..len], x, y);
    }

    pub fn displayMatching(x: f64, y: f64, w: f64, h: f64) i32 {
        const display = XOpenDisplay(null) orelse return -1;
        defer _ = XCloseDisplay(display);

        const count = XScreenCount(display);
        if (count <= 0) return -1;

        var displays: [32]screen_model.DisplayBounds = undefined;
        var len: usize = 0;
        var idx: c_int = 0;
        while (idx < count and len < displays.len) : (idx += 1) {
            if (displayBounds(display, idx)) |b| {
                displays[len] = b;
                len += 1;
            }
        }
        return screen_model.matchingDisplayIndex(displays[0..len], x, y, w, h);
    }

    // ── display 변경 이벤트 (Electron screen display-added/removed/metrics-changed) ──
    // X11 RandR RRScreenChangeNotify 를 별도 connection + 스레드에서 select. 깨어나면
    // 무조건 cef_screen.screenChangedC 콜백 호출 → cef_screen 이 displayCount() count-diff
    // 로 add/removed/metrics 구분(macOS observer 와 동일 로직 재사용). event-type 디코드
    // 불요(RRScreenChangeNotifyMask 만 select → 거의 그 이벤트만 옴) → 견고.

    fn ensureRandr(display: ?*anyopaque) bool {
        if (g_rr_lib == null) {
            g_rr_lib = dlopen("libXrandr.so.2", RTLD_NOW) orelse return false;
            g_rr_get_monitors = @ptrCast(dlsym(g_rr_lib, "XRRGetMonitors"));
            g_rr_free_monitors = @ptrCast(dlsym(g_rr_lib, "XRRFreeMonitors"));
        }
        const query: XRRQueryExtensionFn = @ptrCast(dlsym(g_rr_lib, "XRRQueryExtension") orelse return false);
        var ev_base: c_int = 0;
        var err_base: c_int = 0;
        return query(display, &ev_base, &err_base) != 0;
    }

    /// 활성 모니터 수 (RandR XRRGetMonitors). RandR 1.5 부재 시 XScreenCount fallback.
    pub fn displayCount() i32 {
        const display = XOpenDisplay(null) orelse return 0;
        defer _ = XCloseDisplay(display);
        return monitorCount(display);
    }

    fn monitorCount(display: ?*anyopaque) i32 {
        if (g_rr_get_monitors) |get| {
            const screen = XDefaultScreen(display);
            const root = XRootWindow(display, screen);
            var n: c_int = 0;
            const mons = get(display, root, 1, &n); // get_active=1
            if (mons != null) {
                if (g_rr_free_monitors) |free_fn| free_fn(mons);
                if (n > 0) return @intCast(n);
            }
        }
        const sc = XScreenCount(display);
        return if (sc > 0) @intCast(sc) else 0;
    }

    fn screenThreadMain() void {
        const display = XOpenDisplay(null) orelse return;
        defer _ = XCloseDisplay(display);
        if (!ensureRandr(display)) return; // RandR 미지원 → graceful no-op
        const select: XRRSelectInputFn = @ptrCast(dlsym(g_rr_lib, "XRRSelectInput") orelse return);
        const screen = XDefaultScreen(display);
        const root = XRootWindow(display, screen);
        select(display, root, RR_SCREEN_CHANGE_NOTIFY_MASK);

        // XEvent union — 64-bit 에서 최대 24 longs(192B). 넉넉히 잡아 stack 디코드 불요.
        // daemon 루프(앱 수명) — XNextEvent 블로킹은 self-event 로 깨우지 않으므로
        // uninstall 은 g_screen_cb 만 null 로 게이트한다(thread 는 살아있되 no-op).
        var ev: [24]c_long = undefined;
        while (true) {
            _ = XNextEvent(display, @ptrCast(&ev)); // blocking until RandR notify
            if (g_screen_cb) |cb| cb();
        }
    }

    /// cef_screen.screenChangedC 를 콜백으로 받아 RandR 변경 시 호출. thread 는 **1회만**
    /// spawn(detached daemon, 앱 수명) — 재install 은 g_screen_cb 만 갱신하고 thread 를
    /// 재spawn 하지 않는다(XNextEvent 블로킹이라 옛 thread 가 안 죽어 중복 방지). uninstall
    /// 은 g_screen_cb 만 null 로 게이트(프로세스 종료 시 정리. 정직 경계).
    pub fn installChangeListener(cb: *const fn () callconv(.c) void) void {
        g_screen_cb = cb; // 콜백 갱신(재install 포함)
        if (g_screen_thread_spawned.swap(true, .acq_rel)) return; // thread 는 1회만
        const t = std.Thread.spawn(.{}, screenThreadMain, .{}) catch {
            g_screen_thread_spawned.store(false, .release);
            return;
        };
        t.detach();
    }

    pub fn uninstallChangeListener() void {
        g_screen_cb = null; // daemon thread 는 유지, 콜백만 게이트
    }
} else struct {
    pub fn getAllDisplays(out_buf: []u8) []const u8 {
        const empty = "[]";
        const n = @min(empty.len, out_buf.len);
        @memcpy(out_buf[0..n], empty[0..n]);
        return out_buf[0..n];
    }

    pub fn cursorPoint() [2]f64 {
        return .{ 0, 0 };
    }

    pub fn displayNearestPoint(_: f64, _: f64) i32 {
        return -1;
    }

    pub fn displayMatching(_: f64, _: f64, _: f64, _: f64) i32 {
        return -1;
    }

    pub fn displayCount() i32 {
        return 0;
    }

    pub fn installChangeListener(_: *const fn () callconv(.c) void) void {}
    pub fn uninstallChangeListener() void {}
};

pub const getAllDisplays = impl.getAllDisplays;
pub const cursorPoint = impl.cursorPoint;
pub const displayNearestPoint = impl.displayNearestPoint;
pub const displayMatching = impl.displayMatching;
pub const displayCount = impl.displayCount;
pub const installChangeListener = impl.installChangeListener;
pub const uninstallChangeListener = impl.uninstallChangeListener;
