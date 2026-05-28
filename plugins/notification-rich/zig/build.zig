const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const util_mod = b.createModule(.{
        .root_source_file = b.path("../../../src/core/util.zig"),
        .target = target,
        .optimize = optimize,
    });

    const suji_mod = b.createModule(.{
        .root_source_file = b.path("../../../src/core/app.zig"),
        .target = target,
        .optimize = optimize,
    });
    suji_mod.addImport("util", util_mod);

    const lib = b.addLibrary(.{
        .name = "backend",
        .root_module = b.createModule(.{
            .root_source_file = b.path("app.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
        .linkage = .dynamic,
    });
    lib.root_module.addImport("suji", suji_mod);

    if (target.result.os.tag == .macos) {
        lib.root_module.addCSourceFile(.{
            .file = b.path("notification_rich_macos.m"),
            .flags = &[_][]const u8{"-fobjc-arc"},
        });
        lib.root_module.linkSystemLibrary("objc", .{});
        lib.root_module.linkFramework("AppKit", .{});
        lib.root_module.linkFramework("Foundation", .{});
        lib.root_module.linkFramework("UserNotifications", .{});
    } else if (target.result.os.tag == .linux) {
        lib.root_module.addCSourceFile(.{
            .file = b.path("notification_rich_linux.c"),
            .flags = &[_][]const u8{},
        });
        lib.root_module.linkSystemLibrary("gio-2.0", .{});
        lib.root_module.linkSystemLibrary("gobject-2.0", .{});
        lib.root_module.linkSystemLibrary("glib-2.0", .{});
    } else if (target.result.os.tag == .windows) {
        // WinRT 함수는 모두 combase.dll/shell32.dll 동적 로드(LoadLibraryW +
        // GetProcAddress)로 호출 — MinGW import lib 부재 회피 + graceful
        // degradation (Win7-/no-WinRT 환경 자동 fallback).
        lib.root_module.linkSystemLibrary("kernel32", .{});
    }

    b.installArtifact(lib);
}
