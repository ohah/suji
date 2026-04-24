//! Go 래퍼 통합 테스트.
//!
//! 시나리오: Zig BackendRegistry에 state 플러그인 + Go bridge 백엔드를 로드한다.
//! Go bridge는 suji.Bind로 노출된 메서드(`GoStateSet` 등)에서 plugins/state/go의
//! `state.Set/Get/...`를 호출하고, 그 래퍼가 `suji.Invoke("state", ...)`로
//! state dylib까지 왕복한다.
//!
//! Bind의 positional 파라미터 매핑(0→"name", 1→"text") 때문에 요청은
//! `{"cmd":"go_state_set","name":"k","text":"\"v\""}` 형태로 보낸다.
//!
//! 사전 조건:
//!   1) plugins/state/zig/zig-out/lib/libbackend.{dylib|so|dll}
//!   2) tests/fixtures/state_go_bridge/libbackend.{dylib|so|dll}
//!
//! 빌드 래퍼는 `zig build test-state-go`가 처리한다.

const std = @import("std");
const builtin = @import("builtin");
const loader = @import("loader");

const STATE_PATH = switch (builtin.os.tag) {
    .macos => "plugins/state/zig/zig-out/lib/libbackend.dylib",
    .linux => "plugins/state/zig/zig-out/lib/libbackend.so",
    .windows => "plugins/state/zig/zig-out/bin/backend.dll",
    else => @compileError("unsupported OS"),
};

const BRIDGE_PATH = switch (builtin.os.tag) {
    .macos => "tests/fixtures/state_go_bridge/libbackend.dylib",
    .linux => "tests/fixtures/state_go_bridge/libbackend.so",
    .windows => "tests/fixtures/state_go_bridge/backend.dll",
    else => @compileError("unsupported OS"),
};

fn setupRegistry(reg: *loader.BackendRegistry) !void {
    try reg.register("state", STATE_PATH);
    try reg.register("go", BRIDGE_PATH);
    freeResp(reg, "go", invokeGo(reg, "{\"cmd\":\"go_state_clear\"}"));
}

fn invokeGo(reg: *loader.BackendRegistry, request: []const u8) ?[]const u8 {
    var buf: [4096]u8 = undefined;
    const len = @min(request.len, buf.len - 1);
    @memcpy(buf[0..len], request[0..len]);
    buf[len] = 0;
    return reg.invoke("go", buf[0..len :0]);
}

fn freeResp(reg: *loader.BackendRegistry, name: []const u8, resp: ?[]const u8) void {
    reg.freeResponse(name, resp);
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "go wrapper: load both plugins" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();

    try setupRegistry(&reg);
    try std.testing.expect(reg.get("state") != null);
    try std.testing.expect(reg.get("go") != null);
}

test "go wrapper: set then get roundtrip" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try setupRegistry(&reg);

    const set_resp = invokeGo(&reg, "{\"cmd\":\"go_state_set\",\"name\":\"user\",\"text\":\"\\\"yoon\\\"\"}") orelse return error.NoResponse;
    defer freeResp(&reg, "go", set_resp);
    try std.testing.expect(contains(set_resp, "\"ok\":true"));

    const get_resp = invokeGo(&reg, "{\"cmd\":\"go_state_get\",\"name\":\"user\"}") orelse return error.NoResponse;
    defer freeResp(&reg, "go", get_resp);
    try std.testing.expect(contains(get_resp, "yoon"));
}

test "go wrapper: get missing key returns null" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try setupRegistry(&reg);

    const resp = invokeGo(&reg, "{\"cmd\":\"go_state_get\",\"name\":\"nonexistent\"}") orelse return error.NoResponse;
    defer freeResp(&reg, "go", resp);
    try std.testing.expect(contains(resp, "\"value\":null"));
}

test "go wrapper: delete removes key" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try setupRegistry(&reg);

    freeResp(&reg, "go", invokeGo(&reg, "{\"cmd\":\"go_state_set\",\"name\":\"temp\",\"text\":\"1\"}"));
    freeResp(&reg, "go", invokeGo(&reg, "{\"cmd\":\"go_state_delete\",\"name\":\"temp\"}"));

    const resp = invokeGo(&reg, "{\"cmd\":\"go_state_get\",\"name\":\"temp\"}") orelse return error.NoResponse;
    defer freeResp(&reg, "go", resp);
    try std.testing.expect(contains(resp, "\"value\":null"));
}

test "go wrapper: keys lists everything" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try setupRegistry(&reg);

    freeResp(&reg, "go", invokeGo(&reg, "{\"cmd\":\"go_state_set\",\"name\":\"a\",\"text\":\"1\"}"));
    freeResp(&reg, "go", invokeGo(&reg, "{\"cmd\":\"go_state_set\",\"name\":\"b\",\"text\":\"2\"}"));

    const resp = invokeGo(&reg, "{\"cmd\":\"go_state_keys\"}") orelse return error.NoResponse;
    defer freeResp(&reg, "go", resp);
    try std.testing.expect(contains(resp, "\"a\""));
    try std.testing.expect(contains(resp, "\"b\""));
}

test "go wrapper: object value roundtrip" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try setupRegistry(&reg);

    freeResp(&reg, "go", invokeGo(&reg, "{\"cmd\":\"go_state_set\",\"name\":\"cfg\",\"text\":\"{\\\"theme\\\":\\\"dark\\\"}\"}"));

    const resp = invokeGo(&reg, "{\"cmd\":\"go_state_get\",\"name\":\"cfg\"}") orelse return error.NoResponse;
    defer freeResp(&reg, "go", resp);
    try std.testing.expect(contains(resp, "theme"));
    try std.testing.expect(contains(resp, "dark"));
}
