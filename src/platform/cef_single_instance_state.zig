//! Second-instance 공유 argv 전달 state — primary(락 보유)가 받은 argv 를 호스트
//! 콜백으로 디스패치(→ app:second-instance EventBus emit)하고, secondary 가 보낼
//! 자기 argv 를 보관한다. 락(flock/mutex)과 무관한 순수 IPC payload 상태 —
//! 플랫폼 IPC 구현(cef_single_instance_{posix,windows}.zig)이 공유.
//! cef_tray_state.zig / cef_notification_state.zig 선례 동형.
//!
//! 둘 다 startup 에서 1회 설정 후 runtime read → 별도 락 불요(startup-before-runtime).

// 호스트가 등록하는 수신 콜백(받은 argv JSON → EventBus emit) + 이 프로세스가
// secondary 로 보낼 자기 argv(JSON 배열, 호스트가 setLaunchArgv 로 주입).
pub var g_si_cb: ?*const fn (argv: [*:0]const u8) callconv(.c) void = null;
pub var g_argv_buf: [4096]u8 = undefined;
pub var g_argv_len: usize = 0;

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

// 수신한 argv bytes(total)를 NUL-종단해 수신 콜백으로 디스패치. posix_si.acceptLoop
// 와 win_si.serverLoop 공용(플랫폼 무관 — read 원시 함수만 다름).
pub fn dispatchArgv(buf: *[4097]u8, total: usize) void {
    if (total == 0) return;
    buf[total] = 0;
    if (g_si_cb) |cb| cb(@ptrCast(buf));
}
