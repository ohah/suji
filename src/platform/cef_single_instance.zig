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
