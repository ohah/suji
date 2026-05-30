//! CEF DevTools helpers — cef.zig 에서 분리(동작 무변경).
//! inspectee 매핑, open/close/toggle, quit/shutdown 정리를 담당한다.
const std = @import("std");
const cef = @import("cef.zig");

const c = cef.c;
const zeroCefStruct = cef.zeroCefStruct;

pub fn devtoolsHost(browser: *c.cef_browser_t) ?*c.cef_browser_host_t {
    return cef.asPtr(c.cef_browser_host_t, browser.get_host.?(browser));
}

pub fn hasDevTools(browser: *c.cef_browser_t) bool {
    const host = devtoolsHost(browser) orelse return false;
    return host.has_dev_tools.?(host) == 1;
}

/// devtools_browser_id → inspectee_browser_id 매핑. F5/Cmd+R DevTools self-reload
/// 회피용 (sender DevTools면 inspectee reload — Electron 호환).
///
/// 흐름:
///   1. openDevTools(inspectee): pending_devtools_inspectee = inspectee.id 저장 후 show_dev_tools 호출
///   2. CEF가 새 DevTools browser 생성 → handleAfterCreated 호출
///   3. handleAfterCreated: pending이 있으면 그 새 browser가 DevTools — map.put + pending=null
///   4. reloadInspecteeOrSelf(sender): map.get(sender_id)이 있으면 inspectee 찾아 reload
///   5. handleBeforeClose(devtools_browser): map.remove(id) — stale 매핑 차단
///
/// CEF는 single UI thread라 race 없음. 멀티 윈도우 동시 DevTools 안전.
var devtools_to_inspectee: std.AutoHashMap(u64, u64) = undefined;
var devtools_map_initialized: bool = false;
var pending_devtools_inspectee: ?u64 = null;

fn ensureDevToolsMap() void {
    if (devtools_map_initialized) return;
    const native = cef.globalNative() orelse return;
    devtools_to_inspectee = std.AutoHashMap(u64, u64).init(native.allocator);
    devtools_map_initialized = true;
}

pub fn lookupDevToolsInspectee(devtools_id: u64) ?u64 {
    if (!devtools_map_initialized) return null;
    return devtools_to_inspectee.get(devtools_id);
}

pub fn openDevTools(browser: *c.cef_browser_t) void {
    const host = devtoolsHost(browser) orelse return;
    if (host.has_dev_tools.?(host) == 1) return; // 이미 열려있으면 멱등 no-op

    var window_info: c.cef_window_info_t = undefined;
    zeroCefStruct(c.cef_window_info_t, &window_info);
    window_info.runtime_style = c.CEF_RUNTIME_STYLE_DEFAULT;

    var settings: c.cef_browser_settings_t = undefined;
    zeroCefStruct(c.cef_browser_settings_t, &settings);

    var point: c.cef_point_t = .{ .x = 0, .y = 0 };
    // 다음 onAfterCreated가 우리가 만들 DevTools browser — 그 시점에 매핑 등록.
    pending_devtools_inspectee = @intCast(browser.get_identifier.?(browser));
    host.show_dev_tools.?(host, &window_info, cef.devtoolsClient(), &settings, &point);
}

pub fn closeDevTools(browser: *c.cef_browser_t) void {
    const host = devtoolsHost(browser) orelse return;
    if (host.has_dev_tools.?(host) != 1) return; // 이미 닫혀있으면 no-op
    // 매핑 정리 + inspectee focus 복귀는 handleBeforeClose가 처리 — close_dev_tools가
    // 비동기라 여기서 즉시 makeKeyAndOrderFront 호출하면 OS의 close-time focus
    // 재할당에 덮어쓰임. DevTools browser의 onBeforeClose 콜백이 close 완료 시점.
    host.close_dev_tools.?(host);
}

pub fn toggleDevTools(browser: *c.cef_browser_t) void {
    if (hasDevTools(browser)) closeDevTools(browser) else openDevTools(browser);
}

pub fn handleAfterCreated(devtools_id: u64) bool {
    if (pending_devtools_inspectee) |inspectee| {
        ensureDevToolsMap();
        devtools_to_inspectee.put(devtools_id, inspectee) catch {};
        pending_devtools_inspectee = null;
        return true;
    }
    return false;
}

pub fn handleBeforeClose(handle: u64) void {
    // DevTools 닫히면 (1) inspectee 창에 키 포커스 복귀, (2) 매핑 제거.
    // makeKey는 다음 런루프 틱에 지연 실행해야 함 — onBeforeClose는 NSWindow close
    // 시퀀스 중간에 호출되고 AppKit이 그 후에도 비동기로 키 창을 재할당해 우리 호출이
    // 덮어써짐. performSelector:withObject:afterDelay:0이 다음 틱에 makeKey 예약.
    if (devtools_map_initialized) {
        if (devtools_to_inspectee.get(handle)) |inspectee_id| {
            if (cef.globalNative()) |native| {
                if (native.browsers.get(inspectee_id)) |entry| {
                    if (entry.ns_window) |ns_win| cef.deferMakeKeyAndOrderFront(ns_win);
                }
            }
        }
        _ = devtools_to_inspectee.remove(handle);
    }
}

pub fn closeMappedDevToolsBeforeQuit() void {
    if (!devtools_map_initialized) return;
    const native = cef.globalNative() orelse return;
    var it = devtools_to_inspectee.iterator();
    while (it.next()) |entry| {
        const be = native.browsers.get(entry.value_ptr.*) orelse continue;
        const host = devtoolsHost(be.browser) orelse continue;
        if (host.has_dev_tools.?(host) == 1) host.close_dev_tools.?(host);
    }
}

pub fn deinitAfterShutdown() void {
    if (devtools_map_initialized) {
        devtools_map_initialized = false;
        devtools_to_inspectee.deinit();
    }
    pending_devtools_inspectee = null;
}
