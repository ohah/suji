//! window_ipc 테스트 — handleCreateWindow가 WM.create를 올바르게 호출하고
//! 유효한 JSON 응답을 생성하는지 검증.

const std = @import("std");
const window = @import("window");
const TestNative = @import("test_native").TestNative;
const ipc = @import("window_ipc");

fn newWm(native: *TestNative) window.WindowManager {
    return window.WindowManager.init(std.testing.allocator, std.testing.io, native.asNative());
}

test "handleCreateWindow calls wm.create with title + url + bounds" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();

    var buf: [256]u8 = undefined;
    const resp = ipc.handleCreateWindow(.{
        .title = "My Window",
        .url = "https://example.com",
        .width = 600,
        .height = 400,
    }, &buf, &wm).?;

    try std.testing.expectEqual(@as(usize, 1), native.create_calls);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"cmd\":\"create_window\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"windowId\":1") != null);
}

test "handleCreateWindow applies defaults when fields omitted" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();

    var buf: [256]u8 = undefined;
    _ = ipc.handleCreateWindow(.{}, &buf, &wm).?;

    const w = wm.get(1).?;
    try std.testing.expectEqualStrings("New Window", w.title);
    try std.testing.expectEqual(@as(?[]const u8, null), w.name);
    try std.testing.expectEqual(@as(u32, 800), w.bounds.width);
    try std.testing.expectEqual(@as(u32, 600), w.bounds.height);
}

test "handleCreateWindow returns JSON with valid windowId (parsable)" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();

    var buf: [256]u8 = undefined;
    const resp = ipc.handleCreateWindow(.{ .title = "x" }, &buf, &wm).?;

    const Parsed = struct { windowId: u32, cmd: []const u8, from: []const u8 };
    const parsed = try std.json.parseFromSlice(
        Parsed,
        std.testing.allocator,
        resp,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    try std.testing.expect(parsed.value.windowId > 0);
    try std.testing.expectEqualStrings("create_window", parsed.value.cmd);
    try std.testing.expectEqualStrings("zig-core", parsed.value.from);
}

test "handleCreateWindow with name honors singleton (duplicate returns same id)" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();

    var buf1: [256]u8 = undefined;
    var buf2: [256]u8 = undefined;
    _ = ipc.handleCreateWindow(.{ .name = "about" }, &buf1, &wm).?;
    _ = ipc.handleCreateWindow(.{ .name = "about" }, &buf2, &wm).?;

    // native.create는 1회만
    try std.testing.expectEqual(@as(usize, 1), native.create_calls);
}

test "handleCreateWindow returns null on native failure" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();

    native.fail_next_create = true;
    var buf: [256]u8 = undefined;
    const resp = ipc.handleCreateWindow(.{}, &buf, &wm);
    try std.testing.expect(resp == null);
    try std.testing.expectEqual(@as(usize, 0), native.create_calls);
}

test "handleCreateWindow rejects small buffer WITHOUT creating window" {
    // 고아 윈도우 방지 invariant: 응답 버퍼가 작으면 wm.create를 호출하지 않는다.
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();

    var tiny: [3]u8 = undefined;
    const resp = ipc.handleCreateWindow(.{}, &tiny, &wm);
    try std.testing.expect(resp == null);
    try std.testing.expectEqual(@as(usize, 0), native.create_calls);
}

// ============================================
// Step C — handleSetTitle / handleSetBounds
// ============================================

test "handleSetTitle forwards title to native.setTitle" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();

    _ = try wm.create(.{ .title = "old" });
    var buf: [256]u8 = undefined;
    const resp = ipc.handleSetTitle(.{ .window_id = 1, .title = "new title" }, &buf, &wm).?;

    try std.testing.expectEqual(@as(usize, 1), native.set_title_calls);
    try std.testing.expectEqualStrings("new title", native.last_title.?);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"cmd\":\"set_title\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"ok\":true") != null);
}

test "handleSetTitle on unknown id returns ok:false, does not call native" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();

    var buf: [256]u8 = undefined;
    const resp = ipc.handleSetTitle(.{ .window_id = 999, .title = "x" }, &buf, &wm).?;

    try std.testing.expectEqual(@as(usize, 0), native.set_title_calls);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"ok\":false") != null);
}

test "handleSetBounds forwards bounds to native.setBounds" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();

    _ = try wm.create(.{ .bounds = .{ .width = 100, .height = 100 } });
    var buf: [256]u8 = undefined;
    const resp = ipc.handleSetBounds(.{
        .window_id = 1,
        .x = 10,
        .y = 20,
        .width = 800,
        .height = 600,
    }, &buf, &wm).?;

    try std.testing.expectEqual(@as(usize, 1), native.set_bounds_calls);
    const lb = native.last_bounds.?;
    try std.testing.expectEqual(@as(i32, 10), lb.x);
    try std.testing.expectEqual(@as(i32, 20), lb.y);
    try std.testing.expectEqual(@as(u32, 800), lb.width);
    try std.testing.expectEqual(@as(u32, 600), lb.height);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"ok\":true") != null);
}

test "handleSetBounds rejects small buffer" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();

    var tiny: [3]u8 = undefined;
    const resp = ipc.handleSetBounds(.{ .window_id = 1 }, &tiny, &wm);
    try std.testing.expect(resp == null);
}

test "handleSetBounds on unknown id returns ok:false, does not call native" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();

    var buf: [256]u8 = undefined;
    const resp = ipc.handleSetBounds(.{
        .window_id = 999,
        .width = 800,
        .height = 600,
    }, &buf, &wm).?;

    try std.testing.expectEqual(@as(usize, 0), native.set_bounds_calls);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"ok\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"windowId\":999") != null);
}

test "handleSetTitle rejects small buffer" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();

    var tiny: [3]u8 = undefined;
    const resp = ipc.handleSetTitle(.{ .window_id = 1, .title = "x" }, &tiny, &wm);
    try std.testing.expect(resp == null);
}

test "handleSetTitle on destroyed window returns ok:false" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();

    const id = try wm.create(.{ .title = "living" });
    try wm.destroy(id);

    var buf: [256]u8 = undefined;
    const resp = ipc.handleSetTitle(.{ .window_id = id, .title = "ghost" }, &buf, &wm).?;

    // destroy 후엔 setTitle이 실패해야 한다.
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"ok\":false") != null);
}

test "handleSetBounds on destroyed window returns ok:false" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();

    const id = try wm.create(.{ .title = "living" });
    try wm.destroy(id);

    var buf: [256]u8 = undefined;
    const resp = ipc.handleSetBounds(.{ .window_id = id, .width = 100, .height = 100 }, &buf, &wm).?;

    try std.testing.expect(std.mem.indexOf(u8, resp, "\"ok\":false") != null);
}

test "handleSetTitle response is valid JSON (parsable)" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();

    _ = try wm.create(.{ .title = "x" });
    var buf: [256]u8 = undefined;
    const resp = ipc.handleSetTitle(.{ .window_id = 1, .title = "new" }, &buf, &wm).?;

    const Parsed = struct { windowId: u32, cmd: []const u8, from: []const u8, ok: bool };
    const parsed = try std.json.parseFromSlice(
        Parsed,
        std.testing.allocator,
        resp,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u32, 1), parsed.value.windowId);
    try std.testing.expectEqualStrings("set_title", parsed.value.cmd);
    try std.testing.expectEqualStrings("zig-core", parsed.value.from);
    try std.testing.expect(parsed.value.ok);
}

// ============================================
// Phase 2.5 — injectWindowField (wire 레벨 __window 자동 주입)
// ============================================

test "injectWindowField: inserts into simple object" {
    var buf: [256]u8 = undefined;
    const out = ipc.injectWindowField("{\"cmd\":\"ping\"}", .{ .window_id = 3, .window_name = null, .window_url = null }, &buf).?;
    try std.testing.expectEqualStrings("{\"cmd\":\"ping\",\"__window\":3}", out);
}

test "injectWindowField: handles empty object (no leading comma)" {
    var buf: [64]u8 = undefined;
    const out = ipc.injectWindowField("{}", .{ .window_id = 1, .window_name = null, .window_url = null }, &buf).?;
    try std.testing.expectEqualStrings("{\"__window\":1}", out);
}

test "injectWindowField: handles whitespace-only object body" {
    var buf: [64]u8 = undefined;
    const out = ipc.injectWindowField("{  }", .{ .window_id = 5, .window_name = null, .window_url = null }, &buf).?;
    try std.testing.expectEqualStrings("{  \"__window\":5}", out);
}

test "injectWindowField: already-tagged request is returned as-is (no double-inject)" {
    var buf: [256]u8 = undefined;
    const src = "{\"cmd\":\"ping\",\"__window\":99}";
    const out = ipc.injectWindowField(src, .{ .window_id = 1, .window_name = null, .window_url = null }, &buf).?;
    try std.testing.expectEqualStrings(src, out);
}

test "injectWindowField: non-object input returned as-is" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("[1,2,3]", ipc.injectWindowField("[1,2,3]", .{ .window_id = 1 }, &buf).?);
    try std.testing.expectEqualStrings("42", ipc.injectWindowField("42", .{ .window_id = 1, .window_name = null, .window_url = null }, &buf).?);
    try std.testing.expectEqualStrings("", ipc.injectWindowField("", .{ .window_id = 1, .window_name = null, .window_url = null }, &buf).?);
}

test "injectWindowField: trailing whitespace before } still parses" {
    var buf: [64]u8 = undefined;
    const out = ipc.injectWindowField("{\"a\":1}\n  ", .{ .window_id = 7, .window_name = null, .window_url = null }, &buf).?;
    try std.testing.expectEqualStrings("{\"a\":1,\"__window\":7}", out);
}

test "injectWindowField: returns null when output buffer too small" {
    var tiny: [4]u8 = undefined;
    const out = ipc.injectWindowField("{\"cmd\":\"ping\"}", .{ .window_id = 1, .window_name = null, .window_url = null }, &tiny);
    try std.testing.expect(out == null);
}

// ============================================
// Phase 2.5 — window_name 주입 (Window에 name이 설정된 경우)
// ============================================

test "injectWindowField: name 있으면 __window_name도 주입" {
    var buf: [256]u8 = undefined;
    const out = ipc.injectWindowField("{\"cmd\":\"ping\"}", .{ .window_id = 2, .window_name = "settings", .window_url = null }, &buf).?;
    try std.testing.expectEqualStrings(
        "{\"cmd\":\"ping\",\"__window\":2,\"__window_name\":\"settings\"}",
        out,
    );
}

test "injectWindowField: name 있고 빈 객체일 때 sep 없이 주입" {
    var buf: [128]u8 = undefined;
    const out = ipc.injectWindowField("{}", .{ .window_id = 1, .window_name = "main", .window_url = null }, &buf).?;
    try std.testing.expectEqualStrings("{\"__window\":1,\"__window_name\":\"main\"}", out);
}

test "injectWindowField: __window 이미 있으면 name도 재주입 안 함" {
    var buf: [256]u8 = undefined;
    const src = "{\"cmd\":\"x\",\"__window\":9}";
    try std.testing.expectEqualStrings(src, ipc.injectWindowField(src, .{ .window_id = 1, .window_name = "should-not-appear", .window_url = null }, &buf).?);
}

test "injectWindowField: name이 null이면 __window_name 미주입 (기존 동작 보존)" {
    var buf: [128]u8 = undefined;
    const out = ipc.injectWindowField("{\"cmd\":\"a\"}", .{ .window_id = 4, .window_name = null, .window_url = null }, &buf).?;
    try std.testing.expectEqualStrings("{\"cmd\":\"a\",\"__window\":4}", out);
    try std.testing.expect(std.mem.indexOf(u8, out, "__window_name") == null);
}

test "injectWindowField: name 포함 시 out_buf 작으면 null" {
    var tiny: [20]u8 = undefined;
    const out = ipc.injectWindowField("{\"cmd\":\"ping\"}", .{ .window_id = 1, .window_name = "very-long-window-name", .window_url = null }, &tiny);
    try std.testing.expect(out == null);
}

test "injectWindowField: 빈 문자열 name도 정상 주입" {
    var buf: [128]u8 = undefined;
    const out = ipc.injectWindowField("{\"cmd\":\"x\"}", .{ .window_id = 1, .window_name = "", .window_url = null }, &buf).?;
    try std.testing.expectEqualStrings("{\"cmd\":\"x\",\"__window\":1,\"__window_name\":\"\"}", out);
}

test "injectWindowField: trailing whitespace + name 둘 다 처리" {
    var buf: [128]u8 = undefined;
    const out = ipc.injectWindowField("{\"a\":1}\n", .{ .window_id = 3, .window_name = "main", .window_url = null }, &buf).?;
    try std.testing.expectEqualStrings("{\"a\":1,\"__window\":3,\"__window_name\":\"main\"}", out);
}

test "injectWindowField: name에 \" 있으면 name 생략하고 id만 주입 (JSON 깨짐 방지)" {
    var buf: [128]u8 = undefined;
    const out = ipc.injectWindowField("{\"cmd\":\"x\"}", .{ .window_id = 1, .window_name = "bad\"name" }, &buf).?;
    try std.testing.expectEqualStrings("{\"cmd\":\"x\",\"__window\":1}", out);
    try std.testing.expect(std.mem.indexOf(u8, out, "__window_name") == null);
}

test "injectWindowField: name에 backslash 있으면 name 생략" {
    var buf: [128]u8 = undefined;
    const out = ipc.injectWindowField("{\"cmd\":\"x\"}", .{ .window_id = 1, .window_name = "weird\\path", .window_url = null }, &buf).?;
    try std.testing.expectEqualStrings("{\"cmd\":\"x\",\"__window\":1}", out);
}

test "injectWindowField: name에 control char (newline) 있으면 name 생략" {
    var buf: [128]u8 = undefined;
    const out = ipc.injectWindowField("{\"cmd\":\"x\"}", .{ .window_id = 1, .window_name = "line1\nline2", .window_url = null }, &buf).?;
    try std.testing.expectEqualStrings("{\"cmd\":\"x\",\"__window\":1}", out);
}

// --- url 필드 -------------------------------------------------------------

test "injectWindowField: url 주입 (name 없을 때)" {
    var buf: [256]u8 = undefined;
    const out = ipc.injectWindowField("{\"cmd\":\"x\"}", .{ .window_id = 2, .window_name = null, .window_url = "http://localhost:5173/" }, &buf).?;
    try std.testing.expectEqualStrings(
        "{\"cmd\":\"x\",\"__window\":2,\"__window_url\":\"http://localhost:5173/\"}",
        out,
    );
}

test "injectWindowField: url + name 둘 다 주입" {
    var buf: [256]u8 = undefined;
    const out = ipc.injectWindowField("{\"cmd\":\"x\"}", .{ .window_id = 2, .window_name = "main", .window_url = "http://localhost/" }, &buf).?;
    try std.testing.expectEqualStrings(
        "{\"cmd\":\"x\",\"__window\":2,\"__window_name\":\"main\",\"__window_url\":\"http://localhost/\"}",
        out,
    );
}

test "injectWindowField: url의 \"/\\ 이스케이프" {
    var buf: [512]u8 = undefined;
    const out = ipc.injectWindowField("{}", .{ .window_id = 1, .window_url = "a\"b\\c" }, &buf).?;
    // 기대: `"a\"b\\c"`로 이스케이프되어 JSON 리터럴 유효.
    try std.testing.expectEqualStrings(
        "{\"__window\":1,\"__window_url\":\"a\\\"b\\\\c\"}",
        out,
    );
}

test "injectWindowField: url의 control char는 drop (JSON 리터럴 유효 유지)" {
    var buf: [256]u8 = undefined;
    const out = ipc.injectWindowField("{}", .{ .window_id = 1, .window_name = null, .window_url = "http://a\x00b/c" }, &buf).?;
    // NUL 바이트 drop 후 "http://ab/c"만 남아야.
    try std.testing.expectEqualStrings(
        "{\"__window\":1,\"__window_url\":\"http://ab/c\"}",
        out,
    );
}

test "injectWindowField: 이미 __window 박혀있으면 url도 재주입 안 함 (cross-hop)" {
    var buf: [256]u8 = undefined;
    const src = "{\"cmd\":\"x\",\"__window\":3}";
    try std.testing.expectEqualStrings(
        src,
        ipc.injectWindowField(src, .{ .window_id = 7, .window_name = "ignored", .window_url = "http://ignored/" }, &buf).?,
    );
}

// --- is_main_frame -----------------------------------------------------

test "injectWindowField: is_main_frame=true 주입" {
    var buf: [256]u8 = undefined;
    const out = ipc.injectWindowField("{\"cmd\":\"x\"}", .{ .window_id = 1, .is_main_frame = true }, &buf).?;
    try std.testing.expectEqualStrings(
        "{\"cmd\":\"x\",\"__window\":1,\"__window_main_frame\":true}",
        out,
    );
}

test "injectWindowField: is_main_frame=false 주입 (iframe)" {
    var buf: [256]u8 = undefined;
    const out = ipc.injectWindowField("{}", .{ .window_id = 2, .is_main_frame = false }, &buf).?;
    try std.testing.expectEqualStrings(
        "{\"__window\":2,\"__window_main_frame\":false}",
        out,
    );
}

test "injectWindowField: is_main_frame null이면 필드 생략" {
    var buf: [256]u8 = undefined;
    const out = ipc.injectWindowField("{\"cmd\":\"x\"}", .{ .window_id = 1 }, &buf).?;
    try std.testing.expect(std.mem.indexOf(u8, out, "__window_main_frame") == null);
}

test "injectWindowField: 모든 필드 동시 주입 순서 (id, name, url, main_frame)" {
    var buf: [512]u8 = undefined;
    const out = ipc.injectWindowField("{}", .{
        .window_id = 5,
        .window_name = "settings",
        .window_url = "http://localhost/",
        .is_main_frame = true,
    }, &buf).?;
    try std.testing.expectEqualStrings(
        "{\"__window\":5,\"__window_name\":\"settings\",\"__window_url\":\"http://localhost/\",\"__window_main_frame\":true}",
        out,
    );
}

// ============================================
// Phase 3 — parseCreateWindowFromJson (평면 JSON → CreateWindowReq)
// ============================================

test "parseCreateWindowFromJson: 기본값 (모든 필드 누락)" {
    const req = ipc.parseCreateWindowFromJson("{}");
    try std.testing.expectEqualStrings("New Window", req.title);
    try std.testing.expectEqual(@as(?[]const u8, null), req.url);
    try std.testing.expectEqual(@as(u32, 800), req.width);
    try std.testing.expectEqual(@as(u32, 600), req.height);
    try std.testing.expectEqual(@as(i32, 0), req.x);
    try std.testing.expectEqual(@as(i32, 0), req.y);
    try std.testing.expect(req.frame);
    try std.testing.expect(!req.transparent);
    try std.testing.expect(req.resizable);
    try std.testing.expect(!req.always_on_top);
    try std.testing.expect(!req.fullscreen);
    try std.testing.expectEqual(window.TitleBarStyle.default, req.title_bar_style);
}

test "parseCreateWindowFromJson: title/url/name/width/height" {
    const req = ipc.parseCreateWindowFromJson(
        "{\"cmd\":\"create_window\",\"title\":\"Hi\",\"url\":\"http://x/\",\"name\":\"main\",\"width\":1024,\"height\":768}",
    );
    try std.testing.expectEqualStrings("Hi", req.title);
    try std.testing.expectEqualStrings("http://x/", req.url.?);
    try std.testing.expectEqualStrings("main", req.name.?);
    try std.testing.expectEqual(@as(u32, 1024), req.width);
    try std.testing.expectEqual(@as(u32, 768), req.height);
}

test "parseCreateWindowFromJson: x/y 음수 (화면 왼쪽 밖 배치 허용)" {
    const req = ipc.parseCreateWindowFromJson("{\"x\":-100,\"y\":-50}");
    try std.testing.expectEqual(@as(i32, -100), req.x);
    try std.testing.expectEqual(@as(i32, -50), req.y);
}

test "parseCreateWindowFromJson: width 음수 → 0 clamp (panic 방지)" {
    const req = ipc.parseCreateWindowFromJson("{\"width\":-50,\"height\":-1}");
    try std.testing.expectEqual(@as(u32, 0), req.width);
    try std.testing.expectEqual(@as(u32, 0), req.height);
}

test "parseCreateWindowFromJson: appearance — frame/transparent/backgroundColor" {
    const req = ipc.parseCreateWindowFromJson(
        "{\"frame\":false,\"transparent\":true,\"backgroundColor\":\"#FF00FF\"}",
    );
    try std.testing.expect(!req.frame);
    try std.testing.expect(req.transparent);
    try std.testing.expectEqualStrings("#FF00FF", req.background_color.?);
}

test "parseCreateWindowFromJson: titleBarStyle hidden / hiddenInset / 미인식" {
    try std.testing.expectEqual(
        window.TitleBarStyle.hidden,
        ipc.parseCreateWindowFromJson("{\"titleBarStyle\":\"hidden\"}").title_bar_style,
    );
    try std.testing.expectEqual(
        window.TitleBarStyle.hidden_inset,
        ipc.parseCreateWindowFromJson("{\"titleBarStyle\":\"hiddenInset\"}").title_bar_style,
    );
    // 미인식은 default 유지 (silent)
    try std.testing.expectEqual(
        window.TitleBarStyle.default,
        ipc.parseCreateWindowFromJson("{\"titleBarStyle\":\"bogus\"}").title_bar_style,
    );
}

test "parseCreateWindowFromJson: constraints — resizable/alwaysOnTop/min·max/fullscreen" {
    const req = ipc.parseCreateWindowFromJson(
        "{\"resizable\":false,\"alwaysOnTop\":true,\"minWidth\":200,\"minHeight\":150,\"maxWidth\":1000,\"maxHeight\":900,\"fullscreen\":true}",
    );
    try std.testing.expect(!req.resizable);
    try std.testing.expect(req.always_on_top);
    try std.testing.expectEqual(@as(u32, 200), req.min_width);
    try std.testing.expectEqual(@as(u32, 150), req.min_height);
    try std.testing.expectEqual(@as(u32, 1000), req.max_width);
    try std.testing.expectEqual(@as(u32, 900), req.max_height);
    try std.testing.expect(req.fullscreen);
}

test "parseCreateWindowFromJson: parentId / parent name 둘 다 노출" {
    const req1 = ipc.parseCreateWindowFromJson("{\"parentId\":42}");
    try std.testing.expectEqual(@as(?u32, 42), req1.parent_id);
    try std.testing.expectEqual(@as(?[]const u8, null), req1.parent_name);

    const req2 = ipc.parseCreateWindowFromJson("{\"parent\":\"main\"}");
    try std.testing.expectEqual(@as(?u32, null), req2.parent_id);
    try std.testing.expectEqualStrings("main", req2.parent_name.?);
}

test "parseCreateWindowFromJson: parentId 음수는 무시" {
    const req = ipc.parseCreateWindowFromJson("{\"parentId\":-1}");
    try std.testing.expectEqual(@as(?u32, null), req.parent_id);
}

// ============================================
// Phase 3 — handleCreateWindow가 sub-struct 매핑까지 전달하는지
// ============================================

test "handleCreateWindow: appearance/constraints가 native.createWindow까지 전달" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();

    var buf: [256]u8 = undefined;
    _ = ipc.handleCreateWindow(.{
        .title = "x",
        .frame = false,
        .transparent = true,
        .background_color = "#000000",
        .title_bar_style = .hidden_inset,
        .resizable = false,
        .always_on_top = true,
        .min_width = 100,
        .max_width = 2000,
        .fullscreen = true,
        .x = -10,
        .y = 20,
        .width = 500,
        .height = 400,
    }, &buf, &wm).?;

    const ap = native.last_appearance.?;
    try std.testing.expect(!ap.frame);
    try std.testing.expect(ap.transparent);
    try std.testing.expectEqualStrings("#000000", ap.background_color.?);
    try std.testing.expectEqual(window.TitleBarStyle.hidden_inset, ap.title_bar_style);

    const co = native.last_constraints.?;
    try std.testing.expect(!co.resizable);
    try std.testing.expect(co.always_on_top);
    try std.testing.expectEqual(@as(u32, 100), co.min_width);
    try std.testing.expectEqual(@as(u32, 2000), co.max_width);
    try std.testing.expect(co.fullscreen);

    const bd = native.last_create_bounds.?;
    try std.testing.expectEqual(@as(i32, -10), bd.x);
    try std.testing.expectEqual(@as(i32, 20), bd.y);
    try std.testing.expectEqual(@as(u32, 500), bd.width);
    try std.testing.expectEqual(@as(u32, 400), bd.height);
}

test "handleCreateWindow: parent_id 직접 지정 → CreateOptions.parent_id 전달" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();

    // parent 후보 창 먼저 생성
    const parent_id = try wm.create(.{ .name = "parent-win" });
    var buf: [256]u8 = undefined;
    _ = ipc.handleCreateWindow(.{ .parent_id = parent_id }, &buf, &wm).?;

    try std.testing.expectEqual(@as(?u32, parent_id), native.last_parent_id);
}

test "handleCreateWindow: parent_name → wm.fromName으로 resolve" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();

    const parent_id = try wm.create(.{ .name = "shell" });
    var buf: [256]u8 = undefined;
    _ = ipc.handleCreateWindow(.{ .parent_name = "shell" }, &buf, &wm).?;

    try std.testing.expectEqual(@as(?u32, parent_id), native.last_parent_id);
}

test "handleCreateWindow: parent_id가 parent_name보다 우선" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();

    const a = try wm.create(.{ .name = "a" });
    _ = try wm.create(.{ .name = "b" });

    var buf: [256]u8 = undefined;
    _ = ipc.handleCreateWindow(.{
        .parent_id = a,
        .parent_name = "b", // 무시되어야 함
    }, &buf, &wm).?;

    try std.testing.expectEqual(@as(?u32, a), native.last_parent_id);
}

test "handleCreateWindow: parent_name 미존재면 parent_id null (silent)" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();

    var buf: [256]u8 = undefined;
    _ = ipc.handleCreateWindow(.{ .parent_name = "ghost" }, &buf, &wm).?;

    try std.testing.expectEqual(@as(?u32, null), native.last_parent_id);
}

// ============================================
// Phase 4-A: webContents IPC 핸들러
// ============================================

test "handleLoadUrl: native까지 URL 전달 + ok:true 응답" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();
    _ = try wm.create(.{});
    var buf: [256]u8 = undefined;
    const resp = ipc.handleLoadUrl(.{ .window_id = 1, .url = "http://x/" }, &buf, &wm).?;
    try std.testing.expectEqualStrings("http://x/", native.last_loaded_url.?);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"cmd\":\"load_url\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"ok\":true") != null);
}

test "handleLoadUrl: 알 수 없는 id면 ok:false (native 미호출)" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();
    var buf: [256]u8 = undefined;
    const resp = ipc.handleLoadUrl(.{ .window_id = 999, .url = "x" }, &buf, &wm).?;
    try std.testing.expectEqual(@as(usize, 0), native.load_url_calls);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"ok\":false") != null);
}

test "handleReload: ignore_cache 플래그가 native까지 전달" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();
    _ = try wm.create(.{});
    var buf: [256]u8 = undefined;
    _ = ipc.handleReload(.{ .window_id = 1, .ignore_cache = true }, &buf, &wm).?;
    try std.testing.expectEqual(@as(?bool, true), native.last_reload_ignore_cache);
}

test "handleExecuteJavascript: code가 native까지 전달" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();
    _ = try wm.create(.{});
    var buf: [256]u8 = undefined;
    _ = ipc.handleExecuteJavascript(.{ .window_id = 1, .code = "alert(1)" }, &buf, &wm).?;
    try std.testing.expectEqualStrings("alert(1)", native.last_executed_js.?);
}

test "handleGetUrl: stub URL이 응답에 escape돼서 포함" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();
    _ = try wm.create(.{});
    native.stub_url = "http://localhost/path?q=a&b=c";
    var buf: [512]u8 = undefined;
    const resp = ipc.handleGetUrl(1, &buf, &wm).?;
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"url\":\"http://localhost/path?q=a&b=c\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"ok\":true") != null);
}

test "handleGetUrl: stub_url null이면 url:null + ok:false" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();
    _ = try wm.create(.{});
    var buf: [256]u8 = undefined;
    const resp = ipc.handleGetUrl(1, &buf, &wm).?;
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"url\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"ok\":false") != null);
}

test "handleGetUrl: URL에 \\\" 있으면 escape 처리" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();
    _ = try wm.create(.{});
    native.stub_url = "http://x/\"a\\b";
    var buf: [512]u8 = undefined;
    const resp = ipc.handleGetUrl(1, &buf, &wm).?;
    try std.testing.expect(std.mem.indexOf(u8, resp, "\\\"a\\\\b") != null);
}

test "handleIsLoading: stub 값이 응답 loading 필드로" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();
    _ = try wm.create(.{});
    var buf: [256]u8 = undefined;
    const r1 = ipc.handleIsLoading(1, &buf, &wm).?;
    try std.testing.expect(std.mem.indexOf(u8, r1, "\"loading\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, r1, "\"ok\":true") != null);
    native.stub_is_loading = true;
    const r2 = ipc.handleIsLoading(1, &buf, &wm).?;
    try std.testing.expect(std.mem.indexOf(u8, r2, "\"loading\":true") != null);
}

test "Phase 4-A 응답들 valid JSON (parsable)" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();
    _ = try wm.create(.{});

    var buf: [512]u8 = undefined;
    const r = ipc.handleLoadUrl(.{ .window_id = 1, .url = "http://x/" }, &buf, &wm).?;
    const Parsed = struct { from: []const u8, cmd: []const u8, windowId: u32, ok: bool };
    const parsed = try std.json.parseFromSlice(Parsed, std.testing.allocator, r, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("zig-core", parsed.value.from);
    try std.testing.expectEqualStrings("load_url", parsed.value.cmd);
    try std.testing.expect(parsed.value.ok);
}

test "Phase 4-A 모든 핸들러: 작은 버퍼면 null" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();
    _ = try wm.create(.{});
    var tiny: [3]u8 = undefined;
    try std.testing.expect(ipc.handleLoadUrl(.{ .window_id = 1, .url = "x" }, &tiny, &wm) == null);
    try std.testing.expect(ipc.handleReload(.{ .window_id = 1 }, &tiny, &wm) == null);
    try std.testing.expect(ipc.handleExecuteJavascript(.{ .window_id = 1, .code = "x" }, &tiny, &wm) == null);
    try std.testing.expect(ipc.handleGetUrl(1, &tiny, &wm) == null);
    try std.testing.expect(ipc.handleIsLoading(1, &tiny, &wm) == null);
}

// ============================================
// Phase 4-C: DevTools IPC 핸들러
// ============================================

test "handleOpenDevTools / handleCloseDevTools: native 호출 + ok:true 응답" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();
    _ = try wm.create(.{});
    var buf: [256]u8 = undefined;

    const r1 = ipc.handleOpenDevTools(1, &buf, &wm).?;
    try std.testing.expectEqual(@as(usize, 1), native.open_dev_tools_calls);
    try std.testing.expect(std.mem.indexOf(u8, r1, "\"cmd\":\"open_dev_tools\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r1, "\"ok\":true") != null);

    const r2 = ipc.handleCloseDevTools(1, &buf, &wm).?;
    try std.testing.expectEqual(@as(usize, 1), native.close_dev_tools_calls);
    try std.testing.expect(std.mem.indexOf(u8, r2, "\"cmd\":\"close_dev_tools\"") != null);
}

test "handleToggleDevTools: 호출마다 native toggle + 응답" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();
    _ = try wm.create(.{});
    var buf: [256]u8 = undefined;
    const r = ipc.handleToggleDevTools(1, &buf, &wm).?;
    try std.testing.expectEqual(@as(usize, 1), native.toggle_dev_tools_calls);
    try std.testing.expect(std.mem.indexOf(u8, r, "\"cmd\":\"toggle_dev_tools\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "\"ok\":true") != null);
}

test "handleIsDevToolsOpened: stub 값이 응답 opened 필드로" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();
    _ = try wm.create(.{});
    var buf: [256]u8 = undefined;
    const r1 = ipc.handleIsDevToolsOpened(1, &buf, &wm).?;
    try std.testing.expect(std.mem.indexOf(u8, r1, "\"opened\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, r1, "\"ok\":true") != null);
    native.stub_dev_tools_opened = true;
    const r2 = ipc.handleIsDevToolsOpened(1, &buf, &wm).?;
    try std.testing.expect(std.mem.indexOf(u8, r2, "\"opened\":true") != null);
}

test "Phase 4-C 핸들러: 알 수 없는 id면 ok:false" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();
    var buf: [256]u8 = undefined;
    const r = ipc.handleOpenDevTools(999, &buf, &wm).?;
    try std.testing.expectEqual(@as(usize, 0), native.open_dev_tools_calls);
    try std.testing.expect(std.mem.indexOf(u8, r, "\"ok\":false") != null);
}

// ============================================
// 회귀 테스트 — handleDevToolsOp 헬퍼 통합 (commit 73)
//
// open/close/toggle 핸들러는 이제 wm 메서드 함수 포인터만 다른 동일 헬퍼.
// 각 핸들러가 자기 cmd 이름과 자기 wm 메서드를 정확히 호출함을 회귀로 고정.
// ============================================

test "handleDevToolsOp: 각 핸들러가 자기 cmd 이름을 응답에 정확히 포함" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();
    _ = try wm.create(.{});

    var buf: [256]u8 = undefined;
    const open = ipc.handleOpenDevTools(1, &buf, &wm).?;
    try std.testing.expect(std.mem.indexOf(u8, open, "\"cmd\":\"open_dev_tools\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, open, "\"cmd\":\"close_dev_tools\"") == null);

    const close = ipc.handleCloseDevTools(1, &buf, &wm).?;
    try std.testing.expect(std.mem.indexOf(u8, close, "\"cmd\":\"close_dev_tools\"") != null);

    const toggle = ipc.handleToggleDevTools(1, &buf, &wm).?;
    try std.testing.expect(std.mem.indexOf(u8, toggle, "\"cmd\":\"toggle_dev_tools\"") != null);
}

test "handleDevToolsOp: 각 핸들러가 자기 wm 메서드만 호출 (cross-call 없음)" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();
    _ = try wm.create(.{});
    var buf: [256]u8 = undefined;

    _ = ipc.handleOpenDevTools(1, &buf, &wm).?;
    try std.testing.expectEqual(@as(usize, 1), native.open_dev_tools_calls);
    try std.testing.expectEqual(@as(usize, 0), native.close_dev_tools_calls);
    try std.testing.expectEqual(@as(usize, 0), native.toggle_dev_tools_calls);

    _ = ipc.handleCloseDevTools(1, &buf, &wm).?;
    try std.testing.expectEqual(@as(usize, 1), native.close_dev_tools_calls);
    try std.testing.expectEqual(@as(usize, 0), native.toggle_dev_tools_calls);

    _ = ipc.handleToggleDevTools(1, &buf, &wm).?;
    try std.testing.expectEqual(@as(usize, 1), native.toggle_dev_tools_calls);
}

// ============================================
// Phase 4-B: 줌 IPC 핸들러
// ============================================

test "handleSetZoomLevel: native 호출 + windowOp 응답" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();
    _ = try wm.create(.{});
    var buf: [256]u8 = undefined;
    const r = ipc.handleSetZoomLevel(.{ .window_id = 1, .value = 2.0 }, &buf, &wm).?;
    try std.testing.expectEqual(@as(usize, 1), native.set_zoom_level_calls);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), native.stub_zoom_level, 1e-9);
    try std.testing.expect(std.mem.indexOf(u8, r, "\"cmd\":\"set_zoom_level\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "\"ok\":true") != null);
}

test "handleSetZoomFactor: factor → level 변환 후 native 호출" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();
    _ = try wm.create(.{});
    var buf: [256]u8 = undefined;
    const r = ipc.handleSetZoomFactor(.{ .window_id = 1, .value = 1.2 }, &buf, &wm).?;
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), native.stub_zoom_level, 1e-9); // log(1.2)/log(1.2) = 1
    try std.testing.expect(std.mem.indexOf(u8, r, "\"cmd\":\"set_zoom_factor\"") != null);
}

test "handleGetZoomLevel: stub 값이 응답 level 필드로" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();
    _ = try wm.create(.{});
    native.stub_zoom_level = 1.5;
    var buf: [256]u8 = undefined;
    const r = ipc.handleGetZoomLevel(1, &buf, &wm).?;
    try std.testing.expect(std.mem.indexOf(u8, r, "\"level\":1.5") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "\"ok\":true") != null);
}

test "handleGetZoomFactor: pow(1.2, level)로 변환 응답" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();
    _ = try wm.create(.{});
    native.stub_zoom_level = 1; // factor = 1.2
    var buf: [256]u8 = undefined;
    const r = ipc.handleGetZoomFactor(1, &buf, &wm).?;
    // bufPrint {d}는 실수 정밀도라 "1.2"가 아닌 "1.2000..." 가능 — substring 확인
    try std.testing.expect(std.mem.indexOf(u8, r, "\"factor\":1.2") != null);
}

// ============================================
// Phase 4-E: 편집 + 검색 IPC 핸들러
// ============================================

test "편집 6 핸들러: 자기 cmd 이름과 wm 메서드만 호출" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();
    _ = try wm.create(.{});
    var buf: [256]u8 = undefined;

    const handlers = .{
        .{ "undo", &ipc.handleUndo },
        .{ "redo", &ipc.handleRedo },
        .{ "cut", &ipc.handleCut },
        .{ "copy", &ipc.handleCopy },
        .{ "paste", &ipc.handlePaste },
        .{ "select_all", &ipc.handleSelectAll },
    };
    inline for (handlers) |h| {
        const r = h[1](1, &buf, &wm).?;
        try std.testing.expect(std.mem.indexOf(u8, r, "\"cmd\":\"" ++ h[0] ++ "\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, r, "\"ok\":true") != null);
        try std.testing.expectEqual(@as(usize, 1), @field(native.edit_calls, h[0]));
    }
}

test "handleFindInPage: text + 3 플래그가 native까지 전달" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();
    _ = try wm.create(.{});
    var buf: [256]u8 = undefined;
    const r = ipc.handleFindInPage(.{
        .window_id = 1,
        .text = "needle",
        .forward = false,
        .match_case = true,
        .find_next = true,
    }, &buf, &wm).?;
    try std.testing.expectEqualStrings("needle", native.last_find_text.?);
    try std.testing.expect(!native.last_find_forward);
    try std.testing.expect(native.last_find_match_case);
    try std.testing.expect(native.last_find_next);
    try std.testing.expect(std.mem.indexOf(u8, r, "\"cmd\":\"find_in_page\"") != null);
}

test "handleStopFindInPage: clearSelection 전달" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();
    _ = try wm.create(.{});
    var buf: [256]u8 = undefined;
    _ = ipc.handleStopFindInPage(1, true, &buf, &wm).?;
    try std.testing.expect(native.last_stop_find_clear);
    try std.testing.expectEqual(@as(usize, 1), native.stop_find_calls);
}

test "Phase 4-E 핸들러: 알 수 없는 id면 ok:false" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();
    var buf: [256]u8 = undefined;
    const r1 = ipc.handleUndo(999, &buf, &wm).?;
    try std.testing.expect(std.mem.indexOf(u8, r1, "\"ok\":false") != null);
    const r2 = ipc.handleFindInPage(.{ .window_id = 999, .text = "x" }, &buf, &wm).?;
    try std.testing.expect(std.mem.indexOf(u8, r2, "\"ok\":false") != null);
}

// ============================================
// Phase 4-D: printToPDF IPC 핸들러
// ============================================

test "handlePrintToPDF: path가 native까지 전달 + ok 응답" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();
    _ = try wm.create(.{});
    var buf: [256]u8 = undefined;
    const r = ipc.handlePrintToPDF(.{ .window_id = 1, .path = "/tmp/report.pdf" }, &buf, &wm).?;
    try std.testing.expectEqualStrings("/tmp/report.pdf", native.last_print_path.?);
    try std.testing.expect(std.mem.indexOf(u8, r, "\"cmd\":\"print_to_pdf\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "\"ok\":true") != null);
}

test "handlePrintToPDF: 알 수 없는 id면 ok:false (native 미호출)" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();
    var buf: [256]u8 = undefined;
    const r = ipc.handlePrintToPDF(.{ .window_id = 999, .path = "/tmp/x.pdf" }, &buf, &wm).?;
    try std.testing.expectEqual(@as(usize, 0), native.print_to_pdf_calls);
    try std.testing.expect(std.mem.indexOf(u8, r, "\"ok\":false") != null);
}

test "줌 핸들러: 알 수 없는 id면 ok:false" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();
    var buf: [256]u8 = undefined;
    const r1 = ipc.handleSetZoomLevel(.{ .window_id = 999, .value = 1 }, &buf, &wm).?;
    try std.testing.expect(std.mem.indexOf(u8, r1, "\"ok\":false") != null);
    const r2 = ipc.handleGetZoomLevel(999, &buf, &wm).?;
    try std.testing.expect(std.mem.indexOf(u8, r2, "\"ok\":false") != null);
}

test "handleDevToolsOp: 모든 핸들러 작은 버퍼면 null (회귀)" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();
    _ = try wm.create(.{});
    var tiny: [3]u8 = undefined;
    try std.testing.expect(ipc.handleOpenDevTools(1, &tiny, &wm) == null);
    try std.testing.expect(ipc.handleCloseDevTools(1, &tiny, &wm) == null);
    try std.testing.expect(ipc.handleToggleDevTools(1, &tiny, &wm) == null);
    try std.testing.expect(ipc.handleIsDevToolsOpened(1, &tiny, &wm) == null);
    // 작은 버퍼 시 native는 호출되지 않아야 (응답 보장 invariant).
    try std.testing.expectEqual(@as(usize, 0), native.open_dev_tools_calls);
    try std.testing.expectEqual(@as(usize, 0), native.close_dev_tools_calls);
    try std.testing.expectEqual(@as(usize, 0), native.toggle_dev_tools_calls);
}

// ============================================
// Phase 17-A: WebContentsView IPC 핸들러
// ============================================

test "17-A: parseCreateViewFromJson extracts hostId/url/name/bounds" {
    const json =
        \\{"cmd":"create_view","hostId":7,"url":"https://example.com","name":"side","x":10,"y":20,"width":300,"height":400}
    ;
    const req = ipc.parseCreateViewFromJson(json);
    try std.testing.expectEqual(@as(u32, 7), req.host_window_id);
    try std.testing.expectEqualStrings("https://example.com", req.url.?);
    try std.testing.expectEqualStrings("side", req.name.?);
    try std.testing.expectEqual(@as(i32, 10), req.bounds.x);
    try std.testing.expectEqual(@as(u32, 300), req.bounds.width);
}

test "17-A: handleCreateView calls wm.createView and returns viewId" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();
    const host = try wm.create(.{});

    var buf: [256]u8 = undefined;
    const out = ipc.handleCreateView(.{
        .host_window_id = host,
        .url = "https://x.com",
        .bounds = .{ .x = 0, .y = 0, .width = 100, .height = 200 },
    }, &buf, &wm).?;

    try std.testing.expect(std.mem.indexOf(u8, out, "\"cmd\":\"create_view\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"viewId\":2") != null);
    try std.testing.expectEqual(@as(usize, 1), native.create_view_calls);
}

test "17-A: handleCreateView with InvalidName returns error response" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();
    const host = try wm.create(.{});
    var buf: [256]u8 = undefined;
    const out = ipc.handleCreateView(.{
        .host_window_id = host,
        .name = "bad\"name",
    }, &buf, &wm).?;
    try std.testing.expect(std.mem.indexOf(u8, out, "\"error\":\"invalid name\"") != null);
    try std.testing.expectEqual(@as(usize, 0), native.create_view_calls);
}

test "17-A: handleCreateView with non-existent host returns error" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();
    var buf: [256]u8 = undefined;
    const out = ipc.handleCreateView(.{ .host_window_id = 999 }, &buf, &wm).?;
    try std.testing.expect(std.mem.indexOf(u8, out, "\"error\":\"failed\"") != null);
}

test "17-A: handleDestroyView returns ok:true on live view" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();
    const host = try wm.create(.{});
    const view = try wm.createView(.{ .host_window_id = host });

    var buf: [256]u8 = undefined;
    const out = ipc.handleDestroyView(view, &buf, &wm).?;
    try std.testing.expect(std.mem.indexOf(u8, out, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"viewId\":2") != null);
    try std.testing.expectEqual(@as(usize, 1), native.destroy_view_calls);
}

test "17-A: handleDestroyView on .window returns ok:false" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();
    const w = try wm.create(.{});
    var buf: [256]u8 = undefined;
    const out = ipc.handleDestroyView(w, &buf, &wm).?;
    try std.testing.expect(std.mem.indexOf(u8, out, "\"ok\":false") != null);
    try std.testing.expectEqual(@as(usize, 0), native.destroy_view_calls);
}

test "17-A: handleAddChildView reorders + responds with viewId" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();
    const host = try wm.create(.{});
    const v1 = try wm.createView(.{ .host_window_id = host });
    const v2 = try wm.createView(.{ .host_window_id = host });

    var buf: [256]u8 = undefined;
    const out = ipc.handleAddChildView(.{ .host_id = host, .view_id = v1, .index = null }, &buf, &wm).?;
    try std.testing.expect(std.mem.indexOf(u8, out, "\"ok\":true") != null);
    const ids = try wm.getChildViews(host, std.testing.allocator);
    defer std.testing.allocator.free(ids);
    try std.testing.expectEqual(v2, ids[0]);
    try std.testing.expectEqual(v1, ids[1]);
}

test "17-A: handleSetTopView is alias of addChildView(null)" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();
    const host = try wm.create(.{});
    const v1 = try wm.createView(.{ .host_window_id = host });
    _ = try wm.createView(.{ .host_window_id = host });

    var buf: [256]u8 = undefined;
    const out = ipc.handleSetTopView(host, v1, &buf, &wm).?;
    try std.testing.expect(std.mem.indexOf(u8, out, "\"cmd\":\"set_top_view\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"ok\":true") != null);
}

test "17-A: handleRemoveChildView ok and view stays alive" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();
    const host = try wm.create(.{});
    const view = try wm.createView(.{ .host_window_id = host });

    var buf: [256]u8 = undefined;
    const out = ipc.handleRemoveChildView(host, view, &buf, &wm).?;
    try std.testing.expect(std.mem.indexOf(u8, out, "\"ok\":true") != null);
    try std.testing.expect(!wm.get(view).?.destroyed);
    try std.testing.expectEqual(@as(usize, 0), native.destroy_view_calls);
}

test "17-A: handleSetViewBounds forwards to wm.setViewBounds" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();
    const host = try wm.create(.{});
    const view = try wm.createView(.{ .host_window_id = host });

    var buf: [256]u8 = undefined;
    const out = ipc.handleSetViewBounds(.{
        .view_id = view,
        .x = 10,
        .y = 20,
        .width = 300,
        .height = 400,
    }, &buf, &wm).?;
    try std.testing.expect(std.mem.indexOf(u8, out, "\"ok\":true") != null);
    try std.testing.expectEqual(@as(u32, 300), native.last_view_bounds.?.width);
}

test "17-A: handleSetViewVisible toggle ok + native call" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();
    const host = try wm.create(.{});
    const view = try wm.createView(.{ .host_window_id = host });

    var buf: [256]u8 = undefined;
    const out = ipc.handleSetViewVisible(view, false, &buf, &wm).?;
    try std.testing.expect(std.mem.indexOf(u8, out, "\"ok\":true") != null);
    try std.testing.expectEqual(@as(?bool, false), native.last_set_view_visible);
}

test "17-A: handleGetChildViews emits ordered viewIds array" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();
    const host = try wm.create(.{});
    _ = try wm.createView(.{ .host_window_id = host });
    _ = try wm.createView(.{ .host_window_id = host });

    var buf: [256]u8 = undefined;
    const out = ipc.handleGetChildViews(host, &buf, &wm, std.testing.allocator).?;
    try std.testing.expect(std.mem.indexOf(u8, out, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"viewIds\":[2,3]") != null);
}

test "17-A: handleGetChildViews on empty host returns viewIds:[]" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();
    const host = try wm.create(.{});

    var buf: [256]u8 = undefined;
    const out = ipc.handleGetChildViews(host, &buf, &wm, std.testing.allocator).?;
    try std.testing.expect(std.mem.indexOf(u8, out, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"viewIds\":[]") != null);
}

test "17-A: handleGetChildViews on non-window host returns ok:false" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();
    const host = try wm.create(.{});
    const view = try wm.createView(.{ .host_window_id = host });

    var buf: [256]u8 = undefined;
    // view를 host로 사용 → NotAWindow → ok:false
    const out = ipc.handleGetChildViews(view, &buf, &wm, std.testing.allocator).?;
    try std.testing.expect(std.mem.indexOf(u8, out, "\"ok\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"viewIds\":[]") != null);
}

test "17-A: view 핸들러 모두 작은 버퍼면 null (회귀)" {
    var native = TestNative{};
    var wm = newWm(&native);
    defer wm.deinit();
    const host = try wm.create(.{});
    const view = try wm.createView(.{ .host_window_id = host });

    var tiny: [3]u8 = undefined;
    try std.testing.expect(ipc.handleCreateView(.{ .host_window_id = host }, &tiny, &wm) == null);
    try std.testing.expect(ipc.handleDestroyView(view, &tiny, &wm) == null);
    try std.testing.expect(ipc.handleAddChildView(.{ .host_id = host, .view_id = view }, &tiny, &wm) == null);
    try std.testing.expect(ipc.handleRemoveChildView(host, view, &tiny, &wm) == null);
    try std.testing.expect(ipc.handleSetTopView(host, view, &tiny, &wm) == null);
    try std.testing.expect(ipc.handleSetViewBounds(.{ .view_id = view }, &tiny, &wm) == null);
    try std.testing.expect(ipc.handleSetViewVisible(view, true, &tiny, &wm) == null);
    try std.testing.expect(ipc.handleGetChildViews(host, &tiny, &wm, std.testing.allocator) == null);
}
