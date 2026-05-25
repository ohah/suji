const std = @import("std");

pub const CheckError = error{
    MissingCurrentVersion,
    MissingLatestVersion,
    InvalidCurrentVersion,
    InvalidLatestVersion,
    InvalidUrl,
    InvalidSha256,
};

pub const CheckResult = struct {
    update_available: bool,
    current_version: []const u8,
    version: []const u8,
    url: []const u8,
    sha256: []const u8,
    notes: []const u8,
    pub_date: []const u8,
};

pub fn errorCode(err: anyerror) []const u8 {
    return switch (err) {
        error.MissingCurrentVersion => "missing_current_version",
        error.MissingLatestVersion => "missing_latest_version",
        error.InvalidCurrentVersion => "invalid_current_version",
        error.InvalidLatestVersion => "invalid_latest_version",
        error.InvalidUrl => "invalid_url",
        error.InvalidSha256 => "invalid_sha256",
        else => "updater_error",
    };
}

pub fn checkUpdate(
    current_version_raw: []const u8,
    latest_version_raw: []const u8,
    url: []const u8,
    sha256: []const u8,
    notes: []const u8,
    pub_date: []const u8,
) CheckError!CheckResult {
    const current_version = cleanVersion(current_version_raw);
    const latest_version = cleanVersion(latest_version_raw);
    if (current_version.len == 0) return error.MissingCurrentVersion;
    if (latest_version.len == 0) return error.MissingLatestVersion;
    if (!isSupportedUpdateUrl(url)) return error.InvalidUrl;
    if (!isValidSha256Hex(sha256)) return error.InvalidSha256;

    const cmp = compareVersions(current_version, latest_version) catch |err| switch (err) {
        error.InvalidLeftVersion => return error.InvalidCurrentVersion,
        error.InvalidRightVersion => return error.InvalidLatestVersion,
    };

    return .{
        .update_available = cmp < 0,
        .current_version = current_version,
        .version = latest_version,
        .url = url,
        .sha256 = sha256,
        .notes = notes,
        .pub_date = pub_date,
    };
}

fn cleanVersion(version: []const u8) []const u8 {
    var v = std.mem.trim(u8, version, " \t\r\n");
    if (v.len > 0 and (v[0] == 'v' or v[0] == 'V')) v = v[1..];
    return v;
}

const CompareError = error{ InvalidLeftVersion, InvalidRightVersion };

pub fn compareVersions(left_raw: []const u8, right_raw: []const u8) CompareError!i8 {
    const left = cleanVersion(left_raw);
    const right = cleanVersion(right_raw);
    const left_parts = splitVersion(left) catch return error.InvalidLeftVersion;
    const right_parts = splitVersion(right) catch return error.InvalidRightVersion;

    var left_main = left_parts.main;
    var right_main = right_parts.main;
    while (left_main.len > 0 or right_main.len > 0) {
        const l = takeNumericSegment(&left_main) catch return error.InvalidLeftVersion;
        const r = takeNumericSegment(&right_main) catch return error.InvalidRightVersion;
        if (l < r) return -1;
        if (l > r) return 1;
    }

    return comparePrerelease(left_parts.prerelease, right_parts.prerelease) catch |err| switch (err) {
        error.InvalidLeftVersion => error.InvalidLeftVersion,
        error.InvalidRightVersion => error.InvalidRightVersion,
    };
}

const VersionParts = struct {
    main: []const u8,
    prerelease: []const u8,
};

fn splitVersion(version: []const u8) !VersionParts {
    if (version.len == 0) return error.InvalidVersion;
    const no_build = blk: {
        const plus = std.mem.indexOfScalar(u8, version, '+') orelse break :blk version;
        break :blk version[0..plus];
    };
    if (no_build.len == 0) return error.InvalidVersion;
    const dash = std.mem.indexOfScalar(u8, no_build, '-');
    const main = if (dash) |d| no_build[0..d] else no_build;
    const pre = if (dash) |d| no_build[d + 1 ..] else "";
    if (main.len == 0) return error.InvalidVersion;
    if (dash != null and pre.len == 0) return error.InvalidVersion;
    return .{ .main = main, .prerelease = pre };
}

fn takeNumericSegment(rest: *[]const u8) !u64 {
    if (rest.*.len == 0) return 0;
    const idx = std.mem.indexOfScalar(u8, rest.*, '.') orelse rest.*.len;
    if (idx == 0) return error.InvalidVersion;
    const segment = rest.*[0..idx];
    for (segment) |c| {
        if (!std.ascii.isDigit(c)) return error.InvalidVersion;
    }
    const parsed = std.fmt.parseInt(u64, segment, 10) catch return error.InvalidVersion;
    if (idx == rest.*.len) {
        rest.* = "";
    } else {
        if (idx + 1 == rest.*.len) return error.InvalidVersion;
        rest.* = rest.*[idx + 1 ..];
    }
    return parsed;
}

fn comparePrerelease(left: []const u8, right: []const u8) CompareError!i8 {
    if (left.len == 0 and right.len == 0) return 0;
    if (left.len == 0) return 1;
    if (right.len == 0) return -1;

    var left_rest = left;
    var right_rest = right;
    while (left_rest.len > 0 or right_rest.len > 0) {
        if (left_rest.len == 0) return -1;
        if (right_rest.len == 0) return 1;
        const l = takeIdentifier(&left_rest) catch return error.InvalidLeftVersion;
        const r = takeIdentifier(&right_rest) catch return error.InvalidRightVersion;
        const c = compareIdentifier(l, r);
        if (c != 0) return c;
    }
    return 0;
}

fn takeIdentifier(rest: *[]const u8) ![]const u8 {
    const idx = std.mem.indexOfScalar(u8, rest.*, '.') orelse rest.*.len;
    if (idx == 0) return error.InvalidVersion;
    const ident = rest.*[0..idx];
    for (ident) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '-';
        if (!ok) return error.InvalidVersion;
    }
    if (idx == rest.*.len) {
        rest.* = "";
    } else {
        if (idx + 1 == rest.*.len) return error.InvalidVersion;
        rest.* = rest.*[idx + 1 ..];
    }
    return ident;
}

fn compareIdentifier(left: []const u8, right: []const u8) i8 {
    const left_numeric = allDigits(left);
    const right_numeric = allDigits(right);
    if (left_numeric and right_numeric) {
        const l = std.fmt.parseInt(u64, left, 10) catch std.math.maxInt(u64);
        const r = std.fmt.parseInt(u64, right, 10) catch std.math.maxInt(u64);
        if (l < r) return -1;
        if (l > r) return 1;
        return 0;
    }
    if (left_numeric and !right_numeric) return -1;
    if (!left_numeric and right_numeric) return 1;
    return compareLex(left, right);
}

fn compareLex(left: []const u8, right: []const u8) i8 {
    const n = @min(left.len, right.len);
    for (0..n) |i| {
        if (left[i] < right[i]) return -1;
        if (left[i] > right[i]) return 1;
    }
    if (left.len < right.len) return -1;
    if (left.len > right.len) return 1;
    return 0;
}

fn allDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

pub fn isSupportedUpdateUrl(url: []const u8) bool {
    if (url.len == 0 or url.len > 4096) return false;
    for (url) |c| {
        if (c <= 0x20 or c == '"' or c == '\\') return false;
    }
    return std.mem.startsWith(u8, url, "https://") or
        std.mem.startsWith(u8, url, "http://") or
        std.mem.startsWith(u8, url, "file://");
}

pub fn isValidSha256Hex(hex: []const u8) bool {
    if (hex.len == 0) return true;
    if (hex.len != 64) return false;
    for (hex) |c| {
        const ok = (c >= '0' and c <= '9') or
            (c >= 'a' and c <= 'f') or
            (c >= 'A' and c <= 'F');
        if (!ok) return false;
    }
    return true;
}

pub fn sha256File(io: std.Io, path: []const u8, out_hex: *[64]u8) ![]const u8 {
    var file = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.openFileAbsolute(io, path, .{})
    else
        try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = file.readStreaming(io, &.{&buf}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) break;
        hasher.update(buf[0..n]);
    }

    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    writeLowerHex(&digest, out_hex);
    return out_hex[0..];
}

pub fn sha256Equal(actual: []const u8, expected: []const u8) bool {
    if (actual.len != expected.len) return false;
    for (actual, 0..) |a, i| {
        const b = expected[i];
        if (std.ascii.toLower(a) != std.ascii.toLower(b)) return false;
    }
    return true;
}

fn writeLowerHex(bytes: []const u8, out: []u8) void {
    const alphabet = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[i * 2] = alphabet[b >> 4];
        out[i * 2 + 1] = alphabet[b & 0x0f];
    }
}

test "compareVersions handles semver ordering and v prefix" {
    try std.testing.expectEqual(@as(i8, -1), try compareVersions("1.2.3", "1.2.4"));
    try std.testing.expectEqual(@as(i8, 0), try compareVersions("v1.2.3", "1.2.3+build.7"));
    try std.testing.expectEqual(@as(i8, 1), try compareVersions("1.10.0", "1.9.9"));
    try std.testing.expectEqual(@as(i8, 1), try compareVersions("1.0.0", "1.0.0-beta.1"));
    try std.testing.expectEqual(@as(i8, -1), try compareVersions("1.0.0-beta.1", "1.0.0-beta.2"));
}

test "compareVersions rejects malformed versions" {
    try std.testing.expectError(error.InvalidLeftVersion, compareVersions("1..0", "1.0.0"));
    try std.testing.expectError(error.InvalidRightVersion, compareVersions("1.0.0", "1.0.x"));
    try std.testing.expectError(error.InvalidRightVersion, compareVersions("1.0.0", "1.0.0-"));
}

test "checkUpdate validates URL/hash and detects downgrade/no-op" {
    const sha = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const up = try checkUpdate("1.0.0", "1.1.0", "https://example.test/app.zip", sha, "notes", "2026-05-25T00:00:00Z");
    try std.testing.expect(up.update_available);
    try std.testing.expectEqualStrings("1.1.0", up.version);

    const same = try checkUpdate("1.1.0", "1.1.0", "file:///tmp/app.zip", "", "", "");
    try std.testing.expect(!same.update_available);

    try std.testing.expectError(error.InvalidUrl, checkUpdate("1.0.0", "1.1.0", "ftp://example.test/app.zip", "", "", ""));
    try std.testing.expectError(error.InvalidSha256, checkUpdate("1.0.0", "1.1.0", "https://example.test/app.zip", "abc", "", ""));
}

test "sha256File hashes bytes and compares case-insensitively" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile(io, "payload.bin", .{});
    var writer_buf: [64]u8 = undefined;
    var writer = file.writer(io, &writer_buf);
    try writer.interface.writeAll("hello updater");
    try writer.interface.flush();
    file.close(io);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/payload.bin", .{&tmp.sub_path});
    var hex: [64]u8 = undefined;
    const digest = try sha256File(io, path, &hex);
    try std.testing.expectEqualStrings(
        "026cfa17e5bb78d47c0b760323306b7727f62d83e4a8435b3dcf1ef5ec1da1ac",
        digest,
    );
    try std.testing.expect(sha256Equal(digest, "026CFA17E5BB78D47C0B760323306B7727F62D83E4A8435B3DCF1EF5EC1DA1AC"));
}
