const std = @import("std");
const init = @import("init");

test "BackendLang.fromString: 유효 토큰 + unknown→null" {
    try std.testing.expectEqual(init.BackendLang.zig, init.BackendLang.fromString("zig").?);
    try std.testing.expectEqual(init.BackendLang.rust, init.BackendLang.fromString("rust").?);
    try std.testing.expectEqual(init.BackendLang.go, init.BackendLang.fromString("go").?);
    try std.testing.expectEqual(init.BackendLang.multi, init.BackendLang.fromString("multi").?);
    try std.testing.expect(init.BackendLang.fromString("python") == null);
    try std.testing.expect(init.BackendLang.fromString("") == null);
    try std.testing.expect(init.BackendLang.fromString("Rust") == null); // case-sensitive
}

test "FrontendTemplate.fromString: 6 프레임워크 + unknown→null" {
    try std.testing.expectEqual(init.FrontendTemplate.react, init.FrontendTemplate.fromString("react").?);
    try std.testing.expectEqual(init.FrontendTemplate.vue, init.FrontendTemplate.fromString("vue").?);
    try std.testing.expectEqual(init.FrontendTemplate.svelte, init.FrontendTemplate.fromString("svelte").?);
    try std.testing.expectEqual(init.FrontendTemplate.solid, init.FrontendTemplate.fromString("solid").?);
    try std.testing.expectEqual(init.FrontendTemplate.preact, init.FrontendTemplate.fromString("preact").?);
    try std.testing.expectEqual(init.FrontendTemplate.vanilla, init.FrontendTemplate.fromString("vanilla").?);
    try std.testing.expect(init.FrontendTemplate.fromString("angular") == null);
    try std.testing.expect(init.FrontendTemplate.fromString("") == null);
    try std.testing.expect(init.FrontendTemplate.fromString("React") == null); // case-sensitive
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

    // 프레임워크 목록을 enum 에서 파생 — 7번째 추가 시 자동 커버.
    inline for (std.meta.fields(init.FrontendTemplate)) |f| {
        const t = @field(init.FrontendTemplate, f.name);
        const src_base = "src/templates/frontend/" ++ f.name ++ "/";
        const mir_base = "packages/suji-cli/templates/frontend/" ++ f.name ++ "/";
        inline for (comptime init.feFiles(t)) |rel| {
            const s = try slurp(a, src_base ++ rel);
            defer a.free(s);
            const m = try slurp(a, mir_base ++ rel);
            defer a.free(m);
            // suji-cli 미러는 src/templates 와 byte-동형 (lockstep 가드).
            try std.testing.expectEqualStrings(s, m);
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
    inline for (.{ "gitignore", "zig_app.zig", "rust_cargo.toml", "rust_lib.rs", "go_main.go" }) |rf| {
        const s = try slurp(a, "src/templates/" ++ rf);
        defer a.free(s);
        const m = try slurp(a, "packages/suji-cli/templates/" ++ rf);
        defer a.free(m);
        try std.testing.expectEqualStrings(s, m);
    }
}

test "InitOptions: 기본값 rust 백엔드 + react 프론트엔드" {
    const opts = init.InitOptions{ .name = "x" };
    try std.testing.expectEqual(init.BackendLang.rust, opts.backend);
    try std.testing.expectEqual(init.FrontendTemplate.react, opts.frontend);
}
