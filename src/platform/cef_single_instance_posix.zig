//! Single-instance POSIX(macOS/Linux) 구현 — `flock(LOCK_EX|LOCK_NB)` advisory
//! lock(posix_impl) + Unix 도메인 소켓 second-instance IPC(posix_si).
//! cef_single_instance.zig 가 플랫폼 라우팅으로 호출. Windows 빌드에선 빈 struct
//! (comptime 분석 제외). 공유 argv state 는 cef_single_instance_state.zig.

const std = @import("std");
const builtin = @import("builtin");
const state = @import("cef_single_instance_state.zig");

const is_windows = builtin.os.tag == .windows;

// ---- POSIX (macOS/Linux): flock advisory lock ----
// std.c.open/close/flock = 올바른 per-platform 바인딩(zig 가 variadic ABI 처리).
pub const posix_impl = if (!is_windows) struct {
    var lock_fd: c_int = -1;

    pub fn request(path: [*:0]const u8) bool {
        const fd = std.c.open(path, .{ .ACCMODE = .RDWR, .CREAT = true }, @as(std.c.mode_t, 0o600));
        if (fd < 0) return false;
        if (std.c.flock(fd, std.c.LOCK.EX | std.c.LOCK.NB) != 0) {
            _ = std.c.close(fd); // 다른 인스턴스가 보유 → secondary
            return false;
        }
        lock_fd = fd; // fd 를 열어둔 채 유지 = 락 유지
        return true;
    }

    pub fn release() void {
        if (lock_fd >= 0) {
            _ = std.c.flock(lock_fd, std.c.LOCK.UN);
            _ = std.c.close(lock_fd);
            lock_fd = -1;
        }
    }
} else struct {};

pub const posix_si = if (!is_windows) struct {
    var listen_fd: c_int = -1;
    // startListener 멱등 가드. release 가 소켓 teardown 을 하지 않아 listener 는 1회
    // spawn 후 프로세스 수명 유지 → 단일 플래그면 충분(shutdown 분기/atomic 불요).
    // requestSingleInstanceLock(spinLock) 하에서만 접근하므로 평이 bool.
    var started: bool = false;

    // sun_path(per-platform: macOS 104 / Linux 108)에 path 채우기. 과길이면 false →
    // IPC 비활성(락은 유효). userData 경로가 sun_path 한도를 넘으면 second-instance
    // 만 비활성(드묾 — deep userData). 길이는 addr.path.len 으로 OS 정확.
    fn fillAddr(addr: *std.c.sockaddr.un, path: []const u8) bool {
        if (path.len >= addr.path.len) return false;
        addr.* = .{ .family = std.c.AF.UNIX, .path = undefined };
        @memset(&addr.path, 0);
        @memcpy(addr.path[0..path.len], path);
        return true;
    }

    pub fn startListener(sock_path: [:0]const u8) void {
        if (started) return; // 이미 listen 중(멱등)
        var addr: std.c.sockaddr.un = undefined;
        if (!fillAddr(&addr, sock_path)) return;
        const fd = std.c.socket(std.c.AF.UNIX, std.c.SOCK.STREAM, 0);
        if (fd < 0) return;
        _ = std.c.unlink(sock_path.ptr); // flock 으로 primary 확정 → 기존 .sock 은 stale
        if (std.c.bind(fd, @ptrCast(&addr), @sizeOf(std.c.sockaddr.un)) != 0) {
            _ = std.c.close(fd);
            return;
        }
        if (std.c.listen(fd, 4) != 0) {
            _ = std.c.close(fd);
            return;
        }
        listen_fd = fd;
        const t = std.Thread.spawn(.{}, acceptLoop, .{}) catch {
            _ = std.c.close(fd);
            listen_fd = -1;
            return;
        };
        t.detach(); // 프로세스 수명 동안 listen — 종료 시 OS 가 fd 회수.
        started = true;
    }

    fn acceptLoop() void {
        while (true) {
            const cfd = std.c.accept(listen_fd, null, null);
            if (cfd < 0) {
                const e = std.c._errno().*;
                // EINTR(시그널)/ECONNABORTED(클라 중도 abort)는 재시도. 그 외 영구
                // 에러(EBADF 등)는 break — busy-spin 방지(listener 종료, 락은 유효).
                if (e == @intFromEnum(std.c.E.INTR) or e == @intFromEnum(std.c.E.CONNABORTED)) continue;
                break;
            }
            // SOCK_STREAM 은 write 가 분할 도착할 수 있어 EOF(secondary 의 close)까지
            // 누적 read. buf[4097] → 송신 최대 g_argv_buf.len(4096) 전부 수용 + null term.
            var buf: [4097]u8 = undefined;
            var total: usize = 0;
            while (total < buf.len - 1) {
                const n = std.c.read(cfd, buf[total..].ptr, buf.len - 1 - total);
                if (n <= 0) break; // EOF(0) 또는 에러(<0)
                total += @intCast(n);
            }
            _ = std.c.close(cfd);
            state.dispatchArgv(&buf, total);
        }
    }

    pub fn forward(sock_path: [:0]const u8) void {
        var addr: std.c.sockaddr.un = undefined;
        if (!fillAddr(&addr, sock_path)) return;
        const fd = std.c.socket(std.c.AF.UNIX, std.c.SOCK.STREAM, 0);
        if (fd < 0) return;
        defer _ = std.c.close(fd);
        if (std.c.connect(fd, @ptrCast(&addr), @sizeOf(std.c.sockaddr.un)) != 0) return;
        if (state.g_argv_len > 0) _ = std.c.write(fd, &state.g_argv_buf, state.g_argv_len);
    }
} else struct {};
