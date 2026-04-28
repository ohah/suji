//! WindowManager: 멀티 윈도우의 메모리/정책 관리자.
//!
//! 설계 원칙 (docs/WINDOW_API.md 참조):
//! - id 기반 API, monotonic u32 (재사용 없음)
//! - name 중복 시 singleton (forceNew=true면 신규)
//! - destroyed 창에 메서드 호출 시 error.WindowDestroyed
//! - 플랫폼 조작은 Native vtable로 위임 → WindowManager는 CEF 없이 TDD 가능
//!
//! 스레드 모델 (docs/WINDOW_API.md#스레드-모델 참조):
//! - write API (create/destroy/close/setters)는 **main(CEF UI) 스레드 전용**
//! - read API (get/fromName)는 어느 스레드에서든 호출 가능 (mutex 보호)
//! - std.Io.Mutex는 defense-in-depth (read/write 레이스 방지 + 잘못된 스레드 호출 시
//!   데이터 경합 대신 직렬화 보장). 단일 스레드 계약이 깨져도 crash 대신 느려지기만 함.
//!
//! Phase 2 단위 테스트는 `tests/window_manager_test.zig` 참조.
//! 실제 CEF 통합은 `src/platform/cef.zig`의 CefNative가 VTable 구현.

const std = @import("std");
const builtin = @import("builtin");

pub const Bounds = struct {
    x: i32 = 0,
    y: i32 = 0,
    width: u32 = 800,
    height: u32 = 600,
};

pub const State = packed struct {
    visible: bool = true,
};

pub const events = struct {
    pub const created = "window:created";
    pub const close = "window:close";
    pub const closed = "window:closed";
    /// 마지막 live 윈도우가 파괴되어 남은 창이 0개가 되는 순간 발화. Electron의
    /// `app.on('window-all-closed', ...)`와 동등. macOS는 보통 이 시점에도 종료하지
    /// 않고 dock에 남지만, Windows/Linux는 여기서 quit하는 것이 관습.
    pub const all_closed = "window:all-closed";
    /// Phase 17-A WebContentsView 라이프사이클. payload: `{viewId, hostId}`.
    /// view-created는 createView 성공 시, view-destroyed는 destroyView/host destroy/
    /// destroyAll 어느 경로에서든 view가 정리될 때 한 번씩 발화.
    pub const view_created = "window:view-created";
    pub const view_destroyed = "window:view-destroyed";
    // Phase 5 — OS 라이프사이클. native delegate가 NSWindowDidMiniaturize 등을
    // 받아서 main.zig가 EventBus로 emit. payload = `{"windowId":N}`.
    pub const minimize = "window:minimize";
    pub const restore = "window:restore";
    pub const maximize = "window:maximize";
    pub const unmaximize = "window:unmaximize";
    pub const enter_full_screen = "window:enter-full-screen";
    pub const leave_full_screen = "window:leave-full-screen";
    /// CEF main frame 첫 load 완료 시 1회 발화 (Electron 호환). reload/navigate 후엔 X.
    pub const ready_to_show = "window:ready-to-show";
    /// 문서 `<title>` 변경 시. payload: `{"windowId":N,"title":"..."}`.
    pub const page_title_updated = "window:page-title-updated";
    /// `setVisible(true/false)` 호출 시 상태 전이가 있을 때만 발화 (멱등).
    pub const show = "window:show";
    pub const hide = "window:hide";
};

/// 외형 (시각 속성). frame/transparent/타이틀바 스타일/배경/그림자 등 "보이는 모양".
pub const Appearance = struct {
    /// false면 frameless — 타이틀바/리사이즈 핸들/시스템 보더 모두 제거 (Electron `frame: false`).
    frame: bool = true,
    /// true면 투명 배경 — NSWindow.opaque=false + clear color + 그림자 X. HTML body도 transparent여야 의미.
    transparent: bool = false,
    /// 16진수 RGB(A) (`#FFFFFF` / `#FFFFFFFF`). transparent=true와 함께 쓰면 transparent 우선.
    background_color: ?[]const u8 = null,
    /// Electron 호환: `.default` / `.hidden` / `.hidden_inset`.
    title_bar_style: TitleBarStyle = .default,
};

/// 제약 (창 크기/리사이즈/항상위/전체화면).
pub const Constraints = struct {
    /// false면 사용자 리사이즈 불가 (frame=true일 때만 의미; frameless는 이미 핸들 없음).
    resizable: bool = true,
    /// true면 NSFloatingWindowLevel — 일반 창 위.
    always_on_top: bool = false,
    /// 최소/최대 콘텐츠 크기 (0이면 제한 없음).
    min_width: u32 = 0,
    min_height: u32 = 0,
    max_width: u32 = 0,
    max_height: u32 = 0,
    /// 시작 시 전체화면.
    fullscreen: bool = false,
};

/// min > max (max > 0인 경우만)면 max를 0(제한 없음)으로 reset.
/// Cocoa의 setContentMaxSize: 동작이 모호한 잘못된 입력을 정상화.
/// 사용자에게 한 번 안내해 silent fix를 자각시킴.
///
/// is_test 가드: zig 0.16 test runner는 `--listen=-` IPC 모드에서 자식 프로세스의
/// stderr 노이즈가 많으면 가짜 "failed command"로 표시. 검증은 단위 테스트가 담당.
pub fn normalizeConstraints(c: *Constraints) void {
    if (c.max_width > 0 and c.min_width > c.max_width) {
        if (!builtin.is_test) std.debug.print(
            "[suji] warning: min_width({d}) > max_width({d}) — clearing max_width\n",
            .{ c.min_width, c.max_width },
        );
        c.max_width = 0;
    }
    if (c.max_height > 0 and c.min_height > c.max_height) {
        if (!builtin.is_test) std.debug.print(
            "[suji] warning: min_height({d}) > max_height({d}) — clearing max_height\n",
            .{ c.min_height, c.max_height },
        );
        c.max_height = 0;
    }
}

pub const CreateOptions = struct {
    name: ?[]const u8 = null,
    title: []const u8 = "Suji",
    /// 초기 로드 URL. null이면 Native 구현이 default URL 사용.
    url: ?[]const u8 = null,
    bounds: Bounds = .{},
    /// 부모 창 id. 비-null이면 시각 관계만 설정 (자식은 부모 위에 떠다니고 부모 이동 시 따라감).
    /// 재귀 close X — 부모 close해도 자식은 유지 (PLAN 핵심결정사항: orphan은 destroyAll만).
    parent_id: ?u32 = null,
    /// name 중복 시: false면 기존 id 반환(싱글턴), true면 새 창 생성
    force_new: bool = false,
    /// 외형 옵션 묶음 (frame / transparent / background / title_bar_style).
    appearance: Appearance = .{},
    /// 크기/위치 제약 묶음 (resizable / min·max / always_on_top / fullscreen).
    constraints: Constraints = .{},
};

/// `WindowManager.createView` 옵션. Electron `WebContentsView` 동등 — host 창의
/// contentView 안에 합성될 sub webContents. frame/transparent/title_bar_style 등 OS 창
/// 외형 옵션은 의도적으로 제공하지 않는다 (Electron WebContentsView도 webPreferences만
/// 받는 결정과 일치 — 투명도/외형은 host 창이 결정). bounds는 host contentView 기준
/// (top-left). name은 view 식별/디버깅용 — by_name 등록 X (view는 host scope).
pub const CreateViewOptions = struct {
    /// view를 합성할 host 창 id. live & kind=.window이어야 함.
    host_window_id: u32,
    name: ?[]const u8 = null,
    url: ?[]const u8 = null,
    bounds: Bounds = .{},
};

pub const TitleBarStyle = enum {
    default,
    hidden,
    hidden_inset,

    /// suji.json/IPC의 camelCase 문자열을 enum으로 매핑. 미인식은 .default.
    /// "hidden" → .hidden / "hiddenInset" → .hidden_inset.
    pub fn fromString(s: []const u8) TitleBarStyle {
        if (std.mem.eql(u8, s, "hidden")) return .hidden;
        if (std.mem.eql(u8, s, "hiddenInset")) return .hidden_inset;
        return .default;
    }
};

/// Window 객체의 종류. `.window`는 OS 네이티브 창(NSWindow/HWND/GtkWindow), `.view`는
/// 한 창의 contentView 안에 합성된 sub webContents (Electron `WebContentsView` 동등).
/// id 풀과 webContents API(load_url/executeJavascript/openDevTools/...)는 두 종류가 공유 —
/// kind는 lifecycle/계층 차이를 분기하는 데만 쓰임.
pub const WindowKind = enum { window, view };

pub const Window = struct {
    id: u32,
    /// .window: OS native 창 (NSWindow). .view: host 창 contentView 안에 합성된 sub-content.
    kind: WindowKind = .window,
    /// 플랫폼 native handle. .window: NSWindow*/HWND/GtkWindow*, .view: child NSView*(또는
    /// CEF browser id). 어떤 종류든 webContents API 디스패치는 이 handle로 통일.
    native_handle: u64,
    /// owned string (WindowManager.allocator 소유). null이면 이름 없는 창
    name: ?[]const u8,
    /// owned string. .view는 빈 문자열로 채워짐 (NSWindow가 없어 표시되지 않음).
    title: []const u8,
    bounds: Bounds,
    /// 시각 부모 창 id. **.window 전용** — Cocoa child window 관계 (자식이 부모 위에 떠다님).
    /// .view는 항상 null — view의 소속은 `host_window_id`가 표현.
    parent_id: ?u32,
    /// view가 합성된 host 창 id. **.view 전용** — .window는 항상 null.
    host_window_id: ?u32 = null,
    state: State,
    destroyed: bool = false,
    /// .view 전용. setViewVisible(false)로 숨겨졌는지 추적 (state.visible은 .window용).
    visible_in_host: bool = true,
};

/// 플랫폼 조작을 위임하는 추상화. CefNative가 CEF로 구현, TestNative가 stub.
pub const Native = struct {
    vtable: *const VTable,
    ctx: ?*anyopaque = null,

    pub const VTable = struct {
        create_window: *const fn (ctx: ?*anyopaque, opts: *const CreateOptions) anyerror!u64,
        destroy_window: *const fn (ctx: ?*anyopaque, handle: u64) void,
        set_title: *const fn (ctx: ?*anyopaque, handle: u64, title: []const u8) void,
        set_bounds: *const fn (ctx: ?*anyopaque, handle: u64, bounds: Bounds) void,
        set_visible: *const fn (ctx: ?*anyopaque, handle: u64, visible: bool) void,
        focus: *const fn (ctx: ?*anyopaque, handle: u64) void,
        // Phase 4-A: webContents 네비/JS
        load_url: *const fn (ctx: ?*anyopaque, handle: u64, url: []const u8) void,
        reload: *const fn (ctx: ?*anyopaque, handle: u64, ignore_cache: bool) void,
        execute_javascript: *const fn (ctx: ?*anyopaque, handle: u64, code: []const u8) void,
        get_url: *const fn (ctx: ?*anyopaque, handle: u64) ?[]const u8,
        is_loading: *const fn (ctx: ?*anyopaque, handle: u64) bool,
        // Phase 4-C: DevTools
        open_dev_tools: *const fn (ctx: ?*anyopaque, handle: u64) void,
        close_dev_tools: *const fn (ctx: ?*anyopaque, handle: u64) void,
        is_dev_tools_opened: *const fn (ctx: ?*anyopaque, handle: u64) bool,
        toggle_dev_tools: *const fn (ctx: ?*anyopaque, handle: u64) void,
        // Phase 4-B: 줌 — level만 노출. factor는 WM이 pow(1.2, level)로 변환
        // (Electron 호환 — `setZoomFactor(1.5)` ≈ `setZoomLevel(2.22)`).
        set_zoom_level: *const fn (ctx: ?*anyopaque, handle: u64, level: f64) void,
        get_zoom_level: *const fn (ctx: ?*anyopaque, handle: u64) f64,
        // Phase 4-E: 편집 (6 trivial — main frame에 위임) + 검색
        undo: *const fn (ctx: ?*anyopaque, handle: u64) void,
        redo: *const fn (ctx: ?*anyopaque, handle: u64) void,
        cut: *const fn (ctx: ?*anyopaque, handle: u64) void,
        copy: *const fn (ctx: ?*anyopaque, handle: u64) void,
        paste: *const fn (ctx: ?*anyopaque, handle: u64) void,
        select_all: *const fn (ctx: ?*anyopaque, handle: u64) void,
        find_in_page: *const fn (ctx: ?*anyopaque, handle: u64, text: []const u8, forward: bool, match_case: bool, find_next: bool) void,
        stop_find_in_page: *const fn (ctx: ?*anyopaque, handle: u64, clear_selection: bool) void,
        // Phase 4-D: 인쇄 — fire-and-forget. 결과는 cef.zig가 EventBus로 emit.
        print_to_pdf: *const fn (ctx: ?*anyopaque, handle: u64, path: []const u8) void,
        // Phase 17-A: WebContentsView (한 창 multi-content 합성).
        // create_view는 host의 contentView 안에 child NSView+CefBrowser를 부착하고 view handle 반환.
        // destroy_view/set_view_bounds/set_view_visible는 view handle 단위. reorder_view는
        // host_handle + view_handle + index_in_host로 z-order 재정렬 (0=bottom, ∞=top).
        create_view: *const fn (ctx: ?*anyopaque, host_handle: u64, opts: *const CreateViewOptions) anyerror!u64,
        destroy_view: *const fn (ctx: ?*anyopaque, view_handle: u64) void,
        set_view_bounds: *const fn (ctx: ?*anyopaque, view_handle: u64, bounds: Bounds) void,
        set_view_visible: *const fn (ctx: ?*anyopaque, view_handle: u64, visible: bool) void,
        reorder_view: *const fn (ctx: ?*anyopaque, host_handle: u64, view_handle: u64, index_in_host: u32) void,
        // Phase 5: 라이프사이클 제어 — minimize/maximize/fullscreen.
        // 모두 멱등 (이미 같은 상태면 no-op). is_* 게터는 platform 호출 결과 그대로 반환.
        minimize: *const fn (ctx: ?*anyopaque, handle: u64) void,
        restore_window: *const fn (ctx: ?*anyopaque, handle: u64) void,
        maximize: *const fn (ctx: ?*anyopaque, handle: u64) void,
        unmaximize: *const fn (ctx: ?*anyopaque, handle: u64) void,
        set_fullscreen: *const fn (ctx: ?*anyopaque, handle: u64, flag: bool) void,
        is_minimized: *const fn (ctx: ?*anyopaque, handle: u64) bool,
        is_maximized: *const fn (ctx: ?*anyopaque, handle: u64) bool,
        is_fullscreen: *const fn (ctx: ?*anyopaque, handle: u64) bool,
    };

    pub fn createWindow(self: Native, opts: *const CreateOptions) !u64 {
        return self.vtable.create_window(self.ctx, opts);
    }
    pub fn destroyWindow(self: Native, handle: u64) void {
        self.vtable.destroy_window(self.ctx, handle);
    }
    pub fn setTitle(self: Native, handle: u64, title: []const u8) void {
        self.vtable.set_title(self.ctx, handle, title);
    }
    pub fn setBounds(self: Native, handle: u64, bounds: Bounds) void {
        self.vtable.set_bounds(self.ctx, handle, bounds);
    }
    pub fn setVisible(self: Native, handle: u64, visible: bool) void {
        self.vtable.set_visible(self.ctx, handle, visible);
    }
    pub fn focus(self: Native, handle: u64) void {
        self.vtable.focus(self.ctx, handle);
    }
    pub fn loadUrl(self: Native, handle: u64, url: []const u8) void {
        self.vtable.load_url(self.ctx, handle, url);
    }
    pub fn reload(self: Native, handle: u64, ignore_cache: bool) void {
        self.vtable.reload(self.ctx, handle, ignore_cache);
    }
    pub fn executeJavascript(self: Native, handle: u64, code: []const u8) void {
        self.vtable.execute_javascript(self.ctx, handle, code);
    }
    pub fn getUrl(self: Native, handle: u64) ?[]const u8 {
        return self.vtable.get_url(self.ctx, handle);
    }
    pub fn isLoading(self: Native, handle: u64) bool {
        return self.vtable.is_loading(self.ctx, handle);
    }
    pub fn openDevTools(self: Native, handle: u64) void {
        self.vtable.open_dev_tools(self.ctx, handle);
    }
    pub fn closeDevTools(self: Native, handle: u64) void {
        self.vtable.close_dev_tools(self.ctx, handle);
    }
    pub fn isDevToolsOpened(self: Native, handle: u64) bool {
        return self.vtable.is_dev_tools_opened(self.ctx, handle);
    }
    pub fn toggleDevTools(self: Native, handle: u64) void {
        self.vtable.toggle_dev_tools(self.ctx, handle);
    }
    pub fn setZoomLevel(self: Native, handle: u64, level: f64) void {
        self.vtable.set_zoom_level(self.ctx, handle, level);
    }
    pub fn getZoomLevel(self: Native, handle: u64) f64 {
        return self.vtable.get_zoom_level(self.ctx, handle);
    }
    pub fn undo(self: Native, handle: u64) void {
        self.vtable.undo(self.ctx, handle);
    }
    pub fn redo(self: Native, handle: u64) void {
        self.vtable.redo(self.ctx, handle);
    }
    pub fn cut(self: Native, handle: u64) void {
        self.vtable.cut(self.ctx, handle);
    }
    pub fn copy(self: Native, handle: u64) void {
        self.vtable.copy(self.ctx, handle);
    }
    pub fn paste(self: Native, handle: u64) void {
        self.vtable.paste(self.ctx, handle);
    }
    pub fn selectAll(self: Native, handle: u64) void {
        self.vtable.select_all(self.ctx, handle);
    }
    pub fn findInPage(self: Native, handle: u64, text: []const u8, forward: bool, match_case: bool, find_next: bool) void {
        self.vtable.find_in_page(self.ctx, handle, text, forward, match_case, find_next);
    }
    pub fn stopFindInPage(self: Native, handle: u64, clear_selection: bool) void {
        self.vtable.stop_find_in_page(self.ctx, handle, clear_selection);
    }
    pub fn printToPDF(self: Native, handle: u64, path: []const u8) void {
        self.vtable.print_to_pdf(self.ctx, handle, path);
    }
    pub fn createView(self: Native, host_handle: u64, opts: *const CreateViewOptions) !u64 {
        return self.vtable.create_view(self.ctx, host_handle, opts);
    }
    pub fn destroyView(self: Native, view_handle: u64) void {
        self.vtable.destroy_view(self.ctx, view_handle);
    }
    pub fn setViewBounds(self: Native, view_handle: u64, bounds: Bounds) void {
        self.vtable.set_view_bounds(self.ctx, view_handle, bounds);
    }
    pub fn setViewVisible(self: Native, view_handle: u64, visible: bool) void {
        self.vtable.set_view_visible(self.ctx, view_handle, visible);
    }
    pub fn reorderView(self: Native, host_handle: u64, view_handle: u64, index_in_host: u32) void {
        self.vtable.reorder_view(self.ctx, host_handle, view_handle, index_in_host);
    }
    pub fn minimize(self: Native, handle: u64) void {
        self.vtable.minimize(self.ctx, handle);
    }
    pub fn restoreWindow(self: Native, handle: u64) void {
        self.vtable.restore_window(self.ctx, handle);
    }
    pub fn maximize(self: Native, handle: u64) void {
        self.vtable.maximize(self.ctx, handle);
    }
    pub fn unmaximize(self: Native, handle: u64) void {
        self.vtable.unmaximize(self.ctx, handle);
    }
    pub fn setFullscreen(self: Native, handle: u64, flag: bool) void {
        self.vtable.set_fullscreen(self.ctx, handle, flag);
    }
    pub fn isMinimized(self: Native, handle: u64) bool {
        return self.vtable.is_minimized(self.ctx, handle);
    }
    pub fn isMaximized(self: Native, handle: u64) bool {
        return self.vtable.is_maximized(self.ctx, handle);
    }
    pub fn isFullscreen(self: Native, handle: u64) bool {
        return self.vtable.is_fullscreen(self.ctx, handle);
    }
};

pub const Error = error{
    WindowNotFound,
    WindowDestroyed,
    NativeCreateFailed,
    OutOfMemory,
    /// name이 길이 제한 초과 또는 JSON-unsafe 문자 (`"`, `\`, control char) 포함
    InvalidName,
    /// 호출이 .window를 요구하는데 id가 .view를 가리킴 (예: setTitle을 view에 호출).
    NotAWindow,
    /// 호출이 .view를 요구하는데 id가 .window를 가리킴 (예: setViewBounds를 window에 호출).
    NotAView,
    /// addChildView/removeChildView/setTopView 등 host-child 호출에서 child가 host에
    /// 부착되어 있지 않음 (다른 host에 붙어있거나 분리 상태).
    ViewNotInHost,
};

/// WindowManager.create가 수용하는 name의 최대 바이트 길이.
/// JSON payload 루트에 `__window_name` 으로 주입되는 값이므로 과도한 길이는 거부.
pub const MAX_NAME_LEN: usize = 128;

/// `buildIdPayload`가 emit하는 lifecycle 이벤트 payload의 최대 크기 + 안전 마진.
///
/// 계산: `{"windowId":` (12) + u32 max (10) + `,"name":"` (9) + name (≤ MAX_NAME_LEN) + `"}` (2) = 161.
/// 256으로 잡아 미래에 한두 필드(짧은 것) 추가될 여유를 둔다 — 큰 값(URL 등)을 추가하려면
/// 이 상수도 함께 늘려야 함. 늘리지 않으면 호출부의 `*[PAYLOAD_BUF_SIZE]u8` 시그니처가
/// 컴파일러 단계에서 강제하여 회귀를 차단.
pub const PAYLOAD_BUF_SIZE: usize = 256;
comptime {
    // payload 포맷이 안전하게 들어갈 최소 크기 검증 (회귀 시 빌드 실패).
    const min_required = 12 + 10 + 9 + MAX_NAME_LEN + 2;
    if (PAYLOAD_BUF_SIZE < min_required) {
        @compileError("PAYLOAD_BUF_SIZE too small for current MAX_NAME_LEN");
    }
}

/// wire(JSON) 리터럴 bare 삽입에 안전한 문자열 (`"`, `\`, control char 없음).
/// window_ipc의 __window_name 주입에서 guard로도 사용.
pub fn isJsonSafeChars(s: []const u8) bool {
    for (s) |c| {
        if (c == '"' or c == '\\' or c < 0x20) return false;
    }
    return true;
}

/// name이 WM/wire 주입에 안전한지 검증. 빈 문자열은 별도로 처리하므로 non-empty slice 전제.
pub fn isValidName(name: []const u8) bool {
    if (name.len == 0 or name.len > MAX_NAME_LEN) return false;
    return isJsonSafeChars(name);
}

/// JSON 문자열 리터럴로 bare 삽입이 가능하도록 최소 이스케이프.
/// `"` → `\"`, `\` → `\\`, control char(`< 0x20`) → 건너뛴다(drop).
/// URL처럼 control char이 들어올 일 거의 없는 값에 사용 (event.window.url 주입 등).
/// out_buf 공간 부족 시 0 반환 → caller가 필드 전체 주입을 건너뛰어야.
pub fn escapeJsonChars(src: []const u8, out_buf: []u8) usize {
    var o: usize = 0;
    for (src) |c| {
        if (c < 0x20) continue; // drop control
        const needed: usize = if (c == '"' or c == '\\') 2 else 1;
        if (o + needed > out_buf.len) return 0;
        if (c == '"' or c == '\\') {
            out_buf[o] = '\\';
            out_buf[o + 1] = c;
            o += 2;
        } else {
            out_buf[o] = c;
            o += 1;
        }
    }
    return o;
}

/// 취소 가능 이벤트의 기본 동작 방지 상태. listener가 preventDefault() 호출.
pub const SujiEvent = struct {
    default_prevented: bool = false,

    pub fn preventDefault(self: *SujiEvent) void {
        self.default_prevented = true;
    }
};

/// WindowManager가 EventBus(또는 테스트 spy)에 이벤트를 흘려보내는 얇은 훅.
/// 프로덕션에서는 EventBus.emit/emitCancelable로 래핑.
pub const EventSink = struct {
    vtable: *const VTable,
    ctx: ?*anyopaque = null,

    pub const VTable = struct {
        emit: *const fn (ctx: ?*anyopaque, name: []const u8, data: []const u8) void,
        /// close 같은 취소 가능 이벤트. listener가 ev.preventDefault()를 호출하면
        /// WindowManager는 실제 파괴를 건너뛴다.
        emit_cancelable: *const fn (ctx: ?*anyopaque, name: []const u8, data: []const u8, ev: *SujiEvent) void,
    };

    pub fn emit(self: EventSink, name: []const u8, data: []const u8) void {
        self.vtable.emit(self.ctx, name, data);
    }
    pub fn emitCancelable(self: EventSink, name: []const u8, data: []const u8, ev: *SujiEvent) void {
        self.vtable.emit_cancelable(self.ctx, name, data, ev);
    }
};

pub const WindowManager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    native: Native,
    sink: ?EventSink = null,
    windows: std.AutoHashMap(u32, *Window),
    /// name → id (소유: name_store). fromName lookup에만 사용
    by_name: std.StringHashMap(u32),
    /// host window id → ordered view ids (마지막 원소 = top). Phase 17-A WebContentsView.
    /// addChildView가 entry를 생성/갱신, host destroy 시 entry 통째로 정리 + view 자동 destroy.
    /// view 자체는 `windows` HashMap에 동일 id 풀로 보관 — 이 맵은 z-order/소속만 추적.
    view_children: std.AutoHashMap(u32, std.ArrayListUnmanaged(u32)),
    next_id: u32 = 1,
    /// create/destroy/close/setters를 직렬화. 이벤트 발화는 lock 밖에서.
    lock: std.Io.Mutex = .init,

    pub var global: ?*WindowManager = null;

    pub fn init(allocator: std.mem.Allocator, io: std.Io, native: Native) WindowManager {
        return .{
            .allocator = allocator,
            .io = io,
            .native = native,
            .windows = std.AutoHashMap(u32, *Window).init(allocator),
            .by_name = std.StringHashMap(u32).init(allocator),
            .view_children = std.AutoHashMap(u32, std.ArrayListUnmanaged(u32)).init(allocator),
        };
    }

    /// EventBus 또는 테스트 spy를 주입. null 가능 (이벤트 발행 안 함).
    pub fn setEventSink(self: *WindowManager, sink: EventSink) void {
        self.sink = sink;
    }

    pub fn deinit(self: *WindowManager) void {
        // view_children의 ArrayList들을 먼저 정리 (window destroy 순서와 무관).
        var vc_it = self.view_children.valueIterator();
        while (vc_it.next()) |list_ptr| list_ptr.deinit(self.allocator);
        self.view_children.deinit();

        // 모든 창 destroy + 메모리 회수. kind에 따라 native.destroyWindow / destroyView 분기.
        var it = self.windows.iterator();
        while (it.next()) |entry| {
            const w = entry.value_ptr.*;
            if (!w.destroyed) switch (w.kind) {
                .window => self.native.destroyWindow(w.native_handle),
                .view => self.native.destroyView(w.native_handle),
            };
            self.allocator.free(w.title);
            if (w.name) |n| self.allocator.free(n);
            self.allocator.destroy(w);
        }
        self.windows.deinit();
        self.by_name.deinit();
    }

    /// 새 창 생성. name 중복 + forceNew=false면 기존 id 반환.
    ///
    /// name 정규화/정책:
    /// - 빈 문자열("")은 name=null로 취급 (by_name 등록 X)
    /// - forceNew=true면 기존 name 소유자를 빼앗지 않음. 새 창은 **익명**(Window.name=null)
    ///   으로 생성. fromName(n)은 계속 첫 창을 가리킴.
    pub fn create(self: *WindowManager, opts_in: CreateOptions) Error!u32 {
        var opts = opts_in;
        normalizeConstraints(&opts.constraints);

        // 빈 문자열 name 정규화
        const requested_name: ?[]const u8 = if (opts.name) |n|
            (if (n.len == 0) null else n)
        else
            null;
        if (requested_name) |n| {
            if (!isValidName(n)) return Error.InvalidName;
        }
        // forceNew=true인 경우 by_name 등록 X + Window.name=null (name 탈취 방지)
        const effective_name: ?[]const u8 = if (opts.force_new) null else requested_name;

        const CreateResult = struct { id: u32, is_new: bool };
        const result: CreateResult = blk: {
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);

            // name 싱글턴 정책 (forceNew=false 경로만 도달)
            if (effective_name) |name| {
                if (self.by_name.get(name)) |existing_id| {
                    break :blk .{ .id = existing_id, .is_new = false };
                }
            }

            // HashMap 용량을 먼저 확보해 put 실패를 원천 제거 (put 순간의 부분 성공 방지).
            // by_name.put이 OOM으로 조용히 실패하면 싱글턴 정책이 깨지므로 사전 할당 필수.
            self.windows.ensureUnusedCapacity(1) catch return Error.OutOfMemory;
            if (effective_name != null) {
                self.by_name.ensureUnusedCapacity(1) catch return Error.OutOfMemory;
            }

            const handle = self.native.createWindow(&opts) catch return Error.NativeCreateFailed;
            // 후속 allocation이 실패해도 native handle이 떠돌지 않도록 회수
            errdefer self.native.destroyWindow(handle);

            const win = self.allocator.create(Window) catch return Error.OutOfMemory;
            errdefer self.allocator.destroy(win);

            const owned_title = self.allocator.dupe(u8, opts.title) catch return Error.OutOfMemory;
            errdefer self.allocator.free(owned_title);

            const owned_name: ?[]const u8 = if (effective_name) |n|
                (self.allocator.dupe(u8, n) catch return Error.OutOfMemory)
            else
                null;
            errdefer if (owned_name) |n| self.allocator.free(n);

            const id = self.next_id;
            self.next_id += 1;

            win.* = .{
                .id = id,
                .native_handle = handle,
                .name = owned_name,
                .title = owned_title,
                .bounds = opts.bounds,
                .parent_id = opts.parent_id,
                .state = .{},
            };

            self.windows.putAssumeCapacity(id, win);
            if (owned_name) |n| {
                self.by_name.putAssumeCapacity(n, id);
            }
            break :blk .{ .id = id, .is_new = true };
        };

        // Phase 2: 이벤트 발화 (lock 밖 — listener가 다른 WindowManager 메서드 호출해도 deadlock 없음)
        if (result.is_new) {
            if (self.sink) |s| {
                var buf: [PAYLOAD_BUF_SIZE]u8 = undefined;
                // 새로 만든 창의 name (singleton 분기 없이 effective_name 그대로 — created는 항상 신규).
                const payload = buildIdPayload(&buf, result.id, effective_name);
                s.emit(events.created, payload);
            }
        }
        return result.id;
    }

    /// `{"windowId":N}` 또는 `{"windowId":N,"name":"..."}` payload.
    /// created/close/closed 공용. 표준화: name이 있고 JSON-safe면 함께 emit, 아니면 id만.
    /// 리스너는 항상 `windowId`를 받고, name은 optional로 처리.
    ///
    /// 시그니처: `*[N]u8` 고정 크기 array pointer로 받아 buf 크기를 컴파일타임에 검증.
    /// `MAX_NAME_LEN` 또는 추가 필드 도입으로 PAYLOAD_BUF_SIZE 미달 시 호출부에서 빌드 실패 →
    /// 잘린 invalid JSON이 emit되는 회귀를 정적 단계에서 차단.
    fn buildIdPayload(buf: *[PAYLOAD_BUF_SIZE]u8, id: u32, name: ?[]const u8) []const u8 {
        var w = std.Io.Writer.fixed(buf);
        const safe_name: ?[]const u8 = if (name) |n|
            (if (n.len > 0 and isJsonSafeChars(n)) n else null)
        else
            null;
        if (safe_name) |n| {
            w.print("{{\"windowId\":{d},\"name\":\"{s}\"}}", .{ id, n }) catch return w.buffered();
        } else {
            w.print("{{\"windowId\":{d}}}", .{id}) catch return w.buffered();
        }
        return w.buffered();
    }

    /// `{"viewId":N,"hostId":M}` payload. view-created/view-destroyed 공용.
    /// view name은 by_name에 등록 안 되고 디버깅용이라 payload에 미포함 (Electron WebContentsView도
    /// 이벤트 payload에 name 없음).
    fn buildViewPayload(buf: *[PAYLOAD_BUF_SIZE]u8, view_id: u32, host_id: u32) []const u8 {
        var w = std.Io.Writer.fixed(buf);
        w.print("{{\"viewId\":{d},\"hostId\":{d}}}", .{ view_id, host_id }) catch return w.buffered();
        return w.buffered();
    }

    /// lock 보유 상태에서 id → live window (not destroyed). 내부 헬퍼.
    fn getLiveLocked(self: *WindowManager, id: u32) Error!*Window {
        const win = self.windows.get(id) orelse return Error.WindowNotFound;
        if (win.destroyed) return Error.WindowDestroyed;
        return win;
    }

    /// `getLiveLocked + kind == .window` 단축. 호출 사이트가 12+ 곳이라 중복 제거.
    fn getLiveWindowLocked(self: *WindowManager, id: u32) Error!*Window {
        const w = try self.getLiveLocked(id);
        if (w.kind != .window) return Error.NotAWindow;
        return w;
    }

    /// `getLiveLocked + kind == .view` 단축.
    fn getLiveViewLocked(self: *WindowManager, id: u32) Error!*Window {
        const w = try self.getLiveLocked(id);
        if (w.kind != .view) return Error.NotAView;
        return w;
    }

    /// `list`에서 `view_id`와 같은 첫 항목을 제거. 제거됐으면 true.
    /// view_id 중복 삽입은 addChildView가 막으므로 첫 매치만 처리하면 충분.
    fn removeViewIdFromListLocked(list: *std.ArrayListUnmanaged(u32), view_id: u32) bool {
        const idx = std.mem.indexOfScalar(u32, list.items, view_id) orelse return false;
        _ = list.orderedRemove(idx);
        return true;
    }

    /// `view-destroyed` 이벤트에 필요한 식별 정보. host 정리 시 자동으로 함께 destroy된
    /// view들을 caller가 lock 풀린 후 emit하기 위해 수집. 모듈 내부 사용만.
    const DestroyedView = struct { view_id: u32, host_id: u32 };

    /// host에 부착된 모든 child view를 destroyed 마킹 + native.destroyView 호출 +
    /// view_children entry/by_name 정리. 정리된 view 정보는 `out`에 append (호출자가
    /// lock 풀린 후 view-destroyed 이벤트 발화). 호출자는 lock을 보유. 주 호출처: destroyLocked,
    /// markClosedExternal (host 닫힘 = view 자동 정리, "orphan은 destroyAll만" 정책의 view 버전).
    fn destroyChildViewsLocked(
        self: *WindowManager,
        host_id: u32,
        out: *std.ArrayListUnmanaged(DestroyedView),
    ) void {
        const kv = self.view_children.fetchRemove(host_id) orelse return;
        var list = kv.value;
        defer list.deinit(self.allocator);
        for (list.items) |child_view_id| {
            const child = self.windows.get(child_view_id) orelse continue;
            if (child.destroyed) continue;
            child.destroyed = true;
            if (child.name) |cn| _ = self.by_name.remove(cn);
            self.native.destroyView(child.native_handle);
            out.append(self.allocator, .{ .view_id = child_view_id, .host_id = host_id }) catch {};
        }
    }

    /// lock 이미 잡은 상태에서 실제 파괴. 내부 헬퍼.
    ///
    /// 순서가 중요: destroyed 마킹 + by_name 정리를 **native.destroyWindow 호출 전**에.
    /// 이유: native 구현(CefNative)이 close_browser를 호출하면 CEF가 동기로 DoClose
    /// 콜백을 발화할 수 있다. DoClose 훅이 "이 창은 이미 WM이 닫는 중"인지 판단하려면
    /// destroyed 플래그가 미리 세팅되어 있어야 한다.
    ///
    /// kind=.window인 경우 view_children에 등록된 자식 view들도 함께 destroy
    /// (orphan은 destroyAll만이라는 PLAN 정책의 view 버전 — host 없는 view는 의미 없음).
    /// kind=.view인 경우 host의 view_children list에서 자기 id를 제거.
    /// 정리된 view들은 `out`에 append — caller가 lock 풀린 후 view-destroyed 이벤트 발화.
    fn destroyLocked(
        self: *WindowManager,
        win: *Window,
        out: *std.ArrayListUnmanaged(DestroyedView),
    ) void {
        win.destroyed = true;
        if (win.name) |n| _ = self.by_name.remove(n);
        switch (win.kind) {
            .window => {
                self.destroyChildViewsLocked(win.id, out);
                self.native.destroyWindow(win.native_handle);
            },
            .view => {
                if (win.host_window_id) |host_id| {
                    if (self.view_children.getPtr(host_id)) |list_ptr| {
                        _ = removeViewIdFromListLocked(list_ptr, win.id);
                    }
                    out.append(self.allocator, .{ .view_id = win.id, .host_id = host_id }) catch {};
                }
                self.native.destroyView(win.native_handle);
            },
        }
    }

    /// `out` 리스트의 각 view에 대해 view-destroyed 이벤트 발화 + 메모리 정리.
    /// caller는 lock을 풀고 호출 (이벤트 listener가 wm 메서드 호출해도 deadlock 없음).
    fn emitViewDestroyedAndDeinit(
        self: *WindowManager,
        list: *std.ArrayListUnmanaged(DestroyedView),
    ) void {
        defer list.deinit(self.allocator);
        const s = self.sink orelse return;
        for (list.items) |info| {
            var buf: [PAYLOAD_BUF_SIZE]u8 = undefined;
            const payload = buildViewPayload(&buf, info.view_id, info.host_id);
            s.emit(events.view_destroyed, payload);
        }
    }

    /// 창 파괴 (강제). `window:closed` 이벤트는 `close()` 경로에서만 발화. 단 host destroy로
    /// 자동 정리되는 child view는 view-destroyed 이벤트 발화 (Electron WebContentsView 호환).
    pub fn destroy(self: *WindowManager, id: u32) Error!void {
        var live_after: usize = undefined;
        var destroyed_views: std.ArrayListUnmanaged(DestroyedView) = .empty;
        {
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);
            const win = try self.getLiveLocked(id);
            self.destroyLocked(win, &destroyed_views);
            live_after = self.liveCountLocked();
        }
        self.emitViewDestroyedAndDeinit(&destroyed_views);
        self.maybeEmitAllClosed(true, live_after);
    }

    /// 정책적 close. `window:close`(취소 가능) 발화 → preventDefault 아니면 파괴 +
    /// `window:closed`(단방향) 발화. 이벤트는 lock 밖에서 발화 (deadlock 방지).
    /// 반환값: true면 실제 파괴됨, false면 listener가 취소.
    pub fn close(self: *WindowManager, id: u32) Error!bool {
        // Phase 1: 유효성 확인 (lock). close는 .window 전용 — view는 destroyView 사용.
        {
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);
            _ = try self.getLiveWindowLocked(id);
        }

        // Phase 2: 취소 가능 이벤트 (lock 밖). name은 destroy 전에 캡처해서 close/closed 동일 사용.
        const name_snapshot: ?[]const u8 = if (self.windows.get(id)) |w| w.name else null;
        if (self.sink) |s| {
            var buf: [PAYLOAD_BUF_SIZE]u8 = undefined;
            const payload = buildIdPayload(&buf, id, name_snapshot);
            var ev: SujiEvent = .{};
            s.emitCancelable(events.close, payload, &ev);
            if (ev.default_prevented) return false;
        }

        // Phase 3: 실제 파괴 (lock, listener 도중 destroy됐는지 재확인)
        var live_after: usize = undefined;
        var destroyed_views: std.ArrayListUnmanaged(DestroyedView) = .empty;
        {
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);
            const win = try self.getLiveLocked(id);
            self.destroyLocked(win, &destroyed_views);
            live_after = self.liveCountLocked();
        }

        // Phase 4: 단방향 이벤트 (lock 밖) — view-destroyed 먼저 (자식 → 부모 순서),
        // 그 다음 host의 closed.
        self.emitViewDestroyedAndDeinit(&destroyed_views);
        if (self.sink) |s| {
            var buf: [PAYLOAD_BUF_SIZE]u8 = undefined;
            const payload = buildIdPayload(&buf, id, name_snapshot);
            s.emit(events.closed, payload);
        }
        self.maybeEmitAllClosed(true, live_after);
        return true;
    }

    /// 모든 창 파괴. 프로세스 종료 시 호출. .window는 `window:closed`, .view는
    /// `window:view-destroyed` 단방향 이벤트 발화. 취소 불가 (강제). all-or-nothing:
    /// 중간 할당 실패 시 어떤 창도 파괴하지 않음.
    pub fn destroyAll(self: *WindowManager) Error!void {
        const ClosedWindow = struct { id: u32, name: ?[]const u8 };
        var closed_windows: std.ArrayList(ClosedWindow) = .empty;
        defer closed_windows.deinit(self.allocator);
        var destroyed_views: std.ArrayListUnmanaged(DestroyedView) = .empty;
        defer destroyed_views.deinit(self.allocator);
        {
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);
            closed_windows.ensureTotalCapacity(self.allocator, self.windows.count()) catch
                return Error.OutOfMemory;
            destroyed_views.ensureTotalCapacity(self.allocator, self.windows.count()) catch
                return Error.OutOfMemory;
            var it = self.windows.iterator();
            while (it.next()) |entry| {
                const w = entry.value_ptr.*;
                if (w.destroyed) continue;
                // destroyLocked과 같은 이유로 destroyed 마킹을 native 호출 전에.
                w.destroyed = true;
                switch (w.kind) {
                    .window => {
                        self.native.destroyWindow(w.native_handle);
                        closed_windows.appendAssumeCapacity(.{ .id = w.id, .name = w.name });
                    },
                    .view => {
                        self.native.destroyView(w.native_handle);
                        destroyed_views.appendAssumeCapacity(.{
                            .view_id = w.id,
                            .host_id = w.host_window_id orelse 0,
                        });
                    },
                }
            }
            self.by_name.clearRetainingCapacity();
            // view_children의 ArrayList들 정리 후 맵 비우기 (entry 단위 deinit 누락 방지).
            var vc_it = self.view_children.valueIterator();
            while (vc_it.next()) |list_ptr| list_ptr.deinit(self.allocator);
            self.view_children.clearRetainingCapacity();
        }

        // Phase 2: 이벤트 발화 (lock 밖). view → window 순서 (Electron 자식 먼저 emit).
        if (self.sink) |s| {
            for (destroyed_views.items) |info| {
                var buf: [PAYLOAD_BUF_SIZE]u8 = undefined;
                const payload = buildViewPayload(&buf, info.view_id, info.host_id);
                s.emit(events.view_destroyed, payload);
            }
            for (closed_windows.items) |c| {
                var buf: [PAYLOAD_BUF_SIZE]u8 = undefined;
                const payload = buildIdPayload(&buf, c.id, c.name);
                s.emit(events.closed, payload);
            }
        }
        const destroyed_any = closed_windows.items.len > 0 or destroyed_views.items.len > 0;
        self.maybeEmitAllClosed(destroyed_any, 0);
    }

    pub fn get(self: *const WindowManager, id: u32) ?*const Window {
        return self.windows.get(id);
    }

    pub fn fromName(self: *const WindowManager, name: []const u8) ?u32 {
        return self.by_name.get(name);
    }

    /// native_handle로 WM id 역조회. destroyed 창도 포함 (CEF 콜백이 "이미 WM 처리됨"을
    /// 구별하려면 destroyed 상태로도 찾을 수 있어야).
    pub fn findByNativeHandle(self: *const WindowManager, handle: u64) ?u32 {
        var it = self.windows.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.native_handle == handle) {
                return entry.value_ptr.*.id;
            }
        }
        return null;
    }

    /// 외부 트리거(예: CEF DoClose)용 "물어보기" 버전. `window:close` 취소 가능 이벤트를
    /// 발화하고 preventDefault 여부를 반환. **실제 파괴/`window:closed` 이벤트는 발화 X**
    /// — 외부 layer가 파괴를 수행하고 나중에 markClosedExternal로 WM에 통지.
    pub fn tryClose(self: *WindowManager, id: u32) Error!bool {
        {
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);
            _ = try self.getLiveWindowLocked(id);
        }
        if (self.sink) |s| {
            var buf: [PAYLOAD_BUF_SIZE]u8 = undefined;
            const name_snapshot: ?[]const u8 = if (self.windows.get(id)) |w| w.name else null;
            const payload = buildIdPayload(&buf, id, name_snapshot);
            var ev: SujiEvent = .{};
            s.emitCancelable(events.close, payload, &ev);
            if (ev.default_prevented) return false;
        }
        return true;
    }

    /// 외부(예: CEF OnBeforeClose)가 이미 파괴한 윈도우를 WM에 알림.
    /// destroyed 마킹 + by_name 정리 + `window:closed` 이벤트 발화.
    /// **native.destroyWindow는 호출하지 않음** — 외부가 이미 처리.
    pub fn markClosedExternal(self: *WindowManager, id: u32) Error!void {
        var live_after: usize = undefined;
        var name_snapshot: ?[]const u8 = null;
        var destroyed_views: std.ArrayListUnmanaged(DestroyedView) = .empty;
        {
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);
            // markClosedExternal은 OS 윈도우 close 콜백 진입점이라 .window 전용.
            // view는 host close 시 destroyChildViewsLocked가 자동 정리.
            const win = try self.getLiveWindowLocked(id);
            self.destroyChildViewsLocked(win.id, &destroyed_views);
            win.destroyed = true;
            name_snapshot = win.name;
            if (win.name) |n| _ = self.by_name.remove(n);
            live_after = self.liveCountLocked();
        }
        self.emitViewDestroyedAndDeinit(&destroyed_views);
        if (self.sink) |s| {
            var buf: [PAYLOAD_BUF_SIZE]u8 = undefined;
            const payload = buildIdPayload(&buf, id, name_snapshot);
            s.emit(events.closed, payload);
        }
        self.maybeEmitAllClosed(true, live_after);
    }

    /// 살아있는(destroyed=false) 창의 개수. O(N). Lock 획득.
    pub fn liveCount(self: *WindowManager) usize {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        return self.liveCountLocked();
    }

    /// liveCount lock 보유 버전. 내부 헬퍼. **.window만** 카운트 — `window:all-closed`는
    /// OS 창 단위 시맨틱이라 view는 host에 종속이므로 별도 카운트 X.
    fn liveCountLocked(self: *const WindowManager) usize {
        var count: usize = 0;
        var it = self.windows.iterator();
        while (it.next()) |entry| {
            const w = entry.value_ptr.*;
            if (w.destroyed) continue;
            if (w.kind != .window) continue;
            count += 1;
        }
        return count;
    }

    /// `destroyed_any=true` & `live_count_after==0`이면 `window:all-closed` 발화.
    /// live_count는 caller가 lock 안에서 계산해 전달 (lock 재획득 회피).
    fn maybeEmitAllClosed(self: *WindowManager, destroyed_any: bool, live_count_after: usize) void {
        if (!destroyed_any) return;
        if (live_count_after > 0) return;
        const s = self.sink orelse return;
        s.emit(events.all_closed, "{}");
    }

    pub fn setTitle(self: *WindowManager, id: u32, title: []const u8) Error!void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const win = try self.getLiveWindowLocked(id);
        const owned = self.allocator.dupe(u8, title) catch return Error.OutOfMemory;
        self.allocator.free(win.title);
        win.title = owned;
        self.native.setTitle(win.native_handle, title);
    }

    pub fn setBounds(self: *WindowManager, id: u32, bounds: Bounds) Error!void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const win = try self.getLiveWindowLocked(id);
        win.bounds = bounds;
        self.native.setBounds(win.native_handle, bounds);
    }

    /// 창 표시/숨김. 멱등 — 동일 visible 상태면 native 호출 + 이벤트 발화 모두 skip.
    /// 상태가 바뀐 경우만 `window:show` / `window:hide` 발화 (Electron 호환).
    pub fn setVisible(self: *WindowManager, id: u32, visible: bool) Error!void {
        // name은 lock 안에서 캡처 → lock 밖 emit에서 사용. Window는 lock 다시 잡기 전엔
        // free되지 않으므로 slice 수명 안전 (close()/markClosedExternal과 동일 패턴).
        const name_snapshot: ?[]const u8 = blk: {
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);
            const win = try self.getLiveWindowLocked(id);
            if (win.state.visible == visible) return;
            win.state.visible = visible;
            self.native.setVisible(win.native_handle, visible);
            break :blk win.name;
        };
        const sink = self.sink orelse return;
        var buf: [PAYLOAD_BUF_SIZE]u8 = undefined;
        const payload = buildIdPayload(&buf, id, name_snapshot);
        sink.emit(if (visible) events.show else events.hide, payload);
    }

    pub fn focus(self: *WindowManager, id: u32) Error!void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const win = try self.getLiveLocked(id);
        self.native.focus(win.native_handle);
    }

    // ==================== Phase 4-A: webContents (네비 / JS) ====================

    pub fn loadUrl(self: *WindowManager, id: u32, url: []const u8) Error!void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const win = try self.getLiveLocked(id);
        self.native.loadUrl(win.native_handle, url);
    }

    pub fn reload(self: *WindowManager, id: u32, ignore_cache: bool) Error!void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const win = try self.getLiveLocked(id);
        self.native.reload(win.native_handle, ignore_cache);
    }

    pub fn executeJavascript(self: *WindowManager, id: u32, code: []const u8) Error!void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const win = try self.getLiveLocked(id);
        self.native.executeJavascript(win.native_handle, code);
    }

    /// 현재 main frame URL을 반환. 캐시되어 있지 않으면 null.
    /// 반환 슬라이스의 수명은 native가 보장 (CEF는 BrowserEntry.url_cache에 보관).
    pub fn getUrl(self: *WindowManager, id: u32) Error!?[]const u8 {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const win = try self.getLiveLocked(id);
        return self.native.getUrl(win.native_handle);
    }

    pub fn isLoading(self: *WindowManager, id: u32) Error!bool {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const win = try self.getLiveLocked(id);
        return self.native.isLoading(win.native_handle);
    }

    // ==================== Phase 4-C: DevTools ====================

    pub fn openDevTools(self: *WindowManager, id: u32) Error!void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const win = try self.getLiveLocked(id);
        self.native.openDevTools(win.native_handle);
    }

    pub fn closeDevTools(self: *WindowManager, id: u32) Error!void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const win = try self.getLiveLocked(id);
        self.native.closeDevTools(win.native_handle);
    }

    pub fn isDevToolsOpened(self: *WindowManager, id: u32) Error!bool {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const win = try self.getLiveLocked(id);
        return self.native.isDevToolsOpened(win.native_handle);
    }

    pub fn toggleDevTools(self: *WindowManager, id: u32) Error!void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const win = try self.getLiveLocked(id);
        self.native.toggleDevTools(win.native_handle);
    }

    // ==================== Phase 4-B: 줌 ====================
    // CEF는 zoom_level만 노출 — Electron의 zoomFactor는 pow(1.2, level)로 변환.

    pub fn setZoomLevel(self: *WindowManager, id: u32, level: f64) Error!void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const win = try self.getLiveLocked(id);
        self.native.setZoomLevel(win.native_handle, level);
    }

    pub fn getZoomLevel(self: *WindowManager, id: u32) Error!f64 {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const win = try self.getLiveLocked(id);
        return self.native.getZoomLevel(win.native_handle);
    }

    /// Electron 호환 zoom factor↔level 변환 base. `pow(ZOOM_BASE, level) == factor`,
    /// `log(factor) / log(ZOOM_BASE) == level`.
    pub const ZOOM_BASE: f64 = 1.2;

    /// factor → level 변환. factor <= 0이면 0(기본 100%) — log 도메인 회피.
    pub fn setZoomFactor(self: *WindowManager, id: u32, factor: f64) Error!void {
        const level: f64 = if (factor > 0) @log(factor) / @log(ZOOM_BASE) else 0;
        return self.setZoomLevel(id, level);
    }

    pub fn getZoomFactor(self: *WindowManager, id: u32) Error!f64 {
        const level = try self.getZoomLevel(id);
        return std.math.pow(f64, ZOOM_BASE, level);
    }

    // ==================== Phase 4-E: 편집 / 검색 ====================
    // CEF는 frame 메서드 — view_source/del/paste_and_match_style은 일단 비제공
    // (Electron API에 없거나 잘 안 쓰임). 필요시 추가.

    pub fn undo(self: *WindowManager, id: u32) Error!void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const win = try self.getLiveLocked(id);
        self.native.undo(win.native_handle);
    }
    pub fn redo(self: *WindowManager, id: u32) Error!void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const win = try self.getLiveLocked(id);
        self.native.redo(win.native_handle);
    }
    pub fn cut(self: *WindowManager, id: u32) Error!void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const win = try self.getLiveLocked(id);
        self.native.cut(win.native_handle);
    }
    pub fn copy(self: *WindowManager, id: u32) Error!void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const win = try self.getLiveLocked(id);
        self.native.copy(win.native_handle);
    }
    pub fn paste(self: *WindowManager, id: u32) Error!void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const win = try self.getLiveLocked(id);
        self.native.paste(win.native_handle);
    }
    pub fn selectAll(self: *WindowManager, id: u32) Error!void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const win = try self.getLiveLocked(id);
        self.native.selectAll(win.native_handle);
    }

    pub fn findInPage(self: *WindowManager, id: u32, text: []const u8, forward: bool, match_case: bool, find_next: bool) Error!void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const win = try self.getLiveLocked(id);
        self.native.findInPage(win.native_handle, text, forward, match_case, find_next);
    }

    pub fn stopFindInPage(self: *WindowManager, id: u32, clear_selection: bool) Error!void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const win = try self.getLiveLocked(id);
        self.native.stopFindInPage(win.native_handle, clear_selection);
    }

    // ==================== Phase 4-D: 인쇄 ====================
    // PDF 저장은 비동기 — 호출 직후 ok 응답, 결과는 `window:pdf-print-finished`
    // 이벤트(`{windowId, path, success}`)로 분리. caller는 listener로 매핑.

    pub fn printToPDF(self: *WindowManager, id: u32, path: []const u8) Error!void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const win = try self.getLiveLocked(id);
        self.native.printToPDF(win.native_handle, path);
    }

    // ==================== Phase 17-A: WebContentsView ====================
    // 한 창의 contentView 안에 합성되는 sub webContents (Electron WebContentsView 동등).
    // id 풀과 webContents API(loadUrl/executeJavascript/openDevTools/...)는 .window와 공유 —
    // viewId를 그대로 이 메서드들에 넘기면 동작. .window 전용 메서드(setTitle/setBounds/
    // setVisible/close)는 .view에 호출 시 Error.NotAWindow.

    /// host 창 contentView 안에 새 view 합성. host는 live & kind=.window.
    /// view는 같은 id 풀에서 다음 id 발급 (재사용 X). 자동으로 host의 view_children top에
    /// 추가됨 — 이후 addChildView로 z-order 변경 가능.
    pub fn createView(self: *WindowManager, opts: CreateViewOptions) Error!u32 {
        if (opts.name) |n| {
            if (n.len > 0 and !isValidName(n)) return Error.InvalidName;
        }

        const id = blk: {
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);

            const requested_name: ?[]const u8 = if (opts.name) |n|
                (if (n.len == 0) null else n)
            else
                null;

            const host = try self.getLiveWindowLocked(opts.host_window_id);

            // 사전 capacity 확보 — put 단계의 부분 성공 방지.
            self.windows.ensureUnusedCapacity(1) catch return Error.OutOfMemory;
            const gop = self.view_children.getOrPut(opts.host_window_id) catch return Error.OutOfMemory;
            const inserted_new_list = !gop.found_existing;
            if (inserted_new_list) gop.value_ptr.* = .empty;
            // 실패 경로에서 빈 entry가 view_children에 남지 않도록 정리. main thread 전제라 lock과의
            // 순서 race X.
            errdefer if (inserted_new_list) {
                if (self.view_children.fetchRemove(opts.host_window_id)) |kv| {
                    var v = kv.value;
                    v.deinit(self.allocator);
                }
            };
            const list_ptr = gop.value_ptr;
            list_ptr.ensureUnusedCapacity(self.allocator, 1) catch return Error.OutOfMemory;

            const handle = self.native.createView(host.native_handle, &opts) catch return Error.NativeCreateFailed;
            errdefer self.native.destroyView(handle);

            const view = self.allocator.create(Window) catch return Error.OutOfMemory;
            errdefer self.allocator.destroy(view);

            // Window.title은 항상 owned slice로 둔다 (.view는 표시되지 않지만 free 일관성을 위해 빈 문자열 dupe).
            const owned_title = self.allocator.dupe(u8, "") catch return Error.OutOfMemory;
            errdefer self.allocator.free(owned_title);

            const owned_name: ?[]const u8 = if (requested_name) |n|
                (self.allocator.dupe(u8, n) catch return Error.OutOfMemory)
            else
                null;
            errdefer if (owned_name) |n| self.allocator.free(n);

            const new_id = self.next_id;
            self.next_id += 1;

            view.* = .{
                .id = new_id,
                .kind = .view,
                .native_handle = handle,
                .name = owned_name,
                .title = owned_title,
                .bounds = opts.bounds,
                .parent_id = null,
                .host_window_id = opts.host_window_id,
                .state = .{},
                .visible_in_host = true,
            };

            self.windows.putAssumeCapacity(new_id, view);
            list_ptr.appendAssumeCapacity(new_id);
            break :blk new_id;
        };

        if (self.sink) |s| {
            var buf: [PAYLOAD_BUF_SIZE]u8 = undefined;
            const payload = buildViewPayload(&buf, id, opts.host_window_id);
            s.emit(events.view_created, payload);
        }
        return id;
    }

    /// view 파괴. .window면 NotAView. host의 view_children에서 자동 제거 +
    /// `view-destroyed` 이벤트 발화.
    pub fn destroyView(self: *WindowManager, view_id: u32) Error!void {
        var destroyed_views: std.ArrayListUnmanaged(DestroyedView) = .empty;
        {
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);
            const view = try self.getLiveViewLocked(view_id);
            self.destroyLocked(view, &destroyed_views);
        }
        self.emitViewDestroyedAndDeinit(&destroyed_views);
    }

    /// view를 host의 children list에 추가/재배치. index가 null이면 top(끝).
    /// 같은 view를 다시 add하면 기존 위치에서 빼고 새 위치에 삽입 (Electron WebContentsView idiom).
    /// **host 이동은 미지원** — view.host_window_id != host_id면 ViewNotInHost.
    pub fn addChildView(self: *WindowManager, host_id: u32, view_id: u32, index: ?usize) Error!void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);

        const host = try self.getLiveWindowLocked(host_id);
        const view = try self.getLiveViewLocked(view_id);
        if (view.host_window_id != host_id) return Error.ViewNotInHost;

        const gop = self.view_children.getOrPut(host_id) catch return Error.OutOfMemory;
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        const list_ptr = gop.value_ptr;

        _ = removeViewIdFromListLocked(list_ptr, view_id);
        const insert_idx: usize = if (index) |idx| @min(idx, list_ptr.items.len) else list_ptr.items.len;
        list_ptr.insert(self.allocator, insert_idx, view_id) catch return Error.OutOfMemory;

        const was_visible = view.visible_in_host;
        view.visible_in_host = true;
        // contentView.subviews에 우리 view들 + main browser CEF view가 함께 있어 우리 list의
        // index와 contentView.subviews index가 다른 namespace. 단일 reorder API로는 정확한 z-order
        // 유지 불가 — list 순서대로 모든 view를 sequential reorder하면 마지막 호출된 view가 top.
        for (list_ptr.items) |item_view_id| {
            const item = self.windows.get(item_view_id) orelse continue;
            self.native.reorderView(host.native_handle, item.native_handle, 0);
        }
        if (!was_visible) self.native.setViewVisible(view.native_handle, true);
    }

    /// view를 host의 children list에서 분리 (destroy X). native에서는 setHidden(true)로 처리.
    /// view 자체는 살아있으므로 다시 addChildView로 같은 host에 붙일 수 있다.
    pub fn removeChildView(self: *WindowManager, host_id: u32, view_id: u32) Error!void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);

        _ = try self.getLiveWindowLocked(host_id);
        const view = try self.getLiveViewLocked(view_id);
        if (view.host_window_id != host_id) return Error.ViewNotInHost;

        const list_ptr = self.view_children.getPtr(host_id) orelse return Error.ViewNotInHost;
        if (!removeViewIdFromListLocked(list_ptr, view_id)) return Error.ViewNotInHost;
        view.visible_in_host = false;
        self.native.setViewVisible(view.native_handle, false);
    }

    /// `addChildView(host, view, null)` 편의 alias. Electron 구 BrowserView의 setTopBrowserView 동등.
    pub fn setTopView(self: *WindowManager, host_id: u32, view_id: u32) Error!void {
        return self.addChildView(host_id, view_id, null);
    }

    pub fn setViewBounds(self: *WindowManager, view_id: u32, bounds: Bounds) Error!void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const view = try self.getLiveViewLocked(view_id);
        view.bounds = bounds;
        self.native.setViewBounds(view.native_handle, bounds);
    }

    pub fn setViewVisible(self: *WindowManager, view_id: u32, visible: bool) Error!void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const view = try self.getLiveViewLocked(view_id);
        if (view.visible_in_host == visible) return;
        view.visible_in_host = visible;
        self.native.setViewVisible(view.native_handle, visible);
    }

    /// host의 child view id들을 z-order 순(0=bottom, 마지막=top)으로 owned slice로 반환.
    /// caller가 `allocator.free(slice)`. host가 .view면 NotAWindow. view 없으면 빈 slice.
    pub fn getChildViews(self: *WindowManager, host_id: u32, allocator: std.mem.Allocator) Error![]u32 {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        _ = try self.getLiveWindowLocked(host_id);
        const items: []const u32 = if (self.view_children.get(host_id)) |list| list.items else &[_]u32{};
        const out = allocator.alloc(u32, items.len) catch return Error.OutOfMemory;
        @memcpy(out, items);
        return out;
    }

    // ==================== Phase 5: 라이프사이클 제어 ====================
    // 실제 emit은 native delegate가 상태 전이를 감지해 main.zig 핸들러를 통해 EventBus로
    // 발화 (이 함수가 직접 emit하지 않음 — OS가 거부할 수도 있고, 사용자가 traffic light로
    // 직접 조작한 경우도 동일 경로로 처리해야 일관됨).

    pub fn minimize(self: *WindowManager, id: u32) Error!void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const win = try self.getLiveWindowLocked(id);
        self.native.minimize(win.native_handle);
    }

    pub fn restoreWindow(self: *WindowManager, id: u32) Error!void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const win = try self.getLiveWindowLocked(id);
        self.native.restoreWindow(win.native_handle);
    }

    pub fn maximize(self: *WindowManager, id: u32) Error!void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const win = try self.getLiveWindowLocked(id);
        self.native.maximize(win.native_handle);
    }

    pub fn unmaximize(self: *WindowManager, id: u32) Error!void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const win = try self.getLiveWindowLocked(id);
        self.native.unmaximize(win.native_handle);
    }

    pub fn setFullscreen(self: *WindowManager, id: u32, flag: bool) Error!void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const win = try self.getLiveWindowLocked(id);
        self.native.setFullscreen(win.native_handle, flag);
    }

    pub fn isMinimized(self: *WindowManager, id: u32) Error!bool {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const win = try self.getLiveWindowLocked(id);
        return self.native.isMinimized(win.native_handle);
    }

    pub fn isMaximized(self: *WindowManager, id: u32) Error!bool {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const win = try self.getLiveWindowLocked(id);
        return self.native.isMaximized(win.native_handle);
    }

    pub fn isFullscreen(self: *WindowManager, id: u32) Error!bool {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const win = try self.getLiveWindowLocked(id);
        return self.native.isFullscreen(win.native_handle);
    }
};
