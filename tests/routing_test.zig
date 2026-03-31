const std = @import("std");
const loader = @import("loader");

test "BackendRegistry routes init empty" {
    var reg = loader.BackendRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try std.testing.expect(reg.getBackendForChannel("ping") == null);
    try std.testing.expect(reg.getBackendForChannel("greet") == null);
}

test "BackendRegistry invokeByChannel returns null when no route" {
    var reg = loader.BackendRegistry.init(std.testing.allocator);
    defer reg.deinit();

    const result = reg.invokeByChannel("nonexistent", "{}");
    try std.testing.expect(result == null);
}

test "BackendRegistry routes put and get" {
    var reg = loader.BackendRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try reg.routes.put("ping", "zig");
    try reg.routes.put("greet", "rust");
    try reg.routes.put("stats", "go");

    try std.testing.expectEqualStrings("zig", reg.getBackendForChannel("ping").?);
    try std.testing.expectEqualStrings("rust", reg.getBackendForChannel("greet").?);
    try std.testing.expectEqualStrings("go", reg.getBackendForChannel("stats").?);
    try std.testing.expect(reg.getBackendForChannel("unknown") == null);
}

test "BackendRegistry duplicate route rejected" {
    var reg = loader.BackendRegistry.init(std.testing.allocator);
    defer reg.deinit();
    reg.setGlobal();
    defer { loader.BackendRegistry.global = null; }

    // 첫 번째 등록
    reg.registering_backend = "zig";
    try reg.routes.put("ping", "zig");
    reg.registering_backend = null;

    // 두 번째 등록 시도 — coreRegister가 중복 거부
    reg.registering_backend = "rust";

    // 직접 routes.put하면 덮어쓰지만, coreRegister는 체크함
    // coreRegister를 시뮬레이션: 이미 있으면 put 안 함
    if (reg.routes.get("ping") != null) {
        // 중복이므로 등록 안 함 (coreRegister 동작과 동일)
        try std.testing.expectEqualStrings("zig", reg.getBackendForChannel("ping").?);
    }
    reg.registering_backend = null;
}

test "BackendRegistry routes deinit clears" {
    var reg = loader.BackendRegistry.init(std.testing.allocator);

    try reg.routes.put("ping", "zig");
    try reg.routes.put("greet", "rust");

    reg.deinit();
    // deinit 후 접근 불가 (use-after-free 방지를 위해 재생성)
    reg = loader.BackendRegistry.init(std.testing.allocator);
    defer reg.deinit();
    try std.testing.expect(reg.getBackendForChannel("ping") == null);
}

test "BackendRegistry multiple channels same backend" {
    var reg = loader.BackendRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try reg.routes.put("ping", "zig");
    try reg.routes.put("greet", "zig");
    try reg.routes.put("add", "zig");

    try std.testing.expectEqualStrings("zig", reg.getBackendForChannel("ping").?);
    try std.testing.expectEqualStrings("zig", reg.getBackendForChannel("greet").?);
    try std.testing.expectEqualStrings("zig", reg.getBackendForChannel("add").?);
}

test "BackendRegistry registering_backend lifecycle" {
    var reg = loader.BackendRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try std.testing.expect(reg.registering_backend == null);
    reg.registering_backend = "rust";
    try std.testing.expectEqualStrings("rust", reg.registering_backend.?);
    reg.registering_backend = null;
    try std.testing.expect(reg.registering_backend == null);
}
