const std = @import("std");
const builtin = @import("builtin");
const runtime = @import("runtime");
const logger = @import("logger");
const cef = @import("../platform/cef.zig");

// CEF 디버그 모드(SUJI_CEF_DEBUG)에서 렌더러(샌드박스) 서브프로세스 패닉 사유를
// stderr 핸들로 직출력 — buffered stderr 로 유실되는 케이스 대비(이슈 #60 진단).
pub fn sujiDiagPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    if (builtin.os.tag == .windows and cef.cefDebug()) diagWritePanic(msg);
    std.debug.defaultPanic(msg, first_trace_addr);
}

fn diagWritePanic(msg: []const u8) void {
    const w = std.os.windows;
    const k32 = struct {
        extern "kernel32" fn GetStdHandle(nStdHandle: w.DWORD) callconv(.winapi) w.HANDLE;
        extern "kernel32" fn WriteFile(hFile: w.HANDLE, lpBuffer: [*]const u8, nNumberOfBytesToWrite: w.DWORD, lpNumberOfBytesWritten: ?*w.DWORD, lpOverlapped: ?*anyopaque) callconv(.winapi) w.BOOL;
    };
    // 렌더러는 샌드박스 — 파일 쓰기 차단. stderr 는 inherited handle 이라 허용.
    const STD_ERROR_HANDLE: w.DWORD = @bitCast(@as(i32, -12));
    const h = k32.GetStdHandle(STD_ERROR_HANDLE);
    // stderr 핸들이 없는 서브프로세스는 GetStdHandle 가 NULL(0) 또는
    // INVALID_HANDLE_VALUE 반환 — 둘 다 거른다(WriteFile(NULL) no-op 회피).
    if (h == w.INVALID_HANDLE_VALUE or @intFromPtr(h) == 0) return;
    var hdr_buf: [80]u8 = undefined;
    const hdr = std.fmt.bufPrint(&hdr_buf, "\n[ZIGPANIC pid={d}] ", .{getCurrentPid()}) catch "[ZIGPANIC] ";
    var wrote: w.DWORD = 0;
    _ = k32.WriteFile(h, hdr.ptr, @intCast(hdr.len), &wrote, null);
    _ = k32.WriteFile(h, msg.ptr, @intCast(msg.len), &wrote, null);
    _ = k32.WriteFile(h, "\n", 1, &wrote, null);
}

/// 현재 프로세스 PID — POSIX는 `std.c.getpid()`, Windows는 kernel32.GetCurrentProcessId.
/// Zig 0.16 std.os.windows.kernel32에서 GetCurrentProcessId가 제거돼 extern 직접 선언.
/// std.c.getpid()는 Windows에선 opaque stub(`?*anyopaque`)이라 직접 사용 시 fmt {d} 실패.
pub fn getCurrentPid() i32 {
    if (builtin.os.tag == .windows) {
        const k32 = struct {
            extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) std.os.windows.DWORD;
        };
        return @intCast(k32.GetCurrentProcessId());
    }
    return @intCast(std.c.getpid());
}

/// `~/.suji/logs/` 에 실행별 로그 파일 생성 + 7일 지난 오래된 로그 cleanup.
/// 실패하면 파일 출력 없이 stderr만 사용 (호출자가 error를 삼킴).
pub fn setupLogFile(out_file: *std.Io.File) !void {
    const home = runtime.env("HOME") orelse return error.NoHome;
    var dir_buf: [1024]u8 = undefined;
    const logs_dir_path = try logger.buildLogsDir(&dir_buf, home);
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(runtime.io, logs_dir_path) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };

    // cleanup
    {
        var logs_dir = cwd.openDir(runtime.io, logs_dir_path, .{ .iterate = true }) catch return error.DirOpen;
        defer logs_dir.close(runtime.io);
        const now_ns: i128 = std.Io.Timestamp.now(runtime.io, .real).toNanoseconds();
        logger.cleanupOldLogs(logs_dir, runtime.io, 7, now_ns) catch {};
    }

    // 파일 경로 생성
    const now_ms = std.Io.Timestamp.now(runtime.io, .real).toMilliseconds();
    var fname_buf: [128]u8 = undefined;
    var path_buf: [2048]u8 = undefined;
    var dir_buf2: [1024]u8 = undefined;
    const pid: i32 = getCurrentPid();
    const full_path = try logger.buildLogFilePath(
        .{ .out = &path_buf, .dir = &dir_buf2, .fname = &fname_buf },
        home,
        now_ms,
        pid,
    );
    out_file.* = try cwd.createFile(runtime.io, full_path, .{});
}
