//! CEF keyboard handler — cef.zig 에서 분리(동작 무변경).
//! Electron 호환 단축키를 sender browser 기준으로 처리한다.
const std = @import("std");
const cef = @import("cef.zig");

const c = cef.c;
const zeroCefStruct = cef.zeroCefStruct;
const initBaseRefCounted = cef.initBaseRefCounted;

// ============================================
// CEF Keyboard Handler (Electron 호환 단축키)
// ============================================
// Cmd+Shift+I / F12  — DevTools
// Cmd+R              — Reload
// Cmd+Shift+R        — Hard Reload (캐시 무시)
// Cmd+W              — 창 닫기
// Cmd+Q              — 앱 종료
// Cmd+Plus/Minus/0   — 줌 인/아웃/리셋
// Cmd+[ / ]          — 뒤로/앞으로

var g_keyboard_handler: c.cef_keyboard_handler_t = undefined;
var g_keyboard_handler_initialized: bool = false;

pub fn initKeyboardHandler() void {
    if (g_keyboard_handler_initialized) return;
    zeroCefStruct(c.cef_keyboard_handler_t, &g_keyboard_handler);
    initBaseRefCounted(&g_keyboard_handler.base);
    g_keyboard_handler.on_pre_key_event = &onPreKeyEvent;
    g_keyboard_handler_initialized = true;
}

pub fn getKeyboardHandler(_: ?*c._cef_client_t) callconv(.c) ?*c._cef_keyboard_handler_t {
    return &g_keyboard_handler;
}

fn onPreKeyEvent(
    _: ?*c._cef_keyboard_handler_t,
    browser: ?*c._cef_browser_t,
    event: ?*const c.cef_key_event_t,
    _: c.cef_event_handle_t,
    is_keyboard_shortcut: ?*i32,
) callconv(.c) i32 {
    const ev = event orelse return 0;
    const br = browser orelse return 0;

    // RawKeyDown만 처리
    if (ev.type != c.KEYEVENT_RAWKEYDOWN) return 0;

    const cmd = (ev.modifiers & c.EVENTFLAG_COMMAND_DOWN) != 0;
    const shift = (ev.modifiers & c.EVENTFLAG_SHIFT_DOWN) != 0;
    const alt = (ev.modifiers & c.EVENTFLAG_ALT_DOWN) != 0;
    const key = ev.windows_key_code;

    // F12 / Cmd+Shift+I / Cmd+Option+I — DevTools 토글.
    const is_devtools_key = (key == 123) or (cmd and key == 'I' and (shift or alt));
    if (is_devtools_key) {
        markShortcut(is_keyboard_shortcut);
        // sender가 DevTools front-end면 recursive open(=DevTools의 DevTools) 차단 +
        // 사용자 의도 = "DevTools 닫기" → inspectee.host.close_dev_tools.
        const sender_id: u64 = @intCast(br.get_identifier.?(br));
        if (cef.lookupDevToolsInspectee(sender_id)) |inspectee_id| {
            if (cef.globalNative()) |native| {
                if (native.browsers.get(inspectee_id)) |entry| cef.closeDevTools(entry.browser);
            }
            return 1;
        }
        cef.toggleDevTools(br);
        return 1;
    }

    // F5 / Shift+F5 — Reload (Electron 호환, DevTools 안에서 누르면 inspectee reload).
    if (key == 116) {
        markShortcut(is_keyboard_shortcut);
        reloadInspecteeOrSelf(br, shift);
        return 1;
    }

    if (!cmd) return 0;

    // Cmd+R — Reload (DevTools 안이면 inspectee reload — Electron 호환).
    if (key == 'R' and !shift) {
        markShortcut(is_keyboard_shortcut);
        reloadInspecteeOrSelf(br, false);
        return 1;
    }

    // Cmd+Shift+R — Hard Reload (cache 무시).
    if (key == 'R' and shift) {
        markShortcut(is_keyboard_shortcut);
        reloadInspecteeOrSelf(br, true);
        return 1;
    }

    // Cmd+W — 네이티브로 창을 닫지 않고 DOM 으로 양보한다. 탭 기반 앱은 cmd+W 를 "탭 닫기"로
    // 쓰고 싶어 하는데, 여기서 창을 닫아 버리면 앱 단축키를 가린다. cmd+D 등과 동일하게 아래
    // 기본 처리(is_keyboard_shortcut 마킹 후 return 0)로 흘려보내 renderer(DOM)가 받게 한다.
    // 창을 닫고 싶은 앱은 DOM 에서 처리하지 않거나 명시적으로 window close API 를 호출하면 된다.
    // (cmd+Shift+W 는 애초에 여기서 처리하지 않아 이미 DOM 으로 전달된다.)

    // Cmd+Q — 앱 종료. 일반적으로는 NSApp 메뉴 key equivalent가 먼저 매치되어
    // SujiQuitTarget.sujiQuit:이 발화 → 여긴 도달 X. 폴백으로 동일 quit() 호출.
    if (key == 'Q') {
        cef.quit();
        return 1;
    }

    // Cmd+Plus (=+) — 줌 인
    if (key == 187 or key == '+' or key == '=') {
        cef.zoomChange(br, 0.5);
        return 1;
    }

    // Cmd+Minus — 줌 아웃
    if (key == 189 or key == '-') {
        cef.zoomChange(br, -0.5);
        return 1;
    }

    // Cmd+0 — 줌 리셋
    if (key == '0') {
        cef.zoomSet(br, 0.0);
        return 1;
    }

    // Cmd+[ — 뒤로. 단 히스토리가 있을 때만 소비한다. 히스토리가 없는 앱(예: 단일 화면
    // SPA)에서는 가로채지 않고 아래 기본 처리로 흘려보낸다 → cmd+D 등 다른 Cmd 단축키와
    // 똑같은 경로(is_keyboard_shortcut 마킹 후 return 0)로 renderer(DOM)에 전달되어 앱이
    // 자체 단축키로 쓸 수 있다(앱 포커스 중에만 — onPreKeyEvent 스코프).
    if (key == 219 and br.can_go_back.?(br) != 0) { // VK_OEM_4 = [
        br.go_back.?(br);
        return 1;
    }

    // Cmd+] — 앞으로. 동일하게 히스토리가 있을 때만 소비하고, 없으면 DOM 으로 양보한다.
    if (key == 221 and br.can_go_forward.?(br) != 0) { // VK_OEM_6 = ]
        br.go_forward.?(br);
        return 1;
    }

    // 나머지 Cmd 단축키(히스토리 없는 cmd+[/], 그리고 C/V/X/A/Z)는 기본 처리로:
    // is_keyboard_shortcut 마킹 후 return 0 → macOS Edit 메뉴 / DOM 으로 전달.
    if (is_keyboard_shortcut) |ks| ks.* = 1;
    return 0;
}

/// CEF에 "이 키는 keyboard shortcut이라 default browser command 발동 막아라" 알림.
/// OnPreKeyEvent return 1만으로는 CEF가 자체 reload(Cmd+R) 같은 default 처리를
/// 별도로 발동시킬 수 있어 우리 헬퍼와 충돌 가능. is_keyboard_shortcut.* = 1로 차단.
fn markShortcut(is_keyboard_shortcut: ?*i32) void {
    if (is_keyboard_shortcut) |sc| sc.* = 1;
}

/// reload 키(F5/Cmd+R)는 sender browser를 reload하는 게 기본인데, sender가 DevTools
/// front-end면 self-reload되어 inspectee(개발자가 진짜 reload하고 싶은 페이지)는
/// 변동 없음. 이 함수가 sender가 BrowserEntry에 등록된(= 사용자 창)인지 보고:
///   - 등록됨: sender 그대로 reload (일반 동작)
///   - 미등록(DevTools 추정) + g_devtools_inspectee 있음: inspectee reload (Electron 호환)
///   - 미등록 + 매핑 없음: sender reload (fallback — silent fail X)
fn reloadInspecteeOrSelf(sender: *c.cef_browser_t, ignore_cache: bool) void {
    const target = blk: {
        const sender_id: u64 = @intCast(sender.get_identifier.?(sender));
        // sender가 DevTools면 그 DevTools의 inspectee browser 찾아 reload.
        // 멀티 윈도우 동시 DevTools라도 정확한 매핑.
        if (cef.lookupDevToolsInspectee(sender_id)) |inspectee_id| {
            if (cef.globalNative()) |native| {
                if (native.browsers.get(inspectee_id)) |entry| break :blk entry.browser;
            }
        }
        break :blk sender;
    };
    if (ignore_cache) {
        const fn_ptr = target.reload_ignore_cache orelse return;
        fn_ptr(target);
    } else {
        const fn_ptr = target.reload orelse return;
        fn_ptr(target);
    }
}
