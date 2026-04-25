const std = @import("std");

pub const c = @cImport({
    @cDefine("CEF_API_VERSION", "999999");
    // macOS만: uchar.h 없어서 CEF가 char16_t를 typedef → 매크로로 선회피
    // Linux/Windows: uchar.h가 있으므로 매크로 불필요 (충돌 방지)
    if (is_macos) {
        @cDefine("char16_t", "unsigned short");
    }
    @cInclude("include/capi/cef_app_capi.h");
    @cInclude("include/capi/cef_browser_capi.h");
    @cInclude("include/capi/cef_client_capi.h");
    @cInclude("include/capi/cef_life_span_handler_capi.h");
    @cInclude("include/capi/cef_frame_capi.h");
    @cInclude("include/capi/cef_v8_capi.h");
    @cInclude("include/capi/cef_process_message_capi.h");
    @cInclude("include/capi/cef_render_process_handler_capi.h");
    @cInclude("include/capi/cef_keyboard_handler_capi.h");
    @cInclude("include/capi/cef_scheme_capi.h");
    @cInclude("include/capi/cef_resource_handler_capi.h");
    @cInclude("include/capi/cef_task_capi.h");
});

const builtin = @import("builtin");
const runtime = @import("runtime");
const window_mod = @import("window");
const window_ipc = @import("window_ipc");
const logger = @import("logger");

const log = logger.module("cef");

const is_macos = builtin.os.tag == .macos;
const is_linux = builtin.os.tag == .linux;

// Zig 0.16 translate-c가 objc/runtime.h의 block pointer(^) 문법을 파싱하지 못해서
// 필요한 심볼만 직접 extern 선언. 이 프로젝트에서 실제 사용하는 건 아래 4개뿐.
const objc = if (is_macos) struct {
    pub extern "c" fn sel_registerName(name: [*:0]const u8) ?*anyopaque;
    pub extern "c" fn objc_getClass(name: [*:0]const u8) ?*anyopaque;
    pub extern "c" fn objc_msgSend() void; // 호출부에서 구체 시그니처로 @ptrCast
    pub extern "c" fn class_addMethod(
        cls: ?*anyopaque,
        sel: ?*anyopaque,
        imp: *const fn () callconv(.c) void,
        types: [*:0]const u8,
    ) u8;
} else struct {};

// ============================================
// Public API
// ============================================

// TODO: CefConfig와 core/window.zig의 WindowConfig가 5개 필드 중복.
//       CEF 전환 완료 시 WindowConfig 제거하고 CefConfig로 통일.
pub const CefConfig = struct {
    title: [:0]const u8 = "Suji App",
    width: i32 = 1024,
    height: i32 = 768,
    url: ?[:0]const u8 = null,
    debug: bool = false,
    remote_debugging_port: i32 = 0,
};

/// IPC 핸들러 콜백 — 메인 프로세스에서 백엔드 호출용
/// channel, data를 받아 response_buf에 JSON 응답을 쓰고 슬라이스 반환.
/// 에러 시 null 반환.
pub const InvokeCallback = *const fn (channel: []const u8, data: []const u8, response_buf: []u8) ?[]const u8;
/// target=null: 모든 창으로 브로드캐스트. non-null: 해당 window id에만.
pub const EmitCallback = *const fn (target: ?u32, event: []const u8, data: []const u8) void;

var g_invoke_callback: ?InvokeCallback = null;
var g_emit_callback: ?EmitCallback = null;

/// 메인 프로세스에서 IPC 핸들러 등록
pub fn setInvokeHandler(cb: InvokeCallback) void {
    g_invoke_callback = cb;
}

pub fn setEmitHandler(cb: EmitCallback) void {
    g_emit_callback = cb;
}

var g_app: c.cef_app_t = undefined;
var g_app_initialized: bool = false;

/// Zig 0.16: std.os.argv 제거 → main이 runtime.args_vector에 저장한 값을
/// CEF 네이티브 포맷으로 변환한다.
fn makeMainArgs() c.cef_main_args_t {
    if (comptime builtin.os.tag == .windows) {
        return .{ .instance = null }; // HINSTANCE = GetModuleHandle
    }
    const vec = runtime.args_vector; // []const [*:0]const u8
    return .{
        .argc = @intCast(vec.len),
        .argv = @constCast(@ptrCast(vec.ptr)),
    };
}

/// CEF 서브프로세스 실행 (main 함수 초입에 호출)
/// 서브프로세스면 exit, 메인 프로세스면 반환
pub fn executeSubprocess() void {
    _ = c.cef_api_hash(c.CEF_API_VERSION, 0);
    if (!g_app_initialized) {
        initApp(&g_app);
        g_app_initialized = true;
    }

    var main_args = makeMainArgs();

    const code = c.cef_execute_process(&main_args, &g_app, null);
    if (code >= 0) {
        std.process.exit(@intCast(code));
    }
}

/// CEF 초기화
pub fn initialize(config: CefConfig) !void {
    if (!g_app_initialized) {
        _ = c.cef_api_hash(c.CEF_API_VERSION, 0);
        initApp(&g_app);
        g_app_initialized = true;
    }

    var main_args = makeMainArgs();

    var settings: c.cef_settings_t = undefined;
    zeroCefStruct(c.cef_settings_t, &settings);
    settings.log_severity = c.LOGSEVERITY_WARNING;
    settings.no_sandbox = 1;

    if (config.remote_debugging_port > 0) {
        settings.remote_debugging_port = config.remote_debugging_port;
    } else if (config.debug) {
        settings.remote_debugging_port = 9222;
    }

    // Subprocess path (자기 자신)
    var exe_buf: [1024]u8 = undefined;
    if (std.process.executablePath(runtime.io, &exe_buf)) |exe_len| {
        setCefString(&settings.browser_subprocess_path, exe_buf[0..exe_len]);
    } else |_| {}

    // CEF 경로 설정 (OS/arch별)
    const home: []const u8 = if (comptime builtin.os.tag == .windows)
        runtime.env("USERPROFILE") orelse "C:\\Users\\Default"
    else
        runtime.env("HOME") orelse "/tmp";
    const cef_platform = comptime switch (builtin.os.tag) {
        .macos => "macos-arm64",
        .linux => "linux-x86_64",
        .windows => "windows-x86_64",
        else => @compileError("unsupported OS"),
    };

    var fw_buf: [1024]u8 = undefined;
    var res_buf: [1024]u8 = undefined;
    var loc_buf: [1024]u8 = undefined;
    var cache_buf: [1024]u8 = undefined;

    if (is_macos) {
        setCefString(&settings.framework_dir_path, std.fmt.bufPrint(&fw_buf, "{s}/.suji/cef/{s}/Release/Chromium Embedded Framework.framework", .{ home, cef_platform }) catch return error.PathTooLong);
    }
    setCefString(&settings.resources_dir_path, std.fmt.bufPrint(&res_buf, "{s}/.suji/cef/{s}/Resources", .{ home, cef_platform }) catch return error.PathTooLong);
    setCefString(&settings.locales_dir_path, std.fmt.bufPrint(&loc_buf, "{s}/.suji/cef/{s}/Resources/locales", .{ home, cef_platform }) catch return error.PathTooLong);
    setCefString(&settings.root_cache_path, std.fmt.bufPrint(&cache_buf, "{s}/.suji/cef/cache", .{home}) catch return error.PathTooLong);

    // macOS: NSApplication 초기화 (cef_initialize 전에 필수)
    if (comptime is_macos) initNSApp();

    std.debug.print("[suji] CEF initializing...\n", .{});
    if (c.cef_initialize(&main_args, &settings, &g_app, null) != 1) {
        return error.CefInitFailed;
    }
    std.debug.print("[suji] CEF initialized\n", .{});

    // 커스텀 프로토콜 핸들러 등록 (dist 경로가 설정된 경우)
    if (g_dist_path_len > 0) {
        registerSchemeHandlerFactory();
    }
}

var g_devtools_client: c.cef_client_t = undefined;
var g_browser: ?*c.cef_browser_t = null; // 브라우저 참조 (이벤트 푸시용)

/// 전역 CEF 핸들러 초기화 (idempotent). CefNative.init에서 호출.
/// life_span_handler / keyboard_handler / devtools client — 모든 브라우저가 공유.
var g_handlers_initialized: bool = false;
fn ensureGlobalHandlers() void {
    if (g_handlers_initialized) return;
    initLifeSpanHandler();
    initKeyboardHandler();
    zeroCefStruct(c.cef_client_t, &g_devtools_client);
    initBaseRefCounted(&g_devtools_client.base);
    g_devtools_client.get_keyboard_handler = &getKeyboardHandler;
    g_handlers_initialized = true;
}

// ============================================
// CefNative — WindowManager의 Native vtable 구현
// ============================================
//
// 스레드 계약 (docs/WINDOW_API.md#스레드-모델):
// - 모든 vtable 함수는 CEF UI 스레드에서만 호출
// - 각 진입점에서 std.debug.assert로 방어
// - 잘못된 스레드 호출은 debug에서 crash, release에서 CEF CHECK abort

pub const CefNative = struct {
    /// sender 창 URL 캐시 사이즈. 일반적인 URL은 < 200 byte, query string 포함해도 256이면 충분.
    /// 초과 시 캐시는 비워두고 invoke 핫경로에서 frame.get_url로 폴백.
    pub const URL_CACHE_LEN: usize = 256;

    pub const BrowserEntry = struct {
        browser: *c.cef_browser_t,
        /// macOS: NSWindow 포인터 (destroyWindow에서 close 메시지 송신용).
        /// Linux/Windows: null (CEF가 자체 창 관리).
        ns_window: ?*anyopaque,
        /// 캐시된 main frame URL (OnAddressChange 콜백에서만 갱신).
        /// 매 invoke마다 frame.get_url alloc/free를 피하기 위함. len=0이면 미캐싱(폴백).
        url_cache_buf: [URL_CACHE_LEN]u8 = undefined,
        url_cache_len: usize = 0,
    };

    allocator: std.mem.Allocator,
    /// 모든 윈도우가 공유하는 client (콜백이 전부 module-global이라 공유 안전)
    client: c.cef_client_t = undefined,
    /// WindowManager의 native_handle (= CEF browser identifier를 u64로 캐스팅) → (browser, NSWindow).
    browsers: std.AutoHashMap(u64, BrowserEntry),
    /// opts.url이 null일 때 사용. "" 이면 CEF는 about:blank 수준의 빈 페이지를 로드.
    default_url: [:0]const u8 = "",

    pub fn init(allocator: std.mem.Allocator) CefNative {
        ensureGlobalHandlers();
        var self: CefNative = .{
            .allocator = allocator,
            .browsers = std.AutoHashMap(u64, BrowserEntry).init(allocator),
        };
        initClient(&self.client);
        return self;
    }

    pub fn deinit(self: *CefNative) void {
        // 브라우저 수명은 CEF가 OnBeforeClose로 관리 → 우리는 테이블만 정리.
        self.browsers.deinit();
    }

    /// life_span_handler 콜백이 참조할 수 있도록 stable 포인터 등록.
    pub fn registerGlobal(self: *CefNative) void {
        g_cef_native = self;
    }
    pub fn unregisterGlobal() void {
        g_cef_native = null;
    }

    /// CEF가 OnBeforeClose에서 확정 파괴를 알렸을 때 테이블에서 제거.
    pub fn purge(self: *CefNative, handle: u64) void {
        _ = self.browsers.remove(handle);
    }

    pub fn asNative(self: *CefNative) window_mod.Native {
        return .{ .vtable = &vtable, .ctx = self };
    }

    const vtable: window_mod.Native.VTable = .{
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
    };

    fn fromCtx(ctx: ?*anyopaque) *CefNative {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn assertUiThread() void {
        std.debug.assert(c.cef_currently_on(c.TID_UI) == 1);
    }

    fn getHost(self: *CefNative, handle: u64) ?*c.cef_browser_host_t {
        const entry = self.browsers.get(handle) orelse return null;
        const br = entry.browser;
        return asPtr(c.cef_browser_host_t, br.get_host.?(br));
    }

    fn createWindow(ctx: ?*anyopaque, opts: *const window_mod.CreateOptions) anyerror!u64 {
        const self = fromCtx(ctx);
        assertUiThread();

        // title/url을 null-terminated로 복사 (CEF API 요구)
        var title_buf: [512]u8 = undefined;
        if (opts.title.len >= title_buf.len) return error.TitleTooLong;
        @memcpy(title_buf[0..opts.title.len], opts.title);
        title_buf[opts.title.len] = 0;
        const title_z: [:0]const u8 = title_buf[0..opts.title.len :0];

        var url_buf: [2048]u8 = undefined;
        const url_z: [:0]const u8 = if (opts.url) |u| blk: {
            if (u.len >= url_buf.len) return error.UrlTooLong;
            @memcpy(url_buf[0..u.len], u);
            url_buf[u.len] = 0;
            break :blk url_buf[0..u.len :0];
        } else self.default_url;

        var window_info: c.cef_window_info_t = undefined;
        zeroCefStruct(c.cef_window_info_t, &window_info);
        window_info.runtime_style = c.CEF_RUNTIME_STYLE_ALLOY;
        window_info.bounds = .{
            .x = opts.bounds.x,
            .y = opts.bounds.y,
            .width = @intCast(opts.bounds.width),
            .height = @intCast(opts.bounds.height),
        };
        const ns_window = initWindowInfo(&window_info, WindowInitOpts{
            .title = title_z,
            .width = @intCast(opts.bounds.width),
            .height = @intCast(opts.bounds.height),
            .x = opts.bounds.x,
            .y = opts.bounds.y,
            .appearance = opts.appearance,
            .constraints = opts.constraints,
        });
        setCefString(&window_info.window_name, title_z);

        var cef_url: c.cef_string_t = .{};
        if (url_z.len > 0) setCefString(&cef_url, url_z);

        var browser_settings: c.cef_browser_settings_t = undefined;
        zeroCefStruct(c.cef_browser_settings_t, &browser_settings);
        // transparent면 CEF browser의 기본 배경을 0(완전 투명)로 → HTML body가 투명하면
        // OS 윈도우까지 그대로 비침. 0xFF000000 alpha 마스크는 0 = transparent.
        if (opts.appearance.transparent) browser_settings.background_color = 0;

        const browser = c.cef_browser_host_create_browser_sync(
            &window_info,
            &self.client,
            &cef_url,
            &browser_settings,
            null,
            null,
        );
        if (browser == null) return error.BrowserCreationFailed;
        const br: *c.cef_browser_t = @ptrCast(browser);

        // handle = CEF browser identifier (프로세스 내 unique). life_span 콜백이
        // 같은 정수로 역조회 가능.
        const handle: u64 = @intCast(br.get_identifier.?(br));
        self.browsers.put(handle, .{ .browser = br, .ns_window = ns_window }) catch {
            // CEF browser는 이미 살아있음 → close_browser로 정리해 handle 누수 방지
            const host = asPtr(c.cef_browser_host_t, br.get_host.?(br));
            if (host) |h| h.close_browser.?(h, 1);
            return error.OutOfMemory;
        };

        // 부모-자식 시각 관계 (PLAN: 재귀 close X). browsers.put 이후에 처리해 put 실패 시 attach 스킵.
        if (comptime is_macos) {
            if (opts.parent_id) |pid| {
                if (resolveParentNSWindow(self, pid)) |parent_ns| {
                    if (ns_window) |child_ns| attachMacChildWindow(parent_ns, child_ns);
                } else {
                    log.warn("createWindow: parent_id={d} 해석 실패 — attach 스킵", .{pid});
                }
            }
        }

        return handle;
    }

    /// parent_id → NSWindow* (4단 lookup: WM.global → wm.get → browsers.get → ns_window).
    /// 어느 단계든 실패하면 null. createWindow의 attach 분기 가독성용.
    fn resolveParentNSWindow(self: *CefNative, parent_id: u32) ?*anyopaque {
        const wm = window_mod.WindowManager.global orelse return null;
        const parent_win = wm.get(parent_id) orelse return null;
        const parent_entry = self.browsers.get(parent_win.native_handle) orelse return null;
        return parent_entry.ns_window;
    }

    fn destroyWindow(ctx: ?*anyopaque, handle: u64) void {
        const self = fromCtx(ctx);
        assertUiThread();
        log.debug("CefNative.destroyWindow handle={d}", .{handle});
        const entry = self.browsers.get(handle) orelse {
            log.warn("CefNative.destroyWindow: handle={d} not in table", .{handle});
            return;
        };
        if (comptime is_macos) {
            // macOS: NSWindow close가 content view + CEF browser view를 dealloc시켜
            // CEF 내부 cleanup을 연쇄 트리거 → OnBeforeClose fire. close_browser는 생략
            // (중복 호출이 경쟁상태 유발해 OnBeforeClose 예약 실패 관찰됨).
            closeMacWindow(entry.ns_window);
        } else {
            const br = entry.browser;
            const host = asPtr(c.cef_browser_host_t, br.get_host.?(br));
            if (host) |h| h.close_browser.?(h, 1);
        }
    }

    fn setVisible(ctx: ?*anyopaque, handle: u64, visible: bool) void {
        const self = fromCtx(ctx);
        assertUiThread();
        const host = self.getHost(handle) orelse return;
        host.was_hidden.?(host, if (visible) 0 else 1);
    }

    fn focus(ctx: ?*anyopaque, handle: u64) void {
        const self = fromCtx(ctx);
        assertUiThread();
        const host = self.getHost(handle) orelse return;
        host.set_focus.?(host, 1);
    }

    // Step C: setTitle / setBounds 플랫폼별 연결. macOS는 BrowserEntry.ns_window를 경유.
    // Linux/Windows는 CEF가 자체 윈도우를 관리 → 추후 host.get_window_handle()로 HWND /
    // GtkWindow* 접근. 지금은 macOS만 구현, 나머지는 no-op (빌드되지만 동작 X).
    fn setTitle(ctx: ?*anyopaque, handle: u64, title: []const u8) void {
        assertUiThread();
        if (!is_macos) return;
        const self = fromCtx(ctx);
        const entry = self.browsers.get(handle) orelse return;
        const ns_window = entry.ns_window orelse return;
        setMacWindowTitle(ns_window, title);
    }

    fn setBounds(ctx: ?*anyopaque, handle: u64, bounds: window_mod.Bounds) void {
        assertUiThread();
        if (!is_macos) return;
        const self = fromCtx(ctx);
        const entry = self.browsers.get(handle) orelse return;
        const ns_window = entry.ns_window orelse return;
        setMacWindowBounds(ns_window, bounds);
    }

    // ==================== Phase 4-A: webContents (네비/JS) ====================

    fn loadUrl(ctx: ?*anyopaque, handle: u64, url: []const u8) void {
        assertUiThread();
        const self = fromCtx(ctx);
        const entry = self.browsers.get(handle) orelse return;
        const frame = asPtr(c.cef_frame_t, entry.browser.get_main_frame.?(entry.browser)) orelse return;
        var url_buf: [URL_BUF_SIZE]u8 = undefined;
        const url_z = nullTerminateOrTruncate(url, &url_buf) orelse return;
        var cef_url: c.cef_string_t = .{};
        setCefString(&cef_url, url_z);
        const load_url = frame.load_url orelse return;
        load_url(frame, &cef_url);
    }

    fn reload(ctx: ?*anyopaque, handle: u64, ignore_cache: bool) void {
        assertUiThread();
        const self = fromCtx(ctx);
        const entry = self.browsers.get(handle) orelse return;
        const br = entry.browser;
        if (ignore_cache) {
            const fn_ptr = br.reload_ignore_cache orelse return;
            fn_ptr(br);
        } else {
            const fn_ptr = br.reload orelse return;
            fn_ptr(br);
        }
    }

    fn executeJavascript(ctx: ?*anyopaque, handle: u64, code: []const u8) void {
        assertUiThread();
        const self = fromCtx(ctx);
        const entry = self.browsers.get(handle) orelse return;
        var code_buf: [JS_BUF_SIZE]u8 = undefined;
        const code_z = nullTerminateOrTruncate(code, &code_buf) orelse return;
        evalJsOnBrowser(entry.browser, code_z);
    }

    /// url_cache(OnAddressChange가 갱신)에 캐시된 URL 반환. 비어있으면 null.
    /// 폴백 alloc은 안 함 — 호출자가 동기 응답을 기대하므로 캐시 미스는 그대로 노출.
    fn getUrl(ctx: ?*anyopaque, handle: u64) ?[]const u8 {
        const self = fromCtx(ctx);
        const entry = self.browsers.getPtr(handle) orelse return null;
        if (entry.url_cache_len == 0) return null;
        return entry.url_cache_buf[0..entry.url_cache_len];
    }

    fn isLoading(ctx: ?*anyopaque, handle: u64) bool {
        const self = fromCtx(ctx);
        const entry = self.browsers.get(handle) orelse return false;
        const fn_ptr = entry.browser.is_loading orelse return false;
        return fn_ptr(entry.browser) == 1;
    }
};

const URL_BUF_SIZE: usize = 2048;
const JS_BUF_SIZE: usize = 16 * 1024;

/// `[]const u8` → null-terminated `[:0]const u8` 복사. buf 부족 시 null 반환.
/// CEF API(load_url/execute_java_script)에 전달하기 전에 필요.
fn nullTerminateOrTruncate(src: []const u8, buf: []u8) ?[:0]const u8 {
    if (src.len >= buf.len) return null;
    @memcpy(buf[0..src.len], src);
    buf[src.len] = 0;
    return buf[0..src.len :0];
}

/// 런타임 URL 네비게이션
pub fn navigate(url: [:0]const u8) void {
    const browser = g_browser orelse return;
    const frame = asPtr(c.cef_frame_t, browser.get_main_frame.?(browser)) orelse return;
    var cef_url: c.cef_string_t = .{};
    setCefString(&cef_url, url);
    frame.load_url.?(frame, &cef_url);
}

/// 특정 브라우저 한 개에 JS 실행. 내부 헬퍼.
fn evalJsOnBrowser(browser: *c.cef_browser_t, js: [:0]const u8) void {
    const frame = asPtr(c.cef_frame_t, browser.get_main_frame.?(browser)) orelse return;
    var code: c.cef_string_t = .{};
    setCefString(&code, js);
    var url: c.cef_string_t = .{};
    setCefString(&url, "");
    frame.execute_java_script.?(frame, &code, &url, 0);
}

/// 메인 프로세스에서 렌더러의 JS 실행 (EventBus → JS __dispatch__ 용).
/// target=null: 모든 live 브라우저로 브로드캐스트.
/// target=winId: WindowManager id 기준 해당 브라우저 한 개에만 전달.
///   (살아있는 매핑 없으면 silent no-op — Electron과 동일)
pub fn evalJs(target: ?u32, js: [:0]const u8) void {
    const native = g_cef_native orelse {
        // 초기화 전 또는 단위 테스트 경로 — 과거 동작 유지: 첫 브라우저 fallback.
        if (g_browser) |br| evalJsOnBrowser(br, js);
        return;
    };
    if (target) |win_id| {
        const wm = window_mod.WindowManager.global orelse return;
        const win = wm.get(win_id) orelse return;
        const entry = native.browsers.get(win.native_handle) orelse return;
        evalJsOnBrowser(entry.browser, js);
        return;
    }
    var it = native.browsers.valueIterator();
    while (it.next()) |entry| {
        evalJsOnBrowser(entry.browser, js);
    }
}

/// 메시지 루프 실행 (블로킹)
pub fn run() void {
    if (comptime is_macos) activateNSApp();
    std.debug.print("[suji] CEF running\n", .{});
    c.cef_run_message_loop();
}

/// CEF 종료
pub fn shutdown() void {
    c.cef_shutdown();
    std.debug.print("[suji] CEF shutdown\n", .{});
}

/// 메시지 루프 종료 요청. 현재 콜백 완료 후 run()이 반환.
pub fn quit() void {
    c.cef_quit_message_loop();
}

// ============================================
// C 포인터 헬퍼
// ============================================

/// [*c]T → ?*T 변환 (CEF 함수 포인터 반환값용)
fn asPtr(comptime T: type, p: anytype) ?*T {
    if (p == null) return null;
    return @ptrCast(p);
}

// ============================================
// CEF String 헬퍼
// ============================================

fn zeroCefStruct(comptime T: type, ptr: *T) void {
    @memset(std.mem.asBytes(ptr), 0);
    // CEF 구조체는 base.size 또는 직접 size 필드에 sizeof를 설정해야 함
    if (@hasField(T, "base")) {
        ptr.base.size = @sizeOf(T);
    } else if (@hasField(T, "size")) {
        ptr.size = @sizeOf(T);
    }
}

// TODO: setCefString은 UTF-16 메모리를 할당하지만 cef_string_clear로 해제하지 않음.
//       프로세스 라이프타임 문자열이라 실질적 누수 없으나, 동적 문자열 사용 시 해제 필요.
fn setCefString(dest: *c.cef_string_t, src: []const u8) void {
    _ = c.cef_string_utf8_to_utf16(src.ptr, src.len, dest);
}

/// JSON에서 "cmd":"value" 추출
fn extractCmd(json: []const u8) ?[]const u8 {
    const pattern = "\"cmd\":\"";
    const idx = std.mem.indexOf(u8, json, pattern) orelse return null;
    const start = idx + pattern.len;
    const end = std.mem.indexOfPos(u8, json, start, "\"") orelse return null;
    return json[start..end];
}

/// CefListValue에서 문자열 인자를 UTF-8로 추출
fn getArgString(args: *c.cef_list_value_t, index: usize, buf: []u8) []const u8 {
    return cefUserfreeToUtf8(args.get_string.?(args, index), buf);
}

/// JSON 문자열을 URI percent-encode (single-quote/backslash injection 방지)
fn jsonToHexEscape(src: []const u8, buf: []u8) []const u8 {
    const hex = "0123456789ABCDEF";
    var o: usize = 0;
    for (src) |ch| {
        if (o + 3 > buf.len) break;
        if ((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '-' or ch == '_' or ch == '.' or ch == '~') {
            buf[o] = ch;
            o += 1;
        } else {
            buf[o] = '%';
            buf[o + 1] = hex[ch >> 4];
            buf[o + 2] = hex[ch & 0x0f];
            o += 3;
        }
    }
    return buf[0..o];
}

/// 현재 V8 컨텍스트의 프레임으로 ProcessMessage 전송 (렌더러 → 브라우저)
fn sendToBrowser(msg: *c.cef_process_message_t) void {
    const ctx = asPtr(c.cef_v8_context_t, c.cef_v8_context_get_current_context()) orelse return;
    const frame = asPtr(c.cef_frame_t, ctx.get_frame.?(ctx)) orelse return;
    frame.send_process_message.?(frame, c.PID_BROWSER, msg);
}

/// CEF 문자열 → UTF-8 (스택 버퍼에 복사)
fn cefStringToUtf8(cef_str: *const c.cef_string_t, buf: []u8) []const u8 {
    var utf8: c.cef_string_utf8_t = .{ .str = null, .length = 0, .dtor = null };
    _ = c.cef_string_utf16_to_utf8(cef_str.str, cef_str.length, &utf8);
    if (utf8.str == null or utf8.length == 0) return buf[0..0];
    const len = @min(utf8.length, buf.len);
    @memcpy(buf[0..len], utf8.str[0..len]);
    if (utf8.dtor) |dtor| dtor(utf8.str);
    return buf[0..len];
}

/// cef_string_userfree_t → UTF-8 (스택 버퍼에 복사, userfree 해제)
fn cefUserfreeToUtf8(userfree: c.cef_string_userfree_t, buf: []u8) []const u8 {
    if (userfree == null) return buf[0..0];
    const result = cefStringToUtf8(userfree, buf);
    c.cef_string_userfree_utf16_free(userfree);
    return result;
}

/// 브라우저의 main frame URL 추출 — Phase 2.5 `event.window.url` 원천.
/// 실패(프레임 없음/URL 빈 문자열)는 null → 호출자가 wire 필드 생략.
/// **캐시 우선** — OnAddressChange가 갱신한 BrowserEntry.url_cache를 먼저 보고,
/// 없을 때만 frame.get_url(alloc + UTF8 변환 + free)로 폴백. 매 invoke마다 호출되는 핫경로.
fn getMainFrameUrl(browser: *c.cef_browser_t, buf: []u8) ?[]const u8 {
    // 1) 캐시 시도
    if (g_cef_native) |native| {
        const handle: u64 = @intCast(browser.get_identifier.?(browser));
        if (native.browsers.getPtr(handle)) |entry| {
            if (entry.url_cache_len > 0) {
                return entry.url_cache_buf[0..entry.url_cache_len];
            }
        }
    }
    // 2) 폴백 — 캐시 미스 (초기 로드 전 / URL 길이 초과 / native 미등록)
    const frame = asPtr(c.cef_frame_t, browser.get_main_frame.?(browser)) orelse return null;
    const get_url = frame.get_url orelse return null;
    const userfree = get_url(frame);
    if (userfree == null) return null;
    const url = cefUserfreeToUtf8(userfree, buf);
    if (url.len == 0) return null;
    return url;
}

/// CEF cef_frame_t.is_main의 Zig friendly 래퍼 (C int → bool, vtable null-safe).
fn frameIsMain(frame: *c.cef_frame_t) ?bool {
    const fn_ptr = frame.is_main orelse return null;
    return fn_ptr(frame) == 1;
}

// ============================================
// CEF Reference Counting
// ============================================

fn initBaseRefCounted(base: *c.cef_base_ref_counted_t) void {
    base.add_ref = &addRef;
    base.release = &release;
    base.has_one_ref = &hasOneRef;
    base.has_at_least_one_ref = &hasAtLeastOneRef;
}

// TODO: no-op 참조 카운팅 — 글로벌 스태틱 객체에는 안전하지만,
//       동적 CEF 객체(멀티 브라우저 등) 사용 시 실제 ref counting 구현 필요.
fn addRef(_: ?*c.cef_base_ref_counted_t) callconv(.c) void {}
fn release(_: ?*c.cef_base_ref_counted_t) callconv(.c) i32 { return 1; }
fn hasOneRef(_: ?*c.cef_base_ref_counted_t) callconv(.c) i32 { return 1; }
fn hasAtLeastOneRef(_: ?*c.cef_base_ref_counted_t) callconv(.c) i32 { return 1; }

// ============================================
// CEF App (메인 + 서브프로세스 공통)
// ============================================

fn initApp(app: *c.cef_app_t) void {
    zeroCefStruct(c.cef_app_t, app);
    initBaseRefCounted(&app.base);
    app.get_render_process_handler = &getRenderProcessHandler;
    app.on_before_command_line_processing = &onBeforeCommandLineProcessing;
    app.on_register_custom_schemes = &onRegisterCustomSchemes;
    initRenderHandler();
}

/// CEF 커맨드라인 플래그 주입 (키체인 팝업 방지 등)
fn onBeforeCommandLineProcessing(
    _: ?*c._cef_app_t,
    _: [*c]const c.cef_string_t,
    command_line: ?*c._cef_command_line_t,
) callconv(.c) void {
    const cmd = command_line orelse return;

    // macOS 키체인 접근 시 팝업 방지
    var mock_keychain: c.cef_string_t = .{};
    setCefString(&mock_keychain, "use-mock-keychain");
    cmd.append_switch.?(cmd, &mock_keychain);

    // Helper 프로세스가 Dock에 나타나지 않게
    var disable_bg: c.cef_string_t = .{};
    setCefString(&disable_bg, "disable-background-mode");
    cmd.append_switch.?(cmd, &disable_bg);

    // localhost DevTools 허용
    var remote_origins: c.cef_string_t = .{};
    setCefString(&remote_origins, "remote-allow-origins");
    var wildcard: c.cef_string_t = .{};
    setCefString(&wildcard, "*");
    cmd.append_switch_with_value.?(cmd, &remote_origins, &wildcard);

    // GPU 가속 정책:
    // - macOS: 활성화. build.zig post-install + bundle_macos.zig가 libEGL/libGLESv2/
    //   libvk_swiftshader + vk_swiftshader_icd.json을 실행파일 옆에 심링크로 배치.
    //   ANGLE Metal 경로로 Apple GPU 가속 (WebGL 2.0 확인됨).
    // - Linux/Windows: GPU asset 배치 로직 미구현. disable-gpu로 소프트웨어 렌더링
    //   폴백 (CEF가 자체 SwiftShader로 crash 없이 실행). 향후 OS별 asset 배치 추가 시
    //   아래 조건 블록 제거.
    if (builtin.os.tag != .macos) {
        var disable_gpu: c.cef_string_t = .{};
        setCefString(&disable_gpu, "disable-gpu");
        cmd.append_switch.?(cmd, &disable_gpu);

        var disable_gpu_compositing: c.cef_string_t = .{};
        setCefString(&disable_gpu_compositing, "disable-gpu-compositing");
        cmd.append_switch.?(cmd, &disable_gpu_compositing);
    }
}

fn getRenderProcessHandler(_: ?*c._cef_app_t) callconv(.c) ?*c._cef_render_process_handler_t {
    return &g_render_handler;
}

// ============================================
// CEF Client (메인 프로세스)
// ============================================

fn initClient(client_ptr: *c.cef_client_t) void {
    zeroCefStruct(c.cef_client_t, client_ptr);
    initBaseRefCounted(&client_ptr.base);
    client_ptr.get_life_span_handler = &getLifeSpanHandler;
    client_ptr.get_keyboard_handler = &getKeyboardHandler;
    client_ptr.get_display_handler = &getDisplayHandler;
    client_ptr.on_process_message_received = &onBrowserProcessMessageReceived;
}

fn getKeyboardHandler(_: ?*c._cef_client_t) callconv(.c) ?*c._cef_keyboard_handler_t {
    return &g_keyboard_handler;
}

fn getLifeSpanHandler(_: ?*c._cef_client_t) callconv(.c) ?*c._cef_life_span_handler_t {
    return &g_life_span_handler;
}

// ============================================
// CEF Display Handler — URL 변경 콜백 (캐싱용)
// ============================================

var g_display_handler: c.cef_display_handler_t = undefined;
var g_display_handler_initialized: bool = false;

fn ensureDisplayHandler() void {
    if (g_display_handler_initialized) return;
    zeroCefStruct(c.cef_display_handler_t, &g_display_handler);
    initBaseRefCounted(&g_display_handler.base);
    g_display_handler.on_address_change = &onAddressChange;
    g_display_handler_initialized = true;
}

fn getDisplayHandler(_: ?*c._cef_client_t) callconv(.c) ?*c._cef_display_handler_t {
    ensureDisplayHandler();
    return &g_display_handler;
}

/// main frame URL이 바뀔 때 BrowserEntry.url_cache 갱신.
/// invoke 핫경로의 frame.get_url alloc/free 1회를 절약. iframe 변경은 무시 (main만 캐싱).
fn onAddressChange(
    _: ?*c._cef_display_handler_t,
    browser: ?*c._cef_browser_t,
    frame: ?*c._cef_frame_t,
    url: [*c]const c.cef_string_t,
) callconv(.c) void {
    const br = browser orelse return;
    const f = frame orelse return;
    const u = url orelse return;
    // main frame만 캐싱 — iframe URL은 sender 식별과 무관.
    const is_main = if (f.is_main) |fn_ptr| fn_ptr(f) == 1 else false;
    if (!is_main) return;

    const native = g_cef_native orelse return;
    const handle: u64 = @intCast(br.get_identifier.?(br));
    const entry = native.browsers.getPtr(handle) orelse return;

    const utf8_len = cefStringToUtf8(u, &entry.url_cache_buf).len;
    // 256 byte 초과 URL은 캐시 무효화 → 폴백 (frame.get_url) 사용.
    entry.url_cache_len = if (utf8_len > 0 and utf8_len < entry.url_cache_buf.len) utf8_len else 0;
}

/// 메인 프로세스: 렌더러에서 온 메시지 처리
fn onBrowserProcessMessageReceived(
    _: ?*c._cef_client_t,
    browser: ?*c._cef_browser_t,
    frame: ?*c._cef_frame_t,
    _: c.cef_process_id_t,
    message: ?*c._cef_process_message_t,
) callconv(.c) i32 {
    const msg = message orelse return 0;
    const name_userfree = msg.get_name.?(msg);
    var name_buf: [64]u8 = undefined;
    const msg_name = cefUserfreeToUtf8(name_userfree, &name_buf);

    if (std.mem.eql(u8, msg_name, "suji:invoke")) {
        return handleBrowserInvoke(browser, frame, msg);
    } else if (std.mem.eql(u8, msg_name, "suji:emit")) {
        return handleBrowserEmit(msg);
    }
    return 0;
}

/// 메인 프로세스: invoke 요청 처리 → 백엔드 호출 → 응답 반환
fn handleBrowserInvoke(
    browser: ?*c._cef_browser_t,
    frame: ?*c._cef_frame_t,
    msg: *c._cef_process_message_t,
) i32 {
    const args = asPtr(c.cef_list_value_t, msg.get_argument_list.?(msg)) orelse return 0;

    // args[0] = seq_id (int), args[1] = channel (string), args[2] = data (string)
    const seq_id = args.get_int.?(args, 0);

    var ch_buf: [256]u8 = undefined;
    const channel = getArgString(args, 1, &ch_buf);

    var data_buf: [8192]u8 = undefined;
    const data = getArgString(args, 2, &data_buf);

    // Phase 2.5 — wire 레벨 sender 컨텍스트(__window/__window_name/__window_url/__window_main_frame)
    // 자동 주입. 이미 __window가 박혀있는 요청(cross-hop)은 보존.
    var injected_buf: [8192]u8 = undefined;
    var url_extract_buf: [2048]u8 = undefined;
    const data_to_backend: []const u8 = blk: {
        const br = browser orelse break :blk data;
        const native_handle: u64 = @intCast(br.get_identifier.?(br));
        const wm = window_mod.WindowManager.global orelse break :blk data;
        const win_id = wm.findByNativeHandle(native_handle) orelse break :blk data;
        const win_name: ?[]const u8 = if (wm.get(win_id)) |w| w.name else null;
        // sender 창의 main frame URL. 읽기 실패는 non-fatal — null로 대체.
        const win_url: ?[]const u8 = getMainFrameUrl(br, &url_extract_buf);
        const is_main: ?bool = if (frame) |f| frameIsMain(f) else null;
        break :blk window_ipc.injectWindowField(data, .{
            .window_id = win_id,
            .window_name = win_name,
            .window_url = win_url,
            .is_main_frame = is_main,
        }, &injected_buf) orelse data;
    };

    // 백엔드 호출
    var response_buf: [16384]u8 = undefined;
    var success: bool = false;
    var result: []const u8 = "\"no handler\"";

    if (g_invoke_callback) |cb| {
        if (cb(channel, data_to_backend, &response_buf)) |resp| {
            result = resp;
            success = true;
        } else {
            result = "\"backend error\"";
        }
    }

    // 응답 CefProcessMessage 생성
    sendInvokeResponse(frame, seq_id, success, result);
    return 1;
}

fn sendInvokeResponse(frame: ?*c._cef_frame_t, seq_id: i32, success: bool, result: []const u8) void {
    const f = frame orelse return;

    var resp_name: c.cef_string_t = .{};
    setCefString(&resp_name, "suji:response");
    const resp_msg = asPtr(c.cef_process_message_t, c.cef_process_message_create(&resp_name)) orelse return;

    const resp_args = asPtr(c.cef_list_value_t, resp_msg.get_argument_list.?(resp_msg)) orelse return;
    _ = resp_args.set_int.?(resp_args, 0, seq_id);
    _ = resp_args.set_int.?(resp_args, 1, if (success) 1 else 0);

    var result_str: c.cef_string_t = .{};
    setCefString(&result_str, result);
    _ = resp_args.set_string.?(resp_args, 2, &result_str);

    f.send_process_message.?(f, c.PID_RENDERER, resp_msg);
}

/// 메인 프로세스: emit 처리 → EventBus
fn handleBrowserEmit(msg: *c._cef_process_message_t) i32 {
    const args = asPtr(c.cef_list_value_t, msg.get_argument_list.?(msg)) orelse return 0;

    var ev_buf: [256]u8 = undefined;
    const event = getArgString(args, 0, &ev_buf);

    var data_buf: [8192]u8 = undefined;
    const data = getArgString(args, 1, &data_buf);

    // 3번째 인자 — 선택적 target window id. 없으면(0/미설정) 브로드캐스트.
    const target: ?u32 = blk: {
        const size = args.get_size.?(args);
        if (size < 3) break :blk null;
        const ty = args.get_type.?(args, 2);
        if (ty != c.VTYPE_INT) break :blk null;
        const v = args.get_int.?(args, 2);
        if (v <= 0) break :blk null;
        break :blk @intCast(v);
    };

    std.debug.print("[suji] IPC emit: event={s} target={?}\n", .{ event, target });

    if (g_emit_callback) |cb| {
        cb(target, event, data);
    }
    return 1;
}

// ============================================
// CEF Life Span Handler
// ============================================

var g_life_span_handler: c.cef_life_span_handler_t = undefined;
/// life_span_handler 콜백이 참조하는 CefNative 싱글턴 포인터.
/// 프로세스당 하나의 CefNative만 등록된다고 가정 (CefNative.registerGlobal이 세팅).
/// 여러 인스턴스 등록 시 마지막만 유효 — 현재 설계는 이 제약을 강제하지 않음.
var g_cef_native: ?*CefNative = null;

fn initLifeSpanHandler() void {
    zeroCefStruct(c.cef_life_span_handler_t, &g_life_span_handler);
    initBaseRefCounted(&g_life_span_handler.base);
    g_life_span_handler.on_after_created = &onAfterCreated;
    g_life_span_handler.do_close = &doClose;
    g_life_span_handler.on_before_close = &onBeforeClose;
}

fn onAfterCreated(_: ?*c._cef_life_span_handler_t, browser: ?*c._cef_browser_t) callconv(.c) void {
    // 메인 윈도우만 g_browser에 저장 (첫 번째 브라우저)
    if (g_browser == null) {
        g_browser = browser;
    }
    const br = browser orelse return;
    std.debug.print("[suji] CEF browser after_created: id={d}\n", .{br.get_identifier.?(br)});
}

/// CEF가 browser close 요청을 처리할지 물어보는 훅.
/// - WM이 이미 close 중(destroyed=true)이면 통과 (WM 경로가 이미 이벤트 발화함)
/// - 아니면 사용자/OS 기인 close → wm.tryClose로 라우팅해 `window:close` 취소 가능 이벤트 발화
/// 반환: 0 = 진행, 1 = 취소 (브라우저 유지)
fn doClose(_: ?*c._cef_life_span_handler_t, browser: ?*c._cef_browser_t) callconv(.c) i32 {
    const br = browser orelse return 0;
    const handle: u64 = @intCast(br.get_identifier.?(br));
    const wm = window_mod.WindowManager.global orelse {
        log.debug("DoClose handle={d} WM.global=null → proceed", .{handle});
        return 0;
    };
    const id = wm.findByNativeHandle(handle) orelse {
        log.debug("DoClose handle={d} not in WM → proceed", .{handle});
        return 0;
    };
    const w = wm.get(id) orelse return 0;

    if (w.destroyed) {
        log.debug("DoClose id={d} already destroyed (WM-initiated) → proceed", .{id});
        return 0;
    }

    log.debug("DoClose id={d} external close → tryClose", .{id});
    const proceed = wm.tryClose(id) catch |e| {
        log.err("DoClose tryClose failed: {s}", .{@errorName(e)});
        return 0;
    };
    log.debug("DoClose id={d} proceed={}", .{ id, proceed });
    return if (proceed) 0 else 1;
}

fn onBeforeClose(_: ?*c._cef_life_span_handler_t, browser: ?*c._cef_browser_t) callconv(.c) void {
    const br = browser orelse return;
    const handle: u64 = @intCast(br.get_identifier.?(br));
    log.debug("OnBeforeClose handle={d}", .{handle});

    if (g_cef_native) |cn| cn.purge(handle);

    notifyWm: {
        const wm = window_mod.WindowManager.global orelse break :notifyWm;
        const id = wm.findByNativeHandle(handle) orelse break :notifyWm;
        const w = wm.get(id) orelse break :notifyWm;
        if (w.destroyed) {
            log.debug("OnBeforeClose id={d} already destroyed — skip markClosedExternal", .{id});
            break :notifyWm;
        }
        log.debug("OnBeforeClose id={d} → markClosedExternal", .{id});
        wm.markClosedExternal(id) catch {};
    }

    const is_main = if (g_browser) |main_br|
        br.get_identifier.?(br) == main_br.get_identifier.?(main_br)
    else
        true;
    if (is_main) {
        log.info("main browser closed → quitting message loop", .{});
        c.cef_quit_message_loop();
    } else {
        log.debug("non-main browser closed handle={d} (no quit)", .{handle});
    }
}

// ============================================
// CEF Keyboard Handler (Electron 호환 단축키)
// ============================================
// Cmd+Shift+I / F12  — DevTools
// Cmd+R              — Reload
// Cmd+Shift+R        — Hard Reload (캐시 무시)
// Cmd+W              — 창 닫기
// Cmd+Q              — 앱 종료
// Cmd+Plus/Minus/0   — 줌 인/아웃/리셋
// Cmd+[ / ]          — 뒤로/앞으로

var g_keyboard_handler: c.cef_keyboard_handler_t = undefined;
var g_keyboard_handler_initialized: bool = false;

fn initKeyboardHandler() void {
    if (g_keyboard_handler_initialized) return;
    zeroCefStruct(c.cef_keyboard_handler_t, &g_keyboard_handler);
    initBaseRefCounted(&g_keyboard_handler.base);
    g_keyboard_handler.on_pre_key_event = &onPreKeyEvent;
    g_keyboard_handler_initialized = true;
}

fn onPreKeyEvent(
    _: ?*c._cef_keyboard_handler_t,
    browser: ?*c._cef_browser_t,
    event: ?*const c.cef_key_event_t,
    _: c.cef_event_handle_t,
    is_keyboard_shortcut: ?*i32,
) callconv(.c) i32 {
    const ev = event orelse return 0;
    const br = browser orelse return 0;

    // RawKeyDown만 처리
    if (ev.type != c.KEYEVENT_RAWKEYDOWN) return 0;

    const cmd = (ev.modifiers & c.EVENTFLAG_COMMAND_DOWN) != 0;
    const shift = (ev.modifiers & c.EVENTFLAG_SHIFT_DOWN) != 0;
    const alt = (ev.modifiers & c.EVENTFLAG_ALT_DOWN) != 0;
    const key = ev.windows_key_code;

    // F12 / Cmd+Shift+I / Cmd+Option+I — DevTools 토글.
    // 단축키를 누른 창(br)을 대상으로 — 멀티윈도우에서도 각 창마다 자기 DevTools.
    const is_devtools_key = (key == 123) or (cmd and key == 'I' and (shift or alt));
    if (is_devtools_key) {
        toggleDevTools(br);
        return 1;
    }

    if (!cmd) return 0;

    // Cmd+R — Reload
    if (key == 'R' and !shift) {
        br.reload.?(br);
        return 1;
    }

    // Cmd+Shift+R — Hard Reload
    if (key == 'R' and shift) {
        br.reload_ignore_cache.?(br);
        return 1;
    }

    // Cmd+W — 창 닫기. WM 경유 → window:close 취소 가능 이벤트 발화 후 파괴.
    // WM 미등록이면 CEF 직접 close (폴백, 이벤트 없음).
    if (key == 'W' and !shift) {
        const handle: u64 = @intCast(br.get_identifier.?(br));
        log.debug("cmd+w pressed browser_id={d}", .{handle});
        if (window_mod.WindowManager.global) |wm| {
            if (wm.findByNativeHandle(handle)) |id| {
                log.debug("cmd+w → wm.close id={d}", .{id});
                const ok = wm.close(id) catch |e| {
                    log.err("cmd+w wm.close failed: {s}", .{@errorName(e)});
                    return 1;
                };
                log.debug("cmd+w wm.close returned destroyed={}", .{ok});
                return 1;
            }
            log.warn("cmd+w: handle={d} not found in WM (fallback to direct close)", .{handle});
        } else {
            log.warn("cmd+w: WM.global is null (fallback to direct close)", .{});
        }
        const host = asPtr(c.cef_browser_host_t, br.get_host.?(br));
        if (host) |h| h.close_browser.?(h, 0);
        return 1;
    }

    // Cmd+Q — 앱 종료
    if (key == 'Q') {
        c.cef_quit_message_loop();
        return 1;
    }

    // Cmd+Plus (=+) — 줌 인
    if (key == 187 or key == '+' or key == '=') {
        zoomChange(br, 0.5);
        return 1;
    }

    // Cmd+Minus — 줌 아웃
    if (key == 189 or key == '-') {
        zoomChange(br, -0.5);
        return 1;
    }

    // Cmd+0 — 줌 리셋
    if (key == '0') {
        zoomSet(br, 0.0);
        return 1;
    }

    // Cmd+[ — 뒤로
    if (key == 219) { // VK_OEM_4 = [
        br.go_back.?(br);
        return 1;
    }

    // Cmd+] — 앞으로
    if (key == 221) { // VK_OEM_6 = ]
        br.go_forward.?(br);
        return 1;
    }

    // 나머지 Cmd 단축키는 macOS Edit 메뉴에서 처리 (C/V/X/A/Z)
    if (is_keyboard_shortcut) |ks| ks.* = 1;
    return 0;
}

fn toggleDevTools(browser: *c.cef_browser_t) void {
    const host = asPtr(c.cef_browser_host_t, browser.get_host.?(browser)) orelse return;

    if (host.has_dev_tools.?(host) == 1) {
        host.close_dev_tools.?(host);
    } else {
        var window_info: c.cef_window_info_t = undefined;
        zeroCefStruct(c.cef_window_info_t, &window_info);
        window_info.runtime_style = c.CEF_RUNTIME_STYLE_DEFAULT;

        var settings: c.cef_browser_settings_t = undefined;
        zeroCefStruct(c.cef_browser_settings_t, &settings);

        var point: c.cef_point_t = .{ .x = 0, .y = 0 };
        host.show_dev_tools.?(host, &window_info, &g_devtools_client, &settings, &point);
    }
}

fn zoomChange(browser: *c.cef_browser_t, delta: f64) void {
    const host = asPtr(c.cef_browser_host_t, browser.get_host.?(browser)) orelse return;
    const current = host.get_zoom_level.?(host);
    host.set_zoom_level.?(host, current + delta);
}

fn zoomSet(browser: *c.cef_browser_t, level: f64) void {
    const host = asPtr(c.cef_browser_host_t, browser.get_host.?(browser)) orelse return;
    host.set_zoom_level.?(host, level);
}

// ============================================
// CEF Render Process Handler (렌더러 서브프로세스)
// ============================================
//
// 렌더러 프로세스에서 실행되는 코드.
// V8 컨텍스트가 생성되면 window.__suji__ 오브젝트를 바인딩하고,
// invoke() 호출 시 CefProcessMessage로 메인 프로세스에 전달.
// 메인에서 응답이 오면 Promise를 resolve/reject.

var g_render_handler: c.cef_render_process_handler_t = undefined;
var g_render_handler_initialized: bool = false;

// V8 핸들러 (invoke, emit 함수용)
var g_v8_handler: c.cef_v8_handler_t = undefined;

// 시퀀스 카운터 (요청-응답 매칭)
var g_seq_counter: u32 = 0;

// 렌더러 V8 컨텍스트 (onContextCreated에서 저장, 이벤트 디스패치용)
var g_renderer_context: ?*c.cef_v8_context_t = null;

// 펜딩 컨텍스트 저장소 (렌더러 프로세스, 싱글 스레드)
// Promise는 JS 측에서 관리 (_pending 맵), 네이티브는 컨텍스트만 보관
const MAX_PENDING: usize = 256;
var g_pending_contexts: [MAX_PENDING]?*c.cef_v8_context_t = [_]?*c.cef_v8_context_t{null} ** MAX_PENDING;

fn initRenderHandler() void {
    if (g_render_handler_initialized) return;
    zeroCefStruct(c.cef_render_process_handler_t, &g_render_handler);
    initBaseRefCounted(&g_render_handler.base);
    g_render_handler.on_context_created = &onContextCreated;
    g_render_handler.on_process_message_received = &onRendererProcessMessageReceived;

    zeroCefStruct(c.cef_v8_handler_t, &g_v8_handler);
    initBaseRefCounted(&g_v8_handler.base);
    g_v8_handler.execute = &v8Execute;

    g_render_handler_initialized = true;
}

/// V8 컨텍스트 생성 시 window.__suji__ 바인딩
fn onContextCreated(
    _: ?*c._cef_render_process_handler_t,
    _: ?*c._cef_browser_t,
    _: ?*c._cef_frame_t,
    context: ?*c._cef_v8_context_t,
) callconv(.c) void {
    const ctx = context orelse return;
    g_renderer_context = ctx; // 이벤트 디스패치용 컨텍스트 저장
    const global = asPtr(c.cef_v8_value_t, ctx.get_global.?(ctx)) orelse return;

    // window.__suji__ 오브젝트 생성
    const suji_obj = asPtr(c.cef_v8_value_t, c.cef_v8_value_create_object(null, null)) orelse return;

    // invoke, emit 함수 바인딩 (on/off/__dispatch__는 JS로 주입)
    var invoke_name: c.cef_string_t = .{};
    setCefString(&invoke_name, "invoke");
    const invoke_fn = asPtr(c.cef_v8_value_t, c.cef_v8_value_create_function(&invoke_name, &g_v8_handler)) orelse return;

    var emit_name: c.cef_string_t = .{};
    setCefString(&emit_name, "emit");
    const emit_fn = asPtr(c.cef_v8_value_t, c.cef_v8_value_create_function(&emit_name, &g_v8_handler)) orelse return;

    _ = suji_obj.set_value_bykey.?(suji_obj, &invoke_name, invoke_fn, c.V8_PROPERTY_ATTRIBUTE_NONE);
    _ = suji_obj.set_value_bykey.?(suji_obj, &emit_name, emit_fn, c.V8_PROPERTY_ATTRIBUTE_NONE);

    // window.__suji__ = suji_obj
    var suji_key: c.cef_string_t = .{};
    setCefString(&suji_key, "__suji__");
    _ = global.set_value_bykey.?(global, &suji_key, suji_obj, c.V8_PROPERTY_ATTRIBUTE_NONE);

    // JS 헬퍼: _listeners, on, off, __dispatch__ 주입
    injectJsHelpers(ctx);

    std.debug.print("[suji] V8 context created: window.__suji__ bound\n", .{});
}

/// JS 헬퍼 코드 주입 — 기존 webview ipc.zig와 동일한 window.__suji__ API
fn injectJsHelpers(ctx: *c._cef_v8_context_t) void {
    // __suji_raw_invoke__(json) → Promise<string>  (네이티브 V8 바인딩)
    // __suji_raw_emit__(event, data) → void         (네이티브 V8 바인딩)
    // 이 위에 기존 webview와 동일한 JS 인터페이스를 구성
    const js_code =
        \\(function() {
        \\  var raw_invoke = window.__suji__.invoke;
        \\  var raw_emit = window.__suji__.emit;
        \\  var s = window.__suji__;
        \\  s._pending = {};
        \\  s._nextResolve = function(seq, json) {
        \\    var p = s._pending[seq];
        \\    if (p) { delete s._pending[seq]; try { p.resolve(JSON.parse(json)); } catch(e) { p.resolve(json); } }
        \\  };
        \\  s._nextReject = function(seq, err) {
        \\    var p = s._pending[seq];
        \\    if (p) { delete s._pending[seq]; p.reject(new Error(err)); }
        \\  };
        \\  s.invoke = function(channel, data, options) {
        \\    var req = data ? Object.assign({cmd: channel}, data) : {cmd: channel};
        \\    var target = options && options.target;
        \\    var seq = raw_invoke(target || channel, JSON.stringify(req));
        \\    return new Promise(function(resolve, reject) {
        \\      s._pending[seq] = { resolve: resolve, reject: reject };
        \\    });
        \\  };
        \\  s.emit = function(event, data, target) {
        \\    return raw_emit(event, JSON.stringify(data || {}), target);
        \\  };
        \\  s.chain = function(from, to, request) {
        \\    var seq = raw_invoke("__chain__", JSON.stringify({__chain:true,from:from,to:to,request:request}));
        \\    return new Promise(function(resolve, reject) { s._pending[seq] = { resolve: resolve, reject: reject }; });
        \\  };
        \\  s.fanout = function(backends, request) {
        \\    var seq = raw_invoke("__fanout__", JSON.stringify({__fanout:true,backends:backends,request:request}));
        \\    return new Promise(function(resolve, reject) { s._pending[seq] = { resolve: resolve, reject: reject }; });
        \\  };
        \\  s.core = function(request) {
        \\    var seq = raw_invoke("__core__", JSON.stringify({__core:true,request:request}));
        \\    return new Promise(function(resolve, reject) { s._pending[seq] = { resolve: resolve, reject: reject }; });
        \\  };
        \\  s._listeners = {};
        \\  s.on = function(event, callback) {
        \\    if (!s._listeners[event]) s._listeners[event] = [];
        \\    s._listeners[event].push(callback);
        \\    return function() {
        \\      var idx = s._listeners[event].indexOf(callback);
        \\      if (idx >= 0) s._listeners[event].splice(idx, 1);
        \\    };
        \\  };
        \\  s.off = function(event) {
        \\    delete s._listeners[event];
        \\  };
        \\  s.__dispatch__ = function(event, data) {
        \\    var cbs = s._listeners[event] || [];
        \\    for (var i = 0; i < cbs.length; i++) cbs[i](data);
        \\  };
        \\  // Electron 호환: quit() / platform
        \\  s.quit = function() {
        \\    raw_invoke("__core__", JSON.stringify({__core:true,request:JSON.stringify({cmd:"quit"})}));
        \\  };
        \\})();
    ;

    // Platform 문자열을 개별 eval로 주입 (컴파일타임 결정)
    const platform_js = "window.__suji__.platform = \"" ++ comptime platformLiteral() ++ "\";";

    var code_str: c.cef_string_t = .{};
    setCefString(&code_str, js_code);
    var empty_url: c.cef_string_t = .{};
    setCefString(&empty_url, "");
    var retval: ?*c.cef_v8_value_t = null;
    var exception: ?*c.cef_v8_exception_t = null;
    _ = ctx.eval.?(ctx, &code_str, &empty_url, 0, &retval, &exception);

    // Platform 주입
    var platform_str: c.cef_string_t = .{};
    setCefString(&platform_str, platform_js);
    _ = ctx.eval.?(ctx, &platform_str, &empty_url, 0, &retval, &exception);
}

/// 컴파일타임 플랫폼 문자열 (V8 바인딩의 window.__suji__.platform 값).
fn platformLiteral() []const u8 {
    return switch (builtin.os.tag) {
        .macos => "macos",
        .linux => "linux",
        .windows => "windows",
        else => @compileError("Suji: unsupported OS"),
    };
}

/// V8 함수 실행 콜백 (invoke, emit, on)
fn v8Execute(
    _: ?*c._cef_v8_handler_t,
    name_ptr: [*c]const c.cef_string_t,
    _: ?*c._cef_v8_value_t,
    arguments_count: usize,
    arguments: [*c]const ?*c.cef_v8_value_t,
    retval: ?*?*c.cef_v8_value_t,
    _: ?*c.cef_string_t,
) callconv(.c) i32 {
    var fn_name_buf: [32]u8 = undefined;
    const fn_name = cefStringToUtf8(name_ptr, &fn_name_buf);

    if (std.mem.eql(u8, fn_name, "invoke")) {
        return v8HandleInvoke(arguments_count, arguments, retval);
    } else if (std.mem.eql(u8, fn_name, "emit")) {
        return v8HandleEmit(arguments_count, arguments);
    }
    return 0;
}

/// raw invoke(channel, json_request) → Promise
/// JS 래퍼가 {cmd: channel, ...data}를 조립해서 json_request로 전달.
/// 1인자: invoke(json_request) — 자동 라우팅
/// 2인자: invoke(target, json_request) — 명시적 백엔드 지정
fn v8HandleInvoke(
    argc: usize,
    argv: [*c]const ?*c.cef_v8_value_t,
    retval: ?*?*c.cef_v8_value_t,
) i32 {
    if (argc < 1) return 0;

    var channel_buf: [256]u8 = undefined;
    var channel: []const u8 = "";
    var request_buf: [8192]u8 = undefined;
    var request: []const u8 = "{}";

    if (argc >= 2) {
        // 2인자: invoke(target_or_channel, json_request)
        const arg0 = argv[0] orelse return 0;
        channel = cefUserfreeToUtf8(arg0.get_string_value.?(arg0), &channel_buf);
        const arg1 = argv[1] orelse return 0;
        if (arg1.is_string.?(arg1) == 1) {
            request = cefUserfreeToUtf8(arg1.get_string_value.?(arg1), &request_buf);
        }
    } else {
        // 1인자: invoke(json_request) — cmd 필드에서 채널 추출
        const arg0 = argv[0] orelse return 0;
        if (arg0.is_string.?(arg0) == 1) {
            request = cefUserfreeToUtf8(arg0.get_string_value.?(arg0), &request_buf);
            // {"cmd":"ping",...} 에서 cmd 추출
            channel = extractCmd(request) orelse "";
        }
    }
    if (channel.len == 0) return 0;

    // 시퀀스 ID 할당 (JS에서 Promise 관리)
    const seq_id = g_seq_counter;
    g_seq_counter +%= 1;

    // 컨텍스트 저장 (응답 시 eval에 필요)
    const slot = seq_id % MAX_PENDING;
    const ctx = asPtr(c.cef_v8_context_t, c.cef_v8_context_get_current_context());
    g_pending_contexts[slot] = ctx;

    // CefProcessMessage 생성하여 메인 프로세스에 전송
    var msg_name: c.cef_string_t = .{};
    setCefString(&msg_name, "suji:invoke");
    const msg = asPtr(c.cef_process_message_t, c.cef_process_message_create(&msg_name)) orelse return 0;

    const args = asPtr(c.cef_list_value_t, msg.get_argument_list.?(msg)) orelse return 0;
    _ = args.set_int.?(args, 0, @intCast(seq_id));

    var ch_str: c.cef_string_t = .{};
    setCefString(&ch_str, channel);
    _ = args.set_string.?(args, 1, &ch_str);

    // JS에서 이미 {cmd: channel, ...data}로 조립된 JSON을 그대로 전달
    var req_str: c.cef_string_t = .{};
    setCefString(&req_str, request);
    _ = args.set_string.?(args, 2, &req_str);

    sendToBrowser(msg);

    // Promise 반환
    // seq_id를 JS에 반환 (JS가 이걸로 Promise를 _pending에 등록)
    if (retval) |rv| {
        rv.* = c.cef_v8_value_create_int(@intCast(seq_id));
    }
    return 1;
}

/// emit(event, data, target?) → void
/// target은 선택적 window id. JS 레이어가 `suji.send(..., {to: id})`에서 정수로 전달.
fn v8HandleEmit(argc: usize, argv: [*c]const ?*c.cef_v8_value_t) i32 {
    if (argc < 1) return 0;

    const event_v8 = argv[0] orelse return 0;
    var event_buf: [256]u8 = undefined;
    const event_userfree = event_v8.get_string_value.?(event_v8);
    const event = cefUserfreeToUtf8(event_userfree, &event_buf);

    var data_buf: [8192]u8 = undefined;
    var data: []const u8 = "{}";
    if (argc >= 2) {
        const data_v8 = argv[1];
        if (data_v8 != null and data_v8.?.is_string.?(data_v8) == 1) {
            const data_userfree = data_v8.?.get_string_value.?(data_v8);
            data = cefUserfreeToUtf8(data_userfree, &data_buf);
        }
    }

    // 3번째 인자: 선택적 target window id. number가 아니거나 < 1이면 브로드캐스트로 취급.
    var target: i32 = 0;
    if (argc >= 3) {
        const t_v8 = argv[2];
        if (t_v8 != null and t_v8.?.is_int.?(t_v8) == 1) {
            target = t_v8.?.get_int_value.?(t_v8);
        } else if (t_v8 != null and t_v8.?.is_uint.?(t_v8) == 1) {
            target = @intCast(t_v8.?.get_uint_value.?(t_v8));
        }
    }

    // CefProcessMessage로 메인 프로세스에 전송
    var msg_name: c.cef_string_t = .{};
    setCefString(&msg_name, "suji:emit");
    const msg = asPtr(c.cef_process_message_t, c.cef_process_message_create(&msg_name)) orelse return 0;

    const args = asPtr(c.cef_list_value_t, msg.get_argument_list.?(msg)) orelse return 0;

    var ev_str: c.cef_string_t = .{};
    setCefString(&ev_str, event);
    _ = args.set_string.?(args, 0, &ev_str);

    var data_str: c.cef_string_t = .{};
    setCefString(&data_str, data);
    _ = args.set_string.?(args, 1, &data_str);

    if (target > 0) {
        _ = args.set_int.?(args, 2, target);
    }

    sendToBrowser(msg);
    return 1;
}

/// 렌더러 프로세스: 메인에서 온 응답/이벤트 처리
fn onRendererProcessMessageReceived(
    _: ?*c._cef_render_process_handler_t,
    _: ?*c._cef_browser_t,
    _: ?*c._cef_frame_t,
    _: c.cef_process_id_t,
    message: ?*c._cef_process_message_t,
) callconv(.c) i32 {
    const msg = message orelse return 0;
    const name_userfree = msg.get_name.?(msg);
    var name_buf: [64]u8 = undefined;
    const msg_name = cefUserfreeToUtf8(name_userfree, &name_buf);


    if (std.mem.eql(u8, msg_name, "suji:response")) {
        return handleRendererResponse(msg);
    } else if (std.mem.eql(u8, msg_name, "suji:event")) {
        return handleRendererEvent(msg);
    }
    return 0;
}

/// invoke 응답 처리 → JS _nextResolve/_nextReject 호출
fn handleRendererResponse(msg: *c._cef_process_message_t) i32 {
    const args = asPtr(c.cef_list_value_t, msg.get_argument_list.?(msg)) orelse return 0;

    const seq_id: u32 = @intCast(args.get_int.?(args, 0));
    const success = args.get_int.?(args, 1) == 1;

    var result_buf: [16384]u8 = undefined;
    const result = getArgString(args, 2, &result_buf);


    const slot = seq_id % MAX_PENDING;
    const ctx = g_pending_contexts[slot] orelse g_renderer_context orelse return 0;
    g_pending_contexts[slot] = null;

    _ = ctx.enter.?(ctx);

    // JS에서 Promise resolve/reject
    // result를 hex-escape하여 single-quote injection 방지
    var hex_buf: [32768]u8 = undefined;
    const hex = jsonToHexEscape(result, &hex_buf);

    var js_buf: [33000]u8 = undefined;
    const js = if (success)
        std.fmt.bufPrint(&js_buf, "window.__suji__._nextResolve({d},decodeURIComponent('{s}'))", .{ seq_id, hex }) catch {
            _ = ctx.exit.?(ctx);
            return 0;
        }
    else
        std.fmt.bufPrint(&js_buf, "window.__suji__._nextReject({d},decodeURIComponent('{s}'))", .{ seq_id, hex }) catch {
            _ = ctx.exit.?(ctx);
            return 0;
        };

    var code_str: c.cef_string_t = .{};
    setCefString(&code_str, js);
    var empty_url: c.cef_string_t = .{};
    setCefString(&empty_url, "");
    var retval: ?*c.cef_v8_value_t = null;
    var exception: ?*c.cef_v8_exception_t = null;
    _ = ctx.eval.?(ctx, &code_str, &empty_url, 0, &retval, &exception);

    _ = ctx.exit.?(ctx);
    return 1;
}

/// 메인에서 푸시된 이벤트 → JS __dispatch__ 호출
fn handleRendererEvent(msg: *c._cef_process_message_t) i32 {
    const args = asPtr(c.cef_list_value_t, msg.get_argument_list.?(msg)) orelse return 0;

    var event_buf: [256]u8 = undefined;
    const event = getArgString(args, 0, &event_buf);

    var data_buf: [8192]u8 = undefined;
    const data = getArgString(args, 1, &data_buf);

    // 저장된 렌더러 컨텍스트 사용 (onContextCreated에서 저장)
    // cef_v8_context_get_current_context()는 메시지 핸들러에서 유효하지 않을 수 있음
    const ctx = g_renderer_context orelse return 0;
    _ = ctx.enter.?(ctx);

    // data를 hex-escape하여 injection 방지
    var hex_buf: [16384]u8 = undefined;
    const hex_data = jsonToHexEscape(data, &hex_buf);
    var js_buf: [33000]u8 = undefined;
    const js = std.fmt.bufPrint(&js_buf, "window.__suji__.__dispatch__(\"{s}\",JSON.parse(decodeURIComponent('{s}')))", .{ event, hex_data }) catch {
        _ = ctx.exit.?(ctx);
        return 0;
    };

    var code_str: c.cef_string_t = .{};
    setCefString(&code_str, js);
    var empty_url: c.cef_string_t = .{};
    setCefString(&empty_url, "");
    var retval: ?*c.cef_v8_value_t = null;
    var exception: ?*c.cef_v8_exception_t = null;
    _ = ctx.eval.?(ctx, &code_str, &empty_url, 0, &retval, &exception);

    _ = ctx.exit.?(ctx);
    return 1;
}

// ============================================
// Custom Scheme: suji://
// ============================================
//
// suji://app/path → dist 디렉토리에서 파일 서빙
// file:// 대신 사용하여 CORS, fetch, cookie 등 정상 동작

/// dist 경로 설정 (main.zig에서 호출)
var g_dist_path: [1024]u8 = undefined;
var g_dist_path_len: usize = 0;

pub fn setDistPath(path: []const u8) void {
    const len = @min(path.len, g_dist_path.len);
    @memcpy(g_dist_path[0..len], path[0..len]);
    g_dist_path_len = len;
}

fn getDistPath() []const u8 {
    return g_dist_path[0..g_dist_path_len];
}

/// on_register_custom_schemes — "suji" 스킴 등록 (모든 프로세스에서 호출됨)
fn onRegisterCustomSchemes(
    _: ?*c._cef_app_t,
    registrar: ?*c._cef_scheme_registrar_t,
) callconv(.c) void {
    const reg = registrar orelse return;
    var scheme_name: c.cef_string_t = .{};
    setCefString(&scheme_name, "suji");
    // STANDARD + LOCAL + SECURE + CORS_ENABLED + FETCH_ENABLED + CSP_BYPASSING
    const options = c.CEF_SCHEME_OPTION_STANDARD |
        c.CEF_SCHEME_OPTION_LOCAL |
        c.CEF_SCHEME_OPTION_SECURE |
        c.CEF_SCHEME_OPTION_CORS_ENABLED |
        c.CEF_SCHEME_OPTION_FETCH_ENABLED |
        c.CEF_SCHEME_OPTION_CSP_BYPASSING;
    const result = reg.add_custom_scheme.?(reg, &scheme_name, options);
    std.debug.print("[suji] register scheme 'suji': {d}\n", .{result});
}

/// cef_initialize 후 호출 — scheme handler factory 등록
pub fn registerSchemeHandlerFactory() void {
    var scheme_name: c.cef_string_t = .{};
    setCefString(&scheme_name, "suji");
    var domain_name: c.cef_string_t = .{};
    setCefString(&domain_name, "app");

    initSchemeHandlerFactory();
    const result = c.cef_register_scheme_handler_factory(&scheme_name, &domain_name, &g_scheme_factory);
    std.debug.print("[suji] register scheme handler factory: {d}\n", .{result});
}

// --- Scheme Handler Factory ---

var g_scheme_factory: c.cef_scheme_handler_factory_t = undefined;
var g_scheme_factory_initialized: bool = false;

fn initSchemeHandlerFactory() void {
    if (g_scheme_factory_initialized) return;
    zeroCefStruct(c.cef_scheme_handler_factory_t, &g_scheme_factory);
    initBaseRefCounted(&g_scheme_factory.base);
    g_scheme_factory.create = &schemeFactoryCreate;
    g_scheme_factory_initialized = true;
}

fn schemeFactoryCreate(
    _: ?*c._cef_scheme_handler_factory_t,
    _: ?*c._cef_browser_t,
    _: ?*c._cef_frame_t,
    _: [*c]const c.cef_string_t,
    request: ?*c._cef_request_t,
) callconv(.c) ?*c._cef_resource_handler_t {
    const req = request orelse return null;

    // URL에서 경로 추출: suji://app/path → /path
    const url_userfree = req.get_url.?(req);
    var url_buf: [2048]u8 = undefined;
    const url = cefUserfreeToUtf8(url_userfree, &url_buf);

    // "suji://app" 이후의 경로 추출
    var path: []const u8 = "/index.html";
    if (std.mem.indexOf(u8, url, "suji://app")) |idx| {
        const after = url[idx + "suji://app".len ..];
        if (after.len > 0 and after[0] == '/') {
            path = after;
        }
    }

    // "/" → "/index.html"
    if (std.mem.eql(u8, path, "/")) {
        path = "/index.html";
    }

    std.debug.print("[suji] scheme request: {s} → {s}\n", .{ url, path });

    // dist 경로 + 요청 경로 → 파일 시스템 경로
    const dist = getDistPath();
    if (dist.len == 0) return null;

    var file_path_buf: [2048]u8 = undefined;
    const file_path = std.fmt.bufPrint(&file_path_buf, "{s}{s}", .{ dist, path }) catch return null;

    // 파일 읽기 (동기 — IO 스레드에서 실행됨)
    const io = runtime.io;
    var file = std.Io.Dir.openFileAbsolute(io, file_path, .{}) catch {
        std.debug.print("[suji] scheme 404: {s}\n", .{file_path});
        return createErrorHandler(404);
    };
    defer file.close(io);

    const stat = file.stat(io) catch return null;
    const file_size = stat.size;

    // 파일 내용 읽기 (최대 64MB)
    const max_size: usize = 64 * 1024 * 1024;
    const read_size: usize = @intCast(@min(file_size, @as(u64, max_size)));
    const data = std.heap.page_allocator.alloc(u8, read_size) catch return null;
    var rd_buf: [0]u8 = undefined;
    var fr = file.reader(io, &rd_buf);
    const bytes_read = fr.interface.readSliceShort(data) catch {
        std.heap.page_allocator.free(data);
        return null;
    };

    // MIME type 결정
    const mime = mimeTypeForPath(path);

    // ResourceHandler 생성
    return createResourceHandler(data[0..bytes_read], mime) orelse {
        std.heap.page_allocator.free(data);
        return null;
    };
}

// --- Resource Handler ---

const ResourceHandlerData = struct {
    handler: c.cef_resource_handler_t,
    data: []u8,
    mime: [:0]const u8,
    offset: usize,
    status_code: i32,
};

fn createResourceHandler(data: []u8, mime: [:0]const u8) ?*c.cef_resource_handler_t {
    const rh = std.heap.page_allocator.create(ResourceHandlerData) catch return null;
    zeroCefStruct(c.cef_resource_handler_t, &rh.handler);
    initBaseRefCounted(&rh.handler.base);
    rh.handler.open = &rhOpen;
    rh.handler.get_response_headers = &rhGetResponseHeaders;
    rh.handler.read = &rhRead;
    rh.handler.cancel = &rhCancel;
    // deprecated 콜백은 null로 (Zig가 0으로 초기화)
    rh.data = data;
    rh.mime = mime;
    rh.offset = 0;
    rh.status_code = 200;
    return &rh.handler;
}

fn createErrorHandler(status: i32) ?*c.cef_resource_handler_t {
    const body = std.heap.page_allocator.alloc(u8, 0) catch return null;
    const rh = std.heap.page_allocator.create(ResourceHandlerData) catch {
        std.heap.page_allocator.free(body);
        return null;
    };
    zeroCefStruct(c.cef_resource_handler_t, &rh.handler);
    initBaseRefCounted(&rh.handler.base);
    rh.handler.open = &rhOpen;
    rh.handler.get_response_headers = &rhGetResponseHeaders;
    rh.handler.read = &rhRead;
    rh.handler.cancel = &rhCancel;
    rh.data = body;
    rh.mime = "text/plain";
    rh.offset = 0;
    rh.status_code = status;
    return &rh.handler;
}

fn getRhData(self: ?*c._cef_resource_handler_t) ?*ResourceHandlerData {
    const ptr = self orelse return null;
    return @fieldParentPtr("handler", ptr);
}

fn rhOpen(
    self: ?*c._cef_resource_handler_t,
    _: ?*c._cef_request_t,
    handle_request: ?*i32,
    _: ?*c._cef_callback_t,
) callconv(.c) i32 {
    _ = getRhData(self) orelse return 0;
    if (handle_request) |hr| hr.* = 1; // 즉시 처리
    return 1;
}

fn rhGetResponseHeaders(
    self: ?*c._cef_resource_handler_t,
    response: ?*c._cef_response_t,
    response_length: ?*i64,
    _: ?*c.cef_string_t,
) callconv(.c) void {
    const rh = getRhData(self) orelse return;
    const resp = response orelse return;

    resp.set_status.?(resp, rh.status_code);

    var mime_str: c.cef_string_t = .{};
    setCefString(&mime_str, rh.mime);
    resp.set_mime_type.?(resp, &mime_str);

    if (response_length) |rl| {
        rl.* = @intCast(rh.data.len);
    }
}

fn rhRead(
    self: ?*c._cef_resource_handler_t,
    data_out: ?*anyopaque,
    bytes_to_read: i32,
    bytes_read: ?*i32,
    _: ?*c._cef_resource_read_callback_t,
) callconv(.c) i32 {
    const rh = getRhData(self) orelse return 0;
    const br = bytes_read orelse return 0;
    const out: [*]u8 = @ptrCast(data_out orelse return 0);

    if (rh.offset >= rh.data.len) {
        br.* = 0;
        return 0; // 완료
    }

    const remaining = rh.data.len - rh.offset;
    const to_read = @min(remaining, @as(usize, @intCast(bytes_to_read)));
    @memcpy(out[0..to_read], rh.data[rh.offset..][0..to_read]);
    rh.offset += to_read;
    br.* = @intCast(to_read);
    return 1;
}

fn rhCancel(self: ?*c._cef_resource_handler_t) callconv(.c) void {
    const rh = getRhData(self) orelse return;
    if (rh.data.len > 0) {
        std.heap.page_allocator.free(rh.data);
        rh.data = &.{};
    }
    std.heap.page_allocator.destroy(rh);
}

fn mimeTypeForPath(path: []const u8) [:0]const u8 {
    if (std.mem.endsWith(u8, path, ".html") or std.mem.endsWith(u8, path, ".htm")) return "text/html";
    if (std.mem.endsWith(u8, path, ".js") or std.mem.endsWith(u8, path, ".mjs")) return "application/javascript";
    if (std.mem.endsWith(u8, path, ".css")) return "text/css";
    if (std.mem.endsWith(u8, path, ".json")) return "application/json";
    if (std.mem.endsWith(u8, path, ".png")) return "image/png";
    if (std.mem.endsWith(u8, path, ".jpg") or std.mem.endsWith(u8, path, ".jpeg")) return "image/jpeg";
    if (std.mem.endsWith(u8, path, ".gif")) return "image/gif";
    if (std.mem.endsWith(u8, path, ".svg")) return "image/svg+xml";
    if (std.mem.endsWith(u8, path, ".ico")) return "image/x-icon";
    if (std.mem.endsWith(u8, path, ".woff")) return "font/woff";
    if (std.mem.endsWith(u8, path, ".woff2")) return "font/woff2";
    if (std.mem.endsWith(u8, path, ".ttf")) return "font/ttf";
    if (std.mem.endsWith(u8, path, ".wasm")) return "application/wasm";
    if (std.mem.endsWith(u8, path, ".map")) return "application/json";
    return "application/octet-stream";
}

/// 플랫폼별 윈도우 초기화 옵션. CefConfig(process-level)와 분리 — per-window 속성.
/// Appearance / Constraints는 window 모듈 sub-struct를 그대로 재사용 (3중 정의 회피).
pub const WindowInitOpts = struct {
    title: [:0]const u8,
    width: i32,
    height: i32,
    /// 0이면 cascade 자동 배치 (`cascadeTopLeftFromPoint:`).
    x: i32 = 0,
    y: i32 = 0,
    appearance: window_mod.Appearance = .{},
    constraints: window_mod.Constraints = .{},
};

/// 플랫폼별 윈도우 초기화. 반환값: macOS에서만 NSWindow 포인터 (이후 close 트리거용).
/// Linux/Windows는 CEF가 자체 창을 만들므로 null.
const initWindowInfo = if (is_macos) struct {
    fn call(window_info: *c.cef_window_info_t, opts: WindowInitOpts) ?*anyopaque {
        const handles = createMacWindow(opts);
        if (handles.content_view) |cv| {
            window_info.parent_view = cv;
        }
        return handles.ns_window;
    }
}.call else struct {
    fn call(_: *c.cef_window_info_t, opts: WindowInitOpts) ?*anyopaque {
        warnUnsupportedOptionsOnce(opts);
        return null;
    }
}.call;

/// Phase 3 옵션 중 macOS-only가 set되어 있으면 process당 한 번만 stderr에 안내.
/// silent no-op이면 사용자가 "왜 안 되지?" 디버그하게 됨 → 명시적 warn.
var g_warned_unsupported_options: bool = false;
fn warnUnsupportedOptionsOnce(opts: WindowInitOpts) void {
    if (g_warned_unsupported_options) return;
    if (!hasMacOnlyOption(opts)) return;
    g_warned_unsupported_options = true;
    if (!builtin.is_test) std.debug.print(
        "[suji] warning: window appearance/constraints (frame/transparent/parent/always_on_top/title_bar_style/min·max/fullscreen/background_color) are macOS-only and were ignored on this platform\n",
        .{},
    );
}

fn hasMacOnlyOption(opts: WindowInitOpts) bool {
    const ap = opts.appearance;
    const cs = opts.constraints;
    return !ap.frame or ap.transparent or
        ap.background_color != null or ap.title_bar_style != .default or
        cs.always_on_top or cs.fullscreen or
        cs.min_width != 0 or cs.min_height != 0 or
        cs.max_width != 0 or cs.max_height != 0 or
        opts.parent_id != null;
}

// ============================================
// macOS Objective-C Helpers
// ============================================

fn msgSend(target: anytype, sel_name: [:0]const u8) ?*anyopaque {
    const sel = objc.sel_registerName(sel_name.ptr);
    const func: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque = @ptrCast(&objc.objc_msgSend);
    return func(@ptrCast(target), @ptrCast(sel));
}

fn getClass(name: [:0]const u8) ?*anyopaque {
    return @ptrCast(objc.objc_getClass(name.ptr));
}

fn initNSApp() void {
    const cls = getClass("NSApplication") orelse return;

    // CEF DevTools가 호출하는 isHandlingSendEvent 메서드를 NSApplication에 추가
    // (기본 NSApplication에는 없어서 unrecognized selector 크래시 발생)
    const isSel = objc.sel_registerName("isHandlingSendEvent");
    _ = objc.class_addMethod(
        @ptrCast(cls),
        isSel,
        @ptrCast(&isHandlingSendEventImpl),
        "B@:",
    );
    // _setHandlingSendEvent: (underscore prefix, 전통적 private setter)
    const setSel = objc.sel_registerName("_setHandlingSendEvent:");
    _ = objc.class_addMethod(
        @ptrCast(cls),
        setSel,
        @ptrCast(&setHandlingSendEventImpl),
        "v@:B",
    );
    // setHandlingSendEvent: (CEF 신버전이 underscore 없이 호출하는 경로 대응)
    const setSel2 = objc.sel_registerName("setHandlingSendEvent:");
    _ = objc.class_addMethod(
        @ptrCast(cls),
        setSel2,
        @ptrCast(&setHandlingSendEventImpl),
        "v@:B",
    );

    const app = msgSend(cls, "sharedApplication") orelse return;
    const sel = objc.sel_registerName("setActivationPolicy:");
    const func: *const fn (?*anyopaque, ?*anyopaque, i64) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    func(app, @ptrCast(sel), 0);

    // 메뉴바 등록
    setupMainMenu(app);
}

var g_handling_send_event: bool = false;

fn isHandlingSendEventImpl(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) u8 {
    return if (g_handling_send_event) 1 else 0;
}

fn setHandlingSendEventImpl(_: ?*anyopaque, _: ?*anyopaque, value: u8) callconv(.c) void {
    g_handling_send_event = value != 0;
}

/// macOS 메뉴바 생성 — Edit 메뉴 (Cmd+C/V/X/A/Z/Shift+Z)
fn setupMainMenu(app: ?*anyopaque) void {
    const NSMenu = getClass("NSMenu") orelse return;

    // 메인 메뉴바
    const menubar = msgSend(msgSend(NSMenu, "alloc") orelse return, "init") orelse return;

    // 1. App 메뉴
    const app_menu = createMenu("") orelse return;
    addMenuItem(app_menu, "About Suji", "orderFrontStandardAboutPanel:", "");
    addSeparator(app_menu);
    addMenuItem(app_menu, "Hide Suji", "hide:", "h");
    addMenuItemWithModifier(app_menu, "Hide Others", "hideOtherApplications:", "h", true);
    addMenuItem(app_menu, "Show All", "unhideAllApplications:", "");
    addSeparator(app_menu);
    addMenuItem(app_menu, "Quit Suji", "terminate:", "q");
    addSubmenuItem(menubar, "", app_menu);

    // 2. File 메뉴
    const file_menu = createMenu("File") orelse return;
    addMenuItem(file_menu, "Close Window", "performClose:", "w");
    addSubmenuItem(menubar, "File", file_menu);

    // 3. Edit 메뉴
    const edit_menu = createMenu("Edit") orelse return;
    addMenuItem(edit_menu, "Undo", "undo:", "z");
    addMenuItemWithModifier(edit_menu, "Redo", "redo:", "z", true);
    addSeparator(edit_menu);
    addMenuItem(edit_menu, "Cut", "cut:", "x");
    addMenuItem(edit_menu, "Copy", "copy:", "c");
    addMenuItem(edit_menu, "Paste", "paste:", "v");
    addMenuItemWithModifiers(edit_menu, "Paste and Match Style", "pasteAsPlainText:", "v", true, true); // Opt+Shift+Cmd+V
    addMenuItem(edit_menu, "Delete", "delete:", "");
    addMenuItem(edit_menu, "Select All", "selectAll:", "a");
    addSeparator(edit_menu);
    // Substitutions 서브메뉴
    if (createMenu("Substitutions")) |sub_menu| {
        addMenuItem(sub_menu, "Show Substitutions", "orderFrontSubstitutionsPanel:", "");
        addSeparator(sub_menu);
        addMenuItem(sub_menu, "Smart Copy/Paste", "toggleSmartInsertDelete:", "");
        addMenuItem(sub_menu, "Smart Quotes", "toggleAutomaticQuoteSubstitution:", "");
        addMenuItem(sub_menu, "Smart Dashes", "toggleAutomaticDashSubstitution:", "");
        addMenuItem(sub_menu, "Smart Links", "toggleAutomaticLinkDetection:", "");
        addMenuItem(sub_menu, "Text Replacement", "toggleAutomaticTextReplacement:", "");
        addSubmenuItem(edit_menu, "Substitutions", sub_menu);
    }
    // Speech 서브메뉴
    if (createMenu("Speech")) |speech_menu| {
        addMenuItem(speech_menu, "Start Speaking", "startSpeaking:", "");
        addMenuItem(speech_menu, "Stop Speaking", "stopSpeaking:", "");
        addSubmenuItem(edit_menu, "Speech", speech_menu);
    }
    addSubmenuItem(menubar, "Edit", edit_menu);

    // 4. View 메뉴
    const view_menu = createMenu("View") orelse return;
    addMenuItem(view_menu, "Reload", "reload:", "r");
    addMenuItemWithModifier(view_menu, "Force Reload", "reloadIgnoringCache:", "r", true);
    addMenuItemWithModifiers(view_menu, "Toggle Developer Tools", "toggleDeveloperTools:", "i", false, true); // Alt+Cmd+I
    addSeparator(view_menu);
    addMenuItem(view_menu, "Actual Size", "resetZoom:", "0");
    addMenuItem(view_menu, "Zoom In", "zoomIn:", "+");
    addMenuItem(view_menu, "Zoom Out", "zoomOut:", "-");
    addSeparator(view_menu);
    addMenuItem(view_menu, "Toggle Full Screen", "toggleFullScreen:", "f");
    addSubmenuItem(menubar, "View", view_menu);

    // 5. Window 메뉴
    const window_menu = createMenu("Window") orelse return;
    addMenuItem(window_menu, "Minimize", "performMiniaturize:", "m");
    addMenuItem(window_menu, "Zoom", "performZoom:", "");
    addSeparator(window_menu);
    addMenuItem(window_menu, "Bring All to Front", "arrangeInFront:", "");
    addSubmenuItem(menubar, "Window", window_menu);

    // 6. Help 메뉴
    const help_menu = createMenu("Help") orelse return;
    addSubmenuItem(menubar, "Help", help_menu);

    msgSendVoid1(app, "setMainMenu:", menubar);
}

fn createMenu(title: [:0]const u8) ?*anyopaque {
    const NSMenu = getClass("NSMenu") orelse return null;
    const alloc = msgSend(NSMenu, "alloc") orelse return null;
    const NSString = getClass("NSString") orelse return null;
    const strFn: *const fn (?*anyopaque, ?*anyopaque, [*:0]const u8) callconv(.c) ?*anyopaque = @ptrCast(&objc.objc_msgSend);
    const ns_title = strFn(NSString, @ptrCast(objc.sel_registerName("stringWithUTF8String:")), title.ptr);
    const initSel = objc.sel_registerName("initWithTitle:");
    const initFn: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque = @ptrCast(&objc.objc_msgSend);
    return initFn(alloc, @ptrCast(initSel), ns_title);
}

fn addSubmenuItem(menubar: *anyopaque, title: [:0]const u8, submenu: *anyopaque) void {
    const item = msgSend(msgSend(getClass("NSMenuItem") orelse return, "alloc") orelse return, "init") orelse return;
    msgSendVoid1(item, "setSubmenu:", submenu);
    if (title.len > 0) {
        const NSString = getClass("NSString") orelse return;
        const strFn: *const fn (?*anyopaque, ?*anyopaque, [*:0]const u8) callconv(.c) ?*anyopaque = @ptrCast(&objc.objc_msgSend);
        const ns_title = strFn(NSString, @ptrCast(objc.sel_registerName("stringWithUTF8String:")), title.ptr);
        msgSendVoid1(item, "setTitle:", ns_title);
    }
    msgSendVoid1(menubar, "addItem:", item);
}

fn addMenuItemWithModifier(menu: *anyopaque, title: [:0]const u8, action: [:0]const u8, key: [:0]const u8, shift: bool) void {
    const NSMenuItem = getClass("NSMenuItem") orelse return;
    const NSString = getClass("NSString") orelse return;
    const strFn: *const fn (?*anyopaque, ?*anyopaque, [*:0]const u8) callconv(.c) ?*anyopaque = @ptrCast(&objc.objc_msgSend);
    const ns_title = strFn(NSString, @ptrCast(objc.sel_registerName("stringWithUTF8String:")), title.ptr);
    const ns_key = strFn(NSString, @ptrCast(objc.sel_registerName("stringWithUTF8String:")), key.ptr);

    const initSel = objc.sel_registerName("initWithTitle:action:keyEquivalent:");
    const initFn: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque = @ptrCast(&objc.objc_msgSend);
    const alloc = msgSend(NSMenuItem, "alloc") orelse return;
    const item = initFn(alloc, @ptrCast(initSel), ns_title, @ptrCast(objc.sel_registerName(action.ptr)), ns_key) orelse return;

    if (shift) {
        // NSCommandKeyMask | NSShiftKeyMask = (1 << 20) | (1 << 17)
        const setModSel = objc.sel_registerName("setKeyEquivalentModifierMask:");
        const setModFn: *const fn (?*anyopaque, ?*anyopaque, u64) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
        setModFn(item, @ptrCast(setModSel), (1 << 20) | (1 << 17));
    }

    msgSendVoid1(menu, "addItem:", item);
}

fn addMenuItemWithModifiers(menu: *anyopaque, title: [:0]const u8, action: [:0]const u8, key: [:0]const u8, shift: bool, alt: bool) void {
    const NSMenuItem = getClass("NSMenuItem") orelse return;
    const NSString = getClass("NSString") orelse return;
    const strFn: *const fn (?*anyopaque, ?*anyopaque, [*:0]const u8) callconv(.c) ?*anyopaque = @ptrCast(&objc.objc_msgSend);
    const ns_title = strFn(NSString, @ptrCast(objc.sel_registerName("stringWithUTF8String:")), title.ptr);
    const ns_key = strFn(NSString, @ptrCast(objc.sel_registerName("stringWithUTF8String:")), key.ptr);

    const initSel = objc.sel_registerName("initWithTitle:action:keyEquivalent:");
    const initFn: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque = @ptrCast(&objc.objc_msgSend);
    const alloc = msgSend(NSMenuItem, "alloc") orelse return;
    const item = initFn(alloc, @ptrCast(initSel), ns_title, @ptrCast(objc.sel_registerName(action.ptr)), ns_key) orelse return;

    // NSCommandKeyMask=1<<20, NSShiftKeyMask=1<<17, NSAlternateKeyMask=1<<19
    var mask: u64 = 1 << 20; // Cmd
    if (shift) mask |= 1 << 17;
    if (alt) mask |= 1 << 19;
    const setModSel = objc.sel_registerName("setKeyEquivalentModifierMask:");
    const setModFn: *const fn (?*anyopaque, ?*anyopaque, u64) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    setModFn(item, @ptrCast(setModSel), mask);

    msgSendVoid1(menu, "addItem:", item);
}

fn addMenuItem(menu: *anyopaque, title: [:0]const u8, action: [:0]const u8, key: [:0]const u8) void {
    const NSMenuItem = getClass("NSMenuItem") orelse return;
    const NSString = getClass("NSString") orelse return;
    const strFn: *const fn (?*anyopaque, ?*anyopaque, [*:0]const u8) callconv(.c) ?*anyopaque = @ptrCast(&objc.objc_msgSend);
    const ns_title = strFn(NSString, @ptrCast(objc.sel_registerName("stringWithUTF8String:")), title.ptr);
    const ns_key = strFn(NSString, @ptrCast(objc.sel_registerName("stringWithUTF8String:")), key.ptr);

    const initSel = objc.sel_registerName("initWithTitle:action:keyEquivalent:");
    const initFn: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque = @ptrCast(&objc.objc_msgSend);
    const alloc = msgSend(NSMenuItem, "alloc") orelse return;
    const item = initFn(alloc, @ptrCast(initSel), ns_title, @ptrCast(objc.sel_registerName(action.ptr)), ns_key) orelse return;
    msgSendVoid1(menu, "addItem:", item);
}

fn addSeparator(menu: *anyopaque) void {
    const NSMenuItem = getClass("NSMenuItem") orelse return;
    const sep = msgSend(NSMenuItem, "separatorItem") orelse return;
    msgSendVoid1(menu, "addItem:", sep);
}

fn msgSendVoid1(target: ?*anyopaque, sel_name: [:0]const u8, arg: ?*anyopaque) void {
    const sel = objc.sel_registerName(sel_name.ptr);
    const func: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    func(target, @ptrCast(sel), arg);
}

/// BOOL 인자(u8 0/1) 버전 — setOpaque:/setHasShadow: 등 Objective-C BOOL setter용.
fn msgSendVoidBool(target: ?*anyopaque, sel_name: [:0]const u8, arg: bool) void {
    const sel = objc.sel_registerName(sel_name.ptr);
    const func: *const fn (?*anyopaque, ?*anyopaque, u8) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    func(target, @ptrCast(sel), if (arg) 1 else 0);
}

fn activateNSApp() void {
    const cls = getClass("NSApplication") orelse return;
    const app = msgSend(cls, "sharedApplication") orelse return;

    _ = msgSend(app, "finishLaunching");

    const sel = objc.sel_registerName("activateIgnoringOtherApps:");
    const func: *const fn (?*anyopaque, ?*anyopaque, u8) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    func(app, @ptrCast(sel), 1);
}

pub const MacWindowHandles = struct {
    content_view: ?*anyopaque,
    ns_window: ?*anyopaque,
};

// macOS Foundation/AppKit 기본 geometry 타입. ARM64 ABI는 4×f64 NSRect를 d0~d3 float
// 레지스터로 전달 — extern struct 그대로 두면 Zig가 올바른 calling convention 선택.
// 모든 macOS 헬퍼가 동일 정의 공유 (이전엔 createMacWindow / setMacWindowBounds /
// setMacContentSizeLimits 각각 별도 정의 → 필드명 불일치).
pub const NSPoint = extern struct { x: f64, y: f64 };
pub const NSSize = extern struct { width: f64, height: f64 };
pub const NSRect = extern struct { x: f64, y: f64, width: f64, height: f64 };

/// NSWindow 다중 cascade origin — 첫 호출은 (0, 0)으로 시작 (NSWindow가 화면에 적당히 배치),
/// 이후 매 호출마다 cascadeTopLeftFromPoint: 반환값으로 갱신 → 18px 우/하 offset 자동.
var g_cascade_point: NSPoint = .{ .x = 0, .y = 0 };

fn createMacWindow(opts: WindowInitOpts) MacWindowHandles {
    // 단계 분리:
    //   1) alloc + style mask + initial frame으로 NSWindow 생성
    //   2) x/y 미지정 시 cascade 다음 위치 갱신
    //   3) post-create options 적용 (transparent / shadow / level / size limits / titlebar)
    //   4) title 설정 + makeKeyAndOrderFront
    //   5) fullscreen 토글 (화면에 떠야 의미 있어 마지막)
    const window = allocMacWindow(opts) orelse return .{ .content_view = null, .ns_window = null };
    if (opts.x == 0 and opts.y == 0) advanceCascade(window);
    applyMacWindowOptions(window, opts);
    setMacWindowTitle(window, opts.title);
    const contentView = msgSend(window, "contentView");
    // NSWindow는 releasedWhenClosed=YES(기본값) + NSApp window list 보관으로 수명 관리.
    // 추가 retain 없이 자연스럽게 close 시 dealloc.
    msgSendVoid1(window, "makeKeyAndOrderFront:", null);
    if (opts.constraints.fullscreen) toggleMacFullScreen(window);
    return .{ .content_view = contentView, .ns_window = window };
}

/// NSWindow.alloc + initWithContentRect:styleMask:backing:defer:.
/// frame=false면 borderless(0). frame=true면 titled+closable+miniaturizable[+resizable].
/// borderless는 별도 키보드/마우스 처리 + drag region을 사용자가 직접 만들어야 함 (Phase 4 백로그).
fn allocMacWindow(opts: WindowInitOpts) ?*anyopaque {
    const NSWindow = getClass("NSWindow") orelse return null;
    const window_alloc = msgSend(NSWindow, "alloc") orelse return null;
    const initSel = objc.sel_registerName("initWithContentRect:styleMask:backing:defer:");
    const initFn: *const fn (?*anyopaque, ?*anyopaque, NSRect, u64, u64, u8) callconv(.c) ?*anyopaque = @ptrCast(&objc.objc_msgSend);
    return initFn(window_alloc, @ptrCast(initSel), resolveInitialFrame(opts), computeStyleMask(opts), 2, 0);
}

/// NSWindowStyleMask: titled(1)+closable(2)+miniaturizable(4)+resizable(8).
fn computeStyleMask(opts: WindowInitOpts) u64 {
    if (!opts.appearance.frame) return 0;
    var mask: u64 = 1 | 2 | 4;
    if (opts.constraints.resizable) mask |= 8;
    return mask;
}

/// x/y가 명시됐으면 그 위치, 아니면 (200,200) 시작 — 그 다음 cascade에서 OS가 갱신.
fn resolveInitialFrame(opts: WindowInitOpts) NSRect {
    const explicit = opts.x != 0 or opts.y != 0;
    return .{
        .x = if (explicit) @floatFromInt(opts.x) else 200,
        .y = if (explicit) @floatFromInt(opts.y) else 200,
        .width = @floatFromInt(opts.width),
        .height = @floatFromInt(opts.height),
    };
}

/// [NSWindow cascadeTopLeftFromPoint:] — 매 호출마다 18px offset된 새 origin 반환.
/// 모듈 전역 g_cascade_point을 갱신해 다음 창이 그 자리부터 시작.
fn advanceCascade(window: *anyopaque) void {
    const sel = objc.sel_registerName("cascadeTopLeftFromPoint:");
    const fn_ptr: *const fn (?*anyopaque, ?*anyopaque, NSPoint) callconv(.c) NSPoint = @ptrCast(&objc.objc_msgSend);
    g_cascade_point = fn_ptr(window, @ptrCast(sel), g_cascade_point);
}

/// post-create options — frame/style은 alloc 시점에 결정되고, 나머지는 setter들.
fn applyMacWindowOptions(window: *anyopaque, opts: WindowInitOpts) void {
    const ap = opts.appearance;
    const cs = opts.constraints;
    if (ap.transparent) applyTransparency(window);
    if (cs.always_on_top) setAlwaysOnTop(window);
    if (ap.background_color) |hex| applyBackgroundColor(window, hex);
    setMacContentSizeLimits(window, cs.min_width, cs.min_height, cs.max_width, cs.max_height);
    if (ap.title_bar_style != .default) applyTitleBarStyle(window, ap.title_bar_style);
}

/// macOS: 자식 창을 부모 위에 attach. NSWindow.addChildWindow:ordered:NSWindowAbove(1).
/// 시각 관계만 — 자식은 부모와 함께 이동/min/order 변경되지만 수명은 독립 (PLAN 재귀 close X).
fn attachMacChildWindow(parent: *anyopaque, child: *anyopaque) void {
    const sel = objc.sel_registerName("addChildWindow:ordered:");
    const fn_ptr: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque, c_long) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    fn_ptr(parent, @ptrCast(sel), child, 1); // NSWindowAbove = 1
}

/// macOS: 투명 창 설정 — opaque=NO + clearColor 배경 + 그림자 제거.
/// 그림자를 제거하지 않으면 투명 영역 가장자리에 클리핑 자국이 남는다.
fn applyTransparency(window: ?*anyopaque) void {
    msgSendVoidBool(window, "setOpaque:", false);
    const NSColor = getClass("NSColor") orelse return;
    if (msgSend(NSColor, "clearColor")) |cc| {
        msgSendVoid1(window, "setBackgroundColor:", cc);
    }
    msgSendVoidBool(window, "setHasShadow:", false);
}

/// macOS: NSWindow.level = NSFloatingWindowLevel(3) — 일반 창 위에 항상 떠 있음.
fn setAlwaysOnTop(window: ?*anyopaque) void {
    const sel = objc.sel_registerName("setLevel:");
    const fn_ptr: *const fn (?*anyopaque, ?*anyopaque, c_long) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    fn_ptr(window, @ptrCast(sel), 3); // NSFloatingWindowLevel
}

/// macOS: NSWindow.contentMinSize / contentMaxSize. 0이면 기본값 (해당 한계 없음).
/// CGFloat.greatestFiniteMagnitude를 max=0의 의미로 사용 — Cocoa 표준 "제한 없음".
fn setMacContentSizeLimits(window: ?*anyopaque, min_w: u32, min_h: u32, max_w: u32, max_h: u32) void {
    const SetSizeFn = *const fn (?*anyopaque, ?*anyopaque, NSSize) callconv(.c) void;

    if (min_w > 0 or min_h > 0) {
        const sel = objc.sel_registerName("setContentMinSize:");
        const fn_ptr: SetSizeFn = @ptrCast(&objc.objc_msgSend);
        fn_ptr(window, @ptrCast(sel), .{ .width = @floatFromInt(min_w), .height = @floatFromInt(min_h) });
    }
    if (max_w > 0 or max_h > 0) {
        const huge: f64 = std.math.floatMax(f64);
        const sel = objc.sel_registerName("setContentMaxSize:");
        const fn_ptr: SetSizeFn = @ptrCast(&objc.objc_msgSend);
        fn_ptr(window, @ptrCast(sel), .{
            .width = if (max_w > 0) @floatFromInt(max_w) else huge,
            .height = if (max_h > 0) @floatFromInt(max_h) else huge,
        });
    }
}

/// macOS: `#RRGGBB` 또는 `#RRGGBBAA` 16진수 → NSColor.colorWithRed:green:blue:alpha:.
/// 파싱 실패 시 warn 로그 + 기본 배경 유지. CSS short hex(`#RGB`)는 미지원 (Electron과 동일).
fn applyBackgroundColor(window: ?*anyopaque, hex: []const u8) void {
    if (hex.len < 7 or hex[0] != '#' or (hex.len != 7 and hex.len != 9)) {
        log.warn("backgroundColor: invalid format '{s}' (expected #RRGGBB or #RRGGBBAA)", .{hex});
        return;
    }
    const r = std.fmt.parseInt(u8, hex[1..3], 16) catch {
        log.warn("backgroundColor: hex parse failed '{s}'", .{hex});
        return;
    };
    const g = std.fmt.parseInt(u8, hex[3..5], 16) catch return;
    const b = std.fmt.parseInt(u8, hex[5..7], 16) catch return;
    const a: u8 = if (hex.len == 9)
        (std.fmt.parseInt(u8, hex[7..9], 16) catch 255)
    else
        255;

    const NSColor = getClass("NSColor") orelse return;
    const sel = objc.sel_registerName("colorWithRed:green:blue:alpha:");
    const fn_ptr: *const fn (?*anyopaque, ?*anyopaque, f64, f64, f64, f64) callconv(.c) ?*anyopaque = @ptrCast(&objc.objc_msgSend);
    const color = fn_ptr(NSColor, @ptrCast(sel),
        @as(f64, @floatFromInt(r)) / 255.0,
        @as(f64, @floatFromInt(g)) / 255.0,
        @as(f64, @floatFromInt(b)) / 255.0,
        @as(f64, @floatFromInt(a)) / 255.0,
    ) orelse return;
    msgSendVoid1(window, "setBackgroundColor:", color);
}

/// macOS: NSWindow.toggleFullScreen:. order(create) 직후 호출하면 전체화면 진입 애니메이션.
fn toggleMacFullScreen(window: ?*anyopaque) void {
    msgSendVoid1(window, "toggleFullScreen:", null);
}

/// macOS: titleBarStyle. NSWindow.titlebarAppearsTransparent:YES + style mask에
/// NSWindowStyleMaskFullSizeContentView(0x8000) 추가 → titlebar 영역에 content view까지 확장.
/// traffic light(close/min/max)는 그대로 보임. hidden_inset도 같은 매스크 (toolbar 도입 시 분리).
fn applyTitleBarStyle(window: ?*anyopaque, style: window_mod.TitleBarStyle) void {
    if (style == .default) return;
    msgSendVoidBool(window, "setTitlebarAppearsTransparent:", true);

    // 기존 styleMask에 NSWindowStyleMaskFullSizeContentView (= 1 << 15) OR.
    const getMaskSel = objc.sel_registerName("styleMask");
    const getMaskFn: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) u64 = @ptrCast(&objc.objc_msgSend);
    const current_mask = getMaskFn(window, @ptrCast(getMaskSel));

    const setMaskSel = objc.sel_registerName("setStyleMask:");
    const setMaskFn: *const fn (?*anyopaque, ?*anyopaque, u64) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    setMaskFn(window, @ptrCast(setMaskSel), current_mask | (1 << 15));
}

/// macOS: NSWindow에 `close` 메시지 송신. NSBrowserView가 content view에서 떨어져
/// CEF 내부 cleanup이 연쇄 → 결과적으로 OnBeforeClose가 발화.
fn closeMacWindow(ns_window: ?*anyopaque) void {
    const w = ns_window orelse return;
    const closeSel = objc.sel_registerName("close");
    const closeFn: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    closeFn(w, @ptrCast(closeSel));
}

/// macOS: NSWindow.setTitle:(NSString*). title은 임의 slice (non-null-terminated 가능)
/// → 스택 버퍼로 null-terminate 후 NSString 변환.
fn setMacWindowTitle(ns_window: *anyopaque, title: []const u8) void {
    var buf: [512]u8 = undefined;
    if (title.len >= buf.len) return; // 512바이트 넘는 타이틀은 거부 (현실적 한계)
    @memcpy(buf[0..title.len], title);
    buf[title.len] = 0;

    const NSString = getClass("NSString") orelse return;
    const strFn: *const fn (?*anyopaque, ?*anyopaque, [*:0]const u8) callconv(.c) ?*anyopaque = @ptrCast(&objc.objc_msgSend);
    const ns_title = strFn(NSString, @ptrCast(objc.sel_registerName("stringWithUTF8String:")), @ptrCast(&buf)) orelse return;

    msgSendVoid1(ns_window, "setTitle:", ns_title);
}

/// macOS: NSWindow.setFrame:display:. NSRect는 Cocoa 좌표(bottom-left origin)를 쓰지만
/// Suji Bounds는 top-left 기준이라 화면 높이로 변환. 변환 실패(main screen 없음 등)시
/// 그대로 전달.
///
/// ARM64 ABI: NSRect (4x f64)는 float 레지스터(d0-d3)로 전달. extern fn 시그니처에
/// NSRect를 그대로 두면 Zig 컴파일러가 올바른 calling convention을 선택.
fn setMacWindowBounds(ns_window: *anyopaque, bounds: window_mod.Bounds) void {
    const w_f: f64 = @floatFromInt(bounds.width);
    const h_f: f64 = @floatFromInt(bounds.height);
    const x_f: f64 = @floatFromInt(bounds.x);
    const top_y_f: f64 = @floatFromInt(bounds.y);

    // screen.frame.size.height 읽어 Cocoa Y로 변환. 실패 시 그대로 사용.
    const cocoa_y: f64 = blk: {
        const NSScreen = getClass("NSScreen") orelse break :blk top_y_f;
        const mainScreen = msgSend(NSScreen, "mainScreen") orelse break :blk top_y_f;
        // [screen frame] — 반환이 NSRect (struct). objc_msgSend_stret이 필요할 수 있지만
        // ARM64는 단일 msgSend로 struct return 처리. 함수 포인터 타입으로 직접 호출.
        const frameFn: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) NSRect = @ptrCast(&objc.objc_msgSend);
        const screen_frame = frameFn(mainScreen, @ptrCast(objc.sel_registerName("frame")));
        break :blk screen_frame.height - top_y_f - h_f;
    };

    const rect: NSRect = .{ .x = x_f, .y = cocoa_y, .width = w_f, .height = h_f };

    const setFrameSel = objc.sel_registerName("setFrame:display:");
    const setFrameFn: *const fn (?*anyopaque, ?*anyopaque, NSRect, u8) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    setFrameFn(ns_window, @ptrCast(setFrameSel), rect, 1); // display:YES
}
