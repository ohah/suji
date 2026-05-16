//! CEF 무관 헤드리스 통합 테스트.
//!
//! 코어를 CEF 없이 구동: embed C ABI shim → BackendRegistry 라우팅 →
//! 임베드 런타임 핸들러 → 응답, 그리고 EventBus emit → C 콜백 발화.
//! 기존엔 e2e(puppeteer + CEF DevTools)로만 잡히던 흐름을 단위 테스트로 내림.

const std = @import("std");
const embed = @import("embed");
const loader = @import("loader");

// 임베드 런타임 테스트 핸들러 (Node 폴백과 동일 C ABI 경로).
fn echoInvoke(channel: [*:0]const u8, data: [*:0]const u8) callconv(.c) ?[*:0]const u8 {
    _ = channel;
    _ = data;
    const resp = "{\"pong\":1}";
    const buf = std.heap.c_allocator.allocSentinel(u8, resp.len, 0) catch return null;
    @memcpy(buf, resp);
    return buf.ptr;
}
var echo_free_calls: usize = 0;
fn echoFree(ptr: [*:0]const u8) callconv(.c) void {
    echo_free_calls += 1;
    std.heap.c_allocator.free(std.mem.span(ptr));
}

test "embed: invoke routes through registry to embed runtime (no CEF)" {
    try embed.init(std.testing.allocator, std.testing.io);
    defer embed.deinit();

    try loader.BackendRegistry.registerEmbedRuntime("echo", .{
        .invoke = echoInvoke,
        .free_response = echoFree,
    });

    const resp = embed.invokeOwned("echo", "{\"cmd\":\"echo\"}");
    defer embed.freeResponse(resp);

    const body = std.mem.span(@as([*:0]const u8, @ptrCast(resp)));
    try std.testing.expectEqualStrings("{\"pong\":1}", body);
}

test "embed: EventBus emit reaches C-ABI listener (no CEF)" {
    try embed.init(std.testing.allocator, std.testing.io);
    defer embed.deinit();

    const Ctx = struct {
        var hits: u32 = 0;
        var last: [64]u8 = undefined;
        var last_len: usize = 0;
        fn cb(_: [*c]const u8, data: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
            hits += 1;
            const d = std.mem.span(@as([*:0]const u8, @ptrCast(data)));
            const n = @min(d.len, last.len);
            @memcpy(last[0..n], d[0..n]);
            last_len = n;
        }
    };
    Ctx.hits = 0;
    Ctx.last_len = 0;

    const id = embed.eventBus().onC("ping", &Ctx.cb, null);
    try std.testing.expect(id != 0);

    embed.eventBus().emit("ping", "{\"n\":42}");
    try std.testing.expectEqual(@as(u32, 1), Ctx.hits);
    try std.testing.expectEqualStrings("{\"n\":42}", Ctx.last[0..Ctx.last_len]);

    // off 후엔 더 이상 발화하지 않음.
    embed.eventBus().off(id);
    embed.eventBus().emit("ping", "{}");
    try std.testing.expectEqual(@as(u32, 1), Ctx.hits);
}

test "embed: C ABI export surface (suji_core_*) drives core end-to-end" {
    const c = struct {
        extern fn suji_core_init() c_int;
        extern fn suji_core_destroy() void;
        extern fn suji_core_invoke(channel: [*c]const u8, json: [*c]const u8) [*c]const u8;
        extern fn suji_core_free(ptr: [*c]const u8) void;
        extern fn suji_core_emit(event_name: [*c]const u8, json: [*c]const u8) void;
        extern fn suji_core_on(
            event_name: [*c]const u8,
            callback: ?*const fn ([*c]const u8, [*c]const u8, ?*anyopaque) callconv(.c) void,
            arg: ?*anyopaque,
        ) u64;
        extern fn suji_core_off(listener_id: u64) void;
    };

    try std.testing.expectEqual(@as(c_int, 0), c.suji_core_init());
    defer c.suji_core_destroy();

    try loader.BackendRegistry.registerEmbedRuntime("echo", .{
        .invoke = echoInvoke,
        .free_response = echoFree,
    });

    const resp = c.suji_core_invoke("echo", "{\"cmd\":\"echo\"}");
    try std.testing.expectEqualStrings("{\"pong\":1}", std.mem.span(@as([*:0]const u8, @ptrCast(resp))));
    c.suji_core_free(resp);

    const Ctx = struct {
        var hits: u32 = 0;
        fn cb(_: [*c]const u8, _: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
            hits += 1;
        }
    };
    Ctx.hits = 0;
    const id = c.suji_core_on("evt", &Ctx.cb, null);
    try std.testing.expect(id != 0);
    c.suji_core_emit("evt", "{}");
    try std.testing.expectEqual(@as(u32, 1), Ctx.hits);
    c.suji_core_off(id);
    c.suji_core_emit("evt", "{}");
    try std.testing.expectEqual(@as(u32, 1), Ctx.hits);
}

test "embed: suji_core_register_handler routes invoke to host handler" {
    const c = struct {
        extern fn suji_core_init() c_int;
        extern fn suji_core_destroy() void;
        extern fn suji_core_invoke(channel: [*c]const u8, json: [*c]const u8) [*c]const u8;
        extern fn suji_core_free(ptr: [*c]const u8) void;
        extern fn suji_core_register_handler(
            channel: [*c]const u8,
            invoke_cb: ?*const fn ([*:0]const u8, [*:0]const u8) callconv(.c) ?[*:0]const u8,
            free_cb: ?*const fn ([*:0]const u8) callconv(.c) void,
        ) c_int;
    };

    try std.testing.expectEqual(@as(c_int, 0), c.suji_core_init());
    defer c.suji_core_destroy();

    // 호스트(Swift/Kotlin 자리)가 "ping" 을 네이티브로 응답하도록 등록.
    try std.testing.expectEqual(@as(c_int, 0), c.suji_core_register_handler("ping", echoInvoke, echoFree));

    echo_free_calls = 0;
    const resp = c.suji_core_invoke("ping", "{\"from\":\"host\"}");
    try std.testing.expectEqualStrings("{\"pong\":1}", std.mem.span(@as([*:0]const u8, @ptrCast(resp))));
    // 메모리 계약: 코어가 호스트 응답을 복사하고 free_cb 로 원본을 반납.
    try std.testing.expectEqual(@as(usize, 1), echo_free_calls);
    c.suji_core_free(resp);

    // 미초기화 가드: destroy 후 등록은 -1.
    c.suji_core_destroy();
    try std.testing.expectEqual(@as(c_int, -1), c.suji_core_register_handler("x", echoInvoke, echoFree));
    // defer 의 두 번째 destroy 는 idempotent (no-op).
}

test "embed: suji_core_last_error 가 실패 사유를 노출" {
    const c = struct {
        extern fn suji_core_init() c_int;
        extern fn suji_core_destroy() void;
        extern fn suji_core_last_error() [*c]const u8;
        extern fn suji_core_register_handler(
            channel: [*c]const u8,
            invoke_cb: ?*const fn ([*:0]const u8, [*:0]const u8) callconv(.c) ?[*:0]const u8,
            free_cb: ?*const fn ([*:0]const u8) callconv(.c) void,
        ) c_int;
    };
    const lastErr = struct {
        fn get() []const u8 {
            return std.mem.span(@as([*:0]const u8, @ptrCast(c.suji_core_last_error())));
        }
    }.get;
    const has = struct {
        fn f(needle: []const u8) bool {
            return std.mem.indexOf(u8, lastErr(), needle) != null;
        }
    }.f;

    c.suji_core_destroy(); // 미초기화 상태 보장

    // 미초기화에서 register → -1 + 사유
    try std.testing.expectEqual(@as(c_int, -1), c.suji_core_register_handler("x", echoInvoke, echoFree));
    try std.testing.expect(has("not initialized"));

    // 성공 init → 사유 클리어
    try std.testing.expectEqual(@as(c_int, 0), c.suji_core_init());
    defer c.suji_core_destroy();
    try std.testing.expectEqualStrings("", lastErr());

    // null invoke_cb → 사유
    try std.testing.expectEqual(@as(c_int, -1), c.suji_core_register_handler("y", null, null));
    try std.testing.expect(has("null invoke_cb"));

    // 중복 init → 사유
    try std.testing.expectEqual(@as(c_int, -1), c.suji_core_init());
    try std.testing.expect(has("already initialized"));
}
