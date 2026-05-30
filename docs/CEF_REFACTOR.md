# cef.zig 도메인 분리 리팩터

`src/platform/cef.zig` 는 13,000줄+ 단일 파일이다. native API(clipboard/shell/dialog/…)를
도메인별 `src/platform/cef_<domain>.zig` 로 분리해 cef.zig 는 **코어**(CEF browser/client/
IPC/V8/lifecycle/scheme/render handler)만 남긴다. **동작 무변경**(순수 이동 + re-export)이
원칙이며, 한 도메인 = 한 PR 로 점진 진행한다.

PLAN.md 의 "후속 refactor 후보" 노트가 이 문서를 가리킨다.

## 현황

| 도메인 | 상태 | 모듈 |
|--------|------|------|
| clipboard | ✅ 완료 (PR #65) | `cef_clipboard.zig` (~580줄) |
| shell / dialog / tray / menu / notification / screen / safeStorage / powerMonitor / powerSaveBlocker / dock / globalShortcut / desktopCapturer / sessionCookies / securityScopedBookmark / requestUserAttention / windowLifecycleEvents | ⬜ 대기 | — |
| **코어** (app/client/load/find/print/request/drag/lifespan/render handler, scheme, IPC, V8) | — 유지 | `cef.zig` |

clipboard 분리 후 cef.zig 13,362 → 12,832줄.

## 재사용 기반 (clipboard PR 에서 마련)

후속 도메인은 아래를 그대로 재사용한다 — 추가로 pub 화할 헬퍼만 도메인별로 늘린다.

- **공유 macOS ObjC 브리징** (cef.zig 에서 `pub`): `objc`, `getClass`, `msgSend`,
  `nsStringFromCstr`, `nsStringFromSlice`, `nsStringFromSliceWithCapacity`,
  `nsStringToUtf8Buf`. CoreFoundation: `CFDataCreate`, `CFDataGetBytePtr`,
  `CFDataGetLength`, `CFRelease`.
- **alias 패턴** — 도메인 파일 상단에서 `const msgSend = cef.msgSend;` 식으로 alias 하면
  옮긴 블록의 호출부를 **한 글자도 바꾸지 않는다**.
- **re-export** — cef.zig 가 `pub const clipboardReadText = cef_clipboard.clipboardReadText;`
  로 재노출 → main.zig `__core__` 디스패치 및 각 SDK 호출부 **무변경**.
- **introspection 테스트** — `tests/cef_ipc_test.zig` 의 `readCefSource()` 가 cef.zig +
  분리 sibling 들을 **합쳐 읽는다**. 도메인을 추가하면 그 `parts` 목록에 파일 한 줄 추가.

## 추출 레시피 (도메인당)

1. **도메인 경계 확인** — 섹션 배너(`// ====` … 제목 … `// ====`)로 블록 범위 파악.
   `grep -nE "^// =====" src/platform/cef.zig` 후 제목 줄 확인.
2. **외부 의존성 정적 열거** — 블록이 cef.zig 의 무엇을 쓰는지:
   - `sed -n '<start>,<end>p' cef.zig | grep -oE "\b[A-Za-z_][A-Za-z0-9_]*\("` 로 호출 식별자 추출.
   - 블록 내부 정의/std/`c.`/도메인 FFI 를 제외하면 **외부 의존**만 남는다.
   - ⚠️ **macOS-only `comptime is_macos` 블록은 Windows 빌드가 분석조차 안 한다.** 그래서
     ObjC/CoreFoundation 의존을 빠짐없이 정적 열거해야 한다(아래 "주의" 참조).
3. **분류** — 외부 의존을:
   - 그 도메인만 쓰면 → 함께 이동.
   - 여러 도메인이 쓰면(공유 인프라) → cef.zig 에서 `pub` 화 + 도메인 파일에서 alias.
4. **모듈 생성** — `src/platform/cef_<domain>.zig`: 헤더(imports: std/builtin/util/필요 sibling +
   `const cef = @import("cef.zig");`) + alias 블록 + 이동한 코드(verbatim).
5. **cef.zig 수정** — 블록 삭제, 그 자리에 pub fn re-export 추가, 상단에
   `const cef_<domain> = @import("cef_<domain>.zig");` 추가, 공유 헬퍼 `pub` 화.
6. **테스트 갱신** — `readCefSource()` `parts` 에 새 파일 추가. 특정 도메인 introspection
   테스트가 cef.zig 를 직접 읽으면 새 모듈 경로로 변경.
7. **검증** — `zig build -Doptimize=Debug` (Windows) + 해당 도메인 e2e
   (`bash tests/e2e/run-<domain>.sh`) + `zig build test`. macOS/Linux 는 CI 게이트.

## 주의 (clipboard 에서 겪은 것)

- **반복적 의존성 발굴**: 1차 정적 열거가 완벽하지 않을 수 있다 — 빌드가 "use of undeclared
  identifier" 로 추가 의존(예: `CFRelease`, `CLIPBOARD_MAX_TEXT`, `nsStringFromClipboardText`)을
  알려준다. 그때마다 "이동 vs pub+alias" 분류를 반복한다.
- **mutual coupling 주의**: 도메인 블록이 쓰는 cef.zig 헬퍼가 다시 도메인 상수를 쓰는 경우가
  있다(예: `nsStringFromClipboardText` ↔ `CLIPBOARD_MAX_TEXT`). 도메인 전용이면 그 헬퍼도 함께
  이동해 co-locate.
- **순환 import 허용**: cef.zig → cef_<domain> (re-export) 와 cef_<domain> → cef (alias) 의
  순환은 Zig 가 non-comptime decl 에 대해 허용. 실제로 컴파일된다.
- **macOS 로컬 미검증**: macOS CEF framework 가 없는 머신에선 cef.zig 의 macOS 경로를 로컬
  빌드할 수 없다. Windows(+Linux) 만 로컬 검증하고 macOS 는 CI(`ci (macos-14)` 빌드 체크)에
  의존. 그래서 이동은 **기계적**(블록 verbatim + alias)으로 해 macOS 정합을 보존한다.

## 순서 제안

공유 헬퍼 기반에 의존하므로, **직전 도메인 PR 이 CI(특히 macOS)에서 green 된 뒤** 다음 도메인을
이어간다. 권장 순서(자기완결도/크기 기준): shell → dialog → screen → safeStorage → dock →
powerSaveBlocker → desktopCapturer → sessionCookies → securityScopedBookmark →
requestUserAttention → menu → tray → notification → globalShortcut →
windowLifecycleEvents. 코어 CEF 핸들러(app/client/render/scheme/IPC)는 cef.zig 에 남긴다.
