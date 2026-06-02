const std = @import("std");
const builtin = @import("builtin");
const loader = @import("loader");

// os-info + autostart 플러그인 통합 테스트 (state/sqlite/store 동형).
// dylib 선빌드 필요: cd plugins/<p>/zig && zig build.

fn dylib(comptime name: []const u8) [:0]const u8 {
    return switch (builtin.os.tag) {
        .macos => "plugins/" ++ name ++ "/zig/zig-out/lib/libbackend.dylib",
        .linux => "plugins/" ++ name ++ "/zig/zig-out/lib/libbackend.so",
        .windows => "plugins/" ++ name ++ "/zig/zig-out/bin/backend.dll",
        else => @compileError("unsupported OS"),
    };
}

fn invoke(reg: *loader.BackendRegistry, backend: [:0]const u8, request: []const u8) ?[]const u8 {
    var buf: [4096]u8 = undefined;
    const len = @min(request.len, buf.len - 1);
    @memcpy(buf[0..len], request[0..len]);
    buf[len] = 0;
    return reg.invoke(backend, buf[0..len :0]);
}

fn expectContains(resp: ?[]const u8, needle: []const u8) !void {
    try std.testing.expect(resp != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.?, needle) != null);
}

test "os plugin: info returns valid platform/arch + JSON-parseable" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try reg.register("os", dylib("os-info"));

    const resp = invoke(&reg, "os", "{\"cmd\":\"os:info\"}");
    defer reg.freeResponse("os", resp);
    try expectContains(resp, "\"platform\":");
    try expectContains(resp, "\"arch\":");
    try expectContains(resp, "\"sujiPlatform\":");
    const want = switch (builtin.os.tag) {
        .macos => "darwin",
        .linux => "linux",
        .windows => "win32",
        else => "unknown",
    };
    try expectContains(resp, want);
    // version/hostname/eol 은 valueAlloc 로 JSON-escape → 유효 JSON (parse 가능)
    const parsed = std.json.parseFromSlice(std.json.Value, std.testing.allocator, resp.?, .{}) catch
        return error.InvalidJsonResponse;
    parsed.deinit();
}

test "autostart plugin: enable/isEnabled/disable round-trip" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try reg.register("autostart", dylib("autostart"));

    const L = ",\"label\":\"suji-autostart-test\"";
    reg.freeResponse("autostart", invoke(&reg, "autostart", "{\"cmd\":\"autostart:disable\"" ++ L ++ "}"));
    {
        const r = invoke(&reg, "autostart", "{\"cmd\":\"autostart:enable\"" ++ L ++ "}");
        defer reg.freeResponse("autostart", r);
        // macOS/Linux 는 ok:true, 그 외는 supported:false (둘 다 비-크래시)
        try std.testing.expect(r != null);
    }
    {
        const r = invoke(&reg, "autostart", "{\"cmd\":\"autostart:isEnabled\"" ++ L ++ "}");
        defer reg.freeResponse("autostart", r);
        const want = if (builtin.os.tag == .macos or builtin.os.tag == .linux) "\"enabled\":true" else "\"supported\":false";
        try expectContains(r, want);
    }
    reg.freeResponse("autostart", invoke(&reg, "autostart", "{\"cmd\":\"autostart:disable\"" ++ L ++ "}"));
    {
        const r = invoke(&reg, "autostart", "{\"cmd\":\"autostart:isEnabled\"" ++ L ++ "}");
        defer reg.freeResponse("autostart", r);
        try expectContains(r, "\"enabled\":false");
    }
}
