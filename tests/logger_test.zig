//! logger 테스트 — 레벨 파싱·필터링·포맷·파일 쓰기·cleanup 검증.

const std = @import("std");
const logger = @import("logger");

const io = std.testing.io;

// ============================================
// Level 파싱
// ============================================

test "Level.parse accepts lowercase/uppercase/mixed" {
    try std.testing.expectEqual(logger.Level.trace, try logger.Level.parse("trace"));
    try std.testing.expectEqual(logger.Level.debug, try logger.Level.parse("DEBUG"));
    try std.testing.expectEqual(logger.Level.info, try logger.Level.parse("Info"));
    try std.testing.expectEqual(logger.Level.warn, try logger.Level.parse("warning"));
    try std.testing.expectEqual(logger.Level.err, try logger.Level.parse("ERROR"));
}

test "Level.parse rejects unknown" {
    try std.testing.expectError(error.UnknownLevel, logger.Level.parse("fatal"));
    try std.testing.expectError(error.UnknownLevel, logger.Level.parse(""));
    try std.testing.expectError(error.UnknownLevel, logger.Level.parse("de"));
}

// ============================================
// Level 필터링 — enabled()
// ============================================

test "enabled passes same-or-higher levels" {
    var lg = logger.Logger.init(io, .{ .level = .info });
    try std.testing.expect(!lg.enabled(.trace));
    try std.testing.expect(!lg.enabled(.debug));
    try std.testing.expect(lg.enabled(.info));
    try std.testing.expect(lg.enabled(.warn));
    try std.testing.expect(lg.enabled(.err));
}

test "setLevel updates filter threshold" {
    var lg = logger.Logger.init(io, .{ .level = .info });
    lg.setLevel(.trace);
    try std.testing.expect(lg.enabled(.trace));
    lg.setLevel(.err);
    try std.testing.expect(!lg.enabled(.warn));
    try std.testing.expect(lg.enabled(.err));
}

// ============================================
// formatLine — ISO 8601 + 레벨 라벨 + 모듈 태그 + 메시지
// ============================================

test "formatLine contains ISO8601 timestamp + level + module + message" {
    var buf: [512]u8 = undefined;
    const line = try logger.formatLine(&buf, io, .debug, "window", "create id={d}", .{42});
    try std.testing.expect(line[line.len - 1] == '\n');
    try std.testing.expect(std.mem.indexOf(u8, line, "[DEBUG]") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "[window]") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "create id=42") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "T") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "Z]") != null);
}

test "formatLine INFO label is padded to same width as DEBUG" {
    var buf: [512]u8 = undefined;
    const info_line = try logger.formatLine(&buf, io, .info, "m", "x", .{});
    try std.testing.expect(std.mem.indexOf(u8, info_line, "[INFO ]") != null);
}

test "formatTimestampMs emits ISO8601 UTC bracket format" {
    // 정확한 날짜보다 형식 불변성을 테스트: `[YYYY-MM-DDTHH:MM:SS.mmmZ]`
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try logger.formatTimestampMs(&w, 1_704_067_200_456); // 임의 시점 + 456ms
    const out = w.buffered();
    try std.testing.expectEqual(@as(usize, 26), out.len); // "[YYYY-MM-DDTHH:MM:SS.mmmZ]" = 26자
    try std.testing.expectEqual(@as(u8, '['), out[0]);
    try std.testing.expectEqual(@as(u8, '-'), out[5]);
    try std.testing.expectEqual(@as(u8, '-'), out[8]);
    try std.testing.expectEqual(@as(u8, 'T'), out[11]);
    try std.testing.expectEqual(@as(u8, ':'), out[14]);
    try std.testing.expectEqual(@as(u8, ':'), out[17]);
    try std.testing.expectEqual(@as(u8, '.'), out[20]);
    try std.testing.expectEqualStrings("456Z]", out[21..]);
}

// ============================================
// buildFileName
// ============================================

test "buildFileName format matches suji-DATE-TIME-PID.log" {
    var buf: [128]u8 = undefined;
    const name = try logger.buildFileName(&buf, 1_704_067_200_000, 12345);
    // suji-YYYYMMDD-HHMMSS-12345.log
    try std.testing.expect(std.mem.startsWith(u8, name, "suji-"));
    try std.testing.expect(std.mem.endsWith(u8, name, "-12345.log"));
    try std.testing.expectEqual(@as(u8, '-'), name[13]); // date/time 구분
    try std.testing.expectEqual(@as(u8, '-'), name[20]); // time/pid 구분
    try std.testing.expectEqual(@as(usize, 30), name.len); // "suji-" + 8 + "-" + 6 + "-" + 5 + ".log"
}

test "buildLogsDir composes home + .suji/logs" {
    var buf: [128]u8 = undefined;
    const path = try logger.buildLogsDir(&buf, "/Users/alice");
    try std.testing.expectEqualStrings("/Users/alice/.suji/logs", path);
}

test "buildLogFilePath composes full path" {
    var out_buf: [256]u8 = undefined;
    var dir_buf: [128]u8 = undefined;
    var fname_buf: [128]u8 = undefined;
    const path = try logger.buildLogFilePath(
        .{ .out = &out_buf, .dir = &dir_buf, .fname = &fname_buf },
        "/tmp",
        1_704_067_200_000,
        12345,
    );
    try std.testing.expect(std.mem.startsWith(u8, path, "/tmp/.suji/logs/suji-"));
    try std.testing.expect(std.mem.endsWith(u8, path, "-12345.log"));
}

test "buildLogsDir returns NoSpaceLeft when buffer too small" {
    var tiny: [8]u8 = undefined;
    try std.testing.expectError(
        error.NoSpaceLeft,
        logger.buildLogsDir(&tiny, "/Users/toolong/path"),
    );
}

// ============================================
// cleanupOldLogs — retention 지난 파일만 삭제
// ============================================

test "cleanupOldLogs retention_days=0 is no-op" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var old_file = try tmp.dir.createFile(io, "suji-20200101-000000-1.log", .{});
    old_file.close(io);

    try logger.cleanupOldLogs(tmp.dir, io, 0, std.time.ns_per_week * 1000);

    var f = try tmp.dir.openFile(io, "suji-20200101-000000-1.log", .{});
    f.close(io);
}

test "cleanupOldLogs ignores non-suji files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var other = try tmp.dir.createFile(io, "other.log", .{});
    other.close(io);
    var also = try tmp.dir.createFile(io, "suji-noext", .{});
    also.close(io);

    const very_future: i128 = std.time.ns_per_week * 10000;
    try logger.cleanupOldLogs(tmp.dir, io, 1, very_future);

    var f1 = try tmp.dir.openFile(io, "other.log", .{});
    f1.close(io);
    var f2 = try tmp.dir.openFile(io, "suji-noext", .{});
    f2.close(io);
}

// ============================================
// File output — tmpDir 파일에 써지는지
// ============================================

test "Logger writes to file + stderr" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile(io, "test.log", .{});
    var lg = logger.Logger.init(io, .{ .level = .debug, .file = file, .console_output = false });

    lg.write(.info, "test", "hello {d}", .{42});
    lg.write(.err, "test", "oops", .{});
    file.close(io);

    var read = try tmp.dir.openFile(io, "test.log", .{});
    defer read.close(io);
    var content: [4096]u8 = undefined;
    const n = try read.readStreaming(io, &.{&content});
    const text = content[0..n];

    try std.testing.expect(std.mem.indexOf(u8, text, "[INFO ]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[test]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "hello 42") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[ERROR]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "oops") != null);
}

// ============================================
// ModuleLogger
// ============================================

test "module().xxx is no-op when global is null" {
    const saved = logger.global;
    logger.global = null;
    defer logger.global = saved;

    const m = logger.module("x");
    m.trace("a", .{});
    m.debug("b", .{});
    m.info("c", .{});
    m.warn("d", .{});
    m.err("e", .{});
}

test "module().info() writes via global logger" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile(io, "m.log", .{});
    var lg = logger.Logger.init(io, .{ .level = .trace, .file = file, .console_output = false });

    const saved = logger.global;
    logger.global = &lg;
    defer logger.global = saved;

    const m = logger.module("win");
    m.info("opened id={d}", .{1});
    file.close(io);

    var r = try tmp.dir.openFile(io, "m.log", .{});
    defer r.close(io);
    var content: [4096]u8 = undefined;
    const n = try r.readStreaming(io, &.{&content});
    const text = content[0..n];
    try std.testing.expect(std.mem.indexOf(u8, text, "[win]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "opened id=1") != null);
}

test "module().debug() filters out below warn level" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile(io, "f.log", .{});
    var lg = logger.Logger.init(io, .{ .level = .warn, .file = file, .console_output = false });

    const saved = logger.global;
    logger.global = &lg;
    defer logger.global = saved;

    const m = logger.module("x");
    m.debug("below", .{});
    m.warn("passes", .{});
    file.close(io);

    var r = try tmp.dir.openFile(io, "f.log", .{});
    defer r.close(io);
    var content: [4096]u8 = undefined;
    const n = try r.readStreaming(io, &.{&content});
    const text = content[0..n];
    try std.testing.expect(std.mem.indexOf(u8, text, "below") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "passes") != null);
}
