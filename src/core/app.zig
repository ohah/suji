const std = @import("std");
const events = @import("events");
const util = @import("util");

/// Suji 앱 빌더
///
/// Electron 스타일 API:
///   handle — 요청/응답 (ipcMain.handle)
///   on     — 이벤트 수신 (ipcMain.on)
///   send   — 이벤트 발신 (webContents.send)
///
/// ```zig
/// const suji = @import("suji");
///
/// pub const app = suji.app()
///     .handle("ping", ping)
///     .handle("greet", greet)
///     .on("clicked", onClicked);
///
/// fn ping(req: suji.Request) suji.Response {
///     return req.ok(.{ .msg = "pong" });
/// }
/// ```
pub const App = struct {
    handlers: [MAX_HANDLERS]Handler = undefined,
    handler_count: usize = 0,
    listeners: [MAX_LISTENERS]EventListener = undefined,
    listener_count: usize = 0,

    const MAX_HANDLERS = 64;
    const MAX_LISTENERS = 64;

    const Handler = struct {
        channel: []const u8,
        func: *const fn (Request) Response,
    };

    const EventListener = struct {
        channel: []const u8,
        func: *const fn (Event) void,
    };

    /// 요청/응답 핸들러 등록 (Electron: ipcMain.handle)
    pub fn handle(comptime self: App, channel: []const u8, func: *const fn (Request) Response) App {
        var new = self;
        new.handlers[new.handler_count] = .{ .channel = channel, .func = func };
        new.handler_count += 1;
        return new;
    }

    /// 이벤트 리스너 등록 (Electron: ipcMain.on)
    pub fn on(comptime self: App, channel: []const u8, func: *const fn (Event) void) App {
        var new = self;
        new.listeners[new.listener_count] = .{ .channel = channel, .func = func };
        new.listener_count += 1;
        return new;
    }


    /// IPC 요청 처리
    pub fn handleIpc(self: *const App, allocator: std.mem.Allocator, request_json: []const u8) ?[]const u8 {
        const channel = extractStringField(request_json, "cmd") orelse return null;

        for (self.handlers[0..self.handler_count]) |h| {
            if (std.mem.eql(u8, h.channel, channel)) {
                const req = Request{
                    .raw = request_json,
                    .arena = allocator,
                };
                const resp = h.func(req);
                return resp.data;
            }
        }

        return null;
    }

    pub fn registerEvents(self: *const App, bus: *events.EventBus) void {
        for (self.listeners[0..self.listener_count]) |l| {
            // 함수 포인터를 anyopaque로 캐스팅해서 C ABI 콜백에 전달
            const handler_ptr: *const anyopaque = @ptrCast(l.func);
            _ = bus.onC(l.channel, eventBridgeCallback, @constCast(handler_ptr));
        }
    }

    fn eventBridgeCallback(event_name: [*c]const u8, data: [*c]const u8, arg: ?*anyopaque) callconv(.c) void {
        const handler: *const fn (Event) void = @ptrCast(@alignCast(arg orelse return));
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(event_name)));
        const d = std.mem.span(@as([*:0]const u8, @ptrCast(data)));
        handler(.{ .channel = name, .data = d });
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

    /// 다른 백엔드 호출 (Electron: ipcRenderer.invoke)
    pub fn invoke(self: *const Request, backend: []const u8, request: []const u8) ?[]const u8 {
        _ = self;
        return callBackend(backend, request);
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
    channel: []const u8,
    data: []const u8,
};

/// 이벤트 발신 (Electron: webContents.send)
pub fn send(channel: []const u8, data: []const u8) void {
    const core = _global_core orelse return;
    const emit_fn = core.emit orelse return;

    var ch_buf: [util.MAX_CHANNEL_NAME]u8 = undefined;
    const ch = util.nullTerminate(channel, &ch_buf);

    var data_buf: [util.MAX_REQUEST]u8 = undefined;
    const d = util.nullTerminate(data, &data_buf);

    emit_fn(@ptrCast(ch.ptr), @ptrCast(d.ptr));
}

/// 앱 빌더 시작
pub fn app() App {
    return App{};
}


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
            try parts.appendSlice(allocator, "\"");
            try parts.appendSlice(allocator, field.name);
            try parts.appendSlice(allocator, "\":");
            try appendJsonValue(allocator, &parts, field_value);
            if (i < fields.len - 1) try parts.appendSlice(allocator, ",");
        }
        try parts.appendSlice(allocator, "}}");
        return parts.toOwnedSlice(allocator);
    }

    var parts = std.ArrayListUnmanaged(u8){};
    try parts.appendSlice(allocator, "{\"from\":\"zig\",\"result\":");
    try appendJsonValue(allocator, &parts, value);
    try parts.appendSlice(allocator, "}");
    return parts.toOwnedSlice(allocator);
}

fn appendJsonValue(allocator: std.mem.Allocator, parts: *std.ArrayListUnmanaged(u8), value: anytype) !void {
    const T = @TypeOf(value);
    const info = @typeInfo(T);

    if (T == bool) {
        try parts.appendSlice(allocator, if (value) "true" else "false");
    } else if (info == .int or info == .comptime_int) {
        var num_buf: [32]u8 = undefined;
        const str = std.fmt.bufPrint(&num_buf, "{d}", .{value}) catch return error.OutOfMemory;
        try parts.appendSlice(allocator, str);
    } else if (info == .float or info == .comptime_float) {
        var num_buf: [64]u8 = undefined;
        const str = std.fmt.bufPrint(&num_buf, "{d}", .{value}) catch return error.OutOfMemory;
        try parts.appendSlice(allocator, str);
    } else if (info == .pointer) {
        const ptr = info.pointer;
        if (ptr.size == .slice and ptr.child == u8) {
            try parts.appendSlice(allocator, "\"");
            try parts.appendSlice(allocator, value);
            try parts.appendSlice(allocator, "\"");
        } else if (ptr.size == .one and @typeInfo(ptr.child) == .array) {
            const slice: []const u8 = value;
            try parts.appendSlice(allocator, "\"");
            try parts.appendSlice(allocator, slice);
            try parts.appendSlice(allocator, "\"");
        } else if (ptr.size == .slice) {
            try parts.appendSlice(allocator, "[");
            for (value, 0..) |item, i| {
                try appendJsonValue(allocator, parts, item);
                if (i < value.len - 1) try parts.appendSlice(allocator, ",");
            }
            try parts.appendSlice(allocator, "]");
        } else {
            try parts.appendSlice(allocator, "null");
        }
    } else if (info == .optional) {
        if (value) |v| {
            try appendJsonValue(allocator, parts, v);
        } else {
            try parts.appendSlice(allocator, "null");
        }
    } else {
        try parts.appendSlice(allocator, "null");
    }
}

// ============================================
// JSON 필드 추출
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

// ============================================
// SujiCore (크로스 호출 + 이벤트)
// ============================================

const ExternSujiCore = extern struct {
    invoke_fn: ?*const fn ([*c]const u8, [*c]const u8) callconv(.c) [*c]const u8,
    free_fn: ?*const fn ([*c]const u8) callconv(.c) void,
    emit: ?*const fn ([*c]const u8, [*c]const u8) callconv(.c) void,
    on_fn: ?*const fn ([*c]const u8, ?*const fn ([*c]const u8, [*c]const u8, ?*anyopaque) callconv(.c) void, ?*anyopaque) callconv(.c) u64,
    off_fn: ?*const fn (u64) callconv(.c) void,
};

var _global_core: ?*const ExternSujiCore = null;

/// 다른 백엔드 호출 (invoke)
pub fn callBackend(backend: []const u8, request: []const u8) ?[]const u8 {
    const core = _global_core orelse return null;
    const inv_fn = core.invoke_fn orelse return null;

    var backend_buf: [util.MAX_CHANNEL_NAME]u8 = undefined;
    _ = util.nullTerminate(backend, &backend_buf);

    var request_buf: [util.MAX_REQUEST]u8 = undefined;
    _ = util.nullTerminate(request, &request_buf);

    const resp_ptr = inv_fn(@ptrCast(&backend_buf), @ptrCast(&request_buf));
    const resp: [*]const u8 = @ptrCast(resp_ptr orelse return null);
    if (resp[0] == 0) return null;
    var len: usize = 0;
    while (resp[len] != 0) : (len += 1) {}
    if (len == 0) return null;
    return resp[0..len];
}

// ============================================
// C ABI Export (dlopen용)
// ============================================

pub fn exportApp(comptime application: App) type {
    return struct {
        export fn backend_init(core: ?*const ExternSujiCore) callconv(.c) void {
            _global_core = core;
            // 이벤트 리스너 등록 (SujiCore.on 사용)
            if (core) |c| {
                if (c.on_fn) |on_fn| {
                    for (application.listeners[0..application.listener_count]) |l| {
                        var ch_buf: [util.MAX_CHANNEL_NAME]u8 = undefined;
                        const ch = util.nullTerminate(l.channel, &ch_buf);
                        const handler_ptr: *const anyopaque = @ptrCast(l.func);
                        _ = on_fn(ch.ptr, App.eventBridgeCallback, @constCast(handler_ptr));
                    }
                }
            }
            std.debug.print("[Zig] ready (suji SDK, core API connected)\n", .{});
        }

        export fn backend_handle_ipc(request: [*:0]const u8) callconv(.c) ?[*:0]u8 {
            const req_slice = std.mem.span(request);
            var req_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            const allocator = req_arena.allocator();

            const resp = application.handleIpc(allocator, req_slice);
            if (resp) |data| {
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
