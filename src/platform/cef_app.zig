//! app path/meta API — cef.zig 에서 분리(동작 무변경).
//! Electron app.getPath / app metadata / macOS app activation bridge.
const std = @import("std");
const builtin = @import("builtin");
const runtime = @import("runtime");
const cef = @import("cef.zig");

const is_macos = builtin.os.tag == .macos;

const objc = cef.objc;
const getClass = cef.getClass;
const msgSend = cef.msgSend;
const msgSendVoid1 = cef.msgSendVoid1;
const nsStringToUtf8Buf = cef.nsStringToUtf8Buf;

/// CEF 초기화 — OS 표준 user-data dir + `<app>/Cache` (Electron `app.getPath('userData') + Cache`).
/// root_cache_path:
///   macOS: ~/Library/Application Support/<app>
///   Linux: $XDG_CONFIG_HOME or ~/.config / <app>
///   Windows: %APPDATA% or %USERPROFILE%/AppData/Roaming / <app>
/// cache_path:
///   <root_cache_path>/Cache
/// other: ~/.suji/<app>/Cache (fallback)
///
/// resolveAppDataDir과 OS 분기를 공유 — `<app_data>/<app>/Cache`만 합쳐 cef 디렉토리 포지션.
pub fn buildAppUserDataPath(buf: []u8, home: []const u8, app_name: []const u8) ?[]const u8 {
    var ad_buf: [512]u8 = undefined;
    const app_data = resolveAppDataDir(&ad_buf, home) orelse return null;
    const sep: []const u8 = if (builtin.os.tag == .windows) "\\" else "/";
    return std.fmt.bufPrint(buf, "{s}{s}{s}", .{ app_data, sep, app_name }) catch null;
}

pub fn buildAppCachePath(buf: []u8, home: []const u8, app_name: []const u8) ?[]const u8 {
    const sep: []const u8 = if (builtin.os.tag == .windows) "\\" else "/";
    var user_data_buf: [512]u8 = undefined;
    const user_data = buildAppUserDataPath(&user_data_buf, home, app_name) orelse return null;
    return std.fmt.bufPrint(buf, "{s}{s}Cache", .{ user_data, sep }) catch null;
}

test "buildAppCachePath: 현재 OS 표준 경로 + app_name 포함" {
    var buf: [512]u8 = undefined;
    const path = buildAppCachePath(&buf, "/Users/test", "MyApp").?;
    // 모든 OS에서 home prefix + app_name + Cache는 공통.
    try std.testing.expect(std.mem.indexOf(u8, path, "MyApp") != null);
    try std.testing.expect(std.mem.endsWith(u8, path, "Cache"));
    // OS별 분기 — 빌드 시점 OS만 검증.
    switch (builtin.os.tag) {
        .macos => {
            try std.testing.expect(std.mem.startsWith(u8, path, "/Users/test/Library/Application Support/MyApp"));
        },
        .linux => {
            // XDG 미설정 시 ~/.config; 설정 시 그 경로. test env에 XDG가 없을 가능성 높음.
            try std.testing.expect(std.mem.indexOf(u8, path, "/MyApp/Cache") != null);
        },
        .windows => {
            try std.testing.expect(std.mem.indexOf(u8, path, "MyApp\\Cache") != null);
        },
        else => {},
    }
}

test "buildAppUserDataPath: cache path parent is CEF root cache path" {
    var root_buf: [512]u8 = undefined;
    var cache_buf: [512]u8 = undefined;
    const root = buildAppUserDataPath(&root_buf, "/Users/test", "MyApp").?;
    const cache = buildAppCachePath(&cache_buf, "/Users/test", "MyApp").?;

    try std.testing.expect(std.mem.startsWith(u8, cache, root));
    try std.testing.expect(std.mem.endsWith(u8, cache, "Cache"));
    try std.testing.expect(!std.mem.eql(u8, root, cache));
}

test "buildAppCachePath: 너무 긴 path는 null" {
    var small_buf: [16]u8 = undefined;
    try std.testing.expect(buildAppCachePath(&small_buf, "/Users/test", "VeryLongAppName") == null);
}

/// app.getPath (Electron) — 표준 디렉토리 경로 반환. app_name은 userData에만 사용.
/// home/userData/appData/temp/desktop/documents/downloads 7가지 키 지원.
/// pure 함수 — env는 caller가 미리 lookup해서 home/appdata/tmp/xdg에 전달.
pub const StandardPathInputs = struct {
    home: []const u8,
    /// macOS: ~/Library/Application Support / Linux: $XDG_CONFIG_HOME or ~/.config /
    /// Windows: %APPDATA%. caller가 미리 resolve.
    app_data: []const u8,
    /// $TMPDIR or fallback (`/tmp`).
    tmp: []const u8,
};

pub fn buildStandardPath(buf: []u8, name: []const u8, app_name: []const u8, in: StandardPathInputs) ?[]const u8 {
    const sep: []const u8 = if (builtin.os.tag == .windows) "\\" else "/";
    const result = if (std.mem.eql(u8, name, "home"))
        std.fmt.bufPrint(buf, "{s}", .{in.home})
    else if (std.mem.eql(u8, name, "appData"))
        std.fmt.bufPrint(buf, "{s}", .{in.app_data})
    else if (std.mem.eql(u8, name, "userData"))
        std.fmt.bufPrint(buf, "{s}{s}{s}", .{ in.app_data, sep, app_name })
    else if (std.mem.eql(u8, name, "temp"))
        std.fmt.bufPrint(buf, "{s}", .{in.tmp})
    else if (std.mem.eql(u8, name, "desktop"))
        std.fmt.bufPrint(buf, "{s}{s}Desktop", .{ in.home, sep })
    else if (std.mem.eql(u8, name, "documents"))
        std.fmt.bufPrint(buf, "{s}{s}Documents", .{ in.home, sep })
    else if (std.mem.eql(u8, name, "downloads"))
        std.fmt.bufPrint(buf, "{s}{s}Downloads", .{ in.home, sep })
    else
        return null;
    return result catch null;
}

/// macOS/Linux/Windows의 app_data prefix만 분리 — buildAppCachePath와 동일 OS 분기.
/// Cache suffix가 붙기 전 단계라서 Electron `appData`에 매핑.
fn resolveAppDataDir(buf: []u8, home: []const u8) ?[]const u8 {
    const result = switch (builtin.os.tag) {
        .macos => std.fmt.bufPrint(buf, "{s}/Library/Application Support", .{home}),
        .linux => blk: {
            const xdg = runtime.env("XDG_CONFIG_HOME");
            if (xdg) |x| if (x.len > 0) break :blk std.fmt.bufPrint(buf, "{s}", .{x});
            break :blk std.fmt.bufPrint(buf, "{s}/.config", .{home});
        },
        .windows => blk: {
            const appdata = runtime.env("APPDATA");
            if (appdata) |a| break :blk std.fmt.bufPrint(buf, "{s}", .{a});
            break :blk std.fmt.bufPrint(buf, "{s}\\AppData\\Roaming", .{home});
        },
        else => std.fmt.bufPrint(buf, "{s}/.suji", .{home}),
    } catch return null;
    return result;
}

/// Electron `app.getPath(name)` — IPC 진입점에서 호출. app_name은 config.app.name.
pub fn appGetPath(buf: []u8, name: []const u8, app_name: []const u8) ?[]const u8 {
    const home_env = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
    const home = runtime.env(home_env) orelse return null;
    var ad_buf: [512]u8 = undefined;
    const app_data = resolveAppDataDir(&ad_buf, home) orelse return null;
    const tmp = runtime.env("TMPDIR") orelse "/tmp";
    return buildStandardPath(buf, name, app_name, .{ .home = home, .app_data = app_data, .tmp = tmp });
}

test "buildStandardPath: 7 키 모두 home/app_data/tmp 기반으로 path 빌드" {
    const in = StandardPathInputs{
        .home = "/Users/test",
        .app_data = "/Users/test/Library/Application Support",
        .tmp = "/var/folders/T",
    };
    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings("/Users/test", buildStandardPath(&buf, "home", "MyApp", in).?);
    try std.testing.expectEqualStrings("/Users/test/Library/Application Support", buildStandardPath(&buf, "appData", "MyApp", in).?);
    try std.testing.expectEqualStrings("/Users/test/Library/Application Support/MyApp", buildStandardPath(&buf, "userData", "MyApp", in).?);
    try std.testing.expectEqualStrings("/var/folders/T", buildStandardPath(&buf, "temp", "MyApp", in).?);
    try std.testing.expectEqualStrings("/Users/test/Desktop", buildStandardPath(&buf, "desktop", "MyApp", in).?);
    try std.testing.expectEqualStrings("/Users/test/Documents", buildStandardPath(&buf, "documents", "MyApp", in).?);
    try std.testing.expectEqualStrings("/Users/test/Downloads", buildStandardPath(&buf, "downloads", "MyApp", in).?);
    try std.testing.expect(buildStandardPath(&buf, "unknown", "MyApp", in) == null);
}

/// 메인 번들 경로 (Electron `app.getAppPath` 동등). macOS NSBundle.mainBundle.bundlePath.
/// dev mode (raw binary)에선 binary가 위치한 디렉토리, .app 번들 실행 시 ".../MyApp.app".
pub fn appGetBundlePath(buf: []u8) []const u8 {
    if (!comptime is_macos) return buf[0..0];
    const NSBundle = getClass("NSBundle") orelse return buf[0..0];
    const main_bundle = msgSend(NSBundle, "mainBundle") orelse return buf[0..0];
    const path = msgSend(main_bundle, "bundlePath") orelse return buf[0..0];
    return nsStringToUtf8Buf(path, buf);
}

/// `.app` 번들로 실행 중인지 (Electron `app.isPackaged`). bundlePath가 ".app"로 끝나면 packaged.
pub fn appIsPackaged() bool {
    var buf: [1024]u8 = undefined;
    const path = appGetBundlePath(&buf);
    return std.mem.endsWith(u8, path, ".app");
}

/// 시스템 locale (Electron `app.getLocale()`). 예: "en-US", "ko-KR".
/// `[NSLocale currentLocale] localeIdentifier` 반환 — POSIX style ("en_US")이라
/// underscore → hyphen 치환해 BCP 47 형식으로 통일.
pub fn appGetLocale(out_buf: []u8) []const u8 {
    if (!comptime is_macos) return out_buf[0..0];
    const NSLocale = getClass("NSLocale") orelse return out_buf[0..0];
    const locale = msgSend(NSLocale, "currentLocale") orelse return out_buf[0..0];
    const id_obj = msgSend(locale, "localeIdentifier") orelse return out_buf[0..0];
    const raw = nsStringToUtf8Buf(id_obj, out_buf);
    // POSIX → BCP 47 (en_US → en-US).
    for (out_buf[0..raw.len]) |*c2| if (c2.* == '_') {
        c2.* = '-';
    };
    return raw;
}

/// 앱을 frontmost로 (Electron `app.focus()`). NSApp `activateIgnoringOtherApps:`.
pub fn appFocus() bool {
    if (!comptime is_macos) return false;
    const NSApplication = getClass("NSApplication") orelse return false;
    const app = msgSend(NSApplication, "sharedApplication") orelse return false;
    const f: *const fn (?*anyopaque, ?*anyopaque, u8) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    f(app, @ptrCast(objc.sel_registerName("activateIgnoringOtherApps:")), 1);
    return true;
}

/// 앱 모든 윈도우 hide (Electron `app.hide()` macOS-only — Cmd+H 동등).
pub fn appHide() bool {
    if (!comptime is_macos) return false;
    const NSApplication = getClass("NSApplication") orelse return false;
    const app = msgSend(NSApplication, "sharedApplication") orelse return false;
    msgSendVoid1(app, "hide:", null);
    return true;
}
