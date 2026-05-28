//! @suji/plugin-log — rotating file logger.
//!
//! 채널:
//!   log:write       {level, message, context?}        → {ok:true}
//!   log:set_level   {level}                            → {ok:true, level}
//!   log:get_level                                       → {level}
//!   log:read        {lines}                             → {entries:[{ts,level,message,context?}]}
//!   log:set_path    {path}                              → {ok:true, path}
//!   log:get_path                                        → {path}
//!
//! Levels: "trace" < "debug" < "info" < "warn" < "error" < "off".
//! 기본 레벨 = "info" (trace/debug 무시).
//!
//! 파일 동작:
//!   - OS data dir / suji-app/logs/app.log 기본 경로 (Linux $XDG_DATA_HOME,
//!     macOS Library/Application Support, Windows %APPDATA%).
//!   - 단순 rotation: write 시 file size > MAX_BYTES 면 app.log → app.log.1
//!     (기존 app.log.1 삭제 후), 새 app.log 생성. backlog 1 회 보존.
//!   - JSON Lines format (한 줄 = 한 entry). 안전 escape.

const std = @import("std");
const suji = @import("suji");

pub const app = suji.app()
    .named("log")
    .handle("log:write", logWrite)
    .handle("log:set_level", logSetLevel)
    .handle("log:get_level", logGetLevel)
    .handle("log:read", logRead)
    .handle("log:set_path", logSetPath)
    .handle("log:get_path", logGetPath);

// ============================================
// Level
// ============================================

const Level = enum(u8) {
    trace = 0,
    debug = 1,
    info = 2,
    warn = 3,
    err = 4,
    off = 5,

    fn name(self: Level) []const u8 {
        return switch (self) {
            .trace => "trace",
            .debug => "debug",
            .info => "info",
            .warn => "warn",
            .err => "error",
            .off => "off",
        };
    }

    fn parse(s: []const u8) ?Level {
        if (std.mem.eql(u8, s, "trace")) return .trace;
        if (std.mem.eql(u8, s, "debug")) return .debug;
        if (std.mem.eql(u8, s, "info")) return .info;
        if (std.mem.eql(u8, s, "warn")) return .warn;
        if (std.mem.eql(u8, s, "error")) return .err;
        if (std.mem.eql(u8, s, "off")) return .off;
        return null;
    }
};

// ============================================
// Logger 상태
// ============================================

var gpa: std.heap.DebugAllocator(.{}) = .init;
const alloc = gpa.allocator();

fn pluginIo() std.Io {
    return suji.io();
}

const MAX_BYTES: u64 = 10 * 1024 * 1024; // 10MB → rotate
const READ_LIMIT: usize = 16 * 1024 * 1024; // 16MB read cap

var logger: Logger = .{};

const Logger = struct {
    mutex: std.Io.Mutex = .init,
    level: Level = .info,
    path: ?[]const u8 = null,
    initialized: bool = false,
    dir_created: bool = false,

    fn ensureInit(self: *Logger) void {
        self.mutex.lockUncancelable(pluginIo());
        defer self.mutex.unlock(pluginIo());
        if (self.initialized) return;
        self.initialized = true;
        self.path = defaultLogPath();
    }

    fn write(self: *Logger, level: Level, message: []const u8, context_json: ?[]const u8) bool {
        self.ensureInit();
        self.mutex.lockUncancelable(pluginIo());
        defer self.mutex.unlock(pluginIo());

        if (@intFromEnum(level) < @intFromEnum(self.level)) return true; // level filter
        if (self.level == .off) return true;

        const path = self.path orelse return false;
        self.ensureDirUnlocked(path);
        self.rotateIfNeededUnlocked(path);

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(alloc);
        const ts_ms: i64 = wallClockMs();
        // {ts:N, level:"info", message:"...", context:{...}}
        buf.print(alloc, "{{\"ts\":{d},\"level\":\"{s}\",\"message\":\"", .{ ts_ms, level.name() }) catch return false;
        appendJsonEscaped(&buf, message) catch return false;
        buf.appendSlice(alloc, "\"") catch return false;
        if (context_json) |ctx| {
            if (ctx.len > 0) {
                buf.appendSlice(alloc, ",\"context\":") catch return false;
                buf.appendSlice(alloc, ctx) catch return false;
            }
        }
        buf.appendSlice(alloc, "}\n") catch return false;

        const io = pluginIo();
        // 신규 생성 분기 — 새 파일이면 offset=0 안전 (overwrite 위험 없음).
        var file: std.Io.File = undefined;
        var fresh = false;
        if (std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write })) |f| {
            file = f;
        } else |_| {
            file = std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false }) catch return false;
            fresh = true;
        }
        defer file.close(io);
        // Zig 0.16 의 File 은 seek 없음 — writePositionalAll(offset) 으로 append.
        // 기존 파일은 length 실패시 overwrite 방지 위해 entry skip (1줄 lose vs
        // 전체 파일 lose). 신규 파일은 길이 0 명시.
        const offset: u64 = if (fresh) 0 else (file.length(io) catch return false);
        file.writePositionalAll(io, buf.items, offset) catch return false;
        return true;
    }

    fn ensureDirUnlocked(self: *Logger, path: []const u8) void {
        if (self.dir_created) return;
        if (std.mem.lastIndexOfAny(u8, path, "/\\")) |sep| {
            std.Io.Dir.cwd().createDirPath(pluginIo(), path[0..sep]) catch {};
        }
        self.dir_created = true;
    }

    /// File size > MAX_BYTES → app.log → app.log.1 (.1 삭제 후). 단일 backlog.
    fn rotateIfNeededUnlocked(self: *Logger, path: []const u8) void {
        _ = self;
        const io = pluginIo();
        const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return;
        if (stat.size < MAX_BYTES) return;
        const rotated = std.fmt.allocPrint(alloc, "{s}.1", .{path}) catch return;
        defer alloc.free(rotated);
        std.Io.Dir.cwd().deleteFile(io, rotated) catch {};
        std.Io.Dir.cwd().rename(path, std.Io.Dir.cwd(), rotated, io) catch {};
    }

    fn setLevel(self: *Logger, l: Level) void {
        self.mutex.lockUncancelable(pluginIo());
        defer self.mutex.unlock(pluginIo());
        self.level = l;
    }

    fn getLevel(self: *Logger) Level {
        self.mutex.lockUncancelable(pluginIo());
        defer self.mutex.unlock(pluginIo());
        return self.level;
    }

    /// 최근 N lines 반환 (caller free). path 부재 시 빈 array.
    fn readTail(self: *Logger, arena: std.mem.Allocator, n: usize) ?[]const u8 {
        self.ensureInit();
        self.mutex.lockUncancelable(pluginIo());
        defer self.mutex.unlock(pluginIo());
        const path = self.path orelse return arena.dupe(u8, "{\"entries\":[]}") catch null;

        const io = pluginIo();
        const content = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(READ_LIMIT)) catch {
            return arena.dupe(u8, "{\"entries\":[]}") catch null;
        };

        // 끝에서부터 line break 카운트 → 최근 N 줄 슬라이스. 파일이 newline 으로
        // 끝나지 않으면 마지막 line(trailing fragment) 도 1 line 으로 셈.
        const has_trailing_newline = content.len > 0 and content[content.len - 1] == '\n';
        var start: usize = content.len;
        var count: usize = if (has_trailing_newline) 0 else 1; // trailing fragment seed
        var i: usize = content.len;
        while (i > 0) : (i -= 1) {
            if (content[i - 1] == '\n') {
                count += 1;
                if (count > n) {
                    start = i;
                    break;
                }
            }
        }
        if (count <= n) start = 0;
        const tail = content[start..];

        // {"entries":[<line1>,<line2>,...]} 형식 — 각 line 이 이미 JSON.
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(arena);
        out.appendSlice(arena, "{\"entries\":[") catch return null;
        var first = true;
        var line_start: usize = 0;
        var idx: usize = 0;
        while (idx < tail.len) : (idx += 1) {
            if (tail[idx] == '\n') {
                if (idx > line_start) {
                    if (!first) out.appendSlice(arena, ",") catch return null;
                    out.appendSlice(arena, tail[line_start..idx]) catch return null;
                    first = false;
                }
                line_start = idx + 1;
            }
        }
        if (line_start < tail.len) {
            if (!first) out.appendSlice(arena, ",") catch return null;
            out.appendSlice(arena, tail[line_start..]) catch return null;
        }
        out.appendSlice(arena, "]}") catch return null;
        return out.toOwnedSlice(arena) catch null;
    }

    fn setPath(self: *Logger, new_path: []const u8) bool {
        self.mutex.lockUncancelable(pluginIo());
        defer self.mutex.unlock(pluginIo());
        const owned = alloc.dupe(u8, new_path) catch return false;
        if (self.path) |old| alloc.free(old);
        self.path = owned;
        self.dir_created = false; // 새 경로의 dir 다시 보장
        // 사용자가 ensureInit 전에 setPath 호출하는 race 봉쇄 — ensureInit 가
        // initialized=false 면 defaultLogPath 로 overwrite 하므로 우리 path 손실.
        // setPath 자체가 명시 초기화 — initialized=true 로 마킹.
        self.initialized = true;
        return true;
    }

    fn getPath(self: *Logger) ?[]const u8 {
        self.ensureInit();
        self.mutex.lockUncancelable(pluginIo());
        defer self.mutex.unlock(pluginIo());
        return self.path;
    }
};

// ============================================
// Helpers
// ============================================

/// Unix epoch wall-clock ms. Zig 0.16 의 std.time 이 milliTimestamp 제거 → OS native.
fn wallClockMs() i64 {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) {
        const k32 = struct {
            extern "kernel32" fn GetSystemTimeAsFileTime(lp: *u64) callconv(.winapi) void;
        };
        var ft: u64 = 0;
        k32.GetSystemTimeAsFileTime(&ft);
        // FILETIME = 100ns units since 1601-01-01 UTC. Unix epoch 1970-01-01 차이
        // = 11644473600 sec = 116_444_736_000_000_000 (100ns units).
        const unix_100ns: u64 = ft -% 116_444_736_000_000_000;
        return @intCast(@divTrunc(unix_100ns, 10_000));
    }
    // POSIX: clock_gettime(CLOCK_REALTIME) → seconds + nanoseconds.
    var ts: std.posix.timespec = undefined;
    switch (std.posix.errno(std.posix.system.clock_gettime(.REALTIME, &ts))) {
        .SUCCESS => return @as(i64, @intCast(ts.sec)) * 1000 + @as(i64, @intCast(@divTrunc(ts.nsec, 1_000_000))),
        else => return 0,
    }
}

fn appendJsonEscaped(buf: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(alloc, "\\\""),
            '\\' => try buf.appendSlice(alloc, "\\\\"),
            '\n' => try buf.appendSlice(alloc, "\\n"),
            '\r' => try buf.appendSlice(alloc, "\\r"),
            '\t' => try buf.appendSlice(alloc, "\\t"),
            0...8, 11, 12, 14...31 => {
                var tmp: [6]u8 = undefined;
                const out = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c}) catch continue;
                try buf.appendSlice(alloc, out);
            },
            else => try buf.append(alloc, c),
        }
    }
}

fn cGetenv(name: [*:0]const u8) ?[]const u8 {
    const raw = std.c.getenv(name) orelse return null;
    return std.mem.span(raw);
}

fn defaultLogPath() ?[]const u8 {
    const builtin = @import("builtin");
    if (builtin.os.tag == .macos) {
        const home = cGetenv("HOME") orelse return null;
        return std.fmt.allocPrint(alloc, "{s}/Library/Application Support/suji-app/logs/app.log", .{home}) catch null;
    } else if (builtin.os.tag == .linux) {
        if (cGetenv("XDG_DATA_HOME")) |dir| {
            return std.fmt.allocPrint(alloc, "{s}/suji-app/logs/app.log", .{dir}) catch null;
        }
        const home = cGetenv("HOME") orelse return null;
        return std.fmt.allocPrint(alloc, "{s}/.local/share/suji-app/logs/app.log", .{home}) catch null;
    } else if (builtin.os.tag == .windows) {
        const appdata = cGetenv("APPDATA") orelse return null;
        return std.fmt.allocPrint(alloc, "{s}\\suji-app\\logs\\app.log", .{appdata}) catch null;
    }
    return null;
}

// ============================================
// 핸들러
// ============================================

fn logWrite(req: suji.Request, _: suji.InvokeEvent) suji.Response {
    const level_str = req.string("level") orelse "info";
    const level = Level.parse(level_str) orelse .info;
    const message = req.string("message") orelse "";
    const context_json = suji.extractJsonValue(req.raw, "context");
    _ = logger.write(level, message, context_json);
    return req.okRaw("{\"ok\":true}");
}

fn logSetLevel(req: suji.Request, _: suji.InvokeEvent) suji.Response {
    const level_str = req.string("level") orelse return req.err("missing level");
    const level = Level.parse(level_str) orelse return req.err("invalid level");
    logger.setLevel(level);
    const body = std.fmt.allocPrint(req.arena, "{{\"ok\":true,\"level\":\"{s}\"}}", .{level.name()}) catch return req.err("alloc");
    return req.okRaw(body);
}

fn logGetLevel(req: suji.Request, _: suji.InvokeEvent) suji.Response {
    const level = logger.getLevel();
    const body = std.fmt.allocPrint(req.arena, "{{\"level\":\"{s}\"}}", .{level.name()}) catch return req.err("alloc");
    return req.okRaw(body);
}

fn logRead(req: suji.Request, _: suji.InvokeEvent) suji.Response {
    const lines_raw = req.string("lines") orelse "100";
    const lines = std.fmt.parseInt(usize, lines_raw, 10) catch 100;
    const capped = @min(lines, 10000);
    const result = logger.readTail(req.arena, capped) orelse return req.err("read");
    return req.okRaw(result);
}

fn logSetPath(req: suji.Request, _: suji.InvokeEvent) suji.Response {
    const path = req.string("path") orelse return req.err("missing path");
    if (path.len == 0 or path.len > 4096) return req.err("invalid path");
    if (!logger.setPath(path)) return req.err("alloc");
    const body = std.fmt.allocPrint(req.arena, "{{\"ok\":true,\"path\":\"", .{}) catch return req.err("alloc");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(req.arena);
    out.appendSlice(req.arena, body) catch return req.err("alloc");
    appendJsonEscaped(&out, path) catch return req.err("alloc");
    out.appendSlice(req.arena, "\"}") catch return req.err("alloc");
    const final = out.toOwnedSlice(req.arena) catch return req.err("alloc");
    return req.okRaw(final);
}

fn logGetPath(req: suji.Request, _: suji.InvokeEvent) suji.Response {
    const path = logger.getPath() orelse "";
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(req.arena);
    out.appendSlice(req.arena, "{\"path\":\"") catch return req.err("alloc");
    appendJsonEscaped(&out, path) catch return req.err("alloc");
    out.appendSlice(req.arena, "\"}") catch return req.err("alloc");
    const final = out.toOwnedSlice(req.arena) catch return req.err("alloc");
    return req.okRaw(final);
}

comptime {
    _ = suji.exportApp(app);
}
