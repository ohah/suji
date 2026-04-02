const std = @import("std");
const Watcher = @import("watcher").Watcher;

// ============================================
// Watcher 초기화/해제
// ============================================

test "Watcher init and deinit" {
    var w = Watcher.init(std.testing.allocator);
    defer w.deinit();

    try std.testing.expect(w.paths.items.len == 0);
    try std.testing.expect(w.callback == null);
    try std.testing.expect(w.thread == null);
    try std.testing.expect(w.should_stop.load(.acquire) == false);
}

test "Watcher addPath" {
    var w = Watcher.init(std.testing.allocator);
    defer w.deinit();

    try w.addPath("/tmp");
    try std.testing.expectEqual(@as(usize, 1), w.paths.items.len);
    try std.testing.expectEqualStrings("/tmp", w.paths.items[0]);
}

test "Watcher addPath multiple" {
    var w = Watcher.init(std.testing.allocator);
    defer w.deinit();

    // 실제 존재하는 디렉토리 사용 (Linux inotify는 존재하지 않는 경로 거부)
    const dirs = [_][]const u8{ "/tmp/suji-watch-a", "/tmp/suji-watch-b", "/tmp/suji-watch-c" };
    for (dirs) |d| std.fs.cwd().makePath(d) catch {};
    defer for (dirs) |d| std.fs.cwd().deleteTree(d) catch {};

    for (dirs) |d| try w.addPath(d);
    try std.testing.expectEqual(@as(usize, 3), w.paths.items.len);
}

test "Watcher addPath owns memory" {
    var w = Watcher.init(std.testing.allocator);
    defer w.deinit();

    const tmp_dir = "/tmp/suji-watch-own";
    std.fs.cwd().makePath(tmp_dir) catch {};
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};

    // 스택 문자열 전달 — Watcher가 복제해야 함
    var buf: [32]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}", .{tmp_dir}) catch unreachable;
    try w.addPath(path);
    // buf를 수정해도 watcher의 경로는 영향 없어야 함
    buf[0] = 'X';
    try std.testing.expectEqualStrings(tmp_dir, w.paths.items[0]);
}

// ============================================
// 파일 변경 감지 (실제 파일 생성)
// ============================================

test "Watcher detects file creation" {
    const allocator = std.testing.allocator;

    // 임시 디렉토리 생성
    const tmp_dir = "/tmp/suji-watcher-test-create";
    std.fs.cwd().deleteTree(tmp_dir) catch {};
    try std.fs.cwd().makePath(tmp_dir);
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};

    var w = Watcher.init(allocator);
    defer w.deinit();
    try w.addPath(tmp_dir);

    var detected = std.atomic.Value(bool).init(false);
    const Ctx = struct {
        var flag: *std.atomic.Value(bool) = undefined;
        fn cb(_: []const u8) void {
            flag.store(true, .release);
        }
    };
    Ctx.flag = &detected;
    try w.start(&Ctx.cb);

    // 파일 생성
    std.Thread.sleep(600 * std.time.ns_per_ms); // watcher가 초기 mtime 수집할 시간
    const file_path = tmp_dir ++ "/test.txt";
    {
        var f = try std.fs.cwd().createFile(file_path, .{});
        _ = try f.write("hello");
        f.close();
    }

    // 감지 대기 (최대 3초)
    var waited: usize = 0;
    while (!detected.load(.acquire) and waited < 30) : (waited += 1) {
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }

    w.stop();
    try std.testing.expect(detected.load(.acquire));
}

test "Watcher detects file modification" {
    const allocator = std.testing.allocator;

    const tmp_dir = "/tmp/suji-watcher-test-modify";
    std.fs.cwd().deleteTree(tmp_dir) catch {};
    try std.fs.cwd().makePath(tmp_dir);
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};

    // 미리 파일 생성
    const file_path = tmp_dir ++ "/existing.txt";
    {
        var f = try std.fs.cwd().createFile(file_path, .{});
        _ = try f.write("v1");
        f.close();
    }

    var w = Watcher.init(allocator);
    defer w.deinit();
    try w.addPath(tmp_dir);

    var change_count = std.atomic.Value(u32).init(0);
    const Ctx = struct {
        var counter: *std.atomic.Value(u32) = undefined;
        fn cb(_: []const u8) void {
            _ = counter.fetchAdd(1, .monotonic);
        }
    };
    Ctx.counter = &change_count;
    try w.start(&Ctx.cb);

    // 초기 스캔 대기
    std.Thread.sleep(800 * std.time.ns_per_ms);

    // 파일 수정
    {
        var f = try std.fs.cwd().createFile(file_path, .{});
        _ = try f.write("v2-modified");
        f.close();
    }

    // 감지 대기
    var waited: usize = 0;
    while (change_count.load(.acquire) == 0 and waited < 30) : (waited += 1) {
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }

    w.stop();
    try std.testing.expect(change_count.load(.acquire) > 0);
}

test "Watcher stop is safe when not started" {
    var w = Watcher.init(std.testing.allocator);
    w.stop(); // 크래시 안 남
    w.deinit();
}

test "Watcher start and stop quickly" {
    var w = Watcher.init(std.testing.allocator);
    defer w.deinit();

    try w.addPath("/tmp");

    const noop = struct {
        fn cb(_: []const u8) void {}
    }.cb;

    try w.start(&noop);
    std.Thread.sleep(50 * std.time.ns_per_ms);
    w.stop();

    // 다시 시작 가능
    try w.start(&noop);
    std.Thread.sleep(50 * std.time.ns_per_ms);
    w.stop();
}

// ============================================
// BackendRegistry reload 테스트
// ============================================

test "BackendRegistry clearRoutesFor" {
    const loader = @import("loader");
    var reg = loader.BackendRegistry.init(std.testing.allocator);
    defer {
        // routes 키 메모리 해제 (BackendRegistry.deinit은 키를 해제하지 않음)
        var iter = reg.routes.iterator();
        while (iter.next()) |entry| std.testing.allocator.free(entry.key_ptr.*);
        reg.deinit();
    }

    // 라우팅 엔트리 수동 추가
    const ch1 = try std.testing.allocator.dupe(u8, "ping");
    const ch2 = try std.testing.allocator.dupe(u8, "greet");
    const ch3 = try std.testing.allocator.dupe(u8, "hello");
    try reg.routes.put(ch1, "zig");
    try reg.routes.put(ch2, "zig");
    try reg.routes.put(ch3, "rust");

    // zig 라우트만 제거
    reg.clearRoutesFor("zig");

    // zig 채널은 빈 문자열 (자동 라우팅 차단)
    try std.testing.expectEqualStrings("", reg.routes.get("ping").?);
    try std.testing.expectEqualStrings("", reg.routes.get("greet").?);
    // rust 채널은 유지
    try std.testing.expectEqualStrings("rust", reg.routes.get("hello").?);
}

test "BackendRegistry clearRoutesFor nonexistent backend" {
    const loader = @import("loader");
    var reg = loader.BackendRegistry.init(std.testing.allocator);
    defer {
        var iter = reg.routes.iterator();
        while (iter.next()) |entry| std.testing.allocator.free(entry.key_ptr.*);
        reg.deinit();
    }

    const ch = try std.testing.allocator.dupe(u8, "ping");
    try reg.routes.put(ch, "zig");

    // 없는 백엔드 제거 — 크래시 안 남
    reg.clearRoutesFor("nonexistent");

    // 기존 라우트 유지
    try std.testing.expectEqualStrings("zig", reg.routes.get("ping").?);
}

// ============================================
// RwLock 동시성 테스트
// ============================================

test "BackendRegistry concurrent invoke safety" {
    // RwLock이 shared 접근을 허용하는지 확인
    const loader = @import("loader");
    var reg = loader.BackendRegistry.init(std.testing.allocator);
    defer reg.deinit();

    // 여러 스레드에서 동시 invoke (백엔드 없으므로 null 반환)
    const thread_count = 10;
    var threads: [thread_count]std.Thread = undefined;
    var completed = std.atomic.Value(u32).init(0);

    const Ctx = struct {
        var r: *loader.BackendRegistry = undefined;
        var done: *std.atomic.Value(u32) = undefined;

        fn worker() void {
            var i: usize = 0;
            while (i < 100) : (i += 1) {
                _ = r.invoke("nonexistent", "{}");
            }
            _ = done.fetchAdd(1, .monotonic);
        }
    };
    Ctx.r = &reg;
    Ctx.done = &completed;

    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, Ctx.worker, .{});
    }
    for (&threads) |t| t.join();

    try std.testing.expectEqual(@as(u32, thread_count), completed.load(.acquire));
}
