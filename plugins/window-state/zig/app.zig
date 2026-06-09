//! @suji/plugin-window-state — 창 위치/크기/최대화 상태 저장·복원 (Electron/Tauri window-state 동등).
//!
//! 새 네이티브 0 — 코어 백엔드 windows SDK(getBounds/isMaximized/setBounds/maximize)
//! 조합 + 파일 영속. store 플러그인의 atomic-write 패턴 재사용(per-key 단일 파일).
//!
//! 채널:
//!   window-state:save    {key?, windowId?}  → {ok:true}
//!     호출 창(또는 windowId)의 bounds+maximized 를 <appdata>/suji-app/window-state/<key>.json 에 저장.
//!   window-state:restore {key?, windowId?}  → {ok:true, restored:bool}
//!     저장된 state 를 창에 적용(maximized 면 maximize, 아니면 setBounds). 없으면 restored:false.
//!   window-state:get     {key?}             → {state: {x,y,width,height,maximized}|null}
//!   window-state:clear   {key?}             → {ok:true}
//!
//! key 기본값: 호출 창 name(있으면) 또는 "main". 멀티 윈도우는 key 로 구분.
//! 정직 경계: 코어에 window move/resize 이벤트가 없어 자동 추적은 불가 — save 를 명시
//!   호출(app:before-quit/window:close 시점)해야 한다(Tauri 도 디바운스 차이뿐). Node
//!   백엔드는 창 컨텍스트가 없으므로 windowId 명시 필요(없으면 "no window" 에러).

const std = @import("std");
const builtin = @import("builtin");
const suji = @import("suji");
const util = @import("util");

pub const app = suji.app()
    .named("window-state")
    .handle("window-state:save", wsSave)
    .handle("window-state:restore", wsRestore)
    .handle("window-state:get", wsGet)
    .handle("window-state:clear", wsClear);

var gpa: std.heap.DebugAllocator(.{}) = .init;
const alloc = gpa.allocator();

const MAX_FILE_BYTES: usize = 64 * 1024; // state JSON 은 작음 — 64KB cap
const MAX_KEY_LEN: usize = 64;

fn pluginIo() std.Io {
    return suji.io();
}

// 코어 windows API 응답 파싱은 util.extractJsonInt/extractJsonBool(코어와 동일
// 캐노니컬 추출기)을 직접 사용 — 부재 bool 은 `orelse false` 로 처리.

// ============================================
// key 검증 + 파일 경로 (store 플러그인 패턴)
// ============================================

/// key 문자 화이트리스트 — path traversal 방지(store 와 동일 가드).
fn validKey(key: []const u8) bool {
    if (key.len == 0 or key.len > MAX_KEY_LEN) return false;
    if (std.mem.eql(u8, key, ".") or std.mem.eql(u8, key, "..")) return false;
    for (key) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.') return false;
    }
    return true;
}

fn cGetenv(name: [*:0]const u8) ?[]const u8 {
    const raw = std.c.getenv(name) orelse return null;
    return std.mem.span(raw);
}

/// <appdata>/suji-app/window-state/<key>.json (store makePath 와 동형 디렉토리 트리).
fn makePath(key: []const u8) ?[]const u8 {
    if (builtin.os.tag == .macos) {
        const home = cGetenv("HOME") orelse return null;
        return std.fmt.allocPrint(alloc, "{s}/Library/Application Support/suji-app/window-state/{s}.json", .{ home, key }) catch null;
    } else if (builtin.os.tag == .linux) {
        if (cGetenv("XDG_DATA_HOME")) |dir| {
            return std.fmt.allocPrint(alloc, "{s}/suji-app/window-state/{s}.json", .{ dir, key }) catch null;
        }
        const home = cGetenv("HOME") orelse return null;
        return std.fmt.allocPrint(alloc, "{s}/.local/share/suji-app/window-state/{s}.json", .{ home, key }) catch null;
    } else if (builtin.os.tag == .windows) {
        const appdata = cGetenv("APPDATA") orelse return null;
        return std.fmt.allocPrint(alloc, "{s}\\suji-app\\window-state\\{s}.json", .{ appdata, key }) catch null;
    }
    return null;
}

/// state JSON 을 path 에 atomic write(.tmp → rename). store.persistUnlocked 동형.
fn writeStateFile(path: []const u8, content: []const u8) bool {
    const io = pluginIo();
    if (std.mem.lastIndexOfAny(u8, path, "/\\")) |sep| {
        std.Io.Dir.cwd().createDirPath(io, path[0..sep]) catch {};
    }
    const tmp_path = std.fmt.allocPrint(alloc, "{s}.tmp", .{path}) catch return false;
    defer alloc.free(tmp_path);
    var file = std.Io.Dir.cwd().createFile(io, tmp_path, .{}) catch return false;
    file.writePositionalAll(io, content, 0) catch {
        file.close(io);
        std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
        return false;
    };
    file.close(io);
    // Windows rename 은 dst 존재 시 fail → 미리 delete (store 와 동일 trade-off).
    if (builtin.os.tag == .windows) {
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
    }
    std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), path, io) catch {
        std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
        return false;
    };
    return true;
}

/// path 의 state JSON 을 arena 로 읽음. 없으면 null.
fn readStateFile(path: []const u8, arena: std.mem.Allocator) ?[]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(pluginIo(), path, arena, .limited(MAX_FILE_BYTES)) catch null;
}

// ============================================
// 공통: windowId/key 해석
// ============================================

/// windowId 명시 우선, 없으면 호출 창(InvokeEvent). 0 이면 창 컨텍스트 없음.
/// caller-supplied wid 는 u32 범위 밖일 수 있으므로 cast 실패 시 0(패닉 방지).
fn resolveWindowId(req: suji.Request, ev: suji.InvokeEvent) u32 {
    if (req.int("windowId")) |wid| {
        if (wid <= 0) return 0;
        return std.math.cast(u32, wid) orelse 0;
    }
    return ev.window.id;
}

/// key 해석:
///   - 명시 key: 검증 실패 시 null(에러) — 사용자가 잘못 준 것이므로 알린다.
///   - 자동 파생(창 name → "main"): name 이 validKey 를 통과 못 하면(공백/슬래시 등
///     창 name 은 허용되지만 파일명엔 부적합) "main" 으로 graceful fallback(에러 X).
fn resolveKey(req: suji.Request, ev: suji.InvokeEvent) ?[]const u8 {
    if (req.string("key")) |k| {
        return if (validKey(k)) k else null;
    }
    const derived = ev.window.name orelse "main";
    return if (validKey(derived)) derived else "main";
}

// ============================================
// 핸들러
// ============================================

fn wsSave(req: suji.Request, ev: suji.InvokeEvent) suji.Response {
    const id = resolveWindowId(req, ev);
    if (id == 0) return req.err("no window");
    const key = resolveKey(req, ev) orelse return req.err("invalid key");

    // ⚠️ getBounds/isMaximized 응답은 동일 threadlocal scratch 를 공유 →
    // 두 번째 호출 전에 첫 응답을 i64 로 복사 완료해야 한다(순서 의존).
    const bounds = suji.windows.getBounds(id) orelse return req.err("get_bounds failed");
    if (!(util.extractJsonBool(bounds, "ok") orelse false)) return req.err("get_bounds not ok");
    const x = util.extractJsonInt(bounds, "x") orelse return req.err("bad bounds");
    const y = util.extractJsonInt(bounds, "y") orelse return req.err("bad bounds");
    const w = util.extractJsonInt(bounds, "width") orelse return req.err("bad bounds");
    const h = util.extractJsonInt(bounds, "height") orelse return req.err("bad bounds");

    const max_resp = suji.windows.isMaximized(id);
    const maximized = if (max_resp) |mr| (util.extractJsonBool(mr, "maximized") orelse false) else false;

    const state = std.fmt.allocPrint(
        req.arena,
        "{{\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d},\"maximized\":{}}}",
        .{ x, y, w, h, maximized },
    ) catch return req.err("alloc");

    const path = makePath(key) orelse return req.err("path");
    defer alloc.free(path);
    if (!writeStateFile(path, state)) return req.err("write failed");
    return req.okRaw("{\"ok\":true}");
}

fn wsRestore(req: suji.Request, ev: suji.InvokeEvent) suji.Response {
    const id = resolveWindowId(req, ev);
    if (id == 0) return req.err("no window");
    const key = resolveKey(req, ev) orelse return req.err("invalid key");

    const path = makePath(key) orelse return req.err("path");
    defer alloc.free(path);
    const state = readStateFile(path, req.arena) orelse return req.okRaw("{\"ok\":true,\"restored\":false}");

    // 저장값은 사용자가 수정 가능한 디스크 파일 → 범위 밖 정수는 std.math.cast 로
    // 에러 처리(@intCast 패닉 방지).
    const x = util.extractJsonInt(state, "x") orelse return req.err("corrupt state");
    const y = util.extractJsonInt(state, "y") orelse return req.err("corrupt state");
    const w = util.extractJsonInt(state, "width") orelse return req.err("corrupt state");
    const h = util.extractJsonInt(state, "height") orelse return req.err("corrupt state");
    const xi = std.math.cast(i32, x) orelse return req.err("corrupt state");
    const yi = std.math.cast(i32, y) orelse return req.err("corrupt state");
    const wi = std.math.cast(u32, w) orelse return req.err("corrupt state");
    const hi = std.math.cast(u32, h) orelse return req.err("corrupt state");

    // 항상 bounds 를 먼저 적용한 뒤(maximized 여도 — unmaximize 시 복귀할 bounds 보존),
    // maximized 면 maximize. (정직 경계: 코어에 getNormalBounds 가 없어 maximized 창의
    // 저장 bounds 는 최대화 bounds 자체 — 저장 시점 pre-maximize bounds 는 캡처 불가.)
    _ = suji.windows.setBounds(id, .{ .x = xi, .y = yi, .width = wi, .height = hi });
    if (util.extractJsonBool(state, "maximized") orelse false) {
        _ = suji.windows.maximize(id);
    }
    return req.okRaw("{\"ok\":true,\"restored\":true}");
}

fn wsGet(req: suji.Request, ev: suji.InvokeEvent) suji.Response {
    const key = resolveKey(req, ev) orelse return req.err("invalid key");
    const path = makePath(key) orelse return req.err("path");
    defer alloc.free(path);
    const state = readStateFile(path, req.arena) orelse return req.okRaw("{\"state\":null}");
    const body = std.fmt.allocPrint(req.arena, "{{\"state\":{s}}}", .{state}) catch return req.err("alloc");
    return req.okRaw(body);
}

fn wsClear(req: suji.Request, ev: suji.InvokeEvent) suji.Response {
    const key = resolveKey(req, ev) orelse return req.err("invalid key");
    const path = makePath(key) orelse return req.err("path");
    defer alloc.free(path);
    std.Io.Dir.cwd().deleteFile(pluginIo(), path) catch {};
    return req.okRaw("{\"ok\":true}");
}

comptime {
    _ = suji.exportApp(app);
}
