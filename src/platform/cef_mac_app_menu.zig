const builtin = @import("builtin");
const cef = @import("cef.zig");

const objc = cef.objc;
const is_macos = builtin.os.tag == .macos;

const getClass = cef.getClass;
const msgSend = cef.msgSend;
const msgSendVoid1 = cef.msgSendVoid1;
const nsStringFromSlice = cef.nsStringFromSlice;
const quit = cef.quit;

pub fn initNSApp() void {
    if (!comptime is_macos) return;
    const cls = getClass("NSApplication") orelse return;

    // CEF DevTools가 호출하는 isHandlingSendEvent 메서드를 NSApplication에 추가
    // (기본 NSApplication에는 없어서 unrecognized selector 크래시 발생)
    const isSel = objc.sel_registerName("isHandlingSendEvent");
    _ = objc.class_addMethod(
        @ptrCast(cls),
        isSel,
        @ptrCast(&isHandlingSendEventImpl),
        "B@:",
    );
    // _setHandlingSendEvent: (underscore prefix, 전통적 private setter)
    const setSel = objc.sel_registerName("_setHandlingSendEvent:");
    _ = objc.class_addMethod(
        @ptrCast(cls),
        setSel,
        @ptrCast(&setHandlingSendEventImpl),
        "v@:B",
    );
    // setHandlingSendEvent: (CEF 신버전이 underscore 없이 호출하는 경로 대응)
    const setSel2 = objc.sel_registerName("setHandlingSendEvent:");
    _ = objc.class_addMethod(
        @ptrCast(cls),
        setSel2,
        @ptrCast(&setHandlingSendEventImpl),
        "v@:B",
    );

    const app = msgSend(cls, "sharedApplication") orelse return;
    const sel = objc.sel_registerName("setActivationPolicy:");
    const func: *const fn (?*anyopaque, ?*anyopaque, i64) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    func(app, @ptrCast(sel), 0);

    // 메뉴바 등록
    setupMainMenu(app);
}

var g_handling_send_event: bool = false;

fn isHandlingSendEventImpl(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) u8 {
    return if (g_handling_send_event) 1 else 0;
}

fn setHandlingSendEventImpl(_: ?*anyopaque, _: ?*anyopaque, value: u8) callconv(.c) void {
    g_handling_send_event = value != 0;
}

/// macOS 메뉴바 생성 — Edit 메뉴 (Cmd+C/V/X/A/Z/Shift+Z)
pub fn setupMainMenu(app: ?*anyopaque) void {
    const NSMenu = getClass("NSMenu") orelse return;

    // 메인 메뉴바
    const menubar = msgSend(msgSend(NSMenu, "alloc") orelse return, "init") orelse return;

    // 1. App 메뉴
    addDefaultAppMenu(menubar);

    // 2. File 메뉴
    const file_menu = createMenu("File") orelse return;
    addMenuItem(file_menu, "Close Window", "performClose:", "w");
    _ = addSubmenuItem(menubar, "File", file_menu);

    // 3. Edit 메뉴
    const edit_menu = createMenu("Edit") orelse return;
    addMenuItem(edit_menu, "Undo", "undo:", "z");
    addMenuItemWithModifier(edit_menu, "Redo", "redo:", "z", true);
    addSeparator(edit_menu);
    addMenuItem(edit_menu, "Cut", "cut:", "x");
    addMenuItem(edit_menu, "Copy", "copy:", "c");
    addMenuItem(edit_menu, "Paste", "paste:", "v");
    addMenuItemWithModifiers(edit_menu, "Paste and Match Style", "pasteAsPlainText:", "v", true, true); // Opt+Shift+Cmd+V
    addMenuItem(edit_menu, "Delete", "delete:", "");
    addMenuItem(edit_menu, "Select All", "selectAll:", "a");
    addSeparator(edit_menu);
    // Substitutions 서브메뉴
    if (createMenu("Substitutions")) |sub_menu| {
        addMenuItem(sub_menu, "Show Substitutions", "orderFrontSubstitutionsPanel:", "");
        addSeparator(sub_menu);
        addMenuItem(sub_menu, "Smart Copy/Paste", "toggleSmartInsertDelete:", "");
        addMenuItem(sub_menu, "Smart Quotes", "toggleAutomaticQuoteSubstitution:", "");
        addMenuItem(sub_menu, "Smart Dashes", "toggleAutomaticDashSubstitution:", "");
        addMenuItem(sub_menu, "Smart Links", "toggleAutomaticLinkDetection:", "");
        addMenuItem(sub_menu, "Text Replacement", "toggleAutomaticTextReplacement:", "");
        _ = addSubmenuItem(edit_menu, "Substitutions", sub_menu);
    }
    // Speech 서브메뉴
    if (createMenu("Speech")) |speech_menu| {
        addMenuItem(speech_menu, "Start Speaking", "startSpeaking:", "");
        addMenuItem(speech_menu, "Stop Speaking", "stopSpeaking:", "");
        _ = addSubmenuItem(edit_menu, "Speech", speech_menu);
    }
    _ = addSubmenuItem(menubar, "Edit", edit_menu);

    // 4. View 메뉴
    const view_menu = createMenu("View") orelse return;
    addMenuItem(view_menu, "Reload", "reload:", "r");
    addMenuItemWithModifier(view_menu, "Force Reload", "reloadIgnoringCache:", "r", true);
    addMenuItemWithModifiers(view_menu, "Toggle Developer Tools", "toggleDeveloperTools:", "i", false, true); // Alt+Cmd+I
    addSeparator(view_menu);
    addMenuItem(view_menu, "Actual Size", "resetZoom:", "0");
    addMenuItem(view_menu, "Zoom In", "zoomIn:", "+");
    addMenuItem(view_menu, "Zoom Out", "zoomOut:", "-");
    addSeparator(view_menu);
    addMenuItem(view_menu, "Toggle Full Screen", "toggleFullScreen:", "f");
    _ = addSubmenuItem(menubar, "View", view_menu);

    // 5. Window 메뉴
    const window_menu = createMenu("Window") orelse return;
    addMenuItem(window_menu, "Minimize", "performMiniaturize:", "m");
    addMenuItem(window_menu, "Zoom", "performZoom:", "");
    addSeparator(window_menu);
    addMenuItem(window_menu, "Bring All to Front", "arrangeInFront:", "");
    _ = addSubmenuItem(menubar, "Window", window_menu);

    // 6. Help 메뉴
    const help_menu = createMenu("Help") orelse return;
    _ = addSubmenuItem(menubar, "Help", help_menu);

    msgSendVoid1(app, "setMainMenu:", menubar);
}

pub fn addDefaultAppMenu(menubar: *anyopaque) void {
    const app_menu = createMenu("") orelse return;
    addMenuItem(app_menu, "About Suji", "orderFrontStandardAboutPanel:", "");
    addSeparator(app_menu);
    addMenuItem(app_menu, "Hide Suji", "hide:", "h");
    addMenuItemWithModifier(app_menu, "Hide Others", "hideOtherApplications:", "h", true);
    addMenuItem(app_menu, "Show All", "unhideAllApplications:", "");
    addSeparator(app_menu);
    addQuitMenuItem(app_menu);
    _ = addSubmenuItem(menubar, "", app_menu);
}

pub fn createMenu(title: []const u8) ?*anyopaque {
    const NSMenu = getClass("NSMenu") orelse return null;
    const alloc = msgSend(NSMenu, "alloc") orelse return null;
    const ns_title = nsStringFromSlice(title) orelse return null;
    const initSel = objc.sel_registerName("initWithTitle:");
    const initFn: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque = @ptrCast(&objc.objc_msgSend);
    return initFn(alloc, @ptrCast(initSel), ns_title);
}

pub fn addSubmenuItem(menubar: *anyopaque, title: []const u8, submenu: *anyopaque) ?*anyopaque {
    const item = msgSend(msgSend(getClass("NSMenuItem") orelse return null, "alloc") orelse return null, "init") orelse return null;
    msgSendVoid1(item, "setSubmenu:", submenu);
    if (title.len > 0) {
        const ns_title = nsStringFromSlice(title) orelse return null;
        msgSendVoid1(item, "setTitle:", ns_title);
    }
    msgSendVoid1(menubar, "addItem:", item);
    return item;
}

fn addMenuItemWithModifier(menu: *anyopaque, title: [:0]const u8, action: [:0]const u8, key: [:0]const u8, shift: bool) void {
    addMenuItemWithModifiers(menu, title, action, key, shift, false);
}

fn addMenuItemWithModifiers(menu: *anyopaque, title: [:0]const u8, action: [:0]const u8, key: [:0]const u8, shift: bool, alt: bool) void {
    const NSString = getClass("NSString") orelse return;
    const strFn: *const fn (?*anyopaque, ?*anyopaque, [*:0]const u8) callconv(.c) ?*anyopaque = @ptrCast(&objc.objc_msgSend);
    const ns_title = strFn(NSString, @ptrCast(objc.sel_registerName("stringWithUTF8String:")), title.ptr);
    const ns_key = strFn(NSString, @ptrCast(objc.sel_registerName("stringWithUTF8String:")), key.ptr);
    const item = allocNSMenuItem(ns_title, action.ptr, ns_key) orelse return;

    // NSCommandKeyMask=1<<20, NSShiftKeyMask=1<<17, NSAlternateKeyMask=1<<19
    var mask: u64 = 1 << 20; // Cmd
    if (shift) mask |= 1 << 17;
    if (alt) mask |= 1 << 19;
    const setModFn: *const fn (?*anyopaque, ?*anyopaque, u64) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    setModFn(item, @ptrCast(objc.sel_registerName("setKeyEquivalentModifierMask:")), mask);

    msgSendVoid1(menu, "addItem:", item);
}

/// NSMenuItem.alloc.initWithTitle:action:keyEquivalent: 보일러플레이트.
/// caller가 NSString을 미리 만들고(nsStringFromSlice 또는 stringWithUTF8String) action
/// selector 이름을 줌. target/representedObject/tag는 caller가 추가 설정.
pub fn allocNSMenuItem(ns_title: ?*anyopaque, action_sel_name: [*:0]const u8, ns_key: ?*anyopaque) ?*anyopaque {
    const NSMenuItem = getClass("NSMenuItem") orelse return null;
    const initSel = objc.sel_registerName("initWithTitle:action:keyEquivalent:");
    const initFn: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque =
        @ptrCast(&objc.objc_msgSend);
    const alloc = msgSend(NSMenuItem, "alloc") orelse return null;
    return initFn(alloc, @ptrCast(initSel), ns_title, @ptrCast(objc.sel_registerName(action_sel_name)), ns_key);
}

fn addMenuItem(menu: *anyopaque, title: [:0]const u8, action: [:0]const u8, key: [:0]const u8) void {
    const NSString = getClass("NSString") orelse return;
    const strFn: *const fn (?*anyopaque, ?*anyopaque, [*:0]const u8) callconv(.c) ?*anyopaque = @ptrCast(&objc.objc_msgSend);
    const ns_title = strFn(NSString, @ptrCast(objc.sel_registerName("stringWithUTF8String:")), title.ptr);
    const ns_key = strFn(NSString, @ptrCast(objc.sel_registerName("stringWithUTF8String:")), key.ptr);
    const item = allocNSMenuItem(ns_title, action.ptr, ns_key) orelse return;
    msgSendVoid1(menu, "addItem:", item);
}

fn addQuitMenuItem(menu: *anyopaque) void {
    const target = ensureQuitTarget() orelse return;
    const NSString = getClass("NSString") orelse return;
    const strFn: *const fn (?*anyopaque, ?*anyopaque, [*:0]const u8) callconv(.c) ?*anyopaque = @ptrCast(&objc.objc_msgSend);
    const ns_title = strFn(NSString, @ptrCast(objc.sel_registerName("stringWithUTF8String:")), "Quit Suji");
    const ns_key = strFn(NSString, @ptrCast(objc.sel_registerName("stringWithUTF8String:")), "q");
    const item = allocNSMenuItem(ns_title, "sujiQuit:", ns_key) orelse return;
    msgSendVoid1(item, "setTarget:", target);
    msgSendVoid1(menu, "addItem:", item);
}

fn addSeparator(menu: *anyopaque) void {
    const NSMenuItem = getClass("NSMenuItem") orelse return;
    const sep = msgSend(NSMenuItem, "separatorItem") orelse return;
    msgSendVoid1(menu, "addItem:", sep);
}

/// Quit 메뉴/Cmd+Q action 타깃. 기본 NSApplication의 `terminate:`를 부르면 CEF가
/// NSApplicationWillTerminate 옵저버에서 SIGTRAP — 그래서 자체 selector로 우회해
/// `cef.quit()`(close_browser→cef_quit_message_loop)을 호출, run() 정상 반환 후
/// main.zig가 cef.shutdown까지 정렬 처리.
var g_quit_target: ?*anyopaque = null;

fn sujiQuitImpl(_: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    quit();
}

pub fn ensureQuitTarget() ?*anyopaque {
    if (g_quit_target) |existing| return existing;
    const NSObject = getClass("NSObject") orelse return null;
    const cls = objc.objc_allocateClassPair(NSObject, "SujiQuitTarget", 0) orelse
        getClass("SujiQuitTarget") orelse return null;
    const sel = objc.sel_registerName("sujiQuit:");
    _ = objc.class_addMethod(cls, @ptrCast(sel), @ptrCast(&sujiQuitImpl), "v@:@");
    objc.objc_registerClassPair(cls);
    const alloc = msgSend(cls, "alloc") orelse return null;
    const instance = msgSend(alloc, "init") orelse return null;
    g_quit_target = instance;
    return instance;
}
