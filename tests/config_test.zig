const std = @import("std");
const config = @import("config");

// ============================================
// 기본값 테스트
// ============================================

test "Config default values" {
    const cfg = config.Config{};
    try std.testing.expectEqualStrings("Suji App", cfg.app.name);
    try std.testing.expectEqualStrings("0.1.0", cfg.app.version);
    // 기본 windows: 1개 항목 (Window 기본값)
    try std.testing.expectEqual(@as(usize, 1), cfg.windows.len);
    try std.testing.expectEqual(@as(i64, 1024), cfg.windows[0].width);
    try std.testing.expectEqual(@as(i64, 768), cfg.windows[0].height);
    try std.testing.expectEqualStrings("Suji App", cfg.windows[0].title);
    try std.testing.expect(!cfg.windows[0].debug);
    try std.testing.expect(cfg.windows[0].protocol == .file);
    try std.testing.expect(cfg.windows[0].name == null);
    try std.testing.expect(cfg.windows[0].url == null);
    try std.testing.expect(cfg.windows[0].visible);
    // Phase 3 신규 필드 default
    try std.testing.expect(cfg.windows[0].frame);
    try std.testing.expect(!cfg.windows[0].transparent);
    try std.testing.expect(cfg.windows[0].parent == null);
    try std.testing.expect(cfg.backend == null);
    try std.testing.expect(cfg.backends == null);
    try std.testing.expectEqualStrings("frontend", cfg.frontend.dir);
    try std.testing.expectEqualStrings("http://localhost:5173", cfg.frontend.dev_url);
    try std.testing.expectEqualStrings("frontend/dist", cfg.frontend.dist_dir);
}


test "Config protocol default is file" {
    const cfg = config.Config{};
    try std.testing.expect(cfg.windows[0].protocol == .file);
}

test "Config protocol enum values" {
    const suji_proto: config.Config.Protocol = .suji;
    const file_proto: config.Config.Protocol = .file;
    try std.testing.expect(suji_proto != file_proto);
}

test "Config default SingleBackend" {
    const be = config.Config.SingleBackend{};
    try std.testing.expectEqualStrings("zig", be.lang);
    try std.testing.expectEqualStrings("src/main.zig", be.entry);
}

test "Config default Frontend" {
    const fe = config.Config.Frontend{};
    try std.testing.expectEqualStrings("frontend", fe.dir);
    try std.testing.expectEqualStrings("http://localhost:5173", fe.dev_url);
    try std.testing.expectEqualStrings("frontend/dist", fe.dist_dir);
}

// ============================================
// isMultiBackend / getBackendCount
// ============================================

test "Config isMultiBackend false when no backends" {
    const cfg = config.Config{};
    try std.testing.expect(!cfg.isMultiBackend());
}

test "Config isMultiBackend false when single backend" {
    var cfg = config.Config{};
    cfg.backend = .{ .lang = "rust", .entry = "src/lib.rs" };
    try std.testing.expect(!cfg.isMultiBackend());
}

test "Config getBackendCount zero" {
    const cfg = config.Config{};
    try std.testing.expectEqual(@as(usize, 0), cfg.getBackendCount());
}

test "Config getBackendCount single" {
    var cfg = config.Config{};
    cfg.backend = .{ .lang = "rust", .entry = "src/lib.rs" };
    try std.testing.expectEqual(@as(usize, 1), cfg.getBackendCount());
}

// ============================================
// Config.load (파일 기반)
// ============================================

// Config.load는 cwd 기반이라 단위 테스트에서 안정적으로 테스트 불가
// 통합 테스트(suji dev 실행)로 검증

// ============================================
// JSON 파싱 검증
// ============================================

// 테스트 헬퍼: parseFromSlice + root.object 추출. caller가 std.json.Parsed를 deinit.
// 사용 패턴:
//   const parsed = try parseRoot(json_content);
//   defer parsed.deinit();
//   const root = parsed.value.object;
fn parseRoot(json: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
}

// windows 배열 첫 항목 빠른 접근 — protocol/partial 테스트들이 반복 사용.
fn firstWindow(root: std.json.ObjectMap) std.json.ObjectMap {
    return root.get("windows").?.array.items[0].object;
}

test "JSON single backend parsing" {
    const json_content =
        \\{
        \\  "app": { "name": "Test App", "version": "1.0.0" },
        \\  "windows": [{ "name": "main", "title": "Test", "width": 1024, "height": 768, "debug": true }],
        \\  "backend": { "lang": "rust", "entry": "src/lib.rs" },
        \\  "frontend": { "dir": "web", "dev_url": "http://localhost:3000", "dist_dir": "web/build" }
        \\}
    ;

    const parsed = try parseRoot(json_content);
    defer parsed.deinit();
    const root = parsed.value.object;

    // app
    const app = root.get("app").?.object;
    try std.testing.expectEqualStrings("Test App", app.get("name").?.string);
    try std.testing.expectEqualStrings("1.0.0", app.get("version").?.string);

    // windows[0]
    const wins = root.get("windows").?.array;
    try std.testing.expectEqual(@as(usize, 1), wins.items.len);
    const win = wins.items[0].object;
    try std.testing.expectEqualStrings("main", win.get("name").?.string);
    try std.testing.expectEqualStrings("Test", win.get("title").?.string);
    try std.testing.expectEqual(@as(i64, 1024), win.get("width").?.integer);
    try std.testing.expectEqual(@as(i64, 768), win.get("height").?.integer);
    try std.testing.expect(win.get("debug").?.bool);

    // backend
    const be = root.get("backend").?.object;
    try std.testing.expectEqualStrings("rust", be.get("lang").?.string);
    try std.testing.expectEqualStrings("src/lib.rs", be.get("entry").?.string);

    // frontend
    const fe = root.get("frontend").?.object;
    try std.testing.expectEqualStrings("web", fe.get("dir").?.string);
    try std.testing.expectEqualStrings("http://localhost:3000", fe.get("dev_url").?.string);
    try std.testing.expectEqualStrings("web/build", fe.get("dist_dir").?.string);
}

test "JSON multi-backend parsing" {
    const json_content =
        \\{
        \\  "backends": [
        \\    { "name": "rust", "lang": "rust", "entry": "backends/rust" },
        \\    { "name": "go", "lang": "go", "entry": "backends/go" }
        \\  ]
        \\}
    ;

    const parsed = try parseRoot(json_content);
    defer parsed.deinit();
    const root = parsed.value.object;

    const bs = root.get("backends").?.array;
    try std.testing.expectEqual(@as(usize, 2), bs.items.len);

    try std.testing.expectEqualStrings("rust", bs.items[0].object.get("name").?.string);
    try std.testing.expectEqualStrings("rust", bs.items[0].object.get("lang").?.string);
    try std.testing.expectEqualStrings("backends/rust", bs.items[0].object.get("entry").?.string);

    try std.testing.expectEqualStrings("go", bs.items[1].object.get("name").?.string);
    try std.testing.expectEqualStrings("go", bs.items[1].object.get("lang").?.string);
    try std.testing.expectEqualStrings("backends/go", bs.items[1].object.get("entry").?.string);
}

test "JSON minimal config" {
    const json_content = "{}";
    const parsed = try parseRoot(json_content);
    defer parsed.deinit();

    // 빈 JSON도 파싱 성공 (기본값 사용)
    try std.testing.expect(parsed.value == .object);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.object.count());
}

test "JSON partial config" {
    const json_content =
        \\{ "windows": [{ "width": 1920 }] }
    ;
    const parsed = try parseRoot(json_content);
    defer parsed.deinit();
    const root = parsed.value.object;

    // windows만 있고 나머지 없음
    try std.testing.expect(root.get("app") == null);
    try std.testing.expect(root.get("backend") == null);
    const wins = root.get("windows").?.array;
    try std.testing.expectEqual(@as(i64, 1920), wins.items[0].object.get("width").?.integer);
}

test "JSON protocol suji parsing" {
    const parsed = try parseRoot("{ \"windows\": [{ \"protocol\": \"suji\" }] }");
    defer parsed.deinit();
    try std.testing.expectEqualStrings("suji", firstWindow(parsed.value.object).get("protocol").?.string);
}

test "JSON protocol file parsing" {
    const parsed = try parseRoot("{ \"windows\": [{ \"protocol\": \"file\" }] }");
    defer parsed.deinit();
    try std.testing.expectEqualStrings("file", firstWindow(parsed.value.object).get("protocol").?.string);
}

test "JSON protocol absent defaults to file" {
    const parsed = try parseRoot("{ \"windows\": [{ \"title\": \"Test\" }] }");
    defer parsed.deinit();
    try std.testing.expect(firstWindow(parsed.value.object).get("protocol") == null);
}

// Phase 3: frame / transparent / parent
test "JSON window with frame=false / transparent=true / parent" {
    const parsed = try parseRoot(
        \\{ "windows": [
        \\  { "name": "main" },
        \\  { "name": "panel", "frame": false, "transparent": true, "parent": "main" }
        \\] }
    );
    defer parsed.deinit();
    const wins = parsed.value.object.get("windows").?.array;
    const panel = wins.items[1].object;
    try std.testing.expect(!panel.get("frame").?.bool);
    try std.testing.expect(panel.get("transparent").?.bool);
    try std.testing.expectEqualStrings("main", panel.get("parent").?.string);
}

test "Window struct default — frame/transparent/parent" {
    const w = config.Config.Window{};
    try std.testing.expect(w.frame);
    try std.testing.expect(!w.transparent);
    try std.testing.expectEqual(@as(?[:0]const u8, null), w.parent);
}

// Phase 2 마무리: 다중 창 선언 — Tauri 호환
test "JSON multiple windows parsing" {
    const json_content =
        \\{
        \\  "windows": [
        \\    { "name": "main", "title": "Main", "width": 1024 },
        \\    { "name": "settings", "title": "Settings", "width": 600, "url": "http://localhost:5173/settings" }
        \\  ]
        \\}
    ;
    const parsed = try parseRoot(json_content);
    defer parsed.deinit();
    const root = parsed.value.object;
    const wins = root.get("windows").?.array;
    try std.testing.expectEqual(@as(usize, 2), wins.items.len);
    try std.testing.expectEqualStrings("main", wins.items[0].object.get("name").?.string);
    try std.testing.expectEqualStrings("settings", wins.items[1].object.get("name").?.string);
    try std.testing.expectEqualStrings("http://localhost:5173/settings", wins.items[1].object.get("url").?.string);
}

test "Config deinit without arena" {
    var cfg = config.Config{};
    cfg.deinit(); // arena 없어도 크래시 안 남
}

// ============================================
// 회귀 테스트 — Config._arena는 반드시 포인터
// ============================================
//
// 값 필드로 바꾸면 `Config { ._arena = arena }` 시점에 ArenaAllocator의 state가 복사되고,
// 이후 동일 arena를 통한 할당은 stack 원본에만 기록됨. loadJson return 시 스택이 사라지면
// 그 뒤에 붙은 buffer들이 deinit 경로에 잡히지 않아 leak (JSON 파서 내부 allocation 등).
test "Config._arena must be a pointer to ArenaAllocator (not a value)" {
    const T = comptime blk: {
        const fields = @typeInfo(config.Config).@"struct".fields;
        for (fields) |f| {
            if (std.mem.eql(u8, f.name, "_arena")) break :blk f.type;
        }
        @compileError("Config._arena field missing");
    };
    // ?*ArenaAllocator 형태여야 함 — optional을 풀어 pointer인지 확인.
    const optional_info = @typeInfo(T).optional;
    const payload_info = @typeInfo(optional_info.child);
    try std.testing.expect(payload_info == .pointer);
}
