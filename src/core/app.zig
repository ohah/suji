const std = @import("std");
const events = @import("events");

/// Suji 앱 빌더 (Zig 내장 백엔드)
///
/// ```zig
/// const suji = @import("suji");
///
/// pub const app = suji.app()
///     .command("ping", ping)
///     .command("greet", greet)
///     .on("clicked", onClicked);
///
/// fn ping(req: suji.Request) suji.Response {
///     return suji.ok(.{ .msg = "pong" });
/// }
/// ```
pub const App = struct {
    commands: [MAX_COMMANDS]Command = undefined,
    command_count: usize = 0,
    listeners: [MAX_LISTENERS]EventListener = undefined,
    listener_count: usize = 0,

    const MAX_COMMANDS = 64;
    const MAX_LISTENERS = 64;

    const Command = struct {
        name: []const u8,
        handler: *const fn (Request) Response,
    };

    const EventListener = struct {
        event: []const u8,
        handler: *const fn (Event) void,
    };

    /// 커맨드 등록
    pub fn command(comptime self: App, name: []const u8, handler: *const fn (Request) Response) App {
        var new = self;
        new.commands[new.command_count] = .{ .name = name, .handler = handler };
        new.command_count += 1;
        return new;
    }

    /// 이벤트 리스너 등록
    pub fn on(comptime self: App, event_name: []const u8, handler: *const fn (Event) void) App {
        var new = self;
        new.listeners[new.listener_count] = .{ .event = event_name, .handler = handler };
        new.listener_count += 1;
        return new;
    }

    /// IPC 요청 처리 (코어에서 호출)
    pub fn handleIpc(self: *const App, request_json: []const u8) ?[]const u8 {
        // cmd 추출
        const cmd = extractCmd(request_json) orelse return null;

        for (self.commands[0..self.command_count]) |c| {
            if (std.mem.eql(u8, c.name, cmd)) {
                const req = Request{ .raw = request_json };
                const resp = c.handler(req);
                return resp.data;
            }
        }

        return null;
    }

    /// 이벤트 리스너들을 EventBus에 등록
    pub fn registerEvents(self: *const App, bus: *events.EventBus) void {
        for (self.listeners[0..self.listener_count]) |l| {
            _ = bus.on(l.event, struct {
                fn cb(_: [*:0]const u8) void {}
            }.cb);
        }
    }
};

/// IPC 요청
pub const Request = struct {
    raw: []const u8,

    /// JSON에서 문자열 필드 추출
    pub fn string(self: *const Request, key: []const u8) ?[]const u8 {
        return extractStringField(self.raw, key);
    }

    /// JSON에서 정수 필드 추출
    pub fn int(self: *const Request, key: []const u8) ?i64 {
        return extractIntField(self.raw, key);
    }
};

/// IPC 응답
pub const Response = struct {
    data: []const u8,
};

/// 이벤트 데이터
pub const Event = struct {
    name: []const u8,
    data: []const u8,
};

/// 응답 생성 (JSON 문자열)
pub fn okJson(comptime json: []const u8) Response {
    return .{ .data = "{\"from\":\"zig\",\"result\":" ++ json ++ "}" };
}

/// 응답 생성 (런타임 문자열, 버퍼 사용)
pub fn okFmt(buf: []u8, comptime fmt_str: []const u8, args: anytype) Response {
    const result = std.fmt.bufPrint(buf, fmt_str, args) catch return .{ .data = "{\"from\":\"zig\",\"error\":\"fmt\"}" };
    return .{ .data = result };
}

/// 단순 성공 응답
pub fn ok(comptime value: anytype) Response {
    // comptime으로 간단한 타입만 지원
    const T = @TypeOf(value);
    const info = @typeInfo(T);
    if (info == .@"struct") {
        // struct의 필드를 comptime JSON으로 변환
        comptime var json: []const u8 = "{\"from\":\"zig\",\"result\":{";
        const fields = std.meta.fields(T);
        inline for (fields, 0..) |field, i| {
            const field_value = @field(value, field.name);
            json = json ++ "\"" ++ field.name ++ "\":";
            const FT = @TypeOf(field_value);
            if (FT == comptime_int or FT == i64 or FT == i32 or FT == u64 or FT == usize) {
                json = json ++ std.fmt.comptimePrint("{d}", .{field_value});
            } else {
                json = json ++ "\"" ++ field_value ++ "\"";
            }
            if (i < fields.len - 1) json = json ++ ",";
        }
        json = json ++ "}}";
        return .{ .data = json };
    }
    return .{ .data = "{\"from\":\"zig\",\"result\":null}" };
}

/// 앱 빌더 시작
pub fn init() App {
    return App{};
}

// ============================================
// JSON 헬퍼 (간이 파서, std.json 없이)
// ============================================

fn extractCmd(json: []const u8) ?[]const u8 {
    return extractStringField(json, "cmd");
}

fn extractStringField(json: []const u8, key: []const u8) ?[]const u8 {
    // "key":"value" 패턴 찾기
    var search_buf: [256]u8 = undefined;
    const pattern = std.fmt.bufPrint(&search_buf, "\"{s}\":\"", .{key}) catch return null;

    const idx = std.mem.indexOf(u8, json, pattern) orelse return null;
    const start = idx + pattern.len;
    const end = std.mem.indexOfPos(u8, json, start, "\"") orelse return null;

    return json[start..end];
}

fn extractIntField(json: []const u8, key: []const u8) ?i64 {
    var search_buf: [256]u8 = undefined;
    const pattern = std.fmt.bufPrint(&search_buf, "\"{s}\":", .{key}) catch return null;

    const idx = std.mem.indexOf(u8, json, pattern) orelse return null;
    var start = idx + pattern.len;

    // 공백 스킵
    while (start < json.len and json[start] == ' ') start += 1;

    // 숫자 파싱
    var end = start;
    if (end < json.len and json[end] == '-') end += 1;
    while (end < json.len and json[end] >= '0' and json[end] <= '9') end += 1;

    if (end == start) return null;
    return std.fmt.parseInt(i64, json[start..end], 10) catch null;
}
