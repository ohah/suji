//! Process-wide CefNative singleton registry used by split CEF handlers.

const std = @import("std");
const cef = @import("cef.zig");

/// life_span_handler callbacks and other split modules use this stable pointer.
/// The process owns one CefNative instance; registering another instance replaces
/// the previous pointer, matching the legacy cef.zig behavior.
var g_cef_native: ?*cef.CefNative = null;

pub fn registerGlobal(native: *cef.CefNative) void {
    g_cef_native = native;
}

pub fn unregisterGlobal() void {
    g_cef_native = null;
}

pub fn globalNative() ?*cef.CefNative {
    return g_cef_native;
}

pub fn nativeAllocator() ?std.mem.Allocator {
    const native = g_cef_native orelse return null;
    return native.allocator;
}
