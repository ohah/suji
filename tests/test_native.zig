//! 공용 TestNative — WindowManager.Native vtable stub + 호출 기록용.
//!
//! 여러 테스트 파일(window_manager_test, event_sink_test, window_stack_test, …)이
//! 같은 stub을 반복 정의했던 것을 한 곳으로 모음.

const std = @import("std");
const window = @import("window");

pub const TestNative = struct {
    next_handle: u64 = 1000,
    create_calls: usize = 0,
    destroy_calls: usize = 0,
    set_title_calls: usize = 0,
    set_bounds_calls: usize = 0,
    set_visible_calls: usize = 0,
    focus_calls: usize = 0,
    last_title: ?[]const u8 = null,
    last_bounds: ?window.Bounds = null,
    /// 마지막 createWindow에 전달된 옵션의 sub-struct/parent_id 캡처 (Phase 3 매핑 검증용).
    /// 슬라이스 멤버(title/url/background_color)는 얕은 복사 — caller가 src 수명 보장.
    last_appearance: ?window.Appearance = null,
    last_constraints: ?window.Constraints = null,
    last_parent_id: ?u32 = null,
    last_create_bounds: ?window.Bounds = null,

    // Phase 4-A: webContents 캡처
    load_url_calls: usize = 0,
    reload_calls: usize = 0,
    execute_js_calls: usize = 0,
    last_loaded_url: ?[]const u8 = null,
    last_reload_ignore_cache: ?bool = null,
    last_executed_js: ?[]const u8 = null,
    /// getUrl가 반환할 값 (테스트가 미리 세팅; 기본 null)
    stub_url: ?[]const u8 = null,
    /// isLoading 반환값 (기본 false)
    stub_is_loading: bool = false,

    // Phase 4-C: DevTools 캡처
    open_dev_tools_calls: usize = 0,
    close_dev_tools_calls: usize = 0,
    toggle_dev_tools_calls: usize = 0,
    /// is_dev_tools_opened 반환값. toggle/open/close가 자동 갱신.
    stub_dev_tools_opened: bool = false,

    // Phase 4-B: 줌 — set 호출이 stub_zoom_level 갱신 (get은 그 값 반환).
    set_zoom_level_calls: usize = 0,
    stub_zoom_level: f64 = 0,

    // Phase 4-E: 편집/검색 캡처. named struct — 인덱스 매핑 mismatch 회귀 차단
    // (이전엔 [6]usize + 인덱스로 호출자/검증자가 분리. 위치 바뀌면 silent 잘못 카운트).
    edit_calls: struct {
        undo: usize = 0,
        redo: usize = 0,
        cut: usize = 0,
        copy: usize = 0,
        paste: usize = 0,
        select_all: usize = 0,
    } = .{},
    find_calls: usize = 0,
    stop_find_calls: usize = 0,
    last_find_text: ?[]const u8 = null,
    last_find_forward: bool = true,
    last_find_match_case: bool = false,
    last_find_next: bool = false,
    last_stop_find_clear: bool = false,

    // Phase 4-D: 인쇄
    print_to_pdf_calls: usize = 0,
    last_print_path: ?[]const u8 = null,
    /// true이면 다음 create_window 호출이 error.NativeFailure 반환 후 자동 리셋.
    fail_next_create: bool = false,
    /// destroyWindow 콜백 도중 WM 상태 관찰용. 세팅 시 해당 WM에서 handle을 역조회해
    /// observed_destroyed_during_destroy에 기록 (CefNative의 DoClose 재진입 시나리오 시뮬레이션).
    observe_wm: ?*const window.WindowManager = null,
    observed_destroyed_during_destroy: ?bool = null,

    pub fn asNative(self: *TestNative) window.Native {
        return .{ .vtable = &vtable, .ctx = self };
    }

    const vtable: window.Native.VTable = .{
        .create_window = createWindow,
        .destroy_window = destroyWindow,
        .set_title = setTitle,
        .set_bounds = setBounds,
        .set_visible = setVisible,
        .focus = focus,
        .load_url = loadUrl,
        .reload = reload,
        .execute_javascript = executeJavascript,
        .get_url = getUrl,
        .is_loading = isLoading,
        .open_dev_tools = openDevTools,
        .close_dev_tools = closeDevTools,
        .is_dev_tools_opened = isDevToolsOpened,
        .toggle_dev_tools = toggleDevTools,
        .set_zoom_level = setZoomLevel,
        .get_zoom_level = getZoomLevel,
        .undo = makeEditFn("undo"),
        .redo = makeEditFn("redo"),
        .cut = makeEditFn("cut"),
        .copy = makeEditFn("copy"),
        .paste = makeEditFn("paste"),
        .select_all = makeEditFn("select_all"),
        .find_in_page = findInPage,
        .stop_find_in_page = stopFindInPage,
        .print_to_pdf = printToPDF,
    };

    /// edit_calls의 named 필드 카운트 증가. 잘못된 필드명은 컴파일 에러.
    fn makeEditFn(comptime field: []const u8) *const fn (?*anyopaque, u64) void {
        return struct {
            fn call(ctx: ?*anyopaque, _: u64) void {
                @field(fromCtx(ctx).edit_calls, field) += 1;
            }
        }.call;
    }

    fn fromCtx(ctx: ?*anyopaque) *TestNative {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn createWindow(ctx: ?*anyopaque, opts: *const window.CreateOptions) anyerror!u64 {
        const self = fromCtx(ctx);
        if (self.fail_next_create) {
            self.fail_next_create = false;
            return error.NativeFailure;
        }
        self.create_calls += 1;
        self.last_appearance = opts.appearance;
        self.last_constraints = opts.constraints;
        self.last_parent_id = opts.parent_id;
        self.last_create_bounds = opts.bounds;
        const handle = self.next_handle;
        self.next_handle += 1;
        return handle;
    }

    fn destroyWindow(ctx: ?*anyopaque, handle: u64) void {
        const self = fromCtx(ctx);
        self.destroy_calls += 1;
        if (self.observe_wm) |wm| {
            if (wm.findByNativeHandle(handle)) |id| {
                if (wm.get(id)) |w| self.observed_destroyed_during_destroy = w.destroyed;
            }
        }
    }

    fn setTitle(ctx: ?*anyopaque, _: u64, title: []const u8) void {
        const self = fromCtx(ctx);
        self.set_title_calls += 1;
        self.last_title = title;
    }

    fn setBounds(ctx: ?*anyopaque, _: u64, bounds: window.Bounds) void {
        const self = fromCtx(ctx);
        self.set_bounds_calls += 1;
        self.last_bounds = bounds;
    }

    fn setVisible(ctx: ?*anyopaque, _: u64, _: bool) void {
        fromCtx(ctx).set_visible_calls += 1;
    }

    fn focus(ctx: ?*anyopaque, _: u64) void {
        fromCtx(ctx).focus_calls += 1;
    }

    fn loadUrl(ctx: ?*anyopaque, _: u64, url: []const u8) void {
        const self = fromCtx(ctx);
        self.load_url_calls += 1;
        self.last_loaded_url = url;
    }

    fn reload(ctx: ?*anyopaque, _: u64, ignore_cache: bool) void {
        const self = fromCtx(ctx);
        self.reload_calls += 1;
        self.last_reload_ignore_cache = ignore_cache;
    }

    fn executeJavascript(ctx: ?*anyopaque, _: u64, code: []const u8) void {
        const self = fromCtx(ctx);
        self.execute_js_calls += 1;
        self.last_executed_js = code;
    }

    fn getUrl(ctx: ?*anyopaque, _: u64) ?[]const u8 {
        return fromCtx(ctx).stub_url;
    }

    fn isLoading(ctx: ?*anyopaque, _: u64) bool {
        return fromCtx(ctx).stub_is_loading;
    }

    fn openDevTools(ctx: ?*anyopaque, _: u64) void {
        const self = fromCtx(ctx);
        self.open_dev_tools_calls += 1;
        self.stub_dev_tools_opened = true;
    }

    fn closeDevTools(ctx: ?*anyopaque, _: u64) void {
        const self = fromCtx(ctx);
        self.close_dev_tools_calls += 1;
        self.stub_dev_tools_opened = false;
    }

    fn isDevToolsOpened(ctx: ?*anyopaque, _: u64) bool {
        return fromCtx(ctx).stub_dev_tools_opened;
    }

    fn toggleDevTools(ctx: ?*anyopaque, _: u64) void {
        const self = fromCtx(ctx);
        self.toggle_dev_tools_calls += 1;
        self.stub_dev_tools_opened = !self.stub_dev_tools_opened;
    }

    fn setZoomLevel(ctx: ?*anyopaque, _: u64, level: f64) void {
        const self = fromCtx(ctx);
        self.set_zoom_level_calls += 1;
        self.stub_zoom_level = level;
    }

    fn getZoomLevel(ctx: ?*anyopaque, _: u64) f64 {
        return fromCtx(ctx).stub_zoom_level;
    }

    fn findInPage(ctx: ?*anyopaque, _: u64, text: []const u8, forward: bool, match_case: bool, find_next: bool) void {
        const self = fromCtx(ctx);
        self.find_calls += 1;
        self.last_find_text = text;
        self.last_find_forward = forward;
        self.last_find_match_case = match_case;
        self.last_find_next = find_next;
    }

    fn stopFindInPage(ctx: ?*anyopaque, _: u64, clear_selection: bool) void {
        const self = fromCtx(ctx);
        self.stop_find_calls += 1;
        self.last_stop_find_clear = clear_selection;
    }

    fn printToPDF(ctx: ?*anyopaque, _: u64, path: []const u8) void {
        const self = fromCtx(ctx);
        self.print_to_pdf_calls += 1;
        self.last_print_path = path;
    }
};
