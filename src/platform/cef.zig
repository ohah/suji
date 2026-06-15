const cef_public_api = @import("cef_public_api.zig");

pub const c = cef_public_api.c;

// Shared macOS ObjC bridge — cef_objc.zig 로 분리(동작 무변경).
// Public API는 기존 cef.zig 심볼을 유지한다.
pub const objc = cef_public_api.objc;
pub const SHELL_MAX_PATH = cef_public_api.SHELL_MAX_PATH;
pub const ObjcSenderImpl = cef_public_api.ObjcSenderImpl;
pub const msgSend = cef_public_api.msgSend;
pub const getClass = cef_public_api.getClass;
pub const msgSendVoid1 = cef_public_api.msgSendVoid1;
pub const msgSendVoid2 = cef_public_api.msgSendVoid2;
pub const msgSendVoidBool = cef_public_api.msgSendVoidBool;
pub const msgSendBool = cef_public_api.msgSendBool;
pub const deferMakeKeyAndOrderFront = cef_public_api.deferMakeKeyAndOrderFront;
pub const nsStringFromSliceWithCapacity = cef_public_api.nsStringFromSliceWithCapacity;
pub const nsStringFromSlice = cef_public_api.nsStringFromSlice;
pub const loadNSImageFromFile = cef_public_api.loadNSImageFromFile;
pub const emptyNSString = cef_public_api.emptyNSString;
pub const nsStringFromCstr = cef_public_api.nsStringFromCstr;
pub const nsStringToUtf8Buf = cef_public_api.nsStringToUtf8Buf;
pub const menuItemTag = cef_public_api.menuItemTag;
pub const toggleMenuItemState = cef_public_api.toggleMenuItemState;
pub const representedObjectUtf8 = cef_public_api.representedObjectUtf8;
pub const nsFileUrlIfExists = cef_public_api.nsFileUrlIfExists;
pub const ensureSimpleObjcTarget = cef_public_api.ensureSimpleObjcTarget;
pub const setMenuItemEnabled = cef_public_api.setMenuItemEnabled;
pub const setMenuItemHidden = cef_public_api.setMenuItemHidden;
pub const setMenuItemState = cef_public_api.setMenuItemState;
pub const setMenuItemTag = cef_public_api.setMenuItemTag;

// ============================================
// Public API
// ============================================

/// Native/core public APIs — cef_public_api.zig facade로 집계(동작 무변경).
pub const crashReporterEnabled = cef_public_api.crashReporterEnabled;
pub const crashReporterSetKeyValue = cef_public_api.crashReporterSetKeyValue;
pub const StandardPathInputs = cef_public_api.StandardPathInputs;
pub const buildStandardPath = cef_public_api.buildStandardPath;
pub const appGetPath = cef_public_api.appGetPath;
pub const appGetBundlePath = cef_public_api.appGetBundlePath;
pub const appIsPackaged = cef_public_api.appIsPackaged;
pub const appGetLocale = cef_public_api.appGetLocale;
pub const appFocus = cef_public_api.appFocus;
pub const appHide = cef_public_api.appHide;
pub const appIsActive = cef_public_api.appIsActive;
pub const appIsHidden = cef_public_api.appIsHidden;
pub const appShow = cef_public_api.appShow;
pub const appIsEmojiPanelSupported = cef_public_api.appIsEmojiPanelSupported;
pub const appFlashFrame = cef_public_api.appFlashFrame;
pub const appSetAboutPanelOptions = cef_public_api.appSetAboutPanelOptions;
pub const appShowAboutPanel = cef_public_api.appShowAboutPanel;
pub const appAddRecentDocument = cef_public_api.appAddRecentDocument;
pub const appClearRecentDocuments = cef_public_api.appClearRecentDocuments;
pub const appIsInApplicationsFolder = cef_public_api.appIsInApplicationsFolder;
pub const appGetLocaleCountryCode = cef_public_api.appGetLocaleCountryCode;
pub const appGetRecentDocuments = cef_public_api.appGetRecentDocuments;
pub const appGetApplicationNameForProtocol = cef_public_api.appGetApplicationNameForProtocol;
pub const appGetApplicationBundleForProtocol = cef_public_api.appGetApplicationBundleForProtocol;
pub const loginItemEnabled = cef_public_api.loginItemEnabled;
pub const setLoginItem = cef_public_api.setLoginItem;
pub const clipboardReadText = cef_public_api.clipboardReadText;
pub const clipboardWriteText = cef_public_api.clipboardWriteText;
pub const clipboardWriteBookmark = cef_public_api.clipboardWriteBookmark;
pub const clipboardWriteFindText = cef_public_api.clipboardWriteFindText;
pub const clipboardReadFindText = cef_public_api.clipboardReadFindText;
pub const clipboardWriteMulti = cef_public_api.clipboardWriteMulti;
pub const clipboardClear = cef_public_api.clipboardClear;
pub const clipboardWriteImagePng = cef_public_api.clipboardWriteImagePng;
pub const clipboardReadImagePng = cef_public_api.clipboardReadImagePng;
pub const clipboardWriteTiff = cef_public_api.clipboardWriteTiff;
pub const clipboardReadTiff = cef_public_api.clipboardReadTiff;
pub const clipboardHas = cef_public_api.clipboardHas;
pub const clipboardAvailableFormats = cef_public_api.clipboardAvailableFormats;
pub const clipboardReadHtml = cef_public_api.clipboardReadHtml;
pub const clipboardWriteHtml = cef_public_api.clipboardWriteHtml;
pub const clipboardReadRtf = cef_public_api.clipboardReadRtf;
pub const clipboardWriteRtf = cef_public_api.clipboardWriteRtf;
pub const clipboardWriteBuffer = cef_public_api.clipboardWriteBuffer;
pub const clipboardReadBuffer = cef_public_api.clipboardReadBuffer;
pub const powerMonitorIdleSeconds = cef_public_api.powerMonitorIdleSeconds;
pub const powerMonitorIsOnBattery = cef_public_api.powerMonitorIsOnBattery;
pub const powerMonitorThermalState = cef_public_api.powerMonitorThermalState;
pub const powerMonitorInstall = cef_public_api.powerMonitorInstall;
pub const powerMonitorUninstall = cef_public_api.powerMonitorUninstall;
pub const powerMonitorSetScreenLocked = cef_public_api.powerMonitorSetScreenLocked;
pub const powerMonitorScreenLocked = cef_public_api.powerMonitorScreenLocked;
pub const requestSingleInstanceLock = cef_public_api.requestSingleInstanceLock;
pub const hasSingleInstanceLock = cef_public_api.hasSingleInstanceLock;
pub const releaseSingleInstanceLock = cef_public_api.releaseSingleInstanceLock;
pub const setSecondInstanceHandler = cef_public_api.setSecondInstanceHandler;
pub const setLaunchArgv = cef_public_api.setLaunchArgv;
pub const shellOpenExternal = cef_public_api.shellOpenExternal;
pub const shellShowItemInFolder = cef_public_api.shellShowItemInFolder;
pub const shellBeep = cef_public_api.shellBeep;
pub const shellOpenPath = cef_public_api.shellOpenPath;
pub const shellTrashItem = cef_public_api.shellTrashItem;
pub const screenGetAllDisplays = cef_public_api.screenGetAllDisplays;
pub const screenInstall = cef_public_api.screenInstall;
pub const screenUninstall = cef_public_api.screenUninstall;
pub const screenGetDisplayNearestPoint = cef_public_api.screenGetDisplayNearestPoint;
pub const screenGetDisplayMatching = cef_public_api.screenGetDisplayMatching;
pub const protocolSetAsDefault = cef_public_api.protocolSetAsDefault;
pub const protocolIsDefault = cef_public_api.protocolIsDefault;
pub const protocolRemoveAsDefault = cef_public_api.protocolRemoveAsDefault;
pub const desktopCapturerGetSources = cef_public_api.desktopCapturerGetSources;
pub const desktopCapturerCaptureThumbnail = cef_public_api.desktopCapturerCaptureThumbnail;
pub const nativeThemeIsDark = cef_public_api.nativeThemeIsDark;
pub const nativeThemeSetSource = cef_public_api.nativeThemeSetSource;
pub const nativeThemeHighContrast = cef_public_api.nativeThemeHighContrast;
pub const nativeThemeReducedTransparency = cef_public_api.nativeThemeReducedTransparency;
pub const nativeThemeInvertedColorScheme = cef_public_api.nativeThemeInvertedColorScheme;
pub const nativeThemeDifferentiateWithoutColor = cef_public_api.nativeThemeDifferentiateWithoutColor;
pub const nativeThemeInstall = cef_public_api.nativeThemeInstall;
pub const nativeThemeUninstall = cef_public_api.nativeThemeUninstall;
pub const dockSetBadge = cef_public_api.dockSetBadge;
pub const dockGetBadge = cef_public_api.dockGetBadge;
pub const appSetBadgeCount = cef_public_api.appSetBadgeCount;
pub const PowerSaveBlockerType = cef_public_api.PowerSaveBlockerType;
pub const powerSaveBlockerStart = cef_public_api.powerSaveBlockerStart;
pub const powerSaveBlockerStop = cef_public_api.powerSaveBlockerStop;
pub const powerSaveBlockerIsStarted = cef_public_api.powerSaveBlockerIsStarted;
pub const safeStorageSet = cef_public_api.safeStorageSet;
pub const safeStorageGet = cef_public_api.safeStorageGet;
pub const safeStorageDelete = cef_public_api.safeStorageDelete;
pub const appRequestUserAttention = cef_public_api.appRequestUserAttention;
pub const appCancelUserAttentionRequest = cef_public_api.appCancelUserAttentionRequest;
pub const ScopedAccess = cef_public_api.ScopedAccess;
pub const securityScopedBookmarkCreate = cef_public_api.securityScopedBookmarkCreate;
pub const securityScopedAccessStart = cef_public_api.securityScopedAccessStart;
pub const securityScopedAccessStop = cef_public_api.securityScopedAccessStop;
pub const NSBitmapImageFileType = cef_public_api.NSBitmapImageFileType;
pub const nativeImageEncodeFromPath = cef_public_api.nativeImageEncodeFromPath;
pub const nativeImageFileIconPng = cef_public_api.nativeImageFileIconPng;
pub const nativeImageGetSize = cef_public_api.nativeImageGetSize;
pub const nativeImageIsEmpty = cef_public_api.nativeImageIsEmpty;
pub const nativeImageIsTemplate = cef_public_api.nativeImageIsTemplate;
pub const appSetProgressBar = cef_public_api.appSetProgressBar;
pub const sessionClearCookies = cef_public_api.sessionClearCookies;
pub const sessionFlushStore = cef_public_api.sessionFlushStore;
pub const sessionClearStorageData = cef_public_api.sessionClearStorageData;
pub const sessionSetCookie = cef_public_api.sessionSetCookie;
pub const sessionRemoveCookies = cef_public_api.sessionRemoveCookies;
pub const sessionGetCookies = cef_public_api.sessionGetCookies;
pub const sessionSetProxy = cef_public_api.sessionSetProxy;
pub const PermissionEmitFn = cef_public_api.PermissionEmitFn;
pub const setPermissionEmitHandler = cef_public_api.setPermissionEmitHandler;
pub const permissionSetHandlerEnabled = cef_public_api.permissionSetHandlerEnabled;
pub const permissionRespond = cef_public_api.permissionRespond;
pub const mediaAccessRespond = cef_public_api.mediaAccessRespond;
pub const getPermissionHandler = cef_public_api.getPermissionHandler;
pub const DownloadEmitFn = cef_public_api.DownloadEmitFn;
pub const setDownloadEmitHandler = cef_public_api.setDownloadEmitHandler;
pub const setDownloadPath = cef_public_api.setDownloadPath;
pub const WindowOpenEmitFn = cef_public_api.WindowOpenEmitFn;
pub const setWindowOpenEmitHandler = cef_public_api.setWindowOpenEmitHandler;
pub const setWindowOpenDeny = cef_public_api.setWindowOpenDeny;
pub const ApplicationMenuItem = cef_public_api.ApplicationMenuItem;
pub const MenuEmitHandler = cef_public_api.MenuEmitHandler;
pub const setMenuEmitHandler = cef_public_api.setMenuEmitHandler;
pub const MenuLifecycleEmitHandler = cef_public_api.MenuLifecycleEmitHandler;
pub const setMenuLifecycleEmitHandler = cef_public_api.setMenuLifecycleEmitHandler;
pub const setApplicationMenu = cef_public_api.setApplicationMenu;
pub const resetApplicationMenu = cef_public_api.resetApplicationMenu;
pub const sendActionToFirstResponder = cef_public_api.sendActionToFirstResponder;
pub const popupContextMenu = cef_public_api.popupContextMenu;
pub const TrayMenuItem = cef_public_api.TrayMenuItem;
pub const TrayEmitHandler = cef_public_api.TrayEmitHandler;
pub const setTrayEmitHandler = cef_public_api.setTrayEmitHandler;
pub const createTray = cef_public_api.createTray;
pub const setTrayTitle = cef_public_api.setTrayTitle;
pub const setTrayTooltip = cef_public_api.setTrayTooltip;
pub const trayGetBounds = cef_public_api.trayGetBounds;
pub const setTrayMenu = cef_public_api.setTrayMenu;
pub const destroyTray = cef_public_api.destroyTray;
pub const NotificationEmitHandler = cef_public_api.NotificationEmitHandler;
pub const setNotificationEmitHandler = cef_public_api.setNotificationEmitHandler;
pub const notificationIsSupported = cef_public_api.notificationIsSupported;
pub const notificationRequestPermission = cef_public_api.notificationRequestPermission;
pub const notificationShow = cef_public_api.notificationShow;
pub const notificationClose = cef_public_api.notificationClose;
pub const notificationRemoveAll = cef_public_api.notificationRemoveAll;
pub const notificationRemoveGroup = cef_public_api.notificationRemoveGroup;
pub const GlobalShortcutEmitHandler = cef_public_api.GlobalShortcutEmitHandler;
pub const GlobalShortcutStatus = cef_public_api.GlobalShortcutStatus;
pub const setGlobalShortcutEmitHandler = cef_public_api.setGlobalShortcutEmitHandler;
pub const globalShortcutRegister = cef_public_api.globalShortcutRegister;
pub const globalShortcutUnregister = cef_public_api.globalShortcutUnregister;
pub const globalShortcutUnregisterAll = cef_public_api.globalShortcutUnregisterAll;
pub const globalShortcutSetSuspended = cef_public_api.globalShortcutSetSuspended;
pub const globalShortcutIsSuspended = cef_public_api.globalShortcutIsSuspended;
pub const globalShortcutIsRegistered = cef_public_api.globalShortcutIsRegistered;
pub const WindowResizedHandler = cef_public_api.WindowResizedHandler;
pub const WindowMovedHandler = cef_public_api.WindowMovedHandler;
pub const WindowFocusHandler = cef_public_api.WindowFocusHandler;
pub const WindowBlurHandler = cef_public_api.WindowBlurHandler;
pub const WindowSimpleHandler = cef_public_api.WindowSimpleHandler;
pub const WindowWillResizeHandler = cef_public_api.WindowWillResizeHandler;
pub const WindowLifecycleHandlers = cef_public_api.WindowLifecycleHandlers;
pub const setWindowLifecycleHandlers = cef_public_api.setWindowLifecycleHandlers;
pub const MAX_DIALOG_BUTTONS = cef_public_api.MAX_DIALOG_BUTTONS;
pub const MAX_DIALOG_PATHS = cef_public_api.MAX_DIALOG_PATHS;
pub const MessageBoxStyle = cef_public_api.MessageBoxStyle;
pub const MessageBoxOpts = cef_public_api.MessageBoxOpts;
pub const MessageBoxResult = cef_public_api.MessageBoxResult;
pub const FileFilter = cef_public_api.FileFilter;
pub const OpenDialogOpts = cef_public_api.OpenDialogOpts;
pub const SaveDialogOpts = cef_public_api.SaveDialogOpts;
pub const showMessageBox = cef_public_api.showMessageBox;
pub const showErrorBox = cef_public_api.showErrorBox;
pub const showOpenDialog = cef_public_api.showOpenDialog;
pub const showSaveDialog = cef_public_api.showSaveDialog;

/// CEF process runtime/init — cef_runtime.zig 로 분리(동작 무변경).
pub const CefConfig = cef_public_api.CefConfig;
pub const executeSubprocess = cef_public_api.executeSubprocess;
pub const initialize = cef_public_api.initialize;

/// Browser-process IPC — cef_browser_ipc.zig 로 분리(동작 무변경).
pub const InvokeCallback = cef_public_api.InvokeCallback;
pub const EmitCallback = cef_public_api.EmitCallback;
pub const setInvokeHandler = cef_public_api.setInvokeHandler;
pub const setEmitHandler = cef_public_api.setEmitHandler;

/// CEF App handler/debug — cef_app_handler.zig 로 분리(동작 무변경).
pub const cefDebug = cef_public_api.cefDebug;
pub const diagPrintCefAbi = cef_public_api.diagPrintCefAbi;

/// Browser global state — cef_browser_state.zig 로 분리(동작 무변경).
pub const devtoolsClient = cef_public_api.devtoolsClient;
pub const currentBrowser = cef_public_api.currentBrowser;
pub const rememberMainBrowserIfUnset = cef_public_api.rememberMainBrowserIfUnset;
pub const isMainBrowser = cef_public_api.isMainBrowser;
pub const CEF_IPC_BUF_LEN = cef_public_api.CEF_IPC_BUF_LEN;

/// CefNative global registry — cef_native_registry.zig 로 분리(동작 무변경).
pub const globalNative = cef_public_api.globalNative;
pub const nativeAllocator = cef_public_api.nativeAllocator;

// ============================================
// CefNative lifecycle shell — cef_native.zig 로 분리(동작 무변경).
// ============================================
pub const CefNative = cef_public_api.CefNative;

// ============================================
// Browser IPC / deferred response — cef_browser_ipc.zig 로 분리(동작 무변경).
// capture_page CDP pending cleanup은 cef_pending_cleanup.zig 에서 합친다.
// ============================================
pub const cefDeferResponse = cef_public_api.cefDeferResponse;
pub const cefCompletePending = cef_public_api.cefCompletePending;
pub const purgePendingResponsesForBrowser = cef_public_api.purgePendingResponsesForBrowser;

pub const PDF_PATH_STACK_BUF = cef_public_api.PDF_PATH_STACK_BUF;
pub const EVENT_PDF_PRINT_FINISHED = cef_public_api.EVENT_PDF_PRINT_FINISHED;
pub const EVENT_PAGE_CAPTURED = cef_public_api.EVENT_PAGE_CAPTURED;

// ============================================
// Shared CEF utility helpers — cef_util.zig 로 분리(동작 무변경).
// Public API는 기존 cef.zig 심볼을 유지한다.
// ============================================

pub const nullTerminateOrTruncate = cef_public_api.nullTerminateOrTruncate;
pub const asPtr = cef_public_api.asPtr;
pub const zeroCefStruct = cef_public_api.zeroCefStruct;
pub const setCefString = cef_public_api.setCefString;
pub const setUrlOrBlank = cef_public_api.setUrlOrBlank;
pub const isAboutBlankUrl = cef_public_api.isAboutBlankUrl;
pub const getArgString = cef_public_api.getArgString;
pub const traceIpcEnabled = cef_public_api.traceIpcEnabled;
pub const traceDragRegionEnabled = cef_public_api.traceDragRegionEnabled;
pub const cefStringToUtf8 = cef_public_api.cefStringToUtf8;
pub const cefUserfreeToUtf8 = cef_public_api.cefUserfreeToUtf8;
pub const getMainFrameUrl = cef_public_api.getMainFrameUrl;
pub const frameIsMain = cef_public_api.frameIsMain;
pub const initBaseRefCounted = cef_public_api.initBaseRefCounted;
pub const writeCStr = cef_public_api.writeCStr;

/// Browser navigation/eval/zoom helpers — cef_browser_control.zig 로 분리(동작 무변경).
pub const navigate = cef_public_api.navigate;
pub const evalJs = cef_public_api.evalJs;
pub const zoomChange = cef_public_api.zoomChange;
pub const zoomSet = cef_public_api.zoomSet;

pub const screenGetCursorPoint = cef_public_api.screenGetCursorPoint;

// Shared CoreFoundation data helpers — cef_core_foundation.zig 로 분리(동작 무변경).
pub const CFDataCreate = cef_public_api.CFDataCreate;
pub const CFDataGetBytePtr = cef_public_api.CFDataGetBytePtr;
pub const CFDataGetLength = cef_public_api.CFDataGetLength;
pub const CFRelease = cef_public_api.CFRelease;

// Native window handle lookup — cef_native_window_handles.zig 로 분리(동작 무변경).
pub const windowsEntryHwnd = cef_public_api.windowsEntryHwnd;
pub const collectTopLevelNativeWindowHandles = cef_public_api.collectTopLevelNativeWindowHandles;
pub const nsWindowForBrowserHandle = cef_public_api.nsWindowForBrowserHandle;

// macOS default app menu helpers — cef_mac_app_menu.zig 로 분리(동작 무변경).
pub const setupMainMenu = cef_public_api.setupMainMenu;
pub const addDefaultAppMenu = cef_public_api.addDefaultAppMenu;
pub const createMenu = cef_public_api.createMenu;
pub const addSubmenuItem = cef_public_api.addSubmenuItem;
pub const allocNSMenuItem = cef_public_api.allocNSMenuItem;
pub const ensureQuitTarget = cef_public_api.ensureQuitTarget;

// ============================================
// Win32 message pump thread — cef_win_pump.zig 로 분리(동작 무변경).
// Public API는 기존 cef.zig 심볼을 유지한다.
// ============================================
pub const win_pump = cef_public_api.win_pump;

// CEF message-loop lifecycle — cef_message_loop.zig 로 분리(동작 무변경).
pub const run = cef_public_api.run;
pub const shutdown = cef_public_api.shutdown;
pub const quit = cef_public_api.quit;
pub const quitAfterNextResponse = cef_public_api.quitAfterNextResponse;
pub const BeforeQuitFn = cef_public_api.BeforeQuitFn;
pub const setBeforeQuitHandler = cef_public_api.setBeforeQuitHandler;
pub const fireBeforeQuit = cef_public_api.fireBeforeQuit;

// ============================================
// Window display/load/find/print handlers — cef_window_display.zig 로 분리(동작 무변경).
// Public API는 기존 cef.zig 심볼을 유지하고, CEF client callbacks만 모듈로 위임한다.
// ============================================

pub const MAX_TITLE_BYTES = cef_public_api.MAX_TITLE_BYTES;
pub const WindowReadyToShowHandler = cef_public_api.WindowReadyToShowHandler;
pub const WindowTitleChangeHandler = cef_public_api.WindowTitleChangeHandler;
pub const WindowFindResultHandler = cef_public_api.WindowFindResultHandler;
pub const WindowDisplayHandlers = cef_public_api.WindowDisplayHandlers;
pub const setWindowDisplayHandlers = cef_public_api.setWindowDisplayHandlers;

// ============================================
// session.webRequest API — cef_web_request.zig 로 분리(동작 무변경).
// Request handler는 resource request callback만 위임하고, main.zig __core__는
// 기존 cef.webRequest* API 를 그대로 호출한다.
// ============================================
pub const WebRequestEmitFn = cef_public_api.WebRequestEmitFn;
pub const setWebRequestEmitHandler = cef_public_api.setWebRequestEmitHandler;
pub const emitWebRequestPayload = cef_public_api.emitWebRequestPayload;
pub const webRequestSetBlockedUrls = cef_public_api.webRequestSetBlockedUrls;
pub const webRequestSetListenerFilter = cef_public_api.webRequestSetListenerFilter;
pub const webRequestSetRequestHeaders = cef_public_api.webRequestSetRequestHeaders;
pub const webRequestPendingDrops = cef_public_api.webRequestPendingDrops;
pub const webRequestResolve = cef_public_api.webRequestResolve;

// CEF client vtable glue lives in cef_client_handler.zig.
// Browser process message callback and invoke/emit dispatch live in cef_browser_ipc.zig.

// ============================================
// CEF DevTools / Keyboard / Life Span Handler — cef_devtools.zig,
// cef_keyboard_handler.zig, cef_life_span_handler.zig 로 분리(동작 무변경).
// ============================================

pub const devtoolsHost = cef_public_api.devtoolsHost;
pub const hasDevTools = cef_public_api.hasDevTools;
pub const lookupDevToolsInspectee = cef_public_api.lookupDevToolsInspectee;
pub const openDevTools = cef_public_api.openDevTools;
pub const closeDevTools = cef_public_api.closeDevTools;
pub const toggleDevTools = cef_public_api.toggleDevTools;

// ============================================
// CEF Render Process Handler — cef_render_handler.zig 로 분리(동작 무변경).
// ============================================

// ============================================
// Custom Scheme: suji:// — cef_scheme.zig 로 분리(동작 무변경).
// ============================================

pub const setDistPath = cef_public_api.setDistPath;
pub const registerSchemeHandlerFactory = cef_public_api.registerSchemeHandlerFactory;
pub const buildDefaultCsp = cef_public_api.buildDefaultCsp;
pub const setCspValue = cef_public_api.setCspValue;

/// 플랫폼별 윈도우 초기화 옵션. CefConfig(process-level)와 분리 — per-window 속성.
/// Appearance / Constraints는 window 모듈 sub-struct를 그대로 재사용 (3중 정의 회피).
pub const WindowInitOpts = cef_public_api.WindowInitOpts;
pub const initWindowInfo = cef_public_api.initWindowInfo;
pub const MacWindowHandles = cef_public_api.MacWindowHandles;
pub const NSPoint = cef_public_api.NSPoint;
pub const NSSize = cef_public_api.NSSize;
pub const NSRect = cef_public_api.NSRect;
pub const cefViewsHandleToNSWindow = cef_public_api.cefViewsHandleToNSWindow;
pub const applyCefViewsMacWindowOptions = cef_public_api.applyCefViewsMacWindowOptions;
pub const attachMacChildWindow = cef_public_api.attachMacChildWindow;
pub const detachMacChildWindow = cef_public_api.detachMacChildWindow;
pub const orderMacWindowFront = cef_public_api.orderMacWindowFront;
pub const orderMacWindowOut = cef_public_api.orderMacWindowOut;
pub const setMacWindowFrameRaw = cef_public_api.setMacWindowFrameRaw;
pub const nsViewBounds = cef_public_api.nsViewBounds;
pub const childWindowFrameForBounds = cef_public_api.childWindowFrameForBounds;
pub const applyBackgroundColor = cef_public_api.applyBackgroundColor;
pub const closeMacWindow = cef_public_api.closeMacWindow;
pub const setMacWindowTitle = cef_public_api.setMacWindowTitle;
pub const setMacWindowBounds = cef_public_api.setMacWindowBounds;
pub const setMacContentMinSize = cef_public_api.setMacContentMinSize;
pub const setMacContentMaxSize = cef_public_api.setMacContentMaxSize;
pub const setMacStyleMaskBit = cef_public_api.setMacStyleMaskBit;
pub const setMacZoomButtonEnabled = cef_public_api.setMacZoomButtonEnabled;
pub const setMacMovable = cef_public_api.setMacMovable;
pub const setMacIgnoresMouseEvents = cef_public_api.setMacIgnoresMouseEvents;
pub const setMacCollectionBehaviorBit = cef_public_api.setMacCollectionBehaviorBit;
pub const setMacWindowSharingType = cef_public_api.setMacWindowSharingType;
pub const getMacWindowBounds = cef_public_api.getMacWindowBounds;
pub const getMacWindowContentBounds = cef_public_api.getMacWindowContentBounds;
pub const setMacWindowContentBounds = cef_public_api.setMacWindowContentBounds;
