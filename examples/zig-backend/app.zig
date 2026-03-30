const suji = @import("suji");

pub const app = suji.app()
    .command("ping", ping)
    .command("greet", greet)
    .command("add", add)
    .command("upper", upper);

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

fn upper(req: suji.Request) suji.Response {
    // Zig에서 대문자 변환은 런타임 버퍼 필요
    const text = req.string("text") orelse "";
    _ = text;
    return req.ok(.{ .msg = "uppercase not yet implemented" });
}
