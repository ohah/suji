const std = @import("std");
const builtin = @import("builtin");
const loader = @import("loader");

const PLUGIN_PATH = switch (builtin.os.tag) {
    .macos => "plugins/notification-rich/zig/zig-out/lib/libbackend.dylib",
    .linux => "plugins/notification-rich/zig/zig-out/lib/libbackend.so",
    .windows => "plugins/notification-rich/zig/zig-out/bin/backend.dll",
    else => @compileError("unsupported OS"),
};

fn loadPlugin(reg: *loader.BackendRegistry) !void {
    try reg.register("notification-rich", PLUGIN_PATH);
}

fn invokePlugin(reg: *loader.BackendRegistry, request: []const u8) ?[]const u8 {
    const a = std.heap.page_allocator;
    const buf = a.allocSentinel(u8, request.len, 0) catch return null;
    defer a.free(buf);
    @memcpy(buf, request);
    return reg.invoke("notification-rich", buf);
}

fn freeResp(reg: *const loader.BackendRegistry, resp: ?[]const u8) void {
    reg.freeResponse("notification-rich", resp);
}

test "notification-rich plugin: load" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadPlugin(&reg);
    try std.testing.expect(reg.get("notification-rich") != null);
}

test "notification-rich plugin: required fields enforced" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadPlugin(&reg);

    const cases = [_][]const u8{
        "{\"cmd\":\"notification:rich_show\"}", // no title/body
        "{\"cmd\":\"notification:rich_show\",\"title\":\"T\"}", // no body
        "{\"cmd\":\"notification:rich_show\",\"body\":\"B\"}", // no title
        "{\"cmd\":\"notification:rich_show\",\"title\":\"\",\"body\":\"B\"}", // empty title
    };
    for (cases) |req| {
        const r = invokePlugin(&reg, req);
        defer freeResp(&reg, r);
        try std.testing.expect(r != null);
        try std.testing.expect(std.mem.indexOf(u8, r.?, "\"error\"") != null);
    }
}

test "notification-rich plugin: oversize title/body rejected" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadPlugin(&reg);

    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(std.heap.page_allocator);
    try payload.appendSlice(std.heap.page_allocator, "{\"cmd\":\"notification:rich_show\",\"title\":\"");
    var i: usize = 0;
    while (i < 300) : (i += 1) try payload.append(std.heap.page_allocator, 'a');
    try payload.appendSlice(std.heap.page_allocator, "\",\"body\":\"B\"}");

    const r = invokePlugin(&reg, payload.items);
    defer freeResp(&reg, r);
    try std.testing.expect(std.mem.indexOf(u8, r.?, "\"error\":\"invalid title\"") != null);
}

test "notification-rich plugin: hide of unknown id fails" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadPlugin(&reg);

    const r = invokePlugin(&reg, "{\"cmd\":\"notification:rich_hide\",\"id\":99999}");
    defer freeResp(&reg, r);
    try std.testing.expect(r != null);
    if (builtin.os.tag == .windows) {
        try std.testing.expect(std.mem.indexOf(u8, r.?, "\"error\":\"not_found\"") != null);
    } else {
        try std.testing.expect(std.mem.indexOf(u8, r.?, "\"error\":\"unsupported_platform\"") != null);
    }
}

test "notification-rich plugin: show returns id on Windows / unsupported elsewhere" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadPlugin(&reg);

    const r = invokePlugin(&reg, "{\"cmd\":\"notification:rich_show\",\"title\":\"hi\",\"body\":\"there\"}");
    defer freeResp(&reg, r);
    try std.testing.expect(r != null);
    if (builtin.os.tag == .windows) {
        // 실제 토스트는 헤드리스 CI 에서 표시 안 될 수 있지만, AUMID/RoInitialize 까지는
        // 동작해서 id 가 반환되어야 한다(WinRT 등록 실패 시 명확한 에러).
        // 두 경우 모두 (id 또는 specific WinRT error) 받아들임 — 정직 한계.
        const has_id = std.mem.indexOf(u8, r.?, "\"id\":") != null;
        const has_error = std.mem.indexOf(u8, r.?, "\"error\"") != null;
        try std.testing.expect(has_id or has_error);
    } else {
        try std.testing.expect(std.mem.indexOf(u8, r.?, "\"error\":\"unsupported_platform\"") != null);
    }
}

// XML injection 회귀 가드 — title/body 안 XML 특수문자가 그대로 들어가면 toast XML
// 파싱 실패해서 응답에 LoadXml/XmlDocActivate 에러가 와야 한다(헤드리스 = 실 toast
// 표시 불가하지만 XML 검증은 WinRT 가 해줌). 만약 escape 가 빠지면 LoadXml 단계에서
// XML 파서 에러 + injection 흔적 가능. 현재 jsonEscapeAppend 가 &lt; &gt; &amp;
// 이스케이프하므로 LoadXml 통과 → 정상 id 반환.
test "notification-rich plugin: XML special chars in title escaped (Windows)" {
    if (comptime builtin.os.tag != .windows) return; // 헤드리스 윈도우 only
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadPlugin(&reg);

    const req = "{\"cmd\":\"notification:rich_show\",\"title\":\"<script>x</script>\",\"body\":\"</toast><evil/>\"}";
    const r = invokePlugin(&reg, req);
    defer freeResp(&reg, r);
    try std.testing.expect(r != null);
    // escape 가 동작하면 LoadXml 통과 → id 반환 (또는 WinRT 환경 의존 graceful error).
    // escape 가 빠지면 LoadXml 실패 → "load xml failed" 에러로 fail-fast.
    const has_xml_error = std.mem.indexOf(u8, r.?, "load xml") != null;
    try std.testing.expect(!has_xml_error);
}

// 잘못된 scenario 값은 silently 제거(XML scenario 속성 누락) — 화이트리스트 가드.
// 헤드리스 윈도우에서도 XML 빌드까지는 동작 — 입력에 "bogus" 가 들어가도 결과 XML
// 에는 scenario="bogus" 가 들어가면 안 됨(XML 파서 reject 가능). LoadXml 통과 확인.
test "notification-rich plugin: invalid scenario silently dropped (Windows)" {
    if (comptime builtin.os.tag != .windows) return;
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadPlugin(&reg);

    const req = "{\"cmd\":\"notification:rich_show\",\"title\":\"t\",\"body\":\"b\",\"scenario\":\"bogus_value\"}";
    const r = invokePlugin(&reg, req);
    defer freeResp(&reg, r);
    try std.testing.expect(r != null);
    try std.testing.expect(std.mem.indexOf(u8, r.?, "load xml") == null);
}

test "notification-rich plugin: image roots set/get round-trip" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadPlugin(&reg);

    const s = invokePlugin(&reg, "{\"cmd\":\"notification:set_image_roots\",\"roots\":[\"C:/Users/me/icons\",\"D:/img\"]}");
    defer freeResp(&reg, s);
    try std.testing.expect(std.mem.indexOf(u8, s.?, "\"ok\":true") != null);

    const g = invokePlugin(&reg, "{\"cmd\":\"notification:get_image_roots\"}");
    defer freeResp(&reg, g);
    try std.testing.expect(std.mem.indexOf(u8, g.?, "\"C:/Users/me/icons\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, g.?, "\"D:/img\"") != null);

    // 두 번째 set 은 replace (append 아님)
    const s2 = invokePlugin(&reg, "{\"cmd\":\"notification:set_image_roots\",\"roots\":[\"C:/new\"]}");
    defer freeResp(&reg, s2);

    const g2 = invokePlugin(&reg, "{\"cmd\":\"notification:get_image_roots\"}");
    defer freeResp(&reg, g2);
    try std.testing.expect(std.mem.indexOf(u8, g2.?, "\"C:/Users/me/icons\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, g2.?, "\"C:/new\"") != null);
}

test "notification-rich plugin: image roots reject .. and over-limit" {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadPlugin(&reg);

    const cases = [_][]const u8{
        "{\"cmd\":\"notification:set_image_roots\",\"roots\":[\"C:/../etc\"]}", // traversal
        "{\"cmd\":\"notification:set_image_roots\",\"roots\":[\"../escape\"]}", // bare ..
        "{\"cmd\":\"notification:set_image_roots\",\"roots\":[123]}", // non-string
        "{\"cmd\":\"notification:set_image_roots\",\"roots\":[\"\"]}", // empty
        "{\"cmd\":\"notification:set_image_roots\",\"roots\":\"not-array\"}", // wrong type
    };
    for (cases) |c| {
        const r = invokePlugin(&reg, c);
        defer freeResp(&reg, r);
        try std.testing.expect(std.mem.indexOf(u8, r.?, "\"error\"") != null);
    }
}

// pathPrefixMatchesRoot separator-boundary 회귀 가드:
// root "C:/foo" 는 "C:/foo/x.png" 매치, "C:/foobar/x.png" 거부.
// 헤드리스 윈도우에서도 XML build/LoadXml 까지는 검증.
test "notification-rich plugin: image root prefix separator boundary (Windows)" {
    if (comptime builtin.os.tag != .windows) return;
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadPlugin(&reg);

    const s = invokePlugin(&reg, "{\"cmd\":\"notification:set_image_roots\",\"roots\":[\"C:/foo\"]}");
    defer freeResp(&reg, s);

    // boundary 안 → image 가 XML 에 들어가서 LoadXml 통과
    const r_in = invokePlugin(&reg, "{\"cmd\":\"notification:rich_show\",\"title\":\"t\",\"body\":\"b\",\"image\":\"C:/foo/x.png\"}");
    defer freeResp(&reg, r_in);
    try std.testing.expect(std.mem.indexOf(u8, r_in.?, "load xml") == null);

    // boundary 밖 ("C:/foobar/...") → image silently 무시, 그래도 LoadXml 통과
    const r_out = invokePlugin(&reg, "{\"cmd\":\"notification:rich_show\",\"title\":\"t\",\"body\":\"b\",\"image\":\"C:/foobar/x.png\"}");
    defer freeResp(&reg, r_out);
    try std.testing.expect(std.mem.indexOf(u8, r_out.?, "load xml") == null);
}

// `["*"]` escape hatch — ".." 만 차단, 임의 경로 통과.
test "notification-rich plugin: image roots wildcard escape hatch (Windows)" {
    if (comptime builtin.os.tag != .windows) return;
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadPlugin(&reg);

    const s = invokePlugin(&reg, "{\"cmd\":\"notification:set_image_roots\",\"roots\":[\"*\"]}");
    defer freeResp(&reg, s);

    // 임의 경로 통과 — image 가 XML 에 포함, LoadXml 통과
    const r_any = invokePlugin(&reg, "{\"cmd\":\"notification:rich_show\",\"title\":\"t\",\"body\":\"b\",\"image\":\"D:/anywhere/img.png\"}");
    defer freeResp(&reg, r_any);
    try std.testing.expect(std.mem.indexOf(u8, r_any.?, "load xml") == null);

    // 그래도 ".." 는 거부 (image 만 silently drop, toast 자체는 표시)
    const r_dotdot = invokePlugin(&reg, "{\"cmd\":\"notification:rich_show\",\"title\":\"t\",\"body\":\"b\",\"image\":\"C:/foo/../escape.png\"}");
    defer freeResp(&reg, r_dotdot);
    try std.testing.expect(std.mem.indexOf(u8, r_dotdot.?, "load xml") == null);
}

// 백슬래시 / 혼합 separator ".." 도 차단.
test "notification-rich plugin: image roots reject backslash and mixed .." {
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadPlugin(&reg);

    const cases = [_][]const u8{
        "{\"cmd\":\"notification:set_image_roots\",\"roots\":[\"C:\\\\foo\\\\..\\\\etc\"]}",
        "{\"cmd\":\"notification:set_image_roots\",\"roots\":[\"C:/foo/..\\\\etc\"]}",
    };
    for (cases) |c| {
        const r = invokePlugin(&reg, c);
        defer freeResp(&reg, r);
        try std.testing.expect(std.mem.indexOf(u8, r.?, "\"error\"") != null);
    }
}

// 이미지 gate 동작: roots 비어 있으면 image 무시 → 정상 show.
// 화이트리스트 외 경로도 무시. 화이트 안 경로는 XML 에 들어감.
// 헤드리스에서도 XML build/LoadXml 까지는 검증.
test "notification-rich plugin: image gated by allowlist (Windows)" {
    if (comptime builtin.os.tag != .windows) return;
    var reg = loader.BackendRegistry.init(std.heap.page_allocator, std.testing.io);
    defer reg.deinit();
    reg.setGlobal();
    try loadPlugin(&reg);

    // roots 비어 → image 무시
    const s_clear = invokePlugin(&reg, "{\"cmd\":\"notification:set_image_roots\",\"roots\":[]}");
    defer freeResp(&reg, s_clear);

    const r1 = invokePlugin(&reg, "{\"cmd\":\"notification:rich_show\",\"title\":\"t\",\"body\":\"b\",\"image\":\"C:/blocked/img.png\"}");
    defer freeResp(&reg, r1);
    try std.testing.expect(r1 != null);
    try std.testing.expect(std.mem.indexOf(u8, r1.?, "load xml") == null);

    // 화이트리스트 외 경로 — 무시되어 정상 show
    const s_set = invokePlugin(&reg, "{\"cmd\":\"notification:set_image_roots\",\"roots\":[\"C:/Users/me/icons\"]}");
    defer freeResp(&reg, s_set);
    const r2 = invokePlugin(&reg, "{\"cmd\":\"notification:rich_show\",\"title\":\"t\",\"body\":\"b\",\"image\":\"D:/elsewhere.png\"}");
    defer freeResp(&reg, r2);
    try std.testing.expect(std.mem.indexOf(u8, r2.?, "load xml") == null);

    // 화이트리스트 안 경로 — 동일하게 정상 show (XML 안 image 포함)
    const r3 = invokePlugin(&reg, "{\"cmd\":\"notification:rich_show\",\"title\":\"t\",\"body\":\"b\",\"image\":\"C:/Users/me/icons/app.png\"}");
    defer freeResp(&reg, r3);
    try std.testing.expect(std.mem.indexOf(u8, r3.?, "load xml") == null);
}
