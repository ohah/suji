const std = @import("std");
const events = @import("events");


/// Zig 코어가 백엔드에게 제공하는 API
/// 백엔드에서 다른 백엔드를 호출할 때 사용
pub const SujiCore = extern struct {
    invoke: *const fn ([*c]const u8, [*c]const u8) callconv(.c) [*c]const u8,
    free: *const fn ([*c]const u8) callconv(.c) void,
    emit: *const fn ([*c]const u8, [*c]const u8) callconv(.c) void,
    on: *const fn ([*c]const u8, ?*const fn ([*c]const u8, [*c]const u8, ?*anyopaque) callconv(.c) void, ?*anyopaque) callconv(.c) u64,
    off: *const fn (u64) callconv(.c) void,
    register: *const fn ([*c]const u8) callconv(.c) void,
};

/// C ABI 백엔드 인터페이스
pub const Backend = struct {
    name: []const u8,
    lib: ?std.DynLib,
    vtable: VTable,

    pub const VTable = struct {
        init: *const fn (?*const SujiCore) callconv(.c) void,
        handle_ipc: *const fn ([*:0]const u8) callconv(.c) ?[*:0]u8,
        free: *const fn (?[*:0]u8) callconv(.c) void,
        destroy: *const fn () callconv(.c) void,
    };

    const InitFn = *const fn (?*const SujiCore) callconv(.c) void;
    const HandleIpcFn = *const fn ([*:0]const u8) callconv(.c) ?[*:0]u8;
    const FreeFn = *const fn (?[*:0]u8) callconv(.c) void;
    const DestroyFn = *const fn () callconv(.c) void;

    pub fn load(name: []const u8, path: [:0]const u8) !Backend {
        var lib = try std.DynLib.open(path);
        errdefer lib.close();

        const vtable = VTable{
            .init = lib.lookup(InitFn, "backend_init") orelse return error.SymbolNotFound,
            .handle_ipc = lib.lookup(HandleIpcFn, "backend_handle_ipc") orelse return error.SymbolNotFound,
            .free = lib.lookup(FreeFn, "backend_free") orelse return error.SymbolNotFound,
            .destroy = lib.lookup(DestroyFn, "backend_destroy") orelse return error.SymbolNotFound,
        };

        return Backend{
            .name = name,
            .lib = lib,
            .vtable = vtable,
        };
    }

    pub fn init(self: *const Backend, core: ?*const SujiCore) void {
        self.vtable.init(core);
    }

    pub fn invoke(self: *const Backend, request: [*:0]const u8) ?[]const u8 {
        const result = self.vtable.handle_ipc(request);
        if (result) |r| return std.mem.span(r);
        return null;
    }

    pub fn freeResponse(self: *const Backend, response: ?[]const u8) void {
        if (response) |r| {
            self.vtable.free(@ptrCast(@constCast(r.ptr)));
        }
    }

    pub fn deinit(self: *Backend) void {
        self.vtable.destroy();
        if (self.lib) |*lib| {
            lib.close();
            self.lib = null;
        }
    }
};

/// 여러 백엔드를 관리하는 레지스트리
pub const BackendRegistry = struct {
    backends: std.StringHashMap(Backend),
    allocator: std.mem.Allocator,
    core_api: SujiCore,
    event_bus: ?*events.EventBus = null,
    /// 채널 → 백엔드 이름 라우팅 테이블
    routes: std.StringHashMap([]const u8),
    /// register 중인 백엔드 이름 (backend_init 호출 중에만 유효)
    registering_backend: ?[]const u8 = null,

    pub var global: ?*BackendRegistry = null;

    pub fn init(allocator: std.mem.Allocator) BackendRegistry {
        var reg = BackendRegistry{
            .backends = std.StringHashMap(Backend).init(allocator),
            .allocator = allocator,
            .routes = std.StringHashMap([]const u8).init(allocator),
            .core_api = SujiCore{
                .invoke = coreInvoke,
                .free = coreFree,
                .emit = coreEmit,
                .on = coreOn,
                .off = coreOff,
                .register = coreRegister,
            },
        };
        _ = &reg;
        return reg;
    }

    /// 채널 이름으로 백엔드 자동 라우팅
    pub fn invokeByChannel(self: *const BackendRegistry, channel: []const u8, request: [*:0]const u8) ?[]const u8 {
        // 라우팅 테이블에서 찾기
        if (self.routes.get(channel)) |backend_name| {
            return self.invoke(backend_name, request);
        }
        // 못 찾으면 null
        return null;
    }

    /// 채널이 어느 백엔드에 등록됐는지 조회
    pub fn getBackendForChannel(self: *const BackendRegistry, channel: []const u8) ?[]const u8 {
        return self.routes.get(channel);
    }

    pub fn setEventBus(self: *BackendRegistry, bus: *events.EventBus) void {
        self.event_bus = bus;
    }

    /// 글로벌 참조 설정 (C 콜백에서 접근 가능하게)
    pub fn setGlobal(self: *BackendRegistry) void {
        global = self;
    }

    /// 백엔드 등록 (dlopen + init with core API)
    pub fn register(self: *BackendRegistry, name: []const u8, path: [:0]const u8) !void {
        var backend = try Backend.load(name, path);
        // init 중 register() 콜백에서 이 이름 사용
        self.registering_backend = name;
        backend.init(&self.core_api);
        self.registering_backend = null;
        try self.backends.put(name, backend);
    }

    pub fn get(self: *const BackendRegistry, name: []const u8) ?*const Backend {
        if (self.backends.getPtr(name)) |ptr| return ptr;
        return null;
    }

    pub fn invoke(self: *const BackendRegistry, backend_name: []const u8, request: [*:0]const u8) ?[]const u8 {
        const backend = self.get(backend_name) orelse return null;
        return backend.invoke(request);
    }

    pub fn freeResponse(self: *const BackendRegistry, backend_name: []const u8, response: ?[]const u8) void {
        const backend = self.get(backend_name) orelse return;
        backend.freeResponse(response);
    }

    pub fn deinit(self: *BackendRegistry) void {
        var iter = self.backends.iterator();
        while (iter.next()) |entry| {
            var backend = entry.value_ptr;
            backend.deinit();
        }
        self.backends.deinit();
        self.routes.deinit();
        global = null;
    }

    // C ABI 콜백: 백엔드에서 다른 백엔드 호출
    fn coreInvoke(backend_name: [*c]const u8, request: [*c]const u8) callconv(.c) [*c]const u8 {
        const reg = global orelse return @ptrCast(@constCast(""));
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(backend_name)));
        const resp = reg.invoke(name, @ptrCast(request));
        if (resp) |r| {
            // 응답을 복사해서 반환 (원본은 백엔드 소유)
            const backend = reg.get(name) orelse return @ptrCast(@constCast(""));
            _ = backend;
            // 백엔드 응답 포인터를 그대로 반환 (호출자가 core.free로 해제)
            return @ptrCast(@constCast(r.ptr));
        }
        return @ptrCast(@constCast("{}"));
    }

    // C ABI 콜백: 이벤트 발행
    fn coreEmit(event_name: [*c]const u8, data: [*c]const u8) callconv(.c) void {
        const reg = global orelse return;
        const bus = reg.event_bus orelse return;
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(event_name)));
        const d = std.mem.span(@as([*:0]const u8, @ptrCast(data)));
        bus.emit(name, d);
    }

    // C ABI 콜백: 이벤트 구독
    fn coreOn(event_name: [*c]const u8, callback: ?*const fn ([*c]const u8, [*c]const u8, ?*anyopaque) callconv(.c) void, arg: ?*anyopaque) callconv(.c) u64 {
        const reg = global orelse return 0;
        const bus = reg.event_bus orelse return 0;
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(event_name)));
        if (callback) |cb| {
            return bus.onC(name, cb, arg);
        }
        return 0;
    }

    // C ABI 콜백: 리스너 해제
    fn coreOff(listener_id: u64) callconv(.c) void {
        const reg = global orelse return;
        const bus = reg.event_bus orelse return;
        bus.off(listener_id);
    }

    // C ABI 콜백: 핸들러 등록 (채널 → 백엔드 라우팅)
    fn coreRegister(channel_name: [*c]const u8) callconv(.c) void {
        const reg = global orelse return;
        const channel = std.mem.span(@as([*:0]const u8, @ptrCast(channel_name)));
        const backend = reg.registering_backend orelse return;

        // 중복 등록 체크
        if (reg.routes.get(channel)) |existing| {
            std.debug.print("[suji] WARN: channel '{s}' already registered by '{s}', skipping for '{s}'\n", .{ channel, existing, backend });
            return;
        }

        // 키를 allocator로 복사 (C 스택 포인터는 함수 종료 후 무효)
        const owned_channel = reg.allocator.dupe(u8, channel) catch return;
        reg.routes.put(owned_channel, backend) catch {};
    }

    // C ABI 콜백: 응답 메모리 해제
    fn coreFree(ptr: [*c]const u8) callconv(.c) void {
        // 현재는 백엔드가 할당한 메모리를 그대로 반환하므로
        // 원래 백엔드의 free를 호출해야 하지만, 어떤 백엔드인지 모름
        // TODO: 응답에 백엔드 정보를 태깅하는 방식으로 개선
        _ = ptr;
    }
};
