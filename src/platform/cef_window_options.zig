const std = @import("std");

/// CEF Views maps both Electron-style `frame:false` and transparent windows to
/// frameless native top-level windows. Transparent top-level windows cannot use
/// standard titlebar controls.
pub fn viewsFrameless(frame: bool, transparent: bool) bool {
    return !frame or transparent;
}

pub fn viewsStandardButtons(frame: bool, transparent: bool) bool {
    return frame and !transparent;
}

pub fn viewsCanResize(resizable: bool) bool {
    return resizable;
}

test "frame false maps to CEF Views frameless window" {
    try std.testing.expect(viewsFrameless(false, false));
    try std.testing.expect(!viewsStandardButtons(false, false));
}

test "transparent windows are frameless and hide standard buttons" {
    try std.testing.expect(viewsFrameless(true, true));
    try std.testing.expect(!viewsStandardButtons(true, true));
}

test "framed opaque windows keep standard buttons" {
    try std.testing.expect(!viewsFrameless(true, false));
    try std.testing.expect(viewsStandardButtons(true, false));
}

test "resize policy preserves caller constraint" {
    try std.testing.expect(viewsCanResize(true));
    try std.testing.expect(!viewsCanResize(false));
}
