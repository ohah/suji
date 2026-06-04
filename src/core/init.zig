const std = @import("std");
const runtime = @import("runtime");

const Dir = std.Io.Dir;

pub const BackendLang = enum {
    none,
    zig,
    rust,
    go,
    node,
    lua,
    multi,

    pub fn fromString(s: []const u8) ?BackendLang {
        return std.meta.stringToEnum(BackendLang, s);
    }
};

pub const FrontendFramework = enum {
    react,
    vue,
    svelte,
    solid,
    preact,
    vanilla,
    next,

    pub fn fromString(s: []const u8) ?FrontendFramework {
        return std.meta.stringToEnum(FrontendFramework, s);
    }
};

pub const FrontendToolchain = enum {
    vite,
    rsbuild,
    next,

    pub fn fromString(s: []const u8) ?FrontendToolchain {
        if (std.mem.eql(u8, s, "rspack")) return .rsbuild;
        return std.meta.stringToEnum(FrontendToolchain, s);
    }
};

pub const FrontendTemplate = enum {
    react_vite,
    vue_vite,
    svelte_vite,
    solid_vite,
    preact_vite,
    vanilla_vite,
    react_rsbuild,
    vue_rsbuild,
    next_static,

    pub fn fromString(s: []const u8) ?FrontendTemplate {
        if (std.meta.stringToEnum(FrontendTemplate, s)) |t| return t;
        if (FrontendFramework.fromString(s)) |framework| return fromFrameworkToolchain(framework, .vite);
        return null;
    }

    pub fn fromFrameworkToolchain(framework: FrontendFramework, toolchain: FrontendToolchain) ?FrontendTemplate {
        return switch (toolchain) {
            .vite => switch (framework) {
                .react => .react_vite,
                .vue => .vue_vite,
                .svelte => .svelte_vite,
                .solid => .solid_vite,
                .preact => .preact_vite,
                .vanilla => .vanilla_vite,
                .next => null,
            },
            .rsbuild => switch (framework) {
                .react => .react_rsbuild,
                .vue => .vue_rsbuild,
                else => null,
            },
            .next => switch (framework) {
                .next, .react => .next_static,
                else => null,
            },
        };
    }

    pub fn frameworkName(self: FrontendTemplate) []const u8 {
        return switch (self) {
            .react_vite, .react_rsbuild => "react",
            .vue_vite, .vue_rsbuild => "vue",
            .svelte_vite => "svelte",
            .solid_vite => "solid",
            .preact_vite => "preact",
            .vanilla_vite => "vanilla",
            .next_static => "next",
        };
    }

    pub fn toolchainName(self: FrontendTemplate) []const u8 {
        return switch (self) {
            .react_vite, .vue_vite, .svelte_vite, .solid_vite, .preact_vite, .vanilla_vite => "vite",
            .react_rsbuild, .vue_rsbuild => "rsbuild",
            .next_static => "next",
        };
    }

    pub fn devUrl(self: FrontendTemplate) []const u8 {
        _ = self;
        return "http://localhost:12300";
    }

    pub fn distDir(self: FrontendTemplate) []const u8 {
        return switch (self) {
            .next_static => "frontend/out",
            else => "frontend/dist",
        };
    }
};

pub const PackageManager = enum {
    npm,
    pnpm,
    bun,
    vp,

    pub fn fromString(s: []const u8) ?PackageManager {
        if (std.mem.eql(u8, s, "vz")) return .vp;
        if (std.mem.eql(u8, s, "voidzero")) return .vp;
        if (std.mem.eql(u8, s, "viteplus")) return .vp;
        return std.meta.stringToEnum(PackageManager, s);
    }

    pub fn runCommand(self: PackageManager, script: []const u8) []const u8 {
        return switch (self) {
            .npm => if (std.mem.eql(u8, script, "dev")) "npm run dev" else "npm run build",
            .pnpm => if (std.mem.eql(u8, script, "dev")) "pnpm run dev" else "pnpm run build",
            .bun => if (std.mem.eql(u8, script, "dev")) "bun run dev" else "bun run build",
            .vp => if (std.mem.eql(u8, script, "dev")) "vp run dev" else "vp run build",
        };
    }

    pub fn installArgv(self: PackageManager) []const []const u8 {
        return switch (self) {
            .npm => &.{ "npm", "install" },
            .pnpm => &.{ "pnpm", "install" },
            .bun => &.{ "bun", "install" },
            .vp => &.{ "vp", "install" },
        };
    }

    pub fn installCommand(self: PackageManager) []const u8 {
        return switch (self) {
            .npm => "npm install",
            .pnpm => "pnpm install",
            .bun => "bun install",
            .vp => "vp install",
        };
    }

    pub fn packageManagerField(self: PackageManager) []const u8 {
        return switch (self) {
            .npm => "npm@latest",
            .pnpm => "pnpm@latest",
            .bun => "bun@latest",
            .vp => "pnpm@latest",
        };
    }
};

pub const InitOptions = struct {
    name: []const u8,
    backend: BackendLang = .zig,
    frontend: FrontendTemplate = .react_vite,
    package_manager: PackageManager = .npm,
    install_dependencies: bool = false,
};

pub fn run(allocator: std.mem.Allocator, opts: InitOptions) !void {
    const name = opts.name;
    const io = runtime.io;

    std.debug.print(
        "[suji] creating project '{s}' (backend: {s}, frontend: {s}+{s})\n",
        .{ name, @tagName(opts.backend), opts.frontend.frameworkName(), opts.frontend.toolchainName() },
    );

    Dir.cwd().createDir(io, name, .default_dir) catch |err| {
        if (err == error.PathAlreadyExists) {
            std.debug.print("[suji] error: directory '{s}' already exists\n", .{name});
            return;
        }
        return err;
    };

    var project_dir = try Dir.cwd().openDir(io, name, .{});
    defer project_dir.close(io);

    try writeRootPackage(allocator, project_dir, name, opts.package_manager);

    // suji.json
    try writeConfig(allocator, project_dir, name, opts.backend, opts.frontend, opts.package_manager);

    // 백엔드 스캐폴딩
    switch (opts.backend) {
        .none => {},
        .zig => try scaffoldZig(project_dir),
        .rust => try scaffoldRust(project_dir),
        .go => try scaffoldGo(allocator, project_dir, name),
        .node => {
            try project_dir.createDir(io, "backends", .default_dir);
            var backends_dir = try project_dir.openDir(io, "backends", .{});
            defer backends_dir.close(io);
            try backends_dir.createDir(io, "node", .default_dir);
            var node_dir = try backends_dir.openDir(io, "node", .{});
            defer node_dir.close(io);
            try scaffoldNode(node_dir);
        },
        .lua => {
            try project_dir.createDir(io, "backends", .default_dir);
            var backends_dir = try project_dir.openDir(io, "backends", .{});
            defer backends_dir.close(io);
            try backends_dir.createDir(io, "lua", .default_dir);
            var lua_dir = try backends_dir.openDir(io, "lua", .{});
            defer lua_dir.close(io);
            try scaffoldLua(lua_dir);
        },
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
    std.debug.print("[suji] creating frontend ({s} + {s})...\n", .{ opts.frontend.frameworkName(), opts.frontend.toolchainName() });
    try scaffoldFrontend(project_dir, opts.frontend);
    if (opts.install_dependencies) try installFrontendDependencies(allocator, name, opts.package_manager);

    // .gitignore
    try writeFileContent(project_dir, ".gitignore", @embedFile("../templates/gitignore"));
    try scaffoldGitHubActions(project_dir);

    // AGENTS.md / CLAUDE.md (에이전트 가이드 + llms.txt 링크)
    try writeAgentDocs(allocator, project_dir, name, opts.backend, opts.package_manager);

    std.debug.print("\n[suji] project '{s}' created!\n\n  cd {s}\n  {s}\n  {s}\n\n", .{ name, name, opts.package_manager.installCommand(), opts.package_manager.runCommand("dev") });
}

fn writeRootPackage(allocator: std.mem.Allocator, dir: Dir, name: []const u8, pm: PackageManager) !void {
    var buf: [1024]u8 = undefined;
    const content = try std.fmt.bufPrint(&buf,
        \\{{
        \\  "name": "{s}",
        \\  "version": "0.1.0",
        \\  "private": true,
        \\  "type": "module",
        \\  "packageManager": "{s}",
        \\  "scripts": {{
        \\    "dev": "suji dev",
        \\    "build": "suji build",
        \\    "types": "suji types --out frontend/src/suji.generated.d.ts"
        \\  }},
        \\  "devDependencies": {{
        \\    "@suji/cli": "^0.1.0"
        \\  }}
        \\}}
        \\
    , .{ name, pm.packageManagerField() });
    _ = allocator;
    try writeFileContent(dir, "package.json", content);
}

fn writeConfig(allocator: std.mem.Allocator, dir: Dir, name: []const u8, backend: BackendLang, frontend: FrontendTemplate, pm: PackageManager) !void {
    var buf: [3072]u8 = undefined;
    const frontend_json = try std.fmt.allocPrint(
        allocator,
        \\  "frontend": {{ "dir": "frontend", "dev_url": "{s}", "dev_command": "{s}", "build_command": "{s}", "dist_dir": "{s}" }}
    ,
        .{ frontend.devUrl(), pm.runCommand("dev"), pm.runCommand("build"), frontend.distDir() },
    );
    defer allocator.free(frontend_json);

    const content = switch (backend) {
        .none => try std.fmt.bufPrint(&buf,
            \\{{
            \\  "$schema": "https://raw.githubusercontent.com/ohah/suji/main/suji.schema.json",
            \\  "app": {{ "name": "{s}", "version": "0.1.0" }},
            \\  "windows": [{{ "name": "main", "title": "{s}", "width": 1024, "height": 768, "debug": true }}],
            \\{s}
            \\}}
        , .{ name, name, frontend_json }),
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
            \\{s}
            \\}}
        , .{ name, name, frontend_json }),
        else => try std.fmt.bufPrint(&buf,
            \\{{
            \\  "$schema": "https://raw.githubusercontent.com/ohah/suji/main/suji.schema.json",
            \\  "app": {{ "name": "{s}", "version": "0.1.0" }},
            \\  "windows": [{{ "name": "main", "title": "{s}", "width": 1024, "height": 768, "debug": true }}],
            \\  "backend": {{ "lang": "{s}", "entry": "{s}" }},
            \\{s}
            \\}}
        , .{ name, name, @tagName(backend), backendEntry(backend), frontend_json }),
    };
    try writeFileContent(dir, "suji.json", content);
}

fn backendEntry(backend: BackendLang) []const u8 {
    return switch (backend) {
        .node => "backends/node",
        .lua => "backends/lua",
        else => ".",
    };
}

fn backendLabel(backend: BackendLang) []const u8 {
    return switch (backend) {
        .none => "없음 (frontend-only)",
        .zig => "Zig",
        .rust => "Rust",
        .go => "Go",
        .node => "Node.js",
        .lua => "Lua",
        .multi => "Zig · Rust · Go (multi)",
    };
}

// AGENTS.md / CLAUDE.md 템플릿 토큰 치환 (packages/suji-cli/templates 와 byte-identical).
fn renderAgentDoc(allocator: std.mem.Allocator, tmpl: []const u8, name: []const u8, backend: BackendLang, pm: PackageManager) ![]u8 {
    const pairs = [_][2][]const u8{
        .{ "__NAME__", name },
        .{ "__BACKEND__", backendLabel(backend) },
        .{ "__INSTALL__", pm.installCommand() },
        .{ "__DEV__", pm.runCommand("dev") },
        .{ "__BUILD__", pm.runCommand("build") },
    };
    var out = try allocator.dupe(u8, tmpl);
    for (pairs) |p| {
        const next = try std.mem.replaceOwned(u8, allocator, out, p[0], p[1]);
        allocator.free(out);
        out = next;
    }
    return out;
}

fn writeAgentDocs(allocator: std.mem.Allocator, dir: Dir, name: []const u8, backend: BackendLang, pm: PackageManager) !void {
    const agents = try renderAgentDoc(allocator, @embedFile("../templates/AGENTS.md"), name, backend, pm);
    defer allocator.free(agents);
    try writeFileContent(dir, "AGENTS.md", agents);

    const claude = try renderAgentDoc(allocator, @embedFile("../templates/CLAUDE.md"), name, backend, pm);
    defer allocator.free(claude);
    try writeFileContent(dir, "CLAUDE.md", claude);
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

fn scaffoldNode(dir: Dir) !void {
    try writeFileContent(dir, "package.json", @embedFile("../templates/node_package.json"));
    try writeFileContent(dir, "main.js", @embedFile("../templates/node_main.js"));
}

fn scaffoldLua(dir: Dir) !void {
    try writeFileContent(dir, "main.lua", @embedFile("../templates/lua_main.lua"));
}

// 번들 프론트엔드 템플릿의 상대 파일 목록 (src/templates/frontend/<fw>/).
// @embedFile 가 comptime 이라 목록/파일 불일치는 컴파일 단계에서 실패 →
// 템플릿 회귀 가드. 전 6 프레임워크 bun build 실증(검증 천장: CEF 런타임
// suji.invoke 왕복은 e2e 영역, 여기선 빌드·존재만).
pub fn feFiles(comptime t: FrontendTemplate) []const []const u8 {
    return switch (t) {
        .react_vite => &.{ "package.json", "vite.config.ts", "tsconfig.json", "index.html", "src/suji.ts", "src/main.tsx", "src/App.tsx" },
        .vue_vite => &.{ "package.json", "vite.config.ts", "tsconfig.json", "index.html", "src/suji.ts", "src/main.ts", "src/App.vue" },
        .svelte_vite => &.{ "package.json", "vite.config.ts", "svelte.config.js", "tsconfig.json", "index.html", "src/suji.ts", "src/main.ts", "src/App.svelte" },
        .solid_vite => &.{ "package.json", "vite.config.ts", "tsconfig.json", "index.html", "src/suji.ts", "src/index.tsx", "src/App.tsx" },
        .preact_vite => &.{ "package.json", "vite.config.ts", "tsconfig.json", "index.html", "src/suji.ts", "src/main.tsx", "src/app.tsx" },
        .vanilla_vite => &.{ "package.json", "vite.config.ts", "tsconfig.json", "index.html", "src/suji.ts", "src/main.ts" },
        .react_rsbuild => &.{ "package.json", "rsbuild.config.ts", "tsconfig.json", "index.html", "src/suji.ts", "src/main.tsx", "src/App.tsx" },
        .vue_rsbuild => &.{ "package.json", "rsbuild.config.ts", "tsconfig.json", "index.html", "src/suji.ts", "src/main.ts", "src/App.vue" },
        .next_static => &.{ "package.json", "next.config.mjs", "tsconfig.json", "next-env.d.ts", "app/suji.ts", "app/layout.tsx", "app/page.tsx" },
    };
}

fn templateDir(comptime t: FrontendTemplate) []const u8 {
    return switch (t) {
        .react_vite => "../templates/frontend/react/",
        .vue_vite => "../templates/frontend/vue/",
        .svelte_vite => "../templates/frontend/svelte/",
        .solid_vite => "../templates/frontend/solid/",
        .preact_vite => "../templates/frontend/preact/",
        .vanilla_vite => "../templates/frontend/vanilla/",
        .react_rsbuild => "../templates/frontend/rsbuild-react/",
        .vue_rsbuild => "../templates/frontend/rsbuild-vue/",
        .next_static => "../templates/frontend/next/",
    };
}

pub fn templateDirectoryName(t: FrontendTemplate) []const u8 {
    return switch (t) {
        .react_vite => "react",
        .vue_vite => "vue",
        .svelte_vite => "svelte",
        .solid_vite => "solid",
        .preact_vite => "preact",
        .vanilla_vite => "vanilla",
        .react_rsbuild => "rsbuild-react",
        .vue_rsbuild => "rsbuild-vue",
        .next_static => "next",
    };
}

fn scaffoldFrontend(project_dir: Dir, template: FrontendTemplate) !void {
    const io = runtime.io;
    try project_dir.createDir(io, "frontend", .default_dir);
    var fe = try project_dir.openDir(io, "frontend", .{});
    defer fe.close(io);

    switch (template) {
        .react_vite => try scaffoldFrontendTemplate(.react_vite, fe),
        .vue_vite => try scaffoldFrontendTemplate(.vue_vite, fe),
        .svelte_vite => try scaffoldFrontendTemplate(.svelte_vite, fe),
        .solid_vite => try scaffoldFrontendTemplate(.solid_vite, fe),
        .preact_vite => try scaffoldFrontendTemplate(.preact_vite, fe),
        .vanilla_vite => try scaffoldFrontendTemplate(.vanilla_vite, fe),
        .react_rsbuild => try scaffoldFrontendTemplate(.react_rsbuild, fe),
        .vue_rsbuild => try scaffoldFrontendTemplate(.vue_rsbuild, fe),
        .next_static => try scaffoldFrontendTemplate(.next_static, fe),
    }
}

fn scaffoldFrontendTemplate(comptime template: FrontendTemplate, fe: Dir) !void {
    inline for (comptime feFiles(template)) |rel| {
        const base = comptime templateDir(template);
        const content = @embedFile(base ++ rel);
        try writeNestedFileContent(fe, rel, content);
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

fn installFrontendDependencies(allocator: std.mem.Allocator, project_name: []const u8, pm: PackageManager) !void {
    const io = runtime.io;
    const frontend_path = try std.fmt.allocPrint(allocator, "{s}/frontend", .{project_name});
    defer allocator.free(frontend_path);
    const frontend_real = Dir.cwd().realPathFileAlloc(io, frontend_path, allocator) catch null;
    defer if (frontend_real) |p| allocator.free(p);

    var install = try std.process.spawn(io, .{
        .argv = pm.installArgv(),
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

fn writeNestedFileContent(dir: Dir, rel: []const u8, content: []const u8) !void {
    const io = runtime.io;
    if (std.fs.path.dirname(rel)) |parent| {
        try dir.createDirPath(io, parent);
        var sub = try dir.openDir(io, parent, .{});
        defer sub.close(io);
        const base = std.fs.path.basename(rel);
        return try writeFileContent(sub, base, content);
    }
    try writeFileContent(dir, rel, content);
}
