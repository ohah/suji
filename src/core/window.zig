//! WindowManager: 멀티 윈도우의 메모리/정책 관리자.
//!
//! 설계 원칙 (docs/WINDOW_API.md 참조):
//! - id 기반 API, monotonic u32 (재사용 없음)
//! - name 중복 시 singleton (forceNew=true면 신규)
//! - destroyed 창에 메서드 호출 시 error.WindowDestroyed
//! - 플랫폼 조작은 Native vtable로 위임 → WindowManager는 CEF 없이 TDD 가능
//!
//! 스레드 모델 (docs/WINDOW_API.md#스레드-모델 참조):
//! - write API (create/destroy/close/setters)는 **main(CEF UI) 스레드 전용**
//! - read API (get/fromName)는 어느 스레드에서든 호출 가능 (mutex 보호)
//! - std.Io.Mutex는 defense-in-depth (read/write 레이스 방지 + 잘못된 스레드 호출 시
//!   데이터 경합 대신 직렬화 보장). 단일 스레드 계약이 깨져도 crash 대신 느려지기만 함.
//!
//! Phase 2 단위 테스트는 `tests/window_manager_test.zig` 참조.
//! 실제 CEF 통합은 `src/platform/cef.zig`의 CefNative가 VTable 구현.

const std = @import("std");
const builtin = @import("builtin");

pub const Bounds = struct {
    x: i32 = 0,
    y: i32 = 0,
    width: u32 = 800,
    height: u32 = 600,
};

pub const State = packed struct {
    visible: bool = true,
};

pub const events = struct {
    pub const created = "window:created";
    pub const close = "window:close";
    pub const closed = "window:closed";
    /// 마지막 live 윈도우가 파괴되어 남은 창이 0개가 되는 순간 발화. Electron의
    /// `app.on('window-all-closed', ...)`와 동등. macOS는 보통 이 시점에도 종료하지
    /// 않고 dock에 남지만, Windows/Linux는 여기서 quit하는 것이 관습.
    pub const all_closed = "window:all-closed";
};

/// 외형 (시각 속성). frame/transparent/타이틀바 스타일/배경/그림자 등 "보이는 모양".
pub const Appearance = struct {
    /// false면 frameless — 타이틀바/리사이즈 핸들/시스템 보더 모두 제거 (Electron `frame: false`).
    frame: bool = true,
    /// true면 투명 배경 — NSWindow.opaque=false + clear color + 그림자 X. HTML body도 transparent여야 의미.
    transparent: bool = false,
    /// 16진수 RGB(A) (`#FFFFFF` / `#FFFFFFFF`). transparent=true와 함께 쓰면 transparent 우선.
    background_color: ?[]const u8 = null,
    /// Electron 호환: `.default` / `.hidden` / `.hidden_inset`.
    title_bar_style: TitleBarStyle = .default,
};

/// 제약 (창 크기/리사이즈/항상위/전체화면).
pub const Constraints = struct {
    /// false면 사용자 리사이즈 불가 (frame=true일 때만 의미; frameless는 이미 핸들 없음).
    resizable: bool = true,
    /// true면 NSFloatingWindowLevel — 일반 창 위.
    always_on_top: bool = false,
    /// 최소/최대 콘텐츠 크기 (0이면 제한 없음).
    min_width: u32 = 0,
    min_height: u32 = 0,
    max_width: u32 = 0,
    max_height: u32 = 0,
    /// 시작 시 전체화면.
    fullscreen: bool = false,
};

/// min > max (max > 0인 경우만)면 max를 0(제한 없음)으로 reset.
/// Cocoa의 setContentMaxSize: 동작이 모호한 잘못된 입력을 정상화.
/// 사용자에게 한 번 안내해 silent fix를 자각시킴.
///
/// is_test 가드: zig 0.16 test runner는 `--listen=-` IPC 모드에서 자식 프로세스의
/// stderr 노이즈가 많으면 가짜 "failed command"로 표시. 검증은 단위 테스트가 담당.
pub fn normalizeConstraints(c: *Constraints) void {
    if (c.max_width > 0 and c.min_width > c.max_width) {
        if (!builtin.is_test) std.debug.print(
            "[suji] warning: min_width({d}) > max_width({d}) — clearing max_width\n",
            .{ c.min_width, c.max_width },
        );
        c.max_width = 0;
    }
    if (c.max_height > 0 and c.min_height > c.max_height) {
        if (!builtin.is_test) std.debug.print(
            "[suji] warning: min_height({d}) > max_height({d}) — clearing max_height\n",
            .{ c.min_height, c.max_height },
        );
        c.max_height = 0;
    }
}

pub const CreateOptions = struct {
    name: ?[]const u8 = null,
    title: []const u8 = "Suji",
    /// 초기 로드 URL. null이면 Native 구현이 default URL 사용.
    url: ?[]const u8 = null,
    bounds: Bounds = .{},
    /// 부모 창 id. 비-null이면 시각 관계만 설정 (자식은 부모 위에 떠다니고 부모 이동 시 따라감).
    /// 재귀 close X — 부모 close해도 자식은 유지 (PLAN 핵심결정사항: orphan은 destroyAll만).
    parent_id: ?u32 = null,
    /// name 중복 시: false면 기존 id 반환(싱글턴), true면 새 창 생성
    force_new: bool = false,
    /// 외형 옵션 묶음 (frame / transparent / background / title_bar_style).
    appearance: Appearance = .{},
    /// 크기/위치 제약 묶음 (resizable / min·max / always_on_top / fullscreen).
    constraints: Constraints = .{},
};

pub const TitleBarStyle = enum {
    default,
    hidden,
    hidden_inset,

    /// suji.json/IPC의 camelCase 문자열을 enum으로 매핑. 미인식은 .default.
    /// "hidden" → .hidden / "hiddenInset" → .hidden_inset.
    pub fn fromString(s: []const u8) TitleBarStyle {
        if (std.mem.eql(u8, s, "hidden")) return .hidden;
        if (std.mem.eql(u8, s, "hiddenInset")) return .hidden_inset;
        return .default;
    }
};

pub const Window = struct {
    id: u32,
    /// 플랫폼 native handle (NSWindow*, HWND, GtkWindow* 또는 테스트에선 임의 값)
    native_handle: u64,
    /// owned string (WindowManager.allocator 소유). null이면 이름 없는 창
    name: ?[]const u8,
    /// owned string
    title: []const u8,
    bounds: Bounds,
    parent_id: ?u32,
    state: State,
    destroyed: bool = false,
};

/// 플랫폼 조작을 위임하는 추상화. CefNative가 CEF로 구현, TestNative가 stub.
pub const Native = struct {
    vtable: *const VTable,
    ctx: ?*anyopaque = null,

    pub const VTable = struct {
        create_window: *const fn (ctx: ?*anyopaque, opts: *const CreateOptions) anyerror!u64,
        destroy_window: *const fn (ctx: ?*anyopaque, handle: u64) void,
        set_title: *const fn (ctx: ?*anyopaque, handle: u64, title: []const u8) void,
        set_bounds: *const fn (ctx: ?*anyopaque, handle: u64, bounds: Bounds) void,
        set_visible: *const fn (ctx: ?*anyopaque, handle: u64, visible: bool) void,
        focus: *const fn (ctx: ?*anyopaque, handle: u64) void,
        // Phase 4-A: webContents 네비/JS
        load_url: *const fn (ctx: ?*anyopaque, handle: u64, url: []const u8) void,
        reload: *const fn (ctx: ?*anyopaque, handle: u64, ignore_cache: bool) void,
        execute_javascript: *const fn (ctx: ?*anyopaque, handle: u64, code: []const u8) void,
        get_url: *const fn (ctx: ?*anyopaque, handle: u64) ?[]const u8,
        is_loading: *const fn (ctx: ?*anyopaque, handle: u64) bool,
        // Phase 4-C: DevTools
        open_dev_tools: *const fn (ctx: ?*anyopaque, handle: u64) void,
        close_dev_tools: *const fn (ctx: ?*anyopaque, handle: u64) void,
        is_dev_tools_opened: *const fn (ctx: ?*anyopaque, handle: u64) bool,
        toggle_dev_tools: *const fn (ctx: ?*anyopaque, handle: u64) void,
        // Phase 4-B: 줌 — level만 노출. factor는 WM이 pow(1.2, level)로 변환
        // (Electron 호환 — `setZoomFactor(1.5)` ≈ `setZoomLevel(2.22)`).
        set_zoom_level: *const fn (ctx: ?*anyopaque, handle: u64, level: f64) void,
        get_zoom_level: *const fn (ctx: ?*anyopaque, handle: u64) f64,
    };

    pub fn createWindow(self: Native, opts: *const CreateOptions) !u64 {
        return self.vtable.create_window(self.ctx, opts);
    }
    pub fn destroyWindow(self: Native, handle: u64) void {
        self.vtable.destroy_window(self.ctx, handle);
    }
    pub fn setTitle(self: Native, handle: u64, title: []const u8) void {
        self.vtable.set_title(self.ctx, handle, title);
    }
    pub fn setBounds(self: Native, handle: u64, bounds: Bounds) void {
        self.vtable.set_bounds(self.ctx, handle, bounds);
    }
    pub fn setVisible(self: Native, handle: u64, visible: bool) void {
        self.vtable.set_visible(self.ctx, handle, visible);
    }
    pub fn focus(self: Native, handle: u64) void {
        self.vtable.focus(self.ctx, handle);
    }
    pub fn loadUrl(self: Native, handle: u64, url: []const u8) void {
        self.vtable.load_url(self.ctx, handle, url);
    }
    pub fn reload(self: Native, handle: u64, ignore_cache: bool) void {
        self.vtable.reload(self.ctx, handle, ignore_cache);
    }
    pub fn executeJavascript(self: Native, handle: u64, code: []const u8) void {
        self.vtable.execute_javascript(self.ctx, handle, code);
    }
    pub fn getUrl(self: Native, handle: u64) ?[]const u8 {
        return self.vtable.get_url(self.ctx, handle);
    }
    pub fn isLoading(self: Native, handle: u64) bool {
        return self.vtable.is_loading(self.ctx, handle);
    }
    pub fn openDevTools(self: Native, handle: u64) void {
        self.vtable.open_dev_tools(self.ctx, handle);
    }
    pub fn closeDevTools(self: Native, handle: u64) void {
        self.vtable.close_dev_tools(self.ctx, handle);
    }
    pub fn isDevToolsOpened(self: Native, handle: u64) bool {
        return self.vtable.is_dev_tools_opened(self.ctx, handle);
    }
    pub fn toggleDevTools(self: Native, handle: u64) void {
        self.vtable.toggle_dev_tools(self.ctx, handle);
    }
    pub fn setZoomLevel(self: Native, handle: u64, level: f64) void {
        self.vtable.set_zoom_level(self.ctx, handle, level);
    }
    pub fn getZoomLevel(self: Native, handle: u64) f64 {
        return self.vtable.get_zoom_level(self.ctx, handle);
    }
};

pub const Error = error{
    WindowNotFound,
    WindowDestroyed,
    NativeCreateFailed,
    OutOfMemory,
    /// name이 길이 제한 초과 또는 JSON-unsafe 문자 (`"`, `\`, control char) 포함
    InvalidName,
};

/// WindowManager.create가 수용하는 name의 최대 바이트 길이.
/// JSON payload 루트에 `__window_name` 으로 주입되는 값이므로 과도한 길이는 거부.
pub const MAX_NAME_LEN: usize = 128;

/// `buildIdPayload`가 emit하는 lifecycle 이벤트 payload의 최대 크기 + 안전 마진.
///
/// 계산: `{"windowId":` (12) + u32 max (10) + `,"name":"` (9) + name (≤ MAX_NAME_LEN) + `"}` (2) = 161.
/// 256으로 잡아 미래에 한두 필드(짧은 것) 추가될 여유를 둔다 — 큰 값(URL 등)을 추가하려면
/// 이 상수도 함께 늘려야 함. 늘리지 않으면 호출부의 `*[PAYLOAD_BUF_SIZE]u8` 시그니처가
/// 컴파일러 단계에서 강제하여 회귀를 차단.
pub const PAYLOAD_BUF_SIZE: usize = 256;
comptime {
    // payload 포맷이 안전하게 들어갈 최소 크기 검증 (회귀 시 빌드 실패).
    const min_required = 12 + 10 + 9 + MAX_NAME_LEN + 2;
    if (PAYLOAD_BUF_SIZE < min_required) {
        @compileError("PAYLOAD_BUF_SIZE too small for current MAX_NAME_LEN");
    }
}

/// wire(JSON) 리터럴 bare 삽입에 안전한 문자열 (`"`, `\`, control char 없음).
/// window_ipc의 __window_name 주입에서 guard로도 사용.
pub fn isJsonSafeChars(s: []const u8) bool {
    for (s) |c| {
        if (c == '"' or c == '\\' or c < 0x20) return false;
    }
    return true;
}

/// name이 WM/wire 주입에 안전한지 검증. 빈 문자열은 별도로 처리하므로 non-empty slice 전제.
pub fn isValidName(name: []const u8) bool {
    if (name.len == 0 or name.len > MAX_NAME_LEN) return false;
    return isJsonSafeChars(name);
}

/// JSON 문자열 리터럴로 bare 삽입이 가능하도록 최소 이스케이프.
/// `"` → `\"`, `\` → `\\`, control char(`< 0x20`) → 건너뛴다(drop).
/// URL처럼 control char이 들어올 일 거의 없는 값에 사용 (event.window.url 주입 등).
/// out_buf 공간 부족 시 0 반환 → caller가 필드 전체 주입을 건너뛰어야.
pub fn escapeJsonChars(src: []const u8, out_buf: []u8) usize {
    var o: usize = 0;
    for (src) |c| {
        if (c < 0x20) continue; // drop control
        const needed: usize = if (c == '"' or c == '\\') 2 else 1;
        if (o + needed > out_buf.len) return 0;
        if (c == '"' or c == '\\') {
            out_buf[o] = '\\';
            out_buf[o + 1] = c;
            o += 2;
        } else {
            out_buf[o] = c;
            o += 1;
        }
    }
    return o;
}

/// 취소 가능 이벤트의 기본 동작 방지 상태. listener가 preventDefault() 호출.
pub const SujiEvent = struct {
    default_prevented: bool = false,

    pub fn preventDefault(self: *SujiEvent) void {
        self.default_prevented = true;
    }
};

/// WindowManager가 EventBus(또는 테스트 spy)에 이벤트를 흘려보내는 얇은 훅.
/// 프로덕션에서는 EventBus.emit/emitCancelable로 래핑.
pub const EventSink = struct {
    vtable: *const VTable,
    ctx: ?*anyopaque = null,

    pub const VTable = struct {
        emit: *const fn (ctx: ?*anyopaque, name: []const u8, data: []const u8) void,
        /// close 같은 취소 가능 이벤트. listener가 ev.preventDefault()를 호출하면
        /// WindowManager는 실제 파괴를 건너뛴다.
        emit_cancelable: *const fn (ctx: ?*anyopaque, name: []const u8, data: []const u8, ev: *SujiEvent) void,
    };

    pub fn emit(self: EventSink, name: []const u8, data: []const u8) void {
        self.vtable.emit(self.ctx, name, data);
    }
    pub fn emitCancelable(self: EventSink, name: []const u8, data: []const u8, ev: *SujiEvent) void {
        self.vtable.emit_cancelable(self.ctx, name, data, ev);
    }
};

pub const WindowManager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    native: Native,
    sink: ?EventSink = null,
    windows: std.AutoHashMap(u32, *Window),
    /// name → id (소유: name_store). fromName lookup에만 사용
    by_name: std.StringHashMap(u32),
    next_id: u32 = 1,
    /// create/destroy/close/setters를 직렬화. 이벤트 발화는 lock 밖에서.
    lock: std.Io.Mutex = .init,

    pub var global: ?*WindowManager = null;

    pub fn init(allocator: std.mem.Allocator, io: std.Io, native: Native) WindowManager {
        return .{
            .allocator = allocator,
            .io = io,
            .native = native,
            .windows = std.AutoHashMap(u32, *Window).init(allocator),
            .by_name = std.StringHashMap(u32).init(allocator),
        };
    }

    /// EventBus 또는 테스트 spy를 주입. null 가능 (이벤트 발행 안 함).
    pub fn setEventSink(self: *WindowManager, sink: EventSink) void {
        self.sink = sink;
    }

    pub fn deinit(self: *WindowManager) void {
        // 모든 창 destroy + 메모리 회수
        var it = self.windows.iterator();
        while (it.next()) |entry| {
            const w = entry.value_ptr.*;
            if (!w.destroyed) self.native.destroyWindow(w.native_handle);
            self.allocator.free(w.title);
            if (w.name) |n| self.allocator.free(n);
            self.allocator.destroy(w);
        }
        self.windows.deinit();
        self.by_name.deinit();
    }

    /// 새 창 생성. name 중복 + forceNew=false면 기존 id 반환.
    ///
    /// name 정규화/정책:
    /// - 빈 문자열("")은 name=null로 취급 (by_name 등록 X)
    /// - forceNew=true면 기존 name 소유자를 빼앗지 않음. 새 창은 **익명**(Window.name=null)
    ///   으로 생성. fromName(n)은 계속 첫 창을 가리킴.
    pub fn create(self: *WindowManager, opts_in: CreateOptions) Error!u32 {
        var opts = opts_in;
        normalizeConstraints(&opts.constraints);

        // 빈 문자열 name 정규화
        const requested_name: ?[]const u8 = if (opts.name) |n|
            (if (n.len == 0) null else n)
        else
            null;
        if (requested_name) |n| {
            if (!isValidName(n)) return Error.InvalidName;
        }
        // forceNew=true인 경우 by_name 등록 X + Window.name=null (name 탈취 방지)
        const effective_name: ?[]const u8 = if (opts.force_new) null else requested_name;

        const CreateResult = struct { id: u32, is_new: bool };
        const result: CreateResult = blk: {
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);

            // name 싱글턴 정책 (forceNew=false 경로만 도달)
            if (effective_name) |name| {
                if (self.by_name.get(name)) |existing_id| {
                    break :blk .{ .id = existing_id, .is_new = false };
                }
            }

            // HashMap 용량을 먼저 확보해 put 실패를 원천 제거 (put 순간의 부분 성공 방지).
            // by_name.put이 OOM으로 조용히 실패하면 싱글턴 정책이 깨지므로 사전 할당 필수.
            self.windows.ensureUnusedCapacity(1) catch return Error.OutOfMemory;
            if (effective_name != null) {
                self.by_name.ensureUnusedCapacity(1) catch return Error.OutOfMemory;
            }

            const handle = self.native.createWindow(&opts) catch return Error.NativeCreateFailed;
            // 후속 allocation이 실패해도 native handle이 떠돌지 않도록 회수
            errdefer self.native.destroyWindow(handle);

            const win = self.allocator.create(Window) catch return Error.OutOfMemory;
            errdefer self.allocator.destroy(win);

            const owned_title = self.allocator.dupe(u8, opts.title) catch return Error.OutOfMemory;
            errdefer self.allocator.free(owned_title);

            const owned_name: ?[]const u8 = if (effective_name) |n|
                (self.allocator.dupe(u8, n) catch return Error.OutOfMemory)
            else
                null;
            errdefer if (owned_name) |n| self.allocator.free(n);

            const id = self.next_id;
            self.next_id += 1;

            win.* = .{
                .id = id,
                .native_handle = handle,
                .name = owned_name,
                .title = owned_title,
                .bounds = opts.bounds,
                .parent_id = opts.parent_id,
                .state = .{},
            };

            self.windows.putAssumeCapacity(id, win);
            if (owned_name) |n| {
                self.by_name.putAssumeCapacity(n, id);
            }
            break :blk .{ .id = id, .is_new = true };
        };

        // Phase 2: 이벤트 발화 (lock 밖 — listener가 다른 WindowManager 메서드 호출해도 deadlock 없음)
        if (result.is_new) {
            if (self.sink) |s| {
                var buf: [PAYLOAD_BUF_SIZE]u8 = undefined;
                // 새로 만든 창의 name (singleton 분기 없이 effective_name 그대로 — created는 항상 신규).
                const payload = buildIdPayload(&buf, result.id, effective_name);
                s.emit(events.created, payload);
            }
        }
        return result.id;
    }

    /// `{"windowId":N}` 또는 `{"windowId":N,"name":"..."}` payload.
    /// created/close/closed 공용. 표준화: name이 있고 JSON-safe면 함께 emit, 아니면 id만.
    /// 리스너는 항상 `windowId`를 받고, name은 optional로 처리.
    ///
    /// 시그니처: `*[N]u8` 고정 크기 array pointer로 받아 buf 크기를 컴파일타임에 검증.
    /// `MAX_NAME_LEN` 또는 추가 필드 도입으로 PAYLOAD_BUF_SIZE 미달 시 호출부에서 빌드 실패 →
    /// 잘린 invalid JSON이 emit되는 회귀를 정적 단계에서 차단.
    fn buildIdPayload(buf: *[PAYLOAD_BUF_SIZE]u8, id: u32, name: ?[]const u8) []const u8 {
        var w = std.Io.Writer.fixed(buf);
        const safe_name: ?[]const u8 = if (name) |n|
            (if (n.len > 0 and isJsonSafeChars(n)) n else null)
        else
            null;
        if (safe_name) |n| {
            w.print("{{\"windowId\":{d},\"name\":\"{s}\"}}", .{ id, n }) catch return w.buffered();
        } else {
            w.print("{{\"windowId\":{d}}}", .{id}) catch return w.buffered();
        }
        return w.buffered();
    }

    /// lock 보유 상태에서 id → live window (not destroyed). 내부 헬퍼.
    fn getLiveLocked(self: *WindowManager, id: u32) Error!*Window {
        const win = self.windows.get(id) orelse return Error.WindowNotFound;
        if (win.destroyed) return Error.WindowDestroyed;
        return win;
    }

    /// lock 이미 잡은 상태에서 실제 파괴. 내부 헬퍼.
    ///
    /// 순서가 중요: destroyed 마킹 + by_name 정리를 **native.destroyWindow 호출 전**에.
    /// 이유: native 구현(CefNative)이 close_browser를 호출하면 CEF가 동기로 DoClose
    /// 콜백을 발화할 수 있다. DoClose 훅이 "이 창은 이미 WM이 닫는 중"인지 판단하려면
    /// destroyed 플래그가 미리 세팅되어 있어야 한다.
    fn destroyLocked(self: *WindowManager, win: *Window) void {
        win.destroyed = true;
        if (win.name) |n| {
            _ = self.by_name.remove(n);
        }
        self.native.destroyWindow(win.native_handle);
    }

    /// 창 파괴 (강제). 이벤트 X, 취소 불가. `window:closed` 이벤트는 `close()` 경로에서만.
    pub fn destroy(self: *WindowManager, id: u32) Error!void {
        var live_after: usize = undefined;
        {
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);
            const win = try self.getLiveLocked(id);
            self.destroyLocked(win);
            live_after = self.liveCountLocked();
        }
        self.maybeEmitAllClosed(true, live_after);
    }

    /// 정책적 close. `window:close`(취소 가능) 발화 → preventDefault 아니면 파괴 +
    /// `window:closed`(단방향) 발화. 이벤트는 lock 밖에서 발화 (deadlock 방지).
    /// 반환값: true면 실제 파괴됨, false면 listener가 취소.
    pub fn close(self: *WindowManager, id: u32) Error!bool {
        // Phase 1: 유효성 확인 (lock)
        {
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);
            _ = try self.getLiveLocked(id);
        }

        // Phase 2: 취소 가능 이벤트 (lock 밖). name은 destroy 전에 캡처해서 close/closed 동일 사용.
        const name_snapshot: ?[]const u8 = if (self.windows.get(id)) |w| w.name else null;
        if (self.sink) |s| {
            var buf: [PAYLOAD_BUF_SIZE]u8 = undefined;
            const payload = buildIdPayload(&buf, id, name_snapshot);
            var ev: SujiEvent = .{};
            s.emitCancelable(events.close, payload, &ev);
            if (ev.default_prevented) return false;
        }

        // Phase 3: 실제 파괴 (lock, listener 도중 destroy됐는지 재확인)
        var live_after: usize = undefined;
        {
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);
            const win = try self.getLiveLocked(id);
            self.destroyLocked(win);
            live_after = self.liveCountLocked();
        }

        // Phase 4: 단방향 이벤트 (lock 밖)
        if (self.sink) |s| {
            var buf: [PAYLOAD_BUF_SIZE]u8 = undefined;
            const payload = buildIdPayload(&buf, id, name_snapshot);
            s.emit(events.closed, payload);
        }
        self.maybeEmitAllClosed(true, live_after);
        return true;
    }

    /// 모든 창 파괴. 프로세스 종료 시 호출. 각 창마다 `window:closed` 단방향 이벤트 발화.
    /// 취소 불가 (강제). all-or-nothing: 중간 할당 실패 시 어떤 창도 파괴하지 않음.
    pub fn destroyAll(self: *WindowManager) Error!void {
        // Phase 1: 파괴 + id/name 수집 (lock). 용량 사전 확보 실패 시 아무것도 파괴하지 않음.
        // name은 by_name.clearRetainingCapacity 후에도 살아있는 owned slice에서 가져옴 (Window.name은 별도 alloc).
        const ClosedEntry = struct { id: u32, name: ?[]const u8 };
        var closed: std.ArrayList(ClosedEntry) = .empty;
        defer closed.deinit(self.allocator);
        {
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);
            closed.ensureTotalCapacity(self.allocator, self.windows.count()) catch
                return Error.OutOfMemory;
            var it = self.windows.iterator();
            while (it.next()) |entry| {
                const w = entry.value_ptr.*;
                if (!w.destroyed) {
                    // destroyLocked과 같은 이유로 destroyed 마킹을 native 호출 전에.
                    w.destroyed = true;
                    self.native.destroyWindow(w.native_handle);
                    closed.appendAssumeCapacity(.{ .id = w.id, .name = w.name });
                }
            }
            self.by_name.clearRetainingCapacity();
        }

        // Phase 2: 이벤트 발화 (lock 밖)
        if (self.sink) |s| {
            for (closed.items) |c| {
                var buf: [PAYLOAD_BUF_SIZE]u8 = undefined;
                const payload = buildIdPayload(&buf, c.id, c.name);
                s.emit(events.closed, payload);
            }
        }
        // destroyAll 이후 live=0 (모두 destroyed 마킹됨). lock 재획득 없이 직접 0 전달.
        self.maybeEmitAllClosed(closed.items.len > 0, 0);
    }

    pub fn get(self: *const WindowManager, id: u32) ?*const Window {
        return self.windows.get(id);
    }

    pub fn fromName(self: *const WindowManager, name: []const u8) ?u32 {
        return self.by_name.get(name);
    }

    /// native_handle로 WM id 역조회. destroyed 창도 포함 (CEF 콜백이 "이미 WM 처리됨"을
    /// 구별하려면 destroyed 상태로도 찾을 수 있어야).
    pub fn findByNativeHandle(self: *const WindowManager, handle: u64) ?u32 {
        var it = self.windows.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.native_handle == handle) {
                return entry.value_ptr.*.id;
            }
        }
        return null;
    }

    /// 외부 트리거(예: CEF DoClose)용 "물어보기" 버전. `window:close` 취소 가능 이벤트를
    /// 발화하고 preventDefault 여부를 반환. **실제 파괴/`window:closed` 이벤트는 발화 X**
    /// — 외부 layer가 파괴를 수행하고 나중에 markClosedExternal로 WM에 통지.
    pub fn tryClose(self: *WindowManager, id: u32) Error!bool {
        {
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);
            _ = try self.getLiveLocked(id);
        }
        if (self.sink) |s| {
            var buf: [PAYLOAD_BUF_SIZE]u8 = undefined;
            const name_snapshot: ?[]const u8 = if (self.windows.get(id)) |w| w.name else null;
            const payload = buildIdPayload(&buf, id, name_snapshot);
            var ev: SujiEvent = .{};
            s.emitCancelable(events.close, payload, &ev);
            if (ev.default_prevented) return false;
        }
        return true;
    }

    /// 외부(예: CEF OnBeforeClose)가 이미 파괴한 윈도우를 WM에 알림.
    /// destroyed 마킹 + by_name 정리 + `window:closed` 이벤트 발화.
    /// **native.destroyWindow는 호출하지 않음** — 외부가 이미 처리.
    pub fn markClosedExternal(self: *WindowManager, id: u32) Error!void {
        var live_after: usize = undefined;
        // name은 by_name 제거 전에 캡처 — Window.name(owned slice)는 살아있어 안전.
        var name_snapshot: ?[]const u8 = null;
        {
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);
            const win = try self.getLiveLocked(id);
            win.destroyed = true;
            name_snapshot = win.name;
            if (win.name) |n| {
                _ = self.by_name.remove(n);
            }
            live_after = self.liveCountLocked();
        }
        if (self.sink) |s| {
            var buf: [PAYLOAD_BUF_SIZE]u8 = undefined;
            const payload = buildIdPayload(&buf, id, name_snapshot);
            s.emit(events.closed, payload);
        }
        self.maybeEmitAllClosed(true, live_after);
    }

    /// 살아있는(destroyed=false) 창의 개수. O(N). Lock 획득.
    pub fn liveCount(self: *WindowManager) usize {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        return self.liveCountLocked();
    }

    /// liveCount lock 보유 버전. 내부 헬퍼.
    fn liveCountLocked(self: *const WindowManager) usize {
        var count: usize = 0;
        var it = self.windows.iterator();
        while (it.next()) |entry| {
            if (!entry.value_ptr.*.destroyed) count += 1;
        }
        return count;
    }

    /// `destroyed_any=true` & `live_count_after==0`이면 `window:all-closed` 발화.
    /// live_count는 caller가 lock 안에서 계산해 전달 (lock 재획득 회피).
    fn maybeEmitAllClosed(self: *WindowManager, destroyed_any: bool, live_count_after: usize) void {
        if (!destroyed_any) return;
        if (live_count_after > 0) return;
        const s = self.sink orelse return;
        s.emit(events.all_closed, "{}");
    }

    pub fn setTitle(self: *WindowManager, id: u32, title: []const u8) Error!void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const win = try self.getLiveLocked(id);
        const owned = self.allocator.dupe(u8, title) catch return Error.OutOfMemory;
        self.allocator.free(win.title);
        win.title = owned;
        self.native.setTitle(win.native_handle, title);
    }

    pub fn setBounds(self: *WindowManager, id: u32, bounds: Bounds) Error!void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const win = try self.getLiveLocked(id);
        win.bounds = bounds;
        self.native.setBounds(win.native_handle, bounds);
    }

    pub fn setVisible(self: *WindowManager, id: u32, visible: bool) Error!void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const win = try self.getLiveLocked(id);
        win.state.visible = visible;
        self.native.setVisible(win.native_handle, visible);
    }

    pub fn focus(self: *WindowManager, id: u32) Error!void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const win = try self.getLiveLocked(id);
        self.native.focus(win.native_handle);
    }

    // ==================== Phase 4-A: webContents (네비 / JS) ====================

    pub fn loadUrl(self: *WindowManager, id: u32, url: []const u8) Error!void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const win = try self.getLiveLocked(id);
        self.native.loadUrl(win.native_handle, url);
    }

    pub fn reload(self: *WindowManager, id: u32, ignore_cache: bool) Error!void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const win = try self.getLiveLocked(id);
        self.native.reload(win.native_handle, ignore_cache);
    }

    pub fn executeJavascript(self: *WindowManager, id: u32, code: []const u8) Error!void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const win = try self.getLiveLocked(id);
        self.native.executeJavascript(win.native_handle, code);
    }

    /// 현재 main frame URL을 반환. 캐시되어 있지 않으면 null.
    /// 반환 슬라이스의 수명은 native가 보장 (CEF는 BrowserEntry.url_cache에 보관).
    pub fn getUrl(self: *WindowManager, id: u32) Error!?[]const u8 {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const win = try self.getLiveLocked(id);
        return self.native.getUrl(win.native_handle);
    }

    pub fn isLoading(self: *WindowManager, id: u32) Error!bool {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const win = try self.getLiveLocked(id);
        return self.native.isLoading(win.native_handle);
    }

    // ==================== Phase 4-C: DevTools ====================

    pub fn openDevTools(self: *WindowManager, id: u32) Error!void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const win = try self.getLiveLocked(id);
        self.native.openDevTools(win.native_handle);
    }

    pub fn closeDevTools(self: *WindowManager, id: u32) Error!void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const win = try self.getLiveLocked(id);
        self.native.closeDevTools(win.native_handle);
    }

    pub fn isDevToolsOpened(self: *WindowManager, id: u32) Error!bool {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const win = try self.getLiveLocked(id);
        return self.native.isDevToolsOpened(win.native_handle);
    }

    pub fn toggleDevTools(self: *WindowManager, id: u32) Error!void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const win = try self.getLiveLocked(id);
        self.native.toggleDevTools(win.native_handle);
    }

    // ==================== Phase 4-B: 줌 ====================
    // CEF는 zoom_level만 노출 — Electron의 zoomFactor는 pow(1.2, level)로 변환.

    pub fn setZoomLevel(self: *WindowManager, id: u32, level: f64) Error!void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const win = try self.getLiveLocked(id);
        self.native.setZoomLevel(win.native_handle, level);
    }

    pub fn getZoomLevel(self: *WindowManager, id: u32) Error!f64 {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const win = try self.getLiveLocked(id);
        return self.native.getZoomLevel(win.native_handle);
    }

    /// factor → level 변환: level = log(factor) / log(1.2). factor < 0이면 0(기본 100%) 사용.
    pub fn setZoomFactor(self: *WindowManager, id: u32, factor: f64) Error!void {
        const level: f64 = if (factor > 0) @log(factor) / @log(1.2) else 0;
        return self.setZoomLevel(id, level);
    }

    pub fn getZoomFactor(self: *WindowManager, id: u32) Error!f64 {
        const level = try self.getZoomLevel(id);
        return std.math.pow(f64, 1.2, level);
    }
};
