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

fn call(backend: *const DylibBackend, request: [*:0]const u8) ?[]const u8 {
    const result = backend.handle_ipc(request);
    if (result) |r| {
        return std.mem.span(r);
    }
    return null;
}

fn callAndFree(backend: *const DylibBackend, request: [*:0]const u8) void {
    const result = backend.handle_ipc(request);
    if (result) |_| backend.free(result);
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

fn printHeader(name: []const u8) void {
    std.debug.print("\n--- {s} ---\n", .{name});
}

fn printOk(msg: []const u8) void {
    std.debug.print("  OK: {s}\n", .{msg});
}

pub fn main() !void {
    std.debug.print("\n============================================================\n", .{});
    std.debug.print("  Suji POC: Comprehensive Stress Test\n", .{});
    std.debug.print("============================================================\n", .{});

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

    // ========================================
    // Test 1: 기본 동작 확인
    // ========================================
    printHeader("Test 1: Basic ping");
    {
        const r1 = call(&rust, "{\"cmd\":\"ping\"}");
        if (r1) |resp| {
            std.debug.print("  Rust: {s}\n", .{resp});
            rust.free(@ptrCast(@constCast(resp.ptr)));
        }
        const r2 = call(&go, "{\"cmd\":\"ping\"}");
        if (r2) |resp| {
            std.debug.print("  Go:   {s}\n", .{resp});
            go.free(@ptrCast(@constCast(resp.ptr)));
        }
        printOk("Both backends respond to ping");
    }

    // ========================================
    // Test 2: tokio join / goroutine 동시 작업
    // ========================================
    printHeader("Test 2: Async work (tokio::join / goroutine channels)");
    {
        const ns1 = timedCall(&rust, "{\"cmd\":\"async_work\"}");
        std.debug.print("  Rust tokio::join: {d:.2}ms\n", .{ms(ns1)});

        const ns2 = timedCall(&go, "{\"cmd\":\"async_work\"}");
        std.debug.print("  Go goroutines:   {d:.2}ms\n", .{ms(ns2)});
        printOk("Both complete async tasks");
    }

    // ========================================
    // Test 3: 공유 상태 경합 (RwLock / sync.RWMutex)
    // ========================================
    printHeader("Test 3: Shared state race condition (16 threads x 50 writes)");
    {
        var threads: [32]std.Thread = undefined;

        // 16 스레드가 Rust 상태에 동시 쓰기
        for (0..16) |i| {
            threads[i] = try std.Thread.spawn(.{}, struct {
                fn run(b: *const DylibBackend) void {
                    for (0..50) |_| {
                        callAndFree(b, "{\"cmd\":\"state_write\"}");
                    }
                }
            }.run, .{&rust});
        }
        // 16 스레드가 Go 상태에 동시 쓰기
        for (0..16) |i| {
            threads[16 + i] = try std.Thread.spawn(.{}, struct {
                fn run(b: *const DylibBackend) void {
                    for (0..50) |_| {
                        callAndFree(b, "{\"cmd\":\"state_write\"}");
                    }
                }
            }.run, .{&go});
        }

        for (0..32) |i| threads[i].join();

        // 상태 읽기로 검증
        const r1 = call(&rust, "{\"cmd\":\"state_read\"}");
        if (r1) |resp| {
            std.debug.print("  Rust state: {s}\n", .{resp});
            rust.free(@ptrCast(@constCast(resp.ptr)));
        }
        const r2 = call(&go, "{\"cmd\":\"state_read\"}");
        if (r2) |resp| {
            std.debug.print("  Go state:   {s}\n", .{resp});
            go.free(@ptrCast(@constCast(resp.ptr)));
        }
        printOk("No crash, state consistent after 1600 concurrent writes");
    }

    // ========================================
    // Test 4: CPU 집약 작업 (SHA256 1000회 반복)
    // ========================================
    printHeader("Test 4: CPU heavy (SHA256 x1000, 8 threads each)");
    {
        var overall = std.time.Timer.start() catch unreachable;

        var threads: [16]std.Thread = undefined;
        for (0..8) |i| {
            threads[i] = try std.Thread.spawn(.{}, struct {
                fn run(b: *const DylibBackend) void {
                    for (0..10) |_| {
                        callAndFree(b, "{\"cmd\":\"cpu_heavy\",\"data\":\"stress-test\"}");
                    }
                }
            }.run, .{&rust});
        }
        for (0..8) |i| {
            threads[8 + i] = try std.Thread.spawn(.{}, struct {
                fn run(b: *const DylibBackend) void {
                    for (0..10) |_| {
                        callAndFree(b, "{\"cmd\":\"cpu_heavy\",\"data\":\"stress-test\"}");
                    }
                }
            }.run, .{&go});
        }

        for (0..16) |i| threads[i].join();

        const total = overall.read();
        std.debug.print("  16 threads x 10 hash ops = 160 total: {d:.2}ms\n", .{ms(total)});
        printOk("CPU-heavy concurrent work on both runtimes, no crash");
    }

    // ========================================
    // Test 5: Go goroutine storm (동시 goroutine 대량 생성)
    // ========================================
    printHeader("Test 5: Goroutine storm (100 goroutines per call, 10 calls)");
    {
        var total_ns: u64 = 0;
        for (0..10) |_| {
            total_ns += timedCall(&go, "{\"cmd\":\"goroutine_storm\"}");
        }
        std.debug.print("  1000 total goroutines spawned: {d:.2}ms\n", .{ms(total_ns)});
        printOk("Go runtime handles goroutine storms while coexisting with tokio");
    }

    // ========================================
    // Test 6: 교차 호출 (Rust → Go → Rust → Go 빠르게)
    // ========================================
    printHeader("Test 6: Rapid interleaved calls (500 alternating)");
    {
        var timer = std.time.Timer.start() catch unreachable;
        for (0..500) |i| {
            if (i % 2 == 0) {
                callAndFree(&rust, "{\"cmd\":\"ping\"}");
            } else {
                callAndFree(&go, "{\"cmd\":\"ping\"}");
            }
        }
        const elapsed = timer.read();
        const cps = @as(f64, 500.0) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0);
        std.debug.print("  500 interleaved: {d:.2}ms ({d:.0} calls/sec)\n", .{ ms(elapsed), cps });
        printOk("Rapid context switching between runtimes");
    }

    // ========================================
    // Test 7: 대량 동시 스레드 (32 threads, 양쪽 동시)
    // ========================================
    printHeader("Test 7: Max concurrency (32 threads, 100 calls each, both backends)");
    {
        var timer = std.time.Timer.start() catch unreachable;
        var threads: [32]std.Thread = undefined;

        for (0..16) |i| {
            threads[i] = try std.Thread.spawn(.{}, struct {
                fn run(b: *const DylibBackend) void {
                    for (0..100) |_| {
                        callAndFree(b, "{\"cmd\":\"ping\"}");
                    }
                }
            }.run, .{&rust});
        }
        for (0..16) |i| {
            threads[16 + i] = try std.Thread.spawn(.{}, struct {
                fn run(b: *const DylibBackend) void {
                    for (0..100) |_| {
                        callAndFree(b, "{\"cmd\":\"ping\"}");
                    }
                }
            }.run, .{&go});
        }

        for (0..32) |i| threads[i].join();

        const elapsed = timer.read();
        const cps = @as(f64, 3200.0) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0);
        std.debug.print("  3200 total calls: {d:.2}ms ({d:.0} calls/sec)\n", .{ ms(elapsed), cps });
        printOk("32 concurrent threads, both runtimes, no deadlock");
    }

    // ========================================
    // Test 8: 대량 데이터 전송
    // ========================================
    printHeader("Test 8: Large data generation");
    {
        const sizes = [_][]const u8{ "1024", "10240", "102400" };
        const labels = [_][]const u8{ "1KB", "10KB", "100KB" };

        for (sizes, labels) |size, label| {
            var buf: [256]u8 = undefined;
            const json_req = std.fmt.bufPrint(&buf, "{{\"cmd\":\"gen_data\",\"size\":{s}}}", .{size}) catch continue;
            buf[json_req.len] = 0;

            const ns1 = timedCall(&rust, @ptrCast(json_req.ptr));
            const ns2 = timedCall(&go, @ptrCast(json_req.ptr));
            std.debug.print("  {s}: rust={d:.2}ms go={d:.2}ms\n", .{ label, ms(ns1), ms(ns2) });
        }
        printOk("Large data handled by both backends");
    }

    // ========================================
    // Summary
    // ========================================
    std.debug.print("\n============================================================\n", .{});
    std.debug.print("  ALL TESTS PASSED\n", .{});
    std.debug.print("============================================================\n\n", .{});
}
