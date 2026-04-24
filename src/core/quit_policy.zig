//! quit_policy — 마지막 창이 닫혔을 때 앱을 종료할지 결정.
//!
//! Electron 규칙:
//!   - macOS: false (앱 유지, dock 클릭으로 재오픈 기대)
//!   - Windows/Linux: true (앱 종료)
//! Electron `app.quitOnAllWindowsClosed`는 runtime에서 override 가능. 여기서도
//! `override`를 지원: null이면 플랫폼 기본값, bool이면 해당 값 강제.

const std = @import("std");
const platform_mod = @import("platform");

pub const Platform = platform_mod.Platform;

/// 마지막 창 닫힘 시 앱을 종료할지.
/// `override`가 null이 아니면 플랫폼 무관하게 그 값 사용.
pub fn shouldQuitOnAllClosed(platform: Platform, override: ?bool) bool {
    if (override) |v| return v;
    return switch (platform) {
        .macos => false,
        .linux, .windows, .other => true,
    };
}
