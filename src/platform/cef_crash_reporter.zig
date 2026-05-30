//! crashReporter CEF bridge — cef.zig 에서 분리(동작 무변경).
//! Crashpad/Breakpad runtime state + crash key setter.
const std = @import("std");
const cef = @import("cef.zig");

const c = cef.c;
const setCefString = cef.setCefString;

/// CEF Crashpad/Breakpad runtime state. true only when CEF found a valid
/// crash_reporter.cfg during initialize.
pub fn crashReporterEnabled() bool {
    return c.cef_crash_reporting_enabled() == 1;
}

/// Set or clear a Crashpad crash key. Empty value clears the key. The key must
/// already be declared in crash_reporter.cfg's [CrashKeys] section to be useful.
pub fn crashReporterSetKeyValue(key: []const u8, value: []const u8) bool {
    if (key.len == 0) return false;
    var key_str: c.cef_string_t = std.mem.zeroes(c.cef_string_t);
    var value_str: c.cef_string_t = std.mem.zeroes(c.cef_string_t);
    setCefString(&key_str, key);
    setCefString(&value_str, value);
    defer _ = c.cef_string_utf16_clear(&key_str);
    defer _ = c.cef_string_utf16_clear(&value_str);
    c.cef_set_crash_key_value(&key_str, &value_str);
    return true;
}
