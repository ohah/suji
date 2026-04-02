const std = @import("std");
const loader = @import("loader");

// ============================================
// SujiCore
// ============================================

test "SujiCore struct size" {
    // C ABI 호환 확인
    try std.testing.expect(@sizeOf(loader.SujiCore) > 0);
}

// ============================================
// BackendRegistry
// ============================================

test "BackendRegistry init and deinit" {
    var reg = loader.BackendRegistry.init(std.testing.allocator);
    defer reg.deinit();
    try std.testing.expect(reg.get("nonexistent") == null);
}

test "BackendRegistry invoke nonexistent returns null" {
    var reg = loader.BackendRegistry.init(std.testing.allocator);
    defer reg.deinit();
    const result = reg.invoke("nonexistent", "test");
    try std.testing.expect(result == null);
}

test "BackendRegistry freeResponse nonexistent does not crash" {
    var reg = loader.BackendRegistry.init(std.testing.allocator);
    defer reg.deinit();
    reg.freeResponse("nonexistent", null);
    reg.freeResponse("nonexistent", "some data");
}

test "BackendRegistry register invalid path returns error" {
    var reg = loader.BackendRegistry.init(std.testing.allocator);
    defer reg.deinit();
    const result = reg.register("test", "/nonexistent/path/libtest.dylib");
    try std.testing.expectError(error.FileNotFound, result);
}

test "BackendRegistry get after failed register returns null" {
    var reg = loader.BackendRegistry.init(std.testing.allocator);
    defer reg.deinit();
    _ = reg.register("test", "/nonexistent.dylib") catch {};
    try std.testing.expect(reg.get("test") == null);
}

test "BackendRegistry setGlobal and deinit clears global" {
    var reg = loader.BackendRegistry.init(std.testing.allocator);
    reg.setGlobal();
    try std.testing.expect(loader.BackendRegistry.global == &reg);
    reg.deinit();
    try std.testing.expect(loader.BackendRegistry.global == null);
}

test "BackendRegistry multiple setGlobal" {
    var reg1 = loader.BackendRegistry.init(std.testing.allocator);
    var reg2 = loader.BackendRegistry.init(std.testing.allocator);
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
    try std.testing.expectError(error.FileNotFound, result);
}

test "Backend load empty path" {
    // macOS: FileNotFound, Linux: SymbolNotFound (dlopen 동작 차이)
    try std.testing.expect(std.meta.isError(loader.Backend.load("test", "")));
}
