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
    @cInclude("include/capi/cef_drag_handler_capi.h");
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
const util = @import("util");
const drag_region = @import("cef_drag_region.zig");

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
    pub extern "c" fn class_getMethodImplementation(cls: ?*anyopaque, name: ?*anyopaque) *const fn () callconv(.c) void;
    pub extern "c" fn objc_allocateClassPair(superclass: ?*anyopaque, name: [*:0]const u8, extra_bytes: usize) ?*anyopaque;
    pub extern "c" fn objc_registerClassPair(cls: ?*anyopaque) void;
    /// AppKit 시스템 비프 (NSGraphics.h). Cocoa 프레임워크 링크로 자동 가용.
    pub extern "c" fn NSBeep() void;
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
    /// 앱별 cache 격리 키 (Electron의 app.getPath('userData') 동등). cookie/localStorage/
    /// IndexedDB/Service Worker 모두 이 디렉토리 아래로 격리. config.app.name에서 주입.
    app_name: [:0]const u8 = "Suji App",
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
        .argv = @ptrCast(@constCast(vec.ptr)),
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
/// OS 표준 user-data 디렉토리 + 앱 이름 (Electron `app.getPath('userData')` 동등).
/// macOS: ~/Library/Application Support/&lt;app&gt;/Cache
/// Linux: ~/.config/&lt;app&gt;/Cache
/// Windows: %APPDATA%/&lt;app&gt;/Cache (없으면 %USERPROFILE%/AppData/Roaming/&lt;app&gt;/Cache)
fn buildAppCachePath(buf: []u8, home: []const u8, app_name: []const u8) ?[]const u8 {
    const result = switch (builtin.os.tag) {
        .macos => std.fmt.bufPrint(buf, "{s}/Library/Application Support/{s}/Cache", .{ home, app_name }),
        .linux => blk: {
            // XDG Base Directory Specification — $XDG_CONFIG_HOME 우선, fallback ~/.config
            const xdg = runtime.env("XDG_CONFIG_HOME");
            if (xdg) |x| if (x.len > 0) break :blk std.fmt.bufPrint(buf, "{s}/{s}/Cache", .{ x, app_name });
            break :blk std.fmt.bufPrint(buf, "{s}/.config/{s}/Cache", .{ home, app_name });
        },
        .windows => blk: {
            // %APPDATA% (보통 ~/AppData/Roaming) 우선, fallback %USERPROFILE%/AppData/Roaming
            const appdata = runtime.env("APPDATA");
            if (appdata) |a| break :blk std.fmt.bufPrint(buf, "{s}\\{s}\\Cache", .{ a, app_name });
            break :blk std.fmt.bufPrint(buf, "{s}\\AppData\\Roaming\\{s}\\Cache", .{ home, app_name });
        },
        else => std.fmt.bufPrint(buf, "{s}/.suji/cef/{s}/Cache", .{ home, app_name }),
    } catch return null;
    return result;
}

test "buildAppCachePath: 현재 OS 표준 경로 + app_name 포함" {
    var buf: [512]u8 = undefined;
    const path = buildAppCachePath(&buf, "/Users/test", "MyApp").?;
    // 모든 OS에서 home prefix + app_name + Cache는 공통.
    try std.testing.expect(std.mem.indexOf(u8, path, "MyApp") != null);
    try std.testing.expect(std.mem.endsWith(u8, path, "Cache"));
    // OS별 분기 — 빌드 시점 OS만 검증.
    switch (builtin.os.tag) {
        .macos => {
            try std.testing.expect(std.mem.startsWith(u8, path, "/Users/test/Library/Application Support/MyApp"));
        },
        .linux => {
            // XDG 미설정 시 ~/.config; 설정 시 그 경로. test env에 XDG가 없을 가능성 높음.
            try std.testing.expect(std.mem.indexOf(u8, path, "/MyApp/Cache") != null);
        },
        .windows => {
            try std.testing.expect(std.mem.indexOf(u8, path, "MyApp\\Cache") != null);
        },
        else => {},
    }
}

test "buildAppCachePath: 너무 긴 path는 null" {
    var small_buf: [16]u8 = undefined;
    try std.testing.expect(buildAppCachePath(&small_buf, "/Users/test", "VeryLongAppName") == null);
}

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
    // OS 표준 앱별 user-data 디렉토리. Electron app.getPath('userData') 동등:
    //   macOS:   ~/Library/Application Support/<app_name>
    //   Linux:   $XDG_CONFIG_HOME or ~/.config/<app_name>
    //   Windows: %APPDATA%/<app_name>  (HOME 대용으로 USERPROFILE 사용 X — runtime.env가 emit)
    // 한 system에 여러 Suji 앱 설치 시 cookie/localStorage/IndexedDB 자동 격리.
    const cache_path = buildAppCachePath(&cache_buf, home, config.app_name) orelse return error.PathTooLong;
    setCefString(&settings.root_cache_path, cache_path);

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

/// CEF process_message 페이로드 버퍼 한도 (renderer ↔ browser IPC). Clipboard write_text 같은
/// 큰 payload(최대 16KB text + JSON escape overhead)를 수용. 이전엔 8192라 8KB 텍스트도
/// 잘려 응답 undefined.
const CEF_IPC_BUF_LEN: usize = 65536;

/// 전역 CEF 핸들러 초기화 (idempotent). CefNative.init에서 호출.
/// life_span_handler / keyboard_handler / devtools client — 모든 브라우저가 공유.
var g_handlers_initialized: bool = false;
fn ensureGlobalHandlers() void {
    if (g_handlers_initialized) return;
    initLifeSpanHandler();
    initKeyboardHandler();
    initDragHandler();
    zeroCefStruct(c.cef_client_t, &g_devtools_client);
    initBaseRefCounted(&g_devtools_client.base);
    g_devtools_client.get_keyboard_handler = &getKeyboardHandler;
    g_devtools_client.get_drag_handler = &getDragHandler;
    // life_span_handler — DevTools browser의 onAfterCreated/onBeforeClose 콜백.
    // 없으면 DevTools browser 생성/소멸이 우리에게 안 보여 inspectee 매핑 등록/정리 X.
    g_devtools_client.get_life_span_handler = &getLifeSpanHandler;
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
        /// `ns_window`와 `host_ns_view`는 **상호배타** — 일반 창은 ns_window만, Phase 17-A
        /// WebContentsView는 host_ns_view만 set. WindowManager가 같은 invariant를
        /// `Window.kind`로 표현 (`.window`/`.view`).
        ns_window: ?*anyopaque,
        /// Phase 17-A: host용 view 합성 wrapper NSView. createView 첫 호출 시 lazy init.
        /// contentView 안에 영구 부착되어 우리 view들의 부모 — main browser CEF view와
        /// 격리해 destroy/reorder 시 main browser 영향 X. host BrowserEntry만 set.
        view_wrapper: ?*anyopaque = null,
        /// Phase 17-A: WebContentsView. wrapper NSView 안에 부착된 child NSView 포인터.
        /// 일반 창은 항상 null, view만 set. setViewBounds/setViewVisible/reorderView가
        /// 이 NSView를 조작.
        host_ns_view: ?*anyopaque = null,
        /// 캐시된 main frame URL (OnAddressChange 콜백에서만 갱신).
        /// 매 invoke마다 frame.get_url alloc/free를 피하기 위함. len=0이면 미캐싱(폴백).
        url_cache_buf: [URL_CACHE_LEN]u8 = undefined,
        url_cache_len: usize = 0,
        /// CEF가 계산한 `-webkit-app-region` rectangle들. browser id별로 보관하고
        /// macOS NSWindow.sendEvent:에서 native drag hit-test에 사용.
        drag_regions: []drag_region.DragRegion = &.{},
        /// `window:ready-to-show`는 main frame 첫 로드 완료시 1회만 발화 (Electron 호환).
        /// 이후 reload/navigate에서는 발화 X — caller는 `did-finish-load` 패턴이 필요하면
        /// load_url 응답을 직접 사용.
        ready_to_show_fired: bool = false,
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
        var it = self.browsers.valueIterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.drag_regions);
        }
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
    /// NSView 정리는 destroyView가 이미 처리(removeFromSuperview + release) — purge는
    /// BrowserEntry 메모리만 회수.
    pub fn purge(self: *CefNative, handle: u64) void {
        if (self.browsers.fetchRemove(handle)) |kv| {
            self.allocator.free(kv.value.drag_regions);
        }
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
        .open_dev_tools = openDevToolsImpl,
        .close_dev_tools = closeDevToolsImpl,
        .is_dev_tools_opened = isDevToolsOpenedImpl,
        .toggle_dev_tools = toggleDevToolsImpl,
        .set_zoom_level = setZoomLevelImpl,
        .get_zoom_level = getZoomLevelImpl,
        .undo = makeFrameEditFn("undo"),
        .redo = makeFrameEditFn("redo"),
        .cut = makeFrameEditFn("cut"),
        .copy = makeFrameEditFn("copy"),
        .paste = makeFrameEditFn("paste"),
        .select_all = makeFrameEditFn("select_all"),
        .find_in_page = findInPageImpl,
        .stop_find_in_page = stopFindInPageImpl,
        .print_to_pdf = printToPDFImpl,
        // Phase 17-A: WebContentsView. 실제 구현은 17-A.3 (NSView + cef_window_info_t.parent_view).
        // 일단 컴파일 통과용 placeholder — 호출되면 not-implemented 또는 no-op.
        .create_view = createView,
        .destroy_view = destroyView,
        .set_view_bounds = setViewBounds,
        .set_view_visible = setViewVisible,
        .reorder_view = reorderView,
        .minimize = minimizeImpl,
        .restore_window = restoreWindowImpl,
        .maximize = maximizeImpl,
        .unmaximize = unmaximizeImpl,
        .set_fullscreen = setFullscreenImpl,
        .is_minimized = isMinimizedImpl,
        .is_maximized = isMaximizedImpl,
        .is_fullscreen = isFullscreenImpl,
    };

    fn fromCtx(ctx: ?*anyopaque) *CefNative {
        return @ptrCast(@alignCast(ctx.?));
    }

    // ==================== Phase 17-A: WebContentsView ====================
    // host 창의 contentView 안에 child NSView를 부착하고 그 NSView를 cef_window_info_t.
    // parent_view로 넘겨 별도 CefBrowser를 임베드. id 풀(handle = browser identifier)과 같은
    // client를 공유하므로 모든 webContents API(load_url/executeJavascript/...) 가 view에도
    // 자동 동작. 17-A.3은 macOS만 — Linux/Windows는 17-B.

    fn createView(ctx: ?*anyopaque, host_handle: u64, opts: *const window_mod.CreateViewOptions) anyerror!u64 {
        const self = fromCtx(ctx);
        assertUiThread();
        if (!is_macos) {
            log.warn("create_view: Linux/Windows는 Phase 17-B에서 지원 예정", .{});
            return error.NotSupportedOnPlatform;
        }

        const host_entry = self.browsers.getPtr(host_handle) orelse return error.HostNotFound;
        const host_ns_window = host_entry.ns_window orelse return error.HostHasNoNSWindow;

        // url 처리 (createWindow와 동일 패턴 — null이면 default_url).
        var url_buf: [2048]u8 = undefined;
        const url_z: [:0]const u8 = if (opts.url) |u| blk: {
            if (u.len >= url_buf.len) return error.UrlTooLong;
            @memcpy(url_buf[0..u.len], u);
            url_buf[u.len] = 0;
            break :blk url_buf[0..u.len :0];
        } else self.default_url;

        // host용 view wrapper 보장 — main browser CEF view와 격리할 영구 NSView.
        const wrapper = ensureViewWrapper(host_entry, host_ns_window) orelse return error.WrapperAllocFailed;
        // child NSView를 wrapper 안에 부착 (contentView 직접 X).
        const new_view = allocChildNSView(wrapper, opts.bounds) orelse return error.NSViewAllocFailed;
        // 에러 경로 cleanup: removeFromSuperview(super retain 풀림) + release(alloc retain 풀림 → dealloc).
        errdefer {
            _ = msgSend(new_view, "removeFromSuperview");
            _ = msgSend(new_view, "release");
        }

        // CEF browser를 child NSView 안에 합성. parent_view는 NSView*. bounds는 super 좌표계로
        // (0, 0) + width/height — child NSView 자체가 이미 위치 고정되어 있어 CEF 내부 view는
        // 그 안에서 (0,0)부터 채움.
        var window_info: c.cef_window_info_t = undefined;
        zeroCefStruct(c.cef_window_info_t, &window_info);
        window_info.runtime_style = c.CEF_RUNTIME_STYLE_ALLOY;
        window_info.parent_view = new_view;
        window_info.bounds = .{
            .x = 0,
            .y = 0,
            .width = @intCast(opts.bounds.width),
            .height = @intCast(opts.bounds.height),
        };

        var cef_url: c.cef_string_t = .{};
        if (url_z.len > 0) setCefString(&cef_url, url_z);

        var browser_settings: c.cef_browser_settings_t = undefined;
        zeroCefStruct(c.cef_browser_settings_t, &browser_settings);

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
        const handle: u64 = @intCast(br.get_identifier.?(br));

        self.browsers.put(handle, .{
            .browser = br,
            .ns_window = null,
            .host_ns_view = new_view,
        }) catch {
            // browsers.put 실패 시 CEF browser는 살아있음 → close_browser로 정리
            // (errdefer가 NSView removeFromSuperview는 따로 처리).
            const host_obj = asPtr(c.cef_browser_host_t, br.get_host.?(br));
            if (host_obj) |h| h.close_browser.?(h, 1);
            return error.OutOfMemory;
        };
        return handle;
    }

    fn destroyView(ctx: ?*anyopaque, view_handle: u64) void {
        const self = fromCtx(ctx);
        assertUiThread();
        const entry = self.browsers.get(view_handle) orelse return;
        // 17-A 한계 우회: close_browser, NSView dealloc cascade, NSView ops defer 모두 view
        // CefBrowser의 render subprocess race를 못 잡음 (CEF + macOS multi-WebContentsView 합성
        // 알려진 instability). **메모리 leak 허용하고 시각만 분리** — view CefBrowser는 host
        // close까지 alive 유지. host close 시 NSWindow dealloc cascade가 wrapper → 모든 view를
        // 한꺼번에 정리 (process 종료 직전이라 강종 인지 X). WindowManager는 view를 destroyed
        // 마킹해 같은 viewId 재사용 X.
        if (entry.host_ns_view) |view| {
            msgSendVoidBool(view, "setHidden:", true);
        }
    }

    fn setViewBounds(ctx: ?*anyopaque, view_handle: u64, bounds: window_mod.Bounds) void {
        const self = fromCtx(ctx);
        assertUiThread();
        if (!is_macos) return;
        const entry = self.browsers.get(view_handle) orelse return;
        const view = entry.host_ns_view orelse return;
        const super = msgSend(view, "superview") orelse return;
        // 매 호출마다 super 현재 bounds로 Cocoa Y 재계산 — host 창 resize 후에도 정확히 매핑.
        const rect = computeChildViewRect(super, bounds);
        _ = msgSendNSRect(view, "setFrame:", rect);
    }

    fn setViewVisible(ctx: ?*anyopaque, view_handle: u64, visible: bool) void {
        const self = fromCtx(ctx);
        assertUiThread();
        if (!is_macos) return;
        const entry = self.browsers.get(view_handle) orelse return;
        const view = entry.host_ns_view orelse return;
        // NSView setHidden: + CEF browser host.was_hidden — Cocoa는 시각, CEF는 렌더링/입력 일시정지.
        msgSendVoidBool(view, "setHidden:", !visible);
        const br = entry.browser;
        const host = asPtr(c.cef_browser_host_t, br.get_host.?(br));
        if (host) |h| h.was_hidden.?(h, if (visible) 0 else 1);
    }

    /// view를 host contentView에서 top(끝)으로 옮김. addSubview는 view가 이미 super의
    /// subview면 자동 removeFromSuperview 후 끝에 다시 부착 — 시각적/메모리 상 안전.
    ///
    /// **`index_in_host` 무시**: contentView.subviews에는 우리 view들 + main browser CEF view가
    /// 함께 있어 우리 list index와 contentView.subviews index가 다른 namespace. 이전엔
    /// `addSubview:positioned:relativeTo: subviews[index-1]`로 잘못된 reference(main browser view)
    /// 에 부착해 NSView tree corruption + 후속 destroy crash. WindowManager가 list 순서대로
    /// 모든 view를 sequential 호출하면 마지막 호출된 view가 top — 우리 list 순서와 일치 +
    /// main browser view는 항상 우리 view들 below 유지.
    fn reorderView(ctx: ?*anyopaque, host_handle: u64, view_handle: u64, index_in_host: u32) void {
        const self = fromCtx(ctx);
        assertUiThread();
        if (!is_macos) return;
        _ = host_handle;
        _ = index_in_host;
        const entry = self.browsers.get(view_handle) orelse return;
        const view = entry.host_ns_view orelse return;
        const super = msgSend(view, "superview") orelse return;
        msgSendVoid1(super, "addSubview:", view);
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

        // window:resized/focus/blur/moved 이벤트 라우팅용 NSWindowDelegate 부착.
        // browsers.put 이후 attach해서 매핑 일관성 유지.
        attachWindowLifecycle(ns_window, handle);

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
        // delegate 매핑 제거 (NSWindow dealloc 후엔 lookup이 무의미).
        detachWindowLifecycle(entry.ns_window);
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
        // 4KB 미만은 stack, 그 이상은 heap. 16KB 고정 스택은 큰 코드 silent drop +
        // 매 호출마다 16KB stack 점유 → 폴백으로 변경.
        var stack_buf: [JS_STACK_BUF_SIZE]u8 = undefined;
        if (code.len < stack_buf.len) {
            @memcpy(stack_buf[0..code.len], code);
            stack_buf[code.len] = 0;
            evalJsOnBrowser(entry.browser, stack_buf[0..code.len :0]);
            return;
        }
        const heap = self.allocator.allocSentinel(u8, code.len, 0) catch {
            log.warn("execute_javascript: alloc {d} bytes failed — code dropped", .{code.len});
            return;
        };
        defer self.allocator.free(heap);
        @memcpy(heap, code);
        evalJsOnBrowser(entry.browser, heap);
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

    // ==================== Phase 4-C: DevTools ====================

    fn openDevToolsImpl(ctx: ?*anyopaque, handle: u64) void {
        assertUiThread();
        const self = fromCtx(ctx);
        const entry = self.browsers.get(handle) orelse return;
        openDevTools(entry.browser);
    }

    fn closeDevToolsImpl(ctx: ?*anyopaque, handle: u64) void {
        assertUiThread();
        const self = fromCtx(ctx);
        const entry = self.browsers.get(handle) orelse return;
        closeDevTools(entry.browser);
    }

    fn isDevToolsOpenedImpl(ctx: ?*anyopaque, handle: u64) bool {
        const self = fromCtx(ctx);
        const entry = self.browsers.get(handle) orelse return false;
        return hasDevTools(entry.browser);
    }

    fn toggleDevToolsImpl(ctx: ?*anyopaque, handle: u64) void {
        assertUiThread();
        const self = fromCtx(ctx);
        const entry = self.browsers.get(handle) orelse return;
        toggleDevTools(entry.browser);
    }

    // ==================== Phase 4-B: 줌 ====================

    fn setZoomLevelImpl(ctx: ?*anyopaque, handle: u64, level: f64) void {
        assertUiThread();
        const self = fromCtx(ctx);
        const entry = self.browsers.get(handle) orelse return;
        const host = asPtr(c.cef_browser_host_t, entry.browser.get_host.?(entry.browser)) orelse return;
        host.set_zoom_level.?(host, level);
    }

    fn getZoomLevelImpl(ctx: ?*anyopaque, handle: u64) f64 {
        const self = fromCtx(ctx);
        const entry = self.browsers.get(handle) orelse return 0;
        const host = asPtr(c.cef_browser_host_t, entry.browser.get_host.?(entry.browser)) orelse return 0;
        return host.get_zoom_level.?(host);
    }

    // ==================== Phase 4-E: 편집 (frame 위임) + 검색 ====================

    /// 6 trivial 편집 메서드 — 모두 main_frame.X() 호출. comptime으로 6 fn 생성.
    /// `field`가 cef_frame_t에 없으면 컴파일 에러 (CEF API 변경 회귀 차단).
    fn makeFrameEditFn(comptime field: []const u8) *const fn (?*anyopaque, u64) void {
        comptime {
            if (!@hasField(c.cef_frame_t, field)) {
                @compileError("cef_frame_t에 '" ++ field ++ "' 필드 없음");
            }
        }
        return struct {
            fn call(ctx: ?*anyopaque, handle: u64) void {
                assertUiThread();
                const self = fromCtx(ctx);
                const entry = self.browsers.get(handle) orelse return;
                const frame = asPtr(c.cef_frame_t, entry.browser.get_main_frame.?(entry.browser)) orelse return;
                const fn_ptr = @field(frame, field) orelse return;
                fn_ptr(frame);
            }
        }.call;
    }

    fn findInPageImpl(ctx: ?*anyopaque, handle: u64, text: []const u8, forward: bool, match_case: bool, find_next: bool) void {
        assertUiThread();
        const self = fromCtx(ctx);
        const entry = self.browsers.get(handle) orelse return;
        const host = asPtr(c.cef_browser_host_t, entry.browser.get_host.?(entry.browser)) orelse return;

        var text_buf: [FIND_TEXT_STACK_BUF]u8 = undefined;
        const text_z = nullTerminateOrTruncate(text, &text_buf) orelse {
            log.warn("find_in_page: text {d} bytes > {d} stack buf — dropped", .{ text.len, FIND_TEXT_STACK_BUF });
            return;
        };
        var cef_text: c.cef_string_t = .{};
        setCefString(&cef_text, text_z);
        const find = host.find orelse return;
        find(host, &cef_text, @intFromBool(forward), @intFromBool(match_case), @intFromBool(find_next));
    }

    fn stopFindInPageImpl(ctx: ?*anyopaque, handle: u64, clear_selection: bool) void {
        assertUiThread();
        const self = fromCtx(ctx);
        const entry = self.browsers.get(handle) orelse return;
        const host = asPtr(c.cef_browser_host_t, entry.browser.get_host.?(entry.browser)) orelse return;
        const stop = host.stop_finding orelse return;
        stop(host, @intFromBool(clear_selection));
    }

    // ==================== Phase 4-D: 인쇄 (printToPDF) ====================

    fn printToPDFImpl(ctx: ?*anyopaque, handle: u64, path: []const u8) void {
        assertUiThread();
        const self = fromCtx(ctx);
        const entry = self.browsers.get(handle) orelse return;
        const host = asPtr(c.cef_browser_host_t, entry.browser.get_host.?(entry.browser)) orelse return;

        var path_buf: [PDF_PATH_STACK_BUF]u8 = undefined;
        const path_z = nullTerminateOrTruncate(path, &path_buf) orelse {
            log.warn("print_to_pdf: path {d} bytes > {d} stack buf — dropped", .{ path.len, PDF_PATH_STACK_BUF });
            return;
        };

        var cef_path: c.cef_string_t = .{};
        setCefString(&cef_path, path_z);

        var settings: c.cef_pdf_print_settings_t = undefined;
        zeroCefStruct(c.cef_pdf_print_settings_t, &settings);

        ensurePdfCallback();
        const print = host.print_to_pdf orelse return;
        print(host, &cef_path, &settings, &g_pdf_callback);
    }

    fn nsWindowFor(self: *CefNative, handle: u64) ?*anyopaque {
        const entry = self.browsers.get(handle) orelse return null;
        return entry.ns_window;
    }

    /// 비-macOS / unknown handle / null ns_window 시 no-op로 흡수.
    /// 모든 NSWindow 조작은 UI thread에서만 안전 — getter도 동일.
    fn callOnNs(ctx: ?*anyopaque, handle: u64, comptime native_fn: anytype) void {
        if (!comptime is_macos) return;
        assertUiThread();
        const ns = fromCtx(ctx).nsWindowFor(handle) orelse return;
        native_fn(ns);
    }

    fn callOnNsBool(ctx: ?*anyopaque, handle: u64, comptime native_fn: anytype) bool {
        if (!comptime is_macos) return false;
        assertUiThread();
        const ns = fromCtx(ctx).nsWindowFor(handle) orelse return false;
        return native_fn(ns) != 0;
    }

    fn minimizeImpl(ctx: ?*anyopaque, handle: u64) void {
        callOnNs(ctx, handle, suji_window_lifecycle_minimize);
    }
    fn restoreWindowImpl(ctx: ?*anyopaque, handle: u64) void {
        callOnNs(ctx, handle, suji_window_lifecycle_deminiaturize);
    }
    fn maximizeImpl(ctx: ?*anyopaque, handle: u64) void {
        callOnNs(ctx, handle, suji_window_lifecycle_maximize);
    }
    fn unmaximizeImpl(ctx: ?*anyopaque, handle: u64) void {
        callOnNs(ctx, handle, suji_window_lifecycle_unmaximize);
    }
    fn setFullscreenImpl(ctx: ?*anyopaque, handle: u64, flag: bool) void {
        if (!comptime is_macos) return;
        assertUiThread();
        const ns = fromCtx(ctx).nsWindowFor(handle) orelse return;
        suji_window_lifecycle_set_fullscreen(ns, @intFromBool(flag));
    }
    fn isMinimizedImpl(ctx: ?*anyopaque, handle: u64) bool {
        return callOnNsBool(ctx, handle, suji_window_lifecycle_is_minimized);
    }
    fn isMaximizedImpl(ctx: ?*anyopaque, handle: u64) bool {
        return callOnNsBool(ctx, handle, suji_window_lifecycle_is_maximized);
    }
    fn isFullscreenImpl(ctx: ?*anyopaque, handle: u64) bool {
        return callOnNsBool(ctx, handle, suji_window_lifecycle_is_fullscreen);
    }
};

/// 글로벌 cef_pdf_print_callback_t — 매 print 마다 alloc하면 ref-counted 수명 추적
/// 부담. 콜백 자체는 stateless (path/success를 인자로 받음) → 글로벌 단일로 안전.
/// 동시 print 여러 개 호출 시 EventBus emit이 각자 독립으로 발화 (path가 인자에 포함).
var g_pdf_callback: c.cef_pdf_print_callback_t = undefined;
var g_pdf_callback_initialized: bool = false;
fn ensurePdfCallback() void {
    if (g_pdf_callback_initialized) return;
    zeroCefStruct(c.cef_pdf_print_callback_t, &g_pdf_callback);
    initBaseRefCounted(&g_pdf_callback.base);
    g_pdf_callback.on_pdf_print_finished = &onPdfPrintFinished;
    g_pdf_callback_initialized = true;
}

/// CEF print_to_pdf 완료 콜백 — `window:pdf-print-finished` 이벤트로 emit.
/// payload: `{"path": "<utf8>", "success": true|false}`. main이 inject한
/// g_emit_callback 활용 (cef.zig는 backends/loader에 dep 하지 않도록).
fn onPdfPrintFinished(_: [*c]c.cef_pdf_print_callback_t, path: [*c]const c.cef_string_t, ok: c_int) callconv(.c) void {
    const emit = g_emit_callback orelse return;

    var path_buf: [PDF_PATH_STACK_BUF]u8 = undefined;
    const path_str: []const u8 = if (path) |p| cefStringToUtf8(p, &path_buf) else "";

    var escaped_buf: [PDF_PATH_STACK_BUF]u8 = undefined;
    const escaped_n = window_mod.escapeJsonChars(path_str, &escaped_buf);

    var payload_buf: [PDF_PATH_STACK_BUF + 64]u8 = undefined;
    var w = std.Io.Writer.fixed(&payload_buf);
    w.print("{{\"path\":\"{s}\",\"success\":{}}}", .{ escaped_buf[0..escaped_n], ok != 0 }) catch return;

    emit(null, EVENT_PDF_PRINT_FINISHED, w.buffered());
}

const URL_BUF_SIZE: usize = 2048;
/// PDF 인쇄 path stack 버퍼 — URL과 동일 크기 (둘 다 일반 file path / URL).
const PDF_PATH_STACK_BUF: usize = URL_BUF_SIZE;
/// executeJavascript의 fast-path stack 버퍼. 4KB 미만 코드는 alloc 없이.
const JS_STACK_BUF_SIZE: usize = 4096;
/// find_in_page text stack 버퍼. 검색어 1KB 초과면 log.warn + drop.
const FIND_TEXT_STACK_BUF: usize = 1024;

/// PDF 인쇄 완료 이벤트 — caller(SDK)가 listener로 path 매칭. 이름 변경 시 5 SDK
/// + 문서 모두 동시 변경 필요 (SDK_PORTING.md §4.3 cmd 표 참조).
pub const EVENT_PDF_PRINT_FINISHED: []const u8 = "window:pdf-print-finished";

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

// ============================================
// Clipboard API — NSPasteboard generalPasteboard
// ============================================
// public.utf8-plain-text UTI를 사용해 plain text만 read/write (Electron `clipboard.readText/writeText`).
// 비-macOS는 모두 no-op (readText는 빈 문자열, write/clear는 false 반환).

const PASTEBOARD_TYPE_STRING: [*:0]const u8 = "public.utf8-plain-text";

/// 클립보드 텍스트 최대 길이 (null terminator 포함). main.zig IPC handler가 동일 cap을
/// 사용하므로 여기 한도를 넘는 입력은 caller 단에서 이미 잘려 있음.
const CLIPBOARD_MAX_TEXT: usize = 16384;

/// 시스템 클립보드에서 plain text 읽기 — buf에 복사 후 slice 반환. 비어 있거나
/// non-text content면 빈 슬라이스. buf보다 긴 텍스트는 잘림.
pub fn clipboardReadText(buf: []u8) []const u8 {
    if (!comptime is_macos) return buf[0..0];
    const NSPasteboard = getClass("NSPasteboard") orelse return buf[0..0];
    const pb = msgSend(NSPasteboard, "generalPasteboard") orelse return buf[0..0];
    const NSString = getClass("NSString") orelse return buf[0..0];
    const strFn: *const fn (?*anyopaque, ?*anyopaque, [*:0]const u8) callconv(.c) ?*anyopaque =
        @ptrCast(&objc.objc_msgSend);
    const ns_type = strFn(NSString, @ptrCast(objc.sel_registerName("stringWithUTF8String:")), PASTEBOARD_TYPE_STRING) orelse return buf[0..0];
    const stringForType: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque =
        @ptrCast(&objc.objc_msgSend);
    const ns_str = stringForType(pb, @ptrCast(objc.sel_registerName("stringForType:")), ns_type) orelse return buf[0..0];
    const utf8Fn: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) ?[*:0]const u8 =
        @ptrCast(&objc.objc_msgSend);
    const cstr = utf8Fn(ns_str, @ptrCast(objc.sel_registerName("UTF8String"))) orelse return buf[0..0];
    const len = std.mem.span(cstr).len;
    const copy_len = @min(len, buf.len);
    @memcpy(buf[0..copy_len], cstr[0..copy_len]);
    return buf[0..copy_len];
}

/// 시스템 클립보드에 plain text 쓰기. clear 후 setString:forType: 호출. 성공 시 true.
pub fn clipboardWriteText(text: []const u8) bool {
    if (!comptime is_macos) return false;
    const NSPasteboard = getClass("NSPasteboard") orelse return false;
    const pb = msgSend(NSPasteboard, "generalPasteboard") orelse return false;
    _ = msgSend(pb, "clearContents");

    // stringWithUTF8String은 null-terminated 요구 — 스택 버퍼로 복사.
    var stack_buf: [CLIPBOARD_MAX_TEXT]u8 = undefined;
    if (text.len + 1 > stack_buf.len) return false;
    @memcpy(stack_buf[0..text.len], text);
    stack_buf[text.len] = 0;
    const cstr: [*:0]const u8 = @ptrCast(&stack_buf);

    const NSString = getClass("NSString") orelse return false;
    const strFn: *const fn (?*anyopaque, ?*anyopaque, [*:0]const u8) callconv(.c) ?*anyopaque =
        @ptrCast(&objc.objc_msgSend);
    const ns_text = strFn(NSString, @ptrCast(objc.sel_registerName("stringWithUTF8String:")), cstr) orelse return false;
    const ns_type = strFn(NSString, @ptrCast(objc.sel_registerName("stringWithUTF8String:")), PASTEBOARD_TYPE_STRING) orelse return false;
    const setFn: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) u8 =
        @ptrCast(&objc.objc_msgSend);
    return setFn(pb, @ptrCast(objc.sel_registerName("setString:forType:")), ns_text, ns_type) != 0;
}

/// 시스템 클립보드 비우기 (clearContents).
pub fn clipboardClear() void {
    if (!comptime is_macos) return;
    const NSPasteboard = getClass("NSPasteboard") orelse return;
    const pb = msgSend(NSPasteboard, "generalPasteboard") orelse return;
    _ = msgSend(pb, "clearContents");
}

// ============================================
// Shell API — NSWorkspace + NSBeep (Electron `shell.*`)
// ============================================
// 비-macOS는 모두 false / no-op (시스템 핸들러 미연결).

/// URL 또는 path 길이 한도 (null terminator 포함). 4KB는 macOS NSString이 무난하게 처리 가능.
const SHELL_MAX_PATH: usize = 4096;

/// `[ns_obj utf8String]`을 caller 스택 버퍼에 복사 — 공통 패턴(NSString-from-Zig-slice).
/// 성공 시 NSString*, 실패 시 null. text 길이가 한도 초과면 null.
fn nsStringFromSlice(text: []const u8) ?*anyopaque {
    if (text.len + 1 > SHELL_MAX_PATH) return null;
    var stack_buf: [SHELL_MAX_PATH]u8 = undefined;
    @memcpy(stack_buf[0..text.len], text);
    stack_buf[text.len] = 0;
    const cstr: [*:0]const u8 = @ptrCast(&stack_buf);
    const NSString = getClass("NSString") orelse return null;
    const strFn: *const fn (?*anyopaque, ?*anyopaque, [*:0]const u8) callconv(.c) ?*anyopaque =
        @ptrCast(&objc.objc_msgSend);
    return strFn(NSString, @ptrCast(objc.sel_registerName("stringWithUTF8String:")), cstr);
}

var g_empty_ns_string: ?*anyopaque = null;

/// 모든 NSMenuItem keyEquivalent에서 공유하는 `@""`. 메뉴 아이템마다 빈 NSString을 새로 만드는
/// 비용 회피.
fn emptyNSString() ?*anyopaque {
    if (g_empty_ns_string) |s| return s;
    const s = nsStringFromSlice("") orelse return null;
    g_empty_ns_string = s;
    return s;
}

/// NSMenuItem.tag 읽기 — checkbox 식별 용도.
fn menuItemTag(item: *anyopaque) i64 {
    const f: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) i64 = @ptrCast(&objc.objc_msgSend);
    return f(item, @ptrCast(objc.sel_registerName("tag")));
}

/// NSMenuItem.state 토글 (0 ↔ 1). checkbox 클릭 시 호출.
fn toggleMenuItemState(item: *anyopaque) void {
    const stateFn: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) i64 = @ptrCast(&objc.objc_msgSend);
    const setStateFn: *const fn (?*anyopaque, ?*anyopaque, i64) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    const current = stateFn(item, @ptrCast(objc.sel_registerName("state")));
    setStateFn(item, @ptrCast(objc.sel_registerName("setState:")), if (current == 0) 1 else 0);
}

/// NSMenuItem.representedObject (NSString*)에서 UTF-8 slice 추출. menu/tray click target에서
/// click name 디스패치용.
fn representedObjectUtf8(item: *anyopaque) ?[]const u8 {
    const repObjFn: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque = @ptrCast(&objc.objc_msgSend);
    const ns_str = repObjFn(item, @ptrCast(objc.sel_registerName("representedObject"))) orelse return null;
    const utf8Fn: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) ?[*:0]const u8 = @ptrCast(&objc.objc_msgSend);
    const cstr = utf8Fn(ns_str, @ptrCast(objc.sel_registerName("UTF8String"))) orelse return null;
    return std.mem.span(cstr);
}

/// 시스템 기본 핸들러로 URL 열기 (Electron `shell.openExternal`). http(s) → 기본 브라우저,
/// mailto: → 메일 앱 등. URL syntax invalid 또는 scheme 누락이면 false (LaunchServices에
/// 보내면 -50 OS dialog 발생하므로 사전 차단).
pub fn shellOpenExternal(url: []const u8) bool {
    if (!comptime is_macos) return false;
    const ns_url_str = nsStringFromSlice(url) orelse return false;
    const NSURL = getClass("NSURL") orelse return false;
    const urlFn: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque =
        @ptrCast(&objc.objc_msgSend);
    const ns_url = urlFn(NSURL, @ptrCast(objc.sel_registerName("URLWithString:")), ns_url_str) orelse return false;

    // scheme 검사 — URLWithString은 relative URL("noschemejustwords")도 통과시키지만
    // openURL:에 넘기면 macOS가 "해당 프로그램을 열 수 없습니다 (-50)" 시스템 알림.
    const scheme = msgSend(ns_url, "scheme") orelse return false;
    const utf8Fn: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) ?[*:0]const u8 =
        @ptrCast(&objc.objc_msgSend);
    const scheme_cstr = utf8Fn(scheme, @ptrCast(objc.sel_registerName("UTF8String"))) orelse return false;
    if (std.mem.span(scheme_cstr).len == 0) return false;

    const NSWorkspace = getClass("NSWorkspace") orelse return false;
    const ws = msgSend(NSWorkspace, "sharedWorkspace") orelse return false;
    const openFn: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) u8 =
        @ptrCast(&objc.objc_msgSend);
    return openFn(ws, @ptrCast(objc.sel_registerName("openURL:")), ns_url) != 0;
}

/// Finder에서 항목 reveal — 부모 폴더가 열리고 해당 파일/폴더 선택 (Electron `shell.showItemInFolder`).
/// 존재하지 않는 경로는 NSFileManager.fileExistsAtPath: 사전 검증으로 차단 (없는 경로를
/// activateFileViewerSelectingURLs:에 넘기면 macOS -50 dialog). 존재하면 file:// URL로
/// modern API `activateFileViewerSelectingURLs:` 호출 (deprecated `selectFile:inFileViewerRootedAtPath:`
/// 대체).
pub fn shellShowItemInFolder(path: []const u8) bool {
    if (!comptime is_macos) return false;
    const ns_path = nsStringFromSlice(path) orelse return false;

    const NSFileManager = getClass("NSFileManager") orelse return false;
    const fm = msgSend(NSFileManager, "defaultManager") orelse return false;
    const existsFn: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) u8 =
        @ptrCast(&objc.objc_msgSend);
    if (existsFn(fm, @ptrCast(objc.sel_registerName("fileExistsAtPath:")), ns_path) == 0) return false;

    const NSURL = getClass("NSURL") orelse return false;
    const fileUrlFn: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque =
        @ptrCast(&objc.objc_msgSend);
    const ns_url = fileUrlFn(NSURL, @ptrCast(objc.sel_registerName("fileURLWithPath:")), ns_path) orelse return false;

    const NSArray = getClass("NSArray") orelse return false;
    const arrayFn: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque =
        @ptrCast(&objc.objc_msgSend);
    const ns_arr = arrayFn(NSArray, @ptrCast(objc.sel_registerName("arrayWithObject:")), ns_url) orelse return false;

    const NSWorkspace = getClass("NSWorkspace") orelse return false;
    const ws = msgSend(NSWorkspace, "sharedWorkspace") orelse return false;
    msgSendVoid1(ws, "activateFileViewerSelectingURLs:", ns_arr);
    return true;
}

/// 시스템 비프음 (Electron `shell.beep`). NSBeep — AppKit C symbol.
pub fn shellBeep() void {
    if (!comptime is_macos) return;
    objc.NSBeep();
}

// ============================================
// Application Menu API — NSMenu customization
// ============================================
// macOS 메뉴바 커스터마이즈. App 메뉴(Quit/Hide 등)는 macOS 관례와 종료 라우팅을 위해
// 프레임워크가 유지하고, caller가 전달한 top-level 메뉴를 그 뒤에 붙인다.
//
// 클릭 시 SujiAppMenuTarget.appMenuClick:이 representedObject(NSString click name)를 읽어
// `menu:click {"click":"..."}` 이벤트를 발화한다. checkbox는 클릭 시 state를 토글한다.

pub const ApplicationMenuItem = union(enum) {
    item: struct {
        label: []const u8,
        click: []const u8,
        enabled: bool = true,
    },
    checkbox: struct {
        label: []const u8,
        click: []const u8,
        checked: bool = false,
        enabled: bool = true,
    },
    separator,
    submenu: struct {
        label: []const u8,
        enabled: bool = true,
        items: []const ApplicationMenuItem,
    },
};

pub const MenuEmitHandler = *const fn (click: []const u8) void;
pub var g_menu_emit_handler: ?MenuEmitHandler = null;
var g_app_menu_target: ?*anyopaque = null;

pub fn setMenuEmitHandler(handler: MenuEmitHandler) void {
    g_menu_emit_handler = handler;
}

/// menu/tray click target에 공통 사용하는 ObjC method impl signature: `(self, _cmd, sender)`.
const ObjcSenderImpl = *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) void;

/// NSObject 서브클래스 + 단일 selector method 등록 + 인스턴스 alloc/init.
/// menu/tray click target 같은 stateless ObjC target에 공통 사용.
fn ensureSimpleObjcTarget(
    cache: *?*anyopaque,
    class_name: [:0]const u8,
    sel_name: [:0]const u8,
    impl: ObjcSenderImpl,
) ?*anyopaque {
    if (cache.*) |existing| return existing;
    if (!comptime is_macos) return null;
    const NSObject = getClass("NSObject") orelse return null;
    const cls = objc.objc_allocateClassPair(NSObject, class_name.ptr, 0) orelse
        getClass(class_name) orelse return null;
    const sel = objc.sel_registerName(sel_name.ptr);
    _ = objc.class_addMethod(cls, @ptrCast(sel), @ptrCast(impl), "v@:@");
    objc.objc_registerClassPair(cls);
    const alloc = msgSend(cls, "alloc") orelse return null;
    const instance = msgSend(alloc, "init") orelse return null;
    cache.* = instance;
    return instance;
}

fn ensureAppMenuTarget() ?*anyopaque {
    return ensureSimpleObjcTarget(&g_app_menu_target, "SujiAppMenuTarget", "appMenuClick:", &appMenuClickImpl);
}

/// NSMenuItem.tag === MENU_ITEM_CHECKBOX_TAG → checkbox로 식별, click 시 state 토글.
const MENU_ITEM_CHECKBOX_TAG: i64 = 1;

fn appMenuClickImpl(_: ?*anyopaque, _: ?*anyopaque, sender: ?*anyopaque) callconv(.c) void {
    const item = sender orelse return;
    if (menuItemTag(item) == MENU_ITEM_CHECKBOX_TAG) toggleMenuItemState(item);
    const click = representedObjectUtf8(item) orelse return;
    if (g_menu_emit_handler) |emit| emit(click);
}

pub fn setApplicationMenu(items: []const ApplicationMenuItem) bool {
    if (!comptime is_macos) return false;
    // top-level은 submenu만 허용 (App 메뉴 바). 그 외 타입은 NSMenu 구조상 무의미하므로 거부.
    for (items) |item| if (item != .submenu) return false;

    const NSApplication = getClass("NSApplication") orelse return false;
    const app = msgSend(NSApplication, "sharedApplication") orelse return false;
    const NSMenu = getClass("NSMenu") orelse return false;
    const menubar = msgSend(msgSend(NSMenu, "alloc") orelse return false, "init") orelse return false;

    addDefaultAppMenu(menubar);
    for (items) |item| {
        const sub = item.submenu;
        const menu = createMenuFromItems(sub.label, sub.items) orelse continue;
        const top = addSubmenuItem(menubar, sub.label, menu) orelse continue;
        setMenuItemEnabled(top, sub.enabled);
    }

    msgSendVoid1(app, "setMainMenu:", menubar);
    return true;
}

pub fn resetApplicationMenu() bool {
    if (!comptime is_macos) return false;
    const NSApplication = getClass("NSApplication") orelse return false;
    const app = msgSend(NSApplication, "sharedApplication") orelse return false;
    setupMainMenu(app);
    return true;
}

fn createMenuFromItems(title: []const u8, items: []const ApplicationMenuItem) ?*anyopaque {
    const menu = createMenu(title) orelse return null;
    for (items) |item| addApplicationMenuItem(menu, item);
    return menu;
}

fn addApplicationMenuItem(menu: *anyopaque, item: ApplicationMenuItem) void {
    switch (item) {
        .separator => {
            const NSMenuItem = getClass("NSMenuItem") orelse return;
            const sep = msgSend(NSMenuItem, "separatorItem") orelse return;
            msgSendVoid1(menu, "addItem:", sep);
        },
        .item => |it| addAppMenuClickable(menu, it.label, it.click, it.enabled, null),
        .checkbox => |it| addAppMenuClickable(menu, it.label, it.click, it.enabled, it.checked),
        .submenu => |sub| {
            const sub_menu = createMenuFromItems(sub.label, sub.items) orelse return;
            const m = addSubmenuItem(menu, sub.label, sub_menu) orelse return;
            setMenuItemEnabled(m, sub.enabled);
        },
    }
}

fn addAppMenuClickable(menu: *anyopaque, label: []const u8, click: []const u8, enabled: bool, checked: ?bool) void {
    const target = ensureAppMenuTarget() orelse return;
    const ns_label = nsStringFromSlice(label) orelse return;
    const ns_click = nsStringFromSlice(click) orelse return;
    const m = allocNSMenuItem(ns_label, "appMenuClick:", emptyNSString() orelse return) orelse return;
    msgSendVoid1(m, "setTarget:", target);
    msgSendVoid1(m, "setRepresentedObject:", ns_click);
    if (checked) |state| {
        setMenuItemTag(m, MENU_ITEM_CHECKBOX_TAG);
        setMenuItemState(m, state);
    }
    setMenuItemEnabled(m, enabled);
    msgSendVoid1(menu, "addItem:", m);
}

fn setMenuItemEnabled(item: *anyopaque, enabled: bool) void {
    const f: *const fn (?*anyopaque, ?*anyopaque, u8) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    f(item, @ptrCast(objc.sel_registerName("setEnabled:")), if (enabled) 1 else 0);
}

fn setMenuItemState(item: *anyopaque, checked: bool) void {
    const f: *const fn (?*anyopaque, ?*anyopaque, i64) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    f(item, @ptrCast(objc.sel_registerName("setState:")), if (checked) 1 else 0);
}

fn setMenuItemTag(item: *anyopaque, tag: i64) void {
    const f: *const fn (?*anyopaque, ?*anyopaque, i64) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    f(item, @ptrCast(objc.sel_registerName("setTag:")), tag);
}

// ============================================
// Tray API — NSStatusItem (Electron `Tray`)
// ============================================
// NSStatusBar.systemStatusBar에 statusItem 추가. 메뉴 클릭 시 SujiTrayTarget.trayMenuClick:이
// 호출되고, NSMenuItem.tag(trayId) + representedObject(NSString click name)로 라우팅해
// `tray:menu-click {"trayId":N,"click":"..."}` 이벤트 발화.
//
// 비-macOS는 모두 stub.

pub const TrayMenuItem = union(enum) {
    item: struct { label: []const u8, click: []const u8 },
    separator,
};

const TrayEntry = struct {
    status_item: *anyopaque, // NSStatusItem (retained)
    menu: ?*anyopaque = null, // NSMenu (NSMenuItem retains representedObject NSString)
};

var g_trays: std.AutoHashMap(u32, TrayEntry) = undefined;
var g_trays_initialized: bool = false;
var g_next_tray_id: u32 = 1;
var g_tray_target: ?*anyopaque = null;

fn ensureTraysMap() void {
    if (g_trays_initialized) return;
    const native = g_cef_native orelse return;
    g_trays = std.AutoHashMap(u32, TrayEntry).init(native.allocator);
    g_trays_initialized = true;
}

/// SujiTrayTarget ObjC 클래스 + `trayMenuClick:` selector. NSMenuItem의 tag(trayId)와
/// representedObject(NSString click name)를 읽어 EventBus에 emit.
fn ensureTrayTarget() ?*anyopaque {
    return ensureSimpleObjcTarget(&g_tray_target, "SujiTrayTarget", "trayMenuClick:", &trayMenuClickImpl);
}

/// NSMenuItem clicked → 이벤트 emit. main.zig가 콜백 등록한 g_event_emit 호출.
fn trayMenuClickImpl(_: ?*anyopaque, _: ?*anyopaque, sender: ?*anyopaque) callconv(.c) void {
    const item = sender orelse return;
    const tray_id_signed = menuItemTag(item);
    if (tray_id_signed <= 0) return;
    const tray_id: u32 = @intCast(tray_id_signed);
    const click_name = representedObjectUtf8(item) orelse return;
    if (g_tray_emit_handler) |emit| emit(tray_id, click_name);
}

/// main.zig가 등록 — tray click → EventBus emit 라우팅.
pub const TrayEmitHandler = *const fn (tray_id: u32, click: []const u8) void;
pub var g_tray_emit_handler: ?TrayEmitHandler = null;

pub fn setTrayEmitHandler(handler: TrayEmitHandler) void {
    g_tray_emit_handler = handler;
}

/// 새 tray 생성. title/tooltip은 빈 문자열이면 미설정 (icon 미지원 v1).
/// 반환: trayId (failure 시 0).
pub fn createTray(title: []const u8, tooltip: []const u8) u32 {
    if (!comptime is_macos) return 0;
    ensureTraysMap();
    if (!g_trays_initialized) return 0;

    const NSStatusBar = getClass("NSStatusBar") orelse return 0;
    const bar = msgSend(NSStatusBar, "systemStatusBar") orelse return 0;
    // NSVariableStatusItemLength = -1
    const lenFn: *const fn (?*anyopaque, ?*anyopaque, f64) callconv(.c) ?*anyopaque =
        @ptrCast(&objc.objc_msgSend);
    const item = lenFn(bar, @ptrCast(objc.sel_registerName("statusItemWithLength:")), -1.0) orelse return 0;
    // NSStatusBar가 retain하지만 명시적으로 한 번 더 retain — NSMenu/NSMenuItem 교체 시 안전.
    _ = msgSend(item, "retain");

    if (title.len > 0) applyTrayTitle(item, title);
    if (tooltip.len > 0) applyTrayTooltip(item, tooltip);

    const id = g_next_tray_id;
    g_next_tray_id += 1;
    g_trays.put(id, .{ .status_item = item }) catch {
        // put 실패 → cleanup
        msgSendVoid1(bar, "removeStatusItem:", item);
        _ = msgSend(item, "release");
        return 0;
    };
    return id;
}

/// statusItem.button.title = title.
fn applyTrayTitle(item: *anyopaque, title: []const u8) void {
    const button = msgSend(item, "button") orelse return;
    const ns = nsStringFromSlice(title) orelse return;
    msgSendVoid1(button, "setTitle:", ns);
}

/// statusItem.button.toolTip = tooltip.
fn applyTrayTooltip(item: *anyopaque, tooltip: []const u8) void {
    const button = msgSend(item, "button") orelse return;
    const ns = nsStringFromSlice(tooltip) orelse return;
    msgSendVoid1(button, "setToolTip:", ns);
}

pub fn setTrayTitle(tray_id: u32, title: []const u8) bool {
    if (!comptime is_macos) return false;
    if (!g_trays_initialized) return false;
    const entry = g_trays.get(tray_id) orelse return false;
    applyTrayTitle(entry.status_item, title);
    return true;
}

pub fn setTrayTooltip(tray_id: u32, tooltip: []const u8) bool {
    if (!comptime is_macos) return false;
    if (!g_trays_initialized) return false;
    const entry = g_trays.get(tray_id) orelse return false;
    applyTrayTooltip(entry.status_item, tooltip);
    return true;
}

/// items 배열로 NSMenu 빌드 + tray에 attach. 기존 menu가 있으면 NSMenuItem.representedObject
/// (NSString) 자동 release (NSMenu deinit 연쇄).
pub fn setTrayMenu(tray_id: u32, items: []const TrayMenuItem) bool {
    if (!comptime is_macos) return false;
    if (!g_trays_initialized) return false;
    const entry_ptr = g_trays.getPtr(tray_id) orelse return false;
    const target = ensureTrayTarget() orelse return false;

    const NSMenu = getClass("NSMenu") orelse return false;
    const NSMenuItem = getClass("NSMenuItem") orelse return false;
    const menu_alloc = msgSend(NSMenu, "alloc") orelse return false;
    const menu = msgSend(menu_alloc, "init") orelse return false;

    for (items) |item| switch (item) {
        .separator => {
            const sep = msgSend(NSMenuItem, "separatorItem") orelse continue;
            msgSendVoid1(menu, "addItem:", sep);
        },
        .item => |it| {
            const ns_label = nsStringFromSlice(it.label) orelse continue;
            const ns_click = nsStringFromSlice(it.click) orelse continue;
            const m = allocNSMenuItem(ns_label, "trayMenuClick:", emptyNSString() orelse continue) orelse continue;
            msgSendVoid1(m, "setTarget:", target);
            msgSendVoid1(m, "setRepresentedObject:", ns_click);
            setMenuItemTag(m, @intCast(tray_id));
            msgSendVoid1(menu, "addItem:", m);
        },
    };

    msgSendVoid1(entry_ptr.status_item, "setMenu:", menu);
    entry_ptr.menu = menu;
    return true;
}

/// tray 제거. NSStatusBar에서 빼고 retain count 해제.
pub fn destroyTray(tray_id: u32) bool {
    if (!comptime is_macos) return false;
    if (!g_trays_initialized) return false;
    const entry = g_trays.get(tray_id) orelse return false;

    const NSStatusBar = getClass("NSStatusBar") orelse return false;
    if (msgSend(NSStatusBar, "systemStatusBar")) |bar| {
        msgSendVoid1(bar, "removeStatusItem:", entry.status_item);
    }
    _ = msgSend(entry.status_item, "release");
    _ = g_trays.remove(tray_id);
    return true;
}

// ============================================
// Notification API — UNUserNotificationCenter (Electron `Notification`)
// ============================================
// macOS 10.14+ UNUserNotificationCenter (NSUserNotification deprecated 후 macOS 26 제거).
// 첫 호출 시 OS 권한 다이얼로그 — 그 이후 알림 표시 가능.
// 한계: valid Bundle ID + Info.plist 필요. `suji dev` loose binary는 권한 요청 자체가
// 실패하거나 알림 안 뜰 수 있음. `suji build` .app 번들에서 정상 동작.
//
// click 이벤트는 SujiNotificationDelegate (notification.m)가 C 콜백으로 디스패치 →
// main.zig가 `notification:click {notificationId}` EventBus.emit.

pub const NotificationEmitHandler = *const fn (notification_id: []const u8) void;
pub var g_notification_emit_handler: ?NotificationEmitHandler = null;

/// notification.m의 C 콜백 — Zig 측에서 main.zig로 라우팅.
fn notificationClickC(id_cstr: [*:0]const u8) callconv(.c) void {
    if (g_notification_emit_handler) |emit| emit(std.mem.span(id_cstr));
}

/// main.zig가 등록 — 알림 클릭 → EventBus 라우팅.
pub fn setNotificationEmitHandler(handler: NotificationEmitHandler) void {
    if (!comptime is_macos) return;
    if (!notificationIsSupported()) return;
    g_notification_emit_handler = handler;
    suji_notification_set_click_callback(&notificationClickC);
}

pub fn notificationIsSupported() bool {
    if (!comptime is_macos) return false;
    return suji_notification_is_supported() != 0;
}

/// 권한 요청 — 첫 호출 시 OS 다이얼로그. 동기 대기.
pub fn notificationRequestPermission() bool {
    if (!comptime is_macos) return false;
    return suji_notification_request_permission() != 0;
}

/// 알림 표시. id는 caller-controlled 식별자 (close에 사용). 한도: 64 byte.
/// title/body는 4KB stack-alloc 한도.
pub fn notificationShow(id: []const u8, title: []const u8, body: []const u8, silent: bool) bool {
    if (!comptime is_macos) return false;
    var id_buf: [64]u8 = undefined;
    var t_buf: [4096]u8 = undefined;
    var b_buf: [4096]u8 = undefined;
    const id_cstr = writeCStr(id, &id_buf) orelse return false;
    const t_cstr = writeCStr(title, &t_buf) orelse return false;
    const b_cstr = writeCStr(body, &b_buf) orelse return false;
    return suji_notification_show(id_cstr, t_cstr, b_cstr, if (silent) 1 else 0) != 0;
}

pub fn notificationClose(id: []const u8) bool {
    if (!comptime is_macos) return false;
    var id_buf: [64]u8 = undefined;
    const id_cstr = writeCStr(id, &id_buf) orelse return false;
    suji_notification_close(id_cstr);
    return true;
}

// ============================================
// Global shortcut API — Carbon RegisterEventHotKey (Electron `globalShortcut.*`)
// ============================================
// macOS: Carbon Hot Key API (system-wide, 권한 불필요). global_shortcut.m이 wrap —
// accelerator 문자열 → modifier mask + virtual key code → RegisterEventHotKey.
// 트리거 시 `globalShortcut:trigger {accelerator, click}` EventBus emit.
// 비-macOS는 모두 stub.

pub const GlobalShortcutEmitHandler = *const fn (accelerator: []const u8, click: []const u8) void;
pub var g_global_shortcut_emit_handler: ?GlobalShortcutEmitHandler = null;

const GLOBAL_SHORTCUT_STR_MAX: usize = 128;

fn globalShortcutTriggerC(accel_cstr: [*:0]const u8, click_cstr: [*:0]const u8) callconv(.c) void {
    if (g_global_shortcut_emit_handler) |emit| emit(std.mem.span(accel_cstr), std.mem.span(click_cstr));
}

pub fn setGlobalShortcutEmitHandler(handler: GlobalShortcutEmitHandler) void {
    if (!comptime is_macos) return;
    g_global_shortcut_emit_handler = handler;
    suji_global_shortcut_set_callback(&globalShortcutTriggerC);
}

/// Zig slice → null-terminated C string in caller-supplied buffer.
/// 슬라이스 길이+1 > buf.len이면 null. notification/global_shortcut 등 .m extern 호출 공통.
fn writeCStr(slice: []const u8, buf: []u8) ?[*:0]const u8 {
    if (slice.len + 1 > buf.len) return null;
    @memcpy(buf[0..slice.len], slice);
    buf[slice.len] = 0;
    return @ptrCast(buf.ptr);
}

pub const GlobalShortcutStatus = enum(i32) {
    ok = 0,
    capacity = -1,
    duplicate = -2,
    parse = -3,
    os_reject = -4,
    too_long = -5,
};

pub fn globalShortcutRegister(accelerator: []const u8, click: []const u8) GlobalShortcutStatus {
    if (!comptime is_macos) return .os_reject;
    var accel_buf: [GLOBAL_SHORTCUT_STR_MAX]u8 = undefined;
    var click_buf: [GLOBAL_SHORTCUT_STR_MAX]u8 = undefined;
    const accel_cstr = writeCStr(accelerator, &accel_buf) orelse return .too_long;
    const click_cstr = writeCStr(click, &click_buf) orelse return .too_long;
    return switch (suji_global_shortcut_register(accel_cstr, click_cstr)) {
        0 => .ok,
        -1 => .capacity,
        -2 => .duplicate,
        -3 => .parse,
        -4 => .os_reject,
        -5 => .too_long,
        else => .os_reject,
    };
}

pub fn globalShortcutUnregister(accelerator: []const u8) bool {
    if (!comptime is_macos) return false;
    var accel_buf: [GLOBAL_SHORTCUT_STR_MAX]u8 = undefined;
    const accel_cstr = writeCStr(accelerator, &accel_buf) orelse return false;
    return suji_global_shortcut_unregister(accel_cstr) != 0;
}

pub fn globalShortcutUnregisterAll() void {
    if (!comptime is_macos) return;
    suji_global_shortcut_unregister_all();
}

pub fn globalShortcutIsRegistered(accelerator: []const u8) bool {
    if (!comptime is_macos) return false;
    var accel_buf: [GLOBAL_SHORTCUT_STR_MAX]u8 = undefined;
    const accel_cstr = writeCStr(accelerator, &accel_buf) orelse return false;
    return suji_global_shortcut_is_registered(accel_cstr) != 0;
}

// ============================================
// Window lifecycle events (Electron BrowserWindow events 대응) — 비-macOS는 stub.
// ============================================

pub const WindowResizedHandler = *const fn (handle: u64, x: f64, y: f64, width: f64, height: f64) void;
pub const WindowMovedHandler = *const fn (handle: u64, x: f64, y: f64) void;
pub const WindowFocusHandler = *const fn (handle: u64) void;
pub const WindowBlurHandler = *const fn (handle: u64) void;
pub const WindowSimpleHandler = *const fn (handle: u64) void;
/// will-resize 동기 콜백. handler가 proposed_w/proposed_h 포인터를 mutate 가능 —
/// listener가 preventDefault 시 curr 값으로 덮어쓰면 cancellation.
pub const WindowWillResizeHandler = *const fn (handle: u64, curr_w: f64, curr_h: f64, proposed_w: *f64, proposed_h: *f64) void;

// 11개 lifecycle handler globals — 같은 파일의 C 트램폴린 (`windowMinimizeC` 등)만
// 참조. 외부 노출 없음 → `pub` 제거로 모듈 표면 정리.
var g_window_resized_handler: ?WindowResizedHandler = null;
var g_window_moved_handler: ?WindowMovedHandler = null;
var g_window_focus_handler: ?WindowFocusHandler = null;
var g_window_blur_handler: ?WindowBlurHandler = null;
var g_window_minimize_handler: ?WindowSimpleHandler = null;
var g_window_restore_handler: ?WindowSimpleHandler = null;
var g_window_maximize_handler: ?WindowSimpleHandler = null;
var g_window_unmaximize_handler: ?WindowSimpleHandler = null;
var g_window_enter_fullscreen_handler: ?WindowSimpleHandler = null;
var g_window_leave_fullscreen_handler: ?WindowSimpleHandler = null;
var g_window_will_resize_handler: ?WindowWillResizeHandler = null;

fn windowResizedC(handle: u64, x: f64, y: f64, width: f64, height: f64) callconv(.c) void {
    if (g_window_resized_handler) |h| h(handle, x, y, width, height);
}
fn windowMovedC(handle: u64, x: f64, y: f64) callconv(.c) void {
    if (g_window_moved_handler) |h| h(handle, x, y);
}
fn windowFocusC(handle: u64) callconv(.c) void {
    if (g_window_focus_handler) |h| h(handle);
}
fn windowBlurC(handle: u64) callconv(.c) void {
    if (g_window_blur_handler) |h| h(handle);
}
fn windowMinimizeC(handle: u64) callconv(.c) void {
    if (g_window_minimize_handler) |h| h(handle);
}
fn windowRestoreC(handle: u64) callconv(.c) void {
    if (g_window_restore_handler) |h| h(handle);
}
fn windowMaximizeC(handle: u64) callconv(.c) void {
    if (g_window_maximize_handler) |h| h(handle);
}
fn windowUnmaximizeC(handle: u64) callconv(.c) void {
    if (g_window_unmaximize_handler) |h| h(handle);
}
fn windowEnterFullscreenC(handle: u64) callconv(.c) void {
    if (g_window_enter_fullscreen_handler) |h| h(handle);
}
fn windowLeaveFullscreenC(handle: u64) callconv(.c) void {
    if (g_window_leave_fullscreen_handler) |h| h(handle);
}
fn windowWillResizeC(handle: u64, curr_w: f64, curr_h: f64, proposed_w: *f64, proposed_h: *f64) callconv(.c) void {
    if (g_window_will_resize_handler) |h| h(handle, curr_w, curr_h, proposed_w, proposed_h);
}

pub const WindowLifecycleHandlers = struct {
    resized: WindowResizedHandler,
    moved: WindowMovedHandler,
    focus: WindowFocusHandler,
    blur: WindowBlurHandler,
    minimize: WindowSimpleHandler,
    restore: WindowSimpleHandler,
    maximize: WindowSimpleHandler,
    unmaximize: WindowSimpleHandler,
    enter_fullscreen: WindowSimpleHandler,
    leave_fullscreen: WindowSimpleHandler,
    will_resize: WindowWillResizeHandler,
};

pub fn setWindowLifecycleHandlers(h: WindowLifecycleHandlers) void {
    if (!comptime is_macos) return;
    g_window_resized_handler = h.resized;
    g_window_moved_handler = h.moved;
    g_window_focus_handler = h.focus;
    g_window_blur_handler = h.blur;
    g_window_minimize_handler = h.minimize;
    g_window_restore_handler = h.restore;
    g_window_maximize_handler = h.maximize;
    g_window_unmaximize_handler = h.unmaximize;
    g_window_enter_fullscreen_handler = h.enter_fullscreen;
    g_window_leave_fullscreen_handler = h.leave_fullscreen;
    g_window_will_resize_handler = h.will_resize;
    const cbs: SujiWindowLifecycleCallbacks = .{
        .resized = &windowResizedC,
        .moved = &windowMovedC,
        .focus = &windowFocusC,
        .blur = &windowBlurC,
        .minimize = &windowMinimizeC,
        .restore = &windowRestoreC,
        .maximize = &windowMaximizeC,
        .unmaximize = &windowUnmaximizeC,
        .enter_fullscreen = &windowEnterFullscreenC,
        .leave_fullscreen = &windowLeaveFullscreenC,
        .will_resize = &windowWillResizeC,
    };
    suji_window_lifecycle_set_callbacks(&cbs);
}

fn attachWindowLifecycle(ns_window: ?*anyopaque, handle: u64) void {
    if (!comptime is_macos) return;
    if (suji_window_lifecycle_attach(ns_window, handle) == 0) {
        log.warn("attachWindowLifecycle failed for handle={d} (capacity {d} reached or null window)", .{ handle, 64 });
    }
}

fn detachWindowLifecycle(ns_window: ?*anyopaque) void {
    if (!comptime is_macos) return;
    suji_window_lifecycle_detach(ns_window);
}

// ============================================
// Dialog API — NSAlert / NSOpenPanel / NSSavePanel (Electron `dialog.*`)
// ============================================
// 두 가지 modal 모드:
//   1. **Sheet** — `parent_window` 지정 시 부모 창 타이틀바에서 슬라이드 (Electron 기본).
//      ObjC block(^) completion handler 필요 → src/platform/dialog.m이 wrap.
//      그 창만 입력 차단, 다른 창은 정상 동작.
//   2. **Free-floating** — `parent_window` null이면 runModal로 화면 중앙 독립 창.
//      앱 전체 입력 차단. Electron의 두-인자 호출 없이 부른 케이스.
//
// 비-macOS는 모두 stub (canceled:true / response:0). 향후 GTK/Win32 plug-in.

// dialog.m C 함수 (sheet path). nested run loop로 동기화.
extern "c" fn suji_run_sheet_alert(parent_window: ?*anyopaque, alert: ?*anyopaque) i64;
extern "c" fn suji_run_sheet_save_panel(parent_window: ?*anyopaque, panel: ?*anyopaque) i64;

// notification.m — UNUserNotificationCenter wrapper.
extern "c" fn suji_notification_is_supported() i32;
extern "c" fn suji_notification_set_click_callback(cb: *const fn ([*:0]const u8) callconv(.c) void) void;
extern "c" fn suji_notification_request_permission() i32;
extern "c" fn suji_notification_show(id: [*:0]const u8, title: [*:0]const u8, body: [*:0]const u8, silent: i32) i32;
extern "c" fn suji_notification_close(id: [*:0]const u8) void;

// global_shortcut.m — Carbon RegisterEventHotKey wrapper.
// register status: 0=success, -1=capacity, -2=duplicate, -3=parse, -4=os_reject, -5=too_long.
extern "c" fn suji_global_shortcut_set_callback(cb: *const fn ([*:0]const u8, [*:0]const u8) callconv(.c) void) void;
extern "c" fn suji_global_shortcut_register(accelerator: [*:0]const u8, click: [*:0]const u8) i32;
extern "c" fn suji_global_shortcut_unregister(accelerator: [*:0]const u8) i32;
extern "c" fn suji_global_shortcut_unregister_all() void;
extern "c" fn suji_global_shortcut_is_registered(accelerator: [*:0]const u8) i32;

// window_lifecycle.m — NSWindowDelegate. struct로 묶어 silent mis-routing 차단
// (6개가 동일 시그니처 `*const fn (u64) callconv(.c) void`).
const SujiWindowLifecycleCallbacks = extern struct {
    resized: *const fn (u64, f64, f64, f64, f64) callconv(.c) void,
    moved: *const fn (u64, f64, f64) callconv(.c) void,
    focus: *const fn (u64) callconv(.c) void,
    blur: *const fn (u64) callconv(.c) void,
    minimize: *const fn (u64) callconv(.c) void,
    restore: *const fn (u64) callconv(.c) void,
    maximize: *const fn (u64) callconv(.c) void,
    unmaximize: *const fn (u64) callconv(.c) void,
    enter_fullscreen: *const fn (u64) callconv(.c) void,
    leave_fullscreen: *const fn (u64) callconv(.c) void,
    will_resize: *const fn (u64, f64, f64, *f64, *f64) callconv(.c) void,
};
extern "c" fn suji_window_lifecycle_set_callbacks(cbs: *const SujiWindowLifecycleCallbacks) void;
extern "c" fn suji_window_lifecycle_attach(ns_window: ?*anyopaque, handle: u64) i32;
extern "c" fn suji_window_lifecycle_detach(ns_window: ?*anyopaque) void;
extern "c" fn suji_window_lifecycle_minimize(ns_window: ?*anyopaque) void;
extern "c" fn suji_window_lifecycle_deminiaturize(ns_window: ?*anyopaque) void;
extern "c" fn suji_window_lifecycle_maximize(ns_window: ?*anyopaque) void;
extern "c" fn suji_window_lifecycle_unmaximize(ns_window: ?*anyopaque) void;
extern "c" fn suji_window_lifecycle_set_fullscreen(ns_window: ?*anyopaque, flag: i32) void;
extern "c" fn suji_window_lifecycle_is_minimized(ns_window: ?*anyopaque) i32;
extern "c" fn suji_window_lifecycle_is_maximized(ns_window: ?*anyopaque) i32;
extern "c" fn suji_window_lifecycle_is_fullscreen(ns_window: ?*anyopaque) i32;

/// CEF browser native_handle → NSWindow 포인터 lookup. main.zig가 windowId(WM)를
/// browser handle로 변환 후 호출.
pub fn nsWindowForBrowserHandle(handle: u64) ?*anyopaque {
    if (!comptime is_macos) return null;
    const native = g_cef_native orelse return null;
    const entry = native.browsers.get(handle) orelse return null;
    return entry.ns_window;
}

pub const MAX_DIALOG_BUTTONS: usize = 16;
pub const MAX_DIALOG_PATHS: usize = 64;

pub const MessageBoxStyle = enum { none, info, warning, err, question };

pub const MessageBoxOpts = struct {
    style: MessageBoxStyle = .none,
    title: []const u8 = "",
    message: []const u8 = "",
    detail: []const u8 = "",
    buttons: []const []const u8 = &.{},
    default_id: ?usize = null,
    cancel_id: ?usize = null,
    checkbox_label: []const u8 = "",
    checkbox_checked: bool = false,
    /// 부모 창 NSWindow 포인터 — null이면 free-floating runModal, 있으면 sheet.
    parent_window: ?*anyopaque = null,
};

pub const MessageBoxResult = struct {
    response: usize = 0,
    checkbox_checked: bool = false,
};

pub const FileFilter = struct {
    name: []const u8 = "",
    extensions: []const []const u8 = &.{},
};

pub const OpenDialogOpts = struct {
    title: []const u8 = "",
    default_path: []const u8 = "",
    button_label: []const u8 = "",
    message: []const u8 = "",
    can_choose_files: bool = true,
    can_choose_directories: bool = false,
    allows_multiple_selection: bool = false,
    shows_hidden_files: bool = false,
    can_create_directories: bool = true,
    no_resolve_aliases: bool = false,
    treat_packages_as_dirs: bool = false,
    filters: []const FileFilter = &.{},
    /// 부모 창 NSWindow 포인터 — null이면 free-floating, 있으면 sheet.
    parent_window: ?*anyopaque = null,
};

pub const SaveDialogOpts = struct {
    title: []const u8 = "",
    default_path: []const u8 = "",
    button_label: []const u8 = "",
    message: []const u8 = "",
    name_field_label: []const u8 = "",
    shows_hidden_files: bool = false,
    can_create_directories: bool = true,
    show_overwrite_confirmation: bool = true,
    /// macOS Finder 태그 입력 필드 (NSSavePanel.setShowsTagField:). 기본 false.
    shows_tag_field: bool = false,
    filters: []const FileFilter = &.{},
    /// 부모 창 NSWindow 포인터 — null이면 free-floating, 있으면 sheet.
    parent_window: ?*anyopaque = null,
};

/// NSAlert 메시지 박스. macOS HIG 기본: 첫 버튼 = default(Enter), 마지막 버튼 = Cancel(ESC).
/// `default_id`/`cancel_id`로 명시적 변경.
pub fn showMessageBox(opts: MessageBoxOpts) MessageBoxResult {
    if (!comptime is_macos) return .{};
    const NSAlert = getClass("NSAlert") orelse return .{};
    const alloc = msgSend(NSAlert, "alloc") orelse return .{};
    const alert = msgSend(alloc, "init") orelse return .{};

    if (opts.message.len > 0) {
        if (nsStringFromSlice(opts.message)) |ns| msgSendVoid1(alert, "setMessageText:", ns);
    }
    if (opts.detail.len > 0) {
        if (nsStringFromSlice(opts.detail)) |ns| msgSendVoid1(alert, "setInformativeText:", ns);
    }

    // NSAlertStyle: warning=0, info=1, critical=2. question/none → warning(0).
    const style: u64 = switch (opts.style) {
        .info => 1,
        .err => 2,
        .none, .warning, .question => 0,
    };
    const setStyleFn: *const fn (?*anyopaque, ?*anyopaque, u64) callconv(.c) void =
        @ptrCast(&objc.objc_msgSend);
    setStyleFn(alert, @ptrCast(objc.sel_registerName("setAlertStyle:")), style);

    if (opts.title.len > 0) {
        if (msgSend(alert, "window")) |win| {
            if (nsStringFromSlice(opts.title)) |ns| msgSendVoid1(win, "setTitle:", ns);
        }
    }

    // 버튼 추가 — 빈 배열이면 기본 "OK".
    var added_buttons: [MAX_DIALOG_BUTTONS]?*anyopaque = [_]?*anyopaque{null} ** MAX_DIALOG_BUTTONS;
    const button_titles: []const []const u8 = if (opts.buttons.len > 0) opts.buttons else &.{"OK"};
    const button_count: usize = @min(button_titles.len, MAX_DIALOG_BUTTONS);
    const addBtnFn: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque =
        @ptrCast(&objc.objc_msgSend);
    for (button_titles[0..button_count], 0..) |btn_title, i| {
        const ns = nsStringFromSlice(btn_title) orelse continue;
        added_buttons[i] = addBtnFn(alert, @ptrCast(objc.sel_registerName("addButtonWithTitle:")), ns);
    }

    // default_id 지정 — NSAlert는 기본적으로 첫 버튼이 default (Enter). 다른 index를
    // default로 만들려면 첫 버튼의 keyEquivalent를 지우고 대상에 "\r" 설정.
    if (opts.default_id) |def_idx| {
        if (def_idx < button_count) {
            if (def_idx != 0) {
                if (added_buttons[0]) |b0| {
                    if (nsStringFromSlice("")) |empty| msgSendVoid1(b0, "setKeyEquivalent:", empty);
                }
            }
            if (added_buttons[def_idx]) |btn| {
                if (nsStringFromSlice("\r")) |ret| msgSendVoid1(btn, "setKeyEquivalent:", ret);
            }
        }
    }
    // cancel_id 지정 — ESC 매핑.
    if (opts.cancel_id) |can_idx| {
        if (can_idx < button_count) {
            if (added_buttons[can_idx]) |btn| {
                if (nsStringFromSlice("\x1b")) |esc| msgSendVoid1(btn, "setKeyEquivalent:", esc);
            }
        }
    }

    // Suppression button (체크박스) — checkbox_label 있을 때만.
    if (opts.checkbox_label.len > 0) {
        msgSendVoidBool(alert, "setShowsSuppressionButton:", true);
        if (msgSend(alert, "suppressionButton")) |sb| {
            if (nsStringFromSlice(opts.checkbox_label)) |ns| msgSendVoid1(sb, "setTitle:", ns);
            const setStateFn: *const fn (?*anyopaque, ?*anyopaque, i64) callconv(.c) void =
                @ptrCast(&objc.objc_msgSend);
            setStateFn(sb, @ptrCast(objc.sel_registerName("setState:")), if (opts.checkbox_checked) 1 else 0);
        }
    }

    // parent_window 지정 → sheet path (.m). 없으면 free-floating runModal.
    const ns_response: i64 = if (opts.parent_window) |parent|
        suji_run_sheet_alert(parent, alert)
    else blk: {
        const runModalFn: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) i64 =
            @ptrCast(&objc.objc_msgSend);
        break :blk runModalFn(alert, @ptrCast(objc.sel_registerName("runModal")));
    };
    // NSAlertFirstButtonReturn = 1000.
    const NS_ALERT_FIRST_BTN: i64 = 1000;
    const idx_signed: i64 = ns_response - NS_ALERT_FIRST_BTN;
    const response_idx: usize = if (idx_signed < 0 or idx_signed >= @as(i64, @intCast(button_count)))
        0
    else
        @intCast(idx_signed);

    var checkbox_state: bool = opts.checkbox_checked;
    if (opts.checkbox_label.len > 0) {
        if (msgSend(alert, "suppressionButton")) |sb| {
            const stateFn: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) i64 =
                @ptrCast(&objc.objc_msgSend);
            const state = stateFn(sb, @ptrCast(objc.sel_registerName("state")));
            checkbox_state = (state != 0);
        }
    }

    return .{ .response = response_idx, .checkbox_checked = checkbox_state };
}

/// 단순 에러 popup — NSAlert critical style + 단일 OK 버튼 (Electron `dialog.showErrorBox`).
pub fn showErrorBox(title: []const u8, content: []const u8) void {
    if (!comptime is_macos) return;
    _ = showMessageBox(.{
        .style = .err,
        .title = title,
        .message = content,
        .buttons = &.{"OK"},
    });
}

/// NSOpenPanel — 파일/폴더 선택. 결과는 response_buf에 JSON으로 직접 씀.
/// 형식: `{"canceled":bool,"filePaths":["/p1","/p2"]}`.
/// 호출자(main.zig)가 from/cmd 래핑.
pub fn showOpenDialog(opts: OpenDialogOpts, response_buf: []u8) []const u8 {
    if (!comptime is_macos) return writeCanceledResponse(response_buf, true);
    const NSOpenPanel = getClass("NSOpenPanel") orelse return writeCanceledResponse(response_buf, true);
    const panel = msgSend(NSOpenPanel, "openPanel") orelse return writeCanceledResponse(response_buf, true);

    applySavePanelCommon(panel, .{
        .title = opts.title,
        .default_path = opts.default_path,
        .button_label = opts.button_label,
        .message = opts.message,
        .shows_hidden_files = opts.shows_hidden_files,
        .can_create_directories = opts.can_create_directories,
        .filters = opts.filters,
    });

    msgSendVoidBool(panel, "setCanChooseFiles:", opts.can_choose_files);
    msgSendVoidBool(panel, "setCanChooseDirectories:", opts.can_choose_directories);
    msgSendVoidBool(panel, "setAllowsMultipleSelection:", opts.allows_multiple_selection);
    msgSendVoidBool(panel, "setResolvesAliases:", !opts.no_resolve_aliases);
    msgSendVoidBool(panel, "setTreatsFilePackagesAsDirectories:", opts.treat_packages_as_dirs);

    const result: i64 = if (opts.parent_window) |parent|
        suji_run_sheet_save_panel(parent, panel)
    else blk: {
        const runModalFn: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) i64 =
            @ptrCast(&objc.objc_msgSend);
        break :blk runModalFn(panel, @ptrCast(objc.sel_registerName("runModal")));
    };
    // NSModalResponseOK = 1, NSModalResponseCancel = 0.
    if (result != 1) return writeCanceledResponse(response_buf, true);

    const urls = msgSend(panel, "URLs") orelse return writeCanceledResponse(response_buf, true);
    return writeOpenResponse(response_buf, urls);
}

/// NSSavePanel — 저장 경로 선택.
/// 형식: `{"canceled":bool,"filePath":"/path/file.ext"}`.
pub fn showSaveDialog(opts: SaveDialogOpts, response_buf: []u8) []const u8 {
    if (!comptime is_macos) return writeSaveCanceledResponse(response_buf, true);
    const NSSavePanel = getClass("NSSavePanel") orelse return writeSaveCanceledResponse(response_buf, true);
    const panel = msgSend(NSSavePanel, "savePanel") orelse return writeSaveCanceledResponse(response_buf, true);

    applySavePanelCommon(panel, .{
        .title = opts.title,
        .default_path = opts.default_path,
        .button_label = opts.button_label,
        .message = opts.message,
        .shows_hidden_files = opts.shows_hidden_files,
        .can_create_directories = opts.can_create_directories,
        .filters = opts.filters,
    });

    if (opts.name_field_label.len > 0) {
        if (nsStringFromSlice(opts.name_field_label)) |ns| msgSendVoid1(panel, "setNameFieldLabel:", ns);
    }
    msgSendVoidBool(panel, "setShowsTagField:", opts.shows_tag_field);
    // overwrite confirmation은 NSSavePanel 기본 ON (allowsOtherFileTypes와 별도). API 노출 없어서
    // 옵션 무시 — 기본 동작 유지.

    const result: i64 = if (opts.parent_window) |parent|
        suji_run_sheet_save_panel(parent, panel)
    else blk: {
        const runModalFn: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) i64 =
            @ptrCast(&objc.objc_msgSend);
        break :blk runModalFn(panel, @ptrCast(objc.sel_registerName("runModal")));
    };
    if (result != 1) return writeSaveCanceledResponse(response_buf, true);

    const url = msgSend(panel, "URL") orelse return writeSaveCanceledResponse(response_buf, true);
    var path_buf: [4096]u8 = undefined;
    const path = nsUrlToPath(url, &path_buf);
    return writeSaveSuccessResponse(response_buf, path);
}

const SavePanelCommonOpts = struct {
    title: []const u8,
    default_path: []const u8,
    button_label: []const u8,
    message: []const u8,
    shows_hidden_files: bool,
    can_create_directories: bool,
    filters: []const FileFilter,
};

/// NSSavePanel 계열(Open/Save) 공통 옵션 적용. setDirectoryURL/setNameFieldStringValue는
/// default_path가 디렉토리/파일에 따라 동작이 다름 — 슬래시로 끝나거나 기존 디렉토리면
/// directoryURL, 아니면 (디렉토리, 파일명) 분리.
fn applySavePanelCommon(panel: *anyopaque, opts: SavePanelCommonOpts) void {
    if (opts.title.len > 0) {
        if (nsStringFromSlice(opts.title)) |ns| msgSendVoid1(panel, "setTitle:", ns);
    }
    if (opts.message.len > 0) {
        if (nsStringFromSlice(opts.message)) |ns| msgSendVoid1(panel, "setMessage:", ns);
    }
    if (opts.button_label.len > 0) {
        if (nsStringFromSlice(opts.button_label)) |ns| msgSendVoid1(panel, "setPrompt:", ns);
    }
    msgSendVoidBool(panel, "setShowsHiddenFiles:", opts.shows_hidden_files);
    msgSendVoidBool(panel, "setCanCreateDirectories:", opts.can_create_directories);

    if (opts.default_path.len > 0) applyDefaultPath(panel, opts.default_path);
    if (opts.filters.len > 0) applyFileFilters(panel, opts.filters);
}

fn applyDefaultPath(panel: *anyopaque, default_path: []const u8) void {
    // path 끝이 '/'면 directory만, 아니면 마지막 segment를 파일명으로 분리.
    const ends_with_slash = default_path.len > 0 and default_path[default_path.len - 1] == '/';
    if (ends_with_slash) {
        setDirectoryURLFromPath(panel, default_path[0 .. default_path.len - 1]);
        return;
    }
    if (std.mem.lastIndexOfScalar(u8, default_path, '/')) |slash_idx| {
        const dir = default_path[0..slash_idx];
        const name = default_path[slash_idx + 1 ..];
        if (dir.len > 0) setDirectoryURLFromPath(panel, dir);
        if (name.len > 0) {
            if (nsStringFromSlice(name)) |ns| msgSendVoid1(panel, "setNameFieldStringValue:", ns);
        }
    } else {
        // 슬래시 없음 — 그냥 파일명으로 취급.
        if (nsStringFromSlice(default_path)) |ns| msgSendVoid1(panel, "setNameFieldStringValue:", ns);
    }
}

fn setDirectoryURLFromPath(panel: *anyopaque, dir_path: []const u8) void {
    const ns_dir = nsStringFromSlice(dir_path) orelse return;
    const NSURL = getClass("NSURL") orelse return;
    const fileUrlFn: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque =
        @ptrCast(&objc.objc_msgSend);
    const url = fileUrlFn(NSURL, @ptrCast(objc.sel_registerName("fileURLWithPath:")), ns_dir) orelse return;
    msgSendVoid1(panel, "setDirectoryURL:", url);
}

fn applyFileFilters(panel: *anyopaque, filters: []const FileFilter) void {
    // setAllowedFileTypes:는 macOS 12에서 deprecated이지만 여전히 동작 — UTType 기반 신규 API
    // (setAllowedContentTypes:)는 추후 작업. 모든 필터의 extension을 평탄화해 단일 NSArray로 전달.
    const NSMutableArray = getClass("NSMutableArray") orelse return;
    const arr = msgSend(NSMutableArray, "array") orelse return;
    const addObjFn: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) void =
        @ptrCast(&objc.objc_msgSend);
    var added: usize = 0;
    for (filters) |f| {
        for (f.extensions) |ext| {
            // "*" 또는 빈 문자열은 무시 — 모든 파일 허용 의미라 setAllowedFileTypes 자체를 안 부름이 맞음.
            if (ext.len == 0 or std.mem.eql(u8, ext, "*")) continue;
            if (nsStringFromSlice(ext)) |ns| {
                addObjFn(arr, @ptrCast(objc.sel_registerName("addObject:")), ns);
                added += 1;
            }
        }
    }
    if (added > 0) msgSendVoid1(panel, "setAllowedFileTypes:", arr);
}

fn nsUrlToPath(ns_url: *anyopaque, buf: []u8) []const u8 {
    const path_ns = msgSend(ns_url, "path") orelse return buf[0..0];
    const utf8Fn: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) ?[*:0]const u8 =
        @ptrCast(&objc.objc_msgSend);
    const cstr = utf8Fn(path_ns, @ptrCast(objc.sel_registerName("UTF8String"))) orelse return buf[0..0];
    const len = std.mem.span(cstr).len;
    const copy_len = @min(len, buf.len);
    @memcpy(buf[0..copy_len], cstr[0..copy_len]);
    return buf[0..copy_len];
}

fn writeCanceledResponse(buf: []u8, canceled: bool) []const u8 {
    return std.fmt.bufPrint(
        buf,
        "{{\"canceled\":{},\"filePaths\":[]}}",
        .{canceled},
    ) catch buf[0..0];
}

fn writeSaveCanceledResponse(buf: []u8, canceled: bool) []const u8 {
    return std.fmt.bufPrint(
        buf,
        "{{\"canceled\":{},\"filePath\":\"\"}}",
        .{canceled},
    ) catch buf[0..0];
}

fn writeSaveSuccessResponse(buf: []u8, path: []const u8) []const u8 {
    var esc_buf: [util.MAX_RESPONSE]u8 = undefined;
    const esc_len = util.escapeJsonStrFull(path, &esc_buf) orelse return writeSaveCanceledResponse(buf, true);
    return std.fmt.bufPrint(
        buf,
        "{{\"canceled\":false,\"filePath\":\"{s}\"}}",
        .{esc_buf[0..esc_len]},
    ) catch writeSaveCanceledResponse(buf, true);
}

/// NSArray<NSURL *> → JSON paths array. 응답 버퍼 부족하면 한도까지만.
fn writeOpenResponse(buf: []u8, urls: *anyopaque) []const u8 {
    const countFn: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) usize =
        @ptrCast(&objc.objc_msgSend);
    const count = countFn(urls, @ptrCast(objc.sel_registerName("count")));

    var w: usize = 0;
    const header = std.fmt.bufPrint(buf[w..], "{{\"canceled\":false,\"filePaths\":[", .{}) catch return writeCanceledResponse(buf, true);
    w += header.len;

    const objAtFn: *const fn (?*anyopaque, ?*anyopaque, usize) callconv(.c) ?*anyopaque =
        @ptrCast(&objc.objc_msgSend);
    var path_buf: [4096]u8 = undefined;
    var esc_buf: [4096]u8 = undefined;
    var written_count: usize = 0;
    const max_paths = @min(count, MAX_DIALOG_PATHS);
    var i: usize = 0;
    while (i < max_paths) : (i += 1) {
        const url = objAtFn(urls, @ptrCast(objc.sel_registerName("objectAtIndex:")), i) orelse continue;
        const path = nsUrlToPath(url, &path_buf);
        const esc_len = util.escapeJsonStrFull(path, &esc_buf) orelse continue;

        const sep: []const u8 = if (written_count == 0) "\"" else ",\"";
        const part = std.fmt.bufPrint(buf[w..], "{s}{s}\"", .{ sep, esc_buf[0..esc_len] }) catch break;
        w += part.len;
        written_count += 1;
    }

    const tail = std.fmt.bufPrint(buf[w..], "]}}", .{}) catch return writeCanceledResponse(buf, true);
    w += tail.len;
    return buf[0..w];
}

/// 메시지 루프 실행 (블로킹)
pub fn run() void {
    if (comptime is_macos) activateNSApp();
    std.debug.print("[suji] CEF running\n", .{});
    c.cef_run_message_loop();
}

/// CEF 종료
pub fn shutdown() void {
    // c.cef_shutdown은 메시지 루프 drain 중 잔여 OnBeforeClose 콜백을 발화시킬 수 있음 —
    // 그 시점에 devtools_to_inspectee가 살아있어야 안전한 lookup/remove 가능.
    c.cef_shutdown();
    if (devtools_map_initialized) {
        devtools_map_initialized = false;
        devtools_to_inspectee.deinit();
    }
    pending_devtools_inspectee = null;
    std.debug.print("[suji] CEF shutdown\n", .{});
}

/// 메시지 루프 종료 요청. 매핑된 DevTools와 등록된 모든 창을 force-close 후 quit.
///
/// DevTools 떠 있을 때 cef_quit_message_loop만 호출하면 macOS NSApp 런루프가
/// DevTools pending 이벤트에 매여 quit이 늦거나 무시됨. close_browser(1)은 force라
/// cancelable `window:close` 이벤트는 발화 X — 명시적 quit 요청이라 의도적.
///
/// **명시적 idempotent**: 두 번째 호출은 즉시 no-op. user code(suji.on("window:all-closed"))
/// + 코어 자동 quit(`app.quitOnAllWindowsClosed: true`) 두 경로가 동시에 발화해도 안전.
var g_quit_called: bool = false;

pub fn quit() void {
    if (g_quit_called) return;
    g_quit_called = true;

    if (devtools_map_initialized) {
        var it = devtools_to_inspectee.iterator();
        while (it.next()) |entry| {
            const native = g_cef_native orelse break;
            const be = native.browsers.get(entry.value_ptr.*) orelse continue;
            const host = devtoolsHost(be.browser) orelse continue;
            if (host.has_dev_tools.?(host) == 1) host.close_dev_tools.?(host);
        }
    }

    if (g_cef_native) |native| {
        var it = native.browsers.iterator();
        while (it.next()) |entry| {
            const br = entry.value_ptr.*.browser;
            const host = asPtr(c.cef_browser_host_t, br.get_host.?(br)) orelse continue;
            host.close_browser.?(host, 1);
        }
    }

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
fn release(_: ?*c.cef_base_ref_counted_t) callconv(.c) i32 {
    return 1;
}
fn hasOneRef(_: ?*c.cef_base_ref_counted_t) callconv(.c) i32 {
    return 1;
}
fn hasAtLeastOneRef(_: ?*c.cef_base_ref_counted_t) callconv(.c) i32 {
    return 1;
}

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
    client_ptr.get_drag_handler = &getDragHandler;
    client_ptr.get_display_handler = &getDisplayHandler;
    client_ptr.get_load_handler = &getLoadHandler;
    client_ptr.on_process_message_received = &onBrowserProcessMessageReceived;
}

fn getKeyboardHandler(_: ?*c._cef_client_t) callconv(.c) ?*c._cef_keyboard_handler_t {
    return &g_keyboard_handler;
}

fn getLifeSpanHandler(_: ?*c._cef_client_t) callconv(.c) ?*c._cef_life_span_handler_t {
    return &g_life_span_handler;
}

fn getDragHandler(_: ?*c._cef_client_t) callconv(.c) ?*c._cef_drag_handler_t {
    return &g_drag_handler;
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
    g_display_handler.on_title_change = &onTitleChange;
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

/// 문서 `<title>` 최대 길이 (UTF-8 바이트). 초과 시 cefStringToUtf8가 truncate.
/// 256은 일반 페이지 title에 충분 — 여기서 escape 후 worst-case ~1.5KB까지 부풀고
/// main.zig의 emitToBus 4KB 버퍼와 함께 페이로드(`{windowId,title}`) 안전하게 수용.
pub const MAX_TITLE_BYTES: usize = 256;

/// 문서 `<title>`이 변경될 때 호출. payload UTF-8 변환 후 main.zig handler로 forward.
fn onTitleChange(
    _: ?*c._cef_display_handler_t,
    browser: ?*c._cef_browser_t,
    title: [*c]const c.cef_string_t,
) callconv(.c) void {
    const br = browser orelse return;
    const t = title orelse return;
    const handler = g_window_title_change_handler orelse return;
    const handle: u64 = @intCast(br.get_identifier.?(br));
    var buf: [MAX_TITLE_BYTES]u8 = undefined;
    const slice = cefStringToUtf8(t, &buf);
    handler(handle, slice);
}

// ============================================
// CEF Load Handler — main frame 첫 로드 완료 → window:ready-to-show
// ============================================

var g_load_handler: c.cef_load_handler_t = undefined;
var g_load_handler_initialized: bool = false;

fn ensureLoadHandler() void {
    if (g_load_handler_initialized) return;
    zeroCefStruct(c.cef_load_handler_t, &g_load_handler);
    initBaseRefCounted(&g_load_handler.base);
    g_load_handler.on_load_end = &onLoadEnd;
    g_load_handler_initialized = true;
}

fn getLoadHandler(_: ?*c._cef_client_t) callconv(.c) ?*c._cef_load_handler_t {
    ensureLoadHandler();
    return &g_load_handler;
}

/// main frame이 처음으로 load 완료되는 순간 ready-to-show 1회 발화 (Electron 호환).
/// reload/navigate에선 다시 발화 X — `ready_to_show_fired` 플래그로 멱등성 보장.
fn onLoadEnd(
    _: ?*c._cef_load_handler_t,
    browser: ?*c._cef_browser_t,
    frame: ?*c._cef_frame_t,
    _: c_int,
) callconv(.c) void {
    const br = browser orelse return;
    const f = frame orelse return;
    const is_main = if (f.is_main) |fn_ptr| fn_ptr(f) == 1 else false;
    if (!is_main) return;

    const native = g_cef_native orelse return;
    const handle: u64 = @intCast(br.get_identifier.?(br));
    const entry = native.browsers.getPtr(handle) orelse return;
    if (entry.ready_to_show_fired) return;
    entry.ready_to_show_fired = true;
    if (g_window_ready_to_show_handler) |h| h(handle);
}

pub const WindowReadyToShowHandler = *const fn (handle: u64) void;
pub const WindowTitleChangeHandler = *const fn (handle: u64, title: []const u8) void;

var g_window_ready_to_show_handler: ?WindowReadyToShowHandler = null;
var g_window_title_change_handler: ?WindowTitleChangeHandler = null;

pub const WindowDisplayHandlers = struct {
    ready_to_show: ?WindowReadyToShowHandler = null,
    title_change: ?WindowTitleChangeHandler = null,
};

/// main.zig가 ready-to-show / page-title-updated emit 핸들러를 주입.
/// cef.zig가 EventBus(loader/main)에 직접 의존하지 않도록 한 단계 indirection.
/// lifecycle handlers와 동일하게 struct 패턴 — Phase 5+ 추가 핸들러(did-finish-load 등)
/// 도입 시 비파괴적 확장 가능.
pub fn setWindowDisplayHandlers(handlers: WindowDisplayHandlers) void {
    g_window_ready_to_show_handler = handlers.ready_to_show;
    g_window_title_change_handler = handlers.title_change;
}

// ============================================
// CEF Drag Handler — `-webkit-app-region` region 수집
// ============================================

var g_drag_handler: c.cef_drag_handler_t = undefined;
var g_drag_handler_initialized: bool = false;

fn initDragHandler() void {
    if (g_drag_handler_initialized) return;
    zeroCefStruct(c.cef_drag_handler_t, &g_drag_handler);
    initBaseRefCounted(&g_drag_handler.base);
    g_drag_handler.on_drag_enter = &onDragEnter;
    g_drag_handler.on_draggable_regions_changed = &onDraggableRegionsChanged;
    g_drag_handler_initialized = true;
}

fn onDragEnter(
    _: ?*c._cef_drag_handler_t,
    _: ?*c._cef_browser_t,
    _: ?*c._cef_drag_data_t,
    _: c.cef_drag_operations_mask_t,
) callconv(.c) i32 {
    return 0;
}

fn onDraggableRegionsChanged(
    _: ?*c._cef_drag_handler_t,
    browser: ?*c._cef_browser_t,
    frame: ?*c._cef_frame_t,
    regions_count: usize,
    regions_ptr: [*c]const c.cef_draggable_region_t,
) callconv(.c) void {
    const br = browser orelse return;
    const f = frame orelse return;
    if ((frameIsMain(@ptrCast(f)) orelse false) == false) return;

    const native = g_cef_native orelse return;
    const handle: u64 = @intCast(br.get_identifier.?(br));
    const entry = native.browsers.getPtr(handle) orelse return;

    native.allocator.free(entry.drag_regions);
    entry.drag_regions = &.{};

    if (regions_count == 0 or regions_ptr == null) return;

    const next = native.allocator.alloc(drag_region.DragRegion, regions_count) catch |e| {
        log.err("draggable regions allocation failed: {s}", .{@errorName(e)});
        return;
    };
    const source = regions_ptr[0..regions_count];
    for (source, 0..) |region, i| {
        next[i] = .{
            .x = region.bounds.x,
            .y = region.bounds.y,
            .width = region.bounds.width,
            .height = region.bounds.height,
            .draggable = region.draggable != 0,
        };
    }
    entry.drag_regions = next;
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

    var data_buf: [CEF_IPC_BUF_LEN]u8 = undefined;
    const data = getArgString(args, 2, &data_buf);

    // Phase 2.5 — wire 레벨 sender 컨텍스트(__window/__window_name/__window_url/__window_main_frame)
    // 자동 주입. 이미 __window가 박혀있는 요청(cross-hop)은 보존.
    var injected_buf: [CEF_IPC_BUF_LEN]u8 = undefined;
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

    var data_buf: [CEF_IPC_BUF_LEN]u8 = undefined;
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
    const br = browser orelse return;
    const id: u64 = @intCast(br.get_identifier.?(br));

    if (pending_devtools_inspectee) |inspectee| {
        ensureDevToolsMap();
        devtools_to_inspectee.put(id, inspectee) catch {};
        pending_devtools_inspectee = null;
        return;
    }

    if (g_browser == null) {
        g_browser = browser;
    }
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

    // DevTools 닫히면 (1) inspectee 창에 키 포커스 복귀, (2) 매핑 제거.
    // makeKey는 다음 런루프 틱에 지연 실행해야 함 — onBeforeClose는 NSWindow close
    // 시퀀스 중간에 호출되고 AppKit이 그 후에도 비동기로 키 창을 재할당해 우리 호출이
    // 덮어써짐. performSelector:withObject:afterDelay:0이 다음 틱에 makeKey 예약.
    if (devtools_map_initialized) {
        if (devtools_to_inspectee.get(handle)) |inspectee_id| {
            if (g_cef_native) |native| {
                if (native.browsers.get(inspectee_id)) |entry| {
                    if (entry.ns_window) |ns_win| deferMakeKeyAndOrderFront(ns_win);
                }
            }
        }
        _ = devtools_to_inspectee.remove(handle);
    }

    var is_view: bool = false;
    notifyWm: {
        const wm = window_mod.WindowManager.global orelse break :notifyWm;
        const id = wm.findByNativeHandle(handle) orelse break :notifyWm;
        const w = wm.get(id) orelse break :notifyWm;
        is_view = (w.kind == .view);
        if (w.destroyed) {
            log.debug("OnBeforeClose id={d} already destroyed — skip markClosedExternal", .{id});
            break :notifyWm;
        }
        log.debug("OnBeforeClose id={d} → markClosedExternal", .{id});
        wm.markClosedExternal(id) catch {};
    }

    // view OnBeforeClose는 host 종속 — main browser와 별개라 quit_message_loop 트리거 X
    // (defense-in-depth: g_browser fallback이 view를 main으로 잘못 인식하는 경로 차단).
    const is_main = !is_view and (if (g_browser) |main_br|
        br.get_identifier.?(br) == main_br.get_identifier.?(main_br)
    else
        true);
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
    const is_devtools_key = (key == 123) or (cmd and key == 'I' and (shift or alt));
    if (is_devtools_key) {
        markShortcut(is_keyboard_shortcut);
        // sender가 DevTools front-end면 recursive open(=DevTools의 DevTools) 차단 +
        // 사용자 의도 = "DevTools 닫기" → inspectee.host.close_dev_tools.
        const sender_id: u64 = @intCast(br.get_identifier.?(br));
        if (lookupDevToolsInspectee(sender_id)) |inspectee_id| {
            if (g_cef_native) |native| {
                if (native.browsers.get(inspectee_id)) |entry| closeDevTools(entry.browser);
            }
            return 1;
        }
        toggleDevTools(br);
        return 1;
    }

    // F5 / Shift+F5 — Reload (Electron 호환, DevTools 안에서 누르면 inspectee reload).
    if (key == 116) {
        markShortcut(is_keyboard_shortcut);
        reloadInspecteeOrSelf(br, shift);
        return 1;
    }

    if (!cmd) return 0;

    // Cmd+R — Reload (DevTools 안이면 inspectee reload — Electron 호환).
    if (key == 'R' and !shift) {
        markShortcut(is_keyboard_shortcut);
        reloadInspecteeOrSelf(br, false);
        return 1;
    }

    // Cmd+Shift+R — Hard Reload (cache 무시).
    if (key == 'R' and shift) {
        markShortcut(is_keyboard_shortcut);
        reloadInspecteeOrSelf(br, true);
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

    // Cmd+Q — 앱 종료. 일반적으로는 NSApp 메뉴 key equivalent가 먼저 매치되어
    // SujiQuitTarget.sujiQuit:이 발화 → 여긴 도달 X. 폴백으로 동일 quit() 호출.
    if (key == 'Q') {
        quit();
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

fn devtoolsHost(browser: *c.cef_browser_t) ?*c.cef_browser_host_t {
    return asPtr(c.cef_browser_host_t, browser.get_host.?(browser));
}

/// CEF에 "이 키는 keyboard shortcut이라 default browser command 발동 막아라" 알림.
/// OnPreKeyEvent return 1만으로는 CEF가 자체 reload(Cmd+R) 같은 default 처리를
/// 별도로 발동시킬 수 있어 우리 헬퍼와 충돌 가능. is_keyboard_shortcut.* = 1로 차단.
fn markShortcut(is_keyboard_shortcut: ?*i32) void {
    if (is_keyboard_shortcut) |sc| sc.* = 1;
}

/// reload 키(F5/Cmd+R)는 sender browser를 reload하는 게 기본인데, sender가 DevTools
/// front-end면 self-reload되어 inspectee(개발자가 진짜 reload하고 싶은 페이지)는
/// 변동 없음. 이 함수가 sender가 BrowserEntry에 등록된(= 사용자 창)인지 보고:
///   - 등록됨: sender 그대로 reload (일반 동작)
///   - 미등록(DevTools 추정) + g_devtools_inspectee 있음: inspectee reload (Electron 호환)
///   - 미등록 + 매핑 없음: sender reload (fallback — silent fail X)
fn reloadInspecteeOrSelf(sender: *c.cef_browser_t, ignore_cache: bool) void {
    const target = blk: {
        const sender_id: u64 = @intCast(sender.get_identifier.?(sender));
        // sender가 DevTools면 그 DevTools의 inspectee browser 찾아 reload.
        // 멀티 윈도우 동시 DevTools라도 정확한 매핑.
        if (lookupDevToolsInspectee(sender_id)) |inspectee_id| {
            if (g_cef_native) |native| {
                if (native.browsers.get(inspectee_id)) |entry| break :blk entry.browser;
            }
        }
        break :blk sender;
    };
    if (ignore_cache) {
        const fn_ptr = target.reload_ignore_cache orelse return;
        fn_ptr(target);
    } else {
        const fn_ptr = target.reload orelse return;
        fn_ptr(target);
    }
}

fn hasDevTools(browser: *c.cef_browser_t) bool {
    const host = devtoolsHost(browser) orelse return false;
    return host.has_dev_tools.?(host) == 1;
}

/// devtools_browser_id → inspectee_browser_id 매핑. F5/Cmd+R DevTools self-reload
/// 회피용 (sender DevTools면 inspectee reload — Electron 호환).
///
/// 흐름:
///   1. openDevTools(inspectee): pending_devtools_inspectee = inspectee.id 저장 후 show_dev_tools 호출
///   2. CEF가 새 DevTools browser 생성 → onAfterCreated 호출
///   3. onAfterCreated: pending이 있으면 그 새 browser가 DevTools — map.put + pending=null
///   4. reloadInspecteeOrSelf(sender): map.get(sender_id)이 있으면 inspectee 찾아 reload
///   5. onBeforeClose(devtools_browser): map.remove(id) — stale 매핑 차단
///
/// CEF는 single UI thread라 race 없음. 멀티 윈도우 동시 DevTools 안전.
var devtools_to_inspectee: std.AutoHashMap(u64, u64) = undefined;
var devtools_map_initialized: bool = false;
var pending_devtools_inspectee: ?u64 = null;

fn ensureDevToolsMap() void {
    if (devtools_map_initialized) return;
    const native = g_cef_native orelse return;
    devtools_to_inspectee = std.AutoHashMap(u64, u64).init(native.allocator);
    devtools_map_initialized = true;
}

fn lookupDevToolsInspectee(devtools_id: u64) ?u64 {
    if (!devtools_map_initialized) return null;
    return devtools_to_inspectee.get(devtools_id);
}

fn openDevTools(browser: *c.cef_browser_t) void {
    const host = devtoolsHost(browser) orelse return;
    if (host.has_dev_tools.?(host) == 1) return; // 이미 열려있으면 멱등 no-op

    var window_info: c.cef_window_info_t = undefined;
    zeroCefStruct(c.cef_window_info_t, &window_info);
    window_info.runtime_style = c.CEF_RUNTIME_STYLE_DEFAULT;

    var settings: c.cef_browser_settings_t = undefined;
    zeroCefStruct(c.cef_browser_settings_t, &settings);

    var point: c.cef_point_t = .{ .x = 0, .y = 0 };
    // 다음 onAfterCreated가 우리가 만들 DevTools browser — 그 시점에 매핑 등록.
    pending_devtools_inspectee = @intCast(browser.get_identifier.?(browser));
    host.show_dev_tools.?(host, &window_info, &g_devtools_client, &settings, &point);
}

fn closeDevTools(browser: *c.cef_browser_t) void {
    const host = devtoolsHost(browser) orelse return;
    if (host.has_dev_tools.?(host) != 1) return; // 이미 닫혀있으면 no-op
    // 매핑 정리 + inspectee focus 복귀는 onBeforeClose가 처리 — close_dev_tools가
    // 비동기라 여기서 즉시 makeKeyAndOrderFront 호출하면 OS의 close-time focus
    // 재할당에 덮어쓰임. DevTools browser의 onBeforeClose 콜백이 close 완료 시점.
    host.close_dev_tools.?(host);
}

fn toggleDevTools(browser: *c.cef_browser_t) void {
    if (hasDevTools(browser)) closeDevTools(browser) else openDevTools(browser);
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
    var request_buf: [CEF_IPC_BUF_LEN]u8 = undefined;
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

    var data_buf: [CEF_IPC_BUF_LEN]u8 = undefined;
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

    var data_buf: [CEF_IPC_BUF_LEN]u8 = undefined;
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

    // CSP default — suji:// 프로덕션 응답에만 적용. dev (file:// / dev_url)은 vite hmr
    // 때문에 'unsafe-inline'/'unsafe-eval' 필요해 별도 정책 — 그쪽은 사용자 HTML 메타 태그.
    // config.security.csp가 비어있으면 안전한 default. ["disabled"]면 미적용 (escape hatch).
    setSecurityHeaders(resp);

    if (response_length) |rl| {
        rl.* = @intCast(rh.data.len);
    }
}

fn setSecurityHeaders(resp: *c.cef_response_t) void {
    if (g_csp_enabled) setRespHeader(resp, "Content-Security-Policy", g_csp_value);
    setRespHeader(resp, "X-Content-Type-Options", "nosniff");
    setRespHeader(resp, "X-Frame-Options", "SAMEORIGIN");
}

fn setRespHeader(resp: *c.cef_response_t, name: []const u8, value: []const u8) void {
    var name_str: c.cef_string_t = .{};
    var value_str: c.cef_string_t = .{};
    setCefString(&name_str, name);
    setCefString(&value_str, value);
    resp.set_header_by_name.?(resp, &name_str, &value_str, 1);
}

/// frame-src 자리에 들어갈 sentinel — iframe allowed origins가 빌드 시점 합성.
const CSP_FRAME_SRC_SENTINEL = "__SUJI_FRAME_SRC__";

const DEFAULT_CSP_TEMPLATE =
    "default-src 'self' suji:; " ++
    "script-src 'self' suji: 'unsafe-inline'; " ++
    "style-src 'self' suji: 'unsafe-inline'; " ++
    "img-src 'self' suji: data: blob:; " ++
    "connect-src 'self' suji: ws: wss: http: https:; " ++
    "font-src 'self' suji: data:; " ++
    "frame-src " ++ CSP_FRAME_SRC_SENTINEL ++ ";";

/// `suji://` 응답에 적용되는 CSP. config.security.csp가 `"disabled"`면 CSP 헤더 자체를
/// 안 보냄. 그 외는 user-supplied policy로 override. iframeAllowedOrigins는 default
/// CSP의 frame-src에 합성 (사용자 csp override 시 그것을 우선 — 사용자가 직접 frame-src 명시 책임).
pub var g_csp_value: []const u8 = "";  // setIframeAllowedOrigins / setCspValue가 process init 시 set.
pub var g_csp_enabled: bool = true;

/// 사용자가 csp 미지정 시 default CSP를 빌드. iframe allowed origins는 frame-src에 합성.
/// allocator 소유 — 결과는 process lifetime 유지 (config arena와 연결). 빈 origin 배열이면
/// `frame-src 'none'` (iframe 완전 차단, default safe).
pub fn buildDefaultCsp(allocator: std.mem.Allocator, iframe_allowed_origins: []const []const u8) ![]const u8 {
    var frame_src_buf: std.ArrayList(u8) = .empty;
    defer frame_src_buf.deinit(allocator);
    if (iframe_allowed_origins.len == 0) {
        try frame_src_buf.appendSlice(allocator, "'none'");
    } else {
        // ["*"] = unrestricted (escape hatch)
        var unrestricted = false;
        for (iframe_allowed_origins) |o| if (std.mem.eql(u8, o, "*")) { unrestricted = true; break; };
        if (unrestricted) {
            try frame_src_buf.appendSlice(allocator, "*");
        } else {
            try frame_src_buf.appendSlice(allocator, "'self'");
            for (iframe_allowed_origins) |origin| {
                try frame_src_buf.append(allocator, ' ');
                try frame_src_buf.appendSlice(allocator, origin);
            }
        }
    }

    // template의 sentinel을 실제 frame-src로 치환.
    const result = try std.mem.replaceOwned(u8, allocator, DEFAULT_CSP_TEMPLATE, CSP_FRAME_SRC_SENTINEL, frame_src_buf.items);
    return result;
}

pub fn setCspValue(value: []const u8) void {
    if (value.len == 0) return;
    if (std.mem.eql(u8, value, "disabled")) {
        g_csp_enabled = false;
        return;
    }
    g_csp_value = value;
    g_csp_enabled = true;
}

test "setCspValue: empty/disabled/custom 분기" {
    const saved_value = g_csp_value;
    const saved_enabled = g_csp_enabled;
    defer {
        g_csp_value = saved_value;
        g_csp_enabled = saved_enabled;
    }

    const TEST_DEFAULT = "default-src 'self';";
    // 빈 값 → no-op (default 유지)
    g_csp_value = TEST_DEFAULT;
    g_csp_enabled = true;
    setCspValue("");
    try std.testing.expectEqualStrings(TEST_DEFAULT, g_csp_value);
    try std.testing.expect(g_csp_enabled);

    // "disabled" sentinel → CSP 헤더 자체 disable (escape hatch)
    setCspValue("disabled");
    try std.testing.expect(!g_csp_enabled);

    // custom policy → enable + override
    setCspValue("default-src 'none'");
    try std.testing.expect(g_csp_enabled);
    try std.testing.expectEqualStrings("default-src 'none'", g_csp_value);
}

test "buildDefaultCsp: iframe allowedOrigins 합성" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 빈 배열 → frame-src 'none' (default safe)
    const empty = try buildDefaultCsp(a, &.{});
    try std.testing.expect(std.mem.indexOf(u8, empty, "frame-src 'none';") != null);

    // 명시 origin → frame-src 'self' + origins
    const origins = [_][]const u8{ "https://trusted.com", "https://api.example.com" };
    const restrict = try buildDefaultCsp(a, &origins);
    try std.testing.expect(std.mem.indexOf(u8, restrict, "frame-src 'self' https://trusted.com https://api.example.com;") != null);

    // ["*"] escape → frame-src *
    const wildcard = [_][]const u8{"*"};
    const all = try buildDefaultCsp(a, &wildcard);
    try std.testing.expect(std.mem.indexOf(u8, all, "frame-src *;") != null);

    // 다른 directive 보존
    try std.testing.expect(std.mem.indexOf(u8, empty, "default-src 'self' suji:") != null);
    try std.testing.expect(std.mem.indexOf(u8, empty, "script-src 'self' suji: 'unsafe-inline'") != null);
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
    // parent_id는 WindowInitOpts에 없음 — createWindow에서 별도 처리(line 390 인근).
    // 본 함수는 WindowInitOpts에 들어오는 필드만 검사.
    return !ap.frame or ap.transparent or
        ap.background_color != null or ap.title_bar_style != .default or
        cs.always_on_top or cs.fullscreen or
        cs.min_width != 0 or cs.min_height != 0 or
        cs.max_width != 0 or cs.max_height != 0;
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
    addDefaultAppMenu(menubar);

    // 2. File 메뉴
    const file_menu = createMenu("File") orelse return;
    addMenuItem(file_menu, "Close Window", "performClose:", "w");
    _ = addSubmenuItem(menubar, "File", file_menu);

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
        _ = addSubmenuItem(edit_menu, "Substitutions", sub_menu);
    }
    // Speech 서브메뉴
    if (createMenu("Speech")) |speech_menu| {
        addMenuItem(speech_menu, "Start Speaking", "startSpeaking:", "");
        addMenuItem(speech_menu, "Stop Speaking", "stopSpeaking:", "");
        _ = addSubmenuItem(edit_menu, "Speech", speech_menu);
    }
    _ = addSubmenuItem(menubar, "Edit", edit_menu);

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
    _ = addSubmenuItem(menubar, "View", view_menu);

    // 5. Window 메뉴
    const window_menu = createMenu("Window") orelse return;
    addMenuItem(window_menu, "Minimize", "performMiniaturize:", "m");
    addMenuItem(window_menu, "Zoom", "performZoom:", "");
    addSeparator(window_menu);
    addMenuItem(window_menu, "Bring All to Front", "arrangeInFront:", "");
    _ = addSubmenuItem(menubar, "Window", window_menu);

    // 6. Help 메뉴
    const help_menu = createMenu("Help") orelse return;
    _ = addSubmenuItem(menubar, "Help", help_menu);

    msgSendVoid1(app, "setMainMenu:", menubar);
}

fn addDefaultAppMenu(menubar: *anyopaque) void {
    const app_menu = createMenu("") orelse return;
    addMenuItem(app_menu, "About Suji", "orderFrontStandardAboutPanel:", "");
    addSeparator(app_menu);
    addMenuItem(app_menu, "Hide Suji", "hide:", "h");
    addMenuItemWithModifier(app_menu, "Hide Others", "hideOtherApplications:", "h", true);
    addMenuItem(app_menu, "Show All", "unhideAllApplications:", "");
    addSeparator(app_menu);
    addQuitMenuItem(app_menu);
    _ = addSubmenuItem(menubar, "", app_menu);
}

fn createMenu(title: []const u8) ?*anyopaque {
    const NSMenu = getClass("NSMenu") orelse return null;
    const alloc = msgSend(NSMenu, "alloc") orelse return null;
    const ns_title = nsStringFromSlice(title) orelse return null;
    const initSel = objc.sel_registerName("initWithTitle:");
    const initFn: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque = @ptrCast(&objc.objc_msgSend);
    return initFn(alloc, @ptrCast(initSel), ns_title);
}

fn addSubmenuItem(menubar: *anyopaque, title: []const u8, submenu: *anyopaque) ?*anyopaque {
    const item = msgSend(msgSend(getClass("NSMenuItem") orelse return null, "alloc") orelse return null, "init") orelse return null;
    msgSendVoid1(item, "setSubmenu:", submenu);
    if (title.len > 0) {
        const ns_title = nsStringFromSlice(title) orelse return null;
        msgSendVoid1(item, "setTitle:", ns_title);
    }
    msgSendVoid1(menubar, "addItem:", item);
    return item;
}

fn addMenuItemWithModifier(menu: *anyopaque, title: [:0]const u8, action: [:0]const u8, key: [:0]const u8, shift: bool) void {
    addMenuItemWithModifiers(menu, title, action, key, shift, false);
}

fn addMenuItemWithModifiers(menu: *anyopaque, title: [:0]const u8, action: [:0]const u8, key: [:0]const u8, shift: bool, alt: bool) void {
    const NSString = getClass("NSString") orelse return;
    const strFn: *const fn (?*anyopaque, ?*anyopaque, [*:0]const u8) callconv(.c) ?*anyopaque = @ptrCast(&objc.objc_msgSend);
    const ns_title = strFn(NSString, @ptrCast(objc.sel_registerName("stringWithUTF8String:")), title.ptr);
    const ns_key = strFn(NSString, @ptrCast(objc.sel_registerName("stringWithUTF8String:")), key.ptr);
    const item = allocNSMenuItem(ns_title, action.ptr, ns_key) orelse return;

    // NSCommandKeyMask=1<<20, NSShiftKeyMask=1<<17, NSAlternateKeyMask=1<<19
    var mask: u64 = 1 << 20; // Cmd
    if (shift) mask |= 1 << 17;
    if (alt) mask |= 1 << 19;
    const setModFn: *const fn (?*anyopaque, ?*anyopaque, u64) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    setModFn(item, @ptrCast(objc.sel_registerName("setKeyEquivalentModifierMask:")), mask);

    msgSendVoid1(menu, "addItem:", item);
}

/// NSMenuItem.alloc.initWithTitle:action:keyEquivalent: 보일러플레이트.
/// caller가 NSString을 미리 만들고(nsStringFromSlice 또는 stringWithUTF8String) action
/// selector 이름을 줌. target/representedObject/tag는 caller가 추가 설정.
fn allocNSMenuItem(ns_title: ?*anyopaque, action_sel_name: [*:0]const u8, ns_key: ?*anyopaque) ?*anyopaque {
    const NSMenuItem = getClass("NSMenuItem") orelse return null;
    const initSel = objc.sel_registerName("initWithTitle:action:keyEquivalent:");
    const initFn: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque =
        @ptrCast(&objc.objc_msgSend);
    const alloc = msgSend(NSMenuItem, "alloc") orelse return null;
    return initFn(alloc, @ptrCast(initSel), ns_title, @ptrCast(objc.sel_registerName(action_sel_name)), ns_key);
}

fn addMenuItem(menu: *anyopaque, title: [:0]const u8, action: [:0]const u8, key: [:0]const u8) void {
    const NSString = getClass("NSString") orelse return;
    const strFn: *const fn (?*anyopaque, ?*anyopaque, [*:0]const u8) callconv(.c) ?*anyopaque = @ptrCast(&objc.objc_msgSend);
    const ns_title = strFn(NSString, @ptrCast(objc.sel_registerName("stringWithUTF8String:")), title.ptr);
    const ns_key = strFn(NSString, @ptrCast(objc.sel_registerName("stringWithUTF8String:")), key.ptr);
    const item = allocNSMenuItem(ns_title, action.ptr, ns_key) orelse return;
    msgSendVoid1(menu, "addItem:", item);
}

fn addQuitMenuItem(menu: *anyopaque) void {
    const target = ensureQuitTarget() orelse return;
    const NSString = getClass("NSString") orelse return;
    const strFn: *const fn (?*anyopaque, ?*anyopaque, [*:0]const u8) callconv(.c) ?*anyopaque = @ptrCast(&objc.objc_msgSend);
    const ns_title = strFn(NSString, @ptrCast(objc.sel_registerName("stringWithUTF8String:")), "Quit Suji");
    const ns_key = strFn(NSString, @ptrCast(objc.sel_registerName("stringWithUTF8String:")), "q");
    const item = allocNSMenuItem(ns_title, "sujiQuit:", ns_key) orelse return;
    msgSendVoid1(item, "setTarget:", target);
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

/// `[ns_win performSelector:@selector(makeKeyAndOrderFront:) withObject:nil afterDelay:0]`.
/// onBeforeClose 시점엔 AppKit이 close-time 비동기 focus 재할당을 미루고 있어
/// 즉시 makeKey가 덮어써짐 — afterDelay:0으로 다음 런루프 틱에 예약하면 안정.
fn deferMakeKeyAndOrderFront(ns_win: *anyopaque) void {
    if (!comptime is_macos) return;
    const sel_perform = objc.sel_registerName("performSelector:withObject:afterDelay:");
    const sel_make_key = objc.sel_registerName("makeKeyAndOrderFront:");
    const f: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque, ?*anyopaque, f64) callconv(.c) void =
        @ptrCast(&objc.objc_msgSend);
    f(ns_win, @ptrCast(sel_perform), @ptrCast(sel_make_key), null, 0.0);
}

/// BOOL 인자(u8 0/1) 버전 — setOpaque:/setHasShadow: 등 Objective-C BOOL setter용.
fn msgSendVoidBool(target: ?*anyopaque, sel_name: [:0]const u8, arg: bool) void {
    const sel = objc.sel_registerName(sel_name.ptr);
    const func: *const fn (?*anyopaque, ?*anyopaque, u8) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    func(target, @ptrCast(sel), if (arg) 1 else 0);
}

/// NSRect 1-arg 버전 — setFrame:/initWithFrame: 등. ARM64 ABI는 NSRect를 d0~d3 float
/// 레지스터로 전달하므로 함수 포인터 시그니처에 NSRect를 그대로 두면 Zig가 올바른 cc 선택.
/// initWithFrame:은 alloc된 NSView를 반환해 ?*anyopaque를 돌려주지만 setFrame:은 void —
/// 호출자가 반환값을 _ = 으로 처리하면 동일 헬퍼 재사용 가능.
fn msgSendNSRect(target: ?*anyopaque, sel_name: [:0]const u8, rect: NSRect) ?*anyopaque {
    const sel = objc.sel_registerName(sel_name.ptr);
    const func: *const fn (?*anyopaque, ?*anyopaque, NSRect) callconv(.c) ?*anyopaque = @ptrCast(&objc.objc_msgSend);
    return func(target, @ptrCast(sel), rect);
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
/// borderless 창도 키 이벤트를 받도록 NSWindow subclass `SujiKeyableWindow`를 사용 —
/// 기본 NSWindow.canBecomeKeyWindow는 borderless에서 NO 반환이라 frameless 창에 키 안 옴.
fn allocMacWindow(opts: WindowInitOpts) ?*anyopaque {
    const cls = ensureSujiKeyableWindowClass() orelse return null;
    const window_alloc = msgSend(cls, "alloc") orelse return null;
    const initSel = objc.sel_registerName("initWithContentRect:styleMask:backing:defer:");
    const initFn: *const fn (?*anyopaque, ?*anyopaque, NSRect, u64, u64, u8) callconv(.c) ?*anyopaque = @ptrCast(&objc.objc_msgSend);
    return initFn(window_alloc, @ptrCast(initSel), resolveInitialFrame(opts), computeStyleMask(opts), 2, 0);
}

/// NSWindow subclass로 borderless(frame=false) 창의 canBecomeKeyWindow를 YES override.
/// 그래야 frameless 창에 키 이벤트(F12/Cmd+R 등)가 들어옴 — 기본 NSWindow는 borderless면
/// canBecomeKeyWindow=NO라 키 입력 무시. titled 창은 super가 이미 YES 반환이라 영향 X.
var g_keyable_window_class: ?*anyopaque = null;
fn ensureSujiKeyableWindowClass() ?*anyopaque {
    if (g_keyable_window_class) |existing| return existing;
    const ns_window = getClass("NSWindow") orelse return null;
    const cls = objc.objc_allocateClassPair(ns_window, "SujiKeyableWindow", 0) orelse {
        // 이미 등록된 경우 — 동일 이름으로 다시 alloc하면 null. 기존 클래스 가져옴.
        return getClass("SujiKeyableWindow");
    };
    const sel = objc.sel_registerName("canBecomeKeyWindow");
    _ = objc.class_addMethod(cls, @ptrCast(sel), @ptrCast(&returnYesBOOL), "c@:");
    const send_event_sel = objc.sel_registerName("sendEvent:");
    _ = objc.class_addMethod(cls, @ptrCast(send_event_sel), @ptrCast(&sujiWindowSendEvent), "v@:@");
    objc.objc_registerClassPair(cls);
    g_keyable_window_class = cls;
    return cls;
}

fn returnYesBOOL(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) u8 {
    return 1;
}

fn sujiWindowSendEvent(self: ?*anyopaque, cmd: ?*anyopaque, event: ?*anyopaque) callconv(.c) void {
    const window = self orelse return;
    const ev = event orelse return;
    if (shouldPerformNativeWindowDrag(window, ev)) {
        msgSendVoid1(window, "performWindowDragWithEvent:", ev);
        return;
    }
    callNSWindowSendEvent(window, cmd, ev);
}

fn callNSWindowSendEvent(window: *anyopaque, cmd: ?*anyopaque, event: *anyopaque) void {
    const ns_window = getClass("NSWindow") orelse return;
    const imp = objc.class_getMethodImplementation(ns_window, cmd);
    const f: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) void = @ptrCast(imp);
    f(window, cmd, event);
}

fn shouldPerformNativeWindowDrag(ns_window: *anyopaque, event: *anyopaque) bool {
    const event_type = nsEventType(event);
    if (event_type != 1) return false; // NSEventTypeLeftMouseDown

    const native = g_cef_native orelse return false;
    const entry = findBrowserEntryByNSWindow(native, ns_window) orelse return false;
    if (entry.drag_regions.len == 0) return false;

    const content_view = msgSend(ns_window, "contentView") orelse return false;
    const bounds = nsViewBounds(content_view);
    const point = nsEventLocationInWindow(event);
    const x: i32 = @intFromFloat(@floor(point.x));
    const y: i32 = @intFromFloat(@floor(bounds.height - point.y));
    return drag_region.isPointDraggable(entry.drag_regions, x, y);
}

fn findBrowserEntryByNSWindow(native: *CefNative, ns_window: *anyopaque) ?*CefNative.BrowserEntry {
    var it = native.browsers.valueIterator();
    while (it.next()) |entry| {
        if (entry.ns_window == ns_window) return entry;
    }
    return null;
}

fn nsEventType(event: *anyopaque) u64 {
    const sel = objc.sel_registerName("type");
    const f: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) u64 = @ptrCast(&objc.objc_msgSend);
    return f(event, @ptrCast(sel));
}

fn nsEventLocationInWindow(event: *anyopaque) NSPoint {
    const sel = objc.sel_registerName("locationInWindow");
    const f: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) NSPoint = @ptrCast(&objc.objc_msgSend);
    return f(event, @ptrCast(sel));
}

fn nsViewBounds(view: *anyopaque) NSRect {
    const sel = objc.sel_registerName("bounds");
    const f: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) NSRect = @ptrCast(&objc.objc_msgSend);
    return f(view, @ptrCast(sel));
}

/// Quit 메뉴/Cmd+Q action 타깃. 기본 NSApplication의 `terminate:`를 부르면 CEF가
/// NSApplicationWillTerminate 옵저버에서 SIGTRAP — 그래서 자체 selector로 우회해
/// `cef.quit()`(close_browser→cef_quit_message_loop)을 호출, run() 정상 반환 후
/// main.zig가 cef.shutdown까지 정렬 처리.
var g_quit_target: ?*anyopaque = null;

fn sujiQuitImpl(_: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    quit();
}

fn ensureQuitTarget() ?*anyopaque {
    if (g_quit_target) |existing| return existing;
    const NSObject = getClass("NSObject") orelse return null;
    const cls = objc.objc_allocateClassPair(NSObject, "SujiQuitTarget", 0) orelse
        getClass("SujiQuitTarget") orelse return null;
    const sel = objc.sel_registerName("sujiQuit:");
    _ = objc.class_addMethod(cls, @ptrCast(sel), @ptrCast(&sujiQuitImpl), "v@:@");
    objc.objc_registerClassPair(cls);
    const alloc = msgSend(cls, "alloc") orelse return null;
    const instance = msgSend(alloc, "init") orelse return null;
    g_quit_target = instance;
    return instance;
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
    const color = fn_ptr(
        NSColor,
        @ptrCast(sel),
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

/// macOS: hit testing pass-through NSView subclass — wrapper의 빈 영역(자식 view 없는 곳) 클릭이
/// main browser webContents에 통과되도록 self일 때 nil 반환. 그러지 않으면 wrapper가 contentView
/// 전체를 덮어 main browser webContents의 사용자 입력을 가로채.
var g_view_host_wrapper_class: ?*anyopaque = null;

fn sujiViewHostWrapperHitTest(self: ?*anyopaque, _: ?*anyopaque, point: NSPoint) callconv(.c) ?*anyopaque {
    const NSView = getClass("NSView") orelse return null;
    const sel = objc.sel_registerName("hitTest:");
    const imp = objc.class_getMethodImplementation(NSView, sel);
    const f: *const fn (?*anyopaque, ?*anyopaque, NSPoint) callconv(.c) ?*anyopaque = @ptrCast(imp);
    const hit = f(self, @ptrCast(sel), point);
    if (hit == self) return null;
    return hit;
}

fn ensureSujiViewHostWrapperClass() ?*anyopaque {
    if (g_view_host_wrapper_class) |existing| return existing;
    const ns_view = getClass("NSView") orelse return null;
    const cls = objc.objc_allocateClassPair(ns_view, "SujiViewHostWrapper", 0) orelse {
        return getClass("SujiViewHostWrapper");
    };
    const sel = objc.sel_registerName("hitTest:");
    _ = objc.class_addMethod(cls, @ptrCast(sel), @ptrCast(&sujiViewHostWrapperHitTest), "@@:{CGPoint=dd}");
    objc.objc_registerClassPair(cls);
    g_view_host_wrapper_class = cls;
    return cls;
}

/// host용 view 합성 wrapper NSView를 lazy init. 첫 createView에서 호출되고 host_entry에
/// 영구 보관. contentView resize 따라 자동 리사이즈 (autoresizingMask). hitTest pass-through.
fn ensureViewWrapper(host_entry: *CefNative.BrowserEntry, ns_window: *anyopaque) ?*anyopaque {
    if (host_entry.view_wrapper) |w| return w;

    const content_view = msgSend(ns_window, "contentView") orelse return null;
    const cv_bounds = nsViewBounds(content_view);

    const cls = ensureSujiViewHostWrapperClass() orelse return null;
    const view_alloc = msgSend(cls, "alloc") orelse return null;
    const wrapper = msgSendNSRect(view_alloc, "initWithFrame:", cv_bounds) orelse return null;

    // NSViewWidthSizable(2) | NSViewHeightSizable(16) — host contentView resize 따라 자동.
    const sel_autoresize = objc.sel_registerName("setAutoresizingMask:");
    const f_auto: *const fn (?*anyopaque, ?*anyopaque, u64) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    f_auto(wrapper, @ptrCast(sel_autoresize), 18);

    msgSendVoid1(content_view, "addSubview:", wrapper);
    // alloc retain 정리 — superview retain만 남김. host close 시 contentView dealloc → wrapper dealloc.
    _ = msgSend(wrapper, "release");

    host_entry.view_wrapper = wrapper;
    return wrapper;
}

/// macOS: host contentView 안에 부착될 child NSView를 alloc + init + addSubview까지 처리.
/// `super`는 NSView (host의 contentView), `bounds`는 super 좌표계 top-left 기준.
/// **alloc retain 유지** — reorderSubview의 removeFromSuperview가 super의 retain을 풀 때
/// 우리 alloc retain만 남아 view가 alive. release 없이 super retain만 의존하면 reorder
/// 첫 단계에서 retain count 0 → dealloc → 다음 addSubview 시 dangling pointer crash.
/// destroyView가 마지막 release 호출하여 균형.
fn allocChildNSView(super: *anyopaque, bounds: window_mod.Bounds) ?*anyopaque {
    const NSViewClass = getClass("NSView") orelse return null;
    const view_alloc = msgSend(NSViewClass, "alloc") orelse return null;
    const view_rect = computeChildViewRect(super, bounds);
    const view = msgSendNSRect(view_alloc, "initWithFrame:", view_rect) orelse return null;
    msgSendVoid1(super, "addSubview:", view);
    return view;
}

/// top-left `bounds` → Cocoa bottom-left NSRect (super 좌표계).
/// super.bounds.height에서 y와 height만큼 빼서 Cocoa Y 계산.
fn computeChildViewRect(super: *anyopaque, bounds: window_mod.Bounds) NSRect {
    const super_bounds = nsViewBounds(super);
    const cocoa_y = super_bounds.height -
        @as(f64, @floatFromInt(bounds.y)) -
        @as(f64, @floatFromInt(bounds.height));
    return .{
        .x = @floatFromInt(bounds.x),
        .y = cocoa_y,
        .width = @floatFromInt(bounds.width),
        .height = @floatFromInt(bounds.height),
    };
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
