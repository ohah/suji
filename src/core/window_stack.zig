//! WindowStack: WindowManager + EventBusSink 묶음 — 수명 안전한 배선 도우미.
//!
//! WindowManager가 EventSink를 참조하려면 sink 포인터가 수명 내내 유효해야 한다.
//! 두 객체를 한 구조체에 박아두고 init/deinit 순서를 고정해 자가참조 포인터가
//! 깨질 일이 없게 한다.
//!
//! 사용 패턴:
//! ```
//! var stack: WindowStack = undefined;
//! stack.init(allocator, io, native, &event_bus);
//! defer stack.deinit();
//! stack.setGlobal();
//! defer WindowStack.clearGlobal();
//! _ = try stack.manager.create(opts);
//! ```
//!
//! init은 caller-provided storage 패턴 (self: *Self). return-by-value로 만들면
//! setEventSink가 잡는 &self.sink가 임시 주소라 copy 후 dangling.

const std = @import("std");
const events = @import("events");
const window = @import("window");
const event_sink = @import("event_sink");

pub const WindowStack = struct {
    sink: event_sink.EventBusSink,
    manager: window.WindowManager,

    pub fn init(
        self: *WindowStack,
        allocator: std.mem.Allocator,
        io: std.Io,
        native: window.Native,
        bus: *events.EventBus,
    ) void {
        self.sink = event_sink.EventBusSink.init(allocator, io, bus);
        self.manager = window.WindowManager.init(allocator, io, native);
        self.manager.setEventSink(self.sink.asSink());
    }

    pub fn deinit(self: *WindowStack) void {
        // manager 먼저: destroyAll 등 내부 경로가 sink.emit을 호출할 수 있음
        self.manager.deinit();
        self.sink.deinit();
    }

    /// 플러그인/백엔드가 WindowManager에 접근할 수 있도록 전역 포인터 설정.
    /// 프로세스당 하나의 stack만 global로 등록되는 것을 기대.
    pub fn setGlobal(self: *WindowStack) void {
        window.WindowManager.global = &self.manager;
    }

    pub fn clearGlobal() void {
        window.WindowManager.global = null;
    }
};
