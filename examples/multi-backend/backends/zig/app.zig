const suji = @import("suji");

pub const app = suji.app()
    .command("ping", ping)
    .command("greet", greet)
    .command("info", info);

fn ping(req: suji.Request) suji.Response {
    return req.ok(.{ .msg = "pong from zig" });
}

fn greet(req: suji.Request) suji.Response {
    const name = req.string("name") orelse "world";
    return req.ok(.{ .msg = name, .greeting = "Hello from Zig!" });
}

fn info(req: suji.Request) suji.Response {
    _ = req;
    return req.ok(.{ .runtime = "zig", .type = "dlopen" });
}

comptime {
    _ = suji.exportApp(app);
}
