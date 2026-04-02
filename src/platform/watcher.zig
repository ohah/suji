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
                const IN_CLOEXEC = @as(u32, 0o2000000);
                const IN_NONBLOCK = @as(u32, 0o4000);
                const fd = std.os.linux.inotify_init1(IN_CLOEXEC | IN_NONBLOCK);
                if (@as(isize, @bitCast(fd)) < 0) return error.WatchFailed;
                self.os.inotify_fd = @intCast(fd);
            }
            // 디렉토리 감시 등록
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return error.PathTooLong;
            const IN_MODIFY = @as(u32, 0x00000002);
            const IN_CREATE = @as(u32, 0x00000100);
            const IN_MOVED_TO = @as(u32, 0x00000080);
            const wd = std.os.linux.inotify_add_watch(self.os.inotify_fd, path_z, IN_MODIFY | IN_CREATE | IN_MOVED_TO);
            if (@as(isize, @bitCast(wd)) < 0) return error.WatchFailed;
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

    const InotifyEvent = extern struct {
        wd: i32,
        mask: u32,
        cookie: u32,
        len: u32,
    };

    fn watchLoopLinux(self: *Watcher) void {
        const fd = self.os.inotify_fd;
        if (fd < 0) return;

        var buf: [4096]u8 align(@alignOf(InotifyEvent)) = undefined;

        while (!self.should_stop.load(.acquire)) {
            const len = std.posix.read(fd, &buf) catch |err| {
                if (err == error.WouldBlock) {
                    std.Thread.sleep(100 * std.time.ns_per_ms);
                    continue;
                }
                break;
            };
            if (len == 0) {
                std.Thread.sleep(100 * std.time.ns_per_ms);
                continue;
            }

            var offset: usize = 0;
            while (offset < len) {
                const event: *const InotifyEvent = @alignCast(@ptrCast(buf[offset..]));
                const event_size = @sizeOf(InotifyEvent) + event.len;

                if (event.len > 0) {
                    const name_ptr: [*]const u8 = buf[offset + @sizeOf(InotifyEvent) ..].ptr;
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

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;
            const full_stack = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
            const stat = std.fs.cwd().statFile(full_stack) catch continue;
            if (!mtimes.contains(full_stack)) {
                const owned = allocator.dupe(u8, full_stack) catch continue;
                mtimes.put(owned, stat.mtime) catch {
                    allocator.free(owned);
                };
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

        // 스택 버퍼로 경로 조립 (매 주기 heap 할당 방지)
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;
            const full_stack = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;

            const stat = std.fs.cwd().statFile(full_stack) catch continue;

            if (mtimes.getPtr(full_stack)) |mtime_ptr| {
                if (stat.mtime != mtime_ptr.*) {
                    mtime_ptr.* = stat.mtime;
                    if (callback) |cb| cb(full_stack);
                }
            } else {
                // 새 파일 — heap 할당은 HashMap 키로만
                const owned = allocator.dupe(u8, full_stack) catch continue;
                mtimes.put(owned, stat.mtime) catch {
                    allocator.free(owned);
                    continue;
                };
                if (callback) |cb| cb(full_stack);
            }
        }
    }
};
