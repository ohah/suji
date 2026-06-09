const std = @import("std");
const builtin = @import("builtin");
const loader = @import("loader");

const PLUGIN_PATH = switch (builtin.os.tag) {
    .macos => "plugins/upload/zig/zig-out/lib/libbackend.dylib",
    .linux => "plugins/upload/zig/zig-out/lib/libbackend.so",
    .windows => "plugins/upload/zig/zig-out/bin/backend.dll",
    else => @compileError("unsupported OS"),
};

fn loadUp(reg: *loader.BackendRegistry) !void {
    try reg.register("upload", PLUGIN_PATH);
}

fn invokePlugin(reg: *loader.BackendRegistry, request: []const u8) ?[]const u8 {
    var req_buf: [4096]u8 = undefined;
    const len = @min(request.len, req_buf.len - 1);
    @memcpy(req_buf[0..len], request[0..len]);
    req_buf[len] = 0;
    return reg.invoke("upload", req_buf[0..len :0]);
}

fn freeResp(reg: *const loader.BackendRegistry, resp: ?[]const u8) void {
    reg.freeResponse("upload", resp);
}

fn expectContains(r: ?[]const u8, needle: []const u8) !void {
    try std.testing.expect(r != null);
    try std.testing.expect(std.mem.indexOf(u8, r.?, needle) != null);
}

test "upload plugin: load + channels" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadUp(&reg);
    try std.testing.expect(reg.get("upload") != null);
}

test "upload plugin: allowlist URL round-trip" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadUp(&reg);

    const s = invokePlugin(&reg, "{\"cmd\":\"upload:set_allowed_urls\",\"urls\":[\"https://ok.example/*\"]}");
    defer freeResp(&reg, s);
    try expectContains(s, "\"ok\":true");

    const g = invokePlugin(&reg, "{\"cmd\":\"upload:get_allowed_urls\"}");
    defer freeResp(&reg, g);
    try expectContains(g, "https://ok.example/*");
}

test "upload plugin: allowlist PATH round-trip" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadUp(&reg);

    const s = invokePlugin(&reg, "{\"cmd\":\"upload:set_allowed_paths\",\"paths\":[\"/srv/data\"]}");
    defer freeResp(&reg, s);
    try expectContains(s, "\"ok\":true");

    const g = invokePlugin(&reg, "{\"cmd\":\"upload:get_allowed_paths\"}");
    defer freeResp(&reg, g);
    try expectContains(g, "/srv/data");
}

test "upload plugin: deny-by-default URL (empty allowlist → forbidden url)" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadUp(&reg);

    // 명시적으로 빈 allowlist 설정(전역 상태 격리).
    freeResp(&reg, invokePlugin(&reg, "{\"cmd\":\"upload:set_allowed_urls\",\"urls\":[]}"));
    const r = invokePlugin(&reg, "{\"cmd\":\"upload:download\",\"url\":\"https://evil.example/x\",\"filePath\":\"/tmp/x\"}");
    defer freeResp(&reg, r);
    try expectContains(r, "forbidden url");
}

test "upload plugin: scheme + userinfo SSRF guards" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadUp(&reg);

    const bad_scheme = invokePlugin(&reg, "{\"cmd\":\"upload:download\",\"url\":\"file:///etc/passwd\",\"filePath\":\"/tmp/x\"}");
    defer freeResp(&reg, bad_scheme);
    try expectContains(bad_scheme, "scheme not allowed");

    const userinfo = invokePlugin(&reg, "{\"cmd\":\"upload:download\",\"url\":\"https://ok.example@evil.example/x\",\"filePath\":\"/tmp/x\"}");
    defer freeResp(&reg, userinfo);
    try expectContains(userinfo, "userinfo not allowed");
}

test "upload plugin: PATH deny-by-default + traversal (url allowed, path forbidden)" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadUp(&reg);

    // url 은 허용하되 path allowlist 는 특정 prefix 만 — 그 밖/traversal 은 forbidden path.
    freeResp(&reg, invokePlugin(&reg, "{\"cmd\":\"upload:set_allowed_urls\",\"urls\":[\"https://ok.example/*\"]}"));
    freeResp(&reg, invokePlugin(&reg, "{\"cmd\":\"upload:set_allowed_paths\",\"paths\":[\"/srv/data\"]}"));

    // allowlist 밖 경로
    const outside = invokePlugin(&reg, "{\"cmd\":\"upload:download\",\"url\":\"https://ok.example/x\",\"filePath\":\"/etc/passwd\"}");
    defer freeResp(&reg, outside);
    try expectContains(outside, "forbidden path");

    // boundary: /srv/dataX 는 prefix 통과하지만 separator boundary 로 거부
    const boundary = invokePlugin(&reg, "{\"cmd\":\"upload:download\",\"url\":\"https://ok.example/x\",\"filePath\":\"/srv/dataX/y\"}");
    defer freeResp(&reg, boundary);
    try expectContains(boundary, "forbidden path");

    // traversal
    const traversal = invokePlugin(&reg, "{\"cmd\":\"upload:download\",\"url\":\"https://ok.example/x\",\"filePath\":\"/srv/data/../../etc/passwd\"}");
    defer freeResp(&reg, traversal);
    try expectContains(traversal, "forbidden path");
}

test "upload plugin: ~ in allowed path expands at store time (documented usage works)" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadUp(&reg);

    // "~/suji-up-test" 저장 → get 은 $HOME 으로 확장된 경로를 돌려줘야(raw "~" 잔존 X).
    // 안 그러면 expandHome 된 filePath 와 절대 매치 안 됨(code-review max 발견 버그).
    freeResp(&reg, invokePlugin(&reg, "{\"cmd\":\"upload:set_allowed_paths\",\"paths\":[\"~/suji-up-test\"]}"));
    const g = invokePlugin(&reg, "{\"cmd\":\"upload:get_allowed_paths\"}");
    defer freeResp(&reg, g);
    try expectContains(g, "suji-up-test");
    // raw "~/" 형태가 남아 있으면 확장 실패 — 버그 회귀.
    try std.testing.expect(std.mem.indexOf(u8, g.?, "~/suji-up-test") == null);
}

test "upload plugin: missing url/filePath" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadUp(&reg);

    const no_url = invokePlugin(&reg, "{\"cmd\":\"upload:upload\",\"filePath\":\"/tmp/x\"}");
    defer freeResp(&reg, no_url);
    try expectContains(no_url, "missing url");
}
