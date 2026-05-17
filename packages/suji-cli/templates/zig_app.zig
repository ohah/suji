const suji = @import("suji");

pub const app = suji.app()
    .handle("ping", ping)
    .handle("greet", greet);

fn ping(req: suji.Request) suji.Response {
    return req.ok(.{ .msg = "pong" });
}

fn greet(req: suji.Request) suji.Response {
    const name = req.string("name") orelse "world";
    return req.ok(.{ .msg = name, .greeting = "Hello from Zig!" });
}

// C ABI export (suji dev에서 dlopen으로 로드)
comptime {
    _ = suji.exportApp(app);
}
