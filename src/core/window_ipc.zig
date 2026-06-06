//! Window IPC 커맨드 핸들러 — 프론트엔드가 `__core__:create_window` 등으로 보낸
//! 요청을 WindowManager 경로로 라우팅한다.
//!
//! main.zig가 JSON을 파싱해서 CreateWindowReq를 구성한 뒤 handleCreateWindow를 호출.
//! 파싱과 WM 호출을 분리해 이 모듈은 CEF 없이 단위 테스트 가능.

const std = @import("std");
const window = @import("window");
const util = @import("util");

// ============================================
// Deferred response 콜백 (issue #16, Promise pattern)
// ============================================
//
// 일부 핸들러(print_to_pdf/capture_page)는 CDP 콜백 완료 후에야 결과를 안다.
// `g_defer_response_cb` 가 set 돼 있으면 핸들러가 (kind, path) 키로 응답을 보류하고
// (cef.zig pending registry 에 저장) CDP 콜백 시 송신. 미설정(테스트/모바일)
// 이면 기존 ack-only 동작 fallback. main.zig 가 `cef.cefDeferResponse` 주입.
//
// DeferKind 는 이 CEF-free 모듈에 선언 — cef.zig 가 `window_ipc.DeferKind` 로
// 참조(역방향 import 금지, 단위 테스트가 CEF 없이 가능해야 함). path 단독 매칭은
// print/capture 가 같은 경로일 때 교차충돌(PR #54 review #3) → kind 로 discriminate.
pub const DeferKind = enum { print, capture };
pub const DeferResponseFn = *const fn (kind: DeferKind, path: []const u8) bool;
pub var g_defer_response_cb: ?DeferResponseFn = null;

/// Phase 2.5 — 요청 JSON에 sender 컨텍스트 자동 주입.
///   - `__window`: 항상 (sender 창의 WM id)
///   - `__window_name`: name이 있고 JSON-safe할 때만
///   - `__window_url`: url이 있을 때 (escape 후)
///   - `__window_main_frame`: optional (null 아니면 boolean)
///
/// 동작 규칙:
///   - 이미 `"__window"` 필드가 있으면 원본 반환 (cross-hop 요청 재태깅 방지).
///   - `{...}` 로 끝나지 않는 입력(배열/프리미티브/공백 끝)은 원본 반환.
///   - JSON-unsafe name (`"`, `\`, control < 0x20)은 **name만 생략** (id는 주입).
///   - URL은 `escapeJsonChars`로 `"`/`\\` 이스케이프 + control drop. 버퍼 부족 시 url 필드 생략.
///   - out_buf 부족 시 null 반환 → caller는 원본 사용.
pub const InjectFields = struct {
    window_id: u32,
    window_name: ?[]const u8 = null,
    window_url: ?[]const u8 = null,
    /// null이면 필드 생략. true/false면 그대로 emit.
    is_main_frame: ?bool = null,
};

pub fn injectWindowField(
    src: []const u8,
    fields: InjectFields,
    out_buf: []u8,
) ?[]const u8 {
    // 이미 박혀있으면 no-op
    if (std.mem.indexOf(u8, src, "\"__window\"") != null) return src;

    // 끝에서 공백 스킵해 닫는 `}` 위치 찾기
    var end = src.len;
    while (end > 0 and std.ascii.isWhitespace(src[end - 1])) : (end -= 1) {}
    if (end == 0 or src[end - 1] != '}') return src;

    const body = src[0 .. end - 1];
    // 빈 객체 `{}`인지 — body가 `{` 이후 공백만 있는지 — separator 선택용
    const inner_trimmed = std.mem.trim(u8, body[1..], &std.ascii.whitespace);
    const sep: []const u8 = if (inner_trimmed.len == 0) "" else ",";

    // name이 JSON-safe하면 주입, 아니면 생략.
    const safe_name: ?[]const u8 = if (fields.window_name) |n|
        (if (window.isJsonSafeChars(n)) n else null)
    else
        null;

    // URL은 escape 처리. 실패(버퍼 부족)면 URL 필드 생략.
    var url_buf: [2048]u8 = undefined;
    const escaped_url: ?[]const u8 = blk: {
        const raw = fields.window_url orelse break :blk null;
        const n = window.escapeJsonChars(raw, &url_buf);
        if (n == 0 and raw.len > 0) break :blk null;
        break :blk url_buf[0..n];
    };

    // 점진 빌드 — 분기 폭발 회피. fmt.bufPrint(out_buf, "...", .{...}) 결과 슬라이스로 진행.
    var w = std.Io.Writer.fixed(out_buf);
    w.writeAll(body) catch return null;
    w.writeAll(sep) catch return null;
    w.print("\"__window\":{d}", .{fields.window_id}) catch return null;
    if (safe_name) |n| {
        w.print(",\"__window_name\":\"{s}\"", .{n}) catch return null;
    }
    if (escaped_url) |u| {
        w.print(",\"__window_url\":\"{s}\"", .{u}) catch return null;
    }
    if (fields.is_main_frame) |b| {
        w.print(",\"__window_main_frame\":{}", .{b}) catch return null;
    }
    w.writeByte('}') catch return null;
    return w.buffered();
}

// wire 안전성 guard는 window.isJsonSafeChars 사용 (동일 정의).

/// 프론트엔드/백엔드가 `__core__:create_window`로 보내는 요청.
/// suji.json 시작 창과 동일한 Phase 3 옵션 셋을 평면(flat) 키로 받는다.
/// JSON 키는 schema.json과 동일한 camelCase (`alwaysOnTop`, `minWidth` 등).
pub const CreateWindowReq = struct {
    title: []const u8 = "New Window",
    url: ?[]const u8 = null,
    /// name 지정 시 WM singleton 정책 (중복 이름이면 기존 id 반환).
    name: ?[]const u8 = null,
    width: u32 = 800,
    height: u32 = 600,
    /// 초기 위치 (px). 0이면 OS cascade 자동 배치 (config 시작 창과 동일 정책).
    x: i32 = 0,
    y: i32 = 0,
    /// 부모 창 id 직접 지정. parent_name보다 우선.
    parent_id: ?u32 = null,
    /// 부모 창 이름. handleCreateWindow에서 wm.fromName으로 resolve.
    parent_name: ?[]const u8 = null,
    // ── 외형 (Appearance) ──
    frame: bool = true,
    transparent: bool = false,
    background_color: ?[]const u8 = null,
    title_bar_style: window.TitleBarStyle = .default,
    // ── 제약 (Constraints) ──
    resizable: bool = true,
    always_on_top: bool = false,
    min_width: u32 = 0,
    min_height: u32 = 0,
    max_width: u32 = 0,
    max_height: u32 = 0,
    fullscreen: bool = false,
};

/// 평면 JSON에서 `x/y/width/height` 4 필드를 Bounds로 복원. 키 없는 필드는 default(0).
/// CreateViewReq, SetViewBoundsReq처럼 width/height의 default가 0인 경우에만 사용 적합 —
/// CreateWindowReq는 default 800/600이라 별도 처리(키 유무 보존 필요).
pub fn parseBoundsFromJson(json: []const u8) window.Bounds {
    var b: window.Bounds = .{ .width = 0, .height = 0 };
    if (util.extractJsonInt(json, "x")) |n| b.x = util.clampI32(n);
    if (util.extractJsonInt(json, "y")) |n| b.y = util.clampI32(n);
    if (util.extractJsonInt(json, "width")) |n| b.width = util.nonNegU32(n);
    if (util.extractJsonInt(json, "height")) |n| b.height = util.nonNegU32(n);
    return b;
}

/// 평면 JSON에서 CreateWindowReq를 복원. config.zig는 std.json(nested object)
/// 사용하지만 IPC는 평면 키만 받으므로 경량 util.extractJson* 으로 충분.
/// 반환 슬라이스는 src JSON 버퍼를 가리키므로 호출자가 src 수명 보장 필요.
pub fn parseCreateWindowFromJson(json: []const u8) CreateWindowReq {
    var req = CreateWindowReq{};
    if (util.extractJsonString(json, "title")) |s| req.title = s;
    if (util.extractJsonString(json, "url")) |s| req.url = s;
    if (util.extractJsonString(json, "name")) |s| req.name = s;
    if (util.extractJsonInt(json, "width")) |n| req.width = util.nonNegU32(n);
    if (util.extractJsonInt(json, "height")) |n| req.height = util.nonNegU32(n);
    if (util.extractJsonInt(json, "x")) |n| req.x = util.clampI32(n);
    if (util.extractJsonInt(json, "y")) |n| req.y = util.clampI32(n);
    if (util.extractJsonInt(json, "parentId")) |n| if (n >= 0) {
        req.parent_id = util.nonNegU32(n);
    };
    if (util.extractJsonString(json, "parent")) |s| req.parent_name = s;
    if (util.extractJsonBool(json, "frame")) |b| req.frame = b;
    if (util.extractJsonBool(json, "transparent")) |b| req.transparent = b;
    if (util.extractJsonString(json, "backgroundColor")) |s| req.background_color = s;
    if (util.extractJsonString(json, "titleBarStyle")) |s| req.title_bar_style = window.TitleBarStyle.fromString(s);
    if (util.extractJsonBool(json, "resizable")) |b| req.resizable = b;
    if (util.extractJsonBool(json, "alwaysOnTop")) |b| req.always_on_top = b;
    if (util.extractJsonInt(json, "minWidth")) |n| req.min_width = util.nonNegU32(n);
    if (util.extractJsonInt(json, "minHeight")) |n| req.min_height = util.nonNegU32(n);
    if (util.extractJsonInt(json, "maxWidth")) |n| req.max_width = util.nonNegU32(n);
    if (util.extractJsonInt(json, "maxHeight")) |n| req.max_height = util.nonNegU32(n);
    if (util.extractJsonBool(json, "fullscreen")) |b| req.fullscreen = b;
    return req;
}

/// 응답 고정 템플릿 + u32 max (10자리) 합이 62자. 64바이트면 항상 여유.
const RESPONSE_MIN_LEN = 64;

/// `{from, cmd, windowId, ok}` 4-필드 응답 — set_title/set_bounds/load_url/reload/execute_javascript 공용.
fn respondWindowOp(buf: []u8, cmd: []const u8, window_id: u32, ok: bool) ?[]const u8 {
    return std.fmt.bufPrint(
        buf,
        "{{\"from\":\"zig-core\",\"cmd\":\"{s}\",\"windowId\":{d},\"ok\":{}}}",
        .{ cmd, window_id, ok },
    ) catch null;
}

/// defer 가 거부된(슬롯 풀/ctx 미설정) 경로 — 명시적 `success:false`.
/// CDP 호출은 성공했지만 결과를 관측할 수 없어 ok:false. 이전엔 respondWindowOp
/// 로 ok:true(success 필드 없음) 보내 SDK 가 undefined→false 강제했음(PR #54
/// review #2). 이제 결정적 false 로 정직화.
fn respondDeferFallback(buf: []u8, cmd: []const u8, window_id: u32) ?[]const u8 {
    return std.fmt.bufPrint(
        buf,
        "{{\"from\":\"zig-core\",\"cmd\":\"{s}\",\"windowId\":{d},\"ok\":false,\"success\":false}}",
        .{ cmd, window_id },
    ) catch null;
}

/// create_window 요청 처리. 성공 시 `{"from":"zig-core","cmd":"create_window","windowId":N}`
/// 형식의 응답을 response_buf에 쓰고 그 슬라이스를 반환. 실패 시 null.
///
/// 버퍼가 작으면 **wm.create를 호출하지 않는다** — 윈도우 생성 후 응답 실패로
/// 고아 윈도우가 되는 상황 방지.
pub fn handleCreateWindow(
    req: CreateWindowReq,
    response_buf: []u8,
    wm: *window.WindowManager,
) ?[]const u8 {
    if (response_buf.len < RESPONSE_MIN_LEN) return null;

    // parent_name → parent_id resolve. parent_id가 명시되어 있으면 그게 우선.
    var resolved_parent: ?u32 = req.parent_id;
    if (resolved_parent == null) {
        if (req.parent_name) |pn| {
            if (wm.fromName(pn)) |pid| resolved_parent = pid;
        }
    }

    const id = wm.create(.{
        .name = req.name,
        .title = req.title,
        .url = req.url,
        .bounds = .{
            .x = req.x,
            .y = req.y,
            .width = req.width,
            .height = req.height,
        },
        .parent_id = resolved_parent,
        .appearance = .{
            .frame = req.frame,
            .transparent = req.transparent,
            .background_color = req.background_color,
            .title_bar_style = req.title_bar_style,
        },
        .constraints = .{
            .resizable = req.resizable,
            .always_on_top = req.always_on_top,
            .min_width = req.min_width,
            .min_height = req.min_height,
            .max_width = req.max_width,
            .max_height = req.max_height,
            .fullscreen = req.fullscreen,
        },
    }) catch |e| switch (e) {
        window.Error.InvalidName => return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"create_window\",\"error\":\"invalid name\"}}",
            .{},
        ) catch null,
        else => return null,
    };
    return std.fmt.bufPrint(
        response_buf,
        "{{\"from\":\"zig-core\",\"cmd\":\"create_window\",\"windowId\":{d}}}",
        .{id},
    ) catch null;
}

pub const SetTitleReq = struct {
    window_id: u32,
    title: []const u8,
};

/// set_title 요청 처리. 응답: `{"from":"zig-core","cmd":"set_title","windowId":N,"ok":true|false}`.
pub fn handleSetTitle(
    req: SetTitleReq,
    response_buf: []u8,
    wm: *window.WindowManager,
) ?[]const u8 {
    if (response_buf.len < RESPONSE_MIN_LEN) return null;
    const ok = if (wm.setTitle(req.window_id, req.title)) |_| true else |_| false;
    return respondWindowOp(response_buf, "set_title", req.window_id, ok);
}

pub const SetBoundsReq = struct {
    window_id: u32,
    x: i32 = 0,
    y: i32 = 0,
    width: u32 = 0,
    height: u32 = 0,
};

/// set_bounds 요청 처리. width/height=0이면 현재 유지 (caller 책임).
pub fn handleSetBounds(
    req: SetBoundsReq,
    response_buf: []u8,
    wm: *window.WindowManager,
) ?[]const u8 {
    if (response_buf.len < RESPONSE_MIN_LEN) return null;
    const ok = if (wm.setBounds(req.window_id, .{
        .x = req.x,
        .y = req.y,
        .width = req.width,
        .height = req.height,
    })) |_| true else |_| false;
    return respondWindowOp(response_buf, "set_bounds", req.window_id, ok);
}

// ============================================
// Phase 4-A: webContents (네비 / JS)
// 모든 핸들러는 windowId 기반. 응답은 set_title/set_bounds와 동일 패턴
// `{from, cmd, windowId, ok}`. get_url / is_loading은 추가 필드 포함.
// ============================================

pub const LoadUrlReq = struct {
    window_id: u32,
    url: []const u8,
};

pub fn handleLoadUrl(req: LoadUrlReq, response_buf: []u8, wm: *window.WindowManager) ?[]const u8 {
    if (response_buf.len < RESPONSE_MIN_LEN) return null;
    const ok = if (wm.loadUrl(req.window_id, req.url)) |_| true else |_| false;
    return respondWindowOp(response_buf, "load_url", req.window_id, ok);
}

pub const ReloadReq = struct {
    window_id: u32,
    ignore_cache: bool = false,
};

pub fn handleReload(req: ReloadReq, response_buf: []u8, wm: *window.WindowManager) ?[]const u8 {
    if (response_buf.len < RESPONSE_MIN_LEN) return null;
    const ok = if (wm.reload(req.window_id, req.ignore_cache)) |_| true else |_| false;
    return respondWindowOp(response_buf, "reload", req.window_id, ok);
}

pub const ExecuteJavascriptReq = struct {
    window_id: u32,
    code: []const u8,
};

pub fn handleExecuteJavascript(req: ExecuteJavascriptReq, response_buf: []u8, wm: *window.WindowManager) ?[]const u8 {
    if (response_buf.len < RESPONSE_MIN_LEN) return null;
    const ok = if (wm.executeJavascript(req.window_id, req.code)) |_| true else |_| false;
    return respondWindowOp(response_buf, "execute_javascript", req.window_id, ok);
}

/// get_url 응답 — JSON-safe하지 않은 URL(`"`, `\\`, control char)은 escape 처리.
/// 캐시 미스(URL 없음) 또는 escape 버퍼 부족 시 `url:null` + ok 분기.
pub fn handleGetUrl(window_id: u32, response_buf: []u8, wm: *window.WindowManager) ?[]const u8 {
    if (response_buf.len < RESPONSE_MIN_LEN) return null;
    const url = (wm.getUrl(window_id) catch null) orelse return std.fmt.bufPrint(
        response_buf,
        "{{\"from\":\"zig-core\",\"cmd\":\"get_url\",\"windowId\":{d},\"ok\":false,\"url\":null}}",
        .{window_id},
    ) catch null;

    var url_buf: [2048]u8 = undefined;
    const n = window.escapeJsonChars(url, &url_buf);
    if (n == 0 and url.len > 0) return std.fmt.bufPrint(
        response_buf,
        "{{\"from\":\"zig-core\",\"cmd\":\"get_url\",\"windowId\":{d},\"ok\":true,\"url\":null}}",
        .{window_id},
    ) catch null;

    return std.fmt.bufPrint(
        response_buf,
        "{{\"from\":\"zig-core\",\"cmd\":\"get_url\",\"windowId\":{d},\"ok\":true,\"url\":\"{s}\"}}",
        .{ window_id, url_buf[0..n] },
    ) catch null;
}

// ==================== User-Agent (Electron `webContents.setUserAgent`/`getUserAgent`) ====================
// 동적 — CDP Network.setUserAgentOverride (cef.zig). get 은 설정값 추적 반환.

pub fn handleSetUserAgent(window_id: u32, user_agent: []const u8, response_buf: []u8, wm: *window.WindowManager) ?[]const u8 {
    if (response_buf.len < RESPONSE_MIN_LEN) return null;
    const ok = if (wm.setUserAgent(window_id, user_agent)) |_| true else |_| false;
    return respondWindowOp(response_buf, "set_user_agent", window_id, ok);
}

pub fn handleGetUserAgent(window_id: u32, response_buf: []u8, wm: *window.WindowManager) ?[]const u8 {
    if (response_buf.len < RESPONSE_MIN_LEN) return null;
    // 에러(없는/죽은 창)와 미설정 구분: 에러→ok:false, 미설정→ok:true·null
    // (UA override 미설정은 정상 기본 상태이지 실패가 아님).
    const ua_opt = wm.getUserAgent(window_id) catch return std.fmt.bufPrint(
        response_buf,
        "{{\"from\":\"zig-core\",\"cmd\":\"get_user_agent\",\"windowId\":{d},\"ok\":false,\"userAgent\":null}}",
        .{window_id},
    ) catch null;
    const ua = ua_opt orelse return std.fmt.bufPrint(
        response_buf,
        "{{\"from\":\"zig-core\",\"cmd\":\"get_user_agent\",\"windowId\":{d},\"ok\":true,\"userAgent\":null}}",
        .{window_id},
    ) catch null;

    var ua_buf: [4096]u8 = undefined;
    const n = window.escapeJsonChars(ua, &ua_buf);
    if (n == 0 and ua.len > 0) return std.fmt.bufPrint(
        response_buf,
        "{{\"from\":\"zig-core\",\"cmd\":\"get_user_agent\",\"windowId\":{d},\"ok\":true,\"userAgent\":null}}",
        .{window_id},
    ) catch null;

    return std.fmt.bufPrint(
        response_buf,
        "{{\"from\":\"zig-core\",\"cmd\":\"get_user_agent\",\"windowId\":{d},\"ok\":true,\"userAgent\":\"{s}\"}}",
        .{ window_id, ua_buf[0..n] },
    ) catch null;
}

pub fn handleIsLoading(window_id: u32, response_buf: []u8, wm: *window.WindowManager) ?[]const u8 {
    if (response_buf.len < RESPONSE_MIN_LEN) return null;
    // isLoading이 NotFound/Destroyed 에러면 ok=false, loading=false. 정상이면 ok=true.
    // wm.get으로 ok 판정 안 함 — destroyed 창도 hashmap에 남아있어 get은 some 반환.
    const loading = wm.isLoading(window_id) catch {
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"is_loading\",\"windowId\":{d},\"ok\":false,\"loading\":false}}",
            .{window_id},
        ) catch null;
    };
    return std.fmt.bufPrint(
        response_buf,
        "{{\"from\":\"zig-core\",\"cmd\":\"is_loading\",\"windowId\":{d},\"ok\":true,\"loading\":{}}}",
        .{ window_id, loading },
    ) catch null;
}

// ============================================
// Phase 4-C: DevTools (open/close/is/toggle)
// open/close/toggle은 wm 메서드만 다른 동일 패턴 → 함수 포인터로 통합.
// is_dev_tools_opened는 별도 필드(opened)가 있어 분리.
// ============================================

const WmVoidFn = *const fn (*window.WindowManager, u32) window.Error!void;

fn handleDevToolsOp(
    cmd: []const u8,
    method: WmVoidFn,
    window_id: u32,
    response_buf: []u8,
    wm: *window.WindowManager,
) ?[]const u8 {
    if (response_buf.len < RESPONSE_MIN_LEN) return null;
    const ok = if (method(wm, window_id)) |_| true else |_| false;
    return respondWindowOp(response_buf, cmd, window_id, ok);
}

pub fn handleOpenDevTools(window_id: u32, response_buf: []u8, wm: *window.WindowManager) ?[]const u8 {
    return handleDevToolsOp("open_dev_tools", &window.WindowManager.openDevTools, window_id, response_buf, wm);
}

pub fn handleCloseDevTools(window_id: u32, response_buf: []u8, wm: *window.WindowManager) ?[]const u8 {
    return handleDevToolsOp("close_dev_tools", &window.WindowManager.closeDevTools, window_id, response_buf, wm);
}

pub fn handleToggleDevTools(window_id: u32, response_buf: []u8, wm: *window.WindowManager) ?[]const u8 {
    return handleDevToolsOp("toggle_dev_tools", &window.WindowManager.toggleDevTools, window_id, response_buf, wm);
}

// ============================================
// Phase 4-B: 줌 (set/get zoom_factor + zoom_level)
// CEF는 zoom_level만 — factor는 WM에서 pow(1.2, level) 변환.
// set 응답: windowOp 형식. get 응답: cmd별 필드(level / factor) + ok.
// 4 핸들러가 wm 메서드와 응답 필드명만 다른 동일 패턴 → set/get 헬퍼 2개로 통합.
// ============================================

pub const SetZoomReq = struct {
    window_id: u32,
    /// level 또는 factor 둘 중 하나 (caller가 어느 setter로 보낼지 분기).
    value: f64,
};

const WmF64SetFn = *const fn (*window.WindowManager, u32, f64) window.Error!void;
const WmF64GetFn = *const fn (*window.WindowManager, u32) window.Error!f64;

fn handleZoomSet(cmd: []const u8, method: WmF64SetFn, req: SetZoomReq, response_buf: []u8, wm: *window.WindowManager) ?[]const u8 {
    if (response_buf.len < RESPONSE_MIN_LEN) return null;
    const ok = if (method(wm, req.window_id, req.value)) |_| true else |_| false;
    return respondWindowOp(response_buf, cmd, req.window_id, ok);
}

fn handleZoomGet(
    cmd: []const u8,
    field: []const u8,
    default_value: f64,
    method: WmF64GetFn,
    window_id: u32,
    response_buf: []u8,
    wm: *window.WindowManager,
) ?[]const u8 {
    if (response_buf.len < RESPONSE_MIN_LEN) return null;
    const value = method(wm, window_id) catch {
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"{s}\",\"windowId\":{d},\"ok\":false,\"{s}\":{d}}}",
            .{ cmd, window_id, field, default_value },
        ) catch null;
    };
    return std.fmt.bufPrint(
        response_buf,
        "{{\"from\":\"zig-core\",\"cmd\":\"{s}\",\"windowId\":{d},\"ok\":true,\"{s}\":{d}}}",
        .{ cmd, window_id, field, value },
    ) catch null;
}

pub fn handleSetZoomLevel(req: SetZoomReq, response_buf: []u8, wm: *window.WindowManager) ?[]const u8 {
    return handleZoomSet("set_zoom_level", &window.WindowManager.setZoomLevel, req, response_buf, wm);
}

pub fn handleSetZoomFactor(req: SetZoomReq, response_buf: []u8, wm: *window.WindowManager) ?[]const u8 {
    return handleZoomSet("set_zoom_factor", &window.WindowManager.setZoomFactor, req, response_buf, wm);
}

pub fn handleGetZoomLevel(window_id: u32, response_buf: []u8, wm: *window.WindowManager) ?[]const u8 {
    return handleZoomGet("get_zoom_level", "level", 0, &window.WindowManager.getZoomLevel, window_id, response_buf, wm);
}

pub fn handleGetZoomFactor(window_id: u32, response_buf: []u8, wm: *window.WindowManager) ?[]const u8 {
    return handleZoomGet("get_zoom_factor", "factor", 1, &window.WindowManager.getZoomFactor, window_id, response_buf, wm);
}

// ==================== Audio mute (Electron `webContents.setAudioMuted` / `isAudioMuted`) ====================

pub fn handleSetAudioMuted(window_id: u32, muted: bool, response_buf: []u8, wm: *window.WindowManager) ?[]const u8 {
    if (response_buf.len < RESPONSE_MIN_LEN) return null;
    const ok = if (wm.setAudioMuted(window_id, muted)) |_| true else |_| false;
    return respondWindowOp(response_buf, "set_audio_muted", window_id, ok);
}

pub fn handleIsAudioMuted(window_id: u32, response_buf: []u8, wm: *window.WindowManager) ?[]const u8 {
    return handleStateGet("is_audio_muted", "muted", &window.WindowManager.isAudioMuted, window_id, response_buf, wm);
}

// ==================== Window opacity / background / shadow ====================

pub fn handleSetOpacity(req: SetZoomReq, response_buf: []u8, wm: *window.WindowManager) ?[]const u8 {
    return handleZoomSet("set_opacity", &window.WindowManager.setOpacity, req, response_buf, wm);
}

pub fn handleGetOpacity(window_id: u32, response_buf: []u8, wm: *window.WindowManager) ?[]const u8 {
    return handleZoomGet("get_opacity", "opacity", 1, &window.WindowManager.getOpacity, window_id, response_buf, wm);
}

pub fn handleSetBackgroundColor(window_id: u32, hex: []const u8, response_buf: []u8, wm: *window.WindowManager) ?[]const u8 {
    if (response_buf.len < RESPONSE_MIN_LEN) return null;
    const ok = if (wm.setBackgroundColor(window_id, hex)) |_| true else |_| false;
    return respondWindowOp(response_buf, "set_background_color", window_id, ok);
}

pub fn handleSetHasShadow(window_id: u32, has: bool, response_buf: []u8, wm: *window.WindowManager) ?[]const u8 {
    if (response_buf.len < RESPONSE_MIN_LEN) return null;
    const ok = if (wm.setHasShadow(window_id, has)) |_| true else |_| false;
    return respondWindowOp(response_buf, "set_has_shadow", window_id, ok);
}

pub fn handleHasShadow(window_id: u32, response_buf: []u8, wm: *window.WindowManager) ?[]const u8 {
    return handleStateGet("has_shadow", "hasShadow", &window.WindowManager.hasShadow, window_id, response_buf, wm);
}

// ============================================
// Phase 4-E: 편집 (6 trivial) + 검색
// 6 편집은 windowId만 받는 동일 패턴 — 4-C handleDevToolsOp와 같은 헬퍼 사용.
// find_in_page는 text/forward/matchCase/findNext, stop_find_in_page는 clearSelection.
// ============================================

pub fn handleUndo(window_id: u32, response_buf: []u8, wm: *window.WindowManager) ?[]const u8 {
    return handleDevToolsOp("undo", &window.WindowManager.undo, window_id, response_buf, wm);
}
pub fn handleRedo(window_id: u32, response_buf: []u8, wm: *window.WindowManager) ?[]const u8 {
    return handleDevToolsOp("redo", &window.WindowManager.redo, window_id, response_buf, wm);
}
pub fn handleCut(window_id: u32, response_buf: []u8, wm: *window.WindowManager) ?[]const u8 {
    return handleDevToolsOp("cut", &window.WindowManager.cut, window_id, response_buf, wm);
}
pub fn handleCopy(window_id: u32, response_buf: []u8, wm: *window.WindowManager) ?[]const u8 {
    return handleDevToolsOp("copy", &window.WindowManager.copy, window_id, response_buf, wm);
}
pub fn handlePaste(window_id: u32, response_buf: []u8, wm: *window.WindowManager) ?[]const u8 {
    return handleDevToolsOp("paste", &window.WindowManager.paste, window_id, response_buf, wm);
}
pub fn handleSelectAll(window_id: u32, response_buf: []u8, wm: *window.WindowManager) ?[]const u8 {
    return handleDevToolsOp("select_all", &window.WindowManager.selectAll, window_id, response_buf, wm);
}

pub const FindInPageReq = struct {
    window_id: u32,
    text: []const u8,
    /// 검색 방향 (default: 앞으로). 기본값 외에는 frontend에서 명시 필요.
    forward: bool = true,
    match_case: bool = false,
    /// 첫 호출은 false, 이후 같은 검색어 다음 매치 찾을 때 true.
    find_next: bool = false,
};

pub fn handleFindInPage(req: FindInPageReq, response_buf: []u8, wm: *window.WindowManager) ?[]const u8 {
    if (response_buf.len < RESPONSE_MIN_LEN) return null;
    const ok = if (wm.findInPage(req.window_id, req.text, req.forward, req.match_case, req.find_next)) |_| true else |_| false;
    return respondWindowOp(response_buf, "find_in_page", req.window_id, ok);
}

pub fn handleStopFindInPage(window_id: u32, clear_selection: bool, response_buf: []u8, wm: *window.WindowManager) ?[]const u8 {
    if (response_buf.len < RESPONSE_MIN_LEN) return null;
    const ok = if (wm.stopFindInPage(window_id, clear_selection)) |_| true else |_| false;
    return respondWindowOp(response_buf, "stop_find_in_page", window_id, ok);
}

// ============================================
// Phase 4-D: 인쇄 (printToPDF — 콜백 기반 async)
// 즉시 ok 응답 → 결과는 `window:pdf-print-finished` 이벤트(`{path, success}`)로
// 발화. SDK 측에서 listener + Promise로 매핑 (path 매칭).
// capturePage는 CEF 직접 미지원 → Phase 4 백로그 (CDP 또는 off-screen 우회).
// ============================================

pub const PrintToPDFReq = struct {
    window_id: u32,
    path: []const u8,
};

pub fn handlePrintToPDF(req: PrintToPDFReq, response_buf: []u8, wm: *window.WindowManager) ?[]const u8 {
    if (response_buf.len < RESPONSE_MIN_LEN) return null;
    const ok = if (wm.printToPDF(req.window_id, req.path)) |_| true else |_| false;
    // CDP 호출 성공 + defer 가능 → Promise 보류, CDP 콜백에서 응답 송신.
    // defer 거부(슬롯 풀) 시 명시적 success:false. no-cb 경로(테스트/모바일)는
    // 기존 ack-only(respondWindowOp) 유지.
    if (ok) {
        if (g_defer_response_cb) |cb| {
            if (cb(.print, req.path)) return null; // sentinel: caller skip immediate response
            return respondDeferFallback(response_buf, "print_to_pdf", req.window_id);
        }
    }
    return respondWindowOp(response_buf, "print_to_pdf", req.window_id, ok);
}

// capture_page — CDP Page.captureScreenshot. ack 즉시 + 완료 시
// `window:page-captured`{path,success} 이벤트(printToPDF 와 동형 2단).
// clip 지정 시 부분 영역(Electron `capturePage(rect)`), null=전체(기존 동작).
pub const CapturePageReq = struct {
    window_id: u32,
    path: []const u8,
    clip: ?window.CaptureClip = null,
};

pub fn handleCapturePage(req: CapturePageReq, response_buf: []u8, wm: *window.WindowManager) ?[]const u8 {
    if (response_buf.len < RESPONSE_MIN_LEN) return null;
    const ok = if (wm.capturePage(req.window_id, req.path, req.clip)) |_| true else |_| false;
    if (ok) {
        if (g_defer_response_cb) |cb| {
            if (cb(.capture, req.path)) return null; // deferred — emitPageCaptured 가 응답 송신
            return respondDeferFallback(response_buf, "capture_page", req.window_id);
        }
    }
    return respondWindowOp(response_buf, "capture_page", req.window_id, ok);
}

pub fn handleIsDevToolsOpened(window_id: u32, response_buf: []u8, wm: *window.WindowManager) ?[]const u8 {
    if (response_buf.len < RESPONSE_MIN_LEN) return null;
    const opened = wm.isDevToolsOpened(window_id) catch {
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"is_dev_tools_opened\",\"windowId\":{d},\"ok\":false,\"opened\":false}}",
            .{window_id},
        ) catch null;
    };
    return std.fmt.bufPrint(
        response_buf,
        "{{\"from\":\"zig-core\",\"cmd\":\"is_dev_tools_opened\",\"windowId\":{d},\"ok\":true,\"opened\":{}}}",
        .{ window_id, opened },
    ) catch null;
}

// ============================================
// Phase 17-B: WebContentsView (createView / addChildView / setTopView / ...)
// view 전용 응답은 `viewId` 키 사용 (windowId와 같은 풀이지만 시맨틱 명확화).
// 기존 webContents cmd(load_url/execute_javascript/...)는 windowId 키 그대로 — viewId가
// 그 자리에 들어가 동작.
// ============================================

/// `{from, cmd, viewId, ok}` 4-필드 응답 — view 전용 cmd 공용. respondWindowOp의 view 버전.
fn respondViewOp(buf: []u8, cmd: []const u8, view_id: u32, ok: bool) ?[]const u8 {
    return std.fmt.bufPrint(
        buf,
        "{{\"from\":\"zig-core\",\"cmd\":\"{s}\",\"viewId\":{d},\"ok\":{}}}",
        .{ cmd, view_id, ok },
    ) catch null;
}

pub const CreateViewReq = struct {
    host_window_id: u32,
    url: ?[]const u8 = null,
    name: ?[]const u8 = null,
    bounds: window.Bounds = .{},
};

pub fn parseCreateViewFromJson(json: []const u8) CreateViewReq {
    var req = CreateViewReq{ .host_window_id = 0 };
    if (util.extractJsonInt(json, "hostId")) |n| if (n >= 0) {
        req.host_window_id = util.nonNegU32(n);
    };
    if (util.extractJsonString(json, "url")) |s| req.url = s;
    if (util.extractJsonString(json, "name")) |s| req.name = s;
    req.bounds = parseBoundsFromJson(json);
    return req;
}

/// create_view 요청 처리. 성공 시 `{"from":"zig-core","cmd":"create_view","viewId":N}`.
pub fn handleCreateView(req: CreateViewReq, response_buf: []u8, wm: *window.WindowManager) ?[]const u8 {
    if (response_buf.len < RESPONSE_MIN_LEN) return null;
    const id = wm.createView(.{
        .host_window_id = req.host_window_id,
        .url = req.url,
        .name = req.name,
        .bounds = req.bounds,
    }) catch |e| switch (e) {
        window.Error.InvalidName => return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"create_view\",\"error\":\"invalid name\"}}",
            .{},
        ) catch null,
        else => return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"create_view\",\"error\":\"failed\"}}",
            .{},
        ) catch null,
    };
    return std.fmt.bufPrint(
        response_buf,
        "{{\"from\":\"zig-core\",\"cmd\":\"create_view\",\"viewId\":{d}}}",
        .{id},
    ) catch null;
}

pub fn handleDestroyView(view_id: u32, response_buf: []u8, wm: *window.WindowManager) ?[]const u8 {
    if (response_buf.len < RESPONSE_MIN_LEN) return null;
    const ok = if (wm.destroyView(view_id)) |_| true else |_| false;
    return respondViewOp(response_buf, "destroy_view", view_id, ok);
}

/// 정책적 close — `window:close` cancelable 발화 후 destroy + `window:closed` 발화.
/// listener가 preventDefault 시 success=false. 미존재 windowId도 false.
pub fn handleDestroyWindow(window_id: u32, response_buf: []u8, wm: *window.WindowManager) ?[]const u8 {
    if (response_buf.len < RESPONSE_MIN_LEN) return null;
    const ok = wm.close(window_id) catch false;
    return std.fmt.bufPrint(
        response_buf,
        "{{\"from\":\"zig-core\",\"cmd\":\"destroy_window\",\"windowId\":{d},\"success\":{}}}",
        .{ window_id, ok },
    ) catch null;
}

pub const AddChildViewReq = struct {
    host_id: u32,
    view_id: u32,
    /// null이면 top (끝). 음수는 생략.
    index: ?usize = null,
};

pub fn handleAddChildView(req: AddChildViewReq, response_buf: []u8, wm: *window.WindowManager) ?[]const u8 {
    if (response_buf.len < RESPONSE_MIN_LEN) return null;
    const ok = if (wm.addChildView(req.host_id, req.view_id, req.index)) |_| true else |_| false;
    return respondViewOp(response_buf, "add_child_view", req.view_id, ok);
}

pub fn handleRemoveChildView(host_id: u32, view_id: u32, response_buf: []u8, wm: *window.WindowManager) ?[]const u8 {
    if (response_buf.len < RESPONSE_MIN_LEN) return null;
    const ok = if (wm.removeChildView(host_id, view_id)) |_| true else |_| false;
    return respondViewOp(response_buf, "remove_child_view", view_id, ok);
}

pub fn handleSetTopView(host_id: u32, view_id: u32, response_buf: []u8, wm: *window.WindowManager) ?[]const u8 {
    if (response_buf.len < RESPONSE_MIN_LEN) return null;
    const ok = if (wm.setTopView(host_id, view_id)) |_| true else |_| false;
    return respondViewOp(response_buf, "set_top_view", view_id, ok);
}

pub const SetViewBoundsReq = struct {
    view_id: u32,
    x: i32 = 0,
    y: i32 = 0,
    width: u32 = 0,
    height: u32 = 0,
};

pub fn handleSetViewBounds(req: SetViewBoundsReq, response_buf: []u8, wm: *window.WindowManager) ?[]const u8 {
    if (response_buf.len < RESPONSE_MIN_LEN) return null;
    const ok = if (wm.setViewBounds(req.view_id, .{
        .x = req.x,
        .y = req.y,
        .width = req.width,
        .height = req.height,
    })) |_| true else |_| false;
    return respondViewOp(response_buf, "set_view_bounds", req.view_id, ok);
}

pub fn handleSetViewVisible(view_id: u32, visible: bool, response_buf: []u8, wm: *window.WindowManager) ?[]const u8 {
    if (response_buf.len < RESPONSE_MIN_LEN) return null;
    const ok = if (wm.setViewVisible(view_id, visible)) |_| true else |_| false;
    return respondViewOp(response_buf, "set_view_visible", view_id, ok);
}

/// get_child_views 응답: `{from, cmd, hostId, ok, viewIds: [...]}`. host destroyed/not-window면
/// ok=false + 빈 배열. allocator는 임시 슬라이스 alloc용 (호출자 owned).
pub fn handleGetChildViews(host_id: u32, response_buf: []u8, wm: *window.WindowManager, allocator: std.mem.Allocator) ?[]const u8 {
    if (response_buf.len < RESPONSE_MIN_LEN) return null;
    const ids = wm.getChildViews(host_id, allocator) catch {
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"get_child_views\",\"hostId\":{d},\"ok\":false,\"viewIds\":[]}}",
            .{host_id},
        ) catch null;
    };
    defer allocator.free(ids);

    var w = std.Io.Writer.fixed(response_buf);
    w.print("{{\"from\":\"zig-core\",\"cmd\":\"get_child_views\",\"hostId\":{d},\"ok\":true,\"viewIds\":[", .{host_id}) catch return null;
    for (ids, 0..) |id, i| {
        if (i > 0) w.writeByte(',') catch return null;
        w.print("{d}", .{id}) catch return null;
    }
    w.writeAll("]}") catch return null;
    return w.buffered();
}

// ============================================
// Phase 5: 라이프사이클 제어 (minimize/maximize/fullscreen + 게터)
// 4-C DevTools와 같은 voidFn 패턴 — windowId 단일 입력 + ok 4-필드 응답.
// is_*는 별도 필드(minimized/maximized/fullscreen) 응답.
// ============================================

pub fn handleMinimize(window_id: u32, response_buf: []u8, wm: *window.WindowManager) ?[]const u8 {
    return handleDevToolsOp("minimize", &window.WindowManager.minimize, window_id, response_buf, wm);
}
pub fn handleRestoreWindow(window_id: u32, response_buf: []u8, wm: *window.WindowManager) ?[]const u8 {
    return handleDevToolsOp("restore_window", &window.WindowManager.restoreWindow, window_id, response_buf, wm);
}
pub fn handleMaximize(window_id: u32, response_buf: []u8, wm: *window.WindowManager) ?[]const u8 {
    return handleDevToolsOp("maximize", &window.WindowManager.maximize, window_id, response_buf, wm);
}
pub fn handleUnmaximize(window_id: u32, response_buf: []u8, wm: *window.WindowManager) ?[]const u8 {
    return handleDevToolsOp("unmaximize", &window.WindowManager.unmaximize, window_id, response_buf, wm);
}

pub const SetFullscreenReq = struct {
    window_id: u32,
    flag: bool,
};

pub fn handleSetFullscreen(req: SetFullscreenReq, response_buf: []u8, wm: *window.WindowManager) ?[]const u8 {
    if (response_buf.len < RESPONSE_MIN_LEN) return null;
    const ok = if (wm.setFullscreen(req.window_id, req.flag)) |_| true else |_| false;
    return respondWindowOp(response_buf, "set_fullscreen", req.window_id, ok);
}

pub const SetVisibleReq = struct {
    window_id: u32,
    visible: bool,
};

pub fn handleSetVisible(req: SetVisibleReq, response_buf: []u8, wm: *window.WindowManager) ?[]const u8 {
    if (response_buf.len < RESPONSE_MIN_LEN) return null;
    const ok = if (wm.setVisible(req.window_id, req.visible)) |_| true else |_| false;
    return respondWindowOp(response_buf, "set_visible", req.window_id, ok);
}

const WmBoolGetFn = *const fn (*window.WindowManager, u32) window.Error!bool;

fn handleStateGet(
    cmd: []const u8,
    field: []const u8,
    method: WmBoolGetFn,
    window_id: u32,
    response_buf: []u8,
    wm: *window.WindowManager,
) ?[]const u8 {
    if (response_buf.len < RESPONSE_MIN_LEN) return null;
    const value = method(wm, window_id) catch {
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"{s}\",\"windowId\":{d},\"ok\":false,\"{s}\":false}}",
            .{ cmd, window_id, field },
        ) catch null;
    };
    return std.fmt.bufPrint(
        response_buf,
        "{{\"from\":\"zig-core\",\"cmd\":\"{s}\",\"windowId\":{d},\"ok\":true,\"{s}\":{}}}",
        .{ cmd, window_id, field, value },
    ) catch null;
}

pub fn handleIsMinimized(window_id: u32, response_buf: []u8, wm: *window.WindowManager) ?[]const u8 {
    return handleStateGet("is_minimized", "minimized", &window.WindowManager.isMinimized, window_id, response_buf, wm);
}
pub fn handleIsMaximized(window_id: u32, response_buf: []u8, wm: *window.WindowManager) ?[]const u8 {
    return handleStateGet("is_maximized", "maximized", &window.WindowManager.isMaximized, window_id, response_buf, wm);
}
pub fn handleIsFullscreen(window_id: u32, response_buf: []u8, wm: *window.WindowManager) ?[]const u8 {
    return handleStateGet("is_fullscreen", "fullscreen", &window.WindowManager.isFullscreen, window_id, response_buf, wm);
}

// Electron BrowserWindow.focus() — Native.focus/WindowManager.focus 는 이미 존재
// (set_visible 동선) → void action 패턴으로 노출만.
pub fn handleFocus(window_id: u32, response_buf: []u8, wm: *window.WindowManager) ?[]const u8 {
    return handleDevToolsOp("focus", &window.WindowManager.focus, window_id, response_buf, wm);
}

// Electron BrowserWindow.isNormal() — minimized/maximized/fullscreen 가 모두 아닌
// 상태. 기존 3 게터에서 파생(네이티브 추가 0). 하나라도 조회 실패 시 ok:false.
pub fn handleIsNormal(window_id: u32, response_buf: []u8, wm: *window.WindowManager) ?[]const u8 {
    if (response_buf.len < RESPONSE_MIN_LEN) return null;
    const normal: ?bool = blk: {
        const minimized = wm.isMinimized(window_id) catch break :blk null;
        const maximized = wm.isMaximized(window_id) catch break :blk null;
        const fullscreen = wm.isFullscreen(window_id) catch break :blk null;
        break :blk !minimized and !maximized and !fullscreen;
    };
    return std.fmt.bufPrint(
        response_buf,
        "{{\"from\":\"zig-core\",\"cmd\":\"is_normal\",\"windowId\":{d},\"ok\":{},\"normal\":{}}}",
        .{ window_id, normal != null, normal orelse false },
    ) catch null;
}
