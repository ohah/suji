# Suji

Zig 코어 기반 올인원 데스크톱 앱 프레임워크.
Tauri(Rust), Wails(Go)와 달리 여러 백엔드 언어를 지원.

## 문서

- [구현 계획서](./docs/PLAN.md) — 아키텍처, 구현 단계, 기술 결정 사항

## 빌드 & 실행

```bash
# macOS (Xcode 26.2 필요, 26.4는 Zig 링커 버그)
zig build          # 빌드
zig build test     # 테스트 (55개)
zig build run      # CLI 도움말

# 예제 실행
cd examples/zig-backend && suji dev       # Zig 단독
cd examples/rust-backend && suji dev      # Rust 단독
cd examples/go-backend && suji dev        # Go 단독
cd examples/multi-backend && suji dev     # Zig + Rust + Go
```

## CLI

```bash
suji init <name> --backend=rust|go|multi  # 프로젝트 생성
suji dev                                   # 개발 모드
suji build                                 # 프로덕션 빌드
suji run                                   # 프로덕션 실행
```

## 백엔드 DX

```zig
// Zig (내장, 최고 DX)
pub const app = suji.app()
    .command("ping", ping)
    .on("clicked", handler);

fn ping(req: suji.Request) suji.Response {
    return req.ok(.{ .msg = "pong" });
}
```

```rust
// Rust (SDK: crates/suji-rs)
#[suji::command]
fn ping() -> String { "pong".to_string() }
suji::export_commands!(ping);
```

```go
// Go (SDK: sdks/suji-go)
type App struct{}
func (a *App) Ping() string { return "pong" }
var _ = suji.Bind(&App{})
```

## 폴더 구조

```
suji/
├── src/
│   ├── main.zig              # CLI (init, dev, build, run)
│   ├── root.zig              # 라이브러리 루트
│   ├── core/
│   │   ├── app.zig           # Zig 내장 백엔드 빌더 (comptime)
│   │   ├── config.zig        # JSON 설정 파서
│   │   ├── events.zig        # EventBus (pub/sub)
│   │   ├── init.zig          # suji init 스캐폴딩
│   │   ├── window.zig        # 창 관리
│   │   ├── webview.zig       # WebView API
│   │   └── ipc.zig           # IPC 브릿지 (invoke, chain, fanout, emit, on)
│   ├── backends/
│   │   └── loader.zig        # Backend + BackendRegistry + SujiCore (dlopen)
│   └── templates/            # suji init 템플릿
├── crates/
│   ├── suji-rs/              # Rust SDK (#[suji::command])
│   └── suji-rs-macros/       # Rust proc macro
├── sdks/
│   └── suji-go/              # Go SDK (suji.Bind)
├── tests/                    # 55개 테스트
├── examples/
│   ├── zig-backend/          # Zig 단독 + React
│   ├── rust-backend/         # Rust 단독 + React
│   ├── go-backend/           # Go 단독 + React
│   └── multi-backend/        # Zig + Rust + Go + React
└── docs/
    └── PLAN.md
```

## 알려진 이슈

- macOS 26.4 + Xcode 26.4: Zig 링커 버그 (Xcode 26.2 필요)
- Go 빌드: Homebrew LLVM 충돌 (CC=/usr/bin/clang 자동 설정)
- TOML: 미지원 (JSON만, 백로그)
