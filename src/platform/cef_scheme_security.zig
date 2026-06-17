//! `suji://` response security headers and CSP configuration.

const std = @import("std");
const cef = @import("cef.zig");

const c = cef.c;
const setCefString = cef.setCefString;

pub fn setSecurityHeaders(resp: *c.cef_response_t) void {
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
    "media-src 'self' suji: suji-video: blob:; " ++
    "connect-src 'self' suji: suji-video: ws: wss: http: https:; " ++
    "font-src 'self' suji: data:; " ++
    "frame-src " ++ CSP_FRAME_SRC_SENTINEL ++ ";";

/// `suji://` 응답에 적용되는 CSP. config.security.csp가 `"disabled"`면 CSP 헤더 자체를
/// 안 보냄. 그 외는 user-supplied policy로 override. iframeAllowedOrigins는 default
/// CSP의 frame-src에 합성 (사용자 csp override 시 그것을 우선 — 사용자가 직접 frame-src 명시 책임).
pub var g_csp_value: []const u8 = ""; // setIframeAllowedOrigins / setCspValue가 process init 시 set.
pub var g_csp_enabled: bool = true;

/// 사용자가 csp 미지정 시 default CSP를 빌드. iframe allowed origins는 frame-src에 합성.
/// allocator 소유 — 결과는 process lifetime 유지 (config arena와 연결). 빈 origin 배열이면
/// `frame-src 'none'` (iframe 완전 차단, default safe).
pub fn buildDefaultCsp(allocator: std.mem.Allocator, iframe_allowed_origins: []const []const u8) ![]u8 {
    var frame_src_buf: std.ArrayList(u8) = .empty;
    defer frame_src_buf.deinit(allocator);
    if (iframe_allowed_origins.len == 0) {
        try frame_src_buf.appendSlice(allocator, "'none'");
    } else {
        // ["*"] = unrestricted (escape hatch)
        var unrestricted = false;
        for (iframe_allowed_origins) |o| if (std.mem.eql(u8, o, "*")) {
            unrestricted = true;
            break;
        };
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
    return try std.mem.replaceOwned(u8, allocator, DEFAULT_CSP_TEMPLATE, CSP_FRAME_SRC_SENTINEL, frame_src_buf.items);
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
