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
});

const builtin = @import("builtin");
const runtime = @import("runtime");

const is_macos = builtin.os.tag == .macos;
const is_linux = builtin.os.tag == .linux;

const objc = if (is_macos) @cImport({
    @cInclude("objc/runtime.h");
    @cInclude("objc/message.h");
}) else struct {};

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
pub const EmitCallback = *const fn (event: []const u8, data: []const u8) void;

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

var g_client: c.cef_client_t = undefined;
var g_devtools_client: c.cef_client_t = undefined;
var g_window: ?*anyopaque = null; // NSWindow 강한 참조 유지
var g_browser: ?*c.cef_browser_t = null; // 브라우저 참조 (이벤트 푸시용)
var g_devtools_open: bool = false;

/// 브라우저 창 생성
pub fn createBrowser(config: CefConfig) !void {
    initLifeSpanHandler();
    initKeyboardHandler();
    initClient(&g_client);

    // DevTools 전용 client (키보드만, IPC 무시)
    zeroCefStruct(c.cef_client_t, &g_devtools_client);
    initBaseRefCounted(&g_devtools_client.base);
    g_devtools_client.get_keyboard_handler = &getKeyboardHandler;

    // Window info
    var window_info: c.cef_window_info_t = undefined;
    zeroCefStruct(c.cef_window_info_t, &window_info);
    window_info.runtime_style = c.CEF_RUNTIME_STYLE_ALLOY;
    window_info.bounds = .{ .x = 0, .y = 0, .width = config.width, .height = config.height };
    initWindowInfo(&window_info, config);

    setCefString(&window_info.window_name, config.title);

    // URL
    var cef_url: c.cef_string_t = .{};
    if (config.url) |url| {
        setCefString(&cef_url, url);
    }

    // Browser settings
    var browser_settings: c.cef_browser_settings_t = undefined;
    zeroCefStruct(c.cef_browser_settings_t, &browser_settings);

    std.debug.print("[suji] CEF creating browser... size={d}\n", .{window_info.size});
    const browser = c.cef_browser_host_create_browser_sync(
        &window_info, &g_client, &cef_url, &browser_settings, null, null,
    );
    if (browser == null) {
        std.debug.print("[suji] CEF browser creation FAILED\n", .{});
        return error.BrowserCreationFailed;
    }
    std.debug.print("[suji] CEF browser created\n", .{});
}

/// 새 윈도우(브라우저) 생성 — PoC: 멀티 윈도우 검증용
/// 반환: CEF browser ID (실패 시 -1)
pub fn createNewWindow(title: [:0]const u8, width: i32, height: i32, url: ?[:0]const u8) i32 {
    // 새 client 할당 (힙)
    const client_ptr = std.heap.page_allocator.create(c.cef_client_t) catch return -1;
    initClient(client_ptr);

    var window_info: c.cef_window_info_t = undefined;
    zeroCefStruct(c.cef_window_info_t, &window_info);
    window_info.runtime_style = c.CEF_RUNTIME_STYLE_ALLOY;
    window_info.bounds = .{ .x = 0, .y = 0, .width = width, .height = height };
    initWindowInfo(&window_info, .{ .title = title, .width = width, .height = height });

    setCefString(&window_info.window_name, title);

    var cef_url: c.cef_string_t = .{};
    if (url) |u| {
        setCefString(&cef_url, u);
    }

    var browser_settings: c.cef_browser_settings_t = undefined;
    zeroCefStruct(c.cef_browser_settings_t, &browser_settings);

    std.debug.print("[suji] Creating new window: title={s} size={d}x{d}\n", .{ title, width, height });
    const browser = c.cef_browser_host_create_browser_sync(
        &window_info, client_ptr, &cef_url, &browser_settings, null, null,
    );
    if (browser == null) {
        std.debug.print("[suji] New window creation FAILED\n", .{});
        return -1;
    }
    const br: *c.cef_browser_t = @ptrCast(browser);
    const browser_id = br.get_identifier.?(br);
    std.debug.print("[suji] New window created: browser_id={d}\n", .{browser_id});
    return browser_id;
}

/// 런타임 URL 네비게이션
pub fn navigate(url: [:0]const u8) void {
    const browser = g_browser orelse return;
    const frame = asPtr(c.cef_frame_t, browser.get_main_frame.?(browser)) orelse return;
    var cef_url: c.cef_string_t = .{};
    setCefString(&cef_url, url);
    frame.load_url.?(frame, &cef_url);
}

/// 메인 프로세스에서 렌더러의 JS 실행 (EventBus → JS __dispatch__ 용)
pub fn evalJs(js: [:0]const u8) void {
    const browser = g_browser orelse return;
    const frame = asPtr(c.cef_frame_t, browser.get_main_frame.?(browser)) orelse return;
    var code: c.cef_string_t = .{};
    setCefString(&code, js);
    var url: c.cef_string_t = .{};
    setCefString(&url, "");
    frame.execute_java_script.?(frame, &code, &url, 0);
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

    // GPU 활성화: CEF가 `@executable_path/libEGL.dylib`, `libGLESv2.dylib` 등을 찾는데,
    // build.zig의 post-install이 zig-out/bin/ 옆에 절대 경로 심링크를 배치하고,
    // .app 번들은 bundle_macos.zig의 symlinkGpuLibs가 Contents/MacOS/ 옆에 배치한다.
    // WebGL/CSS 애니메이션/비디오 가속이 정상 동작.
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
    client_ptr.on_process_message_received = &onBrowserProcessMessageReceived;
}

fn getKeyboardHandler(_: ?*c._cef_client_t) callconv(.c) ?*c._cef_keyboard_handler_t {
    return &g_keyboard_handler;
}

fn getLifeSpanHandler(_: ?*c._cef_client_t) callconv(.c) ?*c._cef_life_span_handler_t {
    return &g_life_span_handler;
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
    _: ?*c._cef_browser_t,
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

    // std.debug.print("[suji] IPC invoke: seq={d} channel={s}\n", .{ seq_id, channel });

    // 백엔드 호출
    var response_buf: [16384]u8 = undefined;
    var success: bool = false;
    var result: []const u8 = "\"no handler\"";

    if (g_invoke_callback) |cb| {
        if (cb(channel, data, &response_buf)) |resp| {
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

    std.debug.print("[suji] IPC emit: event={s}\n", .{event});

    if (g_emit_callback) |cb| {
        cb(event, data);
    }
    return 1;
}

// ============================================
// CEF Life Span Handler
// ============================================

var g_life_span_handler: c.cef_life_span_handler_t = undefined;

fn initLifeSpanHandler() void {
    zeroCefStruct(c.cef_life_span_handler_t, &g_life_span_handler);
    initBaseRefCounted(&g_life_span_handler.base);
    g_life_span_handler.on_after_created = &onAfterCreated;
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

fn onBeforeClose(_: ?*c._cef_life_span_handler_t, browser: ?*c._cef_browser_t) callconv(.c) void {
    if (browser) |br| {
        if (g_browser) |main| {
            if (br.get_identifier.?(br) != main.get_identifier.?(main)) {
                return; // 서브 브라우저 (DevTools 등)
            }
        }
    }
    c.cef_quit_message_loop();
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

    // F12 / Cmd+Shift+I / Cmd+Option+I — DevTools 토글
    const is_devtools_key = (key == 123) or (cmd and key == 'I' and (shift or alt));
    if (is_devtools_key) {
        // 항상 메인 브라우저 기준으로 토글
        if (g_browser) |main_br| {
            toggleDevTools(main_br);
        }
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

    // Cmd+W — 창 닫기
    if (key == 'W' and !shift) {
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
        \\  s.emit = function(event, data) {
        \\    return raw_emit(event, JSON.stringify(data || {}));
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
        \\})();
    ;
    var code_str: c.cef_string_t = .{};
    setCefString(&code_str, js_code);
    var empty_url: c.cef_string_t = .{};
    setCefString(&empty_url, "");
    var retval: ?*c.cef_v8_value_t = null;
    var exception: ?*c.cef_v8_exception_t = null;
    _ = ctx.eval.?(ctx, &code_str, &empty_url, 0, &retval, &exception);
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

/// emit(event, data) → void
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

/// 플랫폼별 윈도우 초기화
const initWindowInfo = if (is_macos) struct {
    fn call(window_info: *c.cef_window_info_t, config: CefConfig) void {
        const content_view = createMacWindow(config.title, config.width, config.height);
        if (content_view) |cv| {
            window_info.parent_view = cv;
        }
    }
}.call else struct {
    fn call(_: *c.cef_window_info_t, _: CefConfig) void {
        // Linux/Windows: CEF 자체 윈도우 생성
    }
}.call;

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
    // _setHandlingSendEvent: 도 추가
    const setSel = objc.sel_registerName("_setHandlingSendEvent:");
    _ = objc.class_addMethod(
        @ptrCast(cls),
        setSel,
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
