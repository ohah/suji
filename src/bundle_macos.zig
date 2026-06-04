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
/// 코드 서명 모드 (zero-native `--signing` 패리티) — 단일 출처는
/// core/release_opts.zig. none=생략 / adhoc=`codesign --sign -`(기본,
/// 로컬용) / identity=Developer ID + hardened runtime + timestamp(공증 전제).
pub const SigningMode = @import("core/release_opts.zig").SigningMode;

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
    /// App Sandbox 모드. 기본 false = non-sandbox(Developer ID + Notarization,
    /// Hardened Runtime 만 — `assets/entitlements/*.plist`). true = Mac App
    /// Store(App Sandbox + inherit — `assets/entitlements/sandbox/*.plist`).
    /// `suji build --sandbox` / `SUJI_SANDBOX`.
    sandbox: bool = false,
    /// 딥링크 URL scheme — Info.plist `CFBundleURLTypes` 자동 주입.
    /// 비어있으면 미주입(기존 Info.plist 무변). `config.app.deep_link_schemes`.
    deep_link_schemes: []const []const u8 = &.{},
};

pub fn createBundle(
    allocator: std.mem.Allocator,
    name: []const u8,
    version: []const u8,
    identifier: []const u8,
    exe_path: []const u8,
    frontend_dist: []const u8,
    opts: BundleOptions,
    backends: []const @import("package_desktop.zig").BackendArtifact,
    plugins: []const @import("package_desktop.zig").BackendArtifact,
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
    try writeInfoPlist(allocator, app_name, name, version, identifier, opts.deep_link_schemes);

    // 2. 메인 바이너리 복사 + 최소 macOS 배포 타겟 고정(vtool).
    // Zig 는 네이티브 빌드 시 호스트 OS 버전을 minos(LC_BUILD_VERSION) 로 박아, 빌드 머신보다
    // 낮은 macOS 에서 dyld 가 실행을 거부한다(예: 26.4 빌드 → 26.3 실행 불가). vtool 로 minos 를
    // 12.0(CEF 프레임워크 floor)으로 낮춘다. 헬퍼는 이 바이너리의 hardlink 라(아래 4단계)
    // 자동 반영되고, 서명(8단계)은 그 뒤라 서명도 깨지지 않는다.
    const main_bin = try std.fmt.allocPrint(allocator, "{s}/Contents/MacOS/{s}", .{ app_name, name });
    defer allocator.free(main_bin);
    // copyFile 은 dst 를 내부에서 free 하므로 dupe 를 넘기고, main_bin 은 vtool 용으로 보존.
    try copyFile(allocator, exe_path, try allocator.dupe(u8, main_bin));
    setMinMacosVersion(allocator, main_bin) catch |err| {
        std.debug.print("[suji] warn: vtool min-os 설정 실패({s}) — minos 가 빌드 호스트 버전으로 남는다\n", .{@errorName(err)});
    };

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

    // 6.5. backend/plugin dylib + sentinel — packagedExeDir 의 macOS 분기가
    // Contents/Resources/.suji-packaged 를 probe + 같은 디렉토리에 backends/
    // plugins/ 평탄 배치 기대.
    const resources_path = try std.fmt.allocPrint(allocator, "{s}/Contents/Resources", .{app_name});
    defer allocator.free(resources_path);
    @import("package_desktop.zig").writePackagedSentinel(allocator, resources_path);
    try @import("package_desktop.zig").stageBackendArtifacts(allocator, resources_path, backends, plugins);

    // 7. 메인 + 헬퍼 바이너리 install_name_tool (CEF 절대경로 → 번들 상대경로)
    try fixCefInstallNames(allocator, app_name, name);

    // 8. 코드서명 (sandbox 모드면 helper별 다른 entitlements)
    try codesignBundle(allocator, app_name, name, opts);

    std.debug.print("[suji] bundle created: {s}\n", .{app_name});
}

/// 유효 URL scheme 문자만 (RFC 3986: ALPHA / DIGIT / "+" / "-" / ".").
/// 첫 글자는 ALPHA. 위반/빈 문자열이면 false → 해당 scheme skip(XML 주입·
/// 잘못된 plist 방지). 사용자 config 값을 plist 에 그대로 넣기 전 게이트.
pub fn isValidUrlScheme(s: []const u8) bool {
    if (s.len == 0) return false;
    if (!std.ascii.isAlphabetic(s[0])) return false;
    for (s) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '+' and ch != '-' and ch != '.') return false;
    }
    return true;
}

fn writeInfoPlist(
    allocator: std.mem.Allocator,
    app_name: []const u8,
    name: []const u8,
    version: []const u8,
    identifier: []const u8,
    deep_link_schemes: []const []const u8,
) !void {
    const path = try std.fmt.allocPrint(allocator, "{s}/Contents/Info.plist", .{app_name});
    defer allocator.free(path);
    const plist = try buildInfoPlist(allocator, name, version, identifier, deep_link_schemes);
    defer allocator.free(plist);

    const io = runtime.io;
    var file = try Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var fw = file.writer(io, &buf);
    try fw.interface.writeAll(plist);
    try fw.interface.flush();
}

/// 메인 앱 Info.plist 문자열 생성(파일쓰기 분리 — 순수·단위 검증 가능).
/// caller 가 반환 슬라이스 free. deep_link_schemes 비어있거나 전부 무효면
/// CFBundleURLTypes 미포함(기존 plist 와 바이트 동일 = 무회귀).
pub fn buildInfoPlist(
    allocator: std.mem.Allocator,
    name: []const u8,
    version: []const u8,
    identifier: []const u8,
    deep_link_schemes: []const []const u8,
) ![]u8 {
    // CFBundleURLTypes — scheme 당 dict 1개. 유효 scheme 만(isValidUrlScheme).
    // 빈 블록(스킴 없음/전부 무효)이면 Info.plist 무변(기존 동작).
    var url_types = std.ArrayList(u8).empty;
    defer url_types.deinit(allocator);
    for (deep_link_schemes) |scheme| {
        if (!isValidUrlScheme(scheme)) {
            std.debug.print("[suji] warning: invalid deep-link scheme '{s}' — skipped\n", .{scheme});
            continue;
        }
        // CFBundleURLName = 검증된 scheme 만(isValidUrlScheme 통과 →
        // XML-safe 보장). identifier(=config.app.name)는 미검증이라 새
        // 주입 sink 를 안 만들려고 URLName 에 넣지 않음(라벨이라 무영향).
        try url_types.print(allocator,
            \\
            \\    <dict>
            \\      <key>CFBundleURLName</key>
            \\      <string>{s}</string>
            \\      <key>CFBundleURLSchemes</key>
            \\      <array><string>{s}</string></array>
            \\    </dict>
        , .{ scheme, scheme });
    }
    const url_block: []const u8 = if (url_types.items.len == 0) "" else try std.fmt.allocPrint(
        allocator,
        \\
        \\  <key>CFBundleURLTypes</key>
        \\  <array>{s}
        \\  </array>
    , .{url_types.items});
    defer if (url_block.len > 0) allocator.free(url_block);

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
        \\  <key>LSMinimumSystemVersion</key>
        \\  <string>12.0</string>
        \\  <key>NSHighResolutionCapable</key>
        \\  <true/>
        \\  <key>NSSupportsAutomaticGraphicsSwitching</key>
        \\  <true/>{s}
        \\</dict>
        \\</plist>
    , .{ name, name, identifier, version, version, url_block });
    return plist;
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

fn fixCefInstallNames(allocator: std.mem.Allocator, app_name: []const u8, name: []const u8) !void {
    const home = runtime.env("HOME") orelse "/tmp";
    const old_path = try std.fmt.allocPrint(allocator, "{s}/.suji/cef/macos-arm64/Release/Chromium Embedded Framework.framework/Chromium Embedded Framework", .{home});
    defer allocator.free(old_path);
    const cef = "Chromium Embedded Framework.framework/Chromium Embedded Framework";

    // 메인 바이너리 (Contents/MacOS/<name>) — Frameworks 까지 한 단계.
    {
        const exe = try std.fmt.allocPrint(allocator, "{s}/Contents/MacOS/{s}", .{ app_name, name });
        defer allocator.free(exe);
        runCmd(allocator, &.{ "install_name_tool", "-change", old_path, "@executable_path/../Frameworks/" ++ cef, exe }) catch |err|
            std.debug.print("[suji] install_name_tool(main) warning: {}\n", .{err});
    }

    // Helper 바이너리들 (Frameworks/<name> Helper{suffix}.app/Contents/MacOS/<name> Helper{suffix}) —
    // Frameworks 까지 세 단계 깊어 메인과 다른 상대경로(../../../). createHelperApp 이 메인을 hardlink
    // 하지만 install_name_tool/서명이 hardlink 를 깨면서 메인 수정이 전파되지 않으므로, 각 헬퍼의 CEF
    // 참조를 개별로 고친다 — 안 그러면 빌드 머신 절대경로(~/.suji/cef/...)가 남아 다른 맥에서 CEF
    // 헬퍼가 "Library not loaded" 로 dyld 크래시한다.
    const helper_suffixes = [_][]const u8{ "", " (GPU)", " (Renderer)", " (Plugin)" };
    for (helper_suffixes) |suffix| {
        const helper = try std.fmt.allocPrint(allocator, "{s}/Contents/Frameworks/{s} Helper{s}.app/Contents/MacOS/{s} Helper{s}", .{ app_name, name, suffix, name, suffix });
        defer allocator.free(helper);
        runCmd(allocator, &.{ "install_name_tool", "-change", old_path, "@executable_path/../../../" ++ cef, helper }) catch |err|
            std.debug.print("[suji] install_name_tool(helper) warning: {}\n", .{err});
    }
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

    // 0. CEF 프레임워크 내부 중첩 dylib(Libraries/*.dylib: libEGL/libGLESv2/libcef_sandbox/
    //    libvk_swiftshader) 을 프레임워크 본체보다 먼저 서명한다 — codesign 은 inside-out 이라
    //    바깥(프레임워크)부터 서명하면 안쪽 dylib 은 원래 CEF 서명이 남는다. 이걸 빠뜨리면
    //    로컬 실행/adhoc 은 통과하지만 공증(notarization)이 "valid Developer ID 아님 + secure
    //    timestamp 없음" 으로 reject 한다.
    try codesignDylibsFlat(allocator, app_name, "Contents/Frameworks/Chromium Embedded Framework.framework/Libraries", opts);

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

    // 2.5. backend/plugin dylib — Resources/backends/<name>/<basename> 와
    // Resources/plugins/<name>/<basename> 각각 sign. inherit entitlements
    // 라(receiver process), 명시적 entitlements 없이.  --deep 대신 명시 sign
    // (Apple 권장; --deep 은 deprecated). 디렉토리 부재면 skip.
    try codesignDylibsIn(allocator, app_name, "Contents/Resources/backends", opts);
    try codesignDylibsIn(allocator, app_name, "Contents/Resources/plugins", opts);

    // 3. 메인 바이너리 + 4. 전체 앱 번들 — 둘 다 main.plist.
    const exe = try std.fmt.allocPrint(allocator, "{s}/Contents/MacOS/{s}", .{ app_name, name });
    defer allocator.free(exe);
    try codesignWithEntitlements(allocator, exe, "main.plist", opts, entitlements_dir);
    try codesignWithEntitlements(allocator, app_name, "main.plist", opts, entitlements_dir);
}

/// Iterate over `<app_name>/<sub_path>/*/*` and sign each regular file as a
/// dylib (helper sign, no entitlements). 디렉토리 부재면 silent skip.
fn codesignDylibsIn(allocator: std.mem.Allocator, app_name: []const u8, sub_path: []const u8, opts: BundleOptions) !void {
    const root = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ app_name, sub_path });
    defer allocator.free(root);
    var root_dir = Dir.cwd().openDir(runtime.io, root, .{ .iterate = true }) catch return;
    defer root_dir.close(runtime.io);
    var root_it = root_dir.iterate();
    while (try root_it.next(runtime.io)) |entry| {
        if (entry.kind != .directory) continue;
        const child = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, entry.name });
        defer allocator.free(child);
        var child_dir = Dir.cwd().openDir(runtime.io, child, .{ .iterate = true }) catch continue;
        defer child_dir.close(runtime.io);
        var child_it = child_dir.iterate();
        while (try child_it.next(runtime.io)) |f| {
            if (f.kind != .file) continue;
            const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ child, f.name });
            defer allocator.free(path);
            try codesignNoEntitlements(allocator, path, opts);
        }
    }
}

/// `<app_name>/<sub_path>/*.dylib` 를 각각 서명(non-recursive, dylib 만). CEF 프레임워크의
/// Libraries/ 처럼 한 디렉토리에 평평히 놓인 중첩 dylib 묶음을 inside-out 서명하기 위함.
/// .json 등 비-Mach-O 는 .dylib 필터로 건너뛴다. 디렉토리 부재면 silent skip.
fn codesignDylibsFlat(allocator: std.mem.Allocator, app_name: []const u8, sub_path: []const u8, opts: BundleOptions) !void {
    const root = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ app_name, sub_path });
    defer allocator.free(root);
    var dir = Dir.cwd().openDir(runtime.io, root, .{ .iterate = true }) catch return;
    defer dir.close(runtime.io);
    var it = dir.iterate();
    while (try it.next(runtime.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".dylib")) continue;
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, entry.name });
        defer allocator.free(path);
        try codesignNoEntitlements(allocator, path, opts);
    }
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
    // sandbox=true → Mac App Store 세트(app-sandbox+inherit), 기본 → non-sandbox
    // Hardened Runtime 세트.
    const subdir: []const u8 = if (opts.sandbox) "sandbox/" else "";
    const entitlements = try std.fmt.allocPrint(allocator, "{s}/assets/entitlements/{s}{s}", .{ dir, subdir, plist_filename });
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

/// vtool 로 Mach-O 의 LC_BUILD_VERSION minos 를 12.0 으로 재기록. Zig 네이티브 빌드가 호스트
/// OS 버전을 minos 로 박는 걸 보정 — 빌드 머신보다 낮은 macOS 에서도 실행되게 한다. 반드시
/// 코드서명 전에 호출해야 한다(서명 후면 서명이 무효화된다).
fn setMinMacosVersion(allocator: std.mem.Allocator, path: []const u8) !void {
    try runCmd(allocator, &.{ "xcrun", "vtool", "-set-build-version", "macos", "12.0", "12.0", "-replace", "-output", path, path });
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
/// `xcrun notarytool submit <path> --wait` — creds: keychain_profile 우선,
/// 없으면 apple_id+team_id+password 필수. app(zip)·dmg 양쪽이 공유한다.
fn notarytoolSubmit(allocator: std.mem.Allocator, path: []const u8, creds: NotarizeCreds) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ "xcrun", "notarytool", "submit", path, "--wait" });
    if (creds.keychain_profile) |p| {
        try argv.appendSlice(allocator, &.{ "--keychain-profile", p });
    } else {
        const id = creds.apple_id orelse return error.MissingNotarizeCredentials;
        const team = creds.team_id orelse return error.MissingNotarizeCredentials;
        const pw = creds.password orelse return error.MissingNotarizeCredentials;
        try argv.appendSlice(allocator, &.{ "--apple-id", id, "--team-id", team, "--password", pw });
    }
    std.debug.print("[suji] notarize: submitting {s} (this may take minutes)...\n", .{path});
    try runCmd(allocator, argv.items);
}

pub fn notarizeBundle(allocator: std.mem.Allocator, name: []const u8, creds: NotarizeCreds) !void {
    const app = try std.fmt.allocPrint(allocator, "{s}.app", .{name});
    defer allocator.free(app);
    const zip = try std.fmt.allocPrint(allocator, "{s}.notarize.zip", .{name});
    defer allocator.free(zip);

    std.debug.print("[suji] notarize: zipping {s}...\n", .{app});
    try runCmd(allocator, &.{ "ditto", "-c", "-k", "--keepParent", app, zip });
    try notarytoolSubmit(allocator, zip, creds);

    std.debug.print("[suji] notarize: stapling ticket...\n", .{});
    try runCmd(allocator, &.{ "xcrun", "stapler", "staple", app });
    std.debug.print("[suji] notarized: {s}\n", .{app});
}

/// .dmg 공증 — 배포 컨테이너(dmg) 자체를 Developer ID 로 서명 → notarytool 제출(--wait)
/// → staple. 앱만 공증하고 dmg 를 빠뜨리면 다른 맥에서 dmg 를 열 때 "확인되지 않은 개발자"
/// 경고가 뜬다(앱은 정상이어도 컨테이너가 미공증이라). sign_identity 가 null(adhoc) 이면
/// 서명 생략 — adhoc 은 공증 자체가 불가하므로 호출자가 identity 모드에서만 부른다.
pub fn notarizeDmg(allocator: std.mem.Allocator, dmg: []const u8, sign_identity: ?[]const u8, creds: NotarizeCreds) !void {
    if (sign_identity) |id| {
        std.debug.print("[suji] notarize: signing dmg {s}...\n", .{dmg});
        try runCmd(allocator, &.{ "codesign", "--force", "--sign", id, "--timestamp", dmg });
    }
    try notarytoolSubmit(allocator, dmg, creds);
    std.debug.print("[suji] notarize: stapling dmg ticket...\n", .{});
    try runCmd(allocator, &.{ "xcrun", "stapler", "staple", dmg });
    std.debug.print("[suji] notarized: {s}\n", .{dmg});
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
