const std = @import("std");
const builtin = @import("builtin");

/// Node.js C 브릿지 (bridge.h)
pub const bridge = @cImport({
    @cInclude("bridge.h");
});

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

        // Node 핸들러 등록 대기 (최대 2초)
        std.Thread.sleep(2 * std.time.ns_per_s);
        std.debug.print("[suji-node] started: {s}\n", .{self.entry_path});
    }

    fn runThread(self: *NodeRuntime) void {
        _ = bridge.suji_node_run(self.entry_path.ptr);
    }

    /// Node IPC 호출 (Zig → JS)
    pub fn invoke(channel: []const u8, data: []const u8) ?[]const u8 {
        var ch_buf: [256]u8 = undefined;
        const ch_z = std.fmt.bufPrintZ(&ch_buf, "{s}", .{channel}) catch return null;
        var data_buf: [8192]u8 = undefined;
        const data_z = std.fmt.bufPrintZ(&data_buf, "{s}", .{data}) catch return null;

        const result = bridge.suji_node_invoke(ch_z.ptr, data_z.ptr);
        if (result == null) return null;
        return std.mem.span(result);
    }

    /// Node IPC 응답 해제
    pub fn freeResponse(response: ?[]const u8) void {
        if (response) |r| {
            bridge.suji_node_free(@ptrCast(r.ptr));
        }
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
