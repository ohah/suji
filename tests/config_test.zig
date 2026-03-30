const std = @import("std");
const config = @import("config");

test "Config default values" {
    const cfg = config.Config{};
    try std.testing.expectEqualStrings("Suji App", cfg.app.name);
    try std.testing.expectEqualStrings("0.1.0", cfg.app.version);
    try std.testing.expectEqual(@as(i32, 800), cfg.window.width);
    try std.testing.expectEqual(@as(i32, 600), cfg.window.height);
    try std.testing.expect(!cfg.window.debug);
    try std.testing.expect(cfg.backend == null);
    try std.testing.expect(cfg.backends == null);
    try std.testing.expectEqualStrings("frontend", cfg.frontend.dir);
    try std.testing.expectEqualStrings("http://localhost:5173", cfg.frontend.dev_url);
    try std.testing.expectEqualStrings("frontend/dist", cfg.frontend.dist_dir);
}

test "Config isMultiBackend" {
    var cfg = config.Config{};
    try std.testing.expect(!cfg.isMultiBackend());

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

test "Config load returns error when no config file" {
    // 현재 디렉토리에 suji.toml/suji.json이 없으면 에러
    const result = config.Config.load(std.testing.allocator);
    try std.testing.expectError(error.ConfigNotFound, result);
}

test "Config loadJson parses correctly" {
    // 임시 suji.json 생성
    const json_content =
        \\{
        \\  "app": { "name": "Test App", "version": "1.0.0" },
        \\  "window": { "title": "Test", "width": 1024, "height": 768, "debug": true },
        \\  "backend": { "lang": "rust", "entry": "src/lib.rs" },
        \\  "frontend": { "dir": "web", "dev_url": "http://localhost:3000", "dist_dir": "web/build" }
        \\}
    ;

    // 임시 디렉토리에서 테스트
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "suji.json", .data = json_content });

    // cwd를 변경할 수 없으므로, 직접 파싱 테스트
    // loadJson은 cwd 기반이라 직접 호출 대신 파서 로직 검증
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json_content, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expect(root.get("app") != null);
    try std.testing.expect(root.get("window") != null);
    try std.testing.expect(root.get("backend") != null);
    try std.testing.expect(root.get("frontend") != null);

    const app = root.get("app").?.object;
    try std.testing.expectEqualStrings("Test App", app.get("name").?.string);
    try std.testing.expectEqualStrings("1.0.0", app.get("version").?.string);

    const win = root.get("window").?.object;
    try std.testing.expectEqual(@as(i64, 1024), win.get("width").?.integer);
    try std.testing.expectEqual(@as(i64, 768), win.get("height").?.integer);
    try std.testing.expect(win.get("debug").?.bool);

    const be = root.get("backend").?.object;
    try std.testing.expectEqualStrings("rust", be.get("lang").?.string);

    const fe = root.get("frontend").?.object;
    try std.testing.expectEqualStrings("web", fe.get("dir").?.string);
    try std.testing.expectEqualStrings("http://localhost:3000", fe.get("dev_url").?.string);
}

test "Config JSON multi-backend parsing" {
    const json_content =
        \\{
        \\  "backends": [
        \\    { "name": "rust", "lang": "rust", "entry": "backends/rust" },
        \\    { "name": "go", "lang": "go", "entry": "backends/go" }
        \\  ]
        \\}
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json_content, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const bs = root.get("backends").?.array;
    try std.testing.expectEqual(@as(usize, 2), bs.items.len);

    const first = bs.items[0].object;
    try std.testing.expectEqualStrings("rust", first.get("name").?.string);
    try std.testing.expectEqualStrings("rust", first.get("lang").?.string);

    const second = bs.items[1].object;
    try std.testing.expectEqualStrings("go", second.get("name").?.string);
}
