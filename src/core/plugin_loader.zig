//! 플러그인 로딩 — suji.config 의 plugins[] 를 읽어 dylib 로 BackendRegistry 에
//! 등록한다. 로컬 plugins/<name>/ 와 GitHub source(github.com/<owner>/<repo>)를
//! `~/.suji/plugins/<sanitized>` 캐시로 clone/pull 해 동일한 layout(`<dir>/<lang>/`
//! + suji-plugin.json)으로 다룬다. packaged 환경(macOS .app / Windows
//! .suji-packaged sentinel)에선 빌드 스킵 + 평탄 dylib 직접 로드.

const std = @import("std");
const builtin = @import("builtin");
const runtime = @import("runtime");
const util = @import("util");
const suji = @import("../root.zig");
const backend_build = @import("backend_build.zig");
const packaged_paths = @import("packaged_paths.zig");
const proc = @import("proc.zig");

pub fn loadFromConfig(allocator: std.mem.Allocator, config: *const suji.Config, registry: *suji.BackendRegistry, release: bool) !void {
    const plugins = config.plugins orelse return;

    // packaged 면 build 스킵 + `<exe_dir>/plugins/<name>/<dylib>` 에서 직접 로드.
    if (packaged_paths.exeDir(allocator)) |exe_dir| {
        defer allocator.free(exe_dir);
        for (plugins) |plugin| {
            const plugin_name = plugin.name;
            std.debug.print("[suji] loading plugin (packaged): {s}\n", .{plugin_name});
            // packaged 의 plugin dir 는 같은 layout — plugins/<name>/<lang>/<entry>
            // 가 없고 dylib 만 평탄. lang 을 모르므로 known 4종 시도.
            for ([_][]const u8{ "zig", "rust", "go" }) |lang| {
                const basename: []const u8 = if (std.mem.eql(u8, lang, "rust"))
                    switch (builtin.os.tag) {
                        .windows => "rust_backend.dll",
                        .linux => "librust_backend.so",
                        else => "librust_backend.dylib",
                    }
                else switch (builtin.os.tag) {
                    .windows => "backend.dll",
                    .linux => "libbackend.so",
                    else => "libbackend.dylib",
                };
                const dylib = std.fmt.allocPrint(allocator, "{s}/plugins/{s}/{s}", .{ exe_dir, plugin_name, basename }) catch continue;
                defer allocator.free(dylib);
                std.Io.Dir.cwd().access(runtime.io, dylib, .{}) catch continue;
                var path_z: [1024]u8 = undefined;
                const path_zt = util.nullTerminate(dylib, &path_z);
                setPermissionPolicy(allocator, registry, plugin);
                registry.register(plugin_name, path_zt) catch |err| {
                    std.debug.print("[suji] plugin '{s}' load failed: {}\n", .{ plugin_name, err });
                    continue;
                };
                break;
            }
        }
        return;
    }

    for (plugins) |plugin| {
        const plugin_name = plugin.name;
        std.debug.print("[suji] loading plugin: {s}\n", .{plugin_name});

        // suji-plugin.json 읽어서 lang 결정
        const plugin_dir = dirForSpec(allocator, plugin) orelse {
            std.debug.print("[suji] plugin '{s}' not found\n", .{plugin_name});
            continue;
        };
        defer allocator.free(plugin_dir);

        const lang = readLang(allocator, plugin_dir) orelse {
            std.debug.print("[suji] plugin '{s}': cannot read suji-plugin.json\n", .{plugin_name});
            continue;
        };
        defer allocator.free(lang);

        const entry = std.fmt.allocPrint(allocator, "{s}/{s}", .{ plugin_dir, lang }) catch continue;
        defer allocator.free(entry);

        backend_build.buildByLang(allocator, lang, entry, release) catch |err| {
            std.debug.print("[suji] plugin '{s}' build failed: {}\n", .{ plugin_name, err });
            continue;
        };

        const dylib_path = backend_build.dylibPath(allocator, lang, entry, release) catch continue;
        defer allocator.free(dylib_path);

        var path_z: [1024]u8 = undefined;
        const path_zt = util.nullTerminate(dylib_path, &path_z);

        setPermissionPolicy(allocator, registry, plugin);
        registry.register(plugin_name, path_zt) catch |err| {
            std.debug.print("[suji] plugin '{s}' load failed: {}\n", .{ plugin_name, err });
            continue;
        };
    }
}

pub fn setPermissionPolicy(allocator: std.mem.Allocator, registry: *suji.BackendRegistry, plugin: suji.Config.Plugin) void {
    const permissions = plugin.permissions orelse return;
    var perms = allocator.alloc([]const u8, permissions.len) catch return;
    defer allocator.free(perms);
    for (permissions, 0..) |p, i| perms[i] = p;
    registry.setPluginPermissions(plugin.name, perms) catch |err| {
        std.debug.print("[suji] plugin '{s}' permission setup failed: {}\n", .{ plugin.name, err });
    };
}

pub fn dirForSpec(allocator: std.mem.Allocator, plugin: suji.Config.Plugin) ?[]const u8 {
    if (plugin.source) |source| {
        return sourceDir(allocator, plugin.name, source);
    }
    return localDir(allocator, plugin.name);
}

/// 플러그인 디렉토리 탐색: 로컬 → suji 설치 경로 순
pub fn localDir(allocator: std.mem.Allocator, name: []const u8) ?[]const u8 {
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

pub fn sourceDir(allocator: std.mem.Allocator, name: []const u8, source: []const u8) ?[]const u8 {
    if (isLocalSource(source)) {
        const expanded = expandSourcePath(allocator, source) orelse return null;
        if (manifestExists(allocator, expanded)) return expanded;
        allocator.free(expanded);
        return null;
    }

    const clone_url = gitCloneUrl(allocator, source) orelse return null;
    defer allocator.free(clone_url);
    const cache_dir = sourceCacheDir(allocator, source) orelse return null;
    errdefer allocator.free(cache_dir);

    if (manifestExists(allocator, cache_dir)) {
        proc.run(&.{ "git", "-C", cache_dir, "pull", "--ff-only" }) catch |err| {
            std.debug.print("[suji] plugin '{s}' source update skipped: {}\n", .{ name, err });
        };
        return cache_dir;
    }

    if (std.fs.path.dirname(cache_dir)) |parent| {
        std.Io.Dir.cwd().createDirPath(runtime.io, parent) catch return null;
    }
    proc.run(&.{ "git", "clone", "--depth=1", clone_url, cache_dir }) catch |err| {
        std.debug.print("[suji] plugin '{s}' source clone failed: {}\n", .{ name, err });
        allocator.free(cache_dir);
        return null;
    };
    if (manifestExists(allocator, cache_dir)) return cache_dir;
    allocator.free(cache_dir);
    return null;
}

pub fn isLocalSource(source: []const u8) bool {
    return std.fs.path.isAbsolute(source) or
        std.mem.startsWith(u8, source, ".") or
        std.mem.startsWith(u8, source, "~");
}

pub fn expandSourcePath(allocator: std.mem.Allocator, source: []const u8) ?[]u8 {
    if (std.mem.eql(u8, source, "~") or std.mem.startsWith(u8, source, "~/")) {
        const home = runtime.env(if (builtin.os.tag == .windows) "USERPROFILE" else "HOME") orelse return null;
        const rest = if (source.len == 1) "" else source[1..];
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ home, rest }) catch null;
    }
    return allocator.dupe(u8, source) catch null;
}

pub fn gitCloneUrl(allocator: std.mem.Allocator, source: []const u8) ?[]u8 {
    if (std.mem.startsWith(u8, source, "github.com/")) {
        return std.fmt.allocPrint(allocator, "https://{s}", .{source}) catch null;
    }
    if (std.mem.startsWith(u8, source, "https://github.com/")) {
        return allocator.dupe(u8, source) catch null;
    }
    return null;
}

pub fn sourceCacheDir(allocator: std.mem.Allocator, source: []const u8) ?[]u8 {
    const home = runtime.env(if (builtin.os.tag == .windows) "USERPROFILE" else "HOME") orelse return null;
    const safe = sanitizeSource(allocator, source) orelse return null;
    defer allocator.free(safe);
    return std.fmt.allocPrint(allocator, "{s}/.suji/plugins/{s}", .{ home, safe }) catch null;
}

pub fn sanitizeSource(allocator: std.mem.Allocator, source: []const u8) ?[]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    for (source) |c| {
        const ok = (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '-' or c == '_' or c == '.';
        out.append(allocator, if (ok) c else '_') catch return null;
    }
    if (out.items.len == 0) out.appendSlice(allocator, "plugin") catch return null;
    return out.toOwnedSlice(allocator) catch null;
}

pub fn manifestExists(allocator: std.mem.Allocator, dir: []const u8) bool {
    const manifest = std.fmt.allocPrint(allocator, "{s}/suji-plugin.json", .{dir}) catch return false;
    defer allocator.free(manifest);
    std.Io.Dir.cwd().access(runtime.io, manifest, .{}) catch return false;
    return true;
}

/// suji-plugin.json에서 lang 읽기
pub fn readLang(allocator: std.mem.Allocator, plugin_dir: []const u8) ?[]const u8 {
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
