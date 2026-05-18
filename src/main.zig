const std = @import("std");
const runtime = @import("runtime");
const suji = @import("root.zig");
// 호스트는 코어를 embed 경계로만 접근 (BackendRegistry/EventBus를 직접 생성하지
// 않음). embed.zig가 loader+events만 감싸 CEF 의존을 컴파일 단계에서 차단한다.
const embed = @import("embed.zig");
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
// bundle_macos 의 모든 참조(createBundle/BundleOptions/notarizeBundle/
// createDmg)가 runBuild 의 `switch (comptime builtin.os.tag) { .macos =>
// {...} }` arm 안에만 있어 비-macOS 에선 미분석 → 스텁 본문 불필요(빈
// struct). #13: 스텁 BundleOptions 중복/드리프트 원천 제거.
const bundle_macos = if (builtin.os.tag == .macos) @import("bundle_macos.zig") else struct {};
const package_desktop = @import("package_desktop.zig");

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

    log.info("suji starting pid={d} log_level={s}", .{ getCurrentPid(), @tagName(log_level) });

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
        try runBuild(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "run")) {
        try runProd(allocator);
    } else if (std.mem.eql(u8, command, "types")) {
        try runTypes(allocator, args[2..]);
    } else {
        std.debug.print("Unknown command: {s}\n", .{command});
        printUsage();
    }
}

/// 현재 프로세스 PID — POSIX는 `std.c.getpid()`, Windows는 kernel32.GetCurrentProcessId.
/// Zig 0.16 std.os.windows.kernel32에서 GetCurrentProcessId가 제거돼 extern 직접 선언.
/// std.c.getpid()는 Windows에선 opaque stub(`?*anyopaque`)이라 직접 사용 시 fmt {d} 실패.
fn getCurrentPid() i32 {
    if (builtin.os.tag == .windows) {
        const k32 = struct {
            extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) std.os.windows.DWORD;
        };
        return @intCast(k32.GetCurrentProcessId());
    }
    return @intCast(std.c.getpid());
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
    const pid: i32 = getCurrentPid();
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
        \\  suji types [--out <path>]                    Gen SujiHandlers .d.ts (zig .schema())
        \\
        \\Example:
        \\  suji init my-app --backend=rust
        \\  cd my-app && suji dev
        \\
    , .{});
}

const init_mod = @import("core/init.zig");
const proc = @import("core/proc.zig");
const release_opts = @import("core/release_opts.zig");

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
/// 플래그 우선, 없으면 env 폴백 (CI 는 secret 을 env 로 주입).
/// flagValue/hasFlag 순수 로직은 core/release_opts.zig(테스트 커버).
fn flagOrEnv(args: []const [:0]const u8, flag: []const u8, env_name: []const u8) ?[]const u8 {
    return release_opts.flagValue(args, flag) orelse runtime.env(env_name);
}

fn runBuild(allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
    var config = suji.Config.load(allocator) catch {
        std.debug.print("Error: suji.toml or suji.json not found.\n", .{});
        return;
    };
    defer config.deinit();

    std.debug.print("[suji] production build - {s}\n", .{config.app.name});

    // 서명/공증/패키징 옵션 (zero-native `--signing/--identity` 패리티).
    // 플래그 > env(CI secret) 우선. 기본 adhoc(기존 동작 유지).
    const signing = release_opts.parseSigningMode(flagOrEnv(args, "--sign", "SUJI_SIGN"));
    const identity = flagOrEnv(args, "--identity", "SUJI_SIGN_IDENTITY");
    const want_notarize = release_opts.hasFlag(args, "--notarize") or runtime.env("SUJI_NOTARIZE") != null;
    const want_dmg = release_opts.hasFlag(args, "--dmg") or runtime.env("SUJI_DMG") != null;
    // App Sandbox(MAS) vs non-sandbox(Developer ID, 기본). 기본 false 라
    // 기존 Developer ID/notarize 배포 무회귀.
    const want_sandbox = release_opts.hasFlag(args, "--sandbox") or runtime.env("SUJI_SANDBOX") != null;

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

    // OS 별 패키징 (host os 분기 — release.yml 이 네이티브 러너에서 호출).
    // builtin.os.tag 는 comptime → 매칭 arm 만 분석(비-macOS 가 bundle_macos
    // 스텁의 미존재 심볼 참조 회피).
    switch (comptime builtin.os.tag) {
        .macos => {
            const identifier = config.app.name;
            // [:0]const u8 → []const u8 변환 (BundleOptions 는 sentinel 무관).
            const locales_slice: []const []const u8 = blk: {
                if (config.app.locales.len == 0) break :blk &.{};
                var buf = allocator.alloc([]const u8, config.app.locales.len) catch break :blk &.{};
                for (config.app.locales, 0..) |s, i| buf[i] = s;
                break :blk buf;
            };
            const deep_link_slice: []const []const u8 = blk: {
                if (config.app.deep_link_schemes.len == 0) break :blk &.{};
                var buf = allocator.alloc([]const u8, config.app.deep_link_schemes.len) catch break :blk &.{};
                for (config.app.deep_link_schemes, 0..) |s, i| buf[i] = s;
                break :blk buf;
            };
            try bundle_macos.createBundle(
                allocator,
                config.app.name,
                config.app.version,
                identifier,
                exe_path,
                config.frontend.dist_dir,
                bundle_macos.BundleOptions{
                    .user_entitlements = config.app.entitlements,
                    .locales = locales_slice,
                    .strip_cef = config.app.strip_cef,
                    .signing = signing,
                    .identity = identity,
                    .sandbox = want_sandbox,
                    .deep_link_schemes = deep_link_slice,
                },
            );
            if (want_notarize) {
                bundle_macos.notarizeBundle(allocator, config.app.name, .{
                    .apple_id = runtime.env("SUJI_NOTARIZE_APPLE_ID"),
                    .team_id = runtime.env("SUJI_NOTARIZE_TEAM_ID"),
                    .password = runtime.env("SUJI_NOTARIZE_PASSWORD"),
                    .keychain_profile = runtime.env("SUJI_NOTARIZE_KEYCHAIN_PROFILE"),
                }) catch |err| {
                    std.debug.print("[suji] notarize failed: {s}\n", .{@errorName(err)});
                    return err;
                };
            }
            if (want_dmg) {
                const dmg = bundle_macos.createDmg(allocator, config.app.name, config.app.version) catch |err| {
                    std.debug.print("[suji] dmg failed: {s}\n", .{@errorName(err)});
                    return err;
                };
                allocator.free(dmg);
            }
        },
        .linux => {
            const archive = try package_desktop.packageLinux(allocator, config.app.name, config.app.version, exe_path, config.frontend.dist_dir);
            allocator.free(archive);
        },
        .windows => {
            const archive = try package_desktop.packageWindows(
                allocator,
                config.app.name,
                config.app.version,
                exe_path,
                config.frontend.dist_dir,
                runtime.env("SUJI_WIN_SIGN_CERT"),
                runtime.env("SUJI_WIN_SIGN_PASSWORD"),
            );
            allocator.free(archive);
        },
        else => std.debug.print("[suji] packaging unsupported on this OS\n", .{}),
    }
    _ = .{ signing, identity, want_notarize, want_dmg, want_sandbox }; // 비-macOS arm 미사용 해소
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

/// `suji types [--out <path>]` — zig 백엔드의 `.schema()` 체인을 SujiHandlers
/// `.d.ts` 로 자동 생성(수동 augment 불요). 빌드→dlopen→`backend_dump_schema`.
/// zig 백엔드만 — Rust=specta 수동/Go·Node=수동 augment(정직 한계, 후속).
fn dumpZigSchema(allocator: std.mem.Allocator, entry: []const u8, out: *std.ArrayList(u8)) void {
    if (builtin.os.tag == .windows) {
        std.debug.print("[suji types] Windows dlopen 경로는 후속 — macOS/Linux 사용\n", .{});
        return;
    }
    buildBackendByLang(allocator, "zig", entry, false) catch |err| {
        std.debug.print("[suji types] {s} 빌드 실패: {}\n", .{ entry, err });
        return;
    };
    const path = getDylibPath(allocator, "zig", entry, false) catch return;
    defer allocator.free(path);
    const path_z = allocator.dupeZ(u8, path) catch return;
    defer allocator.free(path_z);
    var lib = std.DynLib.open(path_z) catch |err| {
        std.debug.print("[suji types] dlopen 실패 {s}: {}\n", .{ path, err });
        return;
    };
    defer lib.close();
    const DumpFn = *const fn () callconv(.c) ?[*:0]u8;
    const dump = lib.lookup(DumpFn, "backend_dump_schema") orelse {
        std.debug.print("[suji types] backend_dump_schema 심볼 없음 (구버전 SDK?)\n", .{});
        return;
    };
    const s = dump() orelse {
        std.debug.print("[suji types] {s}: `.schema()` 미등록 — 수동 augment 폴백(docs)\n", .{entry});
        return;
    };
    out.appendSlice(allocator, std.mem.span(s)) catch {};
}

/// 백엔드 1개 → zig 면 schema dump, 아니면 정직 skip(Rust=specta 수동 등).
/// 단일/배열 config 분기에서 공용(중복 제거).
fn typesOneBackend(allocator: std.mem.Allocator, lang: []const u8, entry: []const u8, out: *std.ArrayList(u8)) void {
    if (std.mem.eql(u8, lang, "zig")) {
        dumpZigSchema(allocator, entry, out);
    } else {
        std.debug.print("[suji types] {s} 백엔드 schema 추출 미지원 — 수동 augment(Rust=specta)\n", .{lang});
    }
}

fn runTypes(allocator: std.mem.Allocator, types_args: []const [:0]const u8) !void {
    var out_path: ?[]const u8 = null;
    var i: usize = 0;
    while (i < types_args.len) : (i += 1) {
        if (std.mem.eql(u8, types_args[i], "--out") and i + 1 < types_args.len) {
            out_path = types_args[i + 1];
            i += 1;
        }
    }

    var config = suji.Config.load(allocator) catch {
        std.debug.print("Error: suji.json not found (프로젝트 루트에서 실행).\n", .{});
        return;
    };
    defer config.deinit();

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    if (config.backends) |backends| {
        for (backends) |be| typesOneBackend(allocator, be.lang, be.entry, &out);
    } else if (config.backend) |be| {
        typesOneBackend(allocator, be.lang, be.entry, &out);
    }

    if (out.items.len == 0) {
        std.debug.print("[suji types] 생성할 schema 없음 (zig 백엔드 + `.schema()` 필요).\n", .{});
        return;
    }
    // 생성된 .d.ts 는 stdout(`suji types > suji.d.ts`) 또는 --out 파일.
    // 진단/빌드로그는 std.debug.print=stderr 라 .d.ts 와 안 섞임. Zig 0.16
    // std.fs.File/posix.write 부재 → 코드베이스 std.Io 경로 재사용(stdout 은
    // `/dev/stdout` 특수파일, Windows 는 dumpZigSchema 가 이미 차단).
    const target = out_path orelse "/dev/stdout";
    const f = std.Io.Dir.cwd().createFile(runtime.io, target, .{}) catch |err| {
        std.debug.print("[suji types] {s} 쓰기 실패: {}\n", .{ target, err });
        return;
    };
    defer f.close(runtime.io);
    var wbuf: [4096]u8 = undefined;
    var fw = f.writer(runtime.io, &wbuf);
    fw.interface.writeAll(out.items) catch return;
    fw.interface.flush() catch return;
    if (out_path) |p| std.debug.print("[suji types] → {s} ({d} bytes)\n", .{ p, out.items.len });
}

fn runCmd(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    _ = allocator;
    try proc.run(argv);
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
    setGlobalConfig(&config);

    std.debug.print("[suji] dev mode - {s} v{s}\n", .{ config.app.name, config.app.version });

    try embed.init(allocator, runtime.io);
    defer embed.deinit();
    const registry = embed.registry(); // *BackendRegistry — setGlobal은 embed.init이 수행
    registry.setQuitHandler(&cef.quit); // 백엔드 suji.quit()가 cef.quit()로 이어지도록
    suji.BackendRegistry.special_dispatch = backendSpecialDispatch;
    cef.setTrayEmitHandler(&trayEmitHandler);
    cef.setNotificationEmitHandler(&notificationEmitHandler);
    cef.setMenuEmitHandler(&menuEmitHandler);
    cef.setGlobalShortcutEmitHandler(&globalShortcutEmitHandler);
    cef.powerMonitorInstall(&powerMonitorEmitHandler);
    cef.nativeThemeInstall(&nativeThemeEmitHandler);
    cef.setWebRequestEmitHandler(&webRequestEmitHandler);
    cef.setWindowLifecycleHandlers(window_lifecycle_handlers);
    cef.setWindowDisplayHandlers(.{
        .ready_to_show = &windowReadyToShowHandler,
        .title_change = &windowTitleChangeHandler,
        .find_result = &windowFindResultHandler,
    });
    // CSP — 사용자 명시 csp 우선, 미명시 시 default CSP를 iframe_allowed_origins로 빌드.
    if (config.security.csp) |csp_val| {
        cef.setCspValue(csp_val);
    } else blk: {
        const origins_slice = allocator.alloc([]const u8, config.security.iframe_allowed_origins.len) catch break :blk;
        for (config.security.iframe_allowed_origins, 0..) |s, i| origins_slice[i] = s;
        const csp = cef.buildDefaultCsp(allocator, origins_slice) catch break :blk;
        cef.setCspValue(csp);
    }

    // setEventBus는 backend 로드보다 먼저여야 backend_init의 on() 등록이 반영됨 —
    // embed.init이 이 순서를 보장.
    const event_bus = embed.eventBus();

    try loadPluginsFromConfig(allocator, &config, registry, false);
    try loadBackendsFromConfig(allocator, &config, registry, false);

    // 백엔드 핫 리로드 감시 스레드
    var watcher = Watcher.init(allocator, runtime.io);
    defer watcher.deinit();
    startBackendWatcher(allocator, &config, &watcher, registry);

    // 프론트엔드 dev 서버
    std.debug.print("[suji] starting frontend dev server...\n", .{});
    var frontend_proc = startFrontendDev(allocator, config.frontend.dir) catch |err| {
        std.debug.print("[suji] frontend dev server failed: {}, opening without frontend\n", .{err});
        try openWindow(allocator, &config, event_bus, .dev);
        return;
    };
    defer frontend_proc.kill(runtime.io);

    std.debug.print("[suji] waiting for {s}...\n", .{config.frontend.dev_url});
    runtime.io.sleep(.fromSeconds(2), .awake) catch {};

    try openWindow(allocator, &config, event_bus, .dev);
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
    setGlobalConfig(&config);

    std.debug.print("[suji] production mode - {s}\n", .{config.app.name});

    try embed.init(allocator, runtime.io);
    defer embed.deinit();
    const registry = embed.registry(); // *BackendRegistry — setGlobal은 embed.init이 수행
    registry.setQuitHandler(&cef.quit);
    suji.BackendRegistry.special_dispatch = backendSpecialDispatch;
    cef.setTrayEmitHandler(&trayEmitHandler);
    cef.setNotificationEmitHandler(&notificationEmitHandler);
    cef.setMenuEmitHandler(&menuEmitHandler);
    cef.setGlobalShortcutEmitHandler(&globalShortcutEmitHandler);
    cef.powerMonitorInstall(&powerMonitorEmitHandler);
    cef.nativeThemeInstall(&nativeThemeEmitHandler);
    cef.setWebRequestEmitHandler(&webRequestEmitHandler);
    cef.setWindowLifecycleHandlers(window_lifecycle_handlers);
    cef.setWindowDisplayHandlers(.{
        .ready_to_show = &windowReadyToShowHandler,
        .title_change = &windowTitleChangeHandler,
        .find_result = &windowFindResultHandler,
    });
    // CSP — 사용자 명시 csp 우선, 미명시 시 default CSP를 iframe_allowed_origins로 빌드.
    if (config.security.csp) |csp_val| {
        cef.setCspValue(csp_val);
    } else blk: {
        const origins_slice = allocator.alloc([]const u8, config.security.iframe_allowed_origins.len) catch break :blk;
        for (config.security.iframe_allowed_origins, 0..) |s, i| origins_slice[i] = s;
        const csp = cef.buildDefaultCsp(allocator, origins_slice) catch break :blk;
        cef.setCspValue(csp);
    }

    // setEventBus는 backend 로드보다 먼저여야 backend_init의 on() 등록이 반영됨 —
    // embed.init이 이 순서를 보장.
    const event_bus = embed.eventBus();

    try loadPluginsFromConfig(allocator, &config, registry, true);
    try loadBackendsFromConfig(allocator, &config, registry, true);

    try openWindow(allocator, &config, event_bus, .dist);
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

    // window:all-closed 이벤트는 WindowManager가 발화. 기본은 사용자 backend가 직접
    // `suji.on("window:all-closed", ...)`로 구독하고 platform 분기 후 `suji.quit()` 호출
    // (Electron canonical 패턴). `app.quitOnAllWindowsClosed: true`면 코어가 자동 quit —
    // user code 호출과 동시 발화해도 cef.quit()이 idempotent라 race 없음.
    if (config.app.quit_on_all_windows_closed) {
        _ = event_bus.onC(window_mod.events.all_closed, &allClosedAutoQuit, null);
    }

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
        .app_name = config.app.name,
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
    // Backend SDK가 호출한 흐름이라 fs sandbox 등 frontend-only 검증을 우회.
    g_in_backend_invoke = true;
    defer g_in_backend_invoke = false;
    for (SPECIAL_DISPATCHERS) |d| {
        if (std.mem.eql(u8, channel, d.channel)) return d.handler(registry, data, response_buf);
    }
    return null;
}

/// core: Zig 코어 직접 호출 — 두 경로:
///   1. CEF (frontend `__suji__.core`): data = `{"__core":true,"request":"<escaped cmd JSON>"}`
///   2. Backend SDK (`callBackend("__core__", req)`): data = `<raw cmd JSON>` (backendSpecialDispatch 경유)
///
/// cmd 분기는 `extractJsonString(req, "cmd")`로 정확 매치 — substring 매치는 새 cmd가
/// 비슷한 이름으로 추가되거나 cmd 외 다른 필드에 같은 문자열이 있을 때 잘못 라우팅 위험.
/// `__core__` IPC payload 한계. clipboard write 등 큰 payload 수용 (이전 4KB는 8KB
/// 클립보드 쓰기에서 잘려 응답 비었음). 두 곳에서 같은 값 사용 (response check + req_buf).
const MAX_CORE_PAYLOAD: usize = 32 * 1024;

/// `{"from":"zig-core","cmd":<cmd>,"success":bool}` 응답 빌드 — write/setter류 cmd 공통.
fn respondSuccess(response_buf: []u8, cmd: []const u8, ok: bool) ?[]const u8 {
    return std.fmt.bufPrint(
        response_buf,
        "{{\"from\":\"zig-core\",\"cmd\":\"{s}\",\"success\":{}}}",
        .{ cmd, ok },
    ) catch null;
}

/// raw bytes를 base64로 인코딩해 `{"from":"zig-core","cmd":<cmd>,"data":"<b64>"}` 응답을 빌드.
/// b64 한도(12KB) 초과 시 빈 data 반환 — clipboard_read_image / native_image_to_png/jpeg 공유.
fn respondBase64Data(response_buf: []u8, cmd: []const u8, raw_bytes: []const u8) ?[]const u8 {
    const enc_size = std.base64.standard.Encoder.calcSize(raw_bytes.len);
    var b64_buf: [12 * 1024]u8 = undefined;
    if (enc_size > b64_buf.len) {
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"{s}\",\"data\":\"\"}}", .{cmd}) catch null;
    }
    const encoded = std.base64.standard.Encoder.encode(b64_buf[0..enc_size], raw_bytes);
    return std.fmt.bufPrint(
        response_buf,
        "{{\"from\":\"zig-core\",\"cmd\":\"{s}\",\"data\":\"{s}\"}}",
        .{ cmd, encoded },
    ) catch null;
}

fn cefHandleCore(registry: *suji.BackendRegistry, data: []const u8, response_buf: []u8) ?[]const u8 {
    if (data.len > MAX_CORE_PAYLOAD) return coreError(response_buf, "__core__", "payload_too_large");
    var req_buf: [MAX_CORE_PAYLOAD]u8 = undefined;
    const req_clean: []const u8 = if (util.extractJsonString(data, "request")) |request_str|
        unescapeJson(request_str, &req_buf)
    else
        data;

    const cmd = util.extractJsonString(req_clean, "cmd") orelse "";
    if (cmd.len == 0) return coreError(response_buf, "__core__", "missing_cmd");
    // IPC injection (newline/quote 등) 차단 — char allowlist는 util.isValidCmdName 단위 테스트로.
    if (!util.isValidCmdName(cmd)) return coreError(response_buf, "__core__", "invalid_cmd");

    if (std.mem.eql(u8, cmd, "create_window")) {
        const wm = window_mod.WindowManager.global orelse return null;
        return window_ipc.handleCreateWindow(
            window_ipc.parseCreateWindowFromJson(req_clean),
            response_buf,
            wm,
        );
    }
    if (std.mem.eql(u8, cmd, "destroy_window")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleDestroyWindow(win_id, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "set_title")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = @intCast(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleSetTitle(.{
            .window_id = win_id,
            .title = util.extractJsonString(req_clean, "title") orelse "",
        }, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "set_bounds")) {
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
    // Phase 4-A: webContents (네비/JS)
    if (std.mem.eql(u8, cmd, "load_url")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleLoadUrl(.{
            .window_id = win_id,
            .url = util.extractJsonString(req_clean, "url") orelse "",
        }, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "reload")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleReload(.{
            .window_id = win_id,
            .ignore_cache = util.extractJsonBool(req_clean, "ignoreCache") orelse false,
        }, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "execute_javascript")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleExecuteJavascript(.{
            .window_id = win_id,
            .code = util.extractJsonString(req_clean, "code") orelse "",
        }, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "get_url")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleGetUrl(win_id, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "set_user_agent")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleSetUserAgent(win_id, util.extractJsonString(req_clean, "userAgent") orelse "", response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "get_user_agent")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleGetUserAgent(win_id, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "is_loading")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleIsLoading(win_id, response_buf, wm);
    }
    // Phase 4-C: DevTools — 정확 매치라 4-A의 substring 회귀 가드(is_dev_tools_opened
    // 우선 검사)도 불필요해짐.
    if (std.mem.eql(u8, cmd, "open_dev_tools")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleOpenDevTools(win_id, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "close_dev_tools")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleCloseDevTools(win_id, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "is_dev_tools_opened")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleIsDevToolsOpened(win_id, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "toggle_dev_tools")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleToggleDevTools(win_id, response_buf, wm);
    }
    // Phase 4-B: 줌
    if (std.mem.eql(u8, cmd, "set_zoom_level")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        const level = util.extractJsonFloat(req_clean, "level") orelse 0;
        return window_ipc.handleSetZoomLevel(.{ .window_id = win_id, .value = level }, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "set_zoom_factor")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        const factor = util.extractJsonFloat(req_clean, "factor") orelse 1;
        return window_ipc.handleSetZoomFactor(.{ .window_id = win_id, .value = factor }, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "get_zoom_level")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleGetZoomLevel(win_id, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "get_zoom_factor")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleGetZoomFactor(win_id, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "set_audio_muted")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        const muted = util.extractJsonBool(req_clean, "muted") orelse false;
        return window_ipc.handleSetAudioMuted(win_id, muted, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "is_audio_muted")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleIsAudioMuted(win_id, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "set_opacity")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        const opacity = util.extractJsonFloat(req_clean, "opacity") orelse 1;
        return window_ipc.handleSetOpacity(.{ .window_id = win_id, .value = opacity }, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "get_opacity")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleGetOpacity(win_id, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "set_background_color")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        const raw_hex = util.extractJsonString(req_clean, "color") orelse "";
        var hex_buf: [32]u8 = undefined;
        const hex_n = util.unescapeJsonStr(raw_hex, &hex_buf) orelse 0;
        return window_ipc.handleSetBackgroundColor(win_id, hex_buf[0..hex_n], response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "set_has_shadow")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        const has = util.extractJsonBool(req_clean, "hasShadow") orelse true;
        return window_ipc.handleSetHasShadow(win_id, has, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "has_shadow")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleHasShadow(win_id, response_buf, wm);
    }
    // Phase 4-E: 편집 (6 trivial) + 검색
    inline for (.{
        .{ "undo", &window_ipc.handleUndo },
        .{ "redo", &window_ipc.handleRedo },
        .{ "cut", &window_ipc.handleCut },
        .{ "copy", &window_ipc.handleCopy },
        .{ "paste", &window_ipc.handlePaste },
        .{ "select_all", &window_ipc.handleSelectAll },
    }) |entry| {
        if (std.mem.eql(u8, cmd, entry[0])) {
            const wm = window_mod.WindowManager.global orelse return null;
            const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
            return entry[1](win_id, response_buf, wm);
        }
    }
    if (std.mem.eql(u8, cmd, "find_in_page")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleFindInPage(.{
            .window_id = win_id,
            .text = util.extractJsonString(req_clean, "text") orelse "",
            .forward = util.extractJsonBool(req_clean, "forward") orelse true,
            .match_case = util.extractJsonBool(req_clean, "matchCase") orelse false,
            .find_next = util.extractJsonBool(req_clean, "findNext") orelse false,
        }, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "stop_find_in_page")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        const clear = util.extractJsonBool(req_clean, "clearSelection") orelse false;
        return window_ipc.handleStopFindInPage(win_id, clear, response_buf, wm);
    }
    // Phase 4-D: 인쇄 — 결과는 `window:pdf-print-finished` 이벤트로 분리.
    if (std.mem.eql(u8, cmd, "print_to_pdf")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handlePrintToPDF(.{
            .window_id = win_id,
            .path = util.extractJsonString(req_clean, "path") orelse "",
        }, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "capture_page")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        // clipWidth/clipHeight 둘 다 양수일 때만 부분 캡처(Electron rect). 아니면
        // 전체. CaptureClip 은 f64 (CDP clip 은 fractional CSS px 허용) →
        // extractJsonFloat 재사용(JS/Node rect 소수 정밀도 보존).
        const cw = util.extractJsonFloat(req_clean, "clipWidth");
        const ch = util.extractJsonFloat(req_clean, "clipHeight");
        const clip: ?window_mod.CaptureClip = if (cw != null and ch != null and cw.? > 0 and ch.? > 0)
            .{
                .x = util.extractJsonFloat(req_clean, "clipX") orelse 0,
                .y = util.extractJsonFloat(req_clean, "clipY") orelse 0,
                .width = cw.?,
                .height = ch.?,
            }
        else
            null;
        return window_ipc.handleCapturePage(.{
            .window_id = win_id,
            .path = util.extractJsonString(req_clean, "path") orelse "",
            .clip = clip,
        }, response_buf, wm);
    }
    // Phase 17-A: WebContentsView (createView / addChildView / setTopView / ...)
    if (std.mem.eql(u8, cmd, "create_view")) {
        const wm = window_mod.WindowManager.global orelse return null;
        return window_ipc.handleCreateView(window_ipc.parseCreateViewFromJson(req_clean), response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "destroy_view")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const view_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "viewId") orelse return null);
        return window_ipc.handleDestroyView(view_id, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "add_child_view")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const host_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "hostId") orelse return null);
        const view_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "viewId") orelse return null);
        return window_ipc.handleAddChildView(.{
            .host_id = host_id,
            .view_id = view_id,
            .index = util.extractNonNegUsize(req_clean, "index"),
        }, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "remove_child_view")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const host_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "hostId") orelse return null);
        const view_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "viewId") orelse return null);
        return window_ipc.handleRemoveChildView(host_id, view_id, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "set_top_view")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const host_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "hostId") orelse return null);
        const view_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "viewId") orelse return null);
        return window_ipc.handleSetTopView(host_id, view_id, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "set_view_bounds")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const view_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "viewId") orelse return null);
        const b = window_ipc.parseBoundsFromJson(req_clean);
        return window_ipc.handleSetViewBounds(.{
            .view_id = view_id,
            .x = b.x,
            .y = b.y,
            .width = b.width,
            .height = b.height,
        }, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "set_view_visible")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const view_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "viewId") orelse return null);
        const visible = util.extractJsonBool(req_clean, "visible") orelse true;
        return window_ipc.handleSetViewVisible(view_id, visible, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "get_child_views")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const host_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "hostId") orelse return null);
        // viewIds 임시 u32 슬라이스 — registry.allocator(힙). 고정 스택 arena는 view 수
        // 상한(4KB→~1024)을 만들고 초과 시 getChildViews OOM→오인 `ok:false,viewIds:[]`로
        // 절단됐다. handleGetChildViews가 직후 `defer allocator.free(ids)`로 즉시 반납.
        return window_ipc.handleGetChildViews(host_id, response_buf, wm, registry.allocator);
    }
    // Phase 5: 라이프사이클 제어 — minimize/maximize/restore_window/unmaximize 4 voidFn
    // + is_minimized/is_maximized/is_fullscreen 3 게터. 모두 (windowId, buf, wm) 시그니처라
    // 4-E 편집 핸들러와 동일한 dispatch 테이블. set_fullscreen만 flag 인자로 별도 분기.
    if (std.mem.eql(u8, cmd, "set_fullscreen")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        const flag = util.extractJsonBool(req_clean, "flag") orelse false;
        return window_ipc.handleSetFullscreen(.{ .window_id = win_id, .flag = flag }, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "set_visible")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        // 누락 시 false — set_fullscreen과 일관성 (필드 명시 안 하면 안 변경 의도로 해석).
        const visible = util.extractJsonBool(req_clean, "visible") orelse false;
        return window_ipc.handleSetVisible(.{ .window_id = win_id, .visible = visible }, response_buf, wm);
    }
    inline for (.{
        .{ "minimize", &window_ipc.handleMinimize },
        .{ "restore_window", &window_ipc.handleRestoreWindow },
        .{ "maximize", &window_ipc.handleMaximize },
        .{ "unmaximize", &window_ipc.handleUnmaximize },
        .{ "is_minimized", &window_ipc.handleIsMinimized },
        .{ "is_maximized", &window_ipc.handleIsMaximized },
        .{ "is_fullscreen", &window_ipc.handleIsFullscreen },
    }) |entry| {
        if (std.mem.eql(u8, cmd, entry[0])) {
            const wm = window_mod.WindowManager.global orelse return null;
            const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
            return entry[1](win_id, response_buf, wm);
        }
    }
    if (std.mem.eql(u8, cmd, "quit")) {
        cef.quit();
        const result = std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"quit\"}}", .{}) catch return null;
        return result;
    }

    // Clipboard API — NSPasteboard plain text.
    if (std.mem.eql(u8, cmd, "clipboard_read_text")) {
        var raw_buf: [util.MAX_RESPONSE]u8 = undefined;
        const text = cef.clipboardReadText(&raw_buf);
        var esc_buf: [util.MAX_RESPONSE]u8 = undefined;
        const esc_len = util.escapeJsonStrFull(text, &esc_buf) orelse return null;
        const result = std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"clipboard_read_text\",\"text\":\"{s}\"}}",
            .{esc_buf[0..esc_len]},
        ) catch return null;
        return result;
    }
    if (std.mem.eql(u8, cmd, "clipboard_write_text")) {
        const raw = util.extractJsonString(req_clean, "text") orelse "";
        var unesc_buf: [util.MAX_RESPONSE]u8 = undefined;
        // 한도 초과면 graceful false (caller가 boolean 응답 기대 — null 반환은 raw string으로
        // 떨어져 r.success undefined 됨).
        const ok = if (util.unescapeJsonStr(raw, &unesc_buf)) |unesc_len|
            cef.clipboardWriteText(unesc_buf[0..unesc_len])
        else
            false;
        const result = std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"clipboard_write_text\",\"success\":{}}}",
            .{ok},
        ) catch return null;
        return result;
    }
    if (std.mem.eql(u8, cmd, "clipboard_clear")) {
        cef.clipboardClear();
        const result = std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"clipboard_clear\",\"success\":true}}", .{}) catch return null;
        return result;
    }
    if (std.mem.eql(u8, cmd, "clipboard_read_html")) {
        var raw_buf: [util.MAX_RESPONSE]u8 = undefined;
        const html = cef.clipboardReadHtml(&raw_buf);
        var esc_buf: [util.MAX_RESPONSE]u8 = undefined;
        const esc_len = util.escapeJsonStrFull(html, &esc_buf) orelse return null;
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"clipboard_read_html\",\"html\":\"{s}\"}}",
            .{esc_buf[0..esc_len]},
        ) catch null;
    }
    if (std.mem.eql(u8, cmd, "clipboard_write_html")) {
        const raw = util.extractJsonString(req_clean, "html") orelse "";
        var unesc_buf: [util.MAX_RESPONSE]u8 = undefined;
        const ok = if (util.unescapeJsonStr(raw, &unesc_buf)) |unesc_len|
            cef.clipboardWriteHtml(unesc_buf[0..unesc_len])
        else
            false;
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"clipboard_write_html\",\"success\":{}}}",
            .{ok},
        ) catch null;
    }
    if (std.mem.eql(u8, cmd, "clipboard_read_rtf")) {
        var raw_buf: [util.MAX_RESPONSE]u8 = undefined;
        const rtf = cef.clipboardReadRtf(&raw_buf);
        var esc_buf: [util.MAX_RESPONSE]u8 = undefined;
        const esc_len = util.escapeJsonStrFull(rtf, &esc_buf) orelse return null;
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"clipboard_read_rtf\",\"rtf\":\"{s}\"}}",
            .{esc_buf[0..esc_len]},
        ) catch null;
    }
    if (std.mem.eql(u8, cmd, "clipboard_write_rtf")) {
        const raw = util.extractJsonString(req_clean, "rtf") orelse "";
        var unesc_buf: [util.MAX_RESPONSE]u8 = undefined;
        const ok = if (util.unescapeJsonStr(raw, &unesc_buf)) |unesc_len|
            cef.clipboardWriteRtf(unesc_buf[0..unesc_len])
        else
            false;
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"clipboard_write_rtf\",\"success\":{}}}",
            .{ok},
        ) catch null;
    }
    // clipboard buffer (raw bytes for arbitrary UTI). raw 한도 ~8KB (image와 동일 IPC 제약).
    if (std.mem.eql(u8, cmd, "clipboard_write_buffer")) {
        const raw_type = util.extractJsonString(req_clean, "format") orelse "";
        var type_buf: [256]u8 = undefined;
        const type_n = util.unescapeJsonStr(raw_type, &type_buf) orelse 0;
        if (type_n == 0) return respondSuccess(response_buf, cmd, false);
        const b64_raw = util.extractJsonString(req_clean, "data") orelse "";
        var b64_buf: [util.MAX_RESPONSE]u8 = undefined;
        const b64_n = util.unescapeJsonStr(b64_raw, &b64_buf) orelse 0;
        if (b64_n == 0) return respondSuccess(response_buf, cmd, false);
        var raw_buf: [8 * 1024]u8 = undefined;
        const decoded_size = std.base64.standard.Decoder.calcSizeForSlice(b64_buf[0..b64_n]) catch
            return respondSuccess(response_buf, cmd, false);
        if (decoded_size > raw_buf.len) return respondSuccess(response_buf, cmd, false);
        std.base64.standard.Decoder.decode(raw_buf[0..decoded_size], b64_buf[0..b64_n]) catch
            return respondSuccess(response_buf, cmd, false);
        const ok = cef.clipboardWriteBuffer(raw_buf[0..decoded_size], type_buf[0..type_n]);
        return respondSuccess(response_buf, cmd, ok);
    }
    if (std.mem.eql(u8, cmd, "clipboard_read_buffer")) {
        const raw_type = util.extractJsonString(req_clean, "format") orelse "";
        var type_buf: [256]u8 = undefined;
        const type_n = util.unescapeJsonStr(raw_type, &type_buf) orelse 0;
        var raw_buf: [8 * 1024]u8 = undefined;
        const bytes = cef.clipboardReadBuffer(&raw_buf, type_buf[0..type_n]);
        return respondBase64Data(response_buf, "clipboard_read_buffer", bytes);
    }
    if (std.mem.eql(u8, cmd, "power_monitor_get_idle_time")) {
        const seconds = cef.powerMonitorIdleSeconds();
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"power_monitor_get_idle_time\",\"seconds\":{d}}}",
            .{seconds},
        ) catch null;
    }
    if (std.mem.eql(u8, cmd, "power_monitor_get_idle_state")) {
        const threshold = util.extractJsonInt(req_clean, "threshold") orelse 0;
        const seconds = cef.powerMonitorIdleSeconds();
        // 화면 잠금 시 "locked" 우선(Electron 동등). 아니면 idle 임계 비교 —
        // f64 직접 비교(seconds NaN/Inf여도 panic 없이 false → "active" safe).
        const state: []const u8 = if (cef.powerMonitorScreenLocked())
            "locked"
        else if (seconds >= @as(f64, @floatFromInt(threshold)))
            "idle"
        else
            "active";
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"power_monitor_get_idle_state\",\"state\":\"{s}\"}}",
            .{state},
        ) catch null;
    }

    // Shell API — NSWorkspace 기본 핸들러 / NSBeep.
    if (std.mem.eql(u8, cmd, "shell_open_external")) {
        const raw = util.extractJsonString(req_clean, "url") orelse "";
        var unesc_buf: [util.MAX_RESPONSE]u8 = undefined;
        const ok = blk: {
            const n = util.unescapeJsonStr(raw, &unesc_buf) orelse break :blk false;
            const url = unesc_buf[0..n];
            if (shellUrlGate(response_buf, "shell_open_external", url)) |e| return e;
            break :blk cef.shellOpenExternal(url);
        };
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"shell_open_external\",\"success\":{}}}",
            .{ok},
        ) catch return null;
    }
    if (std.mem.eql(u8, cmd, "shell_show_item_in_folder")) {
        const raw = util.extractJsonString(req_clean, "path") orelse "";
        var unesc_buf: [util.MAX_RESPONSE]u8 = undefined;
        const ok = blk: {
            const n = util.unescapeJsonStr(raw, &unesc_buf) orelse break :blk false;
            const path = unesc_buf[0..n];
            if (shellPathGate(response_buf, "shell_show_item_in_folder", path)) |e| return e;
            break :blk cef.shellShowItemInFolder(path);
        };
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"shell_show_item_in_folder\",\"success\":{}}}",
            .{ok},
        ) catch return null;
    }
    if (std.mem.eql(u8, cmd, "shell_beep")) {
        cef.shellBeep();
        const result = std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"shell_beep\",\"success\":true}}", .{}) catch return null;
        return result;
    }
    if (std.mem.eql(u8, cmd, "shell_trash_item")) {
        const raw = util.extractJsonString(req_clean, "path") orelse "";
        var unesc_buf: [util.MAX_RESPONSE]u8 = undefined;
        const ok = blk: {
            const n = util.unescapeJsonStr(raw, &unesc_buf) orelse break :blk false;
            const path = unesc_buf[0..n];
            if (shellPathGate(response_buf, "shell_trash_item", path)) |e| return e;
            break :blk cef.shellTrashItem(path);
        };
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"shell_trash_item\",\"success\":{}}}",
            .{ok},
        ) catch null;
    }
    if (std.mem.eql(u8, cmd, "shell_open_path")) {
        const raw = util.extractJsonString(req_clean, "path") orelse "";
        var unesc_buf: [util.MAX_RESPONSE]u8 = undefined;
        const ok = blk: {
            const n = util.unescapeJsonStr(raw, &unesc_buf) orelse break :blk false;
            const path = unesc_buf[0..n];
            if (shellPathGate(response_buf, "shell_open_path", path)) |e| return e;
            break :blk cef.shellOpenPath(path);
        };
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"shell_open_path\",\"success\":{}}}",
            .{ok},
        ) catch null;
    }
    if (std.mem.eql(u8, cmd, "native_theme_should_use_dark_colors")) {
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"native_theme_should_use_dark_colors\",\"dark\":{}}}",
            .{cef.nativeThemeIsDark()},
        ) catch null;
    }
    if (std.mem.eql(u8, cmd, "native_theme_set_source")) {
        const source = util.extractJsonString(req_clean, "source") orelse "system";
        const ok = cef.nativeThemeSetSource(source);
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"native_theme_set_source\",\"success\":{}}}",
            .{ok},
        ) catch null;
    }
    if (std.mem.eql(u8, cmd, "screen_get_cursor_point")) {
        const p = cef.screenGetCursorPoint();
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"screen_get_cursor_point\",\"x\":{d},\"y\":{d}}}",
            .{ p.x, p.y },
        ) catch null;
    }
    if (std.mem.eql(u8, cmd, "screen_get_display_nearest_point")) {
        const x = util.extractJsonFloat(req_clean, "x") orelse 0;
        const y = util.extractJsonFloat(req_clean, "y") orelse 0;
        const idx = cef.screenGetDisplayNearestPoint(x, y);
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"screen_get_display_nearest_point\",\"index\":{d}}}",
            .{idx},
        ) catch null;
    }

    // app.getPath — Electron 표준 키 7개. config.app.name이 userData 경로에 들어감.
    if (std.mem.eql(u8, cmd, "app_get_path")) {
        const name = util.extractJsonString(req_clean, "name") orelse "";
        const app_name: []const u8 = if (g_config) |c| c.app.name else "Suji";
        var path_buf: [1024]u8 = undefined;
        const path = cef.appGetPath(&path_buf, name, app_name) orelse "";
        var esc_buf: [2048]u8 = undefined;
        const esc_n = util.escapeJsonStrFull(path, &esc_buf) orelse return coreError(response_buf, "app_get_path", "encode");
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"app_get_path\",\"path\":\"{s}\"}}",
            .{esc_buf[0..esc_n]},
        ) catch null;
    }

    // Screen API — getAllDisplays 결과를 큰 stack 버퍼로 직접 빌드.
    if (std.mem.eql(u8, cmd, "screen_get_all_displays")) {
        var displays_buf: [4096]u8 = undefined;
        const displays = cef.screenGetAllDisplays(&displays_buf);
        const result = std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"screen_get_all_displays\",\"displays\":{s}}}",
            .{displays},
        ) catch return null;
        return result;
    }
    if (std.mem.eql(u8, cmd, "desktop_capturer_get_sources")) {
        // types 미지정 시 screen+window 둘 다 (Electron 은 필수지만 친화 기본).
        const types = util.extractJsonString(req_clean, "types");
        const want_screen = types == null or std.mem.indexOf(u8, types.?, "screen") != null;
        const want_window = types == null or std.mem.indexOf(u8, types.?, "window") != null;
        var sources_buf: [12288]u8 = undefined;
        const sources = cef.desktopCapturerGetSources(&sources_buf, want_screen, want_window);
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"desktop_capturer_get_sources\",\"sources\":{s}}}",
            .{sources},
        ) catch null;
    }
    if (std.mem.eql(u8, cmd, "desktop_capturer_capture_thumbnail")) {
        const source_id = util.extractJsonString(req_clean, "sourceId") orelse "";
        const path = util.extractJsonString(req_clean, "path") orelse "";
        const ok = source_id.len > 0 and path.len > 0 and
            cef.desktopCapturerCaptureThumbnail(source_id, path);
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"desktop_capturer_capture_thumbnail\",\"success\":{}}}",
            .{ok},
        ) catch null;
    }

    // Dock badge API. extractJsonString은 wire escape를 안 풀어주므로 unescape 후 NSDockTile에.
    // unescape 실패(text 한도 초과)면 graceful false — clipboard_write_text 패턴과 일관.
    // 256B 버퍼 — NSDockTile은 짧은 label(6-10 chars) 용도 (Apple HIG). escape margin 포함 충분.
    if (std.mem.eql(u8, cmd, "dock_set_badge")) {
        const raw = util.extractJsonString(req_clean, "text") orelse "";
        var unesc_buf: [256]u8 = undefined;
        const ok = if (util.unescapeJsonStr(raw, &unesc_buf)) |n| blk: {
            cef.dockSetBadge(unesc_buf[0..n]);
            break :blk true;
        } else false;
        const result = std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"dock_set_badge\",\"success\":{}}}",
            .{ok},
        ) catch return null;
        return result;
    }
    if (std.mem.eql(u8, cmd, "dock_get_badge")) {
        var text_buf: [256]u8 = undefined;
        const text = cef.dockGetBadge(&text_buf);
        var esc_buf: [512]u8 = undefined;
        const esc_n = util.escapeJsonStrFull(text, &esc_buf) orelse return null;
        const result = std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"dock_get_badge\",\"text\":\"{s}\"}}",
            .{esc_buf[0..esc_n]},
        ) catch return null;
        return result;
    }

    // Power save blocker.
    if (std.mem.eql(u8, cmd, "power_save_blocker_start")) {
        const type_str = util.extractJsonString(req_clean, "type") orelse "prevent_display_sleep";
        const t: cef.PowerSaveBlockerType = if (std.mem.eql(u8, type_str, "prevent_app_suspension"))
            .prevent_app_suspension
        else
            .prevent_display_sleep;
        const id = cef.powerSaveBlockerStart(t);
        const result = std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"power_save_blocker_start\",\"id\":{d}}}",
            .{id},
        ) catch return null;
        return result;
    }
    if (std.mem.eql(u8, cmd, "power_save_blocker_stop")) {
        const id_n = util.extractJsonInt(req_clean, "id") orelse 0;
        const ok = cef.powerSaveBlockerStop(util.nonNegU32(id_n));
        const result = std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"power_save_blocker_stop\",\"success\":{}}}",
            .{ok},
        ) catch return null;
        return result;
    }

    // app.getName / app.getVersion — config.app exposure (Electron `app.getName/getVersion`).
    if (std.mem.eql(u8, cmd, "app_get_name")) {
        const name: []const u8 = if (g_config) |c| c.app.name else "Suji";
        var esc_buf: [256]u8 = undefined;
        const esc_n = util.escapeJsonStrFull(name, &esc_buf) orelse return null;
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"app_get_name\",\"name\":\"{s}\"}}",
            .{esc_buf[0..esc_n]},
        ) catch null;
    }
    if (std.mem.eql(u8, cmd, "app_is_ready")) {
        // V8 binding이 호출 가능한 시점은 이미 init 후. 항상 true.
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"app_is_ready\",\"ready\":true}}", .{}) catch null;
    }
    if (std.mem.eql(u8, cmd, "app_is_packaged")) {
        const packaged = cef.appIsPackaged();
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"app_is_packaged\",\"packaged\":{}}}",
            .{packaged},
        ) catch null;
    }
    if (std.mem.eql(u8, cmd, "app_get_app_path")) {
        var path_buf: [1024]u8 = undefined;
        const path = cef.appGetBundlePath(&path_buf);
        var esc_buf: [2048]u8 = undefined;
        const esc_n = util.escapeJsonStrFull(path, &esc_buf) orelse 0;
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"app_get_app_path\",\"path\":\"{s}\"}}",
            .{esc_buf[0..esc_n]},
        ) catch null;
    }
    if (std.mem.eql(u8, cmd, "native_image_get_size")) {
        const raw = util.extractJsonString(req_clean, "path") orelse "";
        var unesc_buf: [util.MAX_RESPONSE]u8 = undefined;
        const sz = if (util.unescapeJsonStr(raw, &unesc_buf)) |unesc_n|
            cef.nativeImageGetSize(unesc_buf[0..unesc_n])
        else
            cef.NSSize{ .width = 0, .height = 0 };
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"native_image_get_size\",\"width\":{d},\"height\":{d}}}",
            .{ sz.width, sz.height },
        ) catch null;
    }
    // nativeImage 인코딩 — clipboard image와 같은 16KB response 한도. raw ~8KB까지.
    if (std.mem.eql(u8, cmd, "native_image_to_png") or std.mem.eql(u8, cmd, "native_image_to_jpeg")) {
        const file_type: cef.NSBitmapImageFileType =
            if (std.mem.eql(u8, cmd, "native_image_to_jpeg")) .jpeg else .png;
        const raw_path = util.extractJsonString(req_clean, "path") orelse "";
        var path_buf: [util.MAX_RESPONSE]u8 = undefined;
        const path_n = util.unescapeJsonStr(raw_path, &path_buf) orelse return respondBase64Data(response_buf, cmd, &.{});
        const quality = util.extractJsonFloat(req_clean, "quality") orelse 90;
        var raw_buf: [8 * 1024]u8 = undefined;
        const bytes = cef.nativeImageEncodeFromPath(path_buf[0..path_n], file_type, quality, &raw_buf);
        return respondBase64Data(response_buf, cmd, bytes);
    }
    if (std.mem.eql(u8, cmd, "app_exit")) {
        cef.quit();
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"app_exit\",\"success\":true}}", .{}) catch null;
    }
    if (std.mem.eql(u8, cmd, "session_clear_cookies")) {
        const ok = cef.sessionClearCookies();
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"session_clear_cookies\",\"success\":{}}}", .{ok}) catch null;
    }
    if (std.mem.eql(u8, cmd, "session_flush_store")) {
        const ok = cef.sessionFlushStore();
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"session_flush_store\",\"success\":{}}}", .{ok}) catch null;
    }
    if (std.mem.eql(u8, cmd, "session_clear_storage_data")) {
        var origin_buf: [2048]u8 = undefined;
        var types_buf: [256]u8 = undefined;
        const origin = util.extractJsonString(req_clean, "origin") orelse "";
        const types_raw = util.extractJsonString(req_clean, "storageTypes") orelse "all";
        const origin_n = util.unescapeJsonStr(origin, &origin_buf) orelse 0;
        const types_n = util.unescapeJsonStr(types_raw, &types_buf) orelse 0;
        const ok = cef.sessionClearStorageData(origin_buf[0..origin_n], types_buf[0..types_n]);
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"session_clear_storage_data\",\"success\":{}}}", .{ok}) catch null;
    }
    if (std.mem.eql(u8, cmd, "session_set_cookie")) {
        var url_buf: [2048]u8 = undefined;
        var name_buf: [256]u8 = undefined;
        var value_buf: [4096]u8 = undefined;
        var domain_buf: [256]u8 = undefined;
        var path_buf: [256]u8 = undefined;
        const url = util.extractJsonString(req_clean, "url") orelse "";
        const name = util.extractJsonString(req_clean, "name") orelse "";
        const value = util.extractJsonString(req_clean, "value") orelse "";
        const domain = util.extractJsonString(req_clean, "domain") orelse "";
        const path = util.extractJsonString(req_clean, "path") orelse "";
        const url_n = util.unescapeJsonStr(url, &url_buf) orelse 0;
        const name_n = util.unescapeJsonStr(name, &name_buf) orelse 0;
        const value_n = util.unescapeJsonStr(value, &value_buf) orelse 0;
        const domain_n = util.unescapeJsonStr(domain, &domain_buf) orelse 0;
        const path_n = util.unescapeJsonStr(path, &path_buf) orelse 0;
        const secure = util.extractJsonBool(req_clean, "secure") orelse false;
        const httponly = util.extractJsonBool(req_clean, "httponly") orelse false;
        const expires = util.extractJsonFloat(req_clean, "expires") orelse 0;
        const ok = cef.sessionSetCookie(
            url_buf[0..url_n],
            name_buf[0..name_n],
            value_buf[0..value_n],
            domain_buf[0..domain_n],
            path_buf[0..path_n],
            secure,
            httponly,
            expires,
        );
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"session_set_cookie\",\"success\":{}}}", .{ok}) catch null;
    }
    if (std.mem.eql(u8, cmd, "session_remove_cookies")) {
        var url_buf: [2048]u8 = undefined;
        var name_buf: [256]u8 = undefined;
        const url = util.extractJsonString(req_clean, "url") orelse "";
        const name = util.extractJsonString(req_clean, "name") orelse "";
        const url_n = util.unescapeJsonStr(url, &url_buf) orelse 0;
        const name_n = util.unescapeJsonStr(name, &name_buf) orelse 0;
        const ok = cef.sessionRemoveCookies(url_buf[0..url_n], name_buf[0..name_n]);
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"session_remove_cookies\",\"success\":{}}}", .{ok}) catch null;
    }
    if (std.mem.eql(u8, cmd, "session_get_cookies")) {
        var url_buf: [2048]u8 = undefined;
        const url = util.extractJsonString(req_clean, "url") orelse "";
        const url_n = util.unescapeJsonStr(url, &url_buf) orelse 0;
        const include_http_only = util.extractJsonBool(req_clean, "includeHttpOnly") orelse true;
        const id = cef.sessionGetCookies(url_buf[0..url_n], include_http_only);
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"session_get_cookies\",\"success\":{},\"requestId\":{d}}}",
            .{ id != 0, id },
        ) catch null;
    }
    if (std.mem.eql(u8, cmd, "app_set_progress_bar")) {
        const progress = util.extractJsonFloat(req_clean, "progress") orelse -1;
        const ok = cef.appSetProgressBar(progress);
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"app_set_progress_bar\",\"success\":{}}}",
            .{ok},
        ) catch null;
    }
    if (std.mem.eql(u8, cmd, "app_get_locale")) {
        var raw_buf: [128]u8 = undefined;
        const locale = cef.appGetLocale(&raw_buf);
        var esc_buf: [256]u8 = undefined;
        const esc_n = util.escapeJsonStrFull(locale, &esc_buf) orelse return null;
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"app_get_locale\",\"locale\":\"{s}\"}}",
            .{esc_buf[0..esc_n]},
        ) catch null;
    }
    if (std.mem.eql(u8, cmd, "app_focus")) {
        const ok = cef.appFocus();
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"app_focus\",\"success\":{}}}", .{ok}) catch null;
    }
    if (std.mem.eql(u8, cmd, "app_hide")) {
        const ok = cef.appHide();
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"app_hide\",\"success\":{}}}", .{ok}) catch null;
    }
    // clipboard image — request/response buffer가 16KB라 raw PNG 한도 ~8KB. 더 큰 이미지는
    // 후속 (전용 binary IPC 또는 buffer 확장 필요). e2e용 1x1 transparent PNG (~67B)는 충분.
    if (std.mem.eql(u8, cmd, "clipboard_write_image")) {
        const b64_raw = util.extractJsonString(req_clean, "data") orelse "";
        var b64_buf: [util.MAX_RESPONSE]u8 = undefined;
        const b64_n = util.unescapeJsonStr(b64_raw, &b64_buf) orelse return null;

        var raw_buf: [8 * 1024]u8 = undefined;
        const decoded_size = std.base64.standard.Decoder.calcSizeForSlice(b64_buf[0..b64_n]) catch {
            return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"clipboard_write_image\",\"success\":false,\"error\":\"decode\"}}", .{}) catch null;
        };
        if (decoded_size > raw_buf.len) {
            return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"clipboard_write_image\",\"success\":false,\"error\":\"too_large\"}}", .{}) catch null;
        }
        std.base64.standard.Decoder.decode(raw_buf[0..decoded_size], b64_buf[0..b64_n]) catch {
            return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"clipboard_write_image\",\"success\":false,\"error\":\"decode\"}}", .{}) catch null;
        };
        const ok = cef.clipboardWriteImagePng(raw_buf[0..decoded_size]);
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"clipboard_write_image\",\"success\":{}}}", .{ok}) catch null;
    }
    if (std.mem.eql(u8, cmd, "clipboard_read_image")) {
        var raw_buf: [8 * 1024]u8 = undefined;
        const png_bytes = cef.clipboardReadImagePng(&raw_buf);
        return respondBase64Data(response_buf, cmd, png_bytes);
    }
    if (std.mem.eql(u8, cmd, "clipboard_write_tiff")) {
        const b64_raw = util.extractJsonString(req_clean, "data") orelse "";
        var b64_buf: [util.MAX_RESPONSE]u8 = undefined;
        const b64_n = util.unescapeJsonStr(b64_raw, &b64_buf) orelse return null;

        var raw_buf: [8 * 1024]u8 = undefined;
        const decoded_size = std.base64.standard.Decoder.calcSizeForSlice(b64_buf[0..b64_n]) catch {
            return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"clipboard_write_tiff\",\"success\":false,\"error\":\"decode\"}}", .{}) catch null;
        };
        if (decoded_size > raw_buf.len) {
            return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"clipboard_write_tiff\",\"success\":false,\"error\":\"too_large\"}}", .{}) catch null;
        }
        std.base64.standard.Decoder.decode(raw_buf[0..decoded_size], b64_buf[0..b64_n]) catch {
            return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"clipboard_write_tiff\",\"success\":false,\"error\":\"decode\"}}", .{}) catch null;
        };
        const ok = cef.clipboardWriteTiff(raw_buf[0..decoded_size]);
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"clipboard_write_tiff\",\"success\":{}}}", .{ok}) catch null;
    }
    if (std.mem.eql(u8, cmd, "clipboard_read_tiff")) {
        var raw_buf: [8 * 1024]u8 = undefined;
        const tiff_bytes = cef.clipboardReadTiff(&raw_buf);
        return respondBase64Data(response_buf, cmd, tiff_bytes);
    }
    if (std.mem.eql(u8, cmd, "clipboard_has")) {
        const fmt_str = util.extractJsonString(req_clean, "format") orelse "";
        var unesc_buf: [256]u8 = undefined;
        const has = if (util.unescapeJsonStr(fmt_str, &unesc_buf)) |unesc_n| blk: {
            // null-terminate for cstr.
            unesc_buf[unesc_n] = 0;
            const cstr: [*:0]const u8 = @ptrCast(&unesc_buf);
            break :blk cef.clipboardHas(cstr);
        } else false;
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"clipboard_has\",\"present\":{}}}",
            .{has},
        ) catch null;
    }
    if (std.mem.eql(u8, cmd, "clipboard_available_formats")) {
        var fmt_buf: [4096]u8 = undefined;
        const formats = cef.clipboardAvailableFormats(&fmt_buf);
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"clipboard_available_formats\",\"formats\":{s}}}",
            .{formats},
        ) catch null;
    }
    if (std.mem.eql(u8, cmd, "app_get_version")) {
        const version: []const u8 = if (g_config) |c| c.app.version else "0.0.0";
        var esc_buf: [128]u8 = undefined;
        const esc_n = util.escapeJsonStrFull(version, &esc_buf) orelse return null;
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"app_get_version\",\"version\":\"{s}\"}}",
            .{esc_buf[0..esc_n]},
        ) catch null;
    }

    // app.requestUserAttention — dock bounce. critical=true는 활성화까지 반복, false는 1회.
    if (std.mem.eql(u8, cmd, "app_attention_request")) {
        const critical = util.extractJsonBool(req_clean, "critical") orelse true;
        const id = cef.appRequestUserAttention(critical);
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"app_attention_request\",\"id\":{d}}}",
            .{id},
        ) catch null;
    }
    // webRequest — URL glob blocklist (Electron `session.webRequest.onBeforeRequest({urls}, listener)`).
    if (std.mem.eql(u8, cmd, "web_request_set_blocked_urls")) {
        return handleWebRequestSetBlockedUrls(req_clean, response_buf);
    }
    if (std.mem.eql(u8, cmd, "web_request_set_listener_filter")) {
        return handleWebRequestSetListenerFilter(req_clean, response_buf);
    }
    if (std.mem.eql(u8, cmd, "web_request_resolve")) {
        const id_n = util.extractJsonInt(req_clean, "id") orelse 0;
        const cancel_request = util.extractJsonBool(req_clean, "cancel") orelse false;
        const ok = if (id_n > 0) cef.webRequestResolve(@intCast(id_n), cancel_request) else false;
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"web_request_resolve\",\"success\":{}}}",
            .{ok},
        ) catch null;
    }

    if (std.mem.eql(u8, cmd, "app_attention_cancel")) {
        const id_n = util.extractJsonInt(req_clean, "id") orelse 0;
        const ok = cef.appCancelUserAttentionRequest(util.nonNegU32(id_n));
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"app_attention_cancel\",\"success\":{}}}",
            .{ok},
        ) catch null;
    }

    // Security-scoped bookmarks (Electron `app.startAccessingSecurityScopedResource`).
    if (std.mem.eql(u8, cmd, "security_scoped_bookmark_create")) {
        const raw = util.extractJsonString(req_clean, "path") orelse "";
        var path_buf: [util.MAX_RESPONSE]u8 = undefined;
        const path = if (util.unescapeJsonStr(raw, &path_buf)) |n| path_buf[0..n] else "";
        var bm_buf: [8192]u8 = undefined;
        const bm = cef.securityScopedBookmarkCreate(path, &bm_buf);
        if (bm.len == 0) return coreError(response_buf, "security_scoped_bookmark_create", "create");
        // base64 알파벳엔 JSON-special 없음 — escape 불필요.
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"security_scoped_bookmark_create\",\"success\":true,\"bookmark\":\"{s}\"}}",
            .{bm},
        ) catch null;
    }
    if (std.mem.eql(u8, cmd, "security_scoped_access_start")) {
        const bm = util.extractJsonString(req_clean, "bookmark") orelse "";
        var path_buf: [2048]u8 = undefined;
        const acc = cef.securityScopedAccessStart(bm, &path_buf);
        if (acc.id == 0) return coreError(response_buf, "security_scoped_access_start", "resolve");
        var esc_buf: [4096]u8 = undefined;
        const esc_n = util.escapeJsonStrFull(acc.path, &esc_buf) orelse return coreError(response_buf, "security_scoped_access_start", "encode");
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"security_scoped_access_start\",\"success\":true,\"id\":{d},\"path\":\"{s}\",\"stale\":{}}}",
            .{ acc.id, esc_buf[0..esc_n], acc.stale },
        ) catch null;
    }
    if (std.mem.eql(u8, cmd, "security_scoped_access_stop")) {
        const id_n = util.extractJsonInt(req_clean, "id") orelse 0;
        const ok = if (id_n > 0) cef.securityScopedAccessStop(util.nonNegU32(id_n)) else false;
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"security_scoped_access_stop\",\"success\":{}}}",
            .{ok},
        ) catch null;
    }

    // safeStorage — Keychain Services. service/account/value 셋 다 unescape 필요 (wire JSON).
    if (std.mem.eql(u8, cmd, "safe_storage_set")) {
        const svc_raw = util.extractJsonString(req_clean, "service") orelse "";
        const acc_raw = util.extractJsonString(req_clean, "account") orelse "";
        const val_raw = util.extractJsonString(req_clean, "value") orelse "";
        var svc_buf: [256]u8 = undefined;
        var acc_buf: [256]u8 = undefined;
        var val_buf: [4096]u8 = undefined;
        const svc_n = util.unescapeJsonStr(svc_raw, &svc_buf) orelse return coreError(response_buf, "safe_storage_set", "service");
        const acc_n = util.unescapeJsonStr(acc_raw, &acc_buf) orelse return coreError(response_buf, "safe_storage_set", "account");
        const val_n = util.unescapeJsonStr(val_raw, &val_buf) orelse return coreError(response_buf, "safe_storage_set", "value");
        const ok = cef.safeStorageSet(svc_buf[0..svc_n], acc_buf[0..acc_n], val_buf[0..val_n]);
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"safe_storage_set\",\"success\":{}}}", .{ok}) catch null;
    }
    if (std.mem.eql(u8, cmd, "safe_storage_get")) {
        const svc_raw = util.extractJsonString(req_clean, "service") orelse "";
        const acc_raw = util.extractJsonString(req_clean, "account") orelse "";
        var svc_buf: [256]u8 = undefined;
        var acc_buf: [256]u8 = undefined;
        const svc_n = util.unescapeJsonStr(svc_raw, &svc_buf) orelse return coreError(response_buf, "safe_storage_get", "service");
        const acc_n = util.unescapeJsonStr(acc_raw, &acc_buf) orelse return coreError(response_buf, "safe_storage_get", "account");
        var val_buf: [4096]u8 = undefined;
        const val = cef.safeStorageGet(svc_buf[0..svc_n], acc_buf[0..acc_n], &val_buf);
        var esc_buf: [8192]u8 = undefined;
        const esc_n = util.escapeJsonStrFull(val, &esc_buf) orelse return coreError(response_buf, "safe_storage_get", "encode");
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"safe_storage_get\",\"value\":\"{s}\"}}",
            .{esc_buf[0..esc_n]},
        ) catch null;
    }
    if (std.mem.eql(u8, cmd, "safe_storage_delete")) {
        const svc_raw = util.extractJsonString(req_clean, "service") orelse "";
        const acc_raw = util.extractJsonString(req_clean, "account") orelse "";
        var svc_buf: [256]u8 = undefined;
        var acc_buf: [256]u8 = undefined;
        const svc_n = util.unescapeJsonStr(svc_raw, &svc_buf) orelse return coreError(response_buf, "safe_storage_delete", "service");
        const acc_n = util.unescapeJsonStr(acc_raw, &acc_buf) orelse return coreError(response_buf, "safe_storage_delete", "account");
        const ok = cef.safeStorageDelete(svc_buf[0..svc_n], acc_buf[0..acc_n]);
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"safe_storage_delete\",\"success\":{}}}", .{ok}) catch null;
    }

    if (std.mem.eql(u8, cmd, "fs_read_file")) {
        return handleFsReadFile(req_clean, response_buf);
    }
    if (std.mem.eql(u8, cmd, "fs_write_file")) {
        return handleFsWriteFile(req_clean, response_buf);
    }
    if (std.mem.eql(u8, cmd, "fs_stat")) {
        return handleFsStat(req_clean, response_buf);
    }
    if (std.mem.eql(u8, cmd, "fs_mkdir")) {
        return handleFsMkdir(req_clean, response_buf);
    }
    if (std.mem.eql(u8, cmd, "fs_readdir")) {
        return handleFsReadDir(req_clean, response_buf);
    }
    if (std.mem.eql(u8, cmd, "fs_rm")) {
        return handleFsRm(req_clean, response_buf);
    }

    // Dialog API — NSAlert / NSOpenPanel / NSSavePanel.
    if (std.mem.eql(u8, cmd, "dialog_show_message_box")) {
        return handleDialogShowMessageBox(req_clean, response_buf);
    }
    if (std.mem.eql(u8, cmd, "dialog_show_error_box")) {
        return handleDialogShowErrorBox(req_clean, response_buf);
    }
    if (std.mem.eql(u8, cmd, "dialog_show_open_dialog")) {
        return handleDialogShowOpenDialog(req_clean, response_buf);
    }
    if (std.mem.eql(u8, cmd, "dialog_show_save_dialog")) {
        return handleDialogShowSaveDialog(req_clean, response_buf);
    }

    // Tray API — NSStatusItem.
    if (std.mem.eql(u8, cmd, "tray_create")) {
        const title = util.extractJsonString(req_clean, "title") orelse "";
        const tooltip = util.extractJsonString(req_clean, "tooltip") orelse "";
        var t_buf: [256]u8 = undefined;
        var tt_buf: [512]u8 = undefined;
        const t_n = util.unescapeJsonStr(title, &t_buf) orelse 0;
        const tt_n = util.unescapeJsonStr(tooltip, &tt_buf) orelse 0;
        const id = cef.createTray(t_buf[0..t_n], tt_buf[0..tt_n]);
        const result = std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"tray_create\",\"trayId\":{d}}}",
            .{id},
        ) catch return null;
        return result;
    }
    if (std.mem.eql(u8, cmd, "tray_set_title")) {
        const tray_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "trayId") orelse return null);
        const title = util.extractJsonString(req_clean, "title") orelse "";
        var t_buf: [512]u8 = undefined;
        const t_n = util.unescapeJsonStr(title, &t_buf) orelse 0;
        const ok = cef.setTrayTitle(tray_id, t_buf[0..t_n]);
        const result = std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"tray_set_title\",\"success\":{}}}", .{ok}) catch return null;
        return result;
    }
    if (std.mem.eql(u8, cmd, "tray_set_tooltip")) {
        const tray_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "trayId") orelse return null);
        const tooltip = util.extractJsonString(req_clean, "tooltip") orelse "";
        var t_buf: [1024]u8 = undefined;
        const t_n = util.unescapeJsonStr(tooltip, &t_buf) orelse 0;
        const ok = cef.setTrayTooltip(tray_id, t_buf[0..t_n]);
        const result = std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"tray_set_tooltip\",\"success\":{}}}", .{ok}) catch return null;
        return result;
    }
    if (std.mem.eql(u8, cmd, "tray_set_menu")) {
        return handleTraySetMenu(req_clean, response_buf);
    }
    if (std.mem.eql(u8, cmd, "tray_destroy")) {
        const tray_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "trayId") orelse return null);
        const ok = cef.destroyTray(tray_id);
        const result = std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"tray_destroy\",\"success\":{}}}", .{ok}) catch return null;
        return result;
    }

    // Application Menu API — NSMenu customization.
    if (std.mem.eql(u8, cmd, "menu_set_application_menu")) {
        return handleMenuSetApplicationMenu(req_clean, response_buf);
    }
    if (std.mem.eql(u8, cmd, "menu_reset_application_menu")) {
        const ok = cef.resetApplicationMenu();
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"menu_reset_application_menu\",\"success\":{}}}", .{ok}) catch null;
    }
    if (std.mem.eql(u8, cmd, "menu_popup")) {
        return handleMenuPopup(req_clean, response_buf);
    }

    // Global shortcut API — Carbon Hot Key (macOS only).
    if (std.mem.eql(u8, cmd, "global_shortcut_register")) {
        return handleGlobalShortcutRegister(req_clean, response_buf);
    }
    if (std.mem.eql(u8, cmd, "global_shortcut_unregister")) {
        return handleGlobalShortcutUnregister(req_clean, response_buf);
    }
    if (std.mem.eql(u8, cmd, "global_shortcut_unregister_all")) {
        cef.globalShortcutUnregisterAll();
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"global_shortcut_unregister_all\",\"success\":true}}", .{}) catch null;
    }
    if (std.mem.eql(u8, cmd, "global_shortcut_is_registered")) {
        return handleGlobalShortcutIsRegistered(req_clean, response_buf);
    }

    // Notification API — UNUserNotificationCenter (macOS only).
    if (std.mem.eql(u8, cmd, "notification_is_supported")) {
        const supported = cef.notificationIsSupported();
        const result = std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"notification_is_supported\",\"supported\":{}}}", .{supported}) catch return null;
        return result;
    }
    if (std.mem.eql(u8, cmd, "notification_request_permission")) {
        const granted = cef.notificationRequestPermission();
        const result = std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"notification_request_permission\",\"granted\":{}}}", .{granted}) catch return null;
        return result;
    }
    if (std.mem.eql(u8, cmd, "notification_show")) {
        const title_raw = util.extractJsonString(req_clean, "title") orelse "";
        const body_raw = util.extractJsonString(req_clean, "body") orelse "";
        const silent = util.extractJsonBool(req_clean, "silent") orelse false;
        var t_buf: [4096]u8 = undefined;
        var b_buf: [4096]u8 = undefined;
        const t_n = util.unescapeJsonStr(title_raw, &t_buf) orelse 0;
        const b_n = util.unescapeJsonStr(body_raw, &b_buf) orelse 0;

        const id = nextNotificationId();
        var id_buf: [32]u8 = undefined;
        const id_str = std.fmt.bufPrint(&id_buf, "suji-notif-{d}", .{id}) catch return null;

        const ok = cef.notificationShow(id_str, t_buf[0..t_n], b_buf[0..b_n], silent);
        const result = std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"notification_show\",\"notificationId\":\"{s}\",\"success\":{}}}",
            .{ id_str, ok },
        ) catch return null;
        return result;
    }
    if (std.mem.eql(u8, cmd, "notification_close")) {
        const id_raw = util.extractJsonString(req_clean, "notificationId") orelse "";
        var id_buf: [128]u8 = undefined;
        const id_n = util.unescapeJsonStr(id_raw, &id_buf) orelse 0;
        const ok = cef.notificationClose(id_buf[0..id_n]);
        const result = std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"notification_close\",\"success\":{}}}", .{ok}) catch return null;
        return result;
    }

    if (std.mem.eql(u8, cmd, "core_info")) {
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
    }

    // typo / version mismatch 진단용 — coreError가 cmd echo 자동.
    return coreError(response_buf, cmd, "unknown_cmd");
}

// ============================================
// Dialog handlers — std.json으로 옵션 파싱 후 cef.zig 호출
// ============================================

/// std.json parse용 stack-FBA arena. 디알로그 옵션 한 회 파싱에 충분 (32KB).
const DIALOG_PARSE_ARENA: usize = 32768;

/// JSON 형식: {"type","title","message","detail","buttons":[],"defaultId","cancelId",
///             "checkboxLabel","checkboxChecked","windowId"}
/// windowId 지정 시 sheet, 없으면 free-floating.
const MessageBoxJson = struct {
    type: []const u8 = "none",
    title: []const u8 = "",
    message: []const u8 = "",
    detail: []const u8 = "",
    buttons: []const []const u8 = &.{},
    defaultId: ?usize = null,
    cancelId: ?usize = null,
    checkboxLabel: []const u8 = "",
    checkboxChecked: bool = false,
    windowId: ?u32 = null,
};

const FileFilterJson = struct {
    name: []const u8 = "",
    extensions: []const []const u8 = &.{},
};

const OpenDialogJson = struct {
    title: []const u8 = "",
    defaultPath: []const u8 = "",
    buttonLabel: []const u8 = "",
    message: []const u8 = "",
    filters: []const FileFilterJson = &.{},
    properties: []const []const u8 = &.{},
    windowId: ?u32 = null,
};

const SaveDialogJson = struct {
    title: []const u8 = "",
    defaultPath: []const u8 = "",
    buttonLabel: []const u8 = "",
    message: []const u8 = "",
    nameFieldLabel: []const u8 = "",
    showsTagField: bool = false,
    filters: []const FileFilterJson = &.{},
    properties: []const []const u8 = &.{},
    windowId: ?u32 = null,
};

const ErrorBoxJson = struct {
    title: []const u8 = "",
    content: []const u8 = "",
};

/// std.json properties 배열 → 부울 플래그 테이블. Electron OpenDialog properties:
///   openFile / openDirectory / multiSelections / showHiddenFiles / createDirectory
///   noResolveAliases / treatPackageAsDirectory
fn hasProp(props: []const []const u8, name: []const u8) bool {
    for (props) |p| {
        if (std.mem.eql(u8, p, name)) return true;
    }
    return false;
}

/// windowId(u32 WM id) → NSWindow 포인터. 못 찾으면 null → free-floating fallback.
/// stale/잘못된 windowId가 무성하게 묻히지 않도록 명시 lookup 실패는 warn 로그.
fn dialogParentNSWindow(window_id: ?u32) ?*anyopaque {
    const id = window_id orelse return null;
    const wm = window_mod.WindowManager.global orelse return null;
    const win = wm.get(id) orelse {
        std.log.warn("dialog: windowId={d} not found in WindowManager — sheet fallback to free-floating", .{id});
        return null;
    };
    const ns_win = cef.nsWindowForBrowserHandle(win.native_handle);
    if (ns_win == null) {
        std.log.warn("dialog: windowId={d} (browser handle={d}) has no NSWindow — sheet fallback to free-floating", .{ id, win.native_handle });
    }
    return ns_win;
}

fn parseStyleString(s: []const u8) cef.MessageBoxStyle {
    if (std.mem.eql(u8, s, "info")) return .info;
    if (std.mem.eql(u8, s, "warning")) return .warning;
    if (std.mem.eql(u8, s, "error")) return .err;
    if (std.mem.eql(u8, s, "question")) return .question;
    return .none;
}

/// FileFilterJson [] → cef.FileFilter [] 변환. arena 위에 alloc.
fn convertFilters(arena: std.mem.Allocator, src: []const FileFilterJson) ![]cef.FileFilter {
    var result = try arena.alloc(cef.FileFilter, src.len);
    for (src, 0..) |f, i| {
        result[i] = .{ .name = f.name, .extensions = f.extensions };
    }
    return result;
}

fn handleDialogShowMessageBox(req_clean: []const u8, response_buf: []u8) ?[]const u8 {
    var arena_buf: [DIALOG_PARSE_ARENA]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arena_buf);
    const arena = fba.allocator();

    const parsed = std.json.parseFromSlice(MessageBoxJson, arena, req_clean, .{
        .ignore_unknown_fields = true,
    }) catch {
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"dialog_show_message_box\",\"response\":0,\"checkboxChecked\":false,\"error\":\"parse\"}}",
            .{},
        ) catch null;
    };
    defer parsed.deinit();
    const opts = parsed.value;

    const r = cef.showMessageBox(.{
        .style = parseStyleString(opts.type),
        .title = opts.title,
        .message = opts.message,
        .detail = opts.detail,
        .buttons = opts.buttons,
        .default_id = opts.defaultId,
        .cancel_id = opts.cancelId,
        .checkbox_label = opts.checkboxLabel,
        .checkbox_checked = opts.checkboxChecked,
        .parent_window = dialogParentNSWindow(opts.windowId),
    });

    return std.fmt.bufPrint(
        response_buf,
        "{{\"from\":\"zig-core\",\"cmd\":\"dialog_show_message_box\",\"response\":{d},\"checkboxChecked\":{}}}",
        .{ r.response, r.checkbox_checked },
    ) catch null;
}

fn handleDialogShowErrorBox(req_clean: []const u8, response_buf: []u8) ?[]const u8 {
    var arena_buf: [DIALOG_PARSE_ARENA]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arena_buf);
    const arena = fba.allocator();

    const parsed = std.json.parseFromSlice(ErrorBoxJson, arena, req_clean, .{
        .ignore_unknown_fields = true,
    }) catch return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"dialog_show_error_box\",\"success\":false}}", .{}) catch null;
    defer parsed.deinit();

    cef.showErrorBox(parsed.value.title, parsed.value.content);

    return std.fmt.bufPrint(
        response_buf,
        "{{\"from\":\"zig-core\",\"cmd\":\"dialog_show_error_box\",\"success\":true}}",
        .{},
    ) catch null;
}

/// `__core__` cmd handler 공용 에러 응답. 모든 핸들러가 같은 wire 포맷 사용.
fn coreError(response_buf: []u8, cmd: []const u8, err: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"{s}\",\"success\":false,\"error\":\"{s}\"}}", .{ cmd, err }) catch null;
}

const FS_MAX_TEXT_BYTES: usize = 8192;
const FS_MAX_PATH_BYTES: usize = 4096;

/// 전체 suji.json config을 glob 노출 — fs sandbox / 향후 network/shell allowlist /
/// 플러그인 접근까지 단일 진입점. dev/run 시작 시 setGlobalConfig로 주입.
/// lifetime: dev/run 함수가 process lifetime이라 stack address 안전.
var g_config: ?*const suji.Config = null;

pub fn setGlobalConfig(c: *const suji.Config) void {
    g_config = c;
}

/// Backend invoke 흐름에서는 sandbox 적용 X (사용자 자체 코드라 신뢰).
/// BackendRegistry __core__ 채널 핸들러가 set, frontend IPC origin은 false 유지.
threadlocal var g_in_backend_invoke: bool = false;

/// fs frontend sandbox — fs 는 **default-deny** (cfg null/roots empty → 차단).
/// 공통 매처는 util.* (CEF-free, 모바일 embed 와 공용).
fn isPathAllowedForFrontend(path: []const u8) bool {
    const cfg = g_config orelse return false;
    const roots = cfg.fs.allowed_roots;
    if (roots.len == 0) return false;
    return util.pathAllowedInRoots(path, roots);
}

// hasParentTraversalSegment / pathHasRootBoundary / urlAllowedInList 단위 테스트는
// util.zig 로 이동(공통 매처와 함께 — 데스크톱/모바일 embed 공용).

test "isPathAllowedForFrontend: 종합 시나리오" {
    // g_config은 process global이라 test 사이 reset 필요.
    const saved = g_config;
    defer g_config = saved;

    // 1) g_config null → 차단 (config 미설정)
    g_config = null;
    try std.testing.expect(!isPathAllowedForFrontend("/any/path"));

    // 2) allowedRoots empty → 차단 (default safe)
    var cfg_empty = suji.Config{};
    cfg_empty.fs.allowed_roots = &.{};
    g_config = &cfg_empty;
    try std.testing.expect(!isPathAllowedForFrontend("/any/path"));

    // 3) wildcard ["*"] → 일반 path 허용, .. 거부
    var cfg_wild = suji.Config{};
    const wild_roots = [_][:0]const u8{"*"};
    cfg_wild.fs.allowed_roots = &wild_roots;
    g_config = &cfg_wild;
    try std.testing.expect(isPathAllowedForFrontend("/etc/hosts"));
    try std.testing.expect(isPathAllowedForFrontend("/Users/x/safe"));
    try std.testing.expect(!isPathAllowedForFrontend("/foo/../etc/passwd")); // .. 항상 차단

    // 4) specific root → boundary 가드 검증 (prefix-extension attack)
    var cfg_specific = suji.Config{};
    const spec_roots = [_][:0]const u8{"/Users/x/myapp"};
    cfg_specific.fs.allowed_roots = &spec_roots;
    g_config = &cfg_specific;
    try std.testing.expect(isPathAllowedForFrontend("/Users/x/myapp"));
    try std.testing.expect(isPathAllowedForFrontend("/Users/x/myapp/data.txt"));
    try std.testing.expect(!isPathAllowedForFrontend("/Users/x/myapp_secret/data")); // prefix-extension
    try std.testing.expect(!isPathAllowedForFrontend("/Users/x/other"));

    // 5) mixed ["*", "/specific"] → wildcard로 모두 허용
    var cfg_mixed = suji.Config{};
    const mixed_roots = [_][:0]const u8{ "*", "/Users/x/myapp" };
    cfg_mixed.fs.allowed_roots = &mixed_roots;
    g_config = &cfg_mixed;
    try std.testing.expect(isPathAllowedForFrontend("/anywhere"));
    try std.testing.expect(!isPathAllowedForFrontend("/foo/../etc")); // .. 차단

    // 6) 정상 파일명에 .. 포함 → 통과 (false positive 회귀)
    g_config = &cfg_wild;
    try std.testing.expect(isPathAllowedForFrontend("/foo/my..file.txt"));
    try std.testing.expect(isPathAllowedForFrontend("/foo/archive..bak"));
}

test "fsSandboxCheck: g_in_backend_invoke 마커는 sandbox 우회" {
    const saved_cfg = g_config;
    const saved_marker = g_in_backend_invoke;
    defer {
        g_config = saved_cfg;
        g_in_backend_invoke = saved_marker;
    }

    // sandbox 차단 config (empty roots = forbidden)
    var cfg = suji.Config{};
    cfg.fs.allowed_roots = &.{};
    g_config = &cfg;

    var resp_buf: [256]u8 = undefined;

    // Frontend 흐름 — 차단 (forbidden 에러 반환).
    g_in_backend_invoke = false;
    const fe = fsSandboxCheck(&resp_buf, "fs_test", "/any/path");
    try std.testing.expect(fe != null);
    try std.testing.expect(std.mem.indexOf(u8, fe.?, "\"error\":\"forbidden\"") != null);

    // Backend 흐름 — 우회 (null 반환 = 검사 통과).
    g_in_backend_invoke = true;
    const be = fsSandboxCheck(&resp_buf, "fs_test", "/any/path");
    try std.testing.expect(be == null);
}

test "shell/dialog 게이트: opt-in (키 부재=레거시 허용, 존재=enforce) + backend 우회" {
    const saved_cfg = g_config;
    const saved_marker = g_in_backend_invoke;
    defer {
        g_config = saved_cfg;
        g_in_backend_invoke = saved_marker;
    }
    g_in_backend_invoke = false;
    var resp: [256]u8 = undefined;

    // g_config null → 레거시 허용 (null 반환).
    g_config = null;
    try std.testing.expect(shellPathGate(&resp, "shell_open_path", "/x") == null);
    try std.testing.expect(shellUrlGate(&resp, "shell_open_external", "https://x") == null);
    try std.testing.expect(dialogPathGate(&resp, "dialog_show_open_dialog", "/x") == null);

    // 키 부재 (optional null) → 레거시 허용.
    var cfg_absent = suji.Config{};
    g_config = &cfg_absent;
    try std.testing.expect(shellPathGate(&resp, "shell_open_path", "/etc/passwd") == null);
    try std.testing.expect(shellUrlGate(&resp, "shell_open_external", "https://evil.com") == null);

    // 키 존재하지만 빈 슬라이스 → enforce deny-all (forbidden).
    var cfg_deny = suji.Config{};
    cfg_deny.shell.allowed_paths = &.{};
    cfg_deny.shell.allowed_external_urls = &.{};
    cfg_deny.dialog.allowed_paths = &.{};
    g_config = &cfg_deny;
    const d1 = shellPathGate(&resp, "shell_open_path", "/x");
    try std.testing.expect(d1 != null and std.mem.indexOf(u8, d1.?, "\"error\":\"forbidden\"") != null);
    try std.testing.expect(shellUrlGate(&resp, "shell_open_external", "https://x") != null);
    try std.testing.expect(dialogPathGate(&resp, "dialog_show_open_dialog", "/x") != null);
    // 빈 defaultPath 는 dialog 무제약 (deny config 라도 null).
    try std.testing.expect(dialogPathGate(&resp, "dialog_show_open_dialog", "") == null);

    // 특정 allowlist → boundary/glob enforce.
    var cfg_spec = suji.Config{};
    const sp = [_][:0]const u8{"/Users/x/app"};
    const su = [_][:0]const u8{"https://*.ok.com/*"};
    cfg_spec.shell.allowed_paths = &sp;
    cfg_spec.shell.allowed_external_urls = &su;
    cfg_spec.dialog.allowed_paths = &sp;
    g_config = &cfg_spec;
    try std.testing.expect(shellPathGate(&resp, "shell_open_path", "/Users/x/app/f") == null);
    try std.testing.expect(shellPathGate(&resp, "shell_open_path", "/Users/x/app_secret") != null); // prefix-ext
    try std.testing.expect(shellPathGate(&resp, "shell_open_path", "/Users/x/app/../etc") != null); // ..
    try std.testing.expect(shellUrlGate(&resp, "shell_open_external", "https://a.ok.com/p") == null);
    try std.testing.expect(shellUrlGate(&resp, "shell_open_external", "https://evil.com/") != null);
    try std.testing.expect(dialogPathGate(&resp, "dialog_show_save_dialog", "/Users/x/app/s.txt") == null);
    try std.testing.expect(dialogPathGate(&resp, "dialog_show_save_dialog", "/etc/x") != null);

    // backend invoke 마커 → 전 게이트 우회 (deny config 라도 null).
    g_config = &cfg_deny;
    g_in_backend_invoke = true;
    try std.testing.expect(shellPathGate(&resp, "shell_open_path", "/x") == null);
    try std.testing.expect(shellUrlGate(&resp, "shell_open_external", "https://x") == null);
    try std.testing.expect(dialogPathGate(&resp, "dialog_show_open_dialog", "/x") == null);
}

fn fsSandboxCheck(response_buf: []u8, cmd: []const u8, path: []const u8) ?[]const u8 {
    if (g_in_backend_invoke) return null;
    if (isPathAllowedForFrontend(path)) return null;
    return coreError(response_buf, cmd, "forbidden");
}

/// shell/dialog allowlist 게이트 (opt-in). backend invoke 우회. config 키 부재
/// (optional null) → null 반환 = 레거시 무제한(비파괴). 키 존재 시 enforce:
/// 빈 슬라이스 → 매치 0 → forbidden(deny-all), `["*"]` → 허용, 특정 → 제한.
fn shellPathGate(response_buf: []u8, cmd: []const u8, path: []const u8) ?[]const u8 {
    if (g_in_backend_invoke) return null;
    const cfg = g_config orelse return null;
    const list = cfg.shell.allowed_paths orelse return null;
    if (util.pathAllowedInRoots(path, list)) return null;
    return coreError(response_buf, cmd, "forbidden");
}
fn shellUrlGate(response_buf: []u8, cmd: []const u8, url: []const u8) ?[]const u8 {
    if (g_in_backend_invoke) return null;
    const cfg = g_config orelse return null;
    const list = cfg.shell.allowed_external_urls orelse return null;
    if (util.urlAllowedInList(url, list)) return null;
    return coreError(response_buf, cmd, "forbidden");
}
/// dialog defaultPath 게이트 — 빈 defaultPath 는 무제약(다이얼로그 자체가 사용자 중재).
fn dialogPathGate(response_buf: []u8, cmd: []const u8, path: []const u8) ?[]const u8 {
    if (g_in_backend_invoke) return null;
    if (path.len == 0) return null;
    const cfg = g_config orelse return null;
    const list = cfg.dialog.allowed_paths orelse return null;
    if (util.pathAllowedInRoots(path, list)) return null;
    return coreError(response_buf, cmd, "forbidden");
}

/// `__core__` 핸들러 공통 — JSON에서 string field 추출 후 unescape. 빈 문자열은 거부.
fn extractEscapedField(req_clean: []const u8, key: []const u8, out: []u8) ?[]const u8 {
    const raw = util.extractJsonString(req_clean, key) orelse return null;
    const n = util.unescapeJsonStr(raw, out) orelse return null;
    if (n == 0) return null;
    return out[0..n];
}

fn fsPathFromRequest(req_clean: []const u8, out: []u8) ?[]const u8 {
    return extractEscapedField(req_clean, "path", out);
}

fn fsKindName(kind: std.Io.File.Kind) []const u8 {
    return switch (kind) {
        .file => "file",
        .directory => "directory",
        .sym_link => "symlink",
        .block_device => "blockDevice",
        .character_device => "characterDevice",
        .named_pipe => "fifo",
        .unix_domain_socket => "socket",
        .whiteout => "whiteout",
        .door => "door",
        .event_port => "eventPort",
        .unknown => "unknown",
    };
}

fn handleFsReadFile(req_clean: []const u8, response_buf: []u8) ?[]const u8 {
    var path_buf: [FS_MAX_PATH_BYTES]u8 = undefined;
    const path = fsPathFromRequest(req_clean, &path_buf) orelse return coreError(response_buf, "fs_read_file", "path");
    if (fsSandboxCheck(response_buf, "fs_read_file", path)) |err| return err;

    var text_buf: [FS_MAX_TEXT_BYTES]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&text_buf);
    const text = std.Io.Dir.cwd().readFileAlloc(runtime.io, path, fba.allocator(), .limited(FS_MAX_TEXT_BYTES)) catch |err| {
        // FBA가 OOM을 던지는 케이스는 8KiB 초과가 유일 → too_large로 surface.
        const code: []const u8 = if (err == error.OutOfMemory or err == error.StreamTooLong) "too_large" else "read";
        return coreError(response_buf, "fs_read_file", code);
    };

    var esc_buf: [util.MAX_RESPONSE]u8 = undefined;
    const esc_len = util.escapeJsonStrFull(text, &esc_buf) orelse return coreError(response_buf, "fs_read_file", "too_large");
    return std.fmt.bufPrint(
        response_buf,
        "{{\"from\":\"zig-core\",\"cmd\":\"fs_read_file\",\"success\":true,\"text\":\"{s}\"}}",
        .{esc_buf[0..esc_len]},
    ) catch null;
}

fn handleFsWriteFile(req_clean: []const u8, response_buf: []u8) ?[]const u8 {
    var path_buf: [FS_MAX_PATH_BYTES]u8 = undefined;
    const path = fsPathFromRequest(req_clean, &path_buf) orelse return coreError(response_buf, "fs_write_file", "path");
    if (fsSandboxCheck(response_buf, "fs_write_file", path)) |err| return err;
    const raw_text = util.extractJsonString(req_clean, "text") orelse "";

    var text_buf: [FS_MAX_TEXT_BYTES]u8 = undefined;
    const text_len = util.unescapeJsonStr(raw_text, &text_buf) orelse return coreError(response_buf, "fs_write_file", "too_large");

    var file = std.Io.Dir.cwd().createFile(runtime.io, path, .{}) catch return coreError(response_buf, "fs_write_file", "write");
    defer file.close(runtime.io);
    var writer_buf: [4096]u8 = undefined;
    var fw = file.writer(runtime.io, &writer_buf);
    fw.interface.writeAll(text_buf[0..text_len]) catch return coreError(response_buf, "fs_write_file", "write");
    fw.interface.flush() catch return coreError(response_buf, "fs_write_file", "write");

    return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"fs_write_file\",\"success\":true}}", .{}) catch null;
}

fn handleFsStat(req_clean: []const u8, response_buf: []u8) ?[]const u8 {
    var path_buf: [FS_MAX_PATH_BYTES]u8 = undefined;
    const path = fsPathFromRequest(req_clean, &path_buf) orelse return coreError(response_buf, "fs_stat", "path");
    if (fsSandboxCheck(response_buf, "fs_stat", path)) |err| return err;
    const st = std.Io.Dir.cwd().statFile(runtime.io, path, .{}) catch return coreError(response_buf, "fs_stat", "not_found");
    // ns since epoch → ms — JS `Date(ms)` 호환 + 2^53 안전 범위 확보 (ns 그대로면 ~104일 후 손실).
    const mtime_ms = @divFloor(st.mtime.nanoseconds, 1_000_000);
    return std.fmt.bufPrint(
        response_buf,
        "{{\"from\":\"zig-core\",\"cmd\":\"fs_stat\",\"success\":true,\"type\":\"{s}\",\"size\":{d},\"mtime\":{d}}}",
        .{ fsKindName(st.kind), st.size, mtime_ms },
    ) catch null;
}

fn handleFsMkdir(req_clean: []const u8, response_buf: []u8) ?[]const u8 {
    var path_buf: [FS_MAX_PATH_BYTES]u8 = undefined;
    const path = fsPathFromRequest(req_clean, &path_buf) orelse return coreError(response_buf, "fs_mkdir", "path");
    if (fsSandboxCheck(response_buf, "fs_mkdir", path)) |err| return err;
    const recursive = util.extractJsonBool(req_clean, "recursive") orelse false;
    if (recursive) {
        // recursive=true는 createDirPath 자체가 idempotent (POSIX `mkdir -p`).
        std.Io.Dir.cwd().createDirPath(runtime.io, path) catch return coreError(response_buf, "fs_mkdir", "mkdir");
    } else {
        // POSIX mkdir(2) / Node `fs.mkdir(p)` 호환 — 이미 존재하면 명시적 exists 에러.
        std.Io.Dir.cwd().createDir(runtime.io, path, .default_dir) catch |err| {
            const code: []const u8 = if (err == error.PathAlreadyExists) "exists" else "mkdir";
            return coreError(response_buf, "fs_mkdir", code);
        };
    }
    return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"fs_mkdir\",\"success\":true}}", .{}) catch null;
}

fn handleFsRm(req_clean: []const u8, response_buf: []u8) ?[]const u8 {
    var path_buf: [FS_MAX_PATH_BYTES]u8 = undefined;
    const path = fsPathFromRequest(req_clean, &path_buf) orelse return coreError(response_buf, "fs_rm", "path");
    if (fsSandboxCheck(response_buf, "fs_rm", path)) |err| return err;
    const recursive = util.extractJsonBool(req_clean, "recursive") orelse false;
    const force = util.extractJsonBool(req_clean, "force") orelse false;

    const cwd = std.Io.Dir.cwd();
    if (recursive) {
        // deleteTree는 not-exist를 자체 swallow → force는 다른 에러 swallow에만 영향.
        cwd.deleteTree(runtime.io, path) catch {
            if (!force) return coreError(response_buf, "fs_rm", "rm");
        };
    } else {
        cwd.deleteFile(runtime.io, path) catch |err| switch (err) {
            error.FileNotFound => if (!force) return coreError(response_buf, "fs_rm", "not_found"),
            error.IsDir => return coreError(response_buf, "fs_rm", "is_dir"),
            else => return coreError(response_buf, "fs_rm", "rm"),
        };
    }
    return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"fs_rm\",\"success\":true}}", .{}) catch null;
}

fn handleFsReadDir(req_clean: []const u8, response_buf: []u8) ?[]const u8 {
    var path_buf: [FS_MAX_PATH_BYTES]u8 = undefined;
    const path = fsPathFromRequest(req_clean, &path_buf) orelse return coreError(response_buf, "fs_readdir", "path");
    if (fsSandboxCheck(response_buf, "fs_readdir", path)) |err| return err;
    var dir = std.Io.Dir.cwd().openDir(runtime.io, path, .{ .iterate = true }) catch return coreError(response_buf, "fs_readdir", "open");
    defer dir.close(runtime.io);

    // 닫는 `]}}` 3바이트 + 안전 마진을 reserve해 partial JSON으로 잘리는 것을 방지.
    const tail_reserve: usize = 8;
    var out_pos: usize = 0;
    out_pos += (std.fmt.bufPrint(response_buf[out_pos..], "{{\"from\":\"zig-core\",\"cmd\":\"fs_readdir\",\"success\":true,\"entries\":[", .{}) catch return null).len;
    var iter = dir.iterate();
    var first = true;
    while (iter.next(runtime.io) catch return coreError(response_buf, "fs_readdir", "read")) |entry| {
        var esc_name: [1024]u8 = undefined;
        // entry name escape 실패 = 1024바이트 한도 초과. silent skip 대신 명시적 too_large.
        const n = util.escapeJsonStrFull(entry.name, &esc_name) orelse return coreError(response_buf, "fs_readdir", "too_large");
        const sep: []const u8 = if (first) "" else ",";
        const remaining = response_buf.len - out_pos;
        if (remaining <= tail_reserve) return coreError(response_buf, "fs_readdir", "too_large");
        const part = std.fmt.bufPrint(
            response_buf[out_pos .. response_buf.len - tail_reserve],
            "{s}{{\"name\":\"{s}\",\"type\":\"{s}\"}}",
            .{ sep, esc_name[0..n], fsKindName(entry.kind) },
        ) catch return coreError(response_buf, "fs_readdir", "too_large");
        out_pos += part.len;
        first = false;
    }
    out_pos += (std.fmt.bufPrint(response_buf[out_pos..], "]}}", .{}) catch return null).len;
    return response_buf[0..out_pos];
}

fn handleDialogShowOpenDialog(req_clean: []const u8, response_buf: []u8) ?[]const u8 {
    var arena_buf: [DIALOG_PARSE_ARENA]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arena_buf);
    const arena = fba.allocator();

    const parsed = std.json.parseFromSlice(OpenDialogJson, arena, req_clean, .{
        .ignore_unknown_fields = true,
    }) catch {
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"dialog_show_open_dialog\",\"canceled\":true,\"filePaths\":[],\"error\":\"parse\"}}",
            .{},
        ) catch null;
    };
    defer parsed.deinit();
    const opts = parsed.value;

    if (dialogPathGate(response_buf, "dialog_show_open_dialog", opts.defaultPath)) |e| return e;

    const filters = convertFilters(arena, opts.filters) catch &[_]cef.FileFilter{};
    var dialog_buf: [util.MAX_RESPONSE]u8 = undefined;
    const dialog_json = cef.showOpenDialog(.{
        .title = opts.title,
        .default_path = opts.defaultPath,
        .button_label = opts.buttonLabel,
        .message = opts.message,
        .can_choose_files = hasProp(opts.properties, "openFile") or !hasProp(opts.properties, "openDirectory"),
        .can_choose_directories = hasProp(opts.properties, "openDirectory"),
        .allows_multiple_selection = hasProp(opts.properties, "multiSelections"),
        .shows_hidden_files = hasProp(opts.properties, "showHiddenFiles"),
        .can_create_directories = hasProp(opts.properties, "createDirectory") or !hasProp(opts.properties, "openDirectory"),
        .no_resolve_aliases = hasProp(opts.properties, "noResolveAliases"),
        .treat_packages_as_dirs = hasProp(opts.properties, "treatPackageAsDirectory"),
        .filters = filters,
        .parent_window = dialogParentNSWindow(opts.windowId),
    }, &dialog_buf);

    return std.fmt.bufPrint(
        response_buf,
        "{{\"from\":\"zig-core\",\"cmd\":\"dialog_show_open_dialog\",{s}",
        .{dialog_json[1..]}, // strip leading '{' from dialog_json, keep trailing '}'
    ) catch null;
}

// ============================================
// Tray handlers — std.json으로 menu items 파싱
// ============================================

const TrayMenuItemJson = struct {
    type: []const u8 = "", // "separator"면 separator, 아니면 일반 item
    label: []const u8 = "",
    click: []const u8 = "",
};

const TraySetMenuJson = struct {
    trayId: u32 = 0,
    items: []const TrayMenuItemJson = &.{},
};

fn handleTraySetMenu(req_clean: []const u8, response_buf: []u8) ?[]const u8 {
    var arena_buf: [DIALOG_PARSE_ARENA]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arena_buf);
    const arena = fba.allocator();

    const parsed = std.json.parseFromSlice(TraySetMenuJson, arena, req_clean, .{
        .ignore_unknown_fields = true,
    }) catch {
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"tray_set_menu\",\"success\":false,\"error\":\"parse\"}}", .{}) catch null;
    };
    defer parsed.deinit();
    const opts = parsed.value;

    var items = arena.alloc(cef.TrayMenuItem, opts.items.len) catch return null;
    for (opts.items, 0..) |it, i| {
        if (std.mem.eql(u8, it.type, "separator")) {
            items[i] = .separator;
        } else {
            items[i] = .{ .item = .{ .label = it.label, .click = it.click } };
        }
    }

    const ok = cef.setTrayMenu(opts.trayId, items);
    return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"tray_set_menu\",\"success\":{}}}", .{ok}) catch null;
}

// ============================================
// webRequest — URL glob blocklist 등록
// ============================================

const WebRequestSetBlockedUrlsJson = struct {
    patterns: []const []const u8 = &.{},
};

fn handleWebRequestSetBlockedUrls(req_clean: []const u8, response_buf: []u8) ?[]const u8 {
    var arena_buf: [DIALOG_PARSE_ARENA]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arena_buf);
    const arena = fba.allocator();

    const parsed = std.json.parseFromSlice(WebRequestSetBlockedUrlsJson, arena, req_clean, .{
        .ignore_unknown_fields = true,
    }) catch {
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"web_request_set_blocked_urls\",\"success\":false,\"error\":\"parse\"}}",
            .{},
        ) catch null;
    };
    defer parsed.deinit();

    const n = cef.webRequestSetBlockedUrls(parsed.value.patterns);
    return std.fmt.bufPrint(
        response_buf,
        "{{\"from\":\"zig-core\",\"cmd\":\"web_request_set_blocked_urls\",\"count\":{d}}}",
        .{n},
    ) catch null;
}

fn handleWebRequestSetListenerFilter(req_clean: []const u8, response_buf: []u8) ?[]const u8 {
    var arena_buf: [DIALOG_PARSE_ARENA]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arena_buf);
    const arena = fba.allocator();

    const parsed = std.json.parseFromSlice(WebRequestSetBlockedUrlsJson, arena, req_clean, .{
        .ignore_unknown_fields = true,
    }) catch {
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"web_request_set_listener_filter\",\"success\":false,\"error\":\"parse\"}}",
            .{},
        ) catch null;
    };
    defer parsed.deinit();

    const n = cef.webRequestSetListenerFilter(parsed.value.patterns);
    return std.fmt.bufPrint(
        response_buf,
        "{{\"from\":\"zig-core\",\"cmd\":\"web_request_set_listener_filter\",\"count\":{d}}}",
        .{n},
    ) catch null;
}

// ============================================
// Global shortcut handlers
// ============================================

fn globalShortcutStatusToErrorCode(status: cef.GlobalShortcutStatus) []const u8 {
    return switch (status) {
        .ok => "",
        .capacity => "capacity_full",
        .duplicate => "already_registered",
        .parse => "parse_failed",
        .os_reject => "os_reject",
        .too_long => "too_long",
    };
}

fn handleGlobalShortcutRegister(req_clean: []const u8, response_buf: []u8) ?[]const u8 {
    var accel_buf: [128]u8 = undefined;
    const accel = extractEscapedField(req_clean, "accelerator", &accel_buf) orelse
        return coreError(response_buf, "global_shortcut_register", "accelerator");

    var click_buf: [128]u8 = undefined;
    const click = extractEscapedField(req_clean, "click", &click_buf) orelse
        return coreError(response_buf, "global_shortcut_register", "click");

    const status = cef.globalShortcutRegister(accel, click);
    if (status != .ok) return coreError(response_buf, "global_shortcut_register", globalShortcutStatusToErrorCode(status));
    return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"global_shortcut_register\",\"success\":true}}", .{}) catch null;
}

fn handleGlobalShortcutUnregister(req_clean: []const u8, response_buf: []u8) ?[]const u8 {
    var accel_buf: [128]u8 = undefined;
    const accel = extractEscapedField(req_clean, "accelerator", &accel_buf) orelse
        return coreError(response_buf, "global_shortcut_unregister", "accelerator");
    const ok = cef.globalShortcutUnregister(accel);
    return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"global_shortcut_unregister\",\"success\":{}}}", .{ok}) catch null;
}

fn handleGlobalShortcutIsRegistered(req_clean: []const u8, response_buf: []u8) ?[]const u8 {
    var accel_buf: [128]u8 = undefined;
    const accel = extractEscapedField(req_clean, "accelerator", &accel_buf) orelse
        return coreError(response_buf, "global_shortcut_is_registered", "accelerator");
    const registered = cef.globalShortcutIsRegistered(accel);
    return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"global_shortcut_is_registered\",\"registered\":{}}}", .{registered}) catch null;
}

// ============================================
// Application menu handlers — std.json.Value로 재귀 submenu 파싱
// ============================================

fn handleMenuSetApplicationMenu(req_clean: []const u8, response_buf: []u8) ?[]const u8 {
    // submenu 깊이가 깊어질 수 있어 dialog 대비 2배 arena.
    var arena_buf: [DIALOG_PARSE_ARENA * 2]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arena_buf);
    const arena = fba.allocator();

    const items = parseMenuItemsFromRequest(arena, req_clean) catch return coreError(response_buf, "menu_set_application_menu", "parse");
    const ok = cef.setApplicationMenu(items);
    return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"menu_set_application_menu\",\"success\":{}}}", .{ok}) catch null;
}

/// Electron `Menu.popup({x?,y?})` — 임의 위치 컨텍스트 메뉴. items 파싱은
/// menu_set_application_menu 와 동일(parseMenuItemsFromRequest). 선택은
/// 기존 `menu:click` 이벤트로 수신(setApplicationMenu 와 동일 경로).
fn handleMenuPopup(req_clean: []const u8, response_buf: []u8) ?[]const u8 {
    var arena_buf: [DIALOG_PARSE_ARENA * 2]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arena_buf);
    const arena = fba.allocator();

    const items = parseMenuItemsFromRequest(arena, req_clean) catch return coreError(response_buf, "menu_popup", "parse");
    const x = util.extractJsonFloat(req_clean, "x");
    const y = util.extractJsonFloat(req_clean, "y");
    const ok = cef.popupContextMenu(items, x, y);
    return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"menu_popup\",\"success\":{}}}", .{ok}) catch null;
}

fn parseMenuItemsFromRequest(arena: std.mem.Allocator, req_clean: []const u8) MenuParseError![]cef.ApplicationMenuItem {
    // FixedBufferAllocator로 알로케이션이 끝난 뒤 arena 전체가 한 번에 회수되므로
    // parsed.deinit()은 no-op. 따라서 호출하지 않는다.
    const parsed = std.json.parseFromSlice(std.json.Value, arena, req_clean, .{}) catch return error.InvalidMenuItem;
    if (parsed.value != .object) return error.InvalidMenuItem;
    const items_val = parsed.value.object.get("items") orelse return error.InvalidMenuItem;
    if (items_val != .array) return error.InvalidMenuItem;
    return parseApplicationMenuItems(arena, items_val.array.items);
}

const MenuParseError = error{ OutOfMemory, InvalidMenuItem };

fn parseApplicationMenuItems(arena: std.mem.Allocator, values: []const std.json.Value) MenuParseError![]cef.ApplicationMenuItem {
    var out = try arena.alloc(cef.ApplicationMenuItem, values.len);
    for (values, 0..) |v, i| out[i] = try parseApplicationMenuItem(arena, v);
    return out;
}

fn parseApplicationMenuItem(arena: std.mem.Allocator, value: std.json.Value) MenuParseError!cef.ApplicationMenuItem {
    if (value != .object) return error.InvalidMenuItem;
    const obj = value.object;
    const typ = util.jsonObjectGetString(obj,"type") orelse "";
    if (std.mem.eql(u8, typ, "separator")) return .separator;

    const label = util.jsonObjectGetString(obj,"label") orelse "";
    const click = util.jsonObjectGetString(obj,"click") orelse "";
    const enabled = util.jsonObjectGetBool(obj,"enabled") orelse true;

    if (std.mem.eql(u8, typ, "submenu") or obj.get("submenu") != null) {
        const sub_val = obj.get("submenu") orelse return error.InvalidMenuItem;
        if (sub_val != .array) return error.InvalidMenuItem;
        return .{ .submenu = .{
            .label = label,
            .enabled = enabled,
            .items = try parseApplicationMenuItems(arena, sub_val.array.items),
        } };
    }
    if (std.mem.eql(u8, typ, "checkbox")) {
        return .{ .checkbox = .{
            .label = label,
            .click = click,
            .checked = util.jsonObjectGetBool(obj,"checked") orelse false,
            .enabled = enabled,
        } };
    }
    return .{ .item = .{
        .label = label,
        .click = click,
        .enabled = enabled,
    } };
}

/// notification id 카운터 — `suji-notif-{N}` 형식 식별자 발급.
var g_next_notification_id: u32 = 1;

fn nextNotificationId() u32 {
    const id = g_next_notification_id;
    g_next_notification_id += 1;
    return id;
}

/// cef.zig native click target이 NSApp UI thread에서 호출 → BackendRegistry.global 안전 access.
/// data는 호출자가 std.fmt 포맷으로 미리 빌드한 JSON 페이로드.
/// 1KB 버퍼 — 일반 emit은 ~50B, 가장 큰 정규 caller(globalShortcut: accel256+click256 escape)도
/// ~570B로 충분. page-title-updated는 worst-case ~1.5KB라 자체 버퍼로 emitBusRaw 직행.
fn emitToBus(channel: []const u8, comptime fmt: []const u8, args: anytype) void {
    var data_buf: [1024]u8 = undefined;
    const data = std.fmt.bufPrint(&data_buf, fmt, args) catch return;
    emitBusRaw(channel, data);
}

/// 이미 빌드된 JSON 페이로드를 EventBus로 직접 전달 — 큰 페이로드(page-title-updated 등)가
/// emitToBus의 1KB 버퍼를 우회해 자체 스택 버퍼를 쓸 수 있게 한다.
fn emitBusRaw(channel: []const u8, data: []const u8) void {
    const registry = suji.BackendRegistry.global orelse return;
    const bus = registry.event_bus orelse return;
    bus.emit(channel, data);
}

fn notificationEmitHandler(notification_id: []const u8) void {
    var id_esc: [128]u8 = undefined;
    const id_n = util.escapeJsonStrFull(notification_id, &id_esc) orelse return;
    emitToBus("notification:click", "{{\"notificationId\":\"{s}\"}}", .{id_esc[0..id_n]});
}

fn trayEmitHandler(tray_id: u32, click: []const u8) void {
    var click_esc: [256]u8 = undefined;
    const click_n = util.escapeJsonStrFull(click, &click_esc) orelse return;
    emitToBus("tray:menu-click", "{{\"trayId\":{d},\"click\":\"{s}\"}}", .{ tray_id, click_esc[0..click_n] });
}

fn menuEmitHandler(click: []const u8) void {
    var click_esc: [256]u8 = undefined;
    const click_n = util.escapeJsonStrFull(click, &click_esc) orelse return;
    emitToBus("menu:click", "{{\"click\":\"{s}\"}}", .{click_esc[0..click_n]});
}

/// powerMonitor: power_monitor.m이 dispatch한 4 이벤트(suspend/resume/lock-screen/unlock-screen)
/// 를 `power:<event>` 채널로 emit. event는 "suspend"|"resume"|"lock-screen"|"unlock-screen".
fn powerMonitorEmitHandler(event: [*:0]const u8) callconv(.c) void {
    const event_slice = std.mem.span(event);
    // 화면 잠금 상태 추적 — getSystemIdleState "locked" 판정용(Electron 동등).
    if (std.mem.eql(u8, event_slice, "lock-screen")) {
        cef.powerMonitorSetScreenLocked(true);
    } else if (std.mem.eql(u8, event_slice, "unlock-screen")) {
        cef.powerMonitorSetScreenLocked(false);
    }
    var ch_buf: [64]u8 = undefined;
    const channel = std.fmt.bufPrint(&ch_buf, "power:{s}", .{event_slice}) catch return;
    emitBusRaw(channel, "{}");
}

/// nativeTheme: NSAppearance KVO가 fire되면 현재 dark 여부를 payload로 emit.
fn nativeThemeEmitHandler() callconv(.c) void {
    const dark = cef.nativeThemeIsDark();
    var buf: [64]u8 = undefined;
    const payload = std.fmt.bufPrint(&buf, "{{\"dark\":{}}}", .{dark}) catch return;
    emitBusRaw("nativeTheme:updated", payload);
}

/// webRequest: cef.zig의 onBeforeResourceLoad/onResourceLoadComplete가 IO thread에서
/// 호출. EventBus.emit이 mutex로 thread-safe하므로 그대로 dispatch.
fn webRequestEmitHandler(channel: [*:0]const u8, payload: [*:0]const u8) callconv(.c) void {
    const ch = std.mem.span(channel);
    const data = std.mem.span(payload);
    emitBusRaw(ch, data);
}

fn globalShortcutEmitHandler(accelerator: []const u8, click: []const u8) void {
    var accel_esc: [256]u8 = undefined;
    var click_esc: [256]u8 = undefined;
    const accel_n = util.escapeJsonStrFull(accelerator, &accel_esc) orelse return;
    const click_n = util.escapeJsonStrFull(click, &click_esc) orelse return;
    emitToBus("globalShortcut:trigger", "{{\"accelerator\":\"{s}\",\"click\":\"{s}\"}}", .{ accel_esc[0..accel_n], click_esc[0..click_n] });
}

/// CEF browser native handle → WindowManager.windowId 변환 helper.
fn windowIdFromHandle(handle: u64) ?u32 {
    const wm = window_mod.WindowManager.global orelse return null;
    return wm.findByNativeHandle(handle);
}

fn windowResizedHandler(handle: u64, x: f64, y: f64, width: f64, height: f64) void {
    const win_id = windowIdFromHandle(handle) orelse return;
    emitToBus("window:resized", "{{\"windowId\":{d},\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d}}}", .{ win_id, @as(i64, @intFromFloat(x)), @as(i64, @intFromFloat(y)), @as(i64, @intFromFloat(width)), @as(i64, @intFromFloat(height)) });
}

fn windowMovedHandler(handle: u64, x: f64, y: f64) void {
    const win_id = windowIdFromHandle(handle) orelse return;
    emitToBus("window:moved", "{{\"windowId\":{d},\"x\":{d},\"y\":{d}}}", .{ win_id, @as(i64, @intFromFloat(x)), @as(i64, @intFromFloat(y)) });
}

/// `{windowId}` 단일 필드 이벤트 발화 — focus/blur/minimize/restore/maximize/
/// unmaximize/enter-full-screen/leave-full-screen 공통.
fn emitWindowIdEvent(comptime channel: []const u8, handle: u64) void {
    const win_id = windowIdFromHandle(handle) orelse return;
    emitToBus(channel, "{{\"windowId\":{d}}}", .{win_id});
}

fn windowFocusHandler(handle: u64) void {
    emitWindowIdEvent("window:focus", handle);
}
fn windowBlurHandler(handle: u64) void {
    emitWindowIdEvent("window:blur", handle);
}
fn windowMinimizeHandler(handle: u64) void {
    emitWindowIdEvent(window_mod.events.minimize, handle);
}
fn windowRestoreHandler(handle: u64) void {
    emitWindowIdEvent(window_mod.events.restore, handle);
}
fn windowMaximizeHandler(handle: u64) void {
    emitWindowIdEvent(window_mod.events.maximize, handle);
}
fn windowUnmaximizeHandler(handle: u64) void {
    emitWindowIdEvent(window_mod.events.unmaximize, handle);
}
fn windowEnterFullScreenHandler(handle: u64) void {
    emitWindowIdEvent(window_mod.events.enter_full_screen, handle);
}
fn windowLeaveFullScreenHandler(handle: u64) void {
    emitWindowIdEvent(window_mod.events.leave_full_screen, handle);
}

fn windowWillResizeHandler(handle: u64, curr_w: f64, curr_h: f64, proposed_w: *f64, proposed_h: *f64) void {
    const wm = window_mod.WindowManager.global orelse return;
    wm.applyWillResizeForHandle(handle, curr_w, curr_h, proposed_w, proposed_h);
}

/// CEF find_handler.OnFindResult는 incremental(검색 진행) + final 두 종류로 발화. final만
/// frontend에 forward해 검색어 입력 중 noise 차단 (Electron의 `found-in-page` 의도와 동일).
fn windowFindResultHandler(handle: u64, identifier: i32, count: i32, active_match_ordinal: i32, final_update: bool) void {
    if (!final_update) return;
    const win_id = windowIdFromHandle(handle) orelse return;
    emitToBus(
        window_mod.events.find_result,
        "{{\"windowId\":{d},\"identifier\":{d},\"count\":{d},\"activeMatchOrdinal\":{d}}}",
        .{ win_id, identifier, count, active_match_ordinal },
    );
}

/// `app.quitOnAllWindowsClosed: true` 시 EventBus에 등록되는 listener — window:all-closed 발화 시
/// 자동으로 cef.quit() 호출. C ABI라 ([*c]u8, [*c]u8, ?*anyopaque) 시그니처.
fn allClosedAutoQuit(_: [*c]const u8, _: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
    cef.quit();
}

fn windowReadyToShowHandler(handle: u64) void {
    emitWindowIdEvent(window_mod.events.ready_to_show, handle);
}

fn windowTitleChangeHandler(handle: u64, title: []const u8) void {
    const win_id = windowIdFromHandle(handle) orelse return;
    // JSON escape 최악 6×(`\uXXXX`) — cef.MAX_TITLE_BYTES와 페어. emitToBus의 1KB 버퍼는
    // 이 케이스(~1.5KB)를 못 담아서 자체 페이로드 버퍼로 emitBusRaw 직행. escape 결과를
    // payload_buf 안에 직접 써 중간 버퍼 한 단계 제거.
    var payload_buf: [cef.MAX_TITLE_BYTES * 6 + 64]u8 = undefined;
    const prefix = std.fmt.bufPrint(&payload_buf, "{{\"windowId\":{d},\"title\":\"", .{win_id}) catch return;
    const after_prefix = prefix.len;
    const escape_room = payload_buf.len - after_prefix - 2; // "\"}" 마진
    const title_n = util.escapeJsonStrFull(title, payload_buf[after_prefix..][0..escape_room]) orelse {
        std.debug.print(
            "[suji] page-title-updated: escape overflow (title bytes={d}) — event dropped\n",
            .{title.len},
        );
        return;
    };
    const tail = after_prefix + title_n;
    payload_buf[tail] = '"';
    payload_buf[tail + 1] = '}';
    emitBusRaw(window_mod.events.page_title_updated, payload_buf[0 .. tail + 2]);
}

const window_lifecycle_handlers: cef.WindowLifecycleHandlers = .{
    .resized = &windowResizedHandler,
    .moved = &windowMovedHandler,
    .focus = &windowFocusHandler,
    .blur = &windowBlurHandler,
    .minimize = &windowMinimizeHandler,
    .restore = &windowRestoreHandler,
    .maximize = &windowMaximizeHandler,
    .unmaximize = &windowUnmaximizeHandler,
    .enter_fullscreen = &windowEnterFullScreenHandler,
    .leave_fullscreen = &windowLeaveFullScreenHandler,
    .will_resize = &windowWillResizeHandler,
};

fn handleDialogShowSaveDialog(req_clean: []const u8, response_buf: []u8) ?[]const u8 {
    var arena_buf: [DIALOG_PARSE_ARENA]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arena_buf);
    const arena = fba.allocator();

    const parsed = std.json.parseFromSlice(SaveDialogJson, arena, req_clean, .{
        .ignore_unknown_fields = true,
    }) catch {
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"dialog_show_save_dialog\",\"canceled\":true,\"filePath\":\"\",\"error\":\"parse\"}}",
            .{},
        ) catch null;
    };
    defer parsed.deinit();
    const opts = parsed.value;

    if (dialogPathGate(response_buf, "dialog_show_save_dialog", opts.defaultPath)) |e| return e;

    const filters = convertFilters(arena, opts.filters) catch &[_]cef.FileFilter{};
    var dialog_buf: [util.MAX_RESPONSE]u8 = undefined;
    const dialog_json = cef.showSaveDialog(.{
        .title = opts.title,
        .default_path = opts.defaultPath,
        .button_label = opts.buttonLabel,
        .message = opts.message,
        .name_field_label = opts.nameFieldLabel,
        .shows_hidden_files = hasProp(opts.properties, "showHiddenFiles"),
        .can_create_directories = !hasProp(opts.properties, "createDirectory") or hasProp(opts.properties, "createDirectory"),
        .show_overwrite_confirmation = !hasProp(opts.properties, "noOverwriteConfirmation"),
        .shows_tag_field = opts.showsTagField,
        .filters = filters,
        .parent_window = dialogParentNSWindow(opts.windowId),
    }, &dialog_buf);

    return std.fmt.bufPrint(
        response_buf,
        "{{\"from\":\"zig-core\",\"cmd\":\"dialog_show_save_dialog\",{s}",
        .{dialog_json[1..]},
    ) catch null;
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
