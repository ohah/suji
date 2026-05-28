const std = @import("std");
const runtime = @import("runtime");
const lua_config = @import("lua_config");

pub const lua_enabled = lua_config.lua_enabled;

pub const RegisterRouteFn = *const fn (backend_name: []const u8, channel: []const u8) void;

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

    allocator: std.mem.Allocator,
    backend_name: [:0]const u8,
    entry_path: [:0]const u8,
    route_callback: ?RegisterRouteFn = null,
    owns_paths: bool = false,
    state: ?*c.lua_State = null,
    handlers: std.StringHashMap(c_int),
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

    pub fn start(self: *EnabledRuntime) !void {
        if (self.initialized) return;

        const L = c.luaL_newstate() orelse return error.LuaInitFailed;
        self.state = L;
        c.luaL_openlibs(L);
        self.installSujiModule(L);

        active_registration_runtime = self;
        defer active_registration_runtime = null;

        if (c.luaL_loadfile(L, self.entry_path.ptr) != 0) {
            printTopError(L, "load");
            c.lua_settop(L, 0);
            return error.LuaScriptLoadFailed;
        }
        if (c.lua_pcall(L, 0, 0, 0) != 0) {
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
        c.lua_setglobal(L, "suji");
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
        self.mutex.lockUncancelable(runtime.io);
        defer self.mutex.unlock(runtime.io);

        if (!self.initialized) return null;
        const L = self.state orelse return null;
        const ref = self.handlers.get(channel) orelse return null;

        c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, ref);
        c.lua_pushlstring(L, data.ptr, data.len);
        if (c.lua_pcall(L, 1, 1, 0) != 0) {
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

    pub fn shutdown(self: *EnabledRuntime) void {
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

    const ping = rt.invoke("ping", "{\"cmd\":\"ping\"}") orelse return error.NoLuaResponse;
    defer LuaRuntime.freeResponseC(ping);
    try std.testing.expectEqualStrings("{\"runtime\":\"lua\",\"msg\":\"pong\"}", std.mem.span(ping));

    const echo = rt.invoke("echo", "{\"cmd\":\"echo\",\"value\":\"hello\"}") orelse return error.NoLuaResponse;
    defer LuaRuntime.freeResponseC(echo);
    const echo_body = std.mem.span(echo);
    try std.testing.expect(std.mem.indexOf(u8, echo_body, "\"runtime\":\"lua\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, echo_body, "\\\"cmd\\\":\\\"echo\\\"") != null);
}
