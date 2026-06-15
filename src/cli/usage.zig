const std = @import("std");

pub fn printUsage() void {
    std.debug.print(
        \\Suji - Zig core multi-backend desktop framework
        \\
        \\Usage:
        \\  suji init <name> [--backend=none|zig|rust|go|node|lua|python|multi]
        \\         [--frontend=react|vue|svelte|solid|preact|vanilla|next]
        \\         [--toolchain=vite|rsbuild|next]
        \\         [--pm=npm|pnpm|bun|vp] [--install]
        \\  suji dev                                     Development mode
        \\  suji build                                   Production build
        \\  suji run [main.js]                           Run production build or embedded Node.js file
        \\  suji types [--out <path>]                    Gen SujiHandlers .d.ts (zig .schema())
        \\
        \\Example:
        \\  suji init my-app --backend=zig --frontend=react --toolchain=vite
        \\  cd my-app && suji dev
        \\
    , .{});
}
