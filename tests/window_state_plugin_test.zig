const std = @import("std");
const builtin = @import("builtin");
const loader = @import("loader");

const PLUGIN_PATH = switch (builtin.os.tag) {
    .macos => "plugins/window-state/zig/zig-out/lib/libbackend.dylib",
    .linux => "plugins/window-state/zig/zig-out/lib/libbackend.so",
    .windows => "plugins/window-state/zig/zig-out/bin/backend.dll",
    else => @compileError("unsupported OS"),
};

fn loadWs(reg: *loader.BackendRegistry) !void {
    try reg.register("window-state", PLUGIN_PATH);
}

fn invokePlugin(reg: *loader.BackendRegistry, request: []const u8) ?[]const u8 {
    var req_buf: [4096]u8 = undefined;
    const len = @min(request.len, req_buf.len - 1);
    @memcpy(req_buf[0..len], request[0..len]);
    req_buf[len] = 0;
    return reg.invoke("window-state", req_buf[0..len :0]);
}

fn freeResp(reg: *const loader.BackendRegistry, resp: ?[]const u8) void {
    reg.freeResponse("window-state", resp);
}

var test_counter: u64 = 0;
fn uniqueKey(buf: []u8) ![]const u8 {
    test_counter += 1;
    return std.fmt.bufPrint(buf, "wstest-{d}", .{test_counter});
}

test "window-state plugin: load + channels" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadWs(&reg);
    try std.testing.expect(reg.get("window-state") != null);
}

test "window-state plugin: get fresh key → state null" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadWs(&reg);

    var key_buf: [64]u8 = undefined;
    const key = try uniqueKey(&key_buf);
    var b: [256]u8 = undefined;
    const r = invokePlugin(&reg, try std.fmt.bufPrint(&b, "{{\"cmd\":\"window-state:get\",\"key\":\"{s}\"}}", .{key}));
    defer freeResp(&reg, r);
    try std.testing.expect(r != null);
    try std.testing.expect(std.mem.indexOf(u8, r.?, "\"state\":null") != null);
}

test "window-state plugin: clear is ok (idempotent)" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadWs(&reg);

    var key_buf: [64]u8 = undefined;
    const key = try uniqueKey(&key_buf);
    var b: [256]u8 = undefined;
    const r = invokePlugin(&reg, try std.fmt.bufPrint(&b, "{{\"cmd\":\"window-state:clear\",\"key\":\"{s}\"}}", .{key}));
    defer freeResp(&reg, r);
    try std.testing.expect(r != null);
    try std.testing.expect(std.mem.indexOf(u8, r.?, "\"ok\":true") != null);
}

test "window-state plugin: save without window → no window error" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadWs(&reg);

    // __window 미주입 + windowId 미지정 → id=0 → "no window".
    const r = invokePlugin(&reg, "{\"cmd\":\"window-state:save\",\"key\":\"x\"}");
    defer freeResp(&reg, r);
    try std.testing.expect(r != null);
    try std.testing.expect(std.mem.indexOf(u8, r.?, "\"error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.?, "no window") != null);
}

test "window-state plugin: save with windowId but no core window API → graceful error" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadWs(&reg);

    // windowId 는 있지만 test registry 엔 window API(get_window_api_fn)/__core__ 백엔드가
    // 없어 getBounds 가 null → "get_bounds failed". 크래시 없이 에러 반환(graceful).
    const r = invokePlugin(&reg, "{\"cmd\":\"window-state:save\",\"key\":\"x\",\"windowId\":1}");
    defer freeResp(&reg, r);
    try std.testing.expect(r != null);
    try std.testing.expect(std.mem.indexOf(u8, r.?, "\"error\"") != null);
}

test "window-state plugin: restore with no stored state → restored false" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadWs(&reg);

    var key_buf: [64]u8 = undefined;
    const key = try uniqueKey(&key_buf);
    var b: [256]u8 = undefined;
    // windowId 지정(id!=0)이지만 저장값 없음 → restored:false (window API 호출 전 early return).
    const r = invokePlugin(&reg, try std.fmt.bufPrint(&b, "{{\"cmd\":\"window-state:restore\",\"key\":\"{s}\",\"windowId\":1}}", .{key}));
    defer freeResp(&reg, r);
    try std.testing.expect(r != null);
    try std.testing.expect(std.mem.indexOf(u8, r.?, "\"restored\":false") != null);
}

test "window-state plugin: out-of-range windowId → graceful (no @intCast panic)" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadWs(&reg);

    // u32 범위 밖 windowId — resolveWindowId 가 cast 실패 시 0 으로(패닉 X) → "no window".
    const r = invokePlugin(&reg, "{\"cmd\":\"window-state:save\",\"key\":\"x\",\"windowId\":99999999999}");
    defer freeResp(&reg, r);
    try std.testing.expect(r != null);
    try std.testing.expect(std.mem.indexOf(u8, r.?, "no window") != null);
}

test "window-state plugin: invalid key rejected (path traversal)" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadWs(&reg);

    const bad = [_][]const u8{
        "{\"cmd\":\"window-state:get\",\"key\":\"../evil\"}",
        "{\"cmd\":\"window-state:get\",\"key\":\"..\"}",
        "{\"cmd\":\"window-state:get\",\"key\":\".\"}",
        "{\"cmd\":\"window-state:get\",\"key\":\"\"}",
        "{\"cmd\":\"window-state:get\",\"key\":\"foo/bar\"}",
        "{\"cmd\":\"window-state:clear\",\"key\":\"foo bar\"}",
    };
    for (bad) |req| {
        const r = invokePlugin(&reg, req);
        defer freeResp(&reg, r);
        try std.testing.expect(r != null);
        try std.testing.expect(std.mem.indexOf(u8, r.?, "\"error\"") != null);
    }
}
