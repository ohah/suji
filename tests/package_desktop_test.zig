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

test "renderAppRun execs packaged binary in run mode and quotes names" {
    const a = std.testing.allocator;
    const app_run = try package_desktop.renderAppRun(a, "App's Name");
    defer a.free(app_run);

    try std.testing.expect(std.mem.indexOf(u8, app_run, "APPDIR=\"${APPDIR:-$(dirname \"$(readlink -f \"$0\")\")}\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, app_run, "APP_EXEC='App'\\''s Name'") != null);
    try std.testing.expect(std.mem.indexOf(u8, app_run, "exec \"$APPDIR/usr/bin/$APP_EXEC\" run \"$@\"") != null);
}

test "stageLinuxAppDirAt creates AppDir metadata and bundled resources" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    runtime.io = std.testing.io;

    const a = std.testing.allocator;
    const root = try a.dupe(u8, "/tmp/suji-package-appdir-test");
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
    try writeFile(index, "<!doctype html><title>appdir</title>\n");

    const app_dir = try std.fmt.allocPrint(a, "{s}/AppDir E2E.AppDir", .{root});
    defer a.free(app_dir);
    try package_desktop.stageLinuxAppDirAt(a, app_dir, "AppDir E2E App", exe, frontend);

    const app_run_path = try std.fmt.allocPrint(a, "{s}/AppRun", .{app_dir});
    defer a.free(app_run_path);
    const app_run = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, app_run_path, a, .limited(4096));
    defer a.free(app_run);
    try std.testing.expect(std.mem.indexOf(u8, app_run, "APP_EXEC='AppDir E2E App'") != null);

    const desktop_path = try std.fmt.allocPrint(a, "{s}/appdir-e2e-app.desktop", .{app_dir});
    defer a.free(desktop_path);
    const desktop = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, desktop_path, a, .limited(4096));
    defer a.free(desktop);
    try std.testing.expect(std.mem.indexOf(u8, desktop, "Name=AppDir E2E App\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, desktop, "Exec=AppRun\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, desktop, "Icon=app-icon\n") != null);

    const copied_index = try std.fmt.allocPrint(a, "{s}/usr/resources/frontend/index.html", .{app_dir});
    defer a.free(copied_index);
    const index_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, copied_index, a, .limited(4096));
    defer a.free(index_bytes);
    try std.testing.expect(std.mem.indexOf(u8, index_bytes, "appdir") != null);

    const icon_path = try std.fmt.allocPrint(a, "{s}/app-icon.svg", .{app_dir});
    defer a.free(icon_path);
    const icon = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, icon_path, a, .limited(4096));
    defer a.free(icon);
    try std.testing.expect(std.mem.indexOf(u8, icon, "<svg") != null);
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

    const deb = try package_desktop.packageLinuxDebAt(a, root, "Deb E2E App", "1.2.3", exe, frontend, &.{}, &.{});
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
