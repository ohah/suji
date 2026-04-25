# Suji Window Styles 예제

Phase 3 외형 옵션 데모 — `frame: false`, `transparent: true`, `parent`.

## 실행

```bash
cd examples/window-styles
suji dev
```

## 시작 시 떠 있는 3창

| 창 | 옵션 | 설명 |
|---|---|---|
| **Main** | 기본 (titled) | 일반 OS 윈도우. whoami / hud-toast 버튼 |
| **Frameless Panel** | `frame: false` | 타이틀바 없음 + 커스텀 drag region. 타이틀바 영역 드래그로 이동 |
| **Transparent HUD** | `frame: false`, `transparent: true`, `parent: "main"` | 둥근 모서리 + 반투명 + blur. 메인 창과 함께 이동 |

## 핵심 코드

**suji.json** — 선언적 다중 창:
```json
{
  "windows": [
    { "name": "main", "title": "Main", "width": 720, "height": 480, "url": "http://localhost:5173/" },
    { "name": "panel", "frame": false, "url": "http://localhost:5173/panel.html" },
    { "name": "hud", "frame": false, "transparent": true, "parent": "main",
      "url": "http://localhost:5173/overlay.html" }
  ]
}
```

**panel.html** — frameless drag region:
```css
.titlebar { -webkit-app-region: drag; }
.titlebar button { -webkit-app-region: no-drag; }
```

**overlay.html** — transparent + blur (vibrancy 흉내):
```css
html, body { background: transparent; }
.hud {
  background: rgba(28, 28, 30, 0.85);
  backdrop-filter: blur(20px);
  border-radius: 14px;
}
```

## sendTo 데모

메인 창에서 "HUD에 toast" 버튼 → Zig backend의 `hud-toast` 핸들러 → `suji.send('hud:toast', ...)` broadcast → HUD만 `on('hud:toast')` 구독해서 표시.

## 알려진 한계

**frameless 드래그 미동작**: `-webkit-app-region: drag` CSS는 HTML에 들어있지만 CEF Alloy 런타임에서 자동 라우팅되지 않아 **현재 frameless 창은 이동 불가**. 정식 해결은 CEF의 `cef_drag_handler_t.on_draggable_regions_changed` 콜백 + custom NSView hit-test wrapper — Phase 4 백로그 (PLAN.md 참조).

지금은 데모로 frame/transparent/parent 시각 효과만 확인 가능. 실제 앱에서 frameless 창이 필요하면 백로그 처리 후 사용 권장.

## 플랫폼

현재 frame/transparent/parent는 **macOS만 지원** (NSWindow API). Linux/Windows에서는 옵션이 무시되고 일반 창으로 뜸.

## DevTools Reload Sync 수동 검증 (Phase 4-C)

Electron 호환 — DevTools front-end 안에서 `Cmd+R` / `F5` / `Cmd+Shift+R` 누르면 inspectee(원래 창)을 reload (DevTools 자체가 self-reload 안 됨). 멀티 윈도우 동시 DevTools면 각 DevTools가 **자기 inspectee만** 매핑.

### 검증 순서

1. `cd examples/window-styles && bun install && suji dev` — Main + Panel + HUD 3창 시작.
2. **Main 창 클릭 → `Cmd+Shift+I`** → Main의 DevTools 창 열림.
3. **Panel 창 클릭 → `Cmd+Shift+I`** → Panel의 별 DevTools 창 열림 (총 5개 윈도우 = 3 사용자 + 2 DevTools).
4. **Main의 DevTools에서 `Cmd+R`** → Main만 reload, Panel 변동 X.
5. **Panel의 DevTools에서 `Cmd+R`** → Panel만 reload, Main 변동 X.
6. `Cmd+Shift+R` (cache 무시 hard reload), `F5` (외부 키보드)도 동일 패턴.

### 동작 원리

`openDevTools` 호출 시 `pending_devtools_inspectee = sender_id` 임시 기록 → CEF가 새 DevTools browser 생성 후 `onAfterCreated` 콜백에서 그 새 browser id를 inspectee와 매핑(`devtools_to_inspectee: AutoHashMap(u64, u64)`). 사용자가 DevTools 안에서 reload 키 누르면 `OnPreKeyEvent`의 sender id로 map 조회 → 있으면 inspectee를 대신 reload. CEF는 single UI thread라 race-free. `onBeforeClose`에서 stale 매핑 정리.

여러 DevTools 동시 열린 상태에서도 각 DevTools 매핑이 독립이라 정확히 자기 inspectee만 reload. `cef.zig` 정적 회귀 테스트로 패턴 보장 (`tests/window_manager_test.zig`).
