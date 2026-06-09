const std = @import("std");
const builtin = @import("builtin");
const loader = @import("loader");

const PLUGIN_PATH = switch (builtin.os.tag) {
    .macos => "plugins/positioner/zig/zig-out/lib/libbackend.dylib",
    .linux => "plugins/positioner/zig/zig-out/lib/libbackend.so",
    .windows => "plugins/positioner/zig/zig-out/bin/backend.dll",
    else => @compileError("unsupported OS"),
};

fn loadPos(reg: *loader.BackendRegistry) !void {
    try reg.register("positioner", PLUGIN_PATH);
}

fn invokePlugin(reg: *loader.BackendRegistry, request: []const u8) ?[]const u8 {
    var req_buf: [4096]u8 = undefined;
    const len = @min(request.len, req_buf.len - 1);
    @memcpy(req_buf[0..len], request[0..len]);
    req_buf[len] = 0;
    return reg.invoke("positioner", req_buf[0..len :0]);
}

fn freeResp(reg: *const loader.BackendRegistry, resp: ?[]const u8) void {
    reg.freeResponse("positioner", resp);
}

test "positioner plugin: load + channel" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadPos(&reg);
    try std.testing.expect(reg.get("positioner") != null);
}

test "positioner plugin: missing position → error" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadPos(&reg);

    // windowId 지정(id!=0)이지만 position 누락 → "missing position".
    const r = invokePlugin(&reg, "{\"cmd\":\"positioner:move\",\"windowId\":1}");
    defer freeResp(&reg, r);
    try std.testing.expect(r != null);
    try std.testing.expect(std.mem.indexOf(u8, r.?, "missing position") != null);
}

test "positioner plugin: no window → error (no @intCast panic on huge windowId)" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadPos(&reg);

    // __window 미주입 + windowId 미지정 → id=0 → "no window".
    const r1 = invokePlugin(&reg, "{\"cmd\":\"positioner:move\",\"position\":\"center\"}");
    defer freeResp(&reg, r1);
    try std.testing.expect(r1 != null);
    try std.testing.expect(std.mem.indexOf(u8, r1.?, "no window") != null);

    // u32 범위 밖 windowId → cast 실패 시 0 → "no window"(패닉 X).
    const r2 = invokePlugin(&reg, "{\"cmd\":\"positioner:move\",\"position\":\"center\",\"windowId\":99999999999}");
    defer freeResp(&reg, r2);
    try std.testing.expect(r2 != null);
    try std.testing.expect(std.mem.indexOf(u8, r2.?, "no window") != null);
}

test "positioner plugin: with windowId but no core window API → graceful error" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadPos(&reg);

    // test registry 엔 window/screen API 가 없어 getBounds 가 null → "get_bounds failed".
    // 크래시 없이 에러 반환(graceful). 실 좌표 계산은 e2e(실 CEF 창)가 검증.
    const r = invokePlugin(&reg, "{\"cmd\":\"positioner:move\",\"position\":\"center\",\"windowId\":1}");
    defer freeResp(&reg, r);
    try std.testing.expect(r != null);
    try std.testing.expect(std.mem.indexOf(u8, r.?, "\"error\"") != null);
}
