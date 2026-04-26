# Suji — Agent Instructions

이 프로젝트의 AI 에이전트 (Codex / Claude Code / Cursor 등) 공통 지침.

**프로젝트 컨벤션, API 스펙, 빌드 명령, 알려진 이슈 등 모든 컨텍스트는 [`CLAUDE.md`](./CLAUDE.md)를 참조하세요.**

CLAUDE.md는 다음을 포함합니다:
- 빌드 & 실행 명령 (`zig build`, `zig build test`, 예제 실행)
- 5개 진입점 (Frontend `@suji/api` + Zig/Rust/Go/Node 백엔드 SDK) API 시그니처
- IPC `__core__` cmd 목록 (windows / clipboard / shell / dialog / tray / notification / menu)
- 폴더 구조 + 핵심 모듈 (cef.zig / main.zig / app.zig 등)
- 크로스 플랫폼 정책 + 알려진 제약 (Windows dlopen, Linux/Windows GPU)
- Node.js 백엔드 (libnode 임베드) 양방향 크로스 호출 deadlock 방지 노트
- 배포 채널 계획

상세 API 문서는 [`documents/`](./documents/) (MDX) 참조:
- `frontend.mdx` — `window.__suji__` API
- `backend-{zig,rust,go,node}.mdx` — 각 SDK
- `multi-window.mdx` — 멀티 윈도우 + Phase 4 webContents
- `dialog.mdx` / `tray.mdx` / `notification.mdx` / `menu.mdx` / `clipboard-shell.mdx` — Phase 5 Native API
- `events.mdx` / `ipc-wire.mdx` / `plugin-state.mdx` — IPC + 이벤트 + 플러그인

구현 계획 / 백로그 / Electron·Tauri 대비 갭 — [`docs/PLAN.md`](./docs/PLAN.md).
