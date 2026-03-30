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

# 예제 실행 (examples/ 디렉토리에서)
cd examples/rust-backend && suji dev    # Rust 단일 백엔드
cd examples/go-backend && suji dev      # Go 단일 백엔드
cd examples/multi-backend && suji dev   # Rust + Go 멀티 백엔드
```

## CLI 명령어

```bash
suji dev     # 백엔드 자동 빌드 + 프론트엔드 dev 서버 + WebView
suji build   # 백엔드 릴리스 빌드 + 프론트엔드 빌드
suji run     # 빌드된 앱 실행 (dist/index.html)
```

## 설정 파일

suji.toml 또는 suji.json (자동 감지, toml 우선)

## 폴더 구조

```
suji/
├── build.zig / build.zig.zon    # Zig 빌드 (webview-zig, zig-toml 의존성)
├── src/
│   ├── main.zig                 # CLI (dev, build, run)
│   ├── root.zig                 # 라이브러리 루트
│   ├── core/
│   │   ├── config.zig           # 설정 파서 (TOML + JSON)
│   │   ├── window.zig           # 창 관리
│   │   ├── webview.zig          # WebView API
│   │   └── ipc.zig              # IPC 브릿지 (invoke, chain, fanout, core)
│   ├── backends/
│   │   └── loader.zig           # Backend + BackendRegistry + SujiCore (dlopen)
│   ├── node/                    # (Phase 5: libnode)
│   └── platform/                # (Phase 1: OS별 구현)
├── tests/
│   ├── loader_test.zig          # Backend/Registry 테스트
│   ├── ipc_test.zig             # IPC JSON 파서 테스트
│   └── config_test.zig          # Config 파서 테스트
├── examples/
│   ├── rust-backend/            # Rust 단일 백엔드 + React
│   ├── go-backend/              # Go 단일 백엔드 + React
│   └── multi-backend/           # Rust + Go 멀티 백엔드 + React
├── docs/
│   └── PLAN.md
└── mise.toml                    # zig@0.15.2, rust, node, go

## 알려진 이슈

- macOS 26.4 + Xcode 26.4: Zig 링커 버그 (Xcode 26.2로 다운그레이드 필요)
- Go 빌드: Homebrew LLVM과 충돌 (CC=/usr/bin/clang 자동 설정으로 해결)
- TOML [[backends]] 배열: zig-toml 미지원 (multi-backend는 suji.json 사용)
```
