# cef.zig 도메인 분리 리팩터

`src/platform/cef.zig` 는 13,000줄+ 단일 파일이다. native API(clipboard/shell/dialog/…)를
도메인별 `src/platform/cef_<domain>.zig` 로 분리해 cef.zig 는 **코어**(CEF browser/client/
IPC/V8/lifecycle/scheme/render handler)만 남긴다. **동작 무변경**(순수 이동 + re-export)이
원칙이며, 한 도메인 = 한 PR 로 점진 진행한다.

PLAN.md 의 "후속 refactor 후보" 노트가 이 문서를 가리킨다.

## 현황

| 도메인 | 상태 | 모듈 |
|--------|------|------|
| clipboard | ✅ 완료 (PR #65 + backend split) | `cef_clipboard.zig` (~250줄; public routing + macOS) + `cef_clipboard_{types,linux,windows}.zig` |
| shell | ✅ 완료 | `cef_shell.zig` (~120줄; public routing + macOS) + `cef_shell_{linux,windows}.zig` |
| dialog | ✅ 완료 | `cef_dialog.zig` (~366줄; public routing + macOS) + `cef_dialog_{types,response,linux_{message,file},windows_{message,messagebox,task_dialog,file,folder}}.zig` |
| screen | ✅ 완료 | `cef_screen.zig` (~128줄; public routing + macOS) + `cef_screen_{linux,windows}.zig` |
| safeStorage | ✅ 완료 | `cef_safe_storage.zig` (~306줄) |
| dock | ✅ 완료 | `cef_dock.zig` (~71줄) |
| powerSaveBlocker | ✅ 완료 | `cef_power_save_blocker.zig` (~258줄) |
| desktopCapturer | ✅ 완료 | `cef_desktop_capturer.zig` (~203줄) |
| sessionCookies | ✅ 완료 | `cef_session_cookies.zig` (~323줄) |
| securityScopedBookmark | ✅ 완료 | `cef_security_scoped_bookmark.zig` (~136줄) |
| requestUserAttention | ✅ 완료 | `cef_request_user_attention.zig` (~44줄) |
| menu | ✅ 완료 | `cef_menu.zig` (~160줄; public routing + macOS) + `cef_menu_{types,linux}.zig` |
| tray | ✅ 완료 | `cef_tray.zig` (~257줄; public routing + macOS) + `cef_tray_{types,state,windows,linux}.zig` |
| notification | ✅ 완료 | `cef_notification.zig` (~90줄; public routing + macOS) + `cef_notification_{state,linux,windows}.zig` |
| globalShortcut | ✅ 완료 | `cef_global_shortcut.zig` (~255줄; public routing + macOS/Windows) + `cef_global_shortcut_{types,state,linux,linux_parse}.zig` |
| winPump | ✅ 완료 | `cef_win_pump.zig` (~381줄) |
| windowLifecycleEvents | ✅ 완료 | `cef_window_lifecycle.zig` (~189줄) |
| nativeImage | ✅ 완료 | `cef_native_image.zig` (~94줄) |
| appProgress | ✅ 완료 | `cef_app_progress.zig` (~44줄) |
| powerMonitor | ✅ 완료 | `cef_power_monitor.zig` (~114줄) |
| nativeTheme | ✅ 완료 | `cef_native_theme.zig` (~210줄) |
| appPathMeta | ✅ 완료 | `cef_app.zig` (~208줄) |
| crashReporter | ✅ 완료 | `cef_crash_reporter.zig` (~27줄) |
| webRequest | ✅ 완료 | `cef_web_request.zig` (~287줄) |
| dragHandler | ✅ 완료 | `cef_drag_handler.zig` (~147줄) |
| windowDisplayHandlers | ✅ 완료 | `cef_window_display.zig` (~238줄) |
| requestHandler | ✅ 완료 | `cef_request_handler.zig` (~46줄) |
| keyboardHandler | ✅ 완료 | `cef_keyboard_handler.zig` (~195줄) |
| devTools | ✅ 완료 | `cef_devtools.zig` (~119줄) |
| lifeSpanHandler | ✅ 완료 | `cef_life_span_handler.zig` (~106줄) |
| schemeHandler | ✅ 완료 | `cef_scheme.zig` (~131줄; factory/dist path) + `cef_scheme_resource.zig` (~173줄; per-request resource handler) + `cef_scheme_security.zig` (~129줄; CSP/security headers) |
| renderHandler | ✅ 완료 | `cef_render_handler.zig` (~267줄; V8 handler/vtable) + `cef_render_ipc.zig` (~198줄; renderer IPC state + response/event delivery) + `cef_render_bootstrap.zig` (~130줄; `window.__suji__` JS bootstrap) |
| viewsDelegate | ✅ 완료 | `cef_views_delegate.zig` (~23줄; facade) + `cef_views_browser_delegate.zig` (~89줄) + `cef_views_window_delegate.zig` (~391줄; Window delegate callbacks/create) + `cef_views_window_delegate_state.zig` (~147줄; delegate state/ref/color helpers) |
| browserIpc | ✅ 완료 | `cef_browser_ipc.zig` (~309줄) |
| appHandler | ✅ 완료 | `cef_app_handler.zig` (~96줄) |
| macAppMenu | ✅ 완료 | `cef_mac_app_menu.zig` (~249줄) |
| macWindow | ✅ 완료 | `cef_mac_window.zig` (~387줄) |
| objc | ✅ 완료 | `cef_objc.zig` (~238줄) |
| util | ✅ 완료 | `cef_util.zig` (~142줄) |
| clientHandler | ✅ 완료 | `cef_client_handler.zig` (~43줄) |
| pageOutput | ✅ 완료 | `cef_page_output.zig` (~259줄; vtable glue 포함) |
| pageOutputConstants | ✅ 완료 | `cef_page_output_constants.zig` (~9줄) |
| pendingCleanup | ✅ 완료 | `cef_pending_cleanup.zig` (~9줄) |
| publicApi | ✅ 완료 | `cef_public_api.zig` (~331줄; public facade) |
| initialLoad | ✅ 완료 | `cef_initial_load.zig` (~132줄) |
| webContents | ✅ 완료 | `cef_web_contents.zig` (~226줄) |
| webContentsView | ✅ 완료 | `cef_web_contents_view.zig` (~170줄; public vtable glue) + `cef_web_contents_view_child_window.zig` (~185줄; macOS child-window path) + `cef_web_contents_view_overlay.zig` (~133줄; CEF Views overlay path) |
| windowState | ✅ 완료 | `cef_window_state.zig` (~192줄) |
| windowVisuals | ✅ 완료 | `cef_window_visuals.zig` (~162줄) |
| windowRuntime | ✅ 완료 | `cef_window_runtime.zig` (~114줄) |
| windowCreation | ✅ 완료 | `cef_window_creation.zig` (~220줄) |
| runtime | ✅ 완료 | `cef_runtime.zig` (~162줄) |
| browserState | ✅ 완료 | `cef_browser_state.zig` (~55줄) |
| messageLoop | ✅ 완료 | `cef_message_loop.zig` (~56줄) |
| nativeWindowHandles | ✅ 완료 | `cef_native_window_handles.zig` (~54줄) |
| nativeRegistry | ✅ 완료 | `cef_native_registry.zig` (~26줄) |
| browserControl | ✅ 완료 | `cef_browser_control.zig` (~47줄) |
| nativeRefs | ✅ 완료 | `cef_native_refs.zig` (~38줄) |
| nativeEntry | ✅ 완료 | `cef_native_entry.zig` (~62줄) |
| nativeVtable | ✅ 완료 | `cef_native_vtable.zig` (~63줄) |
| native | ✅ 완료 | `cef_native.zig` (~94줄) |
| cImport | ✅ 완료 | `cef_c.zig` (~47줄) |
| coreFoundation | ✅ 완료 | `cef_core_foundation.zig` (~6줄) |
| **코어** (re-export hub) | — 유지 | `cef.zig` |

clipboard + shell + dialog + screen + safeStorage + dock + powerSaveBlocker + desktopCapturer + sessionCookies + securityScopedBookmark + requestUserAttention + menu + tray + notification + globalShortcut + winPump + windowLifecycleEvents + nativeImage + appProgress + powerMonitor + nativeTheme + appPathMeta + crashReporter + webRequest + dragHandler + windowDisplayHandlers + requestHandler + keyboardHandler + devTools + lifeSpanHandler + schemeHandler + renderHandler + viewsDelegate + browserIpc + appHandler + macAppMenu + macWindow + objc + util + clientHandler + pageOutput + pageOutputConstants + pendingCleanup + publicApi + initialLoad + webContents + webContentsView + windowState + windowVisuals + windowRuntime + windowCreation + runtime + browserState + messageLoop + nativeWindowHandles + nativeRegistry + browserControl + nativeRefs + nativeEntry + nativeVtable + native + cImport + coreFoundation 분리 후 cef.zig 13,362 → 326줄.

## 재사용 기반 (clipboard PR 에서 마련)

후속 도메인은 아래를 그대로 재사용한다 — 추가로 pub 화할 헬퍼만 도메인별로 늘린다.

- **공유 macOS ObjC 브리징** (`cef_objc.zig`, cef.zig 에서 `pub` re-export): `objc`, `getClass`, `msgSend`,
  `nsStringFromCstr`, `nsStringFromSlice`, `nsStringFromSliceWithCapacity`,
  `nsStringToUtf8Buf`, `msgSendVoid1`, `msgSendVoid2`, `msgSendVoidBool`, `nsFileUrlIfExists`. CoreFoundation:
  `CFDataCreate`, `CFDataGetBytePtr`, `CFDataGetLength`, `CFRelease`.
- **공유 CEF 유틸** (`cef_util.zig`, cef.zig 에서 `pub` re-export):
  `nullTerminateOrTruncate`, `asPtr`, `zeroCefStruct`, `setCefString`, `initBaseRefCounted` 등.
- **CEF 런타임 초기화** (`cef_runtime.zig`, cef.zig 에서 `pub` re-export):
  `CefConfig`, `executeSubprocess`, `initialize` 는 기존 public API를 유지하면서 CEF process-wide
  설정과 cache path 초기화를 한 모듈에 모은다.
- **브라우저 전역 상태** (`cef_browser_state.zig`, cef.zig 에서 `pub` re-export):
  `currentBrowser`, `devtoolsClient`, `rememberMainBrowserIfUnset`, `isMainBrowser`, `CEF_IPC_BUF_LEN` 와
  shared CEF handler bootstrap을 보관한다.
- **CEF 메시지 루프 lifecycle** (`cef_message_loop.zig`, cef.zig 에서 `pub` re-export):
  `run`, `shutdown`, `quit`, `quitAfterNextResponse` 는 기존 public API를 유지하면서
  DevTools/browser force-close 후 `cef_quit_message_loop` 순서를 한 모듈에 둔다.
- **alias 패턴** — 도메인 파일 상단에서 `const msgSend = cef.msgSend;` 식으로 alias 하면
  옮긴 블록의 호출부를 **한 글자도 바꾸지 않는다**.
- **re-export** — cef.zig 가 `pub const clipboardReadText = cef_public_api.clipboardReadText;`
  로 facade를 재노출 → main.zig `__core__` 디스패치 및 각 SDK 호출부 **무변경**.
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
7. **검증** — 현재 호스트에서 `zig build -Doptimize=Debug` + 해당 도메인 e2e
   (`bash tests/e2e/run-<domain>.sh`) + `zig build test`. 다른 OS 경로는 각 플랫폼 CI 게이트.

## 주의 (clipboard 에서 겪은 것)

- **반복적 의존성 발굴**: 1차 정적 열거가 완벽하지 않을 수 있다 — 빌드가 "use of undeclared
  identifier" 로 추가 의존(예: `CFRelease`, `CLIPBOARD_MAX_TEXT`, `nsStringFromClipboardText`)을
  알려준다. 그때마다 "이동 vs pub+alias" 분류를 반복한다.
- **mutual coupling 주의**: 도메인 블록이 쓰는 cef.zig 헬퍼가 다시 도메인 상수를 쓰는 경우가
  있다(예: `nsStringFromClipboardText` ↔ `CLIPBOARD_MAX_TEXT`). 도메인 전용이면 그 헬퍼도 함께
  이동해 co-locate.
- **순환 import 허용**: cef.zig → cef_<domain> (re-export) 와 cef_<domain> → cef (alias) 의
  순환은 Zig 가 non-comptime decl 에 대해 허용. 실제로 컴파일된다.
- **플랫폼별 검증 누락 주의**: 현재 호스트/CEF framework 가 없는 OS 경로는 로컬 빌드에서
  검증되지 않을 수 있다. 최소 현재 호스트 build + 도메인 e2e 를 돌리고, 나머지 OS는 CI
  (특히 macOS/Windows 빌드 체크) green 을 확인한다. 그래서 이동은 **기계적**(블록 verbatim
  + alias)으로 해 플랫폼별 정합을 보존한다.

## 순서 제안

공유 헬퍼 기반 도메인 분리와 CefNative shell/cimport 분리는 위 목록 기준으로 완료했다.
후속 분리는 `cef.zig` re-export hub 경계를 별도로 재정의한 뒤 진행한다.
