//! 백엔드 라이프사이클 — config 의 backends[]/backend 를 packaged dylib 또는
//! 빌드 결과물로 BackendRegistry 에 로드한다. Node/Lua 는 별도 임베드 런타임
//! (libnode/LuaJIT) 으로 진입해 EmbedRuntime 테이블에 등록한다.
//!
//! 전역 g_node_runtime / g_lua_runtime 은 dev 모드 정리(아직 main.zig) 가
//! 참조하므로 pub 로 노출한다. 마이그레이션이 끝나면 cli/dev.zig 로 정리.

const std = @import("std");
const runtime = @import("runtime");
const util = @import("util");
const suji = @import("../root.zig");
const embed = @import("../embed.zig");
const backend_build = @import("backend_build.zig");
const packaged_paths = @import("packaged_paths.zig");

const node_mod = @import("../platform/node.zig");
const NodeRuntime = node_mod.NodeRuntime;
const node_enabled = node_mod.node_enabled;
const lua_mod = @import("../platform/lua.zig");
const LuaRuntime = lua_mod.LuaRuntime;
const lua_enabled = lua_mod.lua_enabled;

/// Embedded 런타임 글로벌 참조 (dev 모드에서 정리용)
pub var g_node_runtime: ?*NodeRuntime = null;
pub var g_lua_runtime: ?*LuaRuntime = null;

pub fn embeddedSourceDir(lang: []const u8, entry: []const u8) []const u8 {
    if (std.mem.eql(u8, lang, "lua") and std.mem.endsWith(u8, entry, ".lua")) {
        return std.fs.path.dirname(entry) orelse ".";
    }
    return entry;
}

pub fn loadFromConfig(allocator: std.mem.Allocator, config: *const suji.Config, registry: *suji.BackendRegistry, release: bool) !void {
    // packaged 환경: build 스킵 + packaged dylib 경로에서 직접 로드.
    if (packaged_paths.exeDir(allocator)) |exe_dir| {
        defer allocator.free(exe_dir);
        if (config.isMultiBackend()) {
            if (config.backends) |backends| {
                for (backends) |be| {
                    std.debug.print("[suji] loading {s} ({s}) packaged...\n", .{ be.name, be.lang });
                    if (std.mem.eql(u8, be.lang, "node")) {
                        const node_dir = std.fmt.allocPrintSentinel(allocator, "{s}/backends/{s}", .{ exe_dir, be.name }, 0) catch continue;
                        defer allocator.free(node_dir);
                        startNode(allocator, node_dir) catch |err| {
                            std.debug.print("[suji] node start failed for {s}: {}\n", .{ be.name, err });
                        };
                        continue;
                    }
                    if (std.mem.eql(u8, be.lang, "lua")) {
                        const lua_dir = std.fmt.allocPrintSentinel(allocator, "{s}/backends/{s}", .{ exe_dir, be.name }, 0) catch continue;
                        defer allocator.free(lua_dir);
                        startLua(allocator, be.name, lua_dir) catch |err| {
                            std.debug.print("[suji] lua start failed for {s}: {}\n", .{ be.name, err });
                        };
                        continue;
                    }
                    const dylib = (packaged_paths.backendDylibPath(allocator, exe_dir, be.name, be.lang) catch continue) orelse continue;
                    defer allocator.free(dylib);
                    var path_z: [1024]u8 = undefined;
                    const path_zt = util.nullTerminate(dylib, &path_z);
                    registry.register(be.name, path_zt) catch |err| {
                        std.debug.print("[suji] load failed for {s}: {}\n", .{ be.name, err });
                    };
                }
            }
        } else if (config.backend) |be| {
            if (std.mem.eql(u8, be.lang, "node")) {
                const node_dir = std.fmt.allocPrintSentinel(allocator, "{s}/backends/{s}", .{ exe_dir, be.lang }, 0) catch return;
                defer allocator.free(node_dir);
                startNode(allocator, node_dir) catch |err| {
                    std.debug.print("[suji] node start failed: {}\n", .{err});
                };
                return;
            }
            if (std.mem.eql(u8, be.lang, "lua")) {
                const lua_dir = std.fmt.allocPrintSentinel(allocator, "{s}/backends/{s}", .{ exe_dir, be.lang }, 0) catch return;
                defer allocator.free(lua_dir);
                startLua(allocator, be.lang, lua_dir) catch |err| {
                    std.debug.print("[suji] lua start failed: {}\n", .{err});
                };
                return;
            }
            const dylib = (try packaged_paths.backendDylibPath(allocator, exe_dir, be.lang, be.lang)) orelse return;
            defer allocator.free(dylib);
            var path_z: [1024]u8 = undefined;
            const path_zt = util.nullTerminate(dylib, &path_z);
            registry.register(be.lang, path_zt) catch |err| {
                std.debug.print("[suji] load failed: {}\n", .{err});
            };
        }
        return;
    }

    if (config.isMultiBackend()) {
        if (config.backends) |backends| {
            for (backends) |be| {
                std.debug.print("[suji] building {s} ({s})...\n", .{ be.name, be.lang });
                backend_build.buildByLang(allocator, be.lang, be.entry, release) catch |err| {
                    std.debug.print("[suji] build failed: {}\n", .{err});
                    continue;
                };

                if (std.mem.eql(u8, be.lang, "node")) {
                    // Node 백엔드: libnode로 JS 실행
                    startNode(allocator, be.entry) catch |err| {
                        std.debug.print("[suji] node start failed for {s}: {}\n", .{ be.name, err });
                    };
                    continue;
                }
                if (std.mem.eql(u8, be.lang, "lua")) {
                    startLua(allocator, be.name, be.entry) catch |err| {
                        std.debug.print("[suji] lua start failed for {s}: {}\n", .{ be.name, err });
                    };
                    continue;
                }

                const path = backend_build.dylibPath(allocator, be.lang, be.entry, release) catch continue;
                defer allocator.free(path);
                var path_z: [1024]u8 = undefined;
                const path_zt = util.nullTerminate(path, &path_z);
                registry.register(be.name, path_zt) catch |err| {
                    std.debug.print("[suji] load failed for {s}: {}\n", .{ be.name, err });
                };
            }
        }
    } else if (config.backend) |be| {
        std.debug.print("[suji] building {s} backend...\n", .{be.lang});
        backend_build.buildByLang(allocator, be.lang, be.entry, release) catch |err| {
            std.debug.print("[suji] build failed: {}\n", .{err});
            return;
        };

        if (std.mem.eql(u8, be.lang, "node")) {
            startNode(allocator, be.entry) catch |err| {
                std.debug.print("[suji] node start failed: {}\n", .{err});
            };
            return;
        }
        if (std.mem.eql(u8, be.lang, "lua")) {
            startLua(allocator, be.lang, be.entry) catch |err| {
                std.debug.print("[suji] lua start failed: {}\n", .{err});
            };
            return;
        }

        const path = backend_build.dylibPath(allocator, be.lang, be.entry, release) catch return;
        defer allocator.free(path);
        var path_z: [1024]u8 = undefined;
        const path_zt = util.nullTerminate(path, &path_z);
        registry.register(be.lang, path_zt) catch |err| {
            std.debug.print("[suji] load failed: {}\n", .{err});
        };
    }
}

pub fn startNode(allocator: std.mem.Allocator, entry: [:0]const u8) !void {
    if (!node_enabled) {
        std.debug.print("[suji] Node.js backend not available (libnode not installed)\n", .{});
        return;
    }
    // entry 경로를 절대 경로로 변환 (createRequire가 절대 경로 필요)
    const abs_entry = try std.Io.Dir.cwd().realPathFileAlloc(runtime.io, entry, allocator);
    defer allocator.free(abs_entry);
    const entry_js_str = try std.fmt.allocPrint(allocator, "{s}/main.js", .{abs_entry});
    defer allocator.free(entry_js_str);
    const entry_js = try allocator.dupeZ(u8, entry_js_str);
    // entry_js는 NodeRuntime이 소유 (해제하지 않음)

    const rt = try allocator.create(NodeRuntime);
    errdefer allocator.destroy(rt);
    rt.* = NodeRuntime.init(allocator, entry_js);

    // SujiCore 연결은 rt.start() 이전. start()가 main.js를 즉시 실행하는데,
    // main.js의 top-level `suji.on(...)`/`suji.quit()` 호출 시점에 core가 없으면
    // bridge가 exception 던짐 ("core not connected").
    if (suji.BackendRegistry.global) |g| {
        NodeRuntime.setCore(&g.core_api);
    }

    try rt.start();
    g_node_runtime = rt;

    // 임베드 런타임 테이블에 Node.js 등록. 다른 백엔드가 core.invoke("node", ...)로
    // 들어오면 BackendRegistry.coreInvoke가 이 테이블로 폴백한다.
    if (node_enabled) {
        suji.BackendRegistry.registerEmbedRuntime("node", .{
            .invoke = node_mod.bridge.suji_node_invoke,
            .free_response = node_mod.bridge.suji_node_free,
        }) catch |err| {
            std.debug.print("[suji] node embed registration failed: {}\n", .{err});
        };
    }
}

pub fn luaEntryCandidate(allocator: std.mem.Allocator, entry_arg: []const u8) ![]u8 {
    if (entry_arg.len == 0) return error.InvalidLuaEntry;
    if (std.mem.endsWith(u8, entry_arg, ".lua")) {
        return allocator.dupe(u8, entry_arg);
    }
    return std.fs.path.join(allocator, &.{ entry_arg, "main.lua" });
}

pub fn registerLuaRoute(backend_name: []const u8, channel: []const u8) void {
    const g = suji.BackendRegistry.global orelse return;
    if (g.routes.getPtr(channel)) |existing_ptr| {
        if (std.mem.eql(u8, existing_ptr.*, backend_name)) return;
        if (existing_ptr.*.len == 0) return;
        std.debug.print("[suji] WARN: channel '{s}' registered by multiple backends ('{s}', '{s}') — auto-routing disabled, use {{ target: \"<backend>\" }} to disambiguate\n", .{ channel, existing_ptr.*, backend_name });
        existing_ptr.* = "";
        return;
    }
    g.putRoute(channel, backend_name) catch |err| {
        std.debug.print("[suji] lua route registration failed for '{s}': {}\n", .{ channel, err });
    };
}

pub fn startLua(allocator: std.mem.Allocator, backend_name: [:0]const u8, entry: [:0]const u8) !void {
    if (!lua_enabled) {
        std.debug.print("[suji] Lua backend not available (rebuild Suji with -Dlua and LuaJIT installed)\n", .{});
        return;
    }

    const candidate = try luaEntryCandidate(allocator, entry);
    defer allocator.free(candidate);
    const abs_entry = try std.Io.Dir.cwd().realPathFileAlloc(runtime.io, candidate, allocator);
    defer allocator.free(abs_entry);

    const entry_lua = try allocator.dupeZ(u8, abs_entry);
    errdefer allocator.free(entry_lua);
    const owned_name = try allocator.dupeZ(u8, backend_name);
    errdefer allocator.free(owned_name);

    const rt = try allocator.create(LuaRuntime);
    errdefer allocator.destroy(rt);
    rt.* = LuaRuntime.init(allocator, owned_name, entry_lua, &registerLuaRoute, true);
    errdefer rt.shutdown();

    try rt.start();
    g_lua_runtime = rt;

    suji.BackendRegistry.registerEmbedRuntime(owned_name, .{
        .invoke = LuaRuntime.invokeC,
        .free_response = LuaRuntime.freeResponseC,
    }) catch |err| {
        std.debug.print("[suji] lua embed registration failed for {s}: {}\n", .{ owned_name, err });
    };
}

pub fn nodeRunEntryCandidate(allocator: std.mem.Allocator, entry_arg: []const u8) ![]u8 {
    if (entry_arg.len == 0) return error.InvalidNodeEntry;
    if (std.mem.endsWith(u8, entry_arg, ".js")) {
        return allocator.dupe(u8, entry_arg);
    }
    return std.fs.path.join(allocator, &.{ entry_arg, "main.js" });
}

pub fn standaloneNodeQuit() void {
    if (node_enabled) {
        node_mod.bridge.suji_node_stop();
    }
}

pub fn runNodeScript(allocator: std.mem.Allocator, entry_arg: []const u8) !void {
    if (!node_enabled) {
        std.debug.print("[suji-node] libnode not available. Install the Suji libnode runtime first.\n", .{});
        return;
    }

    const candidate = nodeRunEntryCandidate(allocator, entry_arg) catch {
        std.debug.print("Usage: suji run <main.js|dir>\n", .{});
        return;
    };
    defer allocator.free(candidate);

    const abs_entry = std.Io.Dir.cwd().realPathFileAlloc(runtime.io, candidate, allocator) catch |err| {
        std.debug.print("[suji-node] entry not found: {s} ({s})\n", .{ candidate, @errorName(err) });
        return;
    };
    defer allocator.free(abs_entry);

    const entry_z = allocator.dupeZ(u8, abs_entry) catch return error.OutOfMemory;
    defer allocator.free(entry_z);

    try embed.init(allocator, runtime.io);
    defer embed.deinit();
    const registry = embed.registry();
    registry.setQuitHandler(&standaloneNodeQuit);
    NodeRuntime.setCore(&registry.core_api);

    const argv = [_][*c]u8{@constCast("suji-node")};
    if (node_mod.bridge.suji_node_init(1, @constCast(&argv)) != 0) {
        return error.NodeInitFailed;
    }
    // One-shot CLI process: after suji_node_run returns the process is exiting, so
    // avoid full V8 platform teardown here. Some libnode builds abort during
    // TearDownOncePerProcess after an embedded process.exit/quit path.
    defer node_mod.bridge.suji_node_stop();

    std.debug.print("[suji-node] run: {s}\n", .{abs_entry});
    if (node_mod.bridge.suji_node_run(entry_z.ptr) != 0) {
        return error.NodeRunFailed;
    }
}

test "nodeRunEntryCandidate resolves file and directory forms" {
    const allocator = std.testing.allocator;

    const file = try nodeRunEntryCandidate(allocator, "main.js");
    defer allocator.free(file);
    try std.testing.expectEqualStrings("main.js", file);

    const dir = try nodeRunEntryCandidate(allocator, "backends/node");
    defer allocator.free(dir);
    try std.testing.expect(std.mem.endsWith(u8, dir, "main.js"));
    try std.testing.expect(std.mem.indexOf(u8, dir, "backends") != null);
    try std.testing.expect(std.mem.indexOf(u8, dir, "node") != null);

    try std.testing.expectError(error.InvalidNodeEntry, nodeRunEntryCandidate(allocator, ""));
}

test "luaEntryCandidate resolves file and directory forms" {
    const allocator = std.testing.allocator;

    const file = try luaEntryCandidate(allocator, "main.lua");
    defer allocator.free(file);
    try std.testing.expectEqualStrings("main.lua", file);

    const dir = try luaEntryCandidate(allocator, "backends/lua");
    defer allocator.free(dir);
    try std.testing.expect(std.mem.endsWith(u8, dir, "main.lua"));
    try std.testing.expect(std.mem.indexOf(u8, dir, "backends") != null);
    try std.testing.expect(std.mem.indexOf(u8, dir, "lua") != null);

    try std.testing.expectError(error.InvalidLuaEntry, luaEntryCandidate(allocator, ""));
}
