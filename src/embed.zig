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
    g_last_error = ""; // 새 lifecycle — 이전 실패 사유 클리어
    return 0;
}

/// 마지막 `suji_core_*` 실패의 사람이 읽는 사유. 실패 없으면 빈 문자열.
/// 정적 — free 금지, 다음 실패 호출 전까지 유효.
export fn suji_core_last_error() [*c]const u8 {
    return g_last_error;
}

export fn suji_core_destroy() void {
    deinit();
}

/// 프론트엔드 invoke 디스패치. 반환 문자열은 코어 소유 — 호출자는 사용 후
/// 반드시 `suji_core_free`로 해제. 미초기화 시 빈 문자열.
export fn suji_core_invoke(channel: [*c]const u8, json: [*c]const u8) [*c]const u8 {
    if (g_state == null) return @ptrCast(@constCast(""));
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
/// 채널명 == 등록명 정확 매치. invoke_cb 반환 문자열은 호스트 소유 —
/// 코어가 즉시 복사하고 free_cb로 원본을 호스트에 돌려준다. 0=성공, -1=실패.
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
    ) catch {
        setErr("register failed (registry/oom)");
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
