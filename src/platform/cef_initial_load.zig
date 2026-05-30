//! Initial load retry helpers for CEF Views startup URL races.
const std = @import("std");
const cef = @import("cef.zig");
const cef_views_delegate = @import("cef_views_delegate.zig");

const c = cef.c;

pub fn rememberInitialUrl(entry: anytype, url_z: [:0]const u8) void {
    if (url_z.len == 0 or cef.isAboutBlankUrl(url_z) or url_z.len >= entry.initial_url_buf.len) return;
    @memcpy(entry.initial_url_buf[0..url_z.len], url_z);
    entry.initial_url_len = url_z.len;
    entry.initial_load_pending = true;
}

fn entryInitialUrl(entry: anytype) []const u8 {
    return entry.initial_url_buf[0..entry.initial_url_len];
}

fn currentMainFrameUrl(browser: *c.cef_browser_t, buf: []u8) ?[]const u8 {
    const frame = cef.asPtr(c.cef_frame_t, browser.get_main_frame.?(browser)) orelse return null;
    const get_url = frame.get_url orelse return null;
    const userfree = get_url(frame);
    if (userfree == null) return null;
    const url = cef.cefUserfreeToUtf8(userfree, buf);
    if (url.len == 0) return null;
    return url;
}

pub fn forceInitialLoadUrl(browser: *c.cef_browser_t, url_z: [:0]const u8) void {
    const frame = cef.asPtr(c.cef_frame_t, browser.get_main_frame.?(browser)) orelse return;
    var cef_url: c.cef_string_t = .{};
    setUrlOrBlank(&cef_url, url_z);
    const load_url = frame.load_url orelse return;
    load_url(frame, &cef_url);
}

fn setUrlOrBlank(dest: *c.cef_string_t, url_z: []const u8) void {
    cef.setCefString(dest, if (url_z.len > 0) url_z else "about:blank");
}

const InitialLoadTask = struct {
    task: c.cef_task_t = undefined,
    allocator: std.mem.Allocator,
    ref_count: std.atomic.Value(u32) = .init(1),
    handle: u64,
    url_buf: [2048]u8 = undefined,
    url_len: usize = 0,
};

fn initialLoadTaskFromBase(base: ?*c.cef_base_ref_counted_t) ?*InitialLoadTask {
    return @ptrCast(@alignCast(base orelse return null));
}

fn initialLoadTaskFromSelf(self: ?*c._cef_task_t) ?*InitialLoadTask {
    return @ptrCast(@alignCast(self orelse return null));
}

fn initialLoadTaskAddRef(base: ?*c.cef_base_ref_counted_t) callconv(.c) void {
    const task = initialLoadTaskFromBase(base) orelse return;
    _ = task.ref_count.fetchAdd(1, .acq_rel);
}

fn initialLoadTaskRelease(base: ?*c.cef_base_ref_counted_t) callconv(.c) i32 {
    const task = initialLoadTaskFromBase(base) orelse return 0;
    if (task.ref_count.fetchSub(1, .acq_rel) != 1) return 0;
    task.allocator.destroy(task);
    return 1;
}

fn initialLoadTaskHasOneRef(base: ?*c.cef_base_ref_counted_t) callconv(.c) i32 {
    const task = initialLoadTaskFromBase(base) orelse return 0;
    return if (task.ref_count.load(.acquire) == 1) 1 else 0;
}

fn initialLoadTaskHasAtLeastOneRef(base: ?*c.cef_base_ref_counted_t) callconv(.c) i32 {
    const task = initialLoadTaskFromBase(base) orelse return 0;
    return if (task.ref_count.load(.acquire) >= 1) 1 else 0;
}

fn initialLoadTaskExecute(self: ?*c._cef_task_t) callconv(.c) void {
    const task = initialLoadTaskFromSelf(self) orelse return;
    const native = cef.globalNative() orelse return;
    const entry = native.browsers.getPtr(task.handle) orelse return;
    if (!entry.initial_load_pending) return;

    const requested = entryInitialUrl(entry);
    if (requested.len == 0 or !std.mem.eql(u8, requested, task.url_buf[0..task.url_len])) return;

    var url_buf: [2048]u8 = undefined;
    if (currentMainFrameUrl(entry.browser, &url_buf)) |current| {
        if (std.mem.eql(u8, current, requested)) {
            entry.initial_load_pending = false;
            return;
        }
        if (!cef.isAboutBlankUrl(current)) {
            entry.initial_load_pending = false;
            return;
        }
    }

    const requested_z = task.url_buf[0..task.url_len :0];
    forceInitialLoadUrl(entry.browser, requested_z);
}

fn scheduleInitialLoadRetry(allocator: std.mem.Allocator, handle: u64, url_z: [:0]const u8, delay_ms: i64) void {
    if (url_z.len == 0 or cef.isAboutBlankUrl(url_z) or url_z.len >= 2048) return;
    const task = allocator.create(InitialLoadTask) catch return;
    task.* = .{
        .allocator = allocator,
        .handle = handle,
        .url_len = url_z.len,
    };
    @memset(std.mem.asBytes(&task.task), 0);
    task.task.base.size = @sizeOf(c.cef_task_t);
    task.task.base.add_ref = &initialLoadTaskAddRef;
    task.task.base.release = &initialLoadTaskRelease;
    task.task.base.has_one_ref = &initialLoadTaskHasOneRef;
    task.task.base.has_at_least_one_ref = &initialLoadTaskHasAtLeastOneRef;
    task.task.execute = &initialLoadTaskExecute;
    @memcpy(task.url_buf[0..url_z.len], url_z);
    task.url_buf[url_z.len] = 0;

    if (c.cef_post_delayed_task(c.TID_UI, &task.task, delay_ms) != 1) {
        cef_views_delegate.releaseCefBase(&task.task.base);
    }
}

pub fn scheduleInitialLoadRetries(allocator: std.mem.Allocator, handle: u64, url_z: [:0]const u8) void {
    scheduleInitialLoadRetry(allocator, handle, url_z, 250);
    scheduleInitialLoadRetry(allocator, handle, url_z, 1500);
    scheduleInitialLoadRetry(allocator, handle, url_z, 4000);
}
