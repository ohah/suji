const std = @import("std");

/// 로컬 HTTP 에셋 서버
///
/// WebView IPC는 텍스트 전용이라 바이너리(이미지, 파일) 전송 불가.
/// 로컬 HTTP 서버로 바이너리 에셋을 제공.
///
/// ```html
/// <img src="http://localhost:{port}/images/photo.png">
/// ```
/// ```js
/// const buf = await fetch(window.__suji__.assetUrl + "/data/file.bin").then(r => r.arrayBuffer());
/// ```
pub const AssetServer = struct {
    allocator: std.mem.Allocator,
    server: std.net.Server,
    port: u16,
    asset_dir: []const u8,
    thread: ?std.Thread = null,
    should_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn start(allocator: std.mem.Allocator, asset_dir: []const u8) !*AssetServer {
        const address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
        var server = try address.listen(.{ .reuse_address = true });

        const port = server.listen_address.getPort();

        const self = try allocator.create(AssetServer);
        self.* = .{
            .allocator = allocator,
            .server = server,
            .port = port,
            .asset_dir = asset_dir,
        };

        self.thread = try std.Thread.spawn(.{}, serverLoop, .{self});

        std.debug.print("[suji] asset server started on http://127.0.0.1:{d}\n", .{port});
        return self;
    }

    pub fn stop(self: *AssetServer) void {
        self.should_stop.store(true, .release);
        // accept() 블로킹 해제를 위해 서버 소켓 닫기
        self.server.deinit();
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        self.allocator.destroy(self);
    }

    pub fn getBaseUrl(self: *const AssetServer, buf: []u8) [:0]const u8 {
        const len = (std.fmt.bufPrint(buf, "http://127.0.0.1:{d}", .{self.port}) catch return "http://127.0.0.1:0").len;
        buf[len] = 0;
        return buf[0..len :0];
    }

    fn serverLoop(self: *AssetServer) void {
        while (!self.should_stop.load(.acquire)) {
            const conn = self.server.accept() catch |err| {
                if (self.should_stop.load(.acquire)) break;
                std.debug.print("[suji] asset server accept error: {}\n", .{err});
                std.Thread.sleep(10 * std.time.ns_per_ms);
                continue;
            };
            self.handleConnection(conn);
        }
    }

    fn handleConnection(self: *AssetServer, conn: std.net.Server.Connection) void {
        defer conn.stream.close();

        // HTTP 요청 첫 줄 읽기
        var buf: [4096]u8 = undefined;
        const n = conn.stream.read(&buf) catch return;
        if (n == 0) return;
        const request = buf[0..n];

        // GET /path HTTP/1.x 파싱
        const path = parseRequestPath(request) orelse {
            send400(conn.stream);
            return;
        };

        // OPTIONS (CORS preflight)
        if (isOptions(request)) {
            sendCorsPreflightResponse(conn.stream);
            return;
        }

        // 경로 트래버설 방지
        if (std.mem.indexOf(u8, path, "..") != null) {
            send400(conn.stream);
            return;
        }

        // 파일 경로 조합
        var file_path_buf: [2048]u8 = undefined;
        const clean_path = if (path.len > 0 and path[0] == '/') path[1..] else path;
        const file_path = std.fmt.bufPrint(&file_path_buf, "{s}/{s}", .{ self.asset_dir, clean_path }) catch {
            send400(conn.stream);
            return;
        };

        sendFile(conn.stream, file_path);
    }

    fn parseRequestPath(request: []const u8) ?[]const u8 {
        // "GET /path HTTP/1.x"
        const first_line_end = std.mem.indexOf(u8, request, "\r\n") orelse request.len;
        const first_line = request[0..first_line_end];

        // GET 이후 공백 찾기
        const method_end = std.mem.indexOf(u8, first_line, " ") orelse return null;
        const rest = first_line[method_end + 1 ..];

        // 경로 끝 (다음 공백)
        const path_end = std.mem.indexOf(u8, rest, " ") orelse rest.len;
        const path = rest[0..path_end];

        if (path.len == 0) return null;

        // 쿼리 스트링 제거
        const query_start = std.mem.indexOf(u8, path, "?") orelse path.len;
        return path[0..query_start];
    }

    fn isOptions(request: []const u8) bool {
        return std.mem.startsWith(u8, request, "OPTIONS ");
    }

    fn sendFile(stream: std.net.Stream, path: []const u8) void {
        const file = std.fs.cwd().openFile(path, .{}) catch {
            send404(stream);
            return;
        };
        defer file.close();

        const stat = file.stat() catch {
            send404(stream);
            return;
        };
        const size = stat.size;

        // 확장자에서 MIME 타입 결정
        const ext = std.fs.path.extension(path);
        const mime = mimeForExtension(ext);

        // HTTP 응답 헤더
        var header_buf: [512]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf,
            "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: {s}\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Access-Control-Allow-Origin: *\r\n" ++
            "Connection: close\r\n" ++
            "\r\n",
            .{ mime, size },
        ) catch return;

        _ = stream.write(header) catch return;

        // 파일 청크 전송
        var read_buf: [8192]u8 = undefined;
        while (true) {
            const bytes_read = file.read(&read_buf) catch return;
            if (bytes_read == 0) break;
            _ = stream.write(read_buf[0..bytes_read]) catch return;
        }

    }

    fn send404(stream: std.net.Stream) void {
        const response =
            "HTTP/1.1 404 Not Found\r\n" ++
            "Content-Type: text/plain\r\n" ++
            "Content-Length: 9\r\n" ++
            "Access-Control-Allow-Origin: *\r\n" ++
            "Connection: close\r\n" ++
            "\r\n" ++
            "Not Found";
        _ = stream.write(response) catch {};
    }

    fn send400(stream: std.net.Stream) void {
        const response =
            "HTTP/1.1 400 Bad Request\r\n" ++
            "Content-Type: text/plain\r\n" ++
            "Content-Length: 11\r\n" ++
            "Access-Control-Allow-Origin: *\r\n" ++
            "Connection: close\r\n" ++
            "\r\n" ++
            "Bad Request";
        _ = stream.write(response) catch {};
    }

    fn sendCorsPreflightResponse(stream: std.net.Stream) void {
        const response =
            "HTTP/1.1 204 No Content\r\n" ++
            "Access-Control-Allow-Origin: *\r\n" ++
            "Access-Control-Allow-Methods: GET, OPTIONS\r\n" ++
            "Access-Control-Allow-Headers: *\r\n" ++
            "Access-Control-Max-Age: 86400\r\n" ++
            "Connection: close\r\n" ++
            "\r\n";
        _ = stream.write(response) catch {};
    }

    fn mimeForExtension(ext: []const u8) []const u8 {
        const mime_map = .{
            .{ ".html", "text/html" },
            .{ ".css", "text/css" },
            .{ ".js", "application/javascript" },
            .{ ".mjs", "application/javascript" },
            .{ ".json", "application/json" },
            .{ ".png", "image/png" },
            .{ ".jpg", "image/jpeg" },
            .{ ".jpeg", "image/jpeg" },
            .{ ".gif", "image/gif" },
            .{ ".svg", "image/svg+xml" },
            .{ ".ico", "image/x-icon" },
            .{ ".webp", "image/webp" },
            .{ ".woff", "font/woff" },
            .{ ".woff2", "font/woff2" },
            .{ ".ttf", "font/ttf" },
            .{ ".pdf", "application/pdf" },
            .{ ".wasm", "application/wasm" },
            .{ ".mp3", "audio/mpeg" },
            .{ ".mp4", "video/mp4" },
            .{ ".webm", "video/webm" },
            .{ ".txt", "text/plain" },
            .{ ".xml", "application/xml" },
        };

        inline for (mime_map) |entry| {
            if (std.mem.eql(u8, ext, entry[0])) return entry[1];
        }
        return "application/octet-stream";
    }
};
