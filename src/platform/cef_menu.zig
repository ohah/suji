//! Application Menu API — cef.zig 에서 분리(동작 무변경). macOS NSMenu
//! application/context menu + Linux GTK context menu backend.
const builtin = @import("builtin");
const linux_context_menu = @import("cef_menu_linux.zig");
const menu_types = @import("cef_menu_types.zig");
const cef = @import("cef.zig");

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
const createMenu = cef.createMenu;
const addDefaultAppMenu = cef.addDefaultAppMenu;
const addSubmenuItem = cef.addSubmenuItem;
const allocNSMenuItem = cef.allocNSMenuItem;
const setMenuItemEnabled = cef.setMenuItemEnabled;
const setMenuItemState = cef.setMenuItemState;
const setMenuItemTag = cef.setMenuItemTag;
const setupMainMenu = cef.setupMainMenu;
const NSPoint = cef.NSPoint;
const screenGetCursorPoint = cef.screenGetCursorPoint;

// ============================================
// Application Menu API — native app menu / popup customization
// ============================================
// macOS 메뉴바 커스터마이즈. App 메뉴(Quit/Hide 등)는 macOS 관례와 종료 라우팅을 위해
// 프레임워크가 유지하고, caller가 전달한 top-level 메뉴를 그 뒤에 붙인다.
// Linux는 앱 메뉴바 대신 programmatic context menu(`menu.popup`)만 GTK로 제공한다.
//
// 클릭 시 SujiAppMenuTarget.appMenuClick:이 representedObject(NSString click name)를 읽어
// `menu:click {"click":"..."}` 이벤트를 발화한다. checkbox는 클릭 시 state를 토글한다.

pub const ApplicationMenuItem = menu_types.ApplicationMenuItem;
pub const MenuEmitHandler = menu_types.MenuEmitHandler;
var g_menu_emit_handler: ?MenuEmitHandler = null;
var g_app_menu_target: ?*anyopaque = null;

pub fn setMenuEmitHandler(handler: MenuEmitHandler) void {
    g_menu_emit_handler = handler;
    linux_context_menu.setMenuEmitHandler(handler);
}

fn ensureAppMenuTarget() ?*anyopaque {
    return ensureSimpleObjcTarget(&g_app_menu_target, "SujiAppMenuTarget", "appMenuClick:", &appMenuClickImpl);
}

/// NSMenuItem.tag === MENU_ITEM_CHECKBOX_TAG → checkbox로 식별, click 시 state 토글.
const MENU_ITEM_CHECKBOX_TAG: i64 = 1;

fn appMenuClickImpl(_: ?*anyopaque, _: ?*anyopaque, sender: ?*anyopaque) callconv(.c) void {
    const item = sender orelse return;
    if (menuItemTag(item) == MENU_ITEM_CHECKBOX_TAG) toggleMenuItemState(item);
    const click = representedObjectUtf8(item) orelse return;
    if (g_menu_emit_handler) |emit| emit(click);
}

pub fn setApplicationMenu(items: []const ApplicationMenuItem) bool {
    if (!comptime is_macos) return false;
    // top-level은 submenu만 허용 (App 메뉴 바). 그 외 타입은 NSMenu 구조상 무의미하므로 거부.
    for (items) |item| if (item != .submenu) return false;

    const NSApplication = getClass("NSApplication") orelse return false;
    const app = msgSend(NSApplication, "sharedApplication") orelse return false;
    const NSMenu = getClass("NSMenu") orelse return false;
    const menubar = msgSend(msgSend(NSMenu, "alloc") orelse return false, "init") orelse return false;

    addDefaultAppMenu(menubar);
    for (items) |item| {
        const sub = item.submenu;
        const menu = createMenuFromItems(sub.label, sub.items) orelse continue;
        const top = addSubmenuItem(menubar, sub.label, menu) orelse continue;
        setMenuItemEnabled(top, sub.enabled);
    }

    msgSendVoid1(app, "setMainMenu:", menubar);
    return true;
}

pub fn resetApplicationMenu() bool {
    if (!comptime is_macos) return false;
    const NSApplication = getClass("NSApplication") orelse return false;
    const app = msgSend(NSApplication, "sharedApplication") orelse return false;
    setupMainMenu(app);
    return true;
}

/// Electron `Menu.popup({x?,y?})` 대응 — 임의 위치 컨텍스트 메뉴.
/// NSMenu `popUpMenuPositioningItem:atLocation:inView:` (item=nil →
/// 메뉴 좌상단이 location, view=nil → location 을 화면 좌표로 해석).
/// 메뉴 빌드/click(menu:click emit)은 setApplicationMenu 와 동일 경로
/// (`createMenuFromItems`). x/y 미지정 시 현재 커서(화면 좌표).
/// ⚠️ popUp 은 동기 모달 — 항목 선택/dismiss 까지 블록(macOS 표준 동작).
pub fn popupContextMenu(items: []const ApplicationMenuItem, x: ?f64, y: ?f64) bool {
    if (comptime is_linux) return linux_context_menu.popup(items, x, y);
    if (!comptime is_macos) return false;
    const menu = createMenuFromItems("", items) orelse return false;
    // x·y 둘 다 지정해야 그 좌표 사용 — 한쪽만이면 커서로 폴백(부분 지정 무의미).
    const loc: NSPoint = if (x != null and y != null)
        .{ .x = x.?, .y = y.? }
    else
        screenGetCursorPoint();
    const f: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque, NSPoint, ?*anyopaque) callconv(.c) bool =
        @ptrCast(&objc.objc_msgSend);
    return f(menu, @ptrCast(objc.sel_registerName("popUpMenuPositioningItem:atLocation:inView:")), null, loc, null);
}

fn createMenuFromItems(title: []const u8, items: []const ApplicationMenuItem) ?*anyopaque {
    const menu = createMenu(title) orelse return null;
    for (items) |item| addApplicationMenuItem(menu, item);
    return menu;
}

fn addApplicationMenuItem(menu: *anyopaque, item: ApplicationMenuItem) void {
    switch (item) {
        .separator => {
            const NSMenuItem = getClass("NSMenuItem") orelse return;
            const sep = msgSend(NSMenuItem, "separatorItem") orelse return;
            msgSendVoid1(menu, "addItem:", sep);
        },
        .item => |it| addAppMenuClickable(menu, it.label, it.click, it.enabled, null),
        .checkbox => |it| addAppMenuClickable(menu, it.label, it.click, it.enabled, it.checked),
        .submenu => |sub| {
            const sub_menu = createMenuFromItems(sub.label, sub.items) orelse return;
            const m = addSubmenuItem(menu, sub.label, sub_menu) orelse return;
            setMenuItemEnabled(m, sub.enabled);
        },
    }
}

fn addAppMenuClickable(menu: *anyopaque, label: []const u8, click: []const u8, enabled: bool, checked: ?bool) void {
    const target = ensureAppMenuTarget() orelse return;
    const ns_label = nsStringFromSlice(label) orelse return;
    const ns_click = nsStringFromSlice(click) orelse return;
    const m = allocNSMenuItem(ns_label, "appMenuClick:", emptyNSString() orelse return) orelse return;
    msgSendVoid1(m, "setTarget:", target);
    msgSendVoid1(m, "setRepresentedObject:", ns_click);
    if (checked) |state| {
        setMenuItemTag(m, MENU_ITEM_CHECKBOX_TAG);
        setMenuItemState(m, state);
    }
    setMenuItemEnabled(m, enabled);
    msgSendVoid1(menu, "addItem:", m);
}
