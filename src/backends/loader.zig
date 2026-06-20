const std = @import("std");
const events = @import("events");
const util = @import("util");

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
    /// 특정 창(WindowManager id)에만 이벤트 전달 (Electron `webContents.send`).
    /// 대상이 닫혔거나 존재하지 않으면 no-op.
    emit_to: *const fn (u32, [*c]const u8, [*c]const u8) callconv(.c) void,
    /// WindowManager 전용 API table. 플러그인이 창/webContents를 조작할 때
    /// generic `invoke("__core__", ...)` 대신 사용할 수 있다.
    get_window_api: *const fn () callconv(.c) ?*const WindowApi,
};

/// 플러그인/백엔드에 노출되는 창 전용 C ABI.
///
/// v1은 기존 `__core__` window cmd JSON을 그대로 받는 raw dispatcher다. 이 표면을
/// 먼저 고정해 두면 후속으로 typed function을 추가하더라도 기존 플러그인과 호환된다.
pub const WindowApi = extern struct {
    request_json: *const fn ([*c]const u8) callconv(.c) [*c]const u8,
    free_response: *const fn ([*c]const u8) callconv(.c) void,
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
    /// CEF 경로(cefInvokeHandler)에서 name 정확 매칭이 없을 때 미해결 채널을 받는
    /// catch-all 런타임 여부. node 는 채널을 routes 에 등록하지 않아 catch-all(예:
    /// route 미등록 "node-stress")로 동작 — 기존 동작 보존. lua/python 은 false
    /// (정확 매칭만). catch-all 은 하나만 두는 것을 전제로 한다(여럿이면 순서 비결정).
    is_catch_all: bool = false,
};

const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;

/// Zig 0.16은 `std.DynLib`의 Windows 경로를 의도적으로 제거(릴리스 노트) —
/// regression이 아니라 "kernel32를 직접 쓰라"가 공식 입장. POSIX는 std.DynLib,
/// Windows는 kernel32 직접 래핑으로 동일 인터페이스(open/lookup/close) 제공.
const win = if (is_windows) struct {
    const w = std.os.windows;
    extern "kernel32" fn LoadLibraryExW(lpLibFileName: [*:0]const u16, hFile: ?*anyopaque, dwFlags: u32) callconv(.winapi) ?w.HMODULE;
    extern "kernel32" fn GetProcAddress(hModule: w.HMODULE, lpProcName: [*:0]const u8) callconv(.winapi) ?w.FARPROC;
    extern "kernel32" fn FreeLibrary(hModule: w.HMODULE) callconv(.winapi) w.BOOL;
    /// 의존 DLL을 백엔드 .dll 옆에서 탐색 (Rust/Go 백엔드의 형제 deps 해석).
    const LOAD_WITH_ALTERED_SEARCH_PATH: u32 = 0x00000008;
} else struct {};

pub const WinDynLib = struct {
    handle: std.os.windows.HMODULE,

    pub fn open(path: [:0]const u8) !WinDynLib {
        var buf: [std.os.windows.PATH_MAX_WIDE + 1]u16 = undefined;
        const len = std.unicode.utf8ToUtf16Le(buf[0..], path) catch return error.BadPathName;
        buf[len] = 0;
        const h = win.LoadLibraryExW(buf[0..len :0].ptr, null, win.LOAD_WITH_ALTERED_SEARCH_PATH) orelse
            return error.FileNotFound;
        return .{ .handle = h };
    }

    pub fn lookup(self: *WinDynLib, comptime T: type, name: [:0]const u8) ?T {
        const p = win.GetProcAddress(self.handle, name.ptr) orelse return null;
        return @ptrCast(@alignCast(p));
    }

    pub fn close(self: *WinDynLib) void {
        _ = win.FreeLibrary(self.handle);
    }
};

/// 크로스 플랫폼 동적 라이브러리 핸들. 호출부(open/lookup/close)는 동일 API 사용.
/// POSIX=std.DynLib, Windows=WinDynLib(kernel32). BackendRegistry 외에 `suji types`
/// (cli/types_cmd.zig)도 백엔드 dlopen→backend_dump_schema 에 재사용(단일 출처).
pub const DynLib = if (is_windows) WinDynLib else std.DynLib;

/// C ABI 백엔드 인터페이스
pub const Backend = struct {
    name: []const u8,
    lib: ?DynLib,
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
        var lib = try DynLib.open(path);
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
        // 핫 리로드 경로에서만 호출됨 (registry.deinit는 프로세스 종료 시
        // backend.deinit 생략 — dlclose/FreeLibrary 후 잔존 워커 SIGSEGV 회피).
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
    /// plugin name → outbound invoke allowlist. Missing entry means legacy unrestricted.
    plugin_permissions: std.StringHashMap([]const []const u8),
    /// register 중인 백엔드 이름 (backend_init 호출 중에만 유효)
    registering_backend: ?[]const u8 = null,
    /// 핫 리로드: invoke 중 언로드 방지 (Zig 0.16: std.Io.RwLock)
    rw_lock: std.Io.RwLock = .init,
    /// lock 호출에 필요한 io (init에서 주입, 기본은 runtime.io)
    io: std.Io,

    pub var global: ?*BackendRegistry = null;

    /// special channel 이름 상수 — 4곳(cef/loader/main/test)에서 동일 식별자로 비교.
    /// 새 special channel 추가 시 여기 추가 + special_dispatch wrapper 분기.
    pub const CHANNEL_CORE: []const u8 = "__core__";
    pub const CHANNEL_FANOUT: []const u8 = "__fanout__";
    pub const CHANNEL_CHAIN: []const u8 = "__chain__";

    /// special channel(`__core__`/`__fanout__`/`__chain__`) dispatcher.
    /// main이 backend SDK 경로에도 동일 라우팅을 제공하기 위해 주입.
    /// null이면 백엔드의 callBackend("__core__", ...)는 빈 `{}` 반환 (CEF 경로만 동작).
    pub const SpecialDispatch = *const fn (channel: []const u8, data: []const u8, response_buf: []u8) ?[]const u8;
    pub var special_dispatch: ?SpecialDispatch = null;

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
        // 동일 채널명 재등록 시 getOrPut 으로 기존 키를 재사용 — put 은 기존 키를
        // 유지하므로 새 dupe 한 키가 그대로 누수된다(StringHashMap 계약).
        const gop = try embed_runtimes.getOrPut(name);
        if (!gop.found_existing) {
            gop.key_ptr.* = g.allocator.dupe(u8, name) catch |e| {
                _ = embed_runtimes.remove(name);
                return e;
            };
        }
        gop.value_ptr.* = rt;
    }

    /// CEF 경로(cefInvokeHandler) 임베드 디스패치 — name(target/route) 정확 매칭
    /// 우선, 없으면 catch-all 런타임. 응답을 response_buf 에 복사해 slice 반환.
    /// 정확 매칭 런타임이 있으면 그 결과를 그대로 반환(invoke null → null)하고
    /// catch-all 로 넘기지 않는다 — "백엔드 전용 채널이 다른 런타임에 새는" 일 방지.
    pub fn invokeEmbed(name: []const u8, channel: []const u8, request: [*:0]const u8, response_buf: []u8) ?[]const u8 {
        if (!embed_runtimes_initialized) return null;
        if (embed_runtimes.get(name)) |rt| {
            return dispatchEmbed(rt, channel, request, response_buf);
        }
        var it = embed_runtimes.valueIterator();
        while (it.next()) |rt| {
            if (rt.is_catch_all) {
                if (dispatchEmbed(rt.*, channel, request, response_buf)) |r| return r;
            }
        }
        return null;
    }

    fn dispatchEmbed(rt: EmbedRuntime, channel: []const u8, request: [*:0]const u8, response_buf: []u8) ?[]const u8 {
        var ch_buf: [256]u8 = undefined;
        const len = @min(channel.len, ch_buf.len - 1);
        @memcpy(ch_buf[0..len], channel[0..len]);
        ch_buf[len] = 0;
        const p = rt.invoke(@ptrCast(&ch_buf), request) orelse return null;
        const body = std.mem.span(p);
        const out_len = @min(body.len, response_buf.len);
        @memcpy(response_buf[0..out_len], body[0..out_len]);
        if (rt.free_response) |ff| ff(p);
        return response_buf[0..out_len];
    }

    pub fn init(allocator: std.mem.Allocator, io: std.Io) BackendRegistry {
        var reg = BackendRegistry{
            .backends = std.StringHashMap(Backend).init(allocator),
            .allocator = allocator,
            .routes = std.StringHashMap([]const u8).init(allocator),
            .plugin_permissions = std.StringHashMap([]const []const u8).init(allocator),
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
                .emit_to = coreEmitTo,
                .get_window_api = coreGetWindowApi,
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
        const prev = current_invoker;
        current_invoker = name;
        defer current_invoker = prev;
        backend.init(&self.core_api);
        try self.backends.put(name, backend);
    }

    pub fn get(self: *const BackendRegistry, name: []const u8) ?*const Backend {
        if (self.backends.getPtr(name)) |ptr| return ptr;
        return null;
    }

    pub fn invoke(self: *BackendRegistry, backend_name: []const u8, request: [*:0]const u8) ?[]const u8 {
        self.rw_lock.lockSharedUncancelable(self.io);
        const prev_held = registry_lock_held;
        registry_lock_held = true;
        defer {
            registry_lock_held = prev_held;
            self.rw_lock.unlockShared(self.io);
        }
        const backend = self.get(backend_name) orelse return null;
        const prev = current_invoker;
        current_invoker = backend.name;
        defer current_invoker = prev;
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
        // write lock 보유 중 backend.init 이 같은 스레드에서 coreInvoke 로 크로스콜하면
        // coreInvoke 가 공유락을 재취득하려다 자기 write lock 과 데드락한다 — flag 로 차단.
        const prev_held = registry_lock_held;
        registry_lock_held = true;
        defer {
            registry_lock_held = prev_held;
            self.rw_lock.unlock(self.io);
        }

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
        const prev = current_invoker;
        current_invoker = name;
        defer current_invoker = prev;
        backend.init(&self.core_api);
        try self.backends.put(name, backend);
    }

    /// 라우팅 엔트리 추가 (키를 dupe하여 HashMap이 소유권을 가짐).
    /// deinit이 키를 free하려면 반드시 이 경로로 put해야 한다. 문자열 리터럴을
    /// 직접 `reg.routes.put(...)`하면 deinit이 잘못된 포인터를 free하려다 crash.
    pub fn putRoute(self: *BackendRegistry, channel: []const u8, backend: []const u8) !void {
        const owned = try self.allocator.dupe(u8, channel);
        errdefer self.allocator.free(owned);
        try self.routes.put(owned, backend);
    }

    pub fn setPluginPermissions(self: *BackendRegistry, plugin_name: []const u8, permissions: []const []const u8) !void {
        if (self.plugin_permissions.fetchRemove(plugin_name)) |entry| {
            freePermissionEntry(self.allocator, entry.key, entry.value);
        }

        const owned_name = try self.allocator.dupe(u8, plugin_name);
        errdefer self.allocator.free(owned_name);

        var owned_permissions = try self.allocator.alloc([]const u8, permissions.len);
        errdefer self.allocator.free(owned_permissions);
        var copied: usize = 0;
        errdefer {
            for (owned_permissions[0..copied]) |p| self.allocator.free(p);
        }
        for (permissions, 0..) |permission, i| {
            owned_permissions[i] = try self.allocator.dupe(u8, permission);
            copied += 1;
        }

        try self.plugin_permissions.put(owned_name, owned_permissions);
    }

    pub fn canInvokeFrom(self: *const BackendRegistry, invoker: ?[]const u8, target_name: []const u8, req_json: []const u8) bool {
        const caller = invoker orelse return true;
        const permissions = self.plugin_permissions.get(caller) orelse return true;
        const requested = extractCmdField(req_json) orelse target_name;
        for (permissions) |permission| {
            if (permissionAllows(permission, requested)) return true;
        }
        return false;
    }

    pub fn permissionAllows(permission: []const u8, requested: []const u8) bool {
        if (std.mem.eql(u8, permission, "*")) return true;
        if (std.mem.eql(u8, permission, requested)) return true;
        if (std.mem.endsWith(u8, permission, ":*")) {
            const prefix = permission[0 .. permission.len - 1];
            return std.mem.startsWith(u8, requested, prefix);
        }
        return false;
    }

    /// 특정 백엔드의 라우팅 엔트리를 완전히 제거(소유 키 free 포함).
    /// 값을 ""로 덮으면 coreRegister 의 충돌-가드(`existing.len==0` early-return)가 핫
    /// 리로드 후 합법적 재등록을 중복으로 오인해 차단 → 자동 라우팅이 영구 비활성화됐다.
    /// 그래서 엔트리 자체를 삭제해 재등록이 putRoute 경로로 정상 진행되게 한다.
    /// (route 테이블은 채널 수만큼이라 작음 — scan-remove-first 반복으로 iterator
    ///  무효화를 피하고 추가 할당 없이 처리.)
    pub fn clearRoutesFor(self: *BackendRegistry, backend_name: []const u8) void {
        while (true) {
            var found_key: ?[]const u8 = null;
            var iter = self.routes.iterator();
            while (iter.next()) |entry| {
                if (std.mem.eql(u8, entry.value_ptr.*, backend_name)) {
                    found_key = entry.key_ptr.*;
                    break;
                }
            }
            const key = found_key orelse break;
            _ = self.routes.remove(key);
            self.allocator.free(key);
        }
    }

    pub fn deinit(self: *BackendRegistry) void {
        // 프로세스 종료 중에는 backend.deinit()을 호출하지 않는다.
        //   - backend.deinit() → dlclose → dylib code region이 unmap됨
        //   - Rust tokio worker / Go goroutine / Node 등 남은 워커 스레드가 그 뒤에도
        //     살아서 스케줄되면 unmap된 code를 실행하다 SIGSEGV (librust_backend 케이스).
        //   - OS가 exit() 시 모든 매핑을 자동 회수하므로 graceful dlclose는 불필요.
        //   - 핫 리로드 경로(registry.reload)는 여전히 개별 backend.deinit을 호출함.
        self.backends.deinit();

        // routes 키는 coreRegister에서 dupe한 소유 문자열. HashMap.deinit만으론
        // 키 메모리가 해제되지 않음 → 전수 순회하며 직접 free.
        var routes_iter = self.routes.iterator();
        while (routes_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.routes.deinit();

        var perm_iter = self.plugin_permissions.iterator();
        while (perm_iter.next()) |entry| {
            freePermissionEntry(self.allocator, entry.key_ptr.*, entry.value_ptr.*);
        }
        self.plugin_permissions.deinit();

        // embed_runtimes는 프로세스 전역. 마지막 registry가 deinit될 때 비운다.
        if (embed_runtimes_initialized) {
            var er_iter = embed_runtimes.iterator();
            while (er_iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
            }
            embed_runtimes.deinit();
            embed_runtimes_initialized = false;
        }

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
        const reg = global orelse return @ptrCast(RESP_EMPTY);
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(backend_name)));
        const req_span = std.mem.span(@as([*:0]const u8, @ptrCast(request)));

        if (!reg.canInvokeFrom(current_invoker, name, req_span)) {
            const owned = dupeOwnedResponse(reg.allocator, "{\"error\":\"plugin permission denied\"}") orelse return @ptrCast(RESP_EMPTY_OBJ);
            return @ptrCast(owned);
        }

        // special channel — main이 inject한 dispatcher. CEF의 cefInvokeHandler와 동일
        // 라우팅을 backend SDK 경로에서도 제공.
        if (special_dispatch) |dispatch| {
            if (std.mem.eql(u8, name, CHANNEL_CORE) or
                std.mem.eql(u8, name, CHANNEL_FANOUT) or
                std.mem.eql(u8, name, CHANNEL_CHAIN))
            {
                var resp_buf: [16384]u8 = undefined;
                const out = dispatch(name, req_span, &resp_buf) orelse return @ptrCast(RESP_EMPTY_OBJ);
                const owned = dupeOwnedResponse(reg.allocator, out) orelse return @ptrCast(RESP_EMPTY_OBJ);
                return @ptrCast(owned);
            }
        }

        // dlopen 백엔드 경로 — 외부(독립) 스레드 호출이면 공유락으로 reload(dlclose)
        // 와의 use-after-unmap race 를 막고, invoke 체인 내부 재진입이면 이미 보유 중인
        // 락을 재사용한다(writer 대기 중 nested-shared 데드락 회피). 호출 직전
        // current_invoker 를 대상 백엔드로 갱신해 중첩 크로스콜 권한이 호출자(B) 기준이
        // 아닌 실제 발신자 기준으로 평가되게 한다(public invoke 와 동형).
        {
            const acquired = !registry_lock_held;
            if (acquired) {
                reg.rw_lock.lockSharedUncancelable(reg.io);
                registry_lock_held = true;
            }
            defer if (acquired) {
                registry_lock_held = false;
                reg.rw_lock.unlockShared(reg.io);
            };
            if (reg.get(name)) |backend| {
                const prev = current_invoker;
                current_invoker = backend.name;
                defer current_invoker = prev;
                const raw = backend.invoke(@ptrCast(request));
                if (raw) |r| {
                    const owned = dupeOwnedResponse(reg.allocator, r) orelse {
                        backend.freeResponse(r);
                        return @ptrCast(RESP_EMPTY);
                    };
                    backend.freeResponse(r);
                    return @ptrCast(owned);
                }
            }
        }

        // 임베드 런타임 폴백 (Node.js, 향후 Python/Lua 등)
        if (embed_runtimes_initialized) {
            if (embed_runtimes.get(name)) |rt| {
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

        return @ptrCast(RESP_EMPTY_OBJ);
    }

    /// JSON 요청에서 "cmd" 문자열 필드 추출.
    /// 라우팅 폴백 경로 — 검증된 escape/whitespace-aware 추출기(`util.extractJsonString`)
    /// 재사용: `"cmd": "x"`(콜론 뒤 공백) / `"cmd":"a\"b"`(값 내 escape된 따옴표)에서
    /// 조기 종단·오인 라우팅을 막는다(기존 단순 스캐너는 둘 다 미처리).
    fn extractCmdField(json: []const u8) ?[]const u8 {
        return util.extractJsonString(json, "cmd");
    }

    // C ABI 콜백: 이벤트 발행
    fn coreEmit(event_name: [*c]const u8, data: [*c]const u8) callconv(.c) void {
        const reg = global orelse return;
        const bus = reg.event_bus orelse return;
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(event_name)));
        const d = std.mem.span(@as([*:0]const u8, @ptrCast(data)));
        bus.emit(name, d);
    }

    // C ABI 콜백: 특정 창에만 이벤트 발행 (Electron `webContents.send`)
    fn coreEmitTo(target: u32, event_name: [*c]const u8, data: [*c]const u8) callconv(.c) void {
        const reg = global orelse return;
        const bus = reg.event_bus orelse return;
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(event_name)));
        const d = std.mem.span(@as([*:0]const u8, @ptrCast(data)));
        bus.emitTo(target, name, d);
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
            // 이미 ''로 차단된 채널은 재경고 불필요 (이전 충돌에서 처리됨).
            if (existing_ptr.*.len == 0) return;
            // 중복: 값을 빈 문자열로 덮어쓰기 (자동 라우팅 차단). target 옵션 강제.
            // 의도된 충돌 감지 — 자동 라우팅만 차단하고 명시적 target으로는 여전히 호출 가능.
            // 실제 에러가 아니므로 WARN 레벨로 찍는다.
            std.debug.print("[suji] WARN: channel '{s}' registered by multiple backends ('{s}', '{s}') — auto-routing disabled, use {{ target: \"<backend>\" }} to disambiguate\n", .{ channel, existing_ptr.*, backend });
            existing_ptr.* = "";
            return;
        }

        reg.putRoute(channel, backend) catch {};
    }

    // C ABI 콜백: 응답 메모리 해제 (coreInvoke가 복사한 Suji 소유 메모리)
    fn coreFree(ptr: [*c]const u8) callconv(.c) void {
        if (ptr == null) return;
        const reg = global orelse return;
        const c_ptr: [*:0]const u8 = @ptrCast(ptr);
        // 정적 리터럴(RESP_EMPTY/RESP_EMPTY_OBJ)은 소유권 헤더가 없어 free 불가 —
        // 포인터 동일성으로 식별한다. content 비교는 본문이 "{}"/"" 인 힙 응답까지
        // 건너뛰어 호출마다 누수시켰다.
        if (c_ptr == RESP_EMPTY or c_ptr == RESP_EMPTY_OBJ) return;
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

    const window_api = WindowApi{
        .request_json = windowApiRequestJson,
        .free_response = coreFree,
    };

    fn coreGetWindowApi() callconv(.c) ?*const WindowApi {
        _ = global orelse return null;
        _ = special_dispatch orelse return null;
        return &window_api;
    }

    fn windowApiRequestJson(request: [*c]const u8) callconv(.c) [*c]const u8 {
        const reg = global orelse return @ptrCast(RESP_EMPTY);
        const dispatch = special_dispatch orelse return @ptrCast(RESP_EMPTY_OBJ);
        if (request == null) return @ptrCast(RESP_EMPTY_OBJ);

        const req_span = std.mem.span(@as([*:0]const u8, @ptrCast(request)));
        var resp_buf: [16384]u8 = undefined;
        const out = dispatch(CHANNEL_CORE, req_span, &resp_buf) orelse return @ptrCast(RESP_EMPTY_OBJ);
        const owned = dupeOwnedResponse(reg.allocator, out) orelse return @ptrCast(RESP_EMPTY_OBJ);
        return @ptrCast(owned);
    }
};

var quit_handler: ?*const fn () void = null;
threadlocal var current_invoker: ?[]const u8 = null;
/// 이 스레드가 이미 registry 공유락을 보유 중인가 — coreInvoke 가 invoke 체인 내부
/// 재진입(이미 보유)과 외부(독립) 스레드 호출(미보유)을 구분한다. 전자는 락을
/// 재취득하지 않아 writer(reload) 대기 중 nested-shared 데드락을 피하고, 후자만
/// 공유락으로 reload(dlclose) 와의 use-after-unmap race 를 막는다.
threadlocal var registry_lock_held: bool = false;
/// 정적 응답 리터럴(소유권 헤더 없음). coreFree 가 포인터 동일성으로 식별해 free 를
/// 건너뛴다 — content 비교는 본문이 "{}"/"" 인 힙 응답까지 누수시키기 때문.
const RESP_EMPTY: [*:0]const u8 = "";
const RESP_EMPTY_OBJ: [*:0]const u8 = "{}";

fn freePermissionEntry(allocator: std.mem.Allocator, key: []const u8, permissions: []const []const u8) void {
    allocator.free(key);
    for (permissions) |permission| allocator.free(permission);
    allocator.free(permissions);
}

/// 플랫폼 문자열 상수 — loader / SDK / tests가 동일 문자열 공유.
/// 데스크톱 macOS/Linux/Windows + 모바일 iOS/Android. 그 외 OS는 컴파일 단계 에러.
pub const platform_names = struct {
    pub const macos: [:0]const u8 = "macos";
    pub const linux: [:0]const u8 = "linux";
    pub const windows: [:0]const u8 = "windows";
    pub const ios: [:0]const u8 = "ios";
    pub const android: [:0]const u8 = "android";
};

pub fn platformName() [*:0]const u8 {
    return switch (builtin.os.tag) {
        .macos => platform_names.macos,
        // Android 타깃은 os.tag=.linux + abi=.android — 데스크톱 Linux와 구분.
        .linux => if (builtin.abi == .android) platform_names.android else platform_names.linux,
        .windows => platform_names.windows,
        .ios => platform_names.ios,
        else => @compileError("Suji: unsupported OS (macos/linux/windows/ios/android)"),
    };
}
