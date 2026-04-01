const std = @import("std");
const AssetServer = @import("asset_server").AssetServer;

// ============================================
// 헬퍼
// ============================================

fn httpGet(port: u16, path: []const u8, buf: []u8) ![]const u8 {
    const address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
    const stream = try std.net.tcpConnectToAddress(address);
    defer stream.close();

    // HTTP 요청 전송
    var req_buf: [512]u8 = undefined;
    const req = try std.fmt.bufPrint(&req_buf, "GET {s} HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\n\r\n", .{ path, port });
    _ = try stream.write(req);

    // 응답 읽기
    var total: usize = 0;
    while (total < buf.len) {
        const n = stream.read(buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    return buf[0..total];
}

fn createTestAssets(allocator: std.mem.Allocator) ![]const u8 {
    const dir = try std.fs.cwd().realpathAlloc(allocator, ".");
    const test_dir = try std.fmt.allocPrint(allocator, "{s}/test_assets", .{dir});
    allocator.free(dir);

    std.fs.cwd().makePath("test_assets") catch {};
    const file = try std.fs.cwd().createFile("test_assets/hello.txt", .{});
    try file.writeAll("Hello, Suji!");
    file.close();

    const png_file = try std.fs.cwd().createFile("test_assets/test.png", .{});
    try png_file.writeAll("\x89PNG\r\n\x1a\n"); // PNG 매직 바이트
    png_file.close();

    return test_dir;
}

fn cleanupTestAssets() void {
    std.fs.cwd().deleteTree("test_assets") catch {};
}

// ============================================
// 테스트
// ============================================

test "asset server: starts and binds to a port" {
    const srv = try AssetServer.start(std.heap.page_allocator, "test_assets");
    defer srv.stop();
    try std.testing.expect(srv.port > 0);
}

test "asset server: getBaseUrl" {
    const srv = try AssetServer.start(std.heap.page_allocator, "test_assets");
    defer srv.stop();
    var buf: [128]u8 = undefined;
    const url = srv.getBaseUrl(&buf);
    try std.testing.expect(std.mem.startsWith(u8, url, "http://127.0.0.1:"));
}

test "asset server: serves text file" {
    const test_dir = try createTestAssets(std.heap.page_allocator);
    defer {
        cleanupTestAssets();
        std.heap.page_allocator.free(test_dir);
    }

    const srv = try AssetServer.start(std.heap.page_allocator, "test_assets");
    defer srv.stop();

    // 서버 준비 대기

    var buf: [4096]u8 = undefined;
    const resp = try httpGet(srv.port, "/hello.txt", &buf);

    try std.testing.expect(std.mem.indexOf(u8, resp, "200 OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "text/plain") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "Hello, Suji!") != null);
}

test "asset server: serves binary file with correct MIME" {
    const test_dir = try createTestAssets(std.heap.page_allocator);
    defer {
        cleanupTestAssets();
        std.heap.page_allocator.free(test_dir);
    }

    const srv = try AssetServer.start(std.heap.page_allocator, "test_assets");
    defer srv.stop();


    var buf: [4096]u8 = undefined;
    const resp = try httpGet(srv.port, "/test.png", &buf);

    try std.testing.expect(std.mem.indexOf(u8, resp, "200 OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "image/png") != null);
}

test "asset server: returns 404 for missing file" {
    const srv = try AssetServer.start(std.heap.page_allocator, "test_assets");
    defer srv.stop();


    var buf: [4096]u8 = undefined;
    const resp = try httpGet(srv.port, "/nonexistent.txt", &buf);

    try std.testing.expect(std.mem.indexOf(u8, resp, "404") != null);
}

test "asset server: rejects path traversal" {
    const srv = try AssetServer.start(std.heap.page_allocator, "test_assets");
    defer srv.stop();


    var buf: [4096]u8 = undefined;
    const resp = try httpGet(srv.port, "/../etc/passwd", &buf);

    try std.testing.expect(std.mem.indexOf(u8, resp, "400") != null);
}

test "asset server: CORS headers present" {
    const test_dir = try createTestAssets(std.heap.page_allocator);
    defer {
        cleanupTestAssets();
        std.heap.page_allocator.free(test_dir);
    }

    const srv = try AssetServer.start(std.heap.page_allocator, "test_assets");
    defer srv.stop();


    var buf: [4096]u8 = undefined;
    const resp = try httpGet(srv.port, "/hello.txt", &buf);

    try std.testing.expect(std.mem.indexOf(u8, resp, "Access-Control-Allow-Origin: *") != null);
}
