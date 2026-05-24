const std = @import("std");

pub const Platform = enum {
    macos,
    linux,
    windows,
    other,
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
