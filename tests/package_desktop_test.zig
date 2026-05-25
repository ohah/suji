const std = @import("std");
const package_desktop = @import("package_desktop");
const runtime = @import("runtime");
const builtin = @import("builtin");

fn writeFile(path: []const u8, content: []const u8) !void {
    const io = std.testing.io;
    var f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    var buf: [1024]u8 = undefined;
    var w = f.writer(io, &buf);
    try w.interface.writeAll(content);
    try w.interface.flush();
}

test "sanitizeDebPackageName normalizes user app names" {
    const a = std.testing.allocator;
    const one = try package_desktop.sanitizeDebPackageName(a, "My Cool_App!");
    defer a.free(one);
    try std.testing.expectEqualStrings("my-cool-app", one);

    const two = try package_desktop.sanitizeDebPackageName(a, "...Bad Name\n");
    defer a.free(two);
    try std.testing.expectEqualStrings("bad-name", two);

    const three = try package_desktop.sanitizeDebPackageName(a, "!");
    defer a.free(three);
    try std.testing.expectEqualStrings("suji-app", three);
}

test "renderDebControl emits required Debian control fields without line injection" {
    const a = std.testing.allocator;
    const control = try package_desktop.renderDebControl(a, "my-app", "1.2.3\nBad: yes", "amd64", "My App\r\nOops");
    defer a.free(control);

    try std.testing.expect(std.mem.indexOf(u8, control, "Package: my-app\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, control, "Version: 1.2.3 Bad: yes\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, control, "Architecture: amd64\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, control, "Description: My App Oops desktop application\n") != null);
}

test "packageLinuxDebAt creates a Debian ar archive with control and data members" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    runtime.io = std.testing.io;

    const a = std.testing.allocator;
    const root = try a.dupe(u8, "/tmp/suji-package-desktop-test");
    defer a.free(root);
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root);

    const exe = try std.fmt.allocPrint(a, "{s}/fake-suji", .{root});
    defer a.free(exe);
    try writeFile(exe, "#!/usr/bin/env sh\necho fake\n");

    const frontend = try std.fmt.allocPrint(a, "{s}/frontend-dist", .{root});
    defer a.free(frontend);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, frontend);
    const index = try std.fmt.allocPrint(a, "{s}/index.html", .{frontend});
    defer a.free(index);
    try writeFile(index, "<!doctype html><title>fake</title>\n");

    const deb = try package_desktop.packageLinuxDebAt(a, root, "Deb E2E App", "1.2.3", exe, frontend);
    defer a.free(deb);
    try std.testing.expect(std.mem.endsWith(u8, deb, ".deb"));
    try std.testing.expect(std.mem.indexOf(u8, deb, "deb-e2e-app_1.2.3_") != null);

    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, deb, a, .limited(1024 * 1024));
    defer a.free(bytes);
    try std.testing.expect(std.mem.startsWith(u8, bytes, "!<arch>\n"));
    try std.testing.expect(std.mem.indexOf(u8, bytes, "debian-binary") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "control.tar.gz") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "data.tar.gz") != null);
}
