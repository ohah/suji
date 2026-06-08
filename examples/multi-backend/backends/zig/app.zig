const std = @import("std");
const suji = @import("suji");

pub const my_app = suji.app()
    .handle("ping", ping)
    .handle("greet", greet)
    .handle("add", add)
    .handle("info", info)
    .handle("call_rust", callRust)
    .handle("call_go", callGo)
    .handle("call_lua", callLua)
    .handle("collab", collab)
    .handle("chain_all", chainAll)
    .handle("emit_event", emitEvent)
    .handle("zig-stress", stressDeep)
    .handle("zig-whoami", whoami)
    .handle("zig-echo-to-sender", echoToSender)
    .handle("windows-roundtrip-zig", windowsRoundtrip)
    // Electron 패턴 (macOS는 유지, 나머지는 종료).
    .on("window:all-closed", onWindowAllClosed)
    // Electron app.on('before-quit') — quit 직전 정리 훅(in-process 동기). e2e 검증용:
    // SUJI_E2E_BQ_MARKER 환경변수가 있으면 그 경로에 마커 파일을 쓴다(미설정=no-op, 데모 무영향).
    .on("app:before-quit", onBeforeQuit);

fn onWindowAllClosed(_: suji.Event) void {
    const p = suji.platform();
    std.debug.print("[Zig] window-all-closed received (platform={s})\n", .{p});
    if (!std.mem.eql(u8, p, suji.PLATFORM_MACOS)) {
        std.debug.print("[Zig] non-macOS → suji.quit()\n", .{});
        suji.quit();
    }
}

// libc file I/O (Zig 0.16 std.fs 는 Io 인스턴스 필요 — 핸들러엔 없어 libc 직접 사용).
const libc = struct {
    extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
    extern "c" fn fputs(s: [*:0]const u8, stream: *anyopaque) c_int;
    extern "c" fn fclose(stream: *anyopaque) c_int;
};

fn onBeforeQuit(_: suji.Event) void {
    const raw = std.c.getenv("SUJI_E2E_BQ_MARKER") orelse return;
    const f = libc.fopen(raw, "w") orelse return;
    _ = libc.fputs("before-quit\n", f);
    _ = libc.fclose(f);
}

fn ping(req: suji.Request, event: suji.InvokeEvent) suji.Response {
    const v = std.c.getenv("SUJI_TRACE_IPC");
    if (v != null and v.?[0] != 0 and v.?[0] != '0') {
        std.debug.print("[zig/ping] window.id={d} name={s} raw={s}\n", .{
            event.window.id,
            event.window.name orelse "",
            req.raw,
        });
    }
    return req.ok(.{
        .msg = "pong from zig",
        .window_id = event.window.id,
        .window_name = event.window.name orelse "",
    });
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

/// Phase 4-A round-trip 검증 — sender 창의 isLoading을 Zig SDK로 호출하고
/// 응답 raw JSON을 그대로 회신. e2e가 응답에 `"is_loading"` 포함 확인.
fn windowsRoundtrip(req: suji.Request, event: suji.InvokeEvent) suji.Response {
    const id = event.window.id;
    const resp = suji.windows.isLoading(id) orelse return req.err("zig windows.isLoading null");
    return req.ok(.{ .from_backend = "zig", .window_id = id, .response_raw = resp });
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

// Zig → Lua
fn callLua(req: suji.Request) suji.Response {
    const lua_resp = req.invoke("lua", "{\"cmd\":\"lua-ping\"}") orelse
        return req.err("lua call failed");
    return req.okMulti(&.{
        .{ "cmd", "\"call_lua\"" },
        .{ "lua_said", lua_resp },
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

// Phase 2.5: 2-arity 핸들러 — sender 창 컨텍스트를 바로 응답에 담는다.
fn whoami(req: suji.Request, event: suji.InvokeEvent) suji.Response {
    // 익명 창(name=null)/URL 없음(url=null)은 빈 문자열로 내보낸다 — JSON 직렬화 편의.
    return req.ok(.{
        .window_id = event.window.id,
        .window_name = event.window.name orelse "",
        .window_url = event.window.url orelse "",
    });
}

// Phase 2.5: sendTo — sender 창에게만 이벤트 에코백.
fn echoToSender(req: suji.Request, event: suji.InvokeEvent) suji.Response {
    const text = req.string("text") orelse "hi";
    var buf: [256]u8 = undefined;
    const payload = std.fmt.bufPrint(&buf, "{{\"from\":\"zig\",\"text\":\"{s}\"}}", .{text}) catch "{}";
    // 직접 sendTo는 SDK에 없음 → core의 emit_to_fn 호출용 wrapper 필요. 이 예제는 app.sendTo만 쓴다.
    suji.sendTo(event.window.id, "zig-echo", payload);
    return req.ok(.{ .sent_to = event.window.id });
}

comptime {
    _ = suji.exportApp(my_app);
}
