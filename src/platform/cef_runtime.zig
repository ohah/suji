//! CEF process runtime/init glue — cef.zig 에서 분리(동작 무변경).
//! `CefConfig`, subprocess dispatch, and process-wide `cef_initialize` live here.
const std = @import("std");
const builtin = @import("builtin");
const runtime = @import("runtime");
const cef = @import("cef.zig");
const cef_app = @import("cef_app.zig");
const cef_app_handler = @import("cef_app_handler.zig");
const cef_mac_app_menu = @import("cef_mac_app_menu.zig");
const cef_scheme = @import("cef_scheme.zig");

const c = cef.c;
const zeroCefStruct = cef.zeroCefStruct;
const setCefString = cef.setCefString;

const is_macos = builtin.os.tag == .macos;

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

var g_app: c.cef_app_t = undefined;
var g_app_initialized: bool = false;

/// Zig 0.16: std.os.argv 제거 → main이 runtime.args_vector에 저장한 값을
/// CEF 네이티브 포맷으로 변환한다.
fn makeMainArgs() c.cef_main_args_t {
    if (comptime builtin.os.tag == .windows) {
        const Instance = @TypeOf(@as(c.cef_main_args_t, undefined).instance);
        const k32 = struct {
            extern "kernel32" fn GetModuleHandleW(lpModuleName: ?[*:0]const u16) callconv(.winapi) Instance;
        };
        return .{ .instance = k32.GetModuleHandleW(null) };
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
        cef_app_handler.initApp(&g_app);
        g_app_initialized = true;
    }

    var main_args = makeMainArgs();

    const code = c.cef_execute_process(&main_args, &g_app, null);
    if (code >= 0) {
        std.process.exit(@intCast(code));
    }
}

pub fn initialize(config: CefConfig) !void {
    if (!g_app_initialized) {
        _ = c.cef_api_hash(c.CEF_API_VERSION, 0);
        cef_app_handler.initApp(&g_app);
        g_app_initialized = true;
    }

    var main_args = makeMainArgs();

    var settings: c.cef_settings_t = undefined;
    zeroCefStruct(c.cef_settings_t, &settings);
    settings.log_severity = c.LOGSEVERITY_WARNING;
    settings.no_sandbox = 1;

    if (runtime.env("SUJI_CEF_LOG")) |path| {
        if (path.len > 0) {
            setCefString(&settings.log_file, path);
            settings.log_severity = c.LOGSEVERITY_INFO;
        }
    }

    if (config.remote_debugging_port > 0) {
        settings.remote_debugging_port = config.remote_debugging_port;
    } else if (config.debug) {
        settings.remote_debugging_port = 9222;
    }

    // Subprocess path — exe 경로는 아래 번들 CEF 경로 계산에도 쓰므로 보관.
    var exe_buf: [1024]u8 = undefined;
    const exe_path: ?[]const u8 = if (std.process.executablePath(runtime.io, &exe_buf)) |exe_len| exe_buf[0..exe_len] else |_| null;
    // 번들(.app) macOS 에선 browser_subprocess_path 를 비운다 → CEF 가
    // Contents/Frameworks/<name> Helper*.app 을 자동으로 helper 로 쓴다(CEF 표준). self(메인
    // exe)를 지정하면 macOS 가 메인 exe 를 helper 로 띄우려다 Hardened Runtime + 서명 검증
    // (process_requirement)에서 -67030 으로 실패 → helper 미생성 → 렌더가 비어버린다.
    // dev(헬퍼 번들 없음)에선 self 가 subprocess.
    const is_bundled_macos = is_macos and (if (exe_path) |ep| std.mem.indexOf(u8, ep, "/Contents/MacOS/") != null else false);
    if (exe_path) |ep| {
        if (!is_bundled_macos) setCefString(&settings.browser_subprocess_path, ep);
    }

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
    var user_data_buf: [1024]u8 = undefined;
    var cache_buf: [1024]u8 = undefined;

    // 프로덕션 .app 번들 감지 — exe 가 <app>/Contents/MacOS/<name> 면 번들 내부 CEF 를 쓴다.
    // dev 경로(~/.suji/cef)를 프로덕션 .app 에 남기면 그 경로가 없는 다른 맥에서 cef_initialize
    // 가 프레임워크/리소스를 못 찾아 실패 → 앱이 즉시 종료한다. 번들이면 exe 기준으로 계산.
    const bundle_fw: ?[]const u8 = if (is_macos) blk: {
        const ep = exe_path orelse break :blk null;
        const idx = std.mem.lastIndexOf(u8, ep, "/Contents/MacOS/") orelse break :blk null;
        break :blk std.fmt.bufPrint(&fw_buf, "{s}/Contents/Frameworks/Chromium Embedded Framework.framework", .{ep[0..idx]}) catch return error.PathTooLong;
    } else null;

    if (is_macos) {
        if (bundle_fw) |fw| {
            setCefString(&settings.framework_dir_path, fw);
        } else {
            setCefString(&settings.framework_dir_path, std.fmt.bufPrint(&fw_buf, "{s}/.suji/cef/{s}/Release/Chromium Embedded Framework.framework", .{ home, cef_platform }) catch return error.PathTooLong);
        }
    }
    // Windows: resources_dir_path / locales_dir_path 를 명시하면 (backslash
    // 든 mixed-slash 든) cef_initialize 가 0 반환 + log_file 미오픈 (원인 미상,
    // CEF 자체가 로그를 못 씀 — 실증: 0 export 인 줄 알았던 libnode.dll 진단처럼
    // 도구 한계가 아닌 진짜 CEF 내부 거부). 대신 CEF Windows 가 .exe 옆 dir
    // 에서 *.pak/icudtl.dat/locales/ 를 자동 발견 — build.zig
    // addInstallCefRuntimeStep 이 zig-out/bin/ 으로 복사하고 .github/workflows/
    // e2e.yml `Verify CEF runtime layout` step 이 4개 asset+locales/ 존재 보장.
    // → 자동 발견 경로가 build/배포 단계의 guard 로 covered.
    // 만약 suji.exe 를 install 폴더가 아닌 다른 위치로 옮겨 실행하면 fail.
    if (comptime builtin.os.tag != .windows) {
        var res_buf: [1024]u8 = undefined;
        var loc_buf: [1024]u8 = undefined;
        if (bundle_fw) |fw| {
            // 번들: .pak/icudtl.dat 는 framework/Resources/, 로케일은 그 안 <locale>.lproj/.
            // (locales_dir_path 는 macOS 에서 무시되지만 유효 경로로 둔다.)
            setCefString(&settings.resources_dir_path, std.fmt.bufPrint(&res_buf, "{s}/Resources", .{fw}) catch return error.PathTooLong);
            setCefString(&settings.locales_dir_path, std.fmt.bufPrint(&loc_buf, "{s}/Resources", .{fw}) catch return error.PathTooLong);
        } else {
            setCefString(&settings.resources_dir_path, std.fmt.bufPrint(&res_buf, "{s}/.suji/cef/{s}/Resources", .{ home, cef_platform }) catch return error.PathTooLong);
            setCefString(&settings.locales_dir_path, std.fmt.bufPrint(&loc_buf, "{s}/.suji/cef/{s}/Resources/locales", .{ home, cef_platform }) catch return error.PathTooLong);
        }
    }
    // OS 표준 앱별 user-data 디렉토리. Electron app.getPath('userData') 동등:
    //   macOS:   ~/Library/Application Support/<app_name>
    //   Linux:   $XDG_CONFIG_HOME or ~/.config/<app_name>
    //   Windows: %APPDATA%/<app_name>  (HOME 대용으로 USERPROFILE 사용 X — runtime.env가 emit)
    // 한 system에 여러 Suji 앱 설치 시 cookie/localStorage/IndexedDB 자동 격리.
    const user_data_path = cef_app.buildAppUserDataPath(&user_data_buf, home, config.app_name) orelse return error.PathTooLong;
    const cache_path = cef_app.buildAppCachePath(&cache_buf, home, config.app_name) orelse return error.PathTooLong;
    std.Io.Dir.createDirPath(.cwd(), runtime.io, cache_path) catch |err| {
        std.debug.print("[suji] CEF cache dir create failed: {s} ({s})\n", .{ cache_path, @errorName(err) });
    };
    setCefString(&settings.cache_path, cache_path);
    setCefString(&settings.root_cache_path, user_data_path);

    // macOS: NSApplication 초기화 (cef_initialize 전에 필수)
    if (comptime is_macos) cef_mac_app_menu.initNSApp();

    std.debug.print("[suji] CEF initializing...\n", .{});
    if (c.cef_initialize(&main_args, &settings, &g_app, null) != 1) {
        return error.CefInitFailed;
    }
    std.debug.print("[suji] CEF initialized\n", .{});

    // 커스텀 프로토콜 핸들러 등록 (dist 경로가 설정된 경우)
    if (cef_scheme.hasDistPath()) {
        cef_scheme.registerSchemeHandlerFactory();
    }
}
