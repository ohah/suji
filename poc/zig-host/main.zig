const std = @import("std");

const BackendInitFn = *const fn () callconv(.c) void;
const BackendHandleIpcFn = *const fn ([*:0]const u8) callconv(.c) ?[*:0]u8;
const BackendFreeFn = *const fn (?[*:0]u8) callconv(.c) void;
const BackendDestroyFn = *const fn () callconv(.c) void;

const DylibBackend = struct {
    name: []const u8,
    lib: std.DynLib,
    init: BackendInitFn,
    handle_ipc: BackendHandleIpcFn,
    free: BackendFreeFn,
    destroy: BackendDestroyFn,
};

fn loadDylibBackend(name: []const u8, path: [:0]const u8) !DylibBackend {
    var lib = try std.DynLib.open(path);
    return DylibBackend{
        .name = name,
        .lib = lib,
        .init = lib.lookup(BackendInitFn, "backend_init") orelse return error.SymbolNotFound,
        .handle_ipc = lib.lookup(BackendHandleIpcFn, "backend_handle_ipc") orelse return error.SymbolNotFound,
        .free = lib.lookup(BackendFreeFn, "backend_free") orelse return error.SymbolNotFound,
        .destroy = lib.lookup(BackendDestroyFn, "backend_destroy") orelse return error.SymbolNotFound,
    };
}

fn callDylibBackend(backend: *const DylibBackend, request: [*:0]const u8) void {
    const result = backend.handle_ipc(request);
    if (result) |r| {
        const response = std.mem.span(r);
        std.debug.print("[Host] {s} responded: {s}\n", .{ backend.name, response });
        backend.free(result);
    }
}

fn callNodeBackend(request: []const u8) !void {
    const sock_path = "/tmp/suji-poc-node.sock";
    const addr = try std.net.Address.initUnix(sock_path);
    const fd = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(fd);

    try std.posix.connect(fd, &addr.any, addr.getOsSockLen());

    _ = try std.posix.write(fd, request);

    var buf: [4096]u8 = undefined;
    const len = try std.posix.read(fd, &buf);
    if (len > 0) {
        std.debug.print("[Host] node responded: {s}\n", .{buf[0..len]});
    }
}

pub fn main() !void {
    std.debug.print("\n=== Suji POC: Multi-backend in single process ===\n\n", .{});

    // 1. Load Rust backend (dlopen)
    std.debug.print("[Host] Loading Rust backend...\n", .{});
    var rust = loadDylibBackend("rust", "../rust-backend/target/release/librust_backend.dylib") catch |err| {
        std.debug.print("[Host] Failed to load Rust backend: {}\n", .{err});
        return;
    };
    defer {
        rust.destroy();
        rust.lib.close();
    }
    rust.init();

    // 2. Load Go backend (dlopen)
    std.debug.print("[Host] Loading Go backend...\n", .{});
    var go = loadDylibBackend("go", "../go-backend/libgo_backend.dylib") catch |err| {
        std.debug.print("[Host] Failed to load Go backend: {}\n", .{err});
        return;
    };
    defer {
        go.destroy();
        go.lib.close();
    }
    go.init();

    // 3. Node backend (Unix socket)
    std.debug.print("[Host] Node backend expected on /tmp/suji-poc-node.sock\n\n", .{});

    // Test: 각 백엔드에 메시지 전송
    std.debug.print("--- Sending IPC messages ---\n\n", .{});

    // Rust (tokio)
    std.debug.print("[Host] → Rust: \"hello-rust\"\n", .{});
    callDylibBackend(&rust, "hello-rust");

    // Go (goroutine)
    std.debug.print("[Host] → Go: \"hello-go\"\n", .{});
    callDylibBackend(&go, "hello-go");

    // Node (Unix socket)
    std.debug.print("[Host] → Node: \"hello-node\"\n", .{});
    callNodeBackend("hello-node") catch |err| {
        std.debug.print("[Host] Node backend not available: {} (start with: node ../node-backend/backend.js /tmp/suji-poc-node.sock)\n", .{err});
    };

    std.debug.print("\n--- Concurrent test: calling all backends 5 times each ---\n\n", .{});

    // 동시 호출 테스트 (스레드로)
    const rust_thread = try std.Thread.spawn(.{}, struct {
        fn run(b: *const DylibBackend) void {
            for (0..5) |_| {
                callDylibBackend(b, "concurrent-rust");
            }
        }
    }.run, .{&rust});

    const go_thread = try std.Thread.spawn(.{}, struct {
        fn run(b: *const DylibBackend) void {
            for (0..5) |_| {
                callDylibBackend(b, "concurrent-go");
            }
        }
    }.run, .{&go});

    rust_thread.join();
    go_thread.join();

    std.debug.print("\n=== POC Complete ===\n", .{});
}
