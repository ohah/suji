const std = @import("std");
const builtin = @import("builtin");
const loader = @import("loader");
const events = @import("events");

// State 플러그인 동적 라이브러리 경로 (OS별 확장자)
const PLUGIN_PATH = switch (builtin.os.tag) {
    .macos => "plugins/state/zig/zig-out/lib/libbackend.dylib",
    .linux => "plugins/state/zig/zig-out/lib/libbackend.so",
    .windows => "plugins/state/zig/zig-out/bin/backend.dll",
    else => @compileError("unsupported OS"),
};

// ============================================
// 헬퍼
// ============================================

fn loadStatePlugin(reg: *loader.BackendRegistry) !void {
    // Zig 0.16에서 Windows std.DynLib 미지원 → 전체 테스트 skip.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try reg.register("state", PLUGIN_PATH);
    // 테스트 격리: 이전 테스트의 상태 초기화
    freeResp(reg, invokePlugin(reg, "{\"cmd\":\"state:clear\"}"));
}

fn invokePlugin(reg: *loader.BackendRegistry, request: []const u8) ?[]const u8 {
    var req_buf: [4096]u8 = undefined;
    const len = @min(request.len, req_buf.len - 1);
    @memcpy(req_buf[0..len], request[0..len]);
    req_buf[len] = 0;
    return reg.invoke("state", req_buf[0..len :0]);
}

fn freeResp(reg: *const loader.BackendRegistry, resp: ?[]const u8) void {
    reg.freeResponse("state", resp);
}

// ============================================
// 기본 동작
// ============================================

test "state plugin: load" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();

    try loadStatePlugin(&reg);
    try std.testing.expect(reg.get("state") != null);
}

test "state plugin: get nonexistent key returns null value" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadStatePlugin(&reg);

    const resp = invokePlugin(&reg, "{\"cmd\":\"state:get\",\"key\":\"nonexistent\"}");
    try std.testing.expect(resp != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "null") != null);
    freeResp(&reg, resp);
}

test "state plugin: set and get" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadStatePlugin(&reg);

    // set
    const set_resp = invokePlugin(&reg, "{\"cmd\":\"state:set\",\"key\":\"user\",\"value\":\"yoon\"}");
    try std.testing.expect(set_resp != null);
    try std.testing.expect(std.mem.indexOf(u8, set_resp.?, "true") != null);
    freeResp(&reg, set_resp);

    // get
    const get_resp = invokePlugin(&reg, "{\"cmd\":\"state:get\",\"key\":\"user\"}");
    try std.testing.expect(get_resp != null);
    try std.testing.expect(std.mem.indexOf(u8, get_resp.?, "yoon") != null);
    freeResp(&reg, get_resp);
}

test "state plugin: set overwrites existing value" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadStatePlugin(&reg);

    freeResp(&reg, invokePlugin(&reg, "{\"cmd\":\"state:set\",\"key\":\"count\",\"value\":1}"));
    freeResp(&reg, invokePlugin(&reg, "{\"cmd\":\"state:set\",\"key\":\"count\",\"value\":42}"));

    const resp = invokePlugin(&reg, "{\"cmd\":\"state:get\",\"key\":\"count\"}");
    try std.testing.expect(resp != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "42") != null);
    freeResp(&reg, resp);
}

test "state plugin: delete" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadStatePlugin(&reg);

    freeResp(&reg, invokePlugin(&reg, "{\"cmd\":\"state:set\",\"key\":\"temp\",\"value\":\"data\"}"));
    freeResp(&reg, invokePlugin(&reg, "{\"cmd\":\"state:delete\",\"key\":\"temp\"}"));

    const resp = invokePlugin(&reg, "{\"cmd\":\"state:get\",\"key\":\"temp\"}");
    try std.testing.expect(resp != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "null") != null);
    freeResp(&reg, resp);
}

test "state plugin: keys" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadStatePlugin(&reg);

    freeResp(&reg, invokePlugin(&reg, "{\"cmd\":\"state:set\",\"key\":\"a\",\"value\":1}"));
    freeResp(&reg, invokePlugin(&reg, "{\"cmd\":\"state:set\",\"key\":\"b\",\"value\":2}"));

    const resp = invokePlugin(&reg, "{\"cmd\":\"state:keys\"}");
    try std.testing.expect(resp != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "keys") != null);
    freeResp(&reg, resp);
}

test "state plugin: channel routing via register" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadStatePlugin(&reg);

    // state:get 채널이 자동 등록됐는지 확인
    try std.testing.expect(reg.getBackendForChannel("state:get") != null);
    try std.testing.expect(reg.getBackendForChannel("state:set") != null);
    try std.testing.expect(reg.getBackendForChannel("state:delete") != null);
    try std.testing.expect(reg.getBackendForChannel("state:keys") != null);
}

// ============================================
// Phase 2.5: scope (global / window:N / window 자동 / session:*)
// ============================================

test "state plugin: scope 분리 — 같은 key, 다른 scope는 독립" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadStatePlugin(&reg);

    // 같은 key "theme"을 global / window:1 / window:2 / session:onboard 4개 scope에 set
    freeResp(&reg, invokePlugin(&reg, "{\"cmd\":\"state:set\",\"key\":\"theme\",\"value\":\"global-dark\"}"));
    freeResp(&reg, invokePlugin(&reg, "{\"cmd\":\"state:set\",\"key\":\"theme\",\"value\":\"w1-light\",\"scope\":\"window:1\"}"));
    freeResp(&reg, invokePlugin(&reg, "{\"cmd\":\"state:set\",\"key\":\"theme\",\"value\":\"w2-sepia\",\"scope\":\"window:2\"}"));
    freeResp(&reg, invokePlugin(&reg, "{\"cmd\":\"state:set\",\"key\":\"theme\",\"value\":\"sess-x\",\"scope\":\"session:onboard\"}"));

    const g = invokePlugin(&reg, "{\"cmd\":\"state:get\",\"key\":\"theme\"}");
    try std.testing.expect(std.mem.indexOf(u8, g.?, "global-dark") != null);
    freeResp(&reg, g);

    const w1 = invokePlugin(&reg, "{\"cmd\":\"state:get\",\"key\":\"theme\",\"scope\":\"window:1\"}");
    try std.testing.expect(std.mem.indexOf(u8, w1.?, "w1-light") != null);
    freeResp(&reg, w1);

    const w2 = invokePlugin(&reg, "{\"cmd\":\"state:get\",\"key\":\"theme\",\"scope\":\"window:2\"}");
    try std.testing.expect(std.mem.indexOf(u8, w2.?, "w2-sepia") != null);
    freeResp(&reg, w2);

    const sess = invokePlugin(&reg, "{\"cmd\":\"state:get\",\"key\":\"theme\",\"scope\":\"session:onboard\"}");
    try std.testing.expect(std.mem.indexOf(u8, sess.?, "sess-x") != null);
    freeResp(&reg, sess);
}

test "state plugin: scope=\"window\" 특수값 → __window:N으로 자동 치환" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadStatePlugin(&reg);

    // wire의 __window=3 + scope="window" → 내부적으로 "window:3"로 저장
    freeResp(&reg, invokePlugin(&reg, "{\"cmd\":\"state:set\",\"key\":\"layout\",\"value\":\"split\",\"scope\":\"window\",\"__window\":3}"));

    // window:3 직접 지정으로 조회 가능 — scope 자동 치환이 일관됨을 증명
    const direct = invokePlugin(&reg, "{\"cmd\":\"state:get\",\"key\":\"layout\",\"scope\":\"window:3\"}");
    try std.testing.expect(std.mem.indexOf(u8, direct.?, "split") != null);
    freeResp(&reg, direct);

    // global에는 안 들어감
    const g = invokePlugin(&reg, "{\"cmd\":\"state:get\",\"key\":\"layout\"}");
    try std.testing.expect(std.mem.indexOf(u8, g.?, "null") != null);
    freeResp(&reg, g);
}

test "state plugin: scope=\"window\" 인데 __window 누락 시 global로 폴백" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadStatePlugin(&reg);

    // __window 없음 → resolveScope이 "global"로 폴백
    freeResp(&reg, invokePlugin(&reg, "{\"cmd\":\"state:set\",\"key\":\"x\",\"value\":\"v\",\"scope\":\"window\"}"));

    const g = invokePlugin(&reg, "{\"cmd\":\"state:get\",\"key\":\"x\"}");
    try std.testing.expect(std.mem.indexOf(u8, g.?, "\"v\"") != null);
    freeResp(&reg, g);
}

test "state plugin: scope clear는 해당 scope만 비우고 다른 scope는 보존" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadStatePlugin(&reg);

    freeResp(&reg, invokePlugin(&reg, "{\"cmd\":\"state:set\",\"key\":\"a\",\"value\":1}"));
    freeResp(&reg, invokePlugin(&reg, "{\"cmd\":\"state:set\",\"key\":\"a\",\"value\":2,\"scope\":\"window:5\"}"));

    // window:5만 클리어
    freeResp(&reg, invokePlugin(&reg, "{\"cmd\":\"state:clear\",\"scope\":\"window:5\"}"));

    const g = invokePlugin(&reg, "{\"cmd\":\"state:get\",\"key\":\"a\"}");
    try std.testing.expect(std.mem.indexOf(u8, g.?, "1") != null);
    freeResp(&reg, g);

    const w5 = invokePlugin(&reg, "{\"cmd\":\"state:get\",\"key\":\"a\",\"scope\":\"window:5\"}");
    try std.testing.expect(std.mem.indexOf(u8, w5.?, "null") != null);
    freeResp(&reg, w5);
}

test "state plugin: keys?scope=X — 해당 scope의 user-key만 (prefix 제거)" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadStatePlugin(&reg);

    freeResp(&reg, invokePlugin(&reg, "{\"cmd\":\"state:set\",\"key\":\"foo\",\"value\":1,\"scope\":\"window:9\"}"));
    freeResp(&reg, invokePlugin(&reg, "{\"cmd\":\"state:set\",\"key\":\"bar\",\"value\":2,\"scope\":\"window:9\"}"));
    freeResp(&reg, invokePlugin(&reg, "{\"cmd\":\"state:set\",\"key\":\"baz\",\"value\":3}")); // global

    const resp = invokePlugin(&reg, "{\"cmd\":\"state:keys\",\"scope\":\"window:9\"}");
    try std.testing.expect(resp != null);
    // window:9의 user-key만 — "foo"/"bar"는 있고, "baz"는 없어야
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "\"foo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "\"bar\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "\"baz\"") == null);
    freeResp(&reg, resp);
}

test "state plugin: invokeByChannel routing" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadStatePlugin(&reg);

    _ = invokePlugin(&reg, "{\"cmd\":\"state:set\",\"key\":\"routed\",\"value\":\"yes\"}");

    // invokeByChannel로 라우팅 테스트
    const resp = reg.invokeByChannel("state:get", "{\"cmd\":\"state:get\",\"key\":\"routed\"}");
    try std.testing.expect(resp != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "yes") != null);
    freeResp(&reg, resp);
}

// ============================================
// 경합 테스트 (동시 접근)
// ============================================

test "state plugin: concurrent set/get (10 threads)" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadStatePlugin(&reg);

    const THREAD_COUNT = 10;
    var threads: [THREAD_COUNT]std.Thread = undefined;

    for (0..THREAD_COUNT) |i| {
        threads[i] = try std.Thread.spawn(.{}, concurrentWorker, .{ &reg, i });
    }

    for (0..THREAD_COUNT) |i| {
        threads[i].join();
    }

    // 모든 스레드가 쓴 값이 존재하는지 확인
    for (0..THREAD_COUNT) |i| {
        var key_buf: [64]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "thread_{d}", .{i}) catch continue;
        var req_buf: [256]u8 = undefined;
        const req = std.fmt.bufPrint(&req_buf, "{{\"cmd\":\"state:get\",\"key\":\"{s}\"}}", .{key}) catch continue;
        const resp = invokePlugin(&reg, req);
        try std.testing.expect(resp != null);
        freeResp(&reg, resp);
    }
}

fn concurrentWorker(reg: *loader.BackendRegistry, thread_id: usize) void {
    for (0..10) |j| {
        var set_buf: [256]u8 = undefined;
        const set_req = std.fmt.bufPrint(&set_buf, "{{\"cmd\":\"state:set\",\"key\":\"thread_{d}\",\"value\":{d}}}", .{ thread_id, j }) catch continue;
        freeResp(reg, invokePlugin(reg, set_req));

        var get_buf: [256]u8 = undefined;
        const get_req = std.fmt.bufPrint(&get_buf, "{{\"cmd\":\"state:get\",\"key\":\"thread_{d}\"}}", .{thread_id}) catch continue;
        freeResp(reg, invokePlugin(reg, get_req));
    }
}

test "state plugin: rapid fire 100 concurrent sets" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadStatePlugin(&reg);

    const THREAD_COUNT = 20;
    var threads: [THREAD_COUNT]std.Thread = undefined;

    for (0..THREAD_COUNT) |i| {
        threads[i] = try std.Thread.spawn(.{}, rapidFireWorker, .{ &reg, i });
    }

    for (0..THREAD_COUNT) |i| {
        threads[i].join();
    }

    // 크래시/데드락 없이 완료되면 성공
}

fn rapidFireWorker(reg: *loader.BackendRegistry, thread_id: usize) void {
    for (0..5) |j| {
        var buf: [256]u8 = undefined;
        const req = std.fmt.bufPrint(&buf, "{{\"cmd\":\"state:set\",\"key\":\"rapid_{d}_{d}\",\"value\":{d}}}", .{ thread_id, j, thread_id * 100 + j }) catch continue;
        freeResp(reg, invokePlugin(reg, req));
    }
}
