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
