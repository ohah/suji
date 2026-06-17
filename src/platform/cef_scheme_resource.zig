//! Per-request CEF resource handler for the `suji://app` scheme.

const std = @import("std");
const cef_scheme_security = @import("cef_scheme_security.zig");
const cef = @import("cef.zig");

const c = cef.c;
const zeroCefStruct = cef.zeroCefStruct;
const setCefString = cef.setCefString;
const cefUserfreeToUtf8 = cef.cefUserfreeToUtf8;

const ResourceHandlerData = struct {
    handler: c.cef_resource_handler_t,
    ref_count: std.atomic.Value(u32),
    data: []u8,
    mime: [:0]const u8,
    offset: usize,
    status_code: i32,
    // HTTP Range — 미디어(<video>/<audio>)는 bytes=start-end 부분 요청을 보내며 206 응답을
    // 기대한다. CEF 는 Range 요청 시 skip(offset) 콜백으로 seek 하고, handler 는 206 status +
    // Content-Range/Content-Length 헤더를 직접 설정해야 한다(둘 다 안 하면 416).
    is_partial: bool,
    range_start: usize,
    range_end: usize,
    // cross-origin fetch 허용 여부 — true 면 응답에 Access-Control-Allow-Origin:* 를 단다.
    // suji://app 페이지가 suji-video:// 영상을 fetch(내보내기 zip)할 때 필요. 앱 자산(suji://app)은
    // same-origin 이라 false.
    cors: bool,
};

// per-request 동적 객체 — 글로벌 no-op refcount(release 항상 1)를 쓰면 안 됨.
// CEF 가 응답 완료 후 cancel() 을 호출하는데, 거기서 free 하면 그 뒤 CEF 의
// 추가 release()/접근이 freed 메모리를 건드려 UAF segfault(#60 packaged crash).
// 인스턴스별 실 refcount 로 CEF 가 수명 제어 — 마지막 release 에서만 free,
// cancel 은 free 하지 않음. (InitialLoadTask 와 동형 패턴.)
fn rhFromBase(base: ?*c.cef_base_ref_counted_t) ?*ResourceHandlerData {
    return @ptrCast(@alignCast(base orelse return null));
}

fn rhAddRef(base: ?*c.cef_base_ref_counted_t) callconv(.c) void {
    const rh = rhFromBase(base) orelse return;
    _ = rh.ref_count.fetchAdd(1, .acq_rel);
}

fn rhReleaseRef(base: ?*c.cef_base_ref_counted_t) callconv(.c) i32 {
    const rh = rhFromBase(base) orelse return 0;
    if (rh.ref_count.fetchSub(1, .acq_rel) != 1) return 0;
    if (rh.data.len > 0) std.heap.page_allocator.free(rh.data);
    std.heap.page_allocator.destroy(rh);
    return 1;
}

fn rhHasOneRefCb(base: ?*c.cef_base_ref_counted_t) callconv(.c) i32 {
    const rh = rhFromBase(base) orelse return 0;
    return if (rh.ref_count.load(.acquire) == 1) 1 else 0;
}

fn rhHasAtLeastOneRefCb(base: ?*c.cef_base_ref_counted_t) callconv(.c) i32 {
    const rh = rhFromBase(base) orelse return 0;
    return if (rh.ref_count.load(.acquire) >= 1) 1 else 0;
}

fn initResourceHandler(rh: *ResourceHandlerData, data: []u8, mime: [:0]const u8, status: i32, cors: bool) void {
    zeroCefStruct(c.cef_resource_handler_t, &rh.handler);
    // base 는 글로벌 no-op 대신 인스턴스별 refcount (UAF 방지).
    rh.handler.base.add_ref = &rhAddRef;
    rh.handler.base.release = &rhReleaseRef;
    rh.handler.base.has_one_ref = &rhHasOneRefCb;
    rh.handler.base.has_at_least_one_ref = &rhHasAtLeastOneRefCb;
    rh.handler.open = &rhOpen;
    rh.handler.get_response_headers = &rhGetResponseHeaders;
    rh.handler.skip = &rhSkip;
    rh.handler.read = &rhRead;
    rh.handler.cancel = &rhCancel;
    // deprecated 콜백은 null로 (zeroCefStruct가 0으로 초기화)
    rh.ref_count = .init(1);
    rh.data = data;
    rh.mime = mime;
    rh.offset = 0;
    rh.status_code = status;
    rh.is_partial = false;
    rh.range_start = 0;
    rh.range_end = if (data.len > 0) data.len - 1 else 0;
    rh.cors = cors;
}

pub fn createResourceHandler(data: []u8, path: []const u8, cors: bool) ?*c.cef_resource_handler_t {
    const rh = std.heap.page_allocator.create(ResourceHandlerData) catch return null;
    initResourceHandler(rh, data, mimeTypeForPath(path), 200, cors);
    return &rh.handler;
}

pub fn createErrorHandler(status: i32) ?*c.cef_resource_handler_t {
    const body = std.heap.page_allocator.alloc(u8, 0) catch return null;
    const rh = std.heap.page_allocator.create(ResourceHandlerData) catch {
        std.heap.page_allocator.free(body);
        return null;
    };
    initResourceHandler(rh, body, "text/plain", status, false);
    return &rh.handler;
}

fn getRhData(self: ?*c._cef_resource_handler_t) ?*ResourceHandlerData {
    const ptr = self orelse return null;
    return @fieldParentPtr("handler", ptr);
}

// "bytes=start-end" → rh.range_start/range_end + is_partial. end 생략 시 끝까지.
// 범위가 데이터 밖이면 무시(전체 200 폴백). offset 은 건드리지 않는다 — CEF 의 skip 콜백이
// seek 를 담당하므로 여기서 offset 을 옮기면 이중 이동이 된다.
fn parseRange(rh: *ResourceHandlerData, s: []const u8) void {
    const prefix = "bytes=";
    if (!std.mem.startsWith(u8, s, prefix)) return;
    const rest = s[prefix.len..];
    const dash = std.mem.indexOfScalar(u8, rest, '-') orelse return;
    const start = std.fmt.parseInt(usize, std.mem.trim(u8, rest[0..dash], " "), 10) catch return;
    if (rh.data.len == 0 or start >= rh.data.len) return;
    const end_part = std.mem.trim(u8, rest[dash + 1 ..], " ");
    const end = if (end_part.len == 0)
        rh.data.len - 1
    else
        (std.fmt.parseInt(usize, end_part, 10) catch (rh.data.len - 1));
    rh.range_start = start;
    rh.range_end = @min(end, rh.data.len - 1);
    rh.is_partial = true;
}

fn rhOpen(
    self: ?*c._cef_resource_handler_t,
    request: ?*c._cef_request_t,
    handle_request: ?*i32,
    _: ?*c._cef_callback_t,
) callconv(.c) i32 {
    const rh = getRhData(self) orelse return 0;
    // Range 헤더 파싱 — 미디어 스트리밍 요청을 206 Partial 로 응답하기 위해.
    if (request) |req| {
        var name: c.cef_string_t = .{};
        setCefString(&name, "Range");
        const uf = req.get_header_by_name.?(req, &name);
        if (uf != null) {
            var buf: [128]u8 = undefined;
            parseRange(rh, cefUserfreeToUtf8(uf, &buf));
        }
    }
    if (handle_request) |hr| hr.* = 1; // 즉시 처리
    return 1;
}

fn setRespHeader(resp: *c.cef_response_t, name: []const u8, value: []const u8) void {
    var name_str: c.cef_string_t = .{};
    var value_str: c.cef_string_t = .{};
    setCefString(&name_str, name);
    setCefString(&value_str, value);
    resp.set_header_by_name.?(resp, &name_str, &value_str, 1);
}

fn rhGetResponseHeaders(
    self: ?*c._cef_resource_handler_t,
    response: ?*c._cef_response_t,
    response_length: ?*i64,
    _: ?*c.cef_string_t,
) callconv(.c) void {
    const rh = getRhData(self) orelse return;
    const resp = response orelse return;

    var mime_str: c.cef_string_t = .{};
    setCefString(&mime_str, rh.mime);
    resp.set_mime_type.?(resp, &mime_str);

    // 미디어 seek 지원 — 항상 Accept-Ranges 광고.
    setRespHeader(resp, "Accept-Ranges", "bytes");

    cef_scheme_security.setSecurityHeaders(resp);

    // cross-origin fetch(내보내기 zip)용 — suji-video 응답에만 ACAO. 미디어 seek 헤더도 노출.
    if (rh.cors) {
        setRespHeader(resp, "Access-Control-Allow-Origin", "*");
        setRespHeader(resp, "Access-Control-Expose-Headers", "Content-Length, Content-Range, Accept-Ranges");
    }

    if (rh.is_partial) {
        resp.set_status.?(resp, 206);
        var cr_buf: [96]u8 = undefined;
        const cr = std.fmt.bufPrint(&cr_buf, "bytes {d}-{d}/{d}", .{ rh.range_start, rh.range_end, rh.data.len }) catch "";
        if (cr.len > 0) setRespHeader(resp, "Content-Range", cr);
        // 206 의 Content-Length 는 부분 길이.
        if (response_length) |rl| rl.* = @intCast(rh.range_end - rh.range_start + 1);
    } else {
        resp.set_status.?(resp, rh.status_code);
        if (response_length) |rl| rl.* = @intCast(rh.data.len);
    }
}

// CEF 가 Range 요청의 시작 offset 만큼 seek 하기 위해 호출 — data 내 offset 을 이동한다.
// (이게 없으면 CEF 가 offset 을 못 맞춰 부분 응답이 어긋나고 416 이 난다.)
fn rhSkip(
    self: ?*c._cef_resource_handler_t,
    bytes_to_skip: i64,
    bytes_skipped: ?*i64,
    _: ?*c._cef_resource_skip_callback_t,
) callconv(.c) i32 {
    const rh = getRhData(self) orelse return 0;
    const bs = bytes_skipped orelse return 0;
    if (bytes_to_skip < 0) {
        bs.* = -2; // ERR_FAILED
        return 0;
    }
    const skip: usize = @intCast(bytes_to_skip);
    if (rh.offset + skip > rh.data.len) {
        bs.* = -2;
        return 0;
    }
    rh.offset += skip;
    bs.* = bytes_to_skip;
    return 1;
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

    // partial 이면 range_end 까지만, 아니면 전체.
    const end = if (rh.is_partial) rh.range_end + 1 else rh.data.len;
    if (rh.offset >= end) {
        br.* = 0;
        return 0; // 완료
    }

    const remaining = end - rh.offset;
    const to_read = @min(remaining, @as(usize, @intCast(bytes_to_read)));
    @memcpy(out[0..to_read], rh.data[rh.offset..][0..to_read]);
    rh.offset += to_read;
    br.* = @intCast(to_read);
    return 1;
}

fn rhCancel(_: ?*c._cef_resource_handler_t) callconv(.c) void {
    // free 하지 않음 — 수명은 base refcount(rhReleaseRef)가 소유. CEF 가 cancel
    // 후에도 release 까지 핸들러를 참조하므로 여기서 destroy 하면 UAF(#60). no-op.
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
    // 미디어 — QA 녹화 영상(__localfile__) 재생.
    if (std.mem.endsWith(u8, path, ".mp4") or std.mem.endsWith(u8, path, ".m4v")) return "video/mp4";
    if (std.mem.endsWith(u8, path, ".mov")) return "video/quicktime";
    if (std.mem.endsWith(u8, path, ".webm")) return "video/webm";
    if (std.mem.endsWith(u8, path, ".mkv")) return "video/x-matroska";
    return "application/octet-stream";
}
