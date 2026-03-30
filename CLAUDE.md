# Suji

Zig 코어 기반 올인원 데스크톱 앱 프레임워크.
Tauri(Rust), Wails(Go)와 달리 여러 백엔드 언어를 지원.

## 문서

- [구현 계획서](./docs/PLAN.md) — 아키텍처, 구현 단계, 기술 결정 사항

## 빌드 & 실행

```bash
# macOS (Xcode 26.2 필요, 26.4는 Zig 링커 버그)
zig build          # 빌드
zig build test     # 테스트
zig build run      # CLI 도움말
```

## 폴더 구조

```
suji/
├── build.zig / build.zig.zon    # Zig 빌드 (webview-zig 의존성)
├── src/
│   ├── main.zig                 # CLI (demo, test)
│   ├── root.zig                 # 라이브러리 루트
│   ├── core/
│   │   ├── window.zig           # 창 관리 (WebView 래핑)
│   │   ├── webview.zig          # WebView API
│   │   └── ipc.zig              # IPC 브릿지 (invoke, chain, fanout, core)
│   ├── backends/
│   │   └── loader.zig           # Backend + BackendRegistry + SujiCore (dlopen)
│   ├── node/                    # (Phase 5: libnode)
│   └── platform/                # (Phase 1: OS별 구현)
├── tests/
│   ├── loader_test.zig          # Backend/Registry 테스트
│   └── ipc_test.zig             # IPC JSON 파서 테스트
├── examples/
│   └── multi-backend/           # 멀티 백엔드 예제 (Rust+Go+React)
├── docs/
│   └── PLAN.md
└── mise.toml                    # zig@0.15.2, rust, node, go
```
