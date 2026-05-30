//! Native window handle lookup helpers shared by CEF platform modules.

const builtin = @import("builtin");
const cef = @import("cef.zig");

const c = cef.c;
const is_macos = builtin.os.tag == .macos;
const is_windows = builtin.os.tag == .windows;

fn nativeWindowHandlePtr(handle: anytype) ?*anyopaque {
    const T = @TypeOf(handle);
    return switch (@typeInfo(T)) {
        .optional => if (handle) |h| nativeWindowHandlePtr(h) else null,
        .pointer => if (@intFromPtr(handle) == 0) null else @ptrCast(handle),
        .int, .comptime_int => if (handle == 0) null else @ptrFromInt(@as(usize, @intCast(handle))),
        else => null,
    };
}

pub fn windowsEntryHwnd(entry: *const cef.CefNative.BrowserEntry) ?*anyopaque {
    if (!comptime is_windows) return null;
    if (entry.views_window) |views_window| {
        if (views_window.get_window_handle) |get_handle| {
            if (nativeWindowHandlePtr(get_handle(views_window))) |hwnd| return hwnd;
        }
    }
    const host = cef.asPtr(c.cef_browser_host_t, entry.browser.get_host.?(entry.browser)) orelse return null;
    if (host.get_window_handle) |get_handle| return nativeWindowHandlePtr(get_handle(host));
    return null;
}

pub fn collectTopLevelNativeWindowHandles(out: []?*anyopaque) usize {
    if (!comptime is_windows) return 0;
    const native = cef.globalNative() orelse return 0;
    var len: usize = 0;
    var it = native.browsers.valueIterator();
    while (it.next()) |entry| {
        if (len >= out.len) break;
        if (entry.views_parent_handle != null) continue;
        const hwnd = windowsEntryHwnd(entry) orelse continue;
        out[len] = hwnd;
        len += 1;
    }
    return len;
}

/// CEF browser native_handle -> NSWindow pointer lookup. main.zig converts a
/// WindowManager windowId to a browser handle before calling this helper.
pub fn nsWindowForBrowserHandle(handle: u64) ?*anyopaque {
    if (!comptime is_macos) return null;
    const native = cef.globalNative() orelse return null;
    const entry = native.browsers.get(handle) orelse return null;
    return entry.ns_window;
}
