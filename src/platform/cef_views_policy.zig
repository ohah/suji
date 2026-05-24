const std = @import("std");

pub const Platform = enum {
    macos,
    linux,
    windows,
    other,
};

pub const ChildViewPath = enum {
    child_window,
    overlay,
    unsupported,
};

pub fn defaultEnabled(platform: Platform) bool {
    return switch (platform) {
        .macos, .linux, .windows => true,
        .other => false,
    };
}

pub fn enabled(platform: Platform, env_value: ?[]const u8) bool {
    if (env_value) |value| {
        return !(std.mem.eql(u8, value, "0") or std.ascii.eqlIgnoreCase(value, "false"));
    }
    return defaultEnabled(platform);
}

pub fn childViewPath(platform: Platform, overlay_env_value: ?[]const u8) ChildViewPath {
    return switch (platform) {
        .macos => if (envTruthy(overlay_env_value)) .overlay else .child_window,
        .linux, .windows => .overlay,
        .other => .unsupported,
    };
}

fn envTruthy(env_value: ?[]const u8) bool {
    if (env_value) |value| {
        return !(std.mem.eql(u8, value, "0") or std.ascii.eqlIgnoreCase(value, "false"));
    }
    return false;
}

test "CEF Views defaults on supported desktop platforms" {
    try std.testing.expect(enabled(.macos, null));
    try std.testing.expect(enabled(.linux, null));
    try std.testing.expect(enabled(.windows, null));
    try std.testing.expect(!enabled(.other, null));
}

test "CEF Views env override disables only explicit false values" {
    try std.testing.expect(!enabled(.macos, "0"));
    try std.testing.expect(!enabled(.linux, "false"));
    try std.testing.expect(!enabled(.windows, "FALSE"));
    try std.testing.expect(enabled(.macos, "1"));
    try std.testing.expect(enabled(.linux, "true"));
}

test "WebContentsView path defaults to child window on macOS and overlay on Linux/Windows" {
    try std.testing.expectEqual(ChildViewPath.child_window, childViewPath(.macos, null));
    try std.testing.expectEqual(ChildViewPath.overlay, childViewPath(.linux, null));
    try std.testing.expectEqual(ChildViewPath.overlay, childViewPath(.windows, null));
    try std.testing.expectEqual(ChildViewPath.unsupported, childViewPath(.other, null));
}

test "macOS WebContentsView path can opt into overlay for regression probing" {
    try std.testing.expectEqual(ChildViewPath.overlay, childViewPath(.macos, "1"));
    try std.testing.expectEqual(ChildViewPath.overlay, childViewPath(.macos, "true"));
    try std.testing.expectEqual(ChildViewPath.overlay, childViewPath(.macos, ""));
    try std.testing.expectEqual(ChildViewPath.child_window, childViewPath(.macos, "0"));
    try std.testing.expectEqual(ChildViewPath.child_window, childViewPath(.macos, "FALSE"));
}
