//! iOS/Android 정적 링크 SQLite 백엔드.
//!
//! 데스크탑 `plugins/sqlite` 의 모바일 대응판. 데스크탑은 동적 dylib
//! (BackendRegistry dlopen) 이지만 모바일은 정적 링크 모델이라 코어/SDK
//! 독립으로 재구현한다(예제 zig/rust/go 백엔드와 동형). 단일 바이너리
//! 심볼 충돌을 피하려 고유 네임스페이스 `suji_sqlite_backend_*` 로 노출.
//!
//! 응답 포맷은 데스크탑 `plugins/sqlite` (`req.okRaw` → `{"from":"zig",
//! "result":..}` / `req.err` → `{"from":"zig","error":..}`) 와 **바이트
//! 동형** — 동일한 Rust/Go/JS 래퍼(`plugins/sqlite/{rust,go,js}`)가
//! 데스크탑·모바일 양쪽에서 무수정 동작(Tauri 동형 원칙).
//!
//! ⚠️ 정직 경계: 경로는 `:memory:` 또는 절대경로만(모바일 호스트가 자기
//! 샌드박스 쓰기 가능 디렉토리를 절대경로로 전달). 상대경로는 명시 에러
//! — 정적 lib 에서 OS 샌드박스 경로를 추측하지 않음(데스크탑은 app-data
//! 하위 해소, 모바일은 호스트 책임).

const std = @import("std");

const c = @cImport({
    @cInclude("sqlite3.h");
});

const alloc = std.heap.c_allocator;

/// 코어/SDK 독립이라 `suji.io()` 를 못 쓴다 → src/embed.zig 코어와 동일한
/// `std.Io.Threaded.init_single_threaded` 패턴을 자체 보유(zig http 백엔드와
/// 동형). 레지스트리 뮤텍스 전용(데스크탑 plugins/sqlite 의 suji.io() 대체).
var sqlite_threaded: std.Io.Threaded = std.Io.Threaded.init_single_threaded;
fn bio() std.Io {
    return sqlite_threaded.io();
}

/// SQLITE_STATIC (destructor=null) — sqlite 가 복사하지 않음. 안전한 이유:
/// bind 값은 요청 버퍼(escape 없는 std.json 문자열) 또는 per-call arena 에
/// 있고, arena 는 handle_ipc 스코프에서 핸들러(stmt finalize defer 포함)가
/// 완전히 반환한 *뒤* deinit → step/finalize 동안 항상 유효.
const SQLITE_STATIC: c.sqlite3_destructor_type = null;

// ============================================
// 연결 레지스트리 (dbId → *sqlite3, 글로벌 뮤텍스)
// ============================================
// better-sqlite3 식 동기·직렬 모델. SQLITE_THREADSAFE=1 + 단일 뮤텍스로
// 모든 호출 직렬화 (데스크탑 plugins/sqlite 와 동일 정책).

const Registry = struct {
    map: std.AutoHashMap(u32, *c.sqlite3) = std.AutoHashMap(u32, *c.sqlite3).init(alloc),
    mutex: std.Io.Mutex = .init,
    next_id: u32 = 1,
};
var reg: Registry = .{};

// ============================================
// JSON 직렬화 (데스크탑 plugins/sqlite app.zig 와 동일 정책)
// ============================================

fn appendJsonString(out: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) !void {
    try out.append(a, '"');
    for (s) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(a, "\\\""),
            '\\' => try out.appendSlice(a, "\\\\"),
            '\n' => try out.appendSlice(a, "\\n"),
            '\r' => try out.appendSlice(a, "\\r"),
            '\t' => try out.appendSlice(a, "\\t"),
            0x08 => try out.appendSlice(a, "\\b"),
            0x0C => try out.appendSlice(a, "\\f"),
            else => if (ch < 0x20) {
                try out.appendSlice(a, "\\u00");
                const hex = "0123456789abcdef";
                try out.append(a, hex[(ch >> 4) & 0xF]);
                try out.append(a, hex[ch & 0xF]);
            } else try out.append(a, ch),
        }
    }
    try out.append(a, '"');
}

/// prepare 후 tail 에 공백/세미콜론 외 토큰이 있으면 true (추가 문 존재).
fn hasTrailingStatement(tail: [*c]const u8, end: [*]const u8) bool {
    var p: [*]const u8 = @ptrCast(tail);
    while (@intFromPtr(p) < @intFromPtr(end)) : (p += 1) {
        const ch = p[0];
        if (ch != ' ' and ch != '\t' and ch != '\n' and ch != '\r' and ch != ';') return true;
    }
    return false;
}

/// params 배열을 prepared stmt 에 1-base 바인딩. SQLITE_STATIC(복사 안 함) —
/// bind 값(요청 버퍼 또는 per-call arena)은 핸들러가 step/finalize 를 모두
/// 마치고 반환한 *뒤* handle_ipc 의 arena.deinit 가 돌아 항상 유효(상단
/// SQLITE_STATIC 주석 참조).
fn bindParams(stmt: *c.sqlite3_stmt, params: []const std.json.Value) c_int {
    for (params, 0..) |p, i| {
        const idx: c_int = @intCast(i + 1);
        const rc: c_int = switch (p) {
            .null => c.sqlite3_bind_null(stmt, idx),
            .bool => |b| c.sqlite3_bind_int(stmt, idx, if (b) 1 else 0),
            .integer => |n| c.sqlite3_bind_int64(stmt, idx, n),
            .float => |f| c.sqlite3_bind_double(stmt, idx, f),
            .number_string => |s| c.sqlite3_bind_text(stmt, idx, s.ptr, @intCast(s.len), SQLITE_STATIC),
            .string => |s| c.sqlite3_bind_text(stmt, idx, s.ptr, @intCast(s.len), SQLITE_STATIC),
            else => c.SQLITE_MISMATCH,
        };
        if (rc != c.SQLITE_OK) return rc;
    }
    return c.SQLITE_OK;
}

/// 컬럼 값 → JSON. BLOB 은 base64. NaN/Inf 는 유효 JSON 위해 null.
fn appendColumn(out: *std.ArrayList(u8), a: std.mem.Allocator, s: *c.sqlite3_stmt, col: c_int) !void {
    switch (c.sqlite3_column_type(s, col)) {
        c.SQLITE_NULL => try out.appendSlice(a, "null"),
        c.SQLITE_INTEGER => try out.print(a, "{d}", .{c.sqlite3_column_int64(s, col)}),
        c.SQLITE_FLOAT => {
            const f = c.sqlite3_column_double(s, col);
            if (std.math.isNan(f) or std.math.isInf(f))
                try out.appendSlice(a, "null")
            else
                try out.print(a, "{d}", .{f});
        },
        c.SQLITE_TEXT => {
            const ptr = c.sqlite3_column_text(s, col);
            const len: usize = @intCast(c.sqlite3_column_bytes(s, col));
            try appendJsonString(out, a, if (ptr != null) ptr[0..len] else "");
        },
        c.SQLITE_BLOB => {
            const ptr = c.sqlite3_column_blob(s, col);
            const len: usize = @intCast(c.sqlite3_column_bytes(s, col));
            const raw = if (ptr != null) @as([*]const u8, @ptrCast(ptr))[0..len] else "";
            const enc = std.base64.standard.Encoder;
            const buf = try a.alloc(u8, enc.calcSize(raw.len));
            try out.append(a, '"');
            try out.appendSlice(a, enc.encode(buf, raw));
            try out.append(a, '"');
        },
        else => try out.appendSlice(a, "null"),
    }
}

// ============================================
// 요청 파싱 (std.json — 데스크탑 SDK 비의존, escape 안전)
// ============================================

const Req = struct {
    parsed: std.json.Parsed(std.json.Value),
    obj: std.json.ObjectMap,

    fn str(self: Req, key: []const u8) ?[]const u8 {
        const v = self.obj.get(key) orelse return null;
        return switch (v) {
            .string => |s| s,
            else => null,
        };
    }
    fn dbId(self: Req) ?u32 {
        const v = self.obj.get("dbId") orelse return null;
        const n: i64 = switch (v) {
            .integer => |x| x,
            else => return null,
        };
        if (n <= 0 or n > std.math.maxInt(u32)) return null;
        return @intCast(n);
    }
    fn params(self: Req) []const std.json.Value {
        const v = self.obj.get("params") orelse return &.{};
        return switch (v) {
            .array => |arr| arr.items,
            else => &.{},
        };
    }
};

// ============================================
// 응답 빌더 — 데스크탑 plugins/sqlite 와 키-동형
// ============================================

fn dupZ(s: []const u8) [*:0]u8 {
    const b = alloc.allocSentinel(u8, s.len, 0) catch return @constCast("{}");
    @memcpy(b, s);
    return b.ptr;
}

fn okRaw(a: std.mem.Allocator, json: []const u8) [*:0]u8 {
    const r = std.fmt.allocPrint(a, "{{\"from\":\"zig\",\"result\":{s}}}", .{json}) catch return @constCast("{}");
    return dupZ(r);
}

fn errMsg(a: std.mem.Allocator, msg: []const u8) [*:0]u8 {
    var out = std.ArrayList(u8).empty;
    out.appendSlice(a, "{\"from\":\"zig\",\"error\":") catch return @constCast("{}");
    appendJsonString(&out, a, msg) catch return @constCast("{}");
    out.append(a, '}') catch return @constCast("{}");
    return dupZ(out.items);
}

fn dbErr(a: std.mem.Allocator, db: *c.sqlite3) [*:0]u8 {
    const m = c.sqlite3_errmsg(db);
    return errMsg(a, if (m != null) std.mem.span(m) else "sqlite error");
}

// ============================================
// 핸들러 (데스크탑 plugins/sqlite app.zig 와 동일 의미)
// ============================================

fn resolvePathZ(a: std.mem.Allocator, path: []const u8) ?[:0]const u8 {
    if (path.len == 0) return null;
    if (std.mem.eql(u8, path, ":memory:")) return a.dupeZ(u8, ":memory:") catch null;
    // 모바일: 절대경로만(호스트가 샌드박스 경로 전달). 상대경로는 호출부에서 거부.
    if (path[0] != '/') return null;
    return a.dupeZ(u8, path) catch null;
}

fn sqlOpen(a: std.mem.Allocator, q: Req) [*:0]u8 {
    const path = q.str("path") orelse return errMsg(a, "missing path");
    const cpath = resolvePathZ(a, path) orelse
        return errMsg(a, "invalid path (mobile: use \":memory:\" or an absolute sandbox path)");

    var db: ?*c.sqlite3 = null;
    const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE;
    if (c.sqlite3_open_v2(cpath.ptr, &db, flags, null) != c.SQLITE_OK or db == null) {
        if (db) |d| _ = c.sqlite3_close_v2(d);
        return errMsg(a, "open failed");
    }

    reg.mutex.lockUncancelable(bio());
    defer reg.mutex.unlock(bio());
    const id = reg.next_id;
    reg.map.put(id, db.?) catch {
        _ = c.sqlite3_close_v2(db.?);
        return errMsg(a, "registry full");
    };
    reg.next_id += 1;
    return okRaw(a, std.fmt.allocPrint(a, "{{\"dbId\":{d}}}", .{id}) catch return errMsg(a, "format error"));
}

fn sqlExecute(a: std.mem.Allocator, q: Req) [*:0]u8 {
    reg.mutex.lockUncancelable(bio());
    defer reg.mutex.unlock(bio());

    const db = reg.map.get(q.dbId() orelse return errMsg(a, "invalid dbId")) orelse
        return errMsg(a, "invalid dbId");
    const sql = q.str("sql") orelse return errMsg(a, "missing sql");
    if (sql.len == 0) return errMsg(a, "empty sql");
    const params = q.params();
    const end: [*]const u8 = sql.ptr + sql.len;

    if (params.len > 0) {
        var stmt: ?*c.sqlite3_stmt = null;
        var tail: [*c]const u8 = null;
        if (c.sqlite3_prepare_v2(db, sql.ptr, @intCast(sql.len), &stmt, &tail) != c.SQLITE_OK)
            return dbErr(a, db);
        const s = stmt orelse return errMsg(a, "empty statement");
        defer _ = c.sqlite3_finalize(s);
        if (hasTrailingStatement(tail, end))
            return errMsg(a, "params not allowed with multi-statement sql");
        if (bindParams(s, params) != c.SQLITE_OK) return dbErr(a, db);
        const rc = c.sqlite3_step(s);
        if (rc != c.SQLITE_DONE and rc != c.SQLITE_ROW) return dbErr(a, db);
    } else {
        var cursor: [*]const u8 = sql.ptr;
        while (@intFromPtr(cursor) < @intFromPtr(end)) {
            var tail: [*c]const u8 = null;
            var stmt: ?*c.sqlite3_stmt = null;
            const remaining: c_int = @intCast(@intFromPtr(end) - @intFromPtr(cursor));
            if (c.sqlite3_prepare_v2(db, cursor, remaining, &stmt, &tail) != c.SQLITE_OK)
                return dbErr(a, db);
            const next: [*]const u8 = @ptrCast(tail);
            if (stmt) |s| {
                const rc = c.sqlite3_step(s);
                _ = c.sqlite3_finalize(s);
                if (rc != c.SQLITE_DONE and rc != c.SQLITE_ROW) return dbErr(a, db);
            }
            if (@intFromPtr(next) <= @intFromPtr(cursor)) break;
            cursor = next;
        }
    }

    const changes = c.sqlite3_changes(db);
    const last_id = c.sqlite3_last_insert_rowid(db);
    return okRaw(a, std.fmt.allocPrint(
        a,
        "{{\"changes\":{d},\"lastInsertRowid\":{d}}}",
        .{ changes, last_id },
    ) catch return errMsg(a, "format error"));
}

fn sqlQuery(a: std.mem.Allocator, q: Req) [*:0]u8 {
    reg.mutex.lockUncancelable(bio());
    defer reg.mutex.unlock(bio());

    const db = reg.map.get(q.dbId() orelse return errMsg(a, "invalid dbId")) orelse
        return errMsg(a, "invalid dbId");
    const sql = q.str("sql") orelse return errMsg(a, "missing sql");
    if (sql.len == 0) return errMsg(a, "empty sql");

    var stmt: ?*c.sqlite3_stmt = null;
    var tail: [*c]const u8 = null;
    if (c.sqlite3_prepare_v2(db, sql.ptr, @intCast(sql.len), &stmt, &tail) != c.SQLITE_OK)
        return dbErr(a, db);
    const s = stmt orelse return errMsg(a, "empty statement");
    defer _ = c.sqlite3_finalize(s);
    if (hasTrailingStatement(tail, sql.ptr + sql.len))
        return errMsg(a, "multi-statement not supported in query — use execute");

    if (bindParams(s, q.params()) != c.SQLITE_OK) return dbErr(a, db);

    var out = std.ArrayList(u8).empty;
    out.ensureTotalCapacity(a, 256) catch return errMsg(a, "alloc error");
    out.appendSlice(a, "{\"rows\":[") catch return errMsg(a, "alloc error");

    const ncol = c.sqlite3_column_count(s);
    const names = a.alloc([]const u8, @intCast(@max(ncol, 0))) catch return errMsg(a, "alloc error");
    {
        var col: c_int = 0;
        while (col < ncol) : (col += 1) {
            const nm = c.sqlite3_column_name(s, col);
            names[@intCast(col)] = if (nm != null) std.mem.span(nm) else "";
        }
    }

    var row_n: usize = 0;
    while (true) {
        const rc = c.sqlite3_step(s);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return dbErr(a, db);

        if (row_n > 0) out.append(a, ',') catch return errMsg(a, "alloc error");
        out.append(a, '{') catch return errMsg(a, "alloc error");
        var col: c_int = 0;
        while (col < ncol) : (col += 1) {
            if (col > 0) out.append(a, ',') catch return errMsg(a, "alloc error");
            appendJsonString(&out, a, names[@intCast(col)]) catch return errMsg(a, "alloc error");
            out.append(a, ':') catch return errMsg(a, "alloc error");
            appendColumn(&out, a, s, col) catch return errMsg(a, "alloc error");
        }
        out.append(a, '}') catch return errMsg(a, "alloc error");
        row_n += 1;
    }
    out.appendSlice(a, "]}") catch return errMsg(a, "alloc error");
    return okRaw(a, out.items);
}

fn sqlClose(a: std.mem.Allocator, q: Req) [*:0]u8 {
    reg.mutex.lockUncancelable(bio());
    defer reg.mutex.unlock(bio());
    const kv = reg.map.fetchRemove(q.dbId() orelse return errMsg(a, "invalid dbId")) orelse
        return errMsg(a, "invalid dbId");
    _ = c.sqlite3_close_v2(kv.value);
    return okRaw(a, "{\"ok\":true}");
}

// ============================================
// C ABI (모바일 정적 링크 — 고유 심볼 suji_sqlite_backend_*)
// ============================================

export fn suji_sqlite_backend_init(core: ?*const anyopaque) callconv(.c) void {
    _ = core; // cross-call 미사용 (예제 zig/rust/go 와 동형)
}

export fn suji_sqlite_backend_handle_ipc(req: [*:0]const u8) callconv(.c) [*:0]u8 {
    const r = std.mem.span(req);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, a, r, .{}) catch
        return dupZ("{\"from\":\"zig\",\"error\":\"invalid json\"}");
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return dupZ("{\"from\":\"zig\",\"error\":\"request not an object\"}"),
    };
    const q = Req{ .parsed = parsed, .obj = obj };

    const cmd = q.str("cmd") orelse "";
    // dupZ 는 호스트가 free 하는 c_allocator 버퍼 — arena 응답을 복제 후 반환.
    if (std.mem.eql(u8, cmd, "sql:open")) return sqlOpen(a, q);
    if (std.mem.eql(u8, cmd, "sql:execute")) return sqlExecute(a, q);
    if (std.mem.eql(u8, cmd, "sql:query")) return sqlQuery(a, q);
    if (std.mem.eql(u8, cmd, "sql:close")) return sqlClose(a, q);
    return errMsg(a, "unknown cmd");
}

export fn suji_sqlite_backend_free(p: ?[*:0]u8) callconv(.c) void {
    if (p) |ptr| {
        const s = std.mem.span(ptr);
        if (s.len == 0 or std.mem.eql(u8, s, "{}")) return; // static fallback
        alloc.free(s);
    }
}

export fn suji_sqlite_backend_destroy() callconv(.c) void {
    reg.mutex.lockUncancelable(bio());
    defer reg.mutex.unlock(bio());
    var it = reg.map.valueIterator();
    while (it.next()) |db| _ = c.sqlite3_close_v2(db.*);
    reg.map.clearAndFree();
}
