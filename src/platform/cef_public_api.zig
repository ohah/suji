//! Public native API facade re-exported by cef.zig.
//! This keeps cef.zig focused on core CEF glue while preserving `cef.<api>` names.

const cef_app = @import("cef_app.zig");
const cef_app_handler = @import("cef_app_handler.zig");
const cef_app_progress = @import("cef_app_progress.zig");
const cef_browser_control = @import("cef_browser_control.zig");
const cef_browser_ipc = @import("cef_browser_ipc.zig");
const cef_browser_state = @import("cef_browser_state.zig");
const cef_c = @import("cef_c.zig");
const cef_clipboard = @import("cef_clipboard.zig");
const cef_core_foundation = @import("cef_core_foundation.zig");
const cef_crash_reporter = @import("cef_crash_reporter.zig");
const cef_desktop_capturer = @import("cef_desktop_capturer.zig");
const cef_devtools = @import("cef_devtools.zig");
const cef_dialog = @import("cef_dialog.zig");
const cef_dock = @import("cef_dock.zig");
const cef_global_shortcut = @import("cef_global_shortcut.zig");
const cef_mac_app_menu = @import("cef_mac_app_menu.zig");
const cef_mac_window = @import("cef_mac_window.zig");
const cef_menu = @import("cef_menu.zig");
const cef_message_loop = @import("cef_message_loop.zig");
const cef_native = @import("cef_native.zig");
const cef_native_image = @import("cef_native_image.zig");
const cef_native_registry = @import("cef_native_registry.zig");
const cef_native_theme = @import("cef_native_theme.zig");
const cef_native_window_handles = @import("cef_native_window_handles.zig");
const cef_notification = @import("cef_notification.zig");
const cef_objc = @import("cef_objc.zig");
const cef_page_output_constants = @import("cef_page_output_constants.zig");
const cef_pending_cleanup = @import("cef_pending_cleanup.zig");
const cef_power_monitor = @import("cef_power_monitor.zig");
const cef_power_save_blocker = @import("cef_power_save_blocker.zig");
const cef_request_user_attention = @import("cef_request_user_attention.zig");
const cef_runtime = @import("cef_runtime.zig");
const cef_safe_storage = @import("cef_safe_storage.zig");
const cef_screen = @import("cef_screen.zig");
const cef_scheme = @import("cef_scheme.zig");
const cef_security_scoped_bookmark = @import("cef_security_scoped_bookmark.zig");
const cef_session_cookies = @import("cef_session_cookies.zig");
const cef_shell = @import("cef_shell.zig");
const cef_tray = @import("cef_tray.zig");
const cef_util = @import("cef_util.zig");
const cef_web_request = @import("cef_web_request.zig");
const cef_win_pump = @import("cef_win_pump.zig");
const cef_window_display = @import("cef_window_display.zig");

pub const c = cef_c.c;

pub const objc = cef_objc.objc;
pub const SHELL_MAX_PATH = cef_objc.SHELL_MAX_PATH;
pub const ObjcSenderImpl = cef_objc.ObjcSenderImpl;
pub const msgSend = cef_objc.msgSend;
pub const getClass = cef_objc.getClass;
pub const msgSendVoid1 = cef_objc.msgSendVoid1;
pub const msgSendVoid2 = cef_objc.msgSendVoid2;
pub const msgSendVoidBool = cef_objc.msgSendVoidBool;
pub const deferMakeKeyAndOrderFront = cef_objc.deferMakeKeyAndOrderFront;
pub const nsStringFromSliceWithCapacity = cef_objc.nsStringFromSliceWithCapacity;
pub const nsStringFromSlice = cef_objc.nsStringFromSlice;
pub const emptyNSString = cef_objc.emptyNSString;
pub const nsStringFromCstr = cef_objc.nsStringFromCstr;
pub const nsStringToUtf8Buf = cef_objc.nsStringToUtf8Buf;
pub const menuItemTag = cef_objc.menuItemTag;
pub const toggleMenuItemState = cef_objc.toggleMenuItemState;
pub const representedObjectUtf8 = cef_objc.representedObjectUtf8;
pub const nsFileUrlIfExists = cef_objc.nsFileUrlIfExists;
pub const ensureSimpleObjcTarget = cef_objc.ensureSimpleObjcTarget;
pub const setMenuItemEnabled = cef_objc.setMenuItemEnabled;
pub const setMenuItemState = cef_objc.setMenuItemState;
pub const setMenuItemTag = cef_objc.setMenuItemTag;

pub const CefConfig = cef_runtime.CefConfig;
pub const executeSubprocess = cef_runtime.executeSubprocess;
pub const initialize = cef_runtime.initialize;

pub const InvokeCallback = cef_browser_ipc.InvokeCallback;
pub const EmitCallback = cef_browser_ipc.EmitCallback;
pub const setInvokeHandler = cef_browser_ipc.setInvokeHandler;
pub const setEmitHandler = cef_browser_ipc.setEmitHandler;

pub const cefDebug = cef_app_handler.cefDebug;
pub const diagPrintCefAbi = cef_app_handler.diagPrintCefAbi;

pub const devtoolsClient = cef_browser_state.devtoolsClient;
pub const currentBrowser = cef_browser_state.currentBrowser;
pub const rememberMainBrowserIfUnset = cef_browser_state.rememberMainBrowserIfUnset;
pub const isMainBrowser = cef_browser_state.isMainBrowser;
pub const CEF_IPC_BUF_LEN = cef_browser_state.CEF_IPC_BUF_LEN;

pub const globalNative = cef_native_registry.globalNative;
pub const nativeAllocator = cef_native_registry.nativeAllocator;

pub const CefNative = cef_native.CefNative;

pub const cefDeferResponse = cef_browser_ipc.cefDeferResponse;
pub const cefCompletePending = cef_browser_ipc.cefCompletePending;
pub const purgePendingResponsesForBrowser = cef_pending_cleanup.purgePendingResponsesForBrowser;

pub const PDF_PATH_STACK_BUF = cef_page_output_constants.PDF_PATH_STACK_BUF;
pub const EVENT_PDF_PRINT_FINISHED = cef_page_output_constants.EVENT_PDF_PRINT_FINISHED;
pub const EVENT_PAGE_CAPTURED = cef_page_output_constants.EVENT_PAGE_CAPTURED;

pub const nullTerminateOrTruncate = cef_util.nullTerminateOrTruncate;
pub const asPtr = cef_util.asPtr;
pub const zeroCefStruct = cef_util.zeroCefStruct;
pub const setCefString = cef_util.setCefString;
pub const setUrlOrBlank = cef_util.setUrlOrBlank;
pub const isAboutBlankUrl = cef_util.isAboutBlankUrl;
pub const getArgString = cef_util.getArgString;
pub const traceIpcEnabled = cef_util.traceIpcEnabled;
pub const traceDragRegionEnabled = cef_util.traceDragRegionEnabled;
pub const cefStringToUtf8 = cef_util.cefStringToUtf8;
pub const cefUserfreeToUtf8 = cef_util.cefUserfreeToUtf8;
pub const getMainFrameUrl = cef_util.getMainFrameUrl;
pub const frameIsMain = cef_util.frameIsMain;
pub const initBaseRefCounted = cef_util.initBaseRefCounted;
pub const writeCStr = cef_util.writeCStr;

pub const navigate = cef_browser_control.navigate;
pub const evalJs = cef_browser_control.evalJs;
pub const zoomChange = cef_browser_control.zoomChange;
pub const zoomSet = cef_browser_control.zoomSet;

pub const CFDataCreate = cef_core_foundation.CFDataCreate;
pub const CFDataGetBytePtr = cef_core_foundation.CFDataGetBytePtr;
pub const CFDataGetLength = cef_core_foundation.CFDataGetLength;
pub const CFRelease = cef_core_foundation.CFRelease;

pub const windowsEntryHwnd = cef_native_window_handles.windowsEntryHwnd;
pub const collectTopLevelNativeWindowHandles = cef_native_window_handles.collectTopLevelNativeWindowHandles;
pub const nsWindowForBrowserHandle = cef_native_window_handles.nsWindowForBrowserHandle;

pub const setupMainMenu = cef_mac_app_menu.setupMainMenu;
pub const addDefaultAppMenu = cef_mac_app_menu.addDefaultAppMenu;
pub const createMenu = cef_mac_app_menu.createMenu;
pub const addSubmenuItem = cef_mac_app_menu.addSubmenuItem;
pub const allocNSMenuItem = cef_mac_app_menu.allocNSMenuItem;

pub const win_pump = cef_win_pump.win_pump;

pub const run = cef_message_loop.run;
pub const shutdown = cef_message_loop.shutdown;
pub const quit = cef_message_loop.quit;
pub const quitAfterNextResponse = cef_message_loop.quitAfterNextResponse;

pub const MAX_TITLE_BYTES = cef_window_display.MAX_TITLE_BYTES;
pub const WindowReadyToShowHandler = cef_window_display.WindowReadyToShowHandler;
pub const WindowTitleChangeHandler = cef_window_display.WindowTitleChangeHandler;
pub const WindowFindResultHandler = cef_window_display.WindowFindResultHandler;
pub const WindowDisplayHandlers = cef_window_display.WindowDisplayHandlers;
pub const setWindowDisplayHandlers = cef_window_display.setWindowDisplayHandlers;

pub const WebRequestEmitFn = cef_web_request.WebRequestEmitFn;
pub const setWebRequestEmitHandler = cef_web_request.setWebRequestEmitHandler;
pub const emitWebRequestPayload = cef_web_request.emitWebRequestPayload;
pub const webRequestSetBlockedUrls = cef_web_request.webRequestSetBlockedUrls;
pub const webRequestSetListenerFilter = cef_web_request.webRequestSetListenerFilter;
pub const webRequestPendingDrops = cef_web_request.webRequestPendingDrops;
pub const webRequestResolve = cef_web_request.webRequestResolve;

pub const devtoolsHost = cef_devtools.devtoolsHost;
pub const hasDevTools = cef_devtools.hasDevTools;
pub const lookupDevToolsInspectee = cef_devtools.lookupDevToolsInspectee;
pub const openDevTools = cef_devtools.openDevTools;
pub const closeDevTools = cef_devtools.closeDevTools;
pub const toggleDevTools = cef_devtools.toggleDevTools;

pub const setDistPath = cef_scheme.setDistPath;
pub const registerSchemeHandlerFactory = cef_scheme.registerSchemeHandlerFactory;
pub const buildDefaultCsp = cef_scheme.buildDefaultCsp;
pub const setCspValue = cef_scheme.setCspValue;

pub const WindowInitOpts = cef_mac_window.WindowInitOpts;
pub const initWindowInfo = cef_mac_window.initWindowInfo;
pub const MacWindowHandles = cef_mac_window.MacWindowHandles;
pub const NSPoint = cef_mac_window.NSPoint;
pub const NSSize = cef_mac_window.NSSize;
pub const NSRect = cef_mac_window.NSRect;
pub const cefViewsHandleToNSWindow = cef_mac_window.cefViewsHandleToNSWindow;
pub const applyCefViewsMacWindowOptions = cef_mac_window.applyCefViewsMacWindowOptions;
pub const attachMacChildWindow = cef_mac_window.attachMacChildWindow;
pub const detachMacChildWindow = cef_mac_window.detachMacChildWindow;
pub const orderMacWindowFront = cef_mac_window.orderMacWindowFront;
pub const orderMacWindowOut = cef_mac_window.orderMacWindowOut;
pub const setMacWindowFrameRaw = cef_mac_window.setMacWindowFrameRaw;
pub const nsViewBounds = cef_mac_window.nsViewBounds;
pub const childWindowFrameForBounds = cef_mac_window.childWindowFrameForBounds;
pub const applyBackgroundColor = cef_mac_window.applyBackgroundColor;
pub const closeMacWindow = cef_mac_window.closeMacWindow;
pub const setMacWindowTitle = cef_mac_window.setMacWindowTitle;
pub const setMacWindowBounds = cef_mac_window.setMacWindowBounds;
pub const getMacWindowBounds = cef_mac_window.getMacWindowBounds;
const cef_window_lifecycle = @import("cef_window_lifecycle.zig");

pub const crashReporterEnabled = cef_crash_reporter.crashReporterEnabled;
pub const crashReporterSetKeyValue = cef_crash_reporter.crashReporterSetKeyValue;

pub const StandardPathInputs = cef_app.StandardPathInputs;
pub const buildStandardPath = cef_app.buildStandardPath;
pub const appGetPath = cef_app.appGetPath;
pub const appGetBundlePath = cef_app.appGetBundlePath;
pub const appIsPackaged = cef_app.appIsPackaged;
pub const appGetLocale = cef_app.appGetLocale;
pub const appFocus = cef_app.appFocus;
pub const appHide = cef_app.appHide;

pub const clipboardReadText = cef_clipboard.clipboardReadText;
pub const clipboardWriteText = cef_clipboard.clipboardWriteText;
pub const clipboardClear = cef_clipboard.clipboardClear;
pub const clipboardWriteImagePng = cef_clipboard.clipboardWriteImagePng;
pub const clipboardReadImagePng = cef_clipboard.clipboardReadImagePng;
pub const clipboardWriteTiff = cef_clipboard.clipboardWriteTiff;
pub const clipboardReadTiff = cef_clipboard.clipboardReadTiff;
pub const clipboardHas = cef_clipboard.clipboardHas;
pub const clipboardAvailableFormats = cef_clipboard.clipboardAvailableFormats;
pub const clipboardReadHtml = cef_clipboard.clipboardReadHtml;
pub const clipboardWriteHtml = cef_clipboard.clipboardWriteHtml;
pub const clipboardReadRtf = cef_clipboard.clipboardReadRtf;
pub const clipboardWriteRtf = cef_clipboard.clipboardWriteRtf;
pub const clipboardWriteBuffer = cef_clipboard.clipboardWriteBuffer;
pub const clipboardReadBuffer = cef_clipboard.clipboardReadBuffer;

pub const powerMonitorIdleSeconds = cef_power_monitor.powerMonitorIdleSeconds;
pub const powerMonitorInstall = cef_power_monitor.powerMonitorInstall;
pub const powerMonitorUninstall = cef_power_monitor.powerMonitorUninstall;
pub const powerMonitorSetScreenLocked = cef_power_monitor.powerMonitorSetScreenLocked;
pub const powerMonitorScreenLocked = cef_power_monitor.powerMonitorScreenLocked;

pub const shellOpenExternal = cef_shell.shellOpenExternal;
pub const shellShowItemInFolder = cef_shell.shellShowItemInFolder;
pub const shellBeep = cef_shell.shellBeep;
pub const shellOpenPath = cef_shell.shellOpenPath;
pub const shellTrashItem = cef_shell.shellTrashItem;

pub const screenGetAllDisplays = cef_screen.screenGetAllDisplays;
pub const screenGetCursorPoint = cef_screen.screenGetCursorPoint;
pub const screenGetDisplayNearestPoint = cef_screen.screenGetDisplayNearestPoint;

pub const desktopCapturerGetSources = cef_desktop_capturer.desktopCapturerGetSources;
pub const desktopCapturerCaptureThumbnail = cef_desktop_capturer.desktopCapturerCaptureThumbnail;

pub const nativeThemeIsDark = cef_native_theme.nativeThemeIsDark;
pub const nativeThemeSetSource = cef_native_theme.nativeThemeSetSource;
pub const nativeThemeInstall = cef_native_theme.nativeThemeInstall;
pub const nativeThemeUninstall = cef_native_theme.nativeThemeUninstall;

pub const dockSetBadge = cef_dock.dockSetBadge;
pub const dockGetBadge = cef_dock.dockGetBadge;
pub const appSetBadgeCount = cef_dock.appSetBadgeCount;

pub const PowerSaveBlockerType = cef_power_save_blocker.PowerSaveBlockerType;
pub const powerSaveBlockerStart = cef_power_save_blocker.powerSaveBlockerStart;
pub const powerSaveBlockerStop = cef_power_save_blocker.powerSaveBlockerStop;

pub const safeStorageSet = cef_safe_storage.safeStorageSet;
pub const safeStorageGet = cef_safe_storage.safeStorageGet;
pub const safeStorageDelete = cef_safe_storage.safeStorageDelete;

pub const appRequestUserAttention = cef_request_user_attention.appRequestUserAttention;
pub const appCancelUserAttentionRequest = cef_request_user_attention.appCancelUserAttentionRequest;

pub const ScopedAccess = cef_security_scoped_bookmark.ScopedAccess;
pub const securityScopedBookmarkCreate = cef_security_scoped_bookmark.securityScopedBookmarkCreate;
pub const securityScopedAccessStart = cef_security_scoped_bookmark.securityScopedAccessStart;
pub const securityScopedAccessStop = cef_security_scoped_bookmark.securityScopedAccessStop;

pub const NSBitmapImageFileType = cef_native_image.NSBitmapImageFileType;
pub const nativeImageEncodeFromPath = cef_native_image.nativeImageEncodeFromPath;
pub const nativeImageGetSize = cef_native_image.nativeImageGetSize;

pub const appSetProgressBar = cef_app_progress.appSetProgressBar;

pub const sessionClearCookies = cef_session_cookies.sessionClearCookies;
pub const sessionFlushStore = cef_session_cookies.sessionFlushStore;
pub const sessionClearStorageData = cef_session_cookies.sessionClearStorageData;
pub const sessionSetCookie = cef_session_cookies.sessionSetCookie;
pub const sessionRemoveCookies = cef_session_cookies.sessionRemoveCookies;
pub const sessionGetCookies = cef_session_cookies.sessionGetCookies;

pub const ApplicationMenuItem = cef_menu.ApplicationMenuItem;
pub const MenuEmitHandler = cef_menu.MenuEmitHandler;
pub const setMenuEmitHandler = cef_menu.setMenuEmitHandler;
pub const setApplicationMenu = cef_menu.setApplicationMenu;
pub const resetApplicationMenu = cef_menu.resetApplicationMenu;
pub const popupContextMenu = cef_menu.popupContextMenu;

pub const TrayMenuItem = cef_tray.TrayMenuItem;
pub const TrayEmitHandler = cef_tray.TrayEmitHandler;
pub const setTrayEmitHandler = cef_tray.setTrayEmitHandler;
pub const createTray = cef_tray.createTray;
pub const setTrayTitle = cef_tray.setTrayTitle;
pub const setTrayTooltip = cef_tray.setTrayTooltip;
pub const setTrayMenu = cef_tray.setTrayMenu;
pub const destroyTray = cef_tray.destroyTray;

pub const NotificationEmitHandler = cef_notification.NotificationEmitHandler;
pub const setNotificationEmitHandler = cef_notification.setNotificationEmitHandler;
pub const notificationIsSupported = cef_notification.notificationIsSupported;
pub const notificationRequestPermission = cef_notification.notificationRequestPermission;
pub const notificationShow = cef_notification.notificationShow;
pub const notificationClose = cef_notification.notificationClose;

pub const GlobalShortcutEmitHandler = cef_global_shortcut.GlobalShortcutEmitHandler;
pub const GlobalShortcutStatus = cef_global_shortcut.GlobalShortcutStatus;
pub const setGlobalShortcutEmitHandler = cef_global_shortcut.setGlobalShortcutEmitHandler;
pub const globalShortcutRegister = cef_global_shortcut.globalShortcutRegister;
pub const globalShortcutUnregister = cef_global_shortcut.globalShortcutUnregister;
pub const globalShortcutUnregisterAll = cef_global_shortcut.globalShortcutUnregisterAll;
pub const globalShortcutIsRegistered = cef_global_shortcut.globalShortcutIsRegistered;

pub const WindowResizedHandler = cef_window_lifecycle.WindowResizedHandler;
pub const WindowMovedHandler = cef_window_lifecycle.WindowMovedHandler;
pub const WindowFocusHandler = cef_window_lifecycle.WindowFocusHandler;
pub const WindowBlurHandler = cef_window_lifecycle.WindowBlurHandler;
pub const WindowSimpleHandler = cef_window_lifecycle.WindowSimpleHandler;
pub const WindowWillResizeHandler = cef_window_lifecycle.WindowWillResizeHandler;
pub const WindowLifecycleHandlers = cef_window_lifecycle.WindowLifecycleHandlers;
pub const setWindowLifecycleHandlers = cef_window_lifecycle.setWindowLifecycleHandlers;

pub const MAX_DIALOG_BUTTONS = cef_dialog.MAX_DIALOG_BUTTONS;
pub const MAX_DIALOG_PATHS = cef_dialog.MAX_DIALOG_PATHS;
pub const MessageBoxStyle = cef_dialog.MessageBoxStyle;
pub const MessageBoxOpts = cef_dialog.MessageBoxOpts;
pub const MessageBoxResult = cef_dialog.MessageBoxResult;
pub const FileFilter = cef_dialog.FileFilter;
pub const OpenDialogOpts = cef_dialog.OpenDialogOpts;
pub const SaveDialogOpts = cef_dialog.SaveDialogOpts;
pub const showMessageBox = cef_dialog.showMessageBox;
pub const showErrorBox = cef_dialog.showErrorBox;
pub const showOpenDialog = cef_dialog.showOpenDialog;
pub const showSaveDialog = cef_dialog.showSaveDialog;
