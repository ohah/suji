const std = @import("std");
const node = @import("node");

// ============================================
// NodeRuntime 구조체 테스트 (bridge 호출 없이)
// ============================================

test "NodeRuntime init creates runtime with correct entry_path" {
    const rt = node.NodeRuntime.init(std.testing.allocator, "test/main.js");
    try std.testing.expectEqualStrings("test/main.js", rt.entry_path);
    try std.testing.expect(rt.thread == null);
    try std.testing.expect(!rt.initialized);
}

test "NodeRuntime init with different paths" {
    const rt1 = node.NodeRuntime.init(std.testing.allocator, "/abs/path/main.js");
    try std.testing.expectEqualStrings("/abs/path/main.js", rt1.entry_path);

    const rt2 = node.NodeRuntime.init(std.testing.allocator, "relative/main.js");
    try std.testing.expectEqualStrings("relative/main.js", rt2.entry_path);
}

test "NodeRuntime default state" {
    const rt = node.NodeRuntime.init(std.testing.allocator, "entry.js");
    // 초기 상태: 스레드 없음, 미초기화
    try std.testing.expect(rt.thread == null);
    try std.testing.expect(!rt.initialized);
    try std.testing.expect(rt.allocator.ptr == std.testing.allocator.ptr);
}

test "node_enabled is compile-time constant" {
    const enabled = node.node_enabled;
    // 컴파일 타임 상수 — true 또는 false
    comptime {
        _ = @as(bool, enabled);
    }
}
