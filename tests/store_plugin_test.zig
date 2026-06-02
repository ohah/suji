const std = @import("std");
const builtin = @import("builtin");
const loader = @import("loader");

const PLUGIN_PATH = switch (builtin.os.tag) {
    .macos => "plugins/store/zig/zig-out/lib/libbackend.dylib",
    .linux => "plugins/store/zig/zig-out/lib/libbackend.so",
    .windows => "plugins/store/zig/zig-out/bin/backend.dll",
    else => @compileError("unsupported OS"),
};

fn loadStore(reg: *loader.BackendRegistry) !void {
    try reg.register("store", PLUGIN_PATH);
}

fn invokePlugin(reg: *loader.BackendRegistry, request: []const u8) ?[]const u8 {
    var req_buf: [4096]u8 = undefined;
    const len = @min(request.len, req_buf.len - 1);
    @memcpy(req_buf[0..len], request[0..len]);
    req_buf[len] = 0;
    return reg.invoke("store", req_buf[0..len :0]);
}

fn freeResp(reg: *const loader.BackendRegistry, resp: ?[]const u8) void {
    reg.freeResponse("store", resp);
}

var test_counter: u64 = 0;
fn uniqueName(buf: []u8) ![]const u8 {
    test_counter += 1;
    return std.fmt.bufPrint(buf, "test-{d}", .{test_counter});
}

test "store plugin: load" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadStore(&reg);
    try std.testing.expect(reg.get("store") != null);
}

test "store plugin: set/get round-trip" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadStore(&reg);

    var name_buf: [64]u8 = undefined;
    const name = try uniqueName(&name_buf);

    var req_buf: [256]u8 = undefined;
    const clear_req = try std.fmt.bufPrint(&req_buf, "{{\"cmd\":\"store:clear\",\"name\":\"{s}\"}}", .{name});
    const c = invokePlugin(&reg, clear_req);
    defer freeResp(&reg, c);

    var set_buf: [256]u8 = undefined;
    const set_req = try std.fmt.bufPrint(&set_buf, "{{\"cmd\":\"store:set\",\"name\":\"{s}\",\"key\":\"k\",\"value\":\"v\"}}", .{name});
    const s = invokePlugin(&reg, set_req);
    defer freeResp(&reg, s);
    try std.testing.expect(s != null);
    try std.testing.expect(std.mem.indexOf(u8, s.?, "\"ok\":true") != null);

    var get_buf: [256]u8 = undefined;
    const get_req = try std.fmt.bufPrint(&get_buf, "{{\"cmd\":\"store:get\",\"name\":\"{s}\",\"key\":\"k\"}}", .{name});
    const g = invokePlugin(&reg, get_req);
    defer freeResp(&reg, g);
    try std.testing.expect(g != null);
    try std.testing.expect(std.mem.indexOf(u8, g.?, "\"value\":\"v\"") != null);
}

test "store plugin: get missing returns null" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadStore(&reg);

    var name_buf: [64]u8 = undefined;
    const name = try uniqueName(&name_buf);

    var req_buf: [256]u8 = undefined;
    const get_req = try std.fmt.bufPrint(&req_buf, "{{\"cmd\":\"store:get\",\"name\":\"{s}\",\"key\":\"nope\"}}", .{name});
    const r = invokePlugin(&reg, get_req);
    defer freeResp(&reg, r);
    try std.testing.expect(r != null);
    try std.testing.expect(std.mem.indexOf(u8, r.?, "\"value\":null") != null);
}

test "store plugin: has + delete + keys + size" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadStore(&reg);

    var name_buf: [64]u8 = undefined;
    const name = try uniqueName(&name_buf);

    var clear_buf: [256]u8 = undefined;
    const c = invokePlugin(&reg, try std.fmt.bufPrint(&clear_buf, "{{\"cmd\":\"store:clear\",\"name\":\"{s}\"}}", .{name}));
    defer freeResp(&reg, c);

    var set1_buf: [256]u8 = undefined;
    const s1 = invokePlugin(&reg, try std.fmt.bufPrint(&set1_buf, "{{\"cmd\":\"store:set\",\"name\":\"{s}\",\"key\":\"a\",\"value\":1}}", .{name}));
    defer freeResp(&reg, s1);
    var set2_buf: [256]u8 = undefined;
    const s2 = invokePlugin(&reg, try std.fmt.bufPrint(&set2_buf, "{{\"cmd\":\"store:set\",\"name\":\"{s}\",\"key\":\"b\",\"value\":true}}", .{name}));
    defer freeResp(&reg, s2);

    var has_buf: [256]u8 = undefined;
    const h = invokePlugin(&reg, try std.fmt.bufPrint(&has_buf, "{{\"cmd\":\"store:has\",\"name\":\"{s}\",\"key\":\"a\"}}", .{name}));
    defer freeResp(&reg, h);
    try std.testing.expect(h != null);
    try std.testing.expect(std.mem.indexOf(u8, h.?, "\"has\":true") != null);

    var size_buf: [256]u8 = undefined;
    const sz = invokePlugin(&reg, try std.fmt.bufPrint(&size_buf, "{{\"cmd\":\"store:size\",\"name\":\"{s}\"}}", .{name}));
    defer freeResp(&reg, sz);
    try std.testing.expect(sz != null);
    try std.testing.expect(std.mem.indexOf(u8, sz.?, "\"size\":2") != null);

    var keys_buf: [256]u8 = undefined;
    const k = invokePlugin(&reg, try std.fmt.bufPrint(&keys_buf, "{{\"cmd\":\"store:keys\",\"name\":\"{s}\"}}", .{name}));
    defer freeResp(&reg, k);
    try std.testing.expect(k != null);
    try std.testing.expect(std.mem.indexOf(u8, k.?, "\"a\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, k.?, "\"b\"") != null);

    var del_buf: [256]u8 = undefined;
    const d = invokePlugin(&reg, try std.fmt.bufPrint(&del_buf, "{{\"cmd\":\"store:delete\",\"name\":\"{s}\",\"key\":\"a\"}}", .{name}));
    defer freeResp(&reg, d);
    try std.testing.expect(d != null);

    const has2 = invokePlugin(&reg, try std.fmt.bufPrint(&has_buf, "{{\"cmd\":\"store:has\",\"name\":\"{s}\",\"key\":\"a\"}}", .{name}));
    defer freeResp(&reg, has2);
    try std.testing.expect(std.mem.indexOf(u8, has2.?, "\"has\":false") != null);
}

test "store plugin: named instances are isolated" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadStore(&reg);

    var n1: [64]u8 = undefined;
    const name1 = try uniqueName(&n1);
    var n2: [64]u8 = undefined;
    const name2 = try uniqueName(&n2);

    var b: [256]u8 = undefined;
    _ = invokePlugin(&reg, try std.fmt.bufPrint(&b, "{{\"cmd\":\"store:clear\",\"name\":\"{s}\"}}", .{name1}));
    _ = invokePlugin(&reg, try std.fmt.bufPrint(&b, "{{\"cmd\":\"store:clear\",\"name\":\"{s}\"}}", .{name2}));

    _ = invokePlugin(&reg, try std.fmt.bufPrint(&b, "{{\"cmd\":\"store:set\",\"name\":\"{s}\",\"key\":\"x\",\"value\":\"1\"}}", .{name1}));
    _ = invokePlugin(&reg, try std.fmt.bufPrint(&b, "{{\"cmd\":\"store:set\",\"name\":\"{s}\",\"key\":\"x\",\"value\":\"2\"}}", .{name2}));

    const g1 = invokePlugin(&reg, try std.fmt.bufPrint(&b, "{{\"cmd\":\"store:get\",\"name\":\"{s}\",\"key\":\"x\"}}", .{name1}));
    defer freeResp(&reg, g1);
    try std.testing.expect(std.mem.indexOf(u8, g1.?, "\"value\":\"1\"") != null);

    const g2 = invokePlugin(&reg, try std.fmt.bufPrint(&b, "{{\"cmd\":\"store:get\",\"name\":\"{s}\",\"key\":\"x\"}}", .{name2}));
    defer freeResp(&reg, g2);
    try std.testing.expect(std.mem.indexOf(u8, g2.?, "\"value\":\"2\"") != null);
}

test "store plugin: invalid name rejected" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadStore(&reg);

    // path traversal 시도 + dot-only + empty + 너무 김 + 분리자 — 각 카테고리 거부 확인.
    const bad_names = [_][]const u8{
        "{\"cmd\":\"store:get\",\"name\":\"../evil\",\"key\":\"k\"}",
        "{\"cmd\":\"store:get\",\"name\":\"..\",\"key\":\"k\"}",
        "{\"cmd\":\"store:get\",\"name\":\".\",\"key\":\"k\"}",
        "{\"cmd\":\"store:get\",\"name\":\"\",\"key\":\"k\"}",
        "{\"cmd\":\"store:get\",\"name\":\"foo/bar\",\"key\":\"k\"}",
        "{\"cmd\":\"store:get\",\"name\":\"foo\\\\bar\",\"key\":\"k\"}",
        "{\"cmd\":\"store:get\",\"name\":\"foo bar\",\"key\":\"k\"}",
    };
    for (bad_names) |req| {
        const r = invokePlugin(&reg, req);
        defer freeResp(&reg, r);
        try std.testing.expect(r != null);
        try std.testing.expect(std.mem.indexOf(u8, r.?, "\"error\"") != null);
    }
}

test "store plugin: persistence round-trip across re-init" {
    var name_buf: [64]u8 = undefined;
    const name = try uniqueName(&name_buf);

    // 첫 registry — set 후 destroy.
    {
        var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
        defer reg.deinit();
        reg.setGlobal();
        try loadStore(&reg);

        var b: [256]u8 = undefined;
        const c = invokePlugin(&reg, try std.fmt.bufPrint(&b, "{{\"cmd\":\"store:clear\",\"name\":\"{s}\"}}", .{name}));
        defer freeResp(&reg, c);
        const s_resp = invokePlugin(&reg, try std.fmt.bufPrint(&b, "{{\"cmd\":\"store:set\",\"name\":\"{s}\",\"key\":\"persist\",\"value\":\"survives\"}}", .{name}));
        defer freeResp(&reg, s_resp);
    }

    // 두 번째 registry — 디스크에서 load 되어야 함.
    {
        var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
        defer reg.deinit();
        reg.setGlobal();
        try loadStore(&reg);

        var b: [256]u8 = undefined;
        const g = invokePlugin(&reg, try std.fmt.bufPrint(&b, "{{\"cmd\":\"store:get\",\"name\":\"{s}\",\"key\":\"persist\"}}", .{name}));
        defer freeResp(&reg, g);
        try std.testing.expect(g != null);
        try std.testing.expect(std.mem.indexOf(u8, g.?, "\"value\":\"survives\"") != null);

        // cleanup
        const c = invokePlugin(&reg, try std.fmt.bufPrint(&b, "{{\"cmd\":\"store:clear\",\"name\":\"{s}\"}}", .{name}));
        defer freeResp(&reg, c);
    }
}

test "store plugin: get_path returns non-empty default" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadStore(&reg);

    var b: [256]u8 = undefined;
    var n: [64]u8 = undefined;
    const name = try uniqueName(&n);
    const r = invokePlugin(&reg, try std.fmt.bufPrint(&b, "{{\"cmd\":\"store:get_path\",\"name\":\"{s}\"}}", .{name}));
    defer freeResp(&reg, r);
    try std.testing.expect(r != null);
    try std.testing.expect(std.mem.indexOf(u8, r.?, "\"path\":\"\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.?, name) != null);
}

test "store plugin: values/entries return raw JSON values + escaped keys" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadStore(&reg);

    var name_buf: [64]u8 = undefined;
    const name = try uniqueName(&name_buf);
    var b: [256]u8 = undefined;

    freeResp(&reg, invokePlugin(&reg, try std.fmt.bufPrint(&b, "{{\"cmd\":\"store:clear\",\"name\":\"{s}\"}}", .{name})));
    freeResp(&reg, invokePlugin(&reg, try std.fmt.bufPrint(&b, "{{\"cmd\":\"store:set\",\"name\":\"{s}\",\"key\":\"n\",\"value\":42}}", .{name})));
    freeResp(&reg, invokePlugin(&reg, try std.fmt.bufPrint(&b, "{{\"cmd\":\"store:set\",\"name\":\"{s}\",\"key\":\"o\",\"value\":{{\"x\":1}}}}", .{name})));

    // values: raw JSON 값 (42, {"x":1}) 보존
    {
        const r = invokePlugin(&reg, try std.fmt.bufPrint(&b, "{{\"cmd\":\"store:values\",\"name\":\"{s}\"}}", .{name}));
        defer freeResp(&reg, r);
        try std.testing.expect(r != null);
        try std.testing.expect(std.mem.indexOf(u8, r.?, "\"values\":[") != null);
        try std.testing.expect(std.mem.indexOf(u8, r.?, "42") != null);
        try std.testing.expect(std.mem.indexOf(u8, r.?, "{\"x\":1}") != null);
    }
    // entries: [["n",42],["o",{"x":1}]]
    {
        const r = invokePlugin(&reg, try std.fmt.bufPrint(&b, "{{\"cmd\":\"store:entries\",\"name\":\"{s}\"}}", .{name}));
        defer freeResp(&reg, r);
        try std.testing.expect(r != null);
        try std.testing.expect(std.mem.indexOf(u8, r.?, "\"entries\":[") != null);
        try std.testing.expect(std.mem.indexOf(u8, r.?, "[\"n\",42]") != null);
    }
    freeResp(&reg, invokePlugin(&reg, try std.fmt.bufPrint(&b, "{{\"cmd\":\"store:clear\",\"name\":\"{s}\"}}", .{name})));
}
