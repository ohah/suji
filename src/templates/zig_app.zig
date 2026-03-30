const suji = @import("suji");

pub const app = suji.app()
    .command("ping", ping)
    .command("greet", greet);

fn ping(req: suji.Request) suji.Response {
    return req.ok(.{ .msg = "pong" });
}

fn greet(req: suji.Request) suji.Response {
    const name = req.string("name") orelse "world";
    return req.ok(.{ .msg = name, .greeting = "Hello from Zig!" });
}
