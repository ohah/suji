const std = @import("std");
const suji = @import("suji");

pub const app = suji.app()
    .named("state")
    .handle("state:get", stateGet)
    .handle("state:set", stateSet)
    .handle("state:delete", stateDelete)
    .handle("state:keys", stateKeys)
    .handle("state:clear", stateClear);

// ============================================
// Scope 정책 (Phase 2.5)
//   "global"           — 모든 창이 공유 (기본값, scope 생략 시).
//   "window:<id>"      — 특정 창 전용 (id는 sender 창 = event.window.id).
//   "window"           — wire의 sender 창 id로 자동 치환 → "window:<event.window.id>".
//   "session:<name>"   — 그룹/세션 (예: "session:onboarding"). 자유 문자열.
//
// 저장 키 포맷: `<scope>::<user_key>`. 디스크 JSON에 그대로 저장.
//   기존(prefix 없는) 키는 로드 시 `global::<key>`로 마이그레이션.
const SCOPE_SEP = "::";

fn isScopeValidChars(s: []const u8) bool {
    for (s) |c| {
        if (c == '"' or c == '\\' or c < 0x20) return false;
    }
    return true;
}

/// req.string("scope") + InvokeEvent로 effective scope 결정.
/// 잘못된 입력은 "global"로 폴백 — 안전이 우선이고 KV 분기는 키 충돌 없이 기능.
fn resolveScope(arena: std.mem.Allocator, raw_scope: ?[]const u8, event: suji.InvokeEvent) []const u8 {
    const s = raw_scope orelse return "global";
    if (s.len == 0) return "global";
    if (!isScopeValidChars(s)) return "global";
    // "window" 특수값 — sender 창 id로 자동 치환. id=0(주입 안 됨)이면 "global" 폴백.
    if (std.mem.eql(u8, s, "window")) {
        if (event.window.id == 0) return "global";
        return std.fmt.allocPrint(arena, "window:{d}", .{event.window.id}) catch "global";
    }
    return s;
}

/// "<scope>::<key>" 합성. arena 할당.
fn scopedKey(arena: std.mem.Allocator, scope: []const u8, key: []const u8) ?[]const u8 {
    return std.fmt.allocPrint(arena, "{s}{s}{s}", .{ scope, SCOPE_SEP, key }) catch null;
}

// ============================================
// State Store (HashMap + Mutex + JSON 파일 영속성)
// ============================================

var gpa: std.heap.DebugAllocator(.{}) = .init;
const alloc = gpa.allocator();

// 메인 프로세스의 std.Io를 SujiCore 경유로 획득 (자체 Threaded 생성하지 않음).
// backend_init 이후부터 사용 가능.
fn pluginIo() std.Io {
    return suji.io();
}

var store: Store = .{};

const Store = struct {
    map: std.StringHashMap([]const u8) = std.StringHashMap([]const u8).init(alloc),
    mutex: std.Io.Mutex = .init,
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
        self.mutex.lockUncancelable(pluginIo());
        defer self.mutex.unlock(pluginIo());
        self.ensureInit();
        return self.map.get(key);
    }

    /// 내부 KV 저장 + 이벤트 발행. event 채널 이름은 user-key/scope를 사용해
    /// 사용자에게 노출 (저장 키의 prefix는 구현 detail).
    fn setWithEventChannel(self: *Store, full_key: []const u8, value: []const u8, scope: []const u8, user_key: []const u8) void {
        // Phase 1: 뮤텍스 하에서 맵 업데이트 + 디스크 저장
        {
            self.mutex.lockUncancelable(pluginIo());
            defer self.mutex.unlock(pluginIo());
            self.ensureInit();

            // 기존 값 해제
            if (self.map.fetchRemove(full_key)) |kv| {
                alloc.free(kv.key);
                alloc.free(kv.value);
            }

            const owned_key = alloc.dupe(u8, full_key) catch return;
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
        // 이벤트 채널: "state:<scope>:<user_key>" — 구독자가 scope별로 분기 가능.
        // global scope는 기존 호환을 위해 "state:<user_key>"로 단축.
        var event_buf: [512]u8 = undefined;
        const event_name = if (std.mem.eql(u8, scope, "global"))
            std.fmt.bufPrint(&event_buf, "state:{s}", .{user_key}) catch return
        else
            std.fmt.bufPrint(&event_buf, "state:{s}:{s}", .{ scope, user_key }) catch return;
        suji.send(event_name, value);
    }

    /// 기존 인터페이스 (비스코프 단위 테스트 호환). 항상 global로 처리.
    fn set(self: *Store, key: []const u8, value: []const u8) void {
        var buf: [256]u8 = undefined;
        const full = std.fmt.bufPrint(&buf, "global{s}{s}", .{ SCOPE_SEP, key }) catch return;
        // ArrayList allocations에 fmt 결과 슬라이스 그대로 전달 — setWithEventChannel이 dupe.
        self.setWithEventChannel(full, value, "global", key);
    }

    fn delete(self: *Store, key: []const u8) bool {
        self.mutex.lockUncancelable(pluginIo());
        defer self.mutex.unlock(pluginIo());
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
        return self.keysFiltered(arena, null);
    }

    /// scope_filter가 있으면 해당 scope 키만, prefix(`<scope>::`) 제거한 user-key로 반환.
    /// null이면 모든 키를 prefix 포함해서 반환.
    fn keysFiltered(self: *Store, arena: std.mem.Allocator, scope_filter: ?[]const u8) ?[]const u8 {
        self.mutex.lockUncancelable(pluginIo());
        defer self.mutex.unlock(pluginIo());
        self.ensureInit();

        // prefix 매칭용 버퍼 — scope + "::"
        var prefix_buf: [256]u8 = undefined;
        const prefix: ?[]const u8 = if (scope_filter) |s|
            std.fmt.bufPrint(&prefix_buf, "{s}{s}", .{ s, SCOPE_SEP }) catch null
        else
            null;

        var buf: std.ArrayList(u8) = .empty;
        buf.appendSlice(arena, "{\"keys\":[") catch return null;
        var iter = self.map.iterator();
        var first = true;
        while (iter.next()) |entry| {
            const k = entry.key_ptr.*;
            if (prefix) |p| {
                if (!std.mem.startsWith(u8, k, p)) continue;
                const user_key = k[p.len..];
                if (!first) buf.appendSlice(arena, ",") catch break;
                buf.print(arena, "\"{s}\"", .{user_key}) catch break;
            } else {
                if (!first) buf.appendSlice(arena, ",") catch break;
                buf.print(arena, "\"{s}\"", .{k}) catch break;
            }
            first = false;
        }
        buf.appendSlice(arena, "]}") catch return null;
        return buf.toOwnedSlice(arena) catch null;
    }

    /// 전체 초기화.
    fn clear(self: *Store) void {
        self.mutex.lockUncancelable(pluginIo());
        defer self.mutex.unlock(pluginIo());
        var iter = self.map.iterator();
        while (iter.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            alloc.free(entry.value_ptr.*);
        }
        self.map.clearRetainingCapacity();
        self.persistUnlocked();
    }

    /// 특정 scope의 키만 제거.
    fn clearScope(self: *Store, scope: []const u8) void {
        self.mutex.lockUncancelable(pluginIo());
        defer self.mutex.unlock(pluginIo());
        var prefix_buf: [256]u8 = undefined;
        const prefix = std.fmt.bufPrint(&prefix_buf, "{s}{s}", .{ scope, SCOPE_SEP }) catch return;

        // 두 단계: 매칭 키 수집 → 일괄 제거 (iter 중 mutate 회피).
        var to_remove: std.ArrayList([]const u8) = .empty;
        defer to_remove.deinit(alloc);
        var iter = self.map.iterator();
        while (iter.next()) |entry| {
            if (std.mem.startsWith(u8, entry.key_ptr.*, prefix)) {
                to_remove.append(alloc, entry.key_ptr.*) catch continue;
            }
        }
        for (to_remove.items) |k| {
            if (self.map.fetchRemove(k)) |kv| {
                alloc.free(kv.key);
                alloc.free(kv.value);
            }
        }
        self.persistUnlocked();
    }

    fn loadFromDisk(self: *Store) void {
        const path = self.data_path orelse return;
        const content = std.Io.Dir.cwd().readFileAlloc(pluginIo(), path, alloc, .limited(1024 * 1024)) catch return;
        defer alloc.free(content);

        const parsed = std.json.parseFromSlice(std.json.Value, alloc, content, .{}) catch return;
        defer parsed.deinit();

        if (parsed.value != .object) return;

        var iter = parsed.value.object.iterator();
        while (iter.next()) |entry| {
            const key = entry.key_ptr.*;
            const val = entry.value_ptr.*;

            const val_str = jsonValueToString(val) orelse continue;

            // 마이그레이션: 기존 (prefix 없는) 키는 "global::" 으로 변환해서 저장.
            const has_prefix = std.mem.indexOf(u8, key, SCOPE_SEP) != null;
            const owned_key: []const u8 = if (has_prefix)
                (alloc.dupe(u8, key) catch {
                    alloc.free(val_str);
                    continue;
                })
            else
                (std.fmt.allocPrint(alloc, "global{s}{s}", .{ SCOPE_SEP, key }) catch {
                    alloc.free(val_str);
                    continue;
                });

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
                std.Io.Dir.cwd().createDirPath(pluginIo(), path[0..sep]) catch {};
            }
            self.dir_created = true;
        }

        const a = alloc;
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(a);

        buf.appendSlice(a, "{") catch return;
        var map_iter = self.map.iterator();
        var first = true;
        while (map_iter.next()) |entry| {
            if (!first) buf.appendSlice(a, ",") catch continue;
            buf.print(a, "\"{s}\":{s}", .{ entry.key_ptr.*, entry.value_ptr.* }) catch continue;
            first = false;
        }
        buf.appendSlice(a, "}") catch return;

        const io = pluginIo();
        var file = std.Io.Dir.cwd().createFile(io, path, .{}) catch return;
        defer file.close(io);
        var fw_buf: [4096]u8 = undefined;
        var fw = file.writer(io, &fw_buf);
        fw.interface.writeAll(buf.items) catch {};
        fw.interface.flush() catch {};
    }
};

fn cGetenv(name: [*:0]const u8) ?[]const u8 {
    const raw = std.c.getenv(name) orelse return null;
    return std.mem.span(raw);
}

fn getDataPath() ?[]const u8 {
    const builtin = @import("builtin");
    if (builtin.os.tag == .macos) {
        const home = cGetenv("HOME") orelse return null;
        // TODO: app name을 config에서 받아야 함. 지금은 하드코딩.
        return std.fmt.allocPrint(alloc, "{s}/Library/Application Support/suji-app/state.json", .{home}) catch null;
    } else if (builtin.os.tag == .linux) {
        if (cGetenv("XDG_DATA_HOME")) |dir| {
            return std.fmt.allocPrint(alloc, "{s}/suji-app/state.json", .{dir}) catch null;
        }
        const home = cGetenv("HOME") orelse return null;
        return std.fmt.allocPrint(alloc, "{s}/.local/share/suji-app/state.json", .{home}) catch null;
    } else if (builtin.os.tag == .windows) {
        const appdata = cGetenv("APPDATA") orelse return null;
        return std.fmt.allocPrint(alloc, "{s}\\suji-app\\state.json", .{appdata}) catch null;
    }
    return null;
}

// ============================================
// 핸들러
// ============================================

fn stateGet(req: suji.Request, event: suji.InvokeEvent) suji.Response {
    const key = req.string("key") orelse return req.err("missing key");
    const scope = resolveScope(req.arena, req.string("scope"), event);
    const full = scopedKey(req.arena, scope, key) orelse return req.err("alloc error");
    if (store.get(full)) |value| {
        return req.okRaw(std.fmt.allocPrint(req.arena, "{{\"value\":{s}}}", .{value}) catch return req.err("format error"));
    }
    return req.okRaw("{\"value\":null}");
}

fn stateSet(req: suji.Request, event: suji.InvokeEvent) suji.Response {
    const key = req.string("key") orelse return req.err("missing key");
    const value = suji.extractJsonValue(req.raw, "value") orelse return req.err("missing value");
    const scope = resolveScope(req.arena, req.string("scope"), event);
    const full = scopedKey(req.arena, scope, key) orelse return req.err("alloc error");
    store.setWithEventChannel(full, value, scope, key);
    return req.okRaw("{\"ok\":true}");
}

fn stateDelete(req: suji.Request, event: suji.InvokeEvent) suji.Response {
    const key = req.string("key") orelse return req.err("missing key");
    const scope = resolveScope(req.arena, req.string("scope"), event);
    const full = scopedKey(req.arena, scope, key) orelse return req.err("alloc error");
    _ = store.delete(full);
    return req.okRaw("{\"ok\":true}");
}

fn stateClear(req: suji.Request, event: suji.InvokeEvent) suji.Response {
    // scope 명시 시 그 scope만 비움. 미지정/"*"이면 전체 클리어 (기존 호환).
    const scope_opt = req.string("scope");
    if (scope_opt == null or std.mem.eql(u8, scope_opt.?, "*")) {
        store.clear();
    } else {
        const scope = resolveScope(req.arena, scope_opt, event);
        store.clearScope(scope);
    }
    return req.okRaw("{\"ok\":true}");
}

fn stateKeys(req: suji.Request, event: suji.InvokeEvent) suji.Response {
    // scope 명시 시 prefix 매칭만 반환. 미지정이면 모든 키 — 응답에 prefix 포함.
    const scope_filter: ?[]const u8 = if (req.string("scope")) |raw|
        resolveScope(req.arena, raw, event)
    else
        null;
    const result = store.keysFiltered(req.arena, scope_filter) orelse return req.err("alloc error");
    return req.okRaw(result);
}

comptime {
    _ = suji.exportApp(app);
}
