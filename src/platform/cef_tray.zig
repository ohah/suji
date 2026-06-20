//! Tray API — cef.zig 에서 분리(동작 무변경). NSStatusItem(macOS),
//! GTK StatusIcon(Linux), Shell_NotifyIconW(Windows) 기반 Electron `Tray` 호환 API.
const std = @import("std");
const builtin = @import("builtin");
const cef = @import("cef.zig");
const tray_types = @import("cef_tray_types.zig");
const tray_state = @import("cef_tray_state.zig");
const cef_tray_windows = @import("cef_tray_windows.zig");
const cef_tray_linux = @import("cef_tray_linux.zig");

const is_macos = builtin.os.tag == .macos;
const is_linux = builtin.os.tag == .linux;

const objc = cef.objc;
const getClass = cef.getClass;
const msgSend = cef.msgSend;
const msgSendVoid1 = cef.msgSendVoid1;
const nsStringFromSlice = cef.nsStringFromSlice;
const emptyNSString = cef.emptyNSString;
const menuItemTag = cef.menuItemTag;
const toggleMenuItemState = cef.toggleMenuItemState;
const representedObjectUtf8 = cef.representedObjectUtf8;
const ensureSimpleObjcTarget = cef.ensureSimpleObjcTarget;
const setMenuItemEnabled = cef.setMenuItemEnabled;
const setMenuItemState = cef.setMenuItemState;
const setMenuItemTag = cef.setMenuItemTag;
const createMenu = cef.createMenu;
const addSubmenuItem = cef.addSubmenuItem;
const allocNSMenuItem = cef.allocNSMenuItem;

// ============================================
// Tray API — NSStatusItem / GTK StatusIcon / Shell_NotifyIconW (Electron `Tray`)
// ============================================
// NSStatusBar.systemStatusBar에 statusItem 추가. 메뉴 클릭 시 SujiTrayTarget.trayMenuClick:이
// 호출되고, NSMenuItem.tag(trayId) + representedObject(NSString click name)로 라우팅해
// `tray:menu-click {"trayId":N,"click":"..."}` 이벤트 발화.

pub const TrayMenuItem = tray_types.TrayMenuItem;

const TrayEntry = struct {
    status_item: *anyopaque, // NSStatusItem (retained)
    menu: ?*anyopaque = null, // NSMenu (NSMenuItem retains representedObject NSString)
};

var g_trays: std.AutoHashMap(u32, TrayEntry) = undefined;
var g_trays_initialized: bool = false;
var g_next_tray_id: u32 = 1;
var g_tray_target: ?*anyopaque = null;

fn ensureTraysMap() void {
    if (g_trays_initialized) return;
    const allocator = cef.nativeAllocator() orelse return;
    g_trays = std.AutoHashMap(u32, TrayEntry).init(allocator);
    g_trays_initialized = true;
}

/// SujiTrayTarget ObjC 클래스 + `trayMenuClick:` selector. NSMenuItem의 tag(trayId)와
/// representedObject(NSString click name)를 읽어 EventBus에 emit.
fn ensureTrayTarget() ?*anyopaque {
    return ensureSimpleObjcTarget(&g_tray_target, "SujiTrayTarget", "trayMenuClick:", &trayMenuClickImpl);
}

const TRAY_MENU_CHECKBOX_TAG_BIT: i64 = 1;

fn trayMenuItemTag(tray_id: u32, checkbox: bool) i64 {
    return (@as(i64, @intCast(tray_id)) << 1) | if (checkbox) TRAY_MENU_CHECKBOX_TAG_BIT else 0;
}

fn trayIdFromMenuItemTag(tag: i64) ?u32 {
    if (tag <= 0) return null;
    const tray_id = tag >> 1;
    if (tray_id <= 0) return null;
    return @intCast(tray_id);
}

fn trayMenuTagIsCheckbox(tag: i64) bool {
    return (tag & TRAY_MENU_CHECKBOX_TAG_BIT) != 0;
}

/// NSMenuItem clicked → 이벤트 emit. main.zig가 콜백 등록한 g_event_emit 호출.
fn trayMenuClickImpl(_: ?*anyopaque, _: ?*anyopaque, sender: ?*anyopaque) callconv(.c) void {
    const item = sender orelse return;
    const tag = menuItemTag(item);
    if (tag <= 0) return;
    if (trayMenuTagIsCheckbox(tag)) toggleMenuItemState(item);
    const tray_id = trayIdFromMenuItemTag(tag) orelse return;
    const click_name = representedObjectUtf8(item) orelse return;
    tray_state.emit(tray_id, click_name);
}

/// main.zig가 등록 — tray click → EventBus emit 라우팅.
pub const TrayEmitHandler = tray_state.TrayEmitHandler;

pub fn setTrayEmitHandler(handler: TrayEmitHandler) void {
    tray_state.setTrayEmitHandler(handler);
}

pub const win_tray = cef_tray_windows.win_tray;

/// 새 tray 생성. title/tooltip/iconPath는 빈 문자열이면 미설정.
/// 반환: trayId (failure 시 0).
pub fn createTray(title: []const u8, tooltip: []const u8, icon_path: []const u8) u32 {
    if (comptime builtin.os.tag == .windows) {
        // Windows PoC: title 무시 (system tray 는 보통 icon-only). tooltip 만 적용.
        // 빈 tooltip 이면 title 을 fallback 으로 사용.
        const tip = if (tooltip.len > 0) tooltip else title;
        return win_tray.createIcon(tip, icon_path);
    }
    if (comptime is_linux) return cef_tray_linux.create(title, tooltip, icon_path);
    if (!comptime is_macos) return 0;
    ensureTraysMap();
    if (!g_trays_initialized) return 0;

    const NSStatusBar = getClass("NSStatusBar") orelse return 0;
    const bar = msgSend(NSStatusBar, "systemStatusBar") orelse return 0;
    // NSVariableStatusItemLength = -1
    const lenFn: *const fn (?*anyopaque, ?*anyopaque, f64) callconv(.c) ?*anyopaque =
        @ptrCast(&objc.objc_msgSend);
    const item = lenFn(bar, @ptrCast(objc.sel_registerName("statusItemWithLength:")), -1.0) orelse return 0;
    // NSStatusBar가 retain하지만 명시적으로 한 번 더 retain — NSMenu/NSMenuItem 교체 시 안전.
    _ = msgSend(item, "retain");

    if (title.len > 0) applyTrayTitle(item, title);
    if (tooltip.len > 0) applyTrayTooltip(item, tooltip);
    if (icon_path.len > 0) applyTrayIcon(item, icon_path);

    const id = g_next_tray_id;
    g_next_tray_id += 1;
    g_trays.put(id, .{ .status_item = item }) catch {
        // put 실패 → cleanup
        msgSendVoid1(bar, "removeStatusItem:", item);
        _ = msgSend(item, "release");
        return 0;
    };
    return id;
}

/// statusItem.button.title = title.
fn applyTrayTitle(item: *anyopaque, title: []const u8) void {
    const button = msgSend(item, "button") orelse return;
    const ns = nsStringFromSlice(title) orelse return;
    msgSendVoid1(button, "setTitle:", ns);
}

/// statusItem.button.toolTip = tooltip.
fn applyTrayTooltip(item: *anyopaque, tooltip: []const u8) void {
    const button = msgSend(item, "button") orelse return;
    const ns = nsStringFromSlice(tooltip) orelse return;
    msgSendVoid1(button, "setToolTip:", ns);
}

/// statusItem.button.image = NSImage(contentsOfFile: iconPath).
fn applyTrayIcon(item: *anyopaque, icon_path: []const u8) void {
    const button = msgSend(item, "button") orelse return;
    const img = cef.loadNSImageFromFile(icon_path) orelse return;
    msgSendVoid1(button, "setImage:", img);
}

pub fn setTrayTitle(tray_id: u32, title: []const u8) bool {
    // Windows system tray 는 icon-only — title 은 tooltip 으로 대체 (Electron 패리티
    // 한계: Windows 는 NSStatusItem 의 button title 같은 개념 없음).
    if (comptime builtin.os.tag == .windows) return win_tray.setTooltip(tray_id, title);
    if (comptime is_linux) return cef_tray_linux.setTitle(tray_id, title);
    if (!comptime is_macos) return false;
    if (!g_trays_initialized) return false;
    const entry = g_trays.get(tray_id) orelse return false;
    applyTrayTitle(entry.status_item, title);
    return true;
}

pub fn setTrayTooltip(tray_id: u32, tooltip: []const u8) bool {
    if (comptime builtin.os.tag == .windows) return win_tray.setTooltip(tray_id, tooltip);
    if (comptime is_linux) return cef_tray_linux.setTooltip(tray_id, tooltip);
    if (!comptime is_macos) return false;
    if (!g_trays_initialized) return false;
    const entry = g_trays.get(tray_id) orelse return false;
    applyTrayTooltip(entry.status_item, tooltip);
    return true;
}

/// Electron `tray.getBounds()` — 트레이 아이콘 화면 좌표 rect (top-left origin).
/// macOS: NSStatusItem.button.window.frame 을 Cocoa bottom-left → top-left 변환
/// (y = screenH - frame.y - frame.height). Windows: Shell_NotifyIconGetRect.
/// Linux: gtk_status_icon_get_geometry(X11). 미존재/실패/Wayland 는 0 rect.
fn boundsToNSRect(b: tray_types.Bounds) cef.NSRect {
    return .{ .x = b.x, .y = b.y, .width = b.width, .height = b.height };
}

pub fn trayGetBounds(tray_id: u32) cef.NSRect {
    const empty = cef.NSRect{ .x = 0, .y = 0, .width = 0, .height = 0 };
    if (comptime builtin.os.tag == .windows) return boundsToNSRect(win_tray.getBounds(tray_id) orelse return empty);
    if (comptime is_linux) return boundsToNSRect(cef_tray_linux.getBounds(tray_id) orelse return empty);
    if (!comptime is_macos) return empty;
    if (!g_trays_initialized) return empty;
    const entry = g_trays.get(tray_id) orelse return empty;
    const button = msgSend(entry.status_item, "button") orelse return empty;
    const window = msgSend(button, "window") orelse return empty;
    const frameFn: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) cef.NSRect = @ptrCast(&objc.objc_msgSend);
    const frame = frameFn(window, @ptrCast(objc.sel_registerName("frame")));
    // Cocoa bottom-left → Electron top-left.
    const top_y: f64 = blk: {
        const NSScreen = getClass("NSScreen") orelse break :blk frame.y;
        const mainScreen = msgSend(NSScreen, "mainScreen") orelse break :blk frame.y;
        const screen_frame = frameFn(mainScreen, @ptrCast(objc.sel_registerName("frame")));
        break :blk screen_frame.height - frame.y - frame.height;
    };
    return .{ .x = frame.x, .y = top_y, .width = frame.width, .height = frame.height };
}

/// items 배열로 NSMenu 빌드 + tray에 attach. 기존 menu가 있으면 NSMenuItem.representedObject
/// (NSString) 자동 release (NSMenu deinit 연쇄).
pub fn setTrayMenu(tray_id: u32, items: []const TrayMenuItem) bool {
    if (comptime builtin.os.tag == .windows) return win_tray.setMenu(tray_id, items);
    if (comptime is_linux) return cef_tray_linux.setMenu(tray_id, items);
    if (!comptime is_macos) return false;
    if (!g_trays_initialized) return false;
    const entry_ptr = g_trays.getPtr(tray_id) orelse return false;
    const target = ensureTrayTarget() orelse return false;

    const menu = createTrayNSMenuFromItems("", tray_id, items, target) orelse return false;

    msgSendVoid1(entry_ptr.status_item, "setMenu:", menu);
    // createMenu 는 alloc/init(+1 소유)이고 setMenu: 가 retain 하므로 우리 +1 을 반납한다.
    // 안 하면 setTrayMenu 재호출/destroy 마다 이전 메뉴 트리가 통째로 누수된다(상태 아이템이
    // 단독 소유 → 교체 시 이전 메뉴 dealloc). entry_ptr.menu 는 비소유 참조로 유지.
    _ = msgSend(menu, "release");
    entry_ptr.menu = menu;
    return true;
}

fn createTrayNSMenuFromItems(title: []const u8, tray_id: u32, items: []const TrayMenuItem, target: *anyopaque) ?*anyopaque {
    const menu = createMenu(title) orelse return null;
    for (items) |item| addTrayNSMenuItem(menu, tray_id, item, target);
    return menu;
}

fn addTrayNSMenuItem(menu: *anyopaque, tray_id: u32, item: TrayMenuItem, target: *anyopaque) void {
    switch (item) {
        .separator => {
            const NSMenuItem = getClass("NSMenuItem") orelse return;
            const sep = msgSend(NSMenuItem, "separatorItem") orelse return;
            msgSendVoid1(menu, "addItem:", sep);
        },
        .item => |it| addTrayNSMenuClickable(menu, tray_id, target, it.label, it.click, it.enabled, null),
        .checkbox => |it| addTrayNSMenuClickable(menu, tray_id, target, it.label, it.click, it.enabled, it.checked),
        .submenu => |sub| {
            const submenu = createTrayNSMenuFromItems(sub.label, tray_id, sub.items, target) orelse return;
            const m = addSubmenuItem(menu, sub.label, submenu) orelse return;
            setMenuItemEnabled(m, sub.enabled);
        },
    }
}

fn addTrayNSMenuClickable(menu: *anyopaque, tray_id: u32, target: *anyopaque, label: []const u8, click: []const u8, enabled: bool, checked: ?bool) void {
    const ns_label = nsStringFromSlice(label) orelse return;
    const ns_click = nsStringFromSlice(click) orelse return;
    const m = allocNSMenuItem(ns_label, "trayMenuClick:", emptyNSString() orelse return) orelse return;
    msgSendVoid1(m, "setTarget:", target);
    msgSendVoid1(m, "setRepresentedObject:", ns_click);
    if (checked) |state| {
        setMenuItemTag(m, trayMenuItemTag(tray_id, true));
        setMenuItemState(m, state);
    } else {
        setMenuItemTag(m, trayMenuItemTag(tray_id, false));
    }
    setMenuItemEnabled(m, enabled);
    msgSendVoid1(menu, "addItem:", m);
}

/// tray 제거. NSStatusBar에서 빼고 retain count 해제.
pub fn destroyTray(tray_id: u32) bool {
    if (comptime builtin.os.tag == .windows) return win_tray.destroyIcon(tray_id);
    if (comptime is_linux) return cef_tray_linux.destroy(tray_id);
    if (!comptime is_macos) return false;
    if (!g_trays_initialized) return false;
    const entry = g_trays.get(tray_id) orelse return false;

    const NSStatusBar = getClass("NSStatusBar") orelse return false;
    if (msgSend(NSStatusBar, "systemStatusBar")) |bar| {
        msgSendVoid1(bar, "removeStatusItem:", entry.status_item);
    }
    _ = msgSend(entry.status_item, "release");
    _ = g_trays.remove(tray_id);
    return true;
}
