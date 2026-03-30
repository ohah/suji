const suji = @import("suji");

pub const my_app = suji.app()
    .command("ping", ping)
    .command("greet", greet)
    .command("add", add)
    .command("info", info)
    .command("call_rust", callRust)
    .command("call_go", callGo)
    .command("collab", collab)
    .command("chain_all", chainAll);

fn ping(req: suji.Request) suji.Response {
    return req.ok(.{ .msg = "pong from zig" });
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

fn info(req: suji.Request) suji.Response {
    return req.ok(.{ .runtime = "zig", .loaded_via = "dlopen" });
}

// Zig → Rust
fn callRust(req: suji.Request) suji.Response {
    const rust_resp = req.call("rust", "{\"cmd\":\"ping\"}") orelse
        return req.err("rust call failed");
    return req.okMulti(&.{
        .{ "cmd", "\"call_rust\"" },
        .{ "rust_said", rust_resp },
    });
}

// Zig → Go
fn callGo(req: suji.Request) suji.Response {
    const go_resp = req.call("go", "{\"cmd\":\"ping\"}") orelse
        return req.err("go call failed");
    return req.okMulti(&.{
        .{ "cmd", "\"call_go\"" },
        .{ "go_said", go_resp },
    });
}

// Zig → Rust + Go 협업
fn collab(req: suji.Request) suji.Response {
    const rust_resp = req.call("rust", "{\"cmd\":\"collab\",\"data\":\"zig initiated\"}") orelse "null";
    const go_resp = req.call("go", "{\"cmd\":\"collab\",\"data\":\"zig initiated\"}") orelse "null";
    return req.okMulti(&.{
        .{ "cmd", "\"collab\"" },
        .{ "rust_collab", rust_resp },
        .{ "go_collab", go_resp },
    });
}

// Zig → Rust → Go 체인
fn chainAll(req: suji.Request) suji.Response {
    const rust_resp = req.call("rust", "{\"cmd\":\"ping\"}") orelse "null";
    const go_resp = req.call("go", "{\"cmd\":\"ping\"}") orelse "null";
    return req.okMulti(&.{
        .{ "chain", "\"zig->rust->go\"" },
        .{ "step1_zig", "\"started\"" },
        .{ "step2_rust", rust_resp },
        .{ "step3_go", go_resp },
    });
}

comptime {
    _ = suji.exportApp(my_app);
}
