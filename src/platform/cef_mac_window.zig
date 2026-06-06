//! macOS NSWindow creation and window-geometry helpers shared by CEF window paths.
const std = @import("std");
const builtin = @import("builtin");
const window_mod = @import("window");
const logger = @import("logger");
const cef = @import("cef.zig");
const cef_drag_handler = @import("cef_drag_handler.zig");

const c = cef.c;
const objc = cef.objc;
const log = logger.module("cef");
const is_macos = builtin.os.tag == .macos;

/// 플랫폼별 윈도우 초기화 옵션. CefConfig(process-level)와 분리 — per-window 속성.
/// Appearance / Constraints는 window 모듈 sub-struct를 그대로 재사용 (3중 정의 회피).
pub const WindowInitOpts = struct {
    title: [:0]const u8,
    width: i32,
    height: i32,
    /// 0이면 cascade 자동 배치 (`cascadeTopLeftFromPoint:`).
    x: i32 = 0,
    y: i32 = 0,
    appearance: window_mod.Appearance = .{},
    constraints: window_mod.Constraints = .{},
};

/// 플랫폼별 윈도우 초기화. 반환값: macOS에서만 NSWindow 포인터 (이후 close 트리거용).
/// Linux/Windows는 CEF가 자체 창을 만들므로 null.
pub const initWindowInfo = if (is_macos) struct {
    fn call(window_info: *c.cef_window_info_t, opts: WindowInitOpts) ?*anyopaque {
        const handles = createMacWindow(opts);
        if (handles.content_view) |cv| {
            window_info.parent_view = cv;
        }
        return handles.ns_window;
    }
}.call else struct {
    fn call(_: *c.cef_window_info_t, opts: WindowInitOpts) ?*anyopaque {
        warnUnsupportedOptionsOnce(opts);
        return null;
    }
}.call;

/// Phase 3 옵션 중 macOS-only가 set되어 있으면 process당 한 번만 stderr에 안내.
/// silent no-op이면 사용자가 "왜 안 되지?" 디버그하게 됨 → 명시적 warn.
var g_warned_unsupported_options: bool = false;
fn warnUnsupportedOptionsOnce(opts: WindowInitOpts) void {
    if (g_warned_unsupported_options) return;
    if (!hasMacOnlyOption(opts)) return;
    g_warned_unsupported_options = true;
    if (!builtin.is_test) std.debug.print(
        "[suji] warning: window appearance/constraints (frame/transparent/parent/always_on_top/title_bar_style/min·max/fullscreen/background_color) are macOS-only and were ignored on this platform\n",
        .{},
    );
}

fn hasMacOnlyOption(opts: WindowInitOpts) bool {
    const ap = opts.appearance;
    const cs = opts.constraints;
    return !ap.frame or ap.transparent or
        ap.background_color != null or ap.title_bar_style != .default or
        cs.always_on_top or cs.fullscreen or
        cs.min_width != 0 or cs.min_height != 0 or
        cs.max_width != 0 or cs.max_height != 0;
}

fn msgSendRespondsToSelector(target: ?*anyopaque, sel_name: [:0]const u8) bool {
    const sel_responds = objc.sel_registerName("respondsToSelector:");
    const sel_arg = objc.sel_registerName(sel_name.ptr);
    const func: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) u8 = @ptrCast(&objc.objc_msgSend);
    return func(target, @ptrCast(sel_responds), @ptrCast(sel_arg)) != 0;
}

fn msgSendIsKindOfClass(target: ?*anyopaque, cls: ?*anyopaque) bool {
    const sel = objc.sel_registerName("isKindOfClass:");
    const func: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) u8 = @ptrCast(&objc.objc_msgSend);
    return func(target, @ptrCast(sel), cls) != 0;
}

pub fn cefViewsHandleToNSWindow(handle: ?*anyopaque) ?*anyopaque {
    if (!comptime is_macos) return null;
    const raw = handle orelse return null;
    if (msgSendIsKindOfClass(raw, cef.getClass("NSWindow"))) return raw;
    if (msgSendRespondsToSelector(raw, "window")) return cef.msgSend(raw, "window");
    return null;
}

/// NSRect 1-arg 버전 — setFrame:/initWithFrame: 등. ARM64 ABI는 NSRect를 d0~d3 float
/// 레지스터로 전달하므로 함수 포인터 시그니처에 NSRect를 그대로 두면 Zig가 올바른 cc 선택.
/// initWithFrame:은 alloc된 NSView를 반환해 ?*anyopaque를 돌려주지만 setFrame:은 void —
/// 호출자가 반환값을 _ = 으로 처리하면 동일 헬퍼 재사용 가능.
fn msgSendNSRect(target: ?*anyopaque, sel_name: [:0]const u8, rect: NSRect) ?*anyopaque {
    const sel = objc.sel_registerName(sel_name.ptr);
    const func: *const fn (?*anyopaque, ?*anyopaque, NSRect) callconv(.c) ?*anyopaque = @ptrCast(&objc.objc_msgSend);
    return func(target, @ptrCast(sel), rect);
}

pub const MacWindowHandles = struct {
    content_view: ?*anyopaque,
    ns_window: ?*anyopaque,
};

// macOS Foundation/AppKit 기본 geometry 타입. ARM64 ABI는 4×f64 NSRect를 d0~d3 float
// 레지스터로 전달 — extern struct 그대로 두면 Zig가 올바른 calling convention 선택.
// 모든 macOS 헬퍼가 동일 정의 공유 (이전엔 createMacWindow / setMacWindowBounds /
// setMacContentSizeLimits 각각 별도 정의 → 필드명 불일치).
pub const NSPoint = extern struct { x: f64, y: f64 };
pub const NSSize = extern struct { width: f64, height: f64 };
pub const NSRect = extern struct { x: f64, y: f64, width: f64, height: f64 };

/// NSWindow 다중 cascade origin — 첫 호출은 (0, 0)으로 시작 (NSWindow가 화면에 적당히 배치),
/// 이후 매 호출마다 cascadeTopLeftFromPoint: 반환값으로 갱신 → 18px 우/하 offset 자동.
var g_cascade_point: NSPoint = .{ .x = 0, .y = 0 };

fn createMacWindow(opts: WindowInitOpts) MacWindowHandles {
    const window = allocMacWindow(opts) orelse return .{ .content_view = null, .ns_window = null };
    if (opts.x == 0 and opts.y == 0) advanceCascade(window);
    applyMacWindowOptions(window, opts);
    setMacWindowTitle(window, opts.title);
    const contentView = cef.msgSend(window, "contentView");
    cef.msgSendVoid1(window, "makeKeyAndOrderFront:", null);
    if (opts.constraints.fullscreen) toggleMacFullScreen(window);
    return .{ .content_view = contentView, .ns_window = window };
}

/// NSWindow.alloc + initWithContentRect:styleMask:backing:defer:.
/// frame=false면 borderless(0). frame=true면 titled+closable+miniaturizable[+resizable].
/// borderless 창도 키 이벤트를 받도록 NSWindow subclass `SujiKeyableWindow`를 사용 —
/// 기본 NSWindow.canBecomeKeyWindow는 borderless에서 NO 반환이라 frameless 창에 키 안 옴.
fn allocMacWindow(opts: WindowInitOpts) ?*anyopaque {
    const cls = ensureSujiKeyableWindowClass() orelse return null;
    const window_alloc = cef.msgSend(cls, "alloc") orelse return null;
    const initSel = objc.sel_registerName("initWithContentRect:styleMask:backing:defer:");
    const initFn: *const fn (?*anyopaque, ?*anyopaque, NSRect, u64, u64, u8) callconv(.c) ?*anyopaque = @ptrCast(&objc.objc_msgSend);
    return initFn(window_alloc, @ptrCast(initSel), resolveInitialFrame(opts), computeStyleMask(opts), 2, 0);
}

/// NSWindow subclass로 borderless(frame=false) 창의 canBecomeKeyWindow를 YES override.
/// 그래야 frameless 창에 키 이벤트(F12/Cmd+R 등)가 들어옴 — 기본 NSWindow는 borderless면
/// canBecomeKeyWindow=NO라 키 입력 무시. titled 창은 super가 이미 YES 반환이라 영향 X.
var g_keyable_window_class: ?*anyopaque = null;
fn ensureSujiKeyableWindowClass() ?*anyopaque {
    if (g_keyable_window_class) |existing| return existing;
    const ns_window = cef.getClass("NSWindow") orelse return null;
    const cls = objc.objc_allocateClassPair(ns_window, "SujiKeyableWindow", 0) orelse {
        return cef.getClass("SujiKeyableWindow");
    };
    const sel = objc.sel_registerName("canBecomeKeyWindow");
    _ = objc.class_addMethod(cls, @ptrCast(sel), @ptrCast(&returnYesBOOL), "c@:");
    const send_event_sel = objc.sel_registerName("sendEvent:");
    _ = objc.class_addMethod(cls, @ptrCast(send_event_sel), @ptrCast(&cef_drag_handler.sujiWindowSendEvent), "v@:@");
    objc.objc_registerClassPair(cls);
    g_keyable_window_class = cls;
    return cls;
}

fn returnYesBOOL(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) u8 {
    return 1;
}

/// NSWindowStyleMask: titled(1)+closable(2)+miniaturizable(4)+resizable(8).
fn computeStyleMask(opts: WindowInitOpts) u64 {
    if (!opts.appearance.frame) return 0;
    var mask: u64 = 1 | 2 | 4;
    if (opts.constraints.resizable) mask |= 8;
    return mask;
}

fn resolveInitialFrame(opts: WindowInitOpts) NSRect {
    const explicit = opts.x != 0 or opts.y != 0;
    return .{
        .x = if (explicit) @floatFromInt(opts.x) else 200,
        .y = if (explicit) @floatFromInt(opts.y) else 200,
        .width = @floatFromInt(opts.width),
        .height = @floatFromInt(opts.height),
    };
}

fn advanceCascade(window: *anyopaque) void {
    const sel = objc.sel_registerName("cascadeTopLeftFromPoint:");
    const fn_ptr: *const fn (?*anyopaque, ?*anyopaque, NSPoint) callconv(.c) NSPoint = @ptrCast(&objc.objc_msgSend);
    g_cascade_point = fn_ptr(window, @ptrCast(sel), g_cascade_point);
}

fn applyMacWindowOptions(window: *anyopaque, opts: WindowInitOpts) void {
    const ap = opts.appearance;
    const cs = opts.constraints;
    if (ap.transparent) applyTransparency(window);
    if (cs.always_on_top) setAlwaysOnTop(window);
    if (ap.background_color) |hex| applyBackgroundColor(window, hex);
    setMacContentSizeLimits(window, cs.min_width, cs.min_height, cs.max_width, cs.max_height);
    if (ap.title_bar_style != .default) applyTitleBarStyle(window, ap.title_bar_style);
}

pub fn applyCefViewsMacWindowOptions(ns_window: ?*anyopaque, opts: *const window_mod.CreateOptions) void {
    if (!comptime is_macos) return;
    const window = ns_window orelse return;
    const ap = opts.appearance;
    const cs = opts.constraints;

    if (ap.transparent) applyTransparency(window);
    if (cs.always_on_top) setAlwaysOnTop(window);
    if (ap.background_color) |hex| applyBackgroundColor(window, hex);
    setMacContentSizeLimits(window, cs.min_width, cs.min_height, cs.max_width, cs.max_height);
    if (ap.title_bar_style != .default) applyTitleBarStyle(window, ap.title_bar_style);
}

pub fn attachMacChildWindow(parent: *anyopaque, child: *anyopaque) void {
    const sel = objc.sel_registerName("addChildWindow:ordered:");
    const fn_ptr: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque, c_long) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    fn_ptr(parent, @ptrCast(sel), child, 1);
}

pub fn detachMacChildWindow(parent: *anyopaque, child: *anyopaque) void {
    const sel = objc.sel_registerName("removeChildWindow:");
    const fn_ptr: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    fn_ptr(parent, @ptrCast(sel), child);
}

pub fn orderMacWindowFront(window: *anyopaque) void {
    cef.msgSendVoid1(window, "orderFront:", null);
}

pub fn orderMacWindowOut(window: *anyopaque) void {
    cef.msgSendVoid1(window, "orderOut:", null);
}

pub fn setMacWindowFrameRaw(window: *anyopaque, frame: NSRect) void {
    const setFrameSel = objc.sel_registerName("setFrame:display:");
    const setFrameFn: *const fn (?*anyopaque, ?*anyopaque, NSRect, u8) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    setFrameFn(window, @ptrCast(setFrameSel), frame, 1);
}

fn nsViewConvertRectToWindow(view: *anyopaque, rect: NSRect) NSRect {
    const sel = objc.sel_registerName("convertRect:toView:");
    const fn_ptr: *const fn (?*anyopaque, ?*anyopaque, NSRect, ?*anyopaque) callconv(.c) NSRect = @ptrCast(&objc.objc_msgSend);
    return fn_ptr(view, @ptrCast(sel), rect, null);
}

pub fn nsViewBounds(view: *anyopaque) NSRect {
    const sel = objc.sel_registerName("bounds");
    const f: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) NSRect = @ptrCast(&objc.objc_msgSend);
    return f(view, @ptrCast(sel));
}

fn nsWindowConvertRectToScreen(window: *anyopaque, rect: NSRect) NSRect {
    const sel = objc.sel_registerName("convertRectToScreen:");
    const fn_ptr: *const fn (?*anyopaque, ?*anyopaque, NSRect) callconv(.c) NSRect = @ptrCast(&objc.objc_msgSend);
    return fn_ptr(window, @ptrCast(sel), rect);
}

pub fn childWindowFrameForBounds(parent_window: *anyopaque, bounds: window_mod.Bounds) ?NSRect {
    const content_view = cef.msgSend(parent_window, "contentView") orelse return null;
    const content_bounds = nsViewBounds(content_view);
    const content_window_rect = nsViewConvertRectToWindow(content_view, content_bounds);
    const content_screen_rect = nsWindowConvertRectToScreen(parent_window, content_window_rect);
    return .{
        .x = content_screen_rect.x + @as(f64, @floatFromInt(bounds.x)),
        .y = content_screen_rect.y + content_screen_rect.height -
            @as(f64, @floatFromInt(bounds.y)) -
            @as(f64, @floatFromInt(bounds.height)),
        .width = @floatFromInt(bounds.width),
        .height = @floatFromInt(bounds.height),
    };
}

fn applyTransparency(window: ?*anyopaque) void {
    cef.msgSendVoidBool(window, "setOpaque:", false);
    const NSColor = cef.getClass("NSColor") orelse return;
    if (cef.msgSend(NSColor, "clearColor")) |cc| {
        cef.msgSendVoid1(window, "setBackgroundColor:", cc);
    }
    cef.msgSendVoidBool(window, "setHasShadow:", false);
}

fn setAlwaysOnTop(window: ?*anyopaque) void {
    const sel = objc.sel_registerName("setLevel:");
    const fn_ptr: *const fn (?*anyopaque, ?*anyopaque, c_long) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    fn_ptr(window, @ptrCast(sel), 3);
}

fn setMacContentSizeLimits(window: ?*anyopaque, min_w: u32, min_h: u32, max_w: u32, max_h: u32) void {
    const SetSizeFn = *const fn (?*anyopaque, ?*anyopaque, NSSize) callconv(.c) void;

    if (min_w > 0 or min_h > 0) {
        const sel = objc.sel_registerName("setContentMinSize:");
        const fn_ptr: SetSizeFn = @ptrCast(&objc.objc_msgSend);
        fn_ptr(window, @ptrCast(sel), .{ .width = @floatFromInt(min_w), .height = @floatFromInt(min_h) });
    }
    if (max_w > 0 or max_h > 0) {
        const huge: f64 = std.math.floatMax(f64);
        const sel = objc.sel_registerName("setContentMaxSize:");
        const fn_ptr: SetSizeFn = @ptrCast(&objc.objc_msgSend);
        fn_ptr(window, @ptrCast(sel), .{
            .width = if (max_w > 0) @floatFromInt(max_w) else huge,
            .height = if (max_h > 0) @floatFromInt(max_h) else huge,
        });
    }
}

pub fn applyBackgroundColor(window: ?*anyopaque, hex: []const u8) void {
    if (hex.len < 7 or hex[0] != '#' or (hex.len != 7 and hex.len != 9)) {
        log.warn("backgroundColor: invalid format '{s}' (expected #RRGGBB or #RRGGBBAA)", .{hex});
        return;
    }
    const r = std.fmt.parseInt(u8, hex[1..3], 16) catch {
        log.warn("backgroundColor: hex parse failed '{s}'", .{hex});
        return;
    };
    const g = std.fmt.parseInt(u8, hex[3..5], 16) catch return;
    const b = std.fmt.parseInt(u8, hex[5..7], 16) catch return;
    const a: u8 = if (hex.len == 9)
        (std.fmt.parseInt(u8, hex[7..9], 16) catch 255)
    else
        255;

    const NSColor = cef.getClass("NSColor") orelse return;
    const sel = objc.sel_registerName("colorWithRed:green:blue:alpha:");
    const fn_ptr: *const fn (?*anyopaque, ?*anyopaque, f64, f64, f64, f64) callconv(.c) ?*anyopaque = @ptrCast(&objc.objc_msgSend);
    const color = fn_ptr(
        NSColor,
        @ptrCast(sel),
        @as(f64, @floatFromInt(r)) / 255.0,
        @as(f64, @floatFromInt(g)) / 255.0,
        @as(f64, @floatFromInt(b)) / 255.0,
        @as(f64, @floatFromInt(a)) / 255.0,
    ) orelse return;
    cef.msgSendVoid1(window, "setBackgroundColor:", color);
}

fn toggleMacFullScreen(window: ?*anyopaque) void {
    cef.msgSendVoid1(window, "toggleFullScreen:", null);
}

fn applyTitleBarStyle(window: ?*anyopaque, style: window_mod.TitleBarStyle) void {
    if (style == .default) return;
    cef.msgSendVoidBool(window, "setTitlebarAppearsTransparent:", true);

    const getMaskSel = objc.sel_registerName("styleMask");
    const getMaskFn: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) u64 = @ptrCast(&objc.objc_msgSend);
    const current_mask = getMaskFn(window, @ptrCast(getMaskSel));

    const setMaskSel = objc.sel_registerName("setStyleMask:");
    const setMaskFn: *const fn (?*anyopaque, ?*anyopaque, u64) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    setMaskFn(window, @ptrCast(setMaskSel), current_mask | (1 << 15));
}

pub fn closeMacWindow(ns_window: ?*anyopaque) void {
    const w = ns_window orelse return;
    const closeSel = objc.sel_registerName("close");
    const closeFn: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    closeFn(w, @ptrCast(closeSel));
}

pub fn setMacWindowTitle(ns_window: *anyopaque, title: []const u8) void {
    var buf: [512]u8 = undefined;
    if (title.len >= buf.len) return;
    @memcpy(buf[0..title.len], title);
    buf[title.len] = 0;

    const NSString = cef.getClass("NSString") orelse return;
    const strFn: *const fn (?*anyopaque, ?*anyopaque, [*:0]const u8) callconv(.c) ?*anyopaque = @ptrCast(&objc.objc_msgSend);
    const ns_title = strFn(NSString, @ptrCast(objc.sel_registerName("stringWithUTF8String:")), @ptrCast(&buf)) orelse return;

    cef.msgSendVoid1(ns_window, "setTitle:", ns_title);
}

pub fn setMacWindowBounds(ns_window: *anyopaque, bounds: window_mod.Bounds) void {
    const w_f: f64 = @floatFromInt(bounds.width);
    const h_f: f64 = @floatFromInt(bounds.height);
    const x_f: f64 = @floatFromInt(bounds.x);
    const top_y_f: f64 = @floatFromInt(bounds.y);

    const cocoa_y: f64 = blk: {
        const NSScreen = cef.getClass("NSScreen") orelse break :blk top_y_f;
        const mainScreen = cef.msgSend(NSScreen, "mainScreen") orelse break :blk top_y_f;
        const frameFn: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) NSRect = @ptrCast(&objc.objc_msgSend);
        const screen_frame = frameFn(mainScreen, @ptrCast(objc.sel_registerName("frame")));
        break :blk screen_frame.height - top_y_f - h_f;
    };

    const rect: NSRect = .{ .x = x_f, .y = cocoa_y, .width = w_f, .height = h_f };

    const setFrameSel = objc.sel_registerName("setFrame:display:");
    const setFrameFn: *const fn (?*anyopaque, ?*anyopaque, NSRect, u8) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    setFrameFn(ns_window, @ptrCast(setFrameSel), rect, 1);
}

// setMacWindowBounds 의 역 — NSWindow.frame 을 읽어 top-left 원점 Bounds 로 변환.
// Cocoa 는 bottom-left 원점이라 y 를 screen.height - frame.y - frame.height 로 뒤집는다
// (setMacWindowBounds 의 cocoa_y 계산을 역으로).
pub fn getMacWindowBounds(ns_window: *anyopaque) window_mod.Bounds {
    const frameFn: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) NSRect = @ptrCast(&objc.objc_msgSend);
    const frame = frameFn(ns_window, @ptrCast(objc.sel_registerName("frame")));

    const top_y: f64 = blk: {
        const NSScreen = cef.getClass("NSScreen") orelse break :blk frame.y;
        const mainScreen = cef.msgSend(NSScreen, "mainScreen") orelse break :blk frame.y;
        const sfFn: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) NSRect = @ptrCast(&objc.objc_msgSend);
        const screen_frame = sfFn(mainScreen, @ptrCast(objc.sel_registerName("frame")));
        break :blk screen_frame.height - frame.y - frame.height;
    };

    return .{
        .x = @intFromFloat(@round(frame.x)),
        .y = @intFromFloat(@round(top_y)),
        .width = @intFromFloat(@max(@round(frame.width), 0)),
        .height = @intFromFloat(@max(@round(frame.height), 0)),
    };
}

fn mainScreenHeight() f64 {
    const NSScreen = cef.getClass("NSScreen") orelse return 0;
    const mainScreen = cef.msgSend(NSScreen, "mainScreen") orelse return 0;
    const sfFn: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) NSRect = @ptrCast(&objc.objc_msgSend);
    return sfFn(mainScreen, @ptrCast(objc.sel_registerName("frame"))).height;
}

// getMacWindowBounds 의 content(타이틀바/프레임 제외) 버전 — contentRectForFrameRect:.
pub fn getMacWindowContentBounds(ns_window: *anyopaque) window_mod.Bounds {
    const frameFn: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) NSRect = @ptrCast(&objc.objc_msgSend);
    const frame = frameFn(ns_window, @ptrCast(objc.sel_registerName("frame")));
    const contentFn: *const fn (?*anyopaque, ?*anyopaque, NSRect) callconv(.c) NSRect = @ptrCast(&objc.objc_msgSend);
    const content = contentFn(ns_window, @ptrCast(objc.sel_registerName("contentRectForFrameRect:")), frame);
    const sh = mainScreenHeight();
    const top_y: f64 = if (sh > 0) sh - content.y - content.height else content.y;
    return .{
        .x = @intFromFloat(@round(content.x)),
        .y = @intFromFloat(@round(top_y)),
        .width = @intFromFloat(@max(@round(content.width), 0)),
        .height = @intFromFloat(@max(@round(content.height), 0)),
    };
}

// setMacWindowBounds 의 content 버전 — frameRectForContentRect: 로 프레임 환산 후 setFrame.
pub fn setMacWindowContentBounds(ns_window: *anyopaque, bounds: window_mod.Bounds) void {
    const w_f: f64 = @floatFromInt(bounds.width);
    const h_f: f64 = @floatFromInt(bounds.height);
    const x_f: f64 = @floatFromInt(bounds.x);
    const sh = mainScreenHeight();
    const cocoa_y: f64 = if (sh > 0) sh - @as(f64, @floatFromInt(bounds.y)) - h_f else @floatFromInt(bounds.y);
    const content_rect: NSRect = .{ .x = x_f, .y = cocoa_y, .width = w_f, .height = h_f };

    const frameForContentFn: *const fn (?*anyopaque, ?*anyopaque, NSRect) callconv(.c) NSRect = @ptrCast(&objc.objc_msgSend);
    const frame = frameForContentFn(ns_window, @ptrCast(objc.sel_registerName("frameRectForContentRect:")), content_rect);

    const setFrameFn: *const fn (?*anyopaque, ?*anyopaque, NSRect, u8) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    setFrameFn(ns_window, @ptrCast(objc.sel_registerName("setFrame:display:")), frame, 1);
}
