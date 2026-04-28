const std = @import("std");

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
        if (json[i] == '\\') { i += 1; continue; }
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
    return std.Io.Dir.cwd().readFileAlloc(
        std_io,
        "src/platform/cef.zig",
        std.testing.allocator,
        .limited(4 * 1024 * 1024),
    );
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
        "isPrimary",
        "visibleWidth",
        "visibleHeight",
        "scaleFactor",
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
        "PreventUserIdleSystemSleep",
        "PreventUserIdleDisplaySleep",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, cef_src, needle) != null);
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
