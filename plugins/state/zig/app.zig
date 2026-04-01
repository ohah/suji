const std = @import("std");
const suji = @import("suji");

pub const app = suji.app()
    .handle("state:get", stateGet)
    .handle("state:set", stateSet)
    .handle("state:delete", stateDelete)
    .handle("state:keys", stateKeys)
    .handle("state:clear", stateClear);

// ============================================
// State Store (HashMap + Mutex + JSON 파일 영속성)
// ============================================

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const alloc = gpa.allocator();

var store: Store = .{};

const Store = struct {
    map: std.StringHashMap([]const u8) = std.StringHashMap([]const u8).init(alloc),
    mutex: std.Thread.Mutex = .{},
    data_path: ?[]const u8 = null,
    initialized: bool = false,
    dir_created: bool = false,

    fn ensureInit(self: *Store) void {
        if (self.initialized) return;
        self.initialized = true;
        self.data_path = getDataPath();
        self.loadFromDisk();
    }

    fn get(self: *Store, key: []const u8) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.ensureInit();
        return self.map.get(key);
    }

    fn set(self: *Store, key: []const u8, value: []const u8) void {
        // Phase 1: 뮤텍스 하에서 맵 업데이트 + 디스크 저장
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.ensureInit();

            // 기존 값 해제
            if (self.map.fetchRemove(key)) |kv| {
                alloc.free(kv.key);
                alloc.free(kv.value);
            }

            const owned_key = alloc.dupe(u8, key) catch return;
            const owned_val = alloc.dupe(u8, value) catch {
                alloc.free(owned_key);
                return;
            };
            self.map.put(owned_key, owned_val) catch {
                alloc.free(owned_key);
                alloc.free(owned_val);
                return;
            };

            self.persistUnlocked();
        }

        // Phase 2: 뮤텍스 밖에서 이벤트 발행 (데드락 방지)
        var event_buf: [512]u8 = undefined;
        const event_name = std.fmt.bufPrint(&event_buf, "state:{s}", .{key}) catch return;
        suji.send(event_name, value);
    }

    fn delete(self: *Store, key: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.ensureInit();

        if (self.map.fetchRemove(key)) |kv| {
            alloc.free(kv.key);
            alloc.free(kv.value);
            self.persistUnlocked();
            return true;
        }
        return false;
    }

    fn keys(self: *Store, arena: std.mem.Allocator) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.ensureInit();

        var buf = std.ArrayListUnmanaged(u8){};
        buf.appendSlice(arena, "{\"keys\":[") catch return null;
        var iter = self.map.iterator();
        var first = true;
        while (iter.next()) |entry| {
            if (!first) buf.appendSlice(arena, ",") catch break;
            std.fmt.format(buf.writer(arena), "\"{s}\"", .{entry.key_ptr.*}) catch break;
            first = false;
        }
        buf.appendSlice(arena, "]}") catch return null;
        return buf.toOwnedSlice(arena) catch null;
    }

    /// state:clear — 전체 초기화 (테스트용)
    fn clear(self: *Store) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var iter = self.map.iterator();
        while (iter.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            alloc.free(entry.value_ptr.*);
        }
        self.map.clearRetainingCapacity();
    }

    fn loadFromDisk(self: *Store) void {
        const path = self.data_path orelse return;
        const content = std.fs.cwd().readFileAlloc(alloc, path, 1024 * 1024) catch return;
        defer alloc.free(content);

        const parsed = std.json.parseFromSlice(std.json.Value, alloc, content, .{}) catch return;
        defer parsed.deinit();

        if (parsed.value != .object) return;

        var iter = parsed.value.object.iterator();
        while (iter.next()) |entry| {
            const key = entry.key_ptr.*;
            const val = entry.value_ptr.*;

            const val_str = jsonValueToString(val) orelse continue;

            const owned_key = alloc.dupe(u8, key) catch {
                alloc.free(val_str);
                continue;
            };
            self.map.put(owned_key, val_str) catch {
                alloc.free(owned_key);
                alloc.free(val_str);
            };
        }
    }

    fn jsonValueToString(val: std.json.Value) ?[]const u8 {
        const a = alloc;
        return switch (val) {
            .string => |s| std.fmt.allocPrint(a, "\"{s}\"", .{s}) catch null,
            .integer => |i| std.fmt.allocPrint(a, "{d}", .{i}) catch null,
            .float => |f| std.fmt.allocPrint(a, "{d}", .{f}) catch null,
            .bool => |b| if (b) a.dupe(u8, "true") catch null else a.dupe(u8, "false") catch null,
            .null => a.dupe(u8, "null") catch null,
            else => null, // object/array는 스킵 (단순 KV만 지원)
        };
    }

    fn persistUnlocked(self: *Store) void {
        const path = self.data_path orelse return;

        // 디렉토리 생성 (최초 1회만)
        if (!self.dir_created) {
            if (std.mem.lastIndexOfScalar(u8, path, '/')) |sep| {
                std.fs.cwd().makePath(path[0..sep]) catch {};
            }
            self.dir_created = true;
        }

        const a = alloc;
        var buf = std.ArrayListUnmanaged(u8){};
        defer buf.deinit(a);

        buf.appendSlice(a, "{") catch return;
        var map_iter = self.map.iterator();
        var first = true;
        while (map_iter.next()) |entry| {
            if (!first) buf.appendSlice(a, ",") catch continue;
            std.fmt.format(buf.writer(a), "\"{s}\":{s}", .{ entry.key_ptr.*, entry.value_ptr.* }) catch continue;
            first = false;
        }
        buf.appendSlice(a, "}") catch return;

        const file = std.fs.cwd().createFile(path, .{}) catch return;
        defer file.close();
        file.writeAll(buf.items) catch {};
    }
};

fn getDataPath() ?[]const u8 {
    const builtin = @import("builtin");
    if (builtin.os.tag == .macos) {
        const home = std.posix.getenv("HOME") orelse return null;
        // TODO: app name을 config에서 받아야 함. 지금은 하드코딩.
        return std.fmt.allocPrint(alloc, "{s}/Library/Application Support/suji-app/state.json", .{home}) catch null;
    } else if (builtin.os.tag == .linux) {
        const xdg = std.posix.getenv("XDG_DATA_HOME");
        if (xdg) |dir| {
            return std.fmt.allocPrint(alloc, "{s}/suji-app/state.json", .{dir}) catch null;
        }
        const home = std.posix.getenv("HOME") orelse return null;
        return std.fmt.allocPrint(alloc, "{s}/.local/share/suji-app/state.json", .{home}) catch null;
    } else if (builtin.os.tag == .windows) {
        const appdata = std.posix.getenv("APPDATA") orelse return null;
        return std.fmt.allocPrint(alloc, "{s}\\suji-app\\state.json", .{appdata}) catch null;
    }
    return null;
}

// ============================================
// 핸들러
// ============================================

fn stateGet(req: suji.Request) suji.Response {
    const key = req.string("key") orelse return req.err("missing key");
    if (store.get(key)) |value| {
        // value는 이미 JSON 형태 (문자열이면 "...", 숫자면 42 등)
        return req.okRaw(std.fmt.allocPrint(req.arena, "{{\"value\":{s}}}", .{value}) catch return req.err("format error"));
    }
    return req.okRaw("{\"value\":null}");
}

fn stateSet(req: suji.Request) suji.Response {
    const key = req.string("key") orelse return req.err("missing key");
    const value = suji.extractJsonValue(req.raw, "value") orelse return req.err("missing value");
    store.set(key, value);
    return req.okRaw("{\"ok\":true}");
}

fn stateDelete(req: suji.Request) suji.Response {
    const key = req.string("key") orelse return req.err("missing key");
    _ = store.delete(key);
    return req.okRaw("{\"ok\":true}");
}

fn stateClear(req: suji.Request) suji.Response {
    store.clear();
    return req.okRaw("{\"ok\":true}");
}

fn stateKeys(req: suji.Request) suji.Response {
    const result = store.keys(req.arena) orelse return req.err("alloc error");
    return req.okRaw(result);
}

comptime {
    _ = suji.exportApp(app);
}
