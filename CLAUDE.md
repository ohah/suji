# Suji

Zig 코어 기반 올인원 데스크톱 앱 프레임워크.
Electron 스타일 API (handle/invoke/on/send).

## 문서

- [구현 계획서](./docs/PLAN.md) — 아키텍처, 구현 단계, 기술 결정 사항

## 빌드 & 실행

```bash
zig build          # 빌드
zig build test     # 단위 테스트 (339개)
zig build run      # CLI 도움말

# 예제 실행
cd examples/multi-backend && suji dev   # Zig + Rust + Go + Node.js
cd examples/zig-backend && suji dev     # Zig 단독
cd examples/rust-backend && suji dev    # Rust 단독
cd examples/go-backend && suji dev      # Go 단독
cd examples/node-backend && suji dev    # Node.js 단독

# E2E 테스트 (puppeteer + bun) — 각 스크립트는 fresh suji dev 띄워 단독 실행
bash tests/e2e/run-window-injection.sh  # Phase 2.5 __window wire 주입 검증
bash tests/e2e/run-window-lifecycle.sh  # Phase 4-A 네비/JS + 창 생명주기 검증
bash tests/e2e/run-view-lifecycle.sh    # Phase 17-A WebContentsView (createView/z-order/lifecycle)
bash tests/e2e/run-cef-ipc.sh           # CEF IPC stress (chain/fanout, 200회 round-trip)
bash tests/e2e/run-splash.sh            # 스플래시 스크린 패턴 (windows.create + isLoading polling)
bash tests/e2e/run-web-request.sh       # webRequest URL glob blocklist + completed 이벤트
```

E2E 스크립트는 suji dev를 띄우고 CEF DevTools(`localhost:9222`)에 puppeteer로 붙어
검증. 기존 run-*.sh 스크립트가 자동으로 프로세스 정리까지 한다.

## CLI

```bash
suji init <name> --backend=zig|rust|go|multi
suji dev
suji build
suji run
```

## API (Electron 스타일)

```zig
// Zig
pub const my_app = suji.app()
    .handle("ping", ping)
    .on("clicked", handler)
    .on("window:all-closed", onAllClosed);  // Electron 패턴

fn ping(req: suji.Request) suji.Response { return req.ok(.{ .msg = "pong" }); }

fn onAllClosed(_: suji.Event) void {
    if (!std.mem.eql(u8, suji.platform(), "macos")) suji.quit();
}
// req.invoke("rust", request)  — 크로스 호출
// suji.send("channel", data)   — 이벤트 발신
// suji.sendTo(id, "ch", data)  — 특정 창에만 이벤트
// suji.windows.loadURL(id, url)        — 창 페이지 변경 (Phase 4-A)
// suji.windows.executeJavaScript(id, code) — 렌더러에서 JS 실행
// suji.windows.setZoomLevel(id, 1.5) / setZoomFactor(id, 1.2)  — 줌 (Phase 4-B)
// suji.windows.openDevTools(id) / toggleDevTools(id)  — DevTools (Phase 4-C)
// suji.windows.copy(id) / paste(id) / findInPage(id, "x", .{})  — 편집/검색 (Phase 4-E)
// suji.windows.printToPDF(id, "/tmp/x.pdf")  — PDF 인쇄 (Phase 4-D, 결과는 window:pdf-print-finished)
// suji.clipboard.readText() / writeText("hi") / clear()                — macOS NSPasteboard
//   / readHtml() / writeHtml("<b>x</b>")  — HTML round-trip
//   / has("public.html") / availableFormats()  — format 검사 (UTI)
// suji.powerMonitor.getSystemIdleTime()  — 유휴 초 (CGEventSource)
// suji.shell.openExternal("https://...") / showItemInFolder("/path") / beep() / trashItem(path)
//   / openPath("/Users/me/file.pdf")     — 로컬 파일 기본 앱으로 (URL이 아닌 path)
// suji.nativeTheme.shouldUseDarkColors()  — macOS NSApp.effectiveAppearance
// suji.screen.getCursorScreenPoint()      — NSEvent.mouseLocation (bottom-up)
// suji.dialog.messageBoxSimple("info", "안녕", &.{ "OK", "Cancel" })   — 응답 raw JSON
// suji.dialog.showOpenDialog("\"properties\":[\"openFile\"]")          — raw fields
// suji.dialog.showErrorBox("Title", "content")
// suji.tray.create("🚀 App", "tooltip") / setMenuRaw(id, "...items...") / destroy(id)
//                                                                       (macOS NSStatusItem)
// suji.notification.show("Title", "Body", false) / requestPermission() / close(id)
//                                       (macOS UNUserNotificationCenter, .app 번들 필수)
// suji.menu.setApplicationMenuRaw("\"items\":[...]") / resetApplicationMenu()
//                                       (macOS NSMenu, menu:click 이벤트)
// suji.globalShortcut.register("Cmd+Shift+K", "openSettings") / unregister(accel)
//   / unregisterAll() / isRegistered(accel)   (macOS Carbon Hot Key, globalShortcut:trigger 이벤트)
// suji.screen.getAllDisplays()                — Display 배열 raw JSON (macOS NSScreen)
// suji.powerSaveBlocker.start("prevent_display_sleep") / stop(id)   (macOS IOPMAssertion)
// suji.safeStorage.setItem(svc, acc, "v") / getItem(svc, acc) / deleteItem(svc, acc)
//                                       (macOS Keychain Services)
// suji.dock.setBadge("99") / getBadge()        — dock 배지 (macOS NSDockTile)
// suji.getName() / suji.getVersion()           — config.app.name/version (Electron 동등)
// suji.isReady() / suji.focus() / suji.hide()  — 앱 init/frontmost/Cmd+H
// suji.getPath("home"|"appData"|"userData"|"temp"|"desktop"|"documents"|"downloads")
// suji.screen.getCursorScreenPoint() / suji.screen.getDisplayNearestPoint(x, y)
// suji.requestUserAttention(true) / cancelUserAttentionRequest(id)
//                                       — dock 바운스 (macOS NSApp `requestUserAttention:`)
// powerMonitor 이벤트 — 자동 install (NSWorkspace 옵저버), 4 채널 발신:
//   `power:suspend` / `power:resume` / `power:lock-screen` / `power:unlock-screen`
//   → suji.on("power:suspend", cb) / 다른 SDK도 동일 채널명으로 listen
// suji.process.run(allocator, suji.io(), &.{ "echo", "hi" })  — std.process.run wrap (백엔드 only)
//   → RunResult { code, stdout, stderr }, caller가 stdout/stderr free
// suji.http.fetch(allocator, suji.io(), "https://...", null)   — std.http.Client.fetch wrap
//   → FetchResult { status, body }, payload null이면 GET / non-null이면 POST
// suji.webRequest.setBlockedUrls(&.{ "https://*.ad/*" })   — URL glob blocklist
//   → 매칭 요청 cancel + `webRequest:before-request` / `webRequest:completed` 이벤트
// suji.quit()                  — 앱 종료 요청 (Electron app.quit())
// suji.platform()              — "macos" | "linux" | "windows" | "other"
```

```rust
// Rust
#[suji::handle]
fn ping() -> String { "pong".to_string() }
suji::export_handlers!(ping);
// suji::invoke("go", request)  — 크로스 호출
// suji::send("channel", data)  — 이벤트 발신
// suji::send_to(id, "ch", data) — 특정 창에만 이벤트
// suji::on("channel", cb, arg) — 이벤트 수신
// suji::windows::load_url(id, url) / reload(id, false) / execute_javascript(id, code)  (Phase 4-A)
// suji::windows::set_zoom_factor(id, 1.2) / open_dev_tools(id) / copy(id) / find_in_page(id, "x", ..)
// suji::windows::print_to_pdf(id, "/tmp/x.pdf")  — PDF 인쇄 (Phase 4-D)
// suji::clipboard::read_text() / write_text("hi") / clear()
// suji::shell::open_external("https://...") / show_item_in_folder("/path") / beep() / trash_item(path)
// suji::dialog::show_message_box(MessageBoxOpts { message: "Q", ... })
// suji::dialog::show_open_dialog(r#""properties":["openFile"]"#)
// suji::dialog::show_error_box("Title", "content")
// suji::tray::create("🚀", "tip") / set_menu(id, &[MenuItem::Item{...}, MenuItem::Separator]) / destroy(id)
// suji::notification::{is_supported, request_permission, show("T","B",false), close("id")}
// suji::menu::set_application_menu(&[MenuItem::Submenu{...}]) / reset_application_menu()
// suji::global_shortcut::{register("Cmd+Shift+K","openSettings"), unregister(a),
//   unregister_all(), is_registered(a)}    (macOS Carbon Hot Key)
// suji::screen::get_all_displays()    — Display 배열 raw JSON
// suji::power_save_blocker::{start("prevent_display_sleep"), stop(id)}
// suji::safe_storage::{set_item(s,a,"v"), get_item(s,a), delete_item(s,a)}
// suji::dock::{set_badge("99"), get_badge()}
// suji::get_path("userData") / get_path("home") ...
// suji::web_request::set_blocked_urls(&["https://*.ad/*"])  — URL glob blocklist
// suji::request_user_attention(true) / suji::cancel_user_attention_request(id)
// suji::quit()                 — 앱 종료 (Electron app.quit())
// suji::platform()             — "macos" | "linux" | "windows"
// #[derive(suji::Type)] struct GreetReq { name: String }   — specta re-export로
//   타입을 ts emit 가능 (specta::ts::export::<T>()로 시그니처 추출)
```

```go
// Go
type App struct{}
func (a *App) Ping() string { return "pong" }
var _ = suji.Bind(&App{})
// suji.Invoke("rust", request)
// suji.Send("channel", data)
// suji.SendTo(id, "ch", data)
// suji.On("channel", callback)  — EventBus 연결 (bridge.c)
// import "github.com/ohah/suji-go/windows"
// windows.LoadURL(id, url) / Reload(id, false) / ExecuteJavaScript(id, code)  (Phase 4-A)
// windows.SetZoomFactor(id, 1.2) / OpenDevTools(id) / Copy(id) / FindInPage(id, "x", ..)
// windows.PrintToPDF(id, "/tmp/x.pdf")  — PDF 인쇄 (Phase 4-D)
// import "github.com/ohah/suji-go/clipboard"
// clipboard.ReadText() / WriteText("hi") / Clear()
// import "github.com/ohah/suji-go/shell"
// shell.OpenExternal(url) / ShowItemInFolder(path) / Beep() / TrashItem(path)
// import "github.com/ohah/suji-go/dialog"
// dialog.ShowMessageBox(dialog.MessageBoxOpts{Message:"Q", Buttons:[]string{"OK"}})
// dialog.ShowOpenDialog(`"properties":["openFile"]`) / ShowErrorBox(t, c)
// import "github.com/ohah/suji-go/tray"
// tray.Create("🚀", "tip") / SetMenu(id, []tray.MenuItem{{Label:"Quit",Click:"quit"}}) / Destroy(id)
// import "github.com/ohah/suji-go/notification"
// notification.Show("Title", "Body", false) / RequestPermission() / Close(id)
// import "github.com/ohah/suji-go/menu"
// menu.SetApplicationMenu([]menu.MenuItem{menu.Submenu("Tools", []menu.MenuItem{menu.Item("Run", "run")})})
// import "github.com/ohah/suji-go/globalshortcut"
// globalshortcut.Register("Cmd+Shift+K", "openSettings") / Unregister(a) / UnregisterAll() / IsRegistered(a)
// import "github.com/ohah/suji-go/screen"
// screen.GetAllDisplays()
// import "github.com/ohah/suji-go/powersaveblocker"
// powersaveblocker.Start("prevent_display_sleep") / Stop(id)
// import "github.com/ohah/suji-go/safestorage"
// safestorage.SetItem(svc, acc, "v") / GetItem(svc, acc) / DeleteItem(svc, acc)
// import "github.com/ohah/suji-go/dock"
// dock.SetBadge("99") / GetBadge()
// import "github.com/ohah/suji-go/app"
// app.GetPath("userData")
// import "github.com/ohah/suji-go/attention"
// attention.RequestUser(true) / attention.CancelUserRequest(id)
// import "github.com/ohah/suji-go/webrequest"
// webrequest.SetBlockedUrls([]string{"https://*.ad/*"})
// suji.Quit()                   — 앱 종료
// suji.Platform()               — "macos" | "linux" | "windows"
```

```js
// Frontend (Electron 스타일 — 자동 라우팅)
await suji.invoke("ping")                                    // 채널명만으로 호출 (등록된 백엔드 자동 탐색)
await suji.invoke("greet", { name: "Suji" })                 // 인자 전달
await suji.invoke("greet", { name: "Suji" }, { target: "rust" }) // 특정 백엔드 지정
suji.on("event", (data) => console.log(data))
suji.emit("event", { msg: "hello" })
suji.quit()                                                  // 앱 종료 요청
suji.platform                                                // "macos" | "linux" | "windows" (상수)

// TypeScript type-safe invoke — `SujiHandlers` interface를 augment하면 cmd/req/res 추론.
// declare module '@suji/api' {
//   interface SujiHandlers {
//     ping: { req: void; res: { msg: string } };
//     greet: { req: { name: string }; res: string };
//   }
// }
// await invoke('greet', { name: 'Suji' })   // res: string (자동 추론)
// await invoke('greet')                     // ❌ TS 에러 — req 누락
// await invoke('unknown-cmd')               // unknown 반환 (untyped fallback)
// import { windows } from '@suji/api';
// await windows.create({ title:"Settings", url:"...", frame:false }) — 새 창
// await windows.loadURL(id, url) / reload(id, true) / executeJavaScript(id, code)  (Phase 4-A)
// await windows.getURL(id) / isLoading(id) / setTitle(id, t) / setBounds(id, {...})
// await windows.setZoomFactor(id, 1.2) / setZoomLevel(id, 1.5)  (Phase 4-B)
// await windows.openDevTools(id) / toggleDevTools(id) / isDevToolsOpened(id)  (Phase 4-C)
// await windows.undo(id) / copy(id) / paste(id) / findInPage(id, "x", {})  (Phase 4-E)
// const { success } = await windows.printToPDF(id, "/tmp/x.pdf")  (Phase 4-D)
// await windows.createView({hostId, url, bounds}) → {viewId}              (Phase 17-A WebContentsView)
// await windows.addChildView(host, view, index?) / setTopView / removeChildView
// await windows.setViewBounds(viewId, {...}) / setViewVisible(viewId, bool) / getChildViews(host)
//   viewId는 windowId와 같은 풀 — windows.loadURL(viewId,...) / executeJavaScript / openDevTools
//   등 모든 webContents API가 view에도 동작.
//   ⚠️ destroyView는 known limitation (render subprocess race) — host 창 close 시 자동 정리 권장,
//   동적 hide/show는 setViewVisible 사용. 17-B에서 안정화.

// import { clipboard, shell, dialog } from '@suji/api';
// await clipboard.readText() / writeText(text) / clear()                  (macOS NSPasteboard)
// await shell.openExternal(url) / showItemInFolder(path) / beep() / trashItem(path)   (macOS NSWorkspace + NSFileManager)
// await dialog.showMessageBox({ type, message, buttons, defaultId, ... }) (macOS NSAlert)
// await dialog.showMessageBox(windowId, options)  — sheet (부모 창 attach, dialog.m)
// await dialog.showOpenDialog({ properties:['openFile','multiSelections'], filters }) (NSOpenPanel)
// await dialog.showOpenDialog(windowId, options) — sheet
// await dialog.showSaveDialog({ defaultPath:'~/x.txt', nameFieldLabel })  (NSSavePanel)
// await dialog.showSaveDialog(windowId, options) — sheet
// await dialog.showErrorBox(title, content)                               (간이 에러 popup)

// import { globalShortcut } from '@suji/api';
// await globalShortcut.register("Cmd+Shift+K", "openSettings")            (macOS Carbon Hot Key)
// await globalShortcut.unregister(accel) / unregisterAll() / isRegistered(accel)
// suji.on('globalShortcut:trigger', ({accelerator, click}) => ...)

// import { screen, powerSaveBlocker, safeStorage, app, webRequest } from '@suji/api';
// const displays = await screen.getAllDisplays()                         (macOS NSScreen)
// const id = await powerSaveBlocker.start("prevent_display_sleep")
// await powerSaveBlocker.stop(id)                                         (macOS IOPMAssertion)
// await safeStorage.setItem(svc, acc, "v") / getItem(svc, acc) / deleteItem(svc, acc)
//                                                                         (macOS Keychain Services)
// await app.dock.setBadge("99") / app.dock.getBadge()                     (macOS NSDockTile)
// await app.getPath("userData" | "home" | "documents" | ...)              — Electron app.getPath
// const reqId = await app.requestUserAttention(true)                      (macOS NSApp `requestUserAttention:`)
// await app.cancelUserAttentionRequest(reqId)
// await webRequest.setBlockedUrls(["https://*.ad/*"])                     (CEF ResourceRequestHandler)
//   → suji.on('webRequest:completed', ({url, statusCode, ...}) => ...)
// await webRequest.onBeforeRequest({urls:["https://*.tracker/*"]}, (details, cb) => cb({cancel:true}))
//   → RV_CONTINUE_ASYNC + listener round-trip cancel/allow (e2e 13 pass)
```

## suji.json 설정

JSON Schema 제공: [`suji.schema.json`](./suji.schema.json) — IDE 자동완성 + 검증 지원.

```json
{
  "$schema": "./suji.schema.json",
  "app": { "name": "My App", "version": "1.0.0" },
  "window": {
    "title": "My App",
    "width": 1024,
    "height": 768,
    "debug": false,
    "protocol": "file"       // "file" (기본, file://) | "suji" (suji:// 커스텀 프로토콜)
  },
  "frontend": {
    "dir": "frontend",
    "dev_url": "http://localhost:5173",
    "dist_dir": "frontend/dist"
  }
}
```

`protocol: "suji"` — CORS, fetch, Cookie, Service Worker가 정상 동작하는 커스텀 프로토콜. prod 빌드 시 `suji://app/` URL로 프론트엔드 로드.

## Node.js 백엔드

```json
{ "backend": { "lang": "node", "entry": "backends/node" } }
```

```js
// backends/node/main.js
suji.handle('hello', (data) => {
  const req = JSON.parse(data);
  return JSON.stringify({ message: 'Hello!', echo: req });
});

// 크로스 호출 (핸들러 내부 — 동기)
suji.invokeSync('zig', '{"cmd":"ping"}')

// 크로스 호출 (핸들러 밖 — async, Promise 반환, event loop 비블록)
const result = await suji.invoke('rust', '{"cmd":"greet"}')

// 이벤트 발신
suji.send('my-event', JSON.stringify({ msg: 'hello' }))

// import { clipboard, shell, dialog } from '@suji/node'
// await clipboard.readText() / writeText("hi")
// await shell.openExternal(url) / showItemInFolder(path) / beep() / trashItem(path)
// await dialog.showMessageBox({ message:"...", buttons:["OK"], windowId? })
// await dialog.showOpenDialog({ properties:["openFile"], filters }) / showSaveDialog(...)
// await dialog.showErrorBox(title, content)
// const { trayId } = await tray.create({ title:"🚀", tooltip:"..." })
// await tray.setMenu(trayId, [{label:"Quit",click:"quit"},{type:"separator"}])
// await tray.destroy(trayId) — suji.on('tray:menu-click', ({trayId,click}) => ...)
// const sup = await notification.isSupported() (Bundle ID 필수)
// await notification.requestPermission() / show({title,body,silent}) / close(notificationId)
//                              — suji.on('notification:click', ({notificationId}) => ...)
// await menu.setApplicationMenu([{label:"Tools",submenu:[{label:"Run",click:"run"}]}])
// await menu.resetApplicationMenu() — suji.on('menu:click', ({click}) => ...)
// import { screen, powerSaveBlocker, safeStorage, app, webRequest } from '@suji/node'
// const displays = await screen.getAllDisplays()                         (macOS NSScreen)
// const id = await powerSaveBlocker.start("prevent_display_sleep") / stop(id)
// await safeStorage.setItem(svc, acc, "v") / getItem(svc, acc) / deleteItem(svc, acc)
// await app.dock.setBadge("99") / app.dock.getBadge()
// await app.getPath("userData") — Electron app.getPath
// const reqId = await app.requestUserAttention(true) / cancelUserAttentionRequest(reqId)
// await webRequest.setBlockedUrls(["https://*.ad/*"])

// TypeScript type-safe — `@suji/node`도 SujiHandlers augment 지원.
//   await call('zig', 'greet', { name: 'x' })   // res: string 추론
//   const v = callSync('zig', 'ping')           // sync 변형, res: { msg: string } 추론
//   await invoke<T>('zig', { cmd: 'foo' })      // 기존 untyped 그대로 동작 (backwards compat)
```

libnode 임베딩 방식 (별도 프로세스 없음). `~/.suji/node/24.14.1/libnode.dylib` 필요.
`package.json` + `npm install` + `node_modules` 완전 호환.

## 자동 라우팅

각 백엔드는 초기화 시 자신이 처리할 수 있는 채널(커맨드)을 `register`로 등록한다. 프론트엔드에서 `suji.invoke("ping")`처럼 채널명만으로 호출하면, 코어가 등록 정보를 기반으로 올바른 백엔드로 자동 라우팅한다. `{ target: "rust" }` 옵션으로 특정 백엔드를 명시할 수도 있다. 동일 채널을 여러 백엔드가 중복 등록하면 에러를 반환한다.

## 폴더 구조

```
suji/
├── src/
│   ├── main.zig              # CLI + CEF 윈도우 관리
│   ├── root.zig
│   ├── core/
│   │   ├── app.zig           # Zig SDK (handle/on/send/exportApp)
│   │   ├── config.zig        # JSON 설정 파서
│   │   ├── events.zig        # EventBus (pub/sub, mutex snapshot)
│   │   ├── init.zig          # suji init 스캐폴딩
│   │   └── util.zig          # nullTerminate, 버퍼 상수
│   ├── platform/
│   │   ├── cef.zig           # CEF 통합 (창, IPC, 렌더러, 커스텀 프로토콜)
│   │   ├── node.zig          # Node.js 런타임 (libnode 임베딩)
│   │   ├── node/bridge.cc    # Node.js C++ 브릿지 (V8 IPC, thread pool)
│   │   └── watcher.zig       # 파일 감시 (백엔드 핫 리로드)
│   ├── backends/
│   │   └── loader.zig        # BackendRegistry + SujiCore
│   └── templates/
├── crates/
│   ├── suji-rs/              # Rust SDK
│   └── suji-rs-macros/       # Rust proc macro
├── sdks/
│   └── suji-go/              # Go SDK (bridge.c/bridge.go)
├── tests/                    # 테스트
├── examples/
│   ├── zig-backend/
│   ├── rust-backend/
│   ├── go-backend/
│   ├── node-backend/         # Node.js 단독 예제
│   └── multi-backend/        # Zig+Rust+Go+Node.js + 이벤트 예제
└── docs/PLAN.md

## 크로스 플랫폼

- macOS: Cocoa + ObjC + CEF Framework 링크, `.app` 번들링
- Linux: GTK3 + X11 + CEF 공유 라이브러리, CEF 자체 윈도우
- Windows: Win32 + CEF DLL 링크
- CI: GitHub Actions (macos-14 + ubuntu-24.04 + windows-latest) + e2e (macos-14 only)

## 앱별 cache / 사용자 데이터 (Electron `app.getPath('userData')` 동등)

`config.app.name`을 키로 OS 표준 user-data 디렉토리 아래 격리. 한 시스템에 여러 Suji 앱
설치 시 cookie/localStorage/IndexedDB/Service Worker 자동 격리.

| OS | 경로 | env fallback |
|----|------|------|
| macOS | `~/Library/Application Support/<app>/Cache` | `$HOME` |
| Linux | `$XDG_CONFIG_HOME/<app>/Cache` (없으면 `~/.config/<app>/Cache`) | XDG Base Directory Spec |
| Windows | `%APPDATA%/<app>/Cache` (없으면 `%USERPROFILE%/AppData/Roaming/<app>/Cache`) | Roaming 표준 |

## fs sandbox (Electron `webPreferences.sandbox` 동등)

frontend(renderer)에서 호출되는 `fs.*` cmd가 path 화이트리스트로 검증. backend는 항상 무제한.

```json
{ "fs": { "allowedRoots": ["~/Documents/myapp"] } }
```

| 설정 | Frontend 동작 |
|------|---|
| 미설정 / `[]` | 모든 `fs.*` 차단 → `error: "forbidden"` (default safe) |
| `["~/Documents/myapp"]` | 해당 prefix 안 path만 허용 (`~`은 `$HOME`/`%USERPROFILE%`로 사전 expand) |
| `["*"]` | escape hatch (`..` traversal은 여전히 차단) |

`..` path component는 모든 mode에서 항상 차단 (security-critical). prefix 매치는 separator
boundary 가드 — `/foo/bar` 허용 시 `/foo/barX` 통과 X. backend SDK 호출은 thread-local
마커로 sandbox 우회. 자세한 내용: [`documents/fs.mdx`](./documents/fs.mdx).

## 알려진 이슈

- macOS 26.4 + Xcode 26.4: Zig 링커 버그 (Xcode 26.2 필요)
- Go 빌드: Homebrew LLVM 충돌 (CC=/usr/bin/clang 자동 설정)
- **Windows dlopen 백엔드 로드 불가** (Zig 0.16 `std.DynLib` 미지원 regression): [#11](https://github.com/ohah/suji/issues/11)
  - Node.js 임베드 경로는 영향 없음. Rust/Go/Zig dylib 백엔드만 Windows에서 제약.
  - 업스트림 복원 대기 중. `Backend.load` 구조는 그대로 남아있어 복원 시 5줄 제거로 복구.
- **Linux/Windows GPU 가속 미지원** (명시적 `--disable-gpu`): [#12](https://github.com/ohah/suji/issues/12)
  - macOS만 ANGLE Metal 경로로 GPU 활성. Linux/Windows는 SwiftShader CPU 폴백.
  - asset 배치 로직만 추가하면 됨. 우선순위 낮음.

## 구현 노트

### Node.js 양방향 크로스 호출 (deadlock 방지)
`suji.invokeSync()`에 두 가지 deadlock 방지 경로:

1. **동일 스레드 재귀** (Zig→Rust→Go→Node 동기 체인): `g_in_sync_invoke` thread_local
   플래그로 감지, `suji_node_invoke`가 inline(V8 Locker 재진입)으로 handler 실행.
2. **다른 스레드 재진입** (Rust `std::thread::spawn`에서 Node 호출 등): `js_suji_invoke_sync`가
   워커 스레드에서 `g_core.invoke`를 실행하고 Node main thread는 V8 Unlocker로 isolate를
   놓아준 뒤 `drain_ipc_queue_inline`을 polling. 외부 스레드가 push한 queue가 정상 drain.

BackendRegistry는 Node 등 임베드 런타임에 대한 폴백을 `embed_runtimes` 테이블로 관리
(main이 `registerEmbedRuntime("node", ...)`로 주입).

검증:
- 깊은 재귀 체인(node→zig→rust→go→node→... 최대 depth=40, 10사이클)
- 다른 스레드 재진입 (`rust-thread-node` + `node-thread-deadlock`)
- 응답 메모리 누수 회귀 (200회 체인 호출)
모두 `tests/e2e/cef-ipc.test.ts` stress 섹션에서 E2E 검증.

## 배포 / 설치

### Suji CLI 배포 (예정)

| 채널 | 명령어 | 상태 |
|------|--------|------|
| GitHub Releases | 직접 다운로드 | CI 추가 필요 |
| Homebrew | `brew install ohah/tap/suji` | tap 레포 생성 필요 |
| npm/npx | `npx @suji/cli init my-app` | npm 패키지 필요 |
| curl 스크립트 | `curl -fsSL https://get.suji.dev \| sh` | 스크립트 작성 필요 |

### SDK 배포 (예정)

| SDK | 채널 | 패키지명 | 상태 |
|-----|------|----------|------|
| 프론트엔드 JS | npm | `@suji/api` | `packages/suji-js` 존재 |
| Rust SDK | crates.io | `suji` | `crates/suji-rs` 존재 |
| Go SDK | go module | `github.com/ohah/suji-go` | `sdks/suji-go` 존재 |
| Node.js SDK | npm | `@suji/node` (require) | `packages/suji-node` 존재 |

### 배포 우선순위
1. GitHub Releases — CI에서 플랫폼별 바이너리 빌드 + 자동 릴리즈
2. Homebrew tap — macOS 사용자 1순위
3. npx — 크로스 플랫폼, 프론트엔드 개발자 친화적
4. curl 스크립트 — 범용 설치
```
