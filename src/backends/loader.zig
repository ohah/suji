const std = @import("std");

/// Zig 코어가 백엔드에게 제공하는 API
/// 백엔드에서 다른 백엔드를 호출할 때 사용
pub const SujiCore = extern struct {
    invoke: *const fn ([*c]const u8, [*c]const u8) callconv(.c) [*c]const u8,
    free: *const fn ([*c]const u8) callconv(.c) void,
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

    // 글로벌 레지스트리 참조 (C 콜백에서 접근용)
    pub var global: ?*BackendRegistry = null;

    pub fn init(allocator: std.mem.Allocator) BackendRegistry {
        var reg = BackendRegistry{
            .backends = std.StringHashMap(Backend).init(allocator),
            .allocator = allocator,
            .core_api = SujiCore{
                .invoke = coreInvoke,
                .free = coreFree,
            },
        };
        _ = &reg;
        return reg;
    }

    /// 글로벌 참조 설정 (C 콜백에서 접근 가능하게)
    pub fn setGlobal(self: *BackendRegistry) void {
        global = self;
    }

    /// 백엔드 등록 (dlopen + init with core API)
    pub fn register(self: *BackendRegistry, name: []const u8, path: [:0]const u8) !void {
        var backend = try Backend.load(name, path);
        backend.init(&self.core_api);
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

    // C ABI 콜백: 응답 메모리 해제
    fn coreFree(ptr: [*c]const u8) callconv(.c) void {
        // 현재는 백엔드가 할당한 메모리를 그대로 반환하므로
        // 원래 백엔드의 free를 호출해야 하지만, 어떤 백엔드인지 모름
        // TODO: 응답에 백엔드 정보를 태깅하는 방식으로 개선
        _ = ptr;
    }
};
