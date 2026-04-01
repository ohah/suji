const std = @import("std");
const suji = @import("root.zig");
const util = @import("util");
const cef = @import("platform/cef.zig");

pub fn main() !void {
    // CEF 서브프로세스 처리 (렌더러/GPU 등 — 메인이면 통과)
    cef.executeSubprocess();

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

    // --cef 플래그 감지
    var use_cef = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--cef")) use_cef = true;
    }

    if (std.mem.eql(u8, command, "init")) {
        try runInit(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "dev")) {
        if (use_cef) {
            try runDevCef(allocator);
        } else {
            try runDev(allocator);
        }
    } else if (std.mem.eql(u8, command, "build")) {
        try runBuild(allocator);
    } else if (std.mem.eql(u8, command, "run")) {
        if (use_cef) {
            try runProdCef(allocator);
        } else {
            try runProd(allocator);
        }
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
fn runDev(allocator: std.mem.Allocator) !void {
    var config = suji.Config.load(allocator) catch {
        std.debug.print("Error: suji.toml or suji.json not found.\n", .{});
        return;
    };
    defer config.deinit();

    std.debug.print("[suji] dev mode - {s} v{s}\n", .{ config.app.name, config.app.version });

    // 1. 백엔드 + 플러그인 빌드 + 로드
    var registry = suji.BackendRegistry.init(allocator);
    defer registry.deinit();
    registry.setGlobal();
    try loadPluginsFromConfig(allocator, &config, &registry, false);
    try loadBackendsFromConfig(allocator, &config, &registry, false);

    // 2. 프론트엔드 dev 서버
    std.debug.print("[suji] starting frontend dev server...\n", .{});
    var frontend_proc = startFrontendDev(allocator, config.frontend.dir) catch |err| {
        std.debug.print("[suji] frontend dev server failed: {}, opening without frontend\n", .{err});
        try openWindow(allocator, &config, &registry, .dev);
        return;
    };
    defer _ = frontend_proc.kill() catch {};

    std.debug.print("[suji] waiting for {s}...\n", .{config.frontend.dev_url});
    std.Thread.sleep(2 * std.time.ns_per_s);

    // 3. WebView
    try openWindow(allocator, &config, &registry, .dev);
}

// ============================================
// suji build
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

    std.debug.print("[suji] build complete!\n", .{});
}

// ============================================
// suji run
// ============================================
fn runProd(allocator: std.mem.Allocator) !void {
    var config = suji.Config.load(allocator) catch {
        std.debug.print("Error: suji.toml or suji.json not found.\n", .{});
        return;
    };
    defer config.deinit();

    std.debug.print("[suji] production mode - {s}\n", .{config.app.name});

    var registry = suji.BackendRegistry.init(allocator);
    defer registry.deinit();
    registry.setGlobal();
    try loadPluginsFromConfig(allocator, &config, &registry, true);
    try loadBackendsFromConfig(allocator, &config, &registry, true);

    try openWindow(allocator, &config, &registry, .dist);
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

/// 플러그인 디렉토리 탐색: plugins/{name}/ 찾기
fn getPluginDir(allocator: std.mem.Allocator, name: []const u8) ?[]const u8 {
    // 프로젝트 로컬 plugins/ (존재 여부는 하류에서 확인)
    return std.fmt.allocPrint(allocator, "plugins/{s}", .{name}) catch null;
}

/// suji-plugin.json에서 lang 읽기
fn readPluginLang(allocator: std.mem.Allocator, plugin_dir: []const u8) ?[]const u8 {
    const json_path = std.fmt.allocPrint(allocator, "{s}/suji-plugin.json", .{plugin_dir}) catch return null;
    defer allocator.free(json_path);

    const content = std.fs.cwd().readFileAlloc(allocator, json_path, 1024 * 16) catch return null;
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

fn loadBackendsFromConfig(allocator: std.mem.Allocator, config: *const suji.Config, registry: *suji.BackendRegistry, release: bool) !void {
    if (config.isMultiBackend()) {
        if (config.backends) |backends| {
            for (backends) |be| {
                // Zig도 다른 언어와 동일하게 dlopen
                std.debug.print("[suji] building {s} ({s})...\n", .{ be.name, be.lang });
                buildBackendByLang(allocator, be.lang, be.entry, release) catch |err| {
                    std.debug.print("[suji] build failed: {}\n", .{err});
                    continue;
                };
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
        const path = getDylibPath(allocator, be.lang, be.entry, release) catch return;
        defer allocator.free(path);
        var path_z: [1024]u8 = undefined;
        const path_zt = util.nullTerminate(path, &path_z);
        registry.register(be.lang, path_zt) catch |err| {
            std.debug.print("[suji] load failed: {}\n", .{err});
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
    } else if (std.mem.eql(u8, lang, "zig")) {
        // Zig 백엔드는 자체 build.zig가 있어야 함
        // --prefix로 빌드 결과물을 entry 디렉토리에 설치
        const prefix = try std.fmt.allocPrint(allocator, "--prefix={s}/zig-out", .{entry});
        defer allocator.free(prefix);
        // entry 디렉토리에서 zig build 실행
        var child = std.process.Child.init(&.{ "zig", "build" }, allocator);
        const abs_entry = std.fs.cwd().realpathAlloc(allocator, entry) catch null;
        defer if (abs_entry) |p| allocator.free(p);
        child.cwd = abs_entry;
        child.stderr_behavior = .Inherit;
        child.stdout_behavior = .Inherit;
        try child.spawn();
        const result = try child.wait();
        switch (result) {
            .Exited => |code| if (code != 0) return error.CommandFailed,
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
    var child = std.process.Child.init(argv, allocator);
    child.stderr_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    try child.spawn();
    const result = try child.wait();
    switch (result) {
        .Exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
}

fn runCmdEnv(allocator: std.mem.Allocator, argv: []const []const u8, env_pairs: []const [2][]const u8) !void {
    var child = std.process.Child.init(argv, allocator);
    child.stderr_behavior = .Inherit;
    child.stdout_behavior = .Inherit;

    // 환경 변수 설정
    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();
    for (env_pairs) |pair| {
        try env_map.put(pair[0], pair[1]);
    }
    child.env_map = &env_map;

    try child.spawn();
    const result = try child.wait();
    switch (result) {
        .Exited => |code| if (code != 0) return error.CommandFailed,
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
        std.fs.cwd().access(p, .{}) catch break :blk false;
        break :blk true;
    };

    var child = std.process.Child.init(
        if (has_bun)
            &.{ "bun", "--cwd", frontend_dir, "dev" }
        else
            &.{ "npm", "--prefix", frontend_dir, "run", "dev" },
        allocator,
    );
    child.stderr_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    try child.spawn();
    return child;
}

fn buildFrontend(allocator: std.mem.Allocator, frontend_dir: []const u8) !void {
    var buf: [512]u8 = undefined;
    const p = std.fmt.bufPrint(&buf, "{s}/bun.lock", .{frontend_dir}) catch return;
    const has_bun = blk: {
        std.fs.cwd().access(p, .{}) catch break :blk false;
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

fn runDevCef(allocator: std.mem.Allocator) !void {
    var config = suji.Config.load(allocator) catch {
        std.debug.print("Error: suji.toml or suji.json not found.\n", .{});
        return;
    };
    defer config.deinit();

    std.debug.print("[suji] CEF dev mode - {s} v{s}\n", .{ config.app.name, config.app.version });

    var registry = suji.BackendRegistry.init(allocator);
    defer registry.deinit();
    registry.setGlobal();
    try loadPluginsFromConfig(allocator, &config, &registry, false);
    try loadBackendsFromConfig(allocator, &config, &registry, false);

    // 프론트엔드 dev 서버
    std.debug.print("[suji] starting frontend dev server...\n", .{});
    var frontend_proc = startFrontendDev(allocator, config.frontend.dir) catch |err| {
        std.debug.print("[suji] frontend dev server failed: {}, opening without frontend\n", .{err});
        try openCefWindow(allocator, &config, &registry, .dev);
        return;
    };
    defer _ = frontend_proc.kill() catch {};

    std.debug.print("[suji] waiting for {s}...\n", .{config.frontend.dev_url});
    std.Thread.sleep(2 * std.time.ns_per_s);

    try openCefWindow(allocator, &config, &registry, .dev);
}

fn runProdCef(allocator: std.mem.Allocator) !void {
    var config = suji.Config.load(allocator) catch {
        std.debug.print("Error: suji.toml or suji.json not found.\n", .{});
        return;
    };
    defer config.deinit();

    std.debug.print("[suji] CEF production mode - {s}\n", .{config.app.name});

    var registry = suji.BackendRegistry.init(allocator);
    defer registry.deinit();
    registry.setGlobal();
    try loadPluginsFromConfig(allocator, &config, &registry, true);
    try loadBackendsFromConfig(allocator, &config, &registry, true);

    try openCefWindow(allocator, &config, &registry, .dist);
}

fn openCefWindow(allocator: std.mem.Allocator, config: *const suji.Config, registry: *suji.BackendRegistry, mode: WindowMode) !void {
    // EventBus 생성
    var event_bus = suji.EventBus.init(allocator);
    defer event_bus.deinit();
    registry.setEventBus(&event_bus);

    // CEF IPC 콜백 연결
    cef.setInvokeHandler(&cefInvokeHandler);
    cef.setEmitHandler(&cefEmitHandler);

    // URL 결정
    const url: ?[:0]const u8 = switch (mode) {
        .dev => config.frontend.dev_url,
        .dist => blk: {
            // TODO: dist 모드에서 suji:// 커스텀 프로토콜 사용 (Step 4)
            break :blk null;
        },
    };

    // CEF 초기화 + 브라우저 생성
    const cef_config: cef.CefConfig = .{
        .title = config.window.title,
        .width = @intCast(config.window.width),
        .height = @intCast(config.window.height),
        .url = url,
        .debug = config.window.debug,
    };
    try cef.initialize(cef_config);
    try cef.createBrowser(cef_config);

    std.debug.print("[suji] CEF window opened ({s})\n", .{if (mode == .dev) "dev" else "production"});
    cef.run();
    cef.shutdown();
}

/// CEF invoke 콜백 — BackendRegistry로 라우팅
fn cefInvokeHandler(channel: []const u8, data: []const u8, response_buf: []u8) ?[]const u8 {
    const registry = suji.BackendRegistry.global orelse return null;

    // 요청 null-terminate
    var request_buf: [8192]u8 = undefined;
    const request_len = @min(data.len, request_buf.len - 1);
    @memcpy(request_buf[0..request_len], data[0..request_len]);
    request_buf[request_len] = 0;
    const request: [*:0]const u8 = request_buf[0..request_len :0];

    // 채널 라우팅으로 백엔드 찾기 (없으면 채널명을 백엔드 이름으로 직접 시도)
    const name = registry.getBackendForChannel(channel) orelse channel;
    if (name.len == 0) return null; // 중복 채널

    const resp = registry.invoke(name, request) orelse return null;
    const len = @min(resp.len, response_buf.len);
    @memcpy(response_buf[0..len], resp[0..len]);
    registry.freeResponse(name, resp);
    return response_buf[0..len];
}

/// CEF emit 콜백 — EventBus로 전달
fn cefEmitHandler(event: []const u8, data: []const u8) void {
    const registry = suji.BackendRegistry.global orelse return;
    const bus = registry.event_bus orelse return;
    bus.emit(event, data);
}

// ============================================
// WebView
// ============================================

const WindowMode = enum { dev, dist };

fn openWindow(allocator: std.mem.Allocator, config: *const suji.Config, registry: *suji.BackendRegistry, mode: WindowMode) !void {
    var win = try suji.Window.create(.{
        .title = config.window.title,
        .width = @intCast(config.window.width),
        .height = @intCast(config.window.height),
        .debug = config.window.debug,
        .url = switch (mode) {
            .dev => config.frontend.dev_url,
            .dist => null,
        },
    });
    defer win.destroy();

    // dist 모드: file:// URL로 로드
    if (mode == .dist) {
        const dist_path = std.fmt.allocPrint(allocator, "{s}/index.html", .{config.frontend.dist_dir}) catch null;
        if (dist_path) |dp| {
            defer allocator.free(dp);
            const abs = std.fs.cwd().realpathAlloc(allocator, dp) catch null;
            if (abs) |a| {
                defer allocator.free(a);
                var url_buf: [2048]u8 = undefined;
                const url = std.fmt.bufPrint(&url_buf, "file://{s}", .{a}) catch null;
                if (url) |u| {
                    url_buf[u.len] = 0;
                    win.webview.navigate(url_buf[0..u.len :0]);
                }
            }
        }
    }

    // EventBus 생성 + WebView eval 연결
    var event_bus = suji.EventBus.init(allocator);
    defer event_bus.deinit();

    // webview_eval 연결: EventBus → JS __dispatch__
    const WebViewEvalCtx = struct {
        var wv: *suji.WebView = undefined;
        fn eval(js: [:0]const u8) void {
            wv.eval(js);
        }
    };
    WebViewEvalCtx.wv = &win.webview;
    event_bus.webview_eval = WebViewEvalCtx.eval;

    registry.setEventBus(&event_bus);

    const bridge = try allocator.create(suji.Bridge);
    bridge.* = suji.Bridge.init(&win.webview, registry);
    bridge.setEventBus(&event_bus);
    defer {
        bridge.deinit();
        allocator.destroy(bridge);
    }
    bridge.bind();

    // 에셋 서버 시작 + JS에 URL 주입
    const asset_server = suji.AssetServer.start(allocator, config.asset_dir) catch |err| blk: {
        std.debug.print("[suji] asset server failed: {}, continuing without it\n", .{err});
        break :blk null;
    };
    defer if (asset_server) |srv| srv.stop();

    if (asset_server) |srv| {
        var url_buf: [128]u8 = undefined;
        const base_url = srv.getBaseUrl(&url_buf);
        var js_buf: [256]u8 = undefined;
        const js = std.fmt.bufPrint(&js_buf, "window.__suji__.assetUrl = \"{s}\";", .{base_url}) catch null;
        if (js) |j| {
            js_buf[j.len] = 0;
            win.webview.init(js_buf[0..j.len :0]);
        }
    }

    win.loadContent();
    std.debug.print("[suji] window opened ({s})\n", .{if (mode == .dev) "dev" else "production"});
    win.run();
}
