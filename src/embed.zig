//! Suji 코어 C ABI — CEF 무관 임베드 라이브러리 표면.
//!
//! 호스트(CEF 데스크톱 셸 / iOS·Android 호스트 앱 / 헤드리스 테스트)가 코어를
//! 구동하는 진입점. 비즈니스 로직은 일절 옮기지 않는다 — 이미 CEF 의존이 0인
//! `BackendRegistry`(src/backends/loader.zig) + `EventBus`(src/core/events.zig)를
//! 그대로 감싸 C ABI로만 노출한다.
//!
//! 코어 배선(setGlobal→setEventBus 순서)을 캡슐화하되, CEF 핸들러 주입과 윈도우
//! 생성은 호스트 책임으로 남긴다. 렌더러 eval 경로(`EventBus.webview_eval`)는 Zig
//! 레벨 `eventBus()`로 호스트가 직접 연결 — 비-Zig 호스트용 C ABI 셋터는 미도입.

const std = @import("std");
const loader = @import("loader");
const events = @import("events");
const util = @import("util");

const BackendRegistry = loader.BackendRegistry;
const EventBus = events.EventBus;

/// 독립 실행용 Io. 호스트는 `std.process.Init`을 주지 않으므로 코어가 자체 보유.
/// 단일 스레드 인스턴스로 충분 — invoke/emit은 동기 경로이고, EventBus/RwLock의
/// mutex 연산은 할당 없이 동작한다.
var embed_threaded: std.Io.Threaded = std.Io.Threaded.init_single_threaded;

const State = struct {
    registry: BackendRegistry,
    event_bus: EventBus,
    allocator: std.mem.Allocator,
};

/// 힙 보관 — `BackendRegistry.setGlobal`이 `*BackendRegistry`를, EventBus 리스너가
/// `*EventBus`를 참조하므로 포인터가 고정돼야 한다.
var g_state: ?*State = null;

/// 마지막 실패의 사람이 읽는 사유 (정적 문자열 — 호스트가 free 안 함, 다음
/// 실패 호출 전까지 유효). 단일 `-1` 반환을 진단 가능하게 보강.
/// zero-native `last_error_name` 패턴 차용.
var g_last_error: [*:0]const u8 = "";

fn setErr(msg: [:0]const u8) void {
    g_last_error = msg.ptr;
}

// ============================================================
// Zig 레벨 API (테스트 / 호스트 Zig 코드가 직접 호출)
//   - 테스트는 std.testing.allocator/io 를 주입해 누수 검출.
//   - C ABI export는 아래에서 c_allocator + 독립 Io 로 이 경로를 재사용.
// ============================================================

pub const Error = error{ AlreadyInitialized, OutOfMemory };

pub fn init(allocator: std.mem.Allocator, io: std.Io) Error!void {
    if (g_state != null) return Error.AlreadyInitialized;

    const state = allocator.create(State) catch return Error.OutOfMemory;
    state.* = .{
        .registry = BackendRegistry.init(allocator, io),
        .event_bus = EventBus.init(allocator, io),
        .allocator = allocator,
    };
    // main.zig 배선 순서 미러링: setGlobal → setEventBus.
    state.registry.setGlobal();
    state.registry.setEventBus(&state.event_bus);
    g_state = state;
}

pub fn deinit() void {
    freePerm();
    const state = g_state orelse return;
    state.event_bus.deinit();
    state.registry.deinit();
    const a = state.allocator;
    a.destroy(state);
    g_state = null;
}

fn requireState() *State {
    return g_state orelse std.debug.panic("embed: init() 호출 전 코어 접근", .{});
}

pub fn registry() *BackendRegistry {
    return &requireState().registry;
}

pub fn eventBus() *EventBus {
    return &requireState().event_bus;
}

/// 채널명 → 백엔드 라우팅 후 코어 invoke. 반환 포인터는 호출자가 `freeResponse`로
/// 해제 (C ABI에서는 `suji_core_free`). 라우트가 없으면 채널명 자체를 백엔드/임베드
/// 런타임 이름으로 시도 — main.zig 의 cefInvokeHandler 와 동일 의미.
pub fn invokeOwned(channel: [*:0]const u8, json: [*:0]const u8) [*c]const u8 {
    const reg = registry();
    const ch = std.mem.span(channel);

    if (reg.getBackendForChannel(ch)) |backend_name| {
        var name_buf: [util.MAX_CHANNEL_NAME]u8 = undefined;
        const name = util.nullTerminate(backend_name, &name_buf);
        return reg.core_api.invoke(@ptrCast(name.ptr), @ptrCast(json));
    }
    // 라우트 없음 → 채널명 = 백엔드/임베드 런타임 이름으로 시도.
    return reg.core_api.invoke(@ptrCast(channel), @ptrCast(json));
}

pub fn freeResponse(ptr: [*c]const u8) void {
    const reg = registry();
    reg.core_api.free(ptr);
}

// ============================================================
// C ABI export — 호스트(CEF/iOS/Android)가 dlopen/정적 링크로 호출
// ============================================================

/// 코어 초기화. 0=성공, -1=실패(`suji_core_last_error` 로 사유 조회).
export fn suji_core_init() c_int {
    init(std.heap.c_allocator, embed_threaded.io()) catch |e| {
        setErr(switch (e) {
            Error.AlreadyInitialized => "already initialized",
            Error.OutOfMemory => "out of memory",
        });
        return -1;
    };
    // init = lifecycle 경계라 진단 리셋. lifecycle 내에서는 sticky
    // (실패가 덮고, 성공은 안 지움 — errno 모델).
    setErr("");
    return 0;
}

/// 마지막으로 기록된 `suji_core_*` 실패 사유 (사람이 읽음). 한 lifecycle 내
/// 에선 sticky — 성공 호출은 안 지우고, `suji_core_init` 성공만 리셋한다.
/// 실패 기록 없으면 빈 문자열. 정적 — free 금지, 다음 실패 전까지 유효.
export fn suji_core_last_error() [*c]const u8 {
    return g_last_error;
}

export fn suji_core_destroy() void {
    deinit();
}

/// 프론트엔드 invoke 디스패치. 반환 문자열은 코어 소유 — 호출자는 사용 후
/// 반드시 `suji_core_free`로 해제. 미초기화 시 빈 문자열.
export fn suji_core_invoke(channel: [*c]const u8, json: [*c]const u8) [*c]const u8 {
    if (g_state == null) {
        setErr("not initialized"); // 빈 응답이 미초기화인지 빈 결과인지 진단 가능하게
        return @ptrCast(@constCast(""));
    }
    return invokeOwned(@ptrCast(channel), @ptrCast(json));
}

export fn suji_core_free(ptr: [*c]const u8) void {
    if (g_state == null or ptr == null) return;
    freeResponse(ptr);
}

/// 호스트(Swift/Kotlin/임의 네이티브)가 채널을 네이티브로 응답하도록 등록.
/// dlopen 백엔드가 없는 모바일에서 invoke를 의미 있게 만든다 — Node가 쓰는
/// `embed_runtimes` 경로를 그대로 재사용(코어 측 신규 상태 0).
///
/// 라우팅은 등록명 정확 매치. ⚠️ 단 invoke_cb 의 channel 인자는 등록명이
/// 아닐 수 있음 — `coreInvoke`(loader.zig)가 embed_runtimes 폴백에서
/// `extractCmdField(req) orelse name`를 넘기므로, 요청 json 에 "cmd"가 있으면
/// 그 cmd 값이 channel 로 온다(`__core__` 멀티플렉싱). 호스트는 channel 대신
/// json 의 cmd 로 분기할 것(include/suji_core.h cb 주석 참조).
/// invoke_cb 반환 문자열은 호스트 소유 — 코어가 즉시 복사하고 free_cb로
/// 원본을 호스트에 돌려준다. 0=성공, -1=실패.
export fn suji_core_register_handler(
    channel: [*c]const u8,
    invoke_cb: ?*const fn (channel: [*:0]const u8, data: [*:0]const u8) callconv(.c) ?[*:0]const u8,
    free_cb: ?*const fn (ptr: [*:0]const u8) callconv(.c) void,
) c_int {
    if (g_state == null) {
        setErr("not initialized");
        return -1;
    }
    const cb = invoke_cb orelse {
        setErr("null invoke_cb");
        return -1;
    };
    loader.BackendRegistry.registerEmbedRuntime(
        util.cSpan(channel),
        .{ .invoke = cb, .free_response = free_cb },
    ) catch |e| {
        setErr(switch (e) {
            error.NoRegistry => "no registry",
            error.OutOfMemory => "out of memory",
        });
        return -1;
    };
    return 0;
}

export fn suji_core_emit(event_name: [*c]const u8, json: [*c]const u8) void {
    const state = g_state orelse return;
    state.event_bus.emit(util.cSpan(event_name), util.cSpan(json));
}

export fn suji_core_emit_to(target: u32, event_name: [*c]const u8, json: [*c]const u8) void {
    const state = g_state orelse return;
    state.event_bus.emitTo(target, util.cSpan(event_name), util.cSpan(json));
}

export fn suji_core_on(
    event_name: [*c]const u8,
    callback: ?*const fn ([*c]const u8, [*c]const u8, ?*anyopaque) callconv(.c) void,
    arg: ?*anyopaque,
) u64 {
    const state = g_state orelse return 0;
    const cb = callback orelse return 0;
    return state.event_bus.onC(util.cSpan(event_name), cb, arg);
}

export fn suji_core_off(listener_id: u64) void {
    const state = g_state orelse return;
    state.event_bus.off(listener_id);
}

// ============================================================
// 권한 정책 — 모바일 호스트가 set, 네이티브 액션 전 check (Tauri 패리티).
// 게이트 로직은 util.* 단일 출처 재사용 → Swift/Kotlin glob 재구현 0.
// 모바일은 **uniform opt-in**: 정책/패밀리 키 부재 → 허용(비파괴 — 기존
// 모바일 fs/shell 동작 불변). 키 존재 → enforce(`[]`=deny-all/`["*"]`=allow/
// 특정=제한). 데스크톱 fs default-deny 와 다름(모바일은 OS 샌드박스가 하드
// 경계 + 기존 동작 보존 — 의도적, 문서 명시).
// ============================================================

const PermPolicy = struct {
    parsed: std.json.Parsed(std.json.Value),
    shell_paths: ?[]const [:0]const u8 = null,
    shell_urls: ?[]const [:0]const u8 = null,
    dialog_paths: ?[]const [:0]const u8 = null,
    fs_roots: ?[]const [:0]const u8 = null,
};
var g_perm: ?PermPolicy = null;

fn freePerm() void {
    if (g_perm) |p| {
        p.parsed.deinit();
        g_perm = null;
    }
}

/// obj[key] 가 string 배열이면 arena 로 dupZ 한 슬라이스, 키 부재면 null,
/// 키 존재하나 비배열이면 빈(non-null) 슬라이스 = enforce deny-all.
/// config.zig parseAllowList 와 형태 유사하나 공유 불가 — embed 는 CEF-free
/// 경계라 config(@import("window") 경유) 미import + 모바일은 `~` expand 금지
/// (호스트가 이미 해석된 샌드박스 컨테이너 경로 전달, HOME env 무의미).
fn permList(a: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) !?[]const [:0]const u8 {
    const v = obj.get(key) orelse return null;
    if (v != .array) return &.{};
    var list = std.ArrayList([:0]const u8).empty;
    for (v.array.items) |item| {
        if (item != .string) continue;
        // OOM 을 `catch continue`로 삼키면 allowlist 가 조용히 줄거나 toOwnedSlice
        // 실패 시 빈 슬라이스(=deny-all)로 격하된다 — 호출자가 정책 빌드를 통째 실패
        // 처리하도록 에러를 전파한다(아래 set_permissions 가 기존 정책 보존).
        const s = try a.dupeZ(u8, item.string);
        try list.append(a, s);
    }
    return try list.toOwnedSlice(a);
}

/// 정책 객체에서 shell/dialog/fs allowlist 를 빌드. 어느 하나라도 OOM 이면 에러를
/// 전파해 호출자가 기존 정책을 유지하게 한다(부분 적용 금지).
fn buildPolicy(pol: *PermPolicy, a: std.mem.Allocator, root: std.json.ObjectMap) !void {
    if (root.get("shell")) |sh| if (sh == .object) {
        pol.shell_paths = try permList(a, sh.object, "allowedPaths");
        pol.shell_urls = try permList(a, sh.object, "allowedExternalUrls");
    };
    if (root.get("dialog")) |dl| if (dl == .object) {
        pol.dialog_paths = try permList(a, dl.object, "allowedPaths");
    };
    if (root.get("fs")) |fsv| if (fsv == .object) {
        pol.fs_roots = try permList(a, fsv.object, "allowedRoots");
    };
}

/// 권한 정책 JSON 설정(호스트가 init 후 1회 / 변경 시 호출). null/len=0 →
/// 정책 해제(전체 opt-in 허용). 0=성공, -1=parse 오류. 호스트는 호출 후
/// json_ptr 를 free 해도 됨(코어가 복사 소유).
export fn suji_core_set_permissions(json_ptr: [*c]const u8, len: usize) c_int {
    // null/len=0 → 명시적 정책 해제(전체 opt-in 허용).
    if (json_ptr == null or len == 0) {
        freePerm();
        return 0;
    }
    const bytes = @as([*]const u8, @ptrCast(json_ptr))[0..len];

    // 새 정책을 먼저 완전히 빌드하고, 성공했을 때만 기존 정책을 교체한다.
    // freePerm()을 선두에서 호출하면 이후 parse/build 실패 시 g_perm 이 null 로 남아
    // permission_check 가 전체 허용(fail-OPEN)으로 돌변한다 — 그래서 swap-on-success.
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.c_allocator, bytes, .{}) catch {
        setErr("permissions json parse error");
        return -1; // 기존 정책 유지
    };
    if (parsed.value != .object) {
        parsed.deinit();
        setErr("permissions json not object");
        return -1; // 기존 정책 유지
    }
    const a = parsed.arena.allocator();
    const root = parsed.value.object;
    var pol = PermPolicy{ .parsed = parsed };
    buildPolicy(&pol, a, root) catch {
        parsed.deinit();
        setErr("permissions build out of memory");
        return -1; // 기존 정책 유지 (fail-safe)
    };
    // 빌드 성공 — 이제서야 기존 정책 해제 후 교체.
    freePerm();
    g_perm = pol;
    return 0;
}

/// family(IPC cmd 명)·value(path 또는 url)가 정책 허용인지. is_backend!=0 →
/// 무조건 허용(backend SDK 우회, desktop g_in_backend_invoke 동형).
/// 1=허용, 0=거부. (정책/패밀리 키 미설정 → 1=허용, opt-in.)
export fn suji_core_permission_check(
    family: [*c]const u8,
    value: [*c]const u8,
    is_backend: c_int,
) c_int {
    if (is_backend != 0) return 1;
    // 보안 C ABI — null 입력은 fail-closed(거부). cSpan(null) 크래시 회피.
    if (family == null or value == null) return 0;
    const fam = util.cSpan(family);
    const val = util.cSpan(value);
    const pol = g_perm orelse return 1;

    if (std.mem.eql(u8, fam, "shell_open_external")) {
        // file:// 은 로컬 파일 열기 — shell.allowedPaths 가 설정된 경우 PATH 게이트로 통제
        // 하고, 미설정이면 URL 게이트로 폴백(file:// 는 URL glob 에 안 맞아 deny / 둘 다
        // 미설정 시 legacy allow). 데스크톱 shellOpenExternalGate 동형 — 안 하면
        // allowedExternalUrls 만 설정 시 file:// 가 URL 게이트만 거쳐 무제약 통과.
        if (std.mem.startsWith(u8, val, "file://")) {
            if (pol.shell_paths) |paths| {
                var rest = val["file://".len..];
                if (rest.len > 0 and rest[0] != '/') {
                    rest = if (std.mem.indexOfScalar(u8, rest, '/')) |s| rest[s..] else "";
                }
                if (std.mem.indexOfScalar(u8, rest, '%') != null) return 0;
                return if (util.pathAllowedInRoots(rest, paths)) 1 else 0;
            }
        }
        const list = pol.shell_urls orelse return 1;
        return if (util.urlAllowedInList(val, list)) 1 else 0;
    }
    if (std.mem.eql(u8, fam, "shell_open_path") or
        std.mem.eql(u8, fam, "shell_show_item_in_folder") or
        std.mem.eql(u8, fam, "shell_trash_item"))
    {
        const list = pol.shell_paths orelse return 1;
        return if (util.pathAllowedInRoots(val, list)) 1 else 0;
    }
    if (std.mem.eql(u8, fam, "dialog_show_open_dialog") or
        std.mem.eql(u8, fam, "dialog_show_save_dialog"))
    {
        if (val.len == 0) return 1; // 빈 defaultPath 무제약(사용자 중재)
        const list = pol.dialog_paths orelse return 1;
        return if (util.pathAllowedInRoots(val, list)) 1 else 0;
    }
    if (std.mem.startsWith(u8, fam, "fs_")) {
        const list = pol.fs_roots orelse return 1;
        return if (util.pathAllowedInRoots(val, list)) 1 else 0;
    }
    return 1; // 게이트 대상 아닌 family → 허용
}
