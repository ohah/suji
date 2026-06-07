# Electron 패리티 전수조사 (자동 생성 트리아지)

> `@suji/api` + `@suji/node` 표면을 Electron 공식 API 21개 도메인과 비교 (워크플로 fan-out + adversarial verify).
> 524 에이전트, 500 주장 → **196개 고유 FIX** 분류. 아래는 심각도순 백로그.

## ✅ 이번에 수정됨 (창 생명주기 — Zig 백엔드 기존 구현을 JS/Node SDK 노출)

`windows.*` + `BrowserWindow` 클래스 (suji-js + suji-node 양쪽): `minimize`/`maximize`/`unmaximize`/`restore`/`show`/`hide`/`close`/`setFullScreen`/`isMinimized`/`isMaximized`/`isFullScreen`. 모두 Zig dispatcher(`minimize`/`maximize`/`unmaximize`/`restore_window`/`set_visible`/`destroy_window`/`set_fullscreen`/`is_minimized`/`is_maximized`/`is_fullscreen`)에 이미 존재 → 래퍼만 추가(무위험).

## 백로그 (심각도순 — 대부분 신규 native/Zig 핸들러 필요)


### BrowserWindow

- ~~**[high]** `BrowserWindow.minimize()`~~ ✅ — Add windows.minimize(windowId: number) and BrowserWindow.minimize() instance method to packages/suji-js/src/index.ts following the coreCall({ cmd: "minimize", windowId }) pattern (like setBounds at li
- ~~**[high]** `BrowserWindow.maximize()`~~ ✅ — Add maximize() and unmaximize() methods to windows namespace and BrowserWindow class in packages/suji-js/src/index.ts and packages/suji-node/src/index.ts. Follow the exact pattern of minimize(): coreC
- ~~**[high]** `windows.minimize() / windows.maximize() / windows.restore() / windows.unmaximize() and BrowserWindow methods`~~ ✅ — Add methods to windows namespace and BrowserWindow class in both SDKs:  **packages/suji-js/src/index.ts (lines ~420 after hasShadow)**: - `windows.minimize(windowId: number): Promise<WindowOpResponse>
- ~~**[high]** `BrowserWindow.show() / BrowserWindow.hide()`~~ ✅ — Add two methods to windows namespace in packages/suji-js/src/index.ts: (1) show(windowId: number) calling coreCall with cmd:"set_visible" and visible:true, (2) hide(windowId: number) with visible:fals
- ~~**[high]** `BrowserWindow.hide()`~~ ✅ — Add windows.show(windowId: number) and windows.hide(windowId: number) to the windows namespace in packages/suji-js/src/index.ts (calling coreCall with cmd "set_visible" like setViewVisible does for vi
- ~~**[high]** `BrowserWindow.close()`~~ ✅ — Add windows.close(windowId: number) method in packages/suji-js/src/index.ts and packages/suji-node/src/index.ts that calls coreCall with cmd: "destroy_window". Add BrowserWindow.close() instance metho
- ~~**[high]** `destroy()`~~ ✅ (#101) — Add `windows.destroy(windowId: number): Promise<WindowOpResponse>` to the windows namespace in packages/suji-js/src/index.ts (around line 400, after setBounds). Add corresponding `destroy()` method to
- ~~**[high]** `BrowserWindow.focus()`~~ ✅ — Add windows.focus(windowId: number) method to the windows namespace in packages/suji-js/src/index.ts (around line 300-310, following the pattern of setTitle/setBounds). The method should call coreCall
- ~~**[high]** `BrowserWindow.blur() / BrowserWindow.focus()`~~ ✅ — Add two IPC command handlers in window_ipc.zig (following the pattern of `handleSetTitle`, `handleSetBounds`): `handleFocus(windowId)` and `handleBlur(windowId)`. These should call `wm.focus(id)` and 
- ~~**[high]** `BrowserWindow.isFocused()`~~ ✅ — Add isFocused(windowId) query method: (1) Add fn to window.zig Native vtable returning bool, implement in CEF with native window focus check, (2) add handleIsFocused in window_ipc.zig returning {cmd, 
- ~~**[high]** `BrowserWindow.isVisible()`~~ ✅ — Add isVisible() getter by: (1) Implement WindowManager.isVisible(id: u32) in window.zig (lines ~1115-1125, mirror isLoading pattern); (2) Add window_ipc.handleIsVisible() in window_ipc.zig following h
- ~~**[high]** `BrowserWindow.isMaximized()`~~ ✅ — Add three getter methods to windows namespace and BrowserWindow class in packages/suji-js/src/index.ts and packages/suji-node/src/index.ts: (1) Define IsMinimizedResponse, IsMaximizedResponse, IsFulls
- ~~**[high]** `BrowserWindow.isMinimized()`~~ ✅ — Add isMinimized, isMaximized, isFullscreen to suji-js and suji-node packages using existing coreCall pattern.
- ~~**[high]** `isNormal()`~~ ✅ — 1. Add `handleIsNormal` to /src/core/window_ipc.zig (use handleStateGet pattern like isMinimized, check !minimized && !maximized && !fullscreen). 2. Wire cmd 'is_normal' through main.zig dispatcher. 3
- ~~**[high]** `BrowserWindow.isFullScreen()`~~ ✅ — Add isFullScreen() method to windows namespace and BrowserWindow class in both packages/suji-js/src/index.ts and packages/suji-node/src/index.ts, mirroring the pattern of existing query methods like i
- ~~**[high]** `BrowserWindow.getSize()`~~ ✅ — Add windows.getSize(windowId: number) method to @suji/api and @suji/node returning Promise<{width: number; height: number}>. Implement corresponding get_bounds IPC handler in Zig WindowManager (src/co
- ~~**[high]** `BrowserWindow.getPosition() / BrowserWindow.getBounds()`~~ ✅ — Add `handleGetBounds(window_id: u32, response_buf: []u8, wm: *window.WindowManager) ?[]const u8` and convenience `handleGetPosition(window_id: u32, response_buf: []u8, wm: *window.WindowManager) ?[]co
- ~~**[high]** `BrowserWindow.isAlwaysOnTop()`~~ ✅ — Add handleSetAlwaysOnTop and handleIsAlwaysOnTop to window_ipc.zig following the pattern of setHasShadow/hasShadow. Add routing in main.zig for set_always_on_top and is_always_on_top commands. Add set
- ~~**[high]** `BrowserWindow.getAllWindows()`~~ ✅ — Add `static async getAllWindows(): Promise<BrowserWindow[]>` method to the `BrowserWindow` class in both `packages/suji-js/src/index.ts` (around line 578-600) and `packages/suji-node/src/index.ts` (ar
- ~~**[high]** `BrowserWindow.getFocusedWindow()`~~ ✅ — Add focused window tracking to Suji: (1) Add optional_u32 focused_window_id field to WindowManager, initialized to null. (2) Update focus/blur handlers in cef.zig to set/clear this field. (3) Add pub 
- ~~**[high]** `minimize event: window:minimize`~~ ✅ — Add minimize() and restore() methods to the windows object in packages/suji-js/src/index.ts (lines 293-569) and packages/suji-node/src/index.ts (lines 453-623), following the same pattern as other win

### app

- ~~**[high]** `app.releaseSingleInstanceLock()`~~ ✅ (#94/#95/#96) — Implement three companion methods alongside existing app.* APIs: (1) app.requestSingleInstanceLock() → IPC handler in /src/main.zig + JS/Node SDK wrappers, (2) app.releaseSingleInstanceLock() → same p

### nativeTheme

- ~~**[high]** `nativeTheme.themeSource (getter)`~~ ✅ — Add getThemeSource() async method to @suji/api and @suji/node that returns Promise<ThemeSource>. Implement new IPC command `native_theme_get_source` in src/main.zig (lines 1855+) dispatching to cef.na

### notification

- ~~**[high]** `Notification.removeAll()`~~ ✅ — Add notification.removeAll() method: (1) Zig: add notification_remove_all command handler in src/main.zig/cef.zig that calls cef.notificationRemoveAll() wrapping UNUserNotificationCenter.removeAllDeli

### powerMonitor

- ~~**[high]** `powerMonitor.isOnBatteryPower()`~~ ✅ — Add isOnBatteryPower() method to powerMonitor API: (1) Extend src/platform/power_monitor.m with IOPowerSources-based battery detection function querying kIOPSNameKey and kIOPSPowerSourceStateKey; (2) 

### screen

- ~~**[high]** `screen.getDisplayMatching(rect)`~~ ✅ — Add getDisplayMatching(rect: {x, y, width, height}): Promise<Display> to both suji-js and suji-node. Implement backend IPC handler screen_get_display_matching in src/main.zig that passes rect to cef.s

### session

- 🔒 **[high · 보류 — CEF 본질적 제약]** `session.cookies.changed event` — Electron 은 Chromium network service 의 `CookieManager.AddCookieChangeListener`(CookieStore 변경 옵저버)를 래핑해 지원하지만, CEF 의 `cef_cookie_manager_t` 는 set/delete/visit/flush 만 노출하고 **변경 옵저버 API 가 없다**(CEF 는 Chromium 의 부분집합만 surface). 폴링(주기적 스냅샷 비교)으로만 흉내 가능 → 부정확/비효율이라 **지원 우선 보류**. CEF 가 cookie-change 콜백을 노출하면 재개. (원안) Add session:cookies-changed event emission on cookie modifications via cef_cookie_manager_t callbacks (if CEF expo
- ~~**[high]** `session.setProxy(config)`~~ ✅ (#99) — Add session.setProxy(config) to all SDKs. Define ProxyConfig interface (proxyRules, pacScript, etc.). Backend: implement session_set_proxy Zig command in cef.zig, wired to CEF proxy API. Pattern: sync
- 🔒 **[high · 보류 — CEF 본질적 제약]** `session.setSSLConfig(config)` — Electron 은 Chromium network service 의 `network::mojom::SSLConfig` 를 직접 설정해 minVersion/maxVersion/cipher 를 런타임 제어하지만, CEF 엔 **런타임 SSL 설정 API 가 없다**(TLS 최소버전 등은 시작-시 `--ssl-version-min` 명령행 플래그 정도만; 세션별 런타임 pref 부재). 깔끔한 런타임 동등 구현 불가 → **지원 우선 보류**. CEF 가 SSLConfig 인터페이스를 노출하면 재개. (원안) Add session.setSSLConfig(config) via "session_set_ssl_config" command with minVersion/maxVersion/disabledCipherSuites parameters. (
- **[high]** `session.setPermissionRequestHandler` — Implement permission handler in Zig, CEF, and all SDKs

### shell

- ~~**[high]** `shell.openPath`~~ ✅ — Update packages/suji-js and packages/suji-node openPath implementations: change return type to Promise<string>, return r.error || "" instead of boolean

### BrowserWindow

- ~~**[medium]** `minimize()`~~ ✅ — Add `windows.minimize(windowId)` and `BrowserWindow.minimize()` methods to packages/suji-js/src/index.ts. Mirror the pattern used for other window operations like setTitle (lines 302-304) and toggleDe
- ~~**[medium]** `windows.setFullScreen(windowId: number, flag: boolean): Promise<WindowOpResponse>`~~ ✅ — Add windows.setFullScreen(windowId: number, flag: boolean) and windows.isFullscreen(windowId: number) methods to the windows namespace in both @suji/api (packages/suji-js/src/index.ts) and @suji/node 
- **[medium]** `windows.setSize(windowId: number, width: number, height: number, animate?: boolean)` — Add a setSize(windowId: number, width: number, height: number, animate?: boolean) convenience method to both packages/suji-js/src/index.ts (in the windows namespace and BrowserWindow class) and packag
- **[medium]** `setPosition(x: number, y: number, animate?: boolean)` — Add setPosition convenience method to the SDKs: (1) Extend Zig Native.VTable in src/core/window.zig with set_position(handle, x, y) that calls set_bounds with width=0, height=0 to signal position-only
- **[medium]** `getMinimumSize()` — Implement the complete getter/setter chain for minimum and maximum size constraints: (1) Add WindowManager methods: setMinimumSize(id, w, h), getMinimumSize(id) → {width, height}, setMaximumSize(id, w
- **[medium]** `BrowserWindow.setMinimumSize(width: number, height: number)` — Add the following methods to the JS SDK: 1) In windows namespace (packages/suji-js/src/index.ts ~line 425): `setMinimumSize(windowId: number, width: number, height: number): Promise<WindowOpResponse>`
- **[medium]** `BrowserWindow.setResizable(resizable: boolean)` — Add windows.setResizable(windowId: number, resizable: boolean) to packages/suji-js/src/index.ts (matching pattern of setOpacity/setAudioMuted). Implement set_resizable command handler in src/main.zig 
- **[medium]** `BrowserWindow.setMovable(movable: boolean)` — Add windows.setMovable(windowId: number, movable: boolean) by: (1) Adding a movable boolean field to WindowManager's window properties (src/core/window.zig); (2) Implementing platform-specific setters
- **[medium]** `BrowserWindow.setMaximizable(maximizable: boolean)` — Add set_minimizable and set_maximizable handlers to src/core/window_ipc.zig, wire them to WindowManager method vtable, and expose via windows.setMaximizable(windowId, maximizable) in packages/suji-js/
- **[medium]** `BrowserWindow.setFullScreenable` — Add windows.setFullScreenable(windowId: number, fullscreenable: boolean) and windows.isFullScreenable(windowId: number) to packages/suji-js/src/index.ts, plus corresponding setFullScreenable and isFul
- **[medium]** `BrowserWindow.setClosable(closable: boolean)` — Add three-part implementation following sibling methods (setResizable pattern): (1) Add handleSetClosable and handleIsClosable in src/core/window_ipc.zig with JSON parsing and WindowManager delegation
- **[medium]** `isClosable()` — Add window constraint query/setter APIs for closable/minimizable/maximizable parity with Electron. Implementation incomplete: C ABI vtable designed (WINDOW_API.md) but Constraints struct (window.zig) 
- **[medium]** `BrowserWindow.setFocusable(focusable: boolean)` — Add `setFocusable(windowId: number, focusable: boolean): Promise<WindowOpResponse>` to the `windows` namespace in packages/suji-js/src/index.ts (following the pattern of `setHasShadow`), and add a cor
- **[medium]** `BrowserWindow.setEnabled(enable: boolean): void` — 1. Add `set_enabled: *const fn (id: u32, enabled: i32) callconv(.c) void` to `SujiWindowAPI` in `WINDOW_API.md` and `src/core/window.zig`. 2. Add `enabled: bool = true` field to `Window` struct. 3. Im
- **[medium]** `BrowserWindow.prototype.setKiosk(flag: boolean)` — Add `setKiosk(windowId: number, flag: boolean)` and `isKiosk(windowId: number)` to the `windows` namespace in /packages/suji-js/src/index.ts (lines 293-569) and /packages/suji-node/src/index.ts (lines

### WebContentsView

- **[medium]** `View.getBounds()` — Add getViewBounds handler in window_ipc.zig mirroring the pattern of existing view getters. Add public getViewBounds method to WindowManager in window.zig that retrieves the bounds from the stored Win
- **[medium]** `View.setBackgroundColor(color)` — Add windows.setViewBackgroundColor(viewId: number, color: string) method in packages/suji-js/src/index.ts (mirror of windows.setBackgroundColor but for views, using cmd 'set_view_background_color'). T
- **[medium]** `BrowserWindow facade for views` — Export a WebContentsView class in packages/suji-js/src/index.ts (after BrowserWindow, around line 708) that mirrors BrowserWindow's pattern: static create(opts): Promise<WebContentsView> delegating to

### app

- **[medium]** `app.before-quit event` — Add app:before-quit event hook to Suji quit() path. Modify the quit flow in Zig core to emit a 'app:before-quit' event before termination begins, allowing handlers to call an event.preventDefault() eq
- **[medium]** `app.removeAsDefaultProtocolClient(protocol: string, path?: string, args?: string[]) : boolean` — Add app.setAsDefaultProtocolClient(protocol: string, path?: string, args?: string[]): Promise<boolean> and app.removeAsDefaultProtocolClient(protocol: string, path?: string, args?: string[]): Promise<
- ~~**[medium]** `app.requestSingleInstanceLock()`~~ ✅ (#94) — Add app.requestSingleInstanceLock(additionalData?) method across all SDKs. Zig: implement with temp file lock or NSFileManager (macOS). JS/Node: expose as async method returning boolean. Rust/Go: wrap
- ~~**[medium]** `hasSingleInstanceLock() method`~~ ✅ (#94) — Implement three methods in the app object across both suji-js and suji-node SDKs: (1) app.requestSingleInstanceLock() → Promise<boolean> indicating lock acquisition success, (2) app.hasSingleInstanceL

### clipboard

- **[medium]** `clipboard.writeBookmark(title, url[, type])` — Add clipboard.writeBookmark(title: string, url: string, type?: 'clipboard' | 'selection') to Suji. Implementation: (1) Add Zig handler in src/main.zig parsing title/url/type params, call cef.clipboard
- **[medium]** `clipboard.writeFindText(text: string)` — Add writeFindText(text: string) → Promise<boolean> to Suji's clipboard module: (1) src/platform/cef.zig: new pub fn clipboardWriteFindText(text: []const u8) bool using objc msgSend to get NSPasteboard
- **[medium]** `clipboard.write(data[, type])` — Implement `clipboard.write(data: {text?: string, html?: string, image?: string, rtf?: string}, type?: 'clipboard' | 'selection'): Promise<boolean>` in all SDKs (@suji/api, @suji/node, @suji/js, Zig, R

### globalShortcut

- **[medium]** `globalShortcut.registerAll` — Add `registerAll(accelerators: string[], click: string): Promise<boolean>` method to: (1) packages/suji-js/src/index.ts—loop through accelerators calling existing register() or make single IPC call wi
- ~~**[medium]** `globalShortcut.unregisterAll`~~ ✅ — Change return type of unregisterAll from Promise<boolean> to Promise<void> in: (1) packages/suji-js/src/index.ts lines 1001-1003, and (2) packages/suji-node/src/index.ts lines 1141-1144. This matches 
- **[medium]** `globalShortcut.setSuspended` — Add setSuspended(suspended: boolean) and isSuspended() to Suji's globalShortcut. 1) Zig/main.zig: add global_shortcut_set_suspended and global_shortcut_is_suspended IPC handlers that toggle a module-l
- **[medium]** `globalShortcut.isSuspended` — Add globalShortcut.isSuspended() and globalShortcut.setSuspended(bool). Implementation: (1) Add static bool g_suspended in src/platform/global_shortcut.m with getter/setter C functions, (2) Wire "glob

### ipc

- **[medium]** `ipcRenderer.removeAllListeners([channel])` — In /Users/yoonhb/Documents/workspace/suji/packages/suji-js/src/index.ts (line 136-139): Add a TypeScript overload: `export function off(event?: string): void;` then update implementation to handle und
- **[medium]** `ipcMainHandleOnce` — Add handleOnce to packages/suji-node/src/index.ts after handle() at line 114. Wrapper that registers handler and auto-unregisters after first invocation using closure variable. Maintains HandlerFn typ

### menu

- **[medium]** `Menu.getApplicationMenu()` — Add Menu.getApplicationMenu() getter across all SDKs. Implementation: (1) In cef.zig, add a global variable to store the current menu items when setApplicationMenu succeeds. (2) Add a new IPC handler 
- **[medium]** `Menu.sendActionToFirstResponder` — Add menu.sendActionToFirstResponder(action: string): Promise<boolean> as a macOS-only API across all SDKs. In Zig core (cef.zig), implement a new cmd handler invoking NSApplication.sendAction(selector
- **[medium]** `menu.items / menu.getApplicationMenu()` — Add menu.getApplicationMenu(): Promise<MenuItem[] | null> to both @suji/api (frontend) and @suji/node (backend) SDKs. Backend implementation: Store the current menu items in Suji core when setApplicat
- **[medium]** `menu-will-close event` — Add `menu:will-close` (and ideally `menu:will-show` for parity) event emissions around the NSMenu modal popup lifecycle in cef.zig. Specifically: (1) Emit menu:will-show before line 3097's popUpMenuPo
- **[medium]** `Menu.insert(pos: Integer, menuItem: MenuItem)` — Add Menu.insert(pos: number, menuItem: MenuItem) method to both @suji/api and @suji/node packages. Implementation: new IPC cmd menu_insert with pos + menuItem args, routed to cef.zig's menu handler (N
- **[medium]** `Menu.getMenuItemById(id: string)` — Add optional `id?: string` field to MenuCommandItem, MenuCheckboxItem, and MenuSubmenuItem types across all SDKs (packages/suji-js/src/index.ts, packages/suji-node/src/index.ts, crates/suji-rs, sdks/s
- **[medium]** `MenuItem.role property` — Add optional `role?: string` field to MenuCommandItem interface in packages/suji-js/src/index.ts (line 934-939) and packages/suji-node/src/index.ts (line 1093-1098). Extend cef.ApplicationMenuItem.ite
- **[medium]** `MenuItem.accelerator property` — Add optional `accelerator?: string` field to MenuCommandItem and MenuCheckboxItem types in packages/suji-js/src/index.ts and packages/suji-node/src/index.ts. Parse accelerator in src/platform/cef.zig 
- **[medium]** `MenuItem.icon property` — Add optional `icon?: string` field to MenuCommandItem, MenuCheckboxItem, and MenuSubmenuItem interfaces in packages/suji-js/src/index.ts. Update Zig ApplicationMenuItem union in src/platform/cef.zig t
- **[medium]** `MenuItem.visible property` — Add optional visible?: boolean (default true) field to MenuCommandItem, MenuCheckboxItem, and MenuSubmenuItem interfaces in packages/suji-js/src/index.ts. Update JSON parsing in src/main.zig's parseAp
- **[medium]** `MenuItem constructor options completeness` — Add support for high-value MenuItem fields in phases: (1) Phase A (trivial): `id` (string identifier, no UI side-effect), `visible` (boolean flag, reuse enabled logic pattern). (2) Phase B (moderate):

### nativeImage

- **[medium]** `image.isEmpty()` — Add nativeImage.isEmpty(path: string) → Promise<boolean> to packages/suji-js/src/index.ts (lines 1070+) and packages/suji-node/src/index.ts. Implementation: async function calling getSize() internally
- **[medium]** `nativeImage.isTemplateImage()` — Add isTemplateImage() instance method to nativeImage in both @suji/api (packages/suji-js/src/index.ts) and @suji/node (packages/suji-node/src/index.ts). Return type: Promise<boolean>. Implementation m

### nativeTheme

- **[medium]** `nativeTheme.shouldUseHighContrastColors` — Add shouldUseHighContrastColors() async method to nativeTheme export in both @suji/api (packages/suji-js/src/index.ts:1090+) and @suji/node (packages/suji-node/src/index.ts:937+), following the existi
- **[medium]** `nativeTheme.prefersReducedTransparency` — Add prefersReducedTransparency() method to nativeTheme in both packages/suji-js/src/index.ts and packages/suji-node/src/index.ts. Implement native accessor in src/platform/nativetheme.m via NSWorkspac

### notification

- ~~**[medium]** `notification.show()`~~ ✅ — Create a `Notification` class mirroring Electron's pattern. Signature: `class Notification { constructor(opts: NotificationOptions); async show(): Promise<{notificationId: string; success: boolean}>; 
- **[medium]** `Notification.removeGroup(groupId)` — Add notification.removeGroup(groupId: string) → Promise<boolean>. Steps: (1) Extend NotificationOptions with optional groupId: string; (2) Pass groupId through show() IPC to native layer (modify src/m
- **[medium]** `NotificationOptions.id` — Add `id?: string` to NotificationOptions interface in packages/suji-js/src/index.ts (line 835). In src/main.zig notification_show handler (line 2472), extract the optional id field using util.extractJ
- **[medium]** `notification.id (readonly getter)` — Introduce a Notification class (similar to BrowserWindow) with: constructor(options: NotificationOptions & {id?: string}), readonly id property (exposed post-construction), and async show()/close() me

### powerMonitor

- ~~**[medium]** `powerMonitor.getSystemIdleState(threshold: number)`~~ ✅ — Update TypeScript return type in packages/suji-js/src/index.ts:724 from Promise<'active' | 'idle'> to Promise<'active' | 'idle' | 'locked'> and the coreCall generic from { state: 'active' | 'idle' } t
- **[medium]** `powerMonitor.onBatteryPower (property)` — Implement isOnBatteryPower() method first (platform-specific: macOS via IOKit or IOPowerSources, fetch AC adapter status). Then add onBatteryPower as a getter property delegating to isOnBatteryPower()
- **[medium]** `powerMonitor.on('on-battery') event` — Extend src/platform/power_monitor.m to use IOPowerSources.framework for battery state detection. Add 'power:on-battery' and 'power:on-ac' event emissions via existing NSWorkspace observer callback pat
- **[medium]** `powerMonitor 'shutdown' event` — Add NSWorkspaceWillPowerOffNotification observer to power_monitor.m. Add onPowerOff method to SujiPowerObserver that calls callback with shutdown string. Register notification with NSWorkspace notific

### powerSaveBlocker

- **[medium]** `powerSaveBlocker.isStarted(id)` — Add isStarted(id: number) -> Promise<boolean> method to powerSaveBlocker in both @suji/api and @suji/node. Implement a new Zig command handler power_save_blocker_is_started in src/main.zig that mainta

### screen

- **[medium]** `display-added` — Add NSScreenDidChangeNotification observer in Zig core. Detect display additions/removals/changes via NSScreen diffing. Emit screen:display-added, screen:display-removed, screen:display-metrics-change
- **[medium]** `display-removed event (and display-added, display-metrics-changed)` — Add NSScreen change monitoring in src/cef.zig (watchDisplayChanges loop similar to powerMonitor NSWorkspace observer). On NSScreenChangedNotification → emit `display:added` or `display:removed` events
- **[medium]** `display-metrics-changed event` — Implement three screen events (display-added, display-removed, display-metrics-changed) via macOS NSScreenDidChangeNotification observed by the Zig core. Wire events through existing EventBus emitting

### session

- ~~**[medium]** `session.cookies.set() / setCookie(details)`~~ ✅ — Add sameSite?: 'unspecified' | 'no_restriction' | 'lax' | 'strict' to CookieDescriptor in packages/suji-js/src/index.ts (line 1254) and packages/suji-node/src/index.ts (line 1359). Update src/main.zig
- ~~**[medium]** `cookies.remove(url, name) and cookies.set(details)`~~ ✅ — Change removeCookies and setCookie in packages/suji-js/src/index.ts (lines 1312-1335) to return Promise<void> instead of Promise<boolean>. On success:false from IPC, throw an Error instead of returnin
- **[medium]** `session.will-download event` — To implement parity: (1) Expose CEF's cef_download_handler_t in src/platform/cef.zig with OnBeforeDownload callback; (2) Fire session:will-download event from IPC with {url, suggestedFilename, mimeTyp
- **[medium]** `session.setDownloadPath(path)` — Add session.setDownloadPath(path) method across all 5 SDKs. Implementation requires: (1) CEF download_handler integration in cef.zig (OnBeforeDownload callback), (2) Zig SDK method in app.zig, (3) IPC
- **[medium]** `session.setCertificateVerifyProc(proc)` — Implement custom certificate verification callback via CEF RequestHandler.on_certificate_error. Add session.setCertificateVerifyProc(proc: (request) => verificationResult) method to: (1) cef.zig: regi

### tray

- **[medium]** `setToolTip(toolTip)` — Add setToolTip method alongside setTooltip in tray export (packages/suji-js/src/index.ts line 906), packages/suji-node/src/index.ts, and all language SDKs. Alternatively, rename setTooltip → setToolTi
- **[medium]** `tray.getBounds()` — Add getBounds(trayId: number): Promise<{x: number, y: number, width: number, height: number}> to the tray API in packages/suji-js/src/index.ts (and equivalent methods in suji-node and backend SDKs). I

### webContents

- **[medium]** `webContents.stop()` — Add windows.stop(windowId) method across all SDKs (Zig, Rust, Go, Node, Frontend JS). Implementation: (1) Add stop function pointer to Zig src/core/window.zig Native.VTable; (2) Implement stopImpl in 
- **[medium]** `webContents.insertCSS(css[, options])` — Add insertCSS(windowId: number, css: string, options?: {cssOrigin?: 'user'|'author'}): Promise<string> to windows.* API (both @suji/api frontend and @suji/node backend). Implementation: create a style
- **[medium]** `webContents.removeInsertedCSS(key)` — Add insertCSS(css: string) → Promise&lt;string&gt; and removeInsertedCSS(key: string) → Promise&lt;void&gt; to windows object in packages/suji-js/src/index.ts (lines ~320–330). Backend track CSS keys 
- **[medium]** `webContents.setWindowOpenHandler(handler)` — Implement setWindowOpenHandler(handler) in all 5 SDKs (Frontend @suji/api + Zig/Rust/Go/Node backends). Backend implementation: (1) Add CEF on_before_popup callback in cef.zig to intercept window.open
- ~~**[medium]** `stopFindInPage(windowId, action)`~~ ✅ — Change Suji's stopFindInPage signature from boolean clearSelection to string action enum. Update /packages/suji-js/src/index.ts:463 and /packages/suji-node/src/index.ts:581 to accept action: 'clearSel
- ~~**[medium]** `webContents.openDevTools([options])`~~ ✅ — Add optional options parameter to openDevTools across all SDKs (JS/Node/Zig/Rust/Go). Extend the IPC request in main.zig to accept optional mode/activate/title, parse them in window_ipc.handleOpenDevT

### webRequest

- **[medium]** `webRequest.onBeforeSendHeaders` — Extend WebRequestDecision interface to include optional requestHeaders field (Record<string, string | string[]>), matching Electron's callback signature. Update the native handler to respect the retur
- **[medium]** `webRequest.onHeadersReceived` — Add responseHeaders to webRequest:completed event (array of header objects), optionally implement onHeadersReceived listener method. Minimum: extend event payload to include headers captured from CEF 

### BrowserWindow

- **[low]** `getMaximumSize()` — Add windows.getMaximumSize(windowId): Promise<{width,height}> and windows.setMaximumSize(windowId, width, height): Promise<WindowOpResponse> methods. Mirror existing setZoomLevel/getZoomLevel pattern 
- **[low]** `BrowserWindow.isMovable()` — Add windows.isMovable(windowId: number): Promise<{ok: boolean; movable: boolean}> following the pattern of existing query methods (hasShadow, getOpacity). Implementation: (1) Add is_movable handler in
- **[low]** `isMaximizable()` — Add `isMaximizable(windowId: number)` query method to the `windows` namespace in packages/suji-js/src/index.ts (lines ~293-570), following the pattern of isAudioMuted(). Create an IsMaximizableRespons
- **[low]** `BrowserWindow.isFullScreenable()` — Add windows.setFullScreenable(windowId, fullscreenable) and windows.isFullScreenable(windowId) to suji-js and suji-node SDKs, mirroring the existing setFullscreen/isFullscreen implementation. Add Zig 
- **[low]** `BrowserWindow.isFocusable()` — Add isFocusable() query method (and optionally setFocusable() setter). Implementation mirrors existing query patterns: (1) add native vtable getter is_focusable in WINDOW_API.md design, (2) implement 
- **[low]** `BrowserWindow.isEnabled()` — Add window enabled-state query/setter following the existing pattern: (1) Add `isEnabled()` method to packages/suji-js/src/index.ts `windows` namespace and BrowserWindow class, routing to `is_enabled`
- **[low]** `BrowserWindow.isKiosk()` — Add setKiosk(windowId, flag) and isKiosk(windowId) to the Windows API. Implementation: (1) add handleSetKiosk/handleIsKiosk to window_ipc.zig (request/response structs + JSON serialization); (2) deleg
- **[low]** `BrowserWindow.flashFrame(flag: boolean)` — Implement windows.flashFrame(windowId: number, flag: boolean) following the pattern of adjacent taskbar methods (setSkipTaskbar, setProgressBar): (1) Add handler in src/platform/cef.zig dispatching to
- **[low]** `BrowserWindow.setSkipTaskbar(skip: boolean)` — Add handleSetSkipTaskbar in src/core/window_ipc.zig (pattern: SetSkipTaskbarReq struct + handler function calling wm.setSkipTaskbar(windowId, skip)), add corresponding setSkipTaskbar(windowId, skip) m
- **[low]** `BrowserWindow.isContentProtected()` — Add windows.isContentProtected(windowId: number) method to packages/suji-js/src/index.ts and packages/suji-node/src/index.ts, mirroring the pattern of isAudioMuted (queryable boolean, e.g. lines 396-3
- ~~**[low]** `window:unmaximize`~~ ✅ — Add window:unmaximize (alongside window:maximize, window:minimize, window:restore) to JSDoc comments in packages/suji-js/src/index.ts and packages/suji-node/src/index.ts documenting the window lifecyc

### WebContentsView

- ~~**[low]** `View.setBounds(bounds, animate?)`~~ ✅ — Add optional animate parameter to setViewBounds across the stack: (1) Update Zig Bounds struct or create AnimatedBounds variant with animate field; (2) Update window_ipc.zig SetViewBoundsReq to parse 

### app

- **[low]** `app.on('will-quit', ...)` — Emit 'app:will-quit' event in suji/src/main.zig cef.quit() cleanup phase (after all windows destroyed, before process exit). Implement as cancellable event via EventSink.preventDefault() pattern match
- **[low]** `open-url event` — Add deep-link URL event emission: (1) Define `pub const app_open_url = "app:open-url"` event constant in src/core/window.zig or src/core/events.zig alongside existing window events; (2) In src/platfor
- **[low]** `certificate-error event` — Expose app:certificate-error event on TLS cert verification failure. (1) Hook CEF's certificate verification callback in cef.zig (if not already wired). (2) Fire app:certificate-error IPC event with p
- **[low]** `select-client-certificate event` — To add select-client-certificate parity: (1) Design an app-level event listener API in Suji's core (e.g., core emitting 'app:select-client-certificate' events). (2) Hook CEF's cef_request_handler_t.on
- **[low]** `app.on('login') — HTTP basic auth event` — Wire cef_auth_callback_t into request handler (src/platform/cef.zig line 4739-4780). Register on_auth callback, emit app:login or webRequest:auth-required event following webRequest:before-request pat
- ~~**[low]** `second-instance event + requestSingleInstanceLock`~~ ✅ (#95/#96) — Add requestSingleInstanceLock() to @suji/node app module and @suji/api app module (macOS only, via lock file in app data dir or NSRunningApplication scan). Fire 'app:second-instance' event when second
- **[low]** `app.relaunch(options?) method` — Add app.relaunch(options?: {args?: string[], execPath?: string}) method to Suji:  1. **Frontend (@suji/api)**: Add method to app object in packages/suji-js/src/index.ts (around line 1751-1870). Signat
- **[low]** `app.isActive()` — Add app.isActive() method: (1) Zig handler in src/main.zig: new case "app_is_active" → `NSApplication.sharedApplication.isActive` (macOS) / false (other platforms), returns {success:true, active:bool}
- **[low]** `app.isHidden()` — Add app.isHidden() (macOS only, return false on other platforms) to all SDKs. Implementation: (1) Zig core handler app_is_hidden → NSApplication.isHidden query; (2) expose via __core__ IPC cmd; (3) ad
- **[low]** `app.show()` — Add app.show() method to both @suji/api and @suji/node packages that calls coreCall with cmd: "app_show" (Electron parity, macOS only). Implementation: mirror the existing app.hide() at index.ts ~1808
- **[low]** `app.setPath(name: string, path: string)` — Add app.setPath(name: AppPathName, path: string) → Promise<boolean> to both /packages/suji-js/src/index.ts and /packages/suji-node/src/index.ts. Implement as an async wrapper around core IPC command a
- **[low]** `app.getFileIcon(path, options?)` — Add `app.getFileIcon(path: string, options?: {size?: 'small'|'normal'|'large'}) → Promise<NativeImage>` to Suji. Implement in Zig using macOS NSWorkspace.icon(forFile:) to fetch the system icon for a 
- **[low]** `app.getLocaleCountryCode()` — Add `app.getLocaleCountryCode()` method: (1) cef.zig: implement `appGetLocaleCountryCode()` calling `NSLocale.countryCode` native API; (2) main.zig: add handler for `app_get_locale_country_code` IPC c
- **[low]** `app.addRecentDocument(path: string)` — Add app.addRecentDocument(path: string): Promise<boolean> to @suji/node and @suji/js. Implementation pattern: (1) Backend IPC command in cef.zig: cmd_app_add_recent_document → macOS NSDocumentControll
- **[low]** `app.clearRecentDocuments()` — Implement app.addRecentDocument(path) and app.clearRecentDocuments() methods. In Zig core (src/core/app.zig), add handler functions to register paths with NSDocumentController (macOS) and taskbar jump
- **[low]** `app.getRecentDocuments()` — Add app.getRecentDocuments() method to the app module in both @suji/api and @suji/node packages. Implementation should call macOS NSDocumentController.recentDocumentURLs and return string[] of file pa
- **[low]** `app.getApplicationNameForProtocol(url: string)` — Add app.getApplicationNameForProtocol(url: string) → Promise<string> to both suji-js and suji-node SDKs. Would require Zig backend implementation (NSWorkspace on macOS, equivalent on Linux/Windows) to
- **[low]** `app.getApplicationInfoForProtocol(url: string) → Promise<{icon: NativeImage, path: string, name: string}>` — Add `app.getApplicationInfoForProtocol(url: string)` to Suji's app module. Implementation: (1) Zig: Add handler in `src/main.zig` cefHandleCore (app_get_application_info_for_protocol cmd), delegate to
- **[low]** `app.configureHostResolver(options)` — Add app.configureHostResolver(options) to Suji's app namespace: (1) Core binding in src/platform/cef.zig with CEF request_context_settings_t configuration; (2) IPC handler in main.zig exposing `app_co
- **[low]** `app.isHardwareAccelerationEnabled()` — Add isHardwareAccelerationEnabled() to core app API (src/core/app.zig or cef.zig): Query CEF's GPU acceleration status and expose via new IPC handler in main.zig as `__core__:is_hardware_acceleration_
- **[low]** `app.getGPUInfo(infoType)` — Add app.getGPUInfo(infoType: 'basic'|'complete') to Suji's app module. Implementation: (1) Expose CEF GPU info getter in src/platform/cef.zig (CEF BrowserHost has GetVisibleNavigationEntry → GPU conte
- **[low]** `getLoginItemSettings(options?)` — Add app.getLoginItemSettings([options?]) to both @suji/api (frontend) and @suji/node (backend). Implement platform-specific handlers: (1) macOS: query NSWorkspace / LaunchServices / UserDefaults for a
- **[low]** `app.setLoginItemSettings(settings)` — Add app.setLoginItemSettings(settings) and app.getLoginItemSettings() methods to /Users/yoonhb/Documents/workspace/suji/packages/suji-js/src/index.ts and /packages/suji-node/src/index.ts, mirroring th
- **[low]** `app.isAccessibilitySupportEnabled()` — Add `isAccessibilitySupportEnabled(): Promise<boolean>` to the `app` module in both packages/suji-node/src/index.ts (line ~1620) and packages/suji-js/src/index.ts. Implementation: async invoke of a ne
- **[low]** `app.setAccessibilitySupportEnabled(enabled: boolean) and app.isAccessibilitySupportEnabled()` — Add accessibility support methods to the app namespace in /packages/suji-js/src/index.ts: setAccessibilitySupportEnabled(enabled: boolean) -> coreCall with cmd "app_set_accessibility_support_enabled",
- **[low]** `app.getAccessibilitySupportFeatures()` — Add app.getAccessibilitySupportFeatures() method returning string[] to all 5 SDK surfaces. Implementation would query CEF for active accessibility modes (screen reader, native APIs, etc.) and map to E
- **[low]** `setAccessibilitySupportFeatures` — Add setAccessibilitySupportFeatures(features: string[]): Promise<boolean> method to the app module in both @suji/js (packages/suji-js/src/index.ts around line 1523 where app object is defined) and @su
- **[low]** `app.setAboutPanelOptions(options) / app.showAboutPanel()` — Add two methods to the app namespace: 1. app.setAboutPanelOptions(options) — accepts {applicationName?, applicationVersion?, copyright?, credits?, version?, authors?, website?, iconPath?} 2. app.showA
- **[low]** `app.isEmojiPanelSupported()` — Add app.isEmojiPanelSupported() method to all SDK layers (suji-js, suji-node, Rust, Go) — follows the pattern of other app.* boolean checks like isPackaged()/isReady(). Backend: Zig core should expose
- **[low]** `app.isInApplicationsFolder() method` — Add app.isInApplicationsFolder() to both suji-js and suji-node SDK packages as async method returning Promise<boolean>. Native implementation: check if NSBundle.mainBundle.bundlePath starts with /Appl
- **[low]** `app.accessibilitySupportEnabled` — Add async getter/setter to app object: getAccessibilitySupportEnabled() and setAccessibilitySupportEnabled(enabled: boolean) in both suji-js and suji-node packages. Implement corresponding CEF IPC han
- **[low]** `applicationMenu property` — Add menu.getApplicationMenu() method (and optionally app.applicationMenu as a property accessor pair) to return the currently set Menu items or null. Implementation: (1) backend tracks current menu in

### clipboard

- **[low]** `clipboard.readFindText()` — Add readFindText(): Promise<string> to clipboard module. Implement in Zig core (src/main.zig): add clipboard_read_find_text command handler that calls new cef.clipboardReadFindText() function. In cef.
- ~~**[low]** `clipboard.has(format[, type])`~~ ✅ — Add optional `type?: 'clipboard' | 'selection'` parameter to `clipboard.has()` in packages/suji-js/src/index.ts and packages/suji-node/src/index.ts. Update Zig handler at src/main.zig:2204 to extract 

### dialog

- **[low]** `dialog.showMessageBox() — option: 'icon' (custom icon)` — Add optional 'icon' field to MessageBoxOptions interfaces (suji-js and suji-node packages), add corresponding 'icon: []const u8 = ""' field to MessageBoxOpts struct in src/platform/cef.zig (line 3675)
- **[low]** `dialog.showSaveDialog() — option: 'securityScopedBookmarks' (macOS/MAS)` — Add `securityScopedBookmarks?: boolean` to SaveDialogOptions in packages/suji-js/src/index.ts (line 1229) and packages/suji-node/src/index.ts (line 1190). Add field to SaveDialogJson struct in src/mai
- **[low]** `dialog.showOpenDialog() / dialog.showSaveDialog() — properties: 'dontAddToRecent'` — Add "dontAddToRecent" as a string literal to OpenDialogProperty (line 1202-1209 in packages/suji-js/src/index.ts) and SaveDialogProperty (line 1224-1227). This matches Electron's current API which exp

### ipc

- **[low]** `ipcRenderer.addListener(channel, listener)` — Add a single export line to /Users/yoonhb/Documents/workspace/suji/packages/suji-js/src/index.ts after the `on()` export (line 107): `export const addListener = on;`. This mirrors Electron's EventEmit
- **[low]** `ipcMain.addListener(channel, listener)` — Add the alias to both @suji/node and @suji/js packages immediately after their respective on() function exports. For @suji/node (after line 279): export const addListener = on; For @suji/js (after lin

### menu

- **[low]** `MenuItem.id property` — Add `id?: string` field to MenuCommandItem, MenuCheckboxItem, and MenuSubmenuItem interfaces in packages/suji-js/src/index.ts (~lines 934-954). Apply the same addition to the Rust/Go/Node SDK MenuItem
- **[low]** `MenuItem.sublabel property` — Add optional `sublabel?: string` field to MenuCommandItem and MenuCheckboxItem TypeScript interfaces. Add `sublabel: []const u8 = ""` to Zig's ApplicationMenuItem.item and .checkbox structs. In cef.zi
- **[low]** `MenuItem.toolTip property` — Add optional `toolTip?: string` field to MenuCommandItem and MenuCheckboxItem interfaces in packages/suji-js/src/index.ts (lines 934-947). Update Zig ApplicationMenuItem union in src/platform/cef.zig 
- **[low]** `MenuItem.before/after positioning` — Add optional `before?: string[]` and `after?: string[]` fields to MenuCommandItem, MenuCheckboxItem, and MenuSubmenuItem interfaces in packages/suji-js/src/index.ts and packages/suji-node/src/index.ts
- ~~**[low]** `menu.click event payload`~~ ✅ — Enhance menu:click payload from {click: string} to {click: string, windowId?: number}. Implementation: (1) Store window ID when menu is set, or emit currently active window ID at click time via Window
- **[low]** `menu.click event — window context` — Add windowId tracking to menu:click event: (1) extend menu_popup API to accept optional windowId parameter, (2) store windowId context in g_menu_context or similar, (3) emit menu:click as {click, wind

### nativeImage

- **[low]** `nativeImage.toDataURL()` — Add nativeImage.toDataURL(path, options?) method to @suji/api (packages/suji-js/src/index.ts) and @suji/node (packages/suji-node/src/index.ts) that wraps the return value of toPng with 'data:image/png

### nativeTheme

- **[low]** `nativeTheme.shouldUseInvertedColorScheme` — Add `shouldUseInvertedColorScheme(): Promise<boolean>` method to nativeTheme in both @suji/api (packages/suji-js/src/index.ts, line ~1089) and @suji/node (packages/suji-node/src/index.ts, line ~927). 
- **[low]** `shouldDifferentiateWithoutColor` — Add shouldDifferentiateWithoutColor as async boolean property to nativeTheme across all 5 SDK layers: (1) cef.zig: add pub fn nativeThemeGetShouldDifferentiateWithoutColor() -> bool, call NSWorkspace.

### notification

- **[low]** `NotificationOptions.groupId` — Add groupId?: string to NotificationOptions in packages/suji-js/src/index.ts (line 835-840) and packages/suji-node/src/index.ts (line 1017-1021). Pass groupId through to the native notification_show h
- **[low]** `NotificationOptions.subtitle` — Add `subtitle?: string` field to NotificationOptions interface in both packages/suji-js/src/index.ts (line 835-840) and packages/suji-node/src/index.ts (line 1017-1021). Update src/platform/notificati
- **[low]** `NotificationOptions.sound` — Add optional sound?: string property to NotificationOptions interface in packages/suji-js/src/index.ts and packages/suji-node/src/index.ts. Update notification show methods to pass sound parameter thr
- **[low]** `notification — 'close' event` — Add 'notification:close' event emission: (1) extend SujiNotificationDelegate in notification.m to implement userNotificationCenter:didDismissNotification: or track dismissal state in willPresentNotifi
- **[low]** `notification.groupId readonly property` — Add optional `groupId?: string` field to NotificationOptions interface in packages/suji-js/src/index.ts and packages/suji-node/src/index.ts. Pass groupId to the IPC call in notification.show(). Update

### powerMonitor

- **[low]** `powerMonitor.getCurrentThermalState()` — Add macOS-only method getCurrentThermalState() to powerMonitor. Implement as: (1) Native Zig wrapper around NSProcessInfo.thermalState (iOS 11.2+/macOS 10.14+) in src/platform/cef.zig, (2) IPC command

### safeStorage

- **[low]** `safeStorage.isAsyncEncryptionAvailable()` — Add `safeStorage.isAsyncEncryptionAvailable(): Promise<boolean>` to both @suji/api (packages/suji-js) and @suji/node. Implementation: return true on macOS (Keychain available), false elsewhere (or alw

### session

- **[low]** `session.flushStorageData()` — Add session.flushStorageData() method to packages/suji-js/src/index.ts (lines 1293-1297) and packages/suji-node/src/index.ts (lines 1394-1397). Implement as a wrapper over an IPC command (e.g., sessio
- **[low]** `session.setUSBProtectedClassesHandler(handler)` — Add `setUSBProtectedClassesHandler(handler: ((details: {protectedClasses: string[]}) => string[]) | null): Promise<void>` to the session export in both packages/suji-js/src/index.ts and packages/suji-
- **[low]** `session.isPersistent()` — Add isPersistent() method to session object in both packages/suji-js/src/index.ts (line 1284+) and packages/suji-node/src/index.ts (line 1386+). Implementation: return true (Suji only supports persist
- **[low]** `session.spell-checker properties and methods` — Add spell-checker support to Suji session API: (1) Implement cef_spellcheck_handler_t wrapper in src/platform/cef.zig with setSpellCheckerEnabled, setSpellCheckerLanguages, getSpellCheckerLanguages, s
- **[low]** `session.getBlobData(identifier)` — Add session.getBlobData(identifier: string) → Promise<Buffer> to 5 SDK entry points (Frontend @suji/api, Node @suji/node, Zig, Rust, Go). Implement as thin IPC wrapper: (1) Add `session_get_blob_data`
- **[low]** `session.clearHostResolverCache()` — Add async clearHostResolverCache(): Promise<void> method to session module in packages/suji-js/src/index.ts and corresponding backend handler in src/main.zig via CEF request_context host resolver call
- **[low]** `session.storagePath` — Add async method `session.getStoragePath(): Promise<string | null>` to both `@suji/api` (packages/suji-js/src/index.ts) and `@suji/node` (packages/suji-node/src/index.ts) that calls a new backend comm
- **[low]** `session.serviceWorkers (property)` — Add a `serviceWorkers` property to the session object in both @suji/api (frontend) and @suji/node (Node.js backend), mirroring Electron's read-only ServiceWorkers interface. Requires: (1) Zig core sup

### tray

- **[low]** `tray.getGUID()` — Add getGUID() method to tray API: (1) Generate UUID on tray_create in src/platform/cef.zig and store in TrayEntry; (2) Add getTrayGuid(tray_id) public fn in cef.zig; (3) Expose via tray_get_guid IPC h

### webContents

- **[low]** `webContents.downloadURL()` — Implement windows.downloadURL(windowId, url, options?) across all SDKs (frontend/node/zig/rust/go). Register CEF download handler in cef.zig to intercept downloads, bridge the request through IPC, and
- **[low]** `webContents.getTitle()` — Add windows.getTitle(windowId): Promise<string> method. Implementation: (1) Add title_buf: [256]u8 and title_len: usize fields to BrowserEntry in src/platform/cef.zig; (2) Capture title in setTitle() 
- **[low]** `webContents history navigation (canGoBack / canGoForward / canGoToOffset / goBack / goForward / goToIndex / goToOffset)` — Add 7 history navigation methods to webContents API across all 5 SDKs (Frontend @suji/api, Zig, Rust, Go, Node). Expose CEF equivalents (go_back, go_forward, can_go_back, can_go_forward) via window_ip
- **[low]** `isLoadingMainFrame()` — Add `isLoadingMainFrame(windowId)` method to all SDK surfaces (JS, Node, Rust, Go, Zig) by extending the webContents loading state interface. Implementation: Add CEF function pointer for main-frame-on
- **[low]** `webContents.isCrashed() / webContents.forcefullyCrashRenderer()` — Add `isCrashed(): boolean` (state query) and `forcefullyCrashRenderer(): void` (process terminator) methods to the webContents object in @suji/api (frontend SDK) and @suji/node (Node.js backend SDK). 
- **[low]** `setIgnoreMenuShortcuts(ignore: boolean): void` — Add windows.setIgnoreMenuShortcuts(windowId, ignore) to both frontend (@suji/api) and backend SDKs. Implement via: (1) new CEF IPC command before-input-event dispatching keyboard events from cef_keybo
- **[low]** `webContents.centerSelection() / copyImageAt() / pasteAndMatchStyle() / delete() / unselect() / scrollToTop() / scrollToBottom() / adjustSelection() / replace() / replaceMisspelling() / insertText()` — Add 11 webContents editing/selection methods to packages/suji-js/src/index.ts, packages/suji-node/src/index.ts, and Zig backend (src/main.zig or cef.zig). Mirror the existing 6 methods' pattern: (1) Z
- **[low]** `webContents.setVisualZoomLevelLimits(minimumLevel, maximumLevel)` — Add windows.setVisualZoomLevelLimits(windowId, minimumLevel, maximumLevel): Promise<WindowOpResponse> to suji-js and @suji/node, mirroring the pattern of existing setZoomLevel/setZoomFactor. Backend i
- **[low]** `webContents.isDevToolsFocused() / getDevToolsTitle() / setDevToolsTitle(title)` — Add three new methods to windows API namespace: (1) isDevToolsFocused(windowId) returns boolean indicating if DevTools window has focus; (2) getDevToolsTitle(windowId) returns string of current DevToo
- **[low]** `webContents.addWorkSpace() / removeWorkSpace() / setDevToolsWebContents() / inspectElement() / inspectSharedWorker() / inspectSharedWorkerById() / getAllSharedWorkers() / inspectServiceWorker()` — Add the 8 missing DevTools methods to packages/suji-js/src/index.ts and packages/suji-node/src/index.ts: (1) inspectElement(windowId, x, y), (2) addWorkSpace(windowId, path), (3) removeWorkSpace(windo
- **[low]** `webContents.sendToFrame(frameId, channel, ...args) / webContents.postMessage(channel, message, [transfer])` — Add sendToFrame(windowId, frameId, channel, data) and postMessage(windowId, channel, message, transfer?) to send API. Route windowId+frameId pair to CEF's frame-level message dispatch. Implement in pa
- **[low]** `webContents.enableDeviceEmulation(parameters) / disableDeviceEmulation()` — Add enableDeviceEmulation({screenPosition?, screenSize?, viewPosition?, deviceScaleFactor?, viewSize?, scale?}) and disableDeviceEmulation() methods to windows namespace (suji-js/suji-node). Wire to n
- **[low]** `navigationHistory (property) / mainFrame (property) / ipc (property)` — Add readonly property getters to BrowserWindow class: (1) get navigationHistory() returning a stub with canGoBack(), goBack(), goForward() methods; (2) get mainFrame() returning a frame-like object; (

### webRequest

- **[low]** `webRequest.onErrorOccurred` — Add onErrorOccurred method to webRequest namespace in packages/suji-js/src/index.ts that wraps the webRequest:completed listener, filtering for requestStatus=4 events and exposing listener(details) wi
- **[low]** `onSendHeaders event` — Add onSendHeaders as a read-only observation event to webRequest API. Implement as a fire-and-forget listener (no callback) in native CEF handler, similar to onCompleted. Emit webRequest:send-headers 
- **[low]** `onBeforeRedirect` — Add onBeforeRedirect to webRequest matching onBeforeRequest pattern with WebRequestRedirectDetails interface.
