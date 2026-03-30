const std = @import("std");
const app_mod = @import("app");

fn pingHandler(req: app_mod.Request) app_mod.Response {
    _ = req;
    return app_mod.ok(.{ .msg = "pong" });
}

fn greetHandler(req: app_mod.Request) app_mod.Response {
    const name = req.string("name") orelse "world";
    _ = name;
    return app_mod.ok(.{ .msg = "hello" });
}

fn addHandler(req: app_mod.Request) app_mod.Response {
    const a = req.int("a") orelse 0;
    const b = req.int("b") orelse 0;
    _ = a;
    _ = b;
    return app_mod.ok(.{ .result = 30 });
}

fn clickHandler(_: app_mod.Event) void {}

const test_app = app_mod.init()
    .command("ping", pingHandler)
    .command("greet", greetHandler)
    .command("add", addHandler)
    .on("clicked", clickHandler);

test "App builder creates commands" {
    try std.testing.expectEqual(@as(usize, 3), test_app.command_count);
    try std.testing.expectEqualStrings("ping", test_app.commands[0].name);
    try std.testing.expectEqualStrings("greet", test_app.commands[1].name);
    try std.testing.expectEqualStrings("add", test_app.commands[2].name);
}

test "App builder creates listeners" {
    try std.testing.expectEqual(@as(usize, 1), test_app.listener_count);
    try std.testing.expectEqualStrings("clicked", test_app.listeners[0].event);
}

test "App handleIpc ping" {
    const resp = test_app.handleIpc("{\"cmd\":\"ping\"}");
    try std.testing.expect(resp != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "pong") != null);
}

test "App handleIpc unknown command" {
    const resp = test_app.handleIpc("{\"cmd\":\"unknown\"}");
    try std.testing.expect(resp == null);
}

test "App handleIpc greet" {
    const resp = test_app.handleIpc("{\"cmd\":\"greet\",\"name\":\"suji\"}");
    try std.testing.expect(resp != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "hello") != null);
}

test "Request string extraction" {
    const req = app_mod.Request{ .raw = "{\"cmd\":\"test\",\"name\":\"suji\"}" };
    const name = req.string("name");
    try std.testing.expect(name != null);
    try std.testing.expectEqualStrings("suji", name.?);
}

test "Request string missing" {
    const req = app_mod.Request{ .raw = "{\"cmd\":\"test\"}" };
    try std.testing.expect(req.string("name") == null);
}

test "Request int extraction" {
    const req = app_mod.Request{ .raw = "{\"a\":42,\"b\":-10}" };
    try std.testing.expectEqual(@as(i64, 42), req.int("a").?);
    try std.testing.expectEqual(@as(i64, -10), req.int("b").?);
}

test "Request int missing" {
    const req = app_mod.Request{ .raw = "{\"cmd\":\"test\"}" };
    try std.testing.expect(req.int("a") == null);
}

test "ok response format" {
    const resp = app_mod.ok(.{ .msg = "pong" });
    try std.testing.expect(std.mem.indexOf(u8, resp.data, "zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.data, "pong") != null);
}
