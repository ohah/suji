const std = @import("std");
const runtime = @import("runtime");
const lua_config = @import("lua_config");

pub const lua_enabled = lua_config.lua_enabled;

pub const RegisterRouteFn = *const fn (backend_name: []const u8, channel: []const u8) void;

// 코어(BackendRegistry/EventBus) 함수 포인터 — loader.SujiCore 의 해당 필드와 ABI
// 동형. struct 전체를 복제하면 drift 위험이 있어 outbound 에 쓰는 fn 만 개별로
// 받는다(node bridge 가 SujiNodeCore 로 래핑하는 것과 동일 취지).
pub const CoreInvokeFn = *const fn ([*c]const u8, [*c]const u8) callconv(.c) [*c]const u8;
pub const CoreFreeFn = *const fn ([*c]const u8) callconv(.c) void;
pub const CoreEmitFn = *const fn ([*c]const u8, [*c]const u8) callconv(.c) void;
pub const CoreEventCallback = *const fn ([*c]const u8, [*c]const u8, ?*anyopaque) callconv(.c) void;
pub const CoreOnFn = *const fn ([*c]const u8, ?CoreEventCallback, ?*anyopaque) callconv(.c) u64;
pub const CoreOffFn = *const fn (u64) callconv(.c) void;

pub const LuaRuntime = if (lua_enabled) EnabledRuntime else DisabledRuntime;

const DisabledRuntime = struct {
    allocator: std.mem.Allocator,
    backend_name: [:0]const u8,
    entry_path: [:0]const u8,
    route_callback: ?RegisterRouteFn = null,
    owns_paths: bool = false,
    initialized: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        backend_name: [:0]const u8,
        entry_path: [:0]const u8,
        route_callback: ?RegisterRouteFn,
        owns_paths: bool,
    ) DisabledRuntime {
        return .{
            .allocator = allocator,
            .backend_name = backend_name,
            .entry_path = entry_path,
            .route_callback = route_callback,
            .owns_paths = owns_paths,
        };
    }

    pub fn start(_: *DisabledRuntime) !void {
        return error.LuaNotAvailable;
    }

    pub fn invoke(_: *DisabledRuntime, _: []const u8, _: []const u8) ?[*:0]const u8 {
        return null;
    }

    pub fn shutdown(self: *DisabledRuntime) void {
        if (self.owns_paths) {
            if (self.entry_path.len > 0) self.allocator.free(self.entry_path);
            if (self.backend_name.len > 0) self.allocator.free(self.backend_name);
        }
        self.entry_path = "";
        self.backend_name = "";
        self.initialized = false;
    }

    pub fn setCore(_: CoreInvokeFn, _: CoreFreeFn, _: CoreEmitFn, _: CoreOnFn, _: CoreOffFn) void {}

    pub fn invokeC(_: [*:0]const u8, _: [*:0]const u8) callconv(.c) ?[*:0]const u8 {
        return null;
    }

    pub fn freeResponseC(_: [*:0]const u8) callconv(.c) void {}
};

const EnabledRuntime = struct {
    const c = @cImport({
        @cInclude("lua.h");
        @cInclude("lauxlib.h");
        @cInclude("lualib.h");
    });

    // lua-cjson 진입점 — 공개 헤더가 없어 직접 extern 선언(vendor/cjson 정적 링크).
    extern fn luaopen_cjson(L: ?*c.lua_State) callconv(.c) c_int;

    // suji.on 으로 등록된 이벤트 리스너. EventBus 가 C 콜백을 호출할 때 arg 로 이
    // 포인터를 받아 어느 Lua 함수(registry ref)를 부를지 식별. shutdown 에서 정리.
    const LuaListener = struct {
        rt: *EnabledRuntime,
        ref: c_int,
        id: u64 = 0,
    };

    // 재진입 인지 mutex 가드 — 같은 스레드 재진입(cross-call 체인 / invoke 중
    // send→on 콜백)은 lock 을 다시 잡지 않는다(데드락 회피). invoke/dispatchEvent 공용.
    const ReentrantGuard = struct {
        rt: *EnabledRuntime,
        reentrant: bool,
        fn acquire(rt: *EnabledRuntime) ReentrantGuard {
            const reentrant = lua_call_depth > 0;
            if (!reentrant) rt.mutex.lockUncancelable(runtime.io);
            lua_call_depth += 1;
            return .{ .rt = rt, .reentrant = reentrant };
        }
        fn release(self: ReentrantGuard) void {
            lua_call_depth -= 1;
            if (!self.reentrant) self.rt.mutex.unlock(runtime.io);
        }
    };

    allocator: std.mem.Allocator,
    backend_name: [:0]const u8,
    entry_path: [:0]const u8,
    route_callback: ?RegisterRouteFn = null,
    owns_paths: bool = false,
    state: ?*c.lua_State = null,
    handlers: std.StringHashMap(c_int),
    event_listeners: std.ArrayList(*LuaListener) = .empty,
    mutex: std.Io.Mutex = .init,
    initialized: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        backend_name: [:0]const u8,
        entry_path: [:0]const u8,
        route_callback: ?RegisterRouteFn,
        owns_paths: bool,
    ) EnabledRuntime {
        return .{
            .allocator = allocator,
            .backend_name = backend_name,
            .entry_path = entry_path,
            .route_callback = route_callback,
            .owns_paths = owns_paths,
            .handlers = std.StringHashMap(c_int).init(allocator),
        };
    }

    pub fn setCore(invoke_fn: CoreInvokeFn, free_fn: CoreFreeFn, emit_fn: CoreEmitFn, on_fn: CoreOnFn, off_fn: CoreOffFn) void {
        g_core_invoke = invoke_fn;
        g_core_free = free_fn;
        g_core_emit = emit_fn;
        g_core_on = on_fn;
        g_core_off = off_fn;
    }

    pub fn start(self: *EnabledRuntime) !void {
        if (self.initialized) return;

        const L = c.luaL_newstate() orelse return error.LuaInitFailed;
        self.state = L;
        c.luaL_openlibs(L);
        self.installSujiModule(L);

        active_registration_runtime = self;
        defer active_registration_runtime = null;

        // luaL_loadfile 은 PUC Lua 매크로(NULL mode) — translate-c 가 NULL 을
        // ?*anyopaque 로 추론해 깨지므로 함수형 luaL_loadfilex 를 직접 호출.
        if (c.luaL_loadfilex(L, self.entry_path.ptr, null) != 0) {
            printTopError(L, "load");
            c.lua_settop(L, 0);
            return error.LuaScriptLoadFailed;
        }
        // lua_pcall 은 PUC Lua 매크로(continuation NULL) — lua_pcallk 직접 호출.
        if (c.lua_pcallk(L, 0, 0, 0, 0, null) != 0) {
            printTopError(L, "run");
            c.lua_settop(L, 0);
            return error.LuaScriptRunFailed;
        }

        self.initialized = true;
        g_lua_runtime = self;
        std.debug.print("[suji-lua] started: {s}\n", .{self.entry_path});
    }

    fn installSujiModule(_: *EnabledRuntime, L: *c.lua_State) void {
        c.lua_newtable(L);
        c.lua_pushcclosure(L, &handleRegistration, 0);
        c.lua_setfield(L, -2, "handle");
        // outbound API (node 와 동등): invoke(cross-call) / send(이벤트 발신) /
        // on(이벤트 수신). 코어 함수 포인터는 setCore 로 주입됨.
        c.lua_pushcclosure(L, &luaInvoke, 0);
        c.lua_setfield(L, -2, "invoke");
        c.lua_pushcclosure(L, &luaSend, 0);
        c.lua_setfield(L, -2, "send");
        c.lua_pushcclosure(L, &luaOn, 0);
        c.lua_setfield(L, -2, "on");
        c.lua_setglobal(L, "suji");

        // require("cjson") 노출 — package.loaded["cjson"] 에 등록(glb=0, 전역
        // 오염 없음). vendor/cjson 정적 링크된 luaopen_cjson 사용.
        c.luaL_requiref(L, "cjson", @ptrCast(&luaopen_cjson), 0);
        c.lua_settop(L, 0);
    }

    fn handleRegistration(L: ?*c.lua_State) callconv(.c) c_int {
        const state = L orelse return 0;
        const self = active_registration_runtime orelse g_lua_runtime orelse return 0;

        var channel_len: usize = 0;
        const channel_ptr = c.lua_tolstring(state, 1, &channel_len) orelse return 0;
        if (c.lua_type(state, 2) != c.LUA_TFUNCTION) return 0;

        const channel = channel_ptr[0..channel_len];
        c.lua_pushvalue(state, 2);
        const ref = c.luaL_ref(state, c.LUA_REGISTRYINDEX);

        if (self.handlers.getPtr(channel)) |old_ref| {
            c.luaL_unref(state, c.LUA_REGISTRYINDEX, old_ref.*);
            old_ref.* = ref;
        } else {
            const owned = self.allocator.dupe(u8, channel) catch {
                c.luaL_unref(state, c.LUA_REGISTRYINDEX, ref);
                return 0;
            };
            self.handlers.put(owned, ref) catch {
                self.allocator.free(owned);
                c.luaL_unref(state, c.LUA_REGISTRYINDEX, ref);
                return 0;
            };
        }

        if (self.route_callback) |cb| cb(self.backend_name, channel);
        return 0;
    }

    pub fn invoke(self: *EnabledRuntime, channel: []const u8, data: []const u8) ?[*:0]const u8 {
        const guard = ReentrantGuard.acquire(self);
        defer guard.release();

        if (!self.initialized) return null;
        const L = self.state orelse return null;
        const ref = self.handlers.get(channel) orelse return null;

        // PUC Lua 5.3+ 는 lua_rawgeti/lua_pushlstring 가 값을 반환(LuaJIT 5.1 은
        // void). 푸시 부수효과만 쓰므로 반환값은 discard.
        _ = c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, ref);
        _ = c.lua_pushlstring(L, data.ptr, data.len);
        if (c.lua_pcallk(L, 1, 1, 0, 0, null) != 0) {
            printTopError(L, "handler");
            c.lua_settop(L, 0);
            return self.dupeResponse("{\"error\":\"lua handler failed\"}");
        }

        var out_len: usize = 0;
        const out_ptr = c.lua_tolstring(L, -1, &out_len) orelse {
            c.lua_settop(L, 0);
            return self.dupeResponse("{\"error\":\"lua handler returned non-string\"}");
        };
        const out = self.allocator.dupeZ(u8, out_ptr[0..out_len]) catch {
            c.lua_settop(L, 0);
            return null;
        };
        c.lua_settop(L, 0);
        return out.ptr;
    }

    fn dupeResponse(self: *EnabledRuntime, body: []const u8) ?[*:0]const u8 {
        const out = self.allocator.dupeZ(u8, body) catch return null;
        return out.ptr;
    }

    fn pushStr(L: *c.lua_State, s: []const u8) void {
        _ = c.lua_pushlstring(L, s.ptr, s.len);
    }

    // suji.invoke(target, request_json) -> response_json — 다른 백엔드 동기 호출.
    // coreInvoke 가 같은 스레드에서 동기 실행되므로 cross-call 체인은 lua_call_depth
    // 로 mutex 재진입이 안전하다. 응답은 coreFree 로 반납(정적 "{}"는 가드됨).
    fn luaInvoke(L: ?*c.lua_State) callconv(.c) c_int {
        const state = L orelse return 0;
        const invoke_fn = g_core_invoke orelse {
            pushStr(state, "{\"error\":\"core not connected\"}");
            return 1;
        };
        const target_ptr = c.lua_tolstring(state, 1, null) orelse {
            pushStr(state, "{\"error\":\"invoke: target must be a string\"}");
            return 1;
        };
        const req_ptr = c.lua_tolstring(state, 2, null) orelse {
            pushStr(state, "{\"error\":\"invoke: request must be a string\"}");
            return 1;
        };
        const resp = invoke_fn(target_ptr, req_ptr);
        if (resp != null) {
            const span = std.mem.span(@as([*:0]const u8, @ptrCast(resp)));
            pushStr(state, span);
            if (g_core_free) |ff| ff(resp);
        } else {
            pushStr(state, "{}");
        }
        return 1;
    }

    // suji.send(channel, data) — 이벤트 발신(EventBus 자체 mutex, lua_State 미접근).
    fn luaSend(L: ?*c.lua_State) callconv(.c) c_int {
        const state = L orelse return 0;
        const emit_fn = g_core_emit orelse return 0;
        const ch_ptr = c.lua_tolstring(state, 1, null) orelse return 0;
        const data_ptr = c.lua_tolstring(state, 2, null) orelse return 0;
        emit_fn(ch_ptr, data_ptr);
        return 0;
    }

    // suji.on(channel, fn) -> listener_id — 이벤트 수신. Lua 콜백을 registry ref 로
    // 저장하고 LuaListener 포인터를 EventBus arg 로 넘긴다.
    fn luaOn(L: ?*c.lua_State) callconv(.c) c_int {
        const state = L orelse return 0;
        const self = active_registration_runtime orelse g_lua_runtime orelse return 0;
        const on_fn = g_core_on orelse return 0;
        const ch_ptr = c.lua_tolstring(state, 1, null) orelse return 0;
        if (c.lua_type(state, 2) != c.LUA_TFUNCTION) return 0;

        c.lua_pushvalue(state, 2);
        const ref = c.luaL_ref(state, c.LUA_REGISTRYINDEX);
        const listener = self.allocator.create(LuaListener) catch {
            c.luaL_unref(state, c.LUA_REGISTRYINDEX, ref);
            return 0;
        };
        listener.* = .{ .rt = self, .ref = ref };
        self.event_listeners.append(self.allocator, listener) catch {
            c.luaL_unref(state, c.LUA_REGISTRYINDEX, ref);
            self.allocator.destroy(listener);
            return 0;
        };
        listener.id = on_fn(ch_ptr, luaEventCallback, listener);
        _ = c.lua_pushinteger(state, @intCast(listener.id));
        return 1;
    }

    // EventBus 가 emit 한 스레드에서 호출. arg=*LuaListener. mutex(재진입 인지)로
    // lua_State 접근을 직렬화한 뒤 등록된 Lua 콜백을 data 인자로 호출(응답 없음).
    fn luaEventCallback(_: [*c]const u8, data: [*c]const u8, arg: ?*anyopaque) callconv(.c) void {
        const listener: *LuaListener = @ptrCast(@alignCast(arg orelse return));
        const d = std.mem.span(@as([*:0]const u8, @ptrCast(data)));
        listener.rt.dispatchEvent(listener.ref, d);
    }

    fn dispatchEvent(self: *EnabledRuntime, ref: c_int, data: []const u8) void {
        const guard = ReentrantGuard.acquire(self);
        defer guard.release();

        if (!self.initialized) return;
        const L = self.state orelse return;
        _ = c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, ref);
        _ = c.lua_pushlstring(L, data.ptr, data.len);
        if (c.lua_pcallk(L, 1, 0, 0, 0, null) != 0) {
            printTopError(L, "event");
            c.lua_settop(L, 0);
        }
    }

    pub fn shutdown(self: *EnabledRuntime) void {
        // 이벤트 리스너 정리: off 가 EventBus 에서 제거 + 진행 중 emit 콜백
        // quiescence 까지 보장(off-quiescence)하므로, 반환 후 ref unref/destroy 가
        // in-flight snapshot 과 경합하지 않는다 — 멀티스레드 teardown UAF 해소
        // (events.zig EventBus.off 의 waitQuiescent).
        for (self.event_listeners.items) |listener| {
            if (g_core_off) |off| off(listener.id);
            if (self.state) |L| c.luaL_unref(L, c.LUA_REGISTRYINDEX, listener.ref);
            self.allocator.destroy(listener);
        }
        self.event_listeners.deinit(self.allocator);

        if (self.state) |L| {
            var it = self.handlers.iterator();
            while (it.next()) |entry| {
                c.luaL_unref(L, c.LUA_REGISTRYINDEX, entry.value_ptr.*);
                self.allocator.free(entry.key_ptr.*);
            }
            self.handlers.deinit();
            c.lua_close(L);
            self.state = null;
        } else {
            var it = self.handlers.iterator();
            while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
            self.handlers.deinit();
        }

        if (g_lua_runtime == self) g_lua_runtime = null;
        if (active_registration_runtime == self) active_registration_runtime = null;
        if (self.owns_paths) {
            if (self.entry_path.len > 0) self.allocator.free(self.entry_path);
            if (self.backend_name.len > 0) self.allocator.free(self.backend_name);
        }
        self.entry_path = "";
        self.backend_name = "";
        self.initialized = false;
    }

    pub fn invokeC(channel: [*:0]const u8, data: [*:0]const u8) callconv(.c) ?[*:0]const u8 {
        const rt = g_lua_runtime orelse return null;
        return rt.invoke(std.mem.span(channel), std.mem.span(data));
    }

    pub fn freeResponseC(ptr: [*:0]const u8) callconv(.c) void {
        const rt = g_lua_runtime orelse return;
        const body = std.mem.span(ptr);
        const mutable: [*:0]u8 = @constCast(ptr);
        rt.allocator.free(mutable[0..body.len :0]);
    }

    fn printTopError(L: *c.lua_State, phase: []const u8) void {
        var len: usize = 0;
        const ptr = c.lua_tolstring(L, -1, &len);
        if (ptr) |p| {
            std.debug.print("[suji-lua] {s} error: {s}\n", .{ phase, p[0..len] });
        } else {
            std.debug.print("[suji-lua] {s} error\n", .{phase});
        }
    }
};

var g_lua_runtime: ?*LuaRuntime = null;
var active_registration_runtime: ?*LuaRuntime = null;

// 코어 함수 포인터(startLua 가 setCore 로 주입). outbound invoke/send/on 에 사용.
var g_core_invoke: ?CoreInvokeFn = null;
var g_core_free: ?CoreFreeFn = null;
var g_core_emit: ?CoreEmitFn = null;
var g_core_on: ?CoreOnFn = null;
var g_core_off: ?CoreOffFn = null;

// 같은 스레드 재진입 깊이. cross-call 체인(lua→zig→lua)이나 invoke 중 send→on
// 콜백은 동일 스레드에서 lua_State 에 재진입하므로 mutex 를 다시 잡으면 데드락.
// depth>0 이면 lock 을 건너뛴다(node 의 g_in_sync_invoke 와 동형 — V8 Locker 가
// 없어 더 단순). 다른 스레드는 depth==0 이라 정상 lock(직렬화).
threadlocal var lua_call_depth: u32 = 0;

test "LuaRuntime executes example raw JSON handler when enabled" {
    if (!lua_enabled) return error.SkipZigTest;

    runtime.io = std.testing.io;
    runtime.gpa = std.testing.allocator;

    const name = try std.testing.allocator.dupeZ(u8, "lua");
    errdefer std.testing.allocator.free(name);
    const entry = try std.testing.allocator.dupeZ(u8, "examples/lua-backend/backends/lua/main.lua");
    errdefer std.testing.allocator.free(entry);

    var rt = LuaRuntime.init(std.testing.allocator, name, entry, null, true);
    defer rt.shutdown();
    try rt.start();

    // cjson.encode 는 키 순서를 보장하지 않으므로 substring 으로 단언한다.
    const ping = rt.invoke("ping", "{\"cmd\":\"ping\"}") orelse return error.NoLuaResponse;
    defer LuaRuntime.freeResponseC(ping);
    const ping_body = std.mem.span(ping);
    try std.testing.expect(std.mem.indexOf(u8, ping_body, "\"runtime\":\"lua\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ping_body, "\"msg\":\"pong\"") != null);

    const echo = rt.invoke("echo", "{\"cmd\":\"echo\",\"value\":\"hello\"}") orelse return error.NoLuaResponse;
    defer LuaRuntime.freeResponseC(echo);
    const echo_body = std.mem.span(echo);
    try std.testing.expect(std.mem.indexOf(u8, echo_body, "\"runtime\":\"lua\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, echo_body, "\"cmd\":\"echo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, echo_body, "\"value\":\"hello\"") != null);
}
