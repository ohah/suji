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
///     return req.ok(.{ .msg = "pong" });
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

    pub fn command(comptime self: App, name: []const u8, handler: *const fn (Request) Response) App {
        var new = self;
        new.commands[new.command_count] = .{ .name = name, .handler = handler };
        new.command_count += 1;
        return new;
    }

    pub fn on(comptime self: App, event_name: []const u8, handler: *const fn (Event) void) App {
        var new = self;
        new.listeners[new.listener_count] = .{ .event = event_name, .handler = handler };
        new.listener_count += 1;
        return new;
    }

    /// IPC 요청 처리 (코어에서 호출)
    pub fn handleIpc(self: *const App, allocator: std.mem.Allocator, request_json: []const u8) ?[]const u8 {
        const cmd_name = extractStringField(request_json, "cmd") orelse return null;

        for (self.commands[0..self.command_count]) |c| {
            if (std.mem.eql(u8, c.name, cmd_name)) {
                const req = Request{
                    .raw = request_json,
                    .arena = allocator,
                };
                const resp = c.handler(req);
                return resp.data;
            }
        }

        return null;
    }

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
    arena: std.mem.Allocator,

    /// JSON에서 문자열 필드 추출
    pub fn string(self: *const Request, key: []const u8) ?[]const u8 {
        return extractStringField(self.raw, key);
    }

    /// JSON에서 정수 필드 추출
    pub fn int(self: *const Request, key: []const u8) ?i64 {
        return extractIntField(self.raw, key);
    }

    /// JSON에서 실수 필드 추출
    pub fn float(self: *const Request, key: []const u8) ?f64 {
        return extractFloatField(self.raw, key);
    }

    /// 성공 응답 (런타임, arena 할당)
    pub fn ok(self: *const Request, value: anytype) Response {
        const json = toJson(self.arena, value) catch
            return .{ .data = "{\"from\":\"zig\",\"error\":\"serialize failed\"}", .allocated = false };
        return .{ .data = json, .allocated = true };
    }

    /// 다른 백엔드 호출
    pub fn call(self: *const Request, backend: []const u8, request: []const u8) ?[]const u8 {
        _ = self;
        return callBackend(backend, request);
    }

    /// Raw JSON 응답 (크로스 호출 결과 포함 시)
    pub fn okRaw(self: *const Request, json: []const u8) Response {
        const result = std.fmt.allocPrint(self.arena, "{{\"from\":\"zig\",\"result\":{s}}}", .{json}) catch
            return .{ .data = "{\"from\":\"zig\",\"error\":\"format failed\"}", .allocated = false };
        return .{ .data = result, .allocated = true };
    }

    /// 여러 Raw JSON 결과를 합쳐서 응답
    pub fn okMulti(self: *const Request, fields: []const [2][]const u8) Response {
        var parts = std.ArrayListUnmanaged(u8){};
        parts.appendSlice(self.arena, "{\"from\":\"zig\"") catch return .{ .data = "{}", .allocated = false };
        for (fields) |field| {
            parts.appendSlice(self.arena, ",\"") catch break;
            parts.appendSlice(self.arena, field[0]) catch break;
            parts.appendSlice(self.arena, "\":") catch break;
            parts.appendSlice(self.arena, field[1]) catch break;
        }
        parts.appendSlice(self.arena, "}") catch {};
        const result = parts.toOwnedSlice(self.arena) catch return .{ .data = "{}", .allocated = false };
        return .{ .data = result, .allocated = true };
    }

    /// 에러 응답
    pub fn err(self: *const Request, msg: []const u8) Response {
        const json = std.fmt.allocPrint(self.arena, "{{\"from\":\"zig\",\"error\":\"{s}\"}}", .{msg}) catch
            return .{ .data = "{\"from\":\"zig\",\"error\":\"unknown\"}", .allocated = false };
        return .{ .data = json, .allocated = true };
    }
};

/// IPC 응답
pub const Response = struct {
    data: []const u8,
    allocated: bool = false,
};

/// 이벤트 데이터
pub const Event = struct {
    name: []const u8,
    data: []const u8,
};

/// 앱 빌더 시작
pub fn app() App {
    return App{};
}

// init은 app의 별칭 (root.zig 호환)
pub const init = app;

// ============================================
// 런타임 JSON 직렬화
// ============================================

fn toJson(allocator: std.mem.Allocator, value: anytype) ![]const u8 {
    const T = @TypeOf(value);
    const info = @typeInfo(T);

    if (info == .@"struct") {
        var parts = std.ArrayListUnmanaged(u8){};

        try parts.appendSlice(allocator, "{\"from\":\"zig\",\"result\":{");

        const fields = std.meta.fields(T);
        inline for (fields, 0..) |field, i| {
            const field_value = @field(value, field.name);

            // 키
            try parts.appendSlice(allocator, "\"");
            try parts.appendSlice(allocator, field.name);
            try parts.appendSlice(allocator, "\":");

            // 값
            try appendJsonValue(allocator, &parts, field_value);

            if (i < fields.len - 1) {
                try parts.appendSlice(allocator, ",");
            }
        }

        try parts.appendSlice(allocator, "}}");
        return parts.toOwnedSlice(allocator);
    }

    // 단일 값
    var parts = std.ArrayListUnmanaged(u8){};
    try parts.appendSlice(allocator, "{\"from\":\"zig\",\"result\":");
    try appendJsonValue(allocator, &parts, value);
    try parts.appendSlice(allocator, "}");
    return parts.toOwnedSlice(allocator);
}

fn appendJsonValue(allocator: std.mem.Allocator, parts: *std.ArrayListUnmanaged(u8), value: anytype) !void {
    const T = @TypeOf(value);
    const info = @typeInfo(T);

    // bool 먼저 (int보다 앞에)
    if (T == bool) {
        try parts.appendSlice(allocator, if (value) "true" else "false");
    }
    // 정수
    else if (info == .int or info == .comptime_int) {
        const str = try std.fmt.allocPrint(allocator, "{d}", .{value});
        try parts.appendSlice(allocator, str);
    }
    // 실수
    else if (info == .float or info == .comptime_float) {
        const str = try std.fmt.allocPrint(allocator, "{d}", .{value});
        try parts.appendSlice(allocator, str);
    }
    // 포인터 (문자열 포함)
    else if (info == .pointer) {
        const ptr = info.pointer;
        if (ptr.size == .slice and ptr.child == u8) {
            // []const u8
            try parts.appendSlice(allocator, "\"");
            try parts.appendSlice(allocator, value);
            try parts.appendSlice(allocator, "\"");
        } else if (ptr.size == .one and @typeInfo(ptr.child) == .array) {
            // *const [N:0]u8 (문자열 리터럴)
            const slice: []const u8 = value;
            try parts.appendSlice(allocator, "\"");
            try parts.appendSlice(allocator, slice);
            try parts.appendSlice(allocator, "\"");
        } else if (ptr.size == .slice) {
            // 기타 슬라이스
            try parts.appendSlice(allocator, "[");
            for (value, 0..) |item, i| {
                try appendJsonValue(allocator, parts, item);
                if (i < value.len - 1) try parts.appendSlice(allocator, ",");
            }
            try parts.appendSlice(allocator, "]");
        } else {
            try parts.appendSlice(allocator, "null");
        }
    }
    // optional
    else if (info == .optional) {
        if (value) |v| {
            try appendJsonValue(allocator, parts, v);
        } else {
            try parts.appendSlice(allocator, "null");
        }
    }
    // 기타
    else {
        try parts.appendSlice(allocator, "null");
    }
}

// ============================================
// JSON 필드 추출 (간이 파서)
// ============================================

fn extractStringField(json: []const u8, key: []const u8) ?[]const u8 {
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
    while (start < json.len and json[start] == ' ') start += 1;
    var end = start;
    if (end < json.len and json[end] == '-') end += 1;
    while (end < json.len and json[end] >= '0' and json[end] <= '9') end += 1;
    if (end == start) return null;
    return std.fmt.parseInt(i64, json[start..end], 10) catch null;
}

// ============================================
// C ABI Export (dlopen용)
// ============================================

/// comptime에서 App을 C ABI export 함수로 변환
/// 사용자 코드에서: comptime { suji.exportApp(app); }
/// Zig에서 다른 백엔드 호출 (SujiCore API 경유)
pub fn callBackend(backend: []const u8, request: []const u8) ?[]const u8 {
    const core = _global_core orelse {
        std.debug.print("[Zig callBackend] core is null\n", .{});
        return null;
    };
    const invoke_fn = core.invoke orelse {
        std.debug.print("[Zig callBackend] invoke is null\n", .{});
        return null;
    };

    // null-terminate
    var backend_buf: [256]u8 = undefined;
    const blen = @min(backend.len, backend_buf.len - 1);
    @memcpy(backend_buf[0..blen], backend[0..blen]);
    backend_buf[blen] = 0;

    var request_buf: [8192]u8 = undefined;
    const rlen = @min(request.len, request_buf.len - 1);
    @memcpy(request_buf[0..rlen], request[0..rlen]);
    request_buf[rlen] = 0;

    std.debug.print("[Zig callBackend] calling '{s}' with '{s}'\n", .{ backend_buf[0..blen], request_buf[0..rlen] });

    const resp_ptr = invoke_fn(@ptrCast(&backend_buf), @ptrCast(&request_buf));

    std.debug.print("[Zig callBackend] resp_ptr={*}\n", .{resp_ptr});

    // [*c]const u8 → 체크
    const resp: [*]const u8 = @ptrCast(resp_ptr orelse return null);
    if (resp[0] == 0) return null;

    // span으로 길이 찾기
    var len: usize = 0;
    while (resp[len] != 0) : (len += 1) {}
    if (len == 0) return null;

    std.debug.print("[Zig callBackend] got {d} bytes: {s}\n", .{ len, resp[0..len] });
    return resp[0..len];
}

// SujiCore 타입 (loader.zig와 동일 레이아웃)
const ExternSujiCore = extern struct {
    invoke: ?*const fn ([*c]const u8, [*c]const u8) callconv(.c) [*c]const u8,
    free: ?*const fn ([*c]const u8) callconv(.c) void,
    emit: ?*const fn ([*c]const u8, [*c]const u8) callconv(.c) void,
    on: ?*const fn ([*c]const u8, ?*const fn ([*c]const u8, [*c]const u8, ?*anyopaque) callconv(.c) void, ?*anyopaque) callconv(.c) u64,
    off: ?*const fn (u64) callconv(.c) void,
};

var _global_core: ?*const ExternSujiCore = null;

pub fn exportApp(comptime application: App) type {
    return struct {
        export fn backend_init(core: ?*const ExternSujiCore) callconv(.c) void {
            _global_core = core;
            std.debug.print("[Zig] ready (suji SDK, core API connected)\n", .{});
        }

        export fn backend_handle_ipc(request: [*:0]const u8) callconv(.c) ?[*:0]u8 {
            const req_slice = std.mem.span(request);

            // Arena per request
            var req_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            const allocator = req_arena.allocator();

            const resp = application.handleIpc(allocator, req_slice);
            if (resp) |data| {
                // 응답을 C 힙에 복사 (arena는 여기서 해제)
                const c_resp = std.heap.page_allocator.allocSentinel(u8, data.len, 0) catch {
                    req_arena.deinit();
                    return null;
                };
                @memcpy(c_resp[0..data.len], data[0..data.len]);
                req_arena.deinit();
                return c_resp;
            }

            req_arena.deinit();
            return null;
        }

        export fn backend_free(ptr: ?[*:0]u8) callconv(.c) void {
            if (ptr) |p| {
                const slice = std.mem.span(p);
                std.heap.page_allocator.free(slice[0 .. slice.len + 1]);
            }
        }

        export fn backend_destroy() callconv(.c) void {
            std.debug.print("[Zig] bye (suji SDK)\n", .{});
        }
    };
}

fn extractFloatField(json: []const u8, key: []const u8) ?f64 {
    var search_buf: [256]u8 = undefined;
    const pattern = std.fmt.bufPrint(&search_buf, "\"{s}\":", .{key}) catch return null;
    const idx = std.mem.indexOf(u8, json, pattern) orelse return null;
    var start = idx + pattern.len;
    while (start < json.len and json[start] == ' ') start += 1;
    var end = start;
    if (end < json.len and json[end] == '-') end += 1;
    while (end < json.len and (json[end] >= '0' and json[end] <= '9' or json[end] == '.')) end += 1;
    if (end == start) return null;
    return std.fmt.parseFloat(f64, json[start..end]) catch null;
}
