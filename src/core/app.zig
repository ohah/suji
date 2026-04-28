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
    /// `.schema(channel, Req, Res)`로 등록된 TypeScript 시그니처. SujiHandlers
    /// declaration emit에 사용. 등록은 optional — 미등록 핸들러는 frontend에서
    /// untyped (`unknown` 반환).
    handler_schemas: [MAX_HANDLERS]HandlerSchema = undefined,
    schema_count: usize = 0,
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

    /// `.schema(channel, Req, Res)`로 누적되는 TypeScript handler 시그니처.
    /// schema_ts는 comptime에 빌드된 `"channel: { req: <Req-ts>; res: <Res-ts> };"` 라인.
    pub const HandlerSchema = struct {
        channel: []const u8,
        schema_ts: []const u8,
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

    /// TypeScript 시그니처 등록 — frontend `@suji/api` SujiHandlers의 `channel`
    /// 항목으로 emit. `Req`/`Res`는 comptime type. void/bool/숫자/string([]const u8)/
    /// struct/optional/슬라이스/enum 매핑 지원.
    ///
    /// ```zig
    /// suji.app()
    ///     .handle("greet", greet)
    ///     .schema("greet", GreetReq, GreetRes)
    /// ```
    pub fn schema(
        comptime self: App,
        comptime channel: []const u8,
        comptime ReqType: type,
        comptime ResType: type,
    ) App {
        var new = self;
        new.handler_schemas[new.schema_count] = .{
            .channel = channel,
            .schema_ts = comptime buildSchemaTs(channel, ReqType, ResType),
        };
        new.schema_count += 1;
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
                const req = Request{ .raw = request_json, .arena = allocator };
                const resp = h.func(req, InvokeEvent.fromWire(request_json));
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

/// comptime — Zig 타입을 TypeScript 표현으로 변환. void/bool/숫자/string/struct/
/// optional/slice/enum 매핑 (1차). union/error/pointer-non-slice는 후속.
pub fn typeToTs(comptime T: type) []const u8 {
    const info = @typeInfo(T);
    return switch (info) {
        .void => "void",
        .bool => "boolean",
        .int, .comptime_int => "number",
        .float, .comptime_float => "number",
        .pointer => |p| blk: {
            if (p.size == .slice and p.child == u8) break :blk "string";
            if (p.size == .slice) break :blk (comptime typeToTs(p.child)) ++ "[]";
            @compileError("typeToTs: unsupported pointer kind " ++ @typeName(T));
        },
        .optional => |o| (comptime typeToTs(o.child)) ++ " | null",
        .@"struct" => |s| blk: {
            if (s.fields.len == 0) break :blk "Record<string, never>";
            comptime var out: []const u8 = "{ ";
            inline for (s.fields, 0..) |f, i| {
                const sep = if (i > 0) "; " else "";
                out = out ++ sep ++ f.name ++ ": " ++ comptime typeToTs(f.type);
            }
            break :blk out ++ " }";
        },
        .@"enum" => |e| blk: {
            if (e.fields.len == 0) break :blk "never";
            comptime var out: []const u8 = "";
            inline for (e.fields, 0..) |f, i| {
                const sep = if (i > 0) " | " else "";
                out = out ++ sep ++ "\"" ++ f.name ++ "\"";
            }
            break :blk out;
        },
        else => @compileError("typeToTs: unsupported type " ++ @typeName(T)),
    };
}

/// `App.schema(channel, Req, Res)` 빌더가 사용하는 1-line ts 시그니처 빌더.
pub fn buildSchemaTs(comptime channel: []const u8, comptime Req: type, comptime Res: type) []const u8 {
    return channel ++ ": { req: " ++ typeToTs(Req) ++ "; res: " ++ typeToTs(Res) ++ " };";
}

/// runtime — 등록된 모든 schema를 SujiHandlers declaration으로 emit.
/// caller가 dst slice에 결과 길이만큼 쓰고 byte 길이 반환. 부족하면 0.
pub fn emitSchemaTs(app_ptr: *const App, dst: []u8) usize {
    var w: std.Io.Writer = .fixed(dst);
    w.writeAll("// auto-generated — do not edit\ndeclare module '@suji/api' {\n  interface SujiHandlers {\n") catch return 0;
    for (app_ptr.handler_schemas[0..app_ptr.schema_count]) |s| {
        w.print("    {s}\n", .{s.schema_ts}) catch return 0;
    }
    w.writeAll("  }\n}\n") catch return 0;
    return w.end;
}

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
        /// sender frame이 페이지의 main frame인지 (false면 iframe 내부 호출).
        /// CEF cef_frame_t.is_main에서 파생. wire에서 주입 안 됐으면 null.
        is_main_frame: ?bool = null,
    };

    /// wire JSON에서 `__window` / `__window_name` / `__window_url` / `__window_main_frame`
    /// 4개 필드를 파싱해 InvokeEvent를 구성. `__window` 누락 시 id=0 (legacy/direct 경로).
    /// 음수 `__window`는 0으로 clamp (방어적).
    ///
    /// 핫경로 (매 IPC invoke마다 호출) — `__window`가 없으면 나머지 3개 필드도 없음을 보장.
    /// 코어가 주입할 때 항상 `__window`를 먼저 박기 때문. early-return으로 3회 indexOf 절약.
    pub fn fromWire(request_json: []const u8) InvokeEvent {
        const id_raw = util.extractJsonInt(request_json, "__window") orelse return .{ .window = .{ .id = 0 } };
        const id: u32 = if (id_raw >= 0) @intCast(id_raw) else 0;
        return .{ .window = .{
            .id = id,
            .name = util.extractJsonString(request_json, "__window_name"),
            .url = util.extractJsonString(request_json, "__window_url"),
            .is_main_frame = util.extractJsonBool(request_json, "__window_main_frame"),
        } };
    }
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

// ============================================
// windows API — 백엔드 SDK
//
// dlopen된 백엔드 dylib에서는 in-process WindowManager.global 접근이 불가하므로
// (각 모듈 인스턴스는 자기 BSS만 봄) 모든 호출이 `callBackend("__core__", ...)`로
// IPC를 거친다. Frontend `@suji/api`의 windows.* 와 같은 cmd JSON 형식.
//
// 응답은 `{from, cmd, windowId, ok, ...}` 형태 — caller가 std.json으로 파싱.
// ============================================

pub const windows = struct {
    pub const SetBoundsArgs = struct { x: i32 = 0, y: i32 = 0, width: u32 = 0, height: u32 = 0 };

    /// 새 창 생성. `opts_json`은 cmd 객체 안에 들어갈 필드 셋
    /// (예: `"title":"x","frame":false,"width":400`). caller가 JSON-safe 보장.
    /// 옵션 풀 셋은 documents/multi-window.mdx 참조. 단순 경우는 createSimple() 권장.
    pub fn create(opts_json: []const u8) ?[]const u8 {
        return coreCmd("create_window", opts_json);
    }

    /// 단축: title + url만 지정해 익명 창 생성.
    pub fn createSimple(title: []const u8, url: []const u8) ?[]const u8 {
        var t_buf: [256]u8 = undefined;
        var u_buf: [512]u8 = undefined;
        const t_n = util.escapeJsonStr(title, &t_buf) orelse return null;
        const u_n = util.escapeJsonStr(url, &u_buf) orelse return null;
        var opts_buf: [1024]u8 = undefined;
        const opts = std.fmt.bufPrint(&opts_buf, "\"title\":\"{s}\",\"url\":\"{s}\"", .{ t_buf[0..t_n], u_buf[0..u_n] }) catch return null;
        return create(opts);
    }

    pub fn loadURL(id: u32, url: []const u8) ?[]const u8 {
        var u_buf: [2048]u8 = undefined;
        const u_n = util.escapeJsonStr(url, &u_buf) orelse return null;
        var fields_buf: [2400]u8 = undefined;
        const fields = std.fmt.bufPrint(&fields_buf, "\"windowId\":{d},\"url\":\"{s}\"", .{ id, u_buf[0..u_n] }) catch return null;
        return coreCmd("load_url", fields);
    }

    pub fn reload(id: u32, ignore_cache: bool) ?[]const u8 {
        var fields_buf: [128]u8 = undefined;
        const fields = std.fmt.bufPrint(&fields_buf, "\"windowId\":{d},\"ignoreCache\":{}", .{ id, ignore_cache }) catch return null;
        return coreCmd("reload", fields);
    }

    /// 렌더러에 임의 JS 실행. fire-and-forget — 결과 회신 없음.
    /// 결과가 필요하면 JS에서 `suji.send(channel, value)`로 회신.
    /// `code` 가 4KB 미만이면 stack, 그 이상은 stderr warn 후 null. cef.zig executeJavascript와 동일
    /// 임계값 (스택 점유 일관성). 더 큰 코드가 정말 필요하면 caller가 분할 또는 바깥에서 alloc.
    pub fn executeJavaScript(id: u32, code: []const u8) ?[]const u8 {
        var c_buf: [JS_CODE_STACK_BUF]u8 = undefined;
        const c_n = util.escapeJsonStr(code, &c_buf) orelse {
            std.debug.print(
                "[suji] warning: executeJavaScript code too large ({d} bytes after escape > {d} stack buf) — dropped\n",
                .{ code.len, JS_CODE_STACK_BUF },
            );
            return null;
        };
        var fields_buf: [JS_CODE_STACK_BUF + 128]u8 = undefined;
        const fields = std.fmt.bufPrint(&fields_buf, "\"windowId\":{d},\"code\":\"{s}\"", .{ id, c_buf[0..c_n] }) catch return null;
        return coreCmd("execute_javascript", fields);
    }

    pub fn getURL(id: u32) ?[]const u8 {
        return windowIdCmd("get_url", id);
    }

    pub fn isLoading(id: u32) ?[]const u8 {
        return windowIdCmd("is_loading", id);
    }

    pub fn openDevTools(id: u32) ?[]const u8 {
        return windowIdCmd("open_dev_tools", id);
    }
    pub fn closeDevTools(id: u32) ?[]const u8 {
        return windowIdCmd("close_dev_tools", id);
    }
    pub fn isDevToolsOpened(id: u32) ?[]const u8 {
        return windowIdCmd("is_dev_tools_opened", id);
    }
    pub fn toggleDevTools(id: u32) ?[]const u8 {
        return windowIdCmd("toggle_dev_tools", id);
    }

    pub fn setZoomLevel(id: u32, level: f64) ?[]const u8 {
        var fields_buf: [128]u8 = undefined;
        const fields = std.fmt.bufPrint(&fields_buf, "\"windowId\":{d},\"level\":{d}", .{ id, level }) catch return null;
        return coreCmd("set_zoom_level", fields);
    }
    pub fn getZoomLevel(id: u32) ?[]const u8 {
        return windowIdCmd("get_zoom_level", id);
    }
    pub fn setZoomFactor(id: u32, factor: f64) ?[]const u8 {
        var fields_buf: [128]u8 = undefined;
        const fields = std.fmt.bufPrint(&fields_buf, "\"windowId\":{d},\"factor\":{d}", .{ id, factor }) catch return null;
        return coreCmd("set_zoom_factor", fields);
    }
    pub fn getZoomFactor(id: u32) ?[]const u8 {
        return windowIdCmd("get_zoom_factor", id);
    }

    // Phase 4-E: 편집 (windowId만) + 검색
    pub fn undo(id: u32) ?[]const u8 {
        return windowIdCmd("undo", id);
    }
    pub fn redo(id: u32) ?[]const u8 {
        return windowIdCmd("redo", id);
    }
    pub fn cut(id: u32) ?[]const u8 {
        return windowIdCmd("cut", id);
    }
    pub fn copy(id: u32) ?[]const u8 {
        return windowIdCmd("copy", id);
    }
    pub fn paste(id: u32) ?[]const u8 {
        return windowIdCmd("paste", id);
    }
    pub fn selectAll(id: u32) ?[]const u8 {
        return windowIdCmd("select_all", id);
    }

    pub const FindOptions = struct {
        forward: bool = true,
        match_case: bool = false,
        find_next: bool = false,
    };

    pub fn findInPage(id: u32, text: []const u8, opts: FindOptions) ?[]const u8 {
        var t_buf: [1024]u8 = undefined;
        const t_n = util.escapeJsonStr(text, &t_buf) orelse return null;
        var fields_buf: [1280]u8 = undefined;
        const fields = std.fmt.bufPrint(&fields_buf, "\"windowId\":{d},\"text\":\"{s}\",\"forward\":{},\"matchCase\":{},\"findNext\":{}", .{
            id, t_buf[0..t_n], opts.forward, opts.match_case, opts.find_next,
        }) catch return null;
        return coreCmd("find_in_page", fields);
    }

    pub fn stopFindInPage(id: u32, clear_selection: bool) ?[]const u8 {
        var fields_buf: [128]u8 = undefined;
        const fields = std.fmt.bufPrint(&fields_buf, "\"windowId\":{d},\"clearSelection\":{}", .{ id, clear_selection }) catch return null;
        return coreCmd("stop_find_in_page", fields);
    }

    /// PDF 인쇄 요청. CEF가 콜백 기반 async라 코어는 즉시 ok 응답하고
    /// 완료는 `window:pdf-print-finished` 이벤트(`{path, success}`)로 발화.
    /// caller가 `suji.app().on("window:pdf-print-finished", ...)`로 listen.
    pub fn printToPDF(id: u32, path: []const u8) ?[]const u8 {
        var p_buf: [2048]u8 = undefined;
        const p_n = util.escapeJsonStr(path, &p_buf) orelse return null;
        var fields_buf: [2400]u8 = undefined;
        const fields = std.fmt.bufPrint(&fields_buf, "\"windowId\":{d},\"path\":\"{s}\"", .{ id, p_buf[0..p_n] }) catch return null;
        return coreCmd("print_to_pdf", fields);
    }

    /// `windowId`만 들어가는 단순 cmd 헬퍼 — getURL/isLoading/openDevTools/... 공통.
    fn windowIdCmd(cmd: []const u8, id: u32) ?[]const u8 {
        var fields_buf: [64]u8 = undefined;
        const fields = std.fmt.bufPrint(&fields_buf, "\"windowId\":{d}", .{id}) catch return null;
        return coreCmd(cmd, fields);
    }

    pub fn setTitle(id: u32, title: []const u8) ?[]const u8 {
        var t_buf: [512]u8 = undefined;
        const t_n = util.escapeJsonStr(title, &t_buf) orelse return null;
        var fields_buf: [640]u8 = undefined;
        const fields = std.fmt.bufPrint(&fields_buf, "\"windowId\":{d},\"title\":\"{s}\"", .{ id, t_buf[0..t_n] }) catch return null;
        return coreCmd("set_title", fields);
    }

    pub fn setBounds(id: u32, bounds: SetBoundsArgs) ?[]const u8 {
        var fields_buf: [256]u8 = undefined;
        const fields = std.fmt.bufPrint(
            &fields_buf,
            "\"windowId\":{d},\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d}",
            .{ id, bounds.x, bounds.y, bounds.width, bounds.height },
        ) catch return null;
        return coreCmd("set_bounds", fields);
    }

    /// JS code escape용 stack 버퍼 — cef.zig executeJavascript와 동일 임계값.
    const JS_CODE_STACK_BUF: usize = 4096;
};

/// internal: cmd + payload fields → "__core__" 채널로 invoke. windows/clipboard/shell/dialog
/// 네 namespace 공통.
fn coreCmd(cmd: []const u8, fields_json: []const u8) ?[]const u8 {
    var buf: [util.MAX_REQUEST]u8 = undefined;
    const sep: []const u8 = if (fields_json.len > 0) "," else "";
    const req = std.fmt.bufPrint(&buf, "{{\"cmd\":\"{s}\"{s}{s}}}", .{ cmd, sep, fields_json }) catch return null;
    return callBackend("__core__", req);
}

// ============================================
// Clipboard / Shell / Dialog — frontend `@suji/api`와 동일 cmd 사용.
// 응답은 raw JSON string — caller가 std.json으로 파싱.
// ============================================

pub const clipboard = struct {
    /// 시스템 클립보드 plain text 읽기. 응답: `{"from","cmd","text":"..."}`.
    pub fn readText() ?[]const u8 {
        return coreCmd("clipboard_read_text", "");
    }

    /// 시스템 클립보드 plain text 쓰기. 응답: `{"from","cmd","success":bool}`.
    pub fn writeText(text: []const u8) ?[]const u8 {
        var t_buf: [16384]u8 = undefined;
        const t_n = util.escapeJsonStrFull(text, &t_buf) orelse return null;
        var fields_buf: [16400]u8 = undefined;
        const fields = std.fmt.bufPrint(&fields_buf, "\"text\":\"{s}\"", .{t_buf[0..t_n]}) catch return null;
        return coreCmd("clipboard_write_text", fields);
    }

    pub fn clear() ?[]const u8 {
        return coreCmd("clipboard_clear", "");
    }

    /// HTML 읽기. 응답: `{"html":"..."}`.
    pub fn readHtml() ?[]const u8 {
        return coreCmd("clipboard_read_html", "");
    }

    /// HTML 쓰기. 응답: `{"success":bool}`.
    pub fn writeHtml(html: []const u8) ?[]const u8 {
        var t_buf: [16384]u8 = undefined;
        const t_n = util.escapeJsonStrFull(html, &t_buf) orelse return null;
        var fields_buf: [16400]u8 = undefined;
        const fields = std.fmt.bufPrint(&fields_buf, "\"html\":\"{s}\"", .{t_buf[0..t_n]}) catch return null;
        return coreCmd("clipboard_write_html", fields);
    }

    /// format(UTI)이 클립보드에 있는지. 응답: `{"present":bool}`.
    pub fn has(format: []const u8) ?[]const u8 {
        var f_buf: [256]u8 = undefined;
        const f_n = util.escapeJsonStrFull(format, &f_buf) orelse return null;
        var fields_buf: [320]u8 = undefined;
        const fields = std.fmt.bufPrint(&fields_buf, "\"format\":\"{s}\"", .{f_buf[0..f_n]}) catch return null;
        return coreCmd("clipboard_has", fields);
    }

    /// 클립보드 등록된 format 배열. 응답: `{"formats":[...]}`.
    pub fn availableFormats() ?[]const u8 {
        return coreCmd("clipboard_available_formats", "");
    }
};

pub const powerMonitor = struct {
    /// 시스템 유휴 시간 (초). 응답: `{"seconds":f64}`.
    pub fn getSystemIdleTime() ?[]const u8 {
        return coreCmd("power_monitor_get_idle_time", "");
    }
};

pub const shell = struct {
    /// 시스템 기본 핸들러로 URL 열기. 응답: `{"from","cmd","success":bool}`.
    pub fn openExternal(url: []const u8) ?[]const u8 {
        var u_buf: [4096]u8 = undefined;
        const u_n = util.escapeJsonStrFull(url, &u_buf) orelse return null;
        var fields_buf: [4200]u8 = undefined;
        const fields = std.fmt.bufPrint(&fields_buf, "\"url\":\"{s}\"", .{u_buf[0..u_n]}) catch return null;
        return coreCmd("shell_open_external", fields);
    }

    pub fn showItemInFolder(path: []const u8) ?[]const u8 {
        var p_buf: [4096]u8 = undefined;
        const p_n = util.escapeJsonStrFull(path, &p_buf) orelse return null;
        var fields_buf: [4200]u8 = undefined;
        const fields = std.fmt.bufPrint(&fields_buf, "\"path\":\"{s}\"", .{p_buf[0..p_n]}) catch return null;
        return coreCmd("shell_show_item_in_folder", fields);
    }

    pub fn beep() ?[]const u8 {
        return coreCmd("shell_beep", "");
    }

    /// 휴지통으로 이동. 응답: `{"success":bool}`.
    pub fn trashItem(path: []const u8) ?[]const u8 {
        var p_buf: [4096]u8 = undefined;
        const p_n = util.escapeJsonStrFull(path, &p_buf) orelse return null;
        var fields_buf: [4200]u8 = undefined;
        const fields = std.fmt.bufPrint(&fields_buf, "\"path\":\"{s}\"", .{p_buf[0..p_n]}) catch return null;
        return coreCmd("shell_trash_item", fields);
    }

    /// 로컬 파일/폴더를 기본 앱으로 열기. 응답: `{"success":bool}`.
    pub fn openPath(path: []const u8) ?[]const u8 {
        var p_buf: [4096]u8 = undefined;
        const p_n = util.escapeJsonStrFull(path, &p_buf) orelse return null;
        var fields_buf: [4200]u8 = undefined;
        const fields = std.fmt.bufPrint(&fields_buf, "\"path\":\"{s}\"", .{p_buf[0..p_n]}) catch return null;
        return coreCmd("shell_open_path", fields);
    }
};

pub const nativeTheme = struct {
    /// 시스템 다크 모드 여부. 응답: `{"dark":bool}`.
    pub fn shouldUseDarkColors() ?[]const u8 {
        return coreCmd("native_theme_should_use_dark_colors", "");
    }
};

pub const fs = struct {
    pub fn readFile(path: []const u8) ?[]const u8 {
        var p_buf: [4096]u8 = undefined;
        const p_n = util.escapeJsonStrFull(path, &p_buf) orelse return null;
        var fields_buf: [4200]u8 = undefined;
        const fields = std.fmt.bufPrint(&fields_buf, "\"path\":\"{s}\"", .{p_buf[0..p_n]}) catch return null;
        return coreCmd("fs_read_file", fields);
    }

    pub fn writeFile(path: []const u8, text: []const u8) ?[]const u8 {
        var p_buf: [4096]u8 = undefined;
        var t_buf: [8192]u8 = undefined;
        const p_n = util.escapeJsonStrFull(path, &p_buf) orelse return null;
        const t_n = util.escapeJsonStrFull(text, &t_buf) orelse return null;
        var fields_buf: [12500]u8 = undefined;
        const fields = std.fmt.bufPrint(&fields_buf, "\"path\":\"{s}\",\"text\":\"{s}\"", .{ p_buf[0..p_n], t_buf[0..t_n] }) catch return null;
        return coreCmd("fs_write_file", fields);
    }

    pub fn stat(path: []const u8) ?[]const u8 {
        var p_buf: [4096]u8 = undefined;
        const p_n = util.escapeJsonStrFull(path, &p_buf) orelse return null;
        var fields_buf: [4200]u8 = undefined;
        const fields = std.fmt.bufPrint(&fields_buf, "\"path\":\"{s}\"", .{p_buf[0..p_n]}) catch return null;
        return coreCmd("fs_stat", fields);
    }

    pub fn mkdir(path: []const u8, recursive: bool) ?[]const u8 {
        var p_buf: [4096]u8 = undefined;
        const p_n = util.escapeJsonStrFull(path, &p_buf) orelse return null;
        var fields_buf: [4300]u8 = undefined;
        const fields = std.fmt.bufPrint(&fields_buf, "\"path\":\"{s}\",\"recursive\":{}", .{ p_buf[0..p_n], recursive }) catch return null;
        return coreCmd("fs_mkdir", fields);
    }

    pub fn readdir(path: []const u8) ?[]const u8 {
        var p_buf: [4096]u8 = undefined;
        const p_n = util.escapeJsonStrFull(path, &p_buf) orelse return null;
        var fields_buf: [4200]u8 = undefined;
        const fields = std.fmt.bufPrint(&fields_buf, "\"path\":\"{s}\"", .{p_buf[0..p_n]}) catch return null;
        return coreCmd("fs_readdir", fields);
    }

    /// `recursive=true`이면 디렉토리도 트리 삭제. `force=true`이면 not-exist를 성공으로 처리
    /// (Node `fs.rm({recursive,force})` 호환).
    pub fn rm(path: []const u8, recursive: bool, force: bool) ?[]const u8 {
        var p_buf: [4096]u8 = undefined;
        const p_n = util.escapeJsonStrFull(path, &p_buf) orelse return null;
        var fields_buf: [4400]u8 = undefined;
        const fields = std.fmt.bufPrint(&fields_buf, "\"path\":\"{s}\",\"recursive\":{},\"force\":{}", .{ p_buf[0..p_n], recursive, force }) catch return null;
        return coreCmd("fs_rm", fields);
    }

    pub const FileType = enum { file, directory, symlink, other };
    pub const Stat = struct {
        type: FileType,
        size: u64,
        mtime_ms: i64,
    };

    /// `stat`의 typed wrapper. raw JSON 응답을 파싱해 Stat 구조체 반환.
    /// 실패 시 null (path 거부 / not_found / sandbox forbidden 등).
    pub fn statTyped(path: []const u8) ?Stat {
        const raw = stat(path) orelse return null;
        if (!(util.extractJsonBool(raw, "success") orelse false)) return null;
        const type_str = util.extractJsonString(raw, "type") orelse return null;
        const size = util.extractJsonInt(raw, "size") orelse return null;
        const mtime = util.extractJsonInt(raw, "mtime") orelse return null;
        const t: FileType = if (std.mem.eql(u8, type_str, "file")) .file
            else if (std.mem.eql(u8, type_str, "directory")) .directory
            else if (std.mem.eql(u8, type_str, "symlink")) .symlink
            else .other;
        return .{ .type = t, .size = @intCast(size), .mtime_ms = mtime };
    }

    /// `readdir` typed wrapper. raw JSON entries 배열을 caller-supplied buffer에 파싱.
    /// 반환: 채운 entry 수 (실패 시 null). 배열 element name은 raw JSON 슬라이스 참조라
    /// raw 응답 lifetime 안에서만 유효.
    /// 호출 패턴: const raw = fs.readdir(p); const entries = fs.parseEntries(raw, &buf);
    pub fn parseEntries(raw_response: []const u8, out: []DirEntry) ?usize {
        if (!(util.extractJsonBool(raw_response, "success") orelse false)) return null;
        const entries_start = std.mem.indexOf(u8, raw_response, "\"entries\":[") orelse return 0;
        var pos = entries_start + "\"entries\":[".len;
        var count: usize = 0;
        while (count < out.len and pos < raw_response.len) {
            // skip whitespace
            while (pos < raw_response.len and (raw_response[pos] == ',' or raw_response[pos] == ' ')) pos += 1;
            if (pos >= raw_response.len or raw_response[pos] == ']') break;
            // entry는 {"name":"...","type":"..."}
            const obj_end = std.mem.indexOfScalarPos(u8, raw_response, pos, '}') orelse break;
            const obj = raw_response[pos .. obj_end + 1];
            const name = util.extractJsonString(obj, "name") orelse break;
            const type_str = util.extractJsonString(obj, "type") orelse "other";
            const t: FileType = if (std.mem.eql(u8, type_str, "file")) .file
                else if (std.mem.eql(u8, type_str, "directory")) .directory
                else if (std.mem.eql(u8, type_str, "symlink")) .symlink
                else .other;
            out[count] = .{ .name = name, .type = t };
            count += 1;
            pos = obj_end + 1;
        }
        return count;
    }

    pub const DirEntry = struct {
        name: []const u8,
        type: FileType,
    };
};

pub const notification = struct {
    /// 플랫폼 지원 여부 — `{"supported":bool}` 응답.
    pub fn isSupported() ?[]const u8 {
        return coreCmd("notification_is_supported", "");
    }

    /// 권한 요청 — `{"granted":bool}` 응답. 첫 호출 시 OS 다이얼로그.
    pub fn requestPermission() ?[]const u8 {
        return coreCmd("notification_request_permission", "");
    }

    /// 알림 표시 — `{"notificationId":"...","success":bool}` 응답.
    pub fn show(title: []const u8, body: []const u8, silent: bool) ?[]const u8 {
        var t_buf: [4096]u8 = undefined;
        var b_buf: [4096]u8 = undefined;
        const t_n = util.escapeJsonStrFull(title, &t_buf) orelse return null;
        const b_n = util.escapeJsonStrFull(body, &b_buf) orelse return null;
        var fields_buf: [9000]u8 = undefined;
        const fields = std.fmt.bufPrint(
            &fields_buf,
            "\"title\":\"{s}\",\"body\":\"{s}\",\"silent\":{}",
            .{ t_buf[0..t_n], b_buf[0..b_n], silent },
        ) catch return null;
        return coreCmd("notification_show", fields);
    }

    pub fn close(notification_id: []const u8) ?[]const u8 {
        var id_buf: [128]u8 = undefined;
        const id_n = util.escapeJsonStrFull(notification_id, &id_buf) orelse return null;
        var fields_buf: [256]u8 = undefined;
        const fields = std.fmt.bufPrint(&fields_buf, "\"notificationId\":\"{s}\"", .{id_buf[0..id_n]}) catch return null;
        return coreCmd("notification_close", fields);
    }
};

pub const tray = struct {
    /// 트레이 생성. 응답: `{"from","cmd","trayId":N}`. trayId=0이면 실패 (비-macOS 등).
    /// title/tooltip은 빈 문자열이면 미설정.
    pub fn create(title: []const u8, tooltip: []const u8) ?[]const u8 {
        var t_buf: [512]u8 = undefined;
        var tt_buf: [1024]u8 = undefined;
        const t_n = util.escapeJsonStrFull(title, &t_buf) orelse return null;
        const tt_n = util.escapeJsonStrFull(tooltip, &tt_buf) orelse return null;
        var fields_buf: [2048]u8 = undefined;
        const fields = std.fmt.bufPrint(&fields_buf, "\"title\":\"{s}\",\"tooltip\":\"{s}\"", .{ t_buf[0..t_n], tt_buf[0..tt_n] }) catch return null;
        return coreCmd("tray_create", fields);
    }

    pub fn setTitle(tray_id: u32, title: []const u8) ?[]const u8 {
        var t_buf: [512]u8 = undefined;
        const t_n = util.escapeJsonStrFull(title, &t_buf) orelse return null;
        var fields_buf: [640]u8 = undefined;
        const fields = std.fmt.bufPrint(&fields_buf, "\"trayId\":{d},\"title\":\"{s}\"", .{ tray_id, t_buf[0..t_n] }) catch return null;
        return coreCmd("tray_set_title", fields);
    }

    pub fn setTooltip(tray_id: u32, tooltip: []const u8) ?[]const u8 {
        var t_buf: [1024]u8 = undefined;
        const t_n = util.escapeJsonStrFull(tooltip, &t_buf) orelse return null;
        var fields_buf: [1200]u8 = undefined;
        const fields = std.fmt.bufPrint(&fields_buf, "\"trayId\":{d},\"tooltip\":\"{s}\"", .{ tray_id, t_buf[0..t_n] }) catch return null;
        return coreCmd("tray_set_tooltip", fields);
    }

    /// 메뉴 설정 — items_json은 cmd 객체에 들어갈 raw JSON `"items":[...]`. caller가 빌드.
    /// 예: `\"items\":[{\"label\":\"Settings\",\"click\":\"open-settings\"},{\"type\":\"separator\"}]`.
    pub fn setMenuRaw(tray_id: u32, items_json: []const u8) ?[]const u8 {
        var fields_buf: [8192]u8 = undefined;
        const fields = std.fmt.bufPrint(&fields_buf, "\"trayId\":{d},{s}", .{ tray_id, items_json }) catch return null;
        return coreCmd("tray_set_menu", fields);
    }

    pub fn destroy(tray_id: u32) ?[]const u8 {
        var fields_buf: [64]u8 = undefined;
        const fields = std.fmt.bufPrint(&fields_buf, "\"trayId\":{d}", .{tray_id}) catch return null;
        return coreCmd("tray_destroy", fields);
    }
};

pub const menu = struct {
    /// 애플리케이션 메뉴 설정 — items_json은 cmd 객체에 들어갈 raw JSON `"items":[...]`.
    /// 클릭은 EventBus의 `menu:click {"click":"..."}` 로 수신.
    pub fn setApplicationMenuRaw(items_json: []const u8) ?[]const u8 {
        return coreCmd("menu_set_application_menu", items_json);
    }

    /// Suji 기본 App/File/Edit/View/Window/Help 메뉴로 복원.
    pub fn resetApplicationMenu() ?[]const u8 {
        return coreCmd("menu_reset_application_menu", "");
    }
};

/// macOS Carbon Hot Key 기반 (Electron `globalShortcut.*`). accelerator 파싱:
/// `"Cmd+Shift+K"`, `"CommandOrControl+P"`, `"Alt+F4"` 등. 트리거 시 EventBus의
/// `globalShortcut:trigger {accelerator, click}`로 수신.
pub const globalShortcut = struct {
    // escape는 worst-case 6배 expansion (`\u00xx`) 가능 → 128 input → 768 escape buffer.
    // fields_buf는 두 escape (1536) + JSON wire 텍스트 + 마진.
    pub fn register(accelerator: []const u8, click: []const u8) ?[]const u8 {
        var a_buf: [768]u8 = undefined;
        var c_buf: [768]u8 = undefined;
        const a_n = util.escapeJsonStrFull(accelerator, &a_buf) orelse return null;
        const c_n = util.escapeJsonStrFull(click, &c_buf) orelse return null;
        var fields_buf: [1664]u8 = undefined;
        const fields = std.fmt.bufPrint(&fields_buf, "\"accelerator\":\"{s}\",\"click\":\"{s}\"", .{ a_buf[0..a_n], c_buf[0..c_n] }) catch return null;
        return coreCmd("global_shortcut_register", fields);
    }

    pub fn unregister(accelerator: []const u8) ?[]const u8 {
        var a_buf: [768]u8 = undefined;
        const a_n = util.escapeJsonStrFull(accelerator, &a_buf) orelse return null;
        var fields_buf: [832]u8 = undefined;
        const fields = std.fmt.bufPrint(&fields_buf, "\"accelerator\":\"{s}\"", .{a_buf[0..a_n]}) catch return null;
        return coreCmd("global_shortcut_unregister", fields);
    }

    pub fn unregisterAll() ?[]const u8 {
        return coreCmd("global_shortcut_unregister_all", "");
    }

    pub fn isRegistered(accelerator: []const u8) ?[]const u8 {
        var a_buf: [768]u8 = undefined;
        const a_n = util.escapeJsonStrFull(accelerator, &a_buf) orelse return null;
        var fields_buf: [832]u8 = undefined;
        const fields = std.fmt.bufPrint(&fields_buf, "\"accelerator\":\"{s}\"", .{a_buf[0..a_n]}) catch return null;
        return coreCmd("global_shortcut_is_registered", fields);
    }
};

pub const dialog = struct {
    /// 메시지 박스 — pre-built JSON fields(buttons 배열 등) 직접 전달.
    /// 응답: `{"from","cmd","response":N,"checkboxChecked":bool}`.
    /// 단순 버전은 messageBoxSimple 사용.
    pub fn showMessageBox(fields_json: []const u8) ?[]const u8 {
        return coreCmd("dialog_show_message_box", fields_json);
    }

    /// 단축: type/message + 버튼 배열만 받아 자동으로 fields_json 빌드.
    /// type: "none"/"info"/"warning"/"error"/"question". buttons는 NS-1 개 stack-alloc 안전.
    pub fn messageBoxSimple(msg_type: []const u8, message: []const u8, buttons: []const []const u8) ?[]const u8 {
        var t_buf: [32]u8 = undefined;
        var m_buf: [4096]u8 = undefined;
        const t_n = util.escapeJsonStrFull(msg_type, &t_buf) orelse return null;
        const m_n = util.escapeJsonStrFull(message, &m_buf) orelse return null;
        var fields_buf: [8192]u8 = undefined;
        var w: usize = 0;
        const head = std.fmt.bufPrint(fields_buf[w..], "\"type\":\"{s}\",\"message\":\"{s}\",\"buttons\":[", .{ t_buf[0..t_n], m_buf[0..m_n] }) catch return null;
        w += head.len;
        var b_buf: [256]u8 = undefined;
        for (buttons, 0..) |btn, i| {
            const b_n = util.escapeJsonStrFull(btn, &b_buf) orelse return null;
            const sep: []const u8 = if (i == 0) "\"" else ",\"";
            const part = std.fmt.bufPrint(fields_buf[w..], "{s}{s}\"", .{ sep, b_buf[0..b_n] }) catch return null;
            w += part.len;
        }
        const tail = std.fmt.bufPrint(fields_buf[w..], "]", .{}) catch return null;
        w += tail.len;
        return showMessageBox(fields_buf[0..w]);
    }

    pub fn showErrorBox(title: []const u8, content: []const u8) ?[]const u8 {
        var t_buf: [512]u8 = undefined;
        var c_buf: [4096]u8 = undefined;
        const t_n = util.escapeJsonStrFull(title, &t_buf) orelse return null;
        const c_n = util.escapeJsonStrFull(content, &c_buf) orelse return null;
        var fields_buf: [4800]u8 = undefined;
        const fields = std.fmt.bufPrint(&fields_buf, "\"title\":\"{s}\",\"content\":\"{s}\"", .{ t_buf[0..t_n], c_buf[0..c_n] }) catch return null;
        return coreCmd("dialog_show_error_box", fields);
    }

    /// 파일 열기 dialog — pre-built fields. 응답: `{"from","cmd","canceled":bool,"filePaths":[...]}`.
    pub fn showOpenDialog(fields_json: []const u8) ?[]const u8 {
        return coreCmd("dialog_show_open_dialog", fields_json);
    }

    /// 파일 저장 dialog — pre-built fields. 응답: `{"from","cmd","canceled":bool,"filePath":"..."}`.
    pub fn showSaveDialog(fields_json: []const u8) ?[]const u8 {
        return coreCmd("dialog_show_save_dialog", fields_json);
    }
};

// ============================================
// screen / powerSaveBlocker / safeStorage / app — frontend `@suji/api`와 동일 cmd.
// ============================================

pub const screen = struct {
    /// 모든 모니터 정보. 응답: `{"from","cmd","displays":[{...}]}`.
    pub fn getAllDisplays() ?[]const u8 {
        return coreCmd("screen_get_all_displays", "");
    }

    /// 마우스 포인터 화면 좌표 (NSEvent.mouseLocation, bottom-up). 응답: `{"x":..,"y":..}`.
    pub fn getCursorScreenPoint() ?[]const u8 {
        return coreCmd("screen_get_cursor_point", "");
    }

    /// (x,y)에 가장 가까운 display index. 어느 display에도 contained 안 되면 -1.
    pub fn getDisplayNearestPoint(x: f64, y: f64) ?[]const u8 {
        var fields_buf: [128]u8 = undefined;
        const fields = std.fmt.bufPrint(&fields_buf, "\"x\":{d},\"y\":{d}", .{ x, y }) catch return null;
        return coreCmd("screen_get_display_nearest_point", fields);
    }
};

pub const powerSaveBlocker = struct {
    /// `"prevent_app_suspension"` 또는 `"prevent_display_sleep"`. 응답: `{"id":N}` (0이면 실패).
    pub fn start(t: []const u8) ?[]const u8 {
        var t_buf: [64]u8 = undefined;
        const t_n = util.escapeJsonStrFull(t, &t_buf) orelse return null;
        var fields_buf: [128]u8 = undefined;
        const fields = std.fmt.bufPrint(&fields_buf, "\"type\":\"{s}\"", .{t_buf[0..t_n]}) catch return null;
        return coreCmd("power_save_blocker_start", fields);
    }

    /// 응답: `{"success":bool}`.
    pub fn stop(id: u32) ?[]const u8 {
        var fields_buf: [32]u8 = undefined;
        const fields = std.fmt.bufPrint(&fields_buf, "\"id\":{d}", .{id}) catch return null;
        return coreCmd("power_save_blocker_stop", fields);
    }
};

pub const safeStorage = struct {
    /// service+account에 utf-8 value 저장. 응답: `{"success":bool}`.
    pub fn setItem(service: []const u8, account: []const u8, value: []const u8) ?[]const u8 {
        var s_buf: [256]u8 = undefined;
        var a_buf: [256]u8 = undefined;
        var v_buf: [4096]u8 = undefined;
        const s_n = util.escapeJsonStrFull(service, &s_buf) orelse return null;
        const a_n = util.escapeJsonStrFull(account, &a_buf) orelse return null;
        const v_n = util.escapeJsonStrFull(value, &v_buf) orelse return null;
        var fields_buf: [4800]u8 = undefined;
        const fields = std.fmt.bufPrint(
            &fields_buf,
            "\"service\":\"{s}\",\"account\":\"{s}\",\"value\":\"{s}\"",
            .{ s_buf[0..s_n], a_buf[0..a_n], v_buf[0..v_n] },
        ) catch return null;
        return coreCmd("safe_storage_set", fields);
    }

    /// 응답: `{"value":"..."}` (없으면 빈 문자열).
    pub fn getItem(service: []const u8, account: []const u8) ?[]const u8 {
        var s_buf: [256]u8 = undefined;
        var a_buf: [256]u8 = undefined;
        const s_n = util.escapeJsonStrFull(service, &s_buf) orelse return null;
        const a_n = util.escapeJsonStrFull(account, &a_buf) orelse return null;
        var fields_buf: [600]u8 = undefined;
        const fields = std.fmt.bufPrint(
            &fields_buf,
            "\"service\":\"{s}\",\"account\":\"{s}\"",
            .{ s_buf[0..s_n], a_buf[0..a_n] },
        ) catch return null;
        return coreCmd("safe_storage_get", fields);
    }

    /// 응답: `{"success":bool}` (없는 키도 idempotent true).
    pub fn deleteItem(service: []const u8, account: []const u8) ?[]const u8 {
        var s_buf: [256]u8 = undefined;
        var a_buf: [256]u8 = undefined;
        const s_n = util.escapeJsonStrFull(service, &s_buf) orelse return null;
        const a_n = util.escapeJsonStrFull(account, &a_buf) orelse return null;
        var fields_buf: [600]u8 = undefined;
        const fields = std.fmt.bufPrint(
            &fields_buf,
            "\"service\":\"{s}\",\"account\":\"{s}\"",
            .{ s_buf[0..s_n], a_buf[0..a_n] },
        ) catch return null;
        return coreCmd("safe_storage_delete", fields);
    }
};

// app() 함수와 이름 충돌 방지를 위해 dock/attention을 top-level namespace로 분리.
pub const dock = struct {
    /// dock 배지 텍스트 (빈 문자열 = 제거). 응답: `{"success":bool}`.
    pub fn setBadge(text: []const u8) ?[]const u8 {
        var t_buf: [256]u8 = undefined;
        const t_n = util.escapeJsonStrFull(text, &t_buf) orelse return null;
        var fields_buf: [320]u8 = undefined;
        const fields = std.fmt.bufPrint(&fields_buf, "\"text\":\"{s}\"", .{t_buf[0..t_n]}) catch return null;
        return coreCmd("dock_set_badge", fields);
    }

    /// 응답: `{"text":"..."}`.
    pub fn getBadge() ?[]const u8 {
        return coreCmd("dock_get_badge", "");
    }
};

// ============================================
// webRequest — URL glob blocklist (Electron `session.webRequest`).
// ============================================
// frontend `@suji/api`와 동일 cmd. raw JSON 응답 — caller가 std.json으로 파싱.

pub const webRequest = struct {
    /// patterns는 glob 패턴 (`*` wildcard). 응답: `{"count":N}` (등록된 개수).
    /// 최대 32개 / 256자per. 빈 list로 호출하면 모든 패턴 제거.
    pub fn setBlockedUrls(patterns: []const []const u8) ?[]const u8 {
        return setUrlPatternsCmd("web_request_set_blocked_urls", patterns);
    }

    /// dynamic listener filter — 매칭 요청은 RV_CONTINUE_ASYNC + `webRequest:will-request`
    /// 이벤트. consumer가 resolve(id, cancel) 호출 전까지 hold.
    pub fn setListenerFilter(patterns: []const []const u8) ?[]const u8 {
        return setUrlPatternsCmd("web_request_set_listener_filter", patterns);
    }

    /// pending 요청 결정 (Electron callback). cancel=true면 차단, false면 통과.
    pub fn resolve(id: u64, cancel_request: bool) ?[]const u8 {
        var fields_buf: [64]u8 = undefined;
        const fields = std.fmt.bufPrint(&fields_buf, "\"id\":{d},\"cancel\":{}", .{ id, cancel_request }) catch return null;
        return coreCmd("web_request_resolve", fields);
    }

    fn setUrlPatternsCmd(cmd: []const u8, patterns: []const []const u8) ?[]const u8 {
        var fields_buf: [8192]u8 = undefined;
        var w: std.Io.Writer = .fixed(&fields_buf);
        w.writeAll("\"patterns\":[") catch return null;
        for (patterns, 0..) |p, i| {
            if (i > 0) w.writeAll(",") catch return null;
            w.writeAll("\"") catch return null;
            var p_buf: [512]u8 = undefined;
            const p_n = util.escapeJsonStrFull(p, &p_buf) orelse return null;
            w.writeAll(p_buf[0..p_n]) catch return null;
            w.writeAll("\"") catch return null;
        }
        w.writeAll("]") catch return null;
        return coreCmd(cmd, w.buffered());
    }
};

// ============================================
// http — Zig std.http.Client.fetch wrap (백엔드 only, frontend 미노출 — 보안).
// ============================================

pub const http = struct {
    pub const FetchResult = struct {
        /// HTTP status code (e.g. 200).
        status: u16,
        /// Response body. allocator 소유 → caller가 free.
        body: []u8,
    };

    /// 단순 GET/POST 요청 (Electron `net.fetch` / Node `fetch` 동등). payload null이면 GET,
    /// non-null이면 POST. Redirect 자동 처리. allocator/io는 caller가 주입.
    pub fn fetch(allocator: std.mem.Allocator, fetch_io: std.Io, url: []const u8, payload: ?[]const u8) !FetchResult {
        var client: std.http.Client = .{ .allocator = allocator, .io = fetch_io };
        defer client.deinit();

        var aw = std.Io.Writer.Allocating.init(allocator);
        errdefer aw.deinit();

        const r = try client.fetch(.{
            .location = .{ .url = url },
            .payload = payload,
            .response_writer = &aw.writer,
        });

        return .{
            .status = @intFromEnum(r.status),
            .body = try aw.toOwnedSlice(),
        };
    }
};

// ============================================
// process — Zig std.process.run wrap (백엔드 only, frontend 미노출 — 보안).
// ============================================

pub const process = struct {
    pub const RunResult = struct {
        /// Process exit code. 정상 종료가 아니면 -1.
        code: i32,
        /// Caller가 allocator로 free. 빈 slice면 출력 없음.
        stdout: []u8,
        stderr: []u8,
    };

    /// 외부 명령 실행 (Electron `child_process.spawn` + stdout/stderr capture 동등).
    /// argv[0]은 PATH 또는 절대 경로. allocator가 result.stdout/stderr 소유 → caller가
    /// 사용 후 free. cwd는 부모 프로세스 cwd 상속. io는 caller가 주입 — backend는
    /// `suji.io()`, test는 `std.testing.io` 등.
    pub fn run(allocator: std.mem.Allocator, run_io: std.Io, argv: []const []const u8) !RunResult {
        const result = try std.process.run(allocator, run_io, .{ .argv = argv });
        const code: i32 = switch (result.term) {
            .exited => |c| @intCast(c),
            else => -1,
        };
        return .{ .code = code, .stdout = result.stdout, .stderr = result.stderr };
    }
};

/// suji.json `app.name` 반환. 응답: `{"name":"..."}`.
pub fn getName() ?[]const u8 {
    return coreCmd("app_get_name", "");
}

/// suji.json `app.version` 반환. 응답: `{"version":"..."}`.
pub fn getVersion() ?[]const u8 {
    return coreCmd("app_get_version", "");
}

/// 앱 init 완료 여부 (V8 binding 호출 가능 시점이면 항상 true). 응답: `{"ready":bool}`.
pub fn isReady() ?[]const u8 {
    return coreCmd("app_is_ready", "");
}

/// 앱 frontmost로. 응답: `{"success":bool}`.
pub fn focus() ?[]const u8 {
    return coreCmd("app_focus", "");
}

/// 앱 모든 윈도우 hide (Cmd+H). 응답: `{"success":bool}`.
pub fn hide() ?[]const u8 {
    return coreCmd("app_hide", "");
}

/// Electron `app.getPath` 동등. name = "home"|"appData"|"userData"|"temp"|"desktop"|"documents"|"downloads".
/// 응답: `{"path":"..."}` (unknown name은 빈 문자열).
pub fn getPath(name: []const u8) ?[]const u8 {
    var n_buf: [64]u8 = undefined;
    const n_n = util.escapeJsonStrFull(name, &n_buf) orelse return null;
    var fields_buf: [128]u8 = undefined;
    const fields = std.fmt.bufPrint(&fields_buf, "\"name\":\"{s}\"", .{n_buf[0..n_n]}) catch return null;
    return coreCmd("app_get_path", fields);
}

/// dock 바운스 시작. 응답: `{"id":N}` (0이면 앱이 active라 no-op).
pub fn requestUserAttention(critical: bool) ?[]const u8 {
    var fields_buf: [32]u8 = undefined;
    const fields = std.fmt.bufPrint(&fields_buf, "\"critical\":{}", .{critical}) catch return null;
    return coreCmd("app_attention_request", fields);
}

/// 응답: `{"success":bool}`.
pub fn cancelUserAttentionRequest(id: u32) ?[]const u8 {
    var fields_buf: [32]u8 = undefined;
    const fields = std.fmt.bufPrint(&fields_buf, "\"id\":{d}", .{id}) catch return null;
    return coreCmd("app_attention_cancel", fields);
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
