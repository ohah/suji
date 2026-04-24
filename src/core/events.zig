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
pub const EventBus = struct {
    listeners: std.StringHashMap(std.ArrayList(Listener)),
    allocator: std.mem.Allocator,
    next_id: u64 = 1,
    /// Zig 0.16: std.Thread.Mutex 제거 → std.Io.Mutex
    mutex: std.Io.Mutex = .init,
    io: std.Io,

    // WebView eval 콜백 (JS에 이벤트 전달용)
    webview_eval: ?*const fn (js: [:0]const u8) void = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) EventBus {
        return .{
            .listeners = std.StringHashMap(std.ArrayList(Listener)).init(allocator),
            .allocator = allocator,
            .io = io,
        };
    }

    /// 이벤트 구독 — 리스너 ID 반환 (해제용)
    pub fn on(self: *EventBus, event_name: []const u8, callback: EventCallback) u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const id = self.next_id;
        self.next_id += 1;

        const listener = Listener{
            .id = id,
            .callback = .{ .zig = callback },
        };

        self.addListener(event_name, listener);
        return id;
    }

    /// C ABI 이벤트 구독 (백엔드에서 사용)
    pub fn onC(self: *EventBus, event_name: []const u8, callback: CEventCallback, arg: ?*anyopaque) u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const id = self.next_id;
        self.next_id += 1;

        const listener = Listener{
            .id = id,
            .callback = .{ .c_abi = .{ .func = callback, .arg = arg } },
        };

        self.addListener(event_name, listener);
        return id;
    }

    /// 한 번만 수신
    pub fn once(self: *EventBus, event_name: []const u8, callback: EventCallback) u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const id = self.next_id;
        self.next_id += 1;

        const listener = Listener{
            .id = id,
            .callback = .{ .zig = callback },
            .once = true,
        };

        self.addListener(event_name, listener);
        return id;
    }

    /// 이벤트 발행
    pub fn emit(self: *EventBus, event_name: []const u8, data: []const u8) void {
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

        // 콜백 실행 (mutex 밖 — 블로킹 안전)
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

        self.emitToJs(event_name, data);
    }

    /// 리스너 해제 (ID 기반)
    pub fn off(self: *EventBus, listener_id: u64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var iter = self.listeners.iterator();
        while (iter.next()) |entry| {
            var list = entry.value_ptr;
            var i: usize = 0;
            while (i < list.items.len) {
                if (list.items[i].id == listener_id) {
                    _ = list.orderedRemove(i);
                    return;
                }
                i += 1;
            }
        }
    }

    /// 특정 이벤트의 모든 리스너 해제
    pub fn offAll(self: *EventBus, event_name: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.listeners.getPtr(event_name)) |list| {
            list.clearRetainingCapacity();
        }
    }

    pub fn deinit(self: *EventBus) void {
        var iter = self.listeners.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.listeners.deinit();
    }

    // 내부 헬퍼
    fn addListener(self: *EventBus, event_name: []const u8, listener: Listener) void {
        if (self.listeners.getPtr(event_name)) |list| {
            list.append(self.allocator, listener) catch {};
        } else {
            var list = std.ArrayList(Listener).empty;
            list.append(self.allocator, listener) catch {};
            // event_name은 caller의 스택 버퍼일 수 있음 (backend SDK의 nullTerminate 경유).
            // 바깥에 벗어나면 메모리 재사용되므로 키는 HashMap이 소유하도록 복사.
            const owned_key = self.allocator.dupe(u8, event_name) catch return;
            self.listeners.put(owned_key, list) catch {
                self.allocator.free(owned_key);
            };
        }
    }

    fn emitToJs(self: *EventBus, event_name: []const u8, data: []const u8) void {
        if (self.webview_eval) |eval_fn| {
            var js_buf: [16384]u8 = undefined;
            const js = std.fmt.bufPrint(&js_buf,
                "window.__suji__ && window.__suji__.__dispatch__ && window.__suji__.__dispatch__(\"{s}\", {s})",
                .{ event_name, data },
            ) catch return;
            js_buf[js.len] = 0;
            eval_fn(js_buf[0..js.len :0]);
        }
    }
};
