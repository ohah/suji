const suji = @import("suji");

pub const app = suji.app()
    .handle("ping", ping)
    .handle("greet", greet)
    .handle("add", add);

fn ping(req: suji.Request) suji.Response {
    return req.ok(.{ .msg = "pong" });
}

fn greet(req: suji.Request) suji.Response {
    const name = req.string("name") orelse "world";
    return req.ok(.{ .msg = name, .greeting = "Hello from Zig!" });
}

fn add(req: suji.Request) suji.Response {
    const a = req.int("a") orelse 0;
    const b = req.int("b") orelse 0;
    return req.ok(.{ .result = a + b });
}

comptime {
    _ = suji.exportApp(app);
}
