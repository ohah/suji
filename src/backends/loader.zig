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
    /// 메인 프로세스의 std.Io 포인터 getter (Zig plugin 전용).
    /// 반환값은 `*const std.Io`로 캐스팅해서 사용.
    /// Rust/Go plugin은 무시 (자체 OS I/O 사용).
    get_io: *const fn () callconv(.c) ?*const anyopaque,
    /// 주입 안 된 경우 no-op (SDK/core 버전 불일치로부터 안전).
    quit: *const fn () callconv(.c) void,
    /// dylib 백엔드는 자기가 컴파일된 타겟의 플랫폼을 본다 (런타임 OS와 일치해야 정상).
    platform: *const fn () callconv(.c) [*:0]const u8,
};

/// dlopen 바깥에서 프로세스 내에 임베드되는 언어 런타임 (Node.js, 향후 Python/Lua).
/// `BackendRegistry.embed_runtimes`에 이름으로 등록하면 `coreInvoke`가 dlopen 백엔드를
/// 찾지 못했을 때 이 테이블로 폴백한다. 각 런타임이 자기 언어의 동시성/메모리 모델을
/// 유지하므로 Suji 코어는 채널명 라우팅과 응답 복사만 담당.
pub const EmbedRuntime = struct {
    /// 요청 실행. channel은 JSON 요청의 `cmd` 필드에서 추출된 값.
    /// 반환 문자열은 런타임이 소유 (직후 `free_response`로 해제됨).
    invoke: *const fn (channel: [*:0]const u8, data: [*:0]const u8) callconv(.c) ?[*:0]const u8,
    /// `invoke`가 반환한 응답 문자열의 소유 메모리 해제. null이면 leak (런타임이 정책상 관리 안 하는 경우).
    free_response: ?*const fn (ptr: [*:0]const u8) callconv(.c) void = null,
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
        // Zig 0.16은 Windows용 std.DynLib이 미구현 (LoadLibraryA 래퍼 없음).
        // Windows에서는 dlopen 백엔드 로드가 불가능하므로 즉시 에러 반환.
        // 임베드 런타임(Node 등)은 embed_runtimes 테이블로 계속 동작.
        // 추후 kernel32 직접 래핑으로 지원 예정.
        if (@import("builtin").os.tag == .windows) return error.DynlibUnsupportedOnWindows;

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
        // Windows는 load()가 항상 에러 반환이라 여기 도달할 일이 없음.
        // 그래도 comptime branch로 DynLib.close 참조를 Windows 경로에서 제거.
        if (@import("builtin").os.tag != .windows) {
            if (self.lib) |*lib| {
                lib.close();
                self.lib = null;
            }
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
    /// 핫 리로드: invoke 중 언로드 방지 (Zig 0.16: std.Io.RwLock)
    rw_lock: std.Io.RwLock = .init,
    /// lock 호출에 필요한 io (init에서 주입, 기본은 runtime.io)
    io: std.Io,

    pub var global: ?*BackendRegistry = null;

    /// 임베드 런타임 테이블. main이 Node/Python/Lua 등을 여기 등록.
    /// coreInvoke에서 dlopen registry에 없는 이름일 때 폴백으로 조회.
    pub var embed_runtimes: std.StringHashMap(EmbedRuntime) = undefined;
    var embed_runtimes_initialized: bool = false;

    /// 임베드 런타임 등록. 호출 순서 상관없이 사용 전 lazy-init.
    pub fn registerEmbedRuntime(name: []const u8, rt: EmbedRuntime) !void {
        const g = global orelse return error.NoRegistry;
        if (!embed_runtimes_initialized) {
            embed_runtimes = std.StringHashMap(EmbedRuntime).init(g.allocator);
            embed_runtimes_initialized = true;
        }
        const owned = try g.allocator.dupe(u8, name);
        try embed_runtimes.put(owned, rt);
    }

    pub fn init(allocator: std.mem.Allocator, io: std.Io) BackendRegistry {
        var reg = BackendRegistry{
            .backends = std.StringHashMap(Backend).init(allocator),
            .allocator = allocator,
            .routes = std.StringHashMap([]const u8).init(allocator),
            .io = io,
            .core_api = SujiCore{
                .invoke = coreInvoke,
                .free = coreFree,
                .emit = coreEmit,
                .on = coreOn,
                .off = coreOff,
                .register = coreRegister,
                .get_io = coreGetIo,
                .quit = coreQuit,
                .platform = corePlatform,
            },
        };
        _ = &reg;
        return reg;
    }

    /// 채널 이름으로 백엔드 자동 라우팅
    pub fn invokeByChannel(self: *BackendRegistry, channel: []const u8, request: [*:0]const u8) ?[]const u8 {
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

    /// 앱 종료 함수 주입 (main.zig가 cef.quit 같은 걸 등록).
    /// 주입 전 coreQuit 호출은 no-op.
    pub fn setQuitHandler(_: *BackendRegistry, handler: *const fn () void) void {
        quit_handler = handler;
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
        defer self.registering_backend = null;
        backend.init(&self.core_api);
        try self.backends.put(name, backend);
    }

    pub fn get(self: *const BackendRegistry, name: []const u8) ?*const Backend {
        if (self.backends.getPtr(name)) |ptr| return ptr;
        return null;
    }

    pub fn invoke(self: *BackendRegistry, backend_name: []const u8, request: [*:0]const u8) ?[]const u8 {
        self.rw_lock.lockSharedUncancelable(self.io);
        defer self.rw_lock.unlockShared(self.io);
        const backend = self.get(backend_name) orelse return null;
        return backend.invoke(request);
    }

    pub fn freeResponse(self: *const BackendRegistry, backend_name: []const u8, response: ?[]const u8) void {
        const backend = self.get(backend_name) orelse return;
        backend.freeResponse(response);
    }

    /// 백엔드 핫 리로드: 언로드 → 라우팅 정리 → 재로드
    pub fn reload(self: *BackendRegistry, name: []const u8, path: [:0]const u8) !void {
        // 1. 새 dylib 로드 (lock 밖에서 — I/O + 심볼 해석이 느림)
        var backend = try Backend.load(name, path);
        errdefer backend.deinit();

        // 2. lock 획득 → 스왑
        self.rw_lock.lockUncancelable(self.io);
        defer self.rw_lock.unlock(self.io);

        // 기존 백엔드 언로드
        if (self.backends.getPtr(name)) |old| {
            old.deinit();
            _ = self.backends.remove(name);
        }

        // 라우팅 테이블 정리
        self.clearRoutesFor(name);

        // 새 백엔드 등록 + 초기화
        self.registering_backend = name;
        defer self.registering_backend = null;
        backend.init(&self.core_api);
        try self.backends.put(name, backend);
    }

    /// 특정 백엔드의 라우팅 엔트리 제거
    pub fn clearRoutesFor(self: *BackendRegistry, backend_name: []const u8) void {
        var iter = self.routes.iterator();
        while (iter.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.*, backend_name)) {
                entry.value_ptr.* = ""; // 자동 라우팅 차단
            }
        }
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

    // ============================================
    // 응답 소유권 (length-prefix header)
    // ============================================
    // coreInvoke는 백엔드/Node 응답을 Suji allocator로 즉시 복사하고, 원본은
    // 소유자(백엔드 SDK / node bridge)에게 돌려보낸다. 호출자(다른 SDK)는
    // 받은 포인터를 coreFree로 해제하고, Suji는 포인터 직전 8바이트의 길이 필드로
    // 전체 할당 크기를 계산해 자기 allocator로 free한다.
    //
    // 레이아웃: [len: u64 LE][body...][0]
    //           ^             ^
    //           header_ptr    body_ptr (호출자가 받음)
    const OWNED_HEADER_SIZE: usize = 8;

    /// 백엔드/Node 응답을 Suji 소유 메모리로 복사. 실패 시 null.
    fn dupeOwnedResponse(allocator: std.mem.Allocator, src: []const u8) ?[*:0]u8 {
        const total = OWNED_HEADER_SIZE + src.len + 1;
        const buf = allocator.alloc(u8, total) catch return null;
        std.mem.writeInt(u64, buf[0..OWNED_HEADER_SIZE], src.len, .little);
        @memcpy(buf[OWNED_HEADER_SIZE .. OWNED_HEADER_SIZE + src.len], src);
        buf[OWNED_HEADER_SIZE + src.len] = 0;
        return @ptrCast(buf[OWNED_HEADER_SIZE .. OWNED_HEADER_SIZE + src.len :0].ptr);
    }

    /// coreInvoke가 반환했던 포인터를 해제. null 또는 static 문자열("{}"/"")는 무시.
    fn freeOwnedResponse(allocator: std.mem.Allocator, body_ptr: [*:0]const u8) void {
        const body_bytes: [*]const u8 = @ptrCast(body_ptr);
        const header_bytes = body_bytes - OWNED_HEADER_SIZE;
        const len = std.mem.readInt(u64, header_bytes[0..OWNED_HEADER_SIZE], .little);
        // 방어: 말도 안 되는 크기면 no-op (static literal 등이 잘못 넘어온 경우)
        if (len > 64 * 1024 * 1024) return;
        const total = OWNED_HEADER_SIZE + len + 1;
        const full_slice: []const u8 = header_bytes[0..total];
        allocator.free(full_slice);
    }

    // C ABI 콜백: 백엔드에서 다른 백엔드 호출
    fn coreInvoke(backend_name: [*c]const u8, request: [*c]const u8) callconv(.c) [*c]const u8 {
        const reg = global orelse return @ptrCast(@constCast(""));
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(backend_name)));

        // dlopen 백엔드 경로
        if (reg.get(name)) |backend| {
            const raw = backend.invoke(@ptrCast(request));
            if (raw) |r| {
                const owned = dupeOwnedResponse(reg.allocator, r) orelse {
                    backend.freeResponse(r);
                    return @ptrCast(@constCast(""));
                };
                backend.freeResponse(r);
                return @ptrCast(owned);
            }
        }

        // 임베드 런타임 폴백 (Node.js, 향후 Python/Lua 등)
        if (embed_runtimes_initialized) {
            if (embed_runtimes.get(name)) |rt| {
                const req_span = std.mem.span(@as([*:0]const u8, @ptrCast(request)));
                var ch_buf: [256]u8 = undefined;
                const channel = extractCmdField(req_span) orelse name;
                const len = @min(channel.len, ch_buf.len - 1);
                @memcpy(ch_buf[0..len], channel[0..len]);
                ch_buf[len] = 0;
                if (rt.invoke(@ptrCast(&ch_buf), @ptrCast(request))) |p| {
                    const raw_body = std.mem.span(p);
                    const owned = dupeOwnedResponse(reg.allocator, raw_body);
                    // 런타임이 free_response를 제공하면 원본 메모리 반납
                    if (rt.free_response) |ff| ff(p);
                    if (owned) |o| return @ptrCast(o);
                }
            }
        }

        return @ptrCast(@constCast("{}"));
    }

    /// JSON 요청에서 "cmd" 문자열 필드 추출 (단순 스캐너, 이스케이프 미지원).
    fn extractCmdField(json: []const u8) ?[]const u8 {
        const key = "\"cmd\":\"";
        const i = std.mem.indexOf(u8, json, key) orelse return null;
        const start = i + key.len;
        const end_rel = std.mem.indexOfScalar(u8, json[start..], '"') orelse return null;
        return json[start .. start + end_rel];
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

        if (reg.routes.getPtr(channel)) |existing_ptr| {
            // 중복: 값을 빈 문자열로 덮어쓰기 (자동 라우팅 차단). target 옵션 강제.
            std.debug.print("[suji] ERROR: channel '{s}' duplicate ('{s}' and '{s}') — use target option\n", .{ channel, existing_ptr.*, backend });
            existing_ptr.* = "";
            return;
        }

        const owned_channel = reg.allocator.dupe(u8, channel) catch return;
        reg.routes.put(owned_channel, backend) catch {
            reg.allocator.free(owned_channel);
        };
    }

    // C ABI 콜백: 응답 메모리 해제 (coreInvoke가 복사한 Suji 소유 메모리)
    fn coreFree(ptr: [*c]const u8) callconv(.c) void {
        if (ptr == null) return;
        const reg = global orelse return;
        const c_ptr: [*:0]const u8 = @ptrCast(ptr);
        // 정적 문자열("{}"/"")은 header가 없어 free 불가 — 간단 가드.
        const body = std.mem.span(c_ptr);
        if (body.len == 0 or std.mem.eql(u8, body, "{}")) return;
        freeOwnedResponse(reg.allocator, c_ptr);
    }

    /// C ABI 콜백: 메인 프로세스의 std.Io 포인터 반환.
    /// Zig plugin이 `*const std.Io`로 캐스팅해서 사용.
    /// Rust/Go plugin은 자체 언어 표준 I/O를 쓰면 되므로 호출하지 않음.
    fn coreGetIo() callconv(.c) ?*const anyopaque {
        const g = global orelse return null;
        return @ptrCast(&g.io);
    }

    fn coreQuit() callconv(.c) void {
        if (quit_handler) |h| h();
    }

    fn corePlatform() callconv(.c) [*:0]const u8 {
        return platformName();
    }
};

var quit_handler: ?*const fn () void = null;

/// 플랫폼 문자열 상수 — loader / SDK / tests가 동일 문자열 공유.
/// Suji는 macOS / Linux / Windows만 지원. 그 외 OS는 컴파일 단계 에러.
pub const platform_names = struct {
    pub const macos: [:0]const u8 = "macos";
    pub const linux: [:0]const u8 = "linux";
    pub const windows: [:0]const u8 = "windows";
};

pub fn platformName() [*:0]const u8 {
    const builtin = @import("builtin");
    return switch (builtin.os.tag) {
        .macos => platform_names.macos,
        .linux => platform_names.linux,
        .windows => platform_names.windows,
        else => @compileError("Suji: unsupported OS (only macos/linux/windows)"),
    };
}
