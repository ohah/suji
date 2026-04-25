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
