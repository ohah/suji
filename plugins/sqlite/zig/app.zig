const std = @import("std");
const builtin = @import("builtin");
const suji = @import("suji");

const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const app = suji.app()
    .named("sqlite")
    .handle("sql:open", sqlOpen)
    .handle("sql:execute", sqlExecute)
    .handle("sql:query", sqlQuery)
    .handle("sql:close", sqlClose);

// ============================================
// 연결 레지스트리 (dbId → *sqlite3, 글로벌 뮤텍스)
// ============================================
// better-sqlite3 처럼 동기·직렬화 모델. SQLITE_THREADSAFE=1 + 단일 플러그인
// 뮤텍스로 open/execute/query/close 전부 직렬화 — 멀티-DB 동시성은 없지만
// 임베디드 로컬 DB use-case 엔 충분(상태 플러그인 단일 뮤텍스와 동형).

var gpa: std.heap.DebugAllocator(.{}) = .init;
const alloc = gpa.allocator();

fn pluginIo() std.Io {
    return suji.io();
}

const Registry = struct {
    map: std.AutoHashMap(u32, *c.sqlite3) = std.AutoHashMap(u32, *c.sqlite3).init(alloc),
    mutex: std.Io.Mutex = .init,
    next_id: u32 = 1,
};
var reg: Registry = .{};

// ============================================
// JSON 직렬화 (응답 빌드)
// ============================================
// util.escapeJsonStrFull 과 정책 동일하나 그건 고정버퍼(dst:[]u8) API —
// 여기선 임의 길이 컬럼을 ArrayList 로 스트리밍해야 해 직접 구현(state
// 플러그인의 최소-의존 관례 유지). util 에 streaming escaper 가 생기면 통합 후보.

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

// ============================================
// 경로 해소 — ":memory:" | 절대경로 | app-data 상대경로
// ============================================

fn cGetenv(name: [*:0]const u8) ?[]const u8 {
    const raw = std.c.getenv(name) orelse return null;
    return std.mem.span(raw);
}

/// 상대경로 base 디렉토리 (OS 표준 app-data 하위 `suji-app/sqlite`).
fn dbBaseDir(a: std.mem.Allocator) ?[]const u8 {
    if (builtin.os.tag == .macos) {
        const home = cGetenv("HOME") orelse return null;
        return std.fmt.allocPrint(a, "{s}/Library/Application Support/suji-app/sqlite", .{home}) catch null;
    } else if (builtin.os.tag == .linux) {
        if (cGetenv("XDG_DATA_HOME")) |dir|
            return std.fmt.allocPrint(a, "{s}/suji-app/sqlite", .{dir}) catch null;
        const home = cGetenv("HOME") orelse return null;
        return std.fmt.allocPrint(a, "{s}/.local/share/suji-app/sqlite", .{home}) catch null;
    } else if (builtin.os.tag == .windows) {
        const appdata = cGetenv("APPDATA") orelse return null;
        return std.fmt.allocPrint(a, "{s}\\suji-app\\sqlite", .{appdata}) catch null;
    }
    return null;
}

fn hasDotDot(path: []const u8) bool {
    var it = std.mem.splitAny(u8, path, "/\\");
    while (it.next()) |seg| if (std.mem.eql(u8, seg, "..")) return true;
    return false;
}

/// req path → null-terminated open 경로. 실패 시 null.
fn resolveDbPath(a: std.mem.Allocator, path: []const u8) ?[:0]const u8 {
    if (path.len == 0) return null;
    if (std.mem.eql(u8, path, ":memory:"))
        return a.dupeZ(u8, ":memory:") catch null;
    const is_abs = path[0] == '/' or (path.len > 2 and path[1] == ':'); // POSIX or Win drive
    if (is_abs) return a.dupeZ(u8, path) catch null;
    // 상대경로 — app-data 하위. `..` traversal 차단(샌드박스 경계).
    if (hasDotDot(path)) return null;
    const base = dbBaseDir(a) orelse return null;
    std.Io.Dir.cwd().createDirPath(pluginIo(), base) catch return null;
    const full = std.fmt.allocPrint(a, "{s}/{s}", .{ base, path }) catch return null;
    return a.dupeZ(u8, full) catch null;
}

// ============================================
// 파라미터 바인딩 (positional `?` — SQL injection 차단)
// ============================================

/// params 배열을 prepared stmt 에 1-base 바인딩.
/// ⚠️ SQLITE_STATIC — sqlite 가 텍스트/blob 을 복사하지 않음. 이스케이프가
/// 있는 JSON 문자열은 std.json Parsed 아레나에 복사되므로(이스케이프 없으면
/// req.raw 별칭) Parsed 는 step/finalize 까지 살아있어야 함. caller(handler)
/// 가 `defer parsed.deinit()` 를 `defer finalize(stmt)` *보다 먼저* 선언해
/// LIFO 로 finalize→deinit 순서를 보장한다. 두 defer 순서 변경 금지.
fn bindParams(stmt: *c.sqlite3_stmt, params: []const std.json.Value) c_int {
    for (params, 0..) |p, i| {
        const idx: c_int = @intCast(i + 1);
        const rc: c_int = switch (p) {
            .null => c.sqlite3_bind_null(stmt, idx),
            .bool => |b| c.sqlite3_bind_int(stmt, idx, if (b) 1 else 0),
            .integer => |n| c.sqlite3_bind_int64(stmt, idx, n),
            .float => |f| c.sqlite3_bind_double(stmt, idx, f),
            .number_string => |s| c.sqlite3_bind_text(stmt, idx, s.ptr, @intCast(s.len), c.SQLITE_STATIC),
            .string => |s| c.sqlite3_bind_text(stmt, idx, s.ptr, @intCast(s.len), c.SQLITE_STATIC),
            else => c.SQLITE_MISMATCH, // array/object 는 스칼라 파라미터 불가
        };
        if (rc != c.SQLITE_OK) return rc;
    }
    return c.SQLITE_OK;
}

/// req.raw 의 "params" 배열 파싱. 없으면 빈 슬라이스. 파싱 실패는 error.
fn parseParams(a: std.mem.Allocator, raw: []const u8) !std.json.Parsed([]std.json.Value) {
    const arr = suji.extractJsonValue(raw, "params") orelse "[]";
    return std.json.parseFromSlice([]std.json.Value, a, arr, .{});
}

/// prepare 후 남은 tail 에 공백/세미콜론 외 토큰이 있으면 true (= 추가 문 존재).
fn hasTrailingStatement(tail: [*c]const u8, end: [*]const u8) bool {
    var p: [*]const u8 = @ptrCast(tail);
    while (@intFromPtr(p) < @intFromPtr(end)) : (p += 1) {
        const ch = p[0];
        if (ch != ' ' and ch != '\t' and ch != '\n' and ch != '\r' and ch != ';') return true;
    }
    return false;
}

// ============================================
// 핸들러
// ============================================

fn dbErr(req: suji.Request, db: *c.sqlite3) suji.Response {
    const msg = c.sqlite3_errmsg(db);
    return req.err(if (msg != null) std.mem.span(msg) else "sqlite error");
}

fn sqlOpen(req: suji.Request, _: suji.InvokeEvent) suji.Response {
    const path = req.string("path") orelse return req.err("missing path");
    const cpath = resolveDbPath(req.arena, path) orelse return req.err("invalid path");

    var db: ?*c.sqlite3 = null;
    const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE;
    const rc = c.sqlite3_open_v2(cpath.ptr, &db, flags, null);
    if (rc != c.SQLITE_OK or db == null) {
        if (db) |d| _ = c.sqlite3_close_v2(d);
        return req.err("open failed");
    }

    reg.mutex.lockUncancelable(pluginIo());
    defer reg.mutex.unlock(pluginIo());
    const id = reg.next_id;
    reg.map.put(id, db.?) catch {
        _ = c.sqlite3_close_v2(db.?);
        return req.err("registry full");
    };
    reg.next_id += 1;
    return req.okRaw(std.fmt.allocPrint(req.arena, "{{\"dbId\":{d}}}", .{id}) catch return req.err("format error"));
}

/// req "dbId" → 유효 u32 키. 누락/범위밖이면 null.
fn dbIdKey(req: suji.Request) ?u32 {
    const id = req.int("dbId") orelse return null;
    if (id <= 0 or id > std.math.maxInt(u32)) return null;
    return @intCast(id);
}

fn lookupDb(req: suji.Request) ?*c.sqlite3 {
    return reg.map.get(dbIdKey(req) orelse return null);
}

fn sqlExecute(req: suji.Request, _: suji.InvokeEvent) suji.Response {
    reg.mutex.lockUncancelable(pluginIo());
    defer reg.mutex.unlock(pluginIo());

    const db = lookupDb(req) orelse return req.err("invalid dbId");
    const sql = req.string("sql") orelse return req.err("missing sql");
    if (sql.len == 0) return req.err("empty sql");

    // parsed.deinit() 는 핸들러 스코프 defer — 모든 stmt 는 반환 전 inline
    // finalize 되므로 STATIC 바인딩이 가리키는 parsed 아레나가 항상 더 오래 산다.
    var parsed = parseParams(req.arena, req.raw) catch return req.err("invalid params");
    defer parsed.deinit();
    const params = parsed.value;

    const end: [*]const u8 = sql.ptr + sql.len;
    if (params.len > 0) {
        // 파라미터 있음 → 단일문만. 멀티문은 어느 문에 바인딩할지 모호 →
        // 바인딩 전에 선제 거부(placeholder 없는 첫 문 RANGE 에러보다 명확).
        var stmt: ?*c.sqlite3_stmt = null;
        var tail: [*c]const u8 = null;
        if (c.sqlite3_prepare_v2(db, sql.ptr, @intCast(sql.len), &stmt, &tail) != c.SQLITE_OK)
            return dbErr(req, db);
        const s = stmt orelse return req.err("empty statement");
        defer _ = c.sqlite3_finalize(s);
        if (hasTrailingStatement(tail, end))
            return req.err("params not allowed with multi-statement sql");
        if (bindParams(s, params) != c.SQLITE_OK) return dbErr(req, db);
        const rc = c.sqlite3_step(s);
        if (rc != c.SQLITE_DONE and rc != c.SQLITE_ROW) return dbErr(req, db);
    } else {
        // 파라미터 없음 → 멀티문 스크립트(스키마 마이그레이션 등) 순차 실행.
        var cursor: [*]const u8 = sql.ptr;
        while (@intFromPtr(cursor) < @intFromPtr(end)) {
            var tail: [*c]const u8 = null;
            var stmt: ?*c.sqlite3_stmt = null;
            const remaining: c_int = @intCast(@intFromPtr(end) - @intFromPtr(cursor));
            if (c.sqlite3_prepare_v2(db, cursor, remaining, &stmt, &tail) != c.SQLITE_OK)
                return dbErr(req, db);
            const next: [*]const u8 = @ptrCast(tail);
            if (stmt) |s| {
                const rc = c.sqlite3_step(s);
                _ = c.sqlite3_finalize(s);
                if (rc != c.SQLITE_DONE and rc != c.SQLITE_ROW) return dbErr(req, db);
            }
            if (@intFromPtr(next) <= @intFromPtr(cursor)) break; // 진행 없음 가드
            cursor = next;
        }
    }

    const changes = c.sqlite3_changes(db);
    const last_id = c.sqlite3_last_insert_rowid(db);
    return req.okRaw(std.fmt.allocPrint(
        req.arena,
        "{{\"changes\":{d},\"lastInsertRowid\":{d}}}",
        .{ changes, last_id },
    ) catch return req.err("format error"));
}

fn sqlQuery(req: suji.Request, _: suji.InvokeEvent) suji.Response {
    reg.mutex.lockUncancelable(pluginIo());
    defer reg.mutex.unlock(pluginIo());

    const db = lookupDb(req) orelse return req.err("invalid dbId");
    const sql = req.string("sql") orelse return req.err("missing sql");
    if (sql.len == 0) return req.err("empty sql");

    var parsed = parseParams(req.arena, req.raw) catch return req.err("invalid params");
    defer parsed.deinit();

    var stmt: ?*c.sqlite3_stmt = null;
    var tail: [*c]const u8 = null;
    if (c.sqlite3_prepare_v2(db, sql.ptr, @intCast(sql.len), &stmt, &tail) != c.SQLITE_OK)
        return dbErr(req, db);
    const s = stmt orelse return req.err("empty statement");
    defer _ = c.sqlite3_finalize(s);

    // query 는 단일문만 — 남은 tail 에 추가 문이 있으면 조용히 버리지 않고
    // 명시적 에러(멀티문은 sql:execute 사용).
    if (hasTrailingStatement(tail, sql.ptr + sql.len))
        return req.err("multi-statement not supported in query — use execute");

    if (bindParams(s, parsed.value) != c.SQLITE_OK) return dbErr(req, db);

    const a = req.arena;
    var out = std.ArrayList(u8).empty;
    out.ensureTotalCapacity(a, 256) catch return req.err("alloc error");
    out.appendSlice(a, "{\"rows\":[") catch return req.err("alloc error");

    const ncol = c.sqlite3_column_count(s);

    // 컬럼명은 stmt 메타데이터 고정 — 행마다 재조회/strlen 하지 않고 1회 캐시.
    const names = a.alloc([]const u8, @intCast(@max(ncol, 0))) catch return req.err("alloc error");
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
        if (rc != c.SQLITE_ROW) return dbErr(req, db);

        if (row_n > 0) out.append(a, ',') catch return req.err("alloc error");
        out.append(a, '{') catch return req.err("alloc error");
        var col: c_int = 0;
        while (col < ncol) : (col += 1) {
            if (col > 0) out.append(a, ',') catch return req.err("alloc error");
            appendJsonString(&out, a, names[@intCast(col)]) catch return req.err("alloc error");
            out.append(a, ':') catch return req.err("alloc error");
            appendColumn(&out, a, s, col) catch return req.err("alloc error");
        }
        out.append(a, '}') catch return req.err("alloc error");
        row_n += 1;
    }
    out.appendSlice(a, "]}") catch return req.err("alloc error");
    return req.okRaw(out.items);
}

/// 컬럼 값 → JSON. BLOB 은 base64 문자열(데이터 손실 없는 JSON 표현).
fn appendColumn(out: *std.ArrayList(u8), a: std.mem.Allocator, s: *c.sqlite3_stmt, col: c_int) !void {
    switch (c.sqlite3_column_type(s, col)) {
        c.SQLITE_NULL => try out.appendSlice(a, "null"),
        c.SQLITE_INTEGER => try out.print(a, "{d}", .{c.sqlite3_column_int64(s, col)}),
        c.SQLITE_FLOAT => {
            const f = c.sqlite3_column_double(s, col);
            // NaN/±Inf 는 유효 JSON 이 아님 → null (모든 SDK JSON.parse 보호).
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

fn sqlClose(req: suji.Request, _: suji.InvokeEvent) suji.Response {
    reg.mutex.lockUncancelable(pluginIo());
    defer reg.mutex.unlock(pluginIo());

    const key = dbIdKey(req) orelse return req.err("invalid dbId");
    const kv = reg.map.fetchRemove(key) orelse return req.err("invalid dbId");
    _ = c.sqlite3_close_v2(kv.value);
    return req.okRaw("{\"ok\":true}");
}

comptime {
    _ = suji.exportApp(app);
}
