const std = @import("std");
const runtime = @import("runtime");
const proc = @import("core/proc.zig");

const Dir = std.Io.Dir;

/// macOS .app 번들 생성
///
/// 구조:
/// {name}.app/
/// ├── Contents/
/// │   ├── Info.plist
/// │   ├── MacOS/
/// │   │   └── {name}              ← 메인 바이너리
/// │   ├── Frameworks/
/// │   │   ├── Chromium Embedded Framework.framework/
/// │   │   ├── {name} Helper.app/
/// │   │   ├── {name} Helper (GPU).app/
/// │   │   ├── {name} Helper (Renderer).app/
/// │   │   └── {name} Helper (Plugin).app/
/// │   └── Resources/
/// │       └── frontend/           ← 프론트엔드 빌드 결과
/// 코드 서명 모드 (zero-native `--signing` 패리티).
/// - none: 서명 생략 (로컬 빌드/검증용).
/// - adhoc: ad-hoc 서명 (`codesign --sign -`) — 기본, 배포 불가하나 로컬 실행 OK.
/// - identity: Developer ID 서명 + hardened runtime(`--options runtime`) +
///   secure timestamp(`--timestamp`) — 공증/배포 전제.
pub const SigningMode = enum { none, adhoc, identity };

/// 공증 자격증명 (xcrun notarytool). app-specific password 또는 keychain
/// profile 둘 중 하나. CI 는 secret env 로 주입.
pub const NotarizeCreds = struct {
    apple_id: ?[]const u8 = null,
    team_id: ?[]const u8 = null,
    /// app-specific password (apple_id 와 함께).
    password: ?[]const u8 = null,
    /// `xcrun notarytool store-credentials` 로 저장한 keychain profile 이름
    /// (apple_id/password 대신 사용 가능, 우선).
    keychain_profile: ?[]const u8 = null,
};

pub const BundleOptions = struct {
    /// 사용자 추가 entitlements plist 경로. 비어있으면 Suji default helper별 entitlements
    /// (assets/entitlements/{main,helper,helper-{gpu,renderer,plugin}}.plist) 자동 부착.
    /// 지정 시 모든 binary에 그 plist 단독 적용.
    user_entitlements: ?[]const u8 = null,
    /// 번들에 포함할 CEF locale (`Resources/<lang>.lproj`). 빈 슬라이스면 default `["en"]`만.
    /// `["*"]` 명시하면 220개 모두 포함 (i18n 앱). 기본 1개만 → ~110MB 절약.
    locales: []const []const u8 = &.{},
    /// CEF framework binary strip — debug symbols 제거로 ~30MB 절약. default true.
    /// 디버깅 필요 시 `false`.
    strip_cef: bool = true,
    /// 서명 모드. 기본 adhoc(기존 동작 유지 — 하위호환).
    signing: SigningMode = .adhoc,
    /// identity 모드의 서명 ID (예: "Developer ID Application: Acme (TEAMID)").
    /// signing == .identity 인데 null 이면 error.MissingSigningIdentity.
    identity: ?[]const u8 = null,
};

pub fn createBundle(
    allocator: std.mem.Allocator,
    name: []const u8,
    version: []const u8,
    identifier: []const u8,
    exe_path: []const u8,
    frontend_dist: []const u8,
    opts: BundleOptions,
) !void {
    const app_name = try std.fmt.allocPrint(allocator, "{s}.app", .{name});
    defer allocator.free(app_name);

    std.debug.print("[suji] creating bundle: {s}\n", .{app_name});

    // 디렉토리 생성
    const dirs = [_][]const u8{
        "Contents",
        "Contents/MacOS",
        "Contents/Frameworks",
        "Contents/Resources",
        "Contents/Resources/frontend",
    };
    for (dirs) |dir| {
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ app_name, dir });
        defer allocator.free(path);
        Dir.cwd().createDirPath(runtime.io, path) catch {};
    }

    // 1. Info.plist 생성
    try writeInfoPlist(allocator, app_name, name, version, identifier);

    // 2. 메인 바이너리 복사
    try copyFile(allocator, exe_path, try std.fmt.allocPrint(allocator, "{s}/Contents/MacOS/{s}", .{ app_name, name }));

    // 3. CEF 프레임워크 복사 (옵션: locale 필터링 + binary strip)
    try copyCefFramework(allocator, app_name, opts);

    // 4. Helper 앱 생성
    const helper_types = [_][]const u8{ "", " (GPU)", " (Renderer)", " (Plugin)" };
    for (helper_types) |suffix| {
        try createHelperApp(allocator, app_name, name, suffix, identifier);
    }

    // 5. GPU 라이브러리를 MacOS/ 옆에 심링크 (libGLESv2 등)
    try symlinkGpuLibs(allocator, app_name);

    // 6. 프론트엔드 dist 복사
    try copyDir(allocator, frontend_dist, try std.fmt.allocPrint(allocator, "{s}/Contents/Resources/frontend", .{app_name}));

    // 7. 메인 바이너리 install_name_tool
    try fixMainBinaryRpath(allocator, app_name, name);

    // 8. 코드서명 (sandbox 모드면 helper별 다른 entitlements)
    try codesignBundle(allocator, app_name, name, opts);

    std.debug.print("[suji] bundle created: {s}\n", .{app_name});
}

fn writeInfoPlist(allocator: std.mem.Allocator, app_name: []const u8, name: []const u8, version: []const u8, identifier: []const u8) !void {
    const path = try std.fmt.allocPrint(allocator, "{s}/Contents/Info.plist", .{app_name});
    defer allocator.free(path);

    const plist = try std.fmt.allocPrint(allocator,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\  <key>CFBundleDisplayName</key>
        \\  <string>{s}</string>
        \\  <key>CFBundleExecutable</key>
        \\  <string>{s}</string>
        \\  <key>CFBundleIdentifier</key>
        \\  <string>{s}</string>
        \\  <key>CFBundleVersion</key>
        \\  <string>{s}</string>
        \\  <key>CFBundleShortVersionString</key>
        \\  <string>{s}</string>
        \\  <key>CFBundlePackageType</key>
        \\  <string>APPL</string>
        \\  <key>CFBundleInfoDictionaryVersion</key>
        \\  <string>6.0</string>
        \\  <key>NSHighResolutionCapable</key>
        \\  <true/>
        \\  <key>NSSupportsAutomaticGraphicsSwitching</key>
        \\  <true/>
        \\</dict>
        \\</plist>
    , .{ name, name, identifier, version, version });
    defer allocator.free(plist);

    {
        const io = runtime.io;
        var file = try Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        var buf: [4096]u8 = undefined;
        var fw = file.writer(io, &buf);
        try fw.interface.writeAll(plist);
        try fw.interface.flush();
    }
}

fn copyCefFramework(allocator: std.mem.Allocator, app_name: []const u8, opts: BundleOptions) !void {
    const home = runtime.env("HOME") orelse "/tmp";
    const src = try std.fmt.allocPrint(allocator, "{s}/.suji/cef/macos-arm64/Release/Chromium Embedded Framework.framework", .{home});
    defer allocator.free(src);
    const dst = try std.fmt.allocPrint(allocator, "{s}/Contents/Frameworks/Chromium Embedded Framework.framework", .{app_name});
    defer allocator.free(dst);

    std.debug.print("[suji] copying CEF framework...\n", .{});
    // APFS clone (-c)으로 instant copy, fallback regular cp.
    runCmd(allocator, &.{ "cp", "-Rc", src, dst }) catch {
        try runCmd(allocator, &.{ "cp", "-R", src, dst });
    };

    try pruneCefLocales(allocator, dst, opts.locales);
    if (opts.strip_cef) try stripCefBinary(allocator, dst);
}

/// 220개 .lproj 중 `keep` 명시한 것만 남기고 나머지 삭제. `keep`이 비어있으면 ["en"]만.
/// `["*"]` 포함 시 전부 보존 (i18n 앱). 평균 500KB × ~219 → ~110MB 절약.
fn pruneCefLocales(allocator: std.mem.Allocator, framework_dst: []const u8, keep: []const []const u8) !void {
    // wildcard 검사 — 전체 보존이면 prune 자체 skip.
    for (keep) |lang| if (std.mem.eql(u8, lang, "*")) return;

    const resources = try std.fmt.allocPrint(allocator, "{s}/Resources", .{framework_dst});
    defer allocator.free(resources);

    var dir = std.Io.Dir.cwd().openDir(runtime.io, resources, .{ .iterate = true }) catch return;
    defer dir.close(runtime.io);

    var iter = dir.iterate();
    var pruned: usize = 0;
    while (iter.next(runtime.io) catch null) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".lproj")) continue;
        const lang = entry.name[0 .. entry.name.len - ".lproj".len];
        if (isLangKept(lang, keep)) continue;
        const path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ resources, entry.name }) catch continue;
        defer allocator.free(path);
        runCmd(allocator, &.{ "rm", "-rf", path }) catch continue;
        pruned += 1;
    }
    std.debug.print("[suji] pruned {d} CEF locales (kept: {s})\n", .{ pruned, if (keep.len == 0) "en" else "user-specified" });
}

fn isLangKept(lang: []const u8, keep: []const []const u8) bool {
    if (keep.len == 0) return std.mem.eql(u8, lang, "en");
    for (keep) |k| {
        if (std.mem.eql(u8, k, lang)) return true;
        // "en"이 명시됐으면 "en_GB" 등 variant도 보존 (단순 prefix match).
        if (std.mem.startsWith(u8, lang, k) and lang.len > k.len and lang[k.len] == '_') return true;
    }
    return false;
}

/// CEF framework binary `strip -S` (local + debug symbols 제거) — 약 30MB 절약.
/// 결과 binary는 정상 실행 가능, lldb stack trace만 제한.
fn stripCefBinary(allocator: std.mem.Allocator, framework_dst: []const u8) !void {
    const cef_bin = try std.fmt.allocPrint(allocator, "{s}/Chromium Embedded Framework", .{framework_dst});
    defer allocator.free(cef_bin);
    runCmd(allocator, &.{ "strip", "-S", "-x", cef_bin }) catch |err| {
        std.debug.print("[suji] strip CEF binary skipped: {}\n", .{err});
    };
}

fn createHelperApp(allocator: std.mem.Allocator, app_name: []const u8, name: []const u8, suffix: []const u8, identifier: []const u8) !void {
    const helper_name = try std.fmt.allocPrint(allocator, "{s} Helper{s}", .{ name, suffix });
    defer allocator.free(helper_name);
    const helper_app = try std.fmt.allocPrint(allocator, "{s}/Contents/Frameworks/{s}.app", .{ app_name, helper_name });
    defer allocator.free(helper_app);
    const helper_macos = try std.fmt.allocPrint(allocator, "{s}/Contents/MacOS", .{helper_app});
    defer allocator.free(helper_macos);

    Dir.cwd().createDirPath(runtime.io, helper_macos) catch {};

    // Helper 바이너리 = 메인 바이너리 hardlink (codesign은 hardlink OK, symlink 거부)
    const helper_exe = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ helper_macos, helper_name });
    defer allocator.free(helper_exe);
    const main_src = try std.fmt.allocPrint(allocator, "{s}/Contents/MacOS/{s}", .{ app_name, name });
    defer allocator.free(main_src);
    runCmd(allocator, &.{ "ln", main_src, helper_exe }) catch {
        try runCmd(allocator, &.{ "cp", main_src, helper_exe });
    };
    try runCmd(allocator, &.{ "chmod", "+x", helper_exe });

    // Helper Info.plist
    const helper_id = try std.fmt.allocPrint(allocator, "{s}.helper{s}", .{ identifier, suffix });
    defer allocator.free(helper_id);
    const plist_path = try std.fmt.allocPrint(allocator, "{s}/Contents/Info.plist", .{helper_app});
    defer allocator.free(plist_path);

    const plist = try std.fmt.allocPrint(allocator,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\  <key>CFBundleExecutable</key>
        \\  <string>{s}</string>
        \\  <key>CFBundleIdentifier</key>
        \\  <string>{s}</string>
        \\  <key>CFBundlePackageType</key>
        \\  <string>APPL</string>
        \\</dict>
        \\</plist>
    , .{ helper_name, helper_id });
    defer allocator.free(plist);

    {
        const io = runtime.io;
        var file = try Dir.cwd().createFile(io, plist_path, .{});
        defer file.close(io);
        var buf: [4096]u8 = undefined;
        var fw = file.writer(io, &buf);
        try fw.interface.writeAll(plist);
        try fw.interface.flush();
    }
}

fn symlinkGpuLibs(allocator: std.mem.Allocator, app_name: []const u8) !void {
    // CEF가 실행 파일 옆에서 GPU 라이브러리를 찾음
    const libs = [_][]const u8{ "libEGL.dylib", "libGLESv2.dylib", "libvk_swiftshader.dylib", "vk_swiftshader_icd.json" };
    for (libs) |lib| {
        const target = try std.fmt.allocPrintSentinel(allocator, "../Frameworks/Chromium Embedded Framework.framework/Libraries/{s}", .{lib}, 0);
        defer allocator.free(target);
        const link = try std.fmt.allocPrintSentinel(allocator, "{s}/Contents/MacOS/{s}", .{ app_name, lib }, 0);
        defer allocator.free(link);
        const rc = std.c.symlink(target.ptr, link.ptr);
        if (rc != 0) {
            const errno = std.posix.errno(rc);
            if (errno == .EXIST) continue;
            return error.SymlinkFailed;
        }
    }
}

fn fixMainBinaryRpath(allocator: std.mem.Allocator, app_name: []const u8, name: []const u8) !void {
    const exe = try std.fmt.allocPrint(allocator, "{s}/Contents/MacOS/{s}", .{ app_name, name });
    defer allocator.free(exe);

    const home = runtime.env("HOME") orelse "/tmp";
    const old_path = try std.fmt.allocPrint(allocator, "{s}/.suji/cef/macos-arm64/Release/Chromium Embedded Framework.framework/Chromium Embedded Framework", .{home});
    defer allocator.free(old_path);

    runCmd(allocator, &.{
        "install_name_tool", "-change",
        old_path,
        "@executable_path/../Frameworks/Chromium Embedded Framework.framework/Chromium Embedded Framework",
        exe,
    }) catch |err| {
        std.debug.print("[suji] install_name_tool warning: {}\n", .{err});
    };
}

fn codesignBundle(allocator: std.mem.Allocator, app_name: []const u8, name: []const u8, opts: BundleOptions) !void {
    if (opts.signing == .none) {
        std.debug.print("[suji] code signing skipped (--sign=none)\n", .{});
        return;
    }
    if (opts.signing == .identity and opts.identity == null) return error.MissingSigningIdentity;
    std.debug.print("[suji] code signing ({s})...\n", .{@tagName(opts.signing)});

    // entitlements 디렉토리는 5번 codesign 호출에서 같으니 한 번만 resolve.
    var exe_buf: [1024]u8 = undefined;
    const entitlements_dir: ?[]const u8 = blk: {
        const exe_len = std.process.executablePath(runtime.io, &exe_buf) catch break :blk null;
        const exe_path = exe_buf[0..exe_len];
        const exe_dir = std.fs.path.dirname(std.fs.path.dirname(std.fs.path.dirname(exe_path) orelse "") orelse "") orelse "";
        break :blk exe_dir;
    };

    // 1. CEF 프레임워크 — entitlements 없이 (receiver process가 inherit).
    const fw = try std.fmt.allocPrint(allocator, "{s}/Contents/Frameworks/Chromium Embedded Framework.framework", .{app_name});
    defer allocator.free(fw);
    try codesignNoEntitlements(allocator, fw, opts);

    // 2. Helper 앱들 — helper별 적절 entitlements.
    const helpers = [_]struct { suffix: []const u8, plist: []const u8 }{
        .{ .suffix = "", .plist = "helper.plist" },
        .{ .suffix = " (GPU)", .plist = "helper-gpu.plist" },
        .{ .suffix = " (Renderer)", .plist = "helper-renderer.plist" },
        .{ .suffix = " (Plugin)", .plist = "helper-plugin.plist" },
    };
    for (helpers) |h| {
        const helper = try std.fmt.allocPrint(allocator, "{s}/Contents/Frameworks/{s} Helper{s}.app", .{ app_name, name, h.suffix });
        defer allocator.free(helper);
        try codesignWithEntitlements(allocator, helper, h.plist, opts, entitlements_dir);
    }

    // 3. 메인 바이너리 + 4. 전체 앱 번들 — 둘 다 main.plist.
    const exe = try std.fmt.allocPrint(allocator, "{s}/Contents/MacOS/{s}", .{ app_name, name });
    defer allocator.free(exe);
    try codesignWithEntitlements(allocator, exe, "main.plist", opts, entitlements_dir);
    try codesignWithEntitlements(allocator, app_name, "main.plist", opts, entitlements_dir);
}

/// 서명 ID — adhoc="-", identity=opts.identity (none 은 호출 전 차단됨).
fn signId(opts: BundleOptions) []const u8 {
    return if (opts.signing == .identity) opts.identity.? else "-";
}

/// codesign argv 조립 후 실행. identity 모드면 hardened runtime + secure
/// timestamp 부착(공증 전제). entitlements null 이면 미부착.
fn runCodesign(allocator: std.mem.Allocator, path: []const u8, entitlements: ?[]const u8, opts: BundleOptions) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ "codesign", "--force", "--sign", signId(opts) });
    if (opts.signing == .identity) try argv.appendSlice(allocator, &.{ "--options", "runtime", "--timestamp" });
    if (entitlements) |e| try argv.appendSlice(allocator, &.{ "--entitlements", e });
    try argv.append(allocator, path);
    try runCmd(allocator, argv.items);
}

fn codesignNoEntitlements(allocator: std.mem.Allocator, path: []const u8, opts: BundleOptions) !void {
    try runCodesign(allocator, path, null, opts);
}

/// user_entitlements 지정 시 그것 모든 binary에 단독, 없으면 entitlements_dir/<plist>.
/// entitlements_dir이 null (executablePath 실패) 시 entitlements 없이 sign.
/// identity 모드는 fallback(entitlements 없이) 시에도 hardened runtime 유지.
fn codesignWithEntitlements(
    allocator: std.mem.Allocator,
    path: []const u8,
    plist_filename: []const u8,
    opts: BundleOptions,
    entitlements_dir: ?[]const u8,
) !void {
    if (opts.user_entitlements) |user_path| {
        runCodesign(allocator, path, user_path, opts) catch {
            try codesignNoEntitlements(allocator, path, opts);
        };
        return;
    }
    const dir = entitlements_dir orelse {
        try codesignNoEntitlements(allocator, path, opts);
        return;
    };
    const entitlements = try std.fmt.allocPrint(allocator, "{s}/assets/entitlements/{s}", .{ dir, plist_filename });
    defer allocator.free(entitlements);

    runCodesign(allocator, path, entitlements, opts) catch {
        try codesignNoEntitlements(allocator, path, opts);
    };
}

fn copyFile(allocator: std.mem.Allocator, src: []const u8, dst: []const u8) !void {
    defer allocator.free(dst);
    try runCmd(allocator, &.{ "cp", src, dst });
    try runCmd(allocator, &.{ "chmod", "+x", dst });
}

fn copyDir(allocator: std.mem.Allocator, src: []const u8, dst: []const u8) !void {
    defer allocator.free(dst);
    runCmd(allocator, &.{ "cp", "-R", src, dst }) catch |err| {
        std.debug.print("[suji] copy dir warning: {}\n", .{err});
    };
}

fn runCmd(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    _ = allocator;
    try proc.run(argv);
}

/// Apple 공증 — `<name>.app` 을 zip 후 notarytool 제출(--wait, 동기 차단)
/// 하고 성공 시 ticket 을 stapler 로 부착(오프라인 Gatekeeper 통과).
/// identity 서명(hardened runtime) 된 번들이어야 통과 — 호출자 책임.
/// creds: keychain_profile 우선, 없으면 apple_id+team_id+password 필수.
pub fn notarizeBundle(allocator: std.mem.Allocator, name: []const u8, creds: NotarizeCreds) !void {
    const app = try std.fmt.allocPrint(allocator, "{s}.app", .{name});
    defer allocator.free(app);
    const zip = try std.fmt.allocPrint(allocator, "{s}.notarize.zip", .{name});
    defer allocator.free(zip);

    std.debug.print("[suji] notarize: zipping {s}...\n", .{app});
    try runCmd(allocator, &.{ "ditto", "-c", "-k", "--keepParent", app, zip });

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ "xcrun", "notarytool", "submit", zip, "--wait" });
    if (creds.keychain_profile) |p| {
        try argv.appendSlice(allocator, &.{ "--keychain-profile", p });
    } else {
        const id = creds.apple_id orelse return error.MissingNotarizeCredentials;
        const team = creds.team_id orelse return error.MissingNotarizeCredentials;
        const pw = creds.password orelse return error.MissingNotarizeCredentials;
        try argv.appendSlice(allocator, &.{ "--apple-id", id, "--team-id", team, "--password", pw });
    }
    std.debug.print("[suji] notarize: submitting (this may take minutes)...\n", .{});
    try runCmd(allocator, argv.items);

    std.debug.print("[suji] notarize: stapling ticket...\n", .{});
    try runCmd(allocator, &.{ "xcrun", "stapler", "staple", app });
    std.debug.print("[suji] notarized: {s}\n", .{app});
}

/// 배포용 .dmg 생성 (압축 UDZO). 반환 경로는 caller 가 free.
pub fn createDmg(allocator: std.mem.Allocator, name: []const u8, version: []const u8) ![]const u8 {
    const app = try std.fmt.allocPrint(allocator, "{s}.app", .{name});
    defer allocator.free(app);
    const dmg = try std.fmt.allocPrint(allocator, "{s}-{s}.dmg", .{ name, version });
    errdefer allocator.free(dmg);

    std.debug.print("[suji] creating dmg: {s}\n", .{dmg});
    // 기존 산출물 있으면 hdiutil 이 거부 → 선제 제거.
    runCmd(allocator, &.{ "rm", "-f", dmg }) catch {};
    try runCmd(allocator, &.{
        "hdiutil",      "create",
        "-volname",     name,
        "-srcfolder",   app,
        "-ov",          "-format",
        "UDZO",         dmg,
    });
    std.debug.print("[suji] dmg created: {s}\n", .{dmg});
    return dmg;
}
