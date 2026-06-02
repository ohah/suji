//! @suji/plugin-store — file-backed persistent config (electron-store 동등).
//!
//! state 와 차이: store 는 persistent **config** (atomic write), 여러 이름의 store
//! 인스턴스 지원, scope 없음. state 는 ephemeral KV with scope (per-window 등).
//!
//! 채널:
//!   store:get        {name?, key}        → {value: <T>|null}
//!   store:set        {name?, key, value} → {ok:true}
//!   store:has        {name?, key}        → {has: bool}
//!   store:delete     {name?, key}        → {ok:true}
//!   store:clear      {name?}             → {ok:true}
//!   store:keys       {name?}             → {keys: string[]}
//!   store:size       {name?}             → {size: number}
//!   store:get_path   {name?}             → {path}
//!
//! 파일 위치: <appdata>/suji-app/store/<name>.json. name 미지정 시 "config".
//! atomic save: `<name>.json.tmp` 에 write 후 rename.

const std = @import("std");
const suji = @import("suji");

pub const app = suji.app()
    .named("store")
    .handle("store:get", storeGet)
    .handle("store:set", storeSet)
    .handle("store:has", storeHas)
    .handle("store:delete", storeDelete)
    .handle("store:clear", storeClear)
    .handle("store:keys", storeKeys)
    .handle("store:values", storeValues)
    .handle("store:entries", storeEntries)
    .handle("store:size", storeSize)
    .handle("store:get_path", storeGetPath);

var gpa: std.heap.DebugAllocator(.{}) = .init;
const alloc = gpa.allocator();

fn pluginIo() std.Io {
    return suji.io();
}

const MAX_FILE_BYTES: usize = 64 * 1024 * 1024; // 64MB read cap
const MAX_NAME_LEN: usize = 64;

// ============================================
// Stores registry — 여러 named store 인스턴스 (각자 자기 file + map + mutex).
// ============================================

var stores: std.StringHashMap(*Store) = std.StringHashMap(*Store).init(alloc);
var registry_mutex: std.Io.Mutex = .init;

const Store = struct {
    name: []const u8,
    path: []const u8,
    map: std.StringHashMap([]const u8),
    mutex: std.Io.Mutex = .init,
    dir_created: bool = false,

    fn init(name: []const u8) ?*Store {
        const owned_name = alloc.dupe(u8, name) catch return null;
        errdefer alloc.free(owned_name);
        const path = makePath(owned_name) orelse return null;
        errdefer alloc.free(path);
        const s = alloc.create(Store) catch return null;
        s.* = .{
            .name = owned_name,
            .path = path,
            .map = std.StringHashMap([]const u8).init(alloc),
        };
        s.loadFromDisk();
        return s;
    }

    /// 등록 실패/teardown 시 store 와 내부 할당 즉시 해제. 정상 경로에서는
    /// 호출되지 않음(레지스트리가 영구 보유).
    fn deinit(self: *Store) void {
        var iter = self.map.iterator();
        while (iter.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            alloc.free(entry.value_ptr.*);
        }
        self.map.deinit();
        alloc.free(self.path);
        alloc.free(self.name);
        alloc.destroy(self);
    }

    fn loadFromDisk(self: *Store) void {
        const content = std.Io.Dir.cwd().readFileAlloc(pluginIo(), self.path, alloc, .limited(MAX_FILE_BYTES)) catch return;
        defer alloc.free(content);
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, content, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .object) return;
        var iter = parsed.value.object.iterator();
        while (iter.next()) |entry| {
            const key = alloc.dupe(u8, entry.key_ptr.*) catch continue;
            const val_str = jsonValueToOwned(entry.value_ptr.*) orelse {
                alloc.free(key);
                continue;
            };
            self.map.put(key, val_str) catch {
                alloc.free(key);
                alloc.free(val_str);
            };
        }
    }

    fn get(self: *Store, key: []const u8) ?[]const u8 {
        self.mutex.lockUncancelable(pluginIo());
        defer self.mutex.unlock(pluginIo());
        return self.map.get(key);
    }

    fn has(self: *Store, key: []const u8) bool {
        self.mutex.lockUncancelable(pluginIo());
        defer self.mutex.unlock(pluginIo());
        return self.map.contains(key);
    }

    fn set(self: *Store, key: []const u8, value_raw: []const u8) bool {
        self.mutex.lockUncancelable(pluginIo());
        defer self.mutex.unlock(pluginIo());
        const owned_value = alloc.dupe(u8, value_raw) catch return false;
        if (self.map.fetchRemove(key)) |kv| {
            alloc.free(kv.key);
            alloc.free(kv.value);
        }
        const owned_key = alloc.dupe(u8, key) catch {
            alloc.free(owned_value);
            return false;
        };
        self.map.put(owned_key, owned_value) catch {
            alloc.free(owned_key);
            alloc.free(owned_value);
            return false;
        };
        self.persistUnlocked();
        return true;
    }

    fn delete(self: *Store, key: []const u8) bool {
        self.mutex.lockUncancelable(pluginIo());
        defer self.mutex.unlock(pluginIo());
        if (self.map.fetchRemove(key)) |kv| {
            alloc.free(kv.key);
            alloc.free(kv.value);
            self.persistUnlocked();
            return true;
        }
        return false;
    }

    fn clear(self: *Store) void {
        self.mutex.lockUncancelable(pluginIo());
        defer self.mutex.unlock(pluginIo());
        var iter = self.map.iterator();
        while (iter.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            alloc.free(entry.value_ptr.*);
        }
        self.map.clearAndFree();
        self.persistUnlocked();
    }

    fn keys(self: *Store, arena: std.mem.Allocator) ?[]const u8 {
        self.mutex.lockUncancelable(pluginIo());
        defer self.mutex.unlock(pluginIo());
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(arena);
        out.appendSlice(arena, "{\"keys\":[") catch return null;
        var iter = self.map.iterator();
        var first = true;
        while (iter.next()) |entry| {
            if (!first) out.appendSlice(arena, ",") catch return null;
            out.appendSlice(arena, "\"") catch return null;
            appendJsonEscaped(arena, &out, entry.key_ptr.*) catch return null;
            out.appendSlice(arena, "\"") catch return null;
            first = false;
        }
        out.appendSlice(arena, "]}") catch return null;
        return out.toOwnedSlice(arena) catch null;
    }

    fn size(self: *Store) usize {
        self.mutex.lockUncancelable(pluginIo());
        defer self.mutex.unlock(pluginIo());
        return self.map.count();
    }

    /// 값 배열 (Tauri `store.values()`). 값은 이미 raw JSON 텍스트.
    fn values(self: *Store, arena: std.mem.Allocator) ?[]const u8 {
        self.mutex.lockUncancelable(pluginIo());
        defer self.mutex.unlock(pluginIo());
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(arena);
        out.appendSlice(arena, "{\"values\":[") catch return null;
        var iter = self.map.iterator();
        var first = true;
        while (iter.next()) |entry| {
            if (!first) out.appendSlice(arena, ",") catch return null;
            out.appendSlice(arena, entry.value_ptr.*) catch return null;
            first = false;
        }
        out.appendSlice(arena, "]}") catch return null;
        return out.toOwnedSlice(arena) catch null;
    }

    /// [키,값] 쌍 배열 (Tauri `store.entries()`). 키는 escape, 값은 raw JSON.
    fn entries(self: *Store, arena: std.mem.Allocator) ?[]const u8 {
        self.mutex.lockUncancelable(pluginIo());
        defer self.mutex.unlock(pluginIo());
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(arena);
        out.appendSlice(arena, "{\"entries\":[") catch return null;
        var iter = self.map.iterator();
        var first = true;
        while (iter.next()) |entry| {
            if (!first) out.appendSlice(arena, ",") catch return null;
            out.appendSlice(arena, "[\"") catch return null;
            appendJsonEscaped(arena, &out, entry.key_ptr.*) catch return null;
            out.appendSlice(arena, "\",") catch return null;
            out.appendSlice(arena, entry.value_ptr.*) catch return null;
            out.appendSlice(arena, "]") catch return null;
            first = false;
        }
        out.appendSlice(arena, "]}") catch return null;
        return out.toOwnedSlice(arena) catch null;
    }

    fn persistUnlocked(self: *Store) void {
        if (!self.dir_created) {
            if (std.mem.lastIndexOfAny(u8, self.path, "/\\")) |sep| {
                std.Io.Dir.cwd().createDirPath(pluginIo(), self.path[0..sep]) catch {};
            }
            self.dir_created = true;
        }

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(alloc);
        buf.appendSlice(alloc, "{") catch return;
        var iter = self.map.iterator();
        var first = true;
        while (iter.next()) |entry| {
            if (!first) buf.appendSlice(alloc, ",") catch return;
            buf.appendSlice(alloc, "\"") catch return;
            appendJsonEscaped(alloc, &buf, entry.key_ptr.*) catch return;
            buf.appendSlice(alloc, "\":") catch return;
            buf.appendSlice(alloc, entry.value_ptr.*) catch return;
            first = false;
        }
        buf.appendSlice(alloc, "}") catch return;

        // Atomic write: .tmp 에 write 후 rename. crash 시 기존 파일 보존.
        const tmp_path = std.fmt.allocPrint(alloc, "{s}.tmp", .{self.path}) catch return;
        defer alloc.free(tmp_path);
        const io = pluginIo();
        var file = std.Io.Dir.cwd().createFile(io, tmp_path, .{}) catch return;
        file.writePositionalAll(io, buf.items, 0) catch {
            file.close(io);
            std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
            return;
        };
        file.close(io);
        // rename overwrite — Windows 는 dst 가 있으면 fail 라 미리 delete (atomic
        // 손실하지만 Windows ReplaceFile 호출 안 하는 trade-off; v1 단순화).
        if (@import("builtin").os.tag == .windows) {
            std.Io.Dir.cwd().deleteFile(io, self.path) catch {};
        }
        std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), self.path, io) catch {
            // rename 실패 시 orphan .tmp 누적 방지.
            std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
        };
    }
};

fn getStore(name: []const u8) ?*Store {
    if (name.len == 0 or name.len > MAX_NAME_LEN) return null;
    // dot-only 이름 거부 — "." / ".." 는 character whitelist 만으로 막을 수 없음
    // (alphanumeric/-/_/. 모두 단일/이중 dot 통과). path traversal hardening.
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return null;
    // 이름 character validation — path traversal 방지.
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.') return null;
    }
    registry_mutex.lockUncancelable(pluginIo());
    defer registry_mutex.unlock(pluginIo());
    if (stores.get(name)) |s| return s;
    const s = Store.init(name) orelse return null;
    stores.put(s.name, s) catch {
        // registry put OOM — store 본체와 내부 할당 즉시 해제, 누수 방지.
        s.deinit();
        return null;
    };
    return s;
}

// ============================================
// Helpers
// ============================================

fn appendJsonEscaped(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            0...8, 11, 12, 14...31 => {
                var tmp: [6]u8 = undefined;
                const out = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c}) catch continue;
                try buf.appendSlice(allocator, out);
            },
            else => try buf.append(allocator, c),
        }
    }
}

fn jsonValueToOwned(val: std.json.Value) ?[]const u8 {
    const a = alloc;
    switch (val) {
        .string => |s| {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(a);
            buf.appendSlice(a, "\"") catch return null;
            appendJsonEscaped(a, &buf, s) catch return null;
            buf.appendSlice(a, "\"") catch return null;
            return buf.toOwnedSlice(a) catch null;
        },
        .integer => |i| return std.fmt.allocPrint(a, "{d}", .{i}) catch null,
        .float => |f| return std.fmt.allocPrint(a, "{d}", .{f}) catch null,
        .bool => |b| return a.dupe(u8, if (b) "true" else "false") catch null,
        .null => return a.dupe(u8, "null") catch null,
        // object/array 는 loadFromDisk 의 std.json.parseFromSlice 결과지만, 다시
        // raw JSON 으로 stringify 하려면 std.json.Stringify Writer 인터페이스가
        // 0.16 에서 변경됨. 단순화: 디스크에서 load 시 nested object/array 는 skip
        // (사용자가 다시 set 하면 raw JSON 으로 store 됨 — set path 는 wire raw
        // 직접 저장이라 영향 없음). 한계로 문서화.
        .object, .array => return null,
        else => return null,
    }
}

fn cGetenv(name: [*:0]const u8) ?[]const u8 {
    const raw = std.c.getenv(name) orelse return null;
    return std.mem.span(raw);
}

fn makePath(name: []const u8) ?[]const u8 {
    const builtin = @import("builtin");
    if (builtin.os.tag == .macos) {
        const home = cGetenv("HOME") orelse return null;
        return std.fmt.allocPrint(alloc, "{s}/Library/Application Support/suji-app/store/{s}.json", .{ home, name }) catch null;
    } else if (builtin.os.tag == .linux) {
        if (cGetenv("XDG_DATA_HOME")) |dir| {
            return std.fmt.allocPrint(alloc, "{s}/suji-app/store/{s}.json", .{ dir, name }) catch null;
        }
        const home = cGetenv("HOME") orelse return null;
        return std.fmt.allocPrint(alloc, "{s}/.local/share/suji-app/store/{s}.json", .{ home, name }) catch null;
    } else if (builtin.os.tag == .windows) {
        const appdata = cGetenv("APPDATA") orelse return null;
        return std.fmt.allocPrint(alloc, "{s}\\suji-app\\store\\{s}.json", .{ appdata, name }) catch null;
    }
    return null;
}

fn resolveStoreName(req: suji.Request) []const u8 {
    return req.string("name") orelse "config";
}

// ============================================
// 핸들러
// ============================================

fn storeGet(req: suji.Request, _: suji.InvokeEvent) suji.Response {
    const key = req.string("key") orelse return req.err("missing key");
    const name = resolveStoreName(req);
    const store = getStore(name) orelse return req.err("invalid name");
    if (store.get(key)) |value| {
        return req.okRaw(std.fmt.allocPrint(req.arena, "{{\"value\":{s}}}", .{value}) catch return req.err("alloc"));
    }
    return req.okRaw("{\"value\":null}");
}

fn storeSet(req: suji.Request, _: suji.InvokeEvent) suji.Response {
    const key = req.string("key") orelse return req.err("missing key");
    const value = suji.extractJsonValue(req.raw, "value") orelse return req.err("missing value");
    const name = resolveStoreName(req);
    const store = getStore(name) orelse return req.err("invalid name");
    if (!store.set(key, value)) return req.err("write failed");
    return req.okRaw("{\"ok\":true}");
}

fn storeHas(req: suji.Request, _: suji.InvokeEvent) suji.Response {
    const key = req.string("key") orelse return req.err("missing key");
    const name = resolveStoreName(req);
    const store = getStore(name) orelse return req.err("invalid name");
    const body = std.fmt.allocPrint(req.arena, "{{\"has\":{}}}", .{store.has(key)}) catch return req.err("alloc");
    return req.okRaw(body);
}

fn storeDelete(req: suji.Request, _: suji.InvokeEvent) suji.Response {
    const key = req.string("key") orelse return req.err("missing key");
    const name = resolveStoreName(req);
    const store = getStore(name) orelse return req.err("invalid name");
    _ = store.delete(key);
    return req.okRaw("{\"ok\":true}");
}

fn storeClear(req: suji.Request, _: suji.InvokeEvent) suji.Response {
    const name = resolveStoreName(req);
    const store = getStore(name) orelse return req.err("invalid name");
    store.clear();
    return req.okRaw("{\"ok\":true}");
}

fn storeKeys(req: suji.Request, _: suji.InvokeEvent) suji.Response {
    const name = resolveStoreName(req);
    const store = getStore(name) orelse return req.err("invalid name");
    const result = store.keys(req.arena) orelse return req.err("alloc");
    return req.okRaw(result);
}
fn storeValues(req: suji.Request, _: suji.InvokeEvent) suji.Response {
    const name = resolveStoreName(req);
    const store = getStore(name) orelse return req.err("invalid name");
    const result = store.values(req.arena) orelse return req.err("alloc");
    return req.okRaw(result);
}
fn storeEntries(req: suji.Request, _: suji.InvokeEvent) suji.Response {
    const name = resolveStoreName(req);
    const store = getStore(name) orelse return req.err("invalid name");
    const result = store.entries(req.arena) orelse return req.err("alloc");
    return req.okRaw(result);
}

fn storeSize(req: suji.Request, _: suji.InvokeEvent) suji.Response {
    const name = resolveStoreName(req);
    const store = getStore(name) orelse return req.err("invalid name");
    const body = std.fmt.allocPrint(req.arena, "{{\"size\":{d}}}", .{store.size()}) catch return req.err("alloc");
    return req.okRaw(body);
}

fn storeGetPath(req: suji.Request, _: suji.InvokeEvent) suji.Response {
    const name = resolveStoreName(req);
    const store = getStore(name) orelse return req.err("invalid name");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(req.arena);
    out.appendSlice(req.arena, "{\"path\":\"") catch return req.err("alloc");
    appendJsonEscaped(req.arena, &out, store.path) catch return req.err("alloc");
    out.appendSlice(req.arena, "\"}") catch return req.err("alloc");
    const final = out.toOwnedSlice(req.arena) catch return req.err("alloc");
    return req.okRaw(final);
}

comptime {
    _ = suji.exportApp(app);
}
