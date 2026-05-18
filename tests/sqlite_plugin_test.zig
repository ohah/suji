const std = @import("std");
const builtin = @import("builtin");
const loader = @import("loader");

const PLUGIN_PATH = switch (builtin.os.tag) {
    .macos => "plugins/sqlite/zig/zig-out/lib/libbackend.dylib",
    .linux => "plugins/sqlite/zig/zig-out/lib/libbackend.so",
    .windows => "plugins/sqlite/zig/zig-out/bin/backend.dll",
    else => @compileError("unsupported OS"),
};

/// reg 는 caller 스택에 둔다 — setGlobal() 이 &reg 를 글로벌에 보관하므로
/// 값-반환 헬퍼면 self-포인터가 dangling (state 테스트가 inline 선언인 이유).
fn initReg(reg: *loader.BackendRegistry) void {
    reg.* = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    reg.setGlobal();
}

fn invoke(reg: *loader.BackendRegistry, request: []const u8) ?[]const u8 {
    var buf: [4096]u8 = undefined;
    const n = @min(request.len, buf.len - 1);
    @memcpy(buf[0..n], request[0..n]);
    buf[n] = 0;
    return reg.invoke("sqlite", buf[0..n :0]);
}

fn freeResp(reg: *const loader.BackendRegistry, resp: ?[]const u8) void {
    reg.freeResponse("sqlite", resp);
}

/// `{"from":"zig","result":{"dbId":N}}` → N. 실패 시 0.
fn openMemory(reg: *loader.BackendRegistry) i64 {
    const resp = invoke(reg, "{\"cmd\":\"sql:open\",\"path\":\":memory:\"}") orelse return 0;
    defer freeResp(reg, resp);
    const marker = "\"dbId\":";
    const idx = std.mem.indexOf(u8, resp, marker) orelse return 0;
    var i = idx + marker.len;
    var id: i64 = 0;
    while (i < resp.len and resp[i] >= '0' and resp[i] <= '9') : (i += 1) {
        id = id * 10 + (resp[i] - '0');
    }
    return id;
}

fn execFmt(reg: *loader.BackendRegistry, comptime fmt: []const u8, args: anytype) ?[]const u8 {
    var buf: [2048]u8 = undefined;
    const req = std.fmt.bufPrint(&buf, fmt, args) catch return null;
    return invoke(reg, req);
}

test "sqlite plugin: load" {
    var reg: loader.BackendRegistry = undefined;
    initReg(&reg);
    defer reg.deinit();
    try reg.register("sqlite", PLUGIN_PATH);
    try std.testing.expect(reg.get("sqlite") != null);
}

test "sqlite plugin: open :memory: returns dbId" {
    var reg: loader.BackendRegistry = undefined;
    initReg(&reg);
    defer reg.deinit();
    try reg.register("sqlite", PLUGIN_PATH);
    try std.testing.expect(openMemory(&reg) > 0);
}

test "sqlite plugin: create + insert(params) + query round-trip" {
    var reg: loader.BackendRegistry = undefined;
    initReg(&reg);
    defer reg.deinit();
    try reg.register("sqlite", PLUGIN_PATH);
    const db = openMemory(&reg);
    try std.testing.expect(db > 0);

    const c = execFmt(&reg, "{{\"cmd\":\"sql:execute\",\"dbId\":{d},\"sql\":\"CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT)\"}}", .{db});
    freeResp(&reg, c);

    const ins = execFmt(&reg, "{{\"cmd\":\"sql:execute\",\"dbId\":{d},\"sql\":\"INSERT INTO t(name) VALUES (?)\",\"params\":[\"yoon\"]}}", .{db});
    try std.testing.expect(ins != null);
    try std.testing.expect(std.mem.indexOf(u8, ins.?, "\"changes\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, ins.?, "\"lastInsertRowid\":1") != null);
    freeResp(&reg, ins);

    const q = execFmt(&reg, "{{\"cmd\":\"sql:query\",\"dbId\":{d},\"sql\":\"SELECT id, name FROM t WHERE name = ?\",\"params\":[\"yoon\"]}}", .{db});
    try std.testing.expect(q != null);
    try std.testing.expect(std.mem.indexOf(u8, q.?, "\"name\":\"yoon\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, q.?, "\"id\":1") != null);
    freeResp(&reg, q);
}

test "sqlite plugin: parameterized binding is injection-safe" {
    var reg: loader.BackendRegistry = undefined;
    initReg(&reg);
    defer reg.deinit();
    try reg.register("sqlite", PLUGIN_PATH);
    const db = openMemory(&reg);

    freeResp(&reg, execFmt(&reg, "{{\"cmd\":\"sql:execute\",\"dbId\":{d},\"sql\":\"CREATE TABLE t(v TEXT)\"}}", .{db}));
    // 악의적 입력을 파라미터로 — 리터럴로 저장되고 DROP 안 됨.
    const inj = execFmt(&reg, "{{\"cmd\":\"sql:execute\",\"dbId\":{d},\"sql\":\"INSERT INTO t(v) VALUES (?)\",\"params\":[\"x'); DROP TABLE t;--\"]}}", .{db});
    try std.testing.expect(std.mem.indexOf(u8, inj.?, "\"changes\":1") != null);
    freeResp(&reg, inj);

    // 테이블이 여전히 존재 + 값이 리터럴로 저장됨.
    const q = execFmt(&reg, "{{\"cmd\":\"sql:query\",\"dbId\":{d},\"sql\":\"SELECT v FROM t\"}}", .{db});
    try std.testing.expect(std.mem.indexOf(u8, q.?, "DROP TABLE") != null);
    freeResp(&reg, q);
}

test "sqlite plugin: column types INTEGER/REAL/TEXT/NULL" {
    var reg: loader.BackendRegistry = undefined;
    initReg(&reg);
    defer reg.deinit();
    try reg.register("sqlite", PLUGIN_PATH);
    const db = openMemory(&reg);

    freeResp(&reg, execFmt(&reg, "{{\"cmd\":\"sql:execute\",\"dbId\":{d},\"sql\":\"CREATE TABLE t(i INTEGER, r REAL, s TEXT, n TEXT)\"}}", .{db}));
    freeResp(&reg, execFmt(&reg, "{{\"cmd\":\"sql:execute\",\"dbId\":{d},\"sql\":\"INSERT INTO t VALUES (?, ?, ?, ?)\",\"params\":[7, 3.5, \"hi\", null]}}", .{db}));

    const q = execFmt(&reg, "{{\"cmd\":\"sql:query\",\"dbId\":{d},\"sql\":\"SELECT * FROM t\"}}", .{db});
    try std.testing.expect(std.mem.indexOf(u8, q.?, "\"i\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, q.?, "\"r\":3.5") != null);
    try std.testing.expect(std.mem.indexOf(u8, q.?, "\"s\":\"hi\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, q.?, "\"n\":null") != null);
    freeResp(&reg, q);
}

test "sqlite plugin: query with no rows → empty array" {
    var reg: loader.BackendRegistry = undefined;
    initReg(&reg);
    defer reg.deinit();
    try reg.register("sqlite", PLUGIN_PATH);
    const db = openMemory(&reg);
    freeResp(&reg, execFmt(&reg, "{{\"cmd\":\"sql:execute\",\"dbId\":{d},\"sql\":\"CREATE TABLE t(x)\"}}", .{db}));

    const q = execFmt(&reg, "{{\"cmd\":\"sql:query\",\"dbId\":{d},\"sql\":\"SELECT * FROM t\"}}", .{db});
    try std.testing.expect(std.mem.indexOf(u8, q.?, "\"rows\":[]") != null);
    freeResp(&reg, q);
}

test "sqlite plugin: bad SQL → error" {
    var reg: loader.BackendRegistry = undefined;
    initReg(&reg);
    defer reg.deinit();
    try reg.register("sqlite", PLUGIN_PATH);
    const db = openMemory(&reg);
    const r = execFmt(&reg, "{{\"cmd\":\"sql:execute\",\"dbId\":{d},\"sql\":\"SELCT bad\"}}", .{db});
    try std.testing.expect(std.mem.indexOf(u8, r.?, "\"error\"") != null);
    freeResp(&reg, r);
}

test "sqlite plugin: invalid dbId → error" {
    var reg: loader.BackendRegistry = undefined;
    initReg(&reg);
    defer reg.deinit();
    try reg.register("sqlite", PLUGIN_PATH);
    const r = invoke(&reg, "{\"cmd\":\"sql:query\",\"dbId\":99999,\"sql\":\"SELECT 1\"}");
    try std.testing.expect(std.mem.indexOf(u8, r.?, "invalid dbId") != null);
    freeResp(&reg, r);
}

test "sqlite plugin: close then reuse → invalid dbId" {
    var reg: loader.BackendRegistry = undefined;
    initReg(&reg);
    defer reg.deinit();
    try reg.register("sqlite", PLUGIN_PATH);
    const db = openMemory(&reg);

    const cl = execFmt(&reg, "{{\"cmd\":\"sql:close\",\"dbId\":{d}}}", .{db});
    try std.testing.expect(std.mem.indexOf(u8, cl.?, "\"ok\":true") != null);
    freeResp(&reg, cl);

    const after = execFmt(&reg, "{{\"cmd\":\"sql:query\",\"dbId\":{d},\"sql\":\"SELECT 1\"}}", .{db});
    try std.testing.expect(std.mem.indexOf(u8, after.?, "invalid dbId") != null);
    freeResp(&reg, after);
}

test "sqlite plugin: separate dbs are isolated" {
    var reg: loader.BackendRegistry = undefined;
    initReg(&reg);
    defer reg.deinit();
    try reg.register("sqlite", PLUGIN_PATH);
    const a = openMemory(&reg);
    const b = openMemory(&reg);
    try std.testing.expect(a != b);

    freeResp(&reg, execFmt(&reg, "{{\"cmd\":\"sql:execute\",\"dbId\":{d},\"sql\":\"CREATE TABLE only_a(x)\"}}", .{a}));
    // b 에는 only_a 테이블이 없어야 함 → 에러.
    const q = execFmt(&reg, "{{\"cmd\":\"sql:query\",\"dbId\":{d},\"sql\":\"SELECT * FROM only_a\"}}", .{b});
    try std.testing.expect(std.mem.indexOf(u8, q.?, "\"error\"") != null);
    freeResp(&reg, q);
}

test "sqlite plugin: escaped-string params survive (Parsed-arena lifetime)" {
    var reg: loader.BackendRegistry = undefined;
    initReg(&reg);
    defer reg.deinit();
    try reg.register("sqlite", PLUGIN_PATH);
    const db = openMemory(&reg);
    freeResp(&reg, execFmt(&reg, "{{\"cmd\":\"sql:execute\",\"dbId\":{d},\"sql\":\"CREATE TABLE t(v TEXT)\"}}", .{db}));

    // 이스케이프 포함 문자열 — std.json 이 Parsed 아레나로 복사하는 경로.
    freeResp(&reg, execFmt(&reg, "{{\"cmd\":\"sql:execute\",\"dbId\":{d},\"sql\":\"INSERT INTO t(v) VALUES (?)\",\"params\":[\"a\\nb\\\"c\\\\d\"]}}", .{db}));
    const q = execFmt(&reg, "{{\"cmd\":\"sql:query\",\"dbId\":{d},\"sql\":\"SELECT v FROM t\"}}", .{db});
    // 원래 바이트가 보존되어 응답 JSON 에 다시 escape 되어 나타남.
    try std.testing.expect(std.mem.indexOf(u8, q.?, "a\\nb\\\"c\\\\d") != null);
    freeResp(&reg, q);
}

test "sqlite plugin: multi-statement script (DDL) runs all statements" {
    var reg: loader.BackendRegistry = undefined;
    initReg(&reg);
    defer reg.deinit();
    try reg.register("sqlite", PLUGIN_PATH);
    const db = openMemory(&reg);

    const script = execFmt(&reg, "{{\"cmd\":\"sql:execute\",\"dbId\":{d},\"sql\":\"CREATE TABLE a(x); CREATE TABLE b(y); INSERT INTO b(y) VALUES (1)\"}}", .{db});
    try std.testing.expect(std.mem.indexOf(u8, script.?, "\"error\"") == null);
    freeResp(&reg, script);

    // 두 번째·세 번째 문이 실제 실행됐는지 — b 에서 조회.
    const q = execFmt(&reg, "{{\"cmd\":\"sql:query\",\"dbId\":{d},\"sql\":\"SELECT y FROM b\"}}", .{db});
    try std.testing.expect(std.mem.indexOf(u8, q.?, "\"y\":1") != null);
    freeResp(&reg, q);
}

test "sqlite plugin: params + multi-statement → explicit error" {
    var reg: loader.BackendRegistry = undefined;
    initReg(&reg);
    defer reg.deinit();
    try reg.register("sqlite", PLUGIN_PATH);
    const db = openMemory(&reg);
    const r = execFmt(&reg, "{{\"cmd\":\"sql:execute\",\"dbId\":{d},\"sql\":\"CREATE TABLE a(x); SELECT ?\",\"params\":[1]}}", .{db});
    try std.testing.expect(std.mem.indexOf(u8, r.?, "multi-statement") != null);
    freeResp(&reg, r);
}

test "sqlite plugin: multi-statement query rejected (not silently truncated)" {
    var reg: loader.BackendRegistry = undefined;
    initReg(&reg);
    defer reg.deinit();
    try reg.register("sqlite", PLUGIN_PATH);
    const db = openMemory(&reg);
    const r = execFmt(&reg, "{{\"cmd\":\"sql:query\",\"dbId\":{d},\"sql\":\"SELECT 1; SELECT 2\"}}", .{db});
    try std.testing.expect(std.mem.indexOf(u8, r.?, "multi-statement not supported") != null);
    freeResp(&reg, r);
}
