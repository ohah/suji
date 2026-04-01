const std = @import("std");

pub const c = @cImport({
    @cDefine("CEF_API_VERSION", "999999");
    @cInclude("include/capi/cef_app_capi.h");
    @cInclude("include/capi/cef_browser_capi.h");
    @cInclude("include/capi/cef_client_capi.h");
    @cInclude("include/capi/cef_life_span_handler_capi.h");
});

const objc = @cImport({
    @cInclude("objc/runtime.h");
    @cInclude("objc/message.h");
});

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

var g_app: c.cef_app_t = undefined;
var g_app_initialized: bool = false;

/// CEF 서브프로세스 실행 (main 함수 초입에 호출)
/// 서브프로세스면 exit, 메인 프로세스면 반환
pub fn executeSubprocess() void {
    _ = c.cef_api_hash(c.CEF_API_VERSION, 0);
    if (!g_app_initialized) {
        initApp(&g_app);
        g_app_initialized = true;
    }

    var main_args: c.cef_main_args_t = .{
        .argc = @intCast(std.os.argv.len),
        .argv = @ptrCast(std.os.argv.ptr),
    };

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

    var main_args: c.cef_main_args_t = .{
        .argc = @intCast(std.os.argv.len),
        .argv = @ptrCast(std.os.argv.ptr),
    };

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
    if (std.fs.selfExePath(&exe_buf)) |ep| {
        setCefString(&settings.browser_subprocess_path, ep);
    } else |_| {}

    // CEF 경로 설정
    // TODO: macOS arm64 하드코딩 — 크로스 플랫폼 지원 시 OS/arch 감지로 변경
    const home = std.posix.getenv("HOME") orelse "/tmp";
    var fw_buf: [1024]u8 = undefined;
    var res_buf: [1024]u8 = undefined;
    var loc_buf: [1024]u8 = undefined;
    var cache_buf: [1024]u8 = undefined;

    setCefString(&settings.framework_dir_path, std.fmt.bufPrint(&fw_buf, "{s}/.suji/cef/macos-arm64/Release/Chromium Embedded Framework.framework", .{home}) catch return error.PathTooLong);
    setCefString(&settings.resources_dir_path, std.fmt.bufPrint(&res_buf, "{s}/.suji/cef/macos-arm64/Resources", .{home}) catch return error.PathTooLong);
    setCefString(&settings.locales_dir_path, std.fmt.bufPrint(&loc_buf, "{s}/.suji/cef/macos-arm64/Resources/locales", .{home}) catch return error.PathTooLong);
    setCefString(&settings.root_cache_path, std.fmt.bufPrint(&cache_buf, "{s}/.suji/cef/cache", .{home}) catch return error.PathTooLong);

    // macOS: NSApplication 초기화 (cef_initialize 전에 필수)
    initNSApp();

    std.debug.print("[suji] CEF initializing...\n", .{});
    if (c.cef_initialize(&main_args, &settings, &g_app, null) != 1) {
        return error.CefInitFailed;
    }
    std.debug.print("[suji] CEF initialized\n", .{});
}

var g_client: c.cef_client_t = undefined;
var g_window: ?*anyopaque = null; // NSWindow 강한 참조 유지

/// 브라우저 창 생성
pub fn createBrowser(config: CefConfig) !void {
    initLifeSpanHandler();
    initClient(&g_client);

    // NSWindow 생성
    const content_view = createMacWindow(config.title, config.width, config.height) orelse return error.WindowCreationFailed;

    // Window info
    var window_info: c.cef_window_info_t = undefined;
    zeroCefStruct(c.cef_window_info_t, &window_info);
    window_info.parent_view = content_view;
    window_info.runtime_style = c.CEF_RUNTIME_STYLE_ALLOY;
    window_info.bounds = .{ .x = 0, .y = 0, .width = config.width, .height = config.height };

    setCefString(&window_info.window_name, config.title);

    // URL
    var cef_url: c.cef_string_t = .{};
    if (config.url) |url| {
        setCefString(&cef_url, url);
    }

    // Browser settings
    var browser_settings: c.cef_browser_settings_t = undefined;
    zeroCefStruct(c.cef_browser_settings_t, &browser_settings);

    std.debug.print("[suji] CEF creating browser... size={d} parent={?}\n", .{ window_info.size, window_info.parent_view });
    const browser = c.cef_browser_host_create_browser_sync(
        &window_info, &g_client, &cef_url, &browser_settings, null, null,
    );
    if (browser == null) {
        std.debug.print("[suji] CEF browser creation FAILED\n", .{});
        return error.BrowserCreationFailed;
    }
    std.debug.print("[suji] CEF browser created\n", .{});
}

/// 메시지 루프 실행 (블로킹)
pub fn run() void {
    activateNSApp();
    std.debug.print("[suji] CEF running\n", .{});
    c.cef_run_message_loop();
}

/// CEF 종료
pub fn shutdown() void {
    c.cef_shutdown();
    std.debug.print("[suji] CEF shutdown\n", .{});
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
// CEF App
// ============================================

fn initApp(app: *c.cef_app_t) void {
    zeroCefStruct(c.cef_app_t, app);
    initBaseRefCounted(&app.base);
}

// ============================================
// CEF Client
// ============================================

fn initClient(client_ptr: *c.cef_client_t) void {
    zeroCefStruct(c.cef_client_t, client_ptr);
    initBaseRefCounted(&client_ptr.base);
    client_ptr.get_life_span_handler = &getLifeSpanHandler;
    client_ptr.on_process_message_received = &onProcessMessageReceived;
}

fn getLifeSpanHandler(_: ?*c._cef_client_t) callconv(.c) ?*c._cef_life_span_handler_t {
    return &g_life_span_handler;
}

fn onProcessMessageReceived(
    _: ?*c._cef_client_t,
    _: ?*c._cef_browser_t,
    _: ?*c._cef_frame_t,
    _: c.cef_process_id_t,
    _: ?*c._cef_process_message_t,
) callconv(.c) i32 {
    return 0;
}

// ============================================
// CEF Life Span Handler
// ============================================

var g_life_span_handler: c.cef_life_span_handler_t = undefined;

fn initLifeSpanHandler() void {
    zeroCefStruct(c.cef_life_span_handler_t, &g_life_span_handler);
    initBaseRefCounted(&g_life_span_handler.base);
    g_life_span_handler.on_before_close = &onBeforeClose;
}

fn onBeforeClose(_: ?*c._cef_life_span_handler_t, _: ?*c._cef_browser_t) callconv(.c) void {
    c.cef_quit_message_loop();
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
    const app = msgSend(cls, "sharedApplication") orelse return;
    const sel = objc.sel_registerName("setActivationPolicy:");
    const func: *const fn (?*anyopaque, ?*anyopaque, i64) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    func(app, @ptrCast(sel), 0);
}

fn activateNSApp() void {
    const cls = getClass("NSApplication") orelse return;
    const app = msgSend(cls, "sharedApplication") orelse return;

    _ = msgSend(app, "finishLaunching");

    const sel = objc.sel_registerName("activateIgnoringOtherApps:");
    const func: *const fn (?*anyopaque, ?*anyopaque, u8) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    func(app, @ptrCast(sel), 1);
}

fn createMacWindow(title: [:0]const u8, width: i32, height: i32) ?*anyopaque {
    const NSWindow = getClass("NSWindow") orelse return null;
    const window_alloc = msgSend(NSWindow, "alloc") orelse return null;

    const NSRect = extern struct { x: f64, y: f64, w: f64, h: f64 };
    const initSel = objc.sel_registerName("initWithContentRect:styleMask:backing:defer:");
    const initFn: *const fn (?*anyopaque, ?*anyopaque, NSRect, u64, u64, u8) callconv(.c) ?*anyopaque = @ptrCast(&objc.objc_msgSend);
    const style: u64 = 1 | 2 | 4 | 8; // titled|closable|miniaturizable|resizable
    const window = initFn(window_alloc, @ptrCast(initSel), .{
        .x = 200, .y = 200,
        .w = @floatFromInt(width), .h = @floatFromInt(height),
    }, style, 2, 0) orelse return null;

    // setTitle
    const NSString = getClass("NSString") orelse return null;
    const strSel = objc.sel_registerName("stringWithUTF8String:");
    const strFn: *const fn (?*anyopaque, ?*anyopaque, [*:0]const u8) callconv(.c) ?*anyopaque = @ptrCast(&objc.objc_msgSend);
    const ns_title = strFn(NSString, @ptrCast(strSel), title.ptr);
    const setTitleSel = objc.sel_registerName("setTitle:");
    const setTitleFn: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    setTitleFn(window, @ptrCast(setTitleSel), ns_title);

    const contentView = msgSend(window, "contentView") orelse return null;
    g_window = window; // NSWindow 참조 유지

    // makeKeyAndOrderFront
    const makeKeySel = objc.sel_registerName("makeKeyAndOrderFront:");
    const makeKeyFn: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    makeKeyFn(window, @ptrCast(makeKeySel), null);

    return contentView;
}
