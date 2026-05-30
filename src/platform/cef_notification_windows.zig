//! Windows Shell_NotifyIcon notification backend.

const std = @import("std");
const builtin = @import("builtin");
const cef_tray = @import("cef_tray.zig");

pub const win_notify = if (builtin.os.tag == .windows) struct {
    const NIF_INFO: u32 = 0x10;
    const NIIF_INFO: u32 = 0x01;
    const NIIF_WARNING: u32 = 0x02;
    const NIIF_ERROR: u32 = 0x03;
    const NIIF_NOSOUND: u32 = 0x10;
    const NIM_DELETE: u32 = 0x2;

    const MapEntry = struct {
        used: bool = false,
        id_len: usize = 0,
        id: [64]u8 = [_]u8{0} ** 64,
        tray_id: u32 = 0,
    };
    // 64-slot — Linux notify entries 와 동일 cap. main 스레드(show/close) 와
    // pump 스레드(handleTrayCallback NIN_BALLOONUSERCLICK/TIMEOUT) 가 동시 접근
    // 하므로 spinlock 으로 직렬화.
    var id_map: [64]MapEntry = [_]MapEntry{.{}} ** 64;
    var id_map_lock_flag: std.atomic.Value(bool) = .init(false);

    fn lockIdMap() void {
        while (id_map_lock_flag.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }
    fn unlockIdMap() void {
        id_map_lock_flag.store(false, .release);
    }

    fn rememberMapping(id: []const u8, tray_id: u32) void {
        if (id.len == 0 or id.len > 64) return;
        lockIdMap();
        defer unlockIdMap();
        for (&id_map) |*m| {
            if (m.used and m.id_len == id.len and std.mem.eql(u8, m.id[0..m.id_len], id)) {
                m.tray_id = tray_id;
                return;
            }
        }
        for (&id_map) |*m| {
            if (!m.used) {
                m.used = true;
                m.id_len = id.len;
                @memcpy(m.id[0..id.len], id);
                m.tray_id = tray_id;
                return;
            }
        }
        // 슬롯 부족 (64+ 동시 notification) — close 호출 시 silent fail. 정직 한계.
    }

    fn lookupAndForget(id: []const u8) ?u32 {
        lockIdMap();
        defer unlockIdMap();
        for (&id_map) |*m| {
            if (m.used and m.id_len == id.len and std.mem.eql(u8, m.id[0..m.id_len], id)) {
                const tid = m.tray_id;
                m.* = .{};
                return tid;
            }
        }
        return null;
    }

    /// out_buf 에 id 를 lock 안에서 복사. 반환은 복사된 바이트 수 (0 = miss).
    /// 이전 시그니처(?[]const u8 슬라이스 반환)는 defer unlockIdMap() 이 슬라이스
    /// 리턴 시점에 lock 을 풀어 caller @memcpy 사이에 race window 가 열렸음 —
    /// 다른 스레드가 m.* = .{} 로 zero 하면 caller 가 zero 된 id 복사. out_buf
    /// 패턴은 복사를 lock 안에서 수행해 race 봉쇄.
    pub fn copyIdByTrayId(tray_id: u32, out_buf: []u8) usize {
        lockIdMap();
        defer unlockIdMap();
        for (&id_map) |*m| {
            if (m.used and m.tray_id == tray_id) {
                const n = @min(m.id_len, out_buf.len);
                @memcpy(out_buf[0..n], m.id[0..n]);
                return n;
            }
        }
        return 0;
    }

    /// tray_id 매칭 슬롯 clear. 매칭 = true, 미매칭 = false. lock 안에서 zero.
    pub fn forgetByTrayId(tray_id: u32) bool {
        lockIdMap();
        defer unlockIdMap();
        for (&id_map) |*m| {
            if (m.used and m.tray_id == tray_id) {
                m.* = .{};
                return true;
            }
        }
        return false;
    }

    /// id 별 tray icon 생성 → balloon (NIM_MODIFY + NIF_INFO). show 후
    /// auto-timeout (10초). close 시 NIM_DELETE.
    /// caller 가 같은 id 로 여러 번 show 하면 새 icon 추가 (기존 안 지움).
    pub fn show(id: []const u8, title: []const u8, body: []const u8, silent: bool) bool {
        // 빈 tooltip 으로 tray icon 생성 (notification 전용 — 사용자에게 visible 한 icon
        // 짧게 표시 후 destroy 됨, 실제로는 toast UI 가 주로 보임).
        const tray_id = cef_tray.win_tray.createIcon("", "");
        if (tray_id == 0) return false;
        // tray entry 찾기
        var entry: ?*cef_tray.win_tray.Entry = null;
        for (&cef_tray.win_tray.entries) |*e| {
            if (e.used and e.id == tray_id) {
                entry = e;
                break;
            }
        }
        const e = entry orelse return false;

        var nid: cef_tray.win_tray.NOTIFYICONDATAW = .{};
        nid.cbSize = @sizeOf(cef_tray.win_tray.NOTIFYICONDATAW);
        nid.hWnd = e.hwnd;
        nid.uID = tray_id;
        nid.uFlags = NIF_INFO;
        // szInfo (body), szInfoTitle (title) 채우기 — utf-16 truncate.
        const body_max = nid.szInfo.len - 1;
        const body_src = if (body.len > body_max) body[0..body_max] else body;
        _ = std.unicode.utf8ToUtf16Le(nid.szInfo[0..body_max], body_src) catch {};
        const title_max = nid.szInfoTitle.len - 1;
        const title_src = if (title.len > title_max) title[0..title_max] else title;
        _ = std.unicode.utf8ToUtf16Le(nid.szInfoTitle[0..title_max], title_src) catch {};
        nid.dwInfoFlags = NIIF_INFO;
        if (silent) nid.dwInfoFlags |= NIIF_NOSOUND;
        const ok = cef_tray.win_tray.Shell_NotifyIconW(cef_tray.win_tray.NIM_MODIFY, &nid);
        // balloon 표시 후 icon 은 OS 가 auto-timeout (~10s) — caller 가 close 호출
        // 안 해도 사라짐. 정직: tray entry 는 우리 table 에 남음 (next destroy 까지).
        if (ok == 0) {
            _ = cef_tray.win_tray.destroyIcon(tray_id);
            return false;
        }
        rememberMapping(id, tray_id);
        return true;
    }

    /// id 로 매핑된 tray icon 을 NIM_DELETE 한다. 매핑 없으면 false (auto-timeout 이미 닫힌 경우 포함).
    pub fn close(id: []const u8) bool {
        const tray_id = lookupAndForget(id) orelse return false;
        return cef_tray.win_tray.destroyIcon(tray_id);
    }
} else struct {};
