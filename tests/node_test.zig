const std = @import("std");
const node = @import("node");

// ============================================
// NodeRuntime 구조체 테스트
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
    try std.testing.expect(rt.thread == null);
    try std.testing.expect(!rt.initialized);
    try std.testing.expect(rt.allocator.ptr == std.testing.allocator.ptr);
}

test "NodeRuntime init with empty path" {
    const rt = node.NodeRuntime.init(std.testing.allocator, "");
    try std.testing.expectEqualStrings("", rt.entry_path);
    try std.testing.expect(!rt.initialized);
}

test "NodeRuntime init with special characters in path" {
    const rt = node.NodeRuntime.init(std.testing.allocator, "/Users/O'Brien/app/main.js");
    try std.testing.expectEqualStrings("/Users/O'Brien/app/main.js", rt.entry_path);
}

test "NodeRuntime init preserves allocator" {
    const alloc = std.testing.allocator;
    const rt = node.NodeRuntime.init(alloc, "test.js");
    try std.testing.expect(rt.allocator.ptr == alloc.ptr);
}

// ============================================
// node_enabled 컴파일 타임 상수
// ============================================

test "node_enabled is compile-time constant" {
    const enabled = node.node_enabled;
    comptime {
        _ = @as(bool, enabled);
    }
}

// ============================================
// nullTerminateOrAlloc 테스트
// ============================================

test "nullTerminateOrAlloc fits in stack buffer" {
    var buf: [256]u8 = undefined;
    const result = node.NodeRuntime.nullTerminateOrAlloc("hello", &buf);
    try std.testing.expect(result != null);
    const r = result.?;
    try std.testing.expect(!r.allocated);
    try std.testing.expectEqualStrings("hello", std.mem.span(r.ptr));
}

test "nullTerminateOrAlloc empty string" {
    var buf: [256]u8 = undefined;
    const result = node.NodeRuntime.nullTerminateOrAlloc("", &buf);
    try std.testing.expect(result != null);
    const r = result.?;
    try std.testing.expect(!r.allocated);
    try std.testing.expectEqualStrings("", std.mem.span(r.ptr));
}

test "nullTerminateOrAlloc exact buffer size" {
    var buf: [6]u8 = undefined;
    const result = node.NodeRuntime.nullTerminateOrAlloc("hello", &buf);
    try std.testing.expect(result != null);
    const r = result.?;
    try std.testing.expect(!r.allocated);
    try std.testing.expectEqualStrings("hello", std.mem.span(r.ptr));
}

test "nullTerminateOrAlloc overflow uses heap" {
    var buf: [4]u8 = undefined;
    const result = node.NodeRuntime.nullTerminateOrAlloc("hello", &buf);
    try std.testing.expect(result != null);
    const r = result.?;
    try std.testing.expect(r.allocated);
    try std.testing.expectEqualStrings("hello", std.mem.span(r.ptr));
    std.heap.page_allocator.free(r.ptr[0 .. 5 + 1]);
}

test "nullTerminateOrAlloc single byte buffer overflow" {
    var buf: [1]u8 = undefined;
    const result = node.NodeRuntime.nullTerminateOrAlloc("ab", &buf);
    try std.testing.expect(result != null);
    const r = result.?;
    try std.testing.expect(r.allocated);
    try std.testing.expectEqualStrings("ab", std.mem.span(r.ptr));
    std.heap.page_allocator.free(r.ptr[0 .. 2 + 1]);
}

test "nullTerminateOrAlloc preserves null terminator" {
    var buf: [256]u8 = undefined;
    const data = "test data with spaces";
    const result = node.NodeRuntime.nullTerminateOrAlloc(data, &buf);
    try std.testing.expect(result != null);
    const r = result.?;
    try std.testing.expect(r.ptr[data.len] == 0);
}

test "nullTerminateOrAlloc large data heap allocation" {
    var buf: [8]u8 = undefined;
    const data = "this is a longer string that exceeds the buffer size";
    const result = node.NodeRuntime.nullTerminateOrAlloc(data, &buf);
    try std.testing.expect(result != null);
    const r = result.?;
    try std.testing.expect(r.allocated);
    try std.testing.expectEqualStrings(data, std.mem.span(r.ptr));
    try std.testing.expect(r.ptr[data.len] == 0);
    std.heap.page_allocator.free(r.ptr[0 .. data.len + 1]);
}

test "nullTerminateOrAlloc boundary: src.len == buf.len - 1" {
    var buf: [6]u8 = undefined;
    // "abcde" = 5 bytes, buf = 6, fits (5 < 6)
    const result = node.NodeRuntime.nullTerminateOrAlloc("abcde", &buf);
    try std.testing.expect(result != null);
    const r = result.?;
    try std.testing.expect(!r.allocated);
    try std.testing.expectEqualStrings("abcde", std.mem.span(r.ptr));
}

test "nullTerminateOrAlloc boundary: src.len == buf.len" {
    var buf: [5]u8 = undefined;
    // "abcde" = 5 bytes, buf = 5, overflow (5 >= 5)
    const result = node.NodeRuntime.nullTerminateOrAlloc("abcde", &buf);
    try std.testing.expect(result != null);
    const r = result.?;
    try std.testing.expect(r.allocated);
    try std.testing.expectEqualStrings("abcde", std.mem.span(r.ptr));
    std.heap.page_allocator.free(r.ptr[0 .. 5 + 1]);
}
