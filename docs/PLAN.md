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
| 브라우저 | Chromium 번들 | OS WebView | OS WebView | OS WebView |
| 백엔드 | Node.js 전용 | Rust 전용 | Go 전용 | **아무 언어** |
| 번들 크기 | ~150MB | ~3MB | ~8MB | 1~50MB (선택) |
| 코어 언어 | C++ | Rust | Go | **Zig** |

---

## 아키텍처

```
┌─────────────────────────────────────────┐
│              사용자 앱                    │
├─────────────────────────────────────────┤
│           Suji 프레임워크                 │
│  ┌─────────┬──────────┬───────────┐     │
│  │ 창 관리  │ WebView  │   IPC     │     │
│  │ window  │ webview  │  브릿지    │     │
│  └────┬────┴────┬─────┴─────┬─────┘     │
│       │         │           │            │
│  ┌────┴─────────┴───────────┴──────┐     │
│  │        platform 추상화           │     │
│  │  macOS │ Windows │ Linux        │     │
│  └─────────────────────────────────┘     │
├─────────────────────────────────────────┤
│           백엔드 연결                     │
│  ┌──────────────┬──────────────┐        │
│  │ dlopen       │ libnode      │        │
│  │ (Zig/Rust/   │ (Node.js     │        │
│  │  Go/C)       │  임베드)     │        │
│  └──────────────┴──────────────┘        │
└─────────────────────────────────────────┘
```

---

## 구현 단계

### Phase 1: 기초 (OS WebView + 창)

**목표**: 빈 창에 WebView 띄우기

- [x] `build.zig` + `build.zig.zon` 프로젝트 초기화
- [x] webview.h C 라이브러리 연동 (webview-zig 패키지)
- [x] 기본 창 생성 + HTML 로딩
- [ ] Linux 테스트 (WebKitGTK)
- [x] macOS 지원 (WKWebView)
- [ ] Windows 지원 (WebView2)

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
- [ ] 이벤트 시스템 (구독/발행, 어느 백엔드든 수신 가능)
- [ ] 중앙 상태 스토어 (Zig 코어에서 관리, 백엔드는 읽기 요청/쓰기 요청)
- [ ] 바이너리 데이터 채널 (로컬 HTTP 서버)

**바이너리 데이터 전송**:

webview IPC는 텍스트 전용이라 바이너리(이미지, 파일 등)를 직접 전송 불가.
Tauri도 같은 문제로 커스텀 프로토콜(`asset://`)을 사용.

Suji 해결 방식: **Zig 코어에서 로컬 HTTP 서버 실행**
```
Zig 코어:
  ├─ WebView IPC (JSON 텍스트) — 함수 호출, 상태, 이벤트
  └─ 로컬 HTTP 서버 (바이너리) — 이미지, 파일, 스트림
      http://localhost:{PORT}/asset/photo.png
```
```html
<!-- WebView에서 바이너리 데이터 접근 -->
<img src="http://localhost:9876/asset/photo.png">
```
```js
// JS에서 바이너리 fetch
const response = await fetch("http://localhost:9876/api/file/data.bin");
const buffer = await response.arrayBuffer();
```

각 프레임워크 비교:
| 프레임워크 | 텍스트 IPC | 바이너리 |
|-----------|-----------|---------|
| Electron | JSON (구조화 복제) | Buffer/ArrayBuffer 직접 지원 |
| Tauri | JSON-RPC | 커스텀 프로토콜 (asset://) |
| Wails | JSON | Base64 / 파일 경로 |
| **Suji** | JSON (webview_bind) | **로컬 HTTP 서버** |

**결과물**:
```js
// 프론트엔드에서
const result = await window.__suji__.invoke("greet", { name: "yoon" });
```
```zig
// Zig 백엔드에서
fn greet(ctx: *SujiContext, args: JsonValue) JsonValue {
    const name = args.get("name").string();
    // 중앙 상태 업데이트 (코어 경유)
    ctx.state.set("last_greeted", name);
    return json.string("Hello, " ++ name);
}
```

---

### Phase 3: Zig 백엔드 완성

**목표**: Zig 전용 프레임워크로 완성도 올리기

- [ ] 파일 시스템 API
- [ ] 시스템 다이얼로그 (열기, 저장, 알림)
- [ ] 트레이 아이콘
- [ ] 메뉴바
- [ ] 창 이벤트 (resize, close, focus 등)
- [ ] 멀티 윈도우
- [ ] CLI 도구
  - [ ] `suji init` — 프로젝트 스캐폴딩
  - [x] `suji dev` — 개발 서버 (프론트엔드 + 백엔드 동시 실행)
  - [x] `suji build` — 프로덕션 빌드
  - [x] `suji run` — 빌드된 앱 실행
- [ ] 핫 리로드 (개발 모드)

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
├── suji.toml
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
├── suji.toml
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
# 1. suji.toml 읽기
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
- [ ] 각 언어별 SDK 패키지 배포
  - [ ] Rust: `suji` crate (crates.io)
  - [ ] Go: `suji` module (go pkg)
  - [ ] C: `suji.h` 헤더
- [ ] 각 언어별 예제 프로젝트

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
// Zig 코어가 백엔드에게 제공하는 API (백엔드 → 코어 → 다른 백엔드 호출용)
typedef struct {
    const char* (*invoke)(const char* backend_name, const char* request);
    void (*free)(const char* response);
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

- [ ] libnode 빌드 인프라 (CI에서 빌드, 프리빌트 배포)
- [ ] Zig에서 libnode 링킹 (`@cImport` + node_api.h)
- [ ] Node 환경 초기화/해제
- [ ] Zig에서 Node 환경에 Suji API 주입 (BrowserWindow, app 등)
- [ ] `suji run main.js` CLI
- [ ] require("suji") 패키지
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

### Phase 6 (선택): 멀티 백엔드

**목표**: 하나의 앱에서 여러 언어 백엔드 동시 사용

유스케이스: 고성능 작업은 Rust(tokio), 간단한 로직은 Node.js 등

```
Suji 코어 (Zig)
  ├── dlopen("librust_backend.dylib")   ← 동시성/고성능
  ├── libnode 임베드                     ← 스크립팅/UI 로직
  └── IPC 라우터 (호출을 적절한 백엔드로 분배)
```

- [x] 멀티 백엔드 동시 로드 (POC 검증 완료: Rust tokio + Go goroutine 공존)
- [x] IPC 라우터 (직접, 체인, 팬아웃, 코어 릴레이 — 데모 구현 완료)
- [x] 백엔드 간 메시지 패싱 (Suji 코어 경유, 체인 호출 검증 완료)
- [x] 이벤트 루프 공존 (POC: tokio 4 worker + Go GOMAXPROCS=12, 충돌 없음)
- [ ] 공유 상태 관리

**POC 검증 결과** (poc/ 디렉토리):
- Rust(tokio) + Go(goroutine) 한 프로세스 동시 로드: 32 스레드, 3200 호출, 93만 calls/sec
- 시그널 충돌, 데드락, 크래시 없음
- 외부 라이브러리(sha2 crate, npm lodash/dayjs/uuid) 포함 검증 완료

**선행 조건**: Phase 4, 5 완료 후 단일 백엔드로 충분히 안정된 상태에서 시작

---

### Phase 7 (선택): CEF 지원

**목표**: 렌더링 일관성이 필요한 경우 Chromium 사용

- [ ] CEF C API (`cef_capi.h`) 연동
- [ ] `build.zig`에 `-Dwith-cef` 플래그
- [ ] macOS 번들 구조 (Helper 프로세스, Framework 로딩)
- [ ] Windows/Linux CEF 번들링
- [ ] 코드 서명 가이드

**참고**: Tauri도 cef-rs로 수천 시간 투자했으나 아직 본체 미통합. 난이도 최상.

---

## 사용자 프로젝트 구조

원칙: **각 언어의 관습을 따르되, frontend/ 폴더와 suji.toml만 통일**

### 단일 백엔드

```
Rust 백엔드:                 Go 백엔드:
  my-app/                      my-app/
  ├── Cargo.toml               ├── go.mod
  ├── src/lib.rs               ├── main.go
  ├── frontend/                ├── frontend/
  │   ├── index.html           │   ├── index.html
  │   └── package.json         │   └── package.json
  └── suji.toml                └── suji.toml

Zig 백엔드:                  Node 백엔드:
  my-app/                      my-app/
  ├── build.zig                ├── package.json
  ├── build.zig.zon            ├── main.js
  ├── src/main.zig             ├── frontend/
  ├── frontend/                │   ├── index.html
  │   ├── index.html           │   └── package.json
  │   └── package.json         └── suji.toml
  └── suji.toml
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
└── suji.toml
```

### suji.toml (설정 파일)

```toml
[app]
name = "My App"
version = "0.1.0"

[window]
title = "My App"
width = 800
height = 600

# 단일 백엔드
[backend]
lang = "rust"
entry = "src/lib.rs"

# 또는 멀티 백엔드
# [[backends]]
# name = "rust"
# lang = "rust"
# entry = "backends/rust/src/lib.rs"
#
# [[backends]]
# name = "go"
# lang = "go"
# entry = "backends/go/main.go"

[frontend]
dir = "frontend"
dev_url = "http://localhost:5173"
dist_dir = "frontend/dist"
```

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

## 참고 프로젝트

| 프로젝트 | 설명 | 참고 포인트 |
|----------|------|------------|
| [Tauri](https://github.com/tauri-apps/tauri) | Rust 데스크톱 프레임워크 | 전체 아키텍처, IPC 설계 |
| [Wails](https://github.com/wailsapp/wails) | Go 데스크톱 프레임워크 | 깔끔한 구조, 바인딩 자동 생성 |
| [webview](https://github.com/nicbarker/webview) | C WebView 래퍼 | Phase 1 핵심 의존성 |
| [webview-zig](https://github.com/thechampagne/webview-zig) | Zig WebView 바인딩 | 기존 Zig 바인딩 참고 |
| [cef-rs](https://github.com/tauri-apps/cef-rs) | Rust CEF 바인딩 | Phase 6 참고 |
| [cefcapi](https://github.com/cztomczak/cefcapi) | CEF C API 예제 | Phase 6 참고 |
