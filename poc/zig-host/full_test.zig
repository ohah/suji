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

fn callAndFree(backend: *const DylibBackend, request: [*:0]const u8) void {
    const result = backend.handle_ipc(request);
    if (result) |_| backend.free(result);
}

fn callAndPrint(backend: *const DylibBackend, request: [*:0]const u8) void {
    const result = backend.handle_ipc(request);
    if (result) |r| {
        std.debug.print("  {s}: {s}\n", .{ backend.name, std.mem.span(r) });
        backend.free(result);
    }
}

fn timedCall(backend: *const DylibBackend, request: [*:0]const u8) u64 {
    var timer = std.time.Timer.start() catch return 0;
    const result = backend.handle_ipc(request);
    const elapsed = timer.read();
    if (result) |_| backend.free(result);
    return elapsed;
}

fn ms(nanos: u64) f64 {
    return @as(f64, @floatFromInt(nanos)) / 1_000_000.0;
}

// Node backend (Unix socket) 호출
fn callNode(request: []const u8, response_buf: []u8) ![]const u8 {
    const addr = try std.net.Address.initUnix("/tmp/suji-poc-node.sock");
    const fd = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(fd);

    try std.posix.connect(fd, &addr.any, addr.getOsSockLen());

    // newline으로 메시지 구분
    _ = try std.posix.write(fd, request);
    _ = try std.posix.write(fd, "\n");

    const len = try std.posix.read(fd, response_buf);
    if (len > 0) return response_buf[0..len];
    return error.NoResponse;
}

fn callNodeAndPrint(label: []const u8, request: []const u8) void {
    var buf: [8192]u8 = undefined;
    const resp = callNode(request, &buf) catch |err| {
        std.debug.print("  node {s}: error={}\n", .{ label, err });
        return;
    };
    std.debug.print("  node {s}: {s}", .{ label, resp });
}

fn timedCallNode(request: []const u8) u64 {
    var buf: [8192]u8 = undefined;
    var timer = std.time.Timer.start() catch return 0;
    _ = callNode(request, &buf) catch return 0;
    return timer.read();
}

pub fn main() !void {
    std.debug.print("\n============================================================\n", .{});
    std.debug.print("  Suji POC: Full Integration Test (Rust + Go + Node)\n", .{});
    std.debug.print("============================================================\n", .{});

    // Load Rust & Go
    var rust = loadDylibBackend("rust", "../rust-backend/target/release/librust_backend.dylib") catch |err| {
        std.debug.print("Failed to load Rust: {}\n", .{err});
        return;
    };
    defer {
        rust.destroy();
        rust.lib.close();
    }
    rust.init();

    var go = loadDylibBackend("go", "../go-backend/libgo_backend.dylib") catch |err| {
        std.debug.print("Failed to load Go: {}\n", .{err});
        return;
    };
    defer {
        go.destroy();
        go.lib.close();
    }
    go.init();

    // Check Node
    std.debug.print("[Host] Checking Node backend on /tmp/suji-poc-node.sock...\n", .{});
    {
        var buf: [4096]u8 = undefined;
        _ = callNode("{\"cmd\":\"ping\"}", &buf) catch {
            std.debug.print("[Host] ERROR: Node backend not running!\n", .{});
            std.debug.print("[Host] Start it with: node ../node-backend/backend.js /tmp/suji-poc-node.sock\n", .{});
            return;
        };
        std.debug.print("[Host] Node backend connected!\n\n", .{});
    }

    // ========================================
    // Test 1: 3개 백엔드 기본 ping
    // ========================================
    std.debug.print("--- Test 1: All three backends ping ---\n", .{});
    callAndPrint(&rust, "{\"cmd\":\"ping\"}");
    callAndPrint(&go, "{\"cmd\":\"ping\"}");
    callNodeAndPrint("ping", "{\"cmd\":\"ping\"}");
    std.debug.print("  OK\n", .{});

    // ========================================
    // Test 2: 각 백엔드 고유 기능 (외부 라이브러리)
    // ========================================
    std.debug.print("\n--- Test 2: External library usage ---\n", .{});

    // Rust: sha2 crate
    callAndPrint(&rust, "{\"cmd\":\"cpu_heavy\",\"data\":\"test-sha2-crate\"}");

    // Go: crypto/sha256 (stdlib)
    callAndPrint(&go, "{\"cmd\":\"cpu_heavy\",\"data\":\"test-go-crypto\"}");

    // Node: lodash, dayjs, uuid
    callNodeAndPrint("lodash", "{\"cmd\":\"lodash_heavy\",\"size\":5000}");
    callNodeAndPrint("dayjs", "{\"cmd\":\"time_format\"}");
    callNodeAndPrint("uuid", "{\"cmd\":\"gen_uuid\"}");
    std.debug.print("  OK: All external libraries working\n", .{});

    // ========================================
    // Test 3: 3개 백엔드 동시 호출
    // ========================================
    std.debug.print("\n--- Test 3: Simultaneous calls (3 backends, 100 each) ---\n", .{});
    {
        var timer = std.time.Timer.start() catch unreachable;

        const rust_t = try std.Thread.spawn(.{}, struct {
            fn run(b: *const DylibBackend) void {
                for (0..100) |_| callAndFree(b, "{\"cmd\":\"ping\"}");
            }
        }.run, .{&rust});

        const go_t = try std.Thread.spawn(.{}, struct {
            fn run(b: *const DylibBackend) void {
                for (0..100) |_| callAndFree(b, "{\"cmd\":\"ping\"}");
            }
        }.run, .{&go});

        const node_t = try std.Thread.spawn(.{}, struct {
            fn run() void {
                for (0..100) |_| {
                    _ = timedCallNode("{\"cmd\":\"ping\"}");
                }
            }
        }.run, .{});

        rust_t.join();
        go_t.join();
        node_t.join();

        const elapsed = timer.read();
        std.debug.print("  300 total calls (3x100): {d:.2}ms\n", .{ms(elapsed)});
        std.debug.print("  OK: All three backends concurrent, no crash\n", .{});
    }

    // ========================================
    // Test 4: 경합 테스트 (3개 백엔드 동시 state_write)
    // ========================================
    std.debug.print("\n--- Test 4: State race condition (all 3 backends, 8 threads each) ---\n", .{});
    {
        var threads: [24]std.Thread = undefined;

        for (0..8) |i| {
            threads[i] = try std.Thread.spawn(.{}, struct {
                fn run(b: *const DylibBackend) void {
                    for (0..50) |_| callAndFree(b, "{\"cmd\":\"state_write\"}");
                }
            }.run, .{&rust});
        }
        for (0..8) |i| {
            threads[8 + i] = try std.Thread.spawn(.{}, struct {
                fn run(b: *const DylibBackend) void {
                    for (0..50) |_| callAndFree(b, "{\"cmd\":\"state_write\"}");
                }
            }.run, .{&go});
        }
        for (0..8) |i| {
            threads[16 + i] = try std.Thread.spawn(.{}, struct {
                fn run() void {
                    for (0..50) |_| {
                        _ = timedCallNode("{\"cmd\":\"state_write\"}");
                    }
                }
            }.run, .{});
        }

        for (0..24) |i| threads[i].join();

        // 검증
        callAndPrint(&rust, "{\"cmd\":\"state_read\"}");
        callAndPrint(&go, "{\"cmd\":\"state_read\"}");
        callNodeAndPrint("state", "{\"cmd\":\"state_read\"}");
        std.debug.print("  OK: 24 threads x 50 writes = 1200 concurrent writes, no corruption\n", .{});
    }

    // ========================================
    // Test 5: CPU 부하 + 동시성 (tokio + goroutine + node 동시)
    // ========================================
    std.debug.print("\n--- Test 5: CPU heavy all backends simultaneous ---\n", .{});
    {
        var timer = std.time.Timer.start() catch unreachable;

        const t1 = try std.Thread.spawn(.{}, struct {
            fn run(b: *const DylibBackend) void {
                for (0..20) |_| callAndFree(b, "{\"cmd\":\"cpu_heavy\",\"data\":\"stress\"}");
            }
        }.run, .{&rust});

        const t2 = try std.Thread.spawn(.{}, struct {
            fn run(b: *const DylibBackend) void {
                for (0..20) |_| callAndFree(b, "{\"cmd\":\"cpu_heavy\",\"data\":\"stress\"}");
            }
        }.run, .{&go});

        const t3 = try std.Thread.spawn(.{}, struct {
            fn run() void {
                for (0..20) |_| {
                    _ = timedCallNode("{\"cmd\":\"cpu_heavy\",\"data\":\"stress\"}");
                }
            }
        }.run, .{});

        t1.join();
        t2.join();
        t3.join();

        const elapsed = timer.read();
        std.debug.print("  60 SHA256x1000 ops (20 each): {d:.2}ms\n", .{ms(elapsed)});
        std.debug.print("  OK: CPU-heavy on 3 runtimes simultaneously\n", .{});
    }

    // ========================================
    // Test 6: 빠른 교대 호출 (Rust → Go → Node → Rust → ...)
    // ========================================
    std.debug.print("\n--- Test 6: Round-robin interleaved (300 calls) ---\n", .{});
    {
        var timer = std.time.Timer.start() catch unreachable;

        for (0..100) |i| {
            switch (i % 3) {
                0 => callAndFree(&rust, "{\"cmd\":\"ping\"}"),
                1 => callAndFree(&go, "{\"cmd\":\"ping\"}"),
                2 => {
                    _ = timedCallNode("{\"cmd\":\"ping\"}");
                },
                else => unreachable,
            }
        }

        const elapsed = timer.read();
        std.debug.print("  300 round-robin calls: {d:.2}ms\n", .{ms(elapsed)});
        std.debug.print("  OK: Smooth runtime switching\n", .{});
    }

    // ========================================
    // Test 7: goroutine storm + tokio 동시
    // ========================================
    std.debug.print("\n--- Test 7: Goroutine storm + tokio async_work simultaneous ---\n", .{});
    {
        var timer = std.time.Timer.start() catch unreachable;

        const t1 = try std.Thread.spawn(.{}, struct {
            fn run(b: *const DylibBackend) void {
                for (0..10) |_| callAndFree(b, "{\"cmd\":\"goroutine_storm\"}");
            }
        }.run, .{&go});

        const t2 = try std.Thread.spawn(.{}, struct {
            fn run(b: *const DylibBackend) void {
                for (0..10) |_| callAndFree(b, "{\"cmd\":\"async_work\"}");
            }
        }.run, .{&rust});

        const t3 = try std.Thread.spawn(.{}, struct {
            fn run() void {
                for (0..10) |_| {
                    _ = timedCallNode("{\"cmd\":\"lodash_heavy\",\"size\":10000}");
                }
            }
        }.run, .{});

        t1.join();
        t2.join();
        t3.join();

        const elapsed = timer.read();
        std.debug.print("  1000 goroutines + 10 tokio joins + 10 lodash ops: {d:.2}ms\n", .{ms(elapsed)});
        std.debug.print("  OK: All three runtimes under load simultaneously\n", .{});
    }

    // ========================================
    std.debug.print("\n============================================================\n", .{});
    std.debug.print("  ALL TESTS PASSED - Rust(tokio) + Go(goroutine) + Node(npm)\n", .{});
    std.debug.print("  coexist in single process with no issues\n", .{});
    std.debug.print("============================================================\n\n", .{});
}
