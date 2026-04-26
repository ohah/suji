/// Suji 공통 유틸리티
const std = @import("std");

/// 슬라이스를 고정 크기 버퍼에 null-terminate 복사
/// C ABI 함수에 전달할 때 사용
pub fn nullTerminate(src: []const u8, dst: []u8) [:0]const u8 {
    const len = @min(src.len, dst.len - 1);
    @memcpy(dst[0..len], src[0..len]);
    dst[len] = 0;
    return dst[0..len :0];
}

/// 슬라이스를 고정 크기 버퍼에 복사 (null-terminate 없이)
pub fn copyToBuf(src: []const u8, dst: []u8) []const u8 {
    const len = @min(src.len, dst.len);
    @memcpy(dst[0..len], src[0..len]);
    return dst[0..len];
}

/// `[:0]const u8` (sentinel-aware) → `[]const u8` (sentinel 제거).
/// `std.mem.sliceTo(s, 0)`을 wrapping — config 같은 곳에서 자주 반복되는 패턴 단축.
pub fn cstr(s: [:0]const u8) []const u8 {
    return std.mem.sliceTo(s, 0);
}

/// optional 버전. null이면 null 그대로.
pub fn cstrOpt(s: ?[:0]const u8) ?[]const u8 {
    return if (s) |v| std.mem.sliceTo(v, 0) else null;
}

/// i64 → u32 변환 (음수는 0 clamp, u32 max 초과는 maxInt 클램프).
/// suji.json/wire에 잘못된 값이 들어와도 ReleaseSafe `@intCast` panic 회피.
pub fn nonNegU32(v: i64) u32 {
    if (v < 0) return 0;
    if (v > std.math.maxInt(u32)) return std.math.maxInt(u32);
    return @intCast(v);
}

/// i64 → i32 변환 (i32 범위 밖은 양/음 한쪽으로 clamp).
/// 창 좌표(x/y)에 사용 — 음수 허용 (화면 왼쪽 밖 배치 가능).
pub fn clampI32(v: i64) i32 {
    if (v > std.math.maxInt(i32)) return std.math.maxInt(i32);
    if (v < std.math.minInt(i32)) return std.math.minInt(i32);
    return @intCast(v);
}

/// JSON 문자열 리터럴 안전 escape — `"` → `\"`, `\\` → `\\\\`, control char(`< 0x20`) drop.
/// dst 부족 시 null. 빈 src는 0 반환 (caller가 빈 결과로 처리).
/// 백엔드 SDK windows.* typed wrapper에서 사용.
pub fn escapeJsonStr(src: []const u8, dst: []u8) ?usize {
    var w: usize = 0;
    for (src) |b| {
        if (b < 0x20) continue;
        if (b == '"' or b == '\\') {
            if (w + 2 > dst.len) return null;
            dst[w] = '\\';
            dst[w + 1] = b;
            w += 2;
        } else {
            if (w + 1 > dst.len) return null;
            dst[w] = b;
            w += 1;
        }
    }
    return w;
}

/// JSON 문자열 리터럴 full escape — `escapeJsonStr`과 달리 newline/tab/CR을
/// 보존(`\n`/`\t`/`\r`)하고 그 외 control char(`< 0x20`)는 `\u00XX`로 인코딩.
/// 클립보드 / 사용자 텍스트처럼 줄바꿈 의미가 있는 payload용.
pub fn escapeJsonStrFull(src: []const u8, dst: []u8) ?usize {
    var w: usize = 0;
    for (src) |b| {
        if (b == '"' or b == '\\') {
            if (w + 2 > dst.len) return null;
            dst[w] = '\\';
            dst[w + 1] = b;
            w += 2;
        } else if (b == '\n' or b == '\r' or b == '\t' or b == 8 or b == 12) {
            if (w + 2 > dst.len) return null;
            dst[w] = '\\';
            dst[w + 1] = switch (b) {
                '\n' => 'n',
                '\r' => 'r',
                '\t' => 't',
                8 => 'b',
                12 => 'f',
                else => unreachable,
            };
            w += 2;
        } else if (b < 0x20) {
            if (w + 6 > dst.len) return null;
            const written = std.fmt.bufPrint(dst[w..], "\\u00{x:0>2}", .{b}) catch return null;
            w += written.len;
        } else {
            if (w + 1 > dst.len) return null;
            dst[w] = b;
            w += 1;
        }
    }
    return w;
}

/// JSON 문자열 unescape — `extractJsonString`이 반환하는 raw 슬라이스를 실제 바이트로 변환.
/// `\"`, `\\`, `\/`, `\n`, `\r`, `\t`, `\b`, `\f` 지원. `\u####`는 ASCII만 fast-path
/// (>= 0x80은 그대로 유지 — UTF-8 멀티바이트는 caller가 안 씀 가정). 알 수 없는 escape는 그대로 복사.
pub fn unescapeJsonStr(src: []const u8, dst: []u8) ?usize {
    var w: usize = 0;
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        const b = src[i];
        if (b != '\\' or i + 1 >= src.len) {
            if (w >= dst.len) return null;
            dst[w] = b;
            w += 1;
            continue;
        }
        const next = src[i + 1];
        const decoded: ?u8 = switch (next) {
            '"' => '"',
            '\\' => '\\',
            '/' => '/',
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            'b' => 8,
            'f' => 12,
            else => null,
        };
        if (decoded) |c| {
            if (w >= dst.len) return null;
            dst[w] = c;
            w += 1;
            i += 1;
            continue;
        }
        if (next == 'u' and i + 5 < src.len) {
            const hex = src[i + 2 .. i + 6];
            const code = std.fmt.parseInt(u16, hex, 16) catch {
                if (w >= dst.len) return null;
                dst[w] = b;
                w += 1;
                continue;
            };
            if (code < 0x80) {
                if (w >= dst.len) return null;
                dst[w] = @intCast(code);
                w += 1;
                i += 5;
                continue;
            }
            // 비-ASCII codepoint: dst에 UTF-8 인코딩 (최대 3바이트, BMP 가정).
            var utf8_buf: [4]u8 = undefined;
            const utf8_len = std.unicode.utf8Encode(code, &utf8_buf) catch {
                if (w >= dst.len) return null;
                dst[w] = b;
                w += 1;
                continue;
            };
            if (w + utf8_len > dst.len) return null;
            @memcpy(dst[w .. w + utf8_len], utf8_buf[0..utf8_len]);
            w += utf8_len;
            i += 5;
            continue;
        }
        // unknown escape — '\\'를 그대로 복사 (다음 문자는 다음 iteration에서 처리)
        if (w >= dst.len) return null;
        dst[w] = b;
        w += 1;
    }
    return w;
}

/// IPC 버퍼 크기 상수
pub const MAX_CHANNEL_NAME = 256;
pub const MAX_REQUEST = 8192;
pub const MAX_RESPONSE = 16384;
pub const MAX_ERROR_MSG = 512;
pub const MAX_NUM_BUF = 64;

// ============================================
// JSON 필드 추출 (경량 파서 — 정식 파서 필요하면 std.json 사용)
// ============================================

fn findKey(json: []const u8, key: []const u8) ?usize {
    var buf: [256]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "\"{s}\":", .{key}) catch return null;
    const idx = std.mem.indexOf(u8, json, needle) orelse return null;
    return idx + needle.len;
}

/// JSON에서 `"key":"value"`의 value 추출. `\"`, `\\` 이스케이프를 건너뛰지만 unescape는 안 함 (원문 슬라이스 반환).
pub fn extractJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    const after_colon = findKey(json, key) orelse return null;
    var i = after_colon;
    while (i < json.len and std.ascii.isWhitespace(json[i])) : (i += 1) {}
    if (i >= json.len or json[i] != '"') return null;
    const start = i + 1;
    var j = start;
    while (j < json.len) : (j += 1) {
        if (json[j] == '\\') {
            j += 1;
            continue;
        }
        if (json[j] == '"') return json[start..j];
    }
    return null;
}

/// JSON에서 `"key":123`의 정수 추출. 공백/음수 허용.
pub fn extractJsonInt(json: []const u8, key: []const u8) ?i64 {
    const after_colon = findKey(json, key) orelse return null;
    var start = after_colon;
    while (start < json.len and std.ascii.isWhitespace(json[start])) : (start += 1) {}
    var end = start;
    if (end < json.len and json[end] == '-') end += 1;
    while (end < json.len and json[end] >= '0' and json[end] <= '9') : (end += 1) {}
    if (end == start or (end == start + 1 and json[start] == '-')) return null;
    return std.fmt.parseInt(i64, json[start..end], 10) catch null;
}

/// JSON에서 `"key":true|false`의 boolean 추출. 다른 값(숫자/문자열/null)은 null.
pub fn extractJsonBool(json: []const u8, key: []const u8) ?bool {
    const after_colon = findKey(json, key) orelse return null;
    var start = after_colon;
    while (start < json.len and std.ascii.isWhitespace(json[start])) : (start += 1) {}
    if (start + 4 <= json.len and std.mem.eql(u8, json[start .. start + 4], "true")) return true;
    if (start + 5 <= json.len and std.mem.eql(u8, json[start .. start + 5], "false")) return false;
    return null;
}

/// JSON에서 `"key":1.5`의 실수 추출.
pub fn extractJsonFloat(json: []const u8, key: []const u8) ?f64 {
    const after_colon = findKey(json, key) orelse return null;
    var start = after_colon;
    while (start < json.len and std.ascii.isWhitespace(json[start])) : (start += 1) {}
    var end = start;
    if (end < json.len and json[end] == '-') end += 1;
    while (end < json.len and ((json[end] >= '0' and json[end] <= '9') or json[end] == '.')) : (end += 1) {}
    if (end == start or (end == start + 1 and json[start] == '-')) return null;
    return std.fmt.parseFloat(f64, json[start..end]) catch null;
}

test "escapeJsonStrFull: newline/tab/CR 보존 (\\n/\\t/\\r) + 백슬래시/따옴표 이스케이프" {
    var dst: [128]u8 = undefined;
    const n = escapeJsonStrFull("a\nb\tc\rd\"e\\f", &dst).?;
    try std.testing.expectEqualStrings("a\\nb\\tc\\rd\\\"e\\\\f", dst[0..n]);
}

test "escapeJsonStrFull: control char(<0x20)는 \\u00XX" {
    var dst: [64]u8 = undefined;
    const n = escapeJsonStrFull("a\x01b\x1fc", &dst).?;
    try std.testing.expectEqualStrings("a\\u0001b\\u001fc", dst[0..n]);
}

test "escapeJsonStrFull: 빈 문자열" {
    var dst: [16]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), escapeJsonStrFull("", &dst).?);
}

test "escapeJsonStrFull: 버퍼 부족 → null" {
    var dst: [3]u8 = undefined;
    try std.testing.expect(escapeJsonStrFull("ab\nc", &dst) == null);
}

test "unescapeJsonStr: \\n/\\t/\\r/\\b/\\f → control char" {
    var dst: [64]u8 = undefined;
    const n = unescapeJsonStr("a\\nb\\tc\\rd\\be\\ff", &dst).?;
    try std.testing.expectEqualStrings("a\nb\tc\rd\x08e\x0cf", dst[0..n]);
}

test "unescapeJsonStr: \\\" / \\\\ / \\/" {
    var dst: [32]u8 = undefined;
    const n = unescapeJsonStr("a\\\"b\\\\c\\/d", &dst).?;
    try std.testing.expectEqualStrings("a\"b\\c/d", dst[0..n]);
}

test "unescapeJsonStr: \\u#### ASCII fast-path" {
    var dst: [32]u8 = undefined;
    const n = unescapeJsonStr("a\\u0041b\\u0020c", &dst).?;
    try std.testing.expectEqualStrings("aAb c", dst[0..n]);
}

test "unescapeJsonStr: round-trip with escapeJsonStrFull" {
    const original = "line1\nline2\twith \"quote\" + \\backslash\\";
    var esc: [128]u8 = undefined;
    const en = escapeJsonStrFull(original, &esc).?;
    var unesc: [128]u8 = undefined;
    const un = unescapeJsonStr(esc[0..en], &unesc).?;
    try std.testing.expectEqualStrings(original, unesc[0..un]);
}

test "unescapeJsonStr: 알 수 없는 escape는 백슬래시 그대로" {
    var dst: [16]u8 = undefined;
    const n = unescapeJsonStr("a\\xb", &dst).?;
    try std.testing.expectEqualStrings("a\\xb", dst[0..n]);
}

test "unescapeJsonStr: 빈 문자열" {
    var dst: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), unescapeJsonStr("", &dst).?);
}

test "escapeJsonStrFull: 정확히 dst 끝까지 차는 케이스" {
    var dst: [4]u8 = undefined;
    // "ab\n" → 4 bytes (a, b, \, n). 정확히 dst.len.
    const n = escapeJsonStrFull("ab\n", &dst).?;
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqualStrings("ab\\n", dst[0..n]);
}

test "escapeJsonStrFull: backspace(\\b) + form feed(\\f) 처리" {
    var dst: [16]u8 = undefined;
    const n = escapeJsonStrFull("a\x08b\x0cc", &dst).?;
    try std.testing.expectEqualStrings("a\\bb\\fc", dst[0..n]);
}

test "escapeJsonStrFull: 0x7F (DEL) 이상은 그대로" {
    var dst: [16]u8 = undefined;
    const n = escapeJsonStrFull("a\x7fb", &dst).?;
    // 0x7F는 control이지만 < 0x20 아니라서 그대로 (JSON spec 상 escape 불필요).
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 'a', 0x7f, 'b' }, dst[0..n]);
}

test "escapeJsonStrFull: control char 0x00 (null byte) → \\u0000" {
    var dst: [32]u8 = undefined;
    const n = escapeJsonStrFull("a\x00b", &dst).?;
    try std.testing.expectEqualStrings("a\\u0000b", dst[0..n]);
}

test "escapeJsonStrFull: UTF-8 멀티바이트 (한글 0xEA 0xB0 0x80) 그대로 통과" {
    var dst: [16]u8 = undefined;
    // "가" = 0xEA 0xB0 0x80 (3 bytes). escape 안 됨 (모두 >= 0x20).
    const n = escapeJsonStrFull("가", &dst).?;
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xEA, 0xB0, 0x80 }, dst[0..n]);
}

test "unescapeJsonStr: trailing backslash (incomplete escape) 그대로 보존" {
    var dst: [16]u8 = undefined;
    const n = unescapeJsonStr("abc\\", &dst).?;
    // src.len-1 == '\\' AND i+1 >= src.len → continue without escape, '\\' 그대로.
    try std.testing.expectEqualStrings("abc\\", dst[0..n]);
}

test "unescapeJsonStr: 연속된 escape (\\\\\\n)" {
    var dst: [8]u8 = undefined;
    // input: \ \ \ n (4 chars: backslash backslash backslash n)
    // → \\ unescape to \ → \n unescape to newline → result: \\n (backslash + newline)
    const n = unescapeJsonStr("\\\\\\n", &dst).?;
    try std.testing.expectEqualSlices(u8, &[_]u8{ '\\', '\n' }, dst[0..n]);
}

test "unescapeJsonStr: \\u#### 비-ASCII (0x80+) UTF-8 인코딩 — 한글 \\uAC00 = '가'" {
    var dst: [8]u8 = undefined;
    const n = unescapeJsonStr("\\uac00", &dst).?;
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xEA, 0xB0, 0x80 }, dst[0..n]);
}

test "unescapeJsonStr: \\u#### 잘못된 hex는 백슬래시만 그대로" {
    var dst: [16]u8 = undefined;
    const n = unescapeJsonStr("\\uZZZZ", &dst).?;
    // hex parse 실패 → 백슬래시만 그대로 + 'u', 'Z', 'Z', 'Z', 'Z' 차례로 처리.
    // 다음 iteration들은 escape 아니라 그대로.
    try std.testing.expectEqualStrings("\\uZZZZ", dst[0..n]);
}

test "unescapeJsonStr: dst 정확히 차는 boundary" {
    var dst: [3]u8 = undefined;
    const n = unescapeJsonStr("a\\nb", &dst).?;
    // a + \n + b = 3 bytes. 정확히 dst.len.
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 'a', '\n', 'b' }, dst[0..n]);
}

test "unescapeJsonStr: dst 부족 → null" {
    var dst: [2]u8 = undefined;
    try std.testing.expect(unescapeJsonStr("a\\nb", &dst) == null);
}

test "round-trip: 모든 control chars (0x00 ~ 0x1F)" {
    var raw: [32]u8 = undefined;
    for (0..32) |i| raw[i] = @intCast(i);
    var esc: [256]u8 = undefined;
    const en = escapeJsonStrFull(&raw, &esc).?;
    var unesc: [32]u8 = undefined;
    const un = unescapeJsonStr(esc[0..en], &unesc).?;
    try std.testing.expectEqualSlices(u8, &raw, unesc[0..un]);
}

test "round-trip: 4-byte UTF-8 이모지" {
    // 🎉 = U+1F389 = F0 9F 8E 89 (4 bytes)
    const original = "Hi 🎉!";
    var esc: [64]u8 = undefined;
    const en = escapeJsonStrFull(original, &esc).?;
    var unesc: [64]u8 = undefined;
    const un = unescapeJsonStr(esc[0..en], &unesc).?;
    try std.testing.expectEqualStrings(original, unesc[0..un]);
}

test "extractJsonString basic + whitespace after colon + escape" {
    try std.testing.expectEqualStrings("pong", extractJsonString("{\"cmd\":\"pong\"}", "cmd").?);
    try std.testing.expectEqualStrings("pong", extractJsonString("{\"cmd\": \"pong\"}", "cmd").?);
    // escaped quote inside value (slice includes the backslash)
    try std.testing.expectEqualStrings("a\\\"b", extractJsonString("{\"x\":\"a\\\"b\"}", "x").?);
    try std.testing.expect(extractJsonString("{\"y\":\"v\"}", "x") == null);
}

test "extractJsonInt basic + negative + whitespace" {
    try std.testing.expectEqual(@as(i64, 2), extractJsonInt("{\"__window\":2}", "__window").?);
    try std.testing.expectEqual(@as(i64, -5), extractJsonInt("{\"n\": -5}", "n").?);
    try std.testing.expect(extractJsonInt("{\"n\":-}", "n") == null);
    try std.testing.expect(extractJsonInt("{\"m\":1}", "n") == null);
}

test "extractJsonBool true/false/누락/잘못된 값" {
    try std.testing.expectEqual(@as(?bool, true), extractJsonBool("{\"k\":true}", "k"));
    try std.testing.expectEqual(@as(?bool, false), extractJsonBool("{\"k\":false}", "k"));
    try std.testing.expectEqual(@as(?bool, true), extractJsonBool("{\"k\": true}", "k"));
    try std.testing.expect(extractJsonBool("{\"x\":true}", "k") == null); // 키 없음
    try std.testing.expect(extractJsonBool("{\"k\":1}", "k") == null); // 숫자
    try std.testing.expect(extractJsonBool("{\"k\":\"true\"}", "k") == null); // 문자열
}

test "extractJsonFloat basic + negative" {
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), extractJsonFloat("{\"v\":1.5}", "v").?, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, -2.25), extractJsonFloat("{\"v\":-2.25}", "v").?, 1e-9);
}
