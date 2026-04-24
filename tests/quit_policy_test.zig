//! quit_policy 테스트 — 플랫폼별 quit 결정 + override 검증.

const std = @import("std");
const qp = @import("quit_policy");

test "macOS default: do not quit on all-closed" {
    try std.testing.expect(!qp.shouldQuitOnAllClosed(.macos, null));
}

test "Linux default: quit on all-closed" {
    try std.testing.expect(qp.shouldQuitOnAllClosed(.linux, null));
}

test "Windows default: quit on all-closed" {
    try std.testing.expect(qp.shouldQuitOnAllClosed(.windows, null));
}

test "other platform default: quit (conservative)" {
    try std.testing.expect(qp.shouldQuitOnAllClosed(.other, null));
}

test "override=true quits regardless of platform" {
    try std.testing.expect(qp.shouldQuitOnAllClosed(.macos, true));
    try std.testing.expect(qp.shouldQuitOnAllClosed(.linux, true));
    try std.testing.expect(qp.shouldQuitOnAllClosed(.windows, true));
}

test "override=false stays alive regardless of platform" {
    try std.testing.expect(!qp.shouldQuitOnAllClosed(.macos, false));
    try std.testing.expect(!qp.shouldQuitOnAllClosed(.linux, false));
    try std.testing.expect(!qp.shouldQuitOnAllClosed(.windows, false));
}

test "Platform.current() returns a valid variant for build target" {
    // 컴파일된 타겟에 대해 panic 없이 enum 반환
    const p = qp.Platform.current();
    _ = p;
}
