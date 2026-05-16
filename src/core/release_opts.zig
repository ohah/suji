//! 릴리스/서명 결정 로직 — std-only(런타임/플랫폼 의존 0)이라 단위
//! 테스트 + 전 OS 컴파일 가능. SigningMode 단일 출처(bundle_macos.zig
//! 와 main.zig 비-macOS 스텁이 각자 중복 정의하던 것 통합).
const std = @import("std");

/// 코드 서명 모드 (zero-native `--signing` 패리티).
pub const SigningMode = enum { none, adhoc, identity };

/// 문자열 → SigningMode. 미인식/null 은 adhoc(기존 기본, 하위호환).
pub fn parseSigningMode(s: ?[]const u8) SigningMode {
    const v = s orelse return .adhoc;
    if (std.mem.eql(u8, v, "none")) return .none;
    if (std.mem.eql(u8, v, "identity")) return .identity;
    return .adhoc;
}

/// `--flag=value` 또는 `--flag value` 에서 값 추출. 없으면 null.
pub fn flagValue(args: []const [:0]const u8, flag: []const u8) ?[]const u8 {
    for (args, 0..) |a, i| {
        if (std.mem.startsWith(u8, a, flag) and a.len > flag.len and a[flag.len] == '=')
            return a[flag.len + 1 ..];
        if (std.mem.eql(u8, a, flag) and i + 1 < args.len) return args[i + 1];
    }
    return null;
}

pub fn hasFlag(args: []const [:0]const u8, flag: []const u8) bool {
    for (args) |a| if (std.mem.eql(u8, a, flag)) return true;
    return false;
}
