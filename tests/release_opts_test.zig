//! core/release_opts.zig 단위 테스트 — 서명모드 결정/플래그 파싱.
//! zig build test 로 ci.yml 3-OS 에서 실행(릴리스 서명 로직 CI 커버리지).
const std = @import("std");
const ro = @import("release_opts");

test "parseSigningMode: 인식/기본값" {
    try std.testing.expectEqual(ro.SigningMode.none, ro.parseSigningMode("none"));
    try std.testing.expectEqual(ro.SigningMode.identity, ro.parseSigningMode("identity"));
    try std.testing.expectEqual(ro.SigningMode.adhoc, ro.parseSigningMode("adhoc"));
    // 미인식/null → adhoc(하위호환 기본)
    try std.testing.expectEqual(ro.SigningMode.adhoc, ro.parseSigningMode("bogus"));
    try std.testing.expectEqual(ro.SigningMode.adhoc, ro.parseSigningMode(null));
    try std.testing.expectEqual(ro.SigningMode.adhoc, ro.parseSigningMode(""));
}

test "flagValue: --flag=value / --flag value / 부재" {
    const a = [_][:0]const u8{ "build", "--sign=identity", "--identity", "Dev ID", "--dmg" };
    try std.testing.expectEqualStrings("identity", ro.flagValue(&a, "--sign").?);
    try std.testing.expectEqualStrings("Dev ID", ro.flagValue(&a, "--identity").?);
    try std.testing.expect(ro.flagValue(&a, "--notarize") == null);
    try std.testing.expect(ro.flagValue(&a, "--sign") != null);
}

test "flagValue: --flag 가 마지막이고 값 없음 → null" {
    const a = [_][:0]const u8{ "build", "--identity" };
    try std.testing.expect(ro.flagValue(&a, "--identity") == null);
}

test "flagValue: prefix 충돌 회피(--sign vs --signfoo)" {
    const a = [_][:0]const u8{ "--signfoo=x", "--sign=y" };
    try std.testing.expectEqualStrings("y", ro.flagValue(&a, "--sign").?);
}

test "hasFlag" {
    const a = [_][:0]const u8{ "build", "--notarize", "--dmg", "--deb" };
    try std.testing.expect(ro.hasFlag(&a, "--notarize"));
    try std.testing.expect(ro.hasFlag(&a, "--dmg"));
    try std.testing.expect(ro.hasFlag(&a, "--deb"));
    try std.testing.expect(!ro.hasFlag(&a, "--sign"));
    try std.testing.expect(!ro.hasFlag(&a, "--dm"));
}
