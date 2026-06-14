//! Win32 message pump thread shared by tray, notification, globalShortcut, and nativeTheme.
const std = @import("std");
const builtin = @import("builtin");

// RegisterHotKey 가 호출-스레드 큐에 WM_HOTKEY 를 post 하므로 hotkey 등록/수신
// 둘 다 같은 스레드여야 한다. CEF UI 스레드는 우리가 점유 못 하니 별도 thread +
// hidden message-only window 를 띄우고:
//   - WM_HOTKEY → globalShortcut emit
//   - WM_TRAY (Shell_NotifyIcon uCallbackMessage) → tray click / right-click 메뉴
//   - WM_COMMAND → tray menu item click
//   - WM_SETTINGCHANGE("ImmersiveColorSet") → nativeTheme:updated emit
pub const win_pump = if (builtin.os.tag == .windows) struct {
    const cef_global_shortcut = @import("cef_global_shortcut.zig");
    const cef_native_theme = @import("cef_native_theme.zig");
    const cef_screen = @import("cef_screen.zig");
    const notification_state = @import("cef_notification_state.zig");
    const notification_windows = @import("cef_notification_windows.zig");
    const cef_tray = @import("cef_tray.zig");
    const gs_state = @import("cef_global_shortcut_state.zig");
    const tray_state = @import("cef_tray_state.zig");

    const WM_HOTKEY: u32 = 0x0312;
    const WM_APP_REQ: u32 = 0x8000 + 1;
    const WM_TRAY: u32 = 0x0400 + 1; // WM_USER + 1
    const WM_COMMAND: u32 = 0x0111;
    const WM_SETTINGCHANGE: u32 = 0x001A;
    const WM_DISPLAYCHANGE: u32 = 0x007E;
    const WM_LBUTTONUP: u32 = 0x0202;
    const WM_RBUTTONUP: u32 = 0x0205;
    const WM_LBUTTONDBLCLK: u32 = 0x0203;
    // Shell_NotifyIcon balloon click — lParam value when the user clicks
    // the balloon body (Win10+ rendered as toast).
    const NIN_BALLOONUSERCLICK: u32 = 0x0405;
    const NIN_BALLOONTIMEOUT: u32 = 0x0404;

    const TPM_RIGHTBUTTON: u32 = 0x0002;

    extern "kernel32" fn CreateThread(lpThreadAttributes: ?*anyopaque, dwStackSize: usize, lpStartAddress: *const anyopaque, lpParameter: ?*anyopaque, dwCreationFlags: u32, lpThreadId: ?*u32) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn CreateEventW(lpEventAttributes: ?*anyopaque, bManualReset: i32, bInitialState: i32, lpName: ?[*:0]const u16) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn SetEvent(hEvent: ?*anyopaque) callconv(.winapi) i32;
    extern "kernel32" fn ResetEvent(hEvent: ?*anyopaque) callconv(.winapi) i32;
    extern "kernel32" fn WaitForSingleObject(hHandle: ?*anyopaque, dwMilliseconds: u32) callconv(.winapi) u32;
    extern "kernel32" fn GetModuleHandleW(lpModuleName: ?[*:0]const u16) callconv(.winapi) ?*anyopaque;
    extern "user32" fn PostThreadMessageW(idThread: u32, Msg: u32, wParam: usize, lParam: isize) callconv(.winapi) i32;
    extern "user32" fn GetMessageW(lpMsg: *MSG, hWnd: ?*anyopaque, wMsgFilterMin: u32, wMsgFilterMax: u32) callconv(.winapi) i32;
    extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(.winapi) i32;
    extern "user32" fn DispatchMessageW(lpMsg: *const MSG) callconv(.winapi) isize;
    extern "user32" fn PeekMessageW(lpMsg: *MSG, hWnd: ?*anyopaque, wMsgFilterMin: u32, wMsgFilterMax: u32, wRemoveMsg: u32) callconv(.winapi) i32;
    extern "user32" fn RegisterClassExW(lpwcx: *const WNDCLASSEXW) callconv(.winapi) u16;
    extern "user32" fn CreateWindowExW(dwExStyle: u32, lpClassName: [*:0]const u16, lpWindowName: [*:0]const u16, dwStyle: u32, X: i32, Y: i32, nWidth: i32, nHeight: i32, hWndParent: ?*anyopaque, hMenu: ?*anyopaque, hInstance: ?*anyopaque, lpParam: ?*anyopaque) callconv(.winapi) ?*anyopaque;
    extern "user32" fn DefWindowProcW(hwnd: ?*anyopaque, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize;
    extern "user32" fn GetCursorPos(lpPoint: *POINT) callconv(.winapi) i32;
    extern "user32" fn SetForegroundWindow(hWnd: ?*anyopaque) callconv(.winapi) i32;
    extern "user32" fn TrackPopupMenu(hMenu: ?*anyopaque, uFlags: u32, x: i32, y: i32, nReserved: i32, hWnd: ?*anyopaque, prcRect: ?*anyopaque) callconv(.winapi) i32;
    pub extern "user32" fn CreatePopupMenu() callconv(.winapi) ?*anyopaque;
    pub extern "user32" fn AppendMenuW(hMenu: ?*anyopaque, uFlags: u32, uIDNewItem: usize, lpNewItem: ?[*:0]const u16) callconv(.winapi) i32;
    pub extern "user32" fn DestroyMenu(hMenu: ?*anyopaque) callconv(.winapi) i32;

    pub const MF_STRING: u32 = 0x0;
    pub const MF_GRAYED: u32 = 0x1;
    pub const MF_CHECKED: u32 = 0x8;
    pub const MF_SEPARATOR: u32 = 0x800;

    // HWND_MESSAGE = (HWND)-3
    const HWND_MESSAGE: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -3))));

    const POINT = extern struct { x: i32 = 0, y: i32 = 0 };
    const MSG = extern struct {
        hwnd: ?*anyopaque = null,
        message: u32 = 0,
        wParam: usize = 0,
        lParam: isize = 0,
        time: u32 = 0,
        pt: POINT = .{},
        lPrivate: u32 = 0,
    };
    const WNDCLASSEXW = extern struct {
        cbSize: u32,
        style: u32,
        lpfnWndProc: *const anyopaque,
        cbClsExtra: i32,
        cbWndExtra: i32,
        hInstance: ?*anyopaque,
        hIcon: ?*anyopaque,
        hCursor: ?*anyopaque,
        hbrBackground: ?*anyopaque,
        lpszMenuName: ?[*:0]const u16,
        lpszClassName: [*:0]const u16,
        hIconSm: ?*anyopaque,
    };

    pub const ReqKind = enum(u32) {
        register,
        unregister,
        unregister_all,
        tray_set_tooltip,
        tray_set_menu,
        tray_destroy_menu,
    };
    pub const Req = extern struct {
        kind: u32 = 0,
        id: i32 = 0,
        mods: u32 = 0,
        vk: u32 = 0,
        tray_id: u32 = 0,
        // Slice-by-pointer; caller-owned, valid until response_event signaled.
        ptr: ?*anyopaque = null,
        len: usize = 0,
        hmenu: ?*anyopaque = null,
        result: i32 = 0,
    };

    var thread_handle: ?*anyopaque = null;
    var thread_id: u32 = 0;
    var ready_event: ?*anyopaque = null;
    var response_event: ?*anyopaque = null;
    var pump_hwnd: ?*anyopaque = null;
    var req_lock: std.atomic.Value(bool) = .init(false);
    var current_req: Req = .{};
    var started: std.atomic.Value(bool) = .init(false);

    fn lock() void {
        while (req_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }
    fn unlock() void {
        req_lock.store(false, .release);
    }

    pub fn pumpHwnd() ?*anyopaque {
        ensureRunning();
        return pump_hwnd;
    }

    // 트레이 메뉴 click_id → (tray_id, click) 매핑. WM_COMMAND 의 wParam 으로 dispatch.
    const MenuClickEntry = struct {
        used: bool = false,
        cmd_id: u32 = 0,
        tray_id: u32 = 0,
        click_buf: [64]u8 = undefined,
        click_len: usize = 0,
    };
    var menu_click_map: [256]MenuClickEntry = [_]MenuClickEntry{.{}} ** 256;
    var next_menu_cmd_id: u32 = 0x1000;

    pub fn assignMenuId(tray_id: u32, click: []const u8) ?u32 {
        if (click.len > 64) return null;
        for (&menu_click_map) |*m| {
            if (!m.used) {
                m.used = true;
                m.cmd_id = next_menu_cmd_id;
                next_menu_cmd_id += 1;
                if (next_menu_cmd_id >= 0x7000) next_menu_cmd_id = 0x1000;
                m.tray_id = tray_id;
                @memcpy(m.click_buf[0..click.len], click);
                m.click_len = click.len;
                return m.cmd_id;
            }
        }
        return null;
    }

    pub fn clearMenuIdsForTray(tray_id: u32) void {
        for (&menu_click_map) |*m| {
            if (m.used and m.tray_id == tray_id) m.* = .{};
        }
    }

    fn wndProc(hwnd: ?*anyopaque, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
        switch (msg) {
            WM_TRAY => {
                const uid: u32 = @truncate(wparam);
                const mouse_msg: u32 = @truncate(@as(usize, @bitCast(lparam)));
                handleTrayCallback(uid, mouse_msg);
                return 0;
            },
            WM_COMMAND => {
                const cmd_id: u32 = @truncate(wparam & 0xFFFF);
                handleMenuCommand(cmd_id);
                return 0;
            },
            WM_SETTINGCHANGE => {
                if (lparam != 0) {
                    const param: [*:0]const u16 = @ptrFromInt(@as(usize, @bitCast(lparam)));
                    const param_slice = std.mem.span(param);
                    const target = std.unicode.utf8ToUtf16LeStringLiteral("ImmersiveColorSet");
                    if (param_slice.len == target.len) {
                        var matches = true;
                        for (param_slice, 0..) |ch, i| {
                            if (ch != target[i]) {
                                matches = false;
                                break;
                            }
                        }
                        if (matches) {
                            if (cef_native_theme.g_native_theme_cb_windows) |cb| cb();
                        }
                    }
                }
                return 0;
            },
            WM_DISPLAYCHANGE => {
                // 모니터 추가/제거/해상도 변경 — cef_screen 이 displayCount count-diff 로
                // add/removed/metrics 구분(WM_SETTINGCHANGE 와 동일 broadcast 메커니즘).
                if (cef_screen.g_screen_cb_windows) |cb| cb();
                return 0;
            },
            else => return DefWindowProcW(hwnd, msg, wparam, lparam),
        }
    }

    fn handleTrayCallback(uid: u32, mouse_msg: u32) void {
        // Balloon click — uid 가 notification tray 면 notification:click emit.
        // 별도 emit handler 가 있으므로 tray click 과 분리.
        if (mouse_msg == NIN_BALLOONUSERCLICK) {
            // copyIdByTrayId 가 lock 안에서 stack buf 로 memcpy → race-free.
            var id_copy: [64]u8 = undefined;
            const id_copy_len = notification_windows.win_notify.copyIdByTrayId(uid, &id_copy);
            if (id_copy_len > 0) {
                notification_state.emit(id_copy[0..id_copy_len]);
            }
            return;
        }
        if (mouse_msg == NIN_BALLOONTIMEOUT) {
            // OS 가 balloon 닫음 — id_map slot 정리 + tray icon NIM_DELETE.
            // destroyIcon 은 pump thread 컨텍스트에서 호출 — e.hmenu == null 인
            // 경우(notification balloon 표준 경로)만 안전. hmenu 가 있으면
            // submitSync 가 자기 자신에게 post → 5s timeout. notification 은 menu
            // 미사용이므로 typical path 는 안전. destroyIconNoMenu 로 명시 분리.
            _ = notification_windows.win_notify.forgetByTrayId(uid);
            _ = cef_tray.win_tray.destroyIconFromPumpThread(uid);
            return;
        }
        var entry: ?*cef_tray.win_tray.Entry = null;
        for (&cef_tray.win_tray.entries) |*e| {
            if (e.used and e.id == uid) {
                entry = e;
                break;
            }
        }
        const e = entry orelse return;
        switch (mouse_msg) {
            WM_RBUTTONUP => {
                if (e.hmenu) |hmenu| {
                    var pt: POINT = .{};
                    _ = GetCursorPos(&pt);
                    _ = SetForegroundWindow(pump_hwnd);
                    _ = TrackPopupMenu(hmenu, TPM_RIGHTBUTTON, pt.x, pt.y, 0, pump_hwnd, null);
                }
            },
            WM_LBUTTONUP, WM_LBUTTONDBLCLK => {
                tray_state.emit(uid, "");
            },
            else => {},
        }
    }

    fn handleMenuCommand(cmd_id: u32) void {
        if (cmd_id == 0) return;
        for (&menu_click_map) |*m| {
            if (m.used and m.cmd_id == cmd_id) {
                tray_state.emit(m.tray_id, m.click_buf[0..m.click_len]);
                return;
            }
        }
    }

    fn pumpEntry(_: ?*anyopaque) callconv(.winapi) u32 {
        // Window class 등록 + hidden message-only window 생성.
        const class_name = std.unicode.utf8ToUtf16LeStringLiteral("SujiPumpWindow");
        const inst = GetModuleHandleW(null);
        var wc: WNDCLASSEXW = .{
            .cbSize = @sizeOf(WNDCLASSEXW),
            .style = 0,
            .lpfnWndProc = &wndProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = inst,
            .hIcon = null,
            .hCursor = null,
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = class_name,
            .hIconSm = null,
        };
        _ = RegisterClassExW(&wc);
        pump_hwnd = CreateWindowExW(0, class_name, class_name, 0, 0, 0, 0, 0, HWND_MESSAGE, null, inst, null);

        // 첫 msg 받기 전에 thread message queue 가 형성되도록 PeekMessage 강제.
        var dummy: MSG = .{};
        _ = PeekMessageW(&dummy, null, WM_APP_REQ, WM_APP_REQ, 0);
        _ = SetEvent(ready_event);
        var msg: MSG = .{};
        while (GetMessageW(&msg, null, 0, 0) > 0) {
            // WM_HOTKEY / WM_APP_REQ 는 thread-queued (hwnd == null).
            if (msg.hwnd == null and msg.message == WM_HOTKEY) {
                const hkid: i32 = @intCast(msg.wParam);
                for (&cef_global_shortcut.win_gs.slots) |*s| {
                    if (s.used and s.id == hkid) {
                        gs_state.emit(s.accel[0..s.accel_len], s.click[0..s.click_len]);
                        break;
                    }
                }
                continue;
            }
            if (msg.hwnd == null and msg.message == WM_APP_REQ) {
                executeReq();
                _ = SetEvent(response_event);
                continue;
            }
            _ = TranslateMessage(&msg);
            _ = DispatchMessageW(&msg);
        }
        return 0;
    }

    fn executeReq() void {
        const kind: ReqKind = @enumFromInt(current_req.kind);
        switch (kind) {
            .register => {
                current_req.result = cef_global_shortcut.win_gs.RegisterHotKey(null, current_req.id, current_req.mods, current_req.vk);
            },
            .unregister => {
                current_req.result = cef_global_shortcut.win_gs.UnregisterHotKey(null, current_req.id);
            },
            .unregister_all => {
                for (&cef_global_shortcut.win_gs.slots) |*s| {
                    if (s.used) _ = cef_global_shortcut.win_gs.UnregisterHotKey(null, s.id);
                }
                current_req.result = 1;
            },
            .tray_set_tooltip => {
                current_req.result = if (cef_tray.win_tray.applyTooltipOnPump(current_req.tray_id, current_req.ptr, current_req.len)) 1 else 0;
            },
            .tray_set_menu => {
                current_req.result = if (cef_tray.win_tray.applyMenuOnPump(current_req.tray_id, current_req.hmenu)) 1 else 0;
            },
            .tray_destroy_menu => {
                if (current_req.hmenu) |hm| _ = DestroyMenu(hm);
                current_req.result = 1;
            },
        }
    }

    /// Idempotent — 첫 호출에 thread + events + window 생성 후 ready 까지 wait.
    pub fn ensureRunning() void {
        if (started.load(.acquire)) return;
        if (started.cmpxchgStrong(false, true, .acq_rel, .monotonic) != null) {
            // 누군가 이미 시작 — ready event 가 signal 될 때까지 wait.
            if (ready_event) |ev| _ = WaitForSingleObject(ev, 2000);
            return;
        }
        ready_event = CreateEventW(null, 1, 0, null) orelse return;
        response_event = CreateEventW(null, 1, 0, null) orelse return;
        thread_handle = CreateThread(null, 0, &pumpEntry, null, 0, &thread_id);
        if (thread_handle == null) return;
        _ = WaitForSingleObject(ready_event, 2000);
    }

    pub const SUBMIT_TIMEOUT: i32 = std.math.minInt(i32); // -2147483648 — caller 식별용 sentinel
    pub const SUBMIT_FAIL: i32 = 0;

    /// Generation counter — current_req 가 timeout 후 pump thread 에 의해 늦게
    /// 처리되더라도, 다음 submitSync 가 신규 generation 으로 마킹하므로 stale
    /// completion 이 새 요청 자리에서 처리되지 않음.
    var req_generation: std.atomic.Value(u64) = .init(0);

    pub fn submitSync(req: Req) i32 {
        ensureRunning();
        if (thread_id == 0) return SUBMIT_FAIL;
        lock();
        defer unlock();
        const my_gen = req_generation.fetchAdd(1, .acq_rel) + 1;
        current_req = req;
        current_req_gen = my_gen;
        _ = ResetEvent(response_event);
        if (PostThreadMessageW(thread_id, WM_APP_REQ, 0, 0) == 0) return SUBMIT_FAIL;
        // 5초 타임아웃 — TrackPopupMenu(우클릭 메뉴) 가 펌프 스레드를 모달로 점유
        // 중일 때 main → pump 요청 INFINITE 대기 시 데드락. 5초 후 graceful
        // timeout — caller 는 SUBMIT_TIMEOUT sentinel 받아 'os_reject' 와 구분.
        const WAIT_TIMEOUT_MS: u32 = 5000;
        const rc = WaitForSingleObject(response_event, WAIT_TIMEOUT_MS);
        if (rc != 0) return SUBMIT_TIMEOUT; // WAIT_OBJECT_0 == 0; 그 외는 timeout/abandoned
        // generation 일치 확인 — 늦은 stale completion 이 우리 generation 으로
        // 잘못 마킹되는 경우 방지 (pump 이전 요청을 늦게 처리하며 current_req 가
        // 우리 요청 데이터로 덮인 후 result 만 stale 일 가능성).
        if (current_req_gen != my_gen) return SUBMIT_FAIL;
        return current_req.result;
    }
    var current_req_gen: u64 = 0;
} else struct {};
