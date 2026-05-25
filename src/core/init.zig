const std = @import("std");
const runtime = @import("runtime");

const Dir = std.Io.Dir;

pub const BackendLang = enum {
    zig,
    rust,
    go,
    multi,

    pub fn fromString(s: []const u8) ?BackendLang {
        return std.meta.stringToEnum(BackendLang, s);
    }
};

pub const FrontendTemplate = enum {
    react,
    vue,
    svelte,
    solid,
    preact,
    vanilla,

    pub fn fromString(s: []const u8) ?FrontendTemplate {
        return std.meta.stringToEnum(FrontendTemplate, s);
    }
};

pub const InitOptions = struct {
    name: []const u8,
    backend: BackendLang = .rust,
    frontend: FrontendTemplate = .react,
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
    std.debug.print("[suji] creating frontend (Vite + {s})...\n", .{@tagName(opts.frontend)});
    try scaffoldFrontend(project_dir, opts.frontend);
    try bunInstall(allocator, name);

    // .gitignore
    try writeFileContent(project_dir, ".gitignore", @embedFile("../templates/gitignore"));
    try scaffoldGitHubActions(project_dir);

    std.debug.print("\n[suji] project '{s}' created!\n\n  cd {s}\n  suji dev\n\n", .{ name, name });
}

fn writeConfig(allocator: std.mem.Allocator, dir: Dir, name: []const u8, backend: BackendLang) !void {
    var buf: [2048]u8 = undefined;
    const content = switch (backend) {
        .multi => try std.fmt.bufPrint(&buf,
            \\{{
            \\  "$schema": "https://raw.githubusercontent.com/ohah/suji/main/suji.schema.json",
            \\  "app": {{ "name": "{s}", "version": "0.1.0" }},
            \\  "windows": [{{ "name": "main", "title": "{s}", "width": 1024, "height": 768, "debug": true }}],
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
            \\  "windows": [{{ "name": "main", "title": "{s}", "width": 1024, "height": 768, "debug": true }}],
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

// 번들 프론트엔드 템플릿의 상대 파일 목록 (src/templates/frontend/<fw>/).
// @embedFile 가 comptime 이라 목록/파일 불일치는 컴파일 단계에서 실패 →
// 템플릿 회귀 가드. 전 6 프레임워크 bun build 실증(검증 천장: CEF 런타임
// suji.invoke 왕복은 e2e 영역, 여기선 빌드·존재만).
pub fn feFiles(comptime t: FrontendTemplate) []const []const u8 {
    return switch (t) {
        .react => &.{ "package.json", "vite.config.ts", "tsconfig.json", "index.html", "src/suji.ts", "src/main.tsx", "src/App.tsx" },
        .vue => &.{ "package.json", "vite.config.ts", "tsconfig.json", "index.html", "src/suji.ts", "src/main.ts", "src/App.vue" },
        .svelte => &.{ "package.json", "vite.config.ts", "svelte.config.js", "tsconfig.json", "index.html", "src/suji.ts", "src/main.ts", "src/App.svelte" },
        .solid => &.{ "package.json", "vite.config.ts", "tsconfig.json", "index.html", "src/suji.ts", "src/index.tsx", "src/App.tsx" },
        .preact => &.{ "package.json", "vite.config.ts", "tsconfig.json", "index.html", "src/suji.ts", "src/main.tsx", "src/app.tsx" },
        .vanilla => &.{ "package.json", "vite.config.ts", "tsconfig.json", "index.html", "src/suji.ts", "src/main.ts" },
    };
}

fn scaffoldFrontend(project_dir: Dir, template: FrontendTemplate) !void {
    const io = runtime.io;
    try project_dir.createDir(io, "frontend", .default_dir);
    var fe = try project_dir.openDir(io, "frontend", .{});
    defer fe.close(io);
    try fe.createDir(io, "src", .default_dir);
    var src = try fe.openDir(io, "src", .{});
    defer src.close(io);

    switch (template) {
        inline else => |t| {
            const base = "../templates/frontend/" ++ @tagName(t) ++ "/";
            inline for (comptime feFiles(t)) |rel| {
                const content = @embedFile(base ++ rel);
                if (comptime std.mem.startsWith(u8, rel, "src/")) {
                    try writeFileContent(src, rel["src/".len..], content);
                } else {
                    try writeFileContent(fe, rel, content);
                }
            }
        },
    }
}

fn scaffoldGitHubActions(project_dir: Dir) !void {
    const io = runtime.io;
    try project_dir.createDir(io, ".github", .default_dir);
    var github_dir = try project_dir.openDir(io, ".github", .{});
    defer github_dir.close(io);
    try github_dir.createDir(io, "workflows", .default_dir);
    var workflows_dir = try github_dir.openDir(io, "workflows", .{});
    defer workflows_dir.close(io);
    try writeFileContent(workflows_dir, "suji.yml", @embedFile("../templates/.github/workflows/suji.yml"));
}

fn bunInstall(allocator: std.mem.Allocator, project_name: []const u8) !void {
    const io = runtime.io;
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
