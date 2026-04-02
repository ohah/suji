const std = @import("std");
const builtin = @import("builtin");

/// 파일/디렉토리 변경 감시 (OS 네이티브)
///
/// macOS: FSEvents (CoreFoundation)
/// Linux: inotify
///
/// ```zig
/// var w = try Watcher.init(allocator);
/// defer w.deinit();
/// try w.addPath("/path/to/watch");
/// w.start(struct {
///     fn callback(path: []const u8) void { ... }
/// }.callback);
/// ```
pub const Watcher = struct {
    allocator: std.mem.Allocator,
    paths: std.ArrayListUnmanaged([]const u8),
    callback: ?*const fn ([]const u8) void,
    thread: ?std.Thread,
    should_stop: std.atomic.Value(bool),

    // OS-specific handles
    os: OsData,

    const OsData = switch (builtin.os.tag) {
        .linux => LinuxData,
        .macos => MacosData,
        else => PollData,
    };

    const LinuxData = struct {
        inotify_fd: std.posix.fd_t = -1,
    };

    const MacosData = struct {
        // FSEvents는 CoreFoundation 런루프 필요 — 별도 스레드에서 폴링 사용
        // (FSEvents C API는 CFRunLoop 의존이라 Zig에서 직접 쓰기 복잡)
        // 대신 stat 기반 효율적 폴링 (100ms 간격)
        dummy: u8 = 0,
    };

    const PollData = struct {
        dummy: u8 = 0,
    };

    pub fn init(allocator: std.mem.Allocator) Watcher {
        var w = Watcher{
            .allocator = allocator,
            .paths = .{},
            .callback = null,
            .thread = null,
            .should_stop = std.atomic.Value(bool).init(false),
            .os = undefined,
        };
        if (builtin.os.tag == .linux) {
            w.os = .{ .inotify_fd = -1 };
        } else {
            w.os = .{};
        }
        return w;
    }

    pub fn deinit(self: *Watcher) void {
        self.stop();
        for (self.paths.items) |p| {
            self.allocator.free(p);
        }
        self.paths.deinit(self.allocator);
        if (builtin.os.tag == .linux) {
            if (self.os.inotify_fd >= 0) {
                std.posix.close(self.os.inotify_fd);
            }
        }
    }

    pub fn addPath(self: *Watcher, path: []const u8) !void {
        const owned = try self.allocator.dupe(u8, path);
        try self.paths.append(self.allocator, owned);

        if (builtin.os.tag == .linux) {
            if (self.os.inotify_fd < 0) {
                self.os.inotify_fd = try std.posix.inotify_init1(.{ .CLOEXEC = true, .NONBLOCK = true });
            }
            // 디렉토리 감시 등록
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return error.PathTooLong;
            _ = std.posix.inotify_add_watch(self.os.inotify_fd, path_z, .{
                .MODIFY = true,
                .CREATE = true,
                .MOVED_TO = true,
            }) catch return error.WatchFailed;
        }
    }

    pub fn start(self: *Watcher, callback: *const fn ([]const u8) void) !void {
        self.callback = callback;
        self.should_stop.store(false, .release);
        self.thread = try std.Thread.spawn(.{}, watchLoop, .{self});
    }

    pub fn stop(self: *Watcher) void {
        self.should_stop.store(true, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    fn watchLoop(self: *Watcher) void {
        switch (builtin.os.tag) {
            .linux => self.watchLoopLinux(),
            else => self.watchLoopPoll(),
        }
    }

    // ============================================
    // Linux: inotify
    // ============================================

    fn watchLoopLinux(self: *Watcher) void {
        const fd = self.os.inotify_fd;
        if (fd < 0) return;

        var buf: [4096]u8 align(@alignOf(std.os.linux.inotify_event)) = undefined;

        while (!self.should_stop.load(.acquire)) {
            const len = std.posix.read(fd, &buf) catch |err| {
                if (err == error.WouldBlock) {
                    // 이벤트 없음 — 100ms 대기
                    std.Thread.sleep(100 * std.time.ns_per_ms);
                    continue;
                }
                break; // 에러
            };
            if (len == 0) {
                std.Thread.sleep(100 * std.time.ns_per_ms);
                continue;
            }

            // inotify 이벤트 파싱
            var offset: usize = 0;
            while (offset < len) {
                const event: *const std.os.linux.inotify_event = @alignCast(@ptrCast(buf[offset..]));
                const event_size = @sizeOf(std.os.linux.inotify_event) + event.len;

                if (event.len > 0) {
                    const name_ptr: [*]const u8 = @ptrCast(@as([*]const u8, &buf) + offset + @sizeOf(std.os.linux.inotify_event));
                    const name = std.mem.sliceTo(name_ptr[0..event.len], 0);
                    if (self.callback) |cb| cb(name);
                }

                offset += event_size;
            }
        }
    }

    // ============================================
    // macOS / 기타: stat 기반 폴링 (500ms)
    // ============================================

    fn watchLoopPoll(self: *Watcher) void {
        // 초기 mtime 수집
        var mtimes = std.StringHashMap(i128).init(self.allocator);
        defer {
            // HashMap 키 메모리 해제
            var iter = mtimes.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
            }
            mtimes.deinit();
        }

        for (self.paths.items) |path| {
            collectMtimes(self.allocator, path, &mtimes) catch {};
        }

        while (!self.should_stop.load(.acquire)) {
            std.Thread.sleep(500 * std.time.ns_per_ms);

            for (self.paths.items) |path| {
                checkChanges(self.allocator, path, &mtimes, self.callback) catch {};
            }
        }
    }

    fn collectMtimes(allocator: std.mem.Allocator, dir_path: []const u8, mtimes: *std.StringHashMap(i128)) !void {
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;
            const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
            const stat = std.fs.cwd().statFile(full) catch {
                allocator.free(full);
                continue;
            };
            if (mtimes.contains(full)) {
                allocator.free(full);
            } else {
                try mtimes.put(full, stat.mtime);
            }
        }
    }

    fn checkChanges(
        allocator: std.mem.Allocator,
        dir_path: []const u8,
        mtimes: *std.StringHashMap(i128),
        callback: ?*const fn ([]const u8) void,
    ) !void {
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;
            const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
            const stat = std.fs.cwd().statFile(full) catch {
                allocator.free(full);
                continue;
            };

            if (mtimes.getPtr(full)) |mtime_ptr| {
                if (stat.mtime != mtime_ptr.*) {
                    mtime_ptr.* = stat.mtime;
                    if (callback) |cb| cb(full);
                }
                allocator.free(full); // 기존 키 재사용, 새 할당 해제
            } else {
                // 새 파일 — 키 소유권 이전
                mtimes.put(full, stat.mtime) catch {
                    allocator.free(full);
                };
                if (callback) |cb| cb(full);
            }
        }
    }
};
