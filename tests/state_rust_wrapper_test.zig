//! Rust 래퍼 통합 테스트.
//!
//! 시나리오: Zig BackendRegistry에 state 플러그인 + Rust bridge 백엔드를 로드한다.
//! Rust bridge의 rust_state_* 핸들러는 내부적으로 `suji_plugin_state::{set,get,...}`를
//! 호출하고, 래퍼는 다시 `suji::invoke("state", ...)`로 state dylib를 호출한다.
//! 이 경로 전체(Rust 래퍼 → SujiCore.invoke → state dylib → 응답 역직렬화)가
//! 동작해야 테스트가 통과한다.
//!
//! 사전 조건:
//!   1) plugins/state/zig/zig-out/lib/libbackend.{dylib|so|dll}
//!   2) tests/fixtures/state_rust_bridge/target/debug/libstate_rust_bridge.{dylib|so|dll}
//!
//! 빌드 래퍼는 `zig build test-state-rust`가 처리한다.

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
    .macos => "tests/fixtures/state_rust_bridge/target/debug/libstate_rust_bridge.dylib",
    .linux => "tests/fixtures/state_rust_bridge/target/debug/libstate_rust_bridge.so",
    .windows => "tests/fixtures/state_rust_bridge/target/debug/state_rust_bridge.dll",
    else => @compileError("unsupported OS"),
};

fn setupRegistry(reg: *loader.BackendRegistry) !void {
    try reg.register("state", STATE_PATH);
    try reg.register("rust", BRIDGE_PATH);
    freeResp(reg, "rust", invokeRust(reg, "{\"cmd\":\"rust_state_clear\"}"));
}

fn invokeRust(reg: *loader.BackendRegistry, request: []const u8) ?[]const u8 {
    var buf: [4096]u8 = undefined;
    const len = @min(request.len, buf.len - 1);
    @memcpy(buf[0..len], request[0..len]);
    buf[len] = 0;
    return reg.invoke("rust", buf[0..len :0]);
}

fn freeResp(reg: *loader.BackendRegistry, name: []const u8, resp: ?[]const u8) void {
    reg.freeResponse(name, resp);
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "rust wrapper: load both plugins" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator);
    defer reg.deinit();
    reg.setGlobal();

    try setupRegistry(&reg);
    try std.testing.expect(reg.get("state") != null);
    try std.testing.expect(reg.get("rust") != null);
}

test "rust wrapper: set then get roundtrip" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator);
    defer reg.deinit();
    reg.setGlobal();
    try setupRegistry(&reg);

    // state::set("user", "\"yoon\"")
    const set_resp = invokeRust(&reg, "{\"cmd\":\"rust_state_set\",\"key\":\"user\",\"value\":\"\\\"yoon\\\"\"}") orelse return error.NoResponse;
    defer freeResp(&reg, "rust", set_resp);
    try std.testing.expect(contains(set_resp, "\"ok\":true"));

    // state::get("user") → "\"yoon\""
    const get_resp = invokeRust(&reg, "{\"cmd\":\"rust_state_get\",\"key\":\"user\"}") orelse return error.NoResponse;
    defer freeResp(&reg, "rust", get_resp);
    try std.testing.expect(contains(get_resp, "yoon"));
}

test "rust wrapper: get missing key returns null" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator);
    defer reg.deinit();
    reg.setGlobal();
    try setupRegistry(&reg);

    const resp = invokeRust(&reg, "{\"cmd\":\"rust_state_get\",\"key\":\"nonexistent\"}") orelse return error.NoResponse;
    defer freeResp(&reg, "rust", resp);
    try std.testing.expect(contains(resp, "\"value\":null"));
}

test "rust wrapper: delete removes key" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator);
    defer reg.deinit();
    reg.setGlobal();
    try setupRegistry(&reg);

    freeResp(&reg, "rust", invokeRust(&reg, "{\"cmd\":\"rust_state_set\",\"key\":\"temp\",\"value\":\"1\"}"));
    freeResp(&reg, "rust", invokeRust(&reg, "{\"cmd\":\"rust_state_delete\",\"key\":\"temp\"}"));

    const resp = invokeRust(&reg, "{\"cmd\":\"rust_state_get\",\"key\":\"temp\"}") orelse return error.NoResponse;
    defer freeResp(&reg, "rust", resp);
    try std.testing.expect(contains(resp, "\"value\":null"));
}

test "rust wrapper: keys lists everything" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator);
    defer reg.deinit();
    reg.setGlobal();
    try setupRegistry(&reg);

    freeResp(&reg, "rust", invokeRust(&reg, "{\"cmd\":\"rust_state_set\",\"key\":\"a\",\"value\":\"1\"}"));
    freeResp(&reg, "rust", invokeRust(&reg, "{\"cmd\":\"rust_state_set\",\"key\":\"b\",\"value\":\"2\"}"));

    const resp = invokeRust(&reg, "{\"cmd\":\"rust_state_keys\"}") orelse return error.NoResponse;
    defer freeResp(&reg, "rust", resp);
    try std.testing.expect(contains(resp, "\"a\""));
    try std.testing.expect(contains(resp, "\"b\""));
}

test "rust wrapper: object value roundtrip" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator);
    defer reg.deinit();
    reg.setGlobal();
    try setupRegistry(&reg);

    freeResp(&reg, "rust", invokeRust(&reg, "{\"cmd\":\"rust_state_set\",\"key\":\"cfg\",\"value\":\"{\\\"theme\\\":\\\"dark\\\"}\"}"));

    const resp = invokeRust(&reg, "{\"cmd\":\"rust_state_get\",\"key\":\"cfg\"}") orelse return error.NoResponse;
    defer freeResp(&reg, "rust", resp);
    try std.testing.expect(contains(resp, "theme"));
    try std.testing.expect(contains(resp, "dark"));
}
