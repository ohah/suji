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
