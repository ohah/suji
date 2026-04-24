//! 공용 Platform 감지 — `@import("builtin").os.tag`를 runtime/테스트 친화적으로 래핑.
//!
//! 두 가지 사용처:
//!   1. 런타임 분기: `platform.current()` → `.macos` | `.linux` | ... 로 switch
//!   2. 테스트: Platform을 인자로 받는 순수 함수(예: `quit_policy.shouldQuitOnAllClosed`)
//!      → 각 플랫폼 경로를 테스트에서 강제로 주입 가능
//!
//! 단순 switch만 필요한 곳(예: 문자열 리터럴 `"macos-arm64"` 매칭)은 `builtin` 직접
//! 사용이 더 자연스러워서 이 모듈을 거치지 않아도 된다.

const builtin = @import("builtin");

pub const Platform = enum {
    macos,
    linux,
    windows,
    other,

    /// 빌드 타겟의 현재 플랫폼.
    pub fn current() Platform {
        return switch (builtin.os.tag) {
            .macos => .macos,
            .linux => .linux,
            .windows => .windows,
            else => .other,
        };
    }
};
