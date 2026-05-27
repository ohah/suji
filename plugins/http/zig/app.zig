//! @suji/plugin-http — renderer-safe HTTP fetch with URL allowlist.
//!
//! 데스크톱 `suji.http.fetch` 는 backend-only (frontend 미노출 — 보안 정책).
//! 이 플러그인은 명시적 allowlist 게이트를 통해 frontend 에서도 fetch 호출
//! 가능하게 한다 (Electron `webRequest` allowlist + `net.fetch` 패턴).
//!
//! 채널:
//!   http:fetch              {url, method?, body?}        → {status, body, headers?}
//!   http:set_allowed_urls   {urls: [glob_pattern, ...]}  → {ok:true}
//!   http:get_allowed_urls   {}                            → {urls: [...]}
//!
//! 정책:
//!   - 기본 allowlist 비어 있음 — 모든 fetch 차단 (deny-by-default, fs 와 동일).
//!   - URL glob 매칭은 `util.matchGlob` 재사용 (`https://*.example.com/*` 등).
//!   - 응답 body 최대 16MB (DoS 방지). 초과 시 error.
//!   - method 미지정 = GET, body 있고 method 미지정 = POST.
//!   - 사용자 헤더는 v1 미지원 (Cookie/Authorization 누출 위험 — 후속).

const std = @import("std");
const suji = @import("suji");

pub const app = suji.app()
    .named("http")
    .handle("http:fetch", httpFetch)
    .handle("http:set_allowed_urls", httpSetAllowedUrls)
    .handle("http:get_allowed_urls", httpGetAllowedUrls)
    .handle("http:set_allowed_headers", httpSetAllowedHeaders)
    .handle("http:get_allowed_headers", httpGetAllowedHeaders);

var gpa: std.heap.DebugAllocator(.{}) = .init;
const alloc = gpa.allocator();

fn pluginIo() std.Io {
    return suji.io();
}

const MAX_RESPONSE_BYTES: usize = 16 * 1024 * 1024;
const MAX_URL_LEN: usize = 4096;
const MAX_PATTERN_LEN: usize = 1024;
const MAX_PATTERNS: usize = 256;
const MAX_BODY_BYTES: usize = 16 * 1024 * 1024;
const MAX_HEADERS_PER_REQUEST: usize = 16;
const MAX_HEADER_NAME_LEN: usize = 128;
const MAX_HEADER_VALUE_LEN: usize = 4096;
const MAX_ALLOWED_HEADERS: usize = 32;

// ============================================
// Allowlist
// ============================================

var allowed_urls: std.ArrayList([]const u8) = .empty;
var allowed_mutex: std.Io.Mutex = .init;

var allowed_headers: std.ArrayList([]const u8) = .empty;
var allowed_headers_mutex: std.Io.Mutex = .init;

fn matchGlob(pattern: []const u8, text: []const u8) bool {
    // src/core/util.zig matchGlob 미러 — 플러그인은 util import 안 함, 동형 구현.
    var pi: usize = 0;
    var ti: usize = 0;
    var star_pi: ?usize = null;
    var star_ti: usize = 0;
    while (ti < text.len) {
        if (pi < pattern.len and pattern[pi] == '*') {
            star_pi = pi;
            star_ti = ti;
            pi += 1;
        } else if (pi < pattern.len and pattern[pi] == '?') {
            pi += 1;
            ti += 1;
        } else if (pi < pattern.len and pattern[pi] == text[ti]) {
            pi += 1;
            ti += 1;
        } else if (star_pi) |sp| {
            pi = sp + 1;
            star_ti += 1;
            ti = star_ti;
        } else {
            return false;
        }
    }
    while (pi < pattern.len and pattern[pi] == '*') pi += 1;
    return pi == pattern.len;
}

fn isAllowed(url: []const u8) bool {
    allowed_mutex.lockUncancelable(pluginIo());
    defer allowed_mutex.unlock(pluginIo());
    for (allowed_urls.items) |pat| {
        if (matchGlob(pat, url)) return true;
    }
    return false;
}

fn clearAllowed() void {
    for (allowed_urls.items) |p| alloc.free(p);
    allowed_urls.clearRetainingCapacity();
}

fn clearAllowedHeaders() void {
    for (allowed_headers.items) |h| alloc.free(h);
    allowed_headers.clearRetainingCapacity();
}

/// RFC 7230 token char: alpha/digit + !#$%&'*+-.^_`|~
fn isHeaderTokenChar(c: u8) bool {
    if (std.ascii.isAlphanumeric(c)) return true;
    return switch (c) {
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}

fn isValidHeaderName(name: []const u8) bool {
    if (name.len == 0 or name.len > MAX_HEADER_NAME_LEN) return false;
    for (name) |c| if (!isHeaderTokenChar(c)) return false;
    return true;
}

/// CRLF/NUL 차단 — std.http.Client 도 assert 하지만 정직 경계로 사전 차단.
fn isValidHeaderValue(value: []const u8) bool {
    if (value.len > MAX_HEADER_VALUE_LEN) return false;
    for (value) |c| {
        if (c == '\r' or c == '\n' or c == 0) return false;
    }
    return true;
}

fn isHeaderAllowed(name: []const u8) bool {
    allowed_headers_mutex.lockUncancelable(pluginIo());
    defer allowed_headers_mutex.unlock(pluginIo());
    for (allowed_headers.items) |allowed| {
        if (std.ascii.eqlIgnoreCase(allowed, name)) return true;
    }
    return false;
}

// ============================================
// JSON helpers
// ============================================

fn appendJsonEscaped(buf: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(a, "\\\""),
            '\\' => try buf.appendSlice(a, "\\\\"),
            '\n' => try buf.appendSlice(a, "\\n"),
            '\r' => try buf.appendSlice(a, "\\r"),
            '\t' => try buf.appendSlice(a, "\\t"),
            0...8, 11, 12, 14...31 => {
                var tmp: [6]u8 = undefined;
                const out = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c}) catch continue;
                try buf.appendSlice(a, out);
            },
            else => try buf.append(a, c),
        }
    }
}

// ============================================
// Handlers
// ============================================

fn httpFetch(req: suji.Request, _: suji.InvokeEvent) suji.Response {
    const url = req.string("url") orelse return req.err("missing url");
    if (url.len == 0 or url.len > MAX_URL_LEN) return req.err("invalid url");

    // 스킴 검사 — http:/https: 만 허용 (file:, data:, javascript: 차단).
    const is_http = std.mem.startsWith(u8, url, "http://");
    const is_https = std.mem.startsWith(u8, url, "https://");
    if (!is_http and !is_https) return req.err("scheme not allowed");

    // userinfo bypass 차단 — `https://allowed.com@evil.com/` 같은 URL 은 glob
    // `https://allowed.com/*` 에 매치되지만 실제 std.http.Client 는 `evil.com` 으로
    // 연결한다(RFC 3986 authority = userinfo@host). authority 안의 `@` 거부.
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return req.err("invalid url");
    const authority_start = scheme_end + 3;
    const authority_end = std.mem.indexOfAnyPos(u8, url, authority_start, "/?#") orelse url.len;
    if (std.mem.indexOfScalarPos(u8, url[0..authority_end], authority_start, '@') != null) {
        return req.err("userinfo not allowed");
    }
    // CRLF/NUL injection — std.http.Client 도 보통 거부하지만 정직 경계로 사전 차단.
    for (url) |c| if (c == '\r' or c == '\n' or c == 0) return req.err("invalid url");

    if (!isAllowed(url)) return req.err("forbidden");

    const method_str = req.string("method");
    const body = req.string("body");
    if (body) |b| if (b.len > MAX_BODY_BYTES) return req.err("body too large");

    var is_post: bool = false;
    if (method_str) |m| {
        if (std.ascii.eqlIgnoreCase(m, "POST")) is_post = true
        else if (std.ascii.eqlIgnoreCase(m, "GET")) is_post = false
        else return req.err("method not allowed");
    } else {
        is_post = body != null;
    }

    // headers 처리 — set_allowed_headers 로 등록한 이름만 허용. 응답에 잘못된
    // 이름/값이 있으면 fetch 안 시도 하고 즉시 error 반환.
    var extra_headers: std.ArrayList(std.http.Header) = .empty;
    defer extra_headers.deinit(req.arena);
    if (suji.extractJsonValue(req.raw, "headers")) |headers_raw| {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, headers_raw, .{}) catch return req.err("invalid headers");
        defer parsed.deinit();
        if (parsed.value != .object) return req.err("headers must be object");
        if (parsed.value.object.count() > MAX_HEADERS_PER_REQUEST) return req.err("too many headers");
        var iter = parsed.value.object.iterator();
        while (iter.next()) |entry| {
            const name = entry.key_ptr.*;
            if (entry.value_ptr.* != .string) return req.err("header value not string");
            const value = entry.value_ptr.*.string;
            if (!isValidHeaderName(name)) return req.err("invalid header name");
            if (!isValidHeaderValue(value)) return req.err("invalid header value");
            if (!isHeaderAllowed(name)) return req.err("header not allowed");
            // arena 에 복제 — parsed 의 lifetime 은 이 블록만, fetch 호출시까지 살아야 함.
            const name_dup = req.arena.dupe(u8, name) catch return req.err("alloc");
            const value_dup = req.arena.dupe(u8, value) catch return req.err("alloc");
            extra_headers.append(req.arena, .{ .name = name_dup, .value = value_dup }) catch return req.err("alloc");
        }
    }

    var client: std.http.Client = .{ .allocator = alloc, .io = pluginIo() };
    defer client.deinit();

    // streaming response bound — 16MB 고정 버퍼에 직접 쓰고 초과 시 fetch 가
    // error.WriteFailed 반환. 이전 Allocating writer 는 전체 body 를 할당한 뒤
    // 사후 검사라 10GB 응답 = 10GB 할당. 이제 ceiling 보장 + OOM 방지.
    // Trade-off: 응답이 작아도 16MB 항상 사전 할당(per-fetch 일회성).
    const resp_buf = alloc.alloc(u8, MAX_RESPONSE_BYTES) catch return req.err("alloc");
    defer alloc.free(resp_buf);
    var resp_writer: std.Io.Writer = .fixed(resp_buf);

    const fetch_payload: ?[]const u8 = if (is_post) (body orelse "") else null;

    // redirect SSRF 차단 — allowlist 가 최초 URL 만 검증하므로, `https://allowed/r`
    // → 3xx → `http://169.254.169.254/...` 같은 redirect 가 게이트를 우회한다.
    // `.not_allowed` = 3xx 응답을 그대로 받고 fetch 가 redirect 따라가지 않음.
    const r = client.fetch(.{
        .location = .{ .url = url },
        .payload = fetch_payload,
        .extra_headers = extra_headers.items,
        .response_writer = &resp_writer,
        .redirect_behavior = .not_allowed,
    }) catch |e| {
        if (e == error.WriteFailed) return req.err("response too large");
        return req.err("fetch failed");
    };

    const body_slice = resp_buf[0..resp_writer.end];

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(req.arena);
    out.appendSlice(req.arena, "{\"status\":") catch return req.err("alloc");
    var tmp: [16]u8 = undefined;
    const status_str = std.fmt.bufPrint(&tmp, "{d}", .{@intFromEnum(r.status)}) catch return req.err("alloc");
    out.appendSlice(req.arena, status_str) catch return req.err("alloc");
    out.appendSlice(req.arena, ",\"body\":\"") catch return req.err("alloc");
    appendJsonEscaped(&out, req.arena, body_slice) catch return req.err("alloc");
    out.appendSlice(req.arena, "\"}") catch return req.err("alloc");
    const final = out.toOwnedSlice(req.arena) catch return req.err("alloc");
    return req.okRaw(final);
}

fn httpSetAllowedUrls(req: suji.Request, _: suji.InvokeEvent) suji.Response {
    const raw_array = suji.extractJsonValue(req.raw, "urls") orelse return req.err("missing urls");

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, raw_array, .{}) catch return req.err("invalid urls");
    defer parsed.deinit();
    if (parsed.value != .array) return req.err("urls must be array");
    if (parsed.value.array.items.len > MAX_PATTERNS) return req.err("too many patterns");

    var new_list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (new_list.items) |p| alloc.free(p);
        new_list.deinit(alloc);
    }
    for (parsed.value.array.items) |val| {
        if (val != .string) return req.err("pattern not string");
        if (val.string.len == 0 or val.string.len > MAX_PATTERN_LEN) return req.err("invalid pattern");
        const owned = alloc.dupe(u8, val.string) catch return req.err("alloc");
        new_list.append(alloc, owned) catch {
            alloc.free(owned);
            return req.err("alloc");
        };
    }

    allowed_mutex.lockUncancelable(pluginIo());
    defer allowed_mutex.unlock(pluginIo());
    clearAllowed();
    allowed_urls.deinit(alloc);
    allowed_urls = new_list;
    return req.okRaw("{\"ok\":true}");
}

fn httpSetAllowedHeaders(req: suji.Request, _: suji.InvokeEvent) suji.Response {
    const raw_array = suji.extractJsonValue(req.raw, "headers") orelse return req.err("missing headers");

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, raw_array, .{}) catch return req.err("invalid headers");
    defer parsed.deinit();
    if (parsed.value != .array) return req.err("headers must be array");
    if (parsed.value.array.items.len > MAX_ALLOWED_HEADERS) return req.err("too many headers");

    var new_list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (new_list.items) |h| alloc.free(h);
        new_list.deinit(alloc);
    }
    for (parsed.value.array.items) |val| {
        if (val != .string) return req.err("header name not string");
        if (!isValidHeaderName(val.string)) return req.err("invalid header name");
        const owned = alloc.dupe(u8, val.string) catch return req.err("alloc");
        new_list.append(alloc, owned) catch {
            alloc.free(owned);
            return req.err("alloc");
        };
    }

    allowed_headers_mutex.lockUncancelable(pluginIo());
    defer allowed_headers_mutex.unlock(pluginIo());
    clearAllowedHeaders();
    allowed_headers.deinit(alloc);
    allowed_headers = new_list;
    return req.okRaw("{\"ok\":true}");
}

fn httpGetAllowedHeaders(req: suji.Request, _: suji.InvokeEvent) suji.Response {
    allowed_headers_mutex.lockUncancelable(pluginIo());
    defer allowed_headers_mutex.unlock(pluginIo());

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(req.arena);
    out.appendSlice(req.arena, "{\"headers\":[") catch return req.err("alloc");
    for (allowed_headers.items, 0..) |name, i| {
        if (i > 0) out.append(req.arena, ',') catch return req.err("alloc");
        out.append(req.arena, '"') catch return req.err("alloc");
        appendJsonEscaped(&out, req.arena, name) catch return req.err("alloc");
        out.append(req.arena, '"') catch return req.err("alloc");
    }
    out.appendSlice(req.arena, "]}") catch return req.err("alloc");
    const final = out.toOwnedSlice(req.arena) catch return req.err("alloc");
    return req.okRaw(final);
}

fn httpGetAllowedUrls(req: suji.Request, _: suji.InvokeEvent) suji.Response {
    allowed_mutex.lockUncancelable(pluginIo());
    defer allowed_mutex.unlock(pluginIo());

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(req.arena);
    out.appendSlice(req.arena, "{\"urls\":[") catch return req.err("alloc");
    for (allowed_urls.items, 0..) |pat, i| {
        if (i > 0) out.append(req.arena, ',') catch return req.err("alloc");
        out.append(req.arena, '"') catch return req.err("alloc");
        appendJsonEscaped(&out, req.arena, pat) catch return req.err("alloc");
        out.append(req.arena, '"') catch return req.err("alloc");
    }
    out.appendSlice(req.arena, "]}") catch return req.err("alloc");
    const final = out.toOwnedSlice(req.arena) catch return req.err("alloc");
    return req.okRaw(final);
}

comptime {
    _ = suji.exportApp(app);
}
