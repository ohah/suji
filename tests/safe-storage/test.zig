const std = @import("std");
const sso = @import("safe_storage_os");

// 비-macOS safeStorage 라운드트립 (Linux secret-tool / Windows DPAPI).
test "safeStorage set/get/delete round-trip" {
    const svc = "suji-ci-test";
    const acc = "round-trip";
    const val = "sécret-Ünïçødé-値-🔐";

    try std.testing.expect(sso.set(svc, acc, val));

    var buf: [256]u8 = undefined;
    const got = sso.get(svc, acc, &buf);
    try std.testing.expectEqualStrings(val, got);

    try std.testing.expect(sso.delete(svc, acc));

    // 삭제 후 조회 → 빈 결과.
    var buf2: [256]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), sso.get(svc, acc, &buf2).len);
}
