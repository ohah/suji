const std = @import("std");
const builtin = @import("builtin");
const loader = @import("loader");

const PLUGIN_PATH = switch (builtin.os.tag) {
    .macos => "plugins/http/zig/zig-out/lib/libbackend.dylib",
    .linux => "plugins/http/zig/zig-out/lib/libbackend.so",
    .windows => "plugins/http/zig/zig-out/bin/backend.dll",
    else => @compileError("unsupported OS"),
};

fn loadHttp(reg: *loader.BackendRegistry) !void {
    try reg.register("http", PLUGIN_PATH);
}

fn invokePlugin(reg: *loader.BackendRegistry, request: []const u8) ?[]const u8 {
    // 일부 테스트(MAX_PATTERNS=256+, MAX_URL_LEN=4096+) 가 8KB+ 페이로드를 보낸다.
    const a = std.heap.page_allocator;
    const buf = a.allocSentinel(u8, request.len, 0) catch return null;
    defer a.free(buf);
    @memcpy(buf, request);
    return reg.invoke("http", buf);
}

fn freeResp(reg: *const loader.BackendRegistry, resp: ?[]const u8) void {
    reg.freeResponse("http", resp);
}

test "http plugin: load" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadHttp(&reg);
    try std.testing.expect(reg.get("http") != null);
}

test "http plugin: fetch denied by default (deny-by-default)" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadHttp(&reg);

    // 다른 테스트가 set_allowed_urls 를 호출했을 수 있으므로 초기화.
    const c = invokePlugin(&reg, "{\"cmd\":\"http:set_allowed_urls\",\"urls\":[]}");
    defer freeResp(&reg, c);

    const r = invokePlugin(&reg, "{\"cmd\":\"http:fetch\",\"url\":\"https://example.com/\"}");
    defer freeResp(&reg, r);
    try std.testing.expect(r != null);
    try std.testing.expect(std.mem.indexOf(u8, r.?, "\"error\":\"forbidden\"") != null);
}

test "http plugin: invalid scheme rejected" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadHttp(&reg);

    const set_resp = invokePlugin(&reg, "{\"cmd\":\"http:set_allowed_urls\",\"urls\":[\"*\"]}");
    defer freeResp(&reg, set_resp);

    const bad = [_][]const u8{
        "{\"cmd\":\"http:fetch\",\"url\":\"file:///etc/passwd\"}",
        "{\"cmd\":\"http:fetch\",\"url\":\"javascript:alert(1)\"}",
        "{\"cmd\":\"http:fetch\",\"url\":\"data:text/plain,x\"}",
        "{\"cmd\":\"http:fetch\",\"url\":\"\"}",
    };
    for (bad) |req| {
        const r = invokePlugin(&reg, req);
        defer freeResp(&reg, r);
        try std.testing.expect(r != null);
        try std.testing.expect(std.mem.indexOf(u8, r.?, "\"error\"") != null);
    }
}

test "http plugin: invalid method rejected" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadHttp(&reg);

    const set_resp = invokePlugin(&reg, "{\"cmd\":\"http:set_allowed_urls\",\"urls\":[\"*\"]}");
    defer freeResp(&reg, set_resp);

    const r = invokePlugin(&reg, "{\"cmd\":\"http:fetch\",\"url\":\"https://x/\",\"method\":\"DELETE\"}");
    defer freeResp(&reg, r);
    try std.testing.expect(std.mem.indexOf(u8, r.?, "\"error\":\"method not allowed\"") != null);
}

test "http plugin: set / get allowed urls round-trip" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadHttp(&reg);

    const s = invokePlugin(&reg, "{\"cmd\":\"http:set_allowed_urls\",\"urls\":[\"https://api.x/*\",\"https://*.y.com/*\"]}");
    defer freeResp(&reg, s);
    try std.testing.expect(std.mem.indexOf(u8, s.?, "\"ok\":true") != null);

    const g = invokePlugin(&reg, "{\"cmd\":\"http:get_allowed_urls\"}");
    defer freeResp(&reg, g);
    try std.testing.expect(std.mem.indexOf(u8, g.?, "\"https://api.x/*\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, g.?, "\"https://*.y.com/*\"") != null);
}

test "http plugin: set_allowed_urls rejects non-string and oversized" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadHttp(&reg);

    const non_string = invokePlugin(&reg, "{\"cmd\":\"http:set_allowed_urls\",\"urls\":[123]}");
    defer freeResp(&reg, non_string);
    try std.testing.expect(std.mem.indexOf(u8, non_string.?, "\"error\"") != null);

    const non_array = invokePlugin(&reg, "{\"cmd\":\"http:set_allowed_urls\",\"urls\":\"not-array\"}");
    defer freeResp(&reg, non_array);
    try std.testing.expect(std.mem.indexOf(u8, non_array.?, "\"error\"") != null);
}

test "http plugin: glob matching gates allowlist" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadHttp(&reg);

    const s = invokePlugin(&reg, "{\"cmd\":\"http:set_allowed_urls\",\"urls\":[\"https://api.allowed/*\"]}");
    defer freeResp(&reg, s);

    // 매치 — 실제 네트워크 시도 (이름이 없는 호스트 → fetch failed). 그래도 forbidden 이 아니어야 함.
    const r_match = invokePlugin(&reg, "{\"cmd\":\"http:fetch\",\"url\":\"https://api.allowed/v1\"}");
    defer freeResp(&reg, r_match);
    try std.testing.expect(r_match != null);
    try std.testing.expect(std.mem.indexOf(u8, r_match.?, "\"error\":\"forbidden\"") == null);

    // 불일치 — forbidden.
    const r_nomatch = invokePlugin(&reg, "{\"cmd\":\"http:fetch\",\"url\":\"https://api.blocked/v1\"}");
    defer freeResp(&reg, r_nomatch);
    try std.testing.expect(std.mem.indexOf(u8, r_nomatch.?, "\"error\":\"forbidden\"") != null);
}

test "http plugin: userinfo authority bypass blocked" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadHttp(&reg);

    // allowlist 가 가장 느슨한 `*` 라도 userinfo 가 있는 URL 은 거부 — glob 매칭은
    // raw URL 대상이라 `https://allowed@evil.com/` 는 `https://allowed*` 통과하지만
    // 실제 연결은 `evil.com` 이라는 SSRF 우회. authority 안 `@` 차단으로 sealed.
    const s = invokePlugin(&reg, "{\"cmd\":\"http:set_allowed_urls\",\"urls\":[\"*\"]}");
    defer freeResp(&reg, s);

    const cases = [_][]const u8{
        "{\"cmd\":\"http:fetch\",\"url\":\"https://allowed.com@evil.com/path\"}",
        "{\"cmd\":\"http:fetch\",\"url\":\"http://user:pass@evil/\"}",
    };
    for (cases) |req| {
        const r = invokePlugin(&reg, req);
        defer freeResp(&reg, r);
        try std.testing.expect(std.mem.indexOf(u8, r.?, "\"error\":\"userinfo not allowed\"") != null);
    }
}

test "http plugin: CRLF byte injection in URL blocked" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadHttp(&reg);

    const s = invokePlugin(&reg, "{\"cmd\":\"http:set_allowed_urls\",\"urls\":[\"*\"]}");
    defer freeResp(&reg, s);

    // extractJsonString 은 raw substring 반환 — 실 CR/LF 바이트를 보내야 검증 가능.
    // 정상 JSON 은 string literal 안 unescaped CR/LF 금지지만, 우리 추출기는
    // JSON 디코드 안 함 → byte-level 검증 효력 유지(SDK 정직 한계 인지하고 가드).
    const req_bytes = "{\"cmd\":\"http:fetch\",\"url\":\"https://x.com/\r\nHost: evil\"}";
    const r = invokePlugin(&reg, req_bytes);
    defer freeResp(&reg, r);
    try std.testing.expect(r != null);
    try std.testing.expect(std.mem.indexOf(u8, r.?, "\"error\":\"invalid url\"") != null);
}

test "http plugin: setAllowedUrls replaces (not appends)" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadHttp(&reg);

    const s1 = invokePlugin(&reg, "{\"cmd\":\"http:set_allowed_urls\",\"urls\":[\"https://first.com/*\"]}");
    defer freeResp(&reg, s1);
    const s2 = invokePlugin(&reg, "{\"cmd\":\"http:set_allowed_urls\",\"urls\":[\"https://second.com/*\"]}");
    defer freeResp(&reg, s2);

    const g = invokePlugin(&reg, "{\"cmd\":\"http:get_allowed_urls\"}");
    defer freeResp(&reg, g);
    try std.testing.expect(std.mem.indexOf(u8, g.?, "\"https://first.com/*\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, g.?, "\"https://second.com/*\"") != null);

    const r = invokePlugin(&reg, "{\"cmd\":\"http:fetch\",\"url\":\"https://first.com/v1\"}");
    defer freeResp(&reg, r);
    try std.testing.expect(std.mem.indexOf(u8, r.?, "\"error\":\"forbidden\"") != null);
}

test "http plugin: MAX_PATTERNS limit enforced" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadHttp(&reg);

    // 257 patterns — MAX_PATTERNS=256 초과 → 거부.
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(std.heap.page_allocator);
    try payload.appendSlice(std.heap.page_allocator, "{\"cmd\":\"http:set_allowed_urls\",\"urls\":[");
    var i: usize = 0;
    while (i < 257) : (i += 1) {
        if (i > 0) try payload.append(std.heap.page_allocator, ',');
        var buf: [32]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "\"https://p{d}/*\"", .{i});
        try payload.appendSlice(std.heap.page_allocator, s);
    }
    try payload.appendSlice(std.heap.page_allocator, "]}");

    const r = invokePlugin(&reg, payload.items);
    defer freeResp(&reg, r);
    try std.testing.expect(std.mem.indexOf(u8, r.?, "\"error\":\"too many patterns\"") != null);
}

test "http plugin: oversized pattern rejected" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadHttp(&reg);

    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(std.heap.page_allocator);
    try payload.appendSlice(std.heap.page_allocator, "{\"cmd\":\"http:set_allowed_urls\",\"urls\":[\"");
    var i: usize = 0;
    while (i < 1100) : (i += 1) try payload.append(std.heap.page_allocator, 'a');
    try payload.appendSlice(std.heap.page_allocator, "\"]}");

    const r = invokePlugin(&reg, payload.items);
    defer freeResp(&reg, r);
    try std.testing.expect(std.mem.indexOf(u8, r.?, "\"error\":\"invalid pattern\"") != null);
}

test "http plugin: allowed_headers round-trip + replace" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadHttp(&reg);

    const s = invokePlugin(&reg, "{\"cmd\":\"http:set_allowed_headers\",\"headers\":[\"X-Test\",\"Authorization\"]}");
    defer freeResp(&reg, s);
    try std.testing.expect(std.mem.indexOf(u8, s.?, "\"ok\":true") != null);

    const g = invokePlugin(&reg, "{\"cmd\":\"http:get_allowed_headers\"}");
    defer freeResp(&reg, g);
    try std.testing.expect(std.mem.indexOf(u8, g.?, "\"X-Test\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, g.?, "\"Authorization\"") != null);

    // 두 번째 set 은 replace
    const s2 = invokePlugin(&reg, "{\"cmd\":\"http:set_allowed_headers\",\"headers\":[\"Accept\"]}");
    defer freeResp(&reg, s2);
    const g2 = invokePlugin(&reg, "{\"cmd\":\"http:get_allowed_headers\"}");
    defer freeResp(&reg, g2);
    try std.testing.expect(std.mem.indexOf(u8, g2.?, "\"X-Test\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, g2.?, "\"Accept\"") != null);
}

test "http plugin: header name validation rejects bad tokens" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadHttp(&reg);

    const cases = [_][]const u8{
        "{\"cmd\":\"http:set_allowed_headers\",\"headers\":[\"X:bad\"]}", // colon
        "{\"cmd\":\"http:set_allowed_headers\",\"headers\":[\"With Space\"]}", // space
        "{\"cmd\":\"http:set_allowed_headers\",\"headers\":[\"X\\r\\n\"]}", // CRLF
        "{\"cmd\":\"http:set_allowed_headers\",\"headers\":[\"\"]}", // empty
        "{\"cmd\":\"http:set_allowed_headers\",\"headers\":[42]}", // non-string
        "{\"cmd\":\"http:set_allowed_headers\",\"headers\":\"not-array\"}", // wrong type
    };
    for (cases) |c| {
        const r = invokePlugin(&reg, c);
        defer freeResp(&reg, r);
        try std.testing.expect(std.mem.indexOf(u8, r.?, "\"error\"") != null);
    }
}

test "http plugin: header name matching is case-insensitive" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadHttp(&reg);

    const s_url = invokePlugin(&reg, "{\"cmd\":\"http:set_allowed_urls\",\"urls\":[\"*\"]}");
    defer freeResp(&reg, s_url);
    const s_h = invokePlugin(&reg, "{\"cmd\":\"http:set_allowed_headers\",\"headers\":[\"X-Custom\"]}");
    defer freeResp(&reg, s_h);

    // registered as "X-Custom", passed as "x-custom" / "X-CUSTOM" — 둘 다 통과해야.
    const variants = [_][]const u8{
        "{\"cmd\":\"http:fetch\",\"url\":\"https://x/\",\"headers\":{\"x-custom\":\"v\"}}",
        "{\"cmd\":\"http:fetch\",\"url\":\"https://x/\",\"headers\":{\"X-CUSTOM\":\"v\"}}",
    };
    for (variants) |req| {
        const r = invokePlugin(&reg, req);
        defer freeResp(&reg, r);
        try std.testing.expect(std.mem.indexOf(u8, r.?, "\"error\":\"header not allowed\"") == null);
    }
}

test "http plugin: header value MAX boundary" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadHttp(&reg);

    const s_url = invokePlugin(&reg, "{\"cmd\":\"http:set_allowed_urls\",\"urls\":[\"*\"]}");
    defer freeResp(&reg, s_url);
    const s_h = invokePlugin(&reg, "{\"cmd\":\"http:set_allowed_headers\",\"headers\":[\"X\"]}");
    defer freeResp(&reg, s_h);

    // 정확히 MAX (4096) 통과, MAX+1 거부.
    const a = std.heap.page_allocator;
    inline for (.{ .{ .len = 4096, .expect_ok = true }, .{ .len = 4097, .expect_ok = false } }) |case| {
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(a);
        try payload.appendSlice(a, "{\"cmd\":\"http:fetch\",\"url\":\"https://x/\",\"headers\":{\"X\":\"");
        var i: usize = 0;
        while (i < case.len) : (i += 1) try payload.append(a, 'a');
        try payload.appendSlice(a, "\"}}");
        const r = invokePlugin(&reg, payload.items);
        defer freeResp(&reg, r);
        if (case.expect_ok) {
            try std.testing.expect(std.mem.indexOf(u8, r.?, "\"error\":\"invalid header value\"") == null);
        } else {
            try std.testing.expect(std.mem.indexOf(u8, r.?, "\"error\":\"invalid header value\"") != null);
        }
    }
}

test "http plugin: fetch headers gated by allowlist" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadHttp(&reg);

    const s_url = invokePlugin(&reg, "{\"cmd\":\"http:set_allowed_urls\",\"urls\":[\"https://api.allowed/*\"]}");
    defer freeResp(&reg, s_url);
    const s_clear = invokePlugin(&reg, "{\"cmd\":\"http:set_allowed_headers\",\"headers\":[]}");
    defer freeResp(&reg, s_clear);

    // empty allowlist → 미허용 header 거부
    const r1 = invokePlugin(&reg, "{\"cmd\":\"http:fetch\",\"url\":\"https://api.allowed/v1\",\"headers\":{\"X-Custom\":\"v\"}}");
    defer freeResp(&reg, r1);
    try std.testing.expect(std.mem.indexOf(u8, r1.?, "\"error\":\"header not allowed\"") != null);

    // 허용 후 동일 호출 → 다른 에러(네트워크 등)는 가능하지만 header 자체는 통과해야 함
    const s_set = invokePlugin(&reg, "{\"cmd\":\"http:set_allowed_headers\",\"headers\":[\"X-Custom\"]}");
    defer freeResp(&reg, s_set);
    const r2 = invokePlugin(&reg, "{\"cmd\":\"http:fetch\",\"url\":\"https://api.allowed/v1\",\"headers\":{\"X-Custom\":\"v\"}}");
    defer freeResp(&reg, r2);
    try std.testing.expect(std.mem.indexOf(u8, r2.?, "\"error\":\"header not allowed\"") == null);
}

test "http plugin: header value CRLF injection blocked" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadHttp(&reg);

    const s_url = invokePlugin(&reg, "{\"cmd\":\"http:set_allowed_urls\",\"urls\":[\"*\"]}");
    defer freeResp(&reg, s_url);
    const s_h = invokePlugin(&reg, "{\"cmd\":\"http:set_allowed_headers\",\"headers\":[\"X\"]}");
    defer freeResp(&reg, s_h);

    // JSON 이스케이프 시퀀스 \r\n → 디코드 후 실제 CR/LF 바이트가 헤더 값에 들어감.
    // 우리 isValidHeaderValue 가 byte-level 로 거부.
    const req_bytes = "{\"cmd\":\"http:fetch\",\"url\":\"https://x.com/\",\"headers\":{\"X\":\"a\\r\\nHost: evil\"}}";
    const r = invokePlugin(&reg, req_bytes);
    defer freeResp(&reg, r);
    try std.testing.expect(std.mem.indexOf(u8, r.?, "\"error\":\"invalid header value\"") != null);
}

test "http plugin: oversized URL rejected" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadHttp(&reg);

    const s = invokePlugin(&reg, "{\"cmd\":\"http:set_allowed_urls\",\"urls\":[\"*\"]}");
    defer freeResp(&reg, s);

    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(std.heap.page_allocator);
    try payload.appendSlice(std.heap.page_allocator, "{\"cmd\":\"http:fetch\",\"url\":\"https://x/");
    var i: usize = 0;
    while (i < 4200) : (i += 1) try payload.append(std.heap.page_allocator, 'p');
    try payload.appendSlice(std.heap.page_allocator, "\"}");

    const r = invokePlugin(&reg, payload.items);
    defer freeResp(&reg, r);
    try std.testing.expect(std.mem.indexOf(u8, r.?, "\"error\":\"invalid url\"") != null);
}
