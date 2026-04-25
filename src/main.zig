const std = @import("std");
const runtime = @import("runtime");
const suji = @import("root.zig");
const util = @import("util");
const cef = @import("platform/cef.zig");
const window_mod = @import("window");
const window_stack_mod = @import("window_stack");
const window_ipc = @import("window_ipc");
const logger = @import("logger");

const log = logger.module("main");
const Watcher = @import("platform/watcher.zig").Watcher;
const node_mod = @import("platform/node.zig");
const NodeRuntime = node_mod.NodeRuntime;
const node_enabled = node_mod.node_enabled;
const builtin = @import("builtin");
const bundle_macos = if (builtin.os.tag == .macos) @import("bundle_macos.zig") else struct {
    pub fn createBundle(_: anytype, _: anytype, _: anytype, _: anytype, _: anytype, _: anytype) !void {
        @panic("macOS bundle not supported on this platform");
    }
};

pub fn main(init: std.process.Init) !void {
    runtime.init(.{
        .io = init.io,
        .gpa = init.gpa,
        .environ_map = init.environ_map,
        .args_vector = init.minimal.args.vector,
    });

    // CEF 서브프로세스 처리 (렌더러/GPU 등 — 메인이면 통과)
    cef.executeSubprocess();

    const allocator = init.gpa;

    // 로거 초기화 — 서브프로세스는 logger.global=null로 두어 stderr만 사용.
    // 메인 프로세스는 `~/.suji/logs/suji-YYYYMMDD-HHMMSS-PID.log` 파일로도 기록.
    var log_file_opt: ?std.Io.File = null;
    const log_level: logger.Level = blk: {
        if (runtime.env("SUJI_LOG_LEVEL")) |v| {
            break :blk logger.Level.parse(v) catch .info;
        }
        break :blk .info;
    };
    var log_file_storage: std.Io.File = undefined;
    const setup_err: ?anyerror = if (setupLogFile(&log_file_storage)) blk: {
        log_file_opt = log_file_storage;
        break :blk null;
    } else |e| e;
    var lg = logger.Logger.init(runtime.io, .{ .level = log_level, .file = log_file_opt });
    logger.global = &lg;
    if (setup_err) |e| {
        log.warn("log file setup failed ({s}); stderr only", .{@errorName(e)});
    }
    defer {
        logger.global = null;
        if (log_file_opt) |f| f.close(runtime.io);
    }

    log.info("suji starting pid={d} log_level={s}", .{ std.c.getpid(), @tagName(log_level) });

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    // 번들에서 실행 시 자동으로 run (macOS .app / Linux AppImage)
    if (args.len < 2) {
        var exe_buf: [1024]u8 = undefined;
        if (std.process.executablePath(init.io, &exe_buf)) |n| {
            const ep = exe_buf[0..n];
            const is_bundle = switch (comptime @import("builtin").os.tag) {
                .macos => std.mem.indexOf(u8, ep, ".app/Contents/MacOS/") != null,
                else => false, // Linux/Windows: 향후 AppImage 등 감지 추가
            };
            if (is_bundle) {
                try runProd(allocator);
                return;
            }
        } else |_| {}
        printUsage();
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "init")) {
        try runInit(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "dev")) {
        try runDev(allocator);
    } else if (std.mem.eql(u8, command, "build")) {
        try runBuild(allocator);
    } else if (std.mem.eql(u8, command, "run")) {
        try runProd(allocator);
    } else {
        std.debug.print("Unknown command: {s}\n", .{command});
        printUsage();
    }
}


/// `~/.suji/logs/` 에 실행별 로그 파일 생성 + 7일 지난 오래된 로그 cleanup.
/// 실패하면 파일 출력 없이 stderr만 사용 (호출자가 error를 삼킴).
fn setupLogFile(out_file: *std.Io.File) !void {
    const home = runtime.env("HOME") orelse return error.NoHome;
    var dir_buf: [1024]u8 = undefined;
    const logs_dir_path = try logger.buildLogsDir(&dir_buf, home);
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(runtime.io, logs_dir_path) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };

    // cleanup
    {
        var logs_dir = cwd.openDir(runtime.io, logs_dir_path, .{ .iterate = true }) catch return error.DirOpen;
        defer logs_dir.close(runtime.io);
        const now_ns: i128 = std.Io.Timestamp.now(runtime.io, .real).toNanoseconds();
        logger.cleanupOldLogs(logs_dir, runtime.io, 7, now_ns) catch {};
    }

    // 파일 경로 생성
    const now_ms = std.Io.Timestamp.now(runtime.io, .real).toMilliseconds();
    var fname_buf: [128]u8 = undefined;
    var path_buf: [2048]u8 = undefined;
    var dir_buf2: [1024]u8 = undefined;
    // std.c.getpid() — POSIX에선 pid_t 반환, Windows에선 opaque stub. 플랫폼별 분기.
    const pid: i32 = if (builtin.os.tag == .windows)
        @intCast(std.os.windows.kernel32.GetCurrentProcessId())
    else
        @intCast(std.c.getpid());
    const full_path = try logger.buildLogFilePath(
        .{ .out = &path_buf, .dir = &dir_buf2, .fname = &fname_buf },
        home,
        now_ms,
        pid,
    );
    out_file.* = try cwd.createFile(runtime.io, full_path, .{});
}

fn printUsage() void {
    std.debug.print(
        \\Suji - Zig core multi-backend desktop framework
        \\
        \\Usage:
        \\  suji init <name> [--backend=rust|go|multi]  Create new project
        \\  suji dev                                     Development mode
        \\  suji build                                   Production build
        \\  suji run                                     Run production build
        \\
        \\Example:
        \\  suji init my-app --backend=rust
        \\  cd my-app && suji dev
        \\
    , .{});
}

const init_mod = @import("core/init.zig");

fn runInit(allocator: std.mem.Allocator, init_args: []const [:0]const u8) !void {
    if (init_args.len == 0) {
        std.debug.print("Usage: suji init <project-name> [--backend=rust|go|multi]\n", .{});
        return;
    }

    var name: []const u8 = "";
    var backend = init_mod.BackendLang.rust;

    for (init_args) |arg| {
        if (std.mem.startsWith(u8, arg, "--backend=")) {
            const lang_str = arg[10..];
            backend = init_mod.BackendLang.fromString(lang_str) orelse {
                std.debug.print("Unknown backend: {s}. Use: rust, go, multi\n", .{lang_str});
                return;
            };
        } else {
            name = arg;
        }
    }

    if (name.len == 0) {
        std.debug.print("Usage: suji init <project-name> [--backend=rust|go|multi]\n", .{});
        return;
    }

    try init_mod.run(allocator, .{
        .name = name,
        .backend = backend,
    });
}

// ============================================
// suji dev
// ============================================
fn runBuild(allocator: std.mem.Allocator) !void {
    var config = suji.Config.load(allocator) catch {
        std.debug.print("Error: suji.toml or suji.json not found.\n", .{});
        return;
    };
    defer config.deinit();

    std.debug.print("[suji] production build - {s}\n", .{config.app.name});

    // 백엔드 릴리스 빌드
    try buildBackendsFromConfig(allocator, &config, true);

    // 프론트엔드 빌드
    std.debug.print("[suji] building frontend...\n", .{});
    buildFrontend(allocator, config.frontend.dir) catch |err| {
        std.debug.print("[suji] frontend build failed: {}\n", .{err});
    };

    // suji 바이너리 경로
    var exe_buf: [1024]u8 = undefined;
    const exe_len = std.process.executablePath(runtime.io, &exe_buf) catch {
        std.debug.print("[suji] cannot find self executable\n", .{});
        return;
    };
    const exe_path = exe_buf[0..exe_len];

    // 번들 ID: config 또는 기본값
    const identifier = config.app.name;

    // macOS .app 번들 생성
    try bundle_macos.createBundle(
        allocator,
        config.app.name,
        config.app.version,
        identifier,
        exe_path,
        config.frontend.dist_dir,
    );
}

// ============================================
// 플러그인 빌드/로드
// ============================================

fn loadPluginsFromConfig(allocator: std.mem.Allocator, config: *const suji.Config, registry: *suji.BackendRegistry, release: bool) !void {
    const plugins = config.plugins orelse return;

    for (plugins) |plugin_name| {
        std.debug.print("[suji] loading plugin: {s}\n", .{plugin_name});

        // suji-plugin.json 읽어서 lang 결정
        const plugin_dir = getPluginDir(allocator, plugin_name) orelse {
            std.debug.print("[suji] plugin '{s}' not found\n", .{plugin_name});
            continue;
        };
        defer allocator.free(plugin_dir);

        const lang = readPluginLang(allocator, plugin_dir) orelse {
            std.debug.print("[suji] plugin '{s}': cannot read suji-plugin.json\n", .{plugin_name});
            continue;
        };
        defer allocator.free(lang);

        const entry = std.fmt.allocPrint(allocator, "{s}/{s}", .{ plugin_dir, lang }) catch continue;
        defer allocator.free(entry);

        buildBackendByLang(allocator, lang, entry, release) catch |err| {
            std.debug.print("[suji] plugin '{s}' build failed: {}\n", .{ plugin_name, err });
            continue;
        };

        const dylib_path = getDylibPath(allocator, lang, entry, release) catch continue;
        defer allocator.free(dylib_path);

        var path_z: [1024]u8 = undefined;
        const path_zt = util.nullTerminate(dylib_path, &path_z);

        registry.register(plugin_name, path_zt) catch |err| {
            std.debug.print("[suji] plugin '{s}' load failed: {}\n", .{ plugin_name, err });
        };
    }
}

/// 플러그인 디렉토리 탐색: 로컬 → suji 설치 경로 순
fn getPluginDir(allocator: std.mem.Allocator, name: []const u8) ?[]const u8 {
    // 1. 프로젝트 로컬 plugins/{name}/
    const local = std.fmt.allocPrint(allocator, "plugins/{s}", .{name}) catch return null;
    const local_json = std.fmt.allocPrint(allocator, "plugins/{s}/suji-plugin.json", .{name}) catch {
        allocator.free(local);
        return null;
    };
    defer allocator.free(local_json);
    if (std.Io.Dir.cwd().readFileAlloc(runtime.io, local_json, allocator, .limited(1024))) |content| {
        allocator.free(content);
        return local;
    } else |_| {}
    allocator.free(local);

    // 2. suji 바이너리 기준 (zig-out/bin/suji → ../../plugins/{name})
    var exe_buf: [1024]u8 = undefined;
    const exe_len = std.process.executablePath(runtime.io, &exe_buf) catch return null;
    const exe_path = exe_buf[0..exe_len];
    const bin_dir = std.fs.path.dirname(exe_path) orelse return null;
    const zig_out_dir = std.fs.path.dirname(bin_dir) orelse return null;
    const project_root = std.fs.path.dirname(zig_out_dir) orelse return null;
    const builtin_dir = std.fmt.allocPrint(allocator, "{s}/plugins/{s}", .{ project_root, name }) catch return null;
    const builtin_json = std.fmt.allocPrint(allocator, "{s}/suji-plugin.json", .{builtin_dir}) catch {
        allocator.free(builtin_dir);
        return null;
    };
    defer allocator.free(builtin_json);
    if (std.Io.Dir.cwd().readFileAlloc(runtime.io, builtin_json, allocator, .limited(1024))) |content| {
        allocator.free(content);
        return builtin_dir;
    } else |_| {}
    allocator.free(builtin_dir);

    return null;
}

/// suji-plugin.json에서 lang 읽기
fn readPluginLang(allocator: std.mem.Allocator, plugin_dir: []const u8) ?[]const u8 {
    const json_path = std.fmt.allocPrint(allocator, "{s}/suji-plugin.json", .{plugin_dir}) catch return null;
    defer allocator.free(json_path);

    const content = std.Io.Dir.cwd().readFileAlloc(runtime.io, json_path, allocator, .limited(1024 * 16)) catch return null;
    defer allocator.free(content);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return null;
    defer parsed.deinit();

    if (parsed.value != .object) return null;
    const lang_val = parsed.value.object.get("lang") orelse return null;
    if (lang_val != .string) return null;
    return allocator.dupe(u8, lang_val.string) catch null;
}

// ============================================
// 백엔드 빌드/로드
// ============================================

/// Node 런타임 글로벌 참조 (dev 모드에서 정리용)
var g_node_runtime: ?*NodeRuntime = null;

fn loadBackendsFromConfig(allocator: std.mem.Allocator, config: *const suji.Config, registry: *suji.BackendRegistry, release: bool) !void {
    if (config.isMultiBackend()) {
        if (config.backends) |backends| {
            for (backends) |be| {
                std.debug.print("[suji] building {s} ({s})...\n", .{ be.name, be.lang });
                buildBackendByLang(allocator, be.lang, be.entry, release) catch |err| {
                    std.debug.print("[suji] build failed: {}\n", .{err});
                    continue;
                };

                if (std.mem.eql(u8, be.lang, "node")) {
                    // Node 백엔드: libnode로 JS 실행
                    startNodeBackend(allocator, be.entry) catch |err| {
                        std.debug.print("[suji] node start failed for {s}: {}\n", .{ be.name, err });
                    };
                    continue;
                }

                const path = getDylibPath(allocator, be.lang, be.entry, release) catch continue;
                defer allocator.free(path);
                var path_z: [1024]u8 = undefined;
                const path_zt = util.nullTerminate(path, &path_z);
                registry.register(be.name, path_zt) catch |err| {
                    std.debug.print("[suji] load failed for {s}: {}\n", .{ be.name, err });
                };
            }
        }
    } else if (config.backend) |be| {
        std.debug.print("[suji] building {s} backend...\n", .{be.lang});
        buildBackendByLang(allocator, be.lang, be.entry, release) catch |err| {
            std.debug.print("[suji] build failed: {}\n", .{err});
            return;
        };

        if (std.mem.eql(u8, be.lang, "node")) {
            startNodeBackend(allocator, be.entry) catch |err| {
                std.debug.print("[suji] node start failed: {}\n", .{err});
            };
            return;
        }

        const path = getDylibPath(allocator, be.lang, be.entry, release) catch return;
        defer allocator.free(path);
        var path_z: [1024]u8 = undefined;
        const path_zt = util.nullTerminate(path, &path_z);
        registry.register(be.lang, path_zt) catch |err| {
            std.debug.print("[suji] load failed: {}\n", .{err});
        };
    }
}

fn startNodeBackend(allocator: std.mem.Allocator, entry: [:0]const u8) !void {
    if (!node_enabled) {
        std.debug.print("[suji] Node.js backend not available (libnode not installed)\n", .{});
        return;
    }
    // entry 경로를 절대 경로로 변환 (createRequire가 절대 경로 필요)
    const abs_entry = try std.Io.Dir.cwd().realPathFileAlloc(runtime.io, entry, allocator);
    defer allocator.free(abs_entry);
    const entry_js_str = try std.fmt.allocPrint(allocator, "{s}/main.js", .{abs_entry});
    defer allocator.free(entry_js_str);
    const entry_js = try allocator.dupeZ(u8, entry_js_str);
    // entry_js는 NodeRuntime이 소유 (해제하지 않음)

    const rt = try allocator.create(NodeRuntime);
    errdefer allocator.destroy(rt);
    rt.* = NodeRuntime.init(allocator, entry_js);

    // SujiCore 연결은 rt.start() 이전. start()가 main.js를 즉시 실행하는데,
    // main.js의 top-level `suji.on(...)`/`suji.quit()` 호출 시점에 core가 없으면
    // bridge가 exception 던짐 ("core not connected").
    if (suji.BackendRegistry.global) |g| {
        NodeRuntime.setCore(&g.core_api);
    }

    try rt.start();
    g_node_runtime = rt;

    // 임베드 런타임 테이블에 Node.js 등록. 다른 백엔드가 core.invoke("node", ...)로
    // 들어오면 BackendRegistry.coreInvoke가 이 테이블로 폴백한다.
    if (node_enabled) {
        suji.BackendRegistry.registerEmbedRuntime("node", .{
            .invoke = node_mod.bridge.suji_node_invoke,
            .free_response = node_mod.bridge.suji_node_free,
        }) catch |err| {
            std.debug.print("[suji] node embed registration failed: {}\n", .{err});
        };
    }
}

fn buildBackendsFromConfig(allocator: std.mem.Allocator, config: *const suji.Config, release: bool) !void {
    if (config.isMultiBackend()) {
        if (config.backends) |backends| {
            for (backends) |be| {
                std.debug.print("[suji] building {s} ({s})...\n", .{ be.name, be.lang });
                buildBackendByLang(allocator, be.lang, be.entry, release) catch |err| {
                    std.debug.print("[suji] build failed: {}\n", .{err});
                };
            }
        }
    } else if (config.backend) |be| {
        std.debug.print("[suji] building {s}...\n", .{be.lang});
        buildBackendByLang(allocator, be.lang, be.entry, release) catch |err| {
            std.debug.print("[suji] build failed: {}\n", .{err});
        };
    }
}

fn buildBackendByLang(allocator: std.mem.Allocator, lang: []const u8, entry: []const u8, release: bool) !void {
    if (std.mem.eql(u8, lang, "rust")) {
        const manifest = try std.fmt.allocPrint(allocator, "{s}/Cargo.toml", .{entry});
        defer allocator.free(manifest);
        if (release) {
            try runCmd(allocator, &.{ "cargo", "build", "--release", "--manifest-path", manifest });
        } else {
            try runCmd(allocator, &.{ "cargo", "build", "--manifest-path", manifest });
        }
    } else if (std.mem.eql(u8, lang, "go")) {
        const output = try std.fmt.allocPrint(allocator, "{s}/libbackend.dylib", .{entry});
        defer allocator.free(output);
        const go_entry = try std.fmt.allocPrint(allocator, "{s}/main.go", .{entry});
        defer allocator.free(go_entry);
        try runCmdEnv(allocator, &.{ "go", "build", "-buildmode=c-shared", "-o", output, go_entry }, &.{
            .{ "CC", "/usr/bin/clang" },
            .{ "CGO_ENABLED", "1" },
        });
    } else if (std.mem.eql(u8, lang, "node")) {
        // Node 백엔드: npm install (빌드 불필요, 런타임에 JS 실행)
        const pkg_path = try std.fmt.allocPrint(allocator, "{s}/package.json", .{entry});
        defer allocator.free(pkg_path);
        std.Io.Dir.cwd().access(runtime.io, pkg_path, .{}) catch return; // package.json 없으면 skip
        std.debug.print("[suji] installing npm packages...\n", .{});
        const npm_cmd = if (release) &[_][]const u8{ "npm", "install", "--prefix", entry, "--production" } else &[_][]const u8{ "npm", "install", "--prefix", entry };
        try runCmd(allocator, npm_cmd);
    } else if (std.mem.eql(u8, lang, "zig")) {
        // Zig 백엔드는 자체 build.zig가 있어야 함
        // --prefix로 빌드 결과물을 entry 디렉토리에 설치
        const prefix = try std.fmt.allocPrint(allocator, "--prefix={s}/zig-out", .{entry});
        defer allocator.free(prefix);
        // entry 디렉토리에서 zig build 실행
        const abs_entry = std.Io.Dir.cwd().realPathFileAlloc(runtime.io, entry, allocator) catch null;
        defer if (abs_entry) |p| allocator.free(p);
        var child = try std.process.spawn(runtime.io, .{
            .argv = &.{ "zig", "build" },
            .cwd = if (abs_entry) |p| .{ .path = p } else .inherit,
        });
        const result = try child.wait(runtime.io);
        switch (result) {
            .exited => |code| if (code != 0) return error.CommandFailed,
            else => return error.CommandFailed,
        }
    }
}

fn getDylibPath(allocator: std.mem.Allocator, lang: []const u8, entry: []const u8, release: bool) ![]const u8 {
    if (std.mem.eql(u8, lang, "rust")) {
        const profile: []const u8 = if (release) "release" else "debug";
        return try std.fmt.allocPrint(allocator, "{s}/target/{s}/librust_backend.dylib", .{ entry, profile });
    } else if (std.mem.eql(u8, lang, "go")) {
        return try std.fmt.allocPrint(allocator, "{s}/libbackend.dylib", .{entry});
    } else if (std.mem.eql(u8, lang, "zig")) {
        return try std.fmt.allocPrint(allocator, "{s}/zig-out/lib/libbackend.dylib", .{entry});
    }
    return error.UnsupportedLang;
}

fn runCmd(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    _ = allocator;
    var child = try std.process.spawn(runtime.io, .{ .argv = argv });
    const result = try child.wait(runtime.io);
    switch (result) {
        .exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
}

fn runCmdEnv(allocator: std.mem.Allocator, argv: []const []const u8, env_pairs: []const [2][]const u8) !void {
    // 환경 변수 설정 (부모 환경 복제 후 override)
    var env_map = if (runtime.environ_map) |m|
        try m.clone(allocator)
    else
        std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    for (env_pairs) |pair| {
        try env_map.put(pair[0], pair[1]);
    }

    var child = try std.process.spawn(runtime.io, .{
        .argv = argv,
        .environ_map = &env_map,
    });
    const result = try child.wait(runtime.io);
    switch (result) {
        .exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
}

// ============================================
// 프론트엔드
// ============================================

fn startFrontendDev(allocator: std.mem.Allocator, frontend_dir: []const u8) !std.process.Child {
    const has_bun = blk: {
        var buf: [512]u8 = undefined;
        const p = std.fmt.bufPrint(&buf, "{s}/bun.lock", .{frontend_dir}) catch break :blk false;
        std.Io.Dir.cwd().access(runtime.io, p, .{}) catch break :blk false;
        break :blk true;
    };

    _ = allocator;
    const argv: []const []const u8 = if (has_bun)
        &.{ "bun", "--cwd", frontend_dir, "dev" }
    else
        &.{ "npm", "--prefix", frontend_dir, "run", "dev" };
    return try std.process.spawn(runtime.io, .{ .argv = argv });
}

fn buildFrontend(allocator: std.mem.Allocator, frontend_dir: []const u8) !void {
    var buf: [512]u8 = undefined;
    const p = std.fmt.bufPrint(&buf, "{s}/bun.lock", .{frontend_dir}) catch return;
    const has_bun = blk: {
        std.Io.Dir.cwd().access(runtime.io, p, .{}) catch break :blk false;
        break :blk true;
    };

    if (has_bun) {
        try runCmd(allocator, &.{ "bun", "--cwd", frontend_dir, "run", "build" });
    } else {
        try runCmd(allocator, &.{ "npm", "--prefix", frontend_dir, "run", "build" });
    }
}

// ============================================
// CEF 모드
// ============================================

fn runDev(allocator: std.mem.Allocator) !void {
    var config = suji.Config.load(allocator) catch {
        std.debug.print("Error: suji.toml or suji.json not found.\n", .{});
        return;
    };
    defer config.deinit();

    std.debug.print("[suji] dev mode - {s} v{s}\n", .{ config.app.name, config.app.version });

    var registry = suji.BackendRegistry.init(allocator, runtime.io);
    defer registry.deinit();
    registry.setGlobal();
    registry.setQuitHandler(&cef.quit); // 백엔드 suji.quit()가 cef.quit()로 이어지도록
    suji.BackendRegistry.special_dispatch = backendSpecialDispatch;

    // EventBus를 백엔드 로드보다 먼저 생성해 backend_init의 on() 등록이 반영되도록.
    // (이전엔 openWindow에서 생성해 너무 늦었고 backend listener가 silent 실패)
    var event_bus = suji.EventBus.init(allocator, runtime.io);
    defer event_bus.deinit();
    registry.setEventBus(&event_bus);

    try loadPluginsFromConfig(allocator, &config, &registry, false);
    try loadBackendsFromConfig(allocator, &config, &registry, false);

    // 백엔드 핫 리로드 감시 스레드
    var watcher = Watcher.init(allocator, runtime.io);
    defer watcher.deinit();
    startBackendWatcher(allocator, &config, &watcher, &registry);

    // 프론트엔드 dev 서버
    std.debug.print("[suji] starting frontend dev server...\n", .{});
    var frontend_proc = startFrontendDev(allocator, config.frontend.dir) catch |err| {
        std.debug.print("[suji] frontend dev server failed: {}, opening without frontend\n", .{err});
        try openWindow(allocator, &config, &event_bus, .dev);
        return;
    };
    defer frontend_proc.kill(runtime.io);

    std.debug.print("[suji] waiting for {s}...\n", .{config.frontend.dev_url});
    runtime.io.sleep(.fromSeconds(2), .awake) catch {};

    try openWindow(allocator, &config, &event_bus, .dev);
}

// ============================================
// 백엔드 핫 리로드
// ============================================

/// 핫 리로드 콜백 컨텍스트
const HotReloadCtx = struct {
    var alloc: std.mem.Allocator = undefined;
    var conf: *const suji.Config = undefined;
    var reg: *suji.BackendRegistry = undefined;

    fn onFileChanged(path: []const u8) void {
        // rebuild가 스스로 수정하는 파일은 무시 — 안 그러면 feedback loop.
        // 예: Node는 `npm install`이 package-lock.json을 갱신 → watcher 재발화 → 무한 rebuild.
        if (shouldIgnore(path)) return;

        std.debug.print("[suji] file changed: {s}\n", .{path});
        // 변경된 파일이 어느 백엔드에 속하는지 찾기
        const backends = conf.backends orelse return;
        for (backends) |backend| {
            if (std.mem.indexOf(u8, path, backend.entry) != null) {
                reloadBackend(alloc, backend, reg);
                return;
            }
        }
        // 단일 백엔드
        if (conf.backend) |be| {
            if (std.mem.indexOf(u8, path, be.entry) != null) {
                reloadSingleBackend(alloc, be, reg);
            }
        }
    }

    fn shouldIgnore(path: []const u8) bool {
        const basename = std.fs.path.basename(path);
        const ignored_names = [_][]const u8{
            // Node/npm lock files — npm install이 스스로 갱신해서 feedback loop
            "package-lock.json",
            "yarn.lock",
            "pnpm-lock.yaml",
            // OS metadata
            ".DS_Store",
            "Thumbs.db",
        };
        for (ignored_names) |name| {
            if (std.mem.eql(u8, basename, name)) return true;
        }
        // 빌드 산출물 — rebuild가 생성하므로 watcher가 fire하면 feedback loop.
        // Go: cgo -buildmode=c-shared → libbackend.h (자동 생성) + libbackend.dylib
        // Rust/Zig도 dylib 경로 동일.
        const ignored_prefixes = [_][]const u8{ "libbackend.", "_cgo_" };
        for (ignored_prefixes) |p| {
            if (std.mem.startsWith(u8, basename, p)) return true;
        }
        return false;
    }
};

fn reloadBackend(allocator: std.mem.Allocator, backend: suji.Config.MultiBackend, registry: *suji.BackendRegistry) void {
    reloadBackendCommon(allocator, backend.name, backend.lang, backend.entry, registry);
}

fn reloadSingleBackend(allocator: std.mem.Allocator, backend: suji.Config.SingleBackend, registry: *suji.BackendRegistry) void {
    reloadBackendCommon(allocator, "default", backend.lang, backend.entry, registry);
}

fn reloadBackendCommon(allocator: std.mem.Allocator, name: []const u8, lang: [:0]const u8, entry: [:0]const u8, registry: *suji.BackendRegistry) void {
    std.debug.print("[suji] rebuilding {s}...\n", .{name});

    buildBackendByLang(allocator, lang, entry, false) catch |err| {
        std.debug.print("[suji] rebuild failed: {}\n", .{err});
        return;
    };

    const dylib_path = getDylibPath(allocator, lang, entry, false) catch {
        std.debug.print("[suji] dylib path not found\n", .{});
        return;
    };
    defer allocator.free(dylib_path);

    var path_buf: [1024]u8 = undefined;
    const path_z = util.nullTerminate(dylib_path, &path_buf);

    registry.reload(name, path_z) catch |err| {
        std.debug.print("[suji] reload failed: {}\n", .{err});
        return;
    };

    std.debug.print("[suji] {s} reloaded\n", .{name});
}

fn startBackendWatcher(allocator: std.mem.Allocator, config: *const suji.Config, watcher: *Watcher, registry: *suji.BackendRegistry) void {
    HotReloadCtx.alloc = allocator;
    HotReloadCtx.conf = config;
    HotReloadCtx.reg = registry;

    // 백엔드 소스 디렉토리 감시 등록
    if (config.backends) |backends| {
        for (backends) |backend| {
            watcher.addPath(backend.entry) catch |err| {
                std.debug.print("[suji] watch failed for {s}: {}\n", .{ backend.entry, err });
            };
        }
    } else if (config.backend) |be| {
        watcher.addPath(be.entry) catch |err| {
            std.debug.print("[suji] watch failed: {}\n", .{err});
        };
    }

    if (watcher.paths.items.len > 0) {
        watcher.start(&HotReloadCtx.onFileChanged) catch |err| {
            std.debug.print("[suji] watcher start failed: {}\n", .{err});
        };
        std.debug.print("[suji] watching {d} backend(s) for changes\n", .{watcher.paths.items.len});
    }
}

fn runProd(allocator: std.mem.Allocator) !void {
    var config = suji.Config.load(allocator) catch {
        std.debug.print("Error: suji.toml or suji.json not found.\n", .{});
        return;
    };
    defer config.deinit();

    std.debug.print("[suji] production mode - {s}\n", .{config.app.name});

    var registry = suji.BackendRegistry.init(allocator, runtime.io);
    defer registry.deinit();
    registry.setGlobal();
    registry.setQuitHandler(&cef.quit);
    suji.BackendRegistry.special_dispatch = backendSpecialDispatch;

    // EventBus를 백엔드 로드보다 먼저 생성 (backend_init의 on() 등록이 반영되도록).
    var event_bus = suji.EventBus.init(allocator, runtime.io);
    defer event_bus.deinit();
    registry.setEventBus(&event_bus);

    try loadPluginsFromConfig(allocator, &config, &registry, true);
    try loadBackendsFromConfig(allocator, &config, &registry, true);

    try openWindow(allocator, &config, &event_bus, .dist);
}

const WindowMode = enum { dev, dist };

fn openWindow(
    allocator: std.mem.Allocator,
    config: *const suji.Config,
    event_bus: *suji.EventBus,
    mode: WindowMode,
) !void {
    // EventBus → JS 이벤트 전달 (CEF evalJs 사용)
    event_bus.webview_eval = &cef.evalJs;

    // window:all-closed 이벤트는 WindowManager가 발화. 사용자가 자기 backend에서
    // `suji.on("window:all-closed", ...)`로 구독하고 플랫폼에 맞게 `suji.quit()`
    // 호출하는 Electron 패턴. 코어는 자동 quit하지 않음 → 사용자 코드가 주인.
    // 예시: examples/zig-backend/app.zig

    // CEF IPC 콜백 연결
    cef.setInvokeHandler(&cefInvokeHandler);
    cef.setEmitHandler(&cefEmitHandler);

    // URL 결정
    var url_buf: [2048]u8 = undefined;
    const url: ?[:0]const u8 = switch (mode) {
        .dev => config.frontend.dev_url, // dev 모드: protocol 설정 무관, 항상 HTTP dev 서버
        .dist => blk: {
            // dist 디렉토리 경로 탐색
            const dist_path = findDistPath(allocator, config.frontend.dist_dir) orelse {
                std.debug.print("[suji] frontend dist not found: {s}\n", .{config.frontend.dist_dir});
                break :blk null;
            };
            defer allocator.free(dist_path);

            // 메인(첫) 창의 protocol을 dist URL 결정 기준으로 사용. 추가 창은 명시적 url 권장.
            const url_str = switch (config.windows[0].protocol) {
                .suji => s: {
                    // suji:// 커스텀 프로토콜 (CORS/fetch/cookie/ServiceWorker 정상 동작)
                    cef.setDistPath(dist_path);
                    break :s std.fmt.bufPrint(&url_buf, "suji://app/index.html", .{}) catch break :blk null;
                },
                .file => s: {
                    break :s std.fmt.bufPrint(&url_buf, "file://{s}/index.html", .{dist_path}) catch break :blk null;
                },
            };
            url_buf[url_str.len] = 0;
            break :blk url_buf[0..url_str.len :0];
        },
    };

    if (url) |u| {
        std.debug.print("[suji] CEF URL: {s}\n", .{u});
    } else {
        std.debug.print("[suji] CEF URL: (null)\n", .{});
    }

    // CEF 초기화 (첫 창 사이즈/타이틀 사용 — CEF는 process-level 설정).
    const main_win = config.windows[0];
    const cef_config: cef.CefConfig = .{
        .title = main_win.title,
        .width = @intCast(main_win.width),
        .height = @intCast(main_win.height),
        .url = url,
        .debug = main_win.debug,
    };
    try cef.initialize(cef_config);

    // WindowManager 배선 (CefNative + EventBusSink)
    var cef_native = cef.CefNative.init(allocator);
    cef_native.registerGlobal(); // life_span_handler 콜백이 참조

    var stack: window_stack_mod.WindowStack = undefined;
    stack.init(allocator, runtime.io, cef_native.asNative(), event_bus);
    stack.setGlobal();

    // 첫 창의 default name="main" — 플러그인이 wm.fromName("main")으로 메인 창 식별 가능.
    for (config.windows, 0..) |w, i| {
        const win_name: ?[]const u8 = util.cstrOpt(w.name) orelse (if (i == 0) "main" else null);
        const win_url: ?[]const u8 = util.cstrOpt(w.url) orelse util.cstrOpt(url);
        // 부모 이름이 명시됐으면 wm에서 id 조회 (이미 만들어진 창만 — 따라서 parent는 windows[]
        // 배열 순서상 더 앞에 있어야 함). 없으면 무시.
        const parent_id: ?u32 = if (w.parent) |p_name|
            stack.manager.fromName(util.cstr(p_name))
        else
            null;

        // 음수/오버플로 clamp. config.Window.width/height는 i64로 들어오므로 여기서 변환.
        // x/y는 i32라 음수 허용 (화면 왼쪽 밖 배치 가능).
        const w_px: u32 = util.nonNegU32(w.width);
        const h_px: u32 = util.nonNegU32(w.height);
        _ = stack.manager.create(.{
            .name = win_name,
            .title = util.cstr(w.title),
            .url = win_url,
            .bounds = .{
                .x = @intCast(w.x),
                .y = @intCast(w.y),
                .width = w_px,
                .height = h_px,
            },
            .parent_id = parent_id,
            .appearance = .{
                .frame = w.frame,
                .transparent = w.transparent,
                .background_color = util.cstrOpt(w.background_color),
                .title_bar_style = w.title_bar_style,
            },
            .constraints = .{
                .resizable = w.resizable,
                .always_on_top = w.always_on_top,
                .min_width = w.min_width,
                .min_height = w.min_height,
                .max_width = w.max_width,
                .max_height = w.max_height,
                .fullscreen = w.fullscreen,
            },
        }) catch |err| {
            std.debug.print("[suji] window[{d}] create failed: {s}\n", .{ i, @errorName(err) });
            // 첫 창 실패는 fatal — 빈 앱 상태로 cef.run 진입하면 즉시 quit 돼버림.
            if (i == 0) return err;
        };
    }

    std.debug.print("[suji] CEF window opened ({s}), {d} window(s)\n", .{ if (mode == .dev) "dev" else "production", config.windows.len });
    cef.run();

    // Node runtime 종료 (별도 스레드 join). 이게 빠지면 Cmd+Q로 CEF가 quit한 뒤
    // libnode event loop가 계속 돌아 프로세스가 exit 못하고 hang한다. node::Stop이
    // isolate에 terminate 신호 보내고 run 스레드가 빠져나오면 thread.join이 완료.
    if (g_node_runtime) |rt| {
        rt.shutdown();
        allocator.destroy(rt);
        g_node_runtime = null;
    }

    // cef.shutdown() 전에 정리: user close → OnBeforeClose → wm.markClosedExternal로
    // 이미 destroyed=true 세팅된 상태. WM.deinit은 살아있는 창에만 native.destroyWindow를
    // 호출하므로 CEF가 이미 파괴한 브라우저에 재접근하는 UAF 없음.
    window_stack_mod.WindowStack.clearGlobal();
    stack.deinit();
    cef.CefNative.unregisterGlobal();
    cef_native.deinit();

    cef.shutdown();
}

/// CEF invoke 콜백 — BackendRegistry로 라우팅
fn cefInvokeHandler(channel: []const u8, data: []const u8, response_buf: []u8) ?[]const u8 {
    const registry = suji.BackendRegistry.global orelse return null;

    // 특수 채널: fanout, chain, core — 동일 dispatcher 테이블이 backend SDK 경로(coreInvoke)와
    // 공유한다. 새 channel 추가 시 SPECIAL_DISPATCHERS만 추가.
    for (SPECIAL_DISPATCHERS) |d| {
        if (std.mem.eql(u8, channel, d.channel)) return d.handler(registry, data, response_buf);
    }

    // 요청 null-terminate
    var request_buf: [8192]u8 = undefined;
    const request_len = @min(data.len, request_buf.len - 1);
    @memcpy(request_buf[0..request_len], data[0..request_len]);
    request_buf[request_len] = 0;
    const request: [*:0]const u8 = request_buf[0..request_len :0];

    // 채널 라우팅으로 백엔드 찾기 (없으면 채널명을 백엔드 이름으로 직접 시도)
    const name = registry.getBackendForChannel(channel) orelse channel;
    if (name.len == 0) return null; // 중복 채널

    // 네이티브 백엔드 (Zig/Rust/Go) 시도
    if (registry.invoke(name, request)) |resp| {
        const len = @min(resp.len, response_buf.len);
        @memcpy(response_buf[0..len], resp[0..len]);
        registry.freeResponse(name, resp);
        return response_buf[0..len];
    }

    // Node.js 백엔드 폴백 (libnode 활성화된 경우만)
    // target="node"일 때 channel="node"으로 오므로, data에서 cmd 추출
    if (node_enabled and g_node_runtime != null) {
        const node_channel = util.extractJsonString(data, "cmd") orelse channel;
        if (NodeRuntime.invoke(node_channel, data)) |resp| {
            const len = @min(resp.len, response_buf.len);
            @memcpy(response_buf[0..len], resp[0..len]);
            NodeRuntime.freeResponse(resp);
            return response_buf[0..len];
        }
    }

    return null;
}

/// fanout: 여러 백엔드에 동시 요청
fn cefHandleFanout(registry: *suji.BackendRegistry, data: []const u8, response_buf: []u8) ?[]const u8 {
    // data: {"__fanout":true,"backends":"zig,rust,go","request":"{\"cmd\":\"ping\"}"}
    // backends와 request 추출
    const backends_str = util.extractJsonString(data, "backends") orelse return null;
    const request_str = util.extractJsonString(data, "request") orelse return null;

    // request에서 이스케이프된 따옴표 복원
    var req_buf: [4096]u8 = undefined;
    const req_clean = unescapeJson(request_str, &req_buf);
    var req_nt: [4096]u8 = undefined;
    const req_len = @min(req_clean.len, req_nt.len - 1);
    @memcpy(req_nt[0..req_len], req_clean[0..req_len]);
    req_nt[req_len] = 0;

    var out_pos: usize = 0;
    const out = response_buf;
    out_pos += (std.fmt.bufPrint(out[out_pos..], "{{\"fanout\":[", .{}) catch return null).len;

    var iter = std.mem.splitScalar(u8, backends_str, ',');
    var first = true;
    while (iter.next()) |name| {
        const resp = registry.invoke(name, req_nt[0..req_len :0]);
        if (resp) |r| {
            if (!first) out_pos += (std.fmt.bufPrint(out[out_pos..], ",", .{}) catch break).len;
            out_pos += (std.fmt.bufPrint(out[out_pos..], "{s}", .{r}) catch break).len;
            first = false;
            registry.freeResponse(name, resp);
        }
    }
    out_pos += (std.fmt.bufPrint(out[out_pos..], "]}}", .{}) catch return null).len;
    return out[0..out_pos];
}

/// chain: Backend A → Core → Backend B
fn cefHandleChain(registry: *suji.BackendRegistry, data: []const u8, response_buf: []u8) ?[]const u8 {
    const from = util.extractJsonString(data, "from") orelse return null;
    const to = util.extractJsonString(data, "to") orelse return null;
    const request_escaped = util.extractJsonString(data, "request") orelse return null;
    var req_buf: [4096]u8 = undefined;
    const req_clean = unescapeJson(request_escaped, &req_buf);
    var req_nt: [4096]u8 = undefined;
    const req_len = @min(req_clean.len, req_nt.len - 1);
    @memcpy(req_nt[0..req_len], req_clean[0..req_len]);
    req_nt[req_len] = 0;

    const resp1 = registry.invoke(from, req_nt[0..req_len :0]) orelse return null;
    var r1_buf: [8192]u8 = undefined;
    const r1_len = @min(resp1.len, r1_buf.len);
    @memcpy(r1_buf[0..r1_len], resp1[0..r1_len]);
    registry.freeResponse(from, resp1);

    const resp2 = registry.invoke(to, req_nt[0..req_len :0]);
    var r2_buf: [8192]u8 = undefined;
    const r2: []const u8 = if (resp2) |r| blk: {
        const l = @min(r.len, r2_buf.len);
        @memcpy(r2_buf[0..l], r[0..l]);
        registry.freeResponse(to, resp2);
        break :blk r2_buf[0..l];
    } else "null";

    const result = std.fmt.bufPrint(response_buf, "{{\"chain\":\"{s}->{s}\",\"step1\":{s},\"step2\":{s}}}", .{ from, to, r1_buf[0..r1_len], r2 }) catch return null;
    return result;
}

/// special channel → handler 매핑. CEF cefInvokeHandler와 backend SDK 경로
/// (BackendRegistry.coreInvoke → backendSpecialDispatch) 두 곳이 공유.
/// 새 special 추가 시 여기 한 줄.
const SpecialDispatcher = struct {
    channel: []const u8,
    handler: *const fn (*suji.BackendRegistry, []const u8, []u8) ?[]const u8,
};
const SPECIAL_DISPATCHERS = [_]SpecialDispatcher{
    .{ .channel = suji.BackendRegistry.CHANNEL_CORE, .handler = cefHandleCore },
    .{ .channel = suji.BackendRegistry.CHANNEL_FANOUT, .handler = cefHandleFanout },
    .{ .channel = suji.BackendRegistry.CHANNEL_CHAIN, .handler = cefHandleChain },
};

/// 백엔드 SDK의 callBackend("__core__"|"__fanout__"|"__chain__", ...) 경로 dispatcher.
/// BackendRegistry.special_dispatch에 inject된다.
fn backendSpecialDispatch(channel: []const u8, data: []const u8, response_buf: []u8) ?[]const u8 {
    const registry = suji.BackendRegistry.global orelse return null;
    for (SPECIAL_DISPATCHERS) |d| {
        if (std.mem.eql(u8, channel, d.channel)) return d.handler(registry, data, response_buf);
    }
    return null;
}

/// core: Zig 코어 직접 호출 — 두 경로:
///   1. CEF (frontend `__suji__.core`): data = `{"__core":true,"request":"<escaped cmd JSON>"}`
///   2. Backend SDK (`callBackend("__core__", req)`): data = `<raw cmd JSON>` (backendSpecialDispatch 경유)
fn cefHandleCore(registry: *suji.BackendRegistry, data: []const u8, response_buf: []u8) ?[]const u8 {
    var req_buf: [4096]u8 = undefined;
    const req_clean: []const u8 = if (util.extractJsonString(data, "request")) |request_str|
        unescapeJson(request_str, &req_buf)
    else
        data;

    // create_window 커맨드 — WM 경유. Phase 3 옵션 풀 셋은 window_ipc에서 파싱.
    if (std.mem.indexOf(u8, req_clean, "create_window") != null) {
        const wm = window_mod.WindowManager.global orelse return null;
        return window_ipc.handleCreateWindow(
            window_ipc.parseCreateWindowFromJson(req_clean),
            response_buf,
            wm,
        );
    }

    // set_title 커맨드
    if (std.mem.indexOf(u8, req_clean, "\"cmd\":\"set_title\"") != null) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = @intCast(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleSetTitle(.{
            .window_id = win_id,
            .title = util.extractJsonString(req_clean, "title") orelse "",
        }, response_buf, wm);
    }

    // set_bounds 커맨드
    if (std.mem.indexOf(u8, req_clean, "\"cmd\":\"set_bounds\"") != null) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = @intCast(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleSetBounds(.{
            .window_id = win_id,
            .x = @intCast(util.extractJsonInt(req_clean, "x") orelse 0),
            .y = @intCast(util.extractJsonInt(req_clean, "y") orelse 0),
            .width = @intCast(util.extractJsonInt(req_clean, "width") orelse 0),
            .height = @intCast(util.extractJsonInt(req_clean, "height") orelse 0),
        }, response_buf, wm);
    }

    // ── Phase 4-A: webContents (네비/JS) ──
    if (std.mem.indexOf(u8, req_clean, "\"cmd\":\"load_url\"") != null) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleLoadUrl(.{
            .window_id = win_id,
            .url = util.extractJsonString(req_clean, "url") orelse "",
        }, response_buf, wm);
    }
    if (std.mem.indexOf(u8, req_clean, "\"cmd\":\"reload\"") != null) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleReload(.{
            .window_id = win_id,
            .ignore_cache = util.extractJsonBool(req_clean, "ignoreCache") orelse false,
        }, response_buf, wm);
    }
    if (std.mem.indexOf(u8, req_clean, "\"cmd\":\"execute_javascript\"") != null) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleExecuteJavascript(.{
            .window_id = win_id,
            .code = util.extractJsonString(req_clean, "code") orelse "",
        }, response_buf, wm);
    }
    if (std.mem.indexOf(u8, req_clean, "\"cmd\":\"get_url\"") != null) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleGetUrl(win_id, response_buf, wm);
    }
    if (std.mem.indexOf(u8, req_clean, "\"cmd\":\"is_loading\"") != null) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleIsLoading(win_id, response_buf, wm);
    }

    // ── Phase 4-C: DevTools (open/close/is/toggle) ──
    // is_dev_tools_opened를 먼저 체크 — "open_dev_tools" substring이 그 안에도 매치되므로.
    if (std.mem.indexOf(u8, req_clean, "\"cmd\":\"is_dev_tools_opened\"") != null) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleIsDevToolsOpened(win_id, response_buf, wm);
    }
    if (std.mem.indexOf(u8, req_clean, "\"cmd\":\"toggle_dev_tools\"") != null) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleToggleDevTools(win_id, response_buf, wm);
    }
    if (std.mem.indexOf(u8, req_clean, "\"cmd\":\"open_dev_tools\"") != null) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleOpenDevTools(win_id, response_buf, wm);
    }
    if (std.mem.indexOf(u8, req_clean, "\"cmd\":\"close_dev_tools\"") != null) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleCloseDevTools(win_id, response_buf, wm);
    }

    // quit 커맨드 — 프론트 `__suji__.quit()`가 라우팅됨
    if (std.mem.indexOf(u8, req_clean, "\"cmd\":\"quit\"") != null) {
        cef.quit();
        const result = std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"quit\"}}", .{}) catch return null;
        return result;
    }

    if (std.mem.indexOf(u8, req_clean, "core_info") != null) {
        var out_pos: usize = 0;
        const out = response_buf;
        out_pos += (std.fmt.bufPrint(out[out_pos..], "{{\"from\":\"zig-core\",\"backends\":[", .{}) catch return null).len;
        var it = registry.backends.iterator();
        var first = true;
        while (it.next()) |entry| {
            if (!first) out_pos += (std.fmt.bufPrint(out[out_pos..], ",", .{}) catch break).len;
            out_pos += (std.fmt.bufPrint(out[out_pos..], "\"{s}\"", .{entry.key_ptr.*}) catch break).len;
            first = false;
        }
        out_pos += (std.fmt.bufPrint(out[out_pos..], "]}}", .{}) catch return null).len;
        return out[0..out_pos];
    } else {
        const result = "{\"from\":\"zig-core\",\"msg\":\"hello from zig\"}";
        @memcpy(response_buf[0..result.len], result);
        return response_buf[0..result.len];
    }
}

// JSON 필드 추출은 core/util.zig(util.extractJsonString / util.extractJsonInt) 사용

/// JSON 이스케이프 복원: \" → ", \\ → \
fn unescapeJson(src: []const u8, buf: []u8) []const u8 {
    var i: usize = 0;
    var o: usize = 0;
    while (i < src.len and o < buf.len) {
        if (src[i] == '\\' and i + 1 < src.len) {
            buf[o] = switch (src[i + 1]) {
                '"' => '"',
                '\\' => '\\',
                'n' => '\n',
                else => src[i + 1],
            };
            i += 2;
        } else {
            buf[o] = src[i];
            i += 1;
        }
        o += 1;
    }
    return buf[0..o];
}

/// CEF emit 콜백 — EventBus로 전달. target이 있으면 해당 창만(webContents.send).
fn cefEmitHandler(target: ?u32, event: []const u8, data: []const u8) void {
    const registry = suji.BackendRegistry.global orelse return;
    const bus = registry.event_bus orelse return;
    if (target) |id| {
        bus.emitTo(id, event, data);
    } else {
        bus.emit(event, data);
    }
}

/// dist 디렉토리 절대 경로 탐색 (로컬 → .app 번들)
fn findDistPath(allocator: std.mem.Allocator, dist_dir: []const u8) ?[]const u8 {
    // 1. CWD 기준 (로컬 개발)
    if (std.Io.Dir.cwd().realPathFileAlloc(runtime.io, dist_dir, allocator)) |p| return p else |_| {}

    // 2. .app 번들: exe/../Resources/frontend/dist
    var exe_buf: [1024]u8 = undefined;
    const exe_len = std.process.executablePath(runtime.io, &exe_buf) catch return null;
    const exe_path = exe_buf[0..exe_len];
    const macos_dir = std.fs.path.dirname(exe_path) orelse return null;
    const contents_dir = std.fs.path.dirname(macos_dir) orelse return null;

    const bundle_dist = std.fmt.allocPrint(allocator, "{s}/Resources/frontend/dist", .{contents_dir}) catch return null;
    defer allocator.free(bundle_dist);
    if (std.Io.Dir.cwd().realPathFileAlloc(runtime.io, bundle_dist, allocator)) |p| return p else |_| {}

    // 3. .app 번들: Resources/frontend (dist 없이)
    const bundle_frontend = std.fmt.allocPrint(allocator, "{s}/Resources/frontend", .{contents_dir}) catch return null;
    defer allocator.free(bundle_frontend);
    if (std.Io.Dir.cwd().realPathFileAlloc(runtime.io, bundle_frontend, allocator)) |p| return p else |_| {}

    return null;
}

