# BrowserWindow API 설계

Zig 코어가 모든 윈도우를 소유/관리하고, 각 언어 백엔드는 C ABI 함수 포인터를 통해 네이티브 API처럼 호출한다.

## 아키텍처

```
┌─────────────────────────────────────────────────────┐
│              Zig 코어 (항상 실행중)                     │
│                                                      │
│  WindowManager                                       │
│  ├── windows: HashMap(u32, Window)                   │
│  ├── next_id: u32                                    │
│  ├── create(opts) → u32                              │
│  ├── close(id)                                       │
│  ├── get(id) → *Window                               │
│  └── ...                                             │
│                                                      │
│  SujiWindowAPI (C ABI vtable)                        │
│  ├── create, close, destroy                          │
│  ├── set_title, get_title, ...                       │
│  └── 모든 BrowserWindow 메서드                        │
└──────────────────────┬───────────────────────────────┘
                       │
        ┌──────────────┼──────────────┬────────────────┐
        │              │              │                │
   Zig (직접)    Rust (C ABI)   Go (C ABI)    Node.js (C ABI)
   함수 호출     함수 포인터    함수 포인터   bridge.cc 경유
                       │
                Frontend JS만 CEF IPC 사용
```

### 호출 경로

| 백엔드 | 호출 방식 | JSON 직렬화 | IPC |
|--------|-----------|------------|-----|
| Zig | `WindowManager.create()` 직접 호출 | X | X |
| Rust | `SujiWindowAPI.create()` C 함수 포인터 | X | X |
| Go | `SujiWindowAPI.create()` C 함수 포인터 | X | X |
| Node.js | `SujiWindowAPI.create()` → bridge.cc N-API | X | X |
| Frontend JS | CEF ProcessMessage (`suji:window.*`) | O | O |

## SujiCore 확장

```zig
/// 기존 SujiCore에 window 필드 추가 + on 시그니처 변경 (SujiEvent 추가)
pub const SujiCore = extern struct {
    // 기존
    invoke: *const fn ([*c]const u8, [*c]const u8) callconv(.c) [*c]const u8,
    free: *const fn ([*c]const u8) callconv(.c) void,
    emit: *const fn ([*c]const u8, [*c]const u8) callconv(.c) void,
    on: *const fn ([*c]const u8, ?*const fn (*SujiEvent, [*c]const u8, [*c]const u8, ?*anyopaque) callconv(.c) void, ?*anyopaque) callconv(.c) u64,
    off: *const fn (u64) callconv(.c) void,
    register: *const fn ([*c]const u8) callconv(.c) void,

    // 신규: 윈도우 API
    window: *const SujiWindowAPI,
};

/// 이벤트 객체 — 모든 콜백의 첫 번째 파라미터
pub const SujiEvent = extern struct {
    default_prevented: i32 = 0,  // 0=false, 1=true
};
```

> **Breaking Change**: `on` 콜백 시그니처가 `fn(channel, data, ctx)` → `fn(event, channel, data, ctx)`로 변경됨.
> 기존 Rust SDK(`suji::on`), Go SDK(`suji.On`), Node.js bridge, EventBus 내부 모두 수정 필요.

## SujiWindowAPI (C ABI vtable)

모든 함수는 `callconv(.c)`이며, 문자열은 `[*c]const u8` (null-terminated).

### 원칙

- **ID 기반**: 모든 윈도우는 `u32` ID로 식별. 1부터 시작 (메인 윈도우 = 1). `0`은 "없음/실패"를 의미. 유효하지 않은 ID 전달 시 no-op (크래시 없음).
- **이름 기반 탐색**: `name` 옵션으로 고유 이름 부여, `from_name`으로 탐색 가능.
- **문자열 반환**: 코어가 할당, 호출자가 `free_string`으로 해제. 반환값이 `null`이면 해제 불필요.
- **bool 반환**: `i32` (0=false, 1=true) — C ABI 호환.
- **스레드 안전**: 모든 함수는 내부적으로 mutex 보호. 어떤 스레드에서든 호출 가능. 단, CEF UI 조작은 메인 스레드에서만 유효하므로 내부적으로 `cef_post_task`로 디스패치.
- **에러 처리**: `create`는 실패 시 `0` 반환. `from_name`도 못 찾으면 `0`. 삭제된 윈도우 ID에 대한 호출은 무시.

### 이름 중복 정책

윈도우 `name`은 고유 식별자. 중복 시 동작:

| `forceNew` | name 중복 시 | 설명 |
|------------|-------------|------|
| `false` (기본) | **기존 윈도우 ID 반환** | 싱글턴 패턴. "없으면 만들고, 있으면 가져와" |
| `true` | 기존 것 close → 새로 생성 | 항상 최신 옵션으로 재생성 |

```zig
// WindowManager.create 내부 로직
pub fn create(self: *WindowManager, opts_json: []const u8) u32 {
    const name = extractField(opts_json, "name");
    const force_new = extractBoolField(opts_json, "forceNew");

    if (name) |n| {
        if (self.findByName(n)) |existing| {
            if (force_new) {
                self.close(existing.id);    // 기존 것 닫기
            } else {
                return existing.id;         // 기존 것 반환
            }
        }
    }

    // 새 윈도우 생성...
}
```

**`name` 미지정 시**: 이름 없는 윈도우로 생성. 중복 검사 없음. `from_name`으로 찾을 수 없음.

이 방식의 장점:
- **멀티 백엔드 안전** — Rust가 만든 `"settings"` 창을 Go가 또 만들려 해도 기존 것이 반환됨
- **싱글턴 자연스러움** — 설정창, 대시보드 등 하나만 있어야 하는 윈도우에 적합
- **강제 갱신 가능** — `forceNew: true`로 옵션 변경 시 재생성

```zig
pub const SujiWindowAPI = extern struct {
    // ── 라이프사이클 ──
    create: *const fn (opts_json: [*c]const u8) callconv(.c) u32,
    close: *const fn (id: u32) callconv(.c) void,
    destroy: *const fn (id: u32) callconv(.c) void,
    is_destroyed: *const fn (id: u32) callconv(.c) i32,

    // ── 표시/숨김 ──
    show: *const fn (id: u32) callconv(.c) void,
    show_inactive: *const fn (id: u32) callconv(.c) void,
    hide: *const fn (id: u32) callconv(.c) void,
    is_visible: *const fn (id: u32) callconv(.c) i32,
    focus: *const fn (id: u32) callconv(.c) void,
    blur: *const fn (id: u32) callconv(.c) void,
    is_focused: *const fn (id: u32) callconv(.c) i32,

    // ── 타이틀/아이콘 ──
    set_title: *const fn (id: u32, title: [*c]const u8) callconv(.c) void,
    get_title: *const fn (id: u32) callconv(.c) [*c]const u8,
    set_icon: *const fn (id: u32, path: [*c]const u8) callconv(.c) void,

    // ── 크기/위치 ──
    set_bounds: *const fn (id: u32, x: i32, y: i32, w: i32, h: i32) callconv(.c) void,
    get_bounds: *const fn (id: u32, out_x: *i32, out_y: *i32, out_w: *i32, out_h: *i32) callconv(.c) void,
    set_size: *const fn (id: u32, w: i32, h: i32) callconv(.c) void,
    get_size: *const fn (id: u32, out_w: *i32, out_h: *i32) callconv(.c) void,
    set_position: *const fn (id: u32, x: i32, y: i32) callconv(.c) void,
    get_position: *const fn (id: u32, out_x: *i32, out_y: *i32) callconv(.c) void,
    center: *const fn (id: u32) callconv(.c) void,
    set_content_bounds: *const fn (id: u32, x: i32, y: i32, w: i32, h: i32) callconv(.c) void,
    get_content_bounds: *const fn (id: u32, out_x: *i32, out_y: *i32, out_w: *i32, out_h: *i32) callconv(.c) void,
    set_content_size: *const fn (id: u32, w: i32, h: i32) callconv(.c) void,
    get_content_size: *const fn (id: u32, out_w: *i32, out_h: *i32) callconv(.c) void,

    // ── 크기 제약 ──
    set_minimum_size: *const fn (id: u32, w: i32, h: i32) callconv(.c) void,
    get_minimum_size: *const fn (id: u32, out_w: *i32, out_h: *i32) callconv(.c) void,
    set_maximum_size: *const fn (id: u32, w: i32, h: i32) callconv(.c) void,
    get_maximum_size: *const fn (id: u32, out_w: *i32, out_h: *i32) callconv(.c) void,
    set_aspect_ratio: *const fn (id: u32, ratio: f64) callconv(.c) void,

    // ── 윈도우 상태 ──
    minimize: *const fn (id: u32) callconv(.c) void,
    maximize: *const fn (id: u32) callconv(.c) void,
    restore: *const fn (id: u32) callconv(.c) void,
    unmaximize: *const fn (id: u32) callconv(.c) void,
    is_minimized: *const fn (id: u32) callconv(.c) i32,
    is_maximized: *const fn (id: u32) callconv(.c) i32,
    is_normal: *const fn (id: u32) callconv(.c) i32,
    get_normal_bounds: *const fn (id: u32, out_x: *i32, out_y: *i32, out_w: *i32, out_h: *i32) callconv(.c) void,

    // ── 전체화면 ──
    set_fullscreen: *const fn (id: u32, flag: i32) callconv(.c) void,
    is_fullscreen: *const fn (id: u32) callconv(.c) i32,
    set_fullscreenable: *const fn (id: u32, flag: i32) callconv(.c) void,
    is_fullscreenable: *const fn (id: u32) callconv(.c) i32,
    set_simple_fullscreen: *const fn (id: u32, flag: i32) callconv(.c) void,
    is_simple_fullscreen: *const fn (id: u32) callconv(.c) i32,

    // ── 윈도우 속성 ──
    set_resizable: *const fn (id: u32, flag: i32) callconv(.c) void,
    is_resizable: *const fn (id: u32) callconv(.c) i32,
    set_movable: *const fn (id: u32, flag: i32) callconv(.c) void,
    is_movable: *const fn (id: u32) callconv(.c) i32,
    set_minimizable: *const fn (id: u32, flag: i32) callconv(.c) void,
    is_minimizable: *const fn (id: u32) callconv(.c) i32,
    set_maximizable: *const fn (id: u32, flag: i32) callconv(.c) void,
    is_maximizable: *const fn (id: u32) callconv(.c) i32,
    set_closable: *const fn (id: u32, flag: i32) callconv(.c) void,
    is_closable: *const fn (id: u32) callconv(.c) i32,
    set_focusable: *const fn (id: u32, flag: i32) callconv(.c) void,

    // ── 레이어 순서 ──
    set_always_on_top: *const fn (id: u32, flag: i32) callconv(.c) void,
    is_always_on_top: *const fn (id: u32) callconv(.c) i32,
    move_top: *const fn (id: u32) callconv(.c) void,
    move_above: *const fn (id: u32, target_id: u32) callconv(.c) void,

    // ── 외형 ──
    set_opacity: *const fn (id: u32, opacity: f64) callconv(.c) void,
    get_opacity: *const fn (id: u32) callconv(.c) f64,
    set_background_color: *const fn (id: u32, color: [*c]const u8) callconv(.c) void,
    get_background_color: *const fn (id: u32) callconv(.c) [*c]const u8,
    set_has_shadow: *const fn (id: u32, flag: i32) callconv(.c) void,
    has_shadow: *const fn (id: u32) callconv(.c) i32,
    set_visible_on_all_workspaces: *const fn (id: u32, flag: i32) callconv(.c) void,
    is_visible_on_all_workspaces: *const fn (id: u32) callconv(.c) i32,

    // ── 키오스크 ──
    set_kiosk: *const fn (id: u32, flag: i32) callconv(.c) void,
    is_kiosk: *const fn (id: u32) callconv(.c) i32,

    // ── 작업표시줄 ──
    set_skip_taskbar: *const fn (id: u32, flag: i32) callconv(.c) void,
    set_progress_bar: *const fn (id: u32, progress: f64) callconv(.c) void,
    flash_frame: *const fn (id: u32, flag: i32) callconv(.c) void,

    // ── 부모/자식/모달 ──
    set_parent_window: *const fn (id: u32, parent_id: u32) callconv(.c) void,
    get_parent_window: *const fn (id: u32) callconv(.c) u32,
    get_child_windows: *const fn (id: u32, out_ids: [*c]u32, max_count: u32) callconv(.c) u32,
    is_modal: *const fn (id: u32) callconv(.c) i32,

    // ── 메뉴 ──
    set_menu_bar_visibility: *const fn (id: u32, flag: i32) callconv(.c) void,
    is_menu_bar_visible: *const fn (id: u32) callconv(.c) i32,
    set_auto_hide_menu_bar: *const fn (id: u32, flag: i32) callconv(.c) void,

    // ── 특수 ──
    set_ignore_mouse_events: *const fn (id: u32, flag: i32, forward: i32) callconv(.c) void,
    set_content_protection: *const fn (id: u32, flag: i32) callconv(.c) void,
    set_shape: *const fn (id: u32, rects_json: [*c]const u8) callconv(.c) void,
    get_native_window_handle: *const fn (id: u32) callconv(.c) ?*anyopaque,

    // ── 테마/기타 ──
    set_dark_theme: *const fn (id: u32, flag: i32) callconv(.c) void,
    set_background_throttling: *const fn (id: u32, flag: i32) callconv(.c) void,
    set_accessible_title: *const fn (id: u32, title: [*c]const u8) callconv(.c) void,
    get_accessible_title: *const fn (id: u32) callconv(.c) [*c]const u8,
    set_proxy_url: *const fn (id: u32, url: [*c]const u8) callconv(.c) void,

    // ── macOS 전용 ──
    set_window_button_visibility: *const fn (id: u32, flag: i32) callconv(.c) void,
    set_window_button_position: *const fn (id: u32, x: i32, y: i32) callconv(.c) void,
    get_window_button_position: *const fn (id: u32, out_x: *i32, out_y: *i32) callconv(.c) void,
    set_represented_filename: *const fn (id: u32, path: [*c]const u8) callconv(.c) void,
    get_represented_filename: *const fn (id: u32) callconv(.c) [*c]const u8,
    set_document_edited: *const fn (id: u32, flag: i32) callconv(.c) void,
    is_document_edited: *const fn (id: u32) callconv(.c) i32,
    set_sheet_offset: *const fn (id: u32, offset_y: f64) callconv(.c) void,
    set_vibrancy: *const fn (id: u32, vibrancy_type: [*c]const u8) callconv(.c) void,

    // ── Windows 전용 ──
    set_thumbar_buttons: *const fn (id: u32, buttons_json: [*c]const u8) callconv(.c) void,
    set_thumbnail_clip: *const fn (id: u32, x: i32, y: i32, w: i32, h: i32) callconv(.c) void,
    set_thumbnail_tooltip: *const fn (id: u32, tooltip: [*c]const u8) callconv(.c) void,
    set_app_details: *const fn (id: u32, details_json: [*c]const u8) callconv(.c) void,
    set_title_bar_overlay: *const fn (id: u32, opts_json: [*c]const u8) callconv(.c) void,
    set_background_material: *const fn (id: u32, material: [*c]const u8) callconv(.c) void,

    // ── webContents ──
    load_url: *const fn (id: u32, url: [*c]const u8) callconv(.c) void,
    load_file: *const fn (id: u32, path: [*c]const u8) callconv(.c) void,
    reload: *const fn (id: u32) callconv(.c) void,
    reload_ignoring_cache: *const fn (id: u32) callconv(.c) void,
    stop: *const fn (id: u32) callconv(.c) void,
    go_back: *const fn (id: u32) callconv(.c) void,
    go_forward: *const fn (id: u32) callconv(.c) void,
    can_go_back: *const fn (id: u32) callconv(.c) i32,
    can_go_forward: *const fn (id: u32) callconv(.c) i32,
    get_url: *const fn (id: u32) callconv(.c) [*c]const u8,
    get_web_title: *const fn (id: u32) callconv(.c) [*c]const u8,
    is_loading: *const fn (id: u32) callconv(.c) i32,
    execute_javascript: *const fn (id: u32, code: [*c]const u8) callconv(.c) void,
    insert_css: *const fn (id: u32, css: [*c]const u8) callconv(.c) void,

    // ── webContents: DevTools ──
    open_dev_tools: *const fn (id: u32) callconv(.c) void,
    close_dev_tools: *const fn (id: u32) callconv(.c) void,
    is_dev_tools_opened: *const fn (id: u32) callconv(.c) i32,
    toggle_dev_tools: *const fn (id: u32) callconv(.c) void,

    // ── webContents: 줌 ──
    set_zoom_factor: *const fn (id: u32, factor: f64) callconv(.c) void,
    get_zoom_factor: *const fn (id: u32) callconv(.c) f64,
    set_zoom_level: *const fn (id: u32, level: f64) callconv(.c) void,
    get_zoom_level: *const fn (id: u32) callconv(.c) f64,

    // ── webContents: 오디오 ──
    set_audio_muted: *const fn (id: u32, flag: i32) callconv(.c) void,
    is_audio_muted: *const fn (id: u32) callconv(.c) i32,

    // ── webContents: 인쇄/캡처 ──
    print_to_pdf: *const fn (id: u32, opts_json: [*c]const u8, callback: ?*const fn ([*c]const u8) callconv(.c) void) callconv(.c) void,
    capture_page: *const fn (id: u32, callback: ?*const fn ([*c]const u8, u32) callconv(.c) void) callconv(.c) void,

    // ── webContents: 편집 ──
    undo: *const fn (id: u32) callconv(.c) void,
    redo: *const fn (id: u32) callconv(.c) void,
    cut: *const fn (id: u32) callconv(.c) void,
    copy: *const fn (id: u32) callconv(.c) void,
    paste: *const fn (id: u32) callconv(.c) void,
    select_all: *const fn (id: u32) callconv(.c) void,

    // ── webContents: 검색 ──
    find_in_page: *const fn (id: u32, text: [*c]const u8) callconv(.c) void,
    stop_find_in_page: *const fn (id: u32) callconv(.c) void,

    // ── webContents: User-Agent ──
    set_user_agent: *const fn (id: u32, ua: [*c]const u8) callconv(.c) void,
    get_user_agent: *const fn (id: u32) callconv(.c) [*c]const u8,

    // ── webContents: IPC (특정 윈도우에 메시지 전송) ──
    send: *const fn (id: u32, channel: [*c]const u8, data: [*c]const u8) callconv(.c) void,

    // ── 정적 메서드 ──
    get_all_windows: *const fn (out_ids: [*c]u32, max_count: u32) callconv(.c) u32,
    get_focused_window: *const fn () callconv(.c) u32,
    from_id: *const fn (id: u32) callconv(.c) i32,
    from_name: *const fn (name: [*c]const u8) callconv(.c) u32,  // 0 = not found
    get_name: *const fn (id: u32) callconv(.c) [*c]const u8,
    set_name: *const fn (id: u32, name: [*c]const u8) callconv(.c) void,

    // ── 메모리 해제 ──
    free_string: *const fn (ptr: [*c]const u8) callconv(.c) void,
};
```

## suji.json `windows` 설정

기존 `window` 단수를 `windows` 배열로 교체. 각 항목이 하나의 윈도우 설정.

```json
{
  "app": { "name": "My App", "version": "1.0.0" },
  "windows": [
    {
      "name": "main",
      "title": "My App",
      "width": 1024,
      "height": 768,
      "devTools": true
    },
    {
      "name": "settings",
      "title": "Settings",
      "width": 600,
      "height": 400,
      "create": false,
      "devTools": false
    }
  ],
  "frontend": { "dir": "frontend", "dev_url": "http://localhost:5173" },
  "backend": { "lang": "zig", "entry": "." }
}
```

### 규칙

- **메인 윈도우**: `name: "main"` 또는 배열 첫 번째 항목. 앱 시작 시 자동 생성.
- **`create: false`**: 앱 시작 시 생성하지 않고 설정만 등록. 런타임에 이름으로 생성 시 등록된 설정 적용.
- **`create` 미지정 (기본 `true`)**: 앱 시작 시 자동 생성.
- **런타임 override**: `BrowserWindow.create({ name: "settings", width: 800 })`처럼 코드에서 옵션을 명시하면 suji.json 설정을 override.
- **`windows` 미지정 시**: 기본 메인 윈도우 1개 자동 생성 (title="Suji App", 1024x768).

## Window 생성 옵션 (전체)

`suji.json`의 각 윈도우 항목과 런타임 `create()` 옵션이 동일한 스키마를 공유.

```json
{
  "name": null,
  "create": true,
  "forceNew": false,

  "width": 800,
  "height": 600,
  "x": null,
  "y": null,
  "center": true,
  "minWidth": 0,
  "minHeight": 0,
  "maxWidth": 0,
  "maxHeight": 0,
  "useContentSize": false,

  "resizable": true,
  "movable": true,
  "minimizable": true,
  "maximizable": true,
  "closable": true,
  "focusable": true,
  "alwaysOnTop": false,
  "fullscreen": false,
  "fullscreenable": true,
  "skipTaskbar": false,
  "kiosk": false,

  "show": true,
  "title": "Suji App",
  "icon": null,
  "frame": true,
  "transparent": false,
  "opacity": 1.0,
  "backgroundColor": "#FFFFFF",
  "hasShadow": true,

  "titleBarStyle": "default",
  "titleBarOverlay": null,
  "trafficLightPosition": null,
  "vibrancy": null,
  "backgroundMaterial": "none",

  "parent": null,
  "modal": false,

  "autoHideMenuBar": false,
  "userAgent": null,

  "devTools": true,
  "contextIsolation": false,
  "incognito": false,
  "backgroundThrottling": true,

  "darkTheme": false,
  "acceptFirstMouse": false,
  "type": "normal",
  "roundedCorners": true,
  "thickFrame": true,
  "tabbingIdentifier": null,
  "hiddenInMissionControl": false,
  "accessibleTitle": null,

  "proxyUrl": null,
  "dataDirectory": null,

  "url": null,
  "file": null
}
```

### 프레임리스 윈도우 & CSS 드래그

`frame: false`일 때 OS 타이틀바가 없으므로, CSS로 드래그 영역을 지정해야 한다.

```css
/* 타이틀바 영역 — 드래그로 창 이동 */
.titlebar {
  -webkit-app-region: drag;
  height: 32px;
}

/* 타이틀바 안의 버튼 — 클릭 가능 */
.titlebar button {
  -webkit-app-region: no-drag;
}
```

- CEF(Chromium)가 `-webkit-app-region: drag`를 네이티브 윈도우 드래그로 자동 연결
- Electron, Tauri와 동일한 방식
- `frame: false` + `titleBarStyle: "hidden"` 조합으로 macOS 신호등만 남기고 커스텀 타이틀바 가능
- CEF Alloy 모드에서 동작 확인 필요 — 안 되면 macOS `isMovableByWindowBackground`, Windows `WM_NCHITTEST` 처리 추가

> **`protocol`은 윈도우별 옵션이 아님.** `suji://` scheme handler는 CEF에 전역 등록되므로 윈도우별로 다른 protocol을 쓸 수 없다. `protocol`은 suji.json 최상위 또는 `frontend` 설정에 유지.

## Zig 코어 내부 구조

### Window 구조체

```zig
/// src/core/window.zig (신규)
pub const Window = struct {
    id: u32,
    browser: *cef.c.cef_browser_t,
    native_window: ?*anyopaque,         // NSWindow* / HWND / GtkWindow*

    // 이름 (고유 식별자, 선택적)
    name: [128]u8 = undefined,
    name_len: usize = 0,

    // 옵션 (생성 시 설정, 런타임 변경 가능)
    title: [256]u8 = undefined,
    title_len: usize = 0,
    width: i32 = 800,
    height: i32 = 600,
    x: i32 = 0,
    y: i32 = 0,
    min_width: i32 = 0,
    min_height: i32 = 0,
    max_width: i32 = 0,
    max_height: i32 = 0,

    // 상태
    visible: bool = true,
    focused: bool = false,
    minimized: bool = false,
    maximized: bool = false,
    fullscreen: bool = false,
    destroyed: bool = false,

    // 속성
    resizable: bool = true,
    movable: bool = true,
    minimizable: bool = true,
    maximizable: bool = true,
    closable: bool = true,
    focusable: bool = true,
    always_on_top: bool = false,
    skip_taskbar: bool = false,
    kiosk: bool = false,
    modal: bool = false,
    frame: bool = true,
    transparent: bool = false,
    opacity: f64 = 1.0,
    has_shadow: bool = true,
    auto_hide_menu_bar: bool = false,
    user_agent: [512]u8 = undefined,
    user_agent_len: usize = 0,

    dev_tools: bool = true,
    context_isolation: bool = false,
    incognito: bool = false,
    background_throttling: bool = true,

    dark_theme: bool = false,
    accept_first_mouse: bool = false,
    window_type: WindowType = .normal,
    rounded_corners: bool = true,
    thick_frame: bool = true,
    tabbing_identifier: [128]u8 = undefined,
    tabbing_identifier_len: usize = 0,
    hidden_in_mission_control: bool = false,
    accessible_title: [256]u8 = undefined,
    accessible_title_len: usize = 0,

    proxy_url: [512]u8 = undefined,
    proxy_url_len: usize = 0,
    data_directory: [512]u8 = undefined,
    data_directory_len: usize = 0,

    // 관계
    parent_id: ?u32 = null,

    pub const WindowType = enum { normal, desktop, dock, toolbar, splash, notification };
};
```

### WindowManager 구조체

```zig
/// src/core/window_manager.zig (신규)
pub const WindowManager = struct {
    windows: std.AutoHashMap(u32, Window),
    allocator: std.mem.Allocator,
    next_id: u32 = 1,                  // 0은 "없음/실패", 1부터 할당
    mutex: std.Thread.Mutex = .{},
    event_bus: ?*events.EventBus = null,

    pub var global: ?*WindowManager = null;

    /// 프리셋: suji.json의 create:false 윈도우 설정 저장
    presets: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) WindowManager { ... }
    pub fn deinit(self: *WindowManager) void { ... }

    /// suji.json의 windows 배열 로딩 — create:true는 즉시 생성, create:false는 프리셋 등록
    pub fn loadFromConfig(self: *WindowManager, config_windows: []const WindowConfig) void { ... }

    /// 최초 윈도우 등록 (openWindow 시 호출, 특별한 권한 없음)
    pub fn registerFirstWindow(self: *WindowManager, browser: *cef.c.cef_browser_t, native: ?*anyopaque) u32 { ... }

    /// 새 윈도우 생성
    /// 1. name이 있으면 프리셋에서 기본값 로딩
    /// 2. opts_json의 값으로 override
    /// 3. name 중복 시 기존 윈도우 반환 (forceNew가 아니면)
    pub fn create(self: *WindowManager, opts_json: []const u8) u32 { ... }

    /// 윈도우 닫기 (mutex 밖에서 window:close 이벤트 발화, preventDefault 가능)
    pub fn close(self: *WindowManager, id: u32) void { ... }

    /// 강제 파괴 (이벤트 없음)
    pub fn destroy(self: *WindowManager, id: u32) void { ... }

    /// 마지막 윈도우가 닫혔는지 확인, quitOnAllWindowsClosed 정책 적용
    pub fn checkQuitPolicy(self: *WindowManager) bool { ... }

    pub fn get(self: *WindowManager, id: u32) ?*Window { ... }

    /// 이름으로 찾기
    pub fn findByName(self: *WindowManager, name: []const u8) ?*Window { ... }

    /// 정적 메서드
    pub fn getAllWindows(self: *WindowManager) []u32 { ... }
    pub fn getFocusedWindow(self: *WindowManager) ?u32 { ... }
};
```

## 이벤트

윈도우 이벤트는 기존 `EventBus`를 통해 전파. 채널 네이밍: `window:<event>`.

```
이벤트 데이터: { "windowId": <u32> [, 추가 필드] }
```

### 이벤트 콜백 시그니처 (Electron 방식)

모든 이벤트 콜백은 첫 번째 파라미터로 `SujiEvent` 포인터를 받는다.

```zig
/// C ABI 이벤트 객체
pub const SujiEvent = extern struct {
    default_prevented: i32 = 0,  // 0=false, 1=true
};

/// 통일된 콜백 시그니처
fn callback(
    event: *SujiEvent,
    channel: [*c]const u8,
    data: [*c]const u8,
    ctx: ?*anyopaque,
) callconv(.c) void;
```

- 모든 콜백이 동일한 시그니처 → `on` 등록 함수 하나로 통일
- 취소 불가능 이벤트에서 `preventDefault()` 호출해도 무시됨 (no-op)

**취소 가능 이벤트:** `window:close`, `window:will-resize`, `window:will-move`

**동작 흐름 (취소 가능 이벤트):**

1. WindowManager가 mutex 해제 후 `SujiEvent{}` 생성
2. 이벤트 발화 — 모든 리스너에 `*SujiEvent` 전달 (동기 실행)
3. 리스너가 `event.default_prevented = 1` 설정 가능
4. 모든 리스너 실행 완료 후 `default_prevented` 확인
5. `1`이면 원래 동작 중단 (윈도우 안 닫힘, 리사이즈 안 됨)

**SDK 사용 예시:**

```js
// Frontend JS / Node.js
suji.on('window:close', (event, data) => {
    event.preventDefault();  // 윈도우 안 닫힘
});
```

```rust
// Rust
suji::on("window:close", |event, data| {
    event.prevent_default();
});
```

```go
// Go
suji.On("window:close", func(event *suji.Event, data string) {
    event.PreventDefault()
})
```

**제약:**
- 취소 가능 이벤트는 **동기적으로** 리스너를 실행해야 함 (비동기 취소 불가)
- 취소 가능 이벤트 목록: `window:close`, `window:will-resize`, `window:will-move`

### 전체 이벤트 목록

| 이벤트 | 데이터 | 설명 |
|--------|--------|------|
| `window:created` | `{ windowId, name }` | 윈도우 생성 완료 (모든 백엔드에 브로드캐스트) |
| `window:ready-to-show` | `{ windowId }` | 최초 렌더링 완료 |
| `window:close` | `{ windowId }` | 닫기 전 (취소 가능) |
| `window:closed` | `{ windowId, name }` | 닫힌 후 |
| `window:focus` | `{ windowId }` | 포커스 획득 |
| `window:blur` | `{ windowId }` | 포커스 해제 |
| `window:show` | `{ windowId }` | 표시 |
| `window:hide` | `{ windowId }` | 숨김 |
| `window:maximize` | `{ windowId }` | 최대화 |
| `window:unmaximize` | `{ windowId }` | 최대화 해제 |
| `window:minimize` | `{ windowId }` | 최소화 |
| `window:restore` | `{ windowId }` | 최소화 복원 |
| `window:resize` | `{ windowId, width, height }` | 리사이즈 중 |
| `window:resized` | `{ windowId, width, height }` | 리사이즈 완료 |
| `window:will-resize` | `{ windowId, width, height }` | 리사이즈 전 (취소 가능) |
| `window:move` | `{ windowId, x, y }` | 이동 중 |
| `window:moved` | `{ windowId, x, y }` | 이동 완료 |
| `window:will-move` | `{ windowId, x, y }` | 이동 전 (취소 가능) |
| `window:enter-full-screen` | `{ windowId }` | 전체화면 진입 |
| `window:leave-full-screen` | `{ windowId }` | 전체화면 해제 |
| `window:enter-html-full-screen` | `{ windowId }` | HTML5 전체화면 진입 |
| `window:leave-html-full-screen` | `{ windowId }` | HTML5 전체화면 해제 |
| `window:always-on-top-changed` | `{ windowId, isAlwaysOnTop }` | alwaysOnTop 변경 |
| `window:page-title-updated` | `{ windowId, title }` | 문서 타이틀 변경 |
| `window:unresponsive` | `{ windowId }` | 페이지 응답 없음 |
| `window:responsive` | `{ windowId }` | 응답 복구 |
| `window:session-end` | `{ windowId }` | Windows 세션 종료 |
| `window:app-command` | `{ windowId, command }` | Windows 앱 명령 |
| `window:swipe` | `{ windowId, direction }` | macOS 스와이프 |
| `window:rotate-gesture` | `{ windowId, rotation }` | macOS 회전 |
| `window:sheet-begin` | `{ windowId }` | macOS 시트 열림 |
| `window:sheet-end` | `{ windowId }` | macOS 시트 닫힘 |

## 각 SDK API 예시

### Zig (코어 내부)

```zig
const suji = @import("suji");

// 직접 WindowManager 호출
const wm = suji.WindowManager.global orelse return;
const id = wm.create(
    \\{"title":"Settings","width":600,"height":400}
);
wm.setTitle(id, "변경");
wm.close(id);
```

### Rust

```rust
use suji::BrowserWindow;

let win = BrowserWindow::new(suji::WindowOptions {
    name: Some("settings"),
    title: "Settings",
    width: 600,
    height: 400,
    ..Default::default()
});

win.set_title("변경");
win.on("closed", || println!("닫힘"));
win.load_url("/settings.html");
win.close();

// 정적 메서드
let all = BrowserWindow::get_all_windows();
let focused = BrowserWindow::get_focused_window();
let settings = BrowserWindow::from_name("settings");  // 이름으로 찾기
```

SDK 내부:

```rust
// crates/suji-rs/src/window.rs
pub struct BrowserWindow {
    id: u32,
}

impl BrowserWindow {
    pub fn new(opts: WindowOptions) -> Self {
        let json = serde_json::to_string(&opts).unwrap();
        let c_json = CString::new(json).unwrap();
        let core = __SUJI_CORE.get().unwrap();
        let id = unsafe { ((*core).window.create)(c_json.as_ptr()) };
        Self { id }
    }

    pub fn set_title(&self, title: &str) {
        let c_title = CString::new(title).unwrap();
        let core = __SUJI_CORE.get().unwrap();
        unsafe { ((*core).window.set_title)(self.id, c_title.as_ptr()) };
    }

    pub fn close(&self) {
        let core = __SUJI_CORE.get().unwrap();
        unsafe { ((*core).window.close)(self.id) };
    }
}

impl Drop for BrowserWindow {
    fn drop(&mut self) {
        // 아무것도 안 함 — 코어가 소유.
        // 명시적으로 close()하지 않으면 윈도우는 계속 존재.
    }
}
```

### Go

```go
win := suji.NewBrowserWindow(suji.WindowOptions{
    Name:   "settings",
    Title:  "Settings",
    Width:  600,
    Height: 400,
})
win.SetTitle("변경")
win.On("closed", func() { fmt.Println("닫힘") })
win.LoadURL("/settings.html")
win.Close()

// 정적 메서드
all := suji.GetAllWindows()
focused := suji.GetFocusedWindow()
settings := suji.GetWindowByName("settings")  // 이름으로 찾기
```

SDK 내부:

```go
// sdks/suji-go/window.go
type BrowserWindow struct {
    ID uint32
}

func NewBrowserWindow(opts WindowOptions) *BrowserWindow {
    json, _ := json.Marshal(opts)
    cJSON := C.CString(string(json))
    defer C.free(unsafe.Pointer(cJSON))
    id := C.suji_window_create(unsafe.Pointer(core), cJSON)
    return &BrowserWindow{ID: uint32(id)}
}

func (w *BrowserWindow) SetTitle(title string) {
    cTitle := C.CString(title)
    defer C.free(unsafe.Pointer(cTitle))
    C.suji_window_set_title(unsafe.Pointer(core), C.uint(w.ID), cTitle)
}
```

### Node.js

```js
const { BrowserWindow } = require('@suji/node');

const win = new BrowserWindow({
    title: 'Settings',
    width: 600,
    height: 400,
});
win.setTitle('변경');
win.on('closed', () => console.log('닫힘'));
win.loadURL('/settings.html');
win.close();

// 정적 메서드
BrowserWindow.getAllWindows();
BrowserWindow.getFocusedWindow();
```

SDK 내부 (bridge.cc 에 N-API 바인딩 추가):

```cpp
// bridge.cc 에 추가
napi_value js_window_create(napi_env env, napi_callback_info info) {
    // JSON 문자열 받아서 g_core.window->create 호출
    char* opts = get_string_arg(env, info, 0);
    uint32_t id = g_core.window->create(opts);
    free(opts);
    napi_value result;
    napi_create_uint32(env, id, &result);
    return result;
}
```

### Frontend JS (CEF IPC 경유)

```js
// packages/suji-js/src/window.ts
const win = new BrowserWindow({
    title: 'Settings',
    width: 600,
    height: 400,
});
win.setTitle('변경');
win.on('closed', () => console.log('닫힘'));
win.loadURL('/settings.html');
win.close();
```

SDK 내부 — IPC invoke 래핑:

```ts
// packages/suji-js/src/window.ts
class BrowserWindow {
    private id: number;

    // constructor에서 await 불가 → 팩토리 패턴 사용
    private constructor(id: number) {
        this.id = id;
    }

    static async create(opts: WindowOptions): Promise<BrowserWindow> {
        const result = await suji.invoke('suji:window.create', opts);
        return new BrowserWindow(result.windowId);
    }

    setTitle(title: string) {
        suji.invoke('suji:window.setTitle', { id: this.id, title });
    }

    close() {
        suji.invoke('suji:window.close', { id: this.id });
    }

    on(event: string, callback: Function) {
        suji.on(`window:${event}`, (data: any) => {
            if (data.windowId === this.id) callback(data);
        });
    }

    static async fromName(name: string): Promise<BrowserWindow | null> {
        const result = await suji.invoke('suji:window.fromName', { name });
        return result.windowId ? new BrowserWindow(result.windowId) : null;
    }
}

// 사용:
const win = await BrowserWindow.create({ title: 'Settings', name: 'settings' });
```

## 윈도우 동등성 (Electron 방식)

모든 `BrowserWindow`는 동등하다. "메인 윈도우"라는 특별한 개념이 없다.

- 모든 윈도우는 동일한 API로 create/close/destroy 가능
- 어떤 윈도우도 특별 보호 대상이 아님
- 앱 종료 정책은 개발자가 이벤트로 제어

### 앱 종료 정책

기본 동작: `quitOnAllWindowsClosed: true` (suji.json `app` 설정).

| 시나리오 | 동작 |
|---------|------|
| 모든 윈도우 close | `quitOnAllWindowsClosed: true`면 앱 종료 |
| 일부 윈도우 close | 나머지 윈도우 유지, 앱 계속 |
| 부모 윈도우 close | 부모만 닫힘, 자식은 유지 (시각 관계 해제) |

개발자가 원하면 특정 윈도우 close 시 앱 종료를 직접 구현:

```js
// "특정 윈도우가 닫히면 앱 종료" 패턴
const main = await BrowserWindow.create({ name: 'main', ... });
main.on('closed', () => {
  suji.app.quit();
});
```

```json
// suji.json
{
  "app": {
    "name": "My App",
    "quitOnAllWindowsClosed": true
  }
}
```

### 부모-자식 관계

부모-자식은 **시각적 관계**만 의미한다 (Electron 방식).

- 자식이 부모 위에 항상 표시됨 (z-order)
- `modal: true`면 부모 입력 차단
- 부모 close해도 **자식은 닫히지 않음** — 자식은 부모 없는 일반 윈도우가 됨
- 재귀 close 없음 → 순환 참조 검사 불필요

```zig
// main.zig openWindow() 에서
var window_manager = WindowManager.init(allocator);
window_manager.setGlobal();
// ... CEF 초기화 후, 최초 윈도우를 WindowManager에 등록
window_manager.registerFirstWindow(g_browser, g_window);
```

## 안정성 고려사항

### IPC 멀티 윈도우 타겟팅
- 현재 `evalJs()`가 `g_browser` 하나만 타겟 → **윈도우별 browser 포인터로 실행해야 함**
- `WindowManager`가 `id → *cef_browser_t` 매핑 보유, `evalJsForWindow(id, js)` 제공
- invoke 응답은 CEF의 `frame.send_process_message`가 올바른 렌더러로 보내므로 **이미 안전**
- 이벤트 브로드캐스트 시 모든 윈도우에 전파, 윈도우별 이벤트(`window:*`)는 `windowId` 필드로 구분

### Cmd+W 윈도우 닫기
- `onPreKeyEvent`에서 `Cmd+W`가 포커스된 브라우저의 `window:close` 이벤트 발화
- 리스너가 `preventDefault()` 하지 않으면 해당 윈도우 close
- 마지막 윈도우가 닫히면 `quitOnAllWindowsClosed` 정책에 따라 앱 종료 여부 결정

### cef_client_t 메모리 정리
- 각 윈도우는 독립된 `cef_client_t`를 힙 할당
- `onBeforeClose`에서: WindowManager에서 제거 → `cef_client_t` 힙 해제 → 네이티브 윈도우 참조 해제
- 최초 윈도우의 `cef_client_t`는 스태틱이므로 해제하지 않음 (CEF 초기화와 동일 생명주기)

### 플랫폼별 no-op 처리
- OS에 없는 기능 호출 시 **조용히 무시** (에러 아님)
- 호출자가 플랫폼 분기를 안 해도 코드가 모든 OS에서 동작

| 기능 | macOS | Windows | Linux |
|------|-------|---------|-------|
| 기본 윈도우 조작 (크기/위치/상태) | O | O | O |
| vibrancy | O | no-op | no-op |
| backgroundMaterial (Mica/Acrylic) | no-op | O | no-op |
| trafficLightPosition | O | no-op | no-op |
| titleBarOverlay | no-op | O | no-op |
| thumbarButtons | no-op | O | no-op |
| representedFilename | O | no-op | no-op |
| setDocumentEdited | O | no-op | no-op |
| acceptFirstMouse | O | no-op | no-op |
| roundedCorners | O | no-op | no-op |
| tabbingIdentifier | O | no-op | no-op |
| hiddenInMissionControl | O | no-op | no-op |
| thickFrame | no-op | O | no-op |
| darkTheme | O | O | O (GTK) |
| type (splash, toolbar 등) | O | O | 부분 지원 |

### 스레드 안전
- `WindowManager`의 모든 public 메서드는 `mutex`로 보호
- CEF 브라우저 조작은 반드시 UI 스레드에서 실행해야 함 → `cef_post_task(TID_UI, ...)` 사용
- C ABI 콜백은 임의 스레드에서 호출될 수 있으므로, vtable 함수 내부에서 UI 스레드로 디스패치

### 메모리 안전
- `get_title`, `get_url` 등 문자열 반환 함수는 코어가 `allocator.dupe()`로 복사본 할당
- 호출자는 반드시 `free_string`으로 해제 (안 하면 누수)
- `get_all_windows`는 호출자가 제공한 버퍼에 쓰므로 할당/해제 불필요
- 파괴된 윈도우 ID에 대한 모든 호출은 no-op (dangling pointer 방지)

### 윈도우 라이프사이클
- `close()`: `window:close` 이벤트 발화 (mutex 해제 후) → 리스너가 `preventDefault()` 가능 → 취소되지 않으면 CEF `close_browser` 호출 → `window:closed` 이벤트 → HashMap에서 제거
- `destroy()`: 이벤트 없이 즉시 `close_browser(force=1)` → HashMap에서 제거
- 부모 윈도우 close → 자식은 닫히지 않음 (부모 참조만 해제, 일반 윈도우가 됨)
- CEF 브라우저가 외부에서 닫힌 경우 (유저가 X 버튼 클릭): `onBeforeClose`에서 WindowManager에 통지 → HashMap에서 제거 → `window:closed` 이벤트
- 마지막 윈도우가 닫히면 `quitOnAllWindowsClosed` 정책에 따라 앱 종료

### SujiCore 하위 호환성
- `SujiCore`에 `window` 필드를 추가하면 기존 백엔드 바이너리와 ABI 비호환
- **해결**: `window` 필드는 **구조체 끝**에 추가. 기존 백엔드는 이 필드에 접근하지 않으므로 안전
- 새 SDK 버전부터 `window` 필드 사용. 이전 SDK는 그냥 무시
- `backend_init`에서 전달받는 `SujiCore` 포인터의 크기가 달라도, 기존 필드 오프셋은 동일

### contextIsolation
- `contextIsolation: false` (기본): 웹페이지가 `window.__suji__`에 직접 접근. 자기 앱 코드만 로드할 때 적합
- `contextIsolation: true`: `window.__suji__`를 별도 V8 world에서 생성하고, 웹페이지에는 `Object.freeze`된 프록시만 노출. 웹페이지가 bridge를 변조할 수 없음. 외부 URL 로드 시 권장
- `nodeIntegration`은 Suji에 없음 (렌더러에 Node.js가 없으므로 해당 없음)

### CEF 멀티 윈도우 주의사항
- 각 윈도우는 독립된 `cef_client_t`가 필요 (힙 할당)
- `cef_client_t`의 `on_process_message_received`에서 browser ID로 어떤 윈도우인지 식별
- DevTools 브라우저는 CEF가 내부 생성하므로 WindowManager에 등록하지 않음 (관리 대상 아님)
- DevTools 제어는 `open_dev_tools(id)` / `close_dev_tools(id)`로 해당 윈도우 기준 조작
- `devTools: false`인 윈도우는 DevTools 열기 시도를 모두 무시 (키보드 단축키 포함)
- 렌더러 프로세스는 브라우저별로 별도 V8 컨텍스트 → 각 윈도우의 `window.__suji__`는 독립

## 파일 구조

```
src/
├── core/
│   ├── window.zig              # Window 구조체 (신규)
│   └── window_manager.zig      # WindowManager + SujiWindowAPI vtable 구현 (신규)
├── platform/
│   └── cef.zig                 # createBrowser를 멀티 윈도우 지원으로 확장
├── backends/
│   └── loader.zig              # SujiCore에 window 필드 추가
```

## 구현 단계

### Phase 1: 기반 (PoC ✅ 완료)
- `Window` 구조체 + `WindowManager` 구조체
- `SujiWindowAPI` vtable (create, close, destroy, set_title, get_title, from_name, get_name, set_name)
- `SujiCore.window` 필드 추가 (구조체 끝에 배치)
- CEF 멀티 브라우저 생성 (`cef_browser_host_create_browser_sync` 여러 번 호출)
- name 중복 시 기존 윈도우 반환 / `forceNew` 시 재생성
- **검증**: PoC로 두 번째 윈도우 생성 확인 완료

### Phase 2: 이벤트 시그니처 변경 + 윈도우 제어
- EventBus 콜백 시그니처에 `*SujiEvent` 첫 번째 파라미터 추가 (breaking change)
- 기존 `on` 사용처 일괄 수정 (Rust SDK, Go SDK, Node.js bridge, EventBus 내부)
- `SujiEvent.default_prevented` 기반 취소 가능 이벤트 구현
- 크기/위치/상태 메서드 전부 구현
- 크기 제약 위반 시 클램프 (OS 네이티브 제약 활용)
- 네이티브 윈도우 조작 (macOS NSWindow / Linux / Windows)
- CEF 브라우저 → 네이티브 윈도우 매핑

### Phase 3: 외형/속성
- 프레임리스, 투명, titleBarStyle
- 크기 제약, always-on-top
- 부모-자식 (시각 관계만, 재귀 close 없음), 모달

### Phase 4: webContents
- 네비게이션, JS 실행, DevTools (devTools 옵션 반영)
- 줌, 오디오, 인쇄/캡처
- 편집 명령, 검색

### Phase 5: 이벤트
- CEF life span / keyboard / display 핸들러에서 이벤트 발화
- mutex 해제 후 이벤트 발화 (deadlock 방지, 방식 A)
- 취소 가능 이벤트: mutex 밖에서 동기 발화 후 `default_prevented` 확인
- `quitOnAllWindowsClosed` 정책 구현

### Phase 6: SDK
- Rust SDK: `BrowserWindow` struct
- Go SDK: `BrowserWindow` struct + bridge.c 확장
- Node.js SDK: bridge.cc N-API 바인딩 + `BrowserWindow` class
- Frontend JS SDK: IPC 래핑 `BrowserWindow` class (팩토리 패턴, `await` 필수)

### Phase 7: 보안/플랫폼 전용
- contextIsolation: V8 world 분리, Object.freeze 프록시
- macOS: vibrancy, traffic light, represented filename, 제스처
- Windows: thumbar, overlay, background material
- Linux: 해당 사항 구현

## 설계 결정 사항

### 1. Mutex Deadlock 방지 → 방식 A (mutex 밖 발화) ✅

일반 이벤트는 mutex 해제 후 발화. 취소 가능 이벤트(`window:close`, `window:will-resize`, `window:will-move`)는 상태 변경 전에 mutex 밖에서 동기 발화 후 `default_prevented` 확인.

### 2. config.zig → windows[] 전용 (하위 호환 없음) ✅

기존 `window` 단수 필드 지원 제거. `windows` 배열만 파싱. `windows` 미지정 시 기본 윈도우 1개 (title="Suji App", 1024x768) 자동 생성.

### 3. 메인 윈도우 개념 없음 (Electron 방식) ✅

모든 윈도우 동등. 앱 종료는 `quitOnAllWindowsClosed` 설정 또는 개발자가 이벤트로 제어.

### 4. 부모-자식 = 시각 관계만 (Electron 방식) ✅

부모 close해도 자식 안 닫힘 (부모 참조만 해제). 재귀 close 없음. 순환 참조 검사 불필요.

### 5. 크기 제약 → 클램프 (Electron 방식) ✅

`set_minimum_size(100,100)` 후 `set_size(50,50)` → 자동으로 100x100으로 클램프. OS 네이티브 제약 활용.

### 6. 이벤트 콜백 시그니처 → SujiEvent 통일 (Electron 방식) ✅

모든 콜백에 `*SujiEvent` 첫 번째 파라미터. 취소 불가능 이벤트에서 `preventDefault()` 호출해도 무시. 기존 `on` 시그니처 breaking change — 초기 단계이므로 지금 변경.

### 7. Frontend JS SDK → 팩토리 패턴 (await 필수) ✅

`await BrowserWindow.create()` 후에만 인스턴스 반환. 미완료 상태 접근 불가.

## 미해결 이슈

### 1. CEF 레퍼런스 카운팅

현재 `cef_client_t`의 `add_ref`/`release`가 no-op. 멀티 윈도우에서 각 client가 독립 힙 할당될 때 `onBeforeClose`에서의 해제 타이밍과 CEF 내부 참조 간 경합 가능.

**방안:** 각 힙 할당 `cef_client_t`에 `std.atomic.Value(i32)` 기반 ref count 구현. `release`에서 0 도달 시 `page_allocator.destroy()` 호출.

### 2. 윈도우별 URL 라우팅 (suji:// 프로토콜)

`suji://` scheme handler는 CEF에 전역 등록. 윈도우별 다른 페이지 로드 시의 라우팅:
- `suji://app/` — 기본 (index.html)
- `suji://app/settings` — SPA 라우트 (프론트엔드 라우터가 처리)
- `suji://app/settings.html` — 별도 HTML 파일
- 윈도우 옵션의 `url` 또는 `file` 필드로 지정

### 3. 핫 리로드 시 멀티 윈도우 처리

`watcher.zig`가 백엔드 핫 리로드 시:
- 프론트엔드 리로드: 모든 윈도우에 `location.reload()` 전파
- 백엔드 리로드: 윈도우 상태는 유지, 백엔드 핸들러만 재등록
- 윈도우 목록/설정은 WindowManager가 보존

## 테스트 계획

### 테스트 파일: `tests/window_test.zig`

WindowManager와 Window 구조체의 단위 테스트. CEF 의존성 없이 순수 로직만 검증.

#### 1. WindowManager CRUD

```
- create 기본 — 유효한 ID (≥ 1) 반환
- create 연속 — ID가 단조 증가 (1, 2, 3, ...)
- get — 존재하는 ID → *Window, 없는 ID → null
- close — close 후 get → null
- destroy — destroy 후 is_destroyed → true
- close 후 ID 재사용 안 함 — close(2) 후 create → 3 (2 아님)
```

#### 2. Name 기반 싱글턴

```
- create(name="settings") × 2 → 같은 ID 반환
- create(name="settings", forceNew=true) → 기존 close + 새 ID
- create(name=null) × 2 → 서로 다른 ID
- from_name("settings") → 올바른 ID
- from_name("nonexistent") → 0
- close 후 from_name → 0 (삭제된 name 조회 불가)
- set_name으로 이름 변경 후 from_name → 새 이름으로 탐색
```

#### 3. 부모-자식 관계 (시각 관계만)

```
- set_parent_window(child, parent) → get_parent_window(child) == parent
- 부모 close → 자식 유지 (부모 참조만 해제, get_parent_window → 0)
- 자식 close → 부모 유지
- get_child_windows 반환값 정확성
- 부모 close 후 자식의 modal 해제 확인
- set_parent(A, B) + set_parent(B, A) → 허용 (재귀 close 없으므로 안전)
```

#### 4. 앱 종료 정책 (quitOnAllWindowsClosed)

```
- 모든 윈도우 close → quitOnAllWindowsClosed=true면 앱 종료 트리거
- 일부 윈도우 close → 앱 계속
- quitOnAllWindowsClosed=false → 모든 윈도우 닫혀도 앱 계속
- 어떤 윈도우든 close/destroy 가능 (특별 보호 없음)
```

#### 5. 윈도우 상태 관리

```
- 기본값 검증 — visible=true, focused=false, resizable=true 등
- set/get 왕복 — set_title("A") → get_title == "A"
- 크기 제약 — set_minimum_size(100,100) → set_size(50,50) → 실제 크기 100x100으로 클램프
- 최대 크기 0 (무제한) — set_maximum_size(0,0) → 어떤 크기든 허용
- opacity 범위 — set_opacity(1.5) → 1.0으로 클램프, set_opacity(-0.1) → 0.0
```

#### 6. Destroyed 윈도우 안전성

```
- destroy 후 set_title → no-op (크래시 없음)
- destroy 후 get_title → null
- destroy 후 show/hide/focus/blur → no-op
- destroy 후 set_size/get_size → no-op
- destroy 후 close → no-op (이중 close 안전)
- 존재하지 않는 ID (9999) → 모든 함수 no-op
```

#### 7. 문자열 메모리

```
- get_title 반환 → free_string 호출 → 누수 없음
- get_title 반환값은 원본과 독립 (set_title 후에도 이전 반환값 유효)
- free_string(null) → 크래시 없음
- get_url, get_user_agent 등 모든 문자열 반환 함수 동일 검증
```

#### 8. 스레드 안전성

```
- 10개 스레드에서 동시 create → 모든 ID 고유, 누락 없음
- create + close 동시 — 일관된 상태 (use-after-free 없음)
- get + set_title 동시 — data race 없음
- getAllWindows 동시 호출 — 정확한 스냅샷
```

#### 9. 이벤트 통합

```
- create 시 "window:created" 발화 + windowId, name 포함
- close 시 "window:close" → "window:closed" 순서 보장
- "window:close" 리스너에서 preventDefault → 윈도우 안 닫힘
- "window:will-resize" preventDefault → 크기 변경 안 됨
- destroy 시 이벤트 없음 (설계대로)
- 이벤트 리스너 내에서 WindowManager 호출 → deadlock 없음
```

#### 10. suji.json 설정 파싱

```
- windows 배열 파싱 — 복수 윈도우 설정 로딩
- window 단수 → 파싱 에러 (하위 호환 없음)
- windows 미지정 → 기본 윈도우 1개 (1024x768, "Suji App")
- create: false → 프리셋 등록만 (WindowManager.presets에 저장)
- create: true (기본) → 앱 시작 시 자동 생성
- 프리셋 + 런타임 override — create(name="settings", width=800) → 프리셋의 다른 값 + width만 800
- 잘못된 값 (width: -1, opacity: 999) → 기본값 폴백 또는 클램프
```

#### 11. C ABI vtable

```
- SujiWindowAPI의 모든 필드가 non-null
- 각 함수 포인터 호출 시 올바른 함수로 디스패치
- 잘못된 ID 전달 → 모든 함수 no-op (크래시 없음)
- free_string으로 해제 후 재해제 → 안전 (double-free 방지)
```

### 테스트 파일: `tests/window_integration_test.zig`

CEF IPC를 통한 프론트엔드 ↔ WindowManager 통합 테스트.

```
- __core__ 채널 create_window 요청 → 유효한 browser_id 반환
- create_window JSON 파싱 — title, url, width, height 추출
- create_window 잘못된 JSON → 에러 응답 (크래시 없음)
- suji:window.create IPC → WindowManager.create 호출
- suji:window.setTitle IPC → 윈도우 타이틀 변경
- suji:window.close IPC → 윈도우 닫힘
- suji:window.fromName IPC → 올바른 windowId 반환
```
