# Suji

Zig 코어 기반 올인원 데스크톱 앱 프레임워크.
Electron 스타일 API (handle/invoke/on/send).

## 문서

- [구현 계획서](./docs/PLAN.md) — 아키텍처, 구현 단계, 기술 결정 사항
- [cef.zig 도메인 분리 리팩터](./docs/CEF_REFACTOR.md) — native API를 `cef_<domain>.zig`로 분리하는 진행 중 리팩터(절차/현황/주의)

## 빌드 & 실행

```bash
zig build          # 빌드
zig build test     # 단위 테스트 (790개)
zig build run      # CLI 도움말

# 공식 플러그인 테스트 (dylib 선빌드 필요 — cd plugins/<p>/zig && zig build)
zig build test-state    # state 플러그인 (KV 스토어)
zig build test-sqlite   # sqlite 플러그인 (벤더 SQLite 3.51, sql:open/execute/query/close)
zig build test-log      # log 플러그인 (rotating file logger, level filter, JSON Lines)
zig build test-store    # store 플러그인 (file-backed config store, named instances, atomic persist; +values/entries)
zig build test-http     # http 플러그인 (renderer-safe fetch with URL allowlist, deny-by-default)
zig build test-os-autostart # os-info + autostart 플러그인 (시스템 정보 / 로그인 자동실행)
zig build test-notification-rich # notification-rich 플러그인 (WinRT/UNUserNotificationCenter/Freedesktop actions)

# 임베드 코어 라이브러리 (CEF 무관 — 모바일/임베드용)
zig build lib                                  # libsuji_core.a (host)
zig build lib -Dtarget=aarch64-ios             # iOS
zig build lib -Dtarget=aarch64-linux-android   # Android
zig build lib -Dtarget=x86_64-windows          # Windows

# Windows Node bridge 빌드: SUJI_MINGW_ROOT가 있으면 우선 사용하고, 없으면
# C:\mingw-w64-16\mingw64 / C:\msys64\mingw64 / C:\msys64\ucrt64 순서로 탐색.
# CI/release는 msys2/setup-msys2로 gcc + mingw-w64-x86_64-nodejs +
# libnode runtime deps를 설치하고, MinGW ABI의 libnode.dll/libnode.dll.a/headers를
# ~/.suji/node/<NODE_VERSION>/에 staging한다. MSVC libnode.lib는 사용하지 않는다.

# 예제 실행
cd examples/multi-backend && suji dev   # Zig + Rust + Go + Node.js
cd examples/zig-backend && suji dev     # Zig 단독
cd examples/rust-backend && suji dev    # Rust 단독
cd examples/go-backend && suji dev      # Go 단독
cd examples/node-backend && suji dev    # Node.js 단독
suji run backends/node/main.js          # CEF 없이 embedded Node.js 파일 직접 실행

# E2E 테스트 (puppeteer + bun) — 대부분 fresh suji dev, CLI 테스트는 단독 실행
bash tests/e2e/run-node-run.sh          # suji run main.js embedded Node.js CLI
bash tests/e2e/run-types-cli.sh         # suji types stdout/--out schema generation
bash tests/e2e/run-init-cli.sh          # suji init / @suji/cli 스캐폴딩 + CI 템플릿
bash tests/e2e/run-release-workflow.sh  # release.yml/version contract
bash tests/e2e/run-rust-types-helper.sh # Rust SDK SujiHandlers .d.ts helper
bash tests/e2e/run-go-types-helper.sh   # Go SDK SujiHandlers .d.ts helper
bash tests/e2e/run-node-types-helper.sh # Node SDK SujiHandlers typed invoke/call consumer
bash tests/e2e/run-window-injection.sh  # Phase 2.5 __window wire 주입 검증
bash tests/e2e/run-window-lifecycle.sh  # Phase 4-A 네비/JS + 창 생명주기 검증
bash tests/e2e/run-view-lifecycle.sh    # Phase 17-B WebContentsView (createView/z-order/lifecycle)
bash tests/e2e/run-frameless-drag-region.sh # CEF Views frameless drag/no-drag region
bash tests/e2e/run-cef-ipc.sh           # CEF IPC stress (chain/fanout, 200회 round-trip)
bash tests/e2e/run-splash.sh            # 스플래시 스크린 패턴 (windows.create + isLoading polling)
bash tests/e2e/run-web-request.sh       # webRequest URL glob blocklist + completed 이벤트
bash tests/e2e/run-system-integration.sh # screen/desktopCapturer/crashReporter/app 등 통합
bash tests/e2e/run-capture-page.sh      # capture_page → 실 PNG 파일(매직바이트)
bash tests/e2e/run-deferred-response.sh # deferred-response criticals — cross-kind 라우팅/close-during-defer 무crash/path 라운드트립
bash tests/e2e/run-gpu-accel.sh         # GPU 가속 회귀 가드 (#12) — WebGL ANGLE/D3D11/SwiftShader fallback
bash tests/e2e/run-releasesafe-renderer-boot.sh # #60 part2 회귀 가드 — ReleaseSafe 빌드해 렌더러 V8 부트스트랩(window.__suji__ 바인딩) 검증(Windows CI). 디버깅: SUJI_CEF_DEBUG=1
bash tests/e2e/run-set-user-agent.sh    # set_user_agent CDP override 실효(navigator.userAgent)
bash tests/e2e/run-context-isolation.sh # window.__suji__ frozen/슬롯봉인/변조차단/기능보존
bash tests/e2e/run-plugin-wrappers.sh   # 공식 플러그인 (state/sqlite/log/store/http/notification-rich) × {JS, Node} wrapper wire-contract (mock bridge)
bash tests/e2e/run-plugin-state-integration.sh # state plugin DLL 라운드트립(__suji__ → DLL → 응답)

# 모바일 정적 백엔드 메커니즘 (CEF/iOS 무관, 호스트 검증)
bash tests/mobile-backends/run.sh       # 코어+Rust(staticlib)+Go(c-archive)+Zig
                                        # +SQLite(build-lib) 정적 링크 →
                                        # register_handler 왕복 65 케이스.
                                        # zig:http=std.http→localhost 평문+HTTPS,
                                        # sql:*=실 sqlite3 CRUD(모바일 경로,
                                        # 데스크탑 plugins/sqlite 바이트 동형)
bash tests/mobile-backends/ios-sim-smoke.sh  # iOS 시뮬레이터 변형별 빌드+기동
                                        # 스모크(링크/TLS/심볼충돌 회귀; xcodegen+
                                        # 부팅 시뮬 필요; 기본 zig multi)
bash tests/mobile-backends/ios-e2e.sh   # iOS 시뮬 *기능* e2e — e2e.html 이 실
                                        # UIPasteboard clipboard 8케이스 자가검증
                                        # → 데이터컨테이너 파일 회수·assert
bash tests/mobile-backends/android-e2e.sh # Android 에뮬 *기능* e2e — 실
                                        # ClipboardManager 8케이스 → logcat 회수
                                        # (ANDROID SDK+에뮬+JDK17~21 필요)
bash tests/zig-consumer/run.sh          # 외부 프로젝트가 b.dependency("suji")
                                        # .module("suji") 로 소비 가능 회귀 가드
```

E2E 스크립트는 suji dev를 띄우고 CEF DevTools(`localhost:9222`)에 puppeteer로 붙어
검증. 기존 run-*.sh 스크립트가 자동으로 프로세스 정리까지 한다.

## CLI

```bash
suji init <name> --backend=none|zig|rust|go|node|lua|multi \
  --frontend=react|vue|svelte|solid|preact|vanilla|next \
  --toolchain=vite|rsbuild|next \
  --pm=npm|pnpm|bun|vp   # vp = VoidZero Vite+
suji dev
suji build
suji run                      # 프로덕션 앱 실행
suji run main.js              # CEF 없이 embedded Node.js 파일 실행
suji types [--out <path>]   # zig 백엔드 .schema() → SujiHandlers .d.ts (stdout/파일)
```

`suji types`: zig 백엔드의 `.schema("ch", Req, Res)` 체인을 frontend
`declare module '@suji/api' { interface SujiHandlers {…} }` 로 자동 생성(수동
augment 불요). 백엔드 빌드→dlopen→`backend_dump_schema`(comptime `typeToTs`).
미지정 시 stdout(`suji types > src/suji.d.ts`), `--out`이면 파일. Rust는
`suji::typescript::SujiHandlers` + `#[derive(suji::Type)]`로 수동 등록한
req/res 타입에서 동일한 module augmentation을 생성. Go는 `suji.NewTSHandlers()`와
struct/json tag reflection으로 수동 등록한 req/res 타입에서 생성. Node는 수동
augment를 `invoke/invokeSync/call/callSync`가 소비한다(runtime 타입메타 부재 —
정직 한계).

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
// suji.windows.setAudioMuted(id, true) / isAudioMuted(id)  — webContents audio mute
// suji.windows.setOpacity(id, 0.5) / getOpacity(id)            — NSWindow alphaValue / Win32 layered window
// suji.windows.setBackgroundColor(id, "#ff8800")               — NSWindow.setBackgroundColor (#RRGGBB[AA])
// suji.windows.setHasShadow(id, false) / hasShadow(id)          — NSWindow.hasShadow / Win32 shadow helper
// suji.windows.printToPDF(id, "/tmp/x.pdf")  — PDF 인쇄 (Phase 4-D, 결과는 window:pdf-print-finished)
// suji.windows.capturePage(id, "/tmp/s.png", rect?)  — 스크린샷 PNG (CDP,
//   결과는 window:page-captured; rect{x,y,width,height} 지정 시 부분 영역만)
// suji.clipboard.readText() / writeText("hi") / clear()                — macOS NSPasteboard / Linux GTK text / Windows CF_UNICODETEXT
//   / readHtml() / writeHtml("<b>x</b>")  — HTML round-trip (macOS NSPasteboard / Linux GTK text/html / Windows CF_HTML)
//   / has("public.html") / availableFormats()  — format 검사 (UTI)
//   / writeImage(base64) / readImage() — PNG round-trip (raw ~8KB 1차)
//   / writeTiff(base64) / readTiff() — TIFF round-trip (NSPasteboard public.tiff, PNG 동형)
//   / readRtf() / writeRtf("{\\rtf1...}")  — RTF round-trip (NSPasteboard public.rtf)
//   / readBuffer(uti) / writeBuffer(uti, base64)  — 임의 UTI raw bytes (raw ~8KB)
// suji.powerMonitor.getSystemIdleTime()  — 유휴 초
//   (macOS CGEventSource / Linux XScreenSaver / Windows GetLastInputInfo)
// suji.powerMonitor.getSystemIdleState(60)  — "active"|"idle"|"locked"
//   (잠금 시 "locked" 우선, 아니면 idle_seconds ≥ threshold)
// suji.shell.openExternal("https://...") / showItemInFolder("/path") / beep() / trashItem(path)
//   (openExternal/openPath: macOS NSWorkspace / Linux GIO default handler / Windows ShellExecuteW,
//    showItemInFolder: macOS NSWorkspace reveal / Linux FileManager1 D-Bus / Windows explorer.exe,
//    beep: macOS NSBeep / Linux GDK display beep / Windows MessageBeep,
//    trashItem: macOS NSFileManager / Linux GIO / Windows SHFileOperation)
//   / openPath("/Users/me/file.pdf")     — 로컬 파일 기본 앱으로 (URL이 아닌 path)
// suji.nativeTheme.shouldUseDarkColors() / setThemeSource("light"|"dark"|"system")
//   → suji.on("nativeTheme:updated", ({dark}) => ...) — NSAppearance KVO 자동 발신
// suji.nativeImage.getSize("/path/to/img.png")  — {width, height} (NSImage)
//   / toPng(path) / toJpeg(path, quality)        — base64 인코딩 (raw ~8KB)
// suji.screen.getCursorScreenPoint()      — 플랫폼 native cursor point
// suji.dialog.messageBoxSimple("info", "안녕", &.{ "OK", "Cancel" })   — 응답 raw JSON
// suji.dialog.showOpenDialog("\"properties\":[\"openFile\"]")          — raw fields
// suji.dialog.showErrorBox("Title", "content")
// suji.tray.createWithIcon("App", "tooltip", "/tmp/tray.png")
//   / setMenuRaw(id, "...items with submenu/checkbox...") / destroy(id)
//                                                                       (macOS NSStatusItem / Linux GTK StatusIcon / Windows Shell_NotifyIconW)
// suji.notification.show("Title", "Body", false) / requestPermission() / close(id)
//                                       (macOS UNUserNotificationCenter, .app 번들 필수 / Linux D-Bus / Windows Shell_NotifyIcon balloon)
// suji.menu.setApplicationMenuRaw("\"items\":[...]") / resetApplicationMenu()
//   / popup(items, {x?,y?})  — 임의 위치 컨텍스트 메뉴(macOS NSMenu
//   popUpMenuPositioningItem, Linux GTK popup; x/y 미지정=커서/포인터)
//                                       (macOS NSMenu / Linux GTK, menu:click 이벤트)
// suji.globalShortcut.register("Cmd+Shift+K", "openSettings") / unregister(accel)
//   / unregisterAll() / isRegistered(accel)   (macOS Carbon Hot Key / Linux X11 XGrabKey / Windows RegisterHotKey, globalShortcut:trigger 이벤트)
//   미디어키: register("MediaPlayPause"|"MediaNextTrack"|"MediaPreviousTrack"|
//   "MediaStop", click) — Electron 토큰 패리티. Carbon 불가분 NSEvent
//   systemDefined 모니터 분기(신규 API 0, 동일 register IPC). ⚠️ 글로벌
//   수신은 Accessibility(TCC) 필요(헤드리스 미발화 — globalShortcut 동급 경계)
// suji.screen.getAllDisplays()                — Display 배열 raw JSON (macOS NSScreen / Linux X11 screen)
// suji.desktopCapturer.getSources("screen,window")  — 화면/창 소스
//   {id,name,type,x,y,width,height,displayId?} (CGGetActiveDisplayList +
//   CGWindowListCopyWindowInfo)
//   / captureThumbnail(sourceId, path)  — 소스 PNG 를 파일경로로 캡처
//   (CG capture + ImageIO 인코딩, base64 IPC 한도 우회). ⚠️ Screen Recording
//   TCC 권한 필요 — 미부여/무효 sourceId 시 success:false. 무효 sourceId는
//   파일 미생성까지 E2E 고정. 인코딩 경로는 권한 실기기에서만 실행(헤드리스=
//   컴파일/링크+graceful-fail 만 검증, 정직 경계)
// suji.crashReporter.start("\"uploadToServer\":false") / getParameters()
//   / addExtraParameter(key,value) / removeExtraParameter(key)
//   / getUploadToServer() / setUploadToServer(false)
//   (CEF Crashpad/Breakpad 1차. 첫 프로세스 enable은 app.crashReporter cfg 필요,
//   getUploadedReports/getLastCrashReport는 로컬 Crashpad DB(completed dumps) 조회,
//   실제 crash 유발/upload 서버 검증은 후속 정직 경계)
// suji.powerSaveBlocker.start("prevent_display_sleep") / stop(id)
//   (macOS IOPMAssertion, Linux XScreenSaverSuspend, Windows Power Request API)
// suji.safeStorage.setItem(svc, acc, "v") / getItem(svc, acc) / deleteItem(svc, acc)
//                                       (macOS Keychain, Linux libsecret, Windows Credential Manager)
// suji.dock.setBadge("99") / getBadge()        — dock 배지 (macOS NSDockTile)
// suji.setBadgeCount(5) / getBadgeCount()      — Electron app badge count
//   (macOS dock label, Linux libunity, Windows taskbar overlay best-effort)
// suji.getName() / suji.getVersion()           — config.app.name/version (Electron 동등)
// suji.isPackaged()                              — `.app` 번들 여부 (dev=false, prod=true)
// suji.getAppPath()                              — NSBundle.mainBundle.bundlePath
// suji.isReady() / suji.focus() / suji.hide()  — 앱 init/frontmost/Cmd+H
// suji.getLocale()                              — 시스템 locale (BCP 47, "en-US" 등)
// suji.setProgressBar(0.5)                      — dock 진행률 (NSDockTile)
// suji.getPath("home"|"appData"|"userData"|"temp"|"desktop"|"documents"|"downloads")
// suji.screen.getCursorScreenPoint() / suji.screen.getDisplayNearestPoint(x, y)
// suji.requestUserAttention(true) / cancelUserAttentionRequest(id)
//                                       — dock 바운스 (macOS NSApp `requestUserAttention:`)
// suji.createSecurityScopedBookmark(path) → base64 / startAccessingSecurityScoped
//   Resource(bm) → {id,path,stale} / stopAccessingSecurityScopedResource(id)
//                                       — App Sandbox 영속 파일 접근 (NSURL bookmark,
//                                       비-sandbox=일반 bookmark / MAS 만 실 격상)
// powerMonitor 이벤트 — 자동 install (macOS NSWorkspace, Linux logind/ScreenSaver DBus,
//   Windows WM_POWERBROADCAST/WTS), 4 채널 발신:
//   `power:suspend` / `power:resume` / `power:lock-screen` / `power:unlock-screen`
//   → suji.on("power:suspend", cb) / 다른 SDK도 동일 채널명으로 listen
// suji.process.run(allocator, suji.io(), &.{ "echo", "hi" })  — std.process.run wrap (백엔드 only)
//   → RunResult { code, stdout, stderr }, caller가 stdout/stderr free
// suji.http.fetch(allocator, suji.io(), "https://...", null)   — std.http.Client.fetch wrap
//   → FetchResult { status, body }, payload null이면 GET / non-null이면 POST
// suji.webRequest.setBlockedUrls(&.{ "https://*.ad/*" })   — URL glob blocklist
//   → 매칭 요청 cancel + `webRequest:before-request` / `webRequest:completed` 이벤트
// suji.quit()                  — 앱 종료 요청 (Electron app.quit())
// suji.exit()                  — 앱 강제 종료 (Electron app.exit(), code 무시)
// suji.session.clearCookies() / flushStore() — CEF cookie_manager fire-and-forget
//   / setCookieRaw(args) / getCookiesRaw(args) / removeCookiesRaw(args)
//                                       — Electron session.cookies.set/get/remove
//                                       (visitor 패턴, `session:cookies-result` 이벤트 응답)
//   / clearStorageDataRaw(args)  — Electron session.clearStorageData. CDP
//     Storage.clearDataForOrigin + Network.clearBrowserCache fire-and-forget.
//     origin 미지정 시 현재 문서 origin 자동 해석(앱 자기 storage 삭제) +
//     전역 HTTP 캐시. 전 origin 프로필-전역 wipe 는 CDP 구조상 불가(진짜 제약)
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
// suji::tray::create_with_icon("App", "tip", "/tmp/tray.png")
//   / set_menu(id, &[MenuItem::Item{...}, MenuItem::Checkbox{...}, MenuItem::Separator]) / destroy(id)
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
// suji::exit()                 — 앱 강제 종료 (Electron app.exit, code 무시)
// suji::session::{clear_cookies(), flush_store()}  — CEF cookie_manager fire-and-forget
// suji::platform()             — "macos" | "linux" | "windows"
// suji::typescript::SujiHandlers::new()
//   .handler::<GreetReq, GreetRes>("greet")
//   .export()?              — Rust req/res Type → SujiHandlers .d.ts
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
// tray.CreateWithIcon("App", "tip", "/tmp/tray.png")
//   / SetMenu(id, []tray.MenuItem{{Label:"Quit",Click:"quit"},{Checkbox:true,Label:"Sync",Click:"sync"}}) / Destroy(id)
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
// app.GetPath("userData") / app.Exit()
// import "github.com/ohah/suji-go/session"
// session.ClearCookies() / session.FlushStore()
// import "github.com/ohah/suji-go/attention"
// attention.RequestUser(true) / attention.CancelUserRequest(id)
// import "github.com/ohah/suji-go/webrequest"
// webrequest.SetBlockedUrls([]string{"https://*.ad/*"})
// suji.Quit()                   — 앱 종료
// suji.Platform()               — "macos" | "linux" | "windows"
// suji.NewTSHandlers().Handler("greet", GreetReq{}, GreetRes{}).Export()
//   — Go req/res struct → SujiHandlers .d.ts
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
// import { app, session } from '@suji/api';
// await app.exit()                                           // Electron app.exit() (code 무시)
// await session.clearCookies() / session.flushStore()        // CEF cookie_manager fire-and-forget

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
// await windows.setUserAgent(id, ua) / getUserAgent(id)  — 동적 UA(CDP override)
//   ※ class BrowserWindow OO 래퍼: BrowserWindow.create(opts)/fromId(id) +
//     인스턴스 메서드(setTitle/loadURL/setUserAgent/…) — 4 SDK 동형(Electron 패리티)
// await windows.setZoomFactor(id, 1.2) / setZoomLevel(id, 1.5)  (Phase 4-B)
// await windows.openDevTools(id) / toggleDevTools(id) / isDevToolsOpened(id)  (Phase 4-C)
// await windows.undo(id) / copy(id) / paste(id) / findInPage(id, "x", {})  (Phase 4-E)
// await windows.minimize(id) / maximize(id) / unmaximize(id) / restore(id) / show(id) / hide(id)
//   / close(id) / setFullScreen(id, true) / isMinimized(id) / isMaximized(id) / isFullScreen(id)
//   — Electron BrowserWindow 생명주기 (Zig 백엔드 기존 구현을 SDK 노출, 전수조사 후속). BrowserWindow 클래스 동형
// const { success } = await windows.printToPDF(id, "/tmp/x.pdf")  (Phase 4-D)
// await windows.createView({hostId, url, bounds}) → {viewId}              (Phase 17-B WebContentsView)
// await windows.addChildView(host, view, index?) / setTopView / removeChildView
// await windows.setViewBounds(viewId, {...}) / setViewVisible(viewId, bool) / getChildViews(host)
//   viewId는 windowId와 같은 풀 — windows.loadURL(viewId,...) / executeJavaScript / openDevTools
//   등 모든 webContents API가 view에도 동작.
//   destroyView는 17-B CEF Views 경로에서 안정화 — target child cleanup/host 생존/
//   remaining view/recreate를 E2E로 검증. 단순 동적 hide/show는 setViewVisible 사용.
// Zig plugin/backend low-level: suji.getWindowApi() → WindowApi? (request_json/free_response).
//   windows.*는 주입된 WindowApi를 우선 사용하고 없으면 invoke("__core__")로 폴백.
// C plugin/backend low-level: include/suji.h declares SujiCore + WindowApi v1.

// import { clipboard, shell, dialog } from '@suji/api';
// await clipboard.readText() / writeText(text) / clear()                  (macOS NSPasteboard / Linux GTK text / Windows CF_UNICODETEXT)
// await clipboard.readHTML() / writeHTML(html)                            (macOS NSPasteboard / Linux GTK text/html / Windows CF_HTML)
// await shell.openExternal(url) / showItemInFolder(path) / beep() / trashItem(path)
//   (macOS NSWorkspace + NSFileManager, Linux GIO/FileManager1, Windows ShellExecute/explorer/MessageBeep/SHFileOperation)
// await dialog.showMessageBox({ type, message, buttons, defaultId, ... }) (macOS NSAlert / Linux GTK / Windows TaskDialog)
// await dialog.showMessageBox(windowId, options)  — macOS sheet, Linux/Windows free-floating
// await dialog.showOpenDialog({ properties:['openFile','multiSelections'], filters }) (NSOpenPanel / GTK FileChooser / Win32 file dialog)
// await dialog.showOpenDialog(windowId, options) — macOS sheet, Linux/Windows free-floating
// await dialog.showSaveDialog({ defaultPath:'~/x.txt', nameFieldLabel })  (NSSavePanel / GTK FileChooser / Win32 file dialog)
// await dialog.showSaveDialog(windowId, options) — macOS sheet, Linux/Windows free-floating
// await dialog.showErrorBox(title, content)                               (간이 에러 popup)

// import { globalShortcut } from '@suji/api';
// await globalShortcut.register("Cmd+Shift+K", "openSettings")            (macOS Carbon Hot Key / Linux X11 XGrabKey / Windows RegisterHotKey)
// await globalShortcut.unregister(accel) / unregisterAll() / isRegistered(accel)
// suji.on('globalShortcut:trigger', ({accelerator, click}) => ...)

// import { screen, powerSaveBlocker, safeStorage, app, webRequest, crashReporter, autoUpdater } from '@suji/api';
// const displays = await screen.getAllDisplays()                         (macOS NSScreen / Linux X11 screen)
// await crashReporter.start({uploadToServer:false, extra:{suite:"e2e"}})
// await crashReporter.addExtraParameter("mode", "test") / getParameters()
// const update = await autoUpdater.checkForUpdates({version:"1.2.3", url:"https://example/app.zip"})
// const downloaded = await autoUpdater.downloadArtifact(update, "/tmp/app.zip")
// await autoUpdater.verifyFile(path, sha256)
// const prepared = await autoUpdater.prepareInstall(downloaded, {format:"zip"})
// await autoUpdater.quitAndInstall(prepared, {relaunch:true})              (macOS/Linux shell helper, Windows PowerShell helper)
//                                                                         (manifest check + download + SHA-256 verify + quit-and-install)
// const id = await powerSaveBlocker.start("prevent_display_sleep")
// await powerSaveBlocker.stop(id)                                         (macOS/Linux/Windows)
// await safeStorage.setItem(svc, acc, "v") / getItem(svc, acc) / deleteItem(svc, acc)
//                                                                         (macOS Keychain, Linux libsecret, Windows Credential Manager)
// await app.dock.setBadge("99") / app.dock.getBadge()                     (macOS NSDockTile)
// await app.setBadgeCount(5) / app.getBadgeCount()                        (Electron app badge count)
//   macOS dock label / Linux libunity / Windows taskbar overlay best-effort
// await app.getPath("userData" | "home" | "documents" | ...)              — Electron app.getPath
// const reqId = await app.requestUserAttention(true)                      (macOS NSApp `requestUserAttention:`)
// await app.cancelUserAttentionRequest(reqId)
// const bm = await app.createSecurityScopedBookmark(path)                 — App Sandbox 영속 파일 접근
// const acc = await app.startAccessingSecurityScopedResource(bm)          → {id,path,stale}
// await app.stopAccessingSecurityScopedResource(acc.id)                   (NSURL bookmark; 비-sandbox=일반)
// await webRequest.setBlockedUrls(["https://*.ad/*"])                     (CEF ResourceRequestHandler)
//   → suji.on('webRequest:completed', ({url, statusCode, ...}) => ...)
// await webRequest.onBeforeRequest({urls:["https://*.tracker/*"]}, (details, cb) => cb({cancel:true}))
//   → RV_CONTINUE_ASYNC + listener round-trip cancel/allow (e2e 13 pass)
```

## Suji 설정

`suji.config.ts`가 생성 프로젝트의 source config이고, `suji.json`은 materialized JSON입니다. 네이티브 로더는 `suji.config.ts`/`.mts`/`.cts`/`.js`/`.mjs`/`.cjs`를 먼저 찾고, `@suji/cli`의 JS/TS config loader로 실제 코드를 평가한 뒤 JSON만 Zig 파서에 넘깁니다. 로더가 없는 직접 native 실행 환경에서는 JSON-compatible `defineConfig({ ... })` 정적 fallback만 사용합니다. config 파일은 신뢰한 프로젝트 코드로 실행됩니다. JSON Schema 제공: [`suji.schema.json`](./suji.schema.json) — IDE 자동완성 + 검증 지원.

**프로그래밍 기능 (vite/rspack식 — 정적 JSON 미표현):** 함수형 config `defineConfig(({mode,command})=>({...}))`, **빌드 라이프사이클 훅** `build.beforeBuild`/`afterBuild`/`beforeDev`, **플랫폼별 빌드 오버라이드** `build.{mac,win,linux}`(현재 OS로 fold), **dev.env**(dev 서버 spawn 시 주입), `window` 단축(→`windows[]`)·`dev.devUrl`(→`frontend.dev_url`). loader가 평가 시 현재 플랫폼 build를 fold + 훅 함수를 `build._hooks` 마커로 strip(함수 직렬화 불가)해 JSON으로 emit하고, CLI(`config.zig`가 `--command/--mode` 전달)가 라이프사이클 지점에서 `node load-config.js --hook <name>` 로 훅을 재실행한다. 서명 우선순위: CLI 플래그 > env > `config.build.*` > adhoc. 회귀: `tests/config-loader/run.sh`(loader normalize/hook) + `tests/config_test.zig`(Zig build/dev 파싱).

```ts
// suji.config.ts
import { defineConfig } from "@suji/cli";
export default defineConfig(({ mode }) => ({
  app: { name: "My App", version: "1.0.0" },
  build: {
    async beforeBuild() { /* … */ },
    mac: { sign: "identity", notarize: mode === "production" },
  },
  dev: { devUrl: "http://localhost:12300", env: { VITE_API: "http://localhost:8787" } },
}));
```

```json
{
  "$schema": "./suji.schema.json",
  "app": { "name": "My App", "version": "1.0.0", "deepLinkSchemes": ["myapp"] },
  "window": {
    "title": "My App",
    "width": 1024,
    "height": 768,
    "debug": false,
    "protocol": "file"       // "file" (기본, file://) | "suji" (suji:// 커스텀 프로토콜)
  },
  "frontend": {
    "dir": "frontend",
    "dev_url": "http://localhost:12300",
    "dev_command": "bun run dev",
    "build_command": "bun run build",
    "dist_dir": "frontend/dist"
  }
}
```

`protocol: "suji"` — CORS, fetch, Cookie, Service Worker가 정상 동작하는 커스텀 프로토콜. prod 빌드 시 `suji://app/` URL로 프론트엔드 로드. 이것이 Suji의 same-origin 커스텀 scheme 메커니즘(Electron `protocol.handle`의 앱 로딩/정적 서빙 용도를 충족). ⚠️ 임의 cross-origin 동적 `protocol.handle`(요청마다 백엔드가 응답 계산)은 **미지원** — CEF cross-origin scheme-handler IO-스레드 결함으로 보류(루트커즈·재개조건: docs/PLAN.md "protocol.handle 보류 사유").

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
// await clipboard.readHTML() / writeHTML("<b>x</b>")  // macOS NSPasteboard / Linux GTK text/html / Windows CF_HTML
// await shell.openExternal(url) / showItemInFolder(path) / beep() / trashItem(path)
//   (Linux: openExternal/openPath/trashItem = GIO, showItemInFolder = FileManager1, beep = GDK;
//    Windows: ShellExecute/explorer/MessageBeep/SHFileOperation)
// await dialog.showMessageBox({ message:"...", buttons:["OK"], windowId? })
// await dialog.showOpenDialog({ properties:["openFile"], filters }) / showSaveDialog(...)
// await dialog.showErrorBox(title, content)
// const { trayId } = await tray.create({ title:"App", tooltip:"...", iconPath:"/tmp/tray.png" })
// await tray.setMenu(trayId, [{label:"Quit",click:"quit"},{type:"checkbox",label:"Sync",click:"sync",checked:true},{label:"More",submenu:[{label:"Reload",click:"reload"}]}])
// await tray.destroy(trayId) — suji.on('tray:menu-click', ({trayId,click}) => ...)
// const sup = await notification.isSupported() (macOS Bundle ID 필수 / Linux D-Bus daemon / Windows Shell_NotifyIcon balloon)
// await notification.requestPermission() / show({title,body,silent}) / close(notificationId)
//                              — suji.on('notification:click', ({notificationId}) => ...)
// await menu.setApplicationMenu([{label:"Tools",submenu:[{label:"Run",click:"run"}]}])
// await menu.resetApplicationMenu()
// await menu.popup([{label:"Run",click:"run"}], {x:10,y:10}) — suji.on('menu:click', ({click}) => ...)
// import { screen, powerSaveBlocker, safeStorage, app, webRequest, session, crashReporter, autoUpdater } from '@suji/node'
// const displays = await screen.getAllDisplays()                         (macOS NSScreen / Linux X11 screen)
// await crashReporter.start({uploadToServer:false})
// await autoUpdater.checkForUpdates({version:"1.2.3", url:"https://example/app.zip"})
// const downloaded = await autoUpdater.downloadArtifact("https://example/app.zip", "/tmp/app.zip", {sha256})
// const prepared = await autoUpdater.prepareInstall(downloaded, {format:"zip"})
// await autoUpdater.quitAndInstall(prepared, {relaunch:true})              (macOS/Linux shell helper, Windows PowerShell helper)
// const id = await powerSaveBlocker.start("prevent_display_sleep") / stop(id)  (macOS/Linux/Windows)
// await safeStorage.setItem(svc, acc, "v") / getItem(svc, acc) / deleteItem(svc, acc)
// await app.dock.setBadge("99") / app.dock.getBadge()
// await app.setBadgeCount(5) / app.getBadgeCount()
// await app.getPath("userData") — Electron app.getPath
// await app.exit()                                                       — 앱 강제 종료 (code 무시)
// const reqId = await app.requestUserAttention(true) / cancelUserAttentionRequest(reqId)
// await webRequest.setBlockedUrls(["https://*.ad/*"])
// await session.clearCookies() / session.flushStore()                    — CEF cookie_manager

// 공식 플러그인 backend 래퍼 (renderer @suji/plugin-* 의 Node 백엔드 변형)
// const { state } = require('@suji/plugin-state-node')
//   await state.set("user", { name:"yoon" }, { scope:"window:1" }) / get / delete / keys / clear
//   const cancel = state.watch("user", (v) => ...)                       — EventBus
// const { sqlite } = require('@suji/plugin-sqlite-node')
//   const db = await sqlite.open(":memory:"); await sqlite.execute(db, "INSERT...VALUES(?)", ["x"])
//   const rows = await sqlite.query(db, "SELECT * FROM t WHERE n=?", ["x"]); await sqlite.close(db)

// suji.json plugins: "state" 또는 {name, source?, permissions?}
//   source=로컬 경로 또는 github.com/owner/repo. GitHub source는 ~/.suji/plugins에 clone/pull.
//   permissions 생략=unrestricted, []=deny-all, exact / "prefix:*" / "*" outbound invoke allowlist.

// TypeScript type-safe — `@suji/node`도 SujiHandlers augment 지원.
//   await invoke('zig', { cmd: 'greet', name: 'x' }) // res: string 추론
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
│   │   ├── cef.zig           # CEF 통합 re-export hub (창, IPC, 렌더러, 커스텀 프로토콜)
│   │   ├── cef_*.zig         # 도메인 분리 모듈 (clipboard/shell/dialog/... — docs/CEF_REFACTOR.md)
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
  + `embed-lib` job (CEF 무관 host/iOS/Android/Windows 크로스 빌드 회귀 방지)

## 임베드 코어 (CEF 무관 / 모바일)

데스크톱은 CEF가 창/렌더러를 들지만, 코어 로직(`BackendRegistry`+`EventBus`)은
CEF 의존이 0이라 별도 정적 라이브러리로 분리된다.

- `src/embed.zig` — `BackendRegistry`+`EventBus`를 감싸는 C ABI shim. `zig build
  lib`이 `libsuji_core.a` 생성(CEF/Cocoa/Node 링크 없음).
- C ABI 표면: `suji_core_init/destroy/invoke/free/emit/emit_to/on/off`
  + `suji_core_register_handler`(호스트가 채널을 네이티브로 응답 — `embed_runtimes`
  경로 재사용) + `suji_core_last_error`(단일 -1 보강, 사람이 읽는 사유 — 정적,
  free 금지; zero-native `last_error_name` 차용)
  + `suji_core_set_permissions(json,len)` / `suji_core_permission_check(family,
  value,is_backend)` — **모바일 권한 게이트(Tauri 패리티) 완료**: 게이트
  로직은 `util.*`(CEF-free) 단일 출처 재사용(Swift/Kotlin 보안 로직 0).
  호스트(iOS `_shared` Swift / Android `_shared` Kotlin·JNI)가 init 후 앱
  컨테이너 정책 set → 네이티브 shell/fs 액션 직전 check. 모바일 uniform
  opt-in(키 부재=허용/비파괴, 존재=enforce). null fail-closed. dialog 는
  OS 문서 피커(사용자 중재)라 미게이트. **iOS 실 시뮬 + Android 실 에뮬
  기능 e2e 양쪽 37/37 검증**(ios-e2e.sh/android-e2e.sh 권한 5케이스)
  ([`include/suji_core.h`](./include/suji_core.h), 수기 동기화).
- `main.zig`(CEF 호스트)도 `embed.init/registry()/eventBus()` 경유 — 호스트는
  embed 경계로만 코어 접근, 경계가 CEF 의존을 컴파일 단계에서 차단.
- 모바일 호스트 예제 — **언어별 변형**(PC `examples/*-backend` 대응). 모바일은
  호스트에 정적 링크라 "언어별"=링크/등록 백엔드 차이. 호스트 스캐폴딩은
  `_shared/`에 두고 변형은 thin:
  - `examples/ios/{_shared, multi, rust, go, zig, sqlite}` — XcodeGen
    `project.yml` (`sources: ../_shared`) + Swift `WKWebView`.
    `_shared/BackendBridge.swift` 공용. multi=Rust+Go, 단일=해당 언어,
    sqlite=`plugins/sqlite` 모바일(벤더 sqlite3.c, `suji_sqlite_backend_*`,
    todo 데모; iOS xcodebuild BUILD SUCCEEDED 실증).
  - `examples/android/{_shared, multi, rust, go, zig, sqlite}` —
    Gradle(`sourceSets`로 `_shared` 공유) + JNI. `_shared/cpp/
    suji_jni_core.c`(코어 JNI+공용 `suji_reg_backend`) + 변형
    `cpp/backends.c`. Rust/Zig/SQLite=`.a` 정적, Go=`.so` c-shared
    (Android는 Go c-archive 미지원).
  - 백엔드 소스 `examples/ios/backends/{rust,go,zig,sqlite}` iOS·Android 공유.
    언어 고유 심볼(`export_handlers_static!`→`suji_rs_*`/cgo `suji_go_*`/
    `suji_zig_*`)로 단일 바이너리 무충돌. 각 `build-lib.sh`로 `.a`/`.so`
    스테이징, `suji_core_register_handler` 등록 + `(channel,json)→{"cmd":..}`
    는 `include/suji_mobile_bridge.h` 공용(verify.c·JNI 공유).
  - iOS 시뮬레이터·Android 에뮬레이터에서 빌드+구동 검증됨(multi·zig 변형
    실디바이스 스크린샷: Rust greet / Go go:ping / Zig zig:rev / demo:tick
    네이티브→JS→DOM). Android 코어는 동적 `.so`(`-Dlib-dynamic`+NDK `--libc`,
    zig LE-TLS↔JNI `-shared` 회피), Go `.so` `-Wl,-soname`, Zig 백엔드 `-fPIC`.
    메커니즘 회귀는 `tests/mobile-backends`(호스트 하니스, CI job) 가드.

**모바일 http (`suji.http.fetch` 동등)**: 모바일 백엔드는 코어-독립이라 SDK
대신 std 를 직접 — `examples/ios/backends/zig` 의 `zig:http` 핸들러가
`std.http.Client`(자체 `std.Io.Threaded.init_single_threaded`, embed.zig 패턴
복제) 로 GET/POST. **backend-only**: 프론트(WebView) shim 에 채널 노출 금지
(Zig SDK frontend 미노출 보안모델을 모바일에서도 관례+문서로 유지).
실증=`tests/mobile-backends`(host, register_handler→handle_ipc→std.http→
localhost 평문 왕복 + 로컬 HTTPS fixture 왕복). iOS 는
`suji_zig_backend_set_ca_bundle_path()` 로 앱 번들 `cacert.pem` 을 std CA bundle 에 주입하고
`examples/ios/zig/build-lib.sh` 가 `Vendor/cacert.pem` 을 스테이징한다(Android
는 Zig std Linux rescan 의 `/system/etc/security/cacerts` 후보 사용). 빌드-only
검증=aarch64-ios/-simulator/android-cross 컴파일·정적 링크 성공.
**미검증(정직)**: 실기기·실 네트워크.
`process.run` 은 iOS 샌드박스 fork/exec 금지로 모바일 제외.

**모바일 네이티브 `@suji/api` (`__core__` 와이어, Tauri 동형)**: 데스크톱과
*동일* 프론트 API(`suji.clipboard.*` = `coreCall→__suji__.core`)가 모바일에서도
동작 — 호스트(iOS Swift `sujiCoreDispatch`/Android Kotlin `coreDispatch`)가
`suji_core_register_handler("__core__", …)` 로 cmd 를 네이티브 디스패치
(`coreInvoke` → embed_runtimes 폴백 → `extractCmdField`). 응답은 데스크톱
`src/main.zig cefHandleCore` 와 **키-동형** → `packages/suji-js` **무수정**
(데스크톱 무회귀). bridgeJS `api.core`(재인코딩 금지) 추가 — iOS `_shared` +
Android 4× `web/index.html`(동일변경, drift 주의). **Slice 1~11**(모바일
대응 가능 데스크톱 API 사실상 전부 배선; ⚠️ Android rtf/image/buffer
custom-MIME 앱-내 한정; dialog open/save 보안스코프/content URI; shell
open_path/show_item/trash 모바일 한계 graceful false — beep 만 실
네이티브; fs 는 OS 샌드박스가 경계(allowedRoots 대신); 정직 한계 PLAN
참조):
clipboard(text+html/rtf/image+buffer/has/formats 12)·shell(open_external+
beep)·notification(4)·**dialog(message_box/error/open/save — 호스트-async
가로채기, 사용자 상호작용이라 자동 e2e 불가·빌드+메커니즘 검증)**·
safe_storage(3, iOS Keychain / Android Keystore AES-GCM)·app 메타(4)·
fs(read/write/readdir/stat/mkdir/rm 6, 샌드박스 내). 검증:
`tests/mobile-backends/run.sh`(mock `__core__` 라우팅+키-동형+unknown_cmd,
전체 65/65) + **`ios-e2e.sh`/`android-e2e.sh`**(실 디바이스 e2e: 실 UIPasteboard
(public.html/rtf/png/buffer)/ClipboardManager·Keychain/Keystore·Bundle/
Locale·샌드박스 FS(stat/mkdir/rm) 왕복 자가검증, iOS 32/32 + Android 32/32).
⚠️ **미검증/범위밖**: dialog 탭·실 알림 표시·실 URL open(스모크), 실기기
(시뮬·에뮬 ≠ 디바이스). 데스크톱↔모바일 cmd 커버리지표·미배선/불가
분류는 docs/PLAN.md.

**한계**: window/tray/menu/globalShortcut 등 모바일에 개념 없는 데스크톱
네이티브 API는 호스트가 `unknown_cmd` 동형 반환(프론트 graceful false/빈값).
나머지(clipboard 등)는 위 `__core__` 슬라이스로 점진 배선. **iOS·Android 둘 다 Rust·Go 백엔드 동작**(언어별 고유 심볼
`suji_rs_*`/`suji_go_*` + `suji_core_register_handler`). iOS=Rust staticlib
+ Go c-archive(둘 다 `.a` 정적 링크), Android=Rust `.a` 정적 + Go `.so`
c-shared(Android는 Go c-archive 미지원 → JNI `.so`가 정적/공유 혼합 링크).
`(channel,json)→{"cmd":..}` 브리지는 `include/suji_mobile_bridge.h` 공용
(verify.c·JNI 공유, iOS는 Swift 동형). **Node 만 iOS 미지원** — V8 JIT 가
iOS 코드서명 샌드박스에서 금지(정적 링크해도 런타임 코드 생성 불가).
Android Node 는 NDK로 가능하나 예제 미배선(후속).

## 앱별 cache / 사용자 데이터 (Electron `app.getPath('userData')` 동등)

`config.app.name`을 키로 OS 표준 user-data 디렉토리 아래 격리. 한 시스템에 여러 Suji 앱
설치 시 cookie/localStorage/IndexedDB/Service Worker 자동 격리.

| OS | 경로 | env fallback |
|----|------|------|
| macOS | `~/Library/Application Support/<app>/Cache` | `$HOME` |
| Linux | `$XDG_CONFIG_HOME/<app>/Cache` (없으면 `~/.config/<app>/Cache`) | XDG Base Directory Spec |
| Windows | `%APPDATA%/<app>/Cache` (없으면 `%USERPROFILE%/AppData/Roaming/<app>/Cache`) | Roaming 표준 |

## contextIsolation (window.__suji__ 하드닝)

`onContextCreated` 가 멤버 조립 후 `window.__suji__` 를 `Object.freeze` + window
슬롯 `non-writable`/`non-configurable` 봉인 — 페이지 스크립트가 bridge 메서드
재할당/추가/삭제, 객체 통째 교체/삭제 불가. shallow freeze 라 내부
`_pending`/`_listeners` 는 가변 → invoke/on/off 무손상. **항상 적용**.

**한계(정직)**: 우리 바인드보다 *먼저* 실행된 스크립트는 못 막음(메인 월드
frozen — Chrome isolated-world 아님). 진짜 별도-world 격리는 CEF C API
world-id/contextBridge 부재로 blocked(docs/PLAN.md Phase 7, 정적 가드 있음).
⚠️ `onContextCreated` 의 `ctx.eval` 은 **정확히 1회**
(js_code+bootstrap 단일 `combined_js`. 추가 eval 금지 — 늘리면 CEF inspector
attach 30s 행, `e2e set-user-agent` 가드. 새 JS 는 별도 eval 아니라
combined_js 에 이어붙일 것).

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

렌더러-제어 경로를 받는 역사적-무제한 cmd 도 fs sandbox 우회를 막기 위해
동일 `allowedRoots` 경계로 게이트(`rendererPathFsGate`) — 쓰기:
`print_to_pdf`/`capture_page`/`desktop_capturer_capture_thumbnail`, 읽기:
`native_image_get_size`/`native_image_to_png|jpeg`(임의 파일을 base64 로
렌더러에 반환 = 파일내용 유출), 이미지 로드 `tray_create.iconPath`. 단 **opt-in**(이 API들은 그동안 무제한 출하
— `allowedRoots` 미설정/`[]`이면 레거시 무제한 비파괴, 설정 시 `fs.*` 와
동일 경계 enforce → 설정한 fs 통제가 이 경로 읽기/쓰기도 포함). backend 우회 동일.

### shell / dialog allowlist (opt-in)

`shell.*`(open_external URL · open_path/show_item/trash path) 와 `dialog` open/save
의 `defaultPath` 도 동일 메커니즘으로 게이트. **fs 와 달리 opt-in** — shell/dialog
는 그동안 무제한 출하라 키 부재 시 동작 불변(레거시 무제한)으로 **비파괴**.

```json
{ "shell": { "allowedPaths": ["~/Documents/myapp"],
             "allowedExternalUrls": ["https://*.example.com/*"] },
  "dialog": { "allowedPaths": ["~/Documents"] } }
```

| 설정 | Frontend 동작 |
|------|---|
| 키 미설정 | 레거시 무제한 (기존 동작, 비파괴) |
| `[]` (키 존재, 빈 배열) | 전부 차단 → `error:"forbidden"` (enforce deny-all) |
| `["~/Documents/x"]` / `["https://*.ok/*"]` | 매치만 허용 (path=prefix+boundary, url=`util.matchGlob` 재사용) |
| `["*"]` | escape hatch |

path 는 fs 와 동일 `..`/boundary 가드, url 은 glob(`..` 개념 없음). backend SDK
호출은 fs 와 동일 thread-local 마커로 우회. dialog 는 사용자 중재라 빈 `defaultPath`
는 무제약(프로그램 pre-fill 만 제약). network(webRequest setter)는 선언적
net-control 이라 데이터 유출 sink 아님 → 범위 제외. 모바일은 OS 샌드박스가
경계(fs 동일 — 후속 결정).

## 알려진 이슈

- macOS 26.4 + Xcode 26.4: Zig 링커 버그 (Xcode 26.2 필요)
- Go 빌드: Homebrew LLVM 충돌 (CC=/usr/bin/clang 자동 설정)
- ~~Windows dlopen 백엔드 로드 불가~~ **해결됨**: [#11](https://github.com/ohah/suji/issues/11)
  - Zig 0.16의 `std.DynLib` Windows 제거는 의도된 설계(릴리스 노트) — regression 아님.
  - `loader.zig`가 kernel32 `LoadLibraryExW`/`GetProcAddress`/`FreeLibrary`를 직접
    래핑(`WinDynLib`). POSIX는 `std.DynLib` 그대로, 호출부 불변.
  - state 플러그인 + Rust/Go 래퍼 통합 테스트의 Windows skip 가드 제거 —
    Windows CI(`test-state`/`-rust`/`-go`)가 `.dll` dlopen 왕복까지 실증.
- ~~Windows Go c-shared DLL 로드 실패 (ERROR_BAD_EXE_FORMAT 193)~~ **해결됨** (PR #35).
  Go 1.26+ 의 `-buildmode=c-shared` 가 PE loader 호환되지 않는 DWARF/.debug_*
  섹션을 emit. `suji dev` / build.zig 의 Windows 분기에 `-ldflags=-s -w` 추가로
  fix. `test-state-go` 가 0→10/10 pass.
- ~~Windows Rust SDK 빌드 실패 (specta unstable feature)~~ **해결됨** (PR #37).
  `specta 2.0.0-rc.25` 가 unstable Rust feature `debug_closure_helpers`
  ([rust-lang/rust#117729](https://github.com/rust-lang/rust/issues/117729)) 사용.
  `crates/suji-rs` 의 typescript 생성 기능을 `typescript` cargo feature 로
  격리 — default 빌드에선 specta 없이 stable Rust 빌드 통과. TypeScript
  declaration 필요 시 `--features typescript` (nightly Rust 또는
  RUSTC_BOOTSTRAP=1 + 패치 필요). `test-state-rust` 가 0→11/11 pass.
- ~~Windows ReleaseSafe translate-c 'unused local constant' 컴파일 실패~~
  **해결됨** ([#14](https://github.com/ohah/suji/issues/14)). MinGW `<string.h>` 가
  `__MINGW_FORTIFY_LEVEL > 0`(게이트 `_FORTIFY_SOURCE>0 && __OPTIMIZE__>0`,
  `_mingw_mac.h:331`)일 때 `wcscat`/`wcscpy` 를 `wcscat_s`/`wcscpy_s` 호출하는
  bos-check inline override 로 재정의. Zig 0.16 translate-c 가 그 fortified
  wrapper struct(`extern_local_wcscat_s`)를 `_ = &` discard 없이 생성 →
  ReleaseSafe(C 를 `__OPTIMIZE__>0` 로 번역) 의미분석에서 unused-local 실패.
  Debug(-O0)는 `__OPTIMIZE__` 미정의라 override 미생성→통과. `cef_c.zig`
  `@cImport` 에 Windows-only `@cDefine("_FORTIFY_SOURCE","0")` 로 게이트를 닫아
  근본 해결(fortify 는 CEF 바인딩 무관 — prebuilt lib + 헤더 번역만). release.yml
  Windows=Debug 워크어라운드 제거 → 전 플랫폼 ReleaseSafe.
- ~~Windows ReleaseSafe/ReleaseFast 패키지 빈 화면 (렌더러 크래시)~~ **해결됨**
  ([#60](https://github.com/ohah/suji/issues/60) part 2). Windows 최적화 빌드에서
  렌더러 서브프로세스가 첫 V8 컨텍스트 부트스트랩(`Genesis::CompileExtension`) 중
  `Isolate::StackOverflow` → 부트스트랩 중 throw 불가 → `ud2`(0xC000001D) 크래시 →
  `onContextCreated` 미발화 → `window.__suji__` 미바인딩 → 빈 화면. **루트커즈**:
  ReleaseSafe/Fast 가 호스트 로직(logger/config/runDev — 큰 스택 로컬)을 `main()`
  으로 적극 인라인해 `main()` 프레임이 수 MB 로 비대해지고, 렌더러는 절대 반환하지
  않는 `cef_execute_process` 를 그 거대 프레임 "위에서" 실행한다. V8 은 스택 예산을
  `stack_start`(스택 base) 기준 ~1MB 로 측정하므로, base 아래 ~6.3MB 가 이미 소비된
  채 부트스트랩이 돌면 즉시 오버플로우(실제 64MB reserve 무관 — base 기준 측정).
  Debug 는 인라인이 없어 프레임이 작아 통과. **수정**: `src/main.zig` 에서
  `cef.executeSubprocess()` 이후 호스트 로직을 `runHost` 로 분리하고
  `@call(.never_inline, runHost, .{init})` 로 호출 → `main()` 프레임이 작아져 렌더러가
  얕은 스택에서 V8 예산을 온전히 확보. CEF private 심볼(공식 `_release_symbols`
  패키지) + cdb 로 규명. **디버그 모드**: `SUJI_CEF_DEBUG=1` 환경변수로 Chromium
  verbose 로깅 + 렌더러 crash/navigation 진단 핸들러 + `[cef-debug]` 마커 + ABI 덤프 +
  패닉 stderr 직출력 활성(미설정 시 프로덕션 클린). `SUJI_NO_RELAUNCH` = de-elevation
  self-relaunch 우회(렌더러 경로 격리 디버깅용).
- ~~Windows 네이티브 API 격차 (tray click/menu, globalShortcut trigger,
  nativeTheme event, opacity/shadow non-Views, OS-initiated window state,
  directory picker, custom dialog buttons, notification click)~~ **해결됨**
  (PR #27~#34). `win_pump` 백그라운드 스레드 + hidden message-only window +
  `src/suji.manifest` (Common-Controls v6 + PerMonitorV2) 로 macOS 동등 동작.
- ~~Linux/Windows GPU 가속 미지원 (`--disable-gpu`)~~ **해결됨** ([#12](https://github.com/ohah/suji/issues/12)).
  CEF runtime asset (libEGL/libGLESv2/vk_swiftshader/vk_swiftshader_icd.json) 가
  `addInstallCefRuntimeStep` 으로 zig-out/bin 옆에 자동 배치되어 ANGLE/SwiftShader
  로딩 가능 → WebGL/CSS 합성/비디오 가속 활성. CI headless 환경은 GPU 없어
  SwiftShader CPU fallback 자동(정상 동작).
- **`@suji/plugin-notification-rich` macOS/Linux 액션 버튼 구현됨**:
  macOS는 `UNUserNotificationCenter` category/action + attachment best-effort,
  Linux는 Freedesktop Notifications D-Bus `Notify` actions +
  `ActionInvoked` signal subscribe 경로. 액션 클릭은 기존
  `notification:click` 채널에 `{notificationId, actionId}`로 라우팅한다.
  정직 경계: macOS loose binary는 Bundle ID/권한 한계로 표시 실패 가능,
  Linux는 session bus/notification daemon 부재 시 `show failed`.
- **`@suji/plugin-notification-rich` Windows 액션 클릭 콜백 미구현**:
  WinRT toast 액션 버튼 클릭은 `NotificationActivator` COM 클래스 등록 필요
  (별도 인스톨러 + HKCU 레지스트리). 현재는 표시/Action Center 영속까지만.
- **deferred-response same-path/same-kind 상관 (의도적 미수정)**: 동일 window·
  동일 path·동일 종류(`printToPDF`×2 또는 `capturePage`×2)를 **동시** 호출하면
  두 슬롯이 path 로만 구분돼 완료 콜백이 등록 순서로 매칭(물리적 완료 순서
  아님). 관측 가능한 차이는 caller 별 `success` bool 뿐이고 디스크 결과는
  last-writer-wins 로 동일, 동일 조건 print/capture 는 성공/실패가 거의 완벽히
  상관돼 사실상 비가시. 정직한 correlation-id 재설계는 per-call ref-counted CEF
  콜백 수명 관리(issue #16 가 leak 이던 표면)를 재도입하므로 비용 대비 가치 낮아
  미수정. **서로 다른 종류**(print↔capture)의 같은-path 교차충돌은 `kind`
  디스크리미네이터로 해소됨(PR #54 review #3). UAF/슬롯 고갈/타임아웃은 모두 수정.

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

### Lua 임베드 런타임 (Phase 5.5 1차)

`zig build -Dlua`에서 LuaJIT(`libluajit-5.1`) 기반 Lua backend가 활성화된다.
기본 빌드는 런타임 의존성을 추가하지 않기 위해 `lua_enabled=false`이며,
`lang:"lua"` backend는 실행 시 "rebuild with -Dlua" 메시지로 graceful skip.

현재 Lua ABI는 raw JSON string in/out:

```lua
suji.handle("ping", function(request_json)
  return '{"msg":"pong"}'
end)
```

구현 범위: `src/platform/lua.zig`, `main.zig` load/route/teardown, schema
`lang:"lua"`, `examples/lua-backend`. `cjson` 번들, 정적 liblua, 여러 Lua
runtime 동시 map, LuaRocks/배포 번들링은 후속.

검증:
- 깊은 재귀 체인(node→zig→rust→go→node→... 최대 depth=40, 10사이클)
- 다른 스레드 재진입 (`rust-thread-node` + `node-thread-deadlock`)
- 응답 메모리 누수 회귀 (200회 체인 호출)
모두 `tests/e2e/cef-ipc.test.ts` stress 섹션에서 E2E 검증.

## 배포 / 설치

### Suji CLI 배포

| 채널 | 명령어 | 상태 |
|------|--------|------|
| GitHub Releases | 직접 다운로드 | ✅ `release.yml` (dry_run 검증 + v* 태그 릴리스) |
| Homebrew | `brew install ohah/suji/suji` | ✅ `release.yml` homebrew job + Formula 생성/검증. 외부 tap push는 `HOMEBREW_TAP_TOKEN`/`HOMEBREW_TAP_REPO` 대기 |
| npm/npx | `npx @suji/cli init my-app` / `npx create-suji my-app` | ✅ `packages/suji-cli`(스캐폴더 + `defineConfig`/JS·TS config loader + `suji` JS launcher, init.zig 동형, `suji.config.ts`/`suji.json`, 12300 기본 포트, backend none/zig/rust/go/node/lua/multi, frontend Vite/Rsbuild/Next, pm npm/pnpm/bun/VoidZero `vp`) — npm publish 토큰 대기 |
| curl 스크립트 | `curl -fsSL https://github.com/ohah/suji/releases/latest/download/install.sh \| sh` | ✅ `scripts/install.sh` — 최신/특정 버전 릴리스 asset 다운로드 + `.sha256` 검증 + `~/.suji/bin` 설치. release asset 포함, 유닛/E2E 계약 고정 |

### SDK 배포

워크플로 구현 완료(`.github/workflows/sdk-publish.yml`) — `sdk-v*` 태그
또는 `workflow_dispatch`. 기본 dry_run=검증만, 토큰 시크릿 보유 시 발행.
상세: [docs/RELEASING.md](./docs/RELEASING.md#sdk-배포-sdk-publishyml).

| SDK | 채널 | 패키지명 | 상태 |
|-----|------|----------|------|
| 프론트엔드 JS | npm | `@suji/api` | 워크플로 ✅ (발행 토큰 대기) |
| Rust SDK | crates.io | `suji` | 워크플로 ✅ (발행 토큰 대기) |
| Go SDK | go module | `github.com/ohah/suji-go` | 워크플로 ✅ (VCS 태그 소비) |
| Node.js SDK | npm | `@suji/node` (require) | 워크플로 ✅ (발행 토큰 대기) |

### 배포 우선순위
1. GitHub Releases — CI에서 플랫폼별 바이너리 빌드 + 자동 릴리즈
2. Homebrew tap — macOS 사용자 1순위
3. npx — 크로스 플랫폼, 프론트엔드 개발자 친화적
4. curl 스크립트 — 범용 설치
```
