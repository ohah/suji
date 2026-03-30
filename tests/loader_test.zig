const std = @import("std");
const loader = @import("loader");

test "SujiCore struct layout" {
    // SujiCore는 C ABI extern struct
    const core = loader.SujiCore{
        .invoke = undefined,
        .free = undefined,
    };
    _ = core;
    // 컴파일 성공 = 구조체 정의 OK
}

test "BackendRegistry init and deinit" {
    var reg = loader.BackendRegistry.init(std.testing.allocator);
    defer reg.deinit();

    // 빈 레지스트리
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

    // 존재하지 않는 백엔드의 freeResponse는 무시
    reg.freeResponse("nonexistent", null);
    reg.freeResponse("nonexistent", "some data");
}

test "BackendRegistry register invalid path returns error" {
    var reg = loader.BackendRegistry.init(std.testing.allocator);
    defer reg.deinit();

    // 존재하지 않는 라이브러리 로드 시도
    const result = reg.register("test", "/nonexistent/path/libtest.dylib");
    try std.testing.expectError(error.FileNotFound, result);
}

test "BackendRegistry setGlobal" {
    var reg = loader.BackendRegistry.init(std.testing.allocator);
    defer reg.deinit();

    reg.setGlobal();
    try std.testing.expect(loader.BackendRegistry.global == &reg);

    reg.deinit();
    // deinit 후 global은 null
    reg = loader.BackendRegistry.init(std.testing.allocator);
}

test "Backend load invalid path" {
    const result = loader.Backend.load("test", "/nonexistent.dylib");
    try std.testing.expectError(error.FileNotFound, result);
}
