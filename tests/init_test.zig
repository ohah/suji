const std = @import("std");
const init = @import("init");

test "BackendLang.fromString: 유효 토큰 + unknown→null" {
    try std.testing.expectEqual(init.BackendLang.none, init.BackendLang.fromString("none").?);
    try std.testing.expectEqual(init.BackendLang.zig, init.BackendLang.fromString("zig").?);
    try std.testing.expectEqual(init.BackendLang.rust, init.BackendLang.fromString("rust").?);
    try std.testing.expectEqual(init.BackendLang.go, init.BackendLang.fromString("go").?);
    try std.testing.expectEqual(init.BackendLang.node, init.BackendLang.fromString("node").?);
    try std.testing.expectEqual(init.BackendLang.lua, init.BackendLang.fromString("lua").?);
    try std.testing.expectEqual(init.BackendLang.python, init.BackendLang.fromString("python").?);
    try std.testing.expectEqual(init.BackendLang.multi, init.BackendLang.fromString("multi").?);
    try std.testing.expect(init.BackendLang.fromString("") == null);
    try std.testing.expect(init.BackendLang.fromString("Rust") == null); // case-sensitive
}

test "FrontendTemplate.fromString: framework aliases, composites, and unknown" {
    try std.testing.expectEqual(init.FrontendTemplate.react_vite, init.FrontendTemplate.fromString("react").?);
    try std.testing.expectEqual(init.FrontendTemplate.vue_vite, init.FrontendTemplate.fromString("vue").?);
    try std.testing.expectEqual(init.FrontendTemplate.svelte_vite, init.FrontendTemplate.fromString("svelte").?);
    try std.testing.expectEqual(init.FrontendTemplate.solid_vite, init.FrontendTemplate.fromString("solid").?);
    try std.testing.expectEqual(init.FrontendTemplate.preact_vite, init.FrontendTemplate.fromString("preact").?);
    try std.testing.expectEqual(init.FrontendTemplate.vanilla_vite, init.FrontendTemplate.fromString("vanilla").?);
    try std.testing.expectEqual(init.FrontendTemplate.react_rsbuild, init.FrontendTemplate.fromString("react_rsbuild").?);
    try std.testing.expectEqual(init.FrontendTemplate.next_static, init.FrontendTemplate.fromString("next_static").?);
    try std.testing.expect(init.FrontendTemplate.fromString("angular") == null);
    try std.testing.expect(init.FrontendTemplate.fromString("") == null);
    try std.testing.expect(init.FrontendTemplate.fromString("React") == null); // case-sensitive
}

test "Frontend framework/toolchain matrix" {
    try std.testing.expectEqual(init.FrontendToolchain.rsbuild, init.FrontendToolchain.fromString("rspack").?);
    try std.testing.expectEqual(init.FrontendTemplate.react_vite, init.FrontendTemplate.fromFrameworkToolchain(.react, .vite).?);
    try std.testing.expectEqual(init.FrontendTemplate.vue_rsbuild, init.FrontendTemplate.fromFrameworkToolchain(.vue, .rsbuild).?);
    try std.testing.expectEqual(init.FrontendTemplate.next_static, init.FrontendTemplate.fromFrameworkToolchain(.next, .next).?);
    try std.testing.expectEqual(init.FrontendTemplate.next_static, init.FrontendTemplate.fromFrameworkToolchain(.react, .next).?);
    try std.testing.expect(init.FrontendTemplate.fromFrameworkToolchain(.svelte, .rsbuild) == null);
    try std.testing.expect(init.FrontendTemplate.fromFrameworkToolchain(.vanilla, .next) == null);
}

test "PackageManager commands include VoidZero Vite+ aliases" {
    try std.testing.expectEqual(init.PackageManager.npm, init.PackageManager.fromString("npm").?);
    try std.testing.expectEqual(init.PackageManager.pnpm, init.PackageManager.fromString("pnpm").?);
    try std.testing.expectEqual(init.PackageManager.bun, init.PackageManager.fromString("bun").?);
    try std.testing.expectEqual(init.PackageManager.vp, init.PackageManager.fromString("vp").?);
    try std.testing.expectEqual(init.PackageManager.vp, init.PackageManager.fromString("vz").?);
    try std.testing.expectEqual(init.PackageManager.vp, init.PackageManager.fromString("voidzero").?);
    try std.testing.expectEqualStrings("vp install", init.PackageManager.vp.installCommand());
    try std.testing.expectEqualStrings("vp run dev", init.PackageManager.vp.runCommand("dev"));
    try std.testing.expectEqualStrings("vp run build", init.PackageManager.vp.runCommand("build"));
    try std.testing.expectEqualStrings("pnpm@latest", init.PackageManager.vp.packageManagerField());
}

fn slurp(a: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(1 << 16));
}

test "번들 프론트엔드 템플릿: 계약 + suji-cli 미러 drift 가드" {
    // 스캐폴딩이 create-vite 대신 src/templates/frontend/<fw>/ 트리를
    // @embedFile(init.feFiles 매니페스트). init.zig comptime 가 src/ 측
    // 파일 존재를 강제하지만 suji-cli/templates 미러는 무가드였다 →
    // 동일 feFiles 를 구동해 (a)데모 계약 (b)미러 byte-동형 을 함께 검증.
    const a = std.testing.allocator;

    const ref_suji = try slurp(a, "src/templates/frontend/react/src/suji.ts");
    defer a.free(ref_suji);
    // @suji/api 미발행 → 로컬 래퍼가 window.__suji__ 를 감싸야 한다.
    try std.testing.expect(std.mem.indexOf(u8, ref_suji, "__suji__") != null);
    try std.testing.expect(std.mem.indexOf(u8, ref_suji, "export function invoke") != null);

    // 프레임워크/툴체인 목록을 enum 에서 파생 — 추가 시 자동 커버.
    inline for (std.meta.fields(init.FrontendTemplate)) |f| {
        const t = @field(init.FrontendTemplate, f.name);
        const dir_name = init.templateDirectoryName(t);
        inline for (comptime init.feFiles(t)) |rel| {
            const src_path = try std.fmt.allocPrint(a, "src/templates/frontend/{s}/{s}", .{ dir_name, rel });
            defer a.free(src_path);
            const mir_path = try std.fmt.allocPrint(a, "packages/suji-cli/templates/frontend/{s}/{s}", .{ dir_name, rel });
            defer a.free(mir_path);

            const s = try slurp(a, src_path);
            defer a.free(s);
            const m = try slurp(a, mir_path);
            defer a.free(m);
            // suji-cli 미러는 src/templates 와 byte-동형 (lockstep 가드).
            try std.testing.expectEqualStrings(s, m);
            if (comptime std.mem.endsWith(u8, rel, "suji.ts")) {
                try std.testing.expect(std.mem.indexOf(u8, s, "__suji__") != null);
                try std.testing.expect(std.mem.indexOf(u8, s, "function invoke") != null);
            }
            if (comptime std.mem.eql(u8, rel, "src/suji.ts")) {
                try std.testing.expectEqualStrings(ref_suji, s); // 전 fw 동형
            }
            if (comptime std.mem.eql(u8, rel, "package.json")) {
                try std.testing.expect(std.mem.indexOf(u8, s, "\"build\"") != null);
                try std.testing.expect(std.mem.indexOf(u8, s, "@suji/api") == null);
            }
        }
    }

    // 루트 백엔드 템플릿 미러도 동일 가드 (init.zig @embedFile 무가드였음).
    inline for (.{ "gitignore", "zig_app.zig", "rust_cargo.toml", "rust_lib.rs", "go_main.go", "node_package.json", "node_main.js", "lua_main.lua", "python_main.py", "multi_lua_main.lua", "multi_python_main.py", "multi_node_main.js", ".github/workflows/suji.yml" }) |rf| {
        const s = try slurp(a, "src/templates/" ++ rf);
        defer a.free(s);
        const m = try slurp(a, "packages/suji-cli/templates/" ++ rf);
        defer a.free(m);
        try std.testing.expectEqualStrings(s, m);
    }

    const workflow = try slurp(a, "src/templates/.github/workflows/suji.yml");
    defer a.free(workflow);
    try std.testing.expect(std.mem.indexOf(u8, workflow, "bun run build") != null);
    try std.testing.expect(std.mem.indexOf(u8, workflow, "zig fmt --check") != null);
    try std.testing.expect(std.mem.indexOf(u8, workflow, "cargo build --manifest-path") != null);
    try std.testing.expect(std.mem.indexOf(u8, workflow, "go build ./...") != null);
}

test "InitOptions: 기본값 zig 백엔드 + react/vite 프론트엔드" {
    const opts = init.InitOptions{ .name = "x" };
    try std.testing.expectEqual(init.BackendLang.zig, opts.backend);
    try std.testing.expectEqual(init.FrontendTemplate.react_vite, opts.frontend);
    try std.testing.expectEqual(init.PackageManager.npm, opts.package_manager);
    try std.testing.expect(!opts.install_dependencies);
}
