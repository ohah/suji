//! Per-request CEF resource handler for the `suji://app` scheme.

const std = @import("std");
const cef_scheme_security = @import("cef_scheme_security.zig");
const cef = @import("cef.zig");

const c = cef.c;
const zeroCefStruct = cef.zeroCefStruct;
const setCefString = cef.setCefString;

const ResourceHandlerData = struct {
    handler: c.cef_resource_handler_t,
    ref_count: std.atomic.Value(u32),
    data: []u8,
    mime: [:0]const u8,
    offset: usize,
    status_code: i32,
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

fn initResourceHandler(rh: *ResourceHandlerData, data: []u8, mime: [:0]const u8, status: i32) void {
    zeroCefStruct(c.cef_resource_handler_t, &rh.handler);
    // base 는 글로벌 no-op 대신 인스턴스별 refcount (UAF 방지).
    rh.handler.base.add_ref = &rhAddRef;
    rh.handler.base.release = &rhReleaseRef;
    rh.handler.base.has_one_ref = &rhHasOneRefCb;
    rh.handler.base.has_at_least_one_ref = &rhHasAtLeastOneRefCb;
    rh.handler.open = &rhOpen;
    rh.handler.get_response_headers = &rhGetResponseHeaders;
    rh.handler.read = &rhRead;
    rh.handler.cancel = &rhCancel;
    // deprecated 콜백은 null로 (zeroCefStruct가 0으로 초기화)
    rh.ref_count = .init(1);
    rh.data = data;
    rh.mime = mime;
    rh.offset = 0;
    rh.status_code = status;
}

pub fn createResourceHandler(data: []u8, path: []const u8) ?*c.cef_resource_handler_t {
    const rh = std.heap.page_allocator.create(ResourceHandlerData) catch return null;
    initResourceHandler(rh, data, mimeTypeForPath(path), 200);
    return &rh.handler;
}

pub fn createErrorHandler(status: i32) ?*c.cef_resource_handler_t {
    const body = std.heap.page_allocator.alloc(u8, 0) catch return null;
    const rh = std.heap.page_allocator.create(ResourceHandlerData) catch {
        std.heap.page_allocator.free(body);
        return null;
    };
    initResourceHandler(rh, body, "text/plain", status);
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
    cef_scheme_security.setSecurityHeaders(resp);

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
    return "application/octet-stream";
}
