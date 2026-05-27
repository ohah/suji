# Suji 구현 계획서

## 프로젝트 개요

**Suji** — Zig 코어 기반의 올인원 데스크톱 앱 프레임워크

- 이름 유래: 한국어 "수지" (이어붙이다)
- 코어: Zig (C interop, 크로스컴파일, 작은 바이너리)
- 차별점: 백엔드 언어 자유 선택

**공식 지원**: Zig, Rust, Go, C/C++, Node.js
**비공식 (문서만)**: Swift, Nim, 기타 C ABI export 가능 언어

---

## 기존 프레임워크 비교

| | Electron | Tauri | Wails | **Suji** |
|---|---|---|---|---|
| 브라우저 | Chromium 번들 | OS WebView | OS WebView | **CEF (Chromium)** |
| 백엔드 | Node.js 전용 | Rust 전용 | Go 전용 | **아무 언어** |
| 번들 크기 | ~150MB | ~3MB | ~8MB | 1~50MB (선택) |
| 코어 언어 | C++ | Rust | Go | **Zig** |

---

## 아키텍처

```
┌──────────────────────────────────────────────┐
│              프론트엔드 (React/Vue/Svelte)     │
│              __suji__.invoke / emit / on       │
├──────────────────────────────────────────────┤
│              Suji 코어 (Zig)                   │
│  ┌────────┬─────────┬──────────┬───────────┐  │
│  │ Window │ WebView │ IPC      │ EventBus  │  │
│  │        │         │ Bridge   │ (pub/sub) │  │
│  └────┬───┴────┬────┴────┬─────┴─────┬─────┘  │
│       │        │         │           │         │
│  ┌────┴────────┴─────────┴───────────┴──────┐  │
│  │           BackendRegistry (dlopen)        │  │
│  │  ┌──────┐  ┌──────┐  ┌──────┐  ┌──────┐  │  │
│  │  │ Zig  │  │ Rust │  │  Go  │  │Node* │  │  │
│  │  │.dylib│  │.dylib│  │.dylib│  │      │  │  │
│  │  └──┬───┘  └──┬───┘  └──┬───┘  └──────┘  │  │
│  │     │         │         │                 │  │
│  │     └────┬────┘    ┌────┘                 │  │
│  │          │ SujiCore API (크로스 호출)       │  │
│  │          │ invoke / emit / on / off        │  │
│  └───────────────────────────────────────────┘  │
└──────────────────────────────────────────────┘

* Node.js: libnode 임베드 (Phase 5)
```

**SDK 구조**:
```
crates/suji-rs/       Rust SDK (#[suji::command], export_commands!)
crates/suji-rs-macros/ Rust proc macro
sdks/suji-go/          Go SDK (suji.Bind(&App{}))
src/core/app.zig       Zig SDK (suji.app().command(), exportApp())
```

---

## 구현 단계

### Phase 1: 기초 (OS WebView + 창)

**목표**: 빈 창에 WebView 띄우기

- [x] `build.zig` + `build.zig.zon` 프로젝트 초기화
- [x] webview.h C 라이브러리 연동 (webview-zig 패키지)
- [x] 기본 창 생성 + HTML 로딩
- [x] macOS 지원 (WKWebView)
- [x] Linux/Windows — webview.h가 지원 (CI에서 빌드 테스트 예정)

**결과물**: `zig build run` → 창에 HTML 페이지 표시

---

### Phase 2: IPC 브릿지

**목표**: JS ↔ Zig 양방향 통신. 멀티 백엔드를 고려한 설계.

**핵심 설계 원칙: 메시지 패싱 + 중앙 상태**
```
프론트엔드 (WebView)
    ↕ 메시지
Suji 코어 (Zig) ← 상태 소유자 (단일 진실의 원천)
    ↕ 메시지
백엔드(들)
```
- 상태를 직접 수정하는 건 Zig 코어만
- 백엔드는 요청/응답(메시지)만 주고받음
- Actor 모델: 경합 없음, 언어 무관, 나중에 멀티 백엔드 확장 시 구조 변경 없음

- [x] 메시지 프로토콜 정의 (JSON 기반, 바이너리는 로컬 HTTP 서버로 분리 예정)

  **와이어 포맷**:
  ```
  ┌──────────┬──────────┬──────────┬─────────────┐
  │ type(1B) │ id(16B)  │ len(4B)  │ payload     │
  │ 0=json   │ uuid     │ 크기     │ 실제 데이터  │
  │ 1=binary │          │          │             │
  └──────────┴──────────┴──────────┴─────────────┘
  ```

  **제어 메시지 (type=0, JSON)**: 함수 호출, 상태 변경, 이벤트
  ```json
  {
    "id": "uuid",
    "from": "frontend",
    "to": "backend:default",
    "method": "greet",
    "params": { "name": "yoon" }
  }
  ```

  **데이터 메시지 (type=1, 바이너리)**: 이미지, 파일, 버퍼 등
  ```
  type=1 | id | len | <raw bytes>
  ```

  **혼합 전송 (메타데이터 + 바이너리)**:
  ```
  1) type=0 | id | len | {"method":"upload","size":10485760,"dataId":"abc"}
  2) type=1 | id | len | <10MB raw bytes>
  ```
  제어 메시지에서 dataId로 후속 바이너리 메시지를 참조
- [x] WebView → 코어 호출 (`window.__suji__.invoke()`)
- [x] 코어 → WebView 호출 (evaluate JS)
- [x] 코어 → 백엔드 디스패치 (직접, 체인, 팬아웃, 코어 릴레이)
- [x] 비동기 응답 처리 (Promise 기반)
- [x] 이벤트 시스템 (EventBus: on/once/off/emit)
  - [x] Zig on/send → EventBus ↔ JS __dispatch__
  - [x] Rust on/send → SujiCore emit/on
  - [x] Go On/Send → bridge.c → EventBus (CGo 브릿지)
  - [x] JS on/emit/off → WebView ↔ EventBus
  - [x] EventBus ↔ WebView 연결 (webview_eval)
- [x] 플러그인 시스템
  - [x] suji.json `plugins` 필드 파싱 (문자열 배열)
  - [x] main.zig에서 플러그인 빌드 + dlopen + BackendRegistry 등록
  - [x] 채널 접두사 컨벤션 (`state:get`, `fs:read` 등)
  - [x] `suji-plugin.json` 스펙 (플러그인 메타데이터)
  - [~] 권한 시스템 — fs(default-deny) + shell/dialog allowlist(opt-in,
        비파괴) 완료. network(webRequest setter)는 sink 아니라 범위 제외,
        모바일은 OS 샌드박스 경계(후속 결정)
- [x] State 플러그인 (첫 번째 공식 플러그인)
  - [x] Zig 구현 — `plugins/state/zig/` (HashMap + Mutex + JSON 파일 영속성)
  - [x] 경합 테스트 (`tests/state_plugin_test.zig` — 10 threads + rapid fire 100)
  - [x] JS 래퍼 — `plugins/state/js/`
  - [x] Rust 래퍼 — `plugins/state/rust/`
  - [x] Go 래퍼 — `plugins/state/go/`
  - [x] EventBus 연동 (`state:set` 시 `state:{key}` 이벤트 발행)
  - [x] Node 래퍼 — `plugins/state/node/` (`@suji/plugin-state-node`,
        backend SDK 변형. js/Rust/Go 와이어 동형 — `globalThis.suji.invoke
        ("state",{cmd,...})` + `{from:"zig",result|error}` 언랩. dist+lock
        커밋. Node libnode 임베디드라 dylib 하니스 불가 → mock 브릿지로
        계약 검증(plugins/state/js 테스트 동형), bun 26 단위 테스트)
  - [x] SQLite 플러그인 — `plugins/sqlite` (두 번째 공식 플러그인, state 동형).
        벤더 SQLite 3.51.0 amalgamation(public domain, 결정론적 크로스플랫폼
        빌드) + `sql:open/execute/query/close`. positional `?` 파라미터
        바인딩(SQL injection-safe). dbId 레지스트리 + 글로벌 뮤텍스. Zig 코어
        + Rust/Go/JS/Node 래퍼(state parity, js/node dist+lock 커밋). `zig
        build test-sqlite` 10 테스트(round-trip/파라미터 주입안전/타입/격리/
        에러). Node 래퍼 — `plugins/sqlite/node/` (`@suji/plugin-sqlite-node`,
        state/node 동형: mock 브릿지 bun 16 단위 테스트).
  - [x] **모바일 SQLite 백엔드** — `examples/ios/backends/sqlite/`
        (데스크탑 plugins/sqlite 모바일 대응; 데스크탑=동적 dylib/BackendRegistry,
        모바일=정적 링크라 코어/SDK 독립 재구현, 고유 심볼 `suji_sqlite_backend_*`).
        벤더 sqlite3.c 데스크탑과 단일 출처. std.json 요청 파싱(escape 안전),
        SQLITE_STATIC(arena 가 handler 끝까지 생존). 응답이 데스크탑
        plugins/sqlite 와 **바이트 동형**(`{"from":"zig","result"/"error":..}`)
        → 동일 Rust/Go/JS 래퍼 무수정 동작(Tauri 동형). 검증: 호스트 하니스
        `tests/mobile-backends/run.sh` 62/62(실 sqlite3 CRUD 10 — open/
        create/insert(params,UTF-8)/query/injection-safe/close/use-after-close/
        상대경로거부, register_handler→bridge→handle_ipc, rust/go/zig 와 정적
        링크 공존=심볼 무충돌) + 크로스 컴파일 aarch64-ios/-simulator/
        -linux-android 빌드 성공(Xcode SDK / NDK sysroot). 경로는
        `:memory:`/절대만(상대는 호스트 책임).
  - [x] **iOS/Android 예제 앱 변형** — `examples/ios/sqlite/` +
        `examples/android/sqlite/` (zig 변형 동형, sql:open/execute/query/
        close 등록). iOS=`project.yml`/`Backends.swift`(`suji_sqlite_backend_*`
        @convention(c) + `sujiReg`)/`build-lib.sh`(공용 backends/sqlite
        build-lib.sh 재사용 — sysroot/cflags 단일 출처). Android=Gradle
        +`cpp/backends.c`(JNI `suji_reg_backend`)+CMake. `_shared/Suji-
        Bridging-Header.h` 에 extern 추가. web/index.html=실 SQLite todo
        데모, e2e.html=zig 와 lockstep(`__core__` 스위트, 변형 무관).
        검증: **iOS xcodebuild BUILD SUCCEEDED**(xcodegen→링크: Swift+
        브리징+정적 core/sqlite .a+web 번들) + Android backends.c
        aarch64-android NDK clang 컴파일 + build-lib.sh(core .so + sqlite
        .a 스테이징). ⚠️ 정직 경계: 실기기·시뮬/에뮬 *런타임* 미검증
        (iOS=빌드+링크까지, Android APK 어셈블은 JDK/SDK 필요=기존
        android-e2e.sh 와 동일 CI 게이트). 백엔드 동작 자체는 호스트
        하니스 62/62(실 sqlite3 CRUD)로 실증.
- [x] ~~바이너리 데이터 채널~~ — CEF `suji://` 커스텀 프로토콜로 대체 (fetch + 로컬 파일 접근 가능, 별도 HTTP 서버 불필요)

**결과물**:
```js
// 프론트엔드 (Electron 스타일 — 자동 라우팅)
const result = await suji.invoke("greet", { name: "yoon" });
const result2 = await suji.invoke("greet", { name: "yoon" }, { target: "zig" });
suji.on("data-updated", (data) => console.log(data));
suji.emit("button-clicked", { button: "save" });
```
```zig
// Zig 백엔드 (내장)
fn greet(req: suji.Request) suji.Response {
    const name = req.string("name") orelse "world";
    return req.ok(.{ .msg = name, .greeting = "Hello!" });
}
```
```rust
// Rust 백엔드 (SDK)
#[suji::command]
fn greet(name: String) -> String {
    format!("Hello, {}!", name)
}
```
```go
// Go 백엔드 (SDK)
func (a *App) Greet(name string) string {
    return "Hello, " + name
}
```

**플러그인 시스템 설계**:

플러그인 = 백엔드와 동일한 구조 (dlopen + C ABI + invoke 라우팅).
차이는 역할뿐: 백엔드는 앱 로직, 플러그인은 재사용 가능한 기능 모듈.

**핵심 원칙**:
- 플러그인은 백엔드와 동일한 C ABI (`backend_init`, `backend_handle_ipc`, `backend_free`, `backend_destroy`)
- 모든 통신은 `invoke` 경유 (SujiCore 변경 없음, 플러그인 추가해도 코어 수정 없음)
- 채널 접두사 컨벤션: `state:get`, `fs:read`, `tray:set-icon` 등
- 어떤 언어로 만들었든 사용자에겐 이름만 노출

**동작 흐름**:
```
Renderer  → invoke("state:get", {key:"user"}) ──┐
Rust 백엔드 → invoke("state:set", {key,value}) ──┼→ BackendRegistry → state 플러그인 (dlopen)
Go 백엔드  → invoke("state:get", {key:"user"}) ──┘
```

플러그인도 백엔드도 같은 `BackendRegistry`에 등록. 별도 PluginRegistry 없음.

**suji.json (앱 사용자)**:
```json
{
  "app": { "name": "My App", "version": "0.1.0" },
  "plugins": [
    "state",
    "fs",
    { "name": "analytics", "source": "github.com/someone/suji-plugin-analytics" }
  ],
  "backends": [
    { "name": "rust", "lang": "rust", "entry": "." }
  ],
  "frontend": { "dir": "frontend" }
}
```

공식 플러그인은 이름만, 외부 플러그인은 source 지정.
CLI가 다운로드 + 빌드 + dlopen을 알아서 처리.
사용자는 플러그인이 어떤 언어로 만들어졌는지 알 필요 없음.

**suji-plugin.json (플러그인 개발자)**:
```json
{
  "name": "analytics",
  "lang": "rust"
}
```

플러그인 프로젝트 루트에 위치. 코어가 이 파일을 읽고 빌드 방법을 결정.

**플러그인 개발자 경험**:

기존 백엔드 개발과 동일. 새로 배울 것 없음.

```rust
// Rust로 플러그인 개발
use suji::prelude::*;

#[suji::handle]
fn track(event: String) -> String {
    format!(r#"{{"ok":true}}"#)
}

suji::export_handlers!(track);  // → 자동으로 "analytics:track" 채널 등록
```

```go
// Go로 플러그인 개발
type Plugin struct{}
func (p *Plugin) Track(event string) string {
    return `{"ok":true}`
}
var _ = suji.Bind(&Plugin{})  // → 자동으로 "analytics:track" 채널 등록
```

**앱에서 플러그인 사용**:

각 백엔드 개발자는 자기 언어의 래퍼만 설치하면 끝.

```rust
// Rust 백엔드에서 state 플러그인 사용
suji::invoke("state:set", r#"{"key":"user","value":"yoon"}"#);
let val = suji::invoke("state:get", r#"{"key":"user"}"#);

// SDK 래퍼 사용 시 (suji-plugin-state crate)
suji_state::set("user", r#""yoon""#);
let val = suji_state::get("user");
```

```go
// Go 백엔드에서
suji.Invoke("state:set", `{"key":"user","value":"yoon"}`)

// SDK 래퍼 사용 시
state.Set("user", `"yoon"`)
```

```js
// Renderer — @suji/plugin-state (npm)
await suji.invoke("state:set", { key: "user", value: "yoon" })

// SDK 래퍼 사용 시
import { state } from '@suji/plugin-state'
await state.set("user", "yoon")
```

**플러그인 폴더 구조**:
```
plugins/
└── state/
    ├── suji-plugin.json         # 메타데이터 { "name": "state", "lang": "zig" }
    ├── zig/                     # Zig 구현 (C ABI export)
    ├── rust/                    # Rust SDK 래퍼 (suji-plugin-state crate)
    ├── go/                      # Go SDK 래퍼
    └── js/                      # Renderer SDK 래퍼 (@suji/plugin-state)
```

구현은 하나의 언어로만 존재 (state는 Zig, 다른 플러그인은 Rust나 Go 가능).
SDK 래퍼는 각 언어에서 `invoke` 호출을 편하게 감싸주는 얇은 레이어.

**권한 시스템 (나중에)**:
```json
{
  "plugins": [
    {
      "name": "analytics",
      "source": "github.com/someone/suji-plugin-analytics",
      "permissions": ["state:get", "state:set"]
    }
  ]
}
```
명시적으로 허용한 채널만 호출 가능. 외부 플러그인이 허가 없이 `fs:delete` 등 호출 시 코어가 차단.

**고성능 확장 포인트 (필요 시 추가)**:
SujiCore에 `get_plugin` 함수를 추가해 C ABI 함수 테이블을 직접 노출하는 방식.
JSON 직렬화 없이 직접 함수 호출 가능. 현재는 invoke로 충분하므로 실제 수요가 나타나면 추가.

---

**State 플러그인 상세 설계**:

KV Store + JSON 파일 영속성. 첫 번째 공식 플러그인.

모든 영역(Zig/Rust/Go/Renderer)에서 `invoke("state:*")` 채널로 접근.

```
Renderer (JS)  ──┐
Zig backend    ──┤
Rust backend   ──┼── invoke("state:*") → BackendRegistry → state 플러그인
Go backend     ──┘
```

두 계층 구조:
```
┌─────────────────────────────┐
│  Runtime State (메모리)      │  ← 앱 실행 중 공유 (빠름)
│  HashMap + Mutex + EventBus  │
├─────────────────────────────┤
│  Persistent State (디스크)   │  ← 앱 종료 후에도 유지
│  JSON 파일 (→ 나중에 SQLite) │
└─────────────────────────────┘
```

채널:
| 채널 | 요청 | 응답 |
|------|------|------|
| `state:get` | `{"key":"foo"}` | `{"value":"bar"}` |
| `state:set` | `{"key":"foo","value":"bar"}` | `{"ok":true}` |
| `state:delete` | `{"key":"foo"}` | `{"ok":true}` |
| `state:keys` | `{}` | `{"keys":["a","b"]}` |

watch는 EventBus 연동: `state:set` 시 `state:{key}` 이벤트 발행.

동작 방식:
1. 앱 시작 → 디스크에서 JSON 읽어 메모리에 로드
2. `state:set` → 메모리 업데이트 + EventBus `state:{key}` 알림 + 디스크 쓰기
3. `state:get` → 메모리에서 읽기 (빠름)
4. 앱 종료 → 이미 디스크에 반영돼 있으므로 별도 처리 없음

저장 경로 (OS 표준):
| OS | 경로 |
|-----|-----|
| macOS | `~/Library/Application Support/{app-name}/state.json` |
| Linux | `~/.local/share/{app-name}/state.json` (XDG_DATA_HOME) |
| Windows | `%APPDATA%\{app-name}\state.json` |

경합 테스트 (필수):
- 멀티 백엔드(Rust + Go)에서 동시에 state:set/get
- 동시 쓰기 100회 후 값 일관성 검증
- EventBus 알림이 모든 백엔드에 도달하는지 검증

---

### Phase 3: Zig 백엔드 완성

**목표**: Zig 전용 프레임워크로 완성도 올리기

- [x] fs — 파일 시스템 (Phase 5-F: 코어 API + 5 SDK 노출 + sandbox + typed wrapper)
- [x] dialog — 시스템 다이얼로그 (Phase 5-A: macOS NSAlert/NSOpenPanel/NSSavePanel + sheet modal, Linux GTK3, Windows TaskDialog/commdlg + 5 SDK)
- [x] tray — 트레이 아이콘 (Phase 5-B: macOS NSStatusItem + Linux GTK StatusIcon + Windows Shell_NotifyIconW + 컨텍스트 메뉴 + click 이벤트 + macOS/Linux iconPath/submenu/checkbox + 5 SDK)
- [x] menu — 메뉴바/context menu (Phase 5-D: macOS NSMenu + Linux GTK popup + submenu/item/checkbox/separator + click + 5 SDK)
  > **옛 스펙 vs 실제 구현**: 옛 PLAN은 `plugins/{fs,dialog,tray,menu}/` 분리 dylib을
  > 의도했으나, 실제 구현은 **코어 API + 5 SDK wrapper** 형태. OS native API (Cocoa/
  > CoreFoundation 등) 의존이라 dylib 분리는 Mac App Sandbox + CEF Helper와 충돌.
  > Electron/Tauri도 동일하게 코어 API로 제공. `plugins/` 디렉토리는 `state`,
  > `sqlite`, `log`, `store`, `http`, `notification-rich` 같은 cross-cutting 사용자 코드 전용.
  >
  > **각 기능 코드 위치** (현재 — 모두 `src/platform/cef.zig` 내부):
  > | 기능 | cef.zig section | ObjC .m 파일 | main.zig handler |
  > |---|---|---|---|
  > | clipboard | `clipboardReadText/WriteText/Clear` | — | `clipboard_read_text` 등 |
  > | shell | `shellOpenExternal/ShowItemInFolder/Beep` | — | `shell_*` |
  > | dialog | `showMessageBox/OpenDialog/SaveDialog/ErrorBox` | `src/platform/dialog.m` (macOS sheet modal), `src/platform/dialog_linux.c` (GTK varargs wrapper; Linux/Windows main path는 cef.zig) | `handleDialog*` |
  > | tray | `createTray/setTrayMenu/destroyTray` | — (macOS Cocoa / Linux GTK StatusIcon / Windows Win32 직접) | `tray_*` |
  > | notification | `notificationShow/Close/RequestPermission` | `src/platform/notification.m` (macOS; Linux/Windows path는 cef.zig) | `notification_*` |
  > | menu | `setApplicationMenu/resetApplicationMenu/menu_popup` | — (macOS Cocoa / Linux GTK 직접) | `handleMenu*` |
  > | fs | `fsSandboxCheck` etc | — | `handleFs*` (`src/main.zig`) |
  > | globalShortcut | `globalShortcutRegister` 등 | `src/platform/global_shortcut.m` (macOS Carbon/media keys; Linux X11/Windows RegisterHotKey path는 cef.zig) | `handleGlobalShortcut*` |
  > | window lifecycle | `setWindowLifecycleHandlers` | `src/platform/window_lifecycle.m` (NSWindowDelegate) | `windowResized/Moved/Focus/BlurHandler` |
  > | windows (멀티) | `createWindow/destroyWindow/setBounds/...` | — | `src/core/window_ipc.zig` |
  >
  > **후속 refactor 후보** (별도 PR): 각 native API를 `src/platform/{clipboard,shell,...}.zig`로 분리
  > → cef.zig는 코어 (browser, IPC, V8, lifecycle)만 남김. 분량 큼 (cef.zig 5000+줄
  > 분해, glue/global state 정리), risk 중. 현재 우선순위는 낮음.
- [~] window — 멀티 윈도우 + BrowserWindow API (`docs/WINDOW_API.md`)
  - [x] Phase 1: 설계 확정 + PoC (`__core__:create_window`, `cef.zig:createNewWindow`, Electron 방식 동등성, name 중복 싱글턴)
  - [~] Phase 2: 이벤트 시그니처 변경 (SujiEvent) + 윈도우 제어 (크기/위치/상태) + IPC `__window` 자동 태깅 + `windows[]` 배열 파싱
    - [x] WindowManager 스켈레톤 + Native vtable 추상화 (`src/core/window.zig`)
    - [x] SujiEvent + EventSink (`window:created`/`close`/`closed`, preventDefault)
    - [x] 동시성 안전성 (`std.Io.Mutex` + 이벤트 발화는 lock 밖)
    - [x] TDD 단위 테스트 49개 (동시성·OOM·재진입·에러 경로·이벤트 누출 금지)
    - [x] Step A: CefNative 스켈레톤 — `window.Native` vtable을 CEF로 구현 (`src/platform/cef.zig`)
    - [x] Step B.1: EventBusSink 어댑터 — WM.EventSink → EventBus + cancelable 리스너 레지스트리
    - [x] Step B.2: `main.zig` 배선 — WindowStack으로 WM + CefNative + Sink 통합, 첫 윈도우 `wm.create` 경유
    - [x] Step B.3+B.4: CEF life_span 통합 — `DoClose` 취소 가능 이벤트 라우팅 + `OnBeforeClose` 테이블 정리 + WM 통지. `tryClose`/`markClosedExternal`/`findByNativeHandle` 추가. `destroyLocked` reorder (destroyed 마킹을 native 호출 전에 — DoClose 재진입 시 중복 이벤트 방지)
    - [x] Step B.5: `createNewWindow` PoC 제거 — `create_window` IPC 커맨드를 `window_ipc.handleCreateWindow`로 라우팅해 WM 경유
    - [x] Cmd+W 단축키를 `wm.close` 경유로 전환 (WM 이벤트 파이프라인 통과)
    - [x] `window:all-closed` 이벤트 발화 — 사용자 코드가 `suji.on("window:all-closed", ...)` + `suji.platform()` + `suji.quit()`로 Electron canonical 패턴 직접 작성 (코어 자동 quit X)
    - [x] `suji.quit()` + `suji.platform` 전 언어 SDK 노출 (Zig / Rust / Go / Node / Frontend JS 완료)
    - [x] 구조화 디버그 로거 (`~/.suji/logs/` 실행별 파일 + ISO8601 레벨 필터)
    - [x] macOS NSWindow close cascade 개선 (`g_window` 싱글 참조 제거, per-browser tracking)
    - [x] OnBeforeClose — CEF Alloy 런타임 외부 한계(자연 quit-on-close 트리거
          없음, 메시지루프 기반). 현 `doClose()→window:close 이벤트→quit()` 우회가
          최적이자 의도된 설계: 코어 자동 quit 없음, 사용자 코드가 Electron canonical
          `window:all-closed`+`suji.quit()` 직접 작성(Electron 동등). Chrome runtime
          전환 시에만 개선 가능 → 현 상태로 종결(won't-fix-by-design).
    - [x] `set_title` / `set_bounds` 플랫폼별 구현 (CEF Views 경로는 macOS/Linux/Windows 공통, macOS legacy fallback은 NSWindow)
    - [x] IPC `__window` 자동 태깅 — wire 레벨. `cef.zig:handleBrowserInvoke`에서 sender
          browser의 WM id를 `injectWindowField`로 request JSON에 merge. 이미 태그된 요청,
          비-객체/빈 객체/whitespace 엣지 케이스 모두 처리. `window_ipc.injectWindowField`
          순수 함수로 단위 테스트 7종 + E2E (`tests/e2e/window-injection.test.ts`)로 검증.
    - [x] `windows[]` 배열 파싱 — config.zig의 `Config.windows: []const Window`. 시작 시 배열 길이만큼
          `wm.create` 자동 호출. Tauri 호환 선언적 다중 창. 하위호환 X (단일 `window` 객체 제거).
    - [x] **핸들러 `InvokeEvent` 파라미터** — Electron의 `IpcMainInvokeEvent` 대응.
          (4 SDK + wire 필드 전부 구현 완료 — 하위 항목 모두 [x], 코드 감사 확인.)
          `__window` 필드는 wire 레벨이고, 핸들러 표면에서는 `(req, event)` 2-arity로 받음.
          - [x] Zig: `fn h(req: Request, event: InvokeEvent) Response`. 1-arity 핸들러는 comptime
                wrapper로 adapt되어 호환성 유지. `event.window.id`/`event.window.name`으로 호출한
                창 식별. 기존 SDK의 window listener용 `Event`와 이름 충돌 회피로 `InvokeEvent` 명명.
          - [x] Rust: `#[suji::handle] fn h(req: Value, event: InvokeEvent) -> Value` — proc macro가 타입 기반 자동 주입
          - [x] Go: `func (a *App) H(data string, event *suji.InvokeEvent) any` — reflect 경로 2-arity
          - [x] Node: `handle(ch, (data, event) => ...)` — handler.length 분기
          - [x] `event.window`에 name 추가 — wire의 `__window_name`에서 파생 (익명 창은 null).
                WM에서 `.name("settings")`같이 지정된 창에서 호출 시 event.window.name으로 접근.
          - [x] `event.window`에 url 추가 — wire의 `__window_url`에서 파생. cef.zig가 sender의
                main frame URL을 자동 주입. 4개 SDK 모두 노출 (Electron event.sender.url 대응).
          - [x] `event.window`에 is_main_frame 추가 — wire의 `__window_main_frame`에서 파생.
                cef_frame_t.is_main()으로 sender frame이 main인지 식별. 4개 SDK 모두 노출.
          - Frontend `suji.invoke('ch', data)`는 그대로 (호출 측 변경 없음)
  - [x] Phase 2.5: 멀티 윈도우 데이터 인프라 — 핵심 4축 완료
    - [x] `suji.send(event, data, {to: winId})` + 4개 언어 SDK 모두 `sendTo(id, ch, data)` — Electron `webContents.send` 대응. E2E 통과 (4언어 × target 라우팅).
    - [x] state 플러그인 scope 확장 (`global` / `window:{id}` / `window`(자동) / `session:*`).
          기존 데이터는 자동 마이그레이션 (`<scope>::<key>` prefix). watch 채널도 scope별 분리.
    - [ ] `SujiCore.get_window_api` — 플러그인이 BrowserWindow 조작 가능 (Phase 3+)
    - [x] 생명주기 이벤트 payload `{windowId, name?}` 표준화 — created/close/closed 모두 일관.
          name은 destroy 전 캡처해서 closed에도 포함 → 플러그인이 wm 조회 없이 분기.
  - [x] Phase 3: 외형/속성 (프레임리스, 투명, 부모-자식, 추가 외형 옵션)
    - [x] `windows[].frame: false` — macOS는 NSWindowStyleMaskBorderless, Linux는 CEF Views
          `CefWindowDelegate.is_frameless` 경로로 완료(`run-frameless-drag-region.sh` E2E).
          Windows는 후속.
    - [x] `windows[].transparent: true` — macOS NSWindow.opaque=NO + clearColor + hasShadow=NO, Linux CEF Views window/browser view background_color=0.
    - [x] `windows[].parent: "<name>"` — macOS NSWindow.addChildWindow:ordered:NSWindowAbove, Linux CEF Views `get_parent_window`로 시각 관계만 (PLAN 재귀 close X).
          parent name lookup은 main.zig의 wm.fromName으로 처리 — 따라서 부모는 windows[] 배열 순서상 더 앞에 와야.
    - [x] `windows[].x / y` — 명시 위치. 0이면 OS cascade 자동 (cascadeTopLeftFromPoint:).
    - [x] `windows[].alwaysOnTop` — macOS NSFloatingWindowLevel(3), Linux CEF Views `set_always_on_top`.
    - [x] `windows[].resizable: false` — macOS NSWindowStyleMaskResizable 비트 제외, Linux CEF Views `can_resize/can_maximize`.
    - [x] `windows[].minWidth/minHeight/maxWidth/maxHeight` — macOS NSWindow.contentMinSize/contentMaxSize, Linux CEF Views min/max delegate.
    - [x] `windows[].fullscreen: true` — macOS toggleFullScreen:, Linux CEF Views `set_fullscreen`.
    - [x] `windows[].backgroundColor: "#RRGGBB(AA)"` — macOS NSColor.colorWithRed:green:blue:alpha:, Linux CEF Views `set_background_color`.
    - [x] `windows[].titleBarStyle: "hidden" | "hiddenInset"` — titlebarAppearsTransparent + NSWindowStyleMaskFullSizeContentView.
    - 런타임 변경 API (set_frame/set_transparent/setParent)는 미지원 — 시작 시점 결정만. 실수요 발견 시 SujiCore.get_window_api로 도입.
    - **플랫폼 한계**: macOS/Linux는 frameless의 `-webkit-app-region: drag` 라우팅 완료.
      Windows는 아직 별도 native 검증 전이라 후속 플랫폼 작업 필요.
  - [~] Phase 4: webContents (네비, JS 실행, 줌, 프린트/캡처)
    - [x] **Phase 4-A 네비/JS** — `load_url`, `reload`(`ignoreCache`), `execute_javascript`,
          `get_url`(캐시), `is_loading` 6개. WM 메서드 + IPC 핸들러 + Frontend SDK
          (`windows.loadURL/reload/executeJavaScript/getURL/isLoading`) + 단위 17 + e2e 3.
    - [x] **Phase 4-B 줌** — `set_zoom_level/get_zoom_level/set_zoom_factor/get_zoom_factor`. CEF는
          zoom_level만 노출 — factor는 WM에서 `pow(1.2, level)` 변환 (Electron 호환). Native
          vtable level 2개 + WM 4개 + IPC 4 + 5 SDK + 단위 9 + e2e 4. CEF set_zoom_level은
          navigation 시점 deferred — round-trip 정확 검증은 단위가 담당, e2e는 ok 응답 형식만.
    - [x] **Phase 4-C 핵심** — `open_dev_tools`, `close_dev_tools`, `is_dev_tools_opened`,
          `toggle_dev_tools` 4개. WM 메서드 + IPC 핸들러 + 5 SDK (Frontend + Zig/Rust/Go/Node) +
          단위 11 + e2e 3. open/close 멱등 — 이미 열림/닫힘이면 no-op. 기존 F12 단축키
          토글 코드(`toggleDevTools` 헬퍼)를 분해해 4개 API로 노출.
    - [x] Phase 4-D 인쇄/캡처
      - [x] **`print_to_pdf`** — `cef_browser_host_t.print_to_pdf` + `cef_pdf_print_callback_t`
            (글로벌 stateless callback). 즉시 ok 응답 + 완료 시 `window:pdf-print-finished` 이벤트
            (`{path, success}`) 발화. SDK가 path 매칭으로 Promise resolve (Frontend/Node).
            Native vtable + WM + IPC + 5 SDK + 단위 4 + e2e 2 (실 PDF 파일 생성 검증).
            Linux용 `cef_print_handler_t.get_pdf_paper_size`(U.S. Letter) 등록 완료
            (cef.zig `getPrintHandler`/`getPdfPaperSize`, initClient 배선). macOS/
            Windows 는 네이티브 인쇄라 print_handler 무시 → 등록 무영향(회귀 가드:
            단위 790 + window-lifecycle pdf-print). Linux 는 GitHub Actions
            `run-print-to-pdf.sh`에서 실제 PDF 생성 + `%PDF-` 시그니처 검증.
      - [x] **`capture_page`** — CEF 직접 미지원 → CDP `Page.captureScreenshot`
            (send_dev_tools_message + dev_tools_message_observer). base64 PNG 가
            IPC 한도(64KB) 초과 가능 → printToPDF 와 동형 file-path 방식:
            ack 즉시 + `window:page-captured`{path,success} 이벤트. 코어
            (cef observer/pending + window/ipc/main) + 4 SDK + 단위 테스트 + e2e(실 CEF: 실 PNG 파일 매직바이트·window:page-captured 실증).
    - [x] **Phase 4-E 편집/검색** — `undo/redo/cut/copy/paste/select_all` (frame 위임 6) +
          `find_in_page(text, forward, matchCase, findNext)` + `stop_find_in_page(clearSelection)`.
          5 SDK + 단위 12 + e2e 4. user_agent dynamic은 CEF 미지원(창 settings 한 번만) — Phase 7
          보안과 함께 백로그.
    #### Phase 4 백로그 (Phase 5 진입 전 또는 그 이후 처리)

    A 사용자 가시 기능 (가치 높음 / 작업 큼):
    - [x] **frameless drag region (`-webkit-app-region: drag`) — macOS/Linux 완료**.
          CEF `cef_drag_handler_t.on_draggable_regions_changed`로 region 수집 +
          macOS `NSWindow.sendEvent:` hit-test → `[window performWindowDragWithEvent:]`
          라우팅 완료. Linux는 CEF Views top-level `CefWindowDelegate.is_frameless` +
          `CefWindow.set_draggable_regions` 경로로 native drag/no-drag를 보존.
          검증: `cef_drag_region.zig` 단위, `cef_window_options.zig` 단위,
          `tests/e2e/run-frameless-drag-region.sh` macOS/Linux runtime E2E.
    - [x] **Linux 잔여 native 창 옵션** — CEF Views top-level 경로에서
          `transparent`/`parent`/alwaysOnTop/resizable/min·max/fullscreen/backgroundColor를
          native delegate/API로 배선. `parent`는 `get_parent_window` + non-modal로
          부모 컨트롤을 비활성화하지 않는다.
    - [ ] (backlog) **Windows frameless native window** —
          Windows `frame:false`/drag region은 아직 실 런타임 검증 전.
    - [x] **`capture_page`** — 구현 완료(상위 Phase 4-D 항목 참조): CDP
          `Page.captureScreenshot` + dev_tools observer → file-path 방식.
    - [x] **DevTools "Reload" 버튼 → inspectee 창 reload** (Electron 동작 호환). 완료.
          OnPreKeyEvent의 reload 키(F5/Cmd+R/Cmd+Shift+R) 분기를 `reloadInspecteeOrSelf`
          헬퍼 경유. 멀티 매핑 `devtools_to_inspectee: AutoHashMap(u64, u64)` —
          openDevTools에서 pending 변수 set → onAfterCreated에서 새 DevTools browser와 매핑 →
          onBeforeClose에서 정리. CEF single UI thread라 race-free, 멀티 윈도우 동시 DevTools 안전.
    - [x] **DevTools 닫힘 시 부모 창 키 포커스 복귀** — onBeforeClose에서 inspectee NSWindow에
          `performSelector:withObject:afterDelay:0`으로 다음 런루프 틱에 makeKeyAndOrderFront 예약.
          AppKit close-time 비동기 focus 재할당 후 우리 호출이 적용되도록.
    - [x] **DevTools 떠 있는 상태 quit + Cmd+Q SIGTRAP 회피** — `cef.quit()`이 모든 DevTools/browser
          close 후 cef_quit_message_loop. App 메뉴 Quit 항목은 `terminate:` 대신 `SujiQuitTarget.sujiQuit:`
          custom selector → cef.quit() (NSApplicationWillTerminate 옵저버에서 CEF SIGTRAP 우회).
    - [x] **Frameless 창 키 이벤트** — `SujiKeyableWindow` ObjC subclass + `canBecomeKeyWindow=YES`
          override (기본 NSWindow는 borderless면 NO 반환).
    - [x] **`find_in_page` 결과 보고 이벤트** — `cef_find_handler_t.OnFindResult` 등록 →
          `window:find-result` 이벤트(`{windowId, identifier, count, activeMatchOrdinal}`).
          incremental 진행 update는 forward X (`finalUpdate=true`만, Electron `found-in-page`
          의도와 동일). 단위 + e2e 1 (DOM 텍스트 주입 후 검색 → match count > 0).

    B 플랫폼/엣지 (가치 중간):
    - [x] **Linux PDF 인쇄** — `cef_print_handler_t.get_pdf_paper_size`(U.S. Letter,
          device-units) + `getPrintHandler` 등록 완료(cef.zig, initClient 배선).
          macOS/Windows 는 print_handler 무시(네이티브 인쇄) → 무영향. Linux CI
          런타임 E2E(`run-print-to-pdf.sh`)로 실제 PDF 파일 생성과 `%PDF-`
          시그니처까지 검증.
    - [x] **`set_user_agent` / `get_user_agent` dynamic** — CEF settings UA 는
          init 1회뿐이라, 동적은 CDP `Network.setUserAgentOverride`
          (`send_dev_tools_message`, raw JSON)로 구현. set 값은 BrowserEntry
          inline 추적(url_cache 패턴)해 get 이 반환(CEF per-browser UA getter
          미제공). 코어(cef/window/window_ipc/main) + 4 SDK windows.* +
          BrowserWindow + 단위 테스트(window_manager/JS/Node) + e2e(실 CEF:
          CDP override 가 navigator.userAgent 를 실제 변경함을 실증) 검증.

    C 기술 부채 (가치 낮음 / 코드 정리):
    - [~] **`cefInvokeHandler` ↔ `backendSpecialDispatch` 단일화** — 부분 해소·잔여 의도적 보류.
          현 상태(평가 완료): `SPECIAL_DISPATCHERS` 테이블 + `cefHandleCore/Fanout/Chain`
          핸들러를 두 경로가 **공유**, 디스패처는 각 ~5줄 thin loop(차이는 cefInvokeHandler 의
          backend 라우팅/node 폴백, backendSpecialDispatch 의 `g_in_backend_invoke` 마커 —
          본질적 관심사 차이라 통합 부적절). 잔여 = `cefHandleCore` 의 입력 정규화 2줄
          (`if request 필드 → unescape, else raw`) — 깔끔한 어댑터. 완전 제거하려면 CEF/JS
          `__suji__.core` 와이어 포맷 변경 필요 → 200회 stress·chain/fanout e2e 회귀 위험 大.
          가치 낮음(plan 명시) 대비 위험 과다 → **보류 유지**(억지 단일화 안 함).
  - [~] **Phase 5-A: Native API (Clipboard / Shell / Dialog)** — 5개 진입점 모두 노출 완료.
        - [x] **Clipboard** (`readText/writeText/clear`, `readHTML/writeHTML`) — macOS NSPasteboard + Linux GTK clipboard text/HTML + Windows CF_UNICODETEXT/CF_HTML. Frontend `@suji/api` +
              Zig/Rust/Go/Node SDK 4개. macOS E2E 37 케이스(write/read/clear, 길이 한도, JSON wire,
              Unicode/RTL/이모지/ZWJ, 200회 stress, 다중 창) + Linux Xvfb + Windows text/HTML round-trip E2E
              (`tests/e2e/run-clipboard-text-runtime.sh`). `documents/clipboard-shell.mdx`.
        - [x] **Shell** (`openExternal/showItemInFolder/beep/trashItem`) — macOS NSWorkspace + NSBeep + NSFileManager,
              Linux GIO `g_app_info_launch_default_for_uri`/`g_file_get_uri`/`g_file_trash` + FileManager1 D-Bus + GDK beep, Windows ShellExecute/SHFileOperation.
              modern API `activateFileViewerSelectingURLs:` (deprecated `selectFile:` 회피).
              scheme 사전 검사 + `fileExistsAtPath:` 사전 검증으로 LaunchServices `-50` dialog 회피.
              E2E 32 케이스 + Linux Xvfb/dbus openExternal x-scheme-handler + openPath MIME handler +
              showItemInFolder fake FileManager1 + beep 반복 호출 + trashItem round-trip E2E. 4개 SDK 노출.
        - [x] **Dialog** (`showMessageBox/showErrorBox/showOpenDialog/showSaveDialog` + Sync 변종 3개) —
              macOS NSAlert/NSOpenPanel/NSSavePanel + sheet modal, Linux GTK3 GtkMessageDialog/
              GtkFileChooserDialog, Windows TaskDialogIndirect/MessageBoxW/GetOpenFileNameW/
              IFileOpenDialog/GetSaveFileNameW. `src/platform/dialog.m` ObjC block completion
              handler + nested NSApp event loop, `src/platform/dialog_linux.c` GTK varargs wrapper.
              windowId 첫 인자는 macOS에서 sheet, Linux/Windows에서는 free-floating native dialog.
              showsTagField + filters + checkbox. `documents/dialog.mdx`. 5개 SDK 노출.
        - **새로 깔린 인프라**: `.m` 파일 컴파일 룰 (build.zig + `-fobjc-arc`) — 향후 ObjC block
              필요 API (Notification completion, NSAnimation, vibrancy 등) 재사용 가능.
  - [x] **Phase 5: 라이프사이클 이벤트** — close/closed/all-closed/resized/moved/focus/blur는
        Phase 2에서 완료. Phase 5-1~5-5에서 minimize/restore/maximize/unmaximize/enter·leave-
        full-screen/show/hide/ready-to-show/page-title-updated/will-resize 추가 + quit-policy
        (`app.quitOnAllWindowsClosed`) 옵션. SDK 호환성 (5 SDK 모두 EventBus 통해 자동) + 단위
        47개 + macOS E2E 13 pass / 4 skip / 0 fail. Linux CEF Views runtime E2E도
        `run-window-lifecycle-events-cef-views.sh`로 setBounds resize, lifecycle controls,
        ready/title, show/hide를 검증한다. Linux headless에서 CEF Views min/max getter가
        command 직후 lag되는 문제는 delegate-side 상태 cache로 보정했다. 4 skip은 e2e 환경 한계 — `docs/WINDOW_API.md#
        phase-5-라이프사이클--e2e-미커버-케이스`로 단위 테스트 cover 매핑 documented.
        will-move는 macOS NSWindowDelegate에 sync cancel API 부재로 미구현 (Electron도 macOS
        미발화). frameless drag 라우팅은 macOS/Linux 완료 — Windows는 후속.
  - [x] **Phase 5-B: Tray** — macOS NSStatusItem + Linux GTK StatusIcon + Windows Shell_NotifyIconW + 메뉴 + click 이벤트 라우팅. 5 진입점 모두
        (Frontend `@suji/api` + Zig/Rust/Go/Node SDK). `tray.create/setTitle/setTooltip/setMenu/destroy`,
        `tray:menu-click {trayId, click}` 이벤트. SujiTrayTarget ObjC subclass + NSMenuItem.tag/
        representedObject 라우팅, Linux `GtkStatusIcon` + `GtkMenu`, Windows hidden message-only window + HMENU popup.
        macOS/Linux `iconPath` + submenu/checkbox/enabled 지원. 남은 한계: Windows `iconPath`/nested submenu parity,
        radio item, macOS tray icon click 단독 hook. 회귀/SDK/E2E 테스트. `documents/tray.mdx`.
  - [x] **Phase 5-C: Notification v1** — UNUserNotificationCenter + Linux D-Bus notification daemon + Windows Shell_NotifyIcon balloon + 5 진입점.
        `notification.{isSupported, requestPermission, show, close}` + `notification:click`
        이벤트 라우팅. `src/platform/notification.m` ObjC block completion handler 인프라
        재사용 + SujiNotificationDelegate. Linux는 `org.freedesktop.Notifications`
        `GetServerInformation`/`Notify`/`CloseNotification` 직접 호출 + fake daemon runtime E2E.
        Windows는 notification 전용 tray icon + `NIF_INFO` balloon + `NIN_BALLOONUSERCLICK` 라우팅.
        Bundle ID 검사 — macOS `suji dev` loose binary는 stub 동작, `.app` 번들 후 실 알림 표시.
        v1 한계: actions/buttons, reply, custom icon 미지원. 회귀 + E2E + Zig SDK 단위.
        `documents/notification.mdx`.
  - [x] **Phase 5-D: 메뉴바 / context menu API** — macOS NSMenu + Linux GTK popup 기반.
        App 메뉴(Quit/Hide/About)는 Suji가 보존하고 사용자 정의 top-level menu를 그 뒤에 구성.
        `menu.setApplicationMenu/resetApplicationMenu`, `submenu/item/checkbox/separator`,
        `menu.popup`, `menu:click {click}` 이벤트 라우팅. Linux는 애플리케이션 메뉴바 대신
        GTK `menu.popup` 지원. Frontend `@suji/api` + Zig/Rust/Go/Node SDK 노출.
        회귀 테스트 + SDK 단위 + `tests/e2e/menu.test.ts`. `documents/menu.mdx`.
  - [x] **Phase 5-E: 글로벌 단축키** — macOS Carbon RegisterEventHotKey + Linux X11 XGrabKey + Windows RegisterHotKey
        (macOS 일반 키는 NSEvent monitor가 아닌 Carbon path, 권한 불필요). 5 SDK 모두 노출(`globalShortcut.{register/unregister/
        unregisterAll/isRegistered}`) + accelerator 파싱 + `globalShortcut:trigger` 이벤트.
        미디어키는 macOS NSEvent system-defined monitor 경로. Linux는 X11/XWayland 전용이며 순수 Wayland는 graceful reject.
        `src/platform/global_shortcut.m` + 5 SDK + e2e.
  - [x] **Phase 5-F: 파일 시스템 API** — Zig `std.fs` 노출. readFile/writeFile/stat/mkdir/readdir.
        Frontend JS + Zig/Rust/Go/Node SDK wrapper, 단위/회귀/E2E 테스트, 문서 추가.
        프론트는 IPC, 백엔드는 std lib 직접 + 공통 typed wrapper.
  - [x] Phase 6: SDK (Rust/Go/Node/Frontend JS BrowserWindow)
        - [x] windows.* API 5개 진입점 노출
        - [x] clipboard/shell/dialog 5개 진입점 노출
        - [x] BrowserWindow OO wrapper — 4 SDK 전부(@suji/api·@suji/node
              class, Rust struct, Go struct). windows.<fn>(id,...) 위임으로
              로직/타입 무중복. 단위/타입 테스트 + cargo/go/bun 검증.
  - [ ] Phase 7: 보안/플랫폼 전용 (contextIsolation, vibrancy 등)
    - [x] `contextIsolation` — `onContextCreated` 가 멤버 조립/platform 주입 *후*
          `window.__suji__` 를 `Object.freeze`(메서드 재할당·추가·삭제 차단) + window
          슬롯 `non-writable`/`non-configurable`(통째 교체·삭제 차단)로 봉인.
          shallow freeze 라 `_pending`/`_listeners` inner 객체는 가변 → invoke/on/off
          무손상. **항상 적용**(고정 bridge API freeze 는 정상 사용 안 깸).
          ⚠️ 구현 불변식: `onContextCreated` 의 `ctx.eval` 호출은 **정확히 1회**
          (js_code + platform/harden 을 단일 `combined_js` 로 합침). 늘리면 CEF
          inspector attach 가 30s(protocolTimeout) 행 — 실측 회귀, `e2e
          set-user-agent` 가드. 새 JS 는 별도 eval 아니라 combined_js 에 이어붙일 것.
          **보안 한계(정직)**: 우리 바인드보다 *먼저* 실행된 스크립트는 못 막음
          (메인 월드 frozen — Chrome isolated-world/별도 V8 컨텍스트 아님).
          진짜 isolated-world 격리는 후속(아래 backlog). e2e 5 케이스
          (`tests/e2e/context-isolation.test.ts`) 로 frozen/변조차단/슬롯봉인/
          기능보존 실증. (preload.js / contextBridge 자체는 **비제공**)
    - [ ] (backlog) 진짜 isolated-world — 별도 V8 컨텍스트에 bridge 두고 메인 월드엔
          frozen 프록시만 노출(pre-bind XSS 도 차단). 위 frozen 하드닝의 상위 단계.
    - [x] **macOS App Sandbox 인프라** — `suji build --sandbox` / `SUJI_SANDBOX` 옵션.
          `BundleOptions.sandbox` (기본 false) → `codesignWithEntitlements` 가
          `assets/entitlements/{,sandbox/}<helper>.plist` 서브디렉토리 선택. 루트 5개=
          non-sandbox(Developer ID + Notarization 기본, Hardened Runtime 3종만),
          `sandbox/` 5개=App Sandbox + helper별 inherit (Mac App Store). CEF Helper
          번들 5개(main / Browser / GPU / Renderer / Plugin) 자동 부착 — 기존 codesign
          경로 재사용, signing none/adhoc/identity 와 직교. 단위 회귀(루트=app-sandbox
          부재 + Hardened 키, sandbox/=app-sandbox+inherit) + adhoc 로컬 실증
          (non-sandbox app-sandbox=0 / `--sandbox`=1 / `codesign --verify` exit=0).
          ✅ Security-scoped bookmarks API (`NSURLBookmarkCreationWithSecurityScope` /
          `start/stopAccessingSecurityScopedResource`) 후속 슬라이스로 **완료** —
          Electron 패리티 표 참조(`app.createSecurityScopedBookmark` 외 2, 4 SDK +
          e2e 8 + `sandbox/main.plist files.bookmarks.app-scope`). identity 모드 MAS
          실제 제출은 실 인증서·App Store Connect 필요 = 미검증.
    - [x] **Sheet modal** — 완료 (Phase 5-A에서 구현) — `src/platform/dialog.m` + `windowId` 첫 인자.
  - **설계 비제공 (문서화 완료)**: 렌더러 직접 통신, MessagePort, preload.js, contextBridge — `docs/WINDOW_API.md#설계-비제공-항목과-이유`
  - **V2 검토**: `cross_origin_isolation` 플래그 (SharedArrayBuffer 활성화), `inject` 초기 스크립트 옵션
  - **엣지 케이스 / TDD 전략 / E2E 범위**: `docs/WINDOW_API.md` 해당 섹션 참조
  - **핵심 결정사항** (확정):
    - **Electron 호환 계층**: 허브-스포크, 렌더러 직접 통신 X, preload.js X, MessagePort V2, SharedArrayBuffer는 옵션 플래그만
    - **플러그인 API**: id 기반 (핸들 X) + SDK는 OO wrapper, async 완료는 이벤트 폴백, `executeJavaScript` 필수, `onWindowClosed` SDK 편의 wrapper 제공
    - **안전성**: id monotonic (재사용 X), create 전체 write lock, closed 창 emit은 silent no-op, orphan은 destroyAll, 부모-자식은 시각 관계만 (재귀 close X)
    - **TDD 인프라**: Light 투자 (MockBrowser/MockWebView 각 10~20줄만). 필요 시점에 확장. WindowManager 단위는 CEF 없이 풀-TDD
    - **구현 순서**: Phase 2 (기본) + Phase 2.5 (데이터 인프라) **분리 유지**. 2.5 없이 Phase 2만 완료되면 플러그인이 멀티 윈도우 인지 불가
    - **E2E 실행**: macOS/Linux/Windows CI + CEF runtime subset.
- [x] CLI 도구
  - [x] `suji init` — 프로젝트 스캐폴딩 (backend zig/rust/go/multi + frontend react/vue/svelte/solid/preact/vanilla)
  - [x] `suji dev` — 개발 서버 (프론트엔드 + 백엔드 동시 실행)
  - [x] `suji build` — 프로덕션 빌드
  - [x] `suji run` — 빌드된 앱 실행
- [x] 핫 리로드 (백엔드 — dylib 재빌드/재로드, 프론트엔드는 Vite HMR로 동작)

**`suji init` 스펙**:

```bash
suji init my-app
# 대화형으로 선택:
#   Backend language? [zig/rust/go/node/multi]
#   Frontend framework? [react/vue/svelte/vanilla]
#   Package manager? [bun/npm/pnpm]
```

단일 백엔드 (예: `suji init my-app --backend=rust --frontend=react`):
```
my-app/
├── suji.json
├── Cargo.toml
├── src/lib.rs
└── frontend/          ← 번들 Vite 템플릿 — --frontend=react|vue|svelte|solid|preact|vanilla (기본 react, invoke 데모 동작)
    ├── package.json
    ├── src/App.tsx
    └── ...
```

멀티 백엔드 (예: `suji init my-app --backend=multi`):
```
my-app/
├── suji.json
├── backends/
│   ├── rust/
│   │   ├── Cargo.toml
│   │   └── src/lib.rs
│   └── go/
│       ├── go.mod
│       └── main.go
└── frontend/
    ├── package.json
    └── src/App.tsx
```

**`suji dev` 스펙**:
```bash
suji dev
# 1. suji.json 읽기 (설정 파일)
# 2. 백엔드 빌드 (cargo build / go build / zig build)
# 3. 프론트엔드 dev 서버 실행 (bun dev → localhost:5173)
# 4. WebView 창 열기 (dev_url 로드)
# 5. 파일 감시 → 백엔드 변경 시 자동 재빌드 + 리로드
```

**결과물**: Zig만으로 완전한 데스크톱 앱 개발 가능

---

### Phase 4: 다중 언어 백엔드 (dlopen)

**목표**: 각 언어 개발자가 자기 생태계 DX 그대로 사용

**원칙**: Suji CLI를 강제하지 않음. 각 언어의 패키지 매니저 + 빌드 도구를 그대로 사용.

- [x] C ABI 인터페이스 스펙 정의 (backend_init, backend_handle_ipc, backend_free, backend_destroy)
- [x] `backends/loader.zig` — dlopen 관리자 (Backend, BackendRegistry)
- [x] 각 언어별 SDK (Electron 스타일: handle/invoke/on/send)
  - [x] Rust: `crates/suji-rs` (#[suji::handle], export_handlers!, invoke/send/on/off)
  - [x] Go: `sdks/suji-go` (suji.Bind, Invoke/Send/On/Off, bridge.c로 EventBus 연결)
  - [x] Zig: `src/core/app.zig` (suji.app().handle(), exportApp(), req.invoke/send)
  - [ ] C: `suji.h` 헤더
  - [ ] SDK crates.io / go pkg 배포
- [x] 각 언어별 예제 프로젝트 (examples/zig-backend, rust-backend, go-backend, multi-backend)
- [x] 자동 라우팅 (register): 백엔드가 채널을 등록하면 프론트엔드에서 채널명만으로 호출 가능
- [x] 중복 채널 에러 처리: 동일 채널을 여러 백엔드가 등록 시 에러 반환

**각 언어별 개발자 경험**:

Rust 개발자:
```bash
cargo new my-app && cd my-app
# Cargo.toml에 추가
# [dependencies]
# suji = "0.1"
# [lib]
# crate-type = ["cdylib"]
cargo build   # → target/release/libmy_app.dylib
```
```rust
use suji::prelude::*;

#[suji::command]
fn greet(name: String) -> String {
    format!("Hello, {}", name)
}
```

Go 개발자:
```bash
go mod init my-app
go get github.com/ohah/suji-go
go build -buildmode=c-shared -o libmy_app.dylib
```
```go
package main

import "C"
import "github.com/ohah/suji-go"

//export greet
func greet(name *C.char) *C.char {
    return C.CString("Hello, " + C.GoString(name))
}
```

Zig 개발자:
```bash
zig init
# build.zig.zon에 suji 의존성 추가
zig build run
```

Node 개발자:
```bash
npm init
npm install suji
node main.js
```
```js
const { app, BrowserWindow } = require("suji");
app.on("ready", () => {
  const win = new BrowserWindow({ width: 800, height: 600 });
  win.loadFile("index.html");
});
```

**인터페이스 스펙**:
```c
// Zig 코어가 백엔드에게 제공하는 API
typedef struct {
    const char* (*invoke)(const char* backend_name, const char* request);
    void (*free)(const char* response);
    void (*emit)(const char* event_name, const char* data);
    uint64_t (*on)(const char* event_name, EventCallback cb, void* arg);
    void (*off)(uint64_t listener_id);
} SujiCore;

// 백엔드가 export해야 하는 C ABI 함수
void backend_init(SujiCore* core);          // 코어 참조를 받아 저장
const char* backend_handle_ipc(const char* request);  // IPC 요청 처리
void backend_free(char* ptr);               // 응답 메모리 해제
void backend_destroy(void);                 // 백엔드 종료
```

**크로스 백엔드 호출 예시 (Rust에서 Go 호출)**:
```rust
static CORE: OnceLock<&SujiCore> = OnceLock::new();

#[no_mangle]
pub extern "C" fn backend_init(core: *const SujiCore) {
    unsafe { CORE.set(&*core).ok(); }
}

#[no_mangle]
pub extern "C" fn backend_handle_ipc(request: *const c_char) -> *mut c_char {
    let core = CORE.get().unwrap();
    // Rust 안에서 Go 백엔드 호출
    let go_resp = unsafe { (core.invoke)(c"go".as_ptr(), c"{\"cmd\":\"stats\"}".as_ptr()) };
    // ... go_resp 사용 후 core.free로 해제
}
```

**크로스 백엔드 호출 예시 (Go에서 Rust 호출)**:
```go
var core *C.SujiCore

//export backend_init
func backend_init(c *C.SujiCore) { core = c }

//export backend_handle_ipc
func backend_handle_ipc(request *C.char) *C.char {
    // Go 안에서 Rust 백엔드 호출
    rustResp := C.core_invoke(core, C.CString("rust"), C.CString(`{"cmd":"hash"}`))
    // ... rustResp 사용 후 core_free로 해제
}
```

**SDK가 하는 일**: C ABI boilerplate를 숨기고 각 언어에 자연스러운 API를 제공. 개발자는 `extern "C"` 같은 걸 직접 쓸 필요 없음.

---

### Phase 5: Node.js 지원 (libnode 임베드)

**목표**: Electron과 유사한 DX. Zig 코어가 주인, Node를 임베드.

**방식**: libnode (Node.js를 공유 라이브러리로 빌드하여 Zig에서 로드)

**libnode 빌드 주의사항**:
- Node.js 소스에서 `./configure --shared && make` 로 빌드
- 빌드 시간 15~20분, 디스크 20GB+ 필요
- macOS arm64 프리빌트 없음 (직접 빌드 필수)
- 공식 지원이 아닌 비공식 빌드 옵션
- Electron도 libnode가 아닌 소스 레벨 통합 방식을 사용함
- metacall/libnode 프로젝트 참고 가능
- Windows CI/release는 공식 MSVC `libnode.lib` 대신 MSYS2
  `mingw-w64-x86_64-nodejs`의 MinGW ABI `libnode.dll.a`를 사용한다. `bridge.cc`를
  MinGW g++로 컴파일하므로 MSVC import lib는 의도적으로 Node enable 조건에서 제외한다.

**대안 검토 (채택하지 않음)**:
- NAPI: Node가 Zig를 로드하는 반대 구조. 구현 쉽지만 `node main.js`로 실행해야 하고 유저 PC에 Node 설치 필요. Zig가 프로세스 주인이 아니게 됨.
- Unix 소켓: POC에서 검증 완료. 가능하지만 별도 프로세스라 임베드가 아님.

- [x] libnode 빌드 인프라 (CI에서 빌드, 프리빌트 배포)
- [x] Zig에서 libnode 링킹 (`@cImport` + node_api.h)
- [x] Node 환경 초기화/해제
- [x] Zig에서 Node 환경에 Suji API 주입 (handle/invoke/invokeSync/send/register)
- [x] Node.js 크로스 호출 (invoke async + invokeSync + thread pool + deadlock 방지)
- [x] Node.js 이벤트 발신 (suji.send)
- [x] Node.js 이벤트 수신 (suji.on/once/off)
- [x] Node.js 예제 (node-backend 단독 + multi-backend 포함)
- [x] Node.js SDK 패키지 — `@suji/node` (`packages/suji-node`, TypeScript, require 기반)
- [x] `suji run main.js` CLI — CEF/window 없이 libnode embed로 JS 파일 직접 실행.
      `@suji/node`의 `platform()/quit()` bridge까지 headless core에 연결.
      단위: `nodeRunEntryCandidate` 파일/디렉터리 해석. E2E:
      `tests/e2e/run-node-run.sh` + GitHub Actions macOS. Linux/Windows direct-run은
      libnode C++ ABI/런타임 패키징 정리 후 별도 활성화.
- [ ] Node 바이너리 번들링 (배포 시)
- [ ] Electron 마이그레이션 가이드

**결과물**:
```bash
suji run main.js  # Node 설치 없이 실행 가능
```
```js
const { app, BrowserWindow } = require("suji");

app.on("ready", () => {
  const win = new BrowserWindow({ width: 800, height: 600 });
  win.loadFile("index.html");
});
```

---

### Phase 5.5 (백로그): 추가 임베드 런타임 (Python / Lua)

**목표**: Node 임베드와 같은 패턴으로 Python/Lua 인터프리터를 프로세스 내에 임베드. 사용자 앱이 추가 바이너리 설치 없이 해당 언어로 백엔드/플러그인 작성 가능.

**동기**:
- Python: 데이터사이언스/AI 라이브러리(numpy, pandas, torch) 활용 수요
- Lua: 초경량 임베드 언어 — 설정 스크립트, 플러그인 DSL, 게임/에디터 확장용

**선행 작업 (아키텍처 일반화)**:

**✅ 완료** — `src/backends/loader.zig`에 일반화 구현됨(아래 항목 stale 였어 정정).

- [x] `EmbedRuntime` struct 도입 (`loader.zig:31`)
- [x] `BackendRegistry.embed_runtimes: std.StringHashMap(EmbedRuntime)` 필드 (`loader.zig:173`, `registerEmbedRuntime` `:177`) — "node" 등 이름 등록
- [x] `coreInvoke`(invoke) 가 native 실패 시 `embed_runtimes.get(name)` 제너릭 폴백 (`loader.zig:412`) — Node 전용 하드코딩 if 없음
- [x] Node 는 `registerEmbedRuntime("node", ...)` 로 주입(이관 완료) — CLAUDE.md 구현 노트와 일치

**Python 임베드**:

- [ ] libpython 빌드/다운로드 인프라 (macOS: python.org 프리빌트, Linux: apt `libpython3-dev`, Windows: Python installer)
- [ ] `src/platform/python.zig` + `src/platform/python/bridge.cc` — `Py_Initialize`, `PyObject_CallObject`, `PyGILState_Ensure/Release` (GIL 관리)
- [ ] JSON ↔ PyDict 변환 (Python stdlib `json` 활용)
- [ ] 재진입 패턴 (Node의 `g_in_sync_invoke` 대응) — GIL 하나라 같은 스레드 재귀와 본질적으로 동일
- [ ] `@suji/python` (pip 패키지)
  ```python
  import suji
  suji.handle('ping', lambda: {'msg': 'pong'})
  suji.handle('analyze', lambda data: {'mean': np.mean(data['values'])})
  ```
- [ ] 예제 (`examples/python-backend`, `examples/multi-backend`에 Python 추가)
- [ ] suji.json 설정: `{ "lang": "python", "entry": "backend/main.py" }`

**Lua 임베드**:

- [ ] Lua 런타임 빌드 (정적 링크 `liblua.a` 수백 KB, 또는 LuaJIT)
- [ ] `src/platform/lua.zig` — `luaL_newstate`, `lua_pcall`, `lua_tostring`, `cjson` 라이브러리 번들
- [ ] state 격리 (스레드마다 별도 `lua_State`)
- [ ] Lua 모듈 (`suji.lua`):
  ```lua
  local suji = require("suji")
  suji.handle("ping", function() return {msg = "pong"} end)
  suji.handle("greet", function(data) return {hello = data.name} end)
  ```
- [ ] 예제 (`examples/lua-backend`)
- [ ] suji.json 설정: `{ "lang": "lua", "entry": "backend/main.lua" }`

**언어별 특성 요약**:

| | Python | Lua | Node (참고) |
|---|---|---|---|
| 임베드 크기 | ~15MB | 수백 KB | ~60MB |
| 동시성 | GIL (단일 스레드) | 단일 스레드 + 코루틴 | libuv event loop |
| 패키지 매니저 | pip | LuaRocks | npm |
| JSON 지원 | stdlib | cjson 라이브러리 | 내장 |
| 재진입 패턴 | Node와 동일 (GIL 재귀) | 더 단순 (단일 스레드) | `g_in_sync_invoke` |
| 사용자 수요 | 높음 (AI/DS) | 중간 (DSL/확장) | 매우 높음 |

**구현 순서 권장**:
1. 선행 — `EmbedRuntime` 일반화 (반나절)
2. Lua 먼저 (더 가볍고 임베드 단순, 일반화 설계 검증용)
3. Python 이어서 (수요 높지만 GIL/배포 복잡도 큼)

**남은 설계 질문**:
- Python 패키지 매니저(pip) 자동 설치 방식 (현재 Node는 npm install을 `suji dev`가 호출)
- Lua 라이브러리 번들링 정책 (빌드 타임 vs 런타임 LuaRocks)
- SDK 배포: PyPI `suji` 패키지명 + `github.com/ohah/suji-lua` 모듈

---

### Phase 6 (선택): 멀티 백엔드

**목표**: 하나의 앱에서 여러 언어 백엔드 동시 사용

유스케이스: 고성능 작업은 Rust(tokio), 간단한 로직은 Node.js 등

```
Suji 코어 (Zig)
  ├── dlopen("libzig_backend.dylib")    ← Zig (exportApp)
  ├── dlopen("librust_backend.dylib")   ← Rust (tokio)
  ├── dlopen("libgo_backend.dylib")     ← Go (goroutine)
  ├── libnode 임베드 (Phase 5)           ← Node.js
  └── IPC 라우터 + EventBus
```

- [x] 멀티 백엔드 동시 로드 (Zig + Rust + Go 검증 완료)
- [x] IPC 라우터 (직접, 체인, 팬아웃, 코어 릴레이)
- [x] 백엔드 간 메시지 패싱 (Rust↔Go 크로스 호출 검증 완료)
- [x] 이벤트 루프 공존 (tokio + Go runtime + Zig, 충돌 없음)
- [x] Zig 백엔드도 dlopen (exportApp으로 C ABI 자동 생성)
- [x] Zig→Rust, Zig→Go 크로스 호출 (chain/fanout IPC 경유로 동작)
- [ ] 공유 상태 관리

**검증 결과**:
- 총 141개+ 테스트 (유닛 + 통합 + 스트레스 + CEF IPC)
- Zig + Rust(tokio) + Go(goroutine) 한 프로세스 동시 로드
- CHAOS 테스트: 20개 동시 호출 (직접+크로스+협업+팬아웃+체인)
- RAPID FIRE: 100개 동시 핑 (3개 백엔드)
- 시그널 충돌, 데드락, 크래시 없음

---

### Phase 7: CEF 전환 (webview.h → CEF 단일)

**목표**: webview.h를 CEF(Chromium)로 완전 교체. 3개 OS 모두 CEF 단일.

**동기**:
- 데스크톱 앱에서는 번들 크기(150MB)보다 **렌더링 일관성**이 중요
- OS별 WebView 차이(Safari WebKit vs Chrome vs GTK WebKit)로 프론트엔드 개발 경험 저하
- CEF 단일이면 구현/테스트/버그 수정 모두 **1벌** — OS별 분기 없음
- Windows WebView2도 Chromium이지만, CEF와 API가 달라 관리 포인트 2개 → CEF 통일로 1개
- CEF는 커스텀 프로토콜, DevTools, 메뉴, 다이얼로그, E2E 테스트(CDP) 등 대부분의 기능을 내장

**CEF 프리빌트 사용 (소스 빌드 아님)**:
```
CEF 프리빌트 (Spotify CDN에서 다운로드, ~120MB)
├── include/capi/*.h     ← Zig @cImport로 가져올 C API 헤더
├── Release/
│   ├── libcef.dylib     ← macOS
│   ├── libcef.so        ← Linux
│   └── libcef.dll       ← Windows
└── Resources/*.pak      ← Chromium 리소스
```

`suji build` 첫 실행 시 `~/.suji/cef/{platform}/` 에 자동 다운로드.

**3개 OS 동일 엔진**:
| OS | 엔진 | DevTools | E2E (CDP) | 렌더링 |
|---|---|---|---|---|
| macOS | CEF (Chromium) | ✅ | ✅ Playwright | 동일 |
| Windows | CEF (Chromium) | ✅ | ✅ Playwright | 동일 |
| Linux | CEF (Chromium) | ✅ | ✅ Playwright | 동일 |

**폴더 구조**:
```
src/
├── core/
│   ├── app.zig           # Zig SDK (변경 없음)
│   ├── config.zig        # 설정 파서 (변경 없음)
│   ├── events.zig        # EventBus (변경 없음)
│   └── ipc.zig           # IPC → CEF CefProcessMessage 기반으로 재구현
├── platform/
│   └── cef.zig           # CEF 통합 (창, WebView, IPC, 프로토콜)
├── backends/
│   └── loader.zig        # BackendRegistry (변경 없음)
└── main.zig              # CLI (CEF 초기화/종료 추가)
```

**CEF 멀티 프로세스 아키텍처**:

webview.h (현재, 단일 프로세스):
```
┌───────────────────────┐
│ 하나의 프로세스         │
│ Suji 코어 + WebView   │
│                       │
│ JS invoke("ping")     │
│  → 같은 프로세스 콜백   │
│  → 바로 응답           │
└───────────────────────┘
```

CEF (전환 후, 멀티 프로세스):
```
┌──────────────┐   CefProcessMessage   ┌──────────────────┐
│ 메인 프로세스  │ ◄═══════════════════► │ 렌더러 프로세스    │
│              │                       │                  │
│ Suji 코어    │                       │ V8 (JS 엔진)     │
│ 백엔드 관리   │                       │ window.__suji__  │
│ 창 관리      │                       │                  │
└──────────────┘                       └──────────────────┘
```

JS `invoke("ping")` 호출 시:
1. 렌더러 프로세스: V8 → CefV8Handler 실행
2. CefProcessMessage로 메인 프로세스에 전송
3. 메인 프로세스: 백엔드 invoke 실행
4. 결과를 CefProcessMessage로 렌더러에 반환
5. 렌더러: JS Promise resolve

webview.h에서 1줄이면 되는 IPC가, CEF에서는 프로세스 간 메시지 전달 + 요청-응답 매칭을 직접 구현해야 함. 이것이 핵심 난관.

**CEF가 제공하는 기능 (Phase 3 플러그인 다수를 대체)**:
| 기능 | CEF API | Phase 3 플러그인 |
|------|---------|-----------------|
| 커스텀 프로토콜 | `CefSchemeHandlerFactory` | 에셋 서버 대체 |
| DevTools | `CefBrowserHost::ShowDevTools` | - |
| 메뉴 | `cef_menu_model_capi.h` | menu 플러그인 대체 |
| 다이얼로그 | `cef_dialog_handler_capi.h` | dialog 플러그인 대체 |
| 키보드 단축키 | `cef_keyboard_handler_capi.h` | - |
| E2E 테스트 | CDP (port 9222) | - |
| 네트워크 가로채기 | `CefResourceRequestHandler` | - |
| 멀티 웹뷰 | 여러 `CefBrowser` 인스턴스 | window 플러그인 대체 |

**macOS 번들 구조**:
```
MyApp.app/
├── Contents/
│   ├── Info.plist
│   ├── MacOS/MyApp                              ← 메인 바이너리
│   ├── Frameworks/
│   │   ├── Chromium Embedded Framework.framework/ ← CEF (~120MB)
│   │   ├── MyApp Helper.app/                     ← 렌더러 프로세스
│   │   ├── MyApp Helper (GPU).app/               ← GPU 프로세스
│   │   ├── MyApp Helper (Renderer).app/
│   │   └── MyApp Helper (Plugin).app/
│   └── Resources/
│       ├── backends/                             ← dlopen 백엔드
│       ├── plugins/                              ← 플러그인
│       └── frontend/dist/                        ← 프론트엔드
```

**E2E 테스트**:
```zig
// CEF 초기화 시 리모트 디버깅 포트 열기
settings.remote_debugging_port = 9222;
```
```ts
// Playwright로 Suji 앱 E2E 테스트
const browser = await chromium.connectOverCDP('http://localhost:9222');
const page = browser.contexts()[0].pages()[0];
await page.click('button#save');
await expect(page.locator('#result')).toHaveText('saved');
```

**구현 순서**:
- [x] Step 1: POC — CEF 프리빌트 다운로드 + Zig @cImport + 창 띄우기 (위험 검증)
- [x] Step 2: CEF IPC 구현 (CefV8Handler + CefProcessMessage → invoke/on/send)
- [x] Step 3: 기존 ipc.zig를 CEF IPC로 교체 (main.zig에서 --cef 플래그로 BackendRegistry 연결)
- [x] Step 3.5: CEF 완성도 — JS Promise(JS 관리), EventBus→JS 연결, fanout/chain/core, 키보드 단축키(NSMenu Edit), 플러그인 경로 탐색, injection 방지
- [x] Step 5: DevTools 연동 — 인앱 DevTools (show_dev_tools + DEFAULT 스타일), Cmd+Shift+I 토글
- [x] Step 6: E2E 테스트 지원 (Puppeteer + CDP, `tests/e2e/cef-ipc.test.ts`)
- [x] Step 7: macOS 번들링 (Helper 프로세스 4개, Info.plist, 코드 서명) — `bundle_macos.zig`
- [x] Step 7.5: 커스텀 프로토콜 `suji://` (CefSchemeHandlerFactory, `"protocol": "suji"|"file"` 옵션, 기본 file)
- [x] Step 8: 크로스 플랫폼 빌드 (macOS + Linux + Windows CI, 조건부 컴파일, GTK/X11/Win32 링크)
- [x] Step 9: webview.h 완전 제거 (webview-zig, ipc.zig, window.zig, asset_server.zig 삭제, CEF 단일 경로)

Step 1에서 CEF가 Zig와 호환되는지 확인 — 안 되면 여기서 중단하고 webview.h 유지.
Step 2가 핵심 난관 (멀티 프로세스 IPC).
Step 9 이후 코드베이스에서 OS WebView 관련 코드 완전 제거.

**참고 프로젝트**:
- [cefcapi](https://github.com/cztomczak/cefcapi): CEF C API 예제 (메인+렌더러 프로세스 통신 포함)
- [Electrobun](https://github.com/blackboardsh/electrobun): CEF 통합 구현체 (Zig + ObjC + C++)
- [CEF 프리빌트](https://cef-builds.spotifycdn.com/index.html): Spotify CDN 배포

**다른 프레임워크와의 비교**:
- Electron: Chromium 소스를 직접 포크/빌드 (전담 팀 필요). Suji는 CEF 프리빌트 사용 (1인 가능).
- Tauri: wry(OS WebView)에 깊이 결합, CEF 전환 수천 시간 투자했으나 미완. Suji는 처음부터 CEF 단일.
- Electrobun: OS WebView + CEF 듀얼 지원. Suji는 CEF 단일로 유지보수 절감.

---

## 사용자 프로젝트 구조

원칙: **각 언어의 관습을 따르되, frontend/ 폴더와 suji.json만 통일**

### 단일 백엔드

```
Rust 백엔드:                 Go 백엔드:
  my-app/                      my-app/
  ├── Cargo.toml               ├── go.mod
  ├── src/lib.rs               ├── main.go
  ├── frontend/                ├── frontend/
  │   ├── index.html           │   ├── index.html
  │   └── package.json         │   └── package.json
  └── suji.json                └── suji.json

Zig 백엔드:                  Node 백엔드:
  my-app/                      my-app/
  ├── build.zig                ├── package.json
  ├── build.zig.zon            ├── main.js
  ├── src/main.zig             ├── frontend/
  ├── frontend/                │   ├── index.html
  │   ├── index.html           │   └── package.json
  │   └── package.json         └── suji.json
  └── suji.json
```

### 멀티 백엔드 (Rust + Go 동시 사용 등)

```
my-app/
├── backends/
│   ├── rust/                ← Rust 프로젝트
│   │   ├── Cargo.toml
│   │   └── src/lib.rs
│   └── go/                  ← Go 프로젝트
│       ├── go.mod
│       └── main.go
├── frontend/                ← 프론트엔드 (공통)
│   ├── index.html
│   ├── package.json
│   └── src/
└── suji.json
```

### suji.json (설정 파일)

단일 백엔드:
```json
{
  "app": { "name": "My App", "version": "0.1.0" },
  "window": { "title": "My App", "width": 800, "height": 600, "debug": true },
  "backend": { "lang": "rust", "entry": "." },
  "frontend": { "dir": "frontend", "dev_url": "http://localhost:5173", "dist_dir": "frontend/dist" }
}
```

멀티 백엔드:
```json
{
  "app": { "name": "My App", "version": "0.1.0" },
  "window": { "title": "My App", "width": 900, "height": 600, "debug": true },
  "backends": [
    { "name": "rust", "lang": "rust", "entry": "backends/rust" },
    { "name": "go", "lang": "go", "entry": "backends/go" }
  ],
  "frontend": { "dir": "frontend", "dev_url": "http://localhost:5173", "dist_dir": "frontend/dist" }
}
```

**백로그**: TOML 지원 (적합한 zig-toml 라이브러리가 array of tables 지원 시 추가 예정)

---

## 기술 결정 사항

1. **OS WebView 우선, CEF는 나중에** — CEF부터 하면 앱 만들기 전에 지침
2. **Zig 전용으로 먼저 완성** — 처음부터 모든 언어 SDK 만들면 어느 것도 안 됨
3. **Node는 libnode 임베드** — stdout/WebSocket 방식은 네이티브 느낌 안 남
4. **Bun은 지원 안 함** — 임베드용 라이브러리(libbun) 미제공
5. **언어별 SDK는 수요 보고 추가** — C ABI만으로는 DX가 부족
6. **webview.h로 시작** — 직접 OS API 래핑보다 빠르게 프로토타입 가능

---

## Zig가 코어로 적합한 이유

| 강점 | 설명 |
|------|------|
| C interop | `@cImport` 한 줄로 C 헤더 임포트 |
| 크로스컴파일 | `zig build -Dtarget=...` 한 줄 |
| 바이너리 크기 | 코어 수백 KB 가능 |
| dlopen | `std.DynLib` 기본 제공 |
| GC 없음 | 일관된 성능, IPC 지연 없음 |
| 빌드 속도 | Rust 대비 빠름 |

---

## 배포 (TODO)

### Suji 프레임워크 배포

**Zig 패키지** (Zig 백엔드 사용자용) — ✅ **소비성 검증됨**
(`tests/zig-consumer` 하니스 + ci.yml embed-lib 잡이 회귀 가드):
```zig
// 사용자 build.zig.zon
.dependencies = .{
    .suji = .{
        .url = "https://github.com/ohah/suji/archive/refs/tags/v0.1.0.tar.gz",
        .hash = "...",
    },
},
```
```zig
// 사용자 build.zig
const suji = b.dependency("suji", .{});
lib.root_module.addImport("suji", suji.module("suji"));
```
`build.zig` 가 `b.addModule("suji", src/core/app.zig)` + 모듈 그래프
(events→{util,runtime})를 export, `build.zig.zon .paths` 가 `src`
포함 → 외부 프로젝트에서 위 패턴으로 바로 소비(로컬 실증 + CI 가드).

**Rust crate** (Rust 백엔드 사용자용):
```toml
# crates.io에 배포 후
[dependencies]
suji = "0.1"
```

**Go module** (Go 백엔드 사용자용):
```
# GitHub에서 직접
go get github.com/ohah/suji-go
```

**Suji CLI 바이너리**:
- GitHub Releases: 플랫폼별 바이너리 (macOS arm64/x86_64, Linux, Windows)
- brew: `brew install suji`
- npm: `npm install -g @suji/cli`
- curl: `curl -fsSL https://github.com/ohah/suji/releases/latest/download/install.sh | sh`

### 앱 배포 (suji build)
```
suji build → 결과물:
  dist/
  ├── suji (코어 바이너리)
  ├── backends/
  │   └── libbackend.dylib (빌드된 백엔드)
  └── frontend/
      └── dist/ (빌드된 React)
```
- macOS: .app 번들 (Code Sign + Notarize)
- Windows: .msi 인스톨러
- Linux: tar.gz + 선택적 .deb(`suji build --deb`) + 선택적 AppImage(`suji build --appimage`)

---

## Electron / Tauri 대비 부족한 기능

현재 Suji는 IPC + EventBus + 멀티 백엔드(Phase 2, 4, 6)가 동작하지만, 실제 앱을 만들어 배포하려면 아래 기능들이 필요하다.

### 네이티브 데스크톱 API

| 기능 | Electron | Tauri | Suji |
|------|----------|-------|------|
| 파일 시스템 API | `fs` 모듈 | `fs` 플러그인 | ✅ Phase 5-F. 텍스트 read/write + stat(mtime ms)/mkdir/readdir/rm + 5 SDK 노출 |
| 시스템 다이얼로그 (open/save/messageBox/errorBox) | `dialog` | `dialog` 플러그인 | ✅ Phase 5-A. macOS NSAlert/NSOpenPanel/NSSavePanel + sheet modal, Linux GTK3, Windows TaskDialog/commdlg + 5 SDK 노출 |
| 트레이 아이콘 | `Tray` | `tray-icon` | ✅ Phase 5-B. macOS NSStatusItem + Linux GTK StatusIcon + Windows Shell_NotifyIconW + 컨텍스트 메뉴 + click 이벤트. macOS/Linux `iconPath` + submenu/checkbox/enabled 지원 |
| 메뉴바 | `Menu` | `menu` | ✅ Phase 5-D. macOS NSMenu + Linux GTK `Menu.popup` + submenu/item/checkbox/separator + click 이벤트 |
| 알림 (Notification) | `Notification` | `notification` | ✅ Phase 5-C macOS UNUserNotificationCenter + Linux freedesktop D-Bus + Windows Shell_NotifyIcon balloon |
| 글로벌 단축키 | `globalShortcut` | `global-shortcut` | ✅ Phase 5-E. macOS Carbon Hot Key + Linux X11 XGrabKey + Windows RegisterHotKey + 5 SDK + accelerator 파싱 |
| 창 이벤트 (resize/close/focus/blur) | `BrowserWindow` 이벤트 | `Window` 이벤트 | ✅ Phase 5. close/closed/all-closed/resized/moved/focus/blur (macOS NSWindowDelegate) |
| 멀티 윈도우 | `new BrowserWindow()` | `WebviewWindow` | ✅ `windows.create()` + Phase 3 외형 옵션 풀 셋 (frame/transparent/parent) |
| 핫 리로드 | webpack HMR | Vite HMR + 백엔드 감시 | ✅ (dylib 재로드 + Vite HMR) |

### 보안

| 기능 | Electron | Tauri | Suji |
|------|----------|-------|------|
| **fs sandbox (frontend path 화이트리스트)** | `webPreferences.sandbox` + nodeIntegration:false | allowlist | ✅ `fs.allowedRoots` config + `..` traversal 가드 + boundary check + backend bypass. 렌더러-제어 경로 cmd(쓰기: print_to_pdf/capture_page/desktop_capturer_capture_thumbnail · 읽기: native_image_get_size/to_png|jpeg = 파일내용 base64 유출 · tray_create.iconPath)도 `rendererPathFsGate`로 동일 경계 게이트(opt-in 비파괴 — allowedRoots 설정 시 fs 읽기/쓰기/이미지 로드 우회 차단). 보안 점검 후속 보완 |
| **앱별 cache 격리** | `app.getPath('userData')` | 자동 | ✅ OS 표준 (macOS Application Support / Linux XDG / Windows APPDATA) — 앱 이름별 자동 격리 |
| 권한 시스템 (API 접근 제어) | contextBridge/sandbox | allowlist + CSP | 🟡 fs(default-deny) + **shell/dialog allowlist**(opt-in — `shell.allowedPaths`/`allowedExternalUrls`(glob, util.matchGlob 재사용)/`dialog.allowedPaths`. 키 부재=레거시 무제한 비파괴, 존재=enforce(`[]`=deny-all/`["*"]`=allow/특정=제한). backend SDK 우회·`..`/boundary 가드 fs 동형. 단위 포괄(opt-in/deny-all/glob/boundary/traversal/backend-bypass)). network(webRequest setter)는 그 자체가 선언적 net-control이라 데이터 유출 sink 아님 → 범위 제외(정직). **모바일(Tauri 패리티) 완료**: Stage 1 = embed C ABI `suji_core_set_permissions`/`suji_core_permission_check`(게이트 로직 `util.*` CEF-free 단일 출처, Swift/Kotlin glob 재구현 0, uniform opt-in, null fail-closed). Stage 2 = iOS `_shared` Swift + Android `_shared` Kotlin/JNI 가 네이티브 shell/fs 액션 직전 C ABI 호출 + init 시 앱 컨테이너 정책 전달(보안 로직 0, JSON 직렬화로 escape 안전). dialog 는 모바일=OS 문서 피커(사용자 중재)라 미게이트(데드 config 회피). **검증: iOS 실 시뮬레이터 + Android 실 에뮬레이터 기능 e2e 양쪽 37/37(권한 5케이스 — allowed fs→success, denied fs read/write→forbidden, denied url→forbidden, allowed url→not forbidden — 정책이 네이티브 액션 전 실제 enforce 됨을 격리 검증)** + Zig-side embed_abi 종합 + iOS/Android 크로스빌드 + 모바일 하니스 62/62 무회귀 |
| CSP (Content Security Policy) | 수동 설정 | 빌트인 | ✅ `suji://` 응답에 default CSP + X-Content-Type-Options + X-Frame-Options. `config.security.csp` override + `"disabled"` escape |
| IPC 유효성 검사 | preload 격리 | 커맨드별 타입 검증 | ✅ payload size 32KB · cmd char allowlist (injection 차단) · missing/invalid/unknown_cmd 표준 에러 |
| macOS App Sandbox (App Store 진출) | electron-osx-sign | tauri.conf.json | ✅ `suji build --sandbox` — helper별 entitlements 자동 부착 (main / Browser / GPU / Renderer / Plugin). 루트=non-sandbox(Developer ID, Hardened Runtime 기본) / `sandbox/`=App Sandbox+inherit(MAS). signing 모드와 직교. Security-scoped bookmarks API ✅ (다음 행) |
| Security-scoped bookmarks (sandbox 영속 권한) | `app.startAccessing...` | -- | ✅ `app.createSecurityScopedBookmark(path)` + `start/stopAccessingSecurityScopedResource`. NSURL bookmarkDataWithOptions(WithSecurityScope) → base64, URLByResolvingBookmarkData → accessId 풀(32) retain/release. Electron stop 클로저 대신 opaque accessId+stop cmd(IPC 모델). 4 SDK + e2e 8(create round-trip/resolve path/start·stop lifecycle/이중해제 가드/에러 분기) + sandbox/main.plist `files.bookmarks.app-scope` entitlement. ⚠️ 비-sandbox(기본)에선 일반 bookmark — API round-trip은 실증되나 sandbox escapement 실효는 MAS 환경 필요 = 로컬 미검증 |
| iframe sandbox / origin allowlist | CSP `frame-src` 수동 + `<webview>` partition | `tauri.conf.json` `app.security.csp` | ✅ `security.iframeAllowedOrigins` config — CSP frame-src 자동 합성. default block (`'none'`) + `["*"]` escape |
| contextBridge / preload script | preload로 Node API isolation | -- | N/A — Suji는 frontend에 Node API 자체 미노출 (V8 binding이 `__suji__.{invoke,emit}` 2개만 + JS helper). Electron의 isolation 목적은 Node integration 격리인데 Suji는 처음부터 격리됨 |
| `<webview>` tag (격리된 sub-content) | `<webview>` (별도 process 격리) + `WebContentsView` (한 창 multi-content 합성) | `WebviewWindow` (별도 창만 — 한 창 합성 X) | ✅ 별도 창은 `windows.create({url})` ✅. 한 창 multi-content 합성은 `windows.createView` Phase 17-B CEF Views 경로로 macOS/Linux/Windows 기본 지원. dynamic `destroyView` 후 child target cleanup/host 생존/recreate E2E 검증 완료. Linux/Windows overlay child view도 GitHub Actions runtime E2E로 검증 완료 |
| webRequest 인터셉트 | `session.webRequest.onBeforeRequest` | -- | ✅ declarative URL glob blocklist (`webRequest.setBlockedUrls(patterns)` — `*` wildcard, 32개 max) + dynamic listener (RV_CONTINUE_ASYNC + pending callback storage) — `webRequest.onBeforeRequest({urls}, listener)`로 cancel/allow round-trip. 5 SDK 노출 + e2e 13 케이스 (cancel/allow round-trip 포함). **timeout fallback**: JS SDK `webRequest.onBeforeRequest` 가 listener 미응답/동기 throw 시 `options.timeoutMs`(기본 5000, ≤0=opt-out) 후 자동 통과(fail-open) — 네이티브 RV_CONTINUE_ASYNC hold 해제, 영구 hang 방지(cookie SDK 타임아웃 선례 동형, mock-bridge 단위 6 케이스). 네이티브측은 단일스레드·무 CEF-task 라 설계상 hold 유지(SDK 가 caller 책임 이행) |
| safeStorage (OS secure store) | `safeStorage.encryptString` | -- | ✅ macOS Keychain + Linux libsecret/Secret Service + Windows Credential Manager(`safe_storage_set/get/delete`) 완료. Windows는 Credential Manager의 DPAPI-backed generic credential 저장소 사용. Linux는 libsecret simple API + gnome-keyring CI E2E |

### 앱 배포 & 패키징

| 기능 | Electron | Tauri | Suji |
|------|----------|-------|------|
| macOS .app 번들 | electron-builder | `tauri build` | ✅ (`bundle_macos.zig`, Helper 4개, Info.plist) |
| Windows .msi/.exe | electron-builder | `tauri build` | ❌ |
| Linux .deb/.AppImage | electron-builder | `tauri build` | ✅ `.deb` 구현(`suji build --deb`/`SUJI_DEB`, `/opt/<package>` + `.desktop`, Debian control/data ar archive) + AppImage 구현(`suji build --appimage`/`SUJI_APPIMAGE`, `SUJI_APPIMAGETOOL` 지원, AppDir/usr/bin + resources/frontend). 유닛 + Linux Actions E2E로 `.deb` control/data와 `.AppImage` 생성/추출 검증 |
| 코드 서명 & 공증 | electron-notarize | 빌트인 | ✅ codesign(none/adhoc/identity)+`notarytool`+stapler+DMG 구현(`bundle_macos.zig`), Win signtool(`package_desktop.zig`). `suji build --sign/--identity/--notarize/--dmg`. **adhoc 로컬 실증**(codesign --verify --deep --strict exit=0·Designated Req 만족·helper entitlements 부착·spctl 은 adhoc 이라 reject=정직 경계). identity/notarize/signtool 은 자격증명·Win 환경 필요로 미검증(CI secret 시) |
| 자동 업데이트 | autoUpdater | `updater` 플러그인 | 🟡 1차 — manifest 기반 update check + semver 비교 + native artifact download + SHA-256 검증 + 포맷별 install 준비(`auto_updater_prepare_install`: macOS `.zip/.dmg`→`.app` stage, Windows `.zip`→PowerShell `Expand-Archive` stage, Linux `.AppImage`/raw 교체 입력, `.deb` system package handoff) + macOS/Linux shell helper와 Windows PowerShell quit-and-install helper 구현. Frontend/Node/Zig SDK + 유닛 + system-integration E2E + 실제 prepare→quit-and-install E2E(macOS `.zip`, Linux `.AppImage`, helper cleanup 포함). Windows 실제 교체 E2E는 프로세스 종료/파일 잠금 경계로 후속 |
| GitHub Releases CI 자동 빌드 | 사용자 직접 | 공식 actions | ✅ `.github/workflows/release.yml` — `v*.*.*` 태그 정식 릴리스 + `workflow_dispatch dry_run=true` 검증 모드. macOS/Linux/Windows CLI 패키지 + checksums + embed core libs 크로스빌드 아티팩트, 태그↔`build.zig.zon` 버전 일치 검증, release publish gate. 유닛(`release_workflow_test.zig`) + E2E(`run-release-workflow.sh`)로 workflow 계약 고정 |
| Homebrew tap | 사용자 직접 | -- | ✅ `release.yml` `homebrew` job — 릴리스 아티팩트 checksum으로 `Formula/suji.rb` 생성 + `ruby -c` 검증 + `homebrew-formula` artifact 업로드. 정식 릴리스 시 `HOMEBREW_TAP_TOKEN`/`HOMEBREW_TAP_REPO` 있으면 외부 tap repo push, 없으면 경고 후 skip. 유닛(`release_workflow_test.zig`) + E2E(`run-release-workflow.sh`)로 Formula 계약 고정 |
| curl installer | 직접 다운로드 | -- | ✅ `scripts/install.sh` — 최신/특정 버전 GitHub Release asset 다운로드 + `.sha256` 검증 + 기본 `~/.suji/bin` 설치. release job이 `dist/install.sh`에 포함. macOS arm64/Linux x64 tar.gz + Windows x64 zip 매핑. 유닛(`release_workflow_test.zig`) + E2E(fake release archive 설치/체크섬 mismatch)로 계약 고정 |
| `npx @suji/cli` | -- | `create-tauri-app` | ✅ `packages/suji-cli`(의존 0 순수 Node, suji 바이너리/Releases 불요) — `npx @suji/cli init <name> [--backend=zig\|rust\|go\|multi] [--frontend=react\|vue\|svelte\|solid\|preact\|vanilla]`(create-suji 별칭). 산출물 `init.zig` 동형(templates 사본, 단일출처=init.zig lockstep — `--frontend` 도 양쪽 반영) + `.github/workflows/suji.yml` 생성 앱 CI 템플릿. 로컬 실증: npm pack→npx zig/rust/go/multi + frontend 분기 + 에러케이스, `suji init`/`@suji/cli` 산출 workflow + frontend build E2E. npm publish 는 토큰 대기(워크플로 후속) |

### 플러그인 / 확장 API

| 기능 | Electron | Tauri | Suji |
|------|----------|-------|------|
| 중앙 상태 스토어 | Redux 등 자유 | Tauri state 관리 | ✅ (`plugins/state`, 첫 공식 플러그인) |
| 클립보드 | `clipboard` | `clipboard-manager` | ✅ Phase 5-A. macOS NSPasteboard + Linux GTK clipboard text/HTML + Windows CF_UNICODETEXT/CF_HTML. 4 SDK + macOS E2E 37 케이스 + Linux Xvfb + Windows text/HTML E2E |
| 메뉴바 | `Menu` | `menu` | ✅ Phase 5-D. macOS NSMenu + Linux GTK popup + 5 SDK + E2E |
| 파일 시스템 | `fs` | `fs` 플러그인 | ✅ Phase 5-F. Zig std.fs 기반 텍스트 read/write + metadata/list/rm |
| 글로벌 단축키 | `globalShortcut` | `global-shortcut` | ✅ Phase 5-E. macOS Carbon Hot Key + Linux X11 XGrabKey + Windows RegisterHotKey + 5 SDK |
| 알림 (Notification) | `Notification` | `notification` | ✅ Phase 5-C macOS UNUserNotificationCenter + Linux freedesktop D-Bus + Windows Shell_NotifyIcon balloon |
| 셸 명령 실행 — 외부 핸들러 | `shell.openExternal` | `shell` 플러그인 | ✅ Phase 5-A. macOS NSWorkspace + Linux GIO default URI handler + Windows ShellExecuteW + scheme 사전 검사 + 5 SDK + Linux x-scheme-handler E2E |
| 셸 명령 실행 — child_process | `child_process.spawn` | `shell.Command` | 🟡 백엔드 only — `suji.process.run(allocator, io, argv)` (std.process.run wrap). Frontend 미노출 (보안) |
| HTTP 클라이언트 | Node `fetch` | `http` 플러그인 | ✅ `@suji/plugin-http` — renderer-safe fetch with URL allowlist(deny-by-default), Zig backend + JS/Node wrapper + 단위 테스트. 백엔드 전용 `suji.http.fetch(allocator, io, url, payload?)`도 유지 |
| 로컬 DB (SQLite 등) | better-sqlite3 | `sql` 플러그인 | ✅ `plugins/sqlite` (두 번째 공식 플러그인). 벤더 SQLite 3.51.0 amalgamation(public domain, 결정론적 크로스플랫폼) + `sql:open/execute/query/close`, positional `?` 파라미터(injection-safe), dbId 레지스트리+뮤텍스. Zig 코어 + Rust/Go/JS/Node 래퍼(state 동형 — js=`@suji/plugin-sqlite`/Node=`@suji/plugin-sqlite-node`, 각 mock 브릿지 bun 테스트 js 12·node 16. malformed 응답 하드닝 4언어 일관: `open`=명시 throw(dbId 날조 불가)·`query`/`close`=graceful(`r?.rows ?? []`, Rust None·state.keys 동형)). `zig build test-sqlite` 10 테스트(round-trip/주입안전/타입 INT·REAL·TEXT·NULL/DB 격리/에러/close-후-재사용). **모바일도 지원** — `examples/ios/backends/sqlite/`(정적 링크, 코어독립, 응답 데스크탑 바이트 동형 → 동일 래퍼 무수정). 호스트 하니스 62/62(실 sqlite3 CRUD 모바일 경로) + iOS/Android 크로스 컴파일 빌드 성공(실기기 런타임 미검증=기존 모바일 경계) |
| 딥링크 | `protocol.registerSchemesAsPrivileged` | `deep-link` | ✅ `suji.json app.deepLinkSchemes:["myapp"]` → bundle_macos 가 `.app` Info.plist `CFBundleURLTypes` 자동 주입(scheme 당 dict, identifier-prefixed URLName). isValidUrlScheme(RFC 3986 — ALPHA 시작 [A-Za-z0-9+.-])로 무효 skip(XML 주입 차단). writeInfoPlist→buildInfoPlist 순수 분리. 검증: 실 `suji build` adhoc → `plutil -lint` OK + CFBundleURLTypes 에 유효 2/무효 1 skip 실증 + 단위 회귀. ⚠️ OS 레벨 *라우팅 실동작*(Launch Services)은 설치+등록 필요 = 헤드리스 미검증, plist 선언만 |
| 스플래시 스크린 | BrowserWindow 조합 | `splashscreen` | ✅ 별도 API 없이 `windows.create` + `is_loading` polling + close 조합으로 표현. e2e 검증 (`tests/e2e/run-splash.sh`) |
| 클립보드 — 이미지/HTML/format 검사 | `clipboard.readImage` / `writeImage` / `readHTML` / `has` / `availableFormats` | -- | ✅ HTML (`readHTML`/`writeHTML`) + format 검사 (`has`/`availableFormats`) + PNG image (`writeImage(base64)` / `readImage()` — NSPasteboard `public.png`, raw 한도 ~8KB 1차) + TIFF (`writeTiff`/`readTiff` — `public.tiff`, PNG 동형, 5 SDK + e2e 3) + RTF (`readRtf`/`writeRtf` — `public.rtf`) |
| `shell.openPath` (파일 기본 앱으로) | `shell.openPath(path)` | `opener` | ✅ macOS NSWorkspace `openURL:` + Linux GIO file URI default handler + Windows ShellExecuteW — `shell_open_path` IPC, 존재 검증 + 5 SDK + e2e 2 + Linux MIME handler E2E |
| Programmatic context menu | `Menu.popup({window?, x?, y?})` | `menu.popup` | ✅ `menu_popup`(cef.zig `popupContextMenu` — macOS NSMenu `popUpMenuPositioningItem:atLocation:inView:`, Linux GTK `GtkMenu`; x/y 둘 다 지정 시 화면좌표, 미지정 시 커서/GTK 기본 포인터 위치). items 파싱·`menu:click` emit 은 `setApplicationMenu` 와 동일 parser를 재사용. 프론트 `menu.popup(items,{x?,y?})`. macOS popup은 동기 모달이라 정상 popup 자동 클릭 불가, Linux는 runtime E2E에서 정상 응답 검증 |
| 사용자 정의 protocol 풀 셋 | `protocol.handle(scheme, handler)` | -- | 🟡 same-origin 정적 서빙은 `protocol:"suji"` 가 이미 충족(앱이 `suji://app/` 에서 로드 + dist factory 서빙, 프로덕션 검증). **임의 cross-origin 동적 핸들러는 보류** — 아래 "protocol.handle 보류 사유" 참조 |
| Session 쿠키/스토리지 관리 | `session.cookies.get/set/remove` / `clearStorageData` / `clearCache` | -- | ✅ `session.clearCookies` / `flushStore` / `setCookie` / `getCookies` / `removeCookies` — CEF cookie_manager + visitor 패턴 (`session:cookies-result` 이벤트 + requestId 매칭, race-safe pending buffer + 1초 timeout). 5 SDK 노출 + e2e 8 케이스 (set/get round-trip, httponly 필터, removeCookies, includeHttpOnly:false, URL 검증, SDK wrapper). cookies 0개 case는 visit fn 호출 안 돼 SDK timeout으로 빈 결과 (Electron 동등 동작). ✅ `clearStorageData(origin?, storageTypes?)` — CDP `Storage.clearDataForOrigin` + `Network.clearBrowserCache` fire-and-forget(clearCookies 동형, g_browser send_dev_tools_message 재사용). 5 SDK 노출 + e2e 3(무-origin/origin+types/escape-safe). origin 미지정 시 현재 문서 origin 자동 해석(`getMainFrameUrl`→`util.originFromUrl`, scheme://authority 추출; file://=불투명 best-effort)으로 **앱 자기 storage** 삭제 + 전역 HTTP 캐시. ⚠️ 진짜 제약: IndexedDB/localStorage 는 origin-scoped 라 전 origin 프로필-전역 wipe 는 CDP(per-origin `clearDataForOrigin`) 구조상 단일 호출 불가 — about:/data: 등 origin 해석불가 시 캐시만(Electron 무인자 전역 wipe 와 다른 한계). |

### 시스템 통합 (Electron `app` / `power*` / `screen` / `desktopCapturer` 등)

| 기능 | Electron | Tauri | Suji |
|------|----------|-------|------|
| 디스플레이 정보 | `screen.getAllDisplays` / `getPrimaryDisplay` | -- | ✅ macOS NSScreen + Linux X11 screen — `screen_get_all_displays` IPC, frame/visibleFrame/scaleFactor + isPrimary. macOS system-integration + Linux Xvfb runtime E2E(`tests/e2e/run-screen-runtime.sh`) + `screen_model` 단위 회귀. Windows Win32 경로는 기존 유지(이번 범위 검증 제외) |
| 전원 모니터 (suspend/resume/lock) | `powerMonitor` 이벤트 | `os-info` 플러그인 부분 | ✅ macOS/Linux/Windows — `power:suspend` / `power:resume` / `power:lock-screen` / `power:unlock-screen` 4 채널 자동 발신. macOS NSWorkspace, Linux logind `PrepareForSleep` + ScreenSaver DBus `ActiveChanged`, Windows `WM_POWERBROADCAST` + WTS session lock/unlock. CI는 실제 suspend/lock 강제 불가라 동일 native callback 경로를 `SUJI_E2E_POWER_MONITOR_TEST_HOOK`로 E2E 검증 + 플랫폼 bridge source/링크 회귀로 고정 |
| 슬립 차단 | `powerSaveBlocker.start` | -- | ✅ macOS/Linux/Windows — `power_save_blocker_start/stop` IPC, prevent_app_suspension / prevent_display_sleep + idempotent guard. macOS IOPMAssertion, Linux XScreenSaverSuspend(live X11 display connection), Windows Power Request API. Linux/Windows runtime E2E 추가 |
| 데스크톱 캡처 (스크린샷/녹화) | `desktopCapturer.getSources` | -- | 🟡 `desktopCapturer.getSources({types})` ✅ — macOS CGGetActiveDisplayList(screen) + CGWindowListCopyWindowInfo(window, layer 0 + ExcludeDesktopElements). `{id,name,type,x,y,width,height,displayId?}`. 5 SDK + e2e 4(screen/window/types 필터/SDK round-trip) + 단위 회귀. CG 심볼 Cocoa/Carbon transitive. **썸네일**: `captureThumbnail(sourceId, path)` ✅ — getSources 의 base64 IPC 한도를 capture_page 동형 파일경로로 우회. 동기 CGDisplayCreateImage/CGWindowListCreateImage → ImageIO(CGImageDestination) PNG 인코딩(ImageIO linkFramework 추가). 5 SDK + IPC + source-grep 회귀 + JS/Node SDK 단위 + strict sourceId 파서 단위 + malformed/잘못된 suffix runtime E2E(false + 파일 미생성). ⚠️ **정직 경계(미검증)**: 실 캡처는 Screen Recording TCC 권한 필요 — 헤드리스/CI 는 CG\*CreateImage 가 null → graceful false. 따라서 zig build(컴파일/링크: ImageIO 심볼 해소 실증)+graceful-fail+source-grep 만 검증, **ImageIO 인코딩 경로는 권한 실기기에서만 실행 = 미실행·미검증**(F1~F3 검증격과 다름, 명시) |
| 크래시 리포터 | `crashReporter.start` | -- | 🟡 `crashReporter.start/getParameters/addExtraParameter/removeExtraParameter/getUploadToServer/setUploadToServer/getUploadedReports/getLastCrashReport` 1차. CEF `cef_crash_util_capi.h` 연동(`cef_crash_reporting_enabled`, `cef_set_crash_key_value`) + `app.crashReporter` startup config → `crash_reporter.cfg` 생성(macOS `.app` Resources, raw exe 옆). 5 SDK 노출 + 단위(cfg renderer/config parse/SDK request/source-grep/JS·Node false-path) + e2e runtime parameter/upload flag/report shape + validation(`submitURL_required`, invalid key, oversized value). `getUploadedReports/getLastCrashReport`는 로컬 Crashpad DB(`Crashpad/completed|pending/*.dmp`)를 실제 스캔하고 fake dump E2E로 고정. ⚠️ 정직 경계: 실제 crash 유발·upload 서버 round-trip은 CI에서 검증하지 않음. 첫 프로세스 reporter enable은 CEF initialize 전 cfg가 필요하므로 런타임 `start()`만으로는 현재 프로세스 Crashpad를 새로 켤 수 없음 |
| 인앱 결제 | `inAppPurchase` (Mac App Store) | -- | ❌ (분량 대 — App Store 의존) |
| Mac dock badge / app badge count | `app.dock.setBadge`, `app.setBadgeCount` | -- | ✅ macOS NSDockTile.setBadgeLabel — `dock_set_badge`/`dock_get_badge` IPC, set/get/clear/escape/멀티바이트(이모지+한글) round-trip + `app_set_badge_count`/`app_get_badge_count` Electron식 숫자 badge count(0/음수=clear, dock label sync). Linux/Windows native backend도 같은 IPC에 배선(아래 행). 5 SDK + e2e |
| dock 바운스 (사용자 주의 환기) | `app.requestUserAttention` | -- | ✅ macOS NSApp `requestUserAttention:` / `cancelUserAttentionRequest:` — `app_attention_request`/`app_attention_cancel` IPC, critical/informational + cancel guard 4 e2e (active app 시 id=0 lenient) |
| 표준 디렉토리 경로 | `app.getPath(name)` | `path` 플러그인 | ✅ Electron 표준 7 키 (home/appData/userData/temp/desktop/documents/downloads) — `app_get_path` IPC + `resolveAppDataDir` OS 분기 (macOS/Linux/Windows/fallback). `buildAppCachePath`와 분기 공유. 5 SDK + e2e |
| 휴지통 (trashItem) | `shell.trashItem` | `fs` 플러그인 | ✅ macOS NSFileManager + Linux GIO `g_file_trash` + Windows SHFileOperationW — `shell_trash_item` IPC, 임시 파일 trash + 비존재 경로 false e2e |
| 미디어 키 (재생/일시정지) | `globalShortcut`로 캡처 | -- | ✅ macOS — `globalShortcut.register("MediaPlayPause"\|"MediaNextTrack"\|"MediaPreviousTrack"\|"MediaStop", click)` Electron 토큰 패리티. Carbon RegisterEventHotKey 는 미디어키 미지원 → NSEvent `NSEventMaskSystemDefined` 글로벌+로컬 모니터로 분기(`media_key_for`/`media_event_dispatch`/`ensure_media_monitor`), 엔트리 `ref=NULL` sentinel + unregister NULL 가드. **신규 IPC/SDK 표면 0** — 기존 `global_shortcut_register` 로 토큰만 전달(5 SDK 무수정). ⚠️ 정직 경계: 글로벌 system-defined 키 실수신은 Accessibility(TCC) 신뢰 필요 → 헤드리스 미발화(globalShortcut 실 키 e2e 불가와 동급). 검증=parse/register/emit-wiring source-grep(`cef_ipc_test`) + IPC 패리티 단위(`app_test` MediaPlayPause) + 빌드(AppKit/NSEvent 링크). `MediaStop`=macOS HW transport 키 부재라 토큰 수용은 하나 실 HW 소스 없음 |
| 다크/라이트 테마 감지 + 강제 | `nativeTheme.shouldUseDarkColors` + `themeSource` setter + `updated` 이벤트 | `theme` 플러그인 | ✅ macOS — `shouldUseDarkColors()` + `setThemeSource("light"\|"dark"\|"system")` (NSAppearance setAppearance:) + `nativeTheme:updated` 이벤트 (NSApp.effectiveAppearance KVO observer). 5 SDK + e2e (setThemeSource light→dark 트리거 시 이벤트 round-trip 검증) |
| dock 진행률 표시 | `BrowserWindow.setProgressBar(0..1)` | -- | ✅ macOS NSDockTile.contentView NSProgressIndicator. progress<0=hide, 0~1=ratio, >1=clamp. 5 SDK + e2e |
| 마우스 위치 / 모니터 | `screen.getCursorScreenPoint` / `getDisplayNearestPoint` | -- | ✅ `screen.getCursorScreenPoint()` (macOS NSEvent.mouseLocation bottom-up, Linux XQueryPointer) + `getDisplayNearestPoint({x,y})` (`screen_model` frame contains check, none이면 -1). Linux Xvfb runtime E2E 추가 |
| 시스템 유휴 시간 | `powerMonitor.getSystemIdleState/Time` | -- | ✅ macOS/Linux/Windows `getSystemIdleTime()` + `getSystemIdleState(threshold)` → `"active"\|"idle"\|"locked"` (Electron 동등). macOS CGEventSource, Linux XScreenSaver, Windows GetLastInputInfo. lock-screen/unlock-screen 이벤트로 g_screen_locked atomic 추적 → 잠금 시 "locked" 우선, 아니면 idle_seconds ≥ threshold 비교. Linux/Windows runtime E2E 추가 |
| Linux/Windows tray 배지 | `app.setBadgeCount(n)` | -- | 🟡 native backend 배선 — Linux libunity `UnityLauncherEntry`(dlopen, 없으면 graceful native=false), Windows taskbar overlay icon `ITaskbarList3::SetOverlayIcon`(HWND별 best-effort). `app_set_badge_count` 응답에 `{native:bool}` 추가. CI 자동화는 visual taskbar 픽셀 검증 대신 Linux/Windows 런타임 E2E로 command success/state round-trip/native status shape를 고정 |
| 페이지 영역 캡처 | `BrowserWindow.capturePage(rect?)` | -- | ✅ `capturePage(rect?)` — CDP `Page.captureScreenshot` `params.clip{x,y,width,height,scale:1}`. rect 미지정=전체(기존 동작 무변). window.zig CaptureClip vtable 확장(test_native 포함). 4 SDK(JS/Node rect 옵션, Rust/Go 무회귀 별도 fn capture_page_rect/CapturePageRect) + 단위(clip native 전달) + e2e(clip PNG IHDR width < 전체, DPR 무관 실증) |
| nativeImage (아이콘 decode/encode) | `nativeImage.createFromPath` / `toPNG` | -- | ✅ `nativeImage.getSize(path)` + `toPng(path)` + `toJpeg(path, quality)` (NSImage → NSBitmapImageRep `representationUsingType:properties:`). raw bytes ~8KB 한도 (16KB IPC response). 5 SDK + e2e 3 케이스 (PNG/JPEG signature 검증) |
| 앱 강제 종료 | `app.exit(code)` | `process::exit` | ✅ `app.exit()` (Electron app.exit code 무시 — cef.quit 경유 process 종료). 5 SDK + e2e (IPC handler grep만 — 실제 호출은 process 종료라 e2e 불가) |

### 개발자 경험 (DX)

| 기능 | Electron | Tauri | Suji |
|------|----------|-------|------|
| DevTools | Chromium 내장 | WebView inspect | ✅ (인앱 DevTools, F12/Cmd+Shift+I 토글) |
| E2E 테스트 | Spectron/Playwright | - | ✅ (Puppeteer + CDP `tests/e2e/`, GitHub Actions e2e workflow macOS 자동 실행) |
| TypeScript 타입 자동 생성 | - | specta 연동 | ✅ 옵션 A+B 1차 완료 — `@suji/api` invoke<K> + `@suji/node` invoke/invokeSync/call/callSync 모두 SujiHandlers conditional generic으로 cmd/req/res 추론. Zig SDK는 comptime `typeToTs` + `App.schema` chain + `suji types` CLI(stdout/`--out`). Rust SDK는 specta v2 re-export (`#[derive(suji::Type)]`) + `suji::typescript::SujiHandlers` helper로 수동 등록한 req/res를 `.d.ts` module augmentation으로 emit. Go SDK는 `suji.NewTSHandlers()` + struct/json tag reflection helper로 동일 emit. 검증: app_test 골든 + 실 CLI 통합 + JS/Node type tests + Rust/Go SDK unit + Rust/Go/Node 외부 consumer E2E. Node 자동 생성은 런타임 타입메타 부재로 범위 밖 |
| 프론트엔드 프레임워크 템플릿 | - | create-tauri-app | ✅ `suji init --frontend=react\|vue\|svelte\|solid\|preact\|vanilla`(기본 react). **번들 Vite 템플릿**(Tauri식, create-vite 미위임 — `src/templates/frontend/<fw>/` 트리 comptime `@embedFile`; 누락 시 컴파일 실패=회귀 가드). 각 템플릿은 스캐폴딩 백엔드의 `ping`/`greet` 를 호출하는 동작 데모. `--backend` 대칭, `FrontendTemplate=std.meta.stringToEnum`. ⚠️ **정직 한계**: `@suji/api` npm 미발행 → 템플릿은 발행 불요 로컬 래퍼 `src/suji.ts`(런타임 `window.__suji__` 감쌈, @suji/api 와 표면 동형 — 발행 시 import 경로만 교체)로 동작. suji-cli(npx)는 `cpSync` 로 동일 트리 복사(lockstep). 검증=전 6 fw `bun install`+`bun run build`=0+dist 실증, 실 `suji init` E2E(zig+svelte 스캐폴딩→빌드), `tests/init_test.zig`(enum 구동 계약 + **suji-cli 미러 byte-동형 drift 가드** + 루트 템플릿 미러). 미검증=CEF 런타임 invoke 왕복(globalShortcut 동급 e2e 경계) |
| 플러그인 생태계 | npm 생태계 | 공식 플러그인 30+개 | 🟡 공식 6개(`state`, `sqlite`, `log`, `store`, `http`, `notification-rich`) + JS/Node wrapper 계약 테스트 |
| CI/CD 템플릿 | - | GitHub Actions 공식 제공 | ✅ `suji init` / `@suji/cli`가 `.github/workflows/suji.yml` 생성. 템플릿은 frontend `bun run build`, Zig backend fmt check, Rust/Go backend build를 포함하고, init.zig와 npm CLI 미러 byte-동형 단위 테스트 + init CLI E2E로 고정 |

### 바이너리 데이터 / 고급 기능

| 기능 | Electron | Tauri | Suji |
|------|----------|-------|------|
| 바이너리 IPC | Buffer 직접 전송 | `asset://` 커스텀 프로토콜 | ✅ `suji://` 커스텀 프로토콜 |
| 중앙 상태 스토어 | Redux 등 자유 | Tauri state 관리 | ✅ (`plugins/state`) |

### protocol.handle 보류 사유 (CEF cross-origin scheme-handler 결함)

Electron `protocol.handle(scheme, handler)`(임의 scheme 의 동적 백엔드
응답)는 **보류**. 시도 → 루트커즈 규명 후 코드 미커밋(revert)했다.

**실사용 매핑(언제 쓰나)**:
- ① 깨끗한 origin 에서 앱 로드(CORS/fetch/Cookie/SW/SPA 라우팅 정상) —
  **`protocol:"suji"` 가 이미 충족**(프로덕션 검증, same-origin).
- ② 번들 정적 자산 서빙 — `suji://` dist factory 가 이미 충족.
- ③ 동적 응답(요청마다 백엔드가 계산 — API/미디어 스트리밍/권한 게이팅) —
  **미제공.** 이게 진짜 `protocol.handle` 의 핵심이자 아래 결함 대상.

**루트커즈(확정, 이분탐색 + macOS .ips 네이티브 스택)**:
`cef_register_scheme_handler_factory` 로 등록한 커스텀 standard-scheme 에
대한 **cross-origin 요청**(예: dev 문서 `http://localhost:5173` →
`myscheme://...`)이면 **CEF IO 스레드(Chrome_IOThread) 내부에서
SIGSEGV**. 우리 Zig 0 프레임(Debug 빌드 Zig 패닉 0, faulting thread
전 프레임 `Chromium Embedded Framework`). 이분탐색으로 배제 확정:
async 무죄(sync 모드도 크래시)·서브프로세스 scheme-consistency
무죄(전 프로세스 하드코딩 등록도 크래시)·`LOCAL` 옵션 무죄(제거해도
크래시)·CDP vs 인페이지 네비 무관·fetch(서브리소스)도 동일 크래시.
핸들러 코드는 프로덕션 동작하는 `suji://` factory 와 byte-identical —
차이는 오직 **요청 origin ≠ scheme**(suji:// 는 문서 origin 자체가
suji:// 라 same-origin 이라 무사). ⟹ CEF 빌드 레벨 결함, 우리
Zig/SDK 레이어에서 수정 불가.

**대안 A(config scheme 이름 일반화) 도 보류한 이유**: same-origin
서빙 가치(①②)는 `protocol:"suji"` 가 이미 제공. A 가 더하는 건
"scheme 이름 커스터마이즈" 뿐인데, 비용이 (1) 서브프로세스 cmdline
전파(`cef_command_line_create_global` 바인딩 미검증) (2) **보안
민감 `DEFAULT_CSP_TEMPLATE` 의 `suji:` 5곳 런타임 동적 치환** (3)
리터럴/테스트 파라미터화 — 중간 규모·보안 민감 표면. 자율 유지보수
관점에서 가치 대비 비용·리스크 초과로 보류.

**재개 조건(후속)**: CEF 디버그 심볼 빌드로 cross-origin
scheme-handler IO-스레드 결함 규명(업스트림 수정/정확 API 사용 확인)
+ `cef_command_line` C 바인딩 확인. 그 전까지 same-origin 용도는
`protocol:"suji"` 로 충족, 임의 동적 핸들러는 미지원으로 명문화.

### 우선순위 제안 (현재)

1. ✅ **멀티 윈도우 완성** — Phase 3 외형 옵션 풀 셋 + Phase 4 webContents 모두 완료
2. ✅ **다이얼로그** — Phase 5-A 완료 (sheet modal 포함)
3. ✅ **클립보드 / Shell 외부 핸들러** — Phase 5-A 완료
4. ✅ **트레이 + 알림 + 메뉴바 API** — Phase 5-B/C/D 완료, 데스크톱 앱 기본 요소
5. ✅ **파일 시스템 API** — Phase 5-F 완료. 백엔드/프론트 공통 `fs` wrapper + E2E
6. ✅ **글로벌 단축키** — Phase 5-E 완료. macOS Carbon Hot Key (권한 불필요) + 5 SDK + accelerator 파싱
7. ✅ **라이프사이클 이벤트** — Phase 5 완료. minimize/restore/maximize/unmaximize/enter·leave-
    full-screen/show/hide/ready-to-show/page-title-updated/will-resize + quit-policy. e2e 4 skip은
    환경 한계로 단위 테스트가 cover (`docs/WINDOW_API.md` 매핑 표).
8. ✅ **macOS App Sandbox 자동화** (CEF Helper entitlements) — Mac App Store 진출 시 필수
9. ✅ **보안 모델** (Phase 7: fs sandbox + cache 격리 + IPC 검증 + CSP + contextIsolation audit) — Phase 7 핵심 완료
10. ✅ **CLI 배포** (`npx @suji/cli init my-app` / Homebrew tap / curl) — `@suji/cli` 스캐폴더, Homebrew Formula 생성/검증, curl installer 완료. npm publish/tap push는 토큰 보유 환경에서 수행
11. **Windows frameless drag region 후속** — macOS/Linux `frame:false`
    drag/no-drag는 E2E 완료. Linux 잔여 창 옵션(`transparent`/`parent` 등)은 CEF Views
    native path로 완료. Windows frameless parity는 후속.
12. **앱 패키징** (Windows .msi, Linux .AppImage, macOS notarize 자동화) — 배포 단계
13. 🟡 **자동 업데이트** — manifest check + artifact download + SHA-256 verify + macOS/Linux/Windows prepareInstall/quit-and-install 1차 완료. macOS `.zip/.dmg` stage, Windows `.zip` PowerShell stage/helper, Linux `.AppImage`/raw 교체 입력, `.deb` package-manager handoff 정책까지 문서화/검증(macOS `.zip` + Linux `.AppImage` E2E). 남은 것: Windows 실제 교체 E2E/인스톨러 연계
14. ✅ **`child_process` / HTTP / SQLite SDK** — child_process(`suji.process.run`)와 backend 전용 HTTP(`suji.http.fetch`) 완료. renderer-safe HTTP는 `@suji/plugin-http` 공식 플러그인으로 완료. SQLite는 `plugins/sqlite` 공식 플러그인으로 완료.
15. ✅ **`safeStorage` (OS secure store) — macOS + Linux + Windows 완료**.
    `safe_storage_set/get/delete` IPC 3개. macOS는 Keychain Services
    (SecItemAdd/CopyMatching/Delete), Linux는 libsecret Secret Service simple API
    (secret_password_store/lookup/clear_sync), Windows는 Credential Manager generic
    credential(CredWriteW/CredReadW/CredDeleteW, DPAPI-backed) 기반. idempotent
    set/delete + escape-safe value + multi-service 격리 e2e. Linux는 GitHub Actions에서
    gnome-keyring을 세션 D-Bus 안에서 unlock해 실제 libsecret 왕복 검증.
16. 🟡 **시스템 통합 (macOS 거의 완료)** — `tests/e2e/system-integration.test.ts` 중심 검증. 구현된 항목:
    - `screen.getAllDisplays` (macOS NSScreen + Linux X11 screen)
    - `app.dock.setBadge`/`getBadge` (NSDockTile, 멀티바이트 round-trip 포함)
    - `app.setBadgeCount`/`getBadgeCount` (Electron식 숫자 badge count, macOS dock label sync + Linux/Windows native backend best-effort)
    - `powerSaveBlocker.start`/`stop` (macOS IOPMAssertion, Linux
      XScreenSaverSuspend, Windows Power Request API, idempotent guard)
    - `safeStorage.setItem`/`getItem`/`deleteItem` (macOS Keychain Services,
      Linux libsecret/Secret Service, Windows Credential Manager, multi-service 격리)
    - `app.requestUserAttention`/`cancelUserAttentionRequest` (NSApp dock bounce)
    - `app.getPath` (7 표준 키: home/appData/userData/temp/desktop/documents/downloads)
    - `shell.trashItem` (macOS NSFileManager, Linux GIO, Windows SHFileOperation)
    - `powerMonitor` (macOS NSWorkspace, Linux logind/ScreenSaver DBus, Windows
      WM_POWERBROADCAST/WTS — 4 채널 callback→EventBus E2E + 플랫폼 bridge 회귀)

    Linux/Windows 후속: 남은 macOS-only 구현(대표적으로 애플리케이션 메뉴바와 Windows frameless 등 일부 창 외형 옵션)의 cross-platform 동등 구현 필요. Linux context menu는 GTK `menu.popup`으로 완료.
17. ✅ **`windows.createView` (Electron WebContentsView 동등) — Phase 17-B CEF Views 전환**.
    macOS/Linux/Windows 기본 경로는 CEF-managed `CefWindow + CefBrowserView` 기반. id 풀 공유 +
    모든 webContents API view 호환. 8 SDK 메서드 + view-created/view-destroyed 이벤트 +
    호스트 close 시 자동 정리. 17-A의 wrapper NSView + child NSView+CefBrowser 합성은
    dynamic `destroyView` 시 view render subprocess와 host main webContents가 함께 강종되는
    한계 때문에 제거했다. child NSWindow는 host에 attach해 macOS native input 차단을 피하고,
    dynamic `destroyView` 후 child target cleanup/host 생존/remaining view/recreate를
    E2E로 검증했다. Linux/Windows는 CEF overlay child view 경로로 배선했고
    CEF-free platform/path policy 단위 테스트, Rust/Go/Node backend SDK view API, GitHub Actions
    Linux/Windows runtime E2E(`webcontentsview-cross-platform`)로 검증했다. CI에서 초기
    `about:blank` 커밋 후 요청 URL navigation이 유실되는 CEF Views 레이스는 UI-thread delayed
    retry로 고정했고, macOS/Linux/Windows E2E가 모두 통과한다.
    macOS CEF overlay child path는 `SUJI_CEF_VIEWS_CHILD_OVERLAY=1` 실험 경로로 격리 — 자세한 plan:
    [docs/plans/17-B-cef-views-architecture.md](./plans/17-B-cef-views-architecture.md).
18. ✅ **`webRequest` 인터셉트** — declarative URL glob blocklist + dynamic listener
    (RV_CONTINUE_ASYNC + pending callback storage, 256개) cancel/allow round-trip.
    `webRequest:before-request` / `webRequest:will-request` / `webRequest:completed` 3 채널.
    5 SDK + e2e 13. timeout fallback: JS SDK onBeforeRequest 가 미응답/throw
    시 timeoutMs(기본 5s, ≤0 opt-out) 후 fail-open 자동 통과(네이티브 hold
    해제). mock-bridge 단위 6.
19. ✅ **스플래시 패턴** — 별도 API 없이 `windows.create` + `is_loading` polling + `destroy_window`
    조합. e2e (`tests/e2e/run-splash.sh`).
20. ✅ **TypeScript 타입 자동 생성 (옵션 A 1차 + B 부분)** — frontend(`@suji/api`) /
    Node(`@suji/node`) SujiHandlers augment + invoke conditional generic, Zig comptime
    `typeToTs` + App.schema chain, Rust specta v2 re-export. `suji types` CLI는
    Zig backend `.schema()` stdout/`--out` 생성까지 완료했고
    `tests/e2e/run-types-cli.sh` + GitHub Actions macOS E2E로 고정.
    Rust는 `suji::typescript::SujiHandlers` helper로 `#[derive(suji::Type)]`
    req/res를 `@suji/api` module augmentation `.d.ts`로 emit하는 수동 등록 경로를
    추가했고, Rust SDK 단위 테스트 + 임시 외부 Rust consumer E2E
    (`tests/e2e/run-rust-types-helper.sh`, GitHub Actions macOS E2E)로 고정.
    Go는 `suji.NewTSHandlers()` helper로 struct/json tag reflection 기반 수동 등록
    경로를 추가했고, Go SDK 단위 테스트 + 임시 외부 Go consumer E2E
    (`tests/e2e/run-go-types-helper.sh`, GitHub Actions macOS E2E)로 고정.
    Node는 수동 augment를 `invoke/invokeSync/call/callSync`가 소비하도록 확장했고,
    Node SDK type/unit 테스트 + 임시 외부 TS consumer E2E
    (`tests/e2e/run-node-types-helper.sh`, GitHub Actions macOS E2E)로 고정.
    런타임 타입메타 부재 때문에 Node 자동 생성은 범위 밖.
21. 🟡 **`desktopCapturer` / `crashReporter`** — 화면 캡처 / 크래시 리포팅 (crashReporter 1차 runtime API + CEF cfg + 로컬 Crashpad DB 조회 완료, 실제 crash/upload 서버 검증은 후속)
22. ✅ **SQLite plugin** — `plugins/sqlite` 공식 플러그인 완료. 벤더 SQLite 3.51.0 + Zig/Rust/Go/JS/Node 래퍼 + `zig build test-sqlite` + 모바일 host harness.
23. ✅ **session 쿠키 풀 셋** — `setCookie` / `getCookies` / `removeCookies` 추가
    (`session:cookies-result` 이벤트 + visitor 패턴 + race-safe pending buffer + 1초
    timeout). CEF refcount 모델이 표준 RefPtr scope과 안 맞아 visit fn count==total-1
    시점 emit 채택. cookies 0개 case는 SDK timeout으로 빈 결과 (Electron 동등). 5 SDK
    노출 + e2e 8 케이스. `clearStorageData(origin?, storageTypes?)` ✅ — CDP
    `Storage.clearDataForOrigin`+`Network.clearBrowserCache` fire-and-forget
    (clearCookies 동형). origin 미지정 시 현재 문서 origin 자동 해석
    (`getMainFrameUrl`→`util.originFromUrl`, 앱 자기 storage 삭제)+전역 캐시.
    ⚠️ 진짜 제약: 전 origin 프로필-전역 wipe 는 CDP 구조상 불가(per-origin
    호출만; about:/data: 등 해석불가 시 캐시만).
24. ✅ **임베드 코어 분리 + 모바일 (zero-native 벤치마킹)** — 아래 전용 섹션.
25. ✅ **Windows dlopen 백엔드 복구** — Zig 0.16 std.DynLib Windows 제거(의도된 설계)에
    대응해 kernel32 `LoadLibraryExW`/`GetProcAddress`/`FreeLibrary` 직접 래핑
    (`loader.zig` `WinDynLib`). 이슈 #11 해결.
26. ✅ **로드맵 잔존 sharp edge 5건** (코드 스윕 견고화 — 깨진 기능 아님,
    경계 오동작/무경고 절단/프로세스 사망 위험 제거). 커밋 `e3433cb` + D4
    회귀 보완 `55de50e`:
    - **D-1** `util.matchGlob` 에 `?`·`[abc]`/`[a-z]`·`[!^]` 부정·`\`
      이스케이프 추가 (Electron/표준 glob 패리티; webRequest URL filter;
      `zig test util.zig` 신규 8 describe).
    - **D-2** `loader.extractCmdField` → 검증된 `util.extractJsonString`
      위임 (`"cmd": "x"` 공백·`\"` escape 오라우팅 제거; 모바일 `__core__`).
    - **D-3** `get_child_views` 4KB 스택 FBA(>1024 view 무경고 절단→오인
      `ok:false`) → `registry.allocator` 힙(무제한).
    - **D-4** `EventBus on/onC/once` OOM 시 `@panic`→`return 0`(invalid-id
      sentinel, 임베드 graceful degrade) + 회귀 테스트 신설
      (`events_test.zig`, FailingAllocator).
    - **D-5** `util.originFromUrl`(scheme://authority) 신설 →
      `clearStorageData` 무인자 시 자기 origin 자동 해석(위 23번 항목).
    각 /simplify 3-에이전트 + `zig build test` 무회귀.

---

## 임베드 코어 분리 + 모바일 (Phase 1·2·3)

`vercel-labs/zero-native` 벤치마킹 후, 코어를 CEF에서 분리해 C ABI 임베드
라이브러리로 노출. 동기: 헤드리스 테스트, 결합도 ↓, 빌드 속도, 그리고 시스템
WebView·모바일의 전제. 핵심 발견 — `src/core/*`·`src/backends/loader.zig`는 이미
CEF import 0이라 분리선이 이미 존재했음.

- [x] **Phase 1: C ABI shim** — `src/embed.zig`가 `BackendRegistry`+`EventBus`를
      감싸 `suji_core_init/destroy/invoke/free/emit/emit_to/on/off` export. `zig
      build lib` → `libsuji_core.a`(CEF/Cocoa/Node 링크 0). `include/suji_core.h`
      수기 헤더. `tests/embed_abi_test.zig` 헤드리스 통합 3종 → `zig build test`.
- [x] **Phase 2: 호스트 재배선** — `main.zig` runDev/runProd가 `BackendRegistry`/
      `EventBus`를 직접 생성하지 않고 `embed.init/registry()/eventBus()` 경유.
      호스트는 embed 경계로만 코어 접근 → 경계가 CEF 의존을 컴파일 단계에서 차단.
      CEF 호출부(200+) 불변. e2e cef-ipc 멀티백엔드 40/40 pass.
- [x] **Phase 3: 모바일 활성화**
  - [x] `loader.zig platformName()`에 iOS/Android 추가 (데스크톱 불변).
  - [x] `zig build lib` 4타깃(host/iOS/Android/Windows) 크로스 컴파일 검증.
  - [x] CI `embed-lib` job — CEF 무관, 4타깃 빌드 + `suji_core_*` 심볼 검증.
  - [x] `examples/ios` — XcodeGen `project.yml` + Swift `WKWebView` + bridging
        header + JS 브릿지(`window.suji.invoke`↔C ABI) + `demo:tick` 이벤트.
  - [x] `examples/android` — Gradle + JNI(`suji_jni.c`)가 `libsuji_core.a` 정적
        링크 → `libsujihost.so`, Kotlin `WebView`, UI 스레드 마샬링(single-thread
        core), 동형 JS 브릿지.
  - [x] `suji_core_register_handler` — 호스트가 채널을 네이티브로 응답
        (`registerEmbedRuntime` 위임, 코어 신규 상태 0). iOS(Swift @convention(c)
        + strdup)·Android(JNI 트램폴린, JNI_OnLoad 캐싱 + ExceptionCheck) 예제가
        `ping`→pong / `counter:inc` 실제 왕복 시연. 헤드리스 테스트 +memory 계약.
  - [x] Windows dlopen 복구(#25 항목) — kernel32 직접 래핑.
  - [x] **iOS Rust/Go 정적 백엔드** — 언어 고유 심볼로 단일 바이너리 충돌 회피:
        Rust SDK `export_handlers_static!`(→`suji_rs_*` `#[no_mangle]`),
        Go SDK `//export suji_go_*`(기존 `backend_*`에 위임). 호스트는
        `suji_core_register_handler`로 채널→백엔드 cmd JSON 브리지 등록.
        `examples/ios/backends/{rust(staticlib),go(c-archive)}` + Swift
        `Backends.swift`. 4타깃 심볼 네임스페이스 분리 검증(nm),
        데스크톱 dlopen·SDK 테스트 무회귀. (Node 제외 — V8 JIT iOS 불가.)
  - [x] **Android Rust/Go 정적 백엔드** — iOS와 동형, 백엔드 소스 재사용
        (`examples/ios/backends` 공유). Rust=`.a` 정적, Go=`.so` c-shared
        (Android는 Go c-archive 미지원 → JNI `.so`가 정적/공유 혼합 링크,
        Gradle jniLibs 자동 패키징). `suji_jni.c`가 `suji_core_register_handler`
        로 등록, `(channel,json)→{"cmd":..}` 브리지는 `include/suji_mobile_bridge.h`
        공용(verify.c·JNI 공유, 동일 C 중복 제거). NDK 컴파일·심볼 검증,
        tests/mobile-backends 하니스 ALL PASS.
  - [x] **모바일 언어별 예제**(PC `examples/*-backend` 대응) — 모바일은
        호스트 정적 링크라 "언어별"=링크/등록 백엔드 차이. 호스트 스캐폴딩을
        `_shared/`에 두고 변형 thin: `examples/{ios,android}/{_shared, multi,
        rust, go, zig}`. iOS=XcodeGen `sources: ../_shared` + `BackendBridge.swift`
        공용, Android=Gradle `sourceSets` 공유 + `_shared/cpp/suji_jni_core.c`
        (공용 `suji_reg_backend`). 백엔드 소스(`examples/ios/backends/{rust,
        go,zig}`)·`suji_mobile_bridge.h`·CI(`mobile-backends`) 공유로 중복
        최소화. Node: iOS 불가(V8 JIT), Android 후속.
    - [x] **네이티브 `@suji/api` 인터랙티브 데모** — 8× `examples/{ios,
          android}/{zig,multi,rust,go}/web/index.html` 에 동일 블록 추가
          (md5 단일, append-only — 변형별 백엔드 채널 데모 보존): clipboard/
          safe_storage/fs/app/notification/dialog 버튼 → raw `__suji__.core`
          (데스크톱 키-동형 cmd) → 결과 표시. e2e.html(SUJI_E2E 자동검증
          32/32)과 별개 — 데모는 게이트 없을 때 로드, 사람이 탭하는
          인터랙티브용(검증 경계=ios-sim-smoke 빌드·기동 무결까지). drift 가드:
          e2e.html lockstep 주석과 동일 원칙(단일출처 index.html).
  - [x] **모바일 http (`suji.http.fetch` 동등)** — 모바일 백엔드는 코어-독립이라
        SDK 대신 std 직접: `examples/ios/backends/zig` 의 `zig:http` 가
        `std.http.Client`(자체 `std.Io.Threaded.init_single_threaded` —
        embed.zig 코어 패턴 복제, handle_ipc 에 io 인자 없으므로) 로 GET/POST.
        backend-only(프론트 shim 미노출 — Zig SDK 보안모델 유지, 관례+문서).
        실증: `tests/mobile-backends` 호스트 하니스 17/17 ALL PASS
        (register_handler→handle_ipc→std.http→인프로세스 localhost 평문 GET/
        POST/echo/error). 빌드-only: aarch64-ios/-simulator/android-cross
        컴파일·정적 링크 성공. **미검증(정직)**: 실기기·실 네트워크·모바일
        HTTPS/TLS. `process.run` 은 iOS 샌드박스 fork/exec 금지로 제외.
  - [ ] (backlog) **모바일 HTTPS/TLS** — Zig std `crypto.Certificate.Bundle.
        rescan` 에 `.ios` 분기 없어 iOS CA 번들 공백 → 실 iOS HTTPS 인증서
        검증 실패. 해결: iOS Security.framework `SecTrust` 연동 또는 앱 번들
        PEM 주입(Android는 `/system/etc/security/cacerts` 경로 확인 필요).
        위 평문 http 배선의 상위 단계.
  - [x] **모바일 네이티브 `@suji/api` (`__core__` 와이어, Tauri 동형) — 완료
        (Slice 1~11)**. 데스크톱과 *동일* 프론트 API(`suji.clipboard.*` 등
        `coreCall→__suji__.core`)가 모바일에서도 동작하도록, 호스트(iOS Swift/
        Android Kotlin)가 `suji_core_register_handler("__core__", dispatch,
        free)` 로 cmd 를 네이티브 디스패치. `coreInvoke` 가 special_dispatch
        null(모바일) → `embed_runtimes["__core__"]` 폴백, `extractCmdField` 로
        cmd→channel 추출(loader.zig). 응답 JSON 은 데스크톱 `src/main.zig
        cefHandleCore` 와 **키-동형**(프론트 `packages/suji-js` **무수정** —
        데스크톱 무회귀). 미지원 cmd 는 `coreError` 동형
        (`success:false,error:"unknown_cmd"`). bridgeJS `api` 에 `core`(재인코딩
        금지, channel `__core__` 고정) 추가 — iOS `_shared` + Android 4×
        `web/index.html`(동일 변경, 단일출처 없음 → drift 주의).

        **최종 상태**: 모바일 대응 가능한 데스크톱 API **사실상 전부 배선
        완료**. 총 cmd ≈35 (clipboard 12·fs 6·dialog 4·notification 4·
        safe_storage 3·app 메타 4·shell open_external+beep). 검증: 호스트
        하니스 `tests/mobile-backends/run.sh` **52/52** + 실 디바이스
        `ios-e2e.sh` **iOS 32/32** + `android-e2e.sh` **Android 32/32**
        (실 UIPasteboard/ClipboardManager/Keychain/Keystore/FileManager/
        샌드박스 FS 왕복 자가검증). 진짜 디바이스 e2e 가 호스트 하니스·
        코드리뷰가 놓친 **실 버그 3건 적발·수정**: ① Android `handleInvoke`
        `when(channel)` 가 추출-cmd 를 못 받던 라우팅 결함(→ `else→
        coreDispatch`), ② iOS `setValue`↔`setData` HTML/RTF 왕복 실패,
        ③ iOS `pasteboardTypes`→`types`(iOS14 rename) 컴파일 실패.
        각 Slice `/simplify` 3-에이전트(reuse/quality/efficiency) 통과,
        브랜치→커밋→main ff-merge→push. 정직 한계(플랫폼 의미차)는
        Slice 항목·아래 커버리지표·`CLAUDE.md` 에 일관 명시.
    - [x] **Slice 1: clipboard** — iOS `sujiCoreDispatch`(UIPasteboard,
          JSONSerialization) + Android `coreDispatch`(ClipboardManager,
          JSONObject) — `clipboard_read_text/write_text/clear`. 검증:
          `tests/mobile-backends` 22/22(mock `__core__` 라우팅+write→read
          왕복+clear+unknown_cmd 폴백, 데스크톱 키-동형 응답 실증) + iOS
          시뮬레이터 빌드·기동(Swift/bridgeJS 컴파일·링크·생존). ⚠️ **미검증**:
          실 UIPasteboard/ClipboardManager 동작(실기기), **Android 컴파일**
          (로컬 SDK env 부재 — 코드리뷰+verify.c 메커니즘 간접 보강만, 정직).
    - [x] **Slice 2: `shell_open_external`** — iOS `UIApplication.open`
          (canOpenURL 동기 판정+fire-and-forget) / Android `Intent.ACTION_VIEW`.
          open_path/show_item_in_folder/beep/trash_item 은 unknown_cmd 폴백.
          검증: harness 23/23 + iOS 시뮬 빌드·기동.
    - [x] **Slice 3: notification** — `is_supported/request_permission/show/
          close`. iOS `UNUserNotificationCenter`(권한은 *완전 비동기* — 동기
          `granted:false` 즉시 반환 + 콜백서 `notification:permission` 이벤트
          emit, 정직한 한계) / Android `android.app.NotificationManager`+
          `NotificationChannel`(`areNotificationsEnabled()` 동기값, Builder
          API26+ 전제). 검증: harness 26/26 + iOS 시뮬 빌드·기동. ⚠️ 실기기
          알림 표시·권한 프롬프트·click 이벤트는 미검증(정직).
    - [x] **Slice 4: dialog** — 데드락 회피를 위해 *blocking 아닌* 호스트-측
          비동기 가로채기로 구현(원래 계획의 semaphore 방식은 메인스레드
          데드락이라 폐기). `dialog_show_message_box` 를 iOS
          `userContentController`/Android `Bridge.invoke` 에서 `suji_core_invoke`
          *전에* 가로채 네이티브 alert(UIAlertController/AlertDialog.setItems)를
          비동기 표시 → 사용자 탭 시 *같은 id* 로 `__suji__.__resolve__`
          (`_pending[id]` 유지, **코어 프로토콜 무변경**). 응답 데스크톱
          `handleDialogShowMessageBox` 와 키-동형(`{response,checkboxChecked}`).
          체크박스는 네이티브 부재로 항상 false(정직 한계). open/save dialog 는
          모바일 파일모델 차이로 sync 경로 → unknown_cmd. ⚠️ **검증**: iOS 시뮬
          빌드·기동 + 코드리뷰만 — dialog 는 호스트-async 라 `verify.c`(C 하니스)
          **자동 검증 불가**(슬라이스 1-3 보다 약함, 정직). 실기기 alert 표시·
          Android 컴파일 미검증.
  - [x] **모바일 *기능* e2e (iOS 시뮬 + Android 에뮬, 진짜 e2e)** —
        `tests/mobile-backends/ios-e2e.sh`·`android-e2e.sh`. 디바이스 안
        `e2e.html`(데모 `index.html` 무수정, 호스트가 SUJI_E2E env/intent extra
        게이트로 분기 — 데모 무회귀) 가 데스크톱과 동일 `__suji__.core` 와이어로
        clipboard 8케이스(ascii/멀티라인/UTF-8/empty/clear/reuse/20x stress/
        unknown_cmd) 실 왕복 자가검증 → verdict 를 `e2e:report` 채널로 보고
        (iOS=앱 데이터컨테이너 파일, Android=logcat 태그) → 스크립트 assert.
        **시뮬/에뮬 clipboard 는 실 UIPasteboard/ClipboardManager → 진짜 e2e**
        (호스트 mock 아님). iOS 8/8 + Android 8/8 PASS.
        🐞 이 e2e 가 **실제 Android 배선 버그 적발**: `coreInvoke` 가
        embed_runtimes 폴백서 `extractCmdField` 로 추출한 cmd 를 channel 인자로
        넘기는데 `MainActivity.handleInvoke` 가 `when(channel)` 에서 `"__core__"`
        만 매칭 → clipboard/shell/notification 이 `else→"{}"` 로 죽고 있었음
        (호스트 하니스·코드리뷰가 못 잡음). `else -> coreDispatch(json)` 로
        iOS `sujiCoreDispatch` 와 동형 수정 → Android 슬라이스 1-3 이 컴파일을
        넘어 **e2e 실증**으로 격상. ⚠️ 범위 밖(정직): dialog 탭/실 알림 표시/
        실 URL open(=스모크), 실기기(시뮬·에뮬 ≠ 디바이스), CI 통합(후속 backlog).
    - [x] **Slice 5: safe_storage** — `safe_storage_set/get/delete`. iOS
          Security.framework Keychain(kSecClassGenericPassword) / Android
          Android Keystore 하드웨어-백 AES-GCM + SharedPreferences(androidx.
          security 의존 0, stdlib). 데스크톱 키-동형(set/delete=success,
          get=value, idempotent). 검증: harness 30/30 + iOS 11/11 + Android
          11/11 e2e(실 Keychain/Keystore set/get/update/delete/idempotent
          디바이스 실증).
    - [x] **Slice 6: app 메타** — `app_get_locale/name/version/path`. iOS
          Locale.preferredLanguages(BCP47)/Bundle infoDictionary/FileManager
          / Android Locale.toLanguageTag/PackageManager/filesDir·cacheDir.
          ⚠️ app_get_path 의 desktop/downloads 는 데스크톱에선 ~/Desktop·
          ~/Downloads(non-empty) 를 주는 *지원* 키지만 모바일 플랫폼 부재로
          graceful 빈값 격하(데스크톱 진짜 unknown 키와 동일 *형태*일 뿐
          의미 동형 아님 — 정직). 검증: harness
          34/34 + iOS 17/17 + Android 17/17 e2e(locale BCP47·name·version
          non-empty·documents/temp 절대경로·desktop graceful "").
    - [x] **Slice 7: clipboard 확장(html/rtf/image)** — read/write 각 3.
          iOS UIPasteboard typed UTI(public.html/rtf/png — html/rtf 는
          `setData`(UTF-8); `setValue` 가 Data 로 저장해 String 왕복 실패하던
          것을 e2e 가 적발·수정. image 는 raw PNG Data 로 바이트 정확 왕복).
          Android: html=`ClipData.newHtmlText`(네이티브), rtf/image=custom
          MIME ClipData(시스템 RTF/in-band image 네이티브 부재 — 앱 내 왕복
          동작, 타 앱 상호운용 아님, 플랫폼 한계 정직 명시). 데스크톱
          키-동형(read=html/rtf/data, write=success). 검증: harness 40/40 +
          iOS 20/20 + Android 20/20 e2e(html/rtf/PNG 1x1 실 round-trip).
          buffer/has/available_formats 는 후속.
    - [x] **Slice 8: dialog 확장(error/open/save)** — Slice 4 호스트-async
          가로채기 패턴 확장(코어 무변경, deferred __resolve__). iOS
          UIAlertController(error_box 1버튼) + UIDocumentPicker(open/save,
          UIDocumentPickerDelegate) / Android AlertDialog(error_box) + SAF
          Intent(ACTION_OPEN/CREATE_DOCUMENT, onActivityResult). 데스크톱
          키-동형(error=success, open=canceled+filePaths[], save=canceled+
          filePath""). ⚠️ 정직: 모바일은 절대경로가 아니라 보안스코프 URL
          (iOS .path)/content:// URI(Android) 반환 — 데스크톱 경로와 의미
          다름. iOS save 는 Files export 모델이라 빈 임시파일이 실제 생성
          (데스크톱 save panel 은 경로만 — 의미 근사). 검증: iOS/Android
          빌드 컴파일·링크 + 기존 20/20 무회귀. dialog 는 사용자 상호작용
          (탭/파일선택) 이라 verify.c/e2e 자동 assert 불가(Slice 4 와 동일
          경계 — iOS 시뮬 빌드+코드리뷰+가로채기 메커니즘 재사용 입증).
    - [x] **Slice 9: shell 확장(beep/open_path/show_item/trash)** —
          `shell_beep` 만 실 네이티브(iOS AudioServices 1057 / Android
          ToneGenerator) → success:true. `shell_open_path`/`show_item_in_
          folder`/`trash_item` 은 모바일 플랫폼 한계로 graceful success:false
          (open_path=iOS 샌드박스 file:// 불가·Android FileProvider 미배선,
          show_item=파일탐색기 개념 부재, trash=휴지통(복구가능) 부재로
          영구삭제 근사는 위험) — 데스크톱 success:false 와 키-동형(프론트
          무손상). 검증: harness 42/42 + iOS 24/24 + Android 24/24 e2e
          (beep success:true·나머지 graceful false 디바이스 실증).
    - [x] **Slice 10: fs(read/write/readdir)** — iOS FileManager
          (String(contentsOfFile)/write/contentsOfDirectory) / Android
          java.io.File(readText/writeText/listFiles). 데스크톱 키-동형
          (read=success+text/error, write=success, readdir=success+
          entries[{name,type}]/error). ⚠️ 데스크톱 fs 는 suji.json
          allowedRoots 화이트리스트 검증인데 모바일은 OS 앱 샌드박스 자체가
          경계(컨테이너 밖 path 는 OS 가 거부 → success:false) — app_get_path
          (documents/temp) 하위 절대경로 사용. 검증: harness 45/45 + iOS
          26/26 + Android 26/26 e2e(app_get_path documents 하위 실 샌드박스
          파일 write→read 왕복 + readdir 가 쓴 파일 나열 — 디바이스 실 FS IO).
    - [x] **Slice 11: clipboard(buffer/has/available_formats) + fs(stat/
          mkdir/rm)** — clipboard: iOS UIPasteboard setData/data(forPaste-
          boardType:format)·contains(pasteboardTypes:)·types(iOS14, e2e 가
          pasteboardTypes→types rename 적발·수정) / Android custom-MIME
          ClipData(clipCustomWrite/Read 재사용)·description.hasMimeType·
          mimeType 순회. fs: iOS FileManager attributesOfItem/createDirectory/
          removeItem / Android File length·lastModified·mkdirs·delete
          Recursively. 데스크톱 키-동형(read_buffer=data, has=present,
          available_formats=formats[], stat=success+type+size+mtime/error,
          mkdir/rm=success). fs_rm force=미존재무시(node:fs.rm 동등),
          mkdir 이미존재=성공. 검증: harness 52/52 + iOS 32/32 + Android
          32/32 e2e(buffer 왕복·has·formats·stat 파일/디렉토리·mkdir·rm
          후 stat 실패 — 디바이스 실 네이티브). 모바일 ✅ 배선 사실상 완료.
          ⚠️ 의미차(정직): fs_stat `type` 은 모바일 file|directory 2종
          (데스크톱 fsKindName 10종 — symlink/device 등 — 의 부분집합, file 로
          격하). `available_formats` 는 iOS=시스템 파생 타입 포함 전체 / Android
          =primaryClip 명시 MIME 만(데스크톱과 셋 다름). buffer 는 iOS=실
          UIPasteboard 임의 UTI / Android=custom-MIME 앱-내 한정(Slice 7 상속).

### 데스크톱(지그 네이티브 `cefHandleCore`) ↔ 모바일 cmd 커버리지

데스크톱은 ~130 cmd. 모바일은 호스트(`__core__` 디스패치)가 네이티브 대응
가능한 것만 점진 배선. 동일 `@suji/api`(`packages/suji-js` 무수정).

| 분류 | 영역/cmd | 모바일 |
|---|---|---|
| ✅ 배선됨 | clipboard(text+html/rtf/image+**buffer/has/formats** 12) · notification(4) · shell(open_external+beep) · dialog(4) · safe_storage(3) · app 메타(4) · **fs(read/write/readdir+stat/mkdir/rm 6)** | iOS/Android e2e 실증(dialog 는 빌드+가로채기 메커니즘) |
| 🟡 미배선·대응가능 | (없음 — 모바일 대응 가능 데스크톱 API 사실상 전부 배선) | — |
| ❌ 개념 없음/모바일 한계 | shell(open_path/show_item/trash — 샌드박스/탐색기/휴지통 부재, graceful false) · window 제어 · webContents · WebContentsView · tray/menu/global_shortcut/dock/power_*/native_theme/native_image/screen · session(cookies)/web_request | Tauri 도 모바일 미제공 — `unknown_cmd`/graceful 폴백 |

- 윈도우/clipboard/dialog 등 데스크톱 네이티브 API는 CEF 호스트 전용 — 모바일
  미동작 (C ABI 표면은 invoke/emit/on/off/register_handler).
- **iOS·Android 둘 다 Rust·Go 백엔드 동작** (위 체크 항목). **Node 만 iOS
  미지원** — V8 JIT 이 iOS 코드서명 샌드박스에서 금지(정적 링크해도 런타임 코드
  생성 불가, `--jitless`는 비실용). **Android Node 는 NDK로 가능하나 예제 미배선**
  (후속). **iOS: 시뮬레이터 빌드+구동 검증됨**(데모 demo:tick 네이티브→JS→UI).
  **Android: APK/AAB 빌드+에뮬레이터 구동 검증됨**(multi·zig 변형 실디바이스
  스크린샷 — greet=Rust, go:ping=Go, zig:rev=Zig, demo:tick=네이티브→JS→UI).
  과거 블로커 3건 해결: 코어 정적 .a 의 zig Io.Threaded LE-TLS↔JNI -shared
  비호환 → 코어 동적 .so(`-Dlib-dynamic`, build.zig) + zig 가 Android Bionic
  미제공이라 NDK sysroot 를 `--libc` 공급(TLSDESC); Go c-shared SONAME 부재
  → `-Wl,-soname`; Zig 백엔드 .a 비-PIC → `-fPIC`. .so 는 jniLibs 패키징
  (Gradle 자동 + 런타임 DT_NEEDED). 메커니즘 회귀는 tests/mobile-backends(CI).
- 렌더러 eval은 in-process Zig 호스트가 `embed.eventBus().webview_eval` 직접
  주입. 비-Zig 호스트(모바일)용 C ABI eval 셋터는 미도입(후속).

---

## 참고 프로젝트

| 프로젝트 | 설명 | 참고 포인트 |
|----------|------|------------|
| [Tauri](https://github.com/tauri-apps/tauri) | Rust 데스크톱 프레임워크 | 전체 아키텍처, IPC 설계 |
| [Wails](https://github.com/wailsapp/wails) | Go 데스크톱 프레임워크 | 깔끔한 구조, 바인딩 자동 생성 |
| [webview](https://github.com/nicbarker/webview) | C WebView 래퍼 | Phase 1 핵심 의존성 |
| [webview-zig](https://github.com/thechampagne/webview-zig) | Zig WebView 바인딩 | 기존 Zig 바인딩 참고 |
| [cef-rs](https://github.com/tauri-apps/cef-rs) | Rust CEF 바인딩 | Phase 6 참고 |
| [cefcapi](https://github.com/cztomczak/cefcapi) | CEF C API 예제 | Phase 6 참고 |
