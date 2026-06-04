const std = @import("std");
const lua = @import("lua");

test "lua_enabled is compile-time constant and disabled in default tests" {
    const enabled = lua.lua_enabled;
    comptime {
        _ = @as(bool, enabled);
    }
    try std.testing.expect(!enabled);
}

test "LuaRuntime init preserves backend name and entry path" {
    const rt = lua.LuaRuntime.init(std.testing.allocator, "lua", "backends/lua/main.lua", null, false);
    try std.testing.expectEqualStrings("lua", rt.backend_name);
    try std.testing.expectEqualStrings("backends/lua/main.lua", rt.entry_path);
    try std.testing.expect(!rt.initialized);
}

test "LuaRuntime disabled start reports LuaNotAvailable" {
    var rt = lua.LuaRuntime.init(std.testing.allocator, "lua", "main.lua", null, false);
    try std.testing.expectError(error.LuaNotAvailable, rt.start());
}

test "LuaRuntime shutdown frees owned paths without leak" {
    const name = try std.testing.allocator.dupeZ(u8, "lua");
    const entry = try std.testing.allocator.dupeZ(u8, "/tmp/suji-lua/main.lua");
    var rt = lua.LuaRuntime.init(std.testing.allocator, name, entry, null, true);
    rt.shutdown();
    try std.testing.expectEqualStrings("", rt.backend_name);
    try std.testing.expectEqualStrings("", rt.entry_path);
}

test "main.zig wires Lua backend load, routes, CEF fallback, and teardown" {
    // Lua backend load/start/route registration moved to
    // src/core/backend_lifecycle.zig; the CEF __core__ dispatch fallback +
    // teardown still live in main.zig. Read both so the wiring guard tracks
    // the split.
    const a = std.testing.allocator;
    const lifecycle = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/core/backend_lifecycle.zig",
        a,
        .limited(2 * 1024 * 1024),
    );
    defer a.free(lifecycle);
    const main_src = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/main.zig",
        a,
        .limited(2 * 1024 * 1024),
    );
    defer a.free(main_src);

    var combined = std.ArrayList(u8).empty;
    defer combined.deinit(a);
    try combined.appendSlice(a, lifecycle);
    try combined.append(a, '\n');
    try combined.appendSlice(a, main_src);
    const source = combined.items;

    inline for (.{
        "@import(\"../platform/lua.zig\")",
        "pub var g_lua_runtime: ?*LuaRuntime = null;",
        "pub fn startLua(",
        "pub fn registerLuaRoute(",
        "std.mem.eql(u8, be.lang, \"lua\")",
        "suji.BackendRegistry.registerEmbedRuntime(owned_name",
        "rt.invoke(lua_channel, data)",
        "LuaRuntime.freeResponseC(resp)",
        "rt.shutdown();",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, source, needle) != null);
    }
}

test "build.zig keeps Lua opt-in and default tests stubbed" {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "build.zig",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(source);

    inline for (.{
        "b.option(bool, \"lua\"",
        "lua_options.addOption(bool, \"lua_enabled\", lua_enabled)",
        "root_module.addImport(\"lua_config\"",
        "root_module.linkLibrary(lua_lib)",
        "lua_test_opts.addOption(bool, \"lua_enabled\", false)",
        "src/platform/lua.zig",
        "tests/lua_test.zig",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, source, needle) != null);
    }
}

test "schema and docs advertise Lua backend shape" {
    const schema = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "suji.schema.json",
        std.testing.allocator,
        .limited(256 * 1024),
    );
    defer std.testing.allocator.free(schema);
    try std.testing.expect(std.mem.indexOf(u8, schema, "\"enum\": [\"zig\", \"rust\", \"go\", \"node\", \"lua\"]") != null);

    const plan = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "docs/PLAN.md",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(plan);
    try std.testing.expect(std.mem.indexOf(u8, plan, "Lua 임베드") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan, "suji.handle") != null);
}
