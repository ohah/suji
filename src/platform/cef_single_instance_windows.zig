//! Single-instance Windows 구현 — named mutex(`CreateMutexW` + ERROR_ALREADY_EXISTS,
//! win_impl) + named pipe second-instance IPC(win_si). cef_single_instance.zig 가
//! 플랫폼 라우팅으로 호출. 비-Windows 빌드에선 빈 struct(comptime 분석 제외).
//! 공유 argv state 는 cef_single_instance_state.zig.
//! 정직 경계: Windows 런타임은 CI 빌드(+cross-compile) 검증만 — POSIX(posix_si)와
//! 동형 메커니즘. PIPE_WAIT 블로킹 서버 루프.

const std = @import("std");
const builtin = @import("builtin");
const state = @import("cef_single_instance_state.zig");

const is_windows = builtin.os.tag == .windows;

// ---- Windows: named mutex ----
pub const win_impl = if (is_windows) struct {
    const w = std.os.windows;
    // owner 는 ABI 상 c_int(BOOL) — w.BOOL(Bool(c_int) enum)로 받으면 comptime_int 0
    // 을 못 넘기므로 c_int 로 선언해 0 전달(0 = bInitialOwner FALSE).
    extern "kernel32" fn CreateMutexW(attr: ?*anyopaque, owner: c_int, name: [*:0]const u16) callconv(.winapi) ?w.HANDLE;
    extern "kernel32" fn CloseHandle(h: w.HANDLE) callconv(.winapi) w.BOOL;
    extern "kernel32" fn GetLastError() callconv(.winapi) w.DWORD;
    const ERROR_ALREADY_EXISTS: w.DWORD = 183;

    var mutex: ?w.HANDLE = null;

    pub fn request(name: [*:0]const u16) bool {
        const h = CreateMutexW(null, 0, name) orelse return false;
        if (GetLastError() == ERROR_ALREADY_EXISTS) {
            _ = CloseHandle(h); // 이미 존재 → secondary
            return false;
        }
        mutex = h;
        return true;
    }

    pub fn release() void {
        if (mutex) |h| {
            _ = CloseHandle(h);
            mutex = null;
        }
    }

    // prefix + app_name 을 UTF-16 NUL-종단 이름으로. app_name 의 백슬래시만 '_' 치환
    // (prefix 의 백슬래시는 보존 — mutex 네임스페이스 "Local\" / 파이프 경로 "\\.\pipe\"
    //  구분자). 과길이면 null. mutex 이름과 파이프 이름 빌드에 공용.
    pub fn buildWinNameZ(out8: []u8, out16: []u16, prefix: []const u8, app_name: []const u8) ?[:0]const u16 {
        const full = std.fmt.bufPrint(out8, "{s}{s}", .{ prefix, app_name }) catch return null;
        std.mem.replaceScalar(u8, out8[prefix.len..full.len], '\\', '_');
        const n16 = std.unicode.utf8ToUtf16Le(out16, full) catch return null;
        if (n16 >= out16.len) return null;
        out16[n16] = 0;
        return out16[0..n16 :0];
    }
} else struct {};

// ---- Windows: named pipe (PR-B2) — POSIX Unix 소켓의 Windows 대응 ----
// primary 는 \\.\pipe\suji-si-<app> 서버를 띄워 두 번째 인스턴스의 argv 를 받고,
// secondary 는 그 파이프에 자기 argv 를 쓴 뒤 종료. POSIX posix_si 와 동형 흐름.
// 정직 경계: 이 머신엔 Windows 가 없어 컴파일 검증(gnu+msvc cross-compile)만 — 런타임
// 미검증(Windows CI 빌드 통과 + 메커니즘은 POSIX 와 동형). PIPE_WAIT 블로킹 서버 루프.
pub const win_si = if (is_windows) struct {
    const w = std.os.windows;
    const PIPE_ACCESS_INBOUND: w.DWORD = 0x00000001;
    const PIPE_TYPE_BYTE: w.DWORD = 0x00000000;
    const PIPE_WAIT: w.DWORD = 0x00000000;
    const PIPE_UNLIMITED_INSTANCES: w.DWORD = 255;
    const GENERIC_WRITE: w.DWORD = 0x40000000;
    const OPEN_EXISTING: w.DWORD = 3;
    const ERROR_PIPE_CONNECTED: w.DWORD = 535;
    const ERROR_PIPE_BUSY: w.DWORD = 231;

    // BOOL 반환은 c_int 로 받아 `!= 0` 비교(Bool(c_int) enum 회피 — CreateMutexW 교훈).
    extern "kernel32" fn CreateNamedPipeW(name: [*:0]const u16, open_mode: w.DWORD, pipe_mode: w.DWORD, max_instances: w.DWORD, out_buf: w.DWORD, in_buf: w.DWORD, default_timeout: w.DWORD, sa: ?*anyopaque) callconv(.winapi) w.HANDLE;
    extern "kernel32" fn ConnectNamedPipe(pipe: w.HANDLE, overlapped: ?*anyopaque) callconv(.winapi) c_int;
    extern "kernel32" fn DisconnectNamedPipe(pipe: w.HANDLE) callconv(.winapi) c_int;
    extern "kernel32" fn ReadFile(file: w.HANDLE, buf: [*]u8, n: w.DWORD, read_n: *w.DWORD, overlapped: ?*anyopaque) callconv(.winapi) c_int;
    extern "kernel32" fn WriteFile(file: w.HANDLE, buf: [*]const u8, n: w.DWORD, written: *w.DWORD, overlapped: ?*anyopaque) callconv(.winapi) c_int;
    extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: w.DWORD, share: w.DWORD, sa: ?*anyopaque, disposition: w.DWORD, flags: w.DWORD, template: ?w.HANDLE) callconv(.winapi) w.HANDLE;
    extern "kernel32" fn WaitNamedPipeW(name: [*:0]const u16, timeout: w.DWORD) callconv(.winapi) c_int;
    extern "kernel32" fn CloseHandle(h: w.HANDLE) callconv(.winapi) c_int;
    extern "kernel32" fn GetLastError() callconv(.winapi) w.DWORD;

    var started: bool = false;
    var pipe_name: [256]u16 = undefined; // 서버 스레드가 참조(스레드 수명 = 프로세스).

    pub fn startListener(name16: [:0]const u16) void {
        if (started) return; // 멱등(posix_si 동형)
        if (name16.len + 1 > pipe_name.len) return; // 보관 불가 → IPC 비활성(락은 유효)
        @memcpy(pipe_name[0..name16.len], name16[0..name16.len]);
        pipe_name[name16.len] = 0; // NUL 종단(서버 스레드가 [*:0] 로 참조)
        const t = std.Thread.spawn(.{}, serverLoop, .{}) catch return;
        t.detach();
        started = true;
    }

    fn serverLoop() void {
        const name_ptr: [*:0]const u16 = @ptrCast(&pipe_name);
        // 파이프 인스턴스를 1회 생성 후 Disconnect→재Connect 로 재사용 — 인스턴스가
        // 루프 내내 항상 존재해 recreate gap(POSIX 소켓엔 없는)을 제거. 종료 시 OS 회수.
        const h = CreateNamedPipeW(name_ptr, PIPE_ACCESS_INBOUND, PIPE_TYPE_BYTE | PIPE_WAIT, PIPE_UNLIMITED_INSTANCES, 0, 4096, 0, null);
        if (h == w.INVALID_HANDLE_VALUE) return; // 생성 불가 → second-instance 비활성(락 유효)
        defer _ = CloseHandle(h);
        while (true) {
            // 클라 연결 대기. FALSE 라도 ERROR_PIPE_CONNECTED 면 Connect 전 이미 연결된
            // 정상 케이스. 그 외 실패는 영구 에러로 보고 종료(busy-spin 방지, POSIX 동형).
            if (ConnectNamedPipe(h, null) == 0 and GetLastError() != ERROR_PIPE_CONNECTED) break;
            var buf: [4097]u8 = undefined;
            var total: usize = 0;
            while (total < buf.len - 1) {
                var read_n: w.DWORD = 0;
                if (ReadFile(h, buf[total..].ptr, @intCast(buf.len - 1 - total), &read_n, null) == 0 or read_n == 0) break;
                total += read_n;
            }
            state.dispatchArgv(&buf, total);
            _ = DisconnectNamedPipe(h); // 인스턴스 재사용(다음 클라 위해 — gap 없음)
        }
    }

    pub fn forward(name16: [:0]const u16) void {
        // 단일 인스턴스라 다른 secondary 가 read 중이면 ERROR_PIPE_BUSY → WaitNamedPipe
        // 로 가용 대기 후 재시도(소량 한도 — argv 전달은 best-effort).
        var attempts: u8 = 0;
        while (attempts < 5) : (attempts += 1) {
            const h = CreateFileW(name16.ptr, GENERIC_WRITE, 0, null, OPEN_EXISTING, 0, null);
            if (h != w.INVALID_HANDLE_VALUE) {
                defer _ = CloseHandle(h);
                if (state.g_argv_len > 0) {
                    var written: w.DWORD = 0;
                    _ = WriteFile(h, &state.g_argv_buf, @intCast(state.g_argv_len), &written, null);
                }
                return;
            }
            if (GetLastError() != ERROR_PIPE_BUSY) return; // not-found 등 → 포기
            if (WaitNamedPipeW(name16.ptr, 200) == 0) return; // 타임아웃/에러 → 포기
        }
    }
} else struct {};
