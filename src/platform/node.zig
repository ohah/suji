const std = @import("std");
const builtin = @import("builtin");
const node_config = @import("node_config");

pub const node_enabled = node_config.node_enabled;

/// Node.js C 브릿지 (bridge.h) — libnode가 있을 때만 사용
pub const bridge = if (node_enabled) @cImport({
    @cInclude("bridge.h");
}) else struct {
    pub fn suji_node_init(_: c_int, _: anytype) callconv(.c) c_int { return -1; }
    pub fn suji_node_run(_: anytype) callconv(.c) c_int { return -1; }
    pub fn suji_node_stop() callconv(.c) void {}
    pub fn suji_node_shutdown() callconv(.c) void {}
    pub fn suji_node_invoke(_: anytype, _: anytype) callconv(.c) ?[*:0]const u8 { return null; }
    pub fn suji_node_free(_: anytype) callconv(.c) void {}
    pub fn suji_node_set_core(_: anytype) callconv(.c) void {}
    pub fn suji_node_wait_ready(_: c_int) callconv(.c) c_int { return -1; }
    // on/off는 SujiNodeCore를 통해 전달되므로 stub 불필요
};

/// Node.js 백엔드 런타임
pub const NodeRuntime = struct {
    allocator: std.mem.Allocator,
    entry_path: [:0]const u8,
    thread: ?std.Thread = null,
    initialized: bool = false,

    pub fn init(allocator: std.mem.Allocator, entry_path: [:0]const u8) NodeRuntime {
        return .{
            .allocator = allocator,
            .entry_path = entry_path,
        };
    }

    /// Node.js 런타임 초기화 + JS 실행 (별도 스레드)
    pub fn start(self: *NodeRuntime) !void {
        if (self.initialized) return;

        // Node 초기화 (프로세스당 한 번)
        const argv = [_][*c]u8{@constCast("suji-node")};
        if (bridge.suji_node_init(1, @constCast(&argv)) != 0) {
            return error.NodeInitFailed;
        }
        self.initialized = true;

        // 별도 스레드에서 JS 실행
        self.thread = try std.Thread.spawn(.{}, runThread, .{self});

        // Node 핸들러 등록 완료 대기 (최대 10초)
        if (bridge.suji_node_wait_ready(10000) != 0) {
            std.debug.print("[suji-node] WARNING: ready timeout, handlers may not be registered\n", .{});
        }
        std.debug.print("[suji-node] started: {s}\n", .{self.entry_path});
    }

    fn runThread(self: *NodeRuntime) void {
        _ = bridge.suji_node_run(self.entry_path.ptr);
    }

    /// Node IPC 호출 (Zig → JS)
    pub fn invoke(channel: []const u8, data: []const u8) ?[]const u8 {
        // null-terminated 문자열이 필요하므로 스택 버퍼 시도 후 힙 폴백
        var ch_buf: [256]u8 = undefined;
        var data_buf: [8192]u8 = undefined;

        const ch_z = nullTerminateOrAlloc(channel, &ch_buf) orelse return null;
        defer if (ch_z.heap_slice) |s| std.heap.page_allocator.free(s);

        const data_z = nullTerminateOrAlloc(data, &data_buf) orelse return null;
        defer if (data_z.heap_slice) |s| std.heap.page_allocator.free(s);

        const result = bridge.suji_node_invoke(ch_z.ptr, data_z.ptr);
        if (result == null) return null;
        return std.mem.span(result);
    }

    pub const NullTermResult = struct {
        ptr: [*:0]const u8,
        heap_slice: ?[]u8, // 힙 할당 시 원본 슬라이스 (free용), 스택이면 null
    };

    pub fn nullTerminateOrAlloc(src: []const u8, buf: []u8) ?NullTermResult {
        if (src.len < buf.len) {
            @memcpy(buf[0..src.len], src);
            buf[src.len] = 0;
            return .{ .ptr = buf[0..src.len :0], .heap_slice = null };
        }
        const alloc = std.heap.page_allocator.alloc(u8, src.len + 1) catch return null;
        @memcpy(alloc[0..src.len], src);
        alloc[src.len] = 0;
        return .{ .ptr = alloc[0..src.len :0], .heap_slice = alloc };
    }

    /// Node IPC 응답 해제
    pub fn freeResponse(response: ?[]const u8) void {
        if (response) |r| {
            bridge.suji_node_free(@ptrCast(r.ptr));
        }
    }

    /// SujiCore를 Node bridge에 연결 (크로스 호출 + 이벤트)
    pub fn setCore(core: anytype) void {
        bridge.suji_node_set_core(.{
            .invoke = core.invoke,
            .free = core.free,
            .emit = core.emit,
            .on = core.on,
            .off = core.off,
            .reg = core.register,
        });
    }

    pub fn stop(self: *NodeRuntime) void {
        bridge.suji_node_stop();
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    pub fn shutdown(self: *NodeRuntime) void {
        self.stop();
        bridge.suji_node_shutdown();
        self.initialized = false;
    }
};
