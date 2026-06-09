const std = @import("std");
const util = @import("util");

/// 이벤트 콜백 타입
/// data: JSON 문자열 (null-terminated)
pub const EventCallback = *const fn (data: [*:0]const u8) void;

/// C ABI 이벤트 콜백 (백엔드용)
pub const CEventCallback = *const fn (event_name: [*c]const u8, data: [*c]const u8, arg: ?*anyopaque) callconv(.c) void;

/// 이벤트 리스너
const Listener = struct {
    id: u64,
    callback: union(enum) {
        zig: EventCallback,
        c_abi: struct {
            func: CEventCallback,
            arg: ?*anyopaque,
        },
    },
    once: bool = false,
};

/// 이벤트 버스 — pub/sub 중앙 허브
///
/// 모든 이벤트가 여기를 거침:
///   JS emit → EventBus → Go/Rust on() 수신
///   Rust emit → EventBus → JS on() 수신
///   Zig emit → EventBus → 모든 on() 수신
/// emit 콜백 루프(mutex 밖)를 실행 중인 스레드면 true. 콜백 안에서 off() 를
/// 호출하면 자기 inflight 를 자기가 기다리는 데드락이 생기므로, 그 스레드의
/// off() quiescence 대기를 건너뛰게 한다. 전역 threadlocal — 데스크톱은 EventBus
/// 단일 인스턴스라 무방(임베드 다중 인스턴스는 과보수 skip = 안전쪽, 한계).
threadlocal var in_dispatch: bool = false;

pub const EventBus = struct {
    listeners: std.StringHashMap(std.ArrayList(Listener)),
    allocator: std.mem.Allocator,
    next_id: u64 = 1,
    /// Zig 0.16: std.Thread.Mutex 제거 → std.Io.Mutex
    mutex: std.Io.Mutex = .init,
    io: std.Io,
    /// mutex 밖 콜백 실행 구간 동안 >0. off()/offAll() 이 0 될 때까지 대기해
    /// (epoch barrier) in-flight snapshot 이 freed 리스너 arg 를 부르는 UAF 를 막는다.
    /// 단일스레드 경로는 off 시점에 항상 0이라 무회귀.
    inflight: std.atomic.Value(u32) = .init(0),

    // WebView eval 콜백 (JS에 이벤트 전달용).
    // target=null이면 모든 윈도우로 브로드캐스트, u32이면 해당 WindowManager id만.
    webview_eval: ?*const fn (target: ?u32, js: [:0]const u8) void = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) EventBus {
        return .{
            .listeners = std.StringHashMap(std.ArrayList(Listener)).init(allocator),
            .allocator = allocator,
            .io = io,
        };
    }

    /// 이벤트 구독 — 성공 시 리스너 id(≥1) 반환.
    /// OOM 시 0 반환(등록 실패). 0은 EventBus "invalid id" sentinel — `next_id`는 1부터,
    /// `coreOn`도 콜백 없을 때 0 반환, `off(0)`은 안전한 no-op이라 C ABI u64 시그니처
    /// 불변. 데스크톱은 사실상 도달 불가하나 임베드(libsuji_core) 환경에서 프로세스를
    /// 죽이지 않고 graceful degrade.
    pub fn on(self: *EventBus, event_name: []const u8, callback: EventCallback) u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const id = self.next_id;
        const listener = Listener{ .id = id, .callback = .{ .zig = callback } };
        self.addListener(event_name, listener) catch return 0;
        self.next_id += 1;
        return id;
    }

    /// C ABI 이벤트 구독 (백엔드에서 사용).
    pub fn onC(self: *EventBus, event_name: []const u8, callback: CEventCallback, arg: ?*anyopaque) u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const id = self.next_id;
        const listener = Listener{ .id = id, .callback = .{ .c_abi = .{ .func = callback, .arg = arg } } };
        self.addListener(event_name, listener) catch return 0;
        self.next_id += 1;
        return id;
    }

    /// 한 번만 수신.
    pub fn once(self: *EventBus, event_name: []const u8, callback: EventCallback) u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const id = self.next_id;
        const listener = Listener{ .id = id, .callback = .{ .zig = callback }, .once = true };
        self.addListener(event_name, listener) catch return 0;
        self.next_id += 1;
        return id;
    }

    /// 이벤트 발행 — 모든 윈도우로 브로드캐스트.
    pub fn emit(self: *EventBus, event_name: []const u8, data: []const u8) void {
        self.emitInternal(event_name, data, null);
    }

    /// 특정 창에만 이벤트 전달 (Electron `webContents.send` 대응).
    /// Zig/백엔드 리스너는 target과 무관하게 항상 받는다 — 필터링은 JS dispatch 쪽만.
    pub fn emitTo(self: *EventBus, target: u32, event_name: []const u8, data: []const u8) void {
        self.emitInternal(event_name, data, target);
    }

    fn emitInternal(self: *EventBus, event_name: []const u8, data: []const u8, target: ?u32) void {
        // 리스너 스냅샷 복사 (mutex 범위 최소화)
        var snapshot: [64]Listener = undefined;
        var snapshot_len: usize = 0;
        var once_ids: [64]u64 = undefined;
        var once_count: usize = 0;

        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            if (self.listeners.getPtr(event_name)) |list| {
                snapshot_len = @min(list.items.len, 64);
                @memcpy(snapshot[0..snapshot_len], list.items[0..snapshot_len]);

                // once 리스너 ID 수집 + 제거
                var i: usize = list.items.len;
                while (i > 0) {
                    i -= 1;
                    if (list.items[i].once) {
                        if (once_count < 64) {
                            once_ids[once_count] = list.items[i].id;
                            once_count += 1;
                        }
                        _ = list.orderedRemove(i);
                    }
                }
            }
        }

        // 콜백 실행 (mutex 밖 — 블로킹 안전). inflight 를 올려 off() 가 이 구간을
        // 기다리게 한다(c_abi arg 수명 보호). in_dispatch 로 콜백-내-off 데드락 회피.
        const prev_in_dispatch = in_dispatch;
        in_dispatch = true;
        _ = self.inflight.fetchAdd(1, .acq_rel);
        defer {
            _ = self.inflight.fetchSub(1, .release);
            in_dispatch = prev_in_dispatch;
        }

        for (snapshot[0..snapshot_len]) |listener| {
            switch (listener.callback) {
                .zig => |cb| {
                    var buf: [util.MAX_RESPONSE]u8 = undefined;
                    cb(util.nullTerminate(data, &buf));
                },
                .c_abi => |cb| {
                    var name_buf: [util.MAX_CHANNEL_NAME]u8 = undefined;
                    var data_buf: [util.MAX_RESPONSE]u8 = undefined;
                    cb.func(
                        util.nullTerminate(event_name, &name_buf).ptr,
                        util.nullTerminate(data, &data_buf).ptr,
                        cb.arg,
                    );
                },
            }
        }

        self.emitToJs(event_name, data, target);
    }

    /// off()/offAll() 공용: 진행 중인 emit 콜백이 모두 끝날 때까지 대기.
    /// 반환 후엔 in-flight snapshot 이 없으므로 caller 가 리스너 arg 를 free 해도 안전.
    fn waitQuiescent(self: *EventBus) void {
        if (in_dispatch) return; // 콜백-내 호출: 자기 inflight 자기대기 데드락 회피
        while (self.inflight.load(.acquire) != 0) std.atomic.spinLoopHint();
    }

    /// 리스너 해제 (ID 기반). 제거 후 진행 중인 emit 콜백이 끝날 때까지 대기해
    /// caller 의 후속 free 가 in-flight snapshot 과 경합하지 않게 한다.
    pub fn off(self: *EventBus, listener_id: u64) void {
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            var iter = self.listeners.iterator();
            outer: while (iter.next()) |entry| {
                var list = entry.value_ptr;
                var i: usize = 0;
                while (i < list.items.len) {
                    if (list.items[i].id == listener_id) {
                        _ = list.orderedRemove(i);
                        break :outer;
                    }
                    i += 1;
                }
            }
        }
        self.waitQuiescent();
    }

    /// 특정 이벤트의 모든 리스너 해제
    pub fn offAll(self: *EventBus, event_name: []const u8) void {
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            if (self.listeners.getPtr(event_name)) |list| {
                list.clearRetainingCapacity();
            }
        }
        self.waitQuiescent();
    }

    pub fn deinit(self: *EventBus) void {
        var iter = self.listeners.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.listeners.deinit();
    }

    // 내부 헬퍼. 실패 시 error 반환 → 호출자(`on`/`onC`/`once`)가 id=0 반환 결정.
    // 부분 실패 경로에서 errdefer로 list/key 해제 보장.
    fn addListener(self: *EventBus, event_name: []const u8, listener: Listener) !void {
        if (self.listeners.getPtr(event_name)) |list| {
            try list.append(self.allocator, listener);
            return;
        }
        // event_name은 caller의 스택 버퍼일 수 있음 (backend SDK의 nullTerminate 경유).
        // 키는 HashMap이 소유하도록 복사.
        var list = std.ArrayList(Listener).empty;
        errdefer list.deinit(self.allocator);
        try list.append(self.allocator, listener);
        const owned_key = try self.allocator.dupe(u8, event_name);
        errdefer self.allocator.free(owned_key);
        try self.listeners.put(owned_key, list);
    }

    fn emitToJs(self: *EventBus, event_name: []const u8, data: []const u8, target: ?u32) void {
        if (self.webview_eval) |eval_fn| {
            // 16KB 고정이면 큰 data(예: 200KB 응답)가 안 들어가 bufPrint 가 실패→이벤트 누락.
            // event_name+data 길이에 맞춰 동적 alloc(allocPrintZ)으로 잘림 없이 실행.
            const tmp = std.fmt.allocPrint(self.allocator,
                "window.__suji__ && window.__suji__.__dispatch__ && window.__suji__.__dispatch__(\"{s}\", {s})",
                .{ event_name, data },
            ) catch return;
            defer self.allocator.free(tmp);
            const js = self.allocator.dupeZ(u8, tmp) catch return;
            defer self.allocator.free(js);
            eval_fn(target, js);
        }
    }
};
