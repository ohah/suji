//! @suji/plugin-upload — 파일 업로드(multipart/form-data) / 다운로드(→디스크) (Tauri upload 동등).
//!
//! http 플러그인이 문자열 body 만 다루는 것과 달리, 디스크 파일을 직접 전송/수신한다
//! (JS 메모리에 바이너리를 올리지 않음). 코어 std.http.Client + 파일 I/O 조합.
//!
//! 채널:
//!   upload:upload   {url, filePath, fieldName?, fileName?, contentType?, id?} → {status, body}
//!   upload:download {url, filePath, id?}                                       → {status, bytes}
//!   upload:set_allowed_urls  {urls:[glob,...]}  / upload:get_allowed_urls  {} → {urls}
//!   upload:set_allowed_paths {paths:[prefix,...]}/ upload:get_allowed_paths {} → {paths}
//!   → 완료 시 suji.send("upload:progress", {id, uploaded, total, done:true}).
//!
//! 보안(2중 deny-by-default — http 플러그인 패턴 + fs sandbox 패턴):
//!   - URL allowlist 비어 있으면 모든 요청 차단. scheme http/https 만, userinfo/CRLF 차단,
//!     redirect 미추적(.not_allowed) — SSRF 방지(http 플러그인 동형).
//!   - PATH allowlist 비어 있으면 모든 파일 접근 차단(렌더러가 임의 파일 읽어 업로드=유출,
//!     임의 경로 다운로드=덮어쓰기 방지). `..` 항상 차단, prefix+separator boundary, `*`=escape.
//!
//! 정직 경계: 전송은 bounded in-memory(파일 ≤ 64MB) — 코어가 std.http.Client.fetch(payload)
//!   만 쓰고 low-level streaming request 는 미사용이라 mid-stream progress 불가. 완료
//!   이벤트만 발화(시작/완료). 진짜 청크 progress 는 std.http low-level API 후속.

const std = @import("std");
const suji = @import("suji");
const util = @import("util");

pub const app = suji.app()
    .named("upload")
    .handle("upload:upload", uploadFile)
    .handle("upload:download", downloadFile)
    .handle("upload:set_allowed_urls", setAllowedUrls)
    .handle("upload:get_allowed_urls", getAllowedUrls)
    .handle("upload:set_allowed_paths", setAllowedPaths)
    .handle("upload:get_allowed_paths", getAllowedPaths);

var gpa: std.heap.DebugAllocator(.{}) = .init;
const alloc = gpa.allocator();

fn pluginIo() std.Io {
    return suji.io();
}

const MAX_FILE_BYTES: usize = 64 * 1024 * 1024; // 64MB 파일 상한
const MAX_RESPONSE_BYTES: usize = 16 * 1024 * 1024;
const MAX_URL_LEN: usize = 4096;
const MAX_PATH_LEN: usize = 4096;
const MAX_PATTERN_LEN: usize = 1024;
const MAX_PATTERNS: usize = 256;
const BOUNDARY = "----SujiUploadBoundary7MA4YWxkTrZu0gW";

// ============================================
// Allowlist (URL glob + PATH prefix) — 둘 다 deny-by-default
// ============================================

var allowed_urls: std.ArrayList([]const u8) = .empty;
var urls_mutex: std.Io.Mutex = .init;
var allowed_paths: std.ArrayList([]const u8) = .empty;
var paths_mutex: std.Io.Mutex = .init;

fn matchGlob(pattern: []const u8, text: []const u8) bool {
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

fn isUrlAllowed(url: []const u8) bool {
    urls_mutex.lockUncancelable(pluginIo());
    defer urls_mutex.unlock(pluginIo());
    for (allowed_urls.items) |pat| {
        if (matchGlob(pat, url)) return true;
    }
    return false;
}

/// fs sandbox 동형: `..` 항상 차단, `*`=escape(단 `..` 여전히 차단), 아니면 prefix +
/// separator boundary("/foo" 허용 시 "/fooX" 통과 X). 보안 primitive 는 core `util`
/// 재사용 — fs sandbox(`rendererPathFsGate`)와 단일 출처(util test 가 boundary/`..` 가드).
fn isPathAllowed(path: []const u8) bool {
    if (util.hasParentTraversalSegment(path)) return false;
    paths_mutex.lockUncancelable(pluginIo());
    defer paths_mutex.unlock(pluginIo());
    for (allowed_paths.items) |pat| {
        if (std.mem.eql(u8, pat, "*")) return true;
        if (util.pathHasRootBoundary(path, pat)) return true;
    }
    return false;
}

// ============================================
// URL/JSON helpers (http 플러그인 패턴)
// ============================================

fn validateUrl(req: suji.Request, url: []const u8) ?suji.Response {
    if (url.len == 0 or url.len > MAX_URL_LEN) return req.err("invalid url");
    const is_http = std.mem.startsWith(u8, url, "http://");
    const is_https = std.mem.startsWith(u8, url, "https://");
    if (!is_http and !is_https) return req.err("scheme not allowed");
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return req.err("invalid url");
    const authority_start = scheme_end + 3;
    const authority_end = std.mem.indexOfAnyPos(u8, url, authority_start, "/?#") orelse url.len;
    if (std.mem.indexOfScalarPos(u8, url[0..authority_end], authority_start, '@') != null) {
        return req.err("userinfo not allowed");
    }
    for (url) |c| if (c == '\r' or c == '\n' or c == 0) return req.err("invalid url");
    if (!isUrlAllowed(url)) return req.err("forbidden url");
    return null; // ok
}

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

fn cGetenv(name: [*:0]const u8) ?[]const u8 {
    const raw = std.c.getenv(name) orelse return null;
    return std.mem.span(raw);
}

/// `~` prefix 를 $HOME 으로 확장(arena). 아니면 그대로.
fn expandHome(arena: std.mem.Allocator, path: []const u8) []const u8 {
    if (path.len == 0 or path[0] != '~') return path;
    const home = cGetenv("HOME") orelse cGetenv("USERPROFILE") orelse return path;
    return std.fmt.allocPrint(arena, "{s}{s}", .{ home, path[1..] }) catch path;
}

/// multipart 폼 필드 값(파일명/필드명) 안의 `"`/CR/LF 차단 — 헤더 인젝션 방지.
fn validFormToken(s: []const u8) bool {
    if (s.len == 0 or s.len > 256) return false;
    for (s) |c| {
        if (c == '"' or c == '\r' or c == '\n' or c == 0) return false;
    }
    return true;
}

/// 완료 progress 발화. id 는 렌더러 제어 문자열이라 반드시 JSON-escape(다른 출력과 동일
/// 포스처) + arena 빌드(고정 버퍼 오버플로 회피).
fn emitProgress(arena: std.mem.Allocator, id: []const u8, n: u64) void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(arena);
    buf.appendSlice(arena, "{\"id\":\"") catch return;
    appendJsonEscaped(&buf, arena, id) catch return;
    var tmp: [64]u8 = undefined;
    const tail = std.fmt.bufPrint(&tmp, "\",\"uploaded\":{d},\"total\":{d},\"done\":true}}", .{ n, n }) catch return;
    buf.appendSlice(arena, tail) catch return;
    suji.send("upload:progress", buf.items);
}

// ============================================
// Handlers
// ============================================

fn uploadFile(req: suji.Request, _: suji.InvokeEvent) suji.Response {
    const url = req.string("url") orelse return req.err("missing url");
    if (validateUrl(req, url)) |e| return e;
    const raw_path = req.string("filePath") orelse return req.err("missing filePath");
    if (raw_path.len == 0 or raw_path.len > MAX_PATH_LEN) return req.err("invalid filePath");
    const file_path = expandHome(req.arena, raw_path);
    if (!isPathAllowed(file_path)) return req.err("forbidden path");

    const field = req.string("fieldName") orelse "file";
    const fname = req.string("fileName") orelse "upload";
    const ctype = req.string("contentType") orelse "application/octet-stream";
    if (!validFormToken(field) or !validFormToken(fname) or !validFormToken(ctype)) return req.err("invalid form field");
    const id = req.string("id") orelse "";
    if (id.len > 256) return req.err("id too long");

    const file_data = std.Io.Dir.cwd().readFileAlloc(pluginIo(), file_path, req.arena, .limited(MAX_FILE_BYTES)) catch return req.err("read failed");

    // boundary 충돌 방지 — 파일에 boundary 가 있으면 multipart 손상.
    if (std.mem.indexOf(u8, file_data, BOUNDARY) != null) return req.err("boundary collision");

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(req.arena);
    body.appendSlice(req.arena, "--" ++ BOUNDARY ++ "\r\nContent-Disposition: form-data; name=\"") catch return req.err("alloc");
    body.appendSlice(req.arena, field) catch return req.err("alloc");
    body.appendSlice(req.arena, "\"; filename=\"") catch return req.err("alloc");
    body.appendSlice(req.arena, fname) catch return req.err("alloc");
    body.appendSlice(req.arena, "\"\r\nContent-Type: ") catch return req.err("alloc");
    body.appendSlice(req.arena, ctype) catch return req.err("alloc");
    body.appendSlice(req.arena, "\r\n\r\n") catch return req.err("alloc");
    body.appendSlice(req.arena, file_data) catch return req.err("alloc");
    body.appendSlice(req.arena, "\r\n--" ++ BOUNDARY ++ "--\r\n") catch return req.err("alloc");

    var client: std.http.Client = .{ .allocator = alloc, .io = pluginIo() };
    defer client.deinit();

    const resp_buf = alloc.alloc(u8, MAX_RESPONSE_BYTES) catch return req.err("alloc");
    defer alloc.free(resp_buf);
    var resp_writer: std.Io.Writer = .fixed(resp_buf);

    const ct_header = std.http.Header{ .name = "Content-Type", .value = "multipart/form-data; boundary=" ++ BOUNDARY };
    const r = client.fetch(.{
        .location = .{ .url = url },
        .payload = body.items, // payload 존재 → POST (http 플러그인 동형, method 추론)
        .extra_headers = &.{ct_header},
        .response_writer = &resp_writer,
        .redirect_behavior = .not_allowed,
    }) catch |e| {
        if (e == error.WriteFailed) return req.err("response too large");
        return req.err("upload failed");
    };

    emitProgress(req.arena, id, file_data.len);

    const body_slice = resp_buf[0..resp_writer.end];
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(req.arena);
    out.appendSlice(req.arena, "{\"status\":") catch return req.err("alloc");
    var tmp: [16]u8 = undefined;
    out.appendSlice(req.arena, std.fmt.bufPrint(&tmp, "{d}", .{@intFromEnum(r.status)}) catch return req.err("alloc")) catch return req.err("alloc");
    out.appendSlice(req.arena, ",\"body\":\"") catch return req.err("alloc");
    appendJsonEscaped(&out, req.arena, body_slice) catch return req.err("alloc");
    out.appendSlice(req.arena, "\"}") catch return req.err("alloc");
    return req.okRaw(out.toOwnedSlice(req.arena) catch return req.err("alloc"));
}

fn downloadFile(req: suji.Request, _: suji.InvokeEvent) suji.Response {
    const url = req.string("url") orelse return req.err("missing url");
    if (validateUrl(req, url)) |e| return e;
    const raw_path = req.string("filePath") orelse return req.err("missing filePath");
    if (raw_path.len == 0 or raw_path.len > MAX_PATH_LEN) return req.err("invalid filePath");
    const file_path = expandHome(req.arena, raw_path);
    if (!isPathAllowed(file_path)) return req.err("forbidden path");
    const id = req.string("id") orelse "";
    if (id.len > 256) return req.err("id too long");

    var client: std.http.Client = .{ .allocator = alloc, .io = pluginIo() };
    defer client.deinit();

    const resp_buf = alloc.alloc(u8, MAX_RESPONSE_BYTES) catch return req.err("alloc");
    defer alloc.free(resp_buf);
    var resp_writer: std.Io.Writer = .fixed(resp_buf);

    const r = client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &resp_writer,
        .redirect_behavior = .not_allowed,
    }) catch |e| {
        if (e == error.WriteFailed) return req.err("response too large");
        return req.err("download failed");
    };

    const data = resp_buf[0..resp_writer.end];

    // atomic write (.tmp → rename) — store/window-state 패턴.
    const io = pluginIo();
    if (std.mem.lastIndexOfAny(u8, file_path, "/\\")) |sep| {
        std.Io.Dir.cwd().createDirPath(io, file_path[0..sep]) catch {};
    }
    const tmp_path = std.fmt.allocPrint(req.arena, "{s}.tmp", .{file_path}) catch return req.err("alloc");
    var f = std.Io.Dir.cwd().createFile(io, tmp_path, .{}) catch return req.err("write failed");
    f.writePositionalAll(io, data, 0) catch {
        f.close(io);
        std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
        return req.err("write failed");
    };
    f.close(io);
    if (@import("builtin").os.tag == .windows) std.Io.Dir.cwd().deleteFile(io, file_path) catch {};
    std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), file_path, io) catch {
        std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
        return req.err("write failed");
    };

    emitProgress(req.arena, id, data.len);

    var tmp: [16]u8 = undefined;
    const body = std.fmt.allocPrint(
        req.arena,
        "{{\"status\":{s},\"bytes\":{d}}}",
        .{ std.fmt.bufPrint(&tmp, "{d}", .{@intFromEnum(r.status)}) catch return req.err("alloc"), data.len },
    ) catch return req.err("alloc");
    return req.okRaw(body);
}

// ── allowlist setters/getters (http 플러그인 동형) ──

fn parseStringArrayInto(req: suji.Request, key: []const u8, mutex: *std.Io.Mutex, list: *std.ArrayList([]const u8), expand_home: bool) ?suji.Response {
    const raw = suji.extractJsonValue(req.raw, key) orelse return req.err("missing array");
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, raw, .{}) catch return req.err("invalid array");
    defer parsed.deinit();
    if (parsed.value != .array) return req.err("must be array");
    if (parsed.value.array.items.len > MAX_PATTERNS) return req.err("too many patterns");

    var new_list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (new_list.items) |p| alloc.free(p);
        new_list.deinit(alloc);
    }
    for (parsed.value.array.items) |val| {
        if (val != .string) return req.err("pattern not string");
        if (val.string.len == 0 or val.string.len > MAX_PATTERN_LEN) return req.err("invalid pattern");
        // PATH 패턴은 `~` → $HOME 확장 — filePath 도 expandHome 되므로 양쪽을 맞춘다.
        // 안 하면 "~/Documents" allowlist 가 확장된 "/Users/x/Documents/..." 와 절대 매치 X.
        var home_buf: [MAX_PATH_LEN]u8 = undefined;
        const to_store: []const u8 = if (expand_home and val.string[0] == '~') blk: {
            const home = cGetenv("HOME") orelse cGetenv("USERPROFILE") orelse break :blk val.string;
            break :blk std.fmt.bufPrint(&home_buf, "{s}{s}", .{ home, val.string[1..] }) catch break :blk val.string;
        } else val.string;
        const owned = alloc.dupe(u8, to_store) catch return req.err("alloc");
        new_list.append(alloc, owned) catch {
            alloc.free(owned);
            return req.err("alloc");
        };
    }

    mutex.lockUncancelable(pluginIo());
    defer mutex.unlock(pluginIo());
    for (list.items) |p| alloc.free(p);
    list.deinit(alloc);
    list.* = new_list;
    return null;
}

fn emitStringArray(req: suji.Request, key: []const u8, mutex: *std.Io.Mutex, list: *std.ArrayList([]const u8)) suji.Response {
    mutex.lockUncancelable(pluginIo());
    defer mutex.unlock(pluginIo());
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(req.arena);
    out.appendSlice(req.arena, "{\"") catch return req.err("alloc");
    out.appendSlice(req.arena, key) catch return req.err("alloc");
    out.appendSlice(req.arena, "\":[") catch return req.err("alloc");
    for (list.items, 0..) |item, i| {
        if (i > 0) out.append(req.arena, ',') catch return req.err("alloc");
        out.append(req.arena, '"') catch return req.err("alloc");
        appendJsonEscaped(&out, req.arena, item) catch return req.err("alloc");
        out.append(req.arena, '"') catch return req.err("alloc");
    }
    out.appendSlice(req.arena, "]}") catch return req.err("alloc");
    return req.okRaw(out.toOwnedSlice(req.arena) catch return req.err("alloc"));
}

fn setAllowedUrls(req: suji.Request, _: suji.InvokeEvent) suji.Response {
    if (parseStringArrayInto(req, "urls", &urls_mutex, &allowed_urls, false)) |e| return e;
    return req.okRaw("{\"ok\":true}");
}
fn getAllowedUrls(req: suji.Request, _: suji.InvokeEvent) suji.Response {
    return emitStringArray(req, "urls", &urls_mutex, &allowed_urls);
}
fn setAllowedPaths(req: suji.Request, _: suji.InvokeEvent) suji.Response {
    if (parseStringArrayInto(req, "paths", &paths_mutex, &allowed_paths, true)) |e| return e;
    return req.okRaw("{\"ok\":true}");
}
fn getAllowedPaths(req: suji.Request, _: suji.InvokeEvent) suji.Response {
    return emitStringArray(req, "paths", &paths_mutex, &allowed_paths);
}

comptime {
    _ = suji.exportApp(app);
}
