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

    // 1. 백엔드 빌드 + 로드
    var registry = suji.BackendRegistry.init(allocator);
    defer registry.deinit();
    registry.setGlobal();
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
    try loadBackendsFromConfig(allocator, &config, &registry, true);

    try openWindow(allocator, &config, &registry, .dist);
}

// ============================================
// 백엔드 빌드/로드
// ============================================

fn loadBackendsFromConfig(allocator: std.mem.Allocator, config: *const suji.Config, registry: *suji.BackendRegistry, release: bool) !void {
    if (config.isMultiBackend()) {
        if (config.backends) |backends| {
            for (backends) |be| {
                std.debug.print("[suji] building {s} ({s})...\n", .{ be.name, be.lang });
                buildBackendByLang(allocator, be.lang, be.entry, release) catch |err| {
                    std.debug.print("[suji] build failed: {}\n", .{err});
                    continue;
                };
                const path = getDylibPath(allocator, be.lang, be.entry, release) catch continue;
                defer allocator.free(path);
                var path_z: [1024]u8 = undefined;
                const plen = @min(path.len, path_z.len - 1);
                @memcpy(path_z[0..plen], path[0..plen]);
                path_z[plen] = 0;
                registry.register(be.name, path_z[0..plen :0]) catch |err| {
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
        const plen = @min(path.len, path_z.len - 1);
        @memcpy(path_z[0..plen], path[0..plen]);
        path_z[plen] = 0;
        registry.register("default", path_z[0..plen :0]) catch |err| {
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
    }
}

fn getDylibPath(allocator: std.mem.Allocator, lang: []const u8, entry: []const u8, release: bool) ![]const u8 {
    if (std.mem.eql(u8, lang, "rust")) {
        const profile: []const u8 = if (release) "release" else "debug";
        return try std.fmt.allocPrint(allocator, "{s}/target/{s}/librust_backend.dylib", .{ entry, profile });
    } else if (std.mem.eql(u8, lang, "go")) {
        return try std.fmt.allocPrint(allocator, "{s}/libbackend.dylib", .{entry});
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

    const bridge = try allocator.create(suji.Bridge);
    bridge.* = suji.Bridge.init(&win.webview, registry);
    defer {
        bridge.deinit();
        allocator.destroy(bridge);
    }
    bridge.bind();

    win.loadContent();
    std.debug.print("[suji] window opened ({s})\n", .{if (mode == .dev) "dev" else "production"});
    win.run();
}
