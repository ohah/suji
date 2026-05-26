const std = @import("std");
const builtin = @import("builtin");

pub const CheckError = error{
    MissingCurrentVersion,
    MissingLatestVersion,
    InvalidCurrentVersion,
    InvalidLatestVersion,
    InvalidUrl,
    InvalidSha256,
};

pub const DownloadError = error{
    InvalidUrl,
    InvalidDestination,
    DestinationTooLong,
    InvalidSha256,
    Read,
    Write,
    Download,
    HttpStatus,
};

pub const PrepareError = error{
    OutOfMemory,
    UnsupportedPlatform,
    UnsupportedFormat,
    RequiresPackageManager,
    InvalidPath,
    ArtifactNotFound,
    StagePathTooLong,
    CommandFailed,
    AppBundleNotFound,
    AmbiguousAppBundle,
};

pub const InstallError = error{
    OutOfMemory,
    UnsupportedPlatform,
    InvalidPath,
    SourceNotFound,
    SamePath,
    HelperPathTooLong,
    InvalidPid,
    Write,
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

pub const DownloadResult = struct {
    success: bool,
    path: []const u8,
    sha256: []const u8,
    size: u64,
};

pub const InstallFormat = enum {
    app,
    zip,
    dmg,
    appimage,
    raw,
    deb,
};

pub const PrepareInstallOptions = struct {
    artifact_path: []const u8,
    stage_dir: []const u8,
    target_path: []const u8,
    format: InstallFormat,
};

pub const PreparedInstall = struct {
    source_path: []const u8,
    target_path: []const u8,
    stage_dir: []const u8,
    format: InstallFormat,
    action: []const u8,
    requires_quit_and_install: bool,
};

pub const QuitAndInstallOptions = struct {
    source_path: []const u8,
    target_path: []const u8,
    helper_path: []const u8,
    wait_pid: i64,
    relaunch: bool = true,
};

pub fn errorCode(err: anyerror) []const u8 {
    return switch (err) {
        error.MissingCurrentVersion => "missing_current_version",
        error.MissingLatestVersion => "missing_latest_version",
        error.InvalidCurrentVersion => "invalid_current_version",
        error.InvalidLatestVersion => "invalid_latest_version",
        error.InvalidUrl => "invalid_url",
        error.InvalidSha256 => "invalid_sha256",
        error.InvalidDestination => "invalid_destination",
        error.DestinationTooLong => "destination_too_long",
        error.Read => "read",
        error.Write => "write",
        error.Download => "download",
        error.HttpStatus => "http_status",
        error.UnsupportedPlatform => "unsupported_platform",
        error.UnsupportedFormat => "unsupported_format",
        error.RequiresPackageManager => "requires_package_manager",
        error.ArtifactNotFound => "artifact_not_found",
        error.StagePathTooLong => "stage_path_too_long",
        error.CommandFailed => "command_failed",
        error.AppBundleNotFound => "app_bundle_not_found",
        error.AmbiguousAppBundle => "ambiguous_app_bundle",
        error.InvalidPath => "invalid_path",
        error.SourceNotFound => "source_not_found",
        error.SamePath => "same_path",
        error.HelperPathTooLong => "helper_path_too_long",
        error.InvalidPid => "invalid_pid",
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

pub fn downloadArtifact(
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    destination: []const u8,
    expected_sha256: []const u8,
    temp_path_buf: []u8,
    out_hex: *[64]u8,
) DownloadError!DownloadResult {
    if (!isSupportedUpdateUrl(url)) return error.InvalidUrl;
    if (!isValidDestinationPath(destination)) return error.InvalidDestination;
    if (!isValidSha256Hex(expected_sha256)) return error.InvalidSha256;

    const temp_path = std.fmt.bufPrint(temp_path_buf, "{s}.download", .{destination}) catch
        return error.DestinationTooLong;

    deleteFileIfExists(io, temp_path);
    var promoted = false;
    defer if (!promoted) deleteFileIfExists(io, temp_path);

    try writeUrlToFile(allocator, io, url, temp_path);

    const actual = sha256File(io, temp_path, out_hex) catch return error.Read;
    const size = fileSize(io, temp_path) catch return error.Read;
    if (expected_sha256.len > 0 and !sha256Equal(actual, expected_sha256)) {
        return .{
            .success = false,
            .path = destination,
            .sha256 = actual,
            .size = size,
        };
    }

    renameFile(io, temp_path, destination) catch return error.Write;
    promoted = true;
    return .{
        .success = true,
        .path = destination,
        .sha256 = actual,
        .size = size,
    };
}

pub fn sha256Equal(actual: []const u8, expected: []const u8) bool {
    if (actual.len != expected.len) return false;
    for (actual, 0..) |a, i| {
        const b = expected[i];
        if (std.ascii.toLower(a) != std.ascii.toLower(b)) return false;
    }
    return true;
}

pub fn detectInstallFormat(artifact_path: []const u8) InstallFormat {
    if (std.ascii.endsWithIgnoreCase(artifact_path, ".app")) return .app;
    if (std.ascii.endsWithIgnoreCase(artifact_path, ".zip")) return .zip;
    if (std.ascii.endsWithIgnoreCase(artifact_path, ".dmg")) return .dmg;
    if (std.ascii.endsWithIgnoreCase(artifact_path, ".appimage")) return .appimage;
    if (std.ascii.endsWithIgnoreCase(artifact_path, ".deb")) return .deb;
    return .raw;
}

pub fn parseInstallFormat(format_raw: []const u8, artifact_path: []const u8) PrepareError!InstallFormat {
    const format = std.mem.trim(u8, format_raw, " \t\r\n");
    if (format.len == 0 or std.ascii.eqlIgnoreCase(format, "auto")) {
        return detectInstallFormat(artifact_path);
    }
    if (std.ascii.eqlIgnoreCase(format, "app")) return .app;
    if (std.ascii.eqlIgnoreCase(format, "zip")) return .zip;
    if (std.ascii.eqlIgnoreCase(format, "dmg")) return .dmg;
    if (std.ascii.eqlIgnoreCase(format, "appimage")) return .appimage;
    if (std.ascii.eqlIgnoreCase(format, "raw")) return .raw;
    if (std.ascii.eqlIgnoreCase(format, "deb")) return .deb;
    return error.UnsupportedFormat;
}

pub fn installFormatName(format: InstallFormat) []const u8 {
    return switch (format) {
        .app => "app",
        .zip => "zip",
        .dmg => "dmg",
        .appimage => "appimage",
        .raw => "raw",
        .deb => "deb",
    };
}

pub fn defaultPrepareInstallStageDir(artifact_path: []const u8, out: []u8) PrepareError![]const u8 {
    if (!isValidInstallPath(artifact_path)) return error.InvalidPath;
    return std.fmt.bufPrint(out, "{s}.stage", .{artifact_path}) catch error.StagePathTooLong;
}

pub fn validatePrepareInstallOptions(io: std.Io, opts: PrepareInstallOptions) PrepareError!void {
    if (!isValidInstallPath(opts.artifact_path) or !isValidInstallPath(opts.stage_dir)) {
        return error.InvalidPath;
    }
    if (opts.target_path.len > 0 and !isValidInstallPath(opts.target_path)) {
        return error.InvalidPath;
    }
    if (!pathExists(io, opts.artifact_path)) return error.ArtifactNotFound;

    switch (opts.format) {
        .app, .dmg => {
            if (builtin.os.tag != .macos) return error.UnsupportedPlatform;
            if (opts.target_path.len == 0) return error.InvalidPath;
        },
        .zip => {
            // .zip 은 macOS(stage 내 .app 추출 → target.app 교체) + Windows
            // (stage 디렉토리 → install dir 통째 교체) 둘 다 지원.
            if (builtin.os.tag != .macos and builtin.os.tag != .windows) return error.UnsupportedPlatform;
            if (opts.target_path.len == 0) return error.InvalidPath;
        },
        .appimage => {
            if (builtin.os.tag != .linux) return error.UnsupportedPlatform;
            if (opts.target_path.len == 0) return error.InvalidPath;
        },
        .raw => {
            if (opts.target_path.len == 0) return error.InvalidPath;
        },
        .deb => {
            if (builtin.os.tag != .linux) return error.UnsupportedPlatform;
        },
    }
}

pub fn preparedQuitAndInstall(
    source_path: []const u8,
    target_path: []const u8,
    stage_dir: []const u8,
    format: InstallFormat,
) PreparedInstall {
    return .{
        .source_path = source_path,
        .target_path = target_path,
        .stage_dir = stage_dir,
        .format = format,
        .action = "quitAndInstall",
        .requires_quit_and_install = true,
    };
}

pub fn preparedSystemPackage(artifact_path: []const u8, stage_dir: []const u8) PreparedInstall {
    return .{
        .source_path = artifact_path,
        .target_path = "",
        .stage_dir = stage_dir,
        .format = .deb,
        .action = "systemPackage",
        .requires_quit_and_install = false,
    };
}

pub fn findAppBundle(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_path: []const u8,
) PrepareError![]u8 {
    if (!isValidInstallPath(root_path)) return error.InvalidPath;
    var found: ?[]u8 = null;
    errdefer if (found) |p| allocator.free(p);
    try findAppBundleInner(allocator, io, root_path, 0, &found);
    return found orelse error.AppBundleNotFound;
}

fn findAppBundleInner(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    depth: usize,
    found: *?[]u8,
) PrepareError!void {
    if (depth > 8) return;

    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch return error.AppBundleNotFound;
    defer dir.close(io);

    var iter = dir.iterate();
    while (iter.next(io) catch return error.AppBundleNotFound) |entry| {
        if (entry.kind != .directory) continue;

        const child_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name }) catch
            return error.OutOfMemory;
        errdefer allocator.free(child_path);

        if (std.ascii.endsWithIgnoreCase(entry.name, ".app")) {
            if (found.* != null) return error.AmbiguousAppBundle;
            found.* = child_path;
            continue;
        }

        if (depth < 8) {
            findAppBundleInner(allocator, io, child_path, depth + 1, found) catch |err| switch (err) {
                error.AppBundleNotFound => {},
                else => return err,
            };
        }
        allocator.free(child_path);
    }
}

pub fn defaultQuitAndInstallHelperPath(source_path: []const u8, out: []u8) InstallError![]const u8 {
    if (!isValidInstallPath(source_path)) return error.InvalidPath;
    const ext: []const u8 = if (builtin.os.tag == .windows) ".quit-install.ps1" else ".quit-install.sh";
    return std.fmt.bufPrint(out, "{s}{s}", .{ source_path, ext }) catch error.HelperPathTooLong;
}

pub fn validateQuitAndInstallOptions(io: std.Io, opts: QuitAndInstallOptions) InstallError!void {
    if (!isValidInstallPath(opts.source_path) or
        !isValidInstallPath(opts.target_path) or
        !isValidInstallPath(opts.helper_path))
    {
        return error.InvalidPath;
    }
    if (opts.wait_pid <= 0) return error.InvalidPid;
    if (std.mem.eql(u8, opts.source_path, opts.target_path)) return error.SamePath;
    if (std.mem.eql(u8, opts.helper_path, opts.source_path) or
        std.mem.eql(u8, opts.helper_path, opts.target_path))
    {
        return error.InvalidPath;
    }
    if (!pathExists(io, opts.source_path)) return error.SourceNotFound;
}

pub fn renderQuitAndInstallScript(
    allocator: std.mem.Allocator,
    opts: QuitAndInstallOptions,
) InstallError![]u8 {
    if (!isValidInstallPath(opts.source_path) or
        !isValidInstallPath(opts.target_path) or
        !isValidInstallPath(opts.helper_path))
    {
        return error.InvalidPath;
    }
    if (opts.wait_pid <= 0) return error.InvalidPid;

    if (builtin.os.tag == .windows) return renderQuitAndInstallScriptWindows(allocator, opts);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator,
        \\#!/bin/sh
        \\set -eu
        \\SOURCE=
    );
    try appendShellSingleQuoted(allocator, &out, opts.source_path);
    try out.appendSlice(allocator, "\nTARGET=");
    try appendShellSingleQuoted(allocator, &out, opts.target_path);
    try out.appendSlice(allocator, "\nWAIT_PID=");
    try out.print(allocator, "{d}", .{opts.wait_pid});
    try out.appendSlice(allocator, "\nRELAUNCH=");
    try out.appendSlice(allocator, if (opts.relaunch) "1" else "0");
    try out.appendSlice(allocator,
        \\
        \\BACKUP="${TARGET}.suji-update-backup-$$"
        \\cleanup() { rm -f "$0"; }
        \\trap cleanup EXIT
        \\while kill -0 "$WAIT_PID" 2>/dev/null; do
        \\  sleep 0.1
        \\done
        \\if [ ! -e "$SOURCE" ]; then
        \\  exit 2
        \\fi
        \\rm -rf "$BACKUP"
        \\if [ -e "$TARGET" ]; then
        \\  mv "$TARGET" "$BACKUP"
        \\fi
        \\if ! mv "$SOURCE" "$TARGET"; then
        \\  if [ -e "$BACKUP" ]; then
        \\    mv "$BACKUP" "$TARGET"
        \\  fi
        \\  exit 3
        \\fi
        \\rm -rf "$BACKUP"
        \\if [ "$RELAUNCH" = "1" ]; then
        \\  case "$TARGET" in
        \\    *.app) open -n "$TARGET" >/dev/null 2>&1 || true ;;
        \\    *) if [ -x "$TARGET" ]; then "$TARGET" >/dev/null 2>&1 & fi ;;
        \\  esac
        \\fi
        \\
    );

    return out.toOwnedSlice(allocator);
}

/// Windows PowerShell `.ps1` helper. caller 가
/// `powershell -NoProfile -ExecutionPolicy Bypass -File <helper>` 으로 실행.
/// `.zip` 포맷 — source 는 압축 해제된 stage 디렉토리, target 은 install dir.
/// Move-Item 으로 디렉토리 통째 교체, 실패 시 backup 복구.
fn renderQuitAndInstallScriptWindows(
    allocator: std.mem.Allocator,
    opts: QuitAndInstallOptions,
) InstallError![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    // PowerShell single-quoted string: backtick-escape backtick + double single-quote.
    try out.appendSlice(allocator, "$ErrorActionPreference = 'Stop'\n$src = '");
    try appendPwshSingleQuoted(allocator, &out, opts.source_path);
    try out.appendSlice(allocator, "'\n$dst = '");
    try appendPwshSingleQuoted(allocator, &out, opts.target_path);
    try out.appendSlice(allocator, "'\n$waitPid = ");
    try out.print(allocator, "{d}", .{opts.wait_pid});
    try out.appendSlice(allocator, "\n$relaunch = ");
    try out.appendSlice(allocator, if (opts.relaunch) "1" else "0");
    try out.appendSlice(allocator,
        \\
        \\try {
        \\  # WaitForExit 는 process handle 기준 — `Get-Process` 만 쓰면 PID 재사용
        \\  # race 가능 (Suji 종료 직후 OS 가 같은 PID 를 svchost 등에 재할당 →
        \\  # 무한 대기 또는 잘못된 process 대기). handle 잡고 즉시 WaitForExit.
        \\  $waitProc = Get-Process -Id $waitPid -ErrorAction SilentlyContinue
        \\  if ($waitProc) {
        \\    try { $waitProc.WaitForExit() } catch { }
        \\  }
        \\  if (-not (Test-Path -LiteralPath $src)) { exit 2 }
        \\  $bk = "$dst.suji-update-backup-$([guid]::NewGuid().ToString('N'))"
        \\  if (Test-Path -LiteralPath $dst) {
        \\    try { Move-Item -LiteralPath $dst -Destination $bk -Force } catch { exit 4 }
        \\  }
        \\  try {
        \\    Move-Item -LiteralPath $src -Destination $dst -Force
        \\  } catch {
        \\    if (Test-Path -LiteralPath $bk) {
        \\      try { Move-Item -LiteralPath $bk -Destination $dst -Force } catch { }
        \\    }
        \\    exit 3
        \\  }
        \\  if (Test-Path -LiteralPath $bk) {
        \\    Remove-Item -LiteralPath $bk -Recurse -Force -ErrorAction SilentlyContinue
        \\  }
        \\  # Move 후 source parent (extract_dir) 가 빈 디렉토리로 남아 누적 → 정리.
        \\  $srcParent = Split-Path -Parent $src
        \\  if ($srcParent -and (Test-Path -LiteralPath $srcParent)) {
        \\    $remaining = @(Get-ChildItem -LiteralPath $srcParent -Force -ErrorAction SilentlyContinue)
        \\    if ($remaining.Count -eq 0) {
        \\      Remove-Item -LiteralPath $srcParent -Recurse -Force -ErrorAction SilentlyContinue
        \\    }
        \\  }
        \\  if ($relaunch -eq 1) {
        \\    # target 이 디렉토리(.zip 포맷) — `.exe` 단일 후보 선택. unins*는 Inno
        \\    # Setup 의 uninstaller 라 제외. target 이 파일이면 직접 실행.
        \\    if (Test-Path -LiteralPath $dst -PathType Container) {
        \\      $exe = Get-ChildItem -LiteralPath $dst -Filter '*.exe' -File -ErrorAction SilentlyContinue |
        \\        Where-Object { $_.Name -notlike 'unins*' } |
        \\        Select-Object -First 1
        \\      if ($exe) { Start-Process -FilePath $exe.FullName | Out-Null }
        \\    } else {
        \\      Start-Process -FilePath $dst | Out-Null
        \\    }
        \\  }
        \\} finally {
        \\  Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue
        \\}
        \\
    );

    return out.toOwnedSlice(allocator);
}

/// PowerShell single-quoted literal escape — backtick 와 single quote 만 처리
/// (PowerShell 의 single-quoted 는 backslash interpolation 없음).
fn appendPwshSingleQuoted(allocator: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        if (c == '\'') {
            try out.appendSlice(allocator, "''");
        } else {
            try out.append(allocator, c);
        }
    }
}

pub fn writeQuitAndInstallScript(
    allocator: std.mem.Allocator,
    io: std.Io,
    opts: QuitAndInstallOptions,
) InstallError!void {
    try validateQuitAndInstallOptions(io, opts);
    const script = try renderQuitAndInstallScript(allocator, opts);
    defer allocator.free(script);

    deleteFileIfExists(io, opts.helper_path);
    var file = createFileWrite(io, opts.helper_path) catch return error.Write;
    defer file.close(io);

    var writer_buf: [8192]u8 = undefined;
    var writer = file.writer(io, &writer_buf);
    writer.interface.writeAll(script) catch return error.Write;
    writer.interface.flush() catch return error.Write;
}

fn isValidDestinationPath(path: []const u8) bool {
    if (path.len == 0 or path.len > 4096) return false;
    for (path) |c| {
        if (c == 0) return false;
    }
    return true;
}

fn isValidInstallPath(path: []const u8) bool {
    if (!isValidDestinationPath(path)) return false;
    return std.fs.path.isAbsolute(path);
}

fn pathExists(io: std.Io, path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
        return true;
    }
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn appendShellSingleQuoted(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    value: []const u8,
) !void {
    try out.append(allocator, '\'');
    for (value) |c| {
        if (c == '\'') {
            try out.appendSlice(allocator, "'\\''");
        } else {
            try out.append(allocator, c);
        }
    }
    try out.append(allocator, '\'');
}

fn writeUrlToFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    destination: []const u8,
) DownloadError!void {
    if (std.mem.startsWith(u8, url, "file://")) {
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const source = filePathFromUrl(url, &path_buf) catch return error.InvalidUrl;
        return copyFile(io, source, destination);
    }

    if (std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://")) {
        return downloadHttp(allocator, io, url, destination);
    }

    return error.InvalidUrl;
}

pub fn filePathFromUrl(url: []const u8, path_buf: []u8) ![]const u8 {
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    if (!std.mem.eql(u8, uri.scheme, "file")) return error.InvalidUrl;
    if (uri.host) |host| {
        var host_buf: [256]u8 = undefined;
        const raw_host = host.toRaw(&host_buf) catch return error.InvalidUrl;
        if (raw_host.len != 0 and !std.mem.eql(u8, raw_host, "localhost")) {
            return error.InvalidUrl;
        }
    }
    const raw_path = uri.path.toRaw(path_buf) catch return error.InvalidUrl;
    if (!std.fs.path.isAbsolute(raw_path)) return error.InvalidUrl;
    return raw_path;
}

fn copyFile(io: std.Io, source: []const u8, destination: []const u8) DownloadError!void {
    var in_file = openFileRead(io, source) catch return error.Read;
    defer in_file.close(io);

    var out_file = createFileWrite(io, destination) catch return error.Write;
    defer out_file.close(io);

    var reader_buf: [8192]u8 = undefined;
    var writer_buf: [8192]u8 = undefined;
    var writer = out_file.writer(io, &writer_buf);
    while (true) {
        const n = in_file.readStreaming(io, &.{&reader_buf}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return error.Read,
        };
        if (n == 0) break;
        writer.interface.writeAll(reader_buf[0..n]) catch return error.Write;
    }
    writer.interface.flush() catch return error.Write;
}

fn downloadHttp(
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    destination: []const u8,
) DownloadError!void {
    var out_file = createFileWrite(io, destination) catch return error.Write;
    defer out_file.close(io);

    var writer_buf: [8192]u8 = undefined;
    var writer = out_file.writer(io, &writer_buf);

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    const response = client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &writer.interface,
    }) catch return error.Download;
    writer.interface.flush() catch return error.Write;

    const status: u16 = @intFromEnum(response.status);
    if (status < 200 or status >= 300) return error.HttpStatus;
}

fn openFileRead(io: std.Io, path: []const u8) !std.Io.File {
    if (std.fs.path.isAbsolute(path)) {
        return std.Io.Dir.openFileAbsolute(io, path, .{});
    }
    return std.Io.Dir.cwd().openFile(io, path, .{});
}

fn createFileWrite(io: std.Io, path: []const u8) !std.Io.File {
    if (std.fs.path.isAbsolute(path)) {
        return std.Io.Dir.createFileAbsolute(io, path, .{});
    }
    return std.Io.Dir.cwd().createFile(io, path, .{});
}

fn deleteFileIfExists(io: std.Io, path: []const u8) void {
    if (std.fs.path.isAbsolute(path)) {
        std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    } else {
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
    }
}

fn renameFile(io: std.Io, source: []const u8, destination: []const u8) !void {
    if (std.fs.path.isAbsolute(source) or std.fs.path.isAbsolute(destination)) {
        try std.Io.Dir.renameAbsolute(source, destination, io);
        return;
    }
    const cwd = std.Io.Dir.cwd();
    try cwd.rename(source, cwd, destination, io);
}

fn fileSize(io: std.Io, path: []const u8) !u64 {
    var file = try openFileRead(io, path);
    defer file.close(io);
    return (try file.stat(io)).size;
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

test "downloadArtifact stages file URL downloads and validates checksum before promote" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buf, "/tmp/suji-auto-updater-{s}", .{&tmp.sub_path});
    try std.Io.Dir.cwd().createDirPath(io, base);
    defer std.Io.Dir.cwd().deleteTree(io, base) catch {};

    var source_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const source_path = try std.fmt.bufPrint(&source_path_buf, "{s}/source.bin", .{base});
    var file = try std.Io.Dir.createFileAbsolute(io, source_path, .{});
    var writer_buf: [64]u8 = undefined;
    var writer = file.writer(io, &writer_buf);
    try writer.interface.writeAll("download payload");
    try writer.interface.flush();
    file.close(io);

    var url_buf: [std.Io.Dir.max_path_bytes + 16]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "file://{s}", .{source_path});

    var sha: [64]u8 = undefined;
    _ = try sha256File(io, source_path, &sha);

    var dest_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dest = try std.fmt.bufPrint(&dest_buf, "{s}/downloaded.bin", .{base});
    var temp_buf: [std.Io.Dir.max_path_bytes + 16]u8 = undefined;
    var actual: [64]u8 = undefined;
    const result = try downloadArtifact(std.testing.allocator, io, url, dest, sha[0..], &temp_buf, &actual);

    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings(sha[0..], result.sha256);
    try std.testing.expectEqual(@as(u64, "download payload".len), result.size);

    var verify: [64]u8 = undefined;
    try std.testing.expectEqualStrings(sha[0..], try sha256File(io, dest, &verify));
}

test "downloadArtifact checksum mismatch does not publish destination" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buf, "/tmp/suji-auto-updater-bad-{s}", .{&tmp.sub_path});
    try std.Io.Dir.cwd().createDirPath(io, base);
    defer std.Io.Dir.cwd().deleteTree(io, base) catch {};

    var source_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const source_path = try std.fmt.bufPrint(&source_path_buf, "{s}/bad-source.bin", .{base});
    var file = try std.Io.Dir.createFileAbsolute(io, source_path, .{});
    var writer_buf: [64]u8 = undefined;
    var writer = file.writer(io, &writer_buf);
    try writer.interface.writeAll("bad checksum payload");
    try writer.interface.flush();
    file.close(io);

    var url_buf: [std.Io.Dir.max_path_bytes + 16]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "file://{s}", .{source_path});

    var dest_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dest = try std.fmt.bufPrint(&dest_buf, "{s}/bad-dest.bin", .{base});
    var temp_buf: [std.Io.Dir.max_path_bytes + 16]u8 = undefined;
    var actual: [64]u8 = undefined;
    const result = try downloadArtifact(
        std.testing.allocator,
        io,
        url,
        dest,
        "0000000000000000000000000000000000000000000000000000000000000000",
        &temp_buf,
        &actual,
    );

    try std.testing.expect(!result.success);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openFile(io, dest, .{}));
}

test "prepareInstall detects formats and validates platform policy" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    try std.testing.expectEqual(InstallFormat.app, try parseInstallFormat("auto", "/tmp/Suji.app"));
    try std.testing.expectEqual(InstallFormat.zip, try parseInstallFormat("", "/tmp/Suji.zip"));
    try std.testing.expectEqual(InstallFormat.dmg, try parseInstallFormat("DMG", "/tmp/Suji.bin"));
    try std.testing.expectEqual(InstallFormat.appimage, detectInstallFormat("/tmp/Suji.AppImage"));
    try std.testing.expectEqual(InstallFormat.deb, detectInstallFormat("/tmp/suji_1.0.0_amd64.deb"));
    try std.testing.expectError(error.UnsupportedFormat, parseInstallFormat("msi", "/tmp/Suji.msi"));

    var stage_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const stage = try defaultPrepareInstallStageDir("/tmp/Suji.zip", &stage_buf);
    try std.testing.expectEqualStrings("/tmp/Suji.zip.stage", stage);

    const prepared = preparedQuitAndInstall("/tmp/Suji.app", "/Applications/Suji.app", "/tmp/stage", .app);
    try std.testing.expect(prepared.requires_quit_and_install);
    try std.testing.expectEqualStrings("quitAndInstall", prepared.action);

    const deb = preparedSystemPackage("/tmp/suji.deb", "/tmp/stage");
    try std.testing.expect(!deb.requires_quit_and_install);
    try std.testing.expectEqualStrings("systemPackage", deb.action);
}

test "prepareInstall finds a single app bundle under a staging directory" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buf, "/tmp/suji-auto-updater-prepare-{s}", .{&tmp.sub_path});
    try std.Io.Dir.cwd().createDirPath(io, base);
    defer std.Io.Dir.cwd().deleteTree(io, base) catch {};

    var nested_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const nested = try std.fmt.bufPrint(&nested_buf, "{s}/Payload/Suji.app/Contents", .{base});
    try std.Io.Dir.cwd().createDirPath(io, nested);

    const found = try findAppBundle(std.testing.allocator, io, base);
    defer std.testing.allocator.free(found);
    try std.testing.expect(std.mem.endsWith(u8, found, "/Payload/Suji.app"));
}

test "quitAndInstall helper script quotes paths and encodes relaunch policy" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const script = try renderQuitAndInstallScript(std.testing.allocator, .{
        .source_path = "/tmp/Suji Update's App.app",
        .target_path = "/Applications/Suji App.app",
        .helper_path = "/tmp/suji-helper.sh",
        .wait_pid = 12345,
        .relaunch = false,
    });
    defer std.testing.allocator.free(script);

    try std.testing.expect(std.mem.indexOf(u8, script, "SOURCE='/tmp/Suji Update'\\''s App.app'") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "TARGET='/Applications/Suji App.app'") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "WAIT_PID=12345") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "RELAUNCH=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "cleanup() { rm -f \"$0\"; }") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "trap cleanup EXIT") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "while kill -0 \"$WAIT_PID\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "mv \"$SOURCE\" \"$TARGET\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "open -n \"$TARGET\"") != null);
}

test "Windows: quitAndInstall renders PowerShell helper with .ps1 path" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;

    var helper_buf: [std.Io.Dir.max_path_bytes + 32]u8 = undefined;
    const helper = try defaultQuitAndInstallHelperPath("C:\\Apps\\Suji.exe", &helper_buf);
    try std.testing.expect(std.mem.endsWith(u8, helper, ".quit-install.ps1"));

    const script = try renderQuitAndInstallScript(std.testing.allocator, .{
        .source_path = "C:\\Apps\\stage\\extract\\Suji-1.0.0-windows-x64",
        .target_path = "C:\\Apps\\Suji",
        .helper_path = helper,
        .wait_pid = 4321,
        .relaunch = true,
    });
    defer std.testing.allocator.free(script);

    try std.testing.expect(std.mem.indexOf(u8, script, "$ErrorActionPreference") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "$waitProc.WaitForExit()") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "$waitPid = 4321") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "$relaunch = 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "Move-Item -LiteralPath $src") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "Start-Process -FilePath") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "Remove-Item -LiteralPath $PSCommandPath") != null);
    // source parent cleanup (extract_dir 누적 방지).
    try std.testing.expect(std.mem.indexOf(u8, script, "Split-Path -Parent $src") != null);
}

test "Windows: quitAndInstall escapes single quotes in paths" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;

    const script = try renderQuitAndInstallScript(std.testing.allocator, .{
        .source_path = "C:\\Apps\\Joe's\\stage",
        .target_path = "C:\\Apps\\Joe's\\install",
        .helper_path = "C:\\Apps\\helper.ps1",
        .wait_pid = 1,
        .relaunch = false,
    });
    defer std.testing.allocator.free(script);

    // PowerShell single-quoted single quote escape = doubled.
    try std.testing.expect(std.mem.indexOf(u8, script, "$src = 'C:\\Apps\\Joe''s\\stage'") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "$dst = 'C:\\Apps\\Joe''s\\install'") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "$relaunch = 0") != null);
}

test "quitAndInstall validates source and writes helper script" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buf, "/tmp/suji-auto-updater-install-{s}", .{&tmp.sub_path});
    try std.Io.Dir.cwd().createDirPath(io, base);
    defer std.Io.Dir.cwd().deleteTree(io, base) catch {};

    var source_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const source = try std.fmt.bufPrint(&source_buf, "{s}/staged.bin", .{base});
    var file = try std.Io.Dir.createFileAbsolute(io, source, .{});
    var writer_buf: [64]u8 = undefined;
    var writer = file.writer(io, &writer_buf);
    try writer.interface.writeAll("new app bytes");
    try writer.interface.flush();
    file.close(io);

    var target_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buf, "{s}/current.bin", .{base});
    var helper_buf: [std.Io.Dir.max_path_bytes + 32]u8 = undefined;
    const helper = try defaultQuitAndInstallHelperPath(source, &helper_buf);

    try writeQuitAndInstallScript(std.testing.allocator, io, .{
        .source_path = source,
        .target_path = target,
        .helper_path = helper,
        .wait_pid = 1,
        .relaunch = true,
    });
    try std.Io.Dir.accessAbsolute(io, helper, .{});

    try std.testing.expectError(error.SourceNotFound, validateQuitAndInstallOptions(io, .{
        .source_path = "/tmp/suji-missing-staged-update",
        .target_path = target,
        .helper_path = helper,
        .wait_pid = 1,
        .relaunch = false,
    }));
    try std.testing.expectError(error.SamePath, validateQuitAndInstallOptions(io, .{
        .source_path = source,
        .target_path = source,
        .helper_path = helper,
        .wait_pid = 1,
        .relaunch = false,
    }));
}
