# Suji

Zig 코어 기반 올인원 데스크톱 앱 프레임워크.
Electron 스타일 API (handle/invoke/on/send).

## 문서

- [구현 계획서](./docs/PLAN.md) — 아키텍처, 구현 단계, 기술 결정 사항

## 빌드 & 실행

```bash
zig build          # 빌드
zig build test     # 테스트 (63개)
zig build run      # CLI 도움말

# 예제 실행
cd examples/multi-backend && suji dev   # Zig + Rust + Go
cd examples/zig-backend && suji dev     # Zig 단독
cd examples/rust-backend && suji dev    # Rust 단독
cd examples/go-backend && suji dev      # Go 단독
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
// Frontend
await __suji__.invoke("zig", '{"cmd":"ping"}')
__suji__.on("event", (data) => console.log(data))
__suji__.emit("event", { msg: "hello" })
```

## 폴더 구조

```
suji/
├── src/
│   ├── main.zig              # CLI + EventBus↔WebView 연결
│   ├── root.zig
│   ├── core/
│   │   ├── app.zig           # Zig SDK (handle/on/send/exportApp)
│   │   ├── config.zig        # JSON 설정 파서
│   │   ├── events.zig        # EventBus (pub/sub, mutex snapshot)
│   │   ├── init.zig          # suji init 스캐폴딩
│   │   ├── util.zig          # nullTerminate, 버퍼 상수
│   │   ├── window.zig        # 창 관리
│   │   ├── webview.zig       # WebView API
│   │   └── ipc.zig           # IPC 브릿지
│   ├── backends/
│   │   └── loader.zig        # BackendRegistry + SujiCore
│   └── templates/
├── crates/
│   ├── suji-rs/              # Rust SDK
│   └── suji-rs-macros/       # Rust proc macro
├── sdks/
│   └── suji-go/              # Go SDK (bridge.c/bridge.go)
├── tests/                    # 63개 테스트
├── examples/
│   ├── zig-backend/
│   ├── rust-backend/
│   ├── go-backend/
│   └── multi-backend/        # Zig+Rust+Go + 이벤트 예제
└── docs/PLAN.md

## 알려진 이슈

- macOS 26.4 + Xcode 26.4: Zig 링커 버그 (Xcode 26.2 필요)
- Go 빌드: Homebrew LLVM 충돌 (CC=/usr/bin/clang 자동 설정)
```
