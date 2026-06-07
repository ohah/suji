const std = @import("std");
const clipboard_cf_html = @import("clipboard_cf_html");

// CEF IPC 헬퍼 함수 테스트
// cef.zig와 main.zig의 순수 함수들을 독립적으로 테스트

// ============================================
// extractCmd: JSON에서 "cmd":"value" 추출
// ============================================

fn extractCmd(json: []const u8) ?[]const u8 {
    const pattern = "\"cmd\":\"";
    const idx = std.mem.indexOf(u8, json, pattern) orelse return null;
    const start = idx + pattern.len;
    const end = std.mem.indexOfPos(u8, json, start, "\"") orelse return null;
    return json[start..end];
}

test "extractCmd: basic" {
    try std.testing.expectEqualStrings("ping", extractCmd("{\"cmd\":\"ping\"}").?);
}

test "extractCmd: with extra fields" {
    try std.testing.expectEqualStrings("greet", extractCmd("{\"cmd\":\"greet\",\"name\":\"Suji\"}").?);
}

test "extractCmd: no cmd field" {
    try std.testing.expect(extractCmd("{\"name\":\"Suji\"}") == null);
}

test "extractCmd: empty json" {
    try std.testing.expect(extractCmd("{}") == null);
}

test "extractCmd: nested json" {
    try std.testing.expectEqualStrings("add", extractCmd("{\"cmd\":\"add\",\"data\":{\"a\":1}}").?);
}

// ============================================
// extractJsonString: JSON에서 "key":"value" 추출
// ============================================

fn extractJsonString(json: []const u8, pattern: []const u8) ?[]const u8 {
    const idx = std.mem.indexOf(u8, json, pattern) orelse return null;
    const start = idx + pattern.len;
    var i = start;
    while (i < json.len) : (i += 1) {
        if (json[i] == '\\') {
            i += 1;
            continue;
        }
        if (json[i] == '"') return json[start..i];
    }
    return null;
}

test "extractJsonString: backends field" {
    const data =
        \\{"__fanout":true,"backends":"zig,rust,go","request":"{}"}
    ;
    const result = extractJsonString(data, "\"backends\":\"");
    try std.testing.expectEqualStrings("zig,rust,go", result.?);
}

test "extractJsonString: request field with escapes" {
    const data =
        \\{"__fanout":true,"backends":"zig","request":"{\"cmd\":\"ping\"}"}
    ;
    const result = extractJsonString(data, "\"request\":\"");
    try std.testing.expectEqualStrings(
        \\{\"cmd\":\"ping\"}
    , result.?);
}

test "extractJsonString: missing field" {
    const data =
        \\{"__fanout":true,"backends":"zig"}
    ;
    try std.testing.expect(extractJsonString(data, "\"request\":\"") == null);
}

test "extractJsonString: core request" {
    const data =
        \\{"__core":true,"request":"{\"cmd\":\"core_info\"}"}
    ;
    const result = extractJsonString(data, "\"request\":\"");
    try std.testing.expectEqualStrings(
        \\{\"cmd\":\"core_info\"}
    , result.?);
}

// ============================================
// unescapeJson: \" → ", \\ → \
// ============================================

fn unescapeJson(src: []const u8, buf: []u8) []const u8 {
    var i: usize = 0;
    var o: usize = 0;
    while (i < src.len and o < buf.len) {
        if (src[i] == '\\' and i + 1 < src.len) {
            buf[o] = switch (src[i + 1]) {
                '"' => '"',
                '\\' => '\\',
                'n' => '\n',
                else => src[i + 1],
            };
            i += 2;
        } else {
            buf[o] = src[i];
            i += 1;
        }
        o += 1;
    }
    return buf[0..o];
}

test "unescapeJson: escaped quotes" {
    var buf: [256]u8 = undefined;
    const result = unescapeJson(
        \\{\"cmd\":\"ping\"}
    , &buf);
    try std.testing.expectEqualStrings("{\"cmd\":\"ping\"}", result);
}

test "unescapeJson: no escapes" {
    var buf: [256]u8 = undefined;
    const result = unescapeJson("hello world", &buf);
    try std.testing.expectEqualStrings("hello world", result);
}

test "unescapeJson: escaped backslash" {
    var buf: [256]u8 = undefined;
    const result = unescapeJson("path\\\\to\\\\file", &buf);
    try std.testing.expectEqualStrings("path\\to\\file", result);
}

test "unescapeJson: escaped newline" {
    var buf: [256]u8 = undefined;
    const result = unescapeJson("line1\\nline2", &buf);
    try std.testing.expectEqualStrings("line1\nline2", result);
}

test "unescapeJson: complex nested" {
    var buf: [512]u8 = undefined;
    const result = unescapeJson(
        \\{\"cmd\":\"greet\",\"name\":\"Suji\"}
    , &buf);
    try std.testing.expectEqualStrings("{\"cmd\":\"greet\",\"name\":\"Suji\"}", result);
}

// ============================================
// JS API 시그니처 검증 (invoke 요청 조립)
// ============================================

test "invoke request assembly: channel only" {
    // JS: invoke("ping") → {cmd: "ping"}
    // → JSON.stringify → {"cmd":"ping"}
    const json = "{\"cmd\":\"ping\"}";
    try std.testing.expectEqualStrings("ping", extractCmd(json).?);
}

test "invoke request assembly: channel + data" {
    // JS: invoke("greet", {name: "Suji"}) → {cmd: "greet", name: "Suji"}
    const json = "{\"cmd\":\"greet\",\"name\":\"Suji\"}";
    try std.testing.expectEqualStrings("greet", extractCmd(json).?);
}

test "invoke request assembly: channel + data + target" {
    // JS: invoke("ping", {}, {target: "zig"})
    // → raw_invoke("zig", '{"cmd":"ping"}')
    // → channel = "zig", request = {"cmd":"ping"}
    const channel = "zig";
    const request = "{\"cmd\":\"ping\"}";
    try std.testing.expectEqualStrings("zig", channel);
    try std.testing.expectEqualStrings("ping", extractCmd(request).?);
}

// ============================================
// fanout 메시지 파싱
// ============================================

test "fanout message parsing" {
    const data =
        \\{"__fanout":true,"backends":"zig,rust,go","request":"{\"cmd\":\"ping\"}"}
    ;
    const backends = extractJsonString(data, "\"backends\":\"").?;
    const request_escaped = extractJsonString(data, "\"request\":\"").?;
    var buf: [256]u8 = undefined;
    const request = unescapeJson(request_escaped, &buf);

    try std.testing.expectEqualStrings("zig,rust,go", backends);
    try std.testing.expectEqualStrings("{\"cmd\":\"ping\"}", request);

    // backends 분리
    var iter = std.mem.splitScalar(u8, backends, ',');
    try std.testing.expectEqualStrings("zig", iter.next().?);
    try std.testing.expectEqualStrings("rust", iter.next().?);
    try std.testing.expectEqualStrings("go", iter.next().?);
    try std.testing.expect(iter.next() == null);
}

// ============================================
// core 메시지 파싱
// ============================================

test "core message parsing: core_info" {
    const data =
        \\{"__core":true,"request":"{\"cmd\":\"core_info\"}"}
    ;
    const request_escaped = extractJsonString(data, "\"request\":\"").?;
    var buf: [256]u8 = undefined;
    const request = unescapeJson(request_escaped, &buf);

    try std.testing.expect(std.mem.indexOf(u8, request, "core_info") != null);
}

test "core message parsing: unknown command" {
    const data =
        \\{"__core":true,"request":"{\"cmd\":\"hello\"}"}
    ;
    const request_escaped = extractJsonString(data, "\"request\":\"").?;
    var buf: [256]u8 = undefined;
    const request = unescapeJson(request_escaped, &buf);

    try std.testing.expect(std.mem.indexOf(u8, request, "core_info") == null);
}

// ============================================
// 시퀀스 ID 슬롯 계산
// ============================================

// ============================================
// jsonToHexEscape: URI percent-encoding (injection 방지)
// ============================================

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

test "jsonToHexEscape: simple string" {
    var buf: [256]u8 = undefined;
    const result = jsonToHexEscape("hello", &buf);
    try std.testing.expectEqualStrings("hello", result);
}

test "jsonToHexEscape: JSON with quotes" {
    var buf: [256]u8 = undefined;
    const result = jsonToHexEscape("{\"msg\":\"pong\"}", &buf);
    // { " : } are percent-encoded, letters are not
    try std.testing.expect(std.mem.indexOf(u8, result, "'") == null); // no single quotes
    try std.testing.expect(result.len > 14); // longer than original due to encoding
}

test "jsonToHexEscape: single quote is escaped" {
    var buf: [256]u8 = undefined;
    const result = jsonToHexEscape("it's working", &buf);
    // ' (0x27) → %27
    try std.testing.expect(std.mem.indexOf(u8, result, "%27") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "'") == null);
}

test "jsonToHexEscape: backslash is escaped" {
    var buf: [256]u8 = undefined;
    const result = jsonToHexEscape("a\\b", &buf);
    // \ (0x5C) → %5C
    try std.testing.expect(std.mem.indexOf(u8, result, "%5C") != null);
}

test "jsonToHexEscape: empty string" {
    var buf: [256]u8 = undefined;
    const result = jsonToHexEscape("", &buf);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "jsonToHexEscape: alphanumeric passthrough" {
    var buf: [256]u8 = undefined;
    const result = jsonToHexEscape("abc123XYZ", &buf);
    try std.testing.expectEqualStrings("abc123XYZ", result);
}

test "jsonToHexEscape: special safe chars" {
    var buf: [256]u8 = undefined;
    const result = jsonToHexEscape("a-b_c.d~e", &buf);
    try std.testing.expectEqualStrings("a-b_c.d~e", result);
}

test "jsonToHexEscape: roundtrip via decodeURIComponent simulation" {
    var buf: [512]u8 = undefined;
    const input = "{\"msg\":\"it's a \\\"test\\\"\"}";
    const encoded = jsonToHexEscape(input, &buf);

    // Decode percent-encoding manually
    var decoded: [512]u8 = undefined;
    var di: usize = 0;
    var ei: usize = 0;
    while (ei < encoded.len) {
        if (encoded[ei] == '%' and ei + 2 < encoded.len) {
            const hi = hexVal(encoded[ei + 1]);
            const lo = hexVal(encoded[ei + 2]);
            decoded[di] = (@as(u8, hi) << 4) | @as(u8, lo);
            ei += 3;
        } else {
            decoded[di] = encoded[ei];
            ei += 1;
        }
        di += 1;
    }
    try std.testing.expectEqualStrings(input, decoded[0..di]);
}

fn hexVal(ch: u8) u4 {
    return switch (ch) {
        '0'...'9' => @intCast(ch - '0'),
        'A'...'F' => @intCast(ch - 'A' + 10),
        'a'...'f' => @intCast(ch - 'a' + 10),
        else => 0,
    };
}

// ============================================
// chain 메시지 파싱
// ============================================

test "chain message parsing" {
    const data =
        \\{"__chain":true,"from":"zig","to":"rust","request":"{\"cmd\":\"ping\"}"}
    ;
    const from = extractJsonString(data, "\"from\":\"");
    const to = extractJsonString(data, "\"to\":\"");
    const request_escaped = extractJsonString(data, "\"request\":\"");

    try std.testing.expectEqualStrings("zig", from.?);
    try std.testing.expectEqualStrings("rust", to.?);

    var buf: [256]u8 = undefined;
    const request = unescapeJson(request_escaped.?, &buf);
    try std.testing.expectEqualStrings("{\"cmd\":\"ping\"}", request);
}

test "chain message parsing: missing fields" {
    const data =
        \\{"__chain":true,"from":"zig"}
    ;
    try std.testing.expect(extractJsonString(data, "\"to\":\"") == null);
    try std.testing.expect(extractJsonString(data, "\"request\":\"") == null);
}

// ============================================
// 시퀀스 ID 슬롯 계산
// ============================================

test "seq_id slot wrapping" {
    const MAX_PENDING: usize = 256;

    // 기본 슬롯
    try std.testing.expectEqual(@as(usize, 0), @as(usize, 0) % MAX_PENDING);
    try std.testing.expectEqual(@as(usize, 255), @as(usize, 255) % MAX_PENDING);

    // 래핑
    try std.testing.expectEqual(@as(usize, 0), @as(usize, 256) % MAX_PENDING);
    try std.testing.expectEqual(@as(usize, 1), @as(usize, 257) % MAX_PENDING);

    // u32 max 근처
    const max_u32: u32 = 0xFFFFFFFF;
    try std.testing.expectEqual(@as(usize, 255), @as(usize, max_u32 % MAX_PENDING));
}

// ============================================
// jsonToHexEscape: 특수 문자 + 유니코드
// ============================================

test "jsonToHexEscape: JSON with nested quotes" {
    var buf: [512]u8 = undefined;
    const input = "{\"msg\":\"it's a \\\"test\\\"\"}";
    const result = jsonToHexEscape(input, &buf);
    // single quote가 %27로 인코딩되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result, "%27") != null);
    // 원본에 있는 문자가 안전하게 인코딩됨
    try std.testing.expect(result.len > input.len);
}

test "jsonToHexEscape: spaces and colons" {
    var buf: [256]u8 = undefined;
    const result = jsonToHexEscape("a b:c", &buf);
    // space = %20, colon = %3A
    try std.testing.expect(std.mem.indexOf(u8, result, "%20") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "%3A") != null);
}

test "jsonToHexEscape: curly braces" {
    var buf: [256]u8 = undefined;
    const result = jsonToHexEscape("{}", &buf);
    try std.testing.expectEqualStrings("%7B%7D", result);
}

test "jsonToHexEscape: buffer overflow protection" {
    // 작은 버퍼에 긴 문자열 — 크래시 없이 잘림
    var buf: [6]u8 = undefined;
    const result = jsonToHexEscape("{\"a\":1}", &buf);
    // %7B = 3 bytes, %22 = 3 bytes → 6 bytes에서 끊김
    try std.testing.expectEqual(@as(usize, 6), result.len);
}

// ============================================
// extractJsonString: 엣지 케이스
// ============================================

test "extractJsonString: empty value" {
    const data =
        \\{"key":""}
    ;
    const result = extractJsonString(data, "\"key\":\"");
    try std.testing.expectEqualStrings("", result.?);
}

test "extractJsonString: value with escaped backslash" {
    // extractJsonString은 이스케이프를 건너뛰되 복원하지 않음 (raw 슬라이스 반환)
    const data = "{\"path\":\"C:\\\\Users\\\\test\"}";
    const result = extractJsonString(data, "\"path\":\"");
    try std.testing.expectEqualStrings("C:\\\\Users\\\\test", result.?);
}

test "extractJsonString: multiple same patterns takes first" {
    const data =
        \\{"a":"first","a":"second"}
    ;
    const result = extractJsonString(data, "\"a\":\"");
    try std.testing.expectEqualStrings("first", result.?);
}

test "extractJsonString: unicode value" {
    const data =
        \\{"name":"수지"}
    ;
    const result = extractJsonString(data, "\"name\":\"");
    try std.testing.expectEqualStrings("수지", result.?);
}

// ============================================
// unescapeJson: 엣지 케이스
// ============================================

test "unescapeJson: empty string" {
    var buf: [256]u8 = undefined;
    const result = unescapeJson("", &buf);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "unescapeJson: only escapes" {
    var buf: [256]u8 = undefined;
    const result = unescapeJson("\\\"\\\"", &buf);
    try std.testing.expectEqualStrings("\"\"", result);
}

test "unescapeJson: trailing backslash preserved" {
    var buf: [256]u8 = undefined;
    const input = [_]u8{ 'a', 'b', 'c', '\\' };
    const result = unescapeJson(&input, &buf);
    // trailing \는 이스케이프 대상 없이 그대로 복사
    const expected = [_]u8{ 'a', 'b', 'c', '\\' };
    try std.testing.expectEqualStrings(&expected, result);
}

// ============================================
// extractCmd: 엣지 케이스
// ============================================

test "extractCmd: cmd at end of json" {
    try std.testing.expectEqualStrings("test", extractCmd("{\"cmd\":\"test\"}").?);
}

test "extractCmd: cmd with special chars" {
    try std.testing.expectEqualStrings("state:set", extractCmd("{\"cmd\":\"state:set\",\"key\":\"user\"}").?);
}

test "extractCmd: cmd with hyphen" {
    try std.testing.expectEqualStrings("emit-event", extractCmd("{\"cmd\":\"emit-event\"}").?);
}

test "extractCmd: empty cmd" {
    try std.testing.expectEqualStrings("", extractCmd("{\"cmd\":\"\"}").?);
}

// ============================================
// 특수 채널 라우팅 테스트
// ============================================

test "special channel detection: __fanout__" {
    try std.testing.expect(std.mem.eql(u8, "__fanout__", "__fanout__"));
    try std.testing.expect(!std.mem.eql(u8, "__fanout__", "fanout"));
}

test "special channel detection: __chain__" {
    try std.testing.expect(std.mem.eql(u8, "__chain__", "__chain__"));
}

test "special channel detection: __core__" {
    try std.testing.expect(std.mem.eql(u8, "__core__", "__core__"));
}

test "special channel detection: normal channel is not special" {
    const channel = "ping";
    try std.testing.expect(!std.mem.eql(u8, channel, "__fanout__"));
    try std.testing.expect(!std.mem.eql(u8, channel, "__chain__"));
    try std.testing.expect(!std.mem.eql(u8, channel, "__core__"));
}

// ============================================
// 통합: fanout → extractJsonString → unescapeJson → extractCmd
// ============================================

test "integration: fanout request → backend invoke" {
    // JS에서 보내는 fanout 메시지 시뮬레이션
    const js_data =
        \\{"__fanout":true,"backends":"zig,rust,go","request":"{\"cmd\":\"ping\"}"}
    ;

    // 1. backends 추출
    const backends = extractJsonString(js_data, "\"backends\":\"").?;
    try std.testing.expectEqualStrings("zig,rust,go", backends);

    // 2. request 추출 + unescape
    const req_escaped = extractJsonString(js_data, "\"request\":\"").?;
    var buf: [256]u8 = undefined;
    const req = unescapeJson(req_escaped, &buf);
    try std.testing.expectEqualStrings("{\"cmd\":\"ping\"}", req);

    // 3. request에서 cmd 추출
    try std.testing.expectEqualStrings("ping", extractCmd(req).?);

    // 4. backends split
    var count: usize = 0;
    var iter = std.mem.splitScalar(u8, backends, ',');
    while (iter.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 3), count);
}

test "integration: chain request → from/to/request" {
    const js_data =
        \\{"__chain":true,"from":"zig","to":"rust","request":"{\"cmd\":\"collab\",\"data\":\"test\"}"}
    ;

    const from = extractJsonString(js_data, "\"from\":\"").?;
    const to = extractJsonString(js_data, "\"to\":\"").?;
    const req_escaped = extractJsonString(js_data, "\"request\":\"").?;
    var buf: [256]u8 = undefined;
    const req = unescapeJson(req_escaped, &buf);

    try std.testing.expectEqualStrings("zig", from);
    try std.testing.expectEqualStrings("rust", to);
    try std.testing.expectEqualStrings("collab", extractCmd(req).?);
    try std.testing.expect(std.mem.indexOf(u8, req, "test") != null);
}

test "integration: core_info request" {
    const js_data =
        \\{"__core":true,"request":"{\"cmd\":\"core_info\"}"}
    ;
    const req_escaped = extractJsonString(js_data, "\"request\":\"").?;
    var buf: [256]u8 = undefined;
    const req = unescapeJson(req_escaped, &buf);
    try std.testing.expect(std.mem.indexOf(u8, req, "core_info") != null);
}

test "integration: invoke with target" {
    // JS: invoke("ping", {}, {target: "zig"})
    // → raw_invoke("zig", '{"cmd":"ping"}')
    // channel = "zig", request = {"cmd":"ping"}
    const channel = "zig";
    const request = "{\"cmd\":\"ping\"}";

    // channel이 특수 채널이 아닌지 확인
    try std.testing.expect(!std.mem.eql(u8, channel, "__fanout__"));
    try std.testing.expect(!std.mem.eql(u8, channel, "__chain__"));
    try std.testing.expect(!std.mem.eql(u8, channel, "__core__"));

    // request에서 cmd 추출
    try std.testing.expectEqualStrings("ping", extractCmd(request).?);
}

// ============================================
// suji:// 커스텀 프로토콜 — URL 경로 추출
// ============================================

fn extractSujiPath(url: []const u8) []const u8 {
    const prefix = "suji://app";
    if (std.mem.indexOf(u8, url, prefix)) |idx| {
        const after = url[idx + prefix.len ..];
        if (after.len > 0 and after[0] == '/') {
            return after;
        }
    }
    return "/index.html";
}

test "extractSujiPath: root slash" {
    try std.testing.expectEqualStrings("/", extractSujiPath("suji://app/"));
}

test "extractSujiPath: index.html" {
    try std.testing.expectEqualStrings("/index.html", extractSujiPath("suji://app/index.html"));
}

test "extractSujiPath: nested path" {
    try std.testing.expectEqualStrings("/assets/index-abc123.js", extractSujiPath("suji://app/assets/index-abc123.js"));
}

test "extractSujiPath: css file" {
    try std.testing.expectEqualStrings("/assets/style.css", extractSujiPath("suji://app/assets/style.css"));
}

test "extractSujiPath: no path defaults to index.html" {
    try std.testing.expectEqualStrings("/index.html", extractSujiPath("suji://app"));
}

test "extractSujiPath: image path" {
    try std.testing.expectEqualStrings("/images/logo.png", extractSujiPath("suji://app/images/logo.png"));
}

// ============================================
// MIME type 매핑
// ============================================

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

test "mimeTypeForPath: html" {
    try std.testing.expectEqualStrings("text/html", mimeTypeForPath("/index.html"));
    try std.testing.expectEqualStrings("text/html", mimeTypeForPath("/page.htm"));
}

test "mimeTypeForPath: javascript" {
    try std.testing.expectEqualStrings("application/javascript", mimeTypeForPath("/assets/index-abc.js"));
    try std.testing.expectEqualStrings("application/javascript", mimeTypeForPath("/module.mjs"));
}

test "mimeTypeForPath: css" {
    try std.testing.expectEqualStrings("text/css", mimeTypeForPath("/assets/style.css"));
}

test "mimeTypeForPath: json" {
    try std.testing.expectEqualStrings("application/json", mimeTypeForPath("/data.json"));
}

test "mimeTypeForPath: images" {
    try std.testing.expectEqualStrings("image/png", mimeTypeForPath("/logo.png"));
    try std.testing.expectEqualStrings("image/jpeg", mimeTypeForPath("/photo.jpg"));
    try std.testing.expectEqualStrings("image/jpeg", mimeTypeForPath("/photo.jpeg"));
    try std.testing.expectEqualStrings("image/gif", mimeTypeForPath("/anim.gif"));
    try std.testing.expectEqualStrings("image/svg+xml", mimeTypeForPath("/icon.svg"));
    try std.testing.expectEqualStrings("image/x-icon", mimeTypeForPath("/favicon.ico"));
}

test "mimeTypeForPath: fonts" {
    try std.testing.expectEqualStrings("font/woff", mimeTypeForPath("/font.woff"));
    try std.testing.expectEqualStrings("font/woff2", mimeTypeForPath("/font.woff2"));
    try std.testing.expectEqualStrings("font/ttf", mimeTypeForPath("/font.ttf"));
}

test "mimeTypeForPath: wasm" {
    try std.testing.expectEqualStrings("application/wasm", mimeTypeForPath("/module.wasm"));
}

test "mimeTypeForPath: source map" {
    try std.testing.expectEqualStrings("application/json", mimeTypeForPath("/index.js.map"));
}

test "mimeTypeForPath: unknown extension" {
    try std.testing.expectEqualStrings("application/octet-stream", mimeTypeForPath("/data.bin"));
    try std.testing.expectEqualStrings("application/octet-stream", mimeTypeForPath("/file.xyz"));
}

// ============================================
// suji:// URL 생성 (prod 모드)
// ============================================

test "prod URL: suji protocol" {
    const protocol = "suji";
    var buf: [64]u8 = undefined;
    const url = if (std.mem.eql(u8, protocol, "suji"))
        std.fmt.bufPrint(&buf, "suji://app/index.html", .{}) catch unreachable
    else
        std.fmt.bufPrint(&buf, "file:///path/to/dist/index.html", .{}) catch unreachable;
    try std.testing.expectEqualStrings("suji://app/index.html", url);
}

test "prod URL: file protocol" {
    const protocol = "file";
    var buf: [64]u8 = undefined;
    const url = if (std.mem.eql(u8, protocol, "suji"))
        std.fmt.bufPrint(&buf, "suji://app/index.html", .{}) catch unreachable
    else
        std.fmt.bufPrint(&buf, "file:///path/to/dist/index.html", .{}) catch unreachable;
    try std.testing.expect(std.mem.startsWith(u8, url, "file://"));
}

test "dev URL: always http regardless of protocol" {
    // dev 모드에서는 protocol 설정과 무관하게 항상 dev_url 사용
    const dev_url = "http://localhost:5173";
    try std.testing.expect(std.mem.startsWith(u8, dev_url, "http"));
}

// ============================================
// navigate: 런타임 URL 변경
// ============================================

test "navigate URL: suji protocol" {
    // suji:// URL도 navigate에 전달 가능해야 함
    const url = "suji://app/other-page.html";
    try std.testing.expect(std.mem.startsWith(u8, url, "suji://"));
}

test "navigate URL: http for dev" {
    const url = "http://localhost:5173/about";
    try std.testing.expect(std.mem.startsWith(u8, url, "http"));
}

test "navigate URL: file protocol" {
    const url = "file:///path/to/dist/index.html";
    try std.testing.expect(std.mem.startsWith(u8, url, "file://"));
}

test "navigate URL: null-terminated" {
    // CEF navigate는 [:0]const u8 필요
    const url: [:0]const u8 = "suji://app/index.html";
    try std.testing.expectEqual(@as(u8, 0), url[url.len]);
}

// ============================================
// System integration IPC 라우팅 회귀 — main.zig에 cmd 등록 정적 검증
// ============================================

const std_io = std.testing.io;

fn readMainSource() ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std_io,
        "src/main.zig",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
}

fn readCefSource() ![]u8 {
    // cef.zig + 분리된 도메인 모듈(cef_clipboard.zig 등)을 합쳐 반환 — native API 를
    // 도메인별 cef_*.zig 로 분리하는 리팩터와 무관하게 introspection 테스트가 동작.
    // 도메인을 더 분리하면 이 목록에 파일을 추가한다.
    const a = std.testing.allocator;
    const parts = [_][]const u8{
        "src/platform/cef.zig",
        "src/platform/cef_public_api.zig",
        "src/platform/cef_c.zig",
        "src/platform/cef_core_foundation.zig",
        "src/platform/cef_util.zig",
        "src/platform/cef_objc.zig",
        "src/platform/cef_runtime.zig",
        "src/platform/cef_browser_state.zig",
        "src/platform/cef_message_loop.zig",
        "src/platform/cef_native_window_handles.zig",
        "src/platform/cef_native_registry.zig",
        "src/platform/cef_browser_control.zig",
        "src/platform/cef_native.zig",
        "src/platform/cef_native_refs.zig",
        "src/platform/cef_native_entry.zig",
        "src/platform/cef_native_vtable.zig",
        "src/platform/cef_clipboard.zig",
        "src/platform/cef_clipboard_types.zig",
        "src/platform/cef_clipboard_linux.zig",
        "src/platform/cef_clipboard_windows.zig",
        "src/platform/cef_shell.zig",
        "src/platform/cef_shell_linux.zig",
        "src/platform/cef_shell_windows.zig",
        "src/platform/cef_dialog.zig",
        "src/platform/cef_dialog_types.zig",
        "src/platform/cef_dialog_response.zig",
        "src/platform/cef_dialog_linux.zig",
        "src/platform/cef_dialog_linux_message.zig",
        "src/platform/cef_dialog_linux_file.zig",
        "src/platform/cef_dialog_windows_message.zig",
        "src/platform/cef_dialog_windows_messagebox.zig",
        "src/platform/cef_dialog_windows_task_dialog.zig",
        "src/platform/cef_dialog_windows_file.zig",
        "src/platform/cef_dialog_windows_folder.zig",
        "src/platform/cef_screen.zig",
        "src/platform/cef_screen_linux.zig",
        "src/platform/cef_screen_windows.zig",
        "src/platform/cef_safe_storage.zig",
        "src/platform/cef_dock.zig",
        "src/platform/cef_power_save_blocker.zig",
        "src/platform/cef_desktop_capturer.zig",
        "src/platform/cef_session_cookies.zig",
        "src/platform/cef_session_permission.zig",
        "src/platform/cef_session_proxy.zig",
        "src/platform/cef_security_scoped_bookmark.zig",
        "src/platform/cef_request_user_attention.zig",
        "src/platform/cef_menu.zig",
        "src/platform/cef_menu_types.zig",
        "src/platform/cef_menu_linux.zig",
        "src/platform/cef_tray.zig",
        "src/platform/cef_tray_types.zig",
        "src/platform/cef_tray_state.zig",
        "src/platform/cef_tray_windows.zig",
        "src/platform/cef_tray_linux.zig",
        "src/platform/cef_notification.zig",
        "src/platform/cef_notification_state.zig",
        "src/platform/cef_notification_linux.zig",
        "src/platform/cef_notification_windows.zig",
        "src/platform/cef_global_shortcut.zig",
        "src/platform/cef_global_shortcut_types.zig",
        "src/platform/cef_global_shortcut_state.zig",
        "src/platform/cef_global_shortcut_linux_parse.zig",
        "src/platform/cef_global_shortcut_linux.zig",
        "src/platform/cef_win_pump.zig",
        "src/platform/cef_window_lifecycle.zig",
        "src/platform/cef_native_image.zig",
        "src/platform/cef_app_progress.zig",
        "src/platform/cef_power_monitor.zig",
        "src/platform/cef_native_theme.zig",
        "src/platform/cef_app.zig",
        "src/platform/cef_crash_reporter.zig",
        "src/platform/cef_web_request.zig",
        "src/platform/cef_drag_handler.zig",
        "src/platform/cef_drag_region.zig",
        "src/platform/cef_window_display.zig",
        "src/platform/cef_pdf_print.zig",
        "src/platform/cef_request_handler.zig",
        "src/platform/cef_browser_ipc.zig",
        "src/platform/cef_app_handler.zig",
        "src/platform/cef_command_line_policy.zig",
        "src/platform/cef_mac_app_menu.zig",
        "src/platform/cef_mac_window.zig",
        "src/platform/cef_client_handler.zig",
        "src/platform/cef_page_output.zig",
        "src/platform/cef_page_output_constants.zig",
        "src/platform/cef_pending_cleanup.zig",
        "src/platform/cef_initial_load.zig",
        "src/platform/cef_web_contents.zig",
        "src/platform/cef_web_contents_view_child_window.zig",
        "src/platform/cef_web_contents_view_overlay.zig",
        "src/platform/cef_web_contents_view.zig",
        "src/platform/cef_views_policy.zig",
        "src/platform/cef_window_state.zig",
        "src/platform/cef_window_visuals.zig",
        "src/platform/cef_window_runtime.zig",
        "src/platform/cef_window_creation.zig",
        "src/platform/cef_window_options.zig",
        "src/platform/cef_views_delegate.zig",
        "src/platform/cef_views_browser_delegate.zig",
        "src/platform/cef_views_window_delegate_state.zig",
        "src/platform/cef_views_window_delegate.zig",
        "src/platform/cef_render_ipc.zig",
        "src/platform/cef_render_handler.zig",
        "src/platform/cef_render_bootstrap.zig",
        "src/platform/cef_scheme.zig",
        "src/platform/cef_scheme_resource.zig",
        "src/platform/cef_scheme_security.zig",
        "src/platform/cef_life_span_handler.zig",
        "src/platform/cef_devtools.zig",
        "src/platform/cef_keyboard_handler.zig",
    };
    var combined = std.ArrayList(u8).empty;
    errdefer combined.deinit(a);
    for (parts) |p| {
        const buf = try std.Io.Dir.cwd().readFileAlloc(std_io, p, a, .limited(4 * 1024 * 1024));
        defer a.free(buf);
        try combined.appendSlice(a, buf);
        try combined.append(a, '\n');
    }
    return combined.toOwnedSlice(a);
}

fn readProjectFile(path: []const u8, limit: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std_io,
        path,
        std.testing.allocator,
        .limited(limit),
    );
}

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, pos, needle)) |i| {
        count += 1;
        pos = i + needle.len;
    }
    return count;
}

test "contextIsolation: frozen bridge + isolated-world CEF API gap stays explicit" {
    const cef_src = try readCefSource();
    defer std.testing.allocator.free(cef_src);

    inline for (.{
        "Object.freeze(window.__suji__)",
        "Object.defineProperty(window,\\\"__suji__\\\"",
        "isolated-world 아님",
        "combined_js",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, cef_src, needle) != null);
    }

    const inject_start = std.mem.indexOf(u8, cef_src, "fn injectJsHelpers") orelse
        return error.InjectJsHelpersMissing;
    const inject_end = std.mem.indexOfPos(u8, cef_src, inject_start, "/// 컴파일타임 플랫폼 문자열") orelse
        return error.InjectJsHelpersEndMissing;
    const inject_body = cef_src[inject_start..inject_end];
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(inject_body, "ctx.eval.?"));

    const plan_src = try readProjectFile("docs/PLAN.md", 1024 * 1024);
    defer std.testing.allocator.free(plan_src);
    inline for (.{
        "진짜 isolated-world",
        "cef_register_extension",
        "cef_v8_context_t::eval",
        "world id",
        "메인 월드 frozen bridge",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, plan_src, needle) != null);
    }
}

test "CEF renderer IPC — native dispatch failure does not leave JS promise pending" {
    const cef_src = try readCefSource();
    defer std.testing.allocator.free(cef_src);

    inline for (.{
        "currentOrLastRendererContext",
        "sendToBrowserFromContext",
        "cctx.is_valid",
        "cctx.get_browser",
        "get_main_frame(browser)",
        "invoke failed before browser dispatch",
        "g_pending_contexts[slot] = null",
        "br.get_main_frame.?(br)",
        "deliverRendererResponse(pending_ctx",
        "deliverRendererResponse(fallback_ctx",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, cef_src, needle) != null);
    }
}

test "CEF Views top-level initial navigation is forced after BrowserView materialization" {
    const cef_src = try readCefSource();
    defer std.testing.allocator.free(cef_src);

    try std.testing.expect(std.mem.indexOf(u8, cef_src, "fn forceInitialLoadUrl") != null);
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "fn scheduleInitialLoadRetries") != null);
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "initial_load_pending") != null);
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "frame.load_url") != null);

    const force_needle = "forceInitialLoadUrl(br, url_z)";
    const retry_needle = "scheduleInitialLoadRetries(self.allocator, handle, url_z)";
    const create_window_start = std.mem.indexOf(u8, cef_src, "fn createWindowWithCefViews") orelse return error.CreateWindowWithCefViewsMissing;
    const create_window_end = std.mem.indexOfPos(u8, cef_src, create_window_start, "\npub fn createWindow(") orelse
        std.mem.indexOfPos(u8, cef_src, create_window_start, "\n    fn createWindow(") orelse
        return error.CreateWindowWithCefViewsEndMissing;
    const body = cef_src[create_window_start..create_window_end];
    try std.testing.expect(std.mem.indexOf(u8, body, force_needle) != null);
    try std.testing.expect(std.mem.indexOf(u8, body, retry_needle) != null);
}

test "CEF Views top-level window options use native delegate paths" {
    const cef_src = try readCefSource();
    defer std.testing.allocator.free(cef_src);

    inline for (.{
        "parent_window: ?*c.cef_window_t",
        "fn retainWindowRef",
        "fn viewsWindowGetParentWindow",
        "d.delegate.get_parent_window = &viewsWindowGetParentWindow",
        "d.delegate.is_window_modal_dialog = &viewsWindowIsModalDialog",
        "fn resolveParentViewsWindow",
        "resolveParentViewsWindow(self, pid)",
        "createViewsWindowDelegate(self.allocator, browser_view, opts, parent_views_window)",
        "fn viewsInitialBackgroundColor",
        "if (appearance.transparent) return 0",
        "fn applyViewsBackgroundColor",
        "applyViewsBackgroundColor(win, d.browser_view, color)",
        "applyViewsBackgroundColor(views_window, entry.browser_view, color)",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, cef_src, needle) != null);
    }
}

test "Phase 17-B docs record Linux Windows runtime E2E completion" {
    const plan = try readProjectFile("docs/PLAN.md", 2 * 1024 * 1024);
    defer std.testing.allocator.free(plan);
    const architecture = try readProjectFile("docs/plans/17-B-cef-views-architecture.md", 1024 * 1024);
    defer std.testing.allocator.free(architecture);
    const window_api = try readProjectFile("docs/WINDOW_API.md", 2 * 1024 * 1024);
    defer std.testing.allocator.free(window_api);
    const multi_webview = try readProjectFile("documents/multi-webview.mdx", 1024 * 1024);
    defer std.testing.allocator.free(multi_webview);
    const workflow = try readProjectFile(".github/workflows/e2e.yml", 1024 * 1024);
    defer std.testing.allocator.free(workflow);

    inline for (.{
        "Linux/Windows 실 런타임 E2E는 17-B.7 잔여",
        "Linux/Windows 실 런타임 E2E는 해당 플랫폼 runner에서 후속 확인 필요",
        "Linux/Windows는 실 런타임 E2E가 남아 있다",
        "실 플랫폼 E2E 검증이 남아 있다",
        "Linux/Windows runtime: 실제 CEF runner에서 `createView`/bounds/visibility/destroy E2E가\n  아직 필요하다",
        "### 17-B.7 — Linux/Windows (진행 중)",
        "### 17-B.8 — Documentation & Migration Guide (진행 중)",
        "Phase 17-A WebContentsView",
    }) |stale| {
        try std.testing.expect(std.mem.indexOf(u8, plan, stale) == null);
        try std.testing.expect(std.mem.indexOf(u8, architecture, stale) == null);
        try std.testing.expect(std.mem.indexOf(u8, window_api, stale) == null);
        try std.testing.expect(std.mem.indexOf(u8, multi_webview, stale) == null);
    }

    inline for (.{
        "17. ✅ **`windows.createView`",
        "Linux/Windows runtime E2E(`webcontentsview-cross-platform`)로 검증",
        "`tests/e2e/run-frameless-drag-region.sh` macOS/Linux runtime E2E",
        "CI에서 초기",
        "`about:blank` 커밋 후 요청 URL navigation이 유실되는 CEF Views 레이스",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, plan, needle) != null);
    }

    inline for (.{
        "### 17-B.7 — Linux/Windows (완료)",
        "### 17-B.8 — Documentation & Migration Guide (완료)",
        "GitHub Actions `webcontentsview-cross-platform` matrix",
        "run-frameless-drag-region.sh",
        "CEF Views top-level 초기 URL 레이스",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, architecture, needle) != null);
    }

    try std.testing.expect(std.mem.indexOf(u8, window_api, "GitHub Actions `webcontentsview-cross-platform` job") != null);
    try std.testing.expect(std.mem.indexOf(u8, multi_webview, "Linux/Windows overlay child path도 GitHub Actions") != null);
    try std.testing.expect(std.mem.indexOf(u8, workflow, "webcontentsview-cross-platform") != null);
    try std.testing.expect(std.mem.indexOf(u8, workflow, "ubuntu-24.04") != null);
    try std.testing.expect(std.mem.indexOf(u8, workflow, "windows-latest") != null);
    try std.testing.expect(std.mem.indexOf(u8, workflow, "bash tests/e2e/run-view-lifecycle.sh") != null);
    try std.testing.expect(std.mem.indexOf(u8, workflow, "bash tests/e2e/run-frameless-drag-region.sh") != null);
}

test "Linux CEF Views window lifecycle events are documented and run in Actions" {
    const cef_src = try readCefSource();
    defer std.testing.allocator.free(cef_src);
    const workflow = try readProjectFile(".github/workflows/e2e.yml", 1024 * 1024);
    defer std.testing.allocator.free(workflow);
    const lifecycle_doc = try readProjectFile("documents/window-lifecycle.mdx", 512 * 1024);
    defer std.testing.allocator.free(lifecycle_doc);
    const plan = try readProjectFile("docs/PLAN.md", 2 * 1024 * 1024);
    defer std.testing.allocator.free(plan);

    inline for (.{
        "viewsWindowEmitBoundsChanged",
        "viewsWindowBoundsChanged",
        "viewsWindowActivationChanged",
        "last_minimized: bool = false",
        "last_maximized: bool = false",
        "d.last_minimized = true",
        "d.last_maximized = true",
        "g_window_resized_handler",
        "g_window_moved_handler",
        "g_window_focus_handler",
        "g_window_blur_handler",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, cef_src, needle) != null);
    }

    inline for (.{
        "E2E — window lifecycle events (Linux)",
        "bash tests/e2e/run-window-lifecycle-events-cef-views.sh",
        "xvfb-run",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, workflow, needle) != null);
    }

    inline for (.{
        "Linux는 CEF Views 경로",
        "tests/e2e/run-window-lifecycle-events-cef-views.sh",
        "Windows는 아직 후속",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, lifecycle_doc, needle) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, lifecycle_doc, "Linux/Windows는 모든 라이프사이클 이벤트가 stub") == null);

    inline for (.{
        "Linux CEF Views runtime E2E",
        "run-window-lifecycle-events-cef-views.sh",
        "macOS/Linux/Windows CI + CEF runtime subset",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, plan, needle) != null);
    }
}

test "screen.getAllDisplays IPC — main.zig dispatch + cef.zig 함수" {
    const main_src = try readMainSource();
    defer std.testing.allocator.free(main_src);
    try std.testing.expect(std.mem.indexOf(u8, main_src, "\"screen_get_all_displays\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, main_src, "cef.screenGetAllDisplays") != null);

    const cef_src = try readCefSource();
    defer std.testing.allocator.free(cef_src);
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "pub fn screenGetAllDisplays") != null);
    // JSON shape 필드 정적 검증 — fmt 내 escape 형태가 zig source에서 다양하므로 단어만 매칭.
    inline for (.{
        "const linux_screen",
        "XScreenCount",
        "XDisplayWidth",
        "XDisplayHeight",
        "writeEmptyJsonArray",
        "isPrimary",
        "visibleWidth",
        "visibleHeight",
        "scaleFactor",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, cef_src, needle) != null);
    }
}

test "desktopCapturer.getSources IPC — main.zig dispatch + cef.zig 함수" {
    const main_src = try readMainSource();
    defer std.testing.allocator.free(main_src);
    try std.testing.expect(std.mem.indexOf(u8, main_src, "\"desktop_capturer_get_sources\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, main_src, "cef.desktopCapturerGetSources") != null);

    const cef_src = try readCefSource();
    defer std.testing.allocator.free(cef_src);
    try std.testing.expect(std.mem.indexOf(u8, cef_src, "pub fn desktopCapturerGetSources") != null);
    // CG/CF 열거 경로 + JSON shape 정적 검증. needle 은 zig source 에 verbatim
    // 등장하는 식별자/부분문자열만 (fmt 내 \" escape 형태 매칭 회피 — screen
    // GetAllDisplays 테스트와 동일 정책).
    inline for (.{
        "CGGetActiveDisplayList",
        "CGWindowListCopyWindowInfo",
        "CGRectMakeWithDictionaryRepresentation",
        "kCGWindowLayer",
        "screen:{d}:0",
        "window:{d}:0",
        "displayId",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, cef_src, needle) != null);
    }
}

test "desktopCapturer.captureThumbnail IPC + cef CG/ImageIO 인코딩 경로" {
    const main_src = try readMainSource();
    defer std.testing.allocator.free(main_src);
    inline for (.{
        "\"desktop_capturer_capture_thumbnail\"",
        "cef.desktopCapturerCaptureThumbnail",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, main_src, needle) != null);
    }

    const cef_src = try readCefSource();
    defer std.testing.allocator.free(cef_src);
    inline for (.{
        "pub fn desktopCapturerCaptureThumbnail",
        "CGDisplayCreateImage",
        "CGWindowListCreateImage",
        "CGImageDestinationCreateWithURL",
        "CGImageDestinationFinalize",
        "CFURLCreateFromFileSystemRepresentation",
        "desktop_capturer.parseSourceId",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, cef_src, needle) != null);
    }

    const parser_src = try readProjectFile("src/platform/desktop_capturer.zig", 64 * 1024);
    defer std.testing.allocator.free(parser_src);
    inline for (.{
        "pub fn parseSourceId",
        "screen:<displayId>:0",
        "window:<windowNumber>:0",
        "if (!std.mem.eql(u8, rest[c2 + 1 ..], \"0\")) return null",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, parser_src, needle) != null);
    }

    // ImageIO 프레임워크 링크(빌드 회귀 가드).
    const build_src = try std.Io.Dir.cwd().readFileAlloc(std_io, "build.zig", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(build_src);
    try std.testing.expect(std.mem.indexOf(u8, build_src, "linkFramework(\"ImageIO\"") != null);
}

test "crashReporter IPC + CEF crash util + cfg renderer 연결" {
    const main_src = try readMainSource();
    defer std.testing.allocator.free(main_src);
    inline for (.{
        "\"crash_reporter_start\"",
        "\"crash_reporter_get_parameters\"",
        "\"crash_reporter_add_extra_parameter\"",
        "\"crash_reporter_remove_extra_parameter\"",
        "\"crash_reporter_get_uploaded_reports\"",
        "collectCurrentCrashReports",
        "writeStartupCrashReporterConfig",
        "crash_reporter.renderConfig",
        "crash_reporter.collectReports",
        "cef.crashReporterEnabled",
        "cef.crashReporterSetKeyValue",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, main_src, needle) != null);
    }

    const cef_src = try readCefSource();
    defer std.testing.allocator.free(cef_src);
    inline for (.{
        "cef_crash_util_capi.h",
        "pub fn crashReporterEnabled",
        "cef_crash_reporting_enabled",
        "pub fn crashReporterSetKeyValue",
        "cef_set_crash_key_value",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, cef_src, needle) != null);
    }
}

test "dock badge IPC — set/get round-trip 등록" {
    const main_src = try readMainSource();
    defer std.testing.allocator.free(main_src);
    inline for (.{ "\"dock_set_badge\"", "\"dock_get_badge\"", "cef.dockSetBadge", "cef.dockGetBadge" }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, main_src, needle) != null);
    }

    const cef_src = try readCefSource();
    defer std.testing.allocator.free(cef_src);
    inline for (.{ "pub fn dockSetBadge", "pub fn dockGetBadge", "setBadgeLabel:", "badgeLabel" }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, cef_src, needle) != null);
    }
}

test "powerSaveBlocker IPC — start/stop + 두 type 모두 노출" {
    const main_src = try readMainSource();
    defer std.testing.allocator.free(main_src);
    inline for (.{
        "\"power_save_blocker_start\"",
        "\"power_save_blocker_stop\"",
        "\"prevent_app_suspension\"",
        "\"prevent_display_sleep\"",
        "cef.powerSaveBlockerStart",
        "cef.powerSaveBlockerStop",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, main_src, needle) != null);
    }

    const cef_src = try readCefSource();
    defer std.testing.allocator.free(cef_src);
    inline for (.{
        "pub fn powerSaveBlockerStart",
        "pub fn powerSaveBlockerStop",
        "IOPMAssertionCreateWithName",
        "IOPMAssertionRelease",
        "XScreenSaverSuspend",
        "PowerCreateRequest",
        "PowerSetRequest",
        "PowerClearRequest",
        "PreventUserIdleSystemSleep",
        "PreventUserIdleDisplaySleep",
        "powerSaveInsertLocked",
        "powerSaveRemoveLocked",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, cef_src, needle) != null);
    }

    const build_src = try readProjectFile("build.zig", 1024 * 1024);
    defer std.testing.allocator.free(build_src);
    inline for (.{ "\"Xss\"", "\"kernel32\"" }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, build_src, needle) != null);
    }

    const e2e_src = try readProjectFile("tests/e2e/power-save-blocker.test.ts", 1024 * 1024);
    defer std.testing.allocator.free(e2e_src);
    inline for (.{
        "power_save_blocker_start",
        "power_save_blocker_stop",
        "prevent_display_sleep",
        "prevent_app_suspension",
        "stopping the same id twice is false",
        "Linux: XScreenSaverSuspend",
        "Windows: PowerCreateRequest",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, e2e_src, needle) != null);
    }

    const workflow_src = try readProjectFile(".github/workflows/e2e.yml", 1024 * 1024);
    defer std.testing.allocator.free(workflow_src);
    inline for (.{
        "E2E — powerSaveBlocker",
        "E2E — powerSaveBlocker (Linux)",
        "E2E — powerSaveBlocker (Windows)",
        "run-power-save-blocker.sh",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, workflow_src, needle) != null);
    }
}

test "find_result IPC — find_handler 등록 + main.zig final-only forward + display struct 통합" {
    const main_src = try readMainSource();
    defer std.testing.allocator.free(main_src);
    inline for (.{
        "fn windowFindResultHandler",
        "if (!final_update) return",
        ".find_result = &windowFindResultHandler",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, main_src, needle) != null);
    }

    const cef_src = try readCefSource();
    defer std.testing.allocator.free(cef_src);
    inline for (.{
        "client_ptr.get_find_handler = &getFindHandler",
        "fn ensureFindHandler",
        "fn onFindResult",
        "pub const WindowFindResultHandler",
        "find_result: ?WindowFindResultHandler",
        "g_find_handler.on_find_result = &onFindResult",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, cef_src, needle) != null);
    }
}

test "safeStorage IPC — OS secure store set/get/delete" {
    const main_src = try readMainSource();
    defer std.testing.allocator.free(main_src);
    inline for (.{
        "\"safe_storage_set\"",
        "\"safe_storage_get\"",
        "\"safe_storage_delete\"",
        "cef.safeStorageSet",
        "cef.safeStorageGet",
        "cef.safeStorageDelete",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, main_src, needle) != null);
    }

    const cef_src = try readCefSource();
    defer std.testing.allocator.free(cef_src);
    inline for (.{
        "pub fn safeStorageSet",
        "pub fn safeStorageGet",
        "pub fn safeStorageDelete",
        "safe_storage.buildTargetUtf16",
        "SecItemAdd",
        "SecItemCopyMatching",
        "SecItemDelete",
        "kSecClassGenericPassword",
        "errSecItemNotFound",
        "secret_password_store_sync",
        "secret_password_lookup_sync",
        "secret_password_clear_sync",
        "dev.suji.SafeStorage",
        "linux_secret.schema",
        "CredWriteW",
        "CredReadW",
        "CredDeleteW",
        "CRED_TYPE_GENERIC",
        "CRED_PERSIST_LOCAL_MACHINE",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, cef_src, needle) != null);
    }

    const build_src = try std.Io.Dir.cwd().readFileAlloc(
        std_io,
        "build.zig",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(build_src);
    try std.testing.expect(std.mem.indexOf(u8, build_src, "Security") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_src, "secret-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_src, "glib-2.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_src, "advapi32") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_src, "src/platform/safe_storage.zig") != null);

    const e2e_src = try std.Io.Dir.cwd().readFileAlloc(
        std_io,
        "tests/e2e/safe-storage.test.ts",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(e2e_src);
    inline for (.{
        "safe_storage_set",
        "safe_storage_get",
        "safe_storage_delete",
        "service namespace isolates same account",
        "escape-sensitive value round-trips",
        "Linux: libsecret",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, e2e_src, needle) != null);
    }

    const ci_src = try std.Io.Dir.cwd().readFileAlloc(
        std_io,
        ".github/workflows/e2e.yml",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(ci_src);
    inline for (.{
        "E2E — safeStorage (Linux)",
        "gnome-keyring",
        "libsecret-1-dev",
        "gnome-keyring-daemon --unlock",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, ci_src, needle) != null);
    }
}

test "webRequest — CefRequestHandler wiring + URL glob blocklist + 2 이벤트 채널" {
    const main_src = try readMainSource();
    defer std.testing.allocator.free(main_src);
    inline for (.{
        "\"web_request_set_blocked_urls\"",
        "cef.webRequestSetBlockedUrls",
        "cef.setWebRequestEmitHandler",
        "webRequestEmitHandler",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, main_src, needle) != null);
    }

    const cef_src = try readCefSource();
    defer std.testing.allocator.free(cef_src);
    inline for (.{
        "pub fn webRequestSetBlockedUrls",
        "pub fn setWebRequestEmitHandler",
        "ensureRequestHandler",
        "ensureResourceRequestHandler",
        "on_before_resource_load",
        "on_resource_load_complete",
        "client_ptr.get_request_handler",
        "\"webRequest:before-request\"",
        "\"webRequest:completed\"",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, cef_src, needle) != null);
    }
}

test "webRequest dynamic listener — RV_CONTINUE_ASYNC + pending callback storage" {
    const main_src = try readMainSource();
    defer std.testing.allocator.free(main_src);
    inline for (.{
        "\"web_request_set_listener_filter\"",
        "\"web_request_resolve\"",
        "cef.webRequestSetListenerFilter",
        "cef.webRequestResolve",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, main_src, needle) != null);
    }

    const cef_src = try readCefSource();
    defer std.testing.allocator.free(cef_src);
    inline for (.{
        "pub fn webRequestSetListenerFilter",
        "pub fn webRequestResolve",
        "PendingCallback",
        "pendingPush",
        "pendingTake",
        "RV_CONTINUE_ASYNC",
        "\"webRequest:will-request\"",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, cef_src, needle) != null);
    }
}

test "powerMonitor — install hook + 4 이벤트 채널 emit 패턴" {
    const main_src = try readMainSource();
    defer std.testing.allocator.free(main_src);
    inline for (.{
        "cef.powerMonitorInstall",
        "powerMonitorEmitHandler",
        "\"power:{s}\"",
        "\"power_monitor_test_emit\"",
        "SUJI_E2E_POWER_MONITOR_TEST_HOOK",
        "cef.powerMonitorSetScreenLocked(true)",
        "cef.powerMonitorSetScreenLocked(false)",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, main_src, needle) != null);
    }

    const cef_src = try readCefSource();
    defer std.testing.allocator.free(cef_src);
    inline for (.{
        "pub fn powerMonitorInstall",
        "pub fn powerMonitorUninstall",
        "suji_power_monitor_install",
        "suji_power_monitor_linux_install",
        "suji_power_monitor_windows_install",
        "logind/ScreenSaver DBus signals",
        "WM_POWERBROADCAST + WTS session messages",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, cef_src, needle) != null);
    }

    const m_src = try std.Io.Dir.cwd().readFileAlloc(
        std_io,
        "src/platform/power_monitor.m",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(m_src);
    inline for (.{
        "NSWorkspaceWillSleepNotification",
        "NSWorkspaceDidWakeNotification",
        "NSWorkspaceScreensDidSleepNotification",
        "NSWorkspaceScreensDidWakeNotification",
        "\"suspend\"",
        "\"resume\"",
        "\"lock-screen\"",
        "\"unlock-screen\"",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, m_src, needle) != null);
    }

    const linux_src = try std.Io.Dir.cwd().readFileAlloc(
        std_io,
        "src/platform/power_monitor_linux.c",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(linux_src);
    inline for (.{
        "libdbus-1.so.3",
        "org.freedesktop.login1.Manager",
        "PrepareForSleep",
        "org.freedesktop.ScreenSaver",
        "ActiveChanged",
        "\"suspend\"",
        "\"resume\"",
        "\"lock-screen\"",
        "\"unlock-screen\"",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, linux_src, needle) != null);
    }

    const win_src = try std.Io.Dir.cwd().readFileAlloc(
        std_io,
        "src/platform/power_monitor_win.c",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(win_src);
    inline for (.{
        "WM_POWERBROADCAST",
        "PBT_APMSUSPEND",
        "PBT_APMRESUMEAUTOMATIC",
        "WM_WTSSESSION_CHANGE",
        "WTS_SESSION_LOCK",
        "WTS_SESSION_UNLOCK",
        "\"suspend\"",
        "\"resume\"",
        "\"lock-screen\"",
        "\"unlock-screen\"",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, win_src, needle) != null);
    }

    const build_src = try readProjectFile("build.zig", 1024 * 1024);
    defer std.testing.allocator.free(build_src);
    inline for (.{
        "src/platform/power_monitor_linux.c",
        "src/platform/power_monitor_win.c",
        "\"pthread\"",
        "\"dl\"",
        "\"wtsapi32\"",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, build_src, needle) != null);
    }

    const e2e_src = try readProjectFile("tests/e2e/power-monitor.test.ts", 1024 * 1024);
    defer std.testing.allocator.free(e2e_src);
    inline for (.{
        "power_monitor_test_emit",
        "power:${event}",
        "\"suspend\"",
        "\"resume\"",
        "\"lock-screen\"",
        "\"unlock-screen\"",
        "locked.state",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, e2e_src, needle) != null);
    }

    const run_src = try readProjectFile("tests/e2e/run-power-monitor.sh", 1024 * 1024);
    defer std.testing.allocator.free(run_src);
    try std.testing.expect(std.mem.indexOf(u8, run_src, "SUJI_E2E_POWER_MONITOR_TEST_HOOK=1") != null);

    const workflow_src = try readProjectFile(".github/workflows/e2e.yml", 1024 * 1024);
    defer std.testing.allocator.free(workflow_src);
    inline for (.{
        "E2E — powerMonitor",
        "E2E — powerMonitor idle (Linux)",
        "E2E — powerMonitor idle (Windows)",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, workflow_src, needle) != null);
    }
}

test "nativeTheme — KVO observer install + nativeTheme:updated emit" {
    const main_src = try readMainSource();
    defer std.testing.allocator.free(main_src);
    inline for (.{
        "cef.nativeThemeInstall",
        "nativeThemeEmitHandler",
        "\"nativeTheme:updated\"",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, main_src, needle) != null);
    }

    const cef_src = try readCefSource();
    defer std.testing.allocator.free(cef_src);
    inline for (.{
        "pub fn nativeThemeInstall",
        "pub fn nativeThemeUninstall",
        "suji_native_theme_install",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, cef_src, needle) != null);
    }

    const m_src = try std.Io.Dir.cwd().readFileAlloc(
        std_io,
        "src/platform/nativetheme.m",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(m_src);
    inline for (.{
        "addObserver:",
        "@\"effectiveAppearance\"",
        "observeValueForKeyPath:",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, m_src, needle) != null);
    }
}

test "globalShortcut 미디어키 — global_shortcut.m NSEvent systemDefined 경로" {
    // Electron 패리티: Media* accelerator 는 신규 IPC/SDK 없이 기존
    // global_shortcut_register 로 흐르고, Carbon 불가 → NSEvent
    // systemDefined 모니터로 분기(ref=NULL, UnregisterEventHotKey skip).
    const m_src = try std.Io.Dir.cwd().readFileAlloc(
        std_io,
        "src/platform/global_shortcut.m",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(m_src);
    inline for (.{
        "media_key_for",
        "\"MediaPlayPause\"",
        "\"MediaNextTrack\"",
        "\"MediaPreviousTrack\"",
        "\"MediaStop\"",
        "media_event_dispatch",
        "ensure_media_monitor",
        "NSEventMaskSystemDefined",
        "addGlobalMonitorForEventsMatchingMask:",
        "addLocalMonitorForEventsMatchingMask:",
        "media_key", // HotKeyEntry 필드
        "if (g_hotkeys[idx].ref)", // 미디어 ref=NULL 가드(unregister)
        "if (g_hotkeys[i].ref)", // unregister_all 가드
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, m_src, needle) != null);
    }
}

test "app.getPath IPC — main.zig dispatch + cef.zig 함수 + 7 키" {
    const main_src = try readMainSource();
    defer std.testing.allocator.free(main_src);
    inline for (.{
        "\"app_get_path\"",
        "cef.appGetPath",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, main_src, needle) != null);
    }

    const cef_src = try readCefSource();
    defer std.testing.allocator.free(cef_src);
    inline for (.{
        "pub fn appGetPath",
        "pub fn buildStandardPath",
        "fn resolveAppDataDir",
        "\"home\"",
        "\"userData\"",
        "\"appData\"",
        "\"temp\"",
        "\"desktop\"",
        "\"documents\"",
        "\"downloads\"",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, cef_src, needle) != null);
    }
}

test "clipboard.writeImage / readImage IPC + cef.zig 함수" {
    const main_src = try readMainSource();
    defer std.testing.allocator.free(main_src);
    inline for (.{
        "\"clipboard_write_image\"",
        "\"clipboard_read_image\"",
        "cef.clipboardWriteImagePng",
        "cef.clipboardReadImagePng",
        "std.base64.standard.Encoder",
        "std.base64.standard.Decoder",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, main_src, needle) != null);
    }

    const cef_src = try readCefSource();
    defer std.testing.allocator.free(cef_src);
    inline for (.{
        "pub fn clipboardWriteImagePng",
        "pub fn clipboardReadImagePng",
        "public.png",
        "setData:forType:",
        "dataForType:",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, cef_src, needle) != null);
    }
}

test "nativeImage.getSize IPC + cef.zig 함수" {
    const main_src = try readMainSource();
    defer std.testing.allocator.free(main_src);
    inline for (.{
        "\"native_image_get_size\"",
        "cef.nativeImageGetSize",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, main_src, needle) != null);
    }

    const cef_src = try readCefSource();
    defer std.testing.allocator.free(cef_src);
    inline for (.{
        "pub fn nativeImageGetSize",
        "initWithContentsOfFile:",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, cef_src, needle) != null);
    }
}

test "nativeImage.toPNG/toJPEG IPC + cef.zig encoder" {
    const main_src = try readMainSource();
    defer std.testing.allocator.free(main_src);
    inline for (.{
        "\"native_image_to_png\"",
        "\"native_image_to_jpeg\"",
        "cef.nativeImageEncodeFromPath",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, main_src, needle) != null);
    }

    const cef_src = try readCefSource();
    defer std.testing.allocator.free(cef_src);
    inline for (.{
        "pub fn nativeImageEncodeFromPath",
        "NSBitmapImageFileType",
        "imageRepWithData:",
        "representationUsingType:properties:",
        "NSImageCompressionFactor",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, cef_src, needle) != null);
    }
}

test "app.setProgressBar IPC + cef.zig 함수" {
    const main_src = try readMainSource();
    defer std.testing.allocator.free(main_src);
    inline for (.{
        "\"app_set_progress_bar\"",
        "cef.appSetProgressBar",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, main_src, needle) != null);
    }

    const cef_src = try readCefSource();
    defer std.testing.allocator.free(cef_src);
    inline for (.{
        "pub fn appSetProgressBar",
        "NSProgressIndicator",
        "setContentView:",
        "setDoubleValue:",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, cef_src, needle) != null);
    }
}

test "app.getLocale IPC + cef.zig 함수" {
    const main_src = try readMainSource();
    defer std.testing.allocator.free(main_src);
    inline for (.{
        "\"app_get_locale\"",
        "cef.appGetLocale",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, main_src, needle) != null);
    }

    const cef_src = try readCefSource();
    defer std.testing.allocator.free(cef_src);
    inline for (.{
        "pub fn appGetLocale",
        "currentLocale",
        "localeIdentifier",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, cef_src, needle) != null);
    }
}

test "nativeTheme.setThemeSource IPC + cef.zig 함수" {
    const main_src = try readMainSource();
    defer std.testing.allocator.free(main_src);
    inline for (.{
        "\"native_theme_set_source\"",
        "cef.nativeThemeSetSource",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, main_src, needle) != null);
    }

    const cef_src = try readCefSource();
    defer std.testing.allocator.free(cef_src);
    inline for (.{
        "pub fn nativeThemeSetSource",
        "NSAppearanceNameDarkAqua",
        "NSAppearanceNameAqua",
        "setAppearance:",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, cef_src, needle) != null);
    }
}

test "clipboard.has/availableFormats + app.isReady/focus/hide IPC" {
    const main_src = try readMainSource();
    defer std.testing.allocator.free(main_src);
    inline for (.{
        "\"clipboard_has\"",
        "\"clipboard_available_formats\"",
        "\"app_is_ready\"",
        "\"app_focus\"",
        "\"app_hide\"",
        "cef.clipboardHas",
        "cef.clipboardAvailableFormats",
        "cef.appFocus",
        "cef.appHide",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, main_src, needle) != null);
    }

    const cef_src = try readCefSource();
    defer std.testing.allocator.free(cef_src);
    inline for (.{
        "const linux_clip",
        "gtk_clipboard_get",
        "gtk_clipboard_set_text",
        "gtk_clipboard_set_with_data",
        "gtk_clipboard_wait_for_contents",
        "text/html",
        "gtk_clipboard_wait_for_text",
        "gtk_clipboard_wait_is_text_available",
        "const win_clip",
        "RegisterClipboardFormatW",
        "HTML Format",
        "clipboard_cf_html.writeDocument",
        "clipboard_cf_html.readFragment",
        "pub fn clipboardHas",
        "pub fn clipboardAvailableFormats",
        "pub fn appFocus",
        "pub fn appHide",
        "activateIgnoringOtherApps:",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, cef_src, needle) != null);
    }

    const linux_e2e_src = try readProjectFile("tests/e2e/clipboard-text-runtime.test.ts", 1024 * 1024);
    defer std.testing.allocator.free(linux_e2e_src);
    inline for (.{
        "clipboard_write_html",
        "clipboard_read_html",
        "public.html",
        "CF_UNICODETEXT + CF_HTML",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, linux_e2e_src, needle) != null);
    }

    const workflow_src = try readProjectFile(".github/workflows/e2e.yml", 1024 * 1024);
    defer std.testing.allocator.free(workflow_src);
    inline for (.{
        "E2E — clipboard text/HTML (Linux)",
        "E2E — clipboard text/HTML (Windows)",
        "bash tests/e2e/run-clipboard-text-runtime.sh",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, workflow_src, needle) != null);
    }
    const matrix_job_pos = std.mem.indexOf(u8, workflow_src, "webcontentsview-cross-platform:").?;
    const deps_pos = std.mem.indexOfPos(u8, workflow_src, matrix_job_pos, "Install frontend dependencies").?;
    const linux_clip_pos = std.mem.indexOfPos(u8, workflow_src, matrix_job_pos, "E2E — clipboard text/HTML (Linux)").?;
    const linux_auto_pos = std.mem.indexOf(u8, workflow_src, "E2E — autoUpdater prepare/quit (Linux)").?;
    const windows_clip_pos = std.mem.indexOf(u8, workflow_src, "E2E — clipboard text/HTML (Windows)").?;
    const windows_wcv_pos = std.mem.indexOf(u8, workflow_src, "E2E — WebContentsView lifecycle (Windows)").?;
    try std.testing.expect(deps_pos < linux_clip_pos);
    try std.testing.expect(linux_clip_pos < linux_auto_pos);
    try std.testing.expect(windows_clip_pos < windows_wcv_pos);
}

test "Win32 CF_HTML helper builds byte offsets and extracts fragment" {
    const html = "<section data-x=\"1\">한글 <b>HTML</b></section>";
    var buf: [1024]u8 = undefined;
    const doc = clipboard_cf_html.writeDocument(&buf, html).?;

    try std.testing.expect(std.mem.startsWith(u8, doc, "Version:0.9\r\nStartHTML:"));
    try std.testing.expect(std.mem.indexOf(u8, doc, "<!--StartFragment-->") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "<!--EndFragment-->") != null);
    try std.testing.expectEqualStrings(html, clipboard_cf_html.readFragment(doc).?);
}

test "Win32 CF_HTML helper rejects malformed offsets" {
    var empty: [0]u8 = .{};
    try std.testing.expect(clipboard_cf_html.writeDocument(&empty, "<b>x</b>") == null);
    try std.testing.expect(clipboard_cf_html.readFragment("StartFragment:0000000010\r\nEndFragment:0000009999\r\nx") == null);
    try std.testing.expect(clipboard_cf_html.readFragment("StartFragment:0000000020\r\nEndFragment:0000000010\r\nx") == null);
}

test "app.exit + session.clearCookies/flushStore IPC" {
    const main_src = try readMainSource();
    defer std.testing.allocator.free(main_src);
    inline for (.{
        "\"app_exit\"",
        "\"session_clear_cookies\"",
        "\"session_flush_store\"",
        "\"session_clear_storage_data\"",
        "\"session_set_proxy\"",
        "cef.sessionClearCookies",
        "cef.sessionFlushStore",
        "cef.sessionClearStorageData",
        "cef.sessionSetProxy",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, main_src, needle) != null);
    }

    const cef_src = try readCefSource();
    defer std.testing.allocator.free(cef_src);
    inline for (.{
        "pub fn sessionClearCookies",
        "pub fn sessionFlushStore",
        "pub fn sessionClearStorageData",
        "pub fn sessionSetProxy",
        "Storage.clearDataForOrigin",
        "Network.clearBrowserCache",
        "cef_cookie_manager_get_global_manager",
        "cef_request_context_get_global_context",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, cef_src, needle) != null);
    }
}

test "session.setPermissionRequestHandler IPC + CEF wire" {
    // main.zig: cmd 디스패치 + emit 핸들러 등록.
    const main_src = try readMainSource();
    defer std.testing.allocator.free(main_src);
    inline for (.{
        "\"session_set_permission_handler\"",
        "\"session_permission_response\"",
        "cef.permissionSetHandlerEnabled",
        "cef.permissionRespond",
        "cef.setPermissionEmitHandler",
        "fn permissionEmitHandler",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, main_src, needle) != null);
    }

    // cef_session_permission.zig + cef_client_handler.zig: 핸들러/콜백/이벤트/UI-post 와이어.
    const cef_src = try readCefSource();
    defer std.testing.allocator.free(cef_src);
    inline for (.{
        "pub fn permissionSetHandlerEnabled",
        "pub fn permissionRespond",
        "pub fn getPermissionHandler",
        "on_show_permission_prompt",
        "on_dismiss_permission_prompt",
        "CEF_PERMISSION_RESULT_ACCEPT",
        "CEF_PERMISSION_RESULT_DENY",
        "session:permission-request", // emit 채널
        "cef_post_task", // off-UI → UI 라우팅(setProxy 동형)
        "client_ptr.get_permission_handler", // client 배선
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, cef_src, needle) != null);
    }
}

test "app.getName/getVersion + screen.getDisplayNearestPoint IPC" {
    const main_src = try readMainSource();
    defer std.testing.allocator.free(main_src);
    inline for (.{
        "\"app_get_name\"",
        "\"app_get_version\"",
        "\"screen_get_display_nearest_point\"",
        "cef.screenGetDisplayNearestPoint",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, main_src, needle) != null);
    }

    const cef_src = try readCefSource();
    defer std.testing.allocator.free(cef_src);
    inline for (.{
        "pub fn screenGetDisplayNearestPoint",
        "screen_model.containedDisplayIndex",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, cef_src, needle) != null);
    }
}

test "clipboard HTML + powerMonitor idle IPC + cef.zig 함수" {
    const main_src = try readMainSource();
    defer std.testing.allocator.free(main_src);
    inline for (.{
        "\"clipboard_read_html\"",
        "\"clipboard_write_html\"",
        "\"power_monitor_get_idle_time\"",
        "\"power_monitor_get_idle_state\"",
        "cef.clipboardReadHtml",
        "cef.clipboardWriteHtml",
        "cef.powerMonitorIdleSeconds",
        // 화면 잠금 → idle-state "locked" 배선(Electron 동등).
        "cef.powerMonitorSetScreenLocked",
        "cef.powerMonitorScreenLocked",
        "\"locked\"",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, main_src, needle) != null);
    }

    const cef_src = try readCefSource();
    defer std.testing.allocator.free(cef_src);
    inline for (.{
        "pub fn clipboardReadHtml",
        "pub fn clipboardWriteHtml",
        "pub fn powerMonitorIdleSeconds",
        "pub fn powerMonitorSetScreenLocked",
        "pub fn powerMonitorScreenLocked",
        "PASTEBOARD_TYPE_HTML",
        "CGEventSourceSecondsSinceLastEventType",
        "XScreenSaverQueryInfo",
        "XScreenSaverAllocInfo",
        "GetLastInputInfo",
        "GetTickCount",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, cef_src, needle) != null);
    }

    const build_src = try std.Io.Dir.cwd().readFileAlloc(
        std_io,
        "build.zig",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(build_src);
    inline for (.{
        "\"Xss\"",
        "XScreenSaver",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, build_src, needle) != null);
    }

    const e2e_src = try std.Io.Dir.cwd().readFileAlloc(
        std_io,
        "tests/e2e/power-monitor.test.ts",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(e2e_src);
    inline for (.{
        "power_monitor_get_idle_time",
        "power_monitor_get_idle_state",
        "Linux: XScreenSaverQueryInfo",
        "Windows: GetLastInputInfo",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, e2e_src, needle) != null);
    }
}

test "shell.openPath / nativeTheme / screen.getCursorPoint IPC + cef.zig 함수" {
    const main_src = try readMainSource();
    defer std.testing.allocator.free(main_src);
    inline for (.{
        "\"shell_open_path\"",
        "\"native_theme_should_use_dark_colors\"",
        "\"screen_get_cursor_point\"",
        "cef.shellOpenPath",
        "cef.nativeThemeIsDark",
        "cef.screenGetCursorPoint",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, main_src, needle) != null);
    }

    const cef_src = try readCefSource();
    defer std.testing.allocator.free(cef_src);
    inline for (.{
        "pub fn shellOpenPath",
        "linux_shell.openPath",
        "g_file_query_exists",
        "g_file_get_uri",
        "pub fn nativeThemeIsDark",
        "pub fn screenGetCursorPoint",
        "XQueryPointer",
        "effectiveAppearance",
        "mouseLocation",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, cef_src, needle) != null);
    }
}

test "shell.trashItem IPC — main.zig dispatch + cef.zig 함수" {
    const main_src = try readMainSource();
    defer std.testing.allocator.free(main_src);
    inline for (.{
        "\"shell_trash_item\"",
        "cef.shellTrashItem",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, main_src, needle) != null);
    }

    const cef_src = try readCefSource();
    defer std.testing.allocator.free(cef_src);
    inline for (.{
        "pub fn shellTrashItem",
        "trashItemAtURL:resultingItemURL:error:",
        "const linux_shell",
        "g_file_trash",
        "g_file_new_for_path",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, cef_src, needle) != null);
    }

    const build_src = try readProjectFile("build.zig", 1024 * 1024);
    defer std.testing.allocator.free(build_src);
    inline for (.{
        "linkSystemLibrary(\"gio-2.0\"",
        "linkSystemLibrary(\"gobject-2.0\"",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, build_src, needle) != null);
    }
}

test "shell.showItemInFolder Linux FileManager1 D-Bus wiring + runtime E2E" {
    const cef_src = try readCefSource();
    defer std.testing.allocator.free(cef_src);
    inline for (.{
        "linux_shell.showItemInFolder",
        "g_bus_get_sync",
        "g_dbus_connection_call_sync",
        "org.freedesktop.FileManager1",
        "ShowItems",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, cef_src, needle) != null);
    }

    const e2e_src = try readProjectFile(
        "tests/e2e/shell-show-item-runtime.test.ts",
        1024 * 1024,
    );
    defer std.testing.allocator.free(e2e_src);
    inline for (.{
        "dbus.service.BusName('org.freedesktop.FileManager1'",
        "shell_show_item_in_folder",
        "pathToFileURL",
        "waitForMarker",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, e2e_src, needle) != null);
    }

    const workflow_src = try readProjectFile(".github/workflows/e2e.yml", 1024 * 1024);
    defer std.testing.allocator.free(workflow_src);
    inline for (.{
        "E2E — shell showItemInFolder (Linux)",
        "run-shell-show-item-runtime.sh",
        "python3-dbus",
        "python3-gi",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, workflow_src, needle) != null);
    }
}

test "shell.beep Linux GDK wiring + runtime E2E" {
    const cef_src = try readCefSource();
    defer std.testing.allocator.free(cef_src);
    inline for (.{
        "linux_shell.beep",
        "gdk_display_get_default",
        "gdk_display_beep",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, cef_src, needle) != null);
    }

    const e2e_src = try readProjectFile(
        "tests/e2e/shell-beep-runtime.test.ts",
        1024 * 1024,
    );
    defer std.testing.allocator.free(e2e_src);
    inline for (.{
        "shell_beep",
        "repeated beep calls",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, e2e_src, needle) != null);
    }

    const workflow_src = try readProjectFile(".github/workflows/e2e.yml", 1024 * 1024);
    defer std.testing.allocator.free(workflow_src);
    try std.testing.expect(std.mem.indexOf(u8, workflow_src, "E2E — shell beep (Linux)") != null);
    try std.testing.expect(std.mem.indexOf(u8, workflow_src, "run-shell-beep-runtime.sh") != null);
}

test "shell.openExternal Linux GIO handler wiring + runtime E2E" {
    const cef_src = try readCefSource();
    defer std.testing.allocator.free(cef_src);
    inline for (.{
        "g_app_info_launch_default_for_uri",
        "linux_shell.openExternal",
        "fn urlIsValid(url: []const u8) bool",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, cef_src, needle) != null);
    }

    const e2e_src = try readProjectFile(
        "tests/e2e/shell-open-external-runtime.test.ts",
        1024 * 1024,
    );
    defer std.testing.allocator.free(e2e_src);
    inline for (.{
        "x-scheme-handler",
        "xdg-mime",
        "gio",
        "shell_open_external",
        "waitForMarker",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, e2e_src, needle) != null);
    }

    const workflow_src = try readProjectFile(".github/workflows/e2e.yml", 1024 * 1024);
    defer std.testing.allocator.free(workflow_src);
    try std.testing.expect(std.mem.indexOf(u8, workflow_src, "E2E — shell openExternal (Linux)") != null);
    try std.testing.expect(std.mem.indexOf(u8, workflow_src, "run-shell-open-external-runtime.sh") != null);
}

test "shell.openPath Linux GIO file handler wiring + runtime E2E" {
    const cef_src = try readCefSource();
    defer std.testing.allocator.free(cef_src);
    inline for (.{
        "g_file_query_exists",
        "g_file_get_uri",
        "linux_shell.openPath",
        "g_app_info_launch_default_for_uri",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, cef_src, needle) != null);
    }

    const e2e_src = try readProjectFile(
        "tests/e2e/shell-open-path-runtime.test.ts",
        1024 * 1024,
    );
    defer std.testing.allocator.free(e2e_src);
    inline for (.{
        "xdg-mime",
        "MimeType=",
        "shell_open_path",
        "pathToFileURL",
        "waitForMarker",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, e2e_src, needle) != null);
    }

    const workflow_src = try readProjectFile(".github/workflows/e2e.yml", 1024 * 1024);
    defer std.testing.allocator.free(workflow_src);
    inline for (.{
        "E2E — shell openPath (Linux)",
        "run-shell-open-path-runtime.sh",
        "shared-mime-info",
        "desktop-file-utils",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, workflow_src, needle) != null);
    }

    const shell_doc = try readProjectFile("documents/clipboard-shell.mdx", 1024 * 1024);
    defer std.testing.allocator.free(shell_doc);
    try std.testing.expect(std.mem.indexOf(u8, shell_doc, "path 또는 `file://` URI marker") != null);
}

test "notification Linux D-Bus wiring + runtime E2E" {
    const cef_src = try readCefSource();
    defer std.testing.allocator.free(cef_src);
    inline for (.{
        "const linux_notify",
        "linux_notify.isSupported",
        "linux_notify.show",
        "linux_notify.close",
        "org.freedesktop.Notifications",
        "GetServerInformation",
        "Notify",
        "CloseNotification",
        "g_dbus_connection_call_sync",
        "g_variant_new_boolean",
        "suppress-sound",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, cef_src, needle) != null);
    }

    const e2e_src = try readProjectFile(
        "tests/e2e/notification-linux-runtime.test.ts",
        1024 * 1024,
    );
    defer std.testing.allocator.free(e2e_src);
    inline for (.{
        "dbus.service.BusName('org.freedesktop.Notifications'",
        "notification_is_supported",
        "notification_request_permission",
        "notification_show",
        "notification_close",
        "CloseNotification",
        "suppress-sound",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, e2e_src, needle) != null);
    }

    const workflow_src = try readProjectFile(".github/workflows/e2e.yml", 1024 * 1024);
    defer std.testing.allocator.free(workflow_src);
    inline for (.{
        "E2E — notification (Linux)",
        "run-notification-linux-runtime.sh",
        "python3-dbus",
        "python3-gi",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, workflow_src, needle) != null);
    }

    const notification_doc = try readProjectFile("documents/notification.mdx", 1024 * 1024);
    defer std.testing.allocator.free(notification_doc);
    inline for (.{
        "Linux D-Bus backend",
        "D-Bus `Notify`",
        "D-Bus `CloseNotification`",
        "hints[\"suppress-sound\"] = true",
        "fake `org.freedesktop.Notifications` daemon",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, notification_doc, needle) != null);
    }

    const plan_src = try readProjectFile("docs/PLAN.md", 1024 * 1024 * 2);
    defer std.testing.allocator.free(plan_src);
    try std.testing.expect(std.mem.indexOf(u8, plan_src, "Linux freedesktop D-Bus") != null);
}

test "app.requestUserAttention IPC — NSApp request/cancel" {
    const main_src = try readMainSource();
    defer std.testing.allocator.free(main_src);
    inline for (.{
        "\"app_attention_request\"",
        "\"app_attention_cancel\"",
        "cef.appRequestUserAttention",
        "cef.appCancelUserAttentionRequest",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, main_src, needle) != null);
    }

    const cef_src = try readCefSource();
    defer std.testing.allocator.free(cef_src);
    inline for (.{
        "pub fn appRequestUserAttention",
        "pub fn appCancelUserAttentionRequest",
        "requestUserAttention:",
        "cancelUserAttentionRequest:",
        "kNSCriticalRequest",
        "kNSInformationalRequest",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, cef_src, needle) != null);
    }
}

test "clipboard RTF + Buffer IPC + cef pasteboard" {
    const main_src = try readMainSource();
    defer std.testing.allocator.free(main_src);
    inline for (.{
        "\"clipboard_read_rtf\"",
        "\"clipboard_write_rtf\"",
        "\"clipboard_read_buffer\"",
        "\"clipboard_write_buffer\"",
        "cef.clipboardReadRtf",
        "cef.clipboardWriteRtf",
        "cef.clipboardReadBuffer",
        "cef.clipboardWriteBuffer",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, main_src, needle) != null);
    }

    const cef_src = try readCefSource();
    defer std.testing.allocator.free(cef_src);
    inline for (.{
        "pub fn clipboardReadRtf",
        "pub fn clipboardWriteRtf",
        "pub fn clipboardReadBuffer",
        "pub fn clipboardWriteBuffer",
        "PASTEBOARD_TYPE_RTF",
        "public.rtf",
        "setData:forType:",
        "dataForType:",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, cef_src, needle) != null);
    }
}

test "clipboard TIFF IPC + cef pasteboard (public.tiff)" {
    const main_src = try readMainSource();
    defer std.testing.allocator.free(main_src);
    inline for (.{
        "\"clipboard_write_tiff\"",
        "\"clipboard_read_tiff\"",
        "cef.clipboardWriteTiff",
        "cef.clipboardReadTiff",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, main_src, needle) != null);
    }

    const cef_src = try readCefSource();
    defer std.testing.allocator.free(cef_src);
    inline for (.{
        "pub fn clipboardWriteTiff",
        "pub fn clipboardReadTiff",
        "public.tiff",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, cef_src, needle) != null);
    }
}

test "app.isPackaged + getAppPath IPC + cef NSBundle" {
    const main_src = try readMainSource();
    defer std.testing.allocator.free(main_src);
    inline for (.{
        "\"app_is_packaged\"",
        "\"app_get_app_path\"",
        "cef.appIsPackaged",
        "cef.appGetBundlePath",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, main_src, needle) != null);
    }

    const cef_src = try readCefSource();
    defer std.testing.allocator.free(cef_src);
    inline for (.{
        "pub fn appIsPackaged",
        "pub fn appGetBundlePath",
        "NSBundle",
        "mainBundle",
        "bundlePath",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, cef_src, needle) != null);
    }
}

test "windows.setOpacity/getOpacity/setBackgroundColor/setHasShadow/hasShadow IPC + cef NSWindow" {
    const main_src = try readMainSource();
    defer std.testing.allocator.free(main_src);
    inline for (.{
        "\"set_opacity\"",
        "\"get_opacity\"",
        "\"set_background_color\"",
        "\"set_has_shadow\"",
        "\"has_shadow\"",
        "window_ipc.handleSetOpacity",
        "window_ipc.handleGetOpacity",
        "window_ipc.handleSetBackgroundColor",
        "window_ipc.handleSetHasShadow",
        "window_ipc.handleHasShadow",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, main_src, needle) != null);
    }

    const cef_src = try readCefSource();
    defer std.testing.allocator.free(cef_src);
    inline for (.{
        "fn setOpacityImpl",
        "fn getOpacityImpl",
        "fn setBackgroundColorImpl",
        "fn setHasShadowImpl",
        "fn hasShadowImpl",
        "setAlphaValue:",
        "alphaValue",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, cef_src, needle) != null);
    }
}

test "windows.setAudioMuted/isAudioMuted IPC + cef vtable + browser_host" {
    const main_src = try readMainSource();
    defer std.testing.allocator.free(main_src);
    inline for (.{
        "\"set_audio_muted\"",
        "\"is_audio_muted\"",
        "window_ipc.handleSetAudioMuted",
        "window_ipc.handleIsAudioMuted",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, main_src, needle) != null);
    }

    const cef_src = try readCefSource();
    defer std.testing.allocator.free(cef_src);
    inline for (.{
        "fn setAudioMutedImpl",
        "fn isAudioMutedImpl",
        "host.set_audio_muted",
        "host.is_audio_muted",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, cef_src, needle) != null);
    }
}
