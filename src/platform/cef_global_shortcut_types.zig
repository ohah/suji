//! Shared Global Shortcut API types.

pub const GLOBAL_SHORTCUT_STR_MAX: usize = 128;

pub const GlobalShortcutStatus = enum(i32) {
    ok = 0,
    capacity = -1,
    duplicate = -2,
    parse = -3,
    os_reject = -4,
    too_long = -5,
    timed_out = -6, // Windows pump 스레드 5초 timeout (TrackPopupMenu 모달 등)
};
