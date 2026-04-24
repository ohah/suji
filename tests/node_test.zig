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
    try std.testing.expect(r.heap_slice == null);
    try std.testing.expectEqualStrings("hello", std.mem.span(r.ptr));
}

test "nullTerminateOrAlloc empty string" {
    var buf: [256]u8 = undefined;
    const result = node.NodeRuntime.nullTerminateOrAlloc("", &buf);
    try std.testing.expect(result != null);
    const r = result.?;
    try std.testing.expect(r.heap_slice == null);
    try std.testing.expectEqualStrings("", std.mem.span(r.ptr));
}

test "nullTerminateOrAlloc exact buffer size" {
    var buf: [6]u8 = undefined;
    const result = node.NodeRuntime.nullTerminateOrAlloc("hello", &buf);
    try std.testing.expect(result != null);
    const r = result.?;
    try std.testing.expect(r.heap_slice == null);
    try std.testing.expectEqualStrings("hello", std.mem.span(r.ptr));
}

test "nullTerminateOrAlloc overflow uses heap" {
    var buf: [4]u8 = undefined;
    const result = node.NodeRuntime.nullTerminateOrAlloc("hello", &buf);
    try std.testing.expect(result != null);
    const r = result.?;
    try std.testing.expect(r.heap_slice != null);
    try std.testing.expectEqualStrings("hello", std.mem.span(r.ptr));
    std.heap.page_allocator.free(r.heap_slice.?);
}

test "nullTerminateOrAlloc single byte buffer overflow" {
    var buf: [1]u8 = undefined;
    const result = node.NodeRuntime.nullTerminateOrAlloc("ab", &buf);
    try std.testing.expect(result != null);
    const r = result.?;
    try std.testing.expect(r.heap_slice != null);
    try std.testing.expectEqualStrings("ab", std.mem.span(r.ptr));
    std.heap.page_allocator.free(r.heap_slice.?);
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
    try std.testing.expect(r.heap_slice != null);
    try std.testing.expectEqualStrings(data, std.mem.span(r.ptr));
    try std.testing.expect(r.ptr[data.len] == 0);
    std.heap.page_allocator.free(r.heap_slice.?);
}

test "nullTerminateOrAlloc boundary: src.len == buf.len - 1" {
    var buf: [6]u8 = undefined;
    // "abcde" = 5 bytes, buf = 6, fits (5 < 6)
    const result = node.NodeRuntime.nullTerminateOrAlloc("abcde", &buf);
    try std.testing.expect(result != null);
    const r = result.?;
    try std.testing.expect(r.heap_slice == null);
    try std.testing.expectEqualStrings("abcde", std.mem.span(r.ptr));
}

test "nullTerminateOrAlloc boundary: src.len == buf.len" {
    var buf: [5]u8 = undefined;
    // "abcde" = 5 bytes, buf = 5, overflow (5 >= 5)
    const result = node.NodeRuntime.nullTerminateOrAlloc("abcde", &buf);
    try std.testing.expect(result != null);
    const r = result.?;
    try std.testing.expect(r.heap_slice != null);
    try std.testing.expectEqualStrings("abcde", std.mem.span(r.ptr));
    std.heap.page_allocator.free(r.heap_slice.?);
}

// ============================================
// 회귀 테스트 — startNodeBackend: setCore → start 순서
// ============================================
//
// main.js top-level에서 `suji.on(...)`, `suji.quit()`, `suji.platform()` 호출은
// bridge의 `g_core`를 거친다. `g_core`가 null인 채 start()가 main.js를 실행하면
// "core not connected" exception으로 리스너 등록 실패 → `window:all-closed` 등
// Electron 패턴이 조용히 깨진다 (commit 21d66d0 이전 regression).
//
// 이 invariant는 startNodeBackend 함수 내부 호출 순서로만 보장되므로 소스 레벨에서
// 정적 검증한다.

test "startNodeBackend: NodeRuntime.setCore precedes rt.start()" {
    // `zig build test`는 프로젝트 루트에서 실행되므로 상대경로로 접근 가능.
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/main.zig", std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(source);

    const marker = "fn startNodeBackend(";
    const fn_start = std.mem.indexOf(u8, source, marker) orelse return error.StartNodeBackendNotFound;
    // 함수 body 끝: 다음 top-level `\nfn ` 또는 파일 끝
    const search_from = fn_start + marker.len;
    const body_end = std.mem.indexOfPos(u8, source, search_from, "\nfn ") orelse source.len;
    const body = source[fn_start..body_end];

    // 주석에도 "rt.start()" 같은 문자열이 들어갈 수 있으므로, 실제 호출만
    // 매치되도록 접두사(`&g.`, `try `)를 포함해 검색.
    const setcore_pos = std.mem.indexOf(u8, body, "NodeRuntime.setCore(&g.") orelse return error.SetCoreCallMissing;
    const start_pos = std.mem.indexOf(u8, body, "try rt.start(") orelse return error.StartCallMissing;

    try std.testing.expect(setcore_pos < start_pos);
}
