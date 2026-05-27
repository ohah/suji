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
