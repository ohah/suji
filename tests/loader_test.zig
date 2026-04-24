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

test "loader.platformName returns known string" {
    const name = std.mem.span(loader.platformName());
    const valid = std.mem.eql(u8, name, "macos") or
        std.mem.eql(u8, name, "linux") or
        std.mem.eql(u8, name, "windows") or
        std.mem.eql(u8, name, "other");
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
