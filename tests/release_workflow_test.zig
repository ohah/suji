const std = @import("std");

fn slurp(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1 << 20));
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

test "release workflow publishes only tags or explicit non-dry-run dispatch" {
    const allocator = std.testing.allocator;
    const workflow = try slurp(allocator, ".github/workflows/release.yml");
    defer allocator.free(workflow);

    try expectContains(workflow, "tags: ['v*.*.*']");
    try expectContains(workflow, "workflow_dispatch:");
    try expectContains(workflow, "dry_run:");
    try expectContains(workflow, "default: true");
    try expectContains(workflow, "permissions:");
    try expectContains(workflow, "contents: write");
    try expectContains(workflow, "bash scripts/version.sh --check");
    try expectContains(workflow, "if: github.event_name == 'push' || github.event.inputs.dry_run == 'false'");
    try expectContains(workflow, "softprops/action-gh-release@v2");
}

test "release workflow builds expected desktop and embed artifacts" {
    const allocator = std.testing.allocator;
    const workflow = try slurp(allocator, ".github/workflows/release.yml");
    defer allocator.free(workflow);

    inline for (.{
        "asset: suji-macos-arm64",
        "asset: suji-linux-x64",
        "asset: suji-windows-x64",
        "cef_platform: macos-arm64",
        "cef_platform: linux-x86_64",
        "cef_platform: windows-x86_64",
        "zig build -Doptimize=ReleaseSafe",
        "ios-arm64|-Dtarget=aarch64-ios",
        "android-arm64|-Dtarget=aarch64-linux-android",
        "windows-x64|-Dtarget=x86_64-windows",
        "zig build lib $flags",
        "suji-embed-libs-$V.tar.gz",
        "CHECKSUMS.txt",
    }) |needle| {
        try expectContains(workflow, needle);
    }
}

test "release docs and PLAN agree that GitHub Releases automation exists" {
    const allocator = std.testing.allocator;
    const plan = try slurp(allocator, "docs/PLAN.md");
    defer allocator.free(plan);
    const releasing = try slurp(allocator, "docs/RELEASING.md");
    defer allocator.free(releasing);
    const claude = try slurp(allocator, "CLAUDE.md");
    defer allocator.free(claude);

    try expectContains(plan, "GitHub Releases CI 자동 빌드");
    try expectContains(plan, "release.yml");
    try expectContains(releasing, "GitHub Releases 자동화");
    try expectContains(releasing, "release.yml");
    try expectContains(claude, "GitHub Releases");
    try expectContains(claude, "release.yml");
}
