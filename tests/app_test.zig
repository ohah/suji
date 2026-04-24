const std = @import("std");
const app_mod = @import("app");

fn pingHandler(req: app_mod.Request) app_mod.Response {
    return req.ok(.{ .msg = "pong" });
}

fn greetHandler(req: app_mod.Request) app_mod.Response {
    const name = req.string("name") orelse "world";
    return req.ok(.{ .msg = name });
}

fn addHandler(req: app_mod.Request) app_mod.Response {
    const a = req.int("a") orelse 0;
    const b = req.int("b") orelse 0;
    return req.ok(.{ .result = a + b });
}

fn clickHandler(_: app_mod.Event) void {}

const test_app = app_mod.app()
    .handle("ping", pingHandler)
    .handle("greet", greetHandler)
    .handle("add", addHandler)
    .on("clicked", clickHandler);

test "App builder creates commands" {
    try std.testing.expectEqual(@as(usize, 3), test_app.handler_count);
    try std.testing.expectEqualStrings("ping", test_app.handlers[0].channel);
    try std.testing.expectEqualStrings("greet", test_app.handlers[1].channel);
    try std.testing.expectEqualStrings("add", test_app.handlers[2].channel);
}

test "App builder creates listeners" {
    try std.testing.expectEqual(@as(usize, 1), test_app.listener_count);
    try std.testing.expectEqualStrings("clicked", test_app.listeners[0].channel);
}

test "App handleIpc ping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const resp = test_app.handleIpc(arena.allocator(), "{\"cmd\":\"ping\"}");
    try std.testing.expect(resp != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "pong") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "zig") != null);
}

test "App handleIpc unknown command" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const resp = test_app.handleIpc(arena.allocator(), "{\"cmd\":\"unknown\"}");
    try std.testing.expect(resp == null);
}

test "App handleIpc greet with name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const resp = test_app.handleIpc(arena.allocator(), "{\"cmd\":\"greet\",\"name\":\"suji\"}");
    try std.testing.expect(resp != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "suji") != null);
}

test "App handleIpc add" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const resp = test_app.handleIpc(arena.allocator(), "{\"cmd\":\"add\",\"a\":10,\"b\":20}");
    try std.testing.expect(resp != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "30") != null);
}

test "Request string extraction" {
    const req = app_mod.Request{
        .raw = "{\"cmd\":\"test\",\"name\":\"suji\"}",
        .arena = std.testing.allocator,
    };
    try std.testing.expectEqualStrings("suji", req.string("name").?);
}

test "Request string missing" {
    const req = app_mod.Request{
        .raw = "{\"cmd\":\"test\"}",
        .arena = std.testing.allocator,
    };
    try std.testing.expect(req.string("name") == null);
}

test "Request int extraction" {
    const req = app_mod.Request{
        .raw = "{\"a\":42,\"b\":-10}",
        .arena = std.testing.allocator,
    };
    try std.testing.expectEqual(@as(i64, 42), req.int("a").?);
    try std.testing.expectEqual(@as(i64, -10), req.int("b").?);
}

test "Request int missing" {
    const req = app_mod.Request{
        .raw = "{\"cmd\":\"test\"}",
        .arena = std.testing.allocator,
    };
    try std.testing.expect(req.int("a") == null);
}

test "Request ok with string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const req = app_mod.Request{
        .raw = "{}",
        .arena = arena.allocator(),
    };
    const resp = req.ok(.{ .msg = "hello" });
    try std.testing.expect(std.mem.indexOf(u8, resp.data, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.data, "zig") != null);
}

test "Request ok with int" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const req = app_mod.Request{
        .raw = "{}",
        .arena = arena.allocator(),
    };
    const resp = req.ok(.{ .count = @as(i64, 42) });
    try std.testing.expect(std.mem.indexOf(u8, resp.data, "42") != null);
}

test "Request ok with bool" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const req = app_mod.Request{
        .raw = "{}",
        .arena = arena.allocator(),
    };
    const resp = req.ok(.{ .active = true });
    try std.testing.expect(std.mem.indexOf(u8, resp.data, "true") != null);
}

test "Request ok with runtime variable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const name: []const u8 = "suji";
    const count: i64 = 99;

    const req = app_mod.Request{
        .raw = "{}",
        .arena = arena.allocator(),
    };
    const resp = req.ok(.{ .channel = name, .count = count });
    try std.testing.expect(std.mem.indexOf(u8, resp.data, "suji") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.data, "99") != null);
}

test "Request err" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const req = app_mod.Request{
        .raw = "{}",
        .arena = arena.allocator(),
    };
    const resp = req.err("not found");
    try std.testing.expect(std.mem.indexOf(u8, resp.data, "not found") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.data, "error") != null);
}

// ============================================
// quit / platform API (Electron 호환)
// ============================================

test "suji.quit() is no-op when core not injected" {
    // backend_init 호출 없이 quit() 호출 — silent no-op이어야
    app_mod.quit();
}

test "suji.platform() returns 'unknown' when core not injected" {
    try std.testing.expectEqualStrings("unknown", app_mod.platform());
}

// core 주입 시나리오 검증용 테스트 스텁
const QuitFlag = struct {
    var called: bool = false;
    fn onQuit() callconv(.c) void {
        called = true;
    }
    fn onPlatform() callconv(.c) [*:0]const u8 {
        return "test-platform";
    }
};

test "suji.quit() calls injected core fn_ptr" {
    const ExternSujiCore = app_mod.ExternSujiCore;
    QuitFlag.called = false;
    var core = ExternSujiCore{
        .invoke_fn = null,
        .free_fn = null,
        .emit = null,
        .on_fn = null,
        .off_fn = null,
        .register_fn = null,
        .get_io = null,
        .quit_fn = &QuitFlag.onQuit,
        .platform_fn = null,
    };
    app_mod.setGlobalCore(&core);
    defer app_mod.setGlobalCore(null);

    app_mod.quit();
    try std.testing.expect(QuitFlag.called);
}

test "suji.platform() returns injected core's platform string" {
    const ExternSujiCore = app_mod.ExternSujiCore;
    var core = ExternSujiCore{
        .invoke_fn = null,
        .free_fn = null,
        .emit = null,
        .on_fn = null,
        .off_fn = null,
        .register_fn = null,
        .get_io = null,
        .quit_fn = null,
        .platform_fn = &QuitFlag.onPlatform,
    };
    app_mod.setGlobalCore(&core);
    defer app_mod.setGlobalCore(null);

    try std.testing.expectEqualStrings("test-platform", app_mod.platform());
}
