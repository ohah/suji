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

test "FrontendTemplate.viteTemplate: create-vite -ts 식별자 매핑" {
    // 프론트엔드 스캐폴딩을 create-vite 에 위임 — 매핑이 create-vite 의 실
    // 템플릿명과 어긋나면 스캐폴딩이 침묵 실패하므로 계약을 고정.
    try std.testing.expectEqualStrings("react-ts", init.FrontendTemplate.react.viteTemplate());
    try std.testing.expectEqualStrings("vue-ts", init.FrontendTemplate.vue.viteTemplate());
    try std.testing.expectEqualStrings("svelte-ts", init.FrontendTemplate.svelte.viteTemplate());
    try std.testing.expectEqualStrings("solid-ts", init.FrontendTemplate.solid.viteTemplate());
    try std.testing.expectEqualStrings("preact-ts", init.FrontendTemplate.preact.viteTemplate());
    try std.testing.expectEqualStrings("vanilla-ts", init.FrontendTemplate.vanilla.viteTemplate());

    // 모든 variant 가 -ts 로 끝남(전 템플릿 TypeScript 통일 계약).
    inline for (std.meta.fields(init.FrontendTemplate)) |f| {
        const tmpl = @as(init.FrontendTemplate, @enumFromInt(f.value)).viteTemplate();
        try std.testing.expect(std.mem.endsWith(u8, tmpl, "-ts"));
    }
}

test "InitOptions: 기본값 rust 백엔드 + react 프론트엔드" {
    const opts = init.InitOptions{ .name = "x" };
    try std.testing.expectEqual(init.BackendLang.rust, opts.backend);
    try std.testing.expectEqual(init.FrontendTemplate.react, opts.frontend);
}
