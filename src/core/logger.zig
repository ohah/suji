//! 구조화된 로거 — stderr + 파일 이중 출력, 모듈 태그, 레벨 필터.
//!
//! 설계 목표:
//! - 개발 중: 상세한 실행 흐름 추적 (debug/trace 레벨)
//! - 배포 후: 사용자가 버그 제보할 때 로그 파일 첨부 가능
//!
//! 사용:
//!   const log = @import("logger").module("window");
//!   log.debug("create id={d} title={s}", .{id, title});
//!
//! 경로/수명은 caller(main) 관리:
//!   var file = try opened_by_caller;
//!   var lg = try Logger.init(io, .{ .level = .debug, .file = file });
//!   Logger.global = &lg;
//!
//! 테스트는 file을 tmpDir에서 만들어 직접 주입.

const std = @import("std");

pub const Level = enum(u8) {
    trace = 0,
    debug = 1,
    info = 2,
    warn = 3,
    err = 4,

    pub fn label(self: Level) []const u8 {
        return switch (self) {
            .trace => "TRACE",
            .debug => "DEBUG",
            .info => "INFO ",
            .warn => "WARN ",
            .err => "ERROR",
        };
    }

    /// "debug" | "DEBUG" | "Debug" → .debug. 매칭 실패 시 error.UnknownLevel.
    pub fn parse(name: []const u8) !Level {
        if (eqlIgnoreCase(name, "trace")) return .trace;
        if (eqlIgnoreCase(name, "debug")) return .debug;
        if (eqlIgnoreCase(name, "info")) return .info;
        if (eqlIgnoreCase(name, "warn") or eqlIgnoreCase(name, "warning")) return .warn;
        if (eqlIgnoreCase(name, "err") or eqlIgnoreCase(name, "error")) return .err;
        return error.UnknownLevel;
    }
};

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

pub const Config = struct {
    level: Level = .info,
    /// caller가 이미 연 파일 (null이면 stderr만 사용).
    /// deinit에서 자동 close되지 않으므로 caller가 수명 관리.
    file: ?std.Io.File = null,
};

pub const Logger = struct {
    io: std.Io,
    level: Level,
    file: ?std.Io.File,
    mutex: std.Io.Mutex = .init,

    pub fn init(io: std.Io, config: Config) Logger {
        return .{
            .io = io,
            .level = config.level,
            .file = config.file,
        };
    }

    pub fn setLevel(self: *Logger, level: Level) void {
        self.level = level;
    }

    /// 지정된 레벨이 현재 필터를 통과하는가.
    pub fn enabled(self: *const Logger, level: Level) bool {
        return @intFromEnum(level) >= @intFromEnum(self.level);
    }

    /// 포맷된 메시지 한 줄을 stderr + 파일에 씀.
    /// 호출자는 이미 레벨 체크를 통과한 상태여야 함 (module logger가 처리).
    pub fn write(
        self: *Logger,
        level: Level,
        module_name: []const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        var buf: [4096]u8 = undefined;
        const line = formatLine(&buf, self.io, level, module_name, fmt, args) catch return;

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        std.Io.File.stderr().writeStreamingAll(self.io, line) catch {};
        if (self.file) |f| {
            f.writeStreamingAll(self.io, line) catch {};
        }
    }
};

/// 전역 로거 (main에서 init 후 등록). module logger가 이걸 참조.
pub var global: ?*Logger = null;

/// 모듈 태그 바인딩 — 각 소스 파일에서 `const log = logger.module("이름")`.
pub fn module(comptime name: []const u8) ModuleLogger {
    return .{ .name = name };
}

pub const ModuleLogger = struct {
    name: []const u8,

    pub fn trace(self: ModuleLogger, comptime fmt: []const u8, args: anytype) void {
        self.log(.trace, fmt, args);
    }
    pub fn debug(self: ModuleLogger, comptime fmt: []const u8, args: anytype) void {
        self.log(.debug, fmt, args);
    }
    pub fn info(self: ModuleLogger, comptime fmt: []const u8, args: anytype) void {
        self.log(.info, fmt, args);
    }
    pub fn warn(self: ModuleLogger, comptime fmt: []const u8, args: anytype) void {
        self.log(.warn, fmt, args);
    }
    pub fn err(self: ModuleLogger, comptime fmt: []const u8, args: anytype) void {
        self.log(.err, fmt, args);
    }

    fn log(self: ModuleLogger, level: Level, comptime fmt: []const u8, args: anytype) void {
        const g = global orelse return;
        if (!g.enabled(level)) return;
        g.write(level, self.name, fmt, args);
    }
};

// ============================================
// 포맷 / 파일명 헬퍼 (pure — TDD 가능)
// ============================================

/// `[timestamp] [LEVEL] [module] message\n` 한 줄을 buf에 작성.
/// 반환: buf에 쓰여진 슬라이스 (개행 포함). 버퍼 overflow 시 error.NoSpaceLeft 등.
pub fn formatLine(
    buf: []u8,
    io: std.Io,
    level: Level,
    module_name: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) ![]const u8 {
    const now = std.Io.Timestamp.now(io, .real);
    const ms: i64 = now.toMilliseconds();
    var w = std.Io.Writer.fixed(buf);
    try formatTimestampMs(&w, ms);
    try w.print(" [{s}] [{s}] ", .{ level.label(), module_name });
    try w.print(fmt, args);
    try w.writeByte('\n');
    return w.buffered();
}

/// ISO 8601 `[YYYY-MM-DDTHH:MM:SS.mmmZ]` (UTC). now_ms는 Unix epoch 밀리초.
pub fn formatTimestampMs(w: *std.Io.Writer, now_ms: i64) !void {
    const secs = @divTrunc(now_ms, 1000);
    const ms: u32 = @intCast(@mod(now_ms, 1000));
    const epoch_s: std.time.epoch.EpochSeconds = .{ .secs = @intCast(secs) };
    const ed = epoch_s.getEpochDay();
    const year_day = ed.calculateYearDay();
    const md = year_day.calculateMonthDay();
    const ds = epoch_s.getDaySeconds();
    try w.print(
        "[{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z]",
        .{
            year_day.year,
            md.month.numeric(),
            md.day_index + 1,
            ds.getHoursIntoDay(),
            ds.getMinutesIntoHour(),
            ds.getSecondsIntoMinute(),
            ms,
        },
    );
}

/// `{home}/.suji/logs` 디렉토리 경로를 buf에 작성.
pub fn buildLogsDir(buf: []u8, home: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}/.suji/logs", .{home});
}

/// buildLogFilePath용 caller-provided 버퍼.
pub const PathBuffers = struct {
    out: []u8,
    dir: []u8,
    fname: []u8,
};

/// 로그 파일 전체 경로 작성 — `{home}/.suji/logs/suji-YYYYMMDD-HHMMSS-PID.log`.
/// 내부적으로 buildLogsDir + buildFileName을 조합.
pub fn buildLogFilePath(
    bufs: PathBuffers,
    home: []const u8,
    now_ms: i64,
    pid: i32,
) ![]const u8 {
    const dir = try buildLogsDir(bufs.dir, home);
    const fname = try buildFileName(bufs.fname, now_ms, pid);
    return std.fmt.bufPrint(bufs.out, "{s}/{s}", .{ dir, fname });
}

/// `suji-YYYYMMDD-HHMMSS-PID.log` 파일명 생성.
pub fn buildFileName(buf: []u8, now_ms: i64, pid: i32) ![]const u8 {
    const secs = @divTrunc(now_ms, 1000);
    const epoch_s: std.time.epoch.EpochSeconds = .{ .secs = @intCast(secs) };
    const ed = epoch_s.getEpochDay();
    const year_day = ed.calculateYearDay();
    const md = year_day.calculateMonthDay();
    const ds = epoch_s.getDaySeconds();
    return std.fmt.bufPrint(
        buf,
        "suji-{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}-{d}.log",
        .{
            year_day.year,
            md.month.numeric(),
            md.day_index + 1,
            ds.getHoursIntoDay(),
            ds.getMinutesIntoHour(),
            ds.getSecondsIntoMinute(),
            pid,
        },
    );
}

/// 지정 디렉토리에서 `suji-*.log` 중 mtime이 retention_days 이상 지난 파일 삭제.
/// retention_days=0이면 cleanup 건너뛰고 성공 반환.
pub fn cleanupOldLogs(
    dir: std.Io.Dir,
    io: std.Io,
    retention_days: u32,
    now_ns: i128,
) !void {
    if (retention_days == 0) return;
    const retention_ns: i128 = @as(i128, retention_days) * std.time.ns_per_day;

    // Linux에서 iterate 도중 같은 dir에 openFile/deleteFile을 호출하면 iterator의 fd 상태가
    // 꼬여 BADF panic 발생 (Io.Dir.posixSeekTo). 2-pass로 분리:
    //   1) iterate하며 이름만 수집 (fixed buffer — 과거 로그 수십 개 규모 충분)
    //   2) iterate 끝난 뒤 stat + delete
    var name_buf: [64][std.Io.Dir.max_path_bytes]u8 = undefined;
    var name_lens: [64]usize = undefined;
    var count: usize = 0;

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, "suji-")) continue;
        if (!std.mem.endsWith(u8, entry.name, ".log")) continue;
        if (count >= name_buf.len) break; // 용량 초과 시 안전 중단
        @memcpy(name_buf[count][0..entry.name.len], entry.name);
        name_lens[count] = entry.name.len;
        count += 1;
    }

    for (0..count) |i| {
        const name = name_buf[i][0..name_lens[i]];
        var file = dir.openFile(io, name, .{}) catch continue;
        defer file.close(io);
        const stat = file.stat(io) catch continue;
        const mtime_ns: i128 = stat.mtime.toNanoseconds();
        if (now_ns - mtime_ns > retention_ns) {
            dir.deleteFile(io, name) catch {};
        }
    }
}
