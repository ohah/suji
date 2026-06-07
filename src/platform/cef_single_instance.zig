//! app.requestSingleInstanceLock — Electron single-instance 락.
//!
//! macOS/Linux: `flock(LOCK_EX|LOCK_NB)` advisory lock on
//!   `<userData>/.suji-single-instance.lock`. primary 가 fd 를 열어둔 채 락을
//!   보유하고, 두 번째 프로세스는 같은 파일 flock 에 EWOULDBLOCK 으로 실패 →
//!   secondary 판정. 프로세스 종료(정상/크래시) 시 커널이 fd 와 함께 락을
//!   자동 해제하므로 stale lock 이 없다(socket .sock 잔존 문제 회피).
//! Windows: named mutex (`CreateMutexW` + `ERROR_ALREADY_EXISTS`).
//!
//! Electron 동등: `requestSingleInstanceLock()` → bool(primary 면 true),
//!   `hasSingleInstanceLock()` → bool, `releaseSingleInstanceLock()` → void.
//!   멱등 — 이미 보유 중이면 request 재호출은 재락 없이 true.
//!
//! second-instance argv 전달(Electron `second-instance` 이벤트)은 별도 IPC
//! (Unix 소켓)가 담당할 후속 작업 — 여기선 락만(역할 분리).
//! 보유 상태는 app 당 단일(Electron 도 프로세스당 하나) → 전역 1개.
//!
//! 스레드 안전: `__core__` cmd 는 프론트(CEF UI 스레드)와 백엔드(Node/Lua/Python
//! 워커 스레드) 양쪽에서 디스패치될 수 있어, request 의 check-then-act + fd/handle
//! 변경을 atomic-bool spinlock 으로 직렬화한다(cef_power_save_blocker 등 선례 동형).
//!
//! 정직 경계: flock 은 advisory + 로컬 FS 가정. userData 가 NFS/네트워크 FS 에
//! 있으면 일부 커널/마운트(nolock)에서 flock 이 no-op 가 될 수 있어 두 인스턴스가
//! 모두 primary 로 판정될 수 있다(Electron 이 Linux 에서 소켓을 쓰는 이유 중 하나).

const std = @import("std");
const builtin = @import("builtin");

const is_windows = builtin.os.tag == .windows;

var g_has_lock: bool = false;
// __core__ 가 여러 스레드에서 호출될 수 있어 request/has/release 의 check-then-act
// 를 직렬화. zig 0.16 std.Thread.Mutex 제거 → cef_* 전역 표준인 atomic-bool
// spinlock(cef_power_save_blocker / cef_dialog_windows_task_dialog 동형). 임계구역이
// flock syscall + bool 설정으로 매우 짧고 호출 빈도도 낮아 스핀 비용 무시 가능.
var g_lock_flag: std.atomic.Value(bool) = .init(false);

fn spinLock() void {
    while (g_lock_flag.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}
fn spinUnlock() void {
    g_lock_flag.store(false, .release);
}

// ---- POSIX (macOS/Linux): flock advisory lock ----
// std.c.open/close/flock = 올바른 per-platform 바인딩(zig 가 variadic ABI 처리).
const posix_impl = if (!is_windows) struct {
    var lock_fd: c_int = -1;

    fn request(path: [*:0]const u8) bool {
        const fd = std.c.open(path, .{ .ACCMODE = .RDWR, .CREAT = true }, @as(std.c.mode_t, 0o600));
        if (fd < 0) return false;
        if (std.c.flock(fd, std.c.LOCK.EX | std.c.LOCK.NB) != 0) {
            _ = std.c.close(fd); // 다른 인스턴스가 보유 → secondary
            return false;
        }
        lock_fd = fd; // fd 를 열어둔 채 유지 = 락 유지
        return true;
    }

    fn release() void {
        if (lock_fd >= 0) {
            _ = std.c.flock(lock_fd, std.c.LOCK.UN);
            _ = std.c.close(lock_fd);
            lock_fd = -1;
        }
    }
} else struct {};

// ---- Windows: named mutex ----
const win_impl = if (is_windows) struct {
    const w = std.os.windows;
    // owner 는 ABI 상 c_int(BOOL) — w.BOOL(Bool(c_int) enum)로 받으면 comptime_int 0
    // 을 못 넘기므로 c_int 로 선언해 0 전달(0 = bInitialOwner FALSE).
    extern "kernel32" fn CreateMutexW(attr: ?*anyopaque, owner: c_int, name: [*:0]const u16) callconv(.winapi) ?w.HANDLE;
    extern "kernel32" fn CloseHandle(h: w.HANDLE) callconv(.winapi) w.BOOL;
    extern "kernel32" fn GetLastError() callconv(.winapi) w.DWORD;
    const ERROR_ALREADY_EXISTS: w.DWORD = 183;

    var mutex: ?w.HANDLE = null;

    fn request(name: [*:0]const u16) bool {
        const h = CreateMutexW(null, 0, name) orelse return false;
        if (GetLastError() == ERROR_ALREADY_EXISTS) {
            _ = CloseHandle(h); // 이미 존재 → secondary
            return false;
        }
        mutex = h;
        return true;
    }

    fn release() void {
        if (mutex) |h| {
            _ = CloseHandle(h);
            mutex = null;
        }
    }
} else struct {};

// ============================================================
// second-instance IPC (PR-B) — macOS/Linux Unix 도메인 소켓.
// primary(락 보유)는 <userData>/.suji-si.sock 에 listen 하며 두 번째 인스턴스가
// 보낸 argv 를 받아 호스트 콜백(→ app:second-instance EventBus emit)으로 넘기고,
// secondary(락 실패)는 그 소켓에 connect 해 자기 argv 를 보낸 뒤 종료(Electron
// second-instance 동등). 락은 flock(PR-A)이 담당 — 소켓은 순수 argv 전달 채널.
// listener 는 프로세스 수명 동안 유지(release 는 flock 만 해제; 소켓 teardown 은
// blocked accept unblock 이 POSIX 상 비결정적이라 생략 — 종료 시 OS 가 회수).
// Windows named pipe 는 후속(PR-B2) — Windows 는 락만(second-instance 이벤트 미발).
// ============================================================

// 호스트가 등록하는 수신 콜백(받은 argv JSON → EventBus emit) + 이 프로세스가
// secondary 로 보낼 자기 argv(JSON 배열, 호스트가 setLaunchArgv 로 주입).
// 둘 다 startup 에서 1회 설정 후 runtime read → 별도 락 불요(startup-before-runtime).
var g_si_cb: ?*const fn (argv: [*:0]const u8) callconv(.c) void = null;
var g_argv_buf: [4096]u8 = undefined;
var g_argv_len: usize = 0;

/// 호스트(main)가 second-instance 수신 콜백 등록. argv 는 null-terminated JSON 배열.
pub fn setSecondInstanceHandler(cb: *const fn (argv: [*:0]const u8) callconv(.c) void) void {
    g_si_cb = cb;
}

/// 이 프로세스가 secondary 가 될 때 primary 로 보낼 argv(JSON 배열 문자열) 저장.
pub fn setLaunchArgv(argv_json: []const u8) void {
    const n = @min(argv_json.len, g_argv_buf.len);
    @memcpy(g_argv_buf[0..n], argv_json[0..n]);
    g_argv_len = n;
}

const posix_si = if (!is_windows) struct {
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

    fn startListener(sock_path: [:0]const u8) void {
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
            if (total > 0) {
                buf[total] = 0;
                if (g_si_cb) |cb| cb(@ptrCast(&buf));
            }
        }
    }

    fn forward(sock_path: [:0]const u8) void {
        var addr: std.c.sockaddr.un = undefined;
        if (!fillAddr(&addr, sock_path)) return;
        const fd = std.c.socket(std.c.AF.UNIX, std.c.SOCK.STREAM, 0);
        if (fd < 0) return;
        defer _ = std.c.close(fd);
        if (std.c.connect(fd, @ptrCast(&addr), @sizeOf(std.c.sockaddr.un)) != 0) return;
        if (g_argv_len > 0) _ = std.c.write(fd, &g_argv_buf, g_argv_len);
    }
} else struct {};

/// Electron app.requestSingleInstanceLock() — primary 면 true, 다른 인스턴스가
/// 이미 보유 중이면 false. 이미 보유 중이면(멱등) true.
/// `user_data_dir` = appGetPath("userData") 결과(POSIX lockfile 위치).
pub fn requestSingleInstanceLock(user_data_dir: []const u8, app_name: []const u8) bool {
    spinLock();
    defer spinUnlock();

    if (g_has_lock) return true; // 이미 보유 (Electron 멱등)
    if (comptime !is_windows) {
        // userData 미해석(예: HOME 부재) — 락 위치를 안전히 정할 수 없다. 루트
        // 상대 경로("/.suji-single-instance.lock") 생성을 피하고, sole instance 가
        // 잘못 quit 하지 않도록 degrade(미강제 = 획득 간주). lock_fd 는 -1 유지.
        if (user_data_dir.len == 0) {
            g_has_lock = true;
            return true;
        }
    }
    if (comptime is_windows) {
        // "Local\suji-single-instance-<app>" — app 의 백슬래시만 '_' 치환
        // (백슬래시는 mutex 네임스페이스 구분자 → prefix 의 "Local\" 는 보존하고
        //  app_name 영역만 치환). 이름 과길이는 bufPrint 가 error → false.
        const prefix = "Local\\suji-single-instance-";
        var name8: [512]u8 = undefined;
        const full = std.fmt.bufPrint(&name8, "{s}{s}", .{ prefix, app_name }) catch return false;
        std.mem.replaceScalar(u8, name8[prefix.len..full.len], '\\', '_');
        var name16: [512]u16 = undefined;
        const n16 = std.unicode.utf8ToUtf16Le(&name16, full) catch return false;
        if (n16 >= name16.len) return false;
        name16[n16] = 0;
        g_has_lock = win_impl.request(@ptrCast(&name16));
    } else {
        var buf: [1100]u8 = undefined;
        const path = std.fmt.bufPrintZ(&buf, "{s}/.suji-single-instance.lock", .{user_data_dir}) catch return false;
        g_has_lock = posix_impl.request(path.ptr);
        // second-instance: primary 는 소켓 listen, secondary 는 자기 argv 전달.
        var sock_buf: [1100]u8 = undefined;
        if (std.fmt.bufPrintZ(&sock_buf, "{s}/.suji-si.sock", .{user_data_dir})) |sock| {
            if (g_has_lock) posix_si.startListener(sock) else posix_si.forward(sock);
        } else |_| {}
    }
    return g_has_lock;
}

/// Electron app.hasSingleInstanceLock() — 이 프로세스가 락을 보유 중인지.
pub fn hasSingleInstanceLock() bool {
    spinLock();
    defer spinUnlock();
    return g_has_lock;
}

/// Electron app.releaseSingleInstanceLock() — 보유 락 해제(없으면 no-op).
pub fn releaseSingleInstanceLock() void {
    spinLock();
    defer spinUnlock();
    if (!g_has_lock) return;
    if (comptime is_windows) win_impl.release() else posix_impl.release();
    g_has_lock = false;
}

// ============================================================
// Unit tests (POSIX) — 메커니즘 검증: 획득/멱등/해제/재획득 + cross-fd 차단
// (cross-fd = 두 번째 open-file-description = 두 번째 프로세스가 겪는 것과 동일).
// ============================================================
const testing = std.testing;

test "single instance: acquire / idempotent / release / re-acquire + cross-fd block" {
    if (is_windows) return error.SkipZigTest; // mutex 는 별도 프로세스 필요 — CI 컴파일 가드만

    // pid 고유 디렉토리로 호스트 격리(동시 test 실행/잔존 프로세스와 충돌 방지).
    // lockfile 이름은 impl 고정이라 디렉토리로 격리. fs Dir API 0.16 churn 회피 위해
    // std.c.mkdir 사용.
    var dir_buf: [64]u8 = undefined;
    const dir = std.fmt.bufPrintZ(&dir_buf, "/tmp/suji-si-test-{d}", .{std.c.getpid()}) catch return error.SkipZigTest;
    _ = std.c.mkdir(dir.ptr, @as(std.c.mode_t, 0o700)); // 이미 있어도 무방
    var lock_buf: [128]u8 = undefined;
    const lock_path = try std.fmt.bufPrintZ(&lock_buf, "{s}/.suji-single-instance.lock", .{dir});

    releaseSingleInstanceLock(); // 전역 상태 초기화(테스트 격리)

    // 1) 최초 획득 → true, has → true.
    try testing.expect(requestSingleInstanceLock(dir, "test-app"));
    try testing.expect(hasSingleInstanceLock());

    // 2) 멱등 — 같은 프로세스 재요청은 재락 없이 true.
    try testing.expect(requestSingleInstanceLock(dir, "test-app"));

    // 3) cross-fd 차단 — 보유 중 같은 lockfile 을 다른 fd 로 직접 flock 시
    //    EWOULDBLOCK(두 번째 프로세스 시나리오와 동일).
    {
        const fd = std.c.open(lock_path.ptr, .{ .ACCMODE = .RDWR }, @as(std.c.mode_t, 0));
        try testing.expect(fd >= 0);
        defer _ = std.c.close(fd);
        try testing.expect(std.c.flock(fd, std.c.LOCK.EX | std.c.LOCK.NB) != 0); // 차단됨
    }

    // 4) 해제 → has false.
    releaseSingleInstanceLock();
    try testing.expect(!hasSingleInstanceLock());

    // 5) 해제 후 같은 lockfile 직접 flock 은 성공해야(락 풀림).
    {
        const fd = std.c.open(lock_path.ptr, .{ .ACCMODE = .RDWR }, @as(std.c.mode_t, 0));
        try testing.expect(fd >= 0);
        defer _ = std.c.close(fd);
        try testing.expect(std.c.flock(fd, std.c.LOCK.EX | std.c.LOCK.NB) == 0); // 획득됨
        _ = std.c.flock(fd, std.c.LOCK.UN);
    }

    // 6) 재획득 → true.
    try testing.expect(requestSingleInstanceLock(dir, "test-app"));
    releaseSingleInstanceLock(); // 테스트 정리
}

test "second-instance: forward → listener → callback (argv 전달)" {
    if (is_windows) return error.SkipZigTest; // POSIX 소켓 (Windows 후속 PR-B2)

    // 수신 콜백 — 받은 argv 를 캡처(다른 스레드에서 발화 → atomic 가시성).
    const Cap = struct {
        var buf: [256]u8 = undefined;
        var len: usize = 0;
        var fired = std.atomic.Value(bool).init(false);
        fn cb(argv: [*:0]const u8) callconv(.c) void {
            const s = std.mem.span(argv);
            const n = @min(s.len, buf.len);
            @memcpy(buf[0..n], s[0..n]);
            len = n;
            fired.store(true, .release);
        }
    };
    setSecondInstanceHandler(&Cap.cb);

    var dir_buf: [64]u8 = undefined;
    const dir = std.fmt.bufPrintZ(&dir_buf, "/tmp/suji-si-test-{d}", .{std.c.getpid()}) catch return error.SkipZigTest;
    _ = std.c.mkdir(dir.ptr, @as(std.c.mode_t, 0o700));
    var sock_buf: [128]u8 = undefined;
    const sock = try std.fmt.bufPrintZ(&sock_buf, "{s}/.suji-si.sock", .{dir});

    posix_si.startListener(sock); // 멱등 — 이미 떠있으면 재사용
    setLaunchArgv("[\"suji\",\"file.txt\"]");
    posix_si.forward(sock); // secondary 시뮬: connect + argv 전송

    // accept 스레드가 읽어 cb 발화할 때까지 스핀 대기(bounded).
    var i: usize = 0;
    while (!Cap.fired.load(.acquire) and i < 50_000_000) : (i += 1) std.atomic.spinLoopHint();
    try testing.expect(Cap.fired.load(.acquire));
    try testing.expectEqualStrings("[\"suji\",\"file.txt\"]", Cap.buf[0..Cap.len]);
}
