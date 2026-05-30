//! CEF drag handler — cef.zig 에서 분리(동작 무변경).
//! `-webkit-app-region` rectangles를 CEF Views와 macOS native drag hit-test에 공유한다.
const std = @import("std");
const logger = @import("logger");
const drag_region = @import("cef_drag_region.zig");
const cef = @import("cef.zig");

const c = cef.c;
const log = logger.module("cef");
const zeroCefStruct = cef.zeroCefStruct;
const initBaseRefCounted = cef.initBaseRefCounted;
const objc = cef.objc;
const getClass = cef.getClass;
const msgSend = cef.msgSend;
const msgSendVoid1 = cef.msgSendVoid1;
const NSPoint = cef.NSPoint;
const CefNative = cef.CefNative;

var g_drag_handler: c.cef_drag_handler_t = undefined;
var g_drag_handler_initialized: bool = false;

pub fn initDragHandler() void {
    if (g_drag_handler_initialized) return;
    zeroCefStruct(c.cef_drag_handler_t, &g_drag_handler);
    initBaseRefCounted(&g_drag_handler.base);
    g_drag_handler.on_drag_enter = &onDragEnter;
    g_drag_handler.on_draggable_regions_changed = &onDraggableRegionsChanged;
    g_drag_handler_initialized = true;
}

pub fn getDragHandler(_: ?*c._cef_client_t) callconv(.c) ?*c._cef_drag_handler_t {
    return &g_drag_handler;
}

fn onDragEnter(
    _: ?*c._cef_drag_handler_t,
    _: ?*c._cef_browser_t,
    _: ?*c._cef_drag_data_t,
    _: c.cef_drag_operations_mask_t,
) callconv(.c) i32 {
    return 0;
}

fn onDraggableRegionsChanged(
    _: ?*c._cef_drag_handler_t,
    browser: ?*c._cef_browser_t,
    frame: ?*c._cef_frame_t,
    regions_count: usize,
    regions_ptr: [*c]const c.cef_draggable_region_t,
) callconv(.c) void {
    const br = browser orelse return;
    const f = frame orelse return;
    if ((cef.frameIsMain(@ptrCast(f)) orelse false) == false) return;

    const native = cef.globalNative() orelse return;
    const handle: u64 = @intCast(br.get_identifier.?(br));
    const entry = native.browsers.getPtr(handle) orelse return;

    const has_views_window = entry.views_window != null;
    if (entry.views_window) |views_window| {
        if (regions_count == 0 or regions_ptr == null) {
            views_window.set_draggable_regions.?(views_window, 0, null);
        } else {
            views_window.set_draggable_regions.?(views_window, regions_count, regions_ptr);
        }
    }
    if (cef.traceDragRegionEnabled()) {
        std.debug.print(
            "[suji:drag-region] handle={d} count={d} views_window={} applied_to_cef_views={}\n",
            .{ handle, regions_count, has_views_window, has_views_window },
        );
    }

    native.allocator.free(entry.drag_regions);
    entry.drag_regions = &.{};

    if (regions_count == 0 or regions_ptr == null) return;

    const next = native.allocator.alloc(drag_region.DragRegion, regions_count) catch |e| {
        log.err("draggable regions allocation failed: {s}", .{@errorName(e)});
        return;
    };
    const source = regions_ptr[0..regions_count];
    for (source, 0..) |region, i| {
        next[i] = .{
            .x = region.bounds.x,
            .y = region.bounds.y,
            .width = region.bounds.width,
            .height = region.bounds.height,
            .draggable = region.draggable != 0,
        };
    }
    entry.drag_regions = next;
}

pub fn sujiWindowSendEvent(self: ?*anyopaque, cmd: ?*anyopaque, event: ?*anyopaque) callconv(.c) void {
    const window = self orelse return;
    const ev = event orelse return;
    if (shouldPerformNativeWindowDrag(window, ev)) {
        msgSendVoid1(window, "performWindowDragWithEvent:", ev);
        return;
    }
    callNSWindowSendEvent(window, cmd, ev);
}

fn callNSWindowSendEvent(window: *anyopaque, cmd: ?*anyopaque, event: *anyopaque) void {
    const ns_window = getClass("NSWindow") orelse return;
    const imp = objc.class_getMethodImplementation(ns_window, cmd);
    const f: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) void = @ptrCast(imp);
    f(window, cmd, event);
}

fn shouldPerformNativeWindowDrag(ns_window: *anyopaque, event: *anyopaque) bool {
    const event_type = nsEventType(event);
    if (event_type != 1) return false; // NSEventTypeLeftMouseDown

    const native = cef.globalNative() orelse return false;
    const entry = findBrowserEntryByNSWindow(native, ns_window) orelse return false;
    if (entry.drag_regions.len == 0) return false;

    const content_view = msgSend(ns_window, "contentView") orelse return false;
    const bounds = cef.nsViewBounds(content_view);
    const point = nsEventLocationInWindow(event);
    const x: i32 = @intFromFloat(@floor(point.x));
    const y: i32 = @intFromFloat(@floor(bounds.height - point.y));
    return drag_region.isPointDraggable(entry.drag_regions, x, y);
}

fn findBrowserEntryByNSWindow(native: *CefNative, ns_window: *anyopaque) ?*CefNative.BrowserEntry {
    var it = native.browsers.valueIterator();
    while (it.next()) |entry| {
        if (entry.ns_window == ns_window) return entry;
    }
    return null;
}

fn nsEventType(event: *anyopaque) u64 {
    const sel = objc.sel_registerName("type");
    const f: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) u64 = @ptrCast(&objc.objc_msgSend);
    return f(event, @ptrCast(sel));
}

fn nsEventLocationInWindow(event: *anyopaque) NSPoint {
    const sel = objc.sel_registerName("locationInWindow");
    const f: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) NSPoint = @ptrCast(&objc.objc_msgSend);
    return f(event, @ptrCast(sel));
}
