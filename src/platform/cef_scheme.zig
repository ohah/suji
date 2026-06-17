//! CEF custom scheme/resource handler — cef.zig 에서 분리(동작 무변경).
//! `suji://app/*` 정적 파일 서빙과 suji:// 응답 보안 헤더/CSP를 담당한다.
const std = @import("std");
const runtime = @import("runtime");
const cef_scheme_resource = @import("cef_scheme_resource.zig");
const cef_scheme_security = @import("cef_scheme_security.zig");
const cef = @import("cef.zig");

const c = cef.c;
const zeroCefStruct = cef.zeroCefStruct;
const initBaseRefCounted = cef.initBaseRefCounted;
const setCefString = cef.setCefString;
const cefUserfreeToUtf8 = cef.cefUserfreeToUtf8;

pub const buildDefaultCsp = cef_scheme_security.buildDefaultCsp;
pub const setCspValue = cef_scheme_security.setCspValue;

/// dist 경로 설정 (main.zig에서 호출)
var g_dist_path: [1024]u8 = undefined;
var g_dist_path_len: usize = 0;

pub fn setDistPath(path: []const u8) void {
    const len = @min(path.len, g_dist_path.len);
    @memcpy(g_dist_path[0..len], path[0..len]);
    g_dist_path_len = len;
}

pub fn hasDistPath() bool {
    return g_dist_path_len > 0;
}

fn getDistPath() []const u8 {
    return g_dist_path[0..g_dist_path_len];
}

/// on_register_custom_schemes — "suji" 스킴 등록 (모든 프로세스에서 호출됨)
pub fn onRegisterCustomSchemes(
    _: ?*c._cef_app_t,
    registrar: ?*c._cef_scheme_registrar_t,
) callconv(.c) void {
    const reg = registrar orelse return;
    var scheme_name: c.cef_string_t = .{};
    setCefString(&scheme_name, "suji");
    // STANDARD + SECURE + CORS_ENABLED + FETCH_ENABLED + CSP_BYPASSING.
    // LOCAL 은 절대 넣지 않는다 — LOCAL 은 스킴에 file:// 동급 보안규칙을 적용해
    // origin 을 opaque('null')로 만든다. 그러면 suji://app/index.html 이 같은 출처의
    // /assets/*.js|css 를 불러올 때 origin 'null' → cross-origin 으로 취급돼 CORS 차단
    // (No 'Access-Control-Allow-Origin') → 스크립트 실행 0 → 흰 화면. STANDARD 만으로는
    // 부족하고, LOCAL 이 있으면 STANDARD 라도 file 취급된다. Electron/Tauri 의 앱 스킴도
    // standard+secure+corsEnabled 만 쓰고 local 은 쓰지 않는 이유.
    const options = c.CEF_SCHEME_OPTION_STANDARD |
        c.CEF_SCHEME_OPTION_SECURE |
        c.CEF_SCHEME_OPTION_CORS_ENABLED |
        c.CEF_SCHEME_OPTION_FETCH_ENABLED |
        c.CEF_SCHEME_OPTION_CSP_BYPASSING;
    const result = reg.add_custom_scheme.?(reg, &scheme_name, options);
    std.debug.print("[suji] register scheme 'suji': {d}\n", .{result});

    // suji-video — 로컬 영상 파일 전용 스킴(앱 페이지 suji 와 분리). 동일 옵션.
    var video_scheme: c.cef_string_t = .{};
    setCefString(&video_scheme, "suji-video");
    const vresult = reg.add_custom_scheme.?(reg, &video_scheme, options);
    std.debug.print("[suji] register scheme 'suji-video': {d}\n", .{vresult});
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

    // suji-video://localhost — 로컬 영상 파일 전용 factory.
    var video_scheme: c.cef_string_t = .{};
    setCefString(&video_scheme, "suji-video");
    var video_domain: c.cef_string_t = .{};
    setCefString(&video_domain, "localhost");
    initVideoSchemeHandlerFactory();
    const vresult = c.cef_register_scheme_handler_factory(&video_scheme, &video_domain, &g_video_factory);
    std.debug.print("[suji] register suji-video factory: {d}\n", .{vresult});
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

    // 파일 내용 읽기 (최대 64MB). readFileAlloc 로 정확한 길이의 owned slice 확보
    // (이전 `file.reader(io, &[0]u8)`+readSliceShort 는 zero-length reader 버퍼).
    const io = runtime.io;
    const max_size: usize = 64 * 1024 * 1024;
    const data = std.Io.Dir.cwd().readFileAlloc(io, file_path, std.heap.page_allocator, .limited(max_size)) catch {
        std.debug.print("[suji] scheme 404/read-fail: {s}\n", .{file_path});
        return cef_scheme_resource.createErrorHandler(404);
    };

    // ResourceHandler 생성 (앱 자산 — same-origin 이라 cors 불필요)
    return cef_scheme_resource.createResourceHandler(data, path, false) orelse {
        std.heap.page_allocator.free(data);
        return null;
    };
}

// --- suji-video:// 로컬 영상 파일 전용 스킴 (suji://app 앱 페이지와 분리) ---
// `suji-video://localhost<절대경로>` → 디스크 파일(QA 녹화 영상 등) 서빙. Range/skip 은
// cef_scheme_resource 가 처리. webview 가 file:// 을 못 쓰는 대신 등록된 suji-video 스킴으로
// 로드한다. 보안상 SUJI_ALLOW_FILE_ACCESS(=suji.json app.allowFileAccess) 가 켜진 경우에만 허용.
var g_video_factory: c.cef_scheme_handler_factory_t = undefined;
var g_video_factory_initialized: bool = false;

fn initVideoSchemeHandlerFactory() void {
    if (g_video_factory_initialized) return;
    zeroCefStruct(c.cef_scheme_handler_factory_t, &g_video_factory);
    initBaseRefCounted(&g_video_factory.base);
    g_video_factory.create = &videoSchemeFactoryCreate;
    g_video_factory_initialized = true;
}

fn videoSchemeFactoryCreate(
    _: ?*c._cef_scheme_handler_factory_t,
    _: ?*c._cef_browser_t,
    _: ?*c._cef_frame_t,
    _: [*c]const c.cef_string_t,
    request: ?*c._cef_request_t,
) callconv(.c) ?*c._cef_resource_handler_t {
    const req = request orelse return null;
    if (runtime.env("SUJI_ALLOW_FILE_ACCESS") == null)
        return cef_scheme_resource.createErrorHandler(403);

    const url_userfree = req.get_url.?(req);
    var url_buf: [2048]u8 = undefined;
    const url = cefUserfreeToUtf8(url_userfree, &url_buf);

    // suji-video://localhost<절대경로> 에서 절대경로 추출.
    const MARK = "suji-video://localhost";
    const idx = std.mem.indexOf(u8, url, MARK) orelse return cef_scheme_resource.createErrorHandler(404);
    const abspath = url[idx + MARK.len ..];
    if (abspath.len == 0 or abspath[0] != '/') return cef_scheme_resource.createErrorHandler(404);

    const max: usize = 512 * 1024 * 1024;
    const data = std.Io.Dir.cwd().readFileAlloc(runtime.io, abspath, std.heap.page_allocator, .limited(max)) catch {
        std.debug.print("[suji] suji-video 404: {s}\n", .{abspath});
        return cef_scheme_resource.createErrorHandler(404);
    };
    // cross-origin fetch(내보내기 zip) 허용 — suji://app 페이지가 fetch 하므로 cors=true.
    return cef_scheme_resource.createResourceHandler(data, abspath, true) orelse {
        std.heap.page_allocator.free(data);
        return null;
    };
}
