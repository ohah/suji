const std = @import("std");
const init_mod = @import("../core/init.zig");

const INIT_USAGE = "Usage: suji init <project-name> [--backend=none|zig|rust|go|node|lua|multi] [--frontend=react|vue|svelte|solid|preact|vanilla|next] [--toolchain=vite|rsbuild|next] [--pm=npm|pnpm|bun|vp] [--install]\n";

pub fn run(allocator: std.mem.Allocator, init_args: []const [:0]const u8) !void {
    var name: []const u8 = "";
    var backend = init_mod.BackendLang.zig;
    var frontend_framework = init_mod.FrontendFramework.react;
    var frontend_toolchain = init_mod.FrontendToolchain.vite;
    var frontend_template: ?init_mod.FrontendTemplate = null;
    var package_manager = init_mod.PackageManager.npm;
    var install_dependencies = false;

    const backend_prefix = "--backend=";
    const frontend_prefix = "--frontend=";
    const toolchain_prefix = "--toolchain=";
    const pm_prefix = "--pm=";
    for (init_args) |arg| {
        if (std.mem.startsWith(u8, arg, backend_prefix)) {
            const lang_str = arg[backend_prefix.len..];
            backend = init_mod.BackendLang.fromString(lang_str) orelse {
                std.debug.print("Unknown backend: {s}. Use: none, zig, rust, go, node, lua, multi\n", .{lang_str});
                return;
            };
        } else if (std.mem.startsWith(u8, arg, frontend_prefix)) {
            const fe_str = arg[frontend_prefix.len..];
            if (init_mod.FrontendTemplate.fromString(fe_str)) |tpl| {
                frontend_template = tpl;
            } else if (init_mod.FrontendFramework.fromString(fe_str)) |fw| {
                frontend_framework = fw;
                if (fw == .next) frontend_toolchain = .next;
            } else {
                std.debug.print("Unknown frontend: {s}. Use: react, vue, svelte, solid, preact, vanilla, next\n", .{fe_str});
                return;
            }
        } else if (std.mem.startsWith(u8, arg, toolchain_prefix)) {
            const tc_str = arg[toolchain_prefix.len..];
            frontend_toolchain = init_mod.FrontendToolchain.fromString(tc_str) orelse {
                std.debug.print("Unknown toolchain: {s}. Use: vite, rsbuild, next\n", .{tc_str});
                return;
            };
        } else if (std.mem.startsWith(u8, arg, pm_prefix)) {
            const pm_str = arg[pm_prefix.len..];
            package_manager = init_mod.PackageManager.fromString(pm_str) orelse {
                std.debug.print("Unknown package manager: {s}. Use: npm, pnpm, bun, vp\n", .{pm_str});
                return;
            };
        } else if (std.mem.eql(u8, arg, "--install")) {
            install_dependencies = true;
        } else if (std.mem.eql(u8, arg, "--no-install")) {
            install_dependencies = false;
        } else {
            name = arg;
        }
    }

    // 빈 인자 / name 누락 모두 여기서 커버 (init_args.len==0 → name 그대로 "").
    if (name.len == 0) {
        std.debug.print(INIT_USAGE, .{});
        return;
    }

    const frontend = frontend_template orelse init_mod.FrontendTemplate.fromFrameworkToolchain(frontend_framework, frontend_toolchain) orelse {
        std.debug.print("Unsupported frontend/toolchain combination: {s}+{s}\n", .{ @tagName(frontend_framework), @tagName(frontend_toolchain) });
        return;
    };

    try init_mod.run(allocator, .{
        .name = name,
        .backend = backend,
        .frontend = frontend,
        .package_manager = package_manager,
        .install_dependencies = install_dependencies,
    });
}
