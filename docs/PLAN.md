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
  - [ ] 권한 시스템 (나중에)
- [x] State 플러그인 (첫 번째 공식 플러그인)
  - [x] Zig 구현 — `plugins/state/zig/` (HashMap + Mutex + JSON 파일 영속성)
  - [x] 경합 테스트 (`tests/state_plugin_test.zig` — 10 threads + rapid fire 100)
  - [x] JS 래퍼 — `plugins/state/js/`
  - [x] Rust 래퍼 — `plugins/state/rust/`
  - [x] Go 래퍼 — `plugins/state/go/`
  - [x] EventBus 연동 (`state:set` 시 `state:{key}` 이벤트 발행)
  - [ ] Node 래퍼 (Phase 5 이후)
  - [ ] SQLite 플러그인 (별도, 나중에)
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

- [ ] 플러그인: fs — 파일 시스템 (`plugins/fs/`)
- [ ] 플러그인: dialog — 시스템 다이얼로그 (`plugins/dialog/`)
- [ ] 플러그인: tray — 트레이 아이콘 (`plugins/tray/`)
- [ ] 플러그인: menu — 메뉴바 (CEF `cef_menu_model_capi.h` 사용, 기본 NSMenu Edit 메뉴는 이미 제공)
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
    - [ ] OnBeforeClose 자연 발화 (CEF macOS Alloy 런타임 — 현재 cef.quit 우회)
    - [x] `set_title` / `set_bounds` 플랫폼별 구현 (macOS NSWindow 완료, Linux GTK / Windows Win32는 no-op 스텁)
    - [x] IPC `__window` 자동 태깅 — wire 레벨. `cef.zig:handleBrowserInvoke`에서 sender
          browser의 WM id를 `injectWindowField`로 request JSON에 merge. 이미 태그된 요청,
          비-객체/빈 객체/whitespace 엣지 케이스 모두 처리. `window_ipc.injectWindowField`
          순수 함수로 단위 테스트 7종 + E2E (`tests/e2e/window-injection.test.ts`)로 검증.
    - [x] `windows[]` 배열 파싱 — config.zig의 `Config.windows: []const Window`. 시작 시 배열 길이만큼
          `wm.create` 자동 호출. Tauri 호환 선언적 다중 창. 하위호환 X (단일 `window` 객체 제거).
    - [~] **핸들러 `InvokeEvent` 파라미터** — Electron의 `IpcMainInvokeEvent` 대응.
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
    - [x] `windows[].frame: false` — NSWindowStyleMaskBorderless. macOS 완료, Linux/Windows는 추후.
    - [x] `windows[].transparent: true` — NSWindow.opaque=NO + clearColor + hasShadow=NO + CEF browser background_color=0.
    - [x] `windows[].parent: "<name>"` — NSWindow.addChildWindow:ordered:NSWindowAbove로 시각 관계만 (PLAN 재귀 close X).
          parent name lookup은 main.zig의 wm.fromName으로 처리 — 따라서 부모는 windows[] 배열 순서상 더 앞에 와야.
    - [x] `windows[].x / y` — 명시 위치. 0이면 OS cascade 자동 (cascadeTopLeftFromPoint:).
    - [x] `windows[].alwaysOnTop` — NSFloatingWindowLevel(3).
    - [x] `windows[].resizable: false` — NSWindowStyleMaskResizable 비트 제외.
    - [x] `windows[].minWidth/minHeight/maxWidth/maxHeight` — NSWindow.contentMinSize/contentMaxSize.
    - [x] `windows[].fullscreen: true` — toggleFullScreen: (makeKeyAndOrderFront 이후).
    - [x] `windows[].backgroundColor: "#RRGGBB(AA)"` — NSColor.colorWithRed:green:blue:alpha:.
    - [x] `windows[].titleBarStyle: "hidden" | "hiddenInset"` — titlebarAppearsTransparent + NSWindowStyleMaskFullSizeContentView.
    - 런타임 변경 API (set_frame/set_transparent/setParent)는 미지원 — 시작 시점 결정만. 실수요 발견 시 SujiCore.get_window_api로 도입.
    - **알려진 한계**: frameless의 `-webkit-app-region: drag` 미동작 (Phase 4 백로그 참조).
  - [~] Phase 4: webContents (네비, JS 실행, 줌, 프린트/캡처)
    - [x] **Phase 4-A 네비/JS** — `load_url`, `reload`(`ignoreCache`), `execute_javascript`,
          `get_url`(캐시), `is_loading` 6개. WM 메서드 + IPC 핸들러 + Frontend SDK
          (`windows.loadURL/reload/executeJavaScript/getURL/isLoading`) + 단위 17 + e2e 3.
    - [ ] Phase 4-B 줌 — `set_zoom_factor`, `get_zoom_factor`, `set_zoom_level`, `get_zoom_level`
    - [ ] Phase 4-C DevTools 명시 API — `open_dev_tools`, `close_dev_tools`, `is_dev_tools_opened`, `toggle_dev_tools`
    - [ ] Phase 4-D 인쇄/캡처 — `print_to_pdf`, `capture_page` (콜백 기반)
    - [ ] Phase 4-E 편집/검색/UA — `undo/redo/cut/copy/paste/select_all`, `find_in_page`, `set_user_agent`
    - [ ] DevTools "Reload" 버튼 → **DevTools가 attach된 메인 창도 같이 reload** (Electron 동작 호환).
          현재는 DevTools 자체만 reload되고 main frame은 변동 없음. CEF DevTools front-end의
          reload 명령을 캐치 → host.get_browser().reload() 호출 또는 ReloadIgnoreCache.
          확인 위치: cef.zig DevTools client (g_devtools_client) 또는 OnPreKeyEvent에 추가 핸들링.
    - [ ] **frameless drag region (`-webkit-app-region: drag`) — CEF Alloy 라우팅**.
          현재는 HTML에 drag region을 지정해도 CEF view가 마우스 이벤트를 swallow해서 동작 X.
          정식: `cef_drag_handler_t` vtable + `on_draggable_regions_changed` 콜백 등록 →
          받은 `cef_draggable_region_t` 배열을 macOS `NSView` hit-test로 라우팅 (custom
          contentView wrapper에서 mouseDown 시 영역 안이면 `[window performWindowDragWithEvent:]`).
          Linux GTK는 `gtk_window_begin_move_drag`, Windows는 `WM_NCHITTEST` HTCAPTION 반환.
          현재 임시 한계 — frameless 창 이동 불가. (examples/window-styles README에 명시.)
  - [ ] Phase 5: 라이프사이클 이벤트 (resize/close/focus/blur, quitOnAllWindowsClosed)
  - [ ] Phase 6: SDK (Rust/Go/Node/Frontend JS BrowserWindow)
  - [ ] Phase 7: 보안/플랫폼 전용 (contextIsolation, vibrancy 등)
    - [ ] `contextIsolation: true` — 별도 V8 world에 `window.__suji__` 생성 + `Object.freeze`된
          프록시만 메인 월드에 노출. XSS가 bridge를 변조/레퍼런스 캡처 불가.
          Electron의 contextBridge 대체 (더 간결). 외부 URL 로드 시 권장 기본값 후보.
          (preload.js / contextBridge 자체는 **비제공** — WINDOW_API.md 설계 참조)
  - **설계 비제공 (문서화 완료)**: 렌더러 직접 통신, MessagePort, preload.js, contextBridge — `docs/WINDOW_API.md#설계-비제공-항목과-이유`
  - **V2 검토**: `cross_origin_isolation` 플래그 (SharedArrayBuffer 활성화), `inject` 초기 스크립트 옵션
  - **엣지 케이스 / TDD 전략 / E2E 범위**: `docs/WINDOW_API.md` 해당 섹션 참조
  - **핵심 결정사항** (확정):
    - **Electron 호환 계층**: 허브-스포크, 렌더러 직접 통신 X, preload.js X, MessagePort V2, SharedArrayBuffer는 옵션 플래그만
    - **플러그인 API**: id 기반 (핸들 X) + SDK는 OO wrapper, async 완료는 이벤트 폴백, `executeJavaScript` 필수, `onWindowClosed` SDK 편의 wrapper 제공
    - **안전성**: id monotonic (재사용 X), create 전체 write lock, closed 창 emit은 silent no-op, orphan은 destroyAll, 부모-자식은 시각 관계만 (재귀 close X)
    - **TDD 인프라**: Light 투자 (MockBrowser/MockWebView 각 10~20줄만). 필요 시점에 확장. WindowManager 단위는 CEF 없이 풀-TDD
    - **구현 순서**: Phase 2 (기본) + Phase 2.5 (데이터 인프라) **분리 유지**. 2.5 없이 Phase 2만 완료되면 플러그인이 멀티 윈도우 인지 불가
    - **E2E 실행**: macOS CI만 (필수/권장). Linux/Windows는 컴파일/단위만
- [ ] CLI 도구
  - [x] `suji init` — 프로젝트 스캐폴딩 (rust/go/multi)
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
└── frontend/          ← Vite + React (bun)
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
- [ ] `suji run main.js` CLI
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

현재 `src/backends/loader.zig`의 `BackendRegistry.node_invoke_fallback`은 Node 전용 하드코딩. 새 임베드 런타임마다 분기를 추가하면 지저분해지므로 먼저 일반화가 필요하다.

- [ ] `EmbedRuntime` struct 도입
  ```zig
  pub const EmbedRuntime = extern struct {
      invoke: *const fn (channel: [*:0]const u8, data: [*:0]const u8) callconv(.c) ?[*:0]const u8,
      free_response: ?*const fn ([*:0]const u8) callconv(.c) void = null,
  };
  ```
- [ ] `BackendRegistry.embed_runtimes: std.StringHashMap(EmbedRuntime)` 필드 — "node"/"python"/"lua" 등 이름으로 등록
- [ ] `coreInvoke`에서 `registry.invoke(name, ...)`가 null이면 `embed_runtimes.get(name)` 폴백 (현재 Node 전용 if문 제거)
- [ ] 기존 `node_invoke_fallback`을 `EmbedRuntime` 등록으로 이관 (하위 호환 제거)

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

**Zig 패키지** (Zig 백엔드 사용자용):
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
- curl: `curl -fsSL https://suji.dev/install.sh | sh`

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
- Linux: .AppImage 또는 .deb

---

## Electron / Tauri 대비 부족한 기능

현재 Suji는 IPC + EventBus + 멀티 백엔드(Phase 2, 4, 6)가 동작하지만, 실제 앱을 만들어 배포하려면 아래 기능들이 필요하다.

### 네이티브 데스크톱 API (Phase 3 미완성)

| 기능 | Electron | Tauri | Suji |
|------|----------|-------|------|
| 파일 시스템 API | `fs` 모듈 | `fs` 플러그인 | ❌ |
| 시스템 다이얼로그 (열기/저장/알림) | `dialog` | `dialog` 플러그인 | ❌ |
| 트레이 아이콘 | `Tray` | `tray-icon` | ❌ |
| 메뉴바 | `Menu` | `menu` | 🟡 (macOS Edit 메뉴만 기본 제공) |
| 창 이벤트 (resize/close/focus) | `BrowserWindow` 이벤트 | `Window` 이벤트 | 🟡 (설계 완료, 구현 대기) |
| 멀티 윈도우 | `new BrowserWindow()` | `WebviewWindow` | 🟡 (PoC 완료, API 미구현) |
| 핫 리로드 | webpack HMR | Vite HMR + 백엔드 감시 | ✅ (dylib 재로드 + Vite HMR) |

### 보안

| 기능 | Electron | Tauri | Suji |
|------|----------|-------|------|
| 권한 시스템 (API 접근 제어) | contextBridge/sandbox | allowlist + CSP | ❌ |
| CSP (Content Security Policy) | 수동 설정 | 빌트인 | ❌ |
| IPC 유효성 검사 | preload 격리 | 커맨드별 타입 검증 | ❌ |

### 앱 배포 & 패키징

| 기능 | Electron | Tauri | Suji |
|------|----------|-------|------|
| macOS .app 번들 | electron-builder | `tauri build` | ✅ (`bundle_macos.zig`, Helper 4개, Info.plist) |
| Windows .msi/.exe | electron-builder | `tauri build` | ❌ |
| Linux .deb/.AppImage | electron-builder | `tauri build` | ❌ |
| 코드 서명 & 공증 | electron-notarize | 빌트인 | 🟡 (서명 준비 — 공증 미구현) |
| 자동 업데이트 | autoUpdater | `updater` 플러그인 | ❌ |

### 플러그인 / 확장 API

| 기능 | Electron | Tauri | Suji |
|------|----------|-------|------|
| 중앙 상태 스토어 | Redux 등 자유 | Tauri state 관리 | ✅ (`plugins/state`, 첫 공식 플러그인) |
| 클립보드 | `clipboard` | `clipboard-manager` | ❌ |
| 글로벌 단축키 | `globalShortcut` | `global-shortcut` | ❌ |
| 알림 (Notification) | `Notification` | `notification` | ❌ |
| 셸 명령 실행 | `child_process` | `shell` 플러그인 | ❌ |
| HTTP 클라이언트 | Node `fetch` | `http` 플러그인 | ❌ |
| 로컬 DB (SQLite 등) | better-sqlite3 | `sql` 플러그인 | ❌ |
| 딥링크 | `protocol.registerSchemesAsPrivileged` | `deep-link` | ❌ |
| 스플래시 스크린 | BrowserWindow 조합 | `splashscreen` | ❌ |

### 개발자 경험 (DX)

| 기능 | Electron | Tauri | Suji |
|------|----------|-------|------|
| DevTools | Chromium 내장 | WebView inspect | ✅ (인앱 DevTools, F12/Cmd+Shift+I 토글) |
| E2E 테스트 | Spectron/Playwright | - | ✅ (Puppeteer + CDP `tests/e2e/`) |
| TypeScript 타입 자동 생성 | - | specta 연동 | ❌ |
| 프론트엔드 프레임워크 템플릿 | - | create-tauri-app | 🟡 (`suji init` 존재, 제한적) |
| 플러그인 생태계 | npm 생태계 | 공식 플러그인 30+개 | 🟡 (state 1개) |
| CI/CD 템플릿 | - | GitHub Actions 공식 제공 | 🟡 (내부 CI만, 템플릿 미제공) |

### 바이너리 데이터 / 고급 기능

| 기능 | Electron | Tauri | Suji |
|------|----------|-------|------|
| 바이너리 IPC | Buffer 직접 전송 | `asset://` 커스텀 프로토콜 | ✅ `suji://` 커스텀 프로토콜 |
| 중앙 상태 스토어 | Redux 등 자유 | Tauri state 관리 | ✅ (`plugins/state`) |

### 우선순위 제안

1. **멀티 윈도우 완성** (`BrowserWindow` API Phase 2~7) — 설계 확정됨, 실제 데스크톱 앱 필수
2. **파일 시스템 + 다이얼로그** — 가장 기본적인 네이티브 API
3. **앱 패키징** (Windows .msi, Linux .AppImage) — macOS는 완료, 타 OS 보완
4. **트레이 + 메뉴바** — 데스크톱 앱의 기본 요소
5. **보안 모델** — 프로덕션 사용 전 필수
6. **자동 업데이트** — 배포 후 유지보수에 필수

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
