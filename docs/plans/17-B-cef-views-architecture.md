# Phase 17-B: CEF Views API Architecture Migration

> 17-A에서 발견한 multi-WebContentsView 한계를 잡기 위한 architecture migration phase.

## 1. Background — 17-A 결과 요약

Phase 17-A는 macOS에서 **`cef_window_info_t.parent_view` + 별도 NSView 합성** 패턴으로 WebContentsView를 구현 (Electron WebContentsView 동등 모델, Phase 17-A Plan에서 결정). 결과:

- ✅ Logical layer 검증 — Zig 단위 테스트 400+ + E2E 20/20 (`tests/e2e/run-view-lifecycle.sh`)
- ✅ createView/setViewBounds/setViewVisible/reorderView/getChildViews 시각 동작 (sequential addSubview 패턴 + wrapper NSView 격리)
- ❌ **Dynamic destroyView 시 view CefBrowser의 render subprocess + 메인 webContents까지 함께 강종**

시도한 fix 모두 동일 결과:
- `close_browser` force_close=1/0
- NSView dealloc cascade (close_browser 생략, destroyWindow 패턴 모방)
- NSView ops를 OnBeforeClose의 purge로 defer
- wrapper NSView 격리 (SujiViewHostWrapper subclass + hitTest pass-through)
- `setHidden` only (native cleanup 미발화)

→ **root cause는 CEF wrapper의 multi-CefBrowser cleanup robustness 한계**. CEF Forum/docs 확인 결과 `cef_window_info_t.parent_view` 합성은 less-tested 영역이고 표준 권장 패턴은 **CEF Views API (`CefWindow` + `CefBrowserView`)**.

> "You can add multiple `CefBrowserView` in the same `CefWindow` (with Alloy runtime). The CEF Views framework is **substantially improved** ... use `--use-views` command-line flag for example usage."
> — [CEF Forum](https://www.magpcss.org/ceforum/viewtopic.php?f=6&t=19826)

## 2. 결정 — Option F (Full Migration)

**host도 view도 모두 `CefBrowserView` in `CefWindow`로 변경**. CEF의 standard managed lifecycle 받음.

### Option H (Hybrid) 거부 사유

`CefBrowserView`만 추출해서 native NSWindow에 직접 부착하는 hybrid 패턴도 가능하지만:
- `CefBrowserView` lifecycle은 `CefView` 시스템(`CefWindow`)이 관리. native NSWindow에 부착 시 CEF의 managed cleanup 경로 bypass.
- 17-A의 `parent_view` 합성과 본질적으로 같은 unverified 영역에 머묾.
- short-term 작은 refactor지만 long-term 안정성 보장 X.

### Option F 장점

- CEF의 표준 multi-browser composition 패턴 — well-tested 영역.
- `CefWindow`가 host 윈도우 lifecycle을 관리 → main + secondary CefBrowser cleanup이 CEF 차원에서 일관 처리.
- Linux/Windows에서도 CEF Views가 같은 API → 17-B에서 cross-platform 동시 잡힘.
- Chrome/Alloy runtime 둘 다 CefWindow 패턴 지원.

### Option F 단점 / 작업량

macOS에서 `NSWindow` 직접 관리 코드(Phase 1~5의 자산)를 `CefWindow` API로 재매핑해야 함:

| Suji 옵션 | 현재 (NSWindow direct) | CefWindow 매핑 | 위험도 |
|---|---|---|---|
| `frame: false` | `NSWindowStyleMaskBorderless` | `CefWindowDelegate::IsFrameless` | 낮음 (검증된 API) |
| `backgroundColor` | `setBackgroundColor:` | `CefWindowDelegate::GetBackgroundColor` | 낮음 |
| `resizable` | `NSWindowStyleMaskResizable` | `CefWindowDelegate::CanResize` | 낮음 |
| `alwaysOnTop` | `NSFloatingWindowLevel` | `CefWindowDelegate::IsAlwaysOnTop` | 낮음 |
| `min/max width·height` | `setContentMin/MaxSize:` | `CefWindowDelegate::GetMinimumSize/GetMaximumSize` | 낮음 |
| `fullscreen` | `toggleFullScreen:` | `CefWindow::SetFullscreen` | 낮음 |
| `transparent` | `opaque=NO` + clearColor | `CefWindowDelegate::IsFrameless`+ `WithStandardWindowButtons=false` 조합 | **중간** — 노출 부족 가능 |
| `titleBarStyle: hidden/hiddenInset` | `NSWindowStyleMaskFullSizeContentView` | **CefWindow 직접 미지원 가능성** | **높음** — workaround 필요 |
| Frameless `-webkit-app-region` 드래그 | `SujiKeyableWindow.sendEvent:` 직접 처리 | CefWindow 사용 시 우리 sendEvent override 적용 가능한지 미확인 | **높음** |
| `attachMacChildWindow` (parent-child 시각 관계) | `NSWindow.addChildWindow:ordered:` | `CefWindow::SetParentWindow`? 미확인 | 중간 |
| Native dialog sheet (`dialog.m` `windowId` 첫 인자) | NSWindow에 attach | CefWindow에서 NSWindow 핸들 추출 필요 | 중간 |

→ **macOS 옵션 풀이 light한 use case (frame/resizable/min·max)는 안전하게 CefWindow 마이그레이션 가능. titleBarStyle/transparent/frameless drag은 CefWindow API 노출 + workaround 검증이 핵심 위험.**

## 3. 검증 단계 (Phase 17-B Sub-step 분할)

### 17-B.0 — 사전 조사 (1일)
- CEF `cefclient` 샘플의 Views runtime 코드 (`tests/cefclient/browser/views_window.cc`) 분석
- `CefWindowDelegate` / `CefBrowserViewDelegate` 콜백 풀 셋 확인
- macOS-specific 옵션별 노출 여부 확인 (특히 titleBarStyle, transparent)
- `CefWindow::GetWindowHandle()`로 NSWindow 추출 가능한지 — dialog.m sheet/native menu 등이 그 경로로 호환 가능한지

### 17-B.1 — Skeleton: CefWindow + CefBrowserView 한 개만 (1일)
- 새 `cef_views.zig` (또는 `cef.zig` 안에 `kind: enum { native, views }` 분기) 시작
- 가장 단순 시나리오: 옵션 없는 CefWindow 1개 + CefBrowserView 1개
- 빌드 + 화면에 뜨는 것까지

### 17-B.2 — macOS 옵션 1차 매핑 (2일)
- frame/resizable/alwaysOnTop/min·max/fullscreen/backgroundColor — CefWindowDelegate 콜백 구현
- 단위/회귀 테스트 (Phase 3 옵션 풀 셋 회귀 보존)

### 17-B.3 — titleBarStyle / transparent (2-3일, 위험)
- CefWindowDelegate 직접 노출 안 하면 GetWindowHandle()로 NSWindow 추출 후 macOS API 직접 호출
- 또는 NSWindow subclass 주입 (CefWindow가 내부 만든 NSWindow에 method swizzling)
- **이 단계가 17-B 성패 분기점**

### 17-B.4 — Frameless drag region (2일)
- 현재 SujiKeyableWindow.sendEvent: override는 NSWindow 직접 관리 전제
- CefWindow가 만든 NSWindow에 같은 override 주입 가능한지 검증
- 안 되면 CEF의 drag handler 콜백 활용 우회

### 17-B.5 — multi-WebContentsView 검증 (1일)
- host CefWindow에 secondary CefBrowserView 추가
- **dynamic destroy 시각 검증** (17-A 한계 해결됐는지 — 핵심 목표)
- E2E `view-lifecycle.test.ts` 그대로 재사용 가능 (IPC 인터페이스 동일)

### 17-B.6 — 기존 NSView 합성 코드 폐기 (1일)
- 17-A의 `cef_window_info_t.parent_view` + `host_ns_view` + wrapper 코드 제거
- BrowserEntry 단순화

### 17-B.7 — Linux/Windows (3-5일)
- CefWindow는 cross-platform → Linux GTK/Win32에서도 같은 코드 경로
- macOS-specific 옵션은 제외 (이미 그렇게 되어 있음)
- 17-A에서 빠진 native 백엔드 SDK (Rust/Go/Node)도 같이 view API 노출

### 17-B.8 — Documentation & Migration Guide (0.5일)
- WINDOW_API.md에 CEF Views architecture 섹션
- 17-A → 17-B 변경사항 (사용자 facing API는 그대로)
- PLAN.md 17번 ✅ 완료 표기

**총 분량: ~13-17일**. 17-A 분량(약 14 commit) 대비 비슷하거나 약간 큼.

## 4. 미해결 위험

1. **titleBarStyle / transparent CefWindow 노출 부족** — 17-B.0 사전 조사에서 결론 안 나면 CefWindow 안 쓰는 hybrid로 후퇴할지 결정 trigger.
2. **Frameless drag region SujiKeyableWindow override 주입** — CefWindow가 만든 NSWindow에 우리 sendEvent: override 적용이 method swizzling 없이는 어려울 수도. method swizzling은 macOS sandboxing과 충돌 가능.
3. **dialog.m sheet / native menu / global shortcut 통합** — 모두 NSWindow handle 가정. CefWindow.GetWindowHandle()가 일관 작동하는지 검증.
4. **Phase 5 lifecycle 이벤트 (resize/focus/blur/move)** — 현재 NSWindowDelegate 부착. CefWindow에서는 CefWindowDelegate 콜백으로 재구현.
5. **CefBrowserView가 webContents API 호환성** — load_url/executeJavaScript/openDevTools 등 13+ webContents API가 CefBrowserView 기반에서 같은 동작하는지. CefBrowserView는 CefBrowser 래퍼라 호환 가능성 높음.

## 5. 결정 trigger / Go-No-Go

17-B.0 사전 조사 후:
- ✅ titleBarStyle/transparent/frameless drag 모두 CefWindow API 또는 GetWindowHandle workaround로 해결 가능 → **Option F 진행**
- 🟡 일부만 가능 → 시각 옵션 trade-off 명시하고 부분 진행 (Phase 5의 macOS-specific 옵션 일부 손실 허용)
- ❌ 핵심 옵션 다수 손실 → 17-B는 CefBrowserView only(host는 NSWindow 유지) hybrid 후퇴 → multi-WebContentsView 안정성도 일부만 잡힘

## 6. 즉시 결정사항

- **17-A는 종료 (C 마무리)**: dynamic destroyView limitation 표기 + setViewVisible 토글 권장 + host close 자동 정리 패턴.
- **17-B는 별도 phase**로 plan/검증 trigger 후 진입.
- 17-A의 NSView 합성 코드는 17-B.6에서 폐기. 그때까지는 사용자 use case(view 만들고 host close까지 hold)는 안전 동작.

## 7. 참고 자료

- [CEF Forum — Multiple browser windows](https://magpcss.org/ceforum/viewtopic.php?f=6&t=19327)
- [CEF Forum — Correct way to handle multiple windows](https://www.magpcss.org/ceforum/viewtopic.php?f=6&t=19826)
- [CEF C++ API — CefBrowser](https://magpcss.org/ceforum/apidocs/projects/(default)/CefBrowser.html)
- [Electron #46203 — multi WebContentsView regression](https://github.com/electron/electron/issues/46203)
- [Electron WebContentsView API](https://www.electronjs.org/docs/latest/api/web-contents-view) — Electron architecture (CEF 안 씀, 직접 비교 N/A)
- `cefclient/browser/views_window.cc` — CEF Views runtime 샘플 코드 참고 대상
