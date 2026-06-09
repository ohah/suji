//! @suji/plugin-positioner — 창을 화면/트레이/커서 기준 위치로 배치 (Tauri positioner 동등).
//!
//! 새 네이티브 0 — 코어 screen.getAllDisplays / windows.getBounds+setBounds /
//! tray.getBounds / screen.getCursorScreenPoint 조합.
//!
//! 채널:
//!   positioner:move {position, windowId?, trayId?} → {ok:true, x, y}
//!
//! position:
//!   화면 상대(work area 내): center, top-left, top-right, bottom-left, bottom-right,
//!                            top-center, bottom-center, left-center, right-center
//!   커서: at-cursor (창 좌상단을 커서 위치에, work area 로 clamp)
//!   트레이(trayId 필요): tray-center (트레이 아이콘 아래 가로 중앙)
//!
//! ⚠️ 좌표계: 코어 screen 의 Display/cursor/tray rect 는 macOS NSScreen **bottom-up**,
//!   창 bounds 는 CEF **top-left**. macOS 는 primary 높이로 y-flip(top-left 전환),
//!   Win/Linux 는 이미 top-left 라 flip 없음. multi-display 는 primary 높이 기준 전역
//!   변환이라 정확. tray/cursor 는 macOS 한정(tray.getBounds Win/Linux 0 rect).

const std = @import("std");
const suji = @import("suji");
const util = @import("util");

pub const app = suji.app()
    .named("positioner")
    .handle("positioner:move", positionerMove);

// ============================================
// 헬퍼
// ============================================

/// 코어 응답을 arena 로 복사 — 코어 호출은 threadlocal scratch 를 공유하므로 다음
/// 호출 전에 owned 복사 필수(clobber 방지).
fn dupeCore(arena: std.mem.Allocator, resp: ?[]const u8) ?[]const u8 {
    const r = resp orelse return null;
    return arena.dupe(u8, r) catch null;
}

/// windowId 명시 우선, 없으면 호출 창. cast 실패 시 0(패닉 방지) — window-state 동형.
fn resolveWindowId(req: suji.Request, ev: suji.InvokeEvent) u32 {
    if (req.int("windowId")) |wid| {
        if (wid <= 0) return 0;
        return std.math.cast(u32, wid) orelse 0;
    }
    return ev.window.id;
}

/// displays 배열에서 top-level `{...}` 객체를 순회. display JSON 값은 전부 number/bool
/// (문자열 값 없음) 이라 단순 brace-depth 로 안전.
fn nextObject(arr: []const u8, idx: *usize) ?[]const u8 {
    var i = idx.*;
    while (i < arr.len and arr[i] != '{') i += 1;
    if (i >= arr.len) return null;
    const start = i;
    var depth: i32 = 0;
    while (i < arr.len) : (i += 1) {
        if (arr[i] == '{') {
            depth += 1;
        } else if (arr[i] == '}') {
            depth -= 1;
            if (depth == 0) {
                idx.* = i + 1;
                return arr[start .. i + 1];
            }
        }
    }
    return null;
}

const WorkArea = struct { x: i64, y: i64, w: i64, h: i64 };

/// bottom-up y(높이 h 인 rect)를 top-left 로. macOS 만 flip, 그 외 그대로.
/// 전역 primary 높이 기준 변환(macOS/Chromium 관례: 전역 원점=primary 좌하단)이라
/// 모든 display 에 단일 primary_h 로 정확.
/// NOTE(altitude): 좌표 변환이 코어 screen API 가 아닌 플러그인에 있다 — 코어가 raw
/// bottom-up 만 노출(cef_screen "caller 가 필요 시 변환")하기 때문. 두 번째 지오메트리
/// 플러그인이 생기면 코어 screen 에 top-left/work-area 헬퍼를 추가해 단일 출처로 옮길 것.
fn toTopLeftY(bu_y: i64, h: i64, primary_h: i64, is_macos: bool) i64 {
    return if (is_macos) primary_h - (bu_y + h) else bu_y;
}

/// primary 프레임 높이(전역 bottom-up→top-left flip 기준). primary 부재 시 첫 display.
fn getPrimaryHeight(dj: []const u8) i64 {
    const arr = util.extractJsonArrayRaw(dj, "displays") orelse return 0;
    var primary_h: i64 = 0;
    var first_h: i64 = 0;
    var got_first = false;
    var idx: usize = 0;
    while (nextObject(arr, &idx)) |obj| {
        const fh = util.extractJsonInt(obj, "height") orelse continue;
        if (!got_first) {
            first_h = fh;
            got_first = true;
        }
        if (util.extractJsonBool(obj, "isPrimary") orelse false) primary_h = fh;
    }
    return if (primary_h != 0) primary_h else first_h;
}

/// (px, py) top-left 점을 포함하는 display 의 work area(top-left)를 해석.
/// 우선순위: 포함 display > primary > 첫 display. 못 찾으면 false.
/// ⚠️ 점(px,py)은 **배치 대상** 기준 — screen 위치는 창 중심, at-cursor 는 커서,
///    tray 는 트레이 중심을 넘겨 "그 점이 있는 디스플레이"의 work area 로 clamp 한다.
fn selectWorkArea(dj: []const u8, px: i64, py: i64, primary_h: i64, is_macos: bool, out: *WorkArea) bool {
    const arr = util.extractJsonArrayRaw(dj, "displays") orelse return false;
    var best_rank: i32 = 0;
    var idx: usize = 0;
    while (nextObject(arr, &idx)) |obj| {
        const fx = util.extractJsonInt(obj, "x") orelse continue;
        const fy = util.extractJsonInt(obj, "y") orelse continue;
        const fw = util.extractJsonInt(obj, "width") orelse continue;
        const fh = util.extractJsonInt(obj, "height") orelse continue;
        const vx = util.extractJsonInt(obj, "visibleX") orelse continue;
        const vy = util.extractJsonInt(obj, "visibleY") orelse continue;
        const vw = util.extractJsonInt(obj, "visibleWidth") orelse continue;
        const vh = util.extractJsonInt(obj, "visibleHeight") orelse continue;
        const is_primary = util.extractJsonBool(obj, "isPrimary") orelse false;

        const ftl_y = toTopLeftY(fy, fh, primary_h, is_macos);
        const contains = px >= fx and px < fx + fw and py >= ftl_y and py < ftl_y + fh;

        var rank: i32 = 1;
        if (is_primary) rank = 2;
        if (contains) rank = 3;
        if (rank > best_rank) {
            out.* = .{ .x = vx, .y = toTopLeftY(vy, vh, primary_h, is_macos), .w = vw, .h = vh };
            best_rank = rank;
        }
    }
    return best_rank > 0;
}

fn clampI64(v: i64, lo: i64, hi: i64) i64 {
    if (hi < lo) return lo; // 창이 work area 보다 큰 경우 — 좌상단 우선.
    return std.math.clamp(v, lo, hi);
}

/// 화면 상대 position → 창 좌상단 (tx, ty). 알 수 없는 position 이면 false.
/// 각 position 은 x∈{left,center,right} × y∈{top,middle,bottom} 의 조합 → 테이블 dispatch.
fn screenPosition(pos: []const u8, wa: WorkArea, win_w: i64, win_h: i64, tx: *i64, ty: *i64) bool {
    const xs = [3]i64{ wa.x, wa.x + @divTrunc(wa.w - win_w, 2), wa.x + wa.w - win_w }; // left, center, right
    const ys = [3]i64{ wa.y, wa.y + @divTrunc(wa.h - win_h, 2), wa.y + wa.h - win_h }; // top, middle, bottom
    const Entry = struct { name: []const u8, xi: usize, yi: usize };
    const table = [_]Entry{
        .{ .name = "center", .xi = 1, .yi = 1 },
        .{ .name = "top-left", .xi = 0, .yi = 0 },
        .{ .name = "top-right", .xi = 2, .yi = 0 },
        .{ .name = "bottom-left", .xi = 0, .yi = 2 },
        .{ .name = "bottom-right", .xi = 2, .yi = 2 },
        .{ .name = "top-center", .xi = 1, .yi = 0 },
        .{ .name = "bottom-center", .xi = 1, .yi = 2 },
        .{ .name = "left-center", .xi = 0, .yi = 1 },
        .{ .name = "right-center", .xi = 2, .yi = 1 },
    };
    for (table) |e| {
        if (std.mem.eql(u8, pos, e.name)) {
            tx.* = xs[e.xi];
            ty.* = ys[e.yi];
            return true;
        }
    }
    return false;
}

// ============================================
// 핸들러
// ============================================

fn positionerMove(req: suji.Request, ev: suji.InvokeEvent) suji.Response {
    const id = resolveWindowId(req, ev);
    if (id == 0) return req.err("no window");
    const pos = req.string("position") orelse return req.err("missing position");

    const wb = dupeCore(req.arena, suji.windows.getBounds(id)) orelse return req.err("get_bounds failed");
    if (!(util.extractJsonBool(wb, "ok") orelse false)) return req.err("get_bounds not ok");
    const win_x = util.extractJsonInt(wb, "x") orelse return req.err("bad bounds");
    const win_y = util.extractJsonInt(wb, "y") orelse return req.err("bad bounds");
    const win_w = util.extractJsonInt(wb, "width") orelse return req.err("bad bounds");
    const win_h = util.extractJsonInt(wb, "height") orelse return req.err("bad bounds");

    const is_macos = std.mem.eql(u8, suji.platform(), "macos");

    const dj = dupeCore(req.arena, suji.screen.getAllDisplays()) orelse return req.err("get_displays failed");
    const primary_h = getPrimaryHeight(dj);

    // 배치 대상 좌표(tx,ty)와 work-area 선택 기준점(anchor)을 position 종류별로 계산.
    // ⚠️ 좌표계: displays/cursor 는 코어가 bottom-up 으로 반환(→ flip), tray 는 코어가
    //   이미 top-left 로 변환(cef_tray) 하므로 **flip 하지 않는다**(비대칭 주의).
    var tx: i64 = 0;
    var ty: i64 = 0;
    var anchor_x: i64 = win_x + @divTrunc(win_w, 2);
    var anchor_y: i64 = win_y + @divTrunc(win_h, 2);
    var is_screen_pos = false;
    if (std.mem.eql(u8, pos, "at-cursor")) {
        const cj = dupeCore(req.arena, suji.screen.getCursorScreenPoint()) orelse return req.err("cursor failed");
        const cx = util.extractJsonInt(cj, "x") orelse return req.err("bad cursor");
        const cy = util.extractJsonInt(cj, "y") orelse return req.err("bad cursor");
        tx = cx;
        ty = if (is_macos) primary_h - cy else cy; // 커서는 bottom-up point → 단순 반전.
        anchor_x = tx; // 커서가 있는 디스플레이의 work area 로 clamp.
        anchor_y = ty;
    } else if (std.mem.eql(u8, pos, "tray-center")) {
        const tray_id = req.int("trayId") orelse return req.err("missing trayId");
        if (tray_id < 0) return req.err("bad trayId");
        const tj = dupeCore(req.arena, suji.tray.getBounds(std.math.cast(u32, tray_id) orelse return req.err("bad trayId"))) orelse return req.err("tray failed");
        const trx = util.extractJsonInt(tj, "x") orelse return req.err("bad tray");
        const trycoord = util.extractJsonInt(tj, "y") orelse return req.err("bad tray");
        const trw = util.extractJsonInt(tj, "width") orelse return req.err("bad tray");
        const trh = util.extractJsonInt(tj, "height") orelse return req.err("bad tray");
        if (trw == 0 and trh == 0) return req.err("tray bounds unavailable"); // Win/Linux 0-rect 등.
        // tray.getBounds 는 이미 top-left(cef_tray 변환) — flip 금지. 아이콘 바로 아래, 가로 중앙.
        tx = trx + @divTrunc(trw - win_w, 2);
        ty = trycoord + trh;
        anchor_x = trx + @divTrunc(trw, 2); // 트레이가 있는 디스플레이의 work area 로 clamp.
        anchor_y = trycoord;
    } else {
        is_screen_pos = true; // 화면 위치는 work area 가 필요 — 아래에서 계산.
    }

    var wa: WorkArea = undefined;
    if (!selectWorkArea(dj, anchor_x, anchor_y, primary_h, is_macos, &wa)) return req.err("no display");

    if (is_screen_pos) {
        if (!screenPosition(pos, wa, win_w, win_h, &tx, &ty)) return req.err("unknown position");
    }

    // work area 안으로 clamp (창이 화면 밖으로 나가지 않도록).
    tx = clampI64(tx, wa.x, wa.x + wa.w - win_w);
    ty = clampI64(ty, wa.y, wa.y + wa.h - win_h);

    const xi = std.math.cast(i32, tx) orelse return req.err("coord overflow");
    const yi = std.math.cast(i32, ty) orelse return req.err("coord overflow");
    const wi = std.math.cast(u32, win_w) orelse return req.err("coord overflow");
    const hi = std.math.cast(u32, win_h) orelse return req.err("coord overflow");
    _ = suji.windows.setBounds(id, .{ .x = xi, .y = yi, .width = wi, .height = hi });

    const body = std.fmt.allocPrint(req.arena, "{{\"ok\":true,\"x\":{d},\"y\":{d}}}", .{ tx, ty }) catch return req.err("alloc");
    return req.okRaw(body);
}

comptime {
    _ = suji.exportApp(app);
}
