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
pub const MAX_REPORTS: usize = 64;

pub const CrashReport = struct {
    id_buf: [64]u8 = undefined,
    id_len: usize = 0,
    date_buf: [32]u8 = undefined,
    date_len: usize = 0,
    mtime_ns: i128 = 0,

    pub fn id(self: *const CrashReport) []const u8 {
        return self.id_buf[0..self.id_len];
    }

    pub fn date(self: *const CrashReport) []const u8 {
        return self.date_buf[0..self.date_len];
    }
};

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

pub fn isValidCrashValue(value: []const u8) bool {
    return value.len <= MAX_VALUE_BYTES;
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

fn dumpIdFromName(name: []const u8) ?[]const u8 {
    if (!std.mem.endsWith(u8, name, ".dmp")) return null;
    const id = name[0 .. name.len - ".dmp".len];
    if (id.len == 0 or id.len > 64) return null;
    for (id) |c| {
        const ok = (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '_' or c == '-';
        if (!ok) return null;
    }
    return id;
}

fn formatReportDateNs(dst: []u8, ns: i128) ?[]const u8 {
    const safe_ns = if (ns < 0) 0 else ns;
    const secs: u64 = @intCast(@divFloor(safe_ns, std.time.ns_per_s));
    const epoch_s: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const yd = epoch_s.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = epoch_s.getDaySeconds();
    return std.fmt.bufPrint(
        dst,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
        .{
            yd.year,
            md.month.numeric(),
            md.day_index + 1,
            ds.getHoursIntoDay(),
            ds.getMinutesIntoHour(),
            ds.getSecondsIntoMinute(),
        },
    ) catch null;
}

fn appendReport(out: []CrashReport, count: *usize, id: []const u8, mtime_ns: i128) void {
    var slot: usize = count.*;
    const replacing = count.* >= out.len;
    if (count.* >= out.len) {
        if (out.len == 0) return;
        slot = 0;
        for (out[0..count.*], 0..) |report, i| {
            if (report.mtime_ns < out[slot].mtime_ns) slot = i;
        }
        if (mtime_ns <= out[slot].mtime_ns) return;
    }

    var report = CrashReport{ .id_len = id.len, .mtime_ns = mtime_ns };
    @memcpy(report.id_buf[0..id.len], id);
    const date = formatReportDateNs(&report.date_buf, mtime_ns) orelse return;
    report.date_len = date.len;
    out[slot] = report;
    if (!replacing) count.* += 1;
}

fn reportNewer(_: void, a: CrashReport, b: CrashReport) bool {
    return a.mtime_ns > b.mtime_ns;
}

fn collectReportsFromDir(dir: *std.Io.Dir, io: std.Io, out: []CrashReport, count: *usize) !void {
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const id = dumpIdFromName(entry.name) orelse continue;
        var file = dir.openFile(io, entry.name, .{}) catch continue;
        const stat = file.stat(io) catch {
            file.close(io);
            continue;
        };
        file.close(io);
        appendReport(out, count, id, stat.mtime.toNanoseconds());
    }
}

/// Read Crashpad local report database files from `<root>/completed/*.dmp`
/// and, optionally, `<root>/pending/*.dmp`. CEF stores local dumps in this
/// Crashpad layout; upload server verification remains outside local CI.
pub fn collectReports(crashpad_dir: *std.Io.Dir, io: std.Io, include_pending: bool, out: []CrashReport) usize {
    var count: usize = 0;

    if (crashpad_dir.openDir(io, "completed", .{ .iterate = true })) |completed| {
        var d = completed;
        defer d.close(io);
        collectReportsFromDir(&d, io, out, &count) catch {};
    } else |_| {}

    if (include_pending) {
        if (crashpad_dir.openDir(io, "pending", .{ .iterate = true })) |pending| {
            var d = pending;
            defer d.close(io);
            collectReportsFromDir(&d, io, out, &count) catch {};
        } else |_| {}
    }

    std.mem.sort(CrashReport, out[0..count], {}, reportNewer);
    return count;
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

test "isValidCrashValue accepts 1024 bytes max" {
    var ok_value = [_]u8{'x'} ** MAX_VALUE_BYTES;
    var oversized_value = [_]u8{'x'} ** (MAX_VALUE_BYTES + 1);

    try std.testing.expect(isValidCrashValue(""));
    try std.testing.expect(isValidCrashValue(&ok_value));
    try std.testing.expect(!isValidCrashValue(&oversized_value));
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

test "collectReports reads Crashpad completed dumps" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "completed");
    try tmp.dir.createDirPath(io, "pending");

    var ok = try tmp.dir.createFile(io, "completed/123e4567-e89b-12d3-a456-426614174000.dmp", .{});
    ok.close(io);
    var ignored_ext = try tmp.dir.createFile(io, "completed/not-a-dump.txt", .{});
    ignored_ext.close(io);
    var pending = try tmp.dir.createFile(io, "pending/pending-1.dmp", .{});
    pending.close(io);

    var reports: [MAX_REPORTS]CrashReport = undefined;
    const completed_count = collectReports(&tmp.dir, io, false, &reports);
    try std.testing.expectEqual(@as(usize, 1), completed_count);
    try std.testing.expectEqualStrings("123e4567-e89b-12d3-a456-426614174000", reports[0].id());
    try std.testing.expect(std.mem.endsWith(u8, reports[0].date(), "Z"));

    const all_count = collectReports(&tmp.dir, io, true, &reports);
    try std.testing.expectEqual(@as(usize, 2), all_count);
}
