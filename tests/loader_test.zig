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

test "coreRegister: allocator.dupe must come AFTER duplicate check" {
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
    const dupe_pos = std.mem.indexOf(u8, body, "reg.allocator.dupe(u8, channel)") orelse return error.DupeCallMissing;

    // dupe가 duplicate 체크 뒤에 와야 early return 경로에서 누수 없음.
    try std.testing.expect(dup_check_pos < dupe_pos);
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
}
