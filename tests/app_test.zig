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
