const std = @import("std");

/// CEF Crashpad/Breakpad crash key parameter.
pub const ExtraParam = struct {
    key: []const u8,
    value: []const u8,
};

/// Startup crash reporter config. CEF reads crash_reporter.cfg before initialize,
/// so this represents the portion that must exist before the first browser starts.
pub const Options = struct {
    enabled: bool = true,
    product_name: []const u8 = "Suji App",
    product_version: []const u8 = "0.1.0",
    app_name: []const u8 = "Suji App",
    submit_url: ?[]const u8 = null,
    upload_to_server: bool = true,
    ignore_system_crash_handler: bool = false,
    rate_limit: bool = true,
    max_uploads_per_day: u32 = 5,
    max_database_size_mb: u32 = 20,
    max_database_age_days: u32 = 5,
    extra: []const ExtraParam = &.{},
    global_extra: []const ExtraParam = &.{},
};

/// CEF crash key names are small ASCII identifiers. Keep the public limit below
/// Chromium's small crash-key limit so runtime and cfg behavior agree.
pub const MAX_KEY_BYTES: usize = 39;
pub const MAX_VALUE_BYTES: usize = 1024;

pub fn isValidCrashKey(key: []const u8) bool {
    if (key.len == 0 or key.len > MAX_KEY_BYTES) return false;
    for (key) |c| {
        const ok = (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

fn appendIniValue(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    for (value) |c| {
        // INI line injection and control bytes are not meaningful to Crashpad config.
        try out.append(allocator, if (c < 0x20 or c == 0x7f) ' ' else c);
    }
}

fn appendConfigLine(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    key: []const u8,
    value: []const u8,
) !void {
    try out.appendSlice(allocator, key);
    try out.append(allocator, '=');
    try appendIniValue(allocator, out, value);
    try out.append(allocator, '\n');
}

fn appendBoolLine(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    key: []const u8,
    value: bool,
) !void {
    try appendConfigLine(allocator, out, key, if (value) "true" else "false");
}

fn appendIntLine(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    key: []const u8,
    value: u32,
) !void {
    var num_buf: [32]u8 = undefined;
    const s = try std.fmt.bufPrint(&num_buf, "{d}", .{value});
    try appendConfigLine(allocator, out, key, s);
}

fn hasKey(params: []const ExtraParam, limit: usize, key: []const u8) bool {
    for (params[0..limit]) |p| {
        if (std.mem.eql(u8, p.key, key)) return true;
    }
    return false;
}

fn appendCrashKeys(allocator: std.mem.Allocator, out: *std.ArrayList(u8), opts: Options) !void {
    var seen: [64]ExtraParam = undefined;
    var seen_len: usize = 0;

    const groups = [_][]const ExtraParam{ opts.extra, opts.global_extra };
    for (groups) |params| {
        for (params) |p| {
            if (!isValidCrashKey(p.key)) continue;
            if (seen_len >= seen.len) break;
            if (hasKey(&seen, seen_len, p.key)) continue;
            seen[seen_len] = .{ .key = p.key, .value = "" };
            seen_len += 1;
            try appendConfigLine(allocator, out, p.key, "large");
        }
    }
}

/// Render CEF crash_reporter.cfg. This intentionally does not create files so
/// unit tests can verify exact config behavior without touching the filesystem.
pub fn renderConfig(allocator: std.mem.Allocator, opts: Options) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "[Config]\n");
    try appendConfigLine(allocator, &out, "ProductName", opts.product_name);
    try appendConfigLine(allocator, &out, "ProductVersion", opts.product_version);
    try appendConfigLine(allocator, &out, "AppName", opts.app_name);
    try appendBoolLine(allocator, &out, "BrowserCrashForwardingEnabled", !opts.ignore_system_crash_handler);
    try appendConfigLine(allocator, &out, "ServerURL", if (opts.upload_to_server) (opts.submit_url orelse "") else "");
    try appendBoolLine(allocator, &out, "RateLimitEnabled", opts.rate_limit);
    try appendIntLine(allocator, &out, "MaxUploadsPerDay", opts.max_uploads_per_day);
    try appendIntLine(allocator, &out, "MaxDatabaseSizeInMb", opts.max_database_size_mb);
    try appendIntLine(allocator, &out, "MaxDatabaseAgeInDays", opts.max_database_age_days);

    try out.appendSlice(allocator, "\n[CrashKeys]\n");
    try appendCrashKeys(allocator, &out, opts);

    return out.toOwnedSlice(allocator);
}

test "isValidCrashKey accepts compact ascii identifiers only" {
    try std.testing.expect(isValidCrashKey("suite"));
    try std.testing.expect(isValidCrashKey("sdk-test_1"));
    try std.testing.expect(!isValidCrashKey(""));
    try std.testing.expect(!isValidCrashKey("has space"));
    try std.testing.expect(!isValidCrashKey("has.dot"));
    try std.testing.expect(!isValidCrashKey("한글"));
    try std.testing.expect(!isValidCrashKey("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMN"));
}

test "renderConfig includes upload URL and core Crashpad knobs" {
    const cfg = try renderConfig(std.testing.allocator, .{
        .product_name = "MyApp",
        .product_version = "1.2.3",
        .app_name = "MyApp",
        .submit_url = "https://crash.example/submit",
        .extra = &.{.{ .key = "suite", .value = "unit" }},
    });
    defer std.testing.allocator.free(cfg);

    inline for (.{
        "[Config]",
        "ProductName=MyApp",
        "ProductVersion=1.2.3",
        "AppName=MyApp",
        "BrowserCrashForwardingEnabled=true",
        "ServerURL=https://crash.example/submit",
        "RateLimitEnabled=true",
        "[CrashKeys]",
        "suite=large",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, cfg, needle) != null);
    }
}

test "renderConfig upload disabled leaves ServerURL empty" {
    const cfg = try renderConfig(std.testing.allocator, .{
        .upload_to_server = false,
        .submit_url = "https://ignored.example",
    });
    defer std.testing.allocator.free(cfg);
    try std.testing.expect(std.mem.indexOf(u8, cfg, "ServerURL=\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, cfg, "https://ignored.example") == null);
}

test "renderConfig de-dupes invalid crash keys and sanitizes line breaks" {
    const cfg = try renderConfig(std.testing.allocator, .{
        .product_name = "Bad\nName",
        .extra = &.{
            .{ .key = "ok", .value = "1" },
            .{ .key = "bad key", .value = "2" },
        },
        .global_extra = &.{.{ .key = "ok", .value = "3" }},
    });
    defer std.testing.allocator.free(cfg);

    try std.testing.expect(std.mem.indexOf(u8, cfg, "ProductName=Bad Name") != null);
    try std.testing.expect(std.mem.indexOf(u8, cfg, "bad key") == null);
    const first = std.mem.indexOf(u8, cfg, "ok=large") orelse return error.TestExpectedEqual;
    try std.testing.expect(std.mem.indexOfPos(u8, cfg, first + 1, "ok=large") == null);
}
