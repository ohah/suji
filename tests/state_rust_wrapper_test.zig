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
    if (builtin.os.tag == .windows) return error.SkipZigTest;
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
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();

    try setupRegistry(&reg);
    try std.testing.expect(reg.get("state") != null);
    try std.testing.expect(reg.get("rust") != null);
}

test "rust wrapper: set then get roundtrip" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
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
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try setupRegistry(&reg);

    const resp = invokeRust(&reg, "{\"cmd\":\"rust_state_get\",\"key\":\"nonexistent\"}") orelse return error.NoResponse;
    defer freeResp(&reg, "rust", resp);
    try std.testing.expect(contains(resp, "\"value\":null"));
}

test "rust wrapper: delete removes key" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
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
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
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
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try setupRegistry(&reg);

    freeResp(&reg, "rust", invokeRust(&reg, "{\"cmd\":\"rust_state_set\",\"key\":\"cfg\",\"value\":\"{\\\"theme\\\":\\\"dark\\\"}\"}"));

    const resp = invokeRust(&reg, "{\"cmd\":\"rust_state_get\",\"key\":\"cfg\"}") orelse return error.NoResponse;
    defer freeResp(&reg, "rust", resp);
    try std.testing.expect(contains(resp, "theme"));
    try std.testing.expect(contains(resp, "dark"));
}

// ============================================
// Phase 2.5: scope (set_in / get_in / delete_in / keys_in / clear_scope)
// ============================================

test "rust wrapper: set_in / get_in roundtrip with window:N scope" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try setupRegistry(&reg);

    // window:1 scope에 저장
    freeResp(&reg, "rust", invokeRust(&reg, "{\"cmd\":\"rust_state_set_in\",\"key\":\"layout\",\"value\":\"\\\"split\\\"\",\"scope\":\"window:1\"}"));

    // 같은 scope로 조회 → 값 있음
    const resp_w1 = invokeRust(&reg, "{\"cmd\":\"rust_state_get_in\",\"key\":\"layout\",\"scope\":\"window:1\"}") orelse return error.NoResponse;
    defer freeResp(&reg, "rust", resp_w1);
    try std.testing.expect(contains(resp_w1, "split"));

    // global로는 안 보여야
    const resp_g = invokeRust(&reg, "{\"cmd\":\"rust_state_get\",\"key\":\"layout\"}") orelse return error.NoResponse;
    defer freeResp(&reg, "rust", resp_g);
    try std.testing.expect(contains(resp_g, "null"));
}

test "rust wrapper: clear_scope only clears that scope" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try setupRegistry(&reg);

    freeResp(&reg, "rust", invokeRust(&reg, "{\"cmd\":\"rust_state_set\",\"key\":\"a\",\"value\":\"\\\"global-v\\\"\"}"));
    freeResp(&reg, "rust", invokeRust(&reg, "{\"cmd\":\"rust_state_set_in\",\"key\":\"a\",\"value\":\"\\\"w5-v\\\"\",\"scope\":\"window:5\"}"));

    // window:5만 비움
    freeResp(&reg, "rust", invokeRust(&reg, "{\"cmd\":\"rust_state_clear_scope\",\"scope\":\"window:5\"}"));

    // global은 살아있음
    const g = invokeRust(&reg, "{\"cmd\":\"rust_state_get\",\"key\":\"a\"}") orelse return error.NoResponse;
    defer freeResp(&reg, "rust", g);
    try std.testing.expect(contains(g, "global-v"));

    // window:5는 사라짐
    const w5 = invokeRust(&reg, "{\"cmd\":\"rust_state_get_in\",\"key\":\"a\",\"scope\":\"window:5\"}") orelse return error.NoResponse;
    defer freeResp(&reg, "rust", w5);
    try std.testing.expect(contains(w5, "null"));
}

test "rust wrapper: keys_in returns prefix-stripped user keys" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try setupRegistry(&reg);

    freeResp(&reg, "rust", invokeRust(&reg, "{\"cmd\":\"rust_state_set_in\",\"key\":\"foo\",\"value\":\"1\",\"scope\":\"session:auth\"}"));
    freeResp(&reg, "rust", invokeRust(&reg, "{\"cmd\":\"rust_state_set_in\",\"key\":\"bar\",\"value\":\"2\",\"scope\":\"session:auth\"}"));
    freeResp(&reg, "rust", invokeRust(&reg, "{\"cmd\":\"rust_state_set\",\"key\":\"baz\",\"value\":\"3\"}")); // global

    const resp = invokeRust(&reg, "{\"cmd\":\"rust_state_keys_in\",\"scope\":\"session:auth\"}") orelse return error.NoResponse;
    defer freeResp(&reg, "rust", resp);
    try std.testing.expect(contains(resp, "foo"));
    try std.testing.expect(contains(resp, "bar"));
    try std.testing.expect(!contains(resp, "baz")); // global은 제외
}

// Rust SDK __SUJI_CORE OnceLock → AtomicPtr 회귀.
// 이전엔 OnceLock으로 첫 set만 성공 → 두 번째 reg의 backend_init이 silently 실패하고
// stale 포인터 유지 → invoke 시 use-after-free GP exception (Linux).
// AtomicPtr는 store가 항상 replace — 매 backend_init이 최신 포인터로 갱신.
//
// 명시 회귀: 4개 reg를 순차 생성/teardown하면서 매번 invoke 동작해야 함. 이전 OnceLock
// 구현이면 두 번째부터 crash, 현재는 통과.
test "회귀: __SUJI_CORE AtomicPtr — 다중 reg use-after-free 차단" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    // 4개 reg 순차 생성/teardown. OnceLock 시절엔 두 번째부터 stale 포인터로
    // GP exception (Linux). AtomicPtr는 매 backend_init이 store로 replace.
    for (0..4) |iter| {
        var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
        defer reg.deinit();
        reg.setGlobal();
        try setupRegistry(&reg);

        const set_resp = invokeRust(&reg, "{\"cmd\":\"rust_state_set\",\"key\":\"iter\",\"value\":\"1\"}") orelse {
            std.debug.print("iter {d}: no response — possible use-after-free regression\n", .{iter});
            return error.NoResponse;
        };
        defer freeResp(&reg, "rust", set_resp);
        try std.testing.expect(contains(set_resp, "\"ok\":true"));
    }
}

test "rust wrapper: delete_in removes key only in that scope" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try setupRegistry(&reg);

    // value를 다른 키 ("alpha"/"beta") 사용해 1글자 escape 엣지 회피.
    freeResp(&reg, "rust", invokeRust(&reg, "{\"cmd\":\"rust_state_set\",\"key\":\"x\",\"value\":\"\\\"alpha\\\"\"}"));
    freeResp(&reg, "rust", invokeRust(&reg, "{\"cmd\":\"rust_state_set_in\",\"key\":\"x\",\"value\":\"\\\"beta\\\"\",\"scope\":\"window:2\"}"));

    freeResp(&reg, "rust", invokeRust(&reg, "{\"cmd\":\"rust_state_delete_in\",\"key\":\"x\",\"scope\":\"window:2\"}"));

    const g = invokeRust(&reg, "{\"cmd\":\"rust_state_get\",\"key\":\"x\"}") orelse return error.NoResponse;
    defer freeResp(&reg, "rust", g);
    try std.testing.expect(contains(g, "alpha"));

    const w2 = invokeRust(&reg, "{\"cmd\":\"rust_state_get_in\",\"key\":\"x\",\"scope\":\"window:2\"}") orelse return error.NoResponse;
    defer freeResp(&reg, "rust", w2);
    try std.testing.expect(contains(w2, "null"));
}
