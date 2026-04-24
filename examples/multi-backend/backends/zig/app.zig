const std = @import("std");
const suji = @import("suji");

pub const my_app = suji.app()
    .handle("ping", ping)
    .handle("greet", greet)
    .handle("add", add)
    .handle("info", info)
    .handle("call_rust", callRust)
    .handle("call_go", callGo)
    .handle("collab", collab)
    .handle("chain_all", chainAll)
    .handle("emit_event", emitEvent)
    .handle("zig-stress", stressDeep)
    // Electron 패턴 (macOS는 유지, 나머지는 종료).
    .on("window:all-closed", onWindowAllClosed);

fn onWindowAllClosed(_: suji.Event) void {
    const p = suji.platform();
    std.debug.print("[Zig] window-all-closed received (platform={s})\n", .{p});
    if (!std.mem.eql(u8, p, suji.PLATFORM_MACOS)) {
        std.debug.print("[Zig] non-macOS → suji.quit()\n", .{});
        suji.quit();
    }
}

fn ping(req: suji.Request, event: suji.InvokeEvent) suji.Response {
    const v = std.c.getenv("SUJI_TRACE_IPC");
    if (v != null and v.?[0] != 0 and v.?[0] != '0') {
        std.debug.print("[zig/ping] window.id={d} raw={s}\n", .{ event.window.id, req.raw });
    }
    return req.ok(.{ .msg = "pong from zig", .window_id = event.window.id });
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
    const rust_resp = req.invoke("rust", "{\"cmd\":\"ping\"}") orelse
        return req.err("rust call failed");
    return req.okMulti(&.{
        .{ "cmd", "\"call_rust\"" },
        .{ "rust_said", rust_resp },
    });
}

// Zig → Go
fn callGo(req: suji.Request) suji.Response {
    const go_resp = req.invoke("go", "{\"cmd\":\"ping\"}") orelse
        return req.err("go call failed");
    return req.okMulti(&.{
        .{ "cmd", "\"call_go\"" },
        .{ "go_said", go_resp },
    });
}

// Zig → Rust + Go 협업
fn collab(req: suji.Request) suji.Response {
    const rust_resp = req.invoke("rust", "{\"cmd\":\"collab\",\"data\":\"zig initiated\"}") orelse "null";
    const go_resp = req.invoke("go", "{\"cmd\":\"collab\",\"data\":\"zig initiated\"}") orelse "null";
    return req.okMulti(&.{
        .{ "cmd", "\"collab\"" },
        .{ "rust_collab", rust_resp },
        .{ "go_collab", go_resp },
    });
}

// Zig → Rust → Go 체인
fn chainAll(req: suji.Request) suji.Response {
    const rust_resp = req.invoke("rust", "{\"cmd\":\"ping\"}") orelse "null";
    const go_resp = req.invoke("go", "{\"cmd\":\"ping\"}") orelse "null";
    return req.okMulti(&.{
        .{ "chain", "\"zig->rust->go\"" },
        .{ "step1_zig", "\"started\"" },
        .{ "step2_rust", rust_resp },
        .{ "step3_go", go_resp },
    });
}

fn emitEvent(req: suji.Request) suji.Response {
    suji.send("zig-event", "{\"from\":\"zig\",\"msg\":\"hello from zig backend\"}");
    return req.ok(.{ .sent = "zig-event" });
}

// ============================================
// 스트레스 테스트: 재귀 크로스 호출 체인
// ============================================
// req: {"cmd":"stress_deep","depth":N,"next":"rust|go|node|zig"}
// 다음 백엔드에 depth-1로 invoke. depth==0이면 base 반환.
// 체인 예: node -> zig -> rust -> go -> node -> ...
fn stressDeep(req: suji.Request) suji.Response {
    const depth = req.int("depth") orelse 0;
    if (depth <= 0) {
        return req.okMulti(&.{
            .{ "base", "\"zig\"" },
            .{ "remaining", "0" },
        });
    }
    // 체인: node→zig(여기)→rust
    var buf: [256]u8 = undefined;
    const next_req = std.fmt.bufPrint(&buf, "{{\"cmd\":\"rust-stress\",\"depth\":{d}}}", .{depth - 1}) catch "";
    const child = req.invoke("rust", next_req) orelse return req.err("rust invoke failed");
    return req.okMulti(&.{
        .{ "at", "\"zig\"" },
        .{ "child", child },
    });
}

comptime {
    _ = suji.exportApp(my_app);
}
