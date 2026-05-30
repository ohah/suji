//! CEF Views BrowserView delegate.

const std = @import("std");
const cef = @import("cef.zig");

const c = cef.c;

pub const ViewsBrowserViewDelegate = struct {
    delegate: c.cef_browser_view_delegate_t = undefined,
    allocator: std.mem.Allocator,
    ref_count: std.atomic.Value(u32) = .init(1),
    created_browser: ?*c.cef_browser_t = null,
    created_handle: u64 = 0,
};

fn viewsBrowserFromBase(base: ?*c.cef_base_ref_counted_t) ?*ViewsBrowserViewDelegate {
    return @ptrCast(@alignCast(base orelse return null));
}

fn viewsBrowserFromSelf(self: ?*c._cef_browser_view_delegate_t) ?*ViewsBrowserViewDelegate {
    return @ptrCast(@alignCast(self orelse return null));
}

fn viewsBrowserAddRef(base: ?*c.cef_base_ref_counted_t) callconv(.c) void {
    const d = viewsBrowserFromBase(base) orelse return;
    _ = d.ref_count.fetchAdd(1, .acq_rel);
}

fn viewsBrowserRelease(base: ?*c.cef_base_ref_counted_t) callconv(.c) i32 {
    const d = viewsBrowserFromBase(base) orelse return 0;
    if (d.ref_count.fetchSub(1, .acq_rel) != 1) return 0;
    d.allocator.destroy(d);
    return 1;
}

fn viewsBrowserHasOneRef(base: ?*c.cef_base_ref_counted_t) callconv(.c) i32 {
    const d = viewsBrowserFromBase(base) orelse return 0;
    return if (d.ref_count.load(.acquire) == 1) 1 else 0;
}

fn viewsBrowserHasAtLeastOneRef(base: ?*c.cef_base_ref_counted_t) callconv(.c) i32 {
    const d = viewsBrowserFromBase(base) orelse return 0;
    return if (d.ref_count.load(.acquire) >= 1) 1 else 0;
}

fn viewsBrowserOnCreated(
    self: ?*c._cef_browser_view_delegate_t,
    _: ?*c._cef_browser_view_t,
    browser: ?*c._cef_browser_t,
) callconv(.c) void {
    const d = viewsBrowserFromSelf(self) orelse return;
    const br = browser orelse return;
    d.created_browser = @ptrCast(br);
    d.created_handle = @intCast(br.get_identifier.?(br));
}

fn viewsBrowserOnDestroyed(
    self: ?*c._cef_browser_view_delegate_t,
    _: ?*c._cef_browser_view_t,
    browser: ?*c._cef_browser_t,
) callconv(.c) void {
    const d = viewsBrowserFromSelf(self) orelse return;
    if (browser) |br| {
        const id: u64 = @intCast(br.get_identifier.?(br));
        if (d.created_handle == id) {
            d.created_browser = null;
            d.created_handle = 0;
        }
    }
}

fn viewsBrowserRuntimeStyle(_: ?*c._cef_browser_view_delegate_t) callconv(.c) c.cef_runtime_style_t {
    return c.CEF_RUNTIME_STYLE_ALLOY;
}

pub fn createViewsBrowserDelegate(allocator: std.mem.Allocator) !*ViewsBrowserViewDelegate {
    const d = try allocator.create(ViewsBrowserViewDelegate);
    d.* = .{ .allocator = allocator };
    @memset(std.mem.asBytes(&d.delegate), 0);
    d.delegate.base.base.size = @sizeOf(c.cef_browser_view_delegate_t);
    d.delegate.base.base.add_ref = &viewsBrowserAddRef;
    d.delegate.base.base.release = &viewsBrowserRelease;
    d.delegate.base.base.has_one_ref = &viewsBrowserHasOneRef;
    d.delegate.base.base.has_at_least_one_ref = &viewsBrowserHasAtLeastOneRef;
    d.delegate.on_browser_created = &viewsBrowserOnCreated;
    d.delegate.on_browser_destroyed = &viewsBrowserOnDestroyed;
    d.delegate.get_browser_runtime_style = &viewsBrowserRuntimeStyle;
    return d;
}
