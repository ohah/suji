const std = @import("std");
const loader = @import("loader");

// ============================================
// SujiCore
// ============================================

test "SujiCore struct size" {
    // C ABI 호환 확인
    try std.testing.expect(@sizeOf(loader.SujiCore) > 0);
}

test "SujiCore exposes quit + platform fn pointers" {
    // 필드 존재 확인 — 컴파일 성공이 핵심 (타입 불일치 시 빌드 실패)
    var reg = loader.BackendRegistry.init(std.testing.allocator, std.testing.io);
    defer reg.deinit();
    const api = reg.core_api;
    // 두 함수 포인터는 init 시점에 항상 non-null 값이 설정됨
    try std.testing.expect(@intFromPtr(api.quit) != 0);
    try std.testing.expect(@intFromPtr(api.platform) != 0);
}

test "loader.platformName returns macos/linux/windows" {
    const name = std.mem.span(loader.platformName());
    const p = loader.platform_names;
    const valid = std.mem.eql(u8, name, p.macos) or
        std.mem.eql(u8, name, p.linux) or
        std.mem.eql(u8, name, p.windows);
    try std.testing.expect(valid);
}

test "BackendRegistry.setQuitHandler stores injected handler" {
    const Test = struct {
        var called: bool = false;
        fn h() void {
            called = true;
        }
    };
    Test.called = false;
    var reg = loader.BackendRegistry.init(std.testing.allocator, std.testing.io);
    defer reg.deinit();
    reg.setQuitHandler(&Test.h);
    // 직접 coreQuit 호출은 pub이 아니라 간접 검증: api.quit()
    reg.core_api.quit();
    try std.testing.expect(Test.called);
}

// ============================================
// BackendRegistry
// ============================================

test "BackendRegistry init and deinit" {
    var reg = loader.BackendRegistry.init(std.testing.allocator, std.testing.io);
    defer reg.deinit();
    try std.testing.expect(reg.get("nonexistent") == null);
}

test "BackendRegistry invoke nonexistent returns null" {
    var reg = loader.BackendRegistry.init(std.testing.allocator, std.testing.io);
    defer reg.deinit();
    const result = reg.invoke("nonexistent", "test");
    try std.testing.expect(result == null);
}

test "BackendRegistry freeResponse nonexistent does not crash" {
    var reg = loader.BackendRegistry.init(std.testing.allocator, std.testing.io);
    defer reg.deinit();
    reg.freeResponse("nonexistent", null);
    reg.freeResponse("nonexistent", "some data");
}

test "BackendRegistry register invalid path returns error" {
    var reg = loader.BackendRegistry.init(std.testing.allocator, std.testing.io);
    defer reg.deinit();
    const result = reg.register("test", "/nonexistent/path/libtest.dylib");
    // POSIX: FileNotFound, Windows: DynlibUnsupportedOnWindows (0.16 std.DynLib 미지원).
    try std.testing.expect(std.meta.isError(result));
}

test "BackendRegistry get after failed register returns null" {
    var reg = loader.BackendRegistry.init(std.testing.allocator, std.testing.io);
    defer reg.deinit();
    _ = reg.register("test", "/nonexistent.dylib") catch {};
    try std.testing.expect(reg.get("test") == null);
}

test "BackendRegistry setGlobal and deinit clears global" {
    var reg = loader.BackendRegistry.init(std.testing.allocator, std.testing.io);
    reg.setGlobal();
    try std.testing.expect(loader.BackendRegistry.global == &reg);
    reg.deinit();
    try std.testing.expect(loader.BackendRegistry.global == null);
}

test "BackendRegistry multiple setGlobal" {
    var reg1 = loader.BackendRegistry.init(std.testing.allocator, std.testing.io);
    var reg2 = loader.BackendRegistry.init(std.testing.allocator, std.testing.io);
    defer reg2.deinit();

    reg1.setGlobal();
    try std.testing.expect(loader.BackendRegistry.global == &reg1);

    reg2.setGlobal();
    try std.testing.expect(loader.BackendRegistry.global == &reg2);

    reg1.deinit();
    // reg1.deinit이 global을 null로 안 바꿔야 (reg2가 global이니까)
    // 현재 구현은 deinit에서 global=null 하므로 이건 알려진 동작
}

// ============================================
// Backend
// ============================================

test "Backend load invalid path" {
    const result = loader.Backend.load("test", "/nonexistent.dylib");
    // POSIX: FileNotFound, Windows: DynlibUnsupportedOnWindows.
    try std.testing.expect(std.meta.isError(result));
}

test "Backend load empty path" {
    // macOS: FileNotFound, Linux: SymbolNotFound (dlopen 동작 차이)
    try std.testing.expect(std.meta.isError(loader.Backend.load("test", "")));
}

// ============================================
// SujiCore.get_io (Zig plugin io 공유)
// ============================================

test "SujiCore.get_io function pointer is non-null" {
    var reg = loader.BackendRegistry.init(std.testing.allocator, std.testing.io);
    defer reg.deinit();
    // core_api는 init에서 채워지므로 get_io가 반드시 설정돼 있어야 함.
    _ = reg.core_api.get_io; // 컴파일만 되면 OK (non-nullable 함수 포인터)
}

test "SujiCore.get_io returns null when global unset" {
    // 테스트 간 격리를 위해 global 초기화
    loader.BackendRegistry.global = null;
    var reg = loader.BackendRegistry.init(std.testing.allocator, std.testing.io);
    defer reg.deinit();
    // setGlobal 호출 전에는 null 반환
    try std.testing.expect(reg.core_api.get_io() == null);
}

test "SujiCore.get_io returns BackendRegistry.global.io address" {
    loader.BackendRegistry.global = null;
    var reg = loader.BackendRegistry.init(std.testing.allocator, std.testing.io);
    reg.setGlobal();
    defer reg.deinit();

    const raw = reg.core_api.get_io() orelse return error.NullIo;
    // 반환된 포인터가 global.io 주소와 일치해야 함
    const expected: *const anyopaque = @ptrCast(&reg.io);
    try std.testing.expectEqual(expected, raw);
}

test "SujiCore.get_io returned pointer can be dereferenced as std.Io" {
    loader.BackendRegistry.global = null;
    var reg = loader.BackendRegistry.init(std.testing.allocator, std.testing.io);
    reg.setGlobal();
    defer reg.deinit();

    const raw = reg.core_api.get_io() orelse return error.NullIo;
    const io_ptr: *const std.Io = @ptrCast(@alignCast(raw));
    // vtable 포인터가 std.testing.io의 것과 동일해야 함
    try std.testing.expectEqual(std.testing.io.vtable, io_ptr.vtable);
    try std.testing.expectEqual(std.testing.io.userdata, io_ptr.userdata);
}

test "SujiCore.get_io tracks most recent setGlobal" {
    loader.BackendRegistry.global = null;
    var reg1 = loader.BackendRegistry.init(std.testing.allocator, std.testing.io);
    var reg2 = loader.BackendRegistry.init(std.testing.allocator, std.testing.io);
    defer reg1.deinit();
    defer reg2.deinit();

    reg1.setGlobal();
    const raw1 = reg1.core_api.get_io().?;
    try std.testing.expectEqual(@as(*const anyopaque, @ptrCast(&reg1.io)), raw1);

    // global을 reg2로 교체 → 어느 쪽의 core_api.get_io를 호출해도 reg2.io 반환
    // (get_io는 BackendRegistry.global을 참조하지 self가 아님)
    reg2.setGlobal();
    const raw_from_reg1 = reg1.core_api.get_io().?;
    const raw_from_reg2 = reg2.core_api.get_io().?;
    try std.testing.expectEqual(@as(*const anyopaque, @ptrCast(&reg2.io)), raw_from_reg1);
    try std.testing.expectEqual(@as(*const anyopaque, @ptrCast(&reg2.io)), raw_from_reg2);
}

// ============================================
// 회귀 테스트 — coreRegister duplicate 채널 시 owned_channel 누수 방지
// ============================================
//
// 이전 구조: dupe → 중복 체크 → 중복이면 early return (owned_channel 해제 안 됨).
// 매 duplicate 채널마다 채널 이름 크기만큼 누수 발생 → multi-backend 예제에서만
// 수십 바이트씩 GPA leak 리포트가 쌓였다.
// 수정: 중복 체크 → 통과 시에만 dupe + put. put 실패 시도 free.

test "coreRegister: putRoute (dupe+put) must come AFTER duplicate check" {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/backends/loader.zig",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(source);

    const marker = "fn coreRegister(";
    const fn_start = std.mem.indexOf(u8, source, marker) orelse return error.CoreRegisterNotFound;
    const body_end = std.mem.indexOfPos(u8, source, fn_start + marker.len, "\n    fn ") orelse
        std.mem.indexOfPos(u8, source, fn_start + marker.len, "\nfn ") orelse
        source.len;
    const body = source[fn_start..body_end];

    const dup_check_pos = std.mem.indexOf(u8, body, "reg.routes.getPtr(") orelse return error.DuplicateCheckMissing;
    const put_pos = std.mem.indexOf(u8, body, "reg.putRoute(") orelse return error.PutRouteCallMissing;

    // putRoute가 duplicate 체크 뒤에 와야 early return 경로에서 누수 없음.
    try std.testing.expect(dup_check_pos < put_pos);
}

// putRoute 자체가 dupe → put 하는지 정적 검증.
test "putRoute: dupe key into HashMap ownership" {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/backends/loader.zig",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(source);

    const marker = "pub fn putRoute(";
    const fn_start = std.mem.indexOf(u8, source, marker) orelse return error.PutRouteNotFound;
    const body_end = std.mem.indexOfPos(u8, source, fn_start + marker.len, "\n    pub fn ") orelse
        std.mem.indexOfPos(u8, source, fn_start + marker.len, "\n    fn ") orelse
        source.len;
    const body = source[fn_start..body_end];

    if (std.mem.indexOf(u8, body, "allocator.dupe(u8,") == null) return error.DupeMissing;
    if (std.mem.indexOf(u8, body, "errdefer self.allocator.free") == null) return error.ErrdeferMissing;
    if (std.mem.indexOf(u8, body, "self.routes.put(owned") == null) return error.PutMissing;
}

// BackendRegistry.deinit은 routes/embed_runtimes의 duped 키를 모두 free해야 한다.
test "BackendRegistry.deinit: frees HashMap keys (routes + embed_runtimes)" {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/backends/loader.zig",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(source);

    const marker = "pub fn deinit(self: *BackendRegistry)";
    const fn_start = std.mem.indexOf(u8, source, marker) orelse return error.DeinitNotFound;
    const body_end = std.mem.indexOfPos(u8, source, fn_start + marker.len, "\n    pub fn ") orelse
        std.mem.indexOfPos(u8, source, fn_start + marker.len, "\n    fn ") orelse
        source.len;
    const body = source[fn_start..body_end];

    // routes 키 순회 free
    if (std.mem.indexOf(u8, body, "self.routes.iterator()") == null) return error.RoutesIterMissing;
    // embed_runtimes 키 순회 free
    if (std.mem.indexOf(u8, body, "embed_runtimes.iterator()") == null) return error.EmbedRuntimesIterMissing;
    // 실제 free 호출
    var free_count: usize = 0;
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, body, search_from, "self.allocator.free(entry.key_ptr.*)")) |pos| {
        free_count += 1;
        search_from = pos + 1;
    }
    try std.testing.expect(free_count >= 2);
}

// ============================================
// 회귀 테스트 — watcher onFileChanged: 자동 생성/OS 메타 파일 무시
// ============================================
//
// npm install이 package-lock.json을 갱신 → watcher 재발화 → 무한 rebuild loop.
// shouldIgnore 리스트에 최소 package-lock.json이 포함되어 있어야 한다.

test "onFileChanged: shouldIgnore covers npm/os-metadata feedback files" {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/main.zig",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(source);

    const must_contain = [_][]const u8{
        "\"package-lock.json\"",
        "\"yarn.lock\"",
        "\"pnpm-lock.yaml\"",
        "\".DS_Store\"",
        // 빌드 산출물 prefix (Go cgo가 생성 → watcher 재발화 → 재빌드 loop 방지)
        "\"libbackend.\"",
        "\"_cgo_\"",
    };
    for (must_contain) |needle| {
        if (std.mem.indexOf(u8, source, needle) == null) return error.IgnoreEntryMissing;
    }

    // onFileChanged에서 shouldIgnore가 실제 호출되는지
    const marker = "fn onFileChanged(";
    const fn_start = std.mem.indexOf(u8, source, marker) orelse return error.OnFileChangedNotFound;
    const body_end = std.mem.indexOfPos(u8, source, fn_start + marker.len, "\n    fn ") orelse
        std.mem.indexOfPos(u8, source, fn_start + marker.len, "\nfn ") orelse
        source.len;
    const body = source[fn_start..body_end];
    if (std.mem.indexOf(u8, body, "shouldIgnore(path)") == null) return error.ShouldIgnoreNotCalled;

    // prefix 기반 매칭(startsWith) 경로가 실제 구현되어 있는지 — 단순 eql만 있으면
    // "libbackend.dylib" 같은 파일이 걸러지지 않음.
    const marker2 = "fn shouldIgnore(";
    const fn2_start = std.mem.indexOf(u8, source, marker2) orelse return error.ShouldIgnoreFnNotFound;
    const body2_end = std.mem.indexOfPos(u8, source, fn2_start + marker2.len, "\n    fn ") orelse
        std.mem.indexOfPos(u8, source, fn2_start + marker2.len, "\nfn ") orelse
        source.len;
    const body2 = source[fn2_start..body2_end];
    if (std.mem.indexOf(u8, body2, "startsWith") == null) return error.PrefixMatchMissing;
}

// ============================================
// registerEmbedRuntime — dupe+put leak 없음 (std.testing.allocator이 검출)
// ============================================

test "registerEmbedRuntime + deinit: no leak on happy path" {
    var reg = loader.BackendRegistry.init(std.testing.allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    defer { loader.BackendRegistry.global = null; }

    const stub: loader.EmbedRuntime = .{
        .invoke = undefined,
        .free_response = undefined,
    };
    try loader.BackendRegistry.registerEmbedRuntime("node", stub);
    try loader.BackendRegistry.registerEmbedRuntime("python", stub);
    // reg.deinit이 embed_runtimes 키("node","python") 모두 free 해야 leak 없음.
}

// ============================================
// clearRoutesFor + deinit — value가 ""로 덮인 채 deinit되어도 key는 free
// ============================================

test "BackendRegistry.deinit: frees keys even after clearRoutesFor marks values empty" {
    var reg = loader.BackendRegistry.init(std.testing.allocator, std.testing.io);
    defer reg.deinit();

    try reg.putRoute("ping", "zig");
    try reg.putRoute("greet", "zig");
    try reg.putRoute("other", "rust");

    reg.clearRoutesFor("zig"); // ping, greet 값 "" 마킹
    // 키 ("ping", "greet")는 여전히 HashMap에 남아있음 → deinit에서 iter + free 되어야 함.
}

// ============================================
// 회귀 테스트 — coreInvoke special channel routing (Phase 4-A)
//
// Backend SDK가 callBackend("__core__"|"__fanout__"|"__chain__", ...)로 호출 시
// BackendRegistry.special_dispatch가 set돼 있으면 그쪽으로 위임. set 안 됐으면
// 빈 `{}` 반환 (graceful fallback). 이전 회귀: special channel 분기 없어서
// backend SDK의 windows.* 가 모두 빈 응답 받던 버그 (commit a0d00d1).
// ============================================

const SpecialDispatchSpy = struct {
    var call_count: usize = 0;
    var last_channel: [64]u8 = undefined;
    var last_channel_len: usize = 0;
    var last_data: [256]u8 = undefined;
    var last_data_len: usize = 0;
    /// dispatch가 응답을 채워줄 슬라이스. null이면 dispatch도 null 반환 (caller가 `{}` 처리).
    var stub_response: ?[]const u8 = null;

    fn dispatch(channel: []const u8, data: []const u8, response_buf: []u8) ?[]const u8 {
        call_count += 1;
        last_channel_len = @min(channel.len, last_channel.len);
        @memcpy(last_channel[0..last_channel_len], channel[0..last_channel_len]);
        last_data_len = @min(data.len, last_data.len);
        @memcpy(last_data[0..last_data_len], data[0..last_data_len]);
        const body = stub_response orelse return null;
        const n = @min(body.len, response_buf.len);
        @memcpy(response_buf[0..n], body[0..n]);
        return response_buf[0..n];
    }

    fn reset() void {
        call_count = 0;
        last_channel_len = 0;
        last_data_len = 0;
        stub_response = null;
    }

    fn lastChannel() []const u8 {
        return last_channel[0..last_channel_len];
    }
    fn lastData() []const u8 {
        return last_data[0..last_data_len];
    }
};

/// invoke C ABI 호출 + 응답 span 반환. caller는 끝나면 freeInvokeResp 호출해야 leak 없음.
/// "{}" 같은 static string은 free no-op이라 caller가 분기 안 해도 OK.
fn invokeAsCString(reg_api: loader.SujiCore, backend: [:0]const u8, request: [:0]const u8) ?[]const u8 {
    const resp_ptr = reg_api.invoke(@ptrCast(backend.ptr), @ptrCast(request.ptr));
    if (resp_ptr == null) return null;
    const span = std.mem.span(@as([*:0]const u8, @ptrCast(resp_ptr)));
    if (span.len == 0) return null;
    return span;
}

fn freeInvokeResp(reg_api: loader.SujiCore, resp: ?[]const u8) void {
    const r = resp orelse return;
    reg_api.free(@ptrCast(r.ptr));
}

test "special_dispatch null이면 __core__ 호출은 빈 {} 반환 (회귀: a0d00d1 이전 동작 보장)" {
    SpecialDispatchSpy.reset();
    var reg = loader.BackendRegistry.init(std.testing.allocator, std.testing.io);
    reg.setGlobal();
    defer reg.deinit();
    loader.BackendRegistry.special_dispatch = null;

    const resp = invokeAsCString(reg.core_api, "__core__", "{\"cmd\":\"is_loading\",\"windowId\":1}");
    try std.testing.expectEqualStrings("{}", resp.?);
    try std.testing.expectEqual(@as(usize, 0), SpecialDispatchSpy.call_count);
}

test "special_dispatch가 set되면 __core__ 호출 → dispatcher가 channel/data 받고 응답 반환" {
    SpecialDispatchSpy.reset();
    SpecialDispatchSpy.stub_response = "{\"from\":\"zig-core\",\"cmd\":\"is_loading\",\"loading\":false}";
    var reg = loader.BackendRegistry.init(std.testing.allocator, std.testing.io);
    reg.setGlobal();
    defer reg.deinit();
    loader.BackendRegistry.special_dispatch = SpecialDispatchSpy.dispatch;
    defer loader.BackendRegistry.special_dispatch = null;

    const resp = invokeAsCString(reg.core_api, "__core__", "{\"cmd\":\"is_loading\",\"windowId\":1}").?;
    defer freeInvokeResp(reg.core_api, resp);
    try std.testing.expectEqual(@as(usize, 1), SpecialDispatchSpy.call_count);
    try std.testing.expectEqualStrings("__core__", SpecialDispatchSpy.lastChannel());
    try std.testing.expectEqualStrings("{\"cmd\":\"is_loading\",\"windowId\":1}", SpecialDispatchSpy.lastData());
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"loading\":false") != null);
}

test "special_dispatch가 null 반환하면 caller에게 {} 반환 (graceful)" {
    SpecialDispatchSpy.reset();
    SpecialDispatchSpy.stub_response = null; // dispatch가 null 반환
    var reg = loader.BackendRegistry.init(std.testing.allocator, std.testing.io);
    reg.setGlobal();
    defer reg.deinit();
    loader.BackendRegistry.special_dispatch = SpecialDispatchSpy.dispatch;
    defer loader.BackendRegistry.special_dispatch = null;

    const resp = invokeAsCString(reg.core_api, "__core__", "{}");
    try std.testing.expectEqualStrings("{}", resp.?);
    try std.testing.expectEqual(@as(usize, 1), SpecialDispatchSpy.call_count);
}

test "special_dispatch는 __fanout__ / __chain__ channel도 dispatch" {
    SpecialDispatchSpy.reset();
    SpecialDispatchSpy.stub_response = "{\"ok\":true}";
    var reg = loader.BackendRegistry.init(std.testing.allocator, std.testing.io);
    reg.setGlobal();
    defer reg.deinit();
    loader.BackendRegistry.special_dispatch = SpecialDispatchSpy.dispatch;
    defer loader.BackendRegistry.special_dispatch = null;

    const r1 = invokeAsCString(reg.core_api, "__fanout__", "{}");
    defer freeInvokeResp(reg.core_api, r1);
    try std.testing.expectEqualStrings("__fanout__", SpecialDispatchSpy.lastChannel());

    const r2 = invokeAsCString(reg.core_api, "__chain__", "{}");
    defer freeInvokeResp(reg.core_api, r2);
    try std.testing.expectEqualStrings("__chain__", SpecialDispatchSpy.lastChannel());

    try std.testing.expectEqual(@as(usize, 2), SpecialDispatchSpy.call_count);
}

// ============================================
// 회귀 테스트 — main.zig가 두 init 경로(dev/prod) 모두에서 special_dispatch
// inject. 한 곳 누락되면 해당 모드의 backend SDK windows.* 가 silent 동작 안 함
// (사용자가 dev에선 OK, prod에선 안 되는 식의 이상한 회귀).
// 컴파일된 수치 동작이 아니라 소스 정적 패턴 검증 — 누락이 즉시 드러남.
// ============================================

test "main.zig: special_dispatch inject가 dev + prod 두 init에 모두 있어야" {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/main.zig",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(source);

    // setGlobal()이 두 곳(dev/prod fn) — 각각 직후에 special_dispatch = backendSpecialDispatch가 와야.
    var inject_count: usize = 0;
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, source, search_from, "BackendRegistry.special_dispatch = backendSpecialDispatch")) |pos| {
        inject_count += 1;
        search_from = pos + 1;
    }
    try std.testing.expect(inject_count >= 2);

    // 그리고 backendSpecialDispatch 함수 본문은 SPECIAL_DISPATCHERS 테이블 순회.
    try std.testing.expect(std.mem.indexOf(u8, source, "for (SPECIAL_DISPATCHERS)") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "fn backendSpecialDispatch(") != null);
}

test "non-special channel은 dispatcher를 거치지 않음 (회귀 방지)" {
    // dispatcher가 set돼 있어도 일반 backend 이름은 dlopen registry로만 가야 함.
    SpecialDispatchSpy.reset();
    SpecialDispatchSpy.stub_response = "{\"should\":\"not be returned\"}";
    var reg = loader.BackendRegistry.init(std.testing.allocator, std.testing.io);
    reg.setGlobal();
    defer reg.deinit();
    loader.BackendRegistry.special_dispatch = SpecialDispatchSpy.dispatch;
    defer loader.BackendRegistry.special_dispatch = null;

    // "zig"는 등록 안 된 일반 backend → dlopen registry empty + embed_runtimes empty → `{}`.
    const resp = invokeAsCString(reg.core_api, "zig", "{\"cmd\":\"ping\"}");
    try std.testing.expectEqualStrings("{}", resp.?);
    try std.testing.expectEqual(@as(usize, 0), SpecialDispatchSpy.call_count);
}
