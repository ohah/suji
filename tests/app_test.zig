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

/// 2-arity 핸들러 — InvokeEvent의 window.id를 응답에 반영.
fn whoamiHandler(req: app_mod.Request, event: app_mod.InvokeEvent) app_mod.Response {
    return req.ok(.{ .window_id = event.window.id });
}

/// 2-arity 핸들러 — window.name (optional)도 반영.
fn whoamiNamedHandler(req: app_mod.Request, event: app_mod.InvokeEvent) app_mod.Response {
    return req.ok(.{
        .window_id = event.window.id,
        .window_name = event.window.name orelse "",
    });
}

fn clickHandler(_: app_mod.Event) void {}

const test_app = app_mod.app()
    .handle("ping", pingHandler)
    .handle("greet", greetHandler)
    .handle("add", addHandler)
    .handle("whoami", whoamiHandler)
    .handle("whoami_named", whoamiNamedHandler)
    .on("clicked", clickHandler);

test "App builder creates commands" {
    try std.testing.expectEqual(@as(usize, 5), test_app.handler_count);
    try std.testing.expectEqualStrings("ping", test_app.handlers[0].channel);
    try std.testing.expectEqualStrings("greet", test_app.handlers[1].channel);
    try std.testing.expectEqualStrings("add", test_app.handlers[2].channel);
    try std.testing.expectEqualStrings("whoami", test_app.handlers[3].channel);
    try std.testing.expectEqualStrings("whoami_named", test_app.handlers[4].channel);
}

test "App builder creates listeners" {
    try std.testing.expectEqual(@as(usize, 1), test_app.listener_count);
    try std.testing.expectEqualStrings("clicked", test_app.listeners[0].channel);
}

// ============================================
// App.named() — ready/bye 로그 prefix 구분
// ============================================

// App 빌더는 comptime self 계약이라 comptime 컨텍스트(모듈 스코프 또는 comptime block)에서만
// 체인 가능. 테스트용 샘플은 모듈 스코프로 고정.
const default_app = app_mod.app();
const named_app = app_mod.app().named("state");
const chained_app = app_mod.app()
    .named("my-plugin")
    .handle("ping", pingHandler)
    .on("clicked", clickHandler);

// Phase 2.5 — 1-arity / 2-arity 혼합 등록 검증용 (module scope — comptime chain 필수)
const mixed_arity_app = app_mod.app()
    .handle("w1", whoamiHandler)
    .handle("w2", whoamiHandler)
    .handle("p", pingHandler);

test "App.name defaults to \"Zig\"" {
    try std.testing.expectEqualStrings("Zig", default_app.name);
}

test "App.named sets custom name" {
    try std.testing.expectEqualStrings("state", named_app.name);
}

test "App.named preserves builder chain (handlers/listeners)" {
    try std.testing.expectEqualStrings("my-plugin", chained_app.name);
    try std.testing.expectEqual(@as(usize, 1), chained_app.handler_count);
    try std.testing.expectEqual(@as(usize, 1), chained_app.listener_count);
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

// ============================================
// Phase 2.5 — InvokeEvent (2-arity handler)
// ============================================

test "handleIpc passes __window field to 2-arity handler via InvokeEvent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const resp = test_app.handleIpc(
        arena.allocator(),
        "{\"cmd\":\"whoami\",\"__window\":42}",
    );
    try std.testing.expect(resp != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "\"window_id\":42") != null);
}

test "handleIpc: __window 없으면 InvokeEvent.window.id = 0" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const resp = test_app.handleIpc(arena.allocator(), "{\"cmd\":\"whoami\"}");
    try std.testing.expect(resp != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "\"window_id\":0") != null);
}

test "handleIpc: 기존 1-arity 핸들러는 그대로 동작 (호환성)" {
    // ping은 1-arity 핸들러. __window 붙은 request가 들어와도 wrapper가 event 무시.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const resp = test_app.handleIpc(arena.allocator(), "{\"cmd\":\"ping\",\"__window\":7}");
    try std.testing.expect(resp != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "pong") != null);
}

test "InvokeEvent type has window.id: u32" {
    const e = app_mod.InvokeEvent{ .window = .{ .id = 123 } };
    try std.testing.expectEqual(@as(u32, 123), e.window.id);
}

test "handleIpc: 음수 __window는 0으로 clamp (방어적 처리)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // 악의적/실수로 음수가 들어와도 u32 overflow 없이 0으로 처리
    const resp = test_app.handleIpc(arena.allocator(), "{\"cmd\":\"whoami\",\"__window\":-5}");
    try std.testing.expect(resp != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "\"window_id\":0") != null);
}

test "handleIpc: malformed __window (문자열)도 0 default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const resp = test_app.handleIpc(
        arena.allocator(),
        "{\"cmd\":\"whoami\",\"__window\":\"abc\"}",
    );
    try std.testing.expect(resp != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "\"window_id\":0") != null);
}

test "handleIpc: 큰 windowId도 손실 없이 전달" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // u32 max = 4294967295
    const resp = test_app.handleIpc(
        arena.allocator(),
        "{\"cmd\":\"whoami\",\"__window\":4294967295}",
    );
    try std.testing.expect(resp != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "\"window_id\":4294967295") != null);
}

test "1-arity wrapper가 내부 fn의 return을 그대로 전달 (comptime adapter 검증)" {
    // whoami(2-arity)가 직접 호출됐을 때와 handlers[i].func(wrapper)로 호출했을 때
    // 응답 bytes가 동일해야 1-arity wrapper가 투명하게 동작한다는 증거.
    var arena1 = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena1.deinit();
    var arena2 = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena2.deinit();

    // ping은 1-arity → wrapper가 감싼 후 저장됨. 직접 호출했을 때와 결과 비교.
    const direct = pingHandler(.{ .raw = "{\"cmd\":\"ping\"}", .arena = arena1.allocator() });
    // handlers[0].func는 wrapper
    const via_wrapper = test_app.handlers[0].func(
        .{ .raw = "{\"cmd\":\"ping\"}", .arena = arena2.allocator() },
        .{ .window = .{ .id = 0 } },
    );
    try std.testing.expectEqualStrings(direct.data, via_wrapper.data);
}

test "1-arity wrapper는 event 값과 무관 (여러 window.id로 호출해도 동일 응답)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const req: app_mod.Request = .{ .raw = "{\"cmd\":\"ping\"}", .arena = arena.allocator() };
    const r0 = test_app.handlers[0].func(req, .{ .window = .{ .id = 0 } });
    const r1 = test_app.handlers[0].func(req, .{ .window = .{ .id = 1 } });
    const r999 = test_app.handlers[0].func(req, .{ .window = .{ .id = 999 } });
    try std.testing.expectEqualStrings(r0.data, r1.data);
    try std.testing.expectEqualStrings(r1.data, r999.data);
}

test "handleIpc: cmd 필드 없는 JSON → null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expect(test_app.handleIpc(arena.allocator(), "{}") == null);
    try std.testing.expect(test_app.handleIpc(arena.allocator(), "{\"foo\":\"bar\"}") == null);
}

test "handleIpc: malformed JSON (닫는 brace 없음)도 안전하게 null 반환" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // extractStringField는 naive scanner라 malformed에서도 crash 없어야 함.
    try std.testing.expect(test_app.handleIpc(arena.allocator(), "garbage") == null);
    try std.testing.expect(test_app.handleIpc(arena.allocator(), "{\"cmd") == null);
}

test "2-arity 핸들러: req 데이터와 event 데이터 모두 접근 가능" {
    // whoami는 event.window.id만 사용하지만, 이 테스트는 req+event 조합이 의도대로
    // 독립 경로를 갖는지 확인 — request에 name/window 둘 다 있어도 event가 window 담당.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const resp = test_app.handleIpc(
        arena.allocator(),
        "{\"cmd\":\"whoami\",\"__window\":7,\"name\":\"ignored\"}",
    );
    try std.testing.expect(resp != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "\"window_id\":7") != null);
    // "name" 필드는 whoami가 무시 — 응답에 안 나와야
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "ignored") == null);
}

test "handle 빌더: 여러 2-arity 핸들러 혼합 등록 가능" {
    try std.testing.expectEqual(@as(usize, 3), mixed_arity_app.handler_count);
    try std.testing.expectEqualStrings("w1", mixed_arity_app.handlers[0].channel);
    try std.testing.expectEqualStrings("w2", mixed_arity_app.handlers[1].channel);
    try std.testing.expectEqualStrings("p", mixed_arity_app.handlers[2].channel);
}

test "InvokeEvent는 값 타입 (struct)이라 복사되고 호출자의 것은 불변" {
    // 타입 정보로 struct 여부만 확인 — Zig는 포인터 아니면 자동 복사.
    const info = @typeInfo(app_mod.InvokeEvent);
    try std.testing.expect(info == .@"struct");
}

test "InvokeEvent.Window 중첩 타입이 public하게 접근 가능" {
    const W = app_mod.InvokeEvent.Window;
    const w: W = .{ .id = 55 };
    try std.testing.expectEqual(@as(u32, 55), w.id);
}

// ============================================
// Phase 2.5 — __window_name 주입 + 파싱
// ============================================

test "handleIpc: __window_name이 event.window.name으로 전달" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const resp = test_app.handleIpc(
        arena.allocator(),
        "{\"cmd\":\"whoami_named\",\"__window\":3,\"__window_name\":\"settings\"}",
    );
    try std.testing.expect(resp != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "\"window_id\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "\"window_name\":\"settings\"") != null);
}

test "handleIpc: __window_name 없으면 event.window.name = null (익명 창)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const resp = test_app.handleIpc(
        arena.allocator(),
        "{\"cmd\":\"whoami_named\",\"__window\":1}",
    );
    try std.testing.expect(resp != null);
    // name이 null이면 orelse "" 경로 → 빈 문자열 응답
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "\"window_name\":\"\"") != null);
}

test "InvokeEvent.Window.name: ?[]const u8 default null" {
    const e = app_mod.InvokeEvent{ .window = .{ .id = 1 } };
    try std.testing.expect(e.window.name == null);
}

test "handleIpc: 비-문자열 __window_name (숫자)는 null로 처리" {
    // extractStringField는 `"key":"..."` 패턴만 매칭. 숫자면 null 반환 → event.window.name = null.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const resp = test_app.handleIpc(
        arena.allocator(),
        "{\"cmd\":\"whoami_named\",\"__window\":1,\"__window_name\":42}",
    );
    try std.testing.expect(resp != null);
    // orelse "" 경로로 빈 문자열 응답 (name null 확인)
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "\"window_name\":\"\"") != null);
}

test "handleIpc: 빈 문자열 __window_name은 빈 string으로 전달" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const resp = test_app.handleIpc(
        arena.allocator(),
        "{\"cmd\":\"whoami_named\",\"__window\":1,\"__window_name\":\"\"}",
    );
    try std.testing.expect(resp != null);
    // name은 "" non-null, orelse가 분기 안 타고 "" 그대로
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "\"window_name\":\"\"") != null);
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

// ============================================
// suji.sendTo — Phase 2.5 webContents.send 대응
// ============================================

test "suji.sendTo() is no-op when core not injected" {
    // core 주입 전 sendTo 호출 — crash 없이 silent return.
    app_mod.sendTo(2, "channel", "{}");
}

test "suji.sendTo() is no-op when emit_to_fn is null (구버전 core 호환)" {
    // core는 있지만 emit_to_fn이 null (예: 구버전 core가 주입됐을 때).
    // SDK가 기능을 찾지 못하면 silent — 크래시하지 않아야.
    const ExternSujiCore = app_mod.ExternSujiCore;
    var core = ExternSujiCore{
        .invoke_fn = null,
        .free_fn = null,
        .emit = null,
        .on_fn = null,
        .off_fn = null,
        .register_fn = null,
        .get_io = null,
        // emit_to_fn 명시 생략 → default null
    };
    app_mod.setGlobalCore(&core);
    defer app_mod.setGlobalCore(null);

    app_mod.sendTo(2, "channel", "{}");
}

const SendToSpy = struct {
    var last_target: u32 = 0;
    var last_channel: [64]u8 = undefined;
    var last_channel_len: usize = 0;
    var last_data: [256]u8 = undefined;
    var last_data_len: usize = 0;
    var call_count: usize = 0;

    fn onEmitTo(target: u32, channel: [*c]const u8, data: [*c]const u8) callconv(.c) void {
        last_target = target;
        const ch_span = std.mem.span(@as([*:0]const u8, @ptrCast(channel)));
        last_channel_len = @min(ch_span.len, last_channel.len);
        @memcpy(last_channel[0..last_channel_len], ch_span[0..last_channel_len]);
        const d_span = std.mem.span(@as([*:0]const u8, @ptrCast(data)));
        last_data_len = @min(d_span.len, last_data.len);
        @memcpy(last_data[0..last_data_len], d_span[0..last_data_len]);
        call_count += 1;
    }
};

// ============================================
// Phase 4-A — windows.* SDK가 callBackend("__core__", ...)로 cmd JSON 전송
// ============================================

const InvokeSpy = struct {
    var call_count: usize = 0;
    var last_backend: [256]u8 = undefined;
    var last_backend_len: usize = 0;
    var last_request: [4096]u8 = undefined;
    var last_request_len: usize = 0;
    /// invoke_fn은 응답 포인터를 반환해야 함 (null이면 windows.* null 반환).
    var stub_response: [256:0]u8 = undefined;
    var stub_response_len: usize = 0;

    fn onInvoke(backend: [*c]const u8, request: [*c]const u8) callconv(.c) [*c]const u8 {
        call_count += 1;
        const b_span = std.mem.span(@as([*:0]const u8, @ptrCast(backend)));
        last_backend_len = @min(b_span.len, last_backend.len);
        @memcpy(last_backend[0..last_backend_len], b_span[0..last_backend_len]);
        const r_span = std.mem.span(@as([*:0]const u8, @ptrCast(request)));
        last_request_len = @min(r_span.len, last_request.len);
        @memcpy(last_request[0..last_request_len], r_span[0..last_request_len]);
        if (stub_response_len == 0) return null;
        return @ptrCast(&stub_response);
    }

    fn reset() void {
        call_count = 0;
        last_backend_len = 0;
        last_request_len = 0;
        stub_response_len = 0;
        stub_response[0] = 0;
    }

    fn setStub(body: []const u8) void {
        const n = @min(body.len, stub_response.len - 1);
        @memcpy(stub_response[0..n], body[0..n]);
        stub_response[n] = 0;
        stub_response_len = n;
    }

    fn lastBackend() []const u8 {
        return last_backend[0..last_backend_len];
    }
    fn lastRequest() []const u8 {
        return last_request[0..last_request_len];
    }
};

fn withInvokeCore(body: anytype) !void {
    InvokeSpy.reset();
    InvokeSpy.setStub("{\"ok\":true}");
    var core = app_mod.ExternSujiCore{
        .invoke_fn = &InvokeSpy.onInvoke,
        .free_fn = null,
        .emit = null,
        .on_fn = null,
        .off_fn = null,
        .register_fn = null,
        .get_io = null,
        .emit_to_fn = null,
    };
    app_mod.setGlobalCore(&core);
    defer app_mod.setGlobalCore(null);
    try body();
}

test "windows.loadURL: __core__ + load_url + windowId/url 전송" {
    try withInvokeCore(struct {
        fn run() !void {
            _ = app_mod.windows.loadURL(7, "http://example.com/");
            try std.testing.expectEqual(@as(usize, 1), InvokeSpy.call_count);
            try std.testing.expectEqualStrings("__core__", InvokeSpy.lastBackend());
            const r = InvokeSpy.lastRequest();
            try std.testing.expect(std.mem.indexOf(u8, r, "\"cmd\":\"load_url\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, r, "\"windowId\":7") != null);
            try std.testing.expect(std.mem.indexOf(u8, r, "\"url\":\"http://example.com/\"") != null);
        }
    }.run);
}

test "windows.reload: ignoreCache 플래그가 JSON에 그대로" {
    try withInvokeCore(struct {
        fn run() !void {
            _ = app_mod.windows.reload(3, true);
            const r = InvokeSpy.lastRequest();
            try std.testing.expect(std.mem.indexOf(u8, r, "\"cmd\":\"reload\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, r, "\"windowId\":3") != null);
            try std.testing.expect(std.mem.indexOf(u8, r, "\"ignoreCache\":true") != null);
        }
    }.run);
}

test "windows.executeJavaScript: code의 \" \\ control char escape" {
    try withInvokeCore(struct {
        fn run() !void {
            _ = app_mod.windows.executeJavaScript(1, "alert(\"hi\\n\");");
            const r = InvokeSpy.lastRequest();
            try std.testing.expect(std.mem.indexOf(u8, r, "\"cmd\":\"execute_javascript\"") != null);
            // raw `\n` 컨트롤 문자는 drop, `"`/`\` 는 escape.
            try std.testing.expect(std.mem.indexOf(u8, r, "alert(\\\"hi\\\\n\\\");") != null);
        }
    }.run);
}

test "windows.setTitle / setBounds 필드" {
    try withInvokeCore(struct {
        fn run() !void {
            _ = app_mod.windows.setTitle(2, "New Title");
            const t_req = InvokeSpy.lastRequest();
            try std.testing.expect(std.mem.indexOf(u8, t_req, "\"cmd\":\"set_title\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, t_req, "\"title\":\"New Title\"") != null);

            _ = app_mod.windows.setBounds(2, .{ .x = 10, .y = 20, .width = 800, .height = 600 });
            const b_req = InvokeSpy.lastRequest();
            try std.testing.expect(std.mem.indexOf(u8, b_req, "\"cmd\":\"set_bounds\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, b_req, "\"x\":10,\"y\":20,\"width\":800,\"height\":600") != null);
        }
    }.run);
}

test "windows.getURL / isLoading: windowId만 들어감" {
    try withInvokeCore(struct {
        fn run() !void {
            _ = app_mod.windows.getURL(5);
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"cmd\":\"get_url\",\"windowId\":5") != null);
            _ = app_mod.windows.isLoading(5);
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"cmd\":\"is_loading\",\"windowId\":5") != null);
        }
    }.run);
}

test "windows.create / createSimple: cmd + opts" {
    try withInvokeCore(struct {
        fn run() !void {
            _ = app_mod.windows.create("\"title\":\"X\",\"frame\":false");
            const r1 = InvokeSpy.lastRequest();
            try std.testing.expect(std.mem.indexOf(u8, r1, "\"cmd\":\"create_window\",\"title\":\"X\",\"frame\":false") != null);

            _ = app_mod.windows.createSimple("Win", "http://x/");
            const r2 = InvokeSpy.lastRequest();
            try std.testing.expect(std.mem.indexOf(u8, r2, "\"cmd\":\"create_window\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, r2, "\"title\":\"Win\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, r2, "\"url\":\"http://x/\"") != null);
        }
    }.run);
}

test "windows.setTitle: title의 \" 이스케이프" {
    try withInvokeCore(struct {
        fn run() !void {
            _ = app_mod.windows.setTitle(1, "a\"b");
            const r = InvokeSpy.lastRequest();
            try std.testing.expect(std.mem.indexOf(u8, r, "\"title\":\"a\\\"b\"") != null);
        }
    }.run);
}

// Phase 4-B: 줌 — set은 windowId+level/factor, get은 windowId.
test "windows.setZoomLevel / setZoomFactor / getZoomLevel / getZoomFactor" {
    try withInvokeCore(struct {
        fn run() !void {
            _ = app_mod.windows.setZoomLevel(2, 1.5);
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"cmd\":\"set_zoom_level\",\"windowId\":2,\"level\":1.5") != null);

            _ = app_mod.windows.setZoomFactor(2, 1.2);
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"cmd\":\"set_zoom_factor\",\"windowId\":2,\"factor\":1.2") != null);

            _ = app_mod.windows.getZoomLevel(2);
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"cmd\":\"get_zoom_level\",\"windowId\":2") != null);

            _ = app_mod.windows.getZoomFactor(2);
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"cmd\":\"get_zoom_factor\",\"windowId\":2") != null);

            try std.testing.expectEqual(@as(usize, 4), InvokeSpy.call_count);
        }
    }.run);
}

// Phase 4-E: 편집 6 + find/stop_find.
test "windows.undo/redo/cut/copy/paste/selectAll: cmd JSON 형식" {
    try withInvokeCore(struct {
        fn run() !void {
            inline for (.{
                .{ app_mod.windows.undo, "undo" },
                .{ app_mod.windows.redo, "redo" },
                .{ app_mod.windows.cut, "cut" },
                .{ app_mod.windows.copy, "copy" },
                .{ app_mod.windows.paste, "paste" },
                .{ app_mod.windows.selectAll, "select_all" },
            }) |entry| {
                _ = entry[0](7);
                try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"cmd\":\"" ++ entry[1] ++ "\",\"windowId\":7") != null);
            }
            try std.testing.expectEqual(@as(usize, 6), InvokeSpy.call_count);
        }
    }.run);
}

test "windows.printToPDF: cmd JSON + path escape" {
    try withInvokeCore(struct {
        fn run() !void {
            _ = app_mod.windows.printToPDF(2, "/tmp/out.pdf");
            const r = InvokeSpy.lastRequest();
            try std.testing.expect(std.mem.indexOf(u8, r, "\"cmd\":\"print_to_pdf\",\"windowId\":2,\"path\":\"/tmp/out.pdf\"") != null);

            // path에 " 들어가도 escape
            _ = app_mod.windows.printToPDF(2, "/tmp/has\"quote.pdf");
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\\\"quote") != null);
        }
    }.run);
}

test "windows.findInPage / stopFindInPage: 옵션 + escape" {
    try withInvokeCore(struct {
        fn run() !void {
            _ = app_mod.windows.findInPage(2, "needle", .{ .forward = false, .match_case = true, .find_next = true });
            const r = InvokeSpy.lastRequest();
            try std.testing.expect(std.mem.indexOf(u8, r, "\"cmd\":\"find_in_page\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, r, "\"text\":\"needle\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, r, "\"forward\":false") != null);
            try std.testing.expect(std.mem.indexOf(u8, r, "\"matchCase\":true") != null);
            try std.testing.expect(std.mem.indexOf(u8, r, "\"findNext\":true") != null);

            // escape edge — text에 " 들어가도 깨짐 없음
            _ = app_mod.windows.findInPage(2, "a\"b", .{});
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"text\":\"a\\\"b\"") != null);

            _ = app_mod.windows.stopFindInPage(2, true);
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"clearSelection\":true") != null);
        }
    }.run);
}

// Phase 4-C: DevTools — windowId만 들어가는 단순 cmd 4종.
test "windows.openDevTools / closeDevTools / isDevToolsOpened / toggleDevTools" {
    try withInvokeCore(struct {
        fn run() !void {
            _ = app_mod.windows.openDevTools(3);
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"cmd\":\"open_dev_tools\",\"windowId\":3") != null);

            _ = app_mod.windows.closeDevTools(3);
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"cmd\":\"close_dev_tools\",\"windowId\":3") != null);

            _ = app_mod.windows.isDevToolsOpened(3);
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"cmd\":\"is_dev_tools_opened\",\"windowId\":3") != null);

            _ = app_mod.windows.toggleDevTools(3);
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"cmd\":\"toggle_dev_tools\",\"windowId\":3") != null);

            try std.testing.expectEqual(@as(usize, 4), InvokeSpy.call_count);
        }
    }.run);
}

test "suji.sendTo() forwards target id + channel + data to emit_to_fn" {
    SendToSpy.call_count = 0;
    const ExternSujiCore = app_mod.ExternSujiCore;
    var core = ExternSujiCore{
        .invoke_fn = null,
        .free_fn = null,
        .emit = null,
        .on_fn = null,
        .off_fn = null,
        .register_fn = null,
        .get_io = null,
        .emit_to_fn = &SendToSpy.onEmitTo,
    };
    app_mod.setGlobalCore(&core);
    defer app_mod.setGlobalCore(null);

    app_mod.sendTo(7, "toast", "{\"msg\":\"hi\"}");

    try std.testing.expectEqual(@as(usize, 1), SendToSpy.call_count);
    try std.testing.expectEqual(@as(u32, 7), SendToSpy.last_target);
    try std.testing.expectEqualStrings("toast", SendToSpy.last_channel[0..SendToSpy.last_channel_len]);
    try std.testing.expectEqualStrings("{\"msg\":\"hi\"}", SendToSpy.last_data[0..SendToSpy.last_data_len]);
}

// ============================================
// Phase 5-A/5-B Backend SDK 단위 — Zig SDK가 올바른 cmd JSON을 emit하는지
// ============================================

test "clipboard.readText: __core__ + clipboard_read_text 전송" {
    try withInvokeCore(struct {
        fn run() !void {
            _ = app_mod.clipboard.readText();
            try std.testing.expectEqual(@as(usize, 1), InvokeSpy.call_count);
            try std.testing.expectEqualStrings("__core__", InvokeSpy.lastBackend());
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"cmd\":\"clipboard_read_text\"") != null);
        }
    }.run);
}

test "clipboard.writeText: text 필드 + escape 적용" {
    try withInvokeCore(struct {
        fn run() !void {
            _ = app_mod.clipboard.writeText("hi\nworld");
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"cmd\":\"clipboard_write_text\"") != null);
            // \n이 escape sequence로 보존돼야 (escapeJsonStrFull).
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "hi\\nworld") != null);
        }
    }.run);
}

test "clipboard.clear: 인자 없는 cmd" {
    try withInvokeCore(struct {
        fn run() !void {
            _ = app_mod.clipboard.clear();
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"cmd\":\"clipboard_clear\"") != null);
        }
    }.run);
}

test "shell.openExternal: url 필드 전송" {
    try withInvokeCore(struct {
        fn run() !void {
            _ = app_mod.shell.openExternal("https://example.com");
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"cmd\":\"shell_open_external\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"url\":\"https://example.com\"") != null);
        }
    }.run);
}

test "shell.showItemInFolder: path 필드 + 백슬래시 escape" {
    try withInvokeCore(struct {
        fn run() !void {
            _ = app_mod.shell.showItemInFolder("/tmp/file with spaces.txt");
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"cmd\":\"shell_show_item_in_folder\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "file with spaces") != null);
        }
    }.run);
}

test "shell.beep: 인자 없는 cmd" {
    try withInvokeCore(struct {
        fn run() !void {
            _ = app_mod.shell.beep();
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"cmd\":\"shell_beep\"") != null);
        }
    }.run);
}

test "dialog.showErrorBox: title + content 둘 다 필수 필드" {
    try withInvokeCore(struct {
        fn run() !void {
            _ = app_mod.dialog.showErrorBox("Error", "Something failed");
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"cmd\":\"dialog_show_error_box\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"title\":\"Error\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"content\":\"Something failed\"") != null);
        }
    }.run);
}

test "dialog.messageBoxSimple: type/message + buttons 배열 빌드" {
    try withInvokeCore(struct {
        fn run() !void {
            _ = app_mod.dialog.messageBoxSimple("info", "Q?", &.{ "Yes", "No" });
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"cmd\":\"dialog_show_message_box\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"type\":\"info\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"message\":\"Q?\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"buttons\":[\"Yes\",\"No\"]") != null);
        }
    }.run);
}

test "tray.create: title + tooltip 필드 전송" {
    try withInvokeCore(struct {
        fn run() !void {
            _ = app_mod.tray.create("🚀 App", "tooltip");
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"cmd\":\"tray_create\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"title\":\"🚀 App\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"tooltip\":\"tooltip\"") != null);
        }
    }.run);
}

test "tray.setTitle: trayId + title 전송" {
    try withInvokeCore(struct {
        fn run() !void {
            _ = app_mod.tray.setTitle(42, "New Title");
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"cmd\":\"tray_set_title\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"trayId\":42") != null);
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"title\":\"New Title\"") != null);
        }
    }.run);
}

test "tray.setMenuRaw + tray.destroy: trayId 전송" {
    try withInvokeCore(struct {
        fn run() !void {
            _ = app_mod.tray.setMenuRaw(7, "\"items\":[]");
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"cmd\":\"tray_set_menu\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"trayId\":7") != null);
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"items\":[]") != null);

            _ = app_mod.tray.destroy(7);
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"cmd\":\"tray_destroy\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"trayId\":7") != null);
        }
    }.run);
}

test "menu.setApplicationMenuRaw + resetApplicationMenu: cmd 전송" {
    try withInvokeCore(struct {
        fn run() !void {
            _ = app_mod.menu.setApplicationMenuRaw("\"items\":[{\"type\":\"submenu\",\"label\":\"Tools\",\"submenu\":[{\"label\":\"Run\",\"click\":\"run\"},{\"type\":\"checkbox\",\"label\":\"Flag\",\"click\":\"flag\",\"checked\":true},{\"type\":\"separator\"}]}]");
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"cmd\":\"menu_set_application_menu\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"label\":\"Tools\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"type\":\"checkbox\"") != null);

            _ = app_mod.menu.resetApplicationMenu();
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"cmd\":\"menu_reset_application_menu\"") != null);
        }
    }.run);
}

test "fs.*: __core__ 파일 시스템 cmd 전송" {
    try withInvokeCore(struct {
        fn run() !void {
            _ = app_mod.fs.readFile("/tmp/suji.txt");
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"cmd\":\"fs_read_file\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"path\":\"/tmp/suji.txt\"") != null);

            _ = app_mod.fs.writeFile("/tmp/suji.txt", "hello\nworld");
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"cmd\":\"fs_write_file\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"text\":\"hello\\nworld\"") != null);

            _ = app_mod.fs.stat("/tmp/suji.txt");
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"cmd\":\"fs_stat\"") != null);

            _ = app_mod.fs.mkdir("/tmp/suji-dir", true);
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"cmd\":\"fs_mkdir\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"recursive\":true") != null);

            _ = app_mod.fs.readdir("/tmp");
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"cmd\":\"fs_readdir\"") != null);

            _ = app_mod.fs.rm("/tmp/suji.txt", true, false);
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"cmd\":\"fs_rm\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"recursive\":true") != null);
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"force\":false") != null);
        }
    }.run);
}

test "globalShortcut.*: __core__ Carbon Hot Key cmd 전송" {
    try withInvokeCore(struct {
        fn run() !void {
            _ = app_mod.globalShortcut.register("Cmd+Shift+K", "openSettings");
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"cmd\":\"global_shortcut_register\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"accelerator\":\"Cmd+Shift+K\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"click\":\"openSettings\"") != null);

            _ = app_mod.globalShortcut.unregister("Cmd+Shift+K");
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"cmd\":\"global_shortcut_unregister\"") != null);

            _ = app_mod.globalShortcut.unregisterAll();
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"cmd\":\"global_shortcut_unregister_all\"") != null);

            _ = app_mod.globalShortcut.isRegistered("Cmd+Q");
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"cmd\":\"global_shortcut_is_registered\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"accelerator\":\"Cmd+Q\"") != null);
        }
    }.run);
}

test "notification.isSupported: __core__ + notification_is_supported 전송" {
    try withInvokeCore(struct {
        fn run() !void {
            _ = app_mod.notification.isSupported();
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"cmd\":\"notification_is_supported\"") != null);
        }
    }.run);
}

test "notification.requestPermission: cmd 전송" {
    try withInvokeCore(struct {
        fn run() !void {
            _ = app_mod.notification.requestPermission();
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"cmd\":\"notification_request_permission\"") != null);
        }
    }.run);
}

test "notification.show: title/body/silent 필드 전송" {
    try withInvokeCore(struct {
        fn run() !void {
            _ = app_mod.notification.show("Hello", "World", false);
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"cmd\":\"notification_show\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"title\":\"Hello\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"body\":\"World\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"silent\":false") != null);
        }
    }.run);
}

test "notification.show: silent=true + escape 적용 (newline 보존)" {
    try withInvokeCore(struct {
        fn run() !void {
            _ = app_mod.notification.show("Title", "Line 1\nLine 2", true);
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"silent\":true") != null);
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "Line 1\\nLine 2") != null);
        }
    }.run);
}

test "notification.close: notificationId 전송" {
    try withInvokeCore(struct {
        fn run() !void {
            _ = app_mod.notification.close("suji-notif-42");
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"cmd\":\"notification_close\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, InvokeSpy.lastRequest(), "\"notificationId\":\"suji-notif-42\"") != null);
        }
    }.run);
}
