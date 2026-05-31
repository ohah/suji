//! 백엔드 빌드 헬퍼 — `suji build`/`suji types` 가 공유한다.
//! lang(rust/go/node/lua/zig) → 빌드 명령 + dylib 경로 계산.
//!
//! main.zig 의 runCmd/runCmdInDir/runCmdEnv 가 동등한 spawn→wait→exit-code
//! 패턴이라 여기서는 std.process.spawn 으로 직접 구동한다(공용 출처 src/core/proc.zig
//! 와 동일 의미). main.zig 의 wrapper 와 동작 무변경.

const std = @import("std");
const builtin = @import("builtin");
const runtime = @import("runtime");
const suji = @import("../root.zig");

fn runArgv(argv: []const []const u8) !void {
    var child = try std.process.spawn(runtime.io, .{ .argv = argv });
    switch (try child.wait(runtime.io)) {
        .exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
}

fn runArgvInDir(argv: []const []const u8, cwd_path: []const u8) !void {
    var child = try std.process.spawn(runtime.io, .{
        .argv = argv,
        .cwd = .{ .path = cwd_path },
    });
    switch (try child.wait(runtime.io)) {
        .exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
}

fn runArgvWithEnv(allocator: std.mem.Allocator, argv: []const []const u8, env_pairs: []const [2][]const u8) !void {
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
    switch (try child.wait(runtime.io)) {
        .exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
}

pub fn buildAllFromConfig(allocator: std.mem.Allocator, config: *const suji.Config, release: bool) !void {
    if (config.isMultiBackend()) {
        if (config.backends) |backends| {
            for (backends) |be| {
                std.debug.print("[suji] building {s} ({s})...\n", .{ be.name, be.lang });
                buildByLang(allocator, be.lang, be.entry, release) catch |err| {
                    std.debug.print("[suji] build failed: {}\n", .{err});
                };
            }
        }
    } else if (config.backend) |be| {
        std.debug.print("[suji] building {s}...\n", .{be.lang});
        buildByLang(allocator, be.lang, be.entry, release) catch |err| {
            std.debug.print("[suji] build failed: {}\n", .{err});
        };
    }
}

pub fn buildByLang(allocator: std.mem.Allocator, lang: []const u8, entry: []const u8, release: bool) !void {
    if (std.mem.eql(u8, lang, "rust")) {
        const manifest = try std.fmt.allocPrint(allocator, "{s}/Cargo.toml", .{entry});
        defer allocator.free(manifest);
        if (release) {
            try runArgv(&.{ "cargo", "build", "--release", "--manifest-path", manifest });
        } else {
            try runArgv(&.{ "cargo", "build", "--manifest-path", manifest });
        }
    } else if (std.mem.eql(u8, lang, "go")) {
        const output = try dylibPath(allocator, "go", entry, release);
        defer allocator.free(output);
        const go_entry = try std.fmt.allocPrint(allocator, "{s}/main.go", .{entry});
        defer allocator.free(go_entry);
        if (builtin.os.tag == .windows) {
            // Windows: -ldflags="-s -w" 가 없으면 Go c-shared DLL 이 LoadLibrary 에서
            // ERROR_BAD_EXE_FORMAT(193) 으로 실패하는 케이스가 있다 (Go 1.26+
            // DWARF/.debug_* 섹션이 PE loader 와 충돌). debug info 제거로 안정 로드.
            const argv = &.{ "go", "build", "-buildmode=c-shared", "-ldflags=-s -w", "-o", output, go_entry };
            try runArgvWithEnv(allocator, argv, &.{.{ "CGO_ENABLED", "1" }});
        } else {
            const argv = &.{ "go", "build", "-buildmode=c-shared", "-o", output, go_entry };
            try runArgvWithEnv(allocator, argv, &.{
                .{ "CC", "/usr/bin/clang" },
                .{ "CGO_ENABLED", "1" },
            });
        }
    } else if (std.mem.eql(u8, lang, "node")) {
        // Node 백엔드: npm install (빌드 불필요, 런타임에 JS 실행)
        const pkg_path = try std.fmt.allocPrint(allocator, "{s}/package.json", .{entry});
        defer allocator.free(pkg_path);
        std.Io.Dir.cwd().access(runtime.io, pkg_path, .{}) catch return; // package.json 없으면 skip
        std.debug.print("[suji] installing npm packages...\n", .{});
        const abs_entry = try std.Io.Dir.cwd().realPathFileAlloc(runtime.io, entry, allocator);
        defer allocator.free(abs_entry);
        const npm_cmd = if (release) &[_][]const u8{ "npm", "install", "--production" } else &[_][]const u8{ "npm", "install" };
        try runArgvInDir(npm_cmd, abs_entry);
    } else if (std.mem.eql(u8, lang, "lua")) {
        // Lua 백엔드: 빌드 단계 없음. startLuaBackend가 main.lua 존재 여부와
        // LuaJIT 활성화 여부를 런타임에서 검증한다.
        return;
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

pub fn dylibPath(allocator: std.mem.Allocator, lang: []const u8, entry: []const u8, release: bool) ![]const u8 {
    if (std.mem.eql(u8, lang, "rust")) {
        const profile: []const u8 = if (release) "release" else "debug";
        return switch (builtin.os.tag) {
            .windows => try std.fmt.allocPrint(allocator, "{s}/target/{s}/rust_backend.dll", .{ entry, profile }),
            .linux => try std.fmt.allocPrint(allocator, "{s}/target/{s}/librust_backend.so", .{ entry, profile }),
            else => try std.fmt.allocPrint(allocator, "{s}/target/{s}/librust_backend.dylib", .{ entry, profile }),
        };
    } else if (std.mem.eql(u8, lang, "go")) {
        return switch (builtin.os.tag) {
            .windows => try std.fmt.allocPrint(allocator, "{s}/backend.dll", .{entry}),
            .linux => try std.fmt.allocPrint(allocator, "{s}/libbackend.so", .{entry}),
            else => try std.fmt.allocPrint(allocator, "{s}/libbackend.dylib", .{entry}),
        };
    } else if (std.mem.eql(u8, lang, "zig")) {
        return switch (builtin.os.tag) {
            .windows => try std.fmt.allocPrint(allocator, "{s}/zig-out/bin/backend.dll", .{entry}),
            .linux => try std.fmt.allocPrint(allocator, "{s}/zig-out/lib/libbackend.so", .{entry}),
            else => try std.fmt.allocPrint(allocator, "{s}/zig-out/lib/libbackend.dylib", .{entry}),
        };
    }
    return error.UnsupportedLang;
}

test "dylibPath uses host platform library extension" {
    const allocator = std.testing.allocator;
    const zig_path = try dylibPath(allocator, "zig", "backends/zig", false);
    defer allocator.free(zig_path);
    const rust_path = try dylibPath(allocator, "rust", "backends/rust", false);
    defer allocator.free(rust_path);
    const go_path = try dylibPath(allocator, "go", "backends/go", false);
    defer allocator.free(go_path);

    switch (builtin.os.tag) {
        .windows => {
            try std.testing.expectEqualStrings("backends/zig/zig-out/bin/backend.dll", zig_path);
            try std.testing.expectEqualStrings("backends/rust/target/debug/rust_backend.dll", rust_path);
            try std.testing.expectEqualStrings("backends/go/backend.dll", go_path);
        },
        .linux => {
            try std.testing.expectEqualStrings("backends/zig/zig-out/lib/libbackend.so", zig_path);
            try std.testing.expectEqualStrings("backends/rust/target/debug/librust_backend.so", rust_path);
            try std.testing.expectEqualStrings("backends/go/libbackend.so", go_path);
        },
        else => {
            try std.testing.expectEqualStrings("backends/zig/zig-out/lib/libbackend.dylib", zig_path);
            try std.testing.expectEqualStrings("backends/rust/target/debug/librust_backend.dylib", rust_path);
            try std.testing.expectEqualStrings("backends/go/libbackend.dylib", go_path);
        },
    }
}
