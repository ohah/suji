//! iOS/Android 정적 링크 Zig 백엔드 예제.
//!
//! PC 의 examples/zig-backend 에 대응. 모바일 단일 바이너리 충돌을 피하려
//! 언어 고유 심볼 `suji_zig_backend_*` 로 노출 (Rust=suji_rs_*, Go=suji_go_*).
//! 표준 라이브러리만 사용 (suji 코어와 독립 — 별도 staticlib).

const std = @import("std");
const alloc = std.heap.c_allocator;

/// `zig:http` 전용 Io. 모바일 백엔드는 코어/SDK 독립(handle_ipc 에 io 인자
/// 없음)이라 `suji.io()` 를 못 쓴다 → src/embed.zig 의 코어와 동일한
/// `std.Io.Threaded.init_single_threaded` 패턴을 이 파일 안에서 자체 보유.
/// 동기 단발 fetch 라 단일 스레드로 충분(deinit 불요).
var http_threaded: std.Io.Threaded = std.Io.Threaded.init_single_threaded;

/// JSON 요청에서 "key":"..." 문자열 값 추출 (이스케이프 미지원 단순 스캐너 —
/// 예제 수준. 채널/인자는 프론트 shim 의 JSON.stringify 산출이라 충분).
fn field(json: []const u8, key: []const u8) ?[]const u8 {
    var buf: [64]u8 = undefined;
    const pat = std.fmt.bufPrint(&buf, "\"{s}\":\"", .{key}) catch return null;
    const i = std.mem.indexOf(u8, json, pat) orelse return null;
    const start = i + pat.len;
    const rel = std.mem.indexOfScalar(u8, json[start..], '"') orelse return null;
    return json[start .. start + rel];
}

fn dupZ(s: []const u8) ?[*:0]u8 {
    const b = alloc.allocSentinel(u8, s.len, 0) catch return null;
    @memcpy(b, s);
    return b.ptr;
}

export fn suji_zig_backend_init(core: ?*const anyopaque) callconv(.c) void {
    _ = core; // cross-call 미사용
}

/// `suji.http.fetch`(src/core/app.zig) 와 동일한 std.http wrap — 모바일 백엔드는
/// 코어-독립이라 SDK 대신 std 를 직접 사용. payload null=GET / non-null=POST.
/// ⚠️ backend-only: 프론트(WebView) shim 에 `zig:http` 채널을 노출하지 말 것
/// (Zig SDK 의 frontend 미노출 보안모델을 모바일에서도 관례+문서로 유지).
/// 응답 body 는 예제 단순화를 위해 ASCII(따옴표/백슬래시/제어문자 없음) 가정
/// — JSON escape 생략. 테스트 본문은 하니스가 통제.
fn httpFetchImpl(r: []const u8) ![*:0]u8 {
    const url = field(r, "url") orelse return error.MissingUrl;
    const payload: ?[]const u8 = field(r, "payload");

    var client: std.http.Client = .{ .allocator = alloc, .io = http_threaded.io() };
    defer client.deinit();

    var aw = std.Io.Writer.Allocating.init(alloc);
    errdefer aw.deinit();

    const res = try client.fetch(.{
        .location = .{ .url = url },
        .payload = payload,
        .response_writer = &aw.writer,
    });

    const body = try aw.toOwnedSlice();
    defer alloc.free(body);

    const json = try std.fmt.allocPrint(
        alloc,
        "{{\"from\":\"zig\",\"cmd\":\"zig:http\",\"result\":{{\"status\":{d},\"body\":\"{s}\"}}}}",
        .{ @intFromEnum(res.status), body },
    );
    defer alloc.free(json);
    return dupZ(json) orelse error.OutOfMemory;
}

fn httpFetch(r: []const u8) [*:0]u8 {
    return httpFetchImpl(r) catch |e| {
        const m = std.fmt.allocPrint(
            alloc,
            "{{\"from\":\"zig\",\"cmd\":\"zig:http\",\"error\":\"{s}\"}}",
            .{@errorName(e)},
        ) catch return @constCast("{}");
        defer alloc.free(m);
        return dupZ(m) orelse @constCast("{}");
    };
}

export fn suji_zig_backend_handle_ipc(req: [*:0]const u8) callconv(.c) [*:0]u8 {
    const r = std.mem.span(req);
    const cmd = field(r, "cmd") orelse "";
    if (std.mem.eql(u8, cmd, "zig:http")) return httpFetch(r);
    var buf: [512]u8 = undefined;
    const resp: []const u8 = blk: {
        if (std.mem.eql(u8, cmd, "zig:ping")) {
            break :blk "{\"from\":\"zig\",\"cmd\":\"zig:ping\",\"result\":{\"pong\":true,\"from\":\"zig-native\"}}";
        } else if (std.mem.eql(u8, cmd, "zig:rev")) {
            const s = field(r, "s") orelse "";
            var rev: [256]u8 = undefined;
            const n = @min(s.len, rev.len);
            for (0..n) |k| rev[k] = s[n - 1 - k];
            break :blk std.fmt.bufPrint(&buf, "{{\"from\":\"zig\",\"cmd\":\"zig:rev\",\"result\":{{\"rev\":\"{s}\"}}}}", .{rev[0..n]}) catch "{}";
        }
        break :blk std.fmt.bufPrint(&buf, "{{\"from\":\"zig\",\"error\":\"unknown: {s}\"}}", .{cmd}) catch "{}";
    };
    return dupZ(resp) orelse @constCast("{}");
}

export fn suji_zig_backend_free(p: ?[*:0]u8) callconv(.c) void {
    if (p) |ptr| {
        const s = std.mem.span(ptr);
        if (s.len == 0 or std.mem.eql(u8, s, "{}")) return; // static fallback
        alloc.free(s);
    }
}

export fn suji_zig_backend_destroy() callconv(.c) void {}
