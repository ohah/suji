# Suji

Zig 코어 기반 올인원 데스크톱 앱 프레임워크.
Electron 스타일 API (handle/invoke/on/send).

## 문서

- [구현 계획서](./docs/PLAN.md) — 아키텍처, 구현 단계, 기술 결정 사항
- [cef.zig 도메인 분리 리팩터](./docs/CEF_REFACTOR.md) — native API를 `cef_<domain>.zig`로 분리하는 진행 중 리팩터(절차/현황/주의)

## 빌드 & 실행

```bash
zig build          # 빌드
zig build -Dlua    # + vendored Lua 5.4 backend (vendor/lua + cjson, 시스템 의존 0)
zig build test     # 단위 테스트 (790개; vendored Lua 인라인 runtime test 상시 포함)
zig build run      # CLI 도움말

# 공식 플러그인 테스트 (dylib 선빌드 필요 — cd plugins/<p>/zig && zig build)
zig build test-state    # state 플러그인 (KV 스토어)
zig build test-sqlite   # sqlite 플러그인 (벤더 SQLite 3.51, sql:open/execute/query/close)
zig build test-log      # log 플러그인 (rotating file logger, level filter, JSON Lines)
zig build test-store    # store 플러그인 (file-backed config store, named instances, atomic persist; +values/entries)
zig build test-http     # http 플러그인 (renderer-safe fetch with URL allowlist, deny-by-default)
zig build test-os-autostart # os-info + autostart 플러그인 (시스템 정보 / 로그인 자동실행)
zig build test-notification-rich # notification-rich 플러그인 (WinRT/UNUserNotificationCenter/Freedesktop actions)
zig build test-window-state # window-state 플러그인 (창 bounds/maximized 저장·복원; CEF-free 표면 — file/validate/graceful no-window)
zig build test-positioner # positioner 플러그인 (창을 화면/트레이/커서 위치로 배치; CEF-free 표면 — graceful no-window/missing-position)
zig build test-upload   # upload 플러그인 (multipart 파일 업로드 / 다운로드→디스크; network-free 표면 — URL/PATH allowlist deny-by-default, SSRF, traversal)

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
cd examples/lua-backend && suji dev     # Lua 단독 (vendored Lua 5.4 + cjson; suji 를 -Dlua 로 빌드)
cd examples/python-backend && suji dev  # Python 단독 (embedded CPython 3.13; bash scripts/stage-python.sh 로 staging)
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
bash tests/e2e/run-before-quit.sh       # app:before-quit behavioral (quit → 백엔드 핸들러 마커 파일, 종료 전 발화 검증)
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
bash tests/e2e/run-plugin-wrappers.sh   # 공식 플러그인 (state/sqlite/log/store/http/notification-rich/window-state/positioner/upload) × {JS, Node} wrapper wire-contract (mock bridge)
bash tests/e2e/run-plugin-state-integration.sh # state plugin DLL 라운드트립(__suji__ → DLL → 응답)
bash tests/e2e/run-plugin-window-state.sh # window-state plugin 실 CEF 창 라운드트립(save 가 라이브 bounds 읽기 → file → get/restore/clear)
bash tests/e2e/run-plugin-positioner.sh # positioner plugin 실 CEF 창 지오메트리(move 좌표 단조성 top-left<bottom-right, center 사이, at-cursor)
bash tests/e2e/run-plugin-upload.sh     # upload plugin 실 Bun HTTP 서버 + 디스크(multipart 업로드 바이트 일치 / 다운로드→파일 내용 일치 / allowlist deny / progress 이벤트)
bash tests/e2e/run-lua-e2e.sh           # Lua 백엔드 (vendored Lua 5.4 + cjson) invoke 왕복/cjson roundtrip/50 concurrent (-Dlua 자동 빌드)
bash tests/e2e/run-python-e2e.sh        # Python 백엔드 (embedded CPython 3.13 + GIL) invoke 왕복/json roundtrip/50 concurrent/send·on (scripts/stage-python.sh 자동 staging)

# 모바일 정적 백엔드 메커니즘 (CEF/iOS 무관, 호스트 검증)
bash tests/mobile-backends/run.sh       # 코어+Rust(staticlib)+Go(c-archive)+Zig
                                        # +SQLite(build-lib) 정적 링크 →
                                        # register_handler 왕복 68 케이스.
                                        # zig:http=std.http→localhost 평문+HTTPS,
                                        # sql:*=실 sqlite3 CRUD(모바일 경로,
                                        # 데스크탑 plugins/sqlite 바이트 동형).
                                        # python=backend_android.c 호스트 빌드+실
                                        # 데스크탑 libpython 으로 ping/echo 왕복
                                        # (libpython staged 시 — CI 가 stage-python.sh.
                                        # 모바일 python 의 유일한 CI 자동 기능 커버리지;
                                        # 미staging 이면 graceful skip)
bash tests/mobile-backends/ios-sim-smoke.sh  # iOS 시뮬레이터 변형별 빌드+기동
                                        # 스모크(링크/TLS/심볼충돌 회귀; xcodegen+
                                        # 부팅 시뮬 필요; 기본 zig multi)
bash tests/mobile-backends/ios-e2e.sh   # iOS 시뮬 *기능* e2e — e2e.html 이 실
                                        # UIPasteboard clipboard 8케이스 자가검증
                                        # → 데이터컨테이너 파일 회수·assert
bash scripts/stage-python-ios.sh        # iOS embedded CPython staging (BeeWare
                                        # Python-Apple-support 3.13 → ~/.suji/python-ios)
bash tests/mobile-backends/ios-e2e.sh python  # iOS 시뮬 embedded CPython e2e —
                                        # ping/echo(json)/unicode/nested/20x stress
                                        # (실 libpython+번들 stdlib, 5케이스 자가검증)
bash tests/mobile-backends/android-e2e.sh # Android 에뮬 *기능* e2e — 실
                                        # ClipboardManager 8케이스 → logcat 회수
                                        # (ANDROID SDK+에뮬+JDK17~21 필요)
bash scripts/stage-python-android.sh    # Android embedded CPython staging (NDK
                                        # 소스 크로스빌드 → ~/.suji/python-android, ~20-40분)
bash tests/mobile-backends/android-e2e.sh python  # Android 에뮬 embedded CPython e2e —
                                        # ping/echo(json)/unicode/nested/20x (실 libpython
                                        # +번들 stdlib, 5케이스 자가검증)
bash tests/zig-consumer/run.sh          # 외부 프로젝트가 b.dependency("suji")
                                        # .module("suji") 로 소비 가능 회귀 가드
```

E2E 스크립트는 suji dev를 띄우고 CEF DevTools(`localhost:9222`)에 puppeteer로 붙어
검증. 기존 run-*.sh 스크립트가 자동으로 프로세스 정리까지 한다.

## CLI

```bash
suji init <name> --backend=none|zig|rust|go|node|lua|python|multi \
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
//   / writeBookmark(title, url) / writeFindText(text)  — macOS NSPasteboard public.url /
//     Find pasteboard (macOS only, Win/Linux false)
//   / write({text?, html?, rtf?})  — 여러 포맷 atomic (macOS) / best-effort 단일 (Win/Linux)
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
//   / shouldUseHighContrastColors() / prefersReducedTransparency()  — macOS NSWorkspace
//     accessibilityDisplayShouldIncreaseContrast / ShouldReduceTransparency,
//     Windows SPI_GETHIGHCONTRAST / EnableTransparency==0 (Linux false)
// suji.nativeImage.getSize("/path/to/img.png")  — {width, height} (NSImage)
//   / toPng(path) / toJpeg(path, quality)        — base64 인코딩 (raw ~8KB)
//   / isEmpty(path) / isTemplateImage(path)       — 빈 이미지/template 여부 (macOS NSImage)
//   / fileIcon(path)                              — 파일 시스템 아이콘 PNG base64
//     (Electron app.getFileIcon, macOS NSWorkspace.iconForFile 32x32, raw ~8KB)
// suji.screen.getCursorScreenPoint()      — 플랫폼 native cursor point
// suji.dialog.messageBoxSimple("info", "안녕", &.{ "OK", "Cancel" })   — 응답 raw JSON
// suji.dialog.showOpenDialog("\"properties\":[\"openFile\"]")          — raw fields
// suji.dialog.showErrorBox("Title", "content")
// suji.tray.createWithIcon("App", "tooltip", "/tmp/tray.png")
//   / setMenuRaw(id, "...items with submenu/checkbox...") / destroy(id)
//   / setToolTip(id, tip) (setTooltip Electron 별칭) / getBounds(id) → {x,y,width,height}
//     (getBounds=macOS NSStatusItem.button window frame / Windows Shell_NotifyIconGetRect /
//      Linux gtk_status_icon_get_geometry(X11; Wayland 0 rect))
//                                                                       (macOS NSStatusItem / Linux GTK StatusIcon / Windows Shell_NotifyIconW)
// suji.notification.show("Title", "Body", false) / requestPermission() / close(id)
//   / removeAll() / removeGroup(groupId)  — groupId: macOS threadIdentifier(스택 그룹화),
//     Windows group 추적 후 removeGroup 이 그룹 전체 tray icon 닫음, Linux freedesktop
//     replaces_id 갱신(근사 — 정직 경계)
//   NotificationOptions {id?, groupId?} — caller-id + 그룹화. Notification 클래스(JS/Node):
//   new Notification(opts); await n.show(); n.id (readonly) / n.close()
//                                       (macOS UNUserNotificationCenter, .app 번들 필수 / Linux D-Bus / Windows Shell_NotifyIcon balloon)
// suji.menu.setApplicationMenuRaw("\"items\":[...]") / resetApplicationMenu()
//   / popup(items, {x?,y?})  — 임의 위치 컨텍스트 메뉴(macOS NSMenu
//   popUpMenuPositioningItem, Linux GTK popup; x/y 미지정=커서/포인터)
//                                       (macOS NSMenu / Linux GTK, menu:click 이벤트)
//   MenuItem 필드(전 SDK): id/visible/enabled/accelerator/role/icon. icon=이미지
//   경로(macOS NSImage setImage:, fs sandbox 게이트). popup 은 menu:will-show/
//   menu:will-close 이벤트 발신(suji.on). Menu.getApplicationMenu/getMenuItemById/
//   insert 는 스냅샷 기반(fire-and-forget — 라이브 객체 아님).
// suji.globalShortcut.register("Cmd+Shift+K", "openSettings") / unregister(accel)
//   / unregisterAll() / isRegistered(accel)   (macOS Carbon Hot Key / Linux X11 XGrabKey / Windows RegisterHotKey, globalShortcut:trigger 이벤트)
//   / registerAll(["Cmd+1","Cmd+2"], click)  — 일괄 등록(모두 성공 시 true)
//   / setSuspended(true) / isSuspended()      — 일시 정지(등록 유지, trigger 발신만 차단; 전 플랫폼 emit 게이트)
//   미디어키: register("MediaPlayPause"|"MediaNextTrack"|"MediaPreviousTrack"|
//   "MediaStop", click) — Electron 토큰 패리티. Carbon 불가분 NSEvent
//   systemDefined 모니터 분기(신규 API 0, 동일 register IPC). ⚠️ 글로벌
//   수신은 Accessibility(TCC) 필요(헤드리스 미발화 — globalShortcut 동급 경계)
// suji.screen.getAllDisplays()                — Display 배열 raw JSON (macOS NSScreen / Linux X11 screen)
//   display 변경 이벤트(macOS NSApplicationDidChangeScreenParameters / Windows WM_DISPLAYCHANGE /
//   Linux X11 RandR RRScreenChangeNotify 스레드 — 모두 count-diff):
//   suji.on("screen:display-added"|"screen:display-removed"|"screen:display-metrics-changed", cb)
//   → 페이로드 후 getAllDisplays 로 상세 조회. 정직 경계: 동시 add+remove(수 동일)는 metrics,
//   Linux 는 libXrandr dlopen(미설치/Wayland 는 no-op)
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
// suji.powerSaveBlocker.start("prevent_display_sleep") / stop(id) / isStarted(id)
//   (macOS IOPMAssertion, Linux XScreenSaverSuspend, Windows Power Request API;
//    isStarted=전 플랫폼 power_save_started_ids 추적 테이블)
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
//   Windows WM_POWERBROADCAST/WTS), 채널 발신:
//   `power:suspend` / `power:resume` / `power:lock-screen` / `power:unlock-screen`
//   + `power:shutdown`(macOS NSWorkspaceWillPowerOff / Linux login1 PrepareForShutdown) /
//   `power:on-battery` / `power:on-ac`(macOS IOPS run-loop / Windows WM_POWERBROADCAST
//   PBT_APMPOWERSTATUSCHANGE+GetSystemPowerStatus) → suji.on("power:shutdown", cb)
//   → 다른 SDK도 동일 채널명으로 listen. 정직 경계: Windows shutdown 은 message-only
//   window 가 WM_ENDSESSION broadcast 미수신이라 미지원, Linux 배터리는 UPower dict 파싱 후속
// suji.process.run(allocator, suji.io(), &.{ "echo", "hi" })  — std.process.run wrap (백엔드 only)
//   → RunResult { code, stdout, stderr }, caller가 stdout/stderr free
// suji.http.fetch(allocator, suji.io(), "https://...", null)   — std.http.Client.fetch wrap
//   → FetchResult { status, body }, payload null이면 GET / non-null이면 POST
// suji.webRequest.setBlockedUrls(&.{ "https://*.ad/*" })   — URL glob blocklist
//   → 매칭 요청 cancel + `webRequest:before-request` / `webRequest:completed` 이벤트
// suji.quit()                  — 앱 종료 요청 (Electron app.quit())
//   → quit 직전 `app:before-quit` 이벤트 1회 발신(모든 quit 경로: Cmd+Q/suji.quit/
//     all-closed/IPC 가 cef.quit chokepoint 경유). suji.on("app:before-quit", cb) 로 정리/저장.
//     ⚠️ preventDefault(종료 취소)는 IPC 비동기상 미지원(window:close 렌더러 경계 동일, 정직 경계)
// suji.exit()                  — 앱 강제 종료 (Electron app.exit(), code 무시)
// suji.relaunch()              — quit 후 현재 앱 재시작 등록 (Electron app.relaunch).
//   이후 quit/exit 시 cef 메시지 루프 종료 후 현재 argv 로 새 인스턴스 spawn(detached).
//   ⚠️ args/execPath 옵션 미지원(현재 argv 그대로), 실 재시작은 수동 검증(e2e 시
//   고아 프로세스 위험으로 빌드+wire 검증 — 정직 경계)
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
// suji::request_single_instance_lock() / has_single_instance_lock() / release_single_instance_lock()
//   — 단일 인스턴스 락 (raw Option<String>; {"locked":bool}/{"success":bool}). second-instance
//     argv 는 suji::on("app:second-instance", ...) 로 수신
// suji::session::{clear_cookies(), flush_store()}  — CEF cookie_manager fire-and-forget
// suji::session::set_proxy(mode, proxy_rules, proxy_bypass_rules, pac_script)  — Electron session.setProxy
// suji::session::set_permission_request_handler(|req: PermissionRequest| -> bool { req.permissions ... })
//   / clear_permission_request_handler()  — Electron session.setPermissionRequestHandler
//   (session:permission-request 구독 → grant/deny. camera/mic 별도 경로 미포함)
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
// session.SetProxy(mode, proxyRules, proxyBypassRules, pacScript)  — Electron session.setProxy
// session.SetPermissionRequestHandler(func(req session.PermissionRequest) bool { ... })  — nil=해제
//   Electron session.setPermissionRequestHandler (session:permission-request 구독 → grant/deny)
// import "github.com/ohah/suji-go/attention"
// attention.RequestUser(true) / attention.CancelUserRequest(id)
// import "github.com/ohah/suji-go/webrequest"
// webrequest.SetBlockedUrls([]string{"https://*.ad/*"})
// import "github.com/ohah/suji-go/app"
// app.RequestSingleInstanceLock() / HasSingleInstanceLock() / ReleaseSingleInstanceLock()
//   — 단일 인스턴스 락 (raw {"locked":bool}/{"success":bool}). second-instance argv 는
//     suji.On("app:second-instance", ...) 로 수신
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
// await app.relaunch()                                       // Electron app.relaunch (quit 후 재시작 등록)
// await session.clearCookies() / session.flushStore()        // CEF cookie_manager fire-and-forget
// await session.setDownloadPath("/Users/me/Downloads")        // Electron session.setDownloadPath
//   — 설정 시 다운로드는 OS 대화상자 없이 <path>/<filename> 으로 저장(빈 문자열=대화상자 복귀).
//     모든 다운로드는 suji.on("session:will-download", {id,url,filename,mimeType,totalBytes}) 발신.
//     전 5 SDK(JS/Node/Rust/Go/Zig). CEF cef_download_handler_t.on_before_download.
// await session.setProxy({ mode:"fixed_servers", proxyRules:"host:port", proxyBypassRules, pacScript })
//   — Electron session.setProxy. Chromium "proxy" pref(전역 request context). mode:"direct"=해제.
//     프론트=UI 스레드 직접, 백엔드 SDK=UI 스레드로 post(워커 스레드)
// await session.setPermissionRequestHandler((details) => boolean | Promise<boolean>)
//   — Electron session.setPermissionRequestHandler. 렌더러 권한 요청(geolocation/
//     notifications/clipboard/midi/idle/window-management 등)을 핸들러가 grant(true)/
//     deny(false). null 전달=해제. throw/비-bool=deny(안전 기본). 1 핸들러만 active.
//     → suji.on("session:permission-request", {permissionId,origin,permissions[]}) +
//       session_permission_response 로 응답(CEF cef_permission_handler_t deferred-callback).
//     ⚠️ camera/mic(getUserMedia)는 별도 CEF media-access 경로 → 미포함(후속).

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
// await windows.stop(id)  — 진행 중 로드/네비게이션 중단 (Electron webContents.stop, cef_browser_t.stop_load)
// const key = await windows.insertCSS(id, "body{color:red}")  — author-origin <style> 주입
//   (Electron webContents.insertCSS). CSS 는 base64→atob+TextDecoder 복원이라 따옴표/백슬래시/
//   유니코드 안전. 반환 key 로 제거. ⚠️ options.cssOrigin:'user'는 미지원(style=author, 정직 경계)
// await windows.removeInsertedCSS(id, key)  — insertCSS 가 반환한 key 의 주입 CSS 제거
//   (전 5 SDK + BrowserWindow/WebContentsView 클래스. viewId 도 동작 — id 풀 공유)
// await windows.setWindowOpenHandler("deny"|"allow")  — Electron webContents.setWindowOpenHandler.
//   네이티브 popup(window.open/target=_blank) 정책(전역). deny=차단. popup 마다
//   suji.on("web-contents:new-window", ({url,frameName,disposition})) 발신 → app 이 관리 창으로 라우팅.
//   ⚠️ per-popup 동적 콜백(요청마다 action 계산)은 CEF 제약상 불가(on_before_popup 동기) — 전역 정책+이벤트
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
// await windows.setSize(id, w, h, animate?) / setPosition(id, x, y, animate?)  — Electron
//   BrowserWindow.setSize/setPosition. getBounds→setBounds 파생(위치/크기 유지). animate 무시(CEF Views 비애니메이션)
// await windows.setMinimumSize(id, w, h) / getMinimumSize(id) → [w,h]
//   / setMaximumSize(id, w, h) / getMaximumSize(id) → [w,h]  — Electron BrowserWindow.setMinimumSize 등.
//   w/h=0=제한 없음. 네이티브: delegate constraints(CEF Views get_minimum_size 콜백) + macOS
//   NSWindow setContentMinSize/MaxSize + invalidate_layout. getter=추적값(결정적). 전 6개 언어 + BrowserWindow 클래스
// await windows.setResizable(id, bool) / isResizable(id) / setMinimizable(id, bool) / isMinimizable(id)
//   / setMaximizable(id, bool) / isMaximizable(id) / setClosable(id, bool) / isClosable(id)
//   — Electron BrowserWindow.setResizable 등 capability 토글. 네이티브: delegate constraints
//   (CEF Views can_resize/can_minimize/can_maximize/can_close 콜백 = 단일 출처) + macOS NSWindow
//   styleMask 비트(Resizable/Closable/Miniaturizable)/zoom 버튼(maximizable) + invalidate_layout.
//   getter=추적값(결정적). 전 6개 언어 + BrowserWindow 클래스. ⚠️ 실제 enforcement(사용자
//   drag/zoom/close 차단)은 macOS 확인, Win/Linux 는 CEF Views can_* 의존(real-runner 천장)
// await windows.setMovable(id, bool) / isMovable(id) / setFocusable(id, bool) / isFocusable(id)
//   / setEnabled(id, bool) / isEnabled(id) / setFullScreenable(id, bool) / isFullScreenable(id)
//   / setKiosk(id, bool) / isKiosk(id)  — Electron BrowserWindow 모드 토글. tracked constraints
//   단일 출처(getter 결정적) + best-effort 네이티브: movable=macOS NSWindow.movable, enabled=
//   Win32 EnableWindow(정확)/macOS ignoresMouseEvents(마우스만), fullscreenable=macOS
//   collectionBehavior, kiosk=CEF Views fullscreen(presentation-options 미포함). 전 6개 언어 +
//   BrowserWindow 클래스. ⚠️ 정직 경계: focusable=tracked-only, Win/Linux 다수 tracked, 실
//   enforcement 은 real-runner 천장
// await windows.setContentProtection(id, bool) / isContentProtected(id)  — 화면 캡처/녹화 보호
//   (macOS NSWindowSharingNone / Win SetWindowDisplayAffinity WDA_EXCLUDEFROMCAPTURE; Linux tracked).
//   getter=추적값. ⚠️ Win10 2004+ 필요(구버전은 무시되어 tracked 와 괴리 가능)
// await windows.setSkipTaskbar(id, bool)  — 작업표시줄에서 창 숨김 (Win WS_EX_TOOLWINDOW /
//   Linux skip-taskbar; macOS no-op — 개념 부재). Electron 처럼 getter 없음(set only)
// await windows.destroy(id)  — Electron BrowserWindow.destroy() 강제 파괴. close 와 달리
//   window:close(취소 hook) 스킵, window:closed 만 발화(listener 가 막을 수 없음). 전 6개 언어
// const { success } = await windows.printToPDF(id, "/tmp/x.pdf")  (Phase 4-D)
// await windows.createView({hostId, url, bounds}) → {viewId}              (Phase 17-B WebContentsView)
// await windows.addChildView(host, view, index?) / setTopView / removeChildView
// await windows.setViewBounds(viewId, {...}) / setViewVisible(viewId, bool) / getChildViews(host)
//   / getViewBounds(viewId) → {ok,x,y,width,height} (추적값) / setViewBackgroundColor(viewId, "#RRGGBB[AA]")
//     (cef_view_t.set_background_color). class WebContentsView (BrowserWindow 동형 OO facade):
//     WebContentsView.create({hostId,url,bounds}) + setBounds/getBounds/setVisible/
//     setBackgroundColor/destroy/loadURL/executeJavaScript/openDevTools (viewId=windowId 풀)
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
// await globalShortcut.registerAll([accel...], click) / setSuspended(bool) / isSuspended()
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
// await powerSaveBlocker.stop(id) / await powerSaveBlocker.isStarted(id)  (macOS/Linux/Windows)
// await safeStorage.setItem(svc, acc, "v") / getItem(svc, acc) / deleteItem(svc, acc)
//                                                                         (macOS Keychain, Linux libsecret, Windows Credential Manager)
// await app.dock.setBadge("99") / app.dock.getBadge()                     (macOS NSDockTile)
// await app.setBadgeCount(5) / app.getBadgeCount()                        (Electron app badge count)
//   macOS dock label / Linux libunity / Windows taskbar overlay best-effort
// await app.getPath("userData" | "home" | "documents" | ...)              — Electron app.getPath
// await app.getFileIcon("/path/to/file")  — 파일 시스템 아이콘 PNG base64
//   (Electron app.getFileIcon, macOS NSWorkspace.iconForFile 32x32; Win/Linux 빈 문자열)
// await app.setAsDefaultProtocolClient("myapp") / isDefaultProtocolClient("myapp")
//   / removeAsDefaultProtocolClient("myapp")     — Electron 기본 URL scheme 핸들러 (전 5 SDK)
//   macOS Launch Services. scheme 등록 자체는 suji.json app.deepLinkSchemes(CFBundleURLTypes)가
//   담당 — 이 트리오는 기본-핸들러 강제/조회. remove=macOS LS 해제 API 부재로 false(Electron 동형).
//   ⚠️ 실 .app 번들에서만 동작(dev=번들 ID 부재 → false, 검증 천장)
// const reqId = await app.requestUserAttention(true)                      (macOS NSApp `requestUserAttention:`)
// await app.cancelUserAttentionRequest(reqId)
// const ok = await app.flashFrame(true)                                   — dock/창 주의 끌기 (macOS dock
//                                       bounce, false=중단; app-scoped 단일 dock, 멀티 윈도우는 마지막 우선)
// await app.showAboutPanel() / setAboutPanelOptions({applicationName,applicationVersion,version,copyright})
//                                       — macOS NSApp orderFrontStandardAboutPanel (Win/Linux no-op)
// await app.addRecentDocument(path) / app.clearRecentDocuments()          — macOS NSDocumentController (Win/Linux no-op)
// await app.isInApplicationsFolder()                                      — .app 이 /Applications 아래인지 (macOS only)
// const s = await app.getLoginItemSettings()                             → {openAtLogin,openAsHidden,wasOpenedAtLogin,...}
// await app.setLoginItemSettings({openAtLogin:true})                      — 로그인 자동 실행 (macOS plist /
//                                       Linux desktop; Win 후속. wasOpenedAtLogin=openAtLogin alias, 정직 경계)
// const bm = await app.createSecurityScopedBookmark(path)                 — App Sandbox 영속 파일 접근
// const acc = await app.startAccessingSecurityScopedResource(bm)          → {id,path,stale}
// await app.stopAccessingSecurityScopedResource(acc.id)                   (NSURL bookmark; 비-sandbox=일반)
// const ok = await app.requestSingleInstanceLock()                        — Electron 단일 인스턴스 락
//   primary 면 true, 다른 인스턴스가 이미 보유 중이면 false(보통 앱 quit). 멱등.
//   (macOS/Linux <userData> flock, Windows named mutex)
// await app.hasSingleInstanceLock() / app.releaseSingleInstanceLock()
//   → 두 번째 인스턴스는 자기 argv 를 primary 로 전달 →
//     suji.on('app:second-instance', ({argv}) => myWindow.focus())       (Electron second-instance;
//     argv 전달 IPC: macOS/Linux Unix 소켓, Windows named pipe)
// await webRequest.setBlockedUrls(["https://*.ad/*"])                     (CEF ResourceRequestHandler)
//   → suji.on('webRequest:completed', ({url, statusCode, statusText, requestStatus, receivedBytes, responseHeaders}) => ...)
//     responseHeaders={헤더명:값} 객체(Electron onHeadersReceived 패리티, cef_response_t.get_header_map iterate)
// await webRequest.onBeforeRequest({urls:["https://*.tracker/*"]}, (details, cb) => cb({cancel:true}))
//   → RV_CONTINUE_ASYNC + listener round-trip cancel/allow (e2e 13 pass)
// await webRequest.setRequestHeaders({urls:["https://api.x/*"]}, {Authorization:"Bearer …"})
//   — Electron onBeforeSendHeaders (declarative). URL glob 매칭 요청에 헤더를 동기 주입(덮어쓰기).
//     빈 urls=해제. echo-server e2e 로 wire 도달 실증. ⚠️ per-request JS 콜백(요청마다 동적
//     헤더 계산)은 CEF 제약상 불가(RV_CONTINUE_ASYNC 후 request 수정 무시) — 선언적 규칙만
```

## Suji 설정

설정은 **정적 `suji.json` 단일 출처**입니다. Zig 코어가 `suji.json`을 직접 파싱하므로 node 없이도 모든 백엔드 언어(zig/rust/go/node/lua)가 동일하게 읽습니다. `suji init`(네이티브·`@suji/cli` 동형)이 `suji.json`을 생성하고, 프로덕션 빌드는 이 파일을 `.app`/패키지 Resources 에 복사합니다. JSON Schema 제공: [`suji.schema.json`](./suji.schema.json) — IDE 자동완성 + 검증 지원.

> ⚠️ `suji.config.ts`/`defineConfig`/JS·TS config loader/빌드 훅/`dev.env`/플랫폼별 빌드는 **제거됨** — node 런타임이 있어야 평가 가능해 node 없는 go/rust/zig 프로젝트가 쓸 수 없었다. 서명·공증·dmg·sandbox 등 빌드 옵션은 CLI 플래그(`--sign`/`--identity`/`--notarize`/`--dmg`/`--sandbox`) 또는 env(`SUJI_SIGN`/`SUJI_NOTARIZE`/…)로 지정한다. 회귀: `tests/config_test.zig`(suji.json 파싱).

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
//   MenuItem 옵션: enabled, checked(checkbox), id(getMenuItemById 식별자 — UI 효과 없음),
//   visible(false=항목 숨김; macOS NSMenuItem.setHidden / GTK set_visible 실효, Win no-op),
//   accelerator("Cmd+Shift+K" — macOS NSMenuItem keyEquivalent 단일 문자 키; 특수키
//   best-effort, Win/Linux no-op),
//   role(copy/paste/quit 등 표준 동작 — 설정 시 click 무시, macOS NSMenuItem 네이티브
//   selector/first responder, quit=sujiQuit:; macOS only, Win/Linux no-op).
//   전 6개 언어(JS/Node optional, Rust enum 필드, Go omitempty, lua/python raw).
// await menu.resetApplicationMenu()
// await menu.getApplicationMenu() → MenuItem[]  — 마지막 set 한 메뉴 스냅샷(없으면 []).
//   ⚠️ 라이브 mutation 아님(suji 메뉴 fire-and-forget) — 변경은 setApplicationMenu 재설정.
// await menu.getMenuItemById(id) → MenuItem | null  — 스냅샷에서 id 재귀 탐색(submenu 포함).
//   네이티브: set 성공 시 items 배열 raw 저장(g_app_menu_buf), reset 시 클리어. getMenuItemById
//   는 SDK 가 getApplicationMenu 위에 구현(JS/Node/Rust/Go). 전 6개 언어.
// await menu.sendActionToFirstResponder("copy:")  — macOS first responder(포커스된 web view)에
//   표준 셀렉터 전달(NSApp.sendAction:to:from:). macOS only, Win/Linux no-op. 전 6개 언어.
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
// await app.requestSingleInstanceLock() / hasSingleInstanceLock() / releaseSingleInstanceLock()
//   — Electron 단일 인스턴스 락 (primary=true, 중복=false). second-instance argv 는
//     suji.on('app:second-instance', ({argv}) => ...) 로 수신 (전 6개 언어 동일 채널)
// await webRequest.setBlockedUrls(["https://*.ad/*"])
// await session.clearCookies() / session.flushStore()                    — CEF cookie_manager
// await session.setProxy({ mode, proxyRules, proxyBypassRules, pacScript }) — Electron session.setProxy
// await session.setPermissionRequestHandler((details) => boolean | Promise<boolean>)  — null=해제
//   Electron session.setPermissionRequestHandler (session:permission-request 구독 → grant/deny)

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
전체 68/68) + **`ios-e2e.sh`/`android-e2e.sh`**(실 디바이스 e2e: 실 UIPasteboard
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
**Android Node 는 예제 배선됨**(`examples/android/node` — 데스크탑과 *동일한*
`bridge.cc` 를 NDK clang++ 로 컴파일 + libnode.so 링크, main.js/main.ts 엔트리·
suji.handle 채널·request 형식 동형. bridge 에 `suji_node_channels()` 추가 —
등록 핸들러 목록을 JSON 으로 반환해 호스트가 `suji_core_register_handler` 로
일괄 배선, `suji_python_backend_channels` 동형). libnode.so 는 V8 가 cross
host-tool(mksnapshot)을 Linux 로 가정하므로 `build-libnode.yml`(ubuntu)이 NDK
크로스빌드 → release asset, `scripts/stage-node-android.sh` 가 다운로드(데스크탑
libnode staging 동형, end-user 는 prebuilt 만 — Docker/NDK 불요). ⚠️ 로컬 macOS
arm64 는 V8 host build 가정과 어긋나 framework/SDK/archive 패치가 다발 → libnode
크로스빌드는 CI(ubuntu), 에뮬 e2e(`android-e2e.sh node`)는 로컬 검증(정직 경계).

**embedded CPython 은 iOS 동작**(Node 와 결정적 대조 — 인터프리터라 JIT/코드생성
불요, CPython 3.13 PEP 730 공식 iOS 지원). `src/platform/python.zig` 데스크탑
런타임을 모바일 백엔드(`examples/ios/backends/python/src/backend.zig`,
`suji_python_backend_*`)로 포팅 — `@cImport(Python.h)` 를 zig 가 직접 컴파일,
outbound `suji.invoke/send/on` 은 정적 링크된 `suji_core_*` extern 으로 배선. iOS
libpython/stdlib 는 BeeWare **Python-Apple-support**(`Python.xcframework` + stdlib)를
`scripts/stage-python-ios.sh` 로 staging → `examples/ios/python` 변형이 framework 를
앱에 임베드 + stdlib 을 `<bundle>/python/lib/python3.13`(PYTHONHOME) 으로 번들 +
main.py 를 `<bundle>/main.py` 로. main.py 가 `suji.handle` 로 등록한 핸들러 이름을
`suji_python_backend_channels` 로 받아 호스트(Swift)가 각 채널을
`suji_core_register_handler` 로 등록(데스크탑 채널=핸들러 의미 보존 →
`suji.invoke("ping")` 동형). **iOS 시뮬레이터 실 e2e 검증**: `bash
tests/mobile-backends/ios-e2e.sh python`(ping/echo json·unicode·nested·20x, 5/5).

**Android 도 동작**(PEP 738 공식 Android 지원). iOS 와 차이: ① prebuilt CPython
3.13 Android 가 없어 **NDK 소스 크로스빌드**(`scripts/stage-python-android.sh` →
official `Android/android.py`, libpython3.13.so + stdlib). ② zig `@cImport` 의
translate-c 가 NDK bionic 헤더(배열 nullability/`__overloadable ioctl`)를 못 풀어
백엔드를 **C(`backend_android.c`)로 두고 NDK clang 으로 컴파일**(real clang 은 bionic
무사 — iOS 는 zig backend.zig 유지). ③ PYTHONHOME 이 실 FS 경로라 stdlib(zip)+main.py
를 앱 에셋에서 `filesDir` 로 추출 후 `nativeRegisterPythonBackend(filesDir)`(공유
MainActivity 게이트 — python 에셋 없는 변형 no-op) → C 가 start+channels→
`suji_core_register_handler`. libpython.so/core.so 는 jniLibs(CMake SHARED IMPORTED).
**에뮬레이터 실 e2e 검증**: `bash tests/mobile-backends/android-e2e.sh python`(arm64-v8a,
ping/echo json·unicode·nested·20x, 5/5).

정직 경계: 검증 천장은 시뮬레이터/에뮬레이터(실기기 미검증, clipboard 모바일 e2e
와 동일 바). gradle apk 빌드는 AGP 호환 JDK(17~21) 필요. lib-dynload(.so) 는
filesDir dlopen 이 최신 Android W^X 에서 막힐 수 있으나 json 등은 pure-python
폴백이라 무영향.

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
- **`session.setSSLConfig` / `session.cookies` `'changed'` 이벤트 — CEF 본질적 제약으로
  지원 우선 보류**: Electron 은 Chromium network service 에 직접 접근하지만 suji 는 CEF
  (Chromium 의 부분집합만 노출) 위라, 두 기능이 의존하는 Chromium-deep 인터페이스가
  CEF 에 없다. (1) **setSSLConfig**: Electron 은 `network::mojom::SSLConfig` 로 런타임
  TLS 버전/cipher 제어 — CEF 엔 런타임 SSL 설정 API 부재(시작-시 `--ssl-version-min`
  플래그 정도만). (2) **cookies 'changed'**: Electron 은 `CookieManager.AddCookieChange
  Listener`(변경 옵저버) 래핑 — CEF `cef_cookie_manager_t` 는 set/delete/visit/flush 만,
  변경 옵저버 부재(폴링 흉내만 가능). 깔끔한 런타임 동등 불가라 **보류**(CEF 가 해당
  인터페이스를 노출하면 재개). 같은 패턴: cross-origin `protocol.handle` 보류,
  isolated-world contextBridge 부재. 상세: docs/electron-parity-audit.md `[보류]` 항목.

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

### Lua 임베드 런타임 (vendored Lua 5.4 + cjson)

`zig build -Dlua`에서 **vendored PUC Lua 5.4** 기반 Lua backend가 활성화된다.
`vendor/lua`(onelua.c amalgamation, `-DMAKE_LIB`)와 `vendor/cjson`(lua-cjson
2.1.0)을 zig 가 직접 정적 컴파일하므로 **시스템 LuaJIT/Lua 의존이 0**이고
macOS/Linux/Windows 동일 빌드(sqlite vendoring 패턴 동형, `build.zig`
`buildLuaLibrary`). 기본 빌드는 컴파일 비용/바이너리 크기를 위해 opt-in
(`lua_enabled=false`)이며, `lang:"lua"` backend는 실행 시 "rebuild with -Dlua"
메시지로 graceful skip.

Lua ABI는 raw JSON string in/out. `require("cjson")`이 번들돼 수동 escape 없이
JSON 파싱/직렬화. **다른 백엔드와 동등한 1급 시민** — `suji.handle`(인바운드) 외에
`suji.invoke`(outbound cross-call) / `suji.send`(이벤트 발신) / `suji.on`(이벤트
수신)을 노출(node 패턴 복제):

```lua
local cjson = require("cjson")
suji.handle("ping", function(request_json)
  return cjson.encode({ msg = "pong" })
end)
-- outbound: 다른 백엔드 동기 호출(응답 JSON 문자열 반환)
suji.handle("call-zig", function()
  local resp = suji.invoke("zig", cjson.encode({ cmd = "add", a = 2, b = 3 }))
  return cjson.encode({ zig_said = cjson.decode(resp) })
end)
suji.send("my-event", cjson.encode({ x = 1 }))     -- 이벤트 발신
suji.on("ping-all", function(data) ... end)         -- 이벤트 수신(콜백 = registry ref)
```

outbound 코어 연결은 `startLua`가 `LuaRuntime.setCore(invoke/free/emit/on/off)`로
주입(node `setCore`와 동일 — `rt.start()` 전). cross-call 체인(lua→zig→lua)이나
invoke 중 send→on 콜백은 **같은 스레드 재진입**이라 `threadlocal lua_call_depth`로
mutex 재획득을 건너뛴다(node `g_in_sync_invoke` 동형 — Lua는 V8 Locker 없어 단순).
⚠️ **임베드 폴백 디스패치**(`main.zig cefInvokeHandler`)는 name 으로 구분: Lua 는
name 정확 매칭 시만, Node 는 lua 가 아닌 미해결 채널의 catch-all. 가드 없이 무조건
폴백하면 한 임베드 런타임이 다른 런타임의 target 호출을 가로챈다.

구현 범위: `src/platform/lua.zig`(LuaJIT 5.1→PUC 5.4 전환 — 매크로가 된
`luaL_loadfile`/`lua_pcall`은 함수형 `luaL_loadfilex`/`lua_pcallk`로, 반환값이
생긴 `lua_rawgeti`/`lua_pushlstring`은 discard; `luaL_requiref`로 cjson 등록),
`main.zig` load/route/teardown, schema `lang:"lua"`, `examples/lua-backend`(cjson
handler) + `examples/multi-backend`(lua + zig↔lua cross-call/event). **백로그**:
여러 Lua runtime 동시 map(Node 임베드도 단일 전역이라 불일관 + use-case 없음),
LuaRocks 통합, native API(`suji.clipboard.*` 등 — invoke 로 플러그인은 이미 호출
가능, 나머지 OS API 바인딩은 방대해 후속).

검증:
- `zig build test` — vendored Lua 인라인 runtime test(실제 cjson 예제 ping/echo
  실행)를 시스템 의존 없이 상시 포함. CI matrix(macOS/Linux/Windows) `Build (Lua)`
  step + test 로 Windows 포함 vendored Lua 빌드/실행 가드.
- `bash tests/e2e/run-lua-e2e.sh` — 단독 lua-backend: frontend invoke ↔ Lua handler
  왕복 + cjson(nested/unicode/float) + 50 concurrent + **suji.send/on(이벤트 양방향)**
  (6 pass). CI 포함.
- multi-backend cross-call/event: `zig build -Dlua` 후 `bash tests/e2e/run-cef-ipc.sh`
  의 "lua backend" describe — zig↔lua 양방향 invoke + lua send→JS on + JS emit→lua on
  (45 pass, lua 5 케이스 포함). cef-ipc 는 stress flaky 로 CI 미포함(로컬 실증).
- 깊은 재귀 체인/스레드 재진입/메모리 누수 회귀도 `tests/e2e/cef-ipc.test.ts`
  stress 섹션에서 검증.

### Python 임베드 런타임 (embedded CPython 3.13 + GIL)

**vendored 가 아니라 staged dynamic lib** — CPython 은 거대해 정적 vendoring
대신 [python-build-standalone](https://github.com/astral-sh/python-build-standalone)(astral)
의 `install_only` portable CPython 을 `~/.suji/python/<ver>` 에 staging 하고
**weak-link + auto-detect**(libnode 패턴 동형). `bash scripts/stage-python.sh`
(멱등)로 staging → `build.zig` 가 libpython 존재를 comptime 감지(`python_available`)
→ python 백엔드 활성. `-Dpython` 플래그 불요. staging 부재 시 `lang:"python"`
backend 는 graceful skip(weak-link 라 비-python 앱 무영향).

**핵심 통찰**:
1. **GIL 이 lua 의 `mutex`+`lua_call_depth`+`ReentrantGuard` 를 단일 메커니즘으로
   대체** — `PyGILState_Ensure/Release` 가 멀티스레드 직렬화 + 같은 스레드
   재진입(cross-call/이벤트)을 모두 처리. python.zig 엔 수동 가드 없음.
2. **순수 C ABI** — Python 임베드 API 는 name-mangling 이 없어 node 와 달리
   bridge.cc/mingw/외부 g++ 불필요. `@cImport(Python.h)` 를 zig 가 직접 컴파일.
3. **zig C variadic 전달은 깨진다** — `PyArg_ParseTuple`/`PyObject_CallFunction`
   같은 variadic API 는 포인터가 어긋나 오작동/segfault. 반드시 non-variadic
   (`PyTuple_GetItem`/`PyUnicode_AsUTF8`/`PyObject_CallOneArg`)으로 대체
   (`src/platform/python.zig` `tupleStr`/`tupleObj` 주석).
4. **translate-c 매크로 우회**: CPython 3.13 `pyatomic.h` 가 zig `@cImport` 에서
   `__clang__` 미감지로 C11 stdatomic(`_Generic`) 분기를 타 번역 실패 →
   `@cDefine("_Py_USE_GCC_BUILTIN_ATOMICS", "1")` 로 GCC builtin 분기 강제.

ABI 는 raw JSON string in/out. 표준 `json` 모듈로 파싱/직렬화(cjson 대응 — 별도
의존성 0). **다른 백엔드와 동등한 1급 시민** — `suji.handle`(인바운드) 외에
`suji.invoke`(outbound cross-call) / `suji.send`(이벤트 발신) / `suji.on`(이벤트
수신) 노출(lua/node 패턴 복제):

```python
import suji, json
suji.handle("ping", lambda req: json.dumps({"msg": "pong"}))
# outbound: 다른 백엔드 동기 호출(응답 JSON 문자열 반환)
def call_zig(req):
    resp = suji.invoke("zig", json.dumps({"cmd": "add", "a": 2, "b": 3}))
    return json.dumps({"zig_said": json.loads(resp)})
suji.handle("call-zig", call_zig)
suji.send("my-event", json.dumps({"x": 1}))         # 이벤트 발신
suji.on("ping-all", lambda data: ...)                # 이벤트 수신
```

**packaging(end-user 머신에 Python 미설치라도 동작 — 실 `.app` 검증 완료)**:
`build.zig` `addInstallPythonRuntimeStep` 이 libpython + stdlib 를 `zig-out/bin` 옆에
staging. libpython install_name 이 `@rpath/libpython3.13.dylib` 이고 suji 바이너리
rpath 에 `@executable_path` 가 있어 exe 옆 복사본으로 해석된다. stdlib(json 등)은
런타임 **PYTHONHOME=`exeDir()/python`**(`packaged_paths.pythonHome`)으로 로드.
Linux/Windows 는 packaging 의 `copyDirContents` 가 bin 디렉토리를 통째 복사해 자동
동반(libpython+stdlib 둘 다 bin/). macOS 는 `bundle_macos.zig` 가 libpython(단일
dylib)을 `Contents/MacOS`(@executable_path)로, **stdlib 트리는 `Contents/Resources/
python`** 로 분리 복사한다 — stdlib 트리를 `Contents/MacOS` 안에 두면 메인 바이너리
codesign 이 nested subcomponent 로 보고 "bundle format unrecognized" 로 실패하기
때문(실측). 그래서 `pythonHome` 은 libpython 위치가 아니라 `exeDir()`(macOS=
Contents/Resources) 기준. dev 는 이 복사본을 쓰지 않고 staging
(`python_config.python_home`)을 직접 참조 → 큰 stdlib 복사는 `dest` 존재 시
skip(증분 빌드 비용 0).

구현 범위: `src/platform/python.zig`(lua.zig 복제 + Python C API),
`build.zig`(staging weak-link auto-detect + `addInstallPythonRuntimeStep`),
`backend_lifecycle`(startPython + dispatch + PYTHONHOME dual-mode),
`main.zig`(teardown + packaging 분기), `packaged_paths.pythonHome`,
schema/init/suji-cli `lang:"python"`, `examples/python-backend` +
`examples/multi-backend`(python + zig↔python cross-call/event).

검증:
- `zig build test` — staged 일 때 `src/platform/python.zig` 인라인 runtime test
  (실제 main.py ping/echo invoke + json roundtrip)를 포함. `tests/python_test.zig`
  가 build.zig/staging/CI/예제 소스 계약을 상시 가드(CEF/staging 불요).
- `bash tests/e2e/run-python-e2e.sh` — 단독 python-backend: frontend invoke ↔
  Python handler 왕복 + json(nested/unicode/float) + **50 concurrent(GIL
  직렬화)** + **suji.send/on(이벤트 양방향)** (6 pass). CI(ci.yml/e2e.yml) 포함.
- **packaged `.app` 실행(실측)** — `suji build` 로 `examples/python-backend` 를
  `.app` 패키징 → codesign 통과 + 서명 valid → **staging 디렉토리를 치운 채**(=
  Python 미설치 end-user 시뮬) 실행 → 번들 libpython(Contents/MacOS) + stdlib
  (Contents/Resources/python) 로 `[suji-python] started`(Py_Initialize + bundled
  json import + main.py 실행) 확인. macOS 한정 수동 검증.

**release / 배포(완료)**: released `suji` CLI 가 **batteries-included**(libnode 선례
동형) — `release.yml` 이 macOS/Linux 빌드 전 `scripts/stage-python.sh` 로 staging,
Package 가 libpython + `python/` stdlib 를 suji 옆에 평탄 동반, `install.sh` 가
curl-install 시 그 sibling 들을 함께 설치. CLI suji 는 sentinel 없이 exe 옆 `python/`
을 자립 해석(`packaged_paths.exeRelativePythonHome`) → Python 미설치 머신에서도 python
백엔드 동작(dev e2e 가 이 경로로 실증).

**핫 리로드(정직)**: node/lua/python 임베드 런타임은 **모두** in-process 핫 리로드
미지원 — `reloadBackendCommon` 이 `getDylibPath`(rust/go/zig 만) 에서 graceful bail,
파일 변경 시 dev 재시작 필요. python 은 node/lua 와 **동일 동작**(python 특이 결함
아님) + 추가로 `Py_Initialize/Finalize` 가 프로세스당 1회 안전이라 in-process 재초기화
자체가 불가(프로세스 재시작이 정답).

**타입 스텁**: `packages/suji-python`(PEP 561 stub-only `suji-stubs`) — 런타임 주입
빌트인 `suji` 모듈용 `.pyi`(handle/invoke/send/on). IDE/mypy/pyright 용, 런타임 코드
없음. PyPI 발행만 후속(토큰 대기).

**정직 경계(후속)**: ① **Windows packaging** — Windows 는 `python3.lib` import-lib
hard-link 라 `python313.dll`+`Lib`/`DLLs` 동반 staging(PBS Windows 레이아웃)이
필요해 build gate 에서 **python off 로 강제**(깨진 exe footgun 방지). `addInstall
PythonRuntimeStep` Windows pwsh 분기 + Windows CI 반복이 필요한 별도 작업. CI/release
의 python staging 도 macOS/Linux 한정. ② **iOS**: V8 처럼 CPython JIT 아닌
인터프리터라 가능성은 있으나 iOS 용 python-build-standalone + 코드서명/샌드박스 +
모바일 호스트(examples/ios) 배선이 필요 — 모바일 트랙 별도 작업, 미배선.

## 배포 / 설치

### Suji CLI 배포

| 채널 | 명령어 | 상태 |
|------|--------|------|
| GitHub Releases | 직접 다운로드 | ✅ `release.yml` (dry_run 검증 + v* 태그 릴리스) |
| Homebrew | `brew install ohah/suji/suji` | ✅ `release.yml` homebrew job + Formula 생성/검증. 외부 tap push는 `HOMEBREW_TAP_TOKEN`/`HOMEBREW_TAP_REPO` 대기 |
| npm/npx | `npx @suji/cli init my-app` / `npx create-suji my-app` | ✅ `packages/suji-cli`(스캐폴더 + `suji` JS launcher, init.zig 동형, 정적 `suji.json`, 12300 기본 포트, backend none/zig/rust/go/node/lua/python/multi, frontend Vite/Rsbuild/Next, pm npm/pnpm/bun/VoidZero `vp`) — npm publish 토큰 대기 |
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
| Python 타입 스텁 | PyPI | `suji-stubs` (PEP 561) | 워크플로 ✅ (발행 토큰 대기) |

### 배포 우선순위
1. GitHub Releases — CI에서 플랫폼별 바이너리 빌드 + 자동 릴리즈
2. Homebrew tap — macOS 사용자 1순위
3. npx — 크로스 플랫폼, 프론트엔드 개발자 친화적
4. curl 스크립트 — 범용 설치
```
