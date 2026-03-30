const std = @import("std");

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

    std.debug.print("[suji] creating project '{s}' (backend: {s})\n", .{ name, @tagName(opts.backend) });

    std.fs.cwd().makeDir(name) catch |err| {
        if (err == error.PathAlreadyExists) {
            std.debug.print("[suji] error: directory '{s}' already exists\n", .{name});
            return;
        }
        return err;
    };

    var project_dir = try std.fs.cwd().openDir(name, .{});
    defer project_dir.close();

    // suji.json
    try writeConfig(allocator, project_dir, name, opts.backend);

    // 백엔드 스캐폴딩
    switch (opts.backend) {
        .zig => try scaffoldZig(project_dir),
        .rust => try scaffoldRust(project_dir),
        .go => try scaffoldGo(allocator, project_dir, name),
        .multi => {
            try project_dir.makeDir("backends");
            var backends_dir = try project_dir.openDir("backends", .{});
            defer backends_dir.close();

            try backends_dir.makeDir("zig");
            var zig_dir = try backends_dir.openDir("zig", .{});
            defer zig_dir.close();
            try scaffoldZig(zig_dir);

            try backends_dir.makeDir("rust");
            var rust_dir = try backends_dir.openDir("rust", .{});
            defer rust_dir.close();
            try scaffoldRust(rust_dir);

            try backends_dir.makeDir("go");
            var go_dir = try backends_dir.openDir("go", .{});
            defer go_dir.close();
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

fn writeConfig(allocator: std.mem.Allocator, dir: std.fs.Dir, name: []const u8, backend: BackendLang) !void {
    var buf: [2048]u8 = undefined;
    const content = switch (backend) {
        .multi => try std.fmt.bufPrint(&buf,
            \\{{
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

fn scaffoldZig(dir: std.fs.Dir) !void {
    try writeFileContent(dir, "app.zig", @embedFile("../templates/zig_app.zig"));
}

fn scaffoldRust(dir: std.fs.Dir) !void {
    try writeFileContent(dir, "Cargo.toml", @embedFile("../templates/rust_cargo.toml"));
    try dir.makeDir("src");
    var src_dir = try dir.openDir("src", .{});
    defer src_dir.close();
    try writeFileContent(src_dir, "lib.rs", @embedFile("../templates/rust_lib.rs"));
}

fn scaffoldGo(allocator: std.mem.Allocator, dir: std.fs.Dir, name: []const u8) !void {
    var buf: [512]u8 = undefined;
    const go_mod = try std.fmt.bufPrint(&buf, "module {s}\n\ngo 1.26\n", .{name});
    _ = allocator;
    try writeFileContent(dir, "go.mod", go_mod);
    try writeFileContent(dir, "main.go", @embedFile("../templates/go_main.go"));
}

fn createFrontend(allocator: std.mem.Allocator, project_name: []const u8) !void {
    const project_path = std.fs.cwd().realpathAlloc(allocator, project_name) catch null;
    defer if (project_path) |p| allocator.free(p);

    var child = std.process.Child.init(
        &.{ "bunx", "create-vite", "frontend", "--template", "react-ts" },
        allocator,
    );
    child.cwd = project_path;
    child.stderr_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    try child.spawn();
    const result = try child.wait();
    switch (result) {
        .Exited => |code| if (code != 0) {
            std.debug.print("[suji] warning: frontend creation failed\n", .{});
        },
        else => {},
    }

    // bun install
    const frontend_path = try std.fmt.allocPrint(allocator, "{s}/frontend", .{project_name});
    defer allocator.free(frontend_path);
    const frontend_real = std.fs.cwd().realpathAlloc(allocator, frontend_path) catch null;
    defer if (frontend_real) |p| allocator.free(p);

    var install = std.process.Child.init(&.{ "bun", "install" }, allocator);
    install.cwd = frontend_real;
    install.stderr_behavior = .Inherit;
    install.stdout_behavior = .Inherit;
    try install.spawn();
    _ = try install.wait();
}

fn writeFileContent(dir: std.fs.Dir, name: []const u8, content: []const u8) !void {
    const file = try dir.createFile(name, .{});
    defer file.close();
    try file.writeAll(content);
}
