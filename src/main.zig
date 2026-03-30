const std = @import("std");
const suji = @import("root.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "test")) {
        try runBackendTest(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "demo")) {
        try runDemo(allocator, args[2..]);
    } else {
        std.debug.print("Unknown command: {s}\n", .{command});
        printUsage();
    }
}

fn printUsage() void {
    std.debug.print(
        \\Suji - Zig core multi-backend desktop framework
        \\
        \\Usage:
        \\  suji demo                         Open demo window
        \\  suji demo <backend:path>...        Open demo with backends
        \\  suji test <backend:path>...        Test backend loading
        \\
        \\Example:
        \\  suji demo
        \\  suji demo rust:./librust_backend.dylib
        \\  suji test rust:./librust_backend.dylib go:./libgo_backend.dylib
        \\
    , .{});
}

/// 백엔드 로딩 테스트
fn runBackendTest(allocator: std.mem.Allocator, backend_args: []const [:0]const u8) !void {
    var registry = suji.BackendRegistry.init(allocator);
    defer registry.deinit();

    registry.setGlobal();
    loadBackends(&registry, backend_args);

    std.debug.print("\nSending ping to all backends...\n", .{});

    var iter = registry.backends.iterator();
    while (iter.next()) |entry| {
        const name = entry.key_ptr.*;
        const response = registry.invoke(name, "{\"cmd\":\"ping\"}");
        if (response) |resp| {
            std.debug.print("  {s}: {s}\n", .{ name, resp });
            registry.freeResponse(name, response);
        }
    }

    std.debug.print("\nDone.\n", .{});
}

/// 데모 윈도우
fn runDemo(allocator: std.mem.Allocator, backend_args: []const [:0]const u8) !void {
    var registry = suji.BackendRegistry.init(allocator);
    defer registry.deinit();

    registry.setGlobal();
    if (backend_args.len > 0) {
        loadBackends(&registry, backend_args);
    }

    var win = try suji.Window.create(.{
        .title = "Suji Demo",
        .width = 900,
        .height = 600,
        .debug = true,
        .html =
        \\<!DOCTYPE html>
        \\<html>
        \\<head>
        \\<style>
        \\  * { margin: 0; padding: 0; box-sizing: border-box; }
        \\  body { font-family: -apple-system, system-ui, sans-serif; padding: 24px; background: #0f0f0f; color: #e0e0e0; overflow-y: auto; }
        \\  h1 { font-size: 24px; margin-bottom: 8px; color: #fff; }
        \\  .subtitle { color: #888; margin-bottom: 20px; font-size: 14px; }
        \\  .card { background: #1a1a1a; border: 1px solid #333; border-radius: 8px; padding: 14px; margin-bottom: 10px; }
        \\  .card h3 { color: #4fc3f7; margin-bottom: 6px; font-size: 14px; }
        \\  .card p { color: #666; font-size: 12px; margin-bottom: 8px; }
        \\  button { background: #4fc3f7; color: #000; border: none; padding: 6px 12px; border-radius: 4px; cursor: pointer; margin: 3px; font-weight: 600; font-size: 12px; }
        \\  button:hover { background: #81d4fa; }
        \\  button.rust { background: #ff8a65; }
        \\  button.rust:hover { background: #ffab91; }
        \\  button.go { background: #81c784; }
        \\  button.go:hover { background: #a5d6a7; }
        \\  button.zig { background: #ce93d8; }
        \\  button.zig:hover { background: #e1bee7; }
        \\  button.chain { background: #fff176; }
        \\  button.chain:hover { background: #fff59d; }
        \\  #output { background: #111; border: 1px solid #333; border-radius: 4px; padding: 12px; margin-top: 12px; font-family: monospace; font-size: 12px; white-space: pre-wrap; max-height: 250px; overflow-y: auto; }
        \\</style>
        \\</head>
        \\<body>
        \\  <h1>Suji</h1>
        \\  <p class="subtitle">Zig core multi-backend desktop framework</p>
        \\
        \\  <div class="card">
        \\    <h3>1. Direct Call (JS -> Backend)</h3>
        \\    <p>JS에서 각 백엔드를 직접 호출</p>
        \\    <button class="rust" onclick="direct('rust','ping')">Rust ping</button>
        \\    <button class="go" onclick="direct('go','ping')">Go ping</button>
        \\    <button class="rust" onclick="direct('rust','async_work')">Rust tokio::join</button>
        \\    <button class="go" onclick="direct('go','async_work')">Go goroutines</button>
        \\    <button disabled style="opacity:0.4;cursor:default">Node (coming soon)</button>
        \\  </div>
        \\
        \\  <div class="card">
        \\    <h3>2. Chain Call (Backend A -> Zig Core -> Backend B)</h3>
        \\    <p>Go가 호출 -> Zig가 결과를 Rust에 전달 (또는 반대)</p>
        \\    <button class="chain" onclick="chain('go','rust')">Go -> Zig -> Rust</button>
        \\    <button class="chain" onclick="chain('rust','go')">Rust -> Zig -> Go</button>
        \\  </div>
        \\
        \\  <div class="card">
        \\    <h3>3. Fan-out (Zig Core -> All Backends)</h3>
        \\    <p>Zig 코어가 여러 백엔드에 동시 요청</p>
        \\    <button class="zig" onclick="fanout('rust,go','ping')">Ping All</button>
        \\    <button class="zig" onclick="fanout('rust,go','cpu_heavy')">Hash All</button>
        \\  </div>
        \\
        \\  <div class="card">
        \\    <h3>4. Zig Core Direct</h3>
        \\    <p>Zig 코어가 직접 처리하거나 백엔드에 릴레이</p>
        \\    <button class="zig" onclick="core('core_info')">Backend Info</button>
        \\    <button class="zig" onclick="coreRelay('rust')">Zig -> Rust relay</button>
        \\    <button class="zig" onclick="coreRelay('go')">Zig -> Go relay</button>
        \\  </div>
        \\
        \\  <div class="card">
        \\    <h3>5. Cross-Backend (Rust <-> Go direct call)</h3>
        \\    <p>백엔드가 Zig 코어를 통해 다른 백엔드를 직접 호출</p>
        \\    <button class="rust" onclick="direct('rust','call_go')">Rust calls Go</button>
        \\    <button class="go" onclick="direct('go','call_rust')">Go calls Rust</button>
        \\    <button class="chain" onclick="direct('rust','collab')">Rust+Go collab (hash+stats)</button>
        \\    <button class="chain" onclick="direct('go','collab')">Go+Rust collab (stats+hash)</button>
        \\  </div>
        \\
        \\  <div id="output">Ready.</div>
        \\
        \\  <script>
        \\    const S = (v) => typeof v === 'object' ? JSON.stringify(v) : v;
        \\    function log(msg) {
        \\      const el = document.getElementById('output');
        \\      el.textContent += '\n' + msg;
        \\      el.scrollTop = el.scrollHeight;
        \\    }
        \\    async function direct(backend, cmd) {
        \\      try {
        \\        const r = await __suji__.invoke(backend, JSON.stringify({cmd}));
        \\        log('[' + backend + '] ' + S(r));
        \\      } catch(e) { log('[' + backend + '] ERR: ' + S(e)); }
        \\    }
        \\    async function chain(from, to) {
        \\      try {
        \\        const r = await __suji__.chain(from, to, JSON.stringify({cmd:'process_and_relay',msg:'hello'}));
        \\        log('[' + from + '->' + to + '] ' + S(r));
        \\      } catch(e) { log('[chain] ERR: ' + S(e)); }
        \\    }
        \\    async function fanout(backends, cmd) {
        \\      try {
        \\        const r = await __suji__.fanout(backends, JSON.stringify({cmd}));
        \\        log('[fanout] ' + S(r));
        \\      } catch(e) { log('[fanout] ERR: ' + S(e)); }
        \\    }
        \\    async function core(cmd) {
        \\      try {
        \\        const r = await __suji__.core(JSON.stringify({cmd}));
        \\        log('[zig-core] ' + S(r));
        \\      } catch(e) { log('[zig-core] ERR: ' + S(e)); }
        \\    }
        \\    async function coreRelay(target) {
        \\      try {
        \\        const r = await __suji__.core(JSON.stringify({cmd:'core_relay',target,data:'from zig'}));
        \\        log('[zig->' + target + '] ' + S(r));
        \\      } catch(e) { log('[zig->' + target + '] ERR: ' + S(e)); }
        \\    }
        \\  </script>
        \\</body>
        \\</html>
        ,
    });
    defer win.destroy();

    // IPC 브릿지 바인딩 (힙 할당 — 콜백에서 self 포인터 유효해야 함)
    const bridge = try allocator.create(suji.Bridge);
    bridge.* = suji.Bridge.init(&win.webview, &registry);
    defer {
        bridge.deinit();
        allocator.destroy(bridge);
    }
    bridge.bind();

    // 콘텐츠 로드 & 실행
    win.loadContent();
    win.run();
}

/// name:path 형식의 인자로 백엔드 로드
fn loadBackends(registry: *suji.BackendRegistry, backend_args: []const [:0]const u8) void {
    for (backend_args) |arg| {
        var iter = std.mem.splitScalar(u8, arg, ':');
        const name = iter.next() orelse continue;
        const path = iter.rest();
        if (path.len == 0) {
            std.debug.print("Invalid format: {s} (expected name:path)\n", .{arg});
            continue;
        }

        std.debug.print("Loading backend '{s}' from {s}...\n", .{ name, path });
        registry.register(name, @ptrCast(path)) catch |err| {
            std.debug.print("  Failed: {}\n", .{err});
            continue;
        };
        std.debug.print("  OK\n", .{});
    }
}
