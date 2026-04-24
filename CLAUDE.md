# Suji

Zig 코어 기반 올인원 데스크톱 앱 프레임워크.
Electron 스타일 API (handle/invoke/on/send).

## 문서

- [구현 계획서](./docs/PLAN.md) — 아키텍처, 구현 단계, 기술 결정 사항

## 빌드 & 실행

```bash
zig build          # 빌드
zig build test     # 테스트 (227개)
zig build run      # CLI 도움말

# 예제 실행
cd examples/multi-backend && suji dev   # Zig + Rust + Go + Node.js
cd examples/zig-backend && suji dev     # Zig 단독
cd examples/rust-backend && suji dev    # Rust 단독
cd examples/go-backend && suji dev      # Go 단독
cd examples/node-backend && suji dev    # Node.js 단독
```

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
    .on("clicked", handler);
fn ping(req: suji.Request) suji.Response { return req.ok(.{ .msg = "pong" }); }
// req.invoke("rust", request)  — 크로스 호출
// suji.send("channel", data)   — 이벤트 발신
```

```rust
// Rust
#[suji::handle]
fn ping() -> String { "pong".to_string() }
suji::export_handlers!(ping);
// suji::invoke("go", request)  — 크로스 호출
// suji::send("channel", data)  — 이벤트 발신
// suji::on("channel", cb, arg) — 이벤트 수신
```

```go
// Go
type App struct{}
func (a *App) Ping() string { return "pong" }
var _ = suji.Bind(&App{})
// suji.Invoke("rust", request)
// suji.Send("channel", data)
// suji.On("channel", callback)  — EventBus 연결 (bridge.c)
```

```js
// Frontend (Electron 스타일 — 자동 라우팅)
await suji.invoke("ping")                                    // 채널명만으로 호출 (등록된 백엔드 자동 탐색)
await suji.invoke("greet", { name: "Suji" })                 // 인자 전달
await suji.invoke("greet", { name: "Suji" }, { target: "rust" }) // 특정 백엔드 지정
suji.on("event", (data) => console.log(data))
suji.emit("event", { msg: "hello" })
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
- CI: GitHub Actions (macos-14 + ubuntu-24.04 + windows-latest)

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
