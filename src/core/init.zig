const std = @import("std");
const runtime = @import("runtime");

const Dir = std.Io.Dir;

pub const BackendLang = enum {
    zig,
    rust,
    go,
    multi,

    pub fn fromString(s: []const u8) ?BackendLang {
        if (std.mem.eql(u8, s, "zig")) return .zig;
        if (std.mem.eql(u8, s, "rust")) return .rust;
        if (std.mem.eql(u8, s, "go")) return .go;
        if (std.mem.eql(u8, s, "multi")) return .multi;
        return null;
    }
};

pub const InitOptions = struct {
    name: []const u8,
    backend: BackendLang = .rust,
};

pub fn run(allocator: std.mem.Allocator, opts: InitOptions) !void {
    const name = opts.name;
    const io = runtime.io;

    std.debug.print("[suji] creating project '{s}' (backend: {s})\n", .{ name, @tagName(opts.backend) });

    Dir.cwd().createDir(io, name, .default_dir) catch |err| {
        if (err == error.PathAlreadyExists) {
            std.debug.print("[suji] error: directory '{s}' already exists\n", .{name});
            return;
        }
        return err;
    };

    var project_dir = try Dir.cwd().openDir(io, name, .{});
    defer project_dir.close(io);

    // suji.json
    try writeConfig(allocator, project_dir, name, opts.backend);

    // 백엔드 스캐폴딩
    switch (opts.backend) {
        .zig => try scaffoldZig(project_dir),
        .rust => try scaffoldRust(project_dir),
        .go => try scaffoldGo(allocator, project_dir, name),
        .multi => {
            try project_dir.createDir(io, "backends", .default_dir);
            var backends_dir = try project_dir.openDir(io, "backends", .{});
            defer backends_dir.close(io);

            try backends_dir.createDir(io, "zig", .default_dir);
            var zig_dir = try backends_dir.openDir(io, "zig", .{});
            defer zig_dir.close(io);
            try scaffoldZig(zig_dir);

            try backends_dir.createDir(io, "rust", .default_dir);
            var rust_dir = try backends_dir.openDir(io, "rust", .{});
            defer rust_dir.close(io);
            try scaffoldRust(rust_dir);

            try backends_dir.createDir(io, "go", .default_dir);
            var go_dir = try backends_dir.openDir(io, "go", .{});
            defer go_dir.close(io);
            try scaffoldGo(allocator, go_dir, name);
        },
    }

    // 프론트엔드
    std.debug.print("[suji] creating frontend (Vite + React)...\n", .{});
    try createFrontend(allocator, name);

    // .gitignore
    try writeFileContent(project_dir, ".gitignore", @embedFile("../templates/gitignore"));

    std.debug.print("\n[suji] project '{s}' created!\n\n  cd {s}\n  suji dev\n\n", .{ name, name });
}

fn writeConfig(allocator: std.mem.Allocator, dir: Dir, name: []const u8, backend: BackendLang) !void {
    var buf: [2048]u8 = undefined;
    const content = switch (backend) {
        .multi => try std.fmt.bufPrint(&buf,
            \\{{
            \\  "$schema": "https://raw.githubusercontent.com/ohah/suji/main/suji.schema.json",
            \\  "app": {{ "name": "{s}", "version": "0.1.0" }},
            \\  "window": {{ "title": "{s}", "width": 1024, "height": 768, "debug": true }},
            \\  "backends": [
            \\    {{ "name": "zig", "lang": "zig", "entry": "backends/zig" }},
            \\    {{ "name": "rust", "lang": "rust", "entry": "backends/rust" }},
            \\    {{ "name": "go", "lang": "go", "entry": "backends/go" }}
            \\  ],
            \\  "frontend": {{ "dir": "frontend", "dev_url": "http://localhost:5173", "dist_dir": "frontend/dist" }}
            \\}}
        , .{ name, name }),
        else => try std.fmt.bufPrint(&buf,
            \\{{
            \\  "$schema": "https://raw.githubusercontent.com/ohah/suji/main/suji.schema.json",
            \\  "app": {{ "name": "{s}", "version": "0.1.0" }},
            \\  "window": {{ "title": "{s}", "width": 1024, "height": 768, "debug": true }},
            \\  "backend": {{ "lang": "{s}", "entry": "." }},
            \\  "frontend": {{ "dir": "frontend", "dev_url": "http://localhost:5173", "dist_dir": "frontend/dist" }}
            \\}}
        , .{ name, name, @tagName(backend) }),
    };
    _ = allocator;
    try writeFileContent(dir, "suji.json", content);
}

fn scaffoldZig(dir: Dir) !void {
    try writeFileContent(dir, "app.zig", @embedFile("../templates/zig_app.zig"));
}

fn scaffoldRust(dir: Dir) !void {
    const io = runtime.io;
    try writeFileContent(dir, "Cargo.toml", @embedFile("../templates/rust_cargo.toml"));
    try dir.createDir(io, "src", .default_dir);
    var src_dir = try dir.openDir(io, "src", .{});
    defer src_dir.close(io);
    try writeFileContent(src_dir, "lib.rs", @embedFile("../templates/rust_lib.rs"));
}

fn scaffoldGo(allocator: std.mem.Allocator, dir: Dir, name: []const u8) !void {
    var buf: [512]u8 = undefined;
    const go_mod = try std.fmt.bufPrint(&buf, "module {s}\n\ngo 1.26\n", .{name});
    _ = allocator;
    try writeFileContent(dir, "go.mod", go_mod);
    try writeFileContent(dir, "main.go", @embedFile("../templates/go_main.go"));
}

fn createFrontend(allocator: std.mem.Allocator, project_name: []const u8) !void {
    const io = runtime.io;
    const project_path = Dir.cwd().realPathFileAlloc(io, project_name, allocator) catch null;
    defer if (project_path) |p| allocator.free(p);

    var child = try std.process.spawn(io, .{
        .argv = &.{ "bunx", "create-vite", "frontend", "--template", "react-ts" },
        .cwd = if (project_path) |p| .{ .path = p } else .inherit,
    });
    const result = try child.wait(io);
    switch (result) {
        .exited => |code| if (code != 0) {
            std.debug.print("[suji] warning: frontend creation failed\n", .{});
        },
        else => {},
    }

    // bun install
    const frontend_path = try std.fmt.allocPrint(allocator, "{s}/frontend", .{project_name});
    defer allocator.free(frontend_path);
    const frontend_real = Dir.cwd().realPathFileAlloc(io, frontend_path, allocator) catch null;
    defer if (frontend_real) |p| allocator.free(p);

    var install = try std.process.spawn(io, .{
        .argv = &.{ "bun", "install" },
        .cwd = if (frontend_real) |p| .{ .path = p } else .inherit,
    });
    _ = try install.wait(io);
}

fn writeFileContent(dir: Dir, name: []const u8, content: []const u8) !void {
    const io = runtime.io;
    var file = try dir.createFile(io, name, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var fw = file.writer(io, &buf);
    try fw.interface.writeAll(content);
    try fw.interface.flush();
}
