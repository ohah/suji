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
    /// ready/bye 로그 prefix. 동일 프로세스에서 Zig SDK로 빌드된 dylib이 여러 개일 때
    /// 구분 가능. 미지정 시 "Zig". (.name("state-plugin") → "[state-plugin] ready")
    name: []const u8 = "Zig",

    const MAX_HANDLERS = 64;
    const MAX_LISTENERS = 64;

    const Handler = struct {
        channel: []const u8,
        func: *const fn (Request, InvokeEvent) Response,
    };

    const EventListener = struct {
        channel: []const u8,
        func: *const fn (Event) void,
    };

    /// 요청/응답 핸들러 등록 (Electron: ipcMain.handle).
    /// func는 `fn (Request) Response` 또는 `fn (Request, InvokeEvent) Response` 둘 다 허용.
    /// 1-arity는 comptime wrapper로 2-arity에 맞춰 adapt — 내부 저장은 단일 타입.
    pub fn handle(comptime self: App, channel: []const u8, comptime func: anytype) App {
        const FT = @TypeOf(func);
        const info = @typeInfo(FT);
        if (info != .@"fn") @compileError("handle: func must be a function");
        const arity = info.@"fn".params.len;

        const adapted: *const fn (Request, InvokeEvent) Response = switch (arity) {
            1 => struct {
                fn wrap(req: Request, _: InvokeEvent) Response {
                    return func(req);
                }
            }.wrap,
            2 => func,
            else => @compileError("handle: func must be fn(Request) or fn(Request, InvokeEvent)"),
        };

        var new = self;
        new.handlers[new.handler_count] = .{ .channel = channel, .func = adapted };
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

    /// ready/bye 로그 prefix 지정. 같은 Zig SDK로 빌드된 dylib이 여러 개일 때 구분용.
    pub fn named(comptime self: App, comptime n: []const u8) App {
        var new = self;
        new.name = n;
        return new;
    }


    /// IPC 요청 처리. request_json의 `__window` 필드(cef.zig가 wire에 자동 주입)에서
    /// 파생한 InvokeEvent를 함께 핸들러에 전달. `__window`가 없으면 window.id=0.
    pub fn handleIpc(self: *const App, allocator: std.mem.Allocator, request_json: []const u8) ?[]const u8 {
        const channel = extractStringField(request_json, "cmd") orelse return null;

        for (self.handlers[0..self.handler_count]) |h| {
            if (std.mem.eql(u8, h.channel, channel)) {
                const req = Request{
                    .raw = request_json,
                    .arena = allocator,
                };
                const win_id_raw = extractIntField(request_json, "__window") orelse 0;
                const win_id: u32 = if (win_id_raw >= 0) @intCast(win_id_raw) else 0;
                const win_name = extractStringField(request_json, "__window_name");
                const win_url = extractStringField(request_json, "__window_url");
                const event = InvokeEvent{ .window = .{ .id = win_id, .name = win_name, .url = win_url } };
                const resp = h.func(req, event);
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
        var parts = std.ArrayList(u8).empty;
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

/// 이벤트 데이터 — `on(channel, fn)` 리스너가 받는 window event payload.
pub const Event = struct {
    channel: []const u8,
    data: []const u8,
};

/// IPC 핸들러 컨텍스트 — Electron의 `IpcMainInvokeEvent` 대응.
///   - window.id: wire의 `__window` 필드에서 파생. 어느 창에서 호출됐는지 식별.
///                필드가 없거나 잘못된 경우 0 (legacy/direct 호출 경로 등).
///   - window.name: wire의 `__window_name` 필드에서 파생. WM에서 창을 `.name("settings")`
///                  같은 식으로 등록한 경우에만 non-null. 없으면 null (익명 창).
/// 핸들러 시그니처: `fn (Request, InvokeEvent) Response` — 2-arity 선택 시 사용.
pub const InvokeEvent = struct {
    window: Window,

    pub const Window = struct {
        id: u32,
        name: ?[]const u8 = null,
        /// sender 창의 main frame URL (Electron `event.sender.url` 대응).
        /// 로드 중이거나 빈 페이지면 null. wire 레벨에서 `__window_url`이 주입된 경우만 설정.
        url: ?[]const u8 = null,
    };
};

/// 이벤트 발신 — 모든 창으로 브로드캐스트 (Electron 브로드캐스트 패턴).
pub fn send(channel: []const u8, data: []const u8) void {
    const core = _global_core orelse return;
    const emit_fn = core.emit orelse return;

    var ch_buf: [util.MAX_CHANNEL_NAME]u8 = undefined;
    const ch = util.nullTerminate(channel, &ch_buf);

    var data_buf: [util.MAX_REQUEST]u8 = undefined;
    const d = util.nullTerminate(data, &data_buf);

    emit_fn(@ptrCast(ch.ptr), @ptrCast(d.ptr));
}

/// 특정 창(window id)에만 이벤트 전달 (Electron: `webContents.send`).
/// 대상 창이 이미 닫혔거나 emit_to_fn이 없으면 silent no-op.
pub fn sendTo(target: u32, channel: []const u8, data: []const u8) void {
    const core = _global_core orelse return;
    const fn_ptr = core.emit_to_fn orelse return;

    var ch_buf: [util.MAX_CHANNEL_NAME]u8 = undefined;
    const ch = util.nullTerminate(channel, &ch_buf);

    var data_buf: [util.MAX_REQUEST]u8 = undefined;
    const d = util.nullTerminate(data, &data_buf);

    fn_ptr(target, @ptrCast(ch.ptr), @ptrCast(d.ptr));
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
        var parts = std.ArrayList(u8).empty;
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

    var parts = std.ArrayList(u8).empty;
    try parts.appendSlice(allocator, "{\"from\":\"zig\",\"result\":");
    try appendJsonValue(allocator, &parts, value);
    try parts.appendSlice(allocator, "}");
    return parts.toOwnedSlice(allocator);
}

fn appendJsonValue(allocator: std.mem.Allocator, parts: *std.ArrayList(u8), value: anytype) !void {
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
// JSON 필드 추출 — core/util.zig로 위임 (경량 파서)
// ============================================

const extractStringField = util.extractJsonString;
const extractIntField = util.extractJsonInt;
const extractFloatField = util.extractJsonFloat;

/// JSON 값 추출 (문자열/숫자/bool/object/array 등): {"key":value} → value 슬라이스
pub fn extractJsonValue(json: []const u8, field: []const u8) ?[]const u8 {
    var pattern_buf: [128]u8 = undefined;
    const pattern = std.fmt.bufPrint(&pattern_buf, "\"{s}\":", .{field}) catch return null;
    const idx = std.mem.indexOf(u8, json, pattern) orelse return null;
    const start = idx + pattern.len;

    var i = start;
    while (i < json.len and json[i] == ' ') i += 1;
    if (i >= json.len) return null;

    const first = json[i];
    if (first == '"') {
        return json[i..findStringEnd(json, i)];
    } else if (first == '{' or first == '[') {
        return json[i..findMatchingBrace(json, i)];
    } else {
        const end = std.mem.indexOfAnyPos(u8, json, i, ",}]") orelse json.len;
        var e = end;
        while (e > i and json[e - 1] == ' ') e -= 1;
        return json[i..e];
    }
}

fn findStringEnd(json: []const u8, start: usize) usize {
    var i = start + 1;
    while (i < json.len) {
        if (json[i] == '\\') {
            i += 2;
        } else if (json[i] == '"') {
            return i + 1;
        } else {
            i += 1;
        }
    }
    return json.len;
}

fn findMatchingBrace(json: []const u8, start: usize) usize {
    const open = json[start];
    const close: u8 = if (open == '{') '}' else ']';
    var depth: usize = 0;
    var i = start;
    var in_str = false;
    while (i < json.len) {
        if (json[i] == '\\' and in_str) {
            i += 2;
            continue;
        }
        if (json[i] == '"') in_str = !in_str;
        if (!in_str) {
            if (json[i] == open) depth += 1;
            if (json[i] == close) {
                depth -= 1;
                if (depth == 0) return i + 1;
            }
        }
        i += 1;
    }
    return json.len;
}

// ============================================
// SujiCore (크로스 호출 + 이벤트)
// ============================================

pub const ExternSujiCore = extern struct {
    invoke_fn: ?*const fn ([*c]const u8, [*c]const u8) callconv(.c) [*c]const u8,
    free_fn: ?*const fn ([*c]const u8) callconv(.c) void,
    emit: ?*const fn ([*c]const u8, [*c]const u8) callconv(.c) void,
    on_fn: ?*const fn ([*c]const u8, ?*const fn ([*c]const u8, [*c]const u8, ?*anyopaque) callconv(.c) void, ?*anyopaque) callconv(.c) u64,
    off_fn: ?*const fn (u64) callconv(.c) void,
    register_fn: ?*const fn ([*c]const u8) callconv(.c) void,
    /// 메인 프로세스의 std.Io 포인터 getter (Zig plugin 전용).
    get_io: ?*const fn () callconv(.c) ?*const anyopaque,
    /// 앱 종료 요청.
    quit_fn: ?*const fn () callconv(.c) void = null,
    /// 플랫폼 이름 — "macos" | "linux" | "windows" | "other".
    platform_fn: ?*const fn () callconv(.c) [*:0]const u8 = null,
    /// 특정 창에만 이벤트 전달 (Electron `webContents.send`). 없으면 sendTo는 no-op.
    emit_to_fn: ?*const fn (u32, [*c]const u8, [*c]const u8) callconv(.c) void = null,
};

var _global_core: ?*const ExternSujiCore = null;

/// 테스트 전용 core 주입 hook. 프로덕션 경로는 `exportApp` → `backend_init`.
pub fn setGlobalCore(core: ?*const ExternSujiCore) void {
    _global_core = core;
}

/// 앱 종료 요청 (Electron `app.quit()` 호환).
/// 백엔드가 `on("window:all-closed")` 등의 리스너에서 플랫폼/조건 판단 후 호출.
/// core가 주입 전이거나 SDK/core 버전 불일치로 quit_fn이 없으면 silent no-op.
pub fn quit() void {
    const core = _global_core orelse return;
    const fn_ptr = core.quit_fn orelse return;
    fn_ptr();
}

/// 플랫폼 문자열 상수. `suji.platform()` 반환값과 비교할 때 사용.
/// Suji는 macOS/Linux/Windows만 지원 — 다른 OS는 빌드 자체가 실패.
pub const PLATFORM_MACOS = "macos";
pub const PLATFORM_LINUX = "linux";
pub const PLATFORM_WINDOWS = "windows";

/// 현재 플랫폼 이름. Electron `process.platform` 대응 (단 Suji는 "darwin" 대신 "macos").
pub fn platform() []const u8 {
    const core = _global_core orelse return "unknown";
    const fn_ptr = core.platform_fn orelse return "unknown";
    return std.mem.span(fn_ptr());
}

/// Plugin 개발자 API — 메인 프로세스의 std.Io를 반환.
/// 이걸로 std.Io.Mutex/RwLock, std.Io.Dir, sleep 등을 호출.
/// 호출 전에 backend_init이 실행돼 있어야 함 (plugin init 이후 hot path 어디서든 OK).
pub fn io() std.Io {
    const core = _global_core orelse @panic("suji.io(): backend_init 미호출 상태");
    const get = core.get_io orelse @panic("suji.io(): core.get_io null (SDK/core 버전 불일치)");
    const raw = get() orelse @panic("suji.io(): BackendRegistry.global 미설정");
    const ptr: *const std.Io = @ptrCast(@alignCast(raw));
    return ptr.*;
}

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
            if (core) |c| {
                // 핸들러 등록 (채널 → 백엔드 라우팅)
                if (c.register_fn) |reg_fn| {
                    for (application.handlers[0..application.handler_count]) |h| {
                        var ch_buf: [util.MAX_CHANNEL_NAME]u8 = undefined;
                        reg_fn(util.nullTerminate(h.channel, &ch_buf).ptr);
                    }
                }
                // 이벤트 리스너 등록
                if (c.on_fn) |on_fn| {
                    for (application.listeners[0..application.listener_count]) |l| {
                        var ch_buf: [util.MAX_CHANNEL_NAME]u8 = undefined;
                        const handler_ptr: *const anyopaque = @ptrCast(l.func);
                        _ = on_fn(util.nullTerminate(l.channel, &ch_buf).ptr, App.eventBridgeCallback, @constCast(handler_ptr));
                    }
                }
            }
            std.debug.print("[{s}] ready\n", .{application.name});
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
            std.debug.print("[{s}] bye (suji SDK)\n", .{application.name});
        }
    };
}
