//! Window IPC 커맨드 핸들러 — 프론트엔드가 `__core__:create_window` 등으로 보낸
//! 요청을 WindowManager 경로로 라우팅한다.
//!
//! main.zig가 JSON을 파싱해서 CreateWindowReq를 구성한 뒤 handleCreateWindow를 호출.
//! 파싱과 WM 호출을 분리해 이 모듈은 CEF 없이 단위 테스트 가능.

const std = @import("std");
const window = @import("window");

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

pub const CreateWindowReq = struct {
    title: []const u8 = "New Window",
    url: ?[]const u8 = null,
    width: u32 = 800,
    height: u32 = 600,
    /// name 지정 시 WM singleton 정책 (중복 이름이면 기존 id 반환).
    name: ?[]const u8 = null,
};

/// 응답 고정 템플릿 + u32 max (10자리) 합이 62자. 64바이트면 항상 여유.
const RESPONSE_MIN_LEN = 64;

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
    const id = wm.create(.{
        .name = req.name,
        .title = req.title,
        .url = req.url,
        .bounds = .{ .width = req.width, .height = req.height },
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
    return std.fmt.bufPrint(
        response_buf,
        "{{\"from\":\"zig-core\",\"cmd\":\"set_title\",\"windowId\":{d},\"ok\":{}}}",
        .{ req.window_id, ok },
    ) catch null;
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
    return std.fmt.bufPrint(
        response_buf,
        "{{\"from\":\"zig-core\",\"cmd\":\"set_bounds\",\"windowId\":{d},\"ok\":{}}}",
        .{ req.window_id, ok },
    ) catch null;
}
