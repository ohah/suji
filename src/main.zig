const std = @import("std");
const runtime = @import("runtime");
const suji = @import("root.zig");
// 호스트는 코어를 embed 경계로만 접근 (BackendRegistry/EventBus를 직접 생성하지
// 않음). embed.zig가 loader+events만 감싸 CEF 의존을 컴파일 단계에서 차단한다.
const embed = @import("embed.zig");
const util = @import("util");
const cef = @import("platform/cef.zig");
const badge_count = @import("core/badge_count.zig");
const crash_reporter = @import("core/crash_reporter.zig");
const window_mod = @import("window");
const window_stack_mod = @import("window_stack");
const window_ipc = @import("window_ipc");
const logger = @import("logger");
const auto_updater = @import("auto_updater");

const log = logger.module("main");

const cli_diagnostics = @import("cli/diagnostics.zig");
const cli_usage = @import("cli/usage.zig");
const cli_init = @import("cli/init.zig");
const cli_types_cmd = @import("cli/types_cmd.zig");
const backend_build = @import("core/backend_build.zig");
const packaged_paths = @import("core/packaged_paths.zig");
const plugin_loader = @import("core/plugin_loader.zig");
const backend_lifecycle = @import("core/backend_lifecycle.zig");

const getCurrentPid = cli_diagnostics.getCurrentPid;
const setupLogFile = cli_diagnostics.setupLogFile;
const printUsage = cli_usage.printUsage;
const runInit = cli_init.run;
const runTypes = cli_types_cmd.run;
const buildBackendsFromConfig = backend_build.buildAllFromConfig;
const buildBackendByLang = backend_build.buildByLang;
const getDylibPath = backend_build.dylibPath;
const packagedExeDir = packaged_paths.exeDir;
const packagedBackendDylibPath = packaged_paths.backendDylibPath;
const loadPluginsFromConfig = plugin_loader.loadFromConfig;
const getPluginDirForSpec = plugin_loader.dirForSpec;
const readPluginLang = plugin_loader.readLang;
const embeddedBackendSourceDir = backend_lifecycle.embeddedSourceDir;
const loadBackendsFromConfig = backend_lifecycle.loadFromConfig;
const startNodeBackend = backend_lifecycle.startNode;
const startLuaBackend = backend_lifecycle.startLua;
const standaloneNodeQuit = backend_lifecycle.standaloneNodeQuit;
const runNodeScript = backend_lifecycle.runNodeScript;

// CEF 디버그 모드(SUJI_CEF_DEBUG)에서 렌더러(샌드박스) 서브프로세스 패닉 사유를
// stderr 핸들로 직출력 — buffered stderr 로 유실되는 케이스 대비(이슈 #60 진단).
pub const panic = std.debug.FullPanic(cli_diagnostics.sujiDiagPanic);
const Watcher = @import("platform/watcher.zig").Watcher;
const builtin = @import("builtin");
// bundle_macos 의 모든 참조(createBundle/BundleOptions/notarizeBundle/
// createDmg)가 runBuild 의 `switch (comptime builtin.os.tag) { .macos =>
// {...} }` arm 안에만 있어 비-macOS 에선 미분석 → 스텁 본문 불필요(빈
// struct). #13: 스텁 BundleOptions 중복/드리프트 원천 제거.
const bundle_macos = if (builtin.os.tag == .macos) @import("bundle_macos.zig") else struct {};
const package_desktop = @import("package_desktop.zig");

pub fn main(init: std.process.Init) !void {
    runtime.init(.{
        .io = init.io,
        .gpa = init.gpa,
        .environ_map = init.environ_map,
        .args_vector = init.minimal.args.vector,
    });

    // SUJI_CEF_DEBUG 캐시를 env 가용 직후(단일 스레드)에 1회 채운다 — 이후 CEF
    // 콜백(IO/UI/렌더러 스레드)에서의 cefDebug() 는 전부 읽기만 하므로 비원자
    // 캐시의 동시-쓰기 레이스/torn-read 가 제거된다. 또 패닉이 runtime.init 이후
    // 발생하면 캐시가 올바른 값으로 고정돼 SUJI_CEF_DEBUG 가 무시되지 않는다.
    _ = cef.cefDebug();

    // Windows: CEF 146 이 medium-integrity 사용자 세션에서도 de-elevation 을
    // 시도(`MaybeDeElevateOnStartup`) → de-elevation child 를 spawn 하고 parent
    // 의 cef_initialize 는 0 반환 → CefInitFailed. cmdline 에 `--do-not-de-elevate`
    // 가 있으면 이 로직이 비활성. 사용자가 직접 플래그 붙일 필요 없도록 main
    // 진입 시 자동 self-relaunch. (CI 의 Server 2022 runneradmin 환경에선
    // 발현 안 함 — 정직 한계: 어떤 integrity 조합에서 발현되는지 미상.)
    if (comptime builtin.os.tag == .windows) {
        // CEF 디버그 모드 — main() 진입 프로세스 타입 마커 + CEF 구조체 ABI 레이아웃.
        if (cef.cefDebug()) {
            const cl = std.os.windows.peb().ProcessParameters.CommandLine.slice();
            const is_renderer = util.utf16ContainsAscii(cl, "--type=renderer");
            const is_sub = is_renderer or util.utf16ContainsAscii(cl, "--type=");
            std.debug.print("[cef-debug] main entry: sub={} renderer={}\n", .{ is_sub, is_renderer });
            cef.diagPrintCefAbi();
        }
        // SUJI_NO_RELAUNCH — de-elevation self-relaunch 디버그 우회(렌더러 서브프로세스
        // 경로 격리용). **반드시 CEF 디버그 모드에서만** 동작 — 그렇지 않으면 ambient
        // 환경에 이 변수가 떠 있을 때 프로덕션 앱이 de-elevation 우회를 건너뛰어
        // CefInitFailed(빈 화면)로 조용히 죽을 수 있다(#60 증상 재현). 디버그 게이트로
        // 한정해 ambient-env 풋건을 차단한다.
        const skip_relaunch = cef.cefDebug() and (runtime.env("SUJI_NO_RELAUNCH") != null);
        if (!skip_relaunch) maybeRelaunchWithNoDeElevate();
    }

    // CEF 서브프로세스 처리 (렌더러/GPU 등 — 메인이면 통과)
    cef.executeSubprocess();

    // 서브프로세스(렌더러/GPU/...)는 위에서 cef_execute_process 로 진입해 반환하지
    // 않는다 → 렌더러는 main() 프레임 "위에서" Chromium/V8 을 돌린다. ReleaseSafe/
    // ReleaseFast 는 호스트 로직(logger/config/runDev — 큰 스택 로컬)을 main 으로
    // 적극 인라인해 main() 프레임이 수 MB 로 비대해지고, 그만큼 stack_start(스택
    // base) 아래가 소비된 채 V8 컨텍스트 부트스트랩이 실행된다. V8 은 예산을
    // stack_start 기준 ~1MB 로 측정하므로 base 아래 수 MB 소비 시 곧바로
    // Isolate::StackOverflow → 부트스트랩 중 throw 불가 → ud2 크래시(렌더러 사망,
    // 빈 화면). Debug 는 인라인이 없어 호스트 프레임이 작아 통과. 따라서 호스트
    // 로직을 never_inline 경계로 분리해 서브프로세스가 얕은 main() 프레임 위에서
    // 돌게 한다. (이슈 #60 part 2 — Windows ReleaseSafe/Fast 렌더러 크래시 루트커즈.)
    @call(.never_inline, runHost, .{init}) catch |e| return e;
    // app.relaunch() 가 호출됐으면 cef 메시지 루프 종료(앱 quit) 후 현재 argv 로
    // 새 인스턴스 spawn(detached) — Electron app.relaunch(quit 후 재시작) 동작.
    if (g_should_relaunch) @call(.never_inline, relaunchSelf, .{init});
}

/// app.relaunch() 가 set. cef 메시지 루프 종료(quit) 후 main 이 relaunchSelf 로 재시작.
var g_should_relaunch: bool = false;

/// 현재 실행 파일을 현재 argv 로 재실행(detached) 후 반환 — 부모는 직후 종료.
/// Electron app.relaunch. args/execPath 옵션 미지원(현재 argv 그대로 — 정직 경계).
fn relaunchSelf(init: std.process.Init) void {
    // SUJI_E2E_NO_RELAUNCH — e2e 전용 spawn 우회. e2e 가 graceful 종료(SIGTERM)하면
    // cef 루프가 정상 종료해 이 spawn 이 고아 프로세스를 남기므로, e2e 는 이 env 로 실
    // spawn 을 막고 app_relaunch wire(success)만 검증한다. de-elevation self-relaunch
    // (SUJI_NO_RELAUNCH, cefDebug 게이트)와 분리한 전용 env — ambient SUJI_NO_RELAUNCH
    // 가 프로덕션 relaunch 를 silent no-op 시키는 footgun 회피.
    if (runtime.env("SUJI_E2E_NO_RELAUNCH") != null) return;
    if (builtin.os.tag == .windows) {
        // Windows: args.vector 는 UTF-16 PEB 커맨드라인(u16 원소)이라 POSIX argv 변환
        // 불가. 현재 커맨드라인 그대로 CreateProcessW 로 재실행(detached, wait 안 함).
        // 부모는 직후 main 반환으로 종료, 자식은 정상 startup(de-elevation 포함) 경로.
        const w = std.os.windows;
        const cmdline_w = w.peb().ProcessParameters.CommandLine.slice();
        var new_cmdline: [4096]u16 = undefined;
        if (cmdline_w.len + 1 > new_cmdline.len) return;
        @memcpy(new_cmdline[0..cmdline_w.len], cmdline_w);
        new_cmdline[cmdline_w.len] = 0;
        var startup: w.STARTUPINFOW = std.mem.zeroes(w.STARTUPINFOW);
        startup.cb = @sizeOf(w.STARTUPINFOW);
        var info: w.PROCESS.INFORMATION = undefined;
        const flags: w.CreateProcessFlags = .{ .create_unicode_environment = true };
        const ok = w.kernel32.CreateProcessW(
            null,
            @ptrCast(&new_cmdline),
            null,
            null,
            w.BOOL.FALSE, // detached restart — 핸들 상속 불필요(fresh app instance)
            flags,
            null,
            null,
            &startup,
            &info,
        );
        if (ok.toBool()) {
            w.CloseHandle(info.hThread);
            w.CloseHandle(info.hProcess);
        }
        return;
    }
    // POSIX: init.minimal.args.vector 는 C argv([]const [*:0]const u8) — spawn 은
    // []const []const u8 을 요구하므로 span 으로 변환. 256 상한(앱 인자 통상 소수;
    // 초과 시 truncate). wait 안 함 — 부모는 직후 종료, 자식은 OS reparent(detached).
    var argv_buf: [256][]const u8 = undefined;
    const vec = init.minimal.args.vector;
    const n = @min(vec.len, argv_buf.len);
    for (vec[0..n], 0..) |arg, i| argv_buf[i] = std.mem.span(arg);
    _ = std.process.spawn(init.io, .{ .argv = argv_buf[0..n] }) catch return;
}

fn runHost(init: std.process.Init) !void {
    const allocator = init.gpa;

    // 로거 초기화 — 서브프로세스는 logger.global=null로 두어 stderr만 사용.
    // 메인 프로세스는 `~/.suji/logs/suji-YYYYMMDD-HHMMSS-PID.log` 파일로도 기록.
    var log_file_opt: ?std.Io.File = null;
    const log_level: logger.Level = blk: {
        if (runtime.env("SUJI_LOG_LEVEL")) |v| {
            break :blk logger.Level.parse(v) catch .info;
        }
        break :blk .info;
    };
    var log_file_storage: std.Io.File = undefined;
    const setup_err: ?anyerror = if (setupLogFile(&log_file_storage)) blk: {
        log_file_opt = log_file_storage;
        break :blk null;
    } else |e| e;
    var lg = logger.Logger.init(runtime.io, .{ .level = log_level, .file = log_file_opt });
    logger.global = &lg;
    if (setup_err) |e| {
        log.warn("log file setup failed ({s}); stderr only", .{@errorName(e)});
    }
    defer {
        logger.global = null;
        if (log_file_opt) |f| f.close(runtime.io);
    }

    log.info("suji starting pid={d} log_level={s}", .{ getCurrentPid(), @tagName(log_level) });

    const raw_args = try init.minimal.args.toSlice(init.arena.allocator());

    // `--do-not-de-elevate` 는 maybeRelaunchWithNoDeElevate 가 자기 자신 spawn
    // 시 child cmdline 에 추가하는 internal flag — 사용자 명령으로 해석되면 안 됨.
    // 사전 필터링 후 나머지를 command-line args 로 사용.
    var filtered_buf: [64][:0]const u8 = undefined;
    var filtered_len: usize = 0;
    for (raw_args) |a| {
        if (std.mem.eql(u8, a, "--do-not-de-elevate")) continue;
        if (filtered_len >= filtered_buf.len) break;
        filtered_buf[filtered_len] = a;
        filtered_len += 1;
    }
    const args = filtered_buf[0..filtered_len];

    // second-instance(Electron app:second-instance): 이 프로세스가 secondary 가 될 때
    // primary 로 보낼 argv(JSON 배열)와 primary 가 수신 시 emit 할 콜백 등록. 둘 다
    // 저장만 — 실제 listen/forward 는 requestSingleInstanceLock 가 수행. CLI 전용
    // 명령(init/build/types)에선 사용되지 않음(무해).
    cef.setSecondInstanceHandler(&secondInstanceEmitHandler);
    {
        var argv_buf: [4096]u8 = undefined;
        argv_buf[0] = '[';
        var off: usize = 1;
        for (args) |a| {
            var esc: [512]u8 = undefined;
            const en = util.escapeJsonStrFull(a, &esc) orelse continue;
            const sep: []const u8 = if (off > 1) "," else "";
            // 마지막 1바이트는 닫는 ']' 용으로 예약 → bufPrint 대상에서 제외.
            const chunk = std.fmt.bufPrint(argv_buf[off .. argv_buf.len - 1], "{s}\"{s}\"", .{ sep, esc[0..en] }) catch break;
            off += chunk.len;
        }
        argv_buf[off] = ']'; // 예약분에 항상 들어맞음
        off += 1;
        cef.setLaunchArgv(argv_buf[0..off]);
    }

    // 번들에서 실행 시 자동으로 run (macOS .app / Linux AppImage / Windows packaged exe).
    // Windows packaging 은 `<name>.exe` 옆에 `.suji-packaged` sentinel 을 둔다.
    if (args.len < 2) {
        var exe_buf: [1024]u8 = undefined;
        if (std.process.executablePath(init.io, &exe_buf)) |n| {
            const ep = exe_buf[0..n];
            const is_bundle = switch (comptime @import("builtin").os.tag) {
                .macos => std.mem.indexOf(u8, ep, ".app/Contents/MacOS/") != null,
                .windows => blk: {
                    const exe_dir = std.fs.path.dirname(ep) orelse break :blk false;
                    const probe = std.fmt.allocPrint(
                        init.arena.allocator(),
                        "{s}/.suji-packaged",
                        .{exe_dir},
                    ) catch break :blk false;
                    std.Io.Dir.cwd().access(runtime.io, probe, .{}) catch break :blk false;
                    break :blk true;
                },
                else => false, // Linux: 향후 AppImage 등 감지 추가
            };
            if (is_bundle) {
                try runProd(allocator);
                return;
            }
        } else |_| {}
        printUsage();
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "init")) {
        try runInit(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "dev")) {
        try runDev(allocator);
    } else if (std.mem.eql(u8, command, "build")) {
        try runBuild(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "run")) {
        if (args.len >= 3) {
            try runNodeScript(allocator, args[2]);
        } else {
            try runProd(allocator);
        }
    } else if (std.mem.eql(u8, command, "types")) {
        try runTypes(allocator, args[2..]);
    } else {
        std.debug.print("Unknown command: {s}\n", .{command});
        printUsage();
    }
}

/// Windows local 환경(Win10/11 user session)에서 CEF 146 의 `MaybeDeElevateOnStartup`
/// 가 medium-integrity 사용자 세션을 elevated 라고 잘못 판단해서 de-elevation
/// child 를 spawn → parent 의 cef_initialize 가 0 반환 → CefInitFailed.
///
/// cmdline 에 `--do-not-de-elevate` switch 가 있으면 이 로직이 비활성. 사용자가
/// 매번 플래그를 붙일 필요 없도록 main 진입 시 자동 self-relaunch.
///
/// 호출 조건: Windows + cmdline 에 `--do-not-de-elevate` 와 `--type=` 둘 다 없음
///   - `--type=` 가 있으면 CEF subprocess (renderer/gpu/utility/...) → relaunch X
///   - `--do-not-de-elevate` 가 있으면 이미 우회 적용된 child → relaunch X
/// 처리: CreateProcessW 로 자기자신을 cmdline + ` --do-not-de-elevate` 로 spawn,
///   stdin/stdout/stderr inherit, WaitForSingleObject → exit code 그대로 종료.
///
/// CI (Windows Server 2022 runneradmin) 환경에선 발현 안 함 → 그쪽은 우회 코드
/// 가 no-op (이미 정상 path). 로컬 user 세션에서 발현됨.
// noinline — 8KB `new_cmdline` 로컬을 main() 프레임으로 인라인시키지 않는다.
// main() 프레임은 작게 유지돼야 한다(렌더러 서브프로세스가 그 위에서 V8 을 돌림 —
// #60). executeSubprocess 이전에 호출되는 헬퍼는 큰 로컬을 main 으로 끌어올리면 안 됨.
noinline fn maybeRelaunchWithNoDeElevate() void {
    if (comptime builtin.os.tag != .windows) return;

    const w = std.os.windows;
    const cmdline_w = w.peb().ProcessParameters.CommandLine.slice();

    // utf16 substring search (ASCII-only needle 만 사용 — `--do-not-de-elevate` /
    // `--type=`).
    if (util.utf16ContainsAscii(cmdline_w, "--do-not-de-elevate")) return;
    if (util.utf16ContainsAscii(cmdline_w, "--type=")) return;

    // 새 cmdline: 원본 + ` --do-not-de-elevate\0`. 합쳐서 4KB cmdline 한도 안에 들어감.
    const append = std.unicode.utf8ToUtf16LeStringLiteral(" --do-not-de-elevate");
    var new_cmdline: [4096]u16 = undefined;
    const total = cmdline_w.len + append.len;
    if (total + 1 > new_cmdline.len) return; // bail — relaunch 안 함, 원본 동작
    @memcpy(new_cmdline[0..cmdline_w.len], cmdline_w);
    @memcpy(new_cmdline[cmdline_w.len .. cmdline_w.len + append.len], append);
    new_cmdline[total] = 0;

    var startup: w.STARTUPINFOW = std.mem.zeroes(w.STARTUPINFOW);
    startup.cb = @sizeOf(w.STARTUPINFOW);
    var info: w.PROCESS.INFORMATION = undefined;

    const flags: w.CreateProcessFlags = .{ .create_unicode_environment = true };
    const ok = w.kernel32.CreateProcessW(
        null,
        @ptrCast(&new_cmdline),
        null,
        null,
        w.BOOL.TRUE, // bInheritHandles → stdio 상속 (vite/CEF 로그가 부모 stdout 으로)
        flags,
        null,
        null,
        &startup,
        &info,
    );
    if (!ok.toBool()) return; // CreateProcess 실패 시 fallback — 원본 path 그대로 진행

    const k32 = struct {
        extern "kernel32" fn WaitForSingleObject(hHandle: w.HANDLE, dwMilliseconds: w.DWORD) callconv(.winapi) w.DWORD;
        extern "kernel32" fn GetExitCodeProcess(hProcess: w.HANDLE, lpExitCode: *w.DWORD) callconv(.winapi) w.BOOL;
        extern "kernel32" fn ExitProcess(uExitCode: w.DWORD) callconv(.winapi) noreturn;
    };
    const INFINITE: w.DWORD = 0xFFFFFFFF;
    _ = k32.WaitForSingleObject(info.hProcess, INFINITE);
    var exit_code: w.DWORD = 0;
    _ = k32.GetExitCodeProcess(info.hProcess, &exit_code);
    w.CloseHandle(info.hThread);
    w.CloseHandle(info.hProcess);
    // std.process.exit 는 u8 만 받아 DWORD 상위 바이트를 잘라먹음 (예: 자식이
    // NTSTATUS 0xC0000005 access violation 으로 죽으면 0x05 만 보고됨 →
    // 진단 손실). ExitProcess 로 전체 u32 보존.
    k32.ExitProcess(exit_code);
}

const init_mod = @import("core/init.zig");
const proc = @import("core/proc.zig");
const release_opts = @import("core/release_opts.zig");

// ============================================
// suji dev
// ============================================
/// 플래그 우선, 없으면 env 폴백 (CI 는 secret 을 env 로 주입).
/// flagValue/hasFlag 순수 로직은 core/release_opts.zig(테스트 커버).
fn flagOrEnv(args: []const [:0]const u8, flag: []const u8, env_name: []const u8) ?[]const u8 {
    return release_opts.flagValue(args, flag) orelse runtime.env(env_name);
}

fn runBuild(allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
    var config = suji.Config.load(allocator) catch {
        std.debug.print("Error: suji.json not found.\n", .{});
        return;
    };
    defer config.deinit();

    std.debug.print("[suji] production build - {s}\n", .{config.app.name});

    // 서명/공증/패키징 옵션 (zero-native `--signing/--identity` 패리티).
    // 플래그 > env(CI secret) 우선. 기본 adhoc(기존 동작 유지).
    const signing = release_opts.parseSigningMode(flagOrEnv(args, "--sign", "SUJI_SIGN"));
    const identity = flagOrEnv(args, "--identity", "SUJI_SIGN_IDENTITY");
    const want_notarize = release_opts.hasFlag(args, "--notarize") or runtime.env("SUJI_NOTARIZE") != null;
    const want_dmg = release_opts.hasFlag(args, "--dmg") or runtime.env("SUJI_DMG") != null;
    const want_deb = release_opts.hasFlag(args, "--deb") or runtime.env("SUJI_DEB") != null;
    const want_appimage = release_opts.hasFlag(args, "--appimage") or runtime.env("SUJI_APPIMAGE") != null;
    // App Sandbox(MAS) vs non-sandbox(Developer ID, 기본). 기본 false 라
    // 기존 Developer ID/notarize 배포 무회귀.
    const want_sandbox = release_opts.hasFlag(args, "--sandbox") or runtime.env("SUJI_SANDBOX") != null;
    // Strict mode: 1 개 이상 backend/plugin dylib 가 packaging 에서 누락되면
    // process exit code 를 non-zero 로 만든다. 기본은 lenient + WARN (기존 동작
    // 무회귀). CI 가 silent miss 를 검출 못 하던 문제(`/code-review max PR#41`
    // finding #2) 해소용 opt-in.
    const want_strict = release_opts.hasFlag(args, "--strict") or runtime.env("SUJI_STRICT_PACKAGING") != null;

    // 백엔드 릴리스 빌드
    try buildBackendsFromConfig(allocator, &config, true);

    // 프론트엔드 빌드
    std.debug.print("[suji] building frontend...\n", .{});
    buildFrontend(allocator, config.frontend) catch |err| {
        std.debug.print("[suji] frontend build failed: {}\n", .{err});
    };

    // Backend / plugin dylib + embedded-runtime entry path 수집 (OS-agnostic).
    // 각 OS packaging 함수가 BackendArtifact 슬라이스를 받아 stage 에 평탄 복사.
    var backends_list = std.ArrayList(package_desktop.BackendArtifact).empty;
    defer backends_list.deinit(allocator);
    defer for (backends_list.items) |a| {
        if (!a.is_source_dir) allocator.free(@constCast(a.source_path));
    };
    var plugins_list = std.ArrayList(package_desktop.BackendArtifact).empty;
    defer plugins_list.deinit(allocator);
    // is_source_dir filter — 현재 plugins 는 항상 dylib 라 모두 free 대상이지만,
    // 미래 embedded plugin 지원 추가 시 entry path 가 heap 이 아닐 수 있어 가드.
    defer for (plugins_list.items) |a| {
        if (!a.is_source_dir) allocator.free(@constCast(a.source_path));
    };
    var missing_count: usize = 0;

    if (config.isMultiBackend()) {
        if (config.backends) |bes| {
            for (bes) |be| {
                if (std.mem.eql(u8, be.lang, "node") or std.mem.eql(u8, be.lang, "lua") or std.mem.eql(u8, be.lang, "python")) {
                    try backends_list.append(allocator, .{
                        .name = be.name,
                        .lang = be.lang,
                        .source_path = embeddedBackendSourceDir(be.lang, be.entry),
                        .is_source_dir = true,
                    });
                    continue;
                }
                const dylib = getDylibPath(allocator, be.lang, be.entry, true) catch {
                    std.debug.print("[suji] WARN: backend '{s}' lang={s} unsupported — backend will be absent from package\n", .{ be.name, be.lang });
                    missing_count += 1;
                    continue;
                };
                std.Io.Dir.cwd().access(runtime.io, dylib, .{}) catch {
                    std.debug.print("[suji] WARN: backend '{s}' dylib missing at {s} — backend will be absent from package\n", .{ be.name, dylib });
                    allocator.free(dylib);
                    missing_count += 1;
                    continue;
                };
                try backends_list.append(allocator, .{
                    .name = be.name,
                    .lang = be.lang,
                    .source_path = dylib,
                    .is_source_dir = false,
                });
            }
        }
    } else if (config.backend) |be| {
        if (std.mem.eql(u8, be.lang, "node") or std.mem.eql(u8, be.lang, "lua") or std.mem.eql(u8, be.lang, "python")) {
            try backends_list.append(allocator, .{
                .name = be.lang,
                .lang = be.lang,
                .source_path = embeddedBackendSourceDir(be.lang, be.entry),
                .is_source_dir = true,
            });
        } else if (getDylibPath(allocator, be.lang, be.entry, true)) |dylib| {
            std.Io.Dir.cwd().access(runtime.io, dylib, .{}) catch {
                std.debug.print("[suji] WARN: backend '{s}' dylib missing at {s} — backend will be absent from package\n", .{ be.lang, dylib });
                allocator.free(dylib);
                missing_count += 1;
            };
            try backends_list.append(allocator, .{
                .name = be.lang,
                .lang = be.lang,
                .source_path = dylib,
                .is_source_dir = false,
            });
        } else |_| {
            std.debug.print("[suji] WARN: backend lang={s} unsupported — backend will be absent from package\n", .{be.lang});
            missing_count += 1;
        }
    }

    if (config.plugins) |plugin_names| {
        for (plugin_names) |plugin| {
            const pname = plugin.name;
            const pdir = getPluginDirForSpec(allocator, plugin) orelse {
                std.debug.print("[suji] WARN: plugin '{s}' not found — plugin will be absent from package\n", .{pname});
                missing_count += 1;
                continue;
            };
            defer allocator.free(pdir);
            const plang = readPluginLang(allocator, pdir) orelse {
                std.debug.print("[suji] WARN: plugin '{s}' suji-plugin.json invalid — plugin will be absent from package\n", .{pname});
                missing_count += 1;
                continue;
            };
            defer allocator.free(plang);
            const pentry = std.fmt.allocPrint(allocator, "{s}/{s}", .{ pdir, plang }) catch continue;
            defer allocator.free(pentry);
            const dylib = getDylibPath(allocator, plang, pentry, true) catch {
                std.debug.print("[suji] WARN: plugin '{s}' lang={s} unsupported — plugin will be absent from package\n", .{ pname, plang });
                missing_count += 1;
                continue;
            };
            std.Io.Dir.cwd().access(runtime.io, dylib, .{}) catch {
                std.debug.print("[suji] WARN: plugin '{s}' dylib missing at {s} — plugin will be absent from package\n", .{ pname, dylib });
                allocator.free(dylib);
                missing_count += 1;
                continue;
            };
            plugins_list.append(allocator, .{
                .name = pname,
                .lang = plang,
                .source_path = dylib,
                .is_source_dir = false,
            }) catch {
                allocator.free(dylib);
                missing_count += 1;
                continue;
            };
        }
    }

    if (missing_count > 0) {
        std.debug.print("[suji] WARN: packaging incomplete — {d} backend(s)/plugin(s) missing from package\n", .{missing_count});
        if (want_strict) {
            std.debug.print("[suji] strict mode: aborting (set SUJI_STRICT_PACKAGING=0 or omit --strict to package anyway)\n", .{});
            return error.PackagingIncomplete;
        }
    }

    // suji 바이너리 경로
    var exe_buf: [1024]u8 = undefined;
    const exe_len = std.process.executablePath(runtime.io, &exe_buf) catch {
        std.debug.print("[suji] cannot find self executable\n", .{});
        return;
    };
    const exe_path = exe_buf[0..exe_len];

    // OS 별 패키징 (host os 분기 — release.yml 이 네이티브 러너에서 호출).
    // builtin.os.tag 는 comptime → 매칭 arm 만 분석(비-macOS 가 bundle_macos
    // 스텁의 미존재 심볼 참조 회피).
    switch (comptime builtin.os.tag) {
        .macos => {
            const identifier = config.app.name;
            // [:0]const u8 → []const u8 변환 (BundleOptions 는 sentinel 무관).
            const locales_slice: []const []const u8 = blk: {
                if (config.app.locales.len == 0) break :blk &.{};
                var buf = allocator.alloc([]const u8, config.app.locales.len) catch break :blk &.{};
                for (config.app.locales, 0..) |s, i| buf[i] = s;
                break :blk buf;
            };
            const deep_link_slice: []const []const u8 = blk: {
                if (config.app.deep_link_schemes.len == 0) break :blk &.{};
                var buf = allocator.alloc([]const u8, config.app.deep_link_schemes.len) catch break :blk &.{};
                for (config.app.deep_link_schemes, 0..) |s, i| buf[i] = s;
                break :blk buf;
            };
            try bundle_macos.createBundle(
                allocator,
                config.app.name,
                config.app.version,
                identifier,
                exe_path,
                config.frontend.dist_dir,
                bundle_macos.BundleOptions{
                    .user_entitlements = config.app.entitlements,
                    .locales = locales_slice,
                    .strip_cef = config.app.strip_cef,
                    .signing = signing,
                    .identity = identity,
                    .sandbox = want_sandbox,
                    .deep_link_schemes = deep_link_slice,
                    .macos_min_version = config.app.macos_min_version,
                    .icon = config.app.icon,
                },
                backends_list.items,
                plugins_list.items,
            );
            const ncreds = bundle_macos.NotarizeCreds{
                .apple_id = runtime.env("SUJI_NOTARIZE_APPLE_ID"),
                .team_id = runtime.env("SUJI_NOTARIZE_TEAM_ID"),
                .password = runtime.env("SUJI_NOTARIZE_PASSWORD"),
                .keychain_profile = runtime.env("SUJI_NOTARIZE_KEYCHAIN_PROFILE"),
            };
            if (want_notarize) {
                bundle_macos.notarizeBundle(allocator, config.app.name, ncreds) catch |err| {
                    std.debug.print("[suji] notarize failed: {s}\n", .{@errorName(err)});
                    return err;
                };
            }
            if (want_dmg) {
                const dmg = bundle_macos.createDmg(allocator, config.app.name, config.app.version) catch |err| {
                    std.debug.print("[suji] dmg failed: {s}\n", .{@errorName(err)});
                    return err;
                };
                defer allocator.free(dmg);
                // dmg 도 공증·staple — 배포 컨테이너가 미공증이면 다른 맥에서 dmg 열 때
                // Gatekeeper 경고가 뜬다(앱은 정상이어도). createDmg 가 notarize 뒤라 안의
                // 앱은 이미 stapled 상태.
                if (want_notarize) {
                    const sign_id: ?[]const u8 = if (signing == .identity) identity else null;
                    bundle_macos.notarizeDmg(allocator, dmg, sign_id, ncreds) catch |err| {
                        std.debug.print("[suji] dmg notarize failed: {s}\n", .{@errorName(err)});
                        return err;
                    };
                }
            }
        },
        .linux => {
            const archive = try package_desktop.packageLinux(allocator, config.app.name, config.app.version, exe_path, config.frontend.dist_dir, backends_list.items, plugins_list.items);
            allocator.free(archive);
            if (want_deb) {
                const deb = try package_desktop.packageLinuxDeb(allocator, config.app.name, config.app.version, exe_path, config.frontend.dist_dir, backends_list.items, plugins_list.items);
                allocator.free(deb);
            }
            if (want_appimage) {
                const appimage = try package_desktop.packageLinuxAppImage(allocator, config.app.name, config.app.version, exe_path, config.frontend.dist_dir, backends_list.items, plugins_list.items);
                allocator.free(appimage);
            }
        },
        .windows => {
            const archive = try package_desktop.packageWindows(
                allocator,
                config.app.name,
                config.app.version,
                exe_path,
                config.frontend.dist_dir,
                runtime.env("SUJI_WIN_SIGN_CERT"),
                runtime.env("SUJI_WIN_SIGN_PASSWORD"),
                backends_list.items,
                plugins_list.items,
            );
            allocator.free(archive);
        },
        else => std.debug.print("[suji] packaging unsupported on this OS\n", .{}),
    }
    _ = .{ signing, identity, want_notarize, want_dmg, want_deb, want_appimage, want_sandbox, want_strict }; // 비-Windows/macOS arm 미사용 해소
}

// ============================================
// 플러그인 빌드/로드
// ============================================

/// packaged binary 의 backend/plugin dylib root 반환. caller free.
/// OS 별 layout:
/// - Windows/Linux: `<exe_dir>/.suji-packaged` 가 존재 → `<exe_dir>` 반환
/// - macOS: `<exe_dir>/../Resources/.suji-packaged` 가 존재 →
///   `<exe_dir>/../Resources` 반환 (.app 번들 구조 — backends/plugins 가
///   `Contents/Resources/` 아래에 위치)
///
/// 마커: `.suji-packaged` 빈 파일. 각 packaging 함수가 stage 에 생성. 이전엔
/// `resources/frontend/index.html` 만 probe 했는데, 개발자가 zig-out/bin 에
/// stale 파일 남기면 dev 가 packaged 로 false-positive → 백엔드 로드 실패.
/// 전용 sentinel 은 packaging 만 생성하므로 false-positive 봉쇄.
fn runCmd(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    _ = allocator;
    try proc.run(argv);
}

fn runCmdInDir(argv: []const []const u8, cwd_path: []const u8) !void {
    var child = try std.process.spawn(runtime.io, .{
        .argv = argv,
        .cwd = .{ .path = cwd_path },
    });
    switch (try child.wait(runtime.io)) {
        .exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
}

fn runCmdEnv(allocator: std.mem.Allocator, argv: []const []const u8, env_pairs: []const [2][]const u8) !void {
    // 환경 변수 설정 (부모 환경 복제 후 override)
    var env_map = if (runtime.environ_map) |m|
        try m.clone(allocator)
    else
        std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    for (env_pairs) |pair| {
        try env_map.put(pair[0], pair[1]);
    }

    var child = try std.process.spawn(runtime.io, .{
        .argv = argv,
        .environ_map = &env_map,
    });
    const result = try child.wait(runtime.io);
    switch (result) {
        .exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
}

// ============================================
// 프론트엔드
// ============================================

fn startFrontendDev(allocator: std.mem.Allocator, frontend: suji.Config.Frontend) !std.process.Child {
    _ = allocator;
    return try spawnShellInDir(frontend.dev_command, frontend.dir);
}

fn spawnShellInDir(command: []const u8, cwd_path: []const u8) !std.process.Child {
    const argv: []const []const u8 = if (builtin.os.tag == .windows)
        &.{ "cmd", "/C", command }
    else
        &.{ "sh", "-c", command };
    return try std.process.spawn(runtime.io, .{ .argv = argv, .cwd = .{ .path = cwd_path } });
}

fn runShellInDir(command: []const u8, cwd_path: []const u8) !void {
    var child = try spawnShellInDir(command, cwd_path);
    const result = try child.wait(runtime.io);
    switch (result) {
        .exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
}

fn buildFrontend(allocator: std.mem.Allocator, frontend: suji.Config.Frontend) !void {
    _ = allocator;
    try runShellInDir(frontend.build_command, frontend.dir);
}

// ============================================
// CEF 모드
// ============================================

fn runDev(allocator: std.mem.Allocator) !void {
    var config = suji.Config.load(allocator) catch {
        std.debug.print("Error: suji.json not found.\n", .{});
        return;
    };
    defer config.deinit();
    setGlobalConfig(&config);

    var owned_csp: ?[]u8 = null;
    defer if (owned_csp) |csp| allocator.free(csp);

    std.debug.print("[suji] dev mode - {s} v{s}\n", .{ config.app.name, config.app.version });

    try embed.init(allocator, runtime.io);
    defer embed.deinit();
    const registry = embed.registry(); // *BackendRegistry — setGlobal은 embed.init이 수행
    registry.setQuitHandler(&cef.quit); // 백엔드 suji.quit()가 cef.quit()로 이어지도록
    suji.BackendRegistry.special_dispatch = backendSpecialDispatch;
    cef.setTrayEmitHandler(&trayEmitHandler);
    cef.setNotificationEmitHandler(&notificationEmitHandler);
    cef.setMenuEmitHandler(&menuEmitHandler);
    cef.setMenuLifecycleEmitHandler(&menuLifecycleEmitHandler);
    cef.setGlobalShortcutEmitHandler(&globalShortcutEmitHandler);
    cef.powerMonitorInstall(&powerMonitorEmitHandler);
    cef.nativeThemeInstall(&nativeThemeEmitHandler);
    cef.screenInstall(&screenEmitHandler);
    cef.setWebRequestEmitHandler(&webRequestEmitHandler);
    cef.setPermissionEmitHandler(&permissionEmitHandler);
    cef.setDownloadEmitHandler(&downloadEmitHandler);
    cef.setWindowOpenEmitHandler(&windowOpenEmitHandler);
    cef.setBeforeQuitHandler(&beforeQuitHandler);
    cef.setWindowLifecycleHandlers(window_lifecycle_handlers);
    cef.setWindowDisplayHandlers(.{
        .ready_to_show = &windowReadyToShowHandler,
        .title_change = &windowTitleChangeHandler,
        .find_result = &windowFindResultHandler,
    });
    // CSP — 사용자 명시 csp 우선, 미명시 시 default CSP를 iframe_allowed_origins로 빌드.
    if (config.security.csp) |csp_val| {
        cef.setCspValue(csp_val);
    } else blk: {
        const origins_slice = allocator.alloc([]const u8, config.security.iframe_allowed_origins.len) catch break :blk;
        defer allocator.free(origins_slice);
        for (config.security.iframe_allowed_origins, 0..) |s, i| origins_slice[i] = s;
        const csp = cef.buildDefaultCsp(allocator, origins_slice) catch break :blk;
        owned_csp = csp;
        cef.setCspValue(csp);
    }

    // setEventBus는 backend 로드보다 먼저여야 backend_init의 on() 등록이 반영됨 —
    // embed.init이 이 순서를 보장.
    const event_bus = embed.eventBus();

    var url_buf: [2048]u8 = undefined;
    const main_url = try prepareWindowUrl(allocator, &config, .dev, &url_buf);
    try initializeCefProcess(&config);

    try loadPluginsFromConfig(allocator, &config, registry, false);
    try loadBackendsFromConfig(allocator, &config, registry, false);

    // 백엔드 핫 리로드 감시 스레드
    var watcher = Watcher.init(allocator, runtime.io);
    defer watcher.deinit();
    startBackendWatcher(allocator, &config, &watcher, registry);

    // 프론트엔드 dev 서버
    std.debug.print("[suji] starting frontend dev server...\n", .{});
    var frontend_proc = startFrontendDev(allocator, config.frontend) catch |err| {
        std.debug.print("[suji] frontend dev server failed: {}, opening without frontend\n", .{err});
        try openWindow(allocator, &config, event_bus, .dev, main_url);
        return;
    };
    defer frontend_proc.kill(runtime.io);

    std.debug.print("[suji] waiting for {s}...\n", .{config.frontend.dev_url});
    runtime.io.sleep(.fromSeconds(2), .awake) catch {};

    try openWindow(allocator, &config, event_bus, .dev, main_url);
}

// ============================================
// 백엔드 핫 리로드
// ============================================

/// 핫 리로드 콜백 컨텍스트
const HotReloadCtx = struct {
    var alloc: std.mem.Allocator = undefined;
    var conf: *const suji.Config = undefined;
    var reg: *suji.BackendRegistry = undefined;

    fn onFileChanged(path: []const u8) void {
        // rebuild가 스스로 수정하는 파일은 무시 — 안 그러면 feedback loop.
        // 예: Node는 `npm install`이 package-lock.json을 갱신 → watcher 재발화 → 무한 rebuild.
        if (shouldIgnore(path)) return;

        std.debug.print("[suji] file changed: {s}\n", .{path});
        // 변경된 파일이 어느 백엔드에 속하는지 찾기
        const backends = conf.backends orelse return;
        for (backends) |backend| {
            if (std.mem.indexOf(u8, path, backend.entry) != null) {
                reloadBackend(alloc, backend, reg);
                return;
            }
        }
        // 단일 백엔드
        if (conf.backend) |be| {
            if (std.mem.indexOf(u8, path, be.entry) != null) {
                reloadSingleBackend(alloc, be, reg);
            }
        }
    }

    fn shouldIgnore(path: []const u8) bool {
        const basename = std.fs.path.basename(path);
        const ignored_names = [_][]const u8{
            // Node/npm lock files — npm install이 스스로 갱신해서 feedback loop
            "package-lock.json",
            "yarn.lock",
            "pnpm-lock.yaml",
            // OS metadata
            ".DS_Store",
            "Thumbs.db",
        };
        for (ignored_names) |name| {
            if (std.mem.eql(u8, basename, name)) return true;
        }
        // 빌드 산출물 — rebuild가 생성하므로 watcher가 fire하면 feedback loop.
        // Go: cgo -buildmode=c-shared → libbackend.h (자동 생성) + libbackend.dylib
        // Rust/Zig도 dylib 경로 동일.
        const ignored_prefixes = [_][]const u8{ "libbackend.", "_cgo_" };
        for (ignored_prefixes) |p| {
            if (std.mem.startsWith(u8, basename, p)) return true;
        }
        return false;
    }
};

fn reloadBackend(allocator: std.mem.Allocator, backend: suji.Config.MultiBackend, registry: *suji.BackendRegistry) void {
    reloadBackendCommon(allocator, backend.name, backend.lang, backend.entry, registry);
}

fn reloadSingleBackend(allocator: std.mem.Allocator, backend: suji.Config.SingleBackend, registry: *suji.BackendRegistry) void {
    reloadBackendCommon(allocator, "default", backend.lang, backend.entry, registry);
}

fn reloadBackendCommon(allocator: std.mem.Allocator, name: []const u8, lang: [:0]const u8, entry: [:0]const u8, registry: *suji.BackendRegistry) void {
    std.debug.print("[suji] rebuilding {s}...\n", .{name});

    buildBackendByLang(allocator, lang, entry, false) catch |err| {
        std.debug.print("[suji] rebuild failed: {}\n", .{err});
        return;
    };

    const dylib_path = getDylibPath(allocator, lang, entry, false) catch {
        std.debug.print("[suji] dylib path not found\n", .{});
        return;
    };
    defer allocator.free(dylib_path);

    var path_buf: [1024]u8 = undefined;
    const path_z = util.nullTerminate(dylib_path, &path_buf);

    registry.reload(name, path_z) catch |err| {
        std.debug.print("[suji] reload failed: {}\n", .{err});
        return;
    };

    std.debug.print("[suji] {s} reloaded\n", .{name});
}

fn startBackendWatcher(allocator: std.mem.Allocator, config: *const suji.Config, watcher: *Watcher, registry: *suji.BackendRegistry) void {
    HotReloadCtx.alloc = allocator;
    HotReloadCtx.conf = config;
    HotReloadCtx.reg = registry;

    // 백엔드 소스 디렉토리 감시 등록
    if (config.backends) |backends| {
        for (backends) |backend| {
            watcher.addPath(backend.entry) catch |err| {
                std.debug.print("[suji] watch failed for {s}: {}\n", .{ backend.entry, err });
            };
        }
    } else if (config.backend) |be| {
        watcher.addPath(be.entry) catch |err| {
            std.debug.print("[suji] watch failed: {}\n", .{err});
        };
    }

    if (watcher.paths.items.len > 0) {
        watcher.start(&HotReloadCtx.onFileChanged) catch |err| {
            std.debug.print("[suji] watcher start failed: {}\n", .{err});
        };
        std.debug.print("[suji] watching {d} backend(s) for changes\n", .{watcher.paths.items.len});
    }
}

fn runProd(allocator: std.mem.Allocator) !void {
    var config = suji.Config.load(allocator) catch {
        std.debug.print("Error: suji.json not found.\n", .{});
        return;
    };
    defer config.deinit();
    setGlobalConfig(&config);
    var owned_csp: ?[]u8 = null;
    defer if (owned_csp) |csp| allocator.free(csp);

    std.debug.print("[suji] production mode - {s}\n", .{config.app.name});

    try embed.init(allocator, runtime.io);
    defer embed.deinit();
    const registry = embed.registry(); // *BackendRegistry — setGlobal은 embed.init이 수행
    registry.setQuitHandler(&cef.quit);
    suji.BackendRegistry.special_dispatch = backendSpecialDispatch;
    cef.setTrayEmitHandler(&trayEmitHandler);
    cef.setNotificationEmitHandler(&notificationEmitHandler);
    cef.setMenuEmitHandler(&menuEmitHandler);
    cef.setMenuLifecycleEmitHandler(&menuLifecycleEmitHandler);
    cef.setGlobalShortcutEmitHandler(&globalShortcutEmitHandler);
    cef.powerMonitorInstall(&powerMonitorEmitHandler);
    cef.nativeThemeInstall(&nativeThemeEmitHandler);
    cef.screenInstall(&screenEmitHandler);
    cef.setWebRequestEmitHandler(&webRequestEmitHandler);
    cef.setPermissionEmitHandler(&permissionEmitHandler);
    cef.setDownloadEmitHandler(&downloadEmitHandler);
    cef.setWindowOpenEmitHandler(&windowOpenEmitHandler);
    cef.setBeforeQuitHandler(&beforeQuitHandler);
    cef.setWindowLifecycleHandlers(window_lifecycle_handlers);
    cef.setWindowDisplayHandlers(.{
        .ready_to_show = &windowReadyToShowHandler,
        .title_change = &windowTitleChangeHandler,
        .find_result = &windowFindResultHandler,
    });
    // CSP — 사용자 명시 csp 우선, 미명시 시 default CSP를 iframe_allowed_origins로 빌드.
    if (config.security.csp) |csp_val| {
        cef.setCspValue(csp_val);
    } else blk: {
        const origins_slice = allocator.alloc([]const u8, config.security.iframe_allowed_origins.len) catch break :blk;
        defer allocator.free(origins_slice);
        for (config.security.iframe_allowed_origins, 0..) |s, i| origins_slice[i] = s;
        const csp = cef.buildDefaultCsp(allocator, origins_slice) catch break :blk;
        owned_csp = csp;
        cef.setCspValue(csp);
    }

    // setEventBus는 backend 로드보다 먼저여야 backend_init의 on() 등록이 반영됨 —
    // embed.init이 이 순서를 보장.
    const event_bus = embed.eventBus();

    var url_buf: [2048]u8 = undefined;
    const main_url = try prepareWindowUrl(allocator, &config, .dist, &url_buf);
    try initializeCefProcess(&config);

    try loadPluginsFromConfig(allocator, &config, registry, true);
    try loadBackendsFromConfig(allocator, &config, registry, true);

    try openWindow(allocator, &config, event_bus, .dist, main_url);
}

const WindowMode = enum { dev, dist };

fn prepareWindowUrl(
    allocator: std.mem.Allocator,
    config: *const suji.Config,
    mode: WindowMode,
    url_buf: *[2048]u8,
) !?[:0]const u8 {
    const url: ?[:0]const u8 = switch (mode) {
        .dev => config.frontend.dev_url,
        .dist => blk: {
            const dist_path = findDistPath(allocator, config.frontend.dist_dir) orelse {
                std.debug.print("[suji] frontend dist not found: {s}\n", .{config.frontend.dist_dir});
                break :blk null;
            };
            defer allocator.free(dist_path);

            const url_str = switch (config.windows[0].protocol) {
                .suji => s: {
                    cef.setDistPath(dist_path);
                    break :s std.fmt.bufPrint(url_buf, "suji://app/index.html", .{}) catch break :blk null;
                },
                .file => s: {
                    break :s std.fmt.bufPrint(url_buf, "file://{s}/index.html", .{dist_path}) catch break :blk null;
                },
            };
            url_buf[url_str.len] = 0;
            break :blk url_buf[0..url_str.len :0];
        },
    };

    if (url) |u| {
        std.debug.print("[suji] CEF URL: {s}\n", .{u});
    } else {
        std.debug.print("[suji] CEF URL: (null)\n", .{});
    }
    return url;
}

fn initializeCefProcess(config: *const suji.Config) !void {
    const main_win = config.windows[0];
    writeStartupCrashReporterConfig(allocatorScratch(), config) catch |err| {
        log.warn("crash reporter cfg setup failed: {s}", .{@errorName(err)});
    };
    try cef.initialize(.{
        .title = main_win.title,
        .width = @intCast(main_win.width),
        .height = @intCast(main_win.height),
        .debug = main_win.debug,
        .app_name = config.app.name,
    });
    applyStartupCrashReporterState(config);
}

fn allocatorScratch() std.mem.Allocator {
    return runtime.gpa;
}

fn crashReporterConfigPath(buf: []u8, exe_path: []const u8) ?[]const u8 {
    if (comptime builtin.os.tag == .macos) {
        if (std.mem.indexOf(u8, exe_path, ".app/Contents/MacOS/")) |idx| {
            const app_root = exe_path[0 .. idx + ".app".len];
            return std.fmt.bufPrint(buf, "{s}/Contents/Resources/crash_reporter.cfg", .{app_root}) catch null;
        }
    }
    const dir = std.fs.path.dirname(exe_path) orelse return null;
    const sep: []const u8 = if (builtin.os.tag == .windows) "\\" else "/";
    return std.fmt.bufPrint(buf, "{s}{s}crash_reporter.cfg", .{ dir, sep }) catch null;
}

fn writeTextFileAbsolute(path: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        std.Io.Dir.cwd().createDirPath(runtime.io, dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
    var file = try std.Io.Dir.cwd().createFile(runtime.io, path, .{});
    defer file.close(runtime.io);
    var wbuf: [4096]u8 = undefined;
    var fw = file.writer(runtime.io, &wbuf);
    try fw.interface.writeAll(content);
    try fw.interface.flush();
}

fn writeStartupCrashReporterConfig(allocator: std.mem.Allocator, config: *const suji.Config) !void {
    const cr = config.app.crash_reporter orelse return;
    if (!cr.enabled) return;

    const rendered = try crash_reporter.renderConfig(allocator, cr.toOptions(config.app.name, config.app.version));
    defer allocator.free(rendered);

    var exe_buf: [2048]u8 = undefined;
    const exe_len = try std.process.executablePath(runtime.io, &exe_buf);
    var path_buf: [4096]u8 = undefined;
    const path = crashReporterConfigPath(&path_buf, exe_buf[0..exe_len]) orelse return error.InvalidPath;
    try writeTextFileAbsolute(path, rendered);
    log.info("crash reporter cfg written: {s}", .{path});
}

fn applyStartupCrashReporterState(config: *const suji.Config) void {
    const cr = config.app.crash_reporter orelse return;
    if (!cr.enabled) return;
    g_crash_reporter_started = true;
    g_crash_reporter_upload_to_server = cr.upload_to_server;
    for (cr.extra) |p| _ = crashAddExtraParameter(p.key, p.value);
    for (cr.global_extra) |p| _ = crashAddExtraParameter(p.key, p.value);
}

fn openWindow(
    allocator: std.mem.Allocator,
    config: *const suji.Config,
    event_bus: *suji.EventBus,
    mode: WindowMode,
    url: ?[:0]const u8,
) !void {
    // EventBus → JS 이벤트 전달 (CEF evalJs 사용)
    event_bus.webview_eval = &cef.evalJs;

    // window:all-closed 이벤트는 WindowManager가 발화. 기본은 사용자 backend가 직접
    // `suji.on("window:all-closed", ...)`로 구독하고 platform 분기 후 `suji.quit()` 호출
    // (Electron canonical 패턴). `app.quitOnAllWindowsClosed: true`면 코어가 자동 quit —
    // user code 호출과 동시 발화해도 cef.quit()이 idempotent라 race 없음.
    if (config.app.quit_on_all_windows_closed) {
        _ = event_bus.onC(window_mod.events.all_closed, &allClosedAutoQuit, null);
    }

    // CEF IPC 콜백 연결
    cef.setInvokeHandler(&cefInvokeHandler);
    cef.setEmitHandler(&cefEmitHandler);
    // Deferred response — print_to_pdf/capture_page 가 CDP 콜백 완료까지 응답 보류
    // (issue #16, SDK 가 listener-leak 없는 단순 await 가능).
    window_ipc.g_defer_response_cb = &cef.cefDeferResponse;

    // WindowManager 배선 (CefNative + EventBusSink)
    var cef_native = cef.CefNative.init(allocator);
    cef_native.registerGlobal(); // life_span_handler 콜백이 참조

    var stack: window_stack_mod.WindowStack = undefined;
    stack.init(allocator, runtime.io, cef_native.asNative(), event_bus);
    stack.setGlobal();

    // 첫 창의 default name="main" — 플러그인이 wm.fromName("main")으로 메인 창 식별 가능.
    for (config.windows, 0..) |w, i| {
        const win_name: ?[]const u8 = util.cstrOpt(w.name) orelse (if (i == 0) "main" else null);
        const win_url: ?[]const u8 = util.cstrOpt(w.url) orelse util.cstrOpt(url);
        // 부모 이름이 명시됐으면 wm에서 id 조회 (이미 만들어진 창만 — 따라서 parent는 windows[]
        // 배열 순서상 더 앞에 있어야 함). 없으면 무시.
        const parent_id: ?u32 = if (w.parent) |p_name|
            stack.manager.fromName(util.cstr(p_name))
        else
            null;

        // 음수/오버플로 clamp. config.Window.width/height는 i64로 들어오므로 여기서 변환.
        // x/y는 i32라 음수 허용 (화면 왼쪽 밖 배치 가능).
        const w_px: u32 = util.nonNegU32(w.width);
        const h_px: u32 = util.nonNegU32(w.height);
        _ = stack.manager.create(.{
            .name = win_name,
            .title = util.cstr(w.title),
            .url = win_url,
            .bounds = .{
                .x = @intCast(w.x),
                .y = @intCast(w.y),
                .width = w_px,
                .height = h_px,
            },
            .parent_id = parent_id,
            .appearance = .{
                .frame = w.frame,
                .transparent = w.transparent,
                .background_color = util.cstrOpt(w.background_color),
                .title_bar_style = w.title_bar_style,
            },
            .constraints = .{
                .resizable = w.resizable,
                .always_on_top = w.always_on_top,
                .min_width = w.min_width,
                .min_height = w.min_height,
                .max_width = w.max_width,
                .max_height = w.max_height,
                .fullscreen = w.fullscreen,
            },
        }) catch |err| {
            std.debug.print("[suji] window[{d}] create failed: {s}\n", .{ i, @errorName(err) });
            // 첫 창 실패는 fatal — 빈 앱 상태로 cef.run 진입하면 즉시 quit 돼버림.
            if (i == 0) return err;
        };
    }

    std.debug.print("[suji] CEF window opened ({s}), {d} window(s)\n", .{ if (mode == .dev) "dev" else "production", config.windows.len });
    cef.run();

    // Node runtime 종료 (별도 스레드 join). 이게 빠지면 Cmd+Q로 CEF가 quit한 뒤
    // libnode event loop가 계속 돌아 프로세스가 exit 못하고 hang한다. node::Stop이
    // isolate에 terminate 신호 보내고 run 스레드가 빠져나오면 thread.join이 완료.
    if (backend_lifecycle.g_node_runtime) |rt| {
        rt.shutdown();
        allocator.destroy(rt);
        backend_lifecycle.g_node_runtime = null;
    }
    if (backend_lifecycle.g_lua_runtime) |rt| {
        rt.shutdown();
        allocator.destroy(rt);
        backend_lifecycle.g_lua_runtime = null;
    }
    if (backend_lifecycle.g_python_runtime) |rt| {
        rt.shutdown();
        allocator.destroy(rt);
        backend_lifecycle.g_python_runtime = null;
    }

    // cef.shutdown() 전에 정리: user close → OnBeforeClose → wm.markClosedExternal로
    // 이미 destroyed=true 세팅된 상태. WM.deinit은 살아있는 창에만 native.destroyWindow를
    // 호출하므로 CEF가 이미 파괴한 브라우저에 재접근하는 UAF 없음.
    window_stack_mod.WindowStack.clearGlobal();
    stack.deinit();
    cef.CefNative.unregisterGlobal();
    cef_native.deinit();

    cef.shutdown();
}

/// CEF invoke 콜백 — BackendRegistry로 라우팅
fn cefInvokeHandler(channel: []const u8, data: []const u8, response_buf: []u8) ?[]const u8 {
    const registry = suji.BackendRegistry.global orelse return null;

    // 특수 채널: fanout, chain, core — 동일 dispatcher 테이블이 backend SDK 경로(coreInvoke)와
    // 공유한다. 새 channel 추가 시 SPECIAL_DISPATCHERS만 추가.
    for (SPECIAL_DISPATCHERS) |d| {
        if (std.mem.eql(u8, channel, d.channel)) return d.handler(registry, data, response_buf);
    }

    // 요청 null-terminate
    var request_buf: [8192]u8 = undefined;
    const request_len = @min(data.len, request_buf.len - 1);
    @memcpy(request_buf[0..request_len], data[0..request_len]);
    request_buf[request_len] = 0;
    const request: [*:0]const u8 = request_buf[0..request_len :0];

    // 채널 라우팅으로 백엔드 찾기 (없으면 채널명을 백엔드 이름으로 직접 시도)
    const name = registry.getBackendForChannel(channel) orelse channel;
    if (name.len == 0) return null; // 중복 채널

    // 네이티브 백엔드 (Zig/Rust/Go) 시도
    if (registry.invoke(name, request)) |resp| {
        const len = @min(resp.len, response_buf.len);
        @memcpy(response_buf[0..len], resp[0..len]);
        registry.freeResponse(name, resp);
        return response_buf[0..len];
    }

    // 임베드 런타임 폴백(Node/Lua/Python) — dlopen 백엔드가 아니라 registry.invoke
    // 가 null 이다. invokeEmbed 가 name 정확 매칭 → catch-all(node 등) 순으로
    // 디스패치(data-driven). 새 임베드 런타임은 registerEmbedRuntime 등록만으로
    // 자동 라우팅된다(분기 추가 불요).
    const embed_channel = util.extractJsonString(data, "cmd") orelse channel;
    if (suji.BackendRegistry.invokeEmbed(name, embed_channel, request, response_buf)) |resp| {
        return resp;
    }

    return null;
}

/// fanout: 여러 백엔드에 동시 요청
fn cefHandleFanout(registry: *suji.BackendRegistry, data: []const u8, response_buf: []u8) ?[]const u8 {
    // data: {"__fanout":true,"backends":"zig,rust,go","request":"{\"cmd\":\"ping\"}"}
    // backends와 request 추출
    const backends_str = util.extractJsonString(data, "backends") orelse return null;
    const request_str = util.extractJsonString(data, "request") orelse return null;

    // request에서 이스케이프된 따옴표 복원
    var req_buf: [4096]u8 = undefined;
    const req_clean = unescapeJson(request_str, &req_buf);
    var req_nt: [4096]u8 = undefined;
    const req_len = @min(req_clean.len, req_nt.len - 1);
    @memcpy(req_nt[0..req_len], req_clean[0..req_len]);
    req_nt[req_len] = 0;

    var out_pos: usize = 0;
    const out = response_buf;
    out_pos += (std.fmt.bufPrint(out[out_pos..], "{{\"fanout\":[", .{}) catch return null).len;

    var iter = std.mem.splitScalar(u8, backends_str, ',');
    var first = true;
    while (iter.next()) |name| {
        const resp = registry.invoke(name, req_nt[0..req_len :0]);
        if (resp) |r| {
            if (!first) out_pos += (std.fmt.bufPrint(out[out_pos..], ",", .{}) catch break).len;
            out_pos += (std.fmt.bufPrint(out[out_pos..], "{s}", .{r}) catch break).len;
            first = false;
            registry.freeResponse(name, resp);
        }
    }
    out_pos += (std.fmt.bufPrint(out[out_pos..], "]}}", .{}) catch return null).len;
    return out[0..out_pos];
}

/// chain: Backend A → Core → Backend B
fn cefHandleChain(registry: *suji.BackendRegistry, data: []const u8, response_buf: []u8) ?[]const u8 {
    const from = util.extractJsonString(data, "from") orelse return null;
    const to = util.extractJsonString(data, "to") orelse return null;
    const request_escaped = util.extractJsonString(data, "request") orelse return null;
    var req_buf: [4096]u8 = undefined;
    const req_clean = unescapeJson(request_escaped, &req_buf);
    var req_nt: [4096]u8 = undefined;
    const req_len = @min(req_clean.len, req_nt.len - 1);
    @memcpy(req_nt[0..req_len], req_clean[0..req_len]);
    req_nt[req_len] = 0;

    const resp1 = registry.invoke(from, req_nt[0..req_len :0]) orelse return null;
    var r1_buf: [8192]u8 = undefined;
    const r1_len = @min(resp1.len, r1_buf.len);
    @memcpy(r1_buf[0..r1_len], resp1[0..r1_len]);
    registry.freeResponse(from, resp1);

    const resp2 = registry.invoke(to, req_nt[0..req_len :0]);
    var r2_buf: [8192]u8 = undefined;
    const r2: []const u8 = if (resp2) |r| blk: {
        const l = @min(r.len, r2_buf.len);
        @memcpy(r2_buf[0..l], r[0..l]);
        registry.freeResponse(to, resp2);
        break :blk r2_buf[0..l];
    } else "null";

    const result = std.fmt.bufPrint(response_buf, "{{\"chain\":\"{s}->{s}\",\"step1\":{s},\"step2\":{s}}}", .{ from, to, r1_buf[0..r1_len], r2 }) catch return null;
    return result;
}

/// special channel → handler 매핑. CEF cefInvokeHandler와 backend SDK 경로
/// (BackendRegistry.coreInvoke → backendSpecialDispatch) 두 곳이 공유.
/// 새 special 추가 시 여기 한 줄.
const SpecialDispatcher = struct {
    channel: []const u8,
    handler: *const fn (*suji.BackendRegistry, []const u8, []u8) ?[]const u8,
};
const SPECIAL_DISPATCHERS = [_]SpecialDispatcher{
    .{ .channel = suji.BackendRegistry.CHANNEL_CORE, .handler = cefHandleCore },
    .{ .channel = suji.BackendRegistry.CHANNEL_FANOUT, .handler = cefHandleFanout },
    .{ .channel = suji.BackendRegistry.CHANNEL_CHAIN, .handler = cefHandleChain },
};

/// 백엔드 SDK의 callBackend("__core__"|"__fanout__"|"__chain__", ...) 경로 dispatcher.
/// BackendRegistry.special_dispatch에 inject된다.
fn backendSpecialDispatch(channel: []const u8, data: []const u8, response_buf: []u8) ?[]const u8 {
    const registry = suji.BackendRegistry.global orelse return null;
    // Backend SDK가 호출한 흐름이라 fs sandbox 등 frontend-only 검증을 우회.
    g_in_backend_invoke = true;
    defer g_in_backend_invoke = false;
    for (SPECIAL_DISPATCHERS) |d| {
        if (std.mem.eql(u8, channel, d.channel)) return d.handler(registry, data, response_buf);
    }
    return null;
}

/// core: Zig 코어 직접 호출 — 두 경로:
///   1. CEF (frontend `__suji__.core`): data = `{"__core":true,"request":"<escaped cmd JSON>"}`
///   2. Backend SDK (`callBackend("__core__", req)`): data = `<raw cmd JSON>` (backendSpecialDispatch 경유)
///
/// cmd 분기는 `extractJsonString(req, "cmd")`로 정확 매치 — substring 매치는 새 cmd가
/// 비슷한 이름으로 추가되거나 cmd 외 다른 필드에 같은 문자열이 있을 때 잘못 라우팅 위험.
/// `__core__` IPC payload 한계. clipboard write 등 큰 payload 수용 (이전 4KB는 8KB
/// 클립보드 쓰기에서 잘려 응답 비었음). 두 곳에서 같은 값 사용 (response check + req_buf).
const MAX_CORE_PAYLOAD: usize = 32 * 1024;

/// `{"from":"zig-core","cmd":<cmd>,"success":bool}` 응답 빌드 — write/setter류 cmd 공통.
fn respondSuccess(response_buf: []u8, cmd: []const u8, ok: bool) ?[]const u8 {
    return std.fmt.bufPrint(
        response_buf,
        "{{\"from\":\"zig-core\",\"cmd\":\"{s}\",\"success\":{}}}",
        .{ cmd, ok },
    ) catch null;
}

/// raw bytes를 base64로 인코딩해 `{"from":"zig-core","cmd":<cmd>,"data":"<b64>"}` 응답을 빌드.
/// b64 한도(12KB) 초과 시 빈 data 반환 — clipboard_read_image / native_image_to_png/jpeg 공유.
fn respondBase64Data(response_buf: []u8, cmd: []const u8, raw_bytes: []const u8) ?[]const u8 {
    const enc_size = std.base64.standard.Encoder.calcSize(raw_bytes.len);
    var b64_buf: [12 * 1024]u8 = undefined;
    if (enc_size > b64_buf.len) {
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"{s}\",\"data\":\"\"}}", .{cmd}) catch null;
    }
    const encoded = std.base64.standard.Encoder.encode(b64_buf[0..enc_size], raw_bytes);
    return std.fmt.bufPrint(
        response_buf,
        "{{\"from\":\"zig-core\",\"cmd\":\"{s}\",\"data\":\"{s}\"}}",
        .{ cmd, encoded },
    ) catch null;
}

/// app.setPath 런타임 경로 오버라이드 (Electron app.setPath → 이후 app.getPath 가 우선 반영).
/// 정적 16 슬롯 — config.app.name 기반 표준 경로를 런타임에 덮어쓴다.
const PathOverride = struct {
    name: [64]u8 = undefined,
    name_len: usize = 0,
    path: [1024]u8 = undefined,
    path_len: usize = 0,
};
var g_path_overrides: [16]PathOverride = [_]PathOverride{.{}} ** 16;
var g_path_override_count: usize = 0;

fn pathOverrideGet(name: []const u8) ?[]const u8 {
    for (g_path_overrides[0..g_path_override_count]) |*o| {
        if (std.mem.eql(u8, o.name[0..o.name_len], name)) return o.path[0..o.path_len];
    }
    return null;
}

fn pathOverrideSet(name: []const u8, path: []const u8) bool {
    if (name.len == 0 or name.len > 64 or path.len > 1024) return false;
    for (g_path_overrides[0..g_path_override_count]) |*o| {
        if (std.mem.eql(u8, o.name[0..o.name_len], name)) {
            @memcpy(o.path[0..path.len], path);
            o.path_len = path.len;
            return true;
        }
    }
    if (g_path_override_count >= g_path_overrides.len) return false;
    const o = &g_path_overrides[g_path_override_count];
    @memcpy(o.name[0..name.len], name);
    o.name_len = name.len;
    @memcpy(o.path[0..path.len], path);
    o.path_len = path.len;
    g_path_override_count += 1;
    return true;
}


const MAX_CRASH_PARAMS: usize = 64;
const CrashParam = struct {
    key_buf: [crash_reporter.MAX_KEY_BYTES]u8 = undefined,
    key_len: usize = 0,
    value_buf: [crash_reporter.MAX_VALUE_BYTES]u8 = undefined,
    value_len: usize = 0,

    fn key(self: *const CrashParam) []const u8 {
        return self.key_buf[0..self.key_len];
    }

    fn value(self: *const CrashParam) []const u8 {
        return self.value_buf[0..self.value_len];
    }
};

var g_crash_reporter_started: bool = false;
var g_crash_reporter_upload_to_server: bool = true;
var g_crash_params: [MAX_CRASH_PARAMS]CrashParam = [_]CrashParam{.{}} ** MAX_CRASH_PARAMS;
var g_crash_param_count: usize = 0;
var g_app_badge_count: u32 = 0;
// nativeTheme.themeSource getter 용 — set_source 성공 시 갱신(정적 리터럴만 저장).
// Electron 동등: setter 가 설정한 마지막 값, 미설정 시 "system".
var g_theme_source: []const u8 = "system";

fn crashParamIndex(key: []const u8) ?usize {
    for (g_crash_params[0..g_crash_param_count], 0..) |p, i| {
        if (std.mem.eql(u8, p.key(), key)) return i;
    }
    return null;
}

fn crashAddExtraParameter(key: []const u8, value: []const u8) bool {
    if (!crash_reporter.isValidCrashKey(key)) return false;
    if (!crash_reporter.isValidCrashValue(value)) return false;

    const idx = crashParamIndex(key) orelse blk: {
        if (g_crash_param_count >= g_crash_params.len) return false;
        const next = g_crash_param_count;
        g_crash_param_count += 1;
        break :blk next;
    };

    @memcpy(g_crash_params[idx].key_buf[0..key.len], key);
    g_crash_params[idx].key_len = key.len;
    @memcpy(g_crash_params[idx].value_buf[0..value.len], value);
    g_crash_params[idx].value_len = value.len;

    if (cef.crashReporterEnabled()) _ = cef.crashReporterSetKeyValue(key, value);
    return true;
}

fn crashRemoveExtraParameter(key: []const u8) bool {
    const idx = crashParamIndex(key) orelse return false;
    if (cef.crashReporterEnabled()) _ = cef.crashReporterSetKeyValue(key, "");

    var i = idx;
    while (i + 1 < g_crash_param_count) : (i += 1) {
        g_crash_params[i] = g_crash_params[i + 1];
    }
    g_crash_param_count -= 1;
    g_crash_params[g_crash_param_count] = .{};
    return true;
}

fn extractUnescapedField(req_clean: []const u8, key: []const u8, buf: []u8) ?[]const u8 {
    const raw = util.extractJsonString(req_clean, key) orelse return null;
    const n = util.unescapeJsonStr(raw, buf) orelse return null;
    return buf[0..n];
}

fn crashApplyExtraObject(req_clean: []const u8) void {
    var parse_buf: [util.MAX_REQUEST]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&parse_buf);
    const parsed = std.json.parseFromSlice(std.json.Value, fba.allocator(), req_clean, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const extra_val = parsed.value.object.get("extra") orelse return;
    if (extra_val != .object) return;
    var it = extra_val.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .string) continue;
        _ = crashAddExtraParameter(entry.key_ptr.*, entry.value_ptr.string);
    }
}

fn crashParametersResponse(response_buf: []u8) ?[]const u8 {
    var w: usize = 0;
    const head = std.fmt.bufPrint(response_buf[w..], "{{\"from\":\"zig-core\",\"cmd\":\"crash_reporter_get_parameters\",\"parameters\":{{", .{}) catch return null;
    w += head.len;
    for (g_crash_params[0..g_crash_param_count], 0..) |p, i| {
        var key_buf: [128]u8 = undefined;
        var val_buf: [2048]u8 = undefined;
        const key_n = util.escapeJsonStrFull(p.key(), &key_buf) orelse return null;
        const val_n = util.escapeJsonStrFull(p.value(), &val_buf) orelse return null;
        const sep: []const u8 = if (i == 0) "" else ",";
        const part = std.fmt.bufPrint(
            response_buf[w..],
            "{s}\"{s}\":\"{s}\"",
            .{ sep, key_buf[0..key_n], val_buf[0..val_n] },
        ) catch return null;
        w += part.len;
    }
    const tail = std.fmt.bufPrint(response_buf[w..], "}}}}", .{}) catch return null;
    w += tail.len;
    return response_buf[0..w];
}

fn currentCrashpadDirPath(buf: []u8) ?[]const u8 {
    const cfg = g_config orelse return null;
    const app_name = cfg.app.name;
    const sep: []const u8 = if (builtin.os.tag == .windows) "\\" else "/";

    if (comptime builtin.os.tag == .windows) {
        var fallback_buf: [2048]u8 = undefined;
        const base = runtime.env("LOCALAPPDATA") orelse blk: {
            const home = runtime.env("USERPROFILE") orelse return null;
            break :blk std.fmt.bufPrint(&fallback_buf, "{s}\\AppData\\Local", .{home}) catch return null;
        };
        // CEF crash_util.h: Windows uses AppName under LocalAppData, not root_cache_path.
        return std.fmt.bufPrint(buf, "{s}\\{s}\\User Data\\Crashpad", .{ base, app_name }) catch null;
    }

    var user_data_buf: [2048]u8 = undefined;
    const user_data = cef.appGetPath(&user_data_buf, "userData", app_name) orelse return null;
    return std.fmt.bufPrint(buf, "{s}{s}Crashpad", .{ user_data, sep }) catch null;
}

fn collectCurrentCrashReports(include_pending: bool, out: []crash_reporter.CrashReport) usize {
    var path_buf: [4096]u8 = undefined;
    const path = currentCrashpadDirPath(&path_buf) orelse return 0;
    var dir = std.Io.Dir.cwd().openDir(runtime.io, path, .{ .iterate = true }) catch return 0;
    defer dir.close(runtime.io);
    return crash_reporter.collectReports(&dir, runtime.io, include_pending, out);
}

fn appendCrashReportJson(response_buf: []u8, w: *usize, report: *const crash_reporter.CrashReport) bool {
    const part = std.fmt.bufPrint(
        response_buf[w.*..],
        "{{\"date\":\"{s}\",\"id\":\"{s}\"}}",
        .{ report.date(), report.id() },
    ) catch return false;
    w.* += part.len;
    return true;
}

fn crashUploadedReportsResponse(response_buf: []u8) ?[]const u8 {
    var reports: [crash_reporter.MAX_REPORTS]crash_reporter.CrashReport = undefined;
    const count = collectCurrentCrashReports(false, &reports);

    var w: usize = 0;
    const head = std.fmt.bufPrint(response_buf[w..], "{{\"from\":\"zig-core\",\"cmd\":\"crash_reporter_get_uploaded_reports\",\"reports\":[", .{}) catch return null;
    w += head.len;
    for (reports[0..count], 0..) |*report, i| {
        if (i != 0) {
            response_buf[w] = ',';
            w += 1;
        }
        if (!appendCrashReportJson(response_buf, &w, report)) return null;
    }
    const tail = std.fmt.bufPrint(response_buf[w..], "]}}", .{}) catch return null;
    w += tail.len;
    return response_buf[0..w];
}

fn crashLastReportResponse(response_buf: []u8) ?[]const u8 {
    var reports: [crash_reporter.MAX_REPORTS]crash_reporter.CrashReport = undefined;
    const count = collectCurrentCrashReports(true, &reports);
    if (count == 0) {
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"crash_reporter_get_last_crash_report\",\"report\":null}}",
            .{},
        ) catch null;
    }

    var w: usize = 0;
    const head = std.fmt.bufPrint(response_buf[w..], "{{\"from\":\"zig-core\",\"cmd\":\"crash_reporter_get_last_crash_report\",\"report\":", .{}) catch return null;
    w += head.len;
    if (!appendCrashReportJson(response_buf, &w, &reports[0])) return null;
    const tail = std.fmt.bufPrint(response_buf[w..], "}}", .{}) catch return null;
    w += tail.len;
    return response_buf[0..w];
}

fn cefHandleCore(registry: *suji.BackendRegistry, data: []const u8, response_buf: []u8) ?[]const u8 {
    if (data.len > MAX_CORE_PAYLOAD) return coreError(response_buf, "__core__", "payload_too_large");
    var req_buf: [MAX_CORE_PAYLOAD]u8 = undefined;
    const req_clean: []const u8 = if (util.extractJsonString(data, "request")) |request_str|
        unescapeJson(request_str, &req_buf)
    else
        data;

    const cmd = util.extractJsonString(req_clean, "cmd") orelse "";
    if (cmd.len == 0) return coreError(response_buf, "__core__", "missing_cmd");
    // IPC injection (newline/quote 등) 차단 — char allowlist는 util.isValidCmdName 단위 테스트로.
    if (!util.isValidCmdName(cmd)) return coreError(response_buf, "__core__", "invalid_cmd");

    if (std.mem.eql(u8, cmd, "create_window")) {
        const wm = window_mod.WindowManager.global orelse return null;
        return window_ipc.handleCreateWindow(
            window_ipc.parseCreateWindowFromJson(req_clean),
            response_buf,
            wm,
        );
    }
    if (std.mem.eql(u8, cmd, "destroy_window")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleDestroyWindow(win_id, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "destroy_window_force")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleForceDestroyWindow(win_id, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "set_title")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = @intCast(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleSetTitle(.{
            .window_id = win_id,
            .title = util.extractJsonString(req_clean, "title") orelse "",
        }, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "set_bounds")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = @intCast(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleSetBounds(.{
            .window_id = win_id,
            .x = @intCast(util.extractJsonInt(req_clean, "x") orelse 0),
            .y = @intCast(util.extractJsonInt(req_clean, "y") orelse 0),
            .width = @intCast(util.extractJsonInt(req_clean, "width") orelse 0),
            .height = @intCast(util.extractJsonInt(req_clean, "height") orelse 0),
        }, response_buf, wm);
    }
    // Electron BrowserWindow.setMinimumSize / setMaximumSize. width/height=0 = 제한 없음.
    if (std.mem.eql(u8, cmd, "set_minimum_size") or std.mem.eql(u8, cmd, "set_maximum_size")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = @intCast(util.extractJsonInt(req_clean, "windowId") orelse return null);
        const sreq: window_ipc.SetSizeReq = .{
            .window_id = win_id,
            .width = @intCast(util.extractJsonInt(req_clean, "width") orelse 0),
            .height = @intCast(util.extractJsonInt(req_clean, "height") orelse 0),
        };
        return if (std.mem.eql(u8, cmd, "set_minimum_size"))
            window_ipc.handleSetMinimumSize(sreq, response_buf, wm)
        else
            window_ipc.handleSetMaximumSize(sreq, response_buf, wm);
    }
    // Electron BrowserWindow.setContentBounds() — set_bounds 와 동일 인자(콘텐츠 영역).
    if (std.mem.eql(u8, cmd, "set_content_bounds")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = @intCast(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleSetContentBounds(.{
            .window_id = win_id,
            .x = @intCast(util.extractJsonInt(req_clean, "x") orelse 0),
            .y = @intCast(util.extractJsonInt(req_clean, "y") orelse 0),
            .width = @intCast(util.extractJsonInt(req_clean, "width") orelse 0),
            .height = @intCast(util.extractJsonInt(req_clean, "height") orelse 0),
        }, response_buf, wm);
    }
    // Phase 4-A: webContents (네비/JS)
    if (std.mem.eql(u8, cmd, "load_url")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleLoadUrl(.{
            .window_id = win_id,
            .url = util.extractJsonString(req_clean, "url") orelse "",
        }, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "reload")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleReload(.{
            .window_id = win_id,
            .ignore_cache = util.extractJsonBool(req_clean, "ignoreCache") orelse false,
        }, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "execute_javascript")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleExecuteJavascript(.{
            .window_id = win_id,
            .code = util.extractJsonString(req_clean, "code") orelse "",
        }, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "stop")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleStop(win_id, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "insert_css")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleInsertCss(.{
            .window_id = win_id,
            .css_escaped = util.extractJsonString(req_clean, "css") orelse "",
        }, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "remove_inserted_css")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleRemoveInsertedCss(.{
            .window_id = win_id,
            .key = util.extractJsonString(req_clean, "key") orelse "",
        }, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "get_url")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleGetUrl(win_id, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "set_user_agent")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleSetUserAgent(win_id, util.extractJsonString(req_clean, "userAgent") orelse "", response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "get_user_agent")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleGetUserAgent(win_id, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "is_loading")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleIsLoading(win_id, response_buf, wm);
    }
    // Phase 4-C: DevTools — 정확 매치라 4-A의 substring 회귀 가드(is_dev_tools_opened
    // 우선 검사)도 불필요해짐.
    if (std.mem.eql(u8, cmd, "open_dev_tools")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleOpenDevTools(win_id, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "close_dev_tools")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleCloseDevTools(win_id, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "is_dev_tools_opened")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleIsDevToolsOpened(win_id, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "toggle_dev_tools")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleToggleDevTools(win_id, response_buf, wm);
    }
    // Phase 4-B: 줌
    if (std.mem.eql(u8, cmd, "set_zoom_level")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        const level = util.extractJsonFloat(req_clean, "level") orelse 0;
        return window_ipc.handleSetZoomLevel(.{ .window_id = win_id, .value = level }, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "set_zoom_factor")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        const factor = util.extractJsonFloat(req_clean, "factor") orelse 1;
        return window_ipc.handleSetZoomFactor(.{ .window_id = win_id, .value = factor }, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "get_zoom_level")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleGetZoomLevel(win_id, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "get_zoom_factor")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleGetZoomFactor(win_id, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "set_audio_muted")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        const muted = util.extractJsonBool(req_clean, "muted") orelse false;
        return window_ipc.handleSetAudioMuted(win_id, muted, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "is_audio_muted")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleIsAudioMuted(win_id, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "set_opacity")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        const opacity = util.extractJsonFloat(req_clean, "opacity") orelse 1;
        return window_ipc.handleSetOpacity(.{ .window_id = win_id, .value = opacity }, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "get_opacity")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleGetOpacity(win_id, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "set_background_color")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        const raw_hex = util.extractJsonString(req_clean, "color") orelse "";
        var hex_buf: [32]u8 = undefined;
        const hex_n = util.unescapeJsonStr(raw_hex, &hex_buf) orelse 0;
        return window_ipc.handleSetBackgroundColor(win_id, hex_buf[0..hex_n], response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "set_has_shadow")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        const has = util.extractJsonBool(req_clean, "hasShadow") orelse true;
        return window_ipc.handleSetHasShadow(win_id, has, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "has_shadow")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleHasShadow(win_id, response_buf, wm);
    }
    // Phase 4-E: 편집 (6 trivial) + 검색
    inline for (.{
        .{ "undo", &window_ipc.handleUndo },
        .{ "redo", &window_ipc.handleRedo },
        .{ "cut", &window_ipc.handleCut },
        .{ "copy", &window_ipc.handleCopy },
        .{ "paste", &window_ipc.handlePaste },
        .{ "select_all", &window_ipc.handleSelectAll },
    }) |entry| {
        if (std.mem.eql(u8, cmd, entry[0])) {
            const wm = window_mod.WindowManager.global orelse return null;
            const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
            return entry[1](win_id, response_buf, wm);
        }
    }
    if (std.mem.eql(u8, cmd, "find_in_page")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleFindInPage(.{
            .window_id = win_id,
            .text = util.extractJsonString(req_clean, "text") orelse "",
            .forward = util.extractJsonBool(req_clean, "forward") orelse true,
            .match_case = util.extractJsonBool(req_clean, "matchCase") orelse false,
            .find_next = util.extractJsonBool(req_clean, "findNext") orelse false,
        }, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "stop_find_in_page")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        const clear = util.extractJsonBool(req_clean, "clearSelection") orelse false;
        return window_ipc.handleStopFindInPage(win_id, clear, response_buf, wm);
    }
    // Phase 4-D: 인쇄 — 결과는 `window:pdf-print-finished` 이벤트로 분리.
    if (std.mem.eql(u8, cmd, "print_to_pdf")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        // extractJsonString 은 raw(escaped) 슬라이스 반환 — Windows 경로의 `\\` 가
        // 그대로 CEF·응답·event 로 흘러 path 라운드트립이 깨진다(JS 단 single
        // backslash ≠ echo double). unescape 로 실제 경로 복원(deferred-response
        // event 매칭 + FS gate 정확도). macOS 경로(`/`)는 unescape no-op.
        // path unescape: 렌더러-경로 게이트 공용 primitive(extractUnescapedField).
        // raw escaped 경로(Windows `\\`) → 실제 경로(FS gate 정확도 + deferred-response
        // event path 매칭). macOS 경로(`/`)는 no-op.
        var pdf_path_buf: [FS_MAX_PATH_BYTES]u8 = undefined;
        const pdf_path = extractUnescapedField(req_clean, "path", &pdf_path_buf) orelse "";
        if (rendererPathFsGate(response_buf, "print_to_pdf", pdf_path)) |e| return e;
        return window_ipc.handlePrintToPDF(.{
            .window_id = win_id,
            .path = pdf_path,
        }, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "capture_page")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        // clipWidth/clipHeight 둘 다 양수일 때만 부분 캡처(Electron rect). 아니면
        // 전체. CaptureClip 은 f64 (CDP clip 은 fractional CSS px 허용) →
        // extractJsonFloat 재사용(JS/Node rect 소수 정밀도 보존).
        const cw = util.extractJsonFloat(req_clean, "clipWidth");
        const ch = util.extractJsonFloat(req_clean, "clipHeight");
        const clip: ?window_mod.CaptureClip = if (cw != null and ch != null and cw.? > 0 and ch.? > 0)
            .{
                .x = util.extractJsonFloat(req_clean, "clipX") orelse 0,
                .y = util.extractJsonFloat(req_clean, "clipY") orelse 0,
                .width = cw.?,
                .height = ch.?,
            }
        else
            null;
        // print_to_pdf 와 동일 — raw escaped 경로를 unescape 해 Windows `\\`
        // 라운드트립 + event path 매칭 정상화.
        // print_to_pdf 와 동일 — extractUnescapedField 공용 primitive 로 unescape.
        var cap_path_buf: [FS_MAX_PATH_BYTES]u8 = undefined;
        const cap_path = extractUnescapedField(req_clean, "path", &cap_path_buf) orelse "";
        if (rendererPathFsGate(response_buf, "capture_page", cap_path)) |e| return e;
        return window_ipc.handleCapturePage(.{
            .window_id = win_id,
            .path = cap_path,
            .clip = clip,
        }, response_buf, wm);
    }
    // Phase 17-A: WebContentsView (createView / addChildView / setTopView / ...)
    if (std.mem.eql(u8, cmd, "create_view")) {
        const wm = window_mod.WindowManager.global orelse return null;
        return window_ipc.handleCreateView(window_ipc.parseCreateViewFromJson(req_clean), response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "destroy_view")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const view_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "viewId") orelse return null);
        return window_ipc.handleDestroyView(view_id, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "add_child_view")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const host_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "hostId") orelse return null);
        const view_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "viewId") orelse return null);
        return window_ipc.handleAddChildView(.{
            .host_id = host_id,
            .view_id = view_id,
            .index = util.extractNonNegUsize(req_clean, "index"),
        }, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "remove_child_view")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const host_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "hostId") orelse return null);
        const view_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "viewId") orelse return null);
        return window_ipc.handleRemoveChildView(host_id, view_id, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "set_top_view")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const host_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "hostId") orelse return null);
        const view_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "viewId") orelse return null);
        return window_ipc.handleSetTopView(host_id, view_id, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "set_view_bounds")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const view_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "viewId") orelse return null);
        const b = window_ipc.parseBoundsFromJson(req_clean);
        return window_ipc.handleSetViewBounds(.{
            .view_id = view_id,
            .x = b.x,
            .y = b.y,
            .width = b.width,
            .height = b.height,
        }, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "set_view_visible")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const view_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "viewId") orelse return null);
        const visible = util.extractJsonBool(req_clean, "visible") orelse true;
        return window_ipc.handleSetViewVisible(view_id, visible, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "get_view_bounds")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const view_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "viewId") orelse return null);
        return window_ipc.handleGetViewBounds(view_id, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "set_view_background_color")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const view_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "viewId") orelse return null);
        const raw_hex = util.extractJsonString(req_clean, "color") orelse "";
        var hex_buf: [32]u8 = undefined;
        const hex_n = util.unescapeJsonStr(raw_hex, &hex_buf) orelse 0;
        return window_ipc.handleSetViewBackgroundColor(view_id, hex_buf[0..hex_n], response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "get_child_views")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const host_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "hostId") orelse return null);
        // viewIds 임시 u32 슬라이스 — registry.allocator(힙). 고정 스택 arena는 view 수
        // 상한(4KB→~1024)을 만들고 초과 시 getChildViews OOM→오인 `ok:false,viewIds:[]`로
        // 절단됐다. handleGetChildViews가 직후 `defer allocator.free(ids)`로 즉시 반납.
        return window_ipc.handleGetChildViews(host_id, response_buf, wm, registry.allocator);
    }
    // Phase 5: 라이프사이클 제어 — minimize/maximize/restore_window/unmaximize 4 voidFn
    // + is_minimized/is_maximized/is_fullscreen 3 게터. 모두 (windowId, buf, wm) 시그니처라
    // 4-E 편집 핸들러와 동일한 dispatch 테이블. set_fullscreen만 flag 인자로 별도 분기.
    if (std.mem.eql(u8, cmd, "set_fullscreen")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        const flag = util.extractJsonBool(req_clean, "flag") orelse false;
        return window_ipc.handleSetFullscreen(.{ .window_id = win_id, .flag = flag }, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "set_visible")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        // 누락 시 false — set_fullscreen과 일관성 (필드 명시 안 하면 안 변경 의도로 해석).
        const visible = util.extractJsonBool(req_clean, "visible") orelse false;
        return window_ipc.handleSetVisible(.{ .window_id = win_id, .visible = visible }, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "set_always_on_top")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        const on_top = util.extractJsonBool(req_clean, "onTop") orelse false;
        return window_ipc.handleSetAlwaysOnTop(.{ .window_id = win_id, .on_top = on_top }, response_buf, wm);
    }
    // 창 capability 토글 (Electron setResizable/setMinimizable/setMaximizable/setClosable).
    // 각 cmd 는 동명 bool 키(resizable/minimizable/maximizable/closable) 사용.
    if (std.mem.eql(u8, cmd, "set_resizable")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleSetResizable(win_id, util.extractJsonBool(req_clean, "resizable") orelse false, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "set_minimizable")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleSetMinimizable(win_id, util.extractJsonBool(req_clean, "minimizable") orelse false, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "set_maximizable")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleSetMaximizable(win_id, util.extractJsonBool(req_clean, "maximizable") orelse false, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "set_closable")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleSetClosable(win_id, util.extractJsonBool(req_clean, "closable") orelse false, response_buf, wm);
    }
    // 창 모드 토글 (Electron setMovable/setFocusable/setEnabled/setFullScreenable/setKiosk).
    if (std.mem.eql(u8, cmd, "set_movable")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleSetMovable(win_id, util.extractJsonBool(req_clean, "movable") orelse false, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "set_focusable")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleSetFocusable(win_id, util.extractJsonBool(req_clean, "focusable") orelse false, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "set_enabled")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleSetEnabled(win_id, util.extractJsonBool(req_clean, "enabled") orelse false, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "set_fullscreenable")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleSetFullscreenable(win_id, util.extractJsonBool(req_clean, "fullscreenable") orelse false, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "set_kiosk")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleSetKiosk(win_id, util.extractJsonBool(req_clean, "kiosk") orelse false, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "set_content_protection")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleSetContentProtection(win_id, util.extractJsonBool(req_clean, "contentProtected") orelse false, response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "set_skip_taskbar")) {
        const wm = window_mod.WindowManager.global orelse return null;
        const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
        return window_ipc.handleSetSkipTaskbar(win_id, util.extractJsonBool(req_clean, "skip") orelse false, response_buf, wm);
    }
    // getAllWindows/getFocusedWindow 는 windowId 입력이 없어 전용 분기.
    if (std.mem.eql(u8, cmd, "get_all_windows")) {
        const wm = window_mod.WindowManager.global orelse return null;
        return window_ipc.handleGetAllWindows(response_buf, wm);
    }
    if (std.mem.eql(u8, cmd, "get_focused_window")) {
        const wm = window_mod.WindowManager.global orelse return null;
        return window_ipc.handleGetFocusedWindow(response_buf, wm);
    }
    inline for (.{
        .{ "minimize", &window_ipc.handleMinimize },
        .{ "restore_window", &window_ipc.handleRestoreWindow },
        .{ "maximize", &window_ipc.handleMaximize },
        .{ "unmaximize", &window_ipc.handleUnmaximize },
        .{ "is_minimized", &window_ipc.handleIsMinimized },
        .{ "is_maximized", &window_ipc.handleIsMaximized },
        .{ "is_fullscreen", &window_ipc.handleIsFullscreen },
        .{ "focus", &window_ipc.handleFocus },
        .{ "is_normal", &window_ipc.handleIsNormal },
        .{ "get_bounds", &window_ipc.handleGetBounds },
        .{ "get_minimum_size", &window_ipc.handleGetMinimumSize },
        .{ "get_maximum_size", &window_ipc.handleGetMaximumSize },
        .{ "get_content_bounds", &window_ipc.handleGetContentBounds },
        .{ "blur", &window_ipc.handleBlur },
        .{ "is_focused", &window_ipc.handleIsFocused },
        .{ "is_visible", &window_ipc.handleIsVisible },
        .{ "is_always_on_top", &window_ipc.handleIsAlwaysOnTop },
        .{ "is_resizable", &window_ipc.handleIsResizable },
        .{ "is_minimizable", &window_ipc.handleIsMinimizable },
        .{ "is_maximizable", &window_ipc.handleIsMaximizable },
        .{ "is_closable", &window_ipc.handleIsClosable },
        .{ "is_movable", &window_ipc.handleIsMovable },
        .{ "is_focusable", &window_ipc.handleIsFocusable },
        .{ "is_enabled", &window_ipc.handleIsEnabled },
        .{ "is_fullscreenable", &window_ipc.handleIsFullscreenable },
        .{ "is_kiosk", &window_ipc.handleIsKiosk },
        .{ "is_content_protected", &window_ipc.handleIsContentProtected },
    }) |entry| {
        if (std.mem.eql(u8, cmd, entry[0])) {
            const wm = window_mod.WindowManager.global orelse return null;
            const win_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "windowId") orelse return null);
            return entry[1](win_id, response_buf, wm);
        }
    }
    if (std.mem.eql(u8, cmd, "quit")) {
        cef.quit();
        const result = std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"quit\"}}", .{}) catch return null;
        return result;
    }

    // Clipboard API — NSPasteboard plain text.
    if (std.mem.eql(u8, cmd, "clipboard_read_text")) {
        var raw_buf: [util.MAX_RESPONSE]u8 = undefined;
        const text = cef.clipboardReadText(&raw_buf);
        var esc_buf: [util.MAX_RESPONSE]u8 = undefined;
        const esc_len = util.escapeJsonStrFull(text, &esc_buf) orelse return null;
        const result = std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"clipboard_read_text\",\"text\":\"{s}\"}}",
            .{esc_buf[0..esc_len]},
        ) catch return null;
        return result;
    }
    if (std.mem.eql(u8, cmd, "clipboard_write_text")) {
        const raw = util.extractJsonString(req_clean, "text") orelse "";
        var unesc_buf: [util.MAX_RESPONSE]u8 = undefined;
        // 한도 초과면 graceful false (caller가 boolean 응답 기대 — null 반환은 raw string으로
        // 떨어져 r.success undefined 됨).
        const ok = if (util.unescapeJsonStr(raw, &unesc_buf)) |unesc_len|
            cef.clipboardWriteText(unesc_buf[0..unesc_len])
        else
            false;
        const result = std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"clipboard_write_text\",\"success\":{}}}",
            .{ok},
        ) catch return null;
        return result;
    }
    if (std.mem.eql(u8, cmd, "clipboard_clear")) {
        cef.clipboardClear();
        const result = std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"clipboard_clear\",\"success\":true}}", .{}) catch return null;
        return result;
    }
    if (std.mem.eql(u8, cmd, "clipboard_read_html")) {
        var raw_buf: [util.MAX_RESPONSE]u8 = undefined;
        const html = cef.clipboardReadHtml(&raw_buf);
        var esc_buf: [util.MAX_RESPONSE]u8 = undefined;
        const esc_len = util.escapeJsonStrFull(html, &esc_buf) orelse return null;
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"clipboard_read_html\",\"html\":\"{s}\"}}",
            .{esc_buf[0..esc_len]},
        ) catch null;
    }
    if (std.mem.eql(u8, cmd, "clipboard_write_html")) {
        const raw = util.extractJsonString(req_clean, "html") orelse "";
        var unesc_buf: [util.MAX_RESPONSE]u8 = undefined;
        const ok = if (util.unescapeJsonStr(raw, &unesc_buf)) |unesc_len|
            cef.clipboardWriteHtml(unesc_buf[0..unesc_len])
        else
            false;
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"clipboard_write_html\",\"success\":{}}}",
            .{ok},
        ) catch null;
    }
    if (std.mem.eql(u8, cmd, "clipboard_write_bookmark")) {
        var t_buf: [util.MAX_RESPONSE]u8 = undefined;
        var u_buf: [util.MAX_RESPONSE]u8 = undefined;
        // 필드 한도 초과(unescape null) → success:false (write_text 패턴; 빈 문자열은 0=정상).
        const ok = blk: {
            const title = util.unescapeJsonStr(util.extractJsonString(req_clean, "title") orelse "", &t_buf) orelse break :blk false;
            const url = util.unescapeJsonStr(util.extractJsonString(req_clean, "url") orelse "", &u_buf) orelse break :blk false;
            break :blk cef.clipboardWriteBookmark(t_buf[0..title], u_buf[0..url]);
        };
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"clipboard_write_bookmark\",\"success\":{}}}", .{ok}) catch null;
    }
    if (std.mem.eql(u8, cmd, "clipboard_write_find_text")) {
        const raw = util.extractJsonString(req_clean, "text") orelse "";
        var unesc_buf: [util.MAX_RESPONSE]u8 = undefined;
        const ok = if (util.unescapeJsonStr(raw, &unesc_buf)) |n| cef.clipboardWriteFindText(unesc_buf[0..n]) else false;
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"clipboard_write_find_text\",\"success\":{}}}", .{ok}) catch null;
    }
    if (std.mem.eql(u8, cmd, "clipboard_read_find_text")) {
        var raw_buf: [util.MAX_RESPONSE]u8 = undefined;
        const text = cef.clipboardReadFindText(&raw_buf);
        var esc_buf: [util.MAX_RESPONSE]u8 = undefined;
        const esc_len = util.escapeJsonStrFull(text, &esc_buf) orelse return null;
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"clipboard_read_find_text\",\"text\":\"{s}\"}}",
            .{esc_buf[0..esc_len]},
        ) catch null;
    }
    if (std.mem.eql(u8, cmd, "clipboard_write")) {
        var t_buf: [util.MAX_RESPONSE]u8 = undefined;
        var h_buf: [util.MAX_RESPONSE]u8 = undefined;
        var r_buf: [util.MAX_RESPONSE]u8 = undefined;
        // 한 필드라도 한도 초과 → success:false(조용히 drop 금지). 빈 필드는 0=skip.
        const ok = blk: {
            const tn = util.unescapeJsonStr(util.extractJsonString(req_clean, "text") orelse "", &t_buf) orelse break :blk false;
            const hn = util.unescapeJsonStr(util.extractJsonString(req_clean, "html") orelse "", &h_buf) orelse break :blk false;
            const rn = util.unescapeJsonStr(util.extractJsonString(req_clean, "rtf") orelse "", &r_buf) orelse break :blk false;
            break :blk cef.clipboardWriteMulti(t_buf[0..tn], h_buf[0..hn], r_buf[0..rn]);
        };
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"clipboard_write\",\"success\":{}}}", .{ok}) catch null;
    }
    if (std.mem.eql(u8, cmd, "clipboard_read_rtf")) {
        var raw_buf: [util.MAX_RESPONSE]u8 = undefined;
        const rtf = cef.clipboardReadRtf(&raw_buf);
        var esc_buf: [util.MAX_RESPONSE]u8 = undefined;
        const esc_len = util.escapeJsonStrFull(rtf, &esc_buf) orelse return null;
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"clipboard_read_rtf\",\"rtf\":\"{s}\"}}",
            .{esc_buf[0..esc_len]},
        ) catch null;
    }
    if (std.mem.eql(u8, cmd, "clipboard_write_rtf")) {
        const raw = util.extractJsonString(req_clean, "rtf") orelse "";
        var unesc_buf: [util.MAX_RESPONSE]u8 = undefined;
        const ok = if (util.unescapeJsonStr(raw, &unesc_buf)) |unesc_len|
            cef.clipboardWriteRtf(unesc_buf[0..unesc_len])
        else
            false;
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"clipboard_write_rtf\",\"success\":{}}}",
            .{ok},
        ) catch null;
    }
    // clipboard buffer (raw bytes for arbitrary UTI). raw 한도 ~8KB (image와 동일 IPC 제약).
    if (std.mem.eql(u8, cmd, "clipboard_write_buffer")) {
        const raw_type = util.extractJsonString(req_clean, "format") orelse "";
        var type_buf: [256]u8 = undefined;
        const type_n = util.unescapeJsonStr(raw_type, &type_buf) orelse 0;
        if (type_n == 0) return respondSuccess(response_buf, cmd, false);
        const b64_raw = util.extractJsonString(req_clean, "data") orelse "";
        var b64_buf: [util.MAX_RESPONSE]u8 = undefined;
        const b64_n = util.unescapeJsonStr(b64_raw, &b64_buf) orelse 0;
        if (b64_n == 0) return respondSuccess(response_buf, cmd, false);
        var raw_buf: [8 * 1024]u8 = undefined;
        const decoded_size = std.base64.standard.Decoder.calcSizeForSlice(b64_buf[0..b64_n]) catch
            return respondSuccess(response_buf, cmd, false);
        if (decoded_size > raw_buf.len) return respondSuccess(response_buf, cmd, false);
        std.base64.standard.Decoder.decode(raw_buf[0..decoded_size], b64_buf[0..b64_n]) catch
            return respondSuccess(response_buf, cmd, false);
        const ok = cef.clipboardWriteBuffer(raw_buf[0..decoded_size], type_buf[0..type_n]);
        return respondSuccess(response_buf, cmd, ok);
    }
    if (std.mem.eql(u8, cmd, "clipboard_read_buffer")) {
        const raw_type = util.extractJsonString(req_clean, "format") orelse "";
        var type_buf: [256]u8 = undefined;
        const type_n = util.unescapeJsonStr(raw_type, &type_buf) orelse 0;
        var raw_buf: [8 * 1024]u8 = undefined;
        const bytes = cef.clipboardReadBuffer(&raw_buf, type_buf[0..type_n]);
        return respondBase64Data(response_buf, "clipboard_read_buffer", bytes);
    }
    if (std.mem.eql(u8, cmd, "power_monitor_get_idle_time")) {
        const seconds = cef.powerMonitorIdleSeconds();
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"power_monitor_get_idle_time\",\"seconds\":{d}}}",
            .{seconds},
        ) catch null;
    }
    // Electron powerMonitor.isOnBatteryPower() — macOS IOKit / Windows GetSystemPowerStatus
    // / Linux /sys (AC online). 정보 없으면 false.
    if (std.mem.eql(u8, cmd, "power_monitor_is_on_battery")) {
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"power_monitor_is_on_battery\",\"onBattery\":{}}}",
            .{cef.powerMonitorIsOnBattery()},
        ) catch null;
    }
    if (std.mem.eql(u8, cmd, "power_monitor_thermal_state")) {
        const name = switch (cef.powerMonitorThermalState()) {
            0 => "nominal",
            1 => "fair",
            2 => "serious",
            3 => "critical",
            else => "unknown",
        };
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"power_monitor_thermal_state\",\"thermalState\":\"{s}\"}}",
            .{name},
        ) catch null;
    }
    if (std.mem.eql(u8, cmd, "power_monitor_get_idle_state")) {
        const threshold = util.extractJsonInt(req_clean, "threshold") orelse 0;
        const seconds = cef.powerMonitorIdleSeconds();
        // 화면 잠금 시 "locked" 우선(Electron 동등). 아니면 idle 임계 비교 —
        // f64 직접 비교(seconds NaN/Inf여도 panic 없이 false → "active" safe).
        const state: []const u8 = if (cef.powerMonitorScreenLocked())
            "locked"
        else if (seconds >= @as(f64, @floatFromInt(threshold)))
            "idle"
        else
            "active";
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"power_monitor_get_idle_state\",\"state\":\"{s}\"}}",
            .{state},
        ) catch null;
    }
    if (std.mem.eql(u8, cmd, "power_monitor_test_emit")) {
        const hook_enabled = if (runtime.env("SUJI_E2E_POWER_MONITOR_TEST_HOOK")) |v|
            std.mem.eql(u8, v, "1")
        else
            false;
        if (!hook_enabled) return respondSuccess(response_buf, cmd, false);

        const raw = util.extractJsonString(req_clean, "event") orelse "";
        var event_buf: [32]u8 = undefined;
        const event_n = util.unescapeJsonStr(raw, &event_buf) orelse 0;
        const event = event_buf[0..event_n];
        const valid =
            std.mem.eql(u8, event, "suspend") or
            std.mem.eql(u8, event, "resume") or
            std.mem.eql(u8, event, "lock-screen") or
            std.mem.eql(u8, event, "unlock-screen");
        if (!valid) return respondSuccess(response_buf, cmd, false);

        var event_z_buf: [32:0]u8 = undefined;
        @memcpy(event_z_buf[0..event.len], event);
        event_z_buf[event.len] = 0;
        powerMonitorEmitHandler(event_z_buf[0..event.len :0].ptr);
        return respondSuccess(response_buf, cmd, true);
    }

    // Shell API — NSWorkspace 기본 핸들러 / NSBeep.
    if (std.mem.eql(u8, cmd, "shell_open_external")) {
        const raw = util.extractJsonString(req_clean, "url") orelse "";
        var unesc_buf: [util.MAX_RESPONSE]u8 = undefined;
        const ok = blk: {
            const n = util.unescapeJsonStr(raw, &unesc_buf) orelse break :blk false;
            const url = unesc_buf[0..n];
            if (shellUrlGate(response_buf, "shell_open_external", url)) |e| return e;
            break :blk cef.shellOpenExternal(url);
        };
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"shell_open_external\",\"success\":{}}}",
            .{ok},
        ) catch return null;
    }
    if (std.mem.eql(u8, cmd, "shell_show_item_in_folder")) {
        const raw = util.extractJsonString(req_clean, "path") orelse "";
        var unesc_buf: [util.MAX_RESPONSE]u8 = undefined;
        const ok = blk: {
            const n = util.unescapeJsonStr(raw, &unesc_buf) orelse break :blk false;
            const path = unesc_buf[0..n];
            if (shellPathGate(response_buf, "shell_show_item_in_folder", path)) |e| return e;
            break :blk cef.shellShowItemInFolder(path);
        };
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"shell_show_item_in_folder\",\"success\":{}}}",
            .{ok},
        ) catch return null;
    }
    if (std.mem.eql(u8, cmd, "shell_beep")) {
        cef.shellBeep();
        const result = std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"shell_beep\",\"success\":true}}", .{}) catch return null;
        return result;
    }
    if (std.mem.eql(u8, cmd, "shell_trash_item")) {
        const raw = util.extractJsonString(req_clean, "path") orelse "";
        var unesc_buf: [util.MAX_RESPONSE]u8 = undefined;
        const ok = blk: {
            const n = util.unescapeJsonStr(raw, &unesc_buf) orelse break :blk false;
            const path = unesc_buf[0..n];
            if (shellPathGate(response_buf, "shell_trash_item", path)) |e| return e;
            break :blk cef.shellTrashItem(path);
        };
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"shell_trash_item\",\"success\":{}}}",
            .{ok},
        ) catch null;
    }
    if (std.mem.eql(u8, cmd, "shell_open_path")) {
        const raw = util.extractJsonString(req_clean, "path") orelse "";
        var unesc_buf: [util.MAX_RESPONSE]u8 = undefined;
        const ok = blk: {
            const n = util.unescapeJsonStr(raw, &unesc_buf) orelse break :blk false;
            const path = unesc_buf[0..n];
            if (shellPathGate(response_buf, "shell_open_path", path)) |e| return e;
            break :blk cef.shellOpenPath(path);
        };
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"shell_open_path\",\"success\":{}}}",
            .{ok},
        ) catch null;
    }
    if (std.mem.eql(u8, cmd, "native_theme_should_use_dark_colors")) {
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"native_theme_should_use_dark_colors\",\"dark\":{}}}",
            .{cef.nativeThemeIsDark()},
        ) catch null;
    }
    if (std.mem.eql(u8, cmd, "native_theme_high_contrast") or std.mem.eql(u8, cmd, "native_theme_reduced_transparency")) {
        const high_contrast = std.mem.eql(u8, cmd, "native_theme_high_contrast");
        const val = if (high_contrast) cef.nativeThemeHighContrast() else cef.nativeThemeReducedTransparency();
        const field = if (high_contrast) "highContrast" else "reducedTransparency";
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"{s}\",\"{s}\":{}}}",
            .{ cmd, field, val },
        ) catch null;
    }
    if (std.mem.eql(u8, cmd, "native_theme_inverted_color_scheme") or std.mem.eql(u8, cmd, "native_theme_differentiate_without_color")) {
        const inverted = std.mem.eql(u8, cmd, "native_theme_inverted_color_scheme");
        const val = if (inverted) cef.nativeThemeInvertedColorScheme() else cef.nativeThemeDifferentiateWithoutColor();
        const field = if (inverted) "invertedColorScheme" else "differentiateWithoutColor";
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"{s}\",\"{s}\":{}}}",
            .{ cmd, field, val },
        ) catch null;
    }
    if (std.mem.eql(u8, cmd, "native_theme_set_source")) {
        const source = util.extractJsonString(req_clean, "source") orelse "system";
        const ok = cef.nativeThemeSetSource(source);
        if (ok) {
            // 정적 리터럴만 저장(req_clean 은 일시적).
            g_theme_source = if (std.mem.eql(u8, source, "dark"))
                "dark"
            else if (std.mem.eql(u8, source, "light"))
                "light"
            else
                "system";
        }
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"native_theme_set_source\",\"success\":{}}}",
            .{ok},
        ) catch null;
    }
    // Electron nativeTheme.themeSource (getter) — setter 가 설정한 값(기본 "system").
    if (std.mem.eql(u8, cmd, "native_theme_get_source")) {
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"native_theme_get_source\",\"source\":\"{s}\"}}",
            .{g_theme_source},
        ) catch null;
    }
    if (std.mem.eql(u8, cmd, "screen_get_cursor_point")) {
        const p = cef.screenGetCursorPoint();
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"screen_get_cursor_point\",\"x\":{d},\"y\":{d}}}",
            .{ p.x, p.y },
        ) catch null;
    }
    if (std.mem.eql(u8, cmd, "screen_get_display_nearest_point")) {
        const x = util.extractJsonFloat(req_clean, "x") orelse 0;
        const y = util.extractJsonFloat(req_clean, "y") orelse 0;
        const idx = cef.screenGetDisplayNearestPoint(x, y);
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"screen_get_display_nearest_point\",\"index\":{d}}}",
            .{idx},
        ) catch null;
    }
    // Electron screen.getDisplayMatching — rect 와 겹침 최대 display index(없으면 중심 최근접).
    if (std.mem.eql(u8, cmd, "screen_get_display_matching")) {
        const x = util.extractJsonFloat(req_clean, "x") orelse 0;
        const y = util.extractJsonFloat(req_clean, "y") orelse 0;
        const w = util.extractJsonFloat(req_clean, "width") orelse 0;
        const h = util.extractJsonFloat(req_clean, "height") orelse 0;
        const idx = cef.screenGetDisplayMatching(x, y, w, h);
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"screen_get_display_matching\",\"index\":{d}}}",
            .{idx},
        ) catch null;
    }

    // app.getPath — Electron 표준 키 7개. config.app.name이 userData 경로에 들어감.
    if (std.mem.eql(u8, cmd, "app_get_path")) {
        const name = util.extractJsonString(req_clean, "name") orelse "";
        var path_buf: [1024]u8 = undefined;
        // setPath 로 등록된 오버라이드가 있으면 우선, 없으면 표준 경로 (Electron setPath/getPath).
        const path = pathOverrideGet(name) orelse blk: {
            const app_name: []const u8 = if (g_config) |c| c.app.name else "Suji";
            break :blk cef.appGetPath(&path_buf, name, app_name) orelse "";
        };
        var esc_buf: [2048]u8 = undefined;
        const esc_n = util.escapeJsonStrFull(path, &esc_buf) orelse return coreError(response_buf, "app_get_path", "encode");
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"app_get_path\",\"path\":\"{s}\"}}",
            .{esc_buf[0..esc_n]},
        ) catch null;
    }

    // Screen API — getAllDisplays 결과를 큰 stack 버퍼로 직접 빌드.
    if (std.mem.eql(u8, cmd, "screen_get_all_displays")) {
        var displays_buf: [4096]u8 = undefined;
        const displays = cef.screenGetAllDisplays(&displays_buf);
        const result = std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"screen_get_all_displays\",\"displays\":{s}}}",
            .{displays},
        ) catch return null;
        return result;
    }
    if (std.mem.eql(u8, cmd, "desktop_capturer_get_sources")) {
        // types 미지정 시 screen+window 둘 다 (Electron 은 필수지만 친화 기본).
        const types = util.extractJsonString(req_clean, "types");
        const want_screen = types == null or std.mem.indexOf(u8, types.?, "screen") != null;
        const want_window = types == null or std.mem.indexOf(u8, types.?, "window") != null;
        var sources_buf: [12288]u8 = undefined;
        const sources = cef.desktopCapturerGetSources(&sources_buf, want_screen, want_window);
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"desktop_capturer_get_sources\",\"sources\":{s}}}",
            .{sources},
        ) catch null;
    }
    if (std.mem.eql(u8, cmd, "desktop_capturer_capture_thumbnail")) {
        const source_id = util.extractJsonString(req_clean, "sourceId") orelse "";
        // path 는 extractUnescapedField(렌더러-경로 게이트 공용 primitive)로 unescape —
        // extractJsonString 은 raw(미-unescape)라 Windows `C:\\…`(이중 백슬래시)가
        // allowedRoots(std.json, unescaped)와 어긋나 forbidden 됨. helper 는 overflow/실패
        // 시 null → "" → 아래 path.len 체크가 거부(escaped raw 통과 방지).
        var dc_path_buf: [FS_MAX_PATH_BYTES]u8 = undefined;
        const path = extractUnescapedField(req_clean, "path", &dc_path_buf) orelse "";
        if (rendererPathFsGate(response_buf, "desktop_capturer_capture_thumbnail", path)) |e| return e;
        const ok = source_id.len > 0 and path.len > 0 and
            cef.desktopCapturerCaptureThumbnail(source_id, path);
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"desktop_capturer_capture_thumbnail\",\"success\":{}}}",
            .{ok},
        ) catch null;
    }

    // crashReporter — CEF Crashpad/Breakpad bridge. Runtime start() stores
    // upload flag + extra parameters; full first-process enablement requires
    // app.crashReporter so CEF can read crash_reporter.cfg before initialize.
    if (std.mem.eql(u8, cmd, "crash_reporter_start")) {
        const upload = util.extractJsonBool(req_clean, "uploadToServer") orelse true;
        const submit = util.extractJsonString(req_clean, "submitURL");
        if (upload and (submit == null or submit.?.len == 0)) {
            return coreError(response_buf, "crash_reporter_start", "submitURL_required");
        }
        g_crash_reporter_started = true;
        g_crash_reporter_upload_to_server = upload;
        crashApplyExtraObject(req_clean);
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"crash_reporter_start\",\"success\":true,\"enabled\":{}}}",
            .{cef.crashReporterEnabled()},
        ) catch null;
    }
    if (std.mem.eql(u8, cmd, "crash_reporter_get_parameters")) {
        return crashParametersResponse(response_buf);
    }
    if (std.mem.eql(u8, cmd, "crash_reporter_add_extra_parameter")) {
        var key_buf: [128]u8 = undefined;
        var value_buf: [crash_reporter.MAX_VALUE_BYTES]u8 = undefined;
        const key = extractUnescapedField(req_clean, "key", &key_buf) orelse
            return respondSuccess(response_buf, "crash_reporter_add_extra_parameter", false);
        const value = extractUnescapedField(req_clean, "value", &value_buf) orelse
            return respondSuccess(response_buf, "crash_reporter_add_extra_parameter", false);
        return respondSuccess(response_buf, "crash_reporter_add_extra_parameter", crashAddExtraParameter(key, value));
    }
    if (std.mem.eql(u8, cmd, "crash_reporter_remove_extra_parameter")) {
        var key_buf: [128]u8 = undefined;
        const key = extractUnescapedField(req_clean, "key", &key_buf) orelse
            return respondSuccess(response_buf, "crash_reporter_remove_extra_parameter", false);
        return respondSuccess(response_buf, "crash_reporter_remove_extra_parameter", crashRemoveExtraParameter(key));
    }
    if (std.mem.eql(u8, cmd, "crash_reporter_get_upload_to_server")) {
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"crash_reporter_get_upload_to_server\",\"uploadToServer\":{}}}",
            .{g_crash_reporter_upload_to_server},
        ) catch null;
    }
    if (std.mem.eql(u8, cmd, "crash_reporter_set_upload_to_server")) {
        g_crash_reporter_upload_to_server = util.extractJsonBool(req_clean, "uploadToServer") orelse false;
        return respondSuccess(response_buf, "crash_reporter_set_upload_to_server", g_crash_reporter_started);
    }
    if (std.mem.eql(u8, cmd, "crash_reporter_get_uploaded_reports")) {
        return crashUploadedReportsResponse(response_buf);
    }
    if (std.mem.eql(u8, cmd, "crash_reporter_get_last_crash_report")) {
        return crashLastReportResponse(response_buf);
    }

    // Dock badge API. extractJsonString은 wire escape를 안 풀어주므로 unescape 후 NSDockTile에.
    // unescape 실패(text 한도 초과)면 graceful false — clipboard_write_text 패턴과 일관.
    // 256B 버퍼 — NSDockTile은 짧은 label(6-10 chars) 용도 (Apple HIG). escape margin 포함 충분.
    if (std.mem.eql(u8, cmd, "dock_set_badge")) {
        const raw = util.extractJsonString(req_clean, "text") orelse "";
        var unesc_buf: [256]u8 = undefined;
        const ok = if (util.unescapeJsonStr(raw, &unesc_buf)) |n| blk: {
            const label = unesc_buf[0..n];
            cef.dockSetBadge(label);
            g_app_badge_count = badge_count.countFromLabel(label);
            break :blk true;
        } else false;
        const result = std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"dock_set_badge\",\"success\":{}}}",
            .{ok},
        ) catch return null;
        return result;
    }
    if (std.mem.eql(u8, cmd, "dock_get_badge")) {
        var text_buf: [256]u8 = undefined;
        const text = cef.dockGetBadge(&text_buf);
        var esc_buf: [512]u8 = undefined;
        const esc_n = util.escapeJsonStrFull(text, &esc_buf) orelse return null;
        const result = std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"dock_get_badge\",\"text\":\"{s}\"}}",
            .{esc_buf[0..esc_n]},
        ) catch return null;
        return result;
    }
    if (std.mem.eql(u8, cmd, "app_set_badge_count")) {
        const count = badge_count.countFromWire(util.extractJsonInt(req_clean, "count"));
        g_app_badge_count = count;
        const native = cef.appSetBadgeCount(count);
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"app_set_badge_count\",\"success\":true,\"native\":{}}}",
            .{native},
        ) catch null;
    }
    if (std.mem.eql(u8, cmd, "app_get_badge_count")) {
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"app_get_badge_count\",\"count\":{d}}}",
            .{g_app_badge_count},
        ) catch null;
    }

    // Power save blocker.
    if (std.mem.eql(u8, cmd, "power_save_blocker_start")) {
        const type_str = util.extractJsonString(req_clean, "type") orelse "prevent_display_sleep";
        const t: cef.PowerSaveBlockerType = if (std.mem.eql(u8, type_str, "prevent_app_suspension"))
            .prevent_app_suspension
        else
            .prevent_display_sleep;
        const id = cef.powerSaveBlockerStart(t);
        const result = std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"power_save_blocker_start\",\"id\":{d}}}",
            .{id},
        ) catch return null;
        return result;
    }
    if (std.mem.eql(u8, cmd, "power_save_blocker_stop")) {
        const id_n = util.extractJsonInt(req_clean, "id") orelse 0;
        const ok = cef.powerSaveBlockerStop(util.nonNegU32(id_n));
        const result = std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"power_save_blocker_stop\",\"success\":{}}}",
            .{ok},
        ) catch return null;
        return result;
    }
    if (std.mem.eql(u8, cmd, "power_save_blocker_is_started")) {
        const id_n = util.extractJsonInt(req_clean, "id") orelse 0;
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"power_save_blocker_is_started\",\"started\":{}}}",
            .{cef.powerSaveBlockerIsStarted(util.nonNegU32(id_n))},
        ) catch null;
    }

    // app.getName / app.getVersion — config.app exposure (Electron `app.getName/getVersion`).
    if (std.mem.eql(u8, cmd, "app_get_name")) {
        const name: []const u8 = if (g_config) |c| c.app.name else "Suji";
        var esc_buf: [256]u8 = undefined;
        const esc_n = util.escapeJsonStrFull(name, &esc_buf) orelse return null;
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"app_get_name\",\"name\":\"{s}\"}}",
            .{esc_buf[0..esc_n]},
        ) catch null;
    }
    // Electron app.{setAsDefaultProtocolClient/isDefaultProtocolClient/removeAsDefaultProtocolClient}.
    // macOS Launch Services — 실 .app 번들에서만 동작(dev=번들 ID 부재 → false).
    if (std.mem.eql(u8, cmd, "app_set_as_default_protocol_client") or
        std.mem.eql(u8, cmd, "app_is_default_protocol_client") or
        std.mem.eql(u8, cmd, "app_remove_as_default_protocol_client"))
    {
        var scheme_buf: [256]u8 = undefined;
        const raw = util.extractJsonString(req_clean, "protocol") orelse "";
        const scheme_z = cef.nullTerminateOrTruncate(raw, &scheme_buf) orelse return null;
        const ok = if (std.mem.eql(u8, cmd, "app_set_as_default_protocol_client"))
            cef.protocolSetAsDefault(scheme_z)
        else if (std.mem.eql(u8, cmd, "app_is_default_protocol_client"))
            cef.protocolIsDefault(scheme_z)
        else
            cef.protocolRemoveAsDefault(scheme_z);
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"{s}\",\"success\":{}}}",
            .{ cmd, ok },
        ) catch null;
    }
    // Electron app.requestSingleInstanceLock — primary 면 locked:true, 다른
    // 인스턴스가 이미 보유 중이면 false. macOS/Linux=userData flock, Windows=
    // named mutex. POSIX 는 userData 경로(앱별 격리)로 lockfile 위치 결정.
    if (std.mem.eql(u8, cmd, "app_request_single_instance_lock")) {
        const app_name: []const u8 = if (g_config) |c| c.app.name else "Suji";
        var ud_buf: [1024]u8 = undefined;
        const user_data = cef.appGetPath(&ud_buf, "userData", app_name) orelse "";
        const locked = cef.requestSingleInstanceLock(user_data, app_name);
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"app_request_single_instance_lock\",\"locked\":{}}}", .{locked}) catch null;
    }
    if (std.mem.eql(u8, cmd, "app_has_single_instance_lock")) {
        const locked = cef.hasSingleInstanceLock();
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"app_has_single_instance_lock\",\"locked\":{}}}", .{locked}) catch null;
    }
    if (std.mem.eql(u8, cmd, "app_release_single_instance_lock")) {
        cef.releaseSingleInstanceLock();
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"app_release_single_instance_lock\",\"success\":true}}", .{}) catch null;
    }
    if (std.mem.eql(u8, cmd, "app_is_ready")) {
        // V8 binding이 호출 가능한 시점은 이미 init 후. 항상 true.
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"app_is_ready\",\"ready\":true}}", .{}) catch null;
    }
    if (std.mem.eql(u8, cmd, "app_is_packaged")) {
        const packaged = cef.appIsPackaged();
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"app_is_packaged\",\"packaged\":{}}}",
            .{packaged},
        ) catch null;
    }
    if (std.mem.eql(u8, cmd, "app_get_app_path")) {
        var path_buf: [1024]u8 = undefined;
        const path = cef.appGetBundlePath(&path_buf);
        var esc_buf: [2048]u8 = undefined;
        const esc_n = util.escapeJsonStrFull(path, &esc_buf) orelse 0;
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"app_get_app_path\",\"path\":\"{s}\"}}",
            .{esc_buf[0..esc_n]},
        ) catch null;
    }
    // app.flashFrame — dock/창 주의 끌기 (Electron BrowserWindow.flashFrame). macOS dock bounce.
    if (std.mem.eql(u8, cmd, "app_flash_frame")) {
        const flash = util.extractJsonBool(req_clean, "flash") orelse true;
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"app_flash_frame\",\"success\":{}}}", .{cef.appFlashFrame(flash)}) catch null;
    }
    // app.showAboutPanel / setAboutPanelOptions (Electron). macOS NSApp orderFrontStandardAboutPanel.
    if (std.mem.eql(u8, cmd, "app_show_about_panel")) {
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"app_show_about_panel\",\"success\":{}}}", .{cef.appShowAboutPanel()}) catch null;
    }
    if (std.mem.eql(u8, cmd, "app_set_about_panel_options")) {
        var n_buf: [256]u8 = undefined;
        var v_buf: [256]u8 = undefined;
        var b_buf: [256]u8 = undefined;
        var c_buf: [512]u8 = undefined;
        const ok = cef.appSetAboutPanelOptions(
            unescapeField(req_clean, "applicationName", &n_buf, false),
            unescapeField(req_clean, "applicationVersion", &v_buf, false),
            unescapeField(req_clean, "version", &b_buf, false),
            unescapeField(req_clean, "copyright", &c_buf, false),
        );
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"app_set_about_panel_options\",\"success\":{}}}", .{ok}) catch null;
    }
    // app.addRecentDocument / clearRecentDocuments (Electron). macOS NSDocumentController.
    if (std.mem.eql(u8, cmd, "app_add_recent_document")) {
        var path_buf: [4096]u8 = undefined;
        const path = unescapeField(req_clean, "path", &path_buf, true) orelse "";
        const ok = if (path.len > 0) cef.appAddRecentDocument(path) else false;
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"app_add_recent_document\",\"success\":{}}}", .{ok}) catch null;
    }
    if (std.mem.eql(u8, cmd, "app_clear_recent_documents")) {
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"app_clear_recent_documents\",\"success\":{}}}", .{cef.appClearRecentDocuments()}) catch null;
    }
    // app.isInApplicationsFolder (Electron). macOS bundlePath /Applications 검사.
    if (std.mem.eql(u8, cmd, "app_is_in_applications_folder")) {
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"app_is_in_applications_folder\",\"inApplications\":{}}}", .{cef.appIsInApplicationsFolder()}) catch null;
    }
    // app.getLoginItemSettings / setLoginItemSettings (Electron). macOS plist / Linux desktop (Win 후속).
    if (std.mem.eql(u8, cmd, "app_get_login_item_settings")) {
        const app_name: []const u8 = if (g_config) |c| c.app.name else "Suji";
        const open_at_login = cef.loginItemEnabled(app_name);
        // wasOpenedAtLogin 은 openAtLogin alias — 이번 실행이 실제 로그인으로 spawn 됐는지(launch
        // context)는 미추적(항목 파일 존재 여부만 본다, 정직 경계). openAsHidden/restoreState 미지원.
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"app_get_login_item_settings\",\"openAtLogin\":{},\"openAsHidden\":false,\"wasOpenedAtLogin\":{},\"wasOpenedAsHidden\":false,\"restoreState\":false}}", .{ open_at_login, open_at_login }) catch null;
    }
    if (std.mem.eql(u8, cmd, "app_set_login_item_settings")) {
        const app_name: []const u8 = if (g_config) |c| c.app.name else "Suji";
        const open_at_login = util.extractJsonBool(req_clean, "openAtLogin") orelse false;
        const ok = cef.setLoginItem(app_name, open_at_login);
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"app_set_login_item_settings\",\"success\":{}}}", .{ok}) catch null;
    }
    // app.setPath — Electron getPath 경로 런타임 오버라이드 (정적 테이블에 저장).
    if (std.mem.eql(u8, cmd, "app_set_path")) {
        const name = util.extractJsonString(req_clean, "name") orelse "";
        var p_buf: [1024]u8 = undefined;
        const path = unescapeField(req_clean, "path", &p_buf, true) orelse "";
        const ok = pathOverrideSet(name, path);
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"app_set_path\",\"success\":{}}}", .{ok}) catch null;
    }
    // app.getLocaleCountryCode — NSLocale.countryCode (ISO 3166, "US"/"KR").
    if (std.mem.eql(u8, cmd, "app_get_locale_country_code")) {
        var cc_buf: [16]u8 = undefined;
        const cc = cef.appGetLocaleCountryCode(&cc_buf);
        var esc_buf: [32]u8 = undefined;
        const esc_n = util.escapeJsonStrFull(cc, &esc_buf) orelse 0;
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"app_get_locale_country_code\",\"countryCode\":\"{s}\"}}", .{esc_buf[0..esc_n]}) catch null;
    }
    // app.getRecentDocuments — NSDocumentController.recentDocumentURLs (네이티브가 JSON 배열 빌드).
    if (std.mem.eql(u8, cmd, "app_get_recent_documents")) {
        var rd_buf: [8192]u8 = undefined;
        const arr = cef.appGetRecentDocuments(&rd_buf);
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"app_get_recent_documents\",\"documents\":{s}}}", .{arr}) catch null;
    }
    // app.getApplicationNameForProtocol — NSWorkspace 기본 핸들러 앱 이름.
    if (std.mem.eql(u8, cmd, "app_get_application_name_for_protocol")) {
        var u_buf: [2048]u8 = undefined;
        const url = unescapeField(req_clean, "url", &u_buf, true) orelse "";
        var name_buf: [512]u8 = undefined;
        const name = cef.appGetApplicationNameForProtocol(url, &name_buf);
        var esc_buf: [1024]u8 = undefined;
        const esc_n = util.escapeJsonStrFull(name, &esc_buf) orelse 0;
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"app_get_application_name_for_protocol\",\"name\":\"{s}\"}}", .{esc_buf[0..esc_n]}) catch null;
    }
    // app.getApplicationInfoForProtocol — {name, path, icon(base64 PNG)}.
    if (std.mem.eql(u8, cmd, "app_get_application_info_for_protocol")) {
        var u_buf: [2048]u8 = undefined;
        const url = unescapeField(req_clean, "url", &u_buf, true) orelse "";
        var bundle_buf: [1024]u8 = undefined;
        const bundle = cef.appGetApplicationBundleForProtocol(url, &bundle_buf);
        // name 은 appGetApplicationNameForProtocol 재사용(.app-strip 단일 출처 — basename 중복 제거).
        var name_buf2: [512]u8 = undefined;
        const name = cef.appGetApplicationNameForProtocol(url, &name_buf2);
        var icon_raw: [8 * 1024]u8 = undefined;
        const icon_bytes = if (bundle.len > 0) cef.nativeImageFileIconPng(bundle, &icon_raw) else icon_raw[0..0];
        var b64_buf: [12 * 1024]u8 = undefined;
        const enc_size = std.base64.standard.Encoder.calcSize(icon_bytes.len);
        const icon_b64 = if (enc_size <= b64_buf.len) std.base64.standard.Encoder.encode(b64_buf[0..enc_size], icon_bytes) else "";
        var name_esc: [512]u8 = undefined;
        var path_esc: [2048]u8 = undefined;
        const ne = util.escapeJsonStrFull(name, &name_esc) orelse 0;
        const pe = util.escapeJsonStrFull(bundle, &path_esc) orelse 0;
        // base64 알파벳은 JSON-safe — icon 추가 escape 불필요.
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"app_get_application_info_for_protocol\",\"name\":\"{s}\",\"path\":\"{s}\",\"icon\":\"{s}\"}}", .{ name_esc[0..ne], path_esc[0..pe], icon_b64 }) catch null;
    }
    if (std.mem.eql(u8, cmd, "native_image_get_size")) {
        const raw = util.extractJsonString(req_clean, "path") orelse "";
        var unesc_buf: [util.MAX_RESPONSE]u8 = undefined;
        const sz = blk: {
            const unesc_n = util.unescapeJsonStr(raw, &unesc_buf) orelse break :blk cef.NSSize{ .width = 0, .height = 0 };
            const p = unesc_buf[0..unesc_n];
            if (rendererPathFsGate(response_buf, "native_image_get_size", p)) |e| return e;
            break :blk cef.nativeImageGetSize(p);
        };
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"native_image_get_size\",\"width\":{d},\"height\":{d}}}",
            .{ sz.width, sz.height },
        ) catch null;
    }
    if (std.mem.eql(u8, cmd, "native_image_is_empty") or std.mem.eql(u8, cmd, "native_image_is_template")) {
        const is_template = std.mem.eql(u8, cmd, "native_image_is_template");
        const raw = util.extractJsonString(req_clean, "path") orelse "";
        var unesc_buf: [util.MAX_RESPONSE]u8 = undefined;
        const result = blk: {
            // 빈/디코드 실패 경로: isEmpty=true, isTemplate=false(Electron 동등).
            const unesc_n = util.unescapeJsonStr(raw, &unesc_buf) orelse break :blk !is_template;
            const p = unesc_buf[0..unesc_n];
            if (rendererPathFsGate(response_buf, cmd, p)) |e| return e;
            break :blk if (is_template) cef.nativeImageIsTemplate(p) else cef.nativeImageIsEmpty(p);
        };
        const field = if (is_template) "isTemplate" else "isEmpty";
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"{s}\",\"{s}\":{}}}",
            .{ cmd, field, result },
        ) catch null;
    }
    // nativeImage 인코딩 — clipboard image와 같은 16KB response 한도. raw ~8KB까지.
    if (std.mem.eql(u8, cmd, "native_image_to_png") or std.mem.eql(u8, cmd, "native_image_to_jpeg")) {
        const file_type: cef.NSBitmapImageFileType =
            if (std.mem.eql(u8, cmd, "native_image_to_jpeg")) .jpeg else .png;
        const raw_path = util.extractJsonString(req_clean, "path") orelse "";
        var path_buf: [util.MAX_RESPONSE]u8 = undefined;
        const path_n = util.unescapeJsonStr(raw_path, &path_buf) orelse return respondBase64Data(response_buf, cmd, &.{});
        if (rendererPathFsGate(response_buf, cmd, path_buf[0..path_n])) |e| return e;
        const quality = util.extractJsonFloat(req_clean, "quality") orelse 90;
        var raw_buf: [8 * 1024]u8 = undefined;
        const bytes = cef.nativeImageEncodeFromPath(path_buf[0..path_n], file_type, quality, &raw_buf);
        return respondBase64Data(response_buf, cmd, bytes);
    }
    // Electron app.getFileIcon(path) — 파일의 시스템 아이콘 PNG(base64). NSWorkspace
    // iconForFile(아이콘은 file type 기반이라 파일 내용 유출 아님 → fs gate 불요).
    if (std.mem.eql(u8, cmd, "app_get_file_icon")) {
        const raw_path = util.extractJsonString(req_clean, "path") orelse "";
        var path_buf: [util.MAX_RESPONSE]u8 = undefined;
        const path_n = util.unescapeJsonStr(raw_path, &path_buf) orelse return respondBase64Data(response_buf, cmd, &.{});
        var raw_buf: [8 * 1024]u8 = undefined;
        const bytes = cef.nativeImageFileIconPng(path_buf[0..path_n], &raw_buf);
        return respondBase64Data(response_buf, cmd, bytes);
    }
    // Electron app.relaunch() — quit 후 재시작 등록(flag). quit 은 별도 호출(app.quit/
    // exit). main 이 cef 메시지 루프 종료 후 g_should_relaunch 면 현재 argv 로 재실행.
    if (std.mem.eql(u8, cmd, "app_relaunch")) {
        g_should_relaunch = true;
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"app_relaunch\",\"success\":true}}", .{}) catch null;
    }
    if (std.mem.eql(u8, cmd, "app_exit")) {
        cef.quit();
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"app_exit\",\"success\":true}}", .{}) catch null;
    }
    if (std.mem.eql(u8, cmd, "session_clear_cookies")) {
        const ok = cef.sessionClearCookies();
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"session_clear_cookies\",\"success\":{}}}", .{ok}) catch null;
    }
    if (std.mem.eql(u8, cmd, "session_flush_store")) {
        const ok = cef.sessionFlushStore();
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"session_flush_store\",\"success\":{}}}", .{ok}) catch null;
    }
    // Electron session.setProxy — Chromium "proxy" pref 설정(mode/proxyRules/
    // proxyBypassRules/pacScript). 빈 mode → "direct"(프록시 해제).
    if (std.mem.eql(u8, cmd, "session_set_proxy")) {
        var mode_buf: [64]u8 = undefined;
        var rules_buf: [2048]u8 = undefined;
        var bypass_buf: [2048]u8 = undefined;
        var pac_buf: [2048]u8 = undefined;
        const mode_n = util.unescapeJsonStr(util.extractJsonString(req_clean, "mode") orelse "", &mode_buf) orelse 0;
        const rules_n = util.unescapeJsonStr(util.extractJsonString(req_clean, "proxyRules") orelse "", &rules_buf) orelse 0;
        const bypass_n = util.unescapeJsonStr(util.extractJsonString(req_clean, "proxyBypassRules") orelse "", &bypass_buf) orelse 0;
        const pac_n = util.unescapeJsonStr(util.extractJsonString(req_clean, "pacScript") orelse "", &pac_buf) orelse 0;
        const ok = cef.sessionSetProxy(mode_buf[0..mode_n], rules_buf[0..rules_n], bypass_buf[0..bypass_n], pac_buf[0..pac_n]);
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"session_set_proxy\",\"success\":{}}}", .{ok}) catch null;
    }
    // Electron session.setPermissionRequestHandler — enabled=true 면 네이티브 권한 prompt 를
    // hold 후 session:permission-request 이벤트로 위임(app 이 session_permission_response 응답).
    if (std.mem.eql(u8, cmd, "session_set_permission_handler")) {
        const enabled = util.extractJsonBool(req_clean, "enabled") orelse true;
        cef.permissionSetHandlerEnabled(enabled);
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"session_set_permission_handler\",\"success\":true}}", .{}) catch null;
    }
    // Electron session.setDownloadPath(path) — 빈 path 면 OS 저장 대화상자로 복귀.
    // 이후 다운로드는 무대화상자로 <path>/<filename> 에 저장 + session:will-download 발신.
    if (std.mem.eql(u8, cmd, "session_set_download_path")) {
        var path_buf: [4096]u8 = undefined;
        const raw = util.extractJsonString(req_clean, "path") orelse "";
        // unescape 실패(병적으로 긴 경로)는 success:false — 조용히 기존 경로를 지우지 않는다.
        // 빈 raw 는 unescape 가 0 을 반환(성공) → 의도적 해제로 처리.
        if (util.unescapeJsonStr(raw, &path_buf)) |path_n| {
            cef.setDownloadPath(path_buf[0..path_n]);
            return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"session_set_download_path\",\"success\":true}}", .{}) catch null;
        }
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"session_set_download_path\",\"success\":false}}", .{}) catch null;
    }
    // 권한 결정 응답 — permissionId 로 hold 콜백을 찾아 grant/deny. 없는 id → success:false.
    if (std.mem.eql(u8, cmd, "session_permission_response")) {
        const id_i = util.extractJsonInt(req_clean, "permissionId") orelse -1;
        const granted = util.extractJsonBool(req_clean, "granted") orelse false;
        const ok = if (id_i < 0) false else cef.permissionRespond(@intCast(id_i), granted);
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"session_permission_response\",\"success\":{}}}", .{ok}) catch null;
    }
    // getUserMedia(camera/mic) 권한 — session:media-access-request 이벤트에 대한 app 응답.
    // 같은 setPermissionRequestHandler 등록(g_have_handler) 흐름. audio/video 각각 grant.
    if (std.mem.eql(u8, cmd, "session_media_access_response")) {
        const id_i = util.extractJsonInt(req_clean, "mediaRequestId") orelse -1;
        const audio = util.extractJsonBool(req_clean, "audio") orelse false;
        const video = util.extractJsonBool(req_clean, "video") orelse false;
        const ok = if (id_i < 0) false else cef.mediaAccessRespond(@intCast(id_i), audio, video);
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"session_media_access_response\",\"success\":{}}}", .{ok}) catch null;
    }
    if (std.mem.eql(u8, cmd, "session_clear_storage_data")) {
        var origin_buf: [2048]u8 = undefined;
        var types_buf: [256]u8 = undefined;
        const origin = util.extractJsonString(req_clean, "origin") orelse "";
        const types_raw = util.extractJsonString(req_clean, "storageTypes") orelse "all";
        const origin_n = util.unescapeJsonStr(origin, &origin_buf) orelse 0;
        const types_n = util.unescapeJsonStr(types_raw, &types_buf) orelse 0;
        const ok = cef.sessionClearStorageData(origin_buf[0..origin_n], types_buf[0..types_n]);
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"session_clear_storage_data\",\"success\":{}}}", .{ok}) catch null;
    }
    if (std.mem.eql(u8, cmd, "session_set_cookie")) {
        var url_buf: [2048]u8 = undefined;
        var name_buf: [256]u8 = undefined;
        var value_buf: [4096]u8 = undefined;
        var domain_buf: [256]u8 = undefined;
        var path_buf: [256]u8 = undefined;
        const url = util.extractJsonString(req_clean, "url") orelse "";
        const name = util.extractJsonString(req_clean, "name") orelse "";
        const value = util.extractJsonString(req_clean, "value") orelse "";
        const domain = util.extractJsonString(req_clean, "domain") orelse "";
        const path = util.extractJsonString(req_clean, "path") orelse "";
        const url_n = util.unescapeJsonStr(url, &url_buf) orelse 0;
        const name_n = util.unescapeJsonStr(name, &name_buf) orelse 0;
        const value_n = util.unescapeJsonStr(value, &value_buf) orelse 0;
        const domain_n = util.unescapeJsonStr(domain, &domain_buf) orelse 0;
        const path_n = util.unescapeJsonStr(path, &path_buf) orelse 0;
        const secure = util.extractJsonBool(req_clean, "secure") orelse false;
        const httponly = util.extractJsonBool(req_clean, "httponly") orelse false;
        const expires = util.extractJsonFloat(req_clean, "expires") orelse 0;
        const ok = cef.sessionSetCookie(
            url_buf[0..url_n],
            name_buf[0..name_n],
            value_buf[0..value_n],
            domain_buf[0..domain_n],
            path_buf[0..path_n],
            secure,
            httponly,
            expires,
        );
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"session_set_cookie\",\"success\":{}}}", .{ok}) catch null;
    }
    if (std.mem.eql(u8, cmd, "session_remove_cookies")) {
        var url_buf: [2048]u8 = undefined;
        var name_buf: [256]u8 = undefined;
        const url = util.extractJsonString(req_clean, "url") orelse "";
        const name = util.extractJsonString(req_clean, "name") orelse "";
        const url_n = util.unescapeJsonStr(url, &url_buf) orelse 0;
        const name_n = util.unescapeJsonStr(name, &name_buf) orelse 0;
        const ok = cef.sessionRemoveCookies(url_buf[0..url_n], name_buf[0..name_n]);
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"session_remove_cookies\",\"success\":{}}}", .{ok}) catch null;
    }
    if (std.mem.eql(u8, cmd, "session_get_cookies")) {
        var url_buf: [2048]u8 = undefined;
        const url = util.extractJsonString(req_clean, "url") orelse "";
        const url_n = util.unescapeJsonStr(url, &url_buf) orelse 0;
        const include_http_only = util.extractJsonBool(req_clean, "includeHttpOnly") orelse true;
        const id = cef.sessionGetCookies(url_buf[0..url_n], include_http_only);
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"session_get_cookies\",\"success\":{},\"requestId\":{d}}}",
            .{ id != 0, id },
        ) catch null;
    }
    if (std.mem.eql(u8, cmd, "app_set_progress_bar")) {
        const progress = util.extractJsonFloat(req_clean, "progress") orelse -1;
        const ok = cef.appSetProgressBar(progress);
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"app_set_progress_bar\",\"success\":{}}}",
            .{ok},
        ) catch null;
    }
    if (std.mem.eql(u8, cmd, "app_get_locale")) {
        var raw_buf: [128]u8 = undefined;
        const locale = cef.appGetLocale(&raw_buf);
        var esc_buf: [256]u8 = undefined;
        const esc_n = util.escapeJsonStrFull(locale, &esc_buf) orelse return null;
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"app_get_locale\",\"locale\":\"{s}\"}}",
            .{esc_buf[0..esc_n]},
        ) catch null;
    }
    if (std.mem.eql(u8, cmd, "app_focus")) {
        const ok = cef.appFocus();
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"app_focus\",\"success\":{}}}", .{ok}) catch null;
    }
    if (std.mem.eql(u8, cmd, "app_hide")) {
        const ok = cef.appHide();
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"app_hide\",\"success\":{}}}", .{ok}) catch null;
    }
    if (std.mem.eql(u8, cmd, "app_show")) {
        const ok = cef.appShow();
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"app_show\",\"success\":{}}}", .{ok}) catch null;
    }
    if (std.mem.eql(u8, cmd, "app_is_active")) {
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"app_is_active\",\"active\":{}}}", .{cef.appIsActive()}) catch null;
    }
    if (std.mem.eql(u8, cmd, "app_is_hidden")) {
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"app_is_hidden\",\"hidden\":{}}}", .{cef.appIsHidden()}) catch null;
    }
    if (std.mem.eql(u8, cmd, "app_is_emoji_panel_supported")) {
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"app_is_emoji_panel_supported\",\"supported\":{}}}", .{cef.appIsEmojiPanelSupported()}) catch null;
    }
    // clipboard image — request/response buffer가 16KB라 raw PNG 한도 ~8KB. 더 큰 이미지는
    // 후속 (전용 binary IPC 또는 buffer 확장 필요). e2e용 1x1 transparent PNG (~67B)는 충분.
    if (std.mem.eql(u8, cmd, "clipboard_write_image")) {
        const b64_raw = util.extractJsonString(req_clean, "data") orelse "";
        var b64_buf: [util.MAX_RESPONSE]u8 = undefined;
        const b64_n = util.unescapeJsonStr(b64_raw, &b64_buf) orelse return null;

        var raw_buf: [8 * 1024]u8 = undefined;
        const decoded_size = std.base64.standard.Decoder.calcSizeForSlice(b64_buf[0..b64_n]) catch {
            return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"clipboard_write_image\",\"success\":false,\"error\":\"decode\"}}", .{}) catch null;
        };
        if (decoded_size > raw_buf.len) {
            return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"clipboard_write_image\",\"success\":false,\"error\":\"too_large\"}}", .{}) catch null;
        }
        std.base64.standard.Decoder.decode(raw_buf[0..decoded_size], b64_buf[0..b64_n]) catch {
            return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"clipboard_write_image\",\"success\":false,\"error\":\"decode\"}}", .{}) catch null;
        };
        const ok = cef.clipboardWriteImagePng(raw_buf[0..decoded_size]);
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"clipboard_write_image\",\"success\":{}}}", .{ok}) catch null;
    }
    if (std.mem.eql(u8, cmd, "clipboard_read_image")) {
        var raw_buf: [8 * 1024]u8 = undefined;
        const png_bytes = cef.clipboardReadImagePng(&raw_buf);
        return respondBase64Data(response_buf, cmd, png_bytes);
    }
    if (std.mem.eql(u8, cmd, "clipboard_write_tiff")) {
        const b64_raw = util.extractJsonString(req_clean, "data") orelse "";
        var b64_buf: [util.MAX_RESPONSE]u8 = undefined;
        const b64_n = util.unescapeJsonStr(b64_raw, &b64_buf) orelse return null;

        var raw_buf: [8 * 1024]u8 = undefined;
        const decoded_size = std.base64.standard.Decoder.calcSizeForSlice(b64_buf[0..b64_n]) catch {
            return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"clipboard_write_tiff\",\"success\":false,\"error\":\"decode\"}}", .{}) catch null;
        };
        if (decoded_size > raw_buf.len) {
            return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"clipboard_write_tiff\",\"success\":false,\"error\":\"too_large\"}}", .{}) catch null;
        }
        std.base64.standard.Decoder.decode(raw_buf[0..decoded_size], b64_buf[0..b64_n]) catch {
            return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"clipboard_write_tiff\",\"success\":false,\"error\":\"decode\"}}", .{}) catch null;
        };
        const ok = cef.clipboardWriteTiff(raw_buf[0..decoded_size]);
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"clipboard_write_tiff\",\"success\":{}}}", .{ok}) catch null;
    }
    if (std.mem.eql(u8, cmd, "clipboard_read_tiff")) {
        var raw_buf: [8 * 1024]u8 = undefined;
        const tiff_bytes = cef.clipboardReadTiff(&raw_buf);
        return respondBase64Data(response_buf, cmd, tiff_bytes);
    }
    if (std.mem.eql(u8, cmd, "clipboard_has")) {
        const fmt_str = util.extractJsonString(req_clean, "format") orelse "";
        var unesc_buf: [256]u8 = undefined;
        const has = if (util.unescapeJsonStr(fmt_str, &unesc_buf)) |unesc_n| blk: {
            // null-terminate for cstr.
            unesc_buf[unesc_n] = 0;
            const cstr: [*:0]const u8 = @ptrCast(&unesc_buf);
            break :blk cef.clipboardHas(cstr);
        } else false;
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"clipboard_has\",\"present\":{}}}",
            .{has},
        ) catch null;
    }
    if (std.mem.eql(u8, cmd, "clipboard_available_formats")) {
        var fmt_buf: [4096]u8 = undefined;
        const formats = cef.clipboardAvailableFormats(&fmt_buf);
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"clipboard_available_formats\",\"formats\":{s}}}",
            .{formats},
        ) catch null;
    }
    if (std.mem.eql(u8, cmd, "app_get_version")) {
        const version: []const u8 = if (g_config) |c| c.app.version else "0.0.0";
        var esc_buf: [128]u8 = undefined;
        const esc_n = util.escapeJsonStrFull(version, &esc_buf) orelse return null;
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"app_get_version\",\"version\":\"{s}\"}}",
            .{esc_buf[0..esc_n]},
        ) catch null;
    }
    if (std.mem.eql(u8, cmd, "auto_updater_check_update")) {
        return handleAutoUpdaterCheckUpdate(req_clean, response_buf);
    }
    if (std.mem.eql(u8, cmd, "auto_updater_verify_file")) {
        return handleAutoUpdaterVerifyFile(req_clean, response_buf);
    }
    if (std.mem.eql(u8, cmd, "auto_updater_download_artifact")) {
        return handleAutoUpdaterDownloadArtifact(req_clean, response_buf);
    }
    if (std.mem.eql(u8, cmd, "auto_updater_prepare_install")) {
        return handleAutoUpdaterPrepareInstall(req_clean, response_buf);
    }
    if (std.mem.eql(u8, cmd, "auto_updater_quit_and_install")) {
        return handleAutoUpdaterQuitAndInstall(req_clean, response_buf);
    }

    // app.requestUserAttention — dock bounce. critical=true는 활성화까지 반복, false는 1회.
    if (std.mem.eql(u8, cmd, "app_attention_request")) {
        const critical = util.extractJsonBool(req_clean, "critical") orelse true;
        const id = cef.appRequestUserAttention(critical);
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"app_attention_request\",\"id\":{d}}}",
            .{id},
        ) catch null;
    }
    // webRequest — URL glob blocklist (Electron `session.webRequest.onBeforeRequest({urls}, listener)`).
    if (std.mem.eql(u8, cmd, "web_request_set_blocked_urls")) {
        return handleWebRequestSetBlockedUrls(req_clean, response_buf);
    }
    if (std.mem.eql(u8, cmd, "web_request_set_listener_filter")) {
        return handleWebRequestSetListenerFilter(req_clean, response_buf);
    }
    if (std.mem.eql(u8, cmd, "web_request_resolve")) {
        const id_n = util.extractJsonInt(req_clean, "id") orelse 0;
        const cancel_request = util.extractJsonBool(req_clean, "cancel") orelse false;
        const ok = if (id_n > 0) cef.webRequestResolve(@intCast(id_n), cancel_request) else false;
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"web_request_resolve\",\"success\":{}}}",
            .{ok},
        ) catch null;
    }
    if (std.mem.eql(u8, cmd, "web_request_set_request_headers")) {
        return handleWebRequestSetRequestHeaders(req_clean, response_buf);
    }
    // Electron webContents.setWindowOpenHandler — action:"deny" 면 네이티브 popup 전역 차단.
    // 그 외/미지정="allow". popup 마다 web-contents:new-window 이벤트는 정책 무관 발신.
    if (std.mem.eql(u8, cmd, "web_contents_set_window_open_handler")) {
        const action = util.extractJsonString(req_clean, "action") orelse "allow";
        cef.setWindowOpenDeny(std.mem.eql(u8, action, "deny"));
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"web_contents_set_window_open_handler\",\"success\":true}}",
            .{},
        ) catch null;
    }

    if (std.mem.eql(u8, cmd, "app_attention_cancel")) {
        const id_n = util.extractJsonInt(req_clean, "id") orelse 0;
        const ok = cef.appCancelUserAttentionRequest(util.nonNegU32(id_n));
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"app_attention_cancel\",\"success\":{}}}",
            .{ok},
        ) catch null;
    }

    // Security-scoped bookmarks (Electron `app.startAccessingSecurityScopedResource`).
    if (std.mem.eql(u8, cmd, "security_scoped_bookmark_create")) {
        const raw = util.extractJsonString(req_clean, "path") orelse "";
        var path_buf: [util.MAX_RESPONSE]u8 = undefined;
        const path = if (util.unescapeJsonStr(raw, &path_buf)) |n| path_buf[0..n] else "";
        var bm_buf: [8192]u8 = undefined;
        const bm = cef.securityScopedBookmarkCreate(path, &bm_buf);
        if (bm.len == 0) return coreError(response_buf, "security_scoped_bookmark_create", "create");
        // base64 알파벳엔 JSON-special 없음 — escape 불필요.
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"security_scoped_bookmark_create\",\"success\":true,\"bookmark\":\"{s}\"}}",
            .{bm},
        ) catch null;
    }
    if (std.mem.eql(u8, cmd, "security_scoped_access_start")) {
        const bm = util.extractJsonString(req_clean, "bookmark") orelse "";
        var path_buf: [2048]u8 = undefined;
        const acc = cef.securityScopedAccessStart(bm, &path_buf);
        if (acc.id == 0) return coreError(response_buf, "security_scoped_access_start", "resolve");
        var esc_buf: [4096]u8 = undefined;
        const esc_n = util.escapeJsonStrFull(acc.path, &esc_buf) orelse return coreError(response_buf, "security_scoped_access_start", "encode");
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"security_scoped_access_start\",\"success\":true,\"id\":{d},\"path\":\"{s}\",\"stale\":{}}}",
            .{ acc.id, esc_buf[0..esc_n], acc.stale },
        ) catch null;
    }
    if (std.mem.eql(u8, cmd, "security_scoped_access_stop")) {
        const id_n = util.extractJsonInt(req_clean, "id") orelse 0;
        const ok = if (id_n > 0) cef.securityScopedAccessStop(util.nonNegU32(id_n)) else false;
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"security_scoped_access_stop\",\"success\":{}}}",
            .{ok},
        ) catch null;
    }

    // safeStorage — OS secure store. service/account/value 셋 다 unescape 필요 (wire JSON).
    if (std.mem.eql(u8, cmd, "safe_storage_set")) {
        const svc_raw = util.extractJsonString(req_clean, "service") orelse "";
        const acc_raw = util.extractJsonString(req_clean, "account") orelse "";
        const val_raw = util.extractJsonString(req_clean, "value") orelse "";
        var svc_buf: [256]u8 = undefined;
        var acc_buf: [256]u8 = undefined;
        var val_buf: [4096]u8 = undefined;
        const svc_n = util.unescapeJsonStr(svc_raw, &svc_buf) orelse return coreError(response_buf, "safe_storage_set", "service");
        const acc_n = util.unescapeJsonStr(acc_raw, &acc_buf) orelse return coreError(response_buf, "safe_storage_set", "account");
        const val_n = util.unescapeJsonStr(val_raw, &val_buf) orelse return coreError(response_buf, "safe_storage_set", "value");
        const ok = cef.safeStorageSet(svc_buf[0..svc_n], acc_buf[0..acc_n], val_buf[0..val_n]);
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"safe_storage_set\",\"success\":{}}}", .{ok}) catch null;
    }
    if (std.mem.eql(u8, cmd, "safe_storage_get")) {
        const svc_raw = util.extractJsonString(req_clean, "service") orelse "";
        const acc_raw = util.extractJsonString(req_clean, "account") orelse "";
        var svc_buf: [256]u8 = undefined;
        var acc_buf: [256]u8 = undefined;
        const svc_n = util.unescapeJsonStr(svc_raw, &svc_buf) orelse return coreError(response_buf, "safe_storage_get", "service");
        const acc_n = util.unescapeJsonStr(acc_raw, &acc_buf) orelse return coreError(response_buf, "safe_storage_get", "account");
        var val_buf: [4096]u8 = undefined;
        const val = cef.safeStorageGet(svc_buf[0..svc_n], acc_buf[0..acc_n], &val_buf);
        var esc_buf: [8192]u8 = undefined;
        const esc_n = util.escapeJsonStrFull(val, &esc_buf) orelse return coreError(response_buf, "safe_storage_get", "encode");
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"safe_storage_get\",\"value\":\"{s}\"}}",
            .{esc_buf[0..esc_n]},
        ) catch null;
    }
    if (std.mem.eql(u8, cmd, "safe_storage_delete")) {
        const svc_raw = util.extractJsonString(req_clean, "service") orelse "";
        const acc_raw = util.extractJsonString(req_clean, "account") orelse "";
        var svc_buf: [256]u8 = undefined;
        var acc_buf: [256]u8 = undefined;
        const svc_n = util.unescapeJsonStr(svc_raw, &svc_buf) orelse return coreError(response_buf, "safe_storage_delete", "service");
        const acc_n = util.unescapeJsonStr(acc_raw, &acc_buf) orelse return coreError(response_buf, "safe_storage_delete", "account");
        const ok = cef.safeStorageDelete(svc_buf[0..svc_n], acc_buf[0..acc_n]);
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"safe_storage_delete\",\"success\":{}}}", .{ok}) catch null;
    }

    if (std.mem.eql(u8, cmd, "fs_read_file")) {
        return handleFsReadFile(req_clean, response_buf);
    }
    if (std.mem.eql(u8, cmd, "fs_write_file")) {
        return handleFsWriteFile(req_clean, response_buf);
    }
    if (std.mem.eql(u8, cmd, "fs_stat")) {
        return handleFsStat(req_clean, response_buf);
    }
    if (std.mem.eql(u8, cmd, "fs_mkdir")) {
        return handleFsMkdir(req_clean, response_buf);
    }
    if (std.mem.eql(u8, cmd, "fs_readdir")) {
        return handleFsReadDir(req_clean, response_buf);
    }
    if (std.mem.eql(u8, cmd, "fs_rm")) {
        return handleFsRm(req_clean, response_buf);
    }

    // Dialog API — NSAlert / NSOpenPanel / NSSavePanel.
    if (std.mem.eql(u8, cmd, "dialog_show_message_box")) {
        return handleDialogShowMessageBox(req_clean, response_buf);
    }
    if (std.mem.eql(u8, cmd, "dialog_show_error_box")) {
        return handleDialogShowErrorBox(req_clean, response_buf);
    }
    if (std.mem.eql(u8, cmd, "dialog_show_open_dialog")) {
        return handleDialogShowOpenDialog(req_clean, response_buf);
    }
    if (std.mem.eql(u8, cmd, "dialog_show_save_dialog")) {
        return handleDialogShowSaveDialog(req_clean, response_buf);
    }

    // Tray API — NSStatusItem / GTK StatusIcon / Shell_NotifyIconW.
    if (std.mem.eql(u8, cmd, "tray_create")) {
        const title = util.extractJsonString(req_clean, "title") orelse "";
        const tooltip = util.extractJsonString(req_clean, "tooltip") orelse "";
        const icon_path_raw = util.extractJsonString(req_clean, "iconPath") orelse "";
        var t_buf: [256]u8 = undefined;
        var tt_buf: [512]u8 = undefined;
        var icon_path_buf: [2048]u8 = undefined;
        const t_n = util.unescapeJsonStr(title, &t_buf) orelse 0;
        const tt_n = util.unescapeJsonStr(tooltip, &tt_buf) orelse 0;
        const icon_path_n = util.unescapeJsonStr(icon_path_raw, &icon_path_buf) orelse 0;
        const icon_path = icon_path_buf[0..icon_path_n];
        if (icon_path.len > 0) {
            if (rendererPathFsGate(response_buf, "tray_create", icon_path)) |e| return e;
        }
        const id = cef.createTray(t_buf[0..t_n], tt_buf[0..tt_n], icon_path);
        const result = std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"tray_create\",\"trayId\":{d}}}",
            .{id},
        ) catch return null;
        return result;
    }
    if (std.mem.eql(u8, cmd, "tray_set_title")) {
        const tray_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "trayId") orelse return null);
        const title = util.extractJsonString(req_clean, "title") orelse "";
        var t_buf: [512]u8 = undefined;
        const t_n = util.unescapeJsonStr(title, &t_buf) orelse 0;
        const ok = cef.setTrayTitle(tray_id, t_buf[0..t_n]);
        const result = std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"tray_set_title\",\"success\":{}}}", .{ok}) catch return null;
        return result;
    }
    if (std.mem.eql(u8, cmd, "tray_set_tooltip")) {
        const tray_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "trayId") orelse return null);
        const tooltip = util.extractJsonString(req_clean, "tooltip") orelse "";
        var t_buf: [1024]u8 = undefined;
        const t_n = util.unescapeJsonStr(tooltip, &t_buf) orelse 0;
        const ok = cef.setTrayTooltip(tray_id, t_buf[0..t_n]);
        const result = std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"tray_set_tooltip\",\"success\":{}}}", .{ok}) catch return null;
        return result;
    }
    if (std.mem.eql(u8, cmd, "tray_get_bounds")) {
        const tray_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "trayId") orelse return null);
        const r = cef.trayGetBounds(tray_id);
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"tray_get_bounds\",\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d}}}",
            .{ r.x, r.y, r.width, r.height },
        ) catch null;
    }
    if (std.mem.eql(u8, cmd, "tray_set_menu")) {
        return handleTraySetMenu(req_clean, response_buf);
    }
    if (std.mem.eql(u8, cmd, "tray_destroy")) {
        const tray_id: u32 = util.nonNegU32(util.extractJsonInt(req_clean, "trayId") orelse return null);
        const ok = cef.destroyTray(tray_id);
        const result = std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"tray_destroy\",\"success\":{}}}", .{ok}) catch return null;
        return result;
    }

    // Application Menu API — native app menu / popup customization.
    if (std.mem.eql(u8, cmd, "menu_set_application_menu")) {
        return handleMenuSetApplicationMenu(req_clean, response_buf);
    }
    if (std.mem.eql(u8, cmd, "menu_reset_application_menu")) {
        const ok = cef.resetApplicationMenu();
        if (ok) g_app_menu_len = 0; // 스냅샷 클리어(기본 메뉴로 복귀)
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"menu_reset_application_menu\",\"success\":{}}}", .{ok}) catch null;
    }
    if (std.mem.eql(u8, cmd, "menu_get_application_menu")) {
        return handleMenuGetApplicationMenu(response_buf);
    }
    if (std.mem.eql(u8, cmd, "menu_send_action_to_first_responder")) {
        const action = util.extractJsonString(req_clean, "action") orelse "";
        const ok = cef.sendActionToFirstResponder(action);
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"menu_send_action_to_first_responder\",\"success\":{}}}", .{ok}) catch null;
    }
    if (std.mem.eql(u8, cmd, "menu_popup")) {
        return handleMenuPopup(req_clean, response_buf);
    }

    // Global shortcut API — Carbon Hot Key (macOS only).
    if (std.mem.eql(u8, cmd, "global_shortcut_register")) {
        return handleGlobalShortcutRegister(req_clean, response_buf);
    }
    if (std.mem.eql(u8, cmd, "global_shortcut_unregister")) {
        return handleGlobalShortcutUnregister(req_clean, response_buf);
    }
    if (std.mem.eql(u8, cmd, "global_shortcut_unregister_all")) {
        cef.globalShortcutUnregisterAll();
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"global_shortcut_unregister_all\",\"success\":true}}", .{}) catch null;
    }
    if (std.mem.eql(u8, cmd, "global_shortcut_is_registered")) {
        return handleGlobalShortcutIsRegistered(req_clean, response_buf);
    }
    if (std.mem.eql(u8, cmd, "global_shortcut_set_suspended")) {
        const suspended = util.extractJsonBool(req_clean, "suspended") orelse false;
        cef.globalShortcutSetSuspended(suspended);
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"global_shortcut_set_suspended\",\"success\":true}}", .{}) catch null;
    }
    if (std.mem.eql(u8, cmd, "global_shortcut_is_suspended")) {
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"global_shortcut_is_suspended\",\"suspended\":{}}}", .{cef.globalShortcutIsSuspended()}) catch null;
    }

    // Notification API — UNUserNotificationCenter (macOS only).
    if (std.mem.eql(u8, cmd, "notification_is_supported")) {
        const supported = cef.notificationIsSupported();
        const result = std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"notification_is_supported\",\"supported\":{}}}", .{supported}) catch return null;
        return result;
    }
    if (std.mem.eql(u8, cmd, "notification_request_permission")) {
        const granted = cef.notificationRequestPermission();
        const result = std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"notification_request_permission\",\"granted\":{}}}", .{granted}) catch return null;
        return result;
    }
    if (std.mem.eql(u8, cmd, "notification_show")) {
        const title_raw = util.extractJsonString(req_clean, "title") orelse "";
        const body_raw = util.extractJsonString(req_clean, "body") orelse "";
        const silent = util.extractJsonBool(req_clean, "silent") orelse false;
        var t_buf: [4096]u8 = undefined;
        var b_buf: [4096]u8 = undefined;
        var g_buf: [256]u8 = undefined;
        const t_n = util.unescapeJsonStr(title_raw, &t_buf) orelse 0;
        const b_n = util.unescapeJsonStr(body_raw, &b_buf) orelse 0;
        const g_n = util.unescapeJsonStr(util.extractJsonString(req_clean, "groupId") orelse "", &g_buf) orelse 0;

        // caller 가 id 를 주면 사용(NotificationOptions.id), 없으면 자동 생성. id 한도는 64
        // byte(네이티브 notificationShow id_buf 와 동형) — 초과 시 graceful 하게 자동 생성으로
        // 폴백(응답 notificationId 가 generated 라 caller 가 그 값으로 close — uuid 등 정상 id 는 안전).
        var id_buf: [64]u8 = undefined;
        const id_str = blk: {
            const id_override = util.extractJsonString(req_clean, "id") orelse "";
            if (id_override.len > 0) {
                if (util.unescapeJsonStr(id_override, &id_buf)) |n| break :blk id_buf[0..n];
            }
            break :blk std.fmt.bufPrint(&id_buf, "suji-notif-{d}", .{nextNotificationId()}) catch return null;
        };

        const ok = cef.notificationShow(id_str, t_buf[0..t_n], b_buf[0..b_n], silent, g_buf[0..g_n]);
        const result = std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"notification_show\",\"notificationId\":\"{s}\",\"success\":{}}}",
            .{ id_str, ok },
        ) catch return null;
        return result;
    }
    if (std.mem.eql(u8, cmd, "notification_close")) {
        const id_raw = util.extractJsonString(req_clean, "notificationId") orelse "";
        var id_buf: [128]u8 = undefined;
        const id_n = util.unescapeJsonStr(id_raw, &id_buf) orelse 0;
        const ok = cef.notificationClose(id_buf[0..id_n]);
        const result = std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"notification_close\",\"success\":{}}}", .{ok}) catch return null;
        return result;
    }
    // Electron Notification.removeAll() — 표시/대기 모든 알림 제거(macOS 실동작).
    if (std.mem.eql(u8, cmd, "notification_remove_all")) {
        const ok = cef.notificationRemoveAll();
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"notification_remove_all\",\"success\":{}}}", .{ok}) catch null;
    }
    // Electron Notification.removeGroup(groupId) — threadIdentifier 일치 알림 제거(macOS).
    if (std.mem.eql(u8, cmd, "notification_remove_group")) {
        var g_buf: [256]u8 = undefined;
        const g_n = util.unescapeJsonStr(util.extractJsonString(req_clean, "groupId") orelse "", &g_buf) orelse 0;
        const ok = cef.notificationRemoveGroup(g_buf[0..g_n]);
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"notification_remove_group\",\"success\":{}}}", .{ok}) catch null;
    }

    if (std.mem.eql(u8, cmd, "core_info")) {
        var out_pos: usize = 0;
        const out = response_buf;
        out_pos += (std.fmt.bufPrint(out[out_pos..], "{{\"from\":\"zig-core\",\"backends\":[", .{}) catch return null).len;
        var it = registry.backends.iterator();
        var first = true;
        while (it.next()) |entry| {
            if (!first) out_pos += (std.fmt.bufPrint(out[out_pos..], ",", .{}) catch break).len;
            out_pos += (std.fmt.bufPrint(out[out_pos..], "\"{s}\"", .{entry.key_ptr.*}) catch break).len;
            first = false;
        }
        out_pos += (std.fmt.bufPrint(out[out_pos..], "]}}", .{}) catch return null).len;
        return out[0..out_pos];
    }

    // typo / version mismatch 진단용 — coreError가 cmd echo 자동.
    return coreError(response_buf, cmd, "unknown_cmd");
}

// ============================================
// Dialog handlers — std.json으로 옵션 파싱 후 cef.zig 호출
// ============================================

/// std.json parse용 stack-FBA arena. 디알로그 옵션 한 회 파싱에 충분 (32KB).
const DIALOG_PARSE_ARENA: usize = 32768;

/// JSON 형식: {"type","title","message","detail","buttons":[],"defaultId","cancelId",
///             "checkboxLabel","checkboxChecked","windowId"}
/// windowId 지정 시 sheet, 없으면 free-floating.
const MessageBoxJson = struct {
    type: []const u8 = "none",
    title: []const u8 = "",
    message: []const u8 = "",
    detail: []const u8 = "",
    buttons: []const []const u8 = &.{},
    defaultId: ?usize = null,
    cancelId: ?usize = null,
    checkboxLabel: []const u8 = "",
    checkboxChecked: bool = false,
    icon: []const u8 = "",
    windowId: ?u32 = null,
};

const FileFilterJson = struct {
    name: []const u8 = "",
    extensions: []const []const u8 = &.{},
};

const OpenDialogJson = struct {
    title: []const u8 = "",
    defaultPath: []const u8 = "",
    buttonLabel: []const u8 = "",
    message: []const u8 = "",
    filters: []const FileFilterJson = &.{},
    properties: []const []const u8 = &.{},
    windowId: ?u32 = null,
};

const SaveDialogJson = struct {
    title: []const u8 = "",
    defaultPath: []const u8 = "",
    buttonLabel: []const u8 = "",
    message: []const u8 = "",
    nameFieldLabel: []const u8 = "",
    showsTagField: bool = false,
    filters: []const FileFilterJson = &.{},
    properties: []const []const u8 = &.{},
    windowId: ?u32 = null,
};

const ErrorBoxJson = struct {
    title: []const u8 = "",
    content: []const u8 = "",
};

/// std.json properties 배열 → 부울 플래그 테이블. Electron OpenDialog properties:
///   openFile / openDirectory / multiSelections / showHiddenFiles / createDirectory
///   noResolveAliases / treatPackageAsDirectory
fn hasProp(props: []const []const u8, name: []const u8) bool {
    for (props) |p| {
        if (std.mem.eql(u8, p, name)) return true;
    }
    return false;
}

/// macOS sheet용 windowId(u32 WM id) → NSWindow 포인터.
/// Linux/Windows는 native sheet attach가 없어 null → free-floating fallback.
/// macOS에서 stale/잘못된 windowId가 무성하게 묻히지 않도록 명시 lookup 실패는 warn 로그.
fn dialogParentNSWindow(window_id: ?u32) ?*anyopaque {
    const id = window_id orelse return null;
    if (!comptime (builtin.os.tag == .macos)) return null;
    const wm = window_mod.WindowManager.global orelse return null;
    const win = wm.get(id) orelse {
        std.log.warn("dialog: windowId={d} not found in WindowManager — sheet fallback to free-floating", .{id});
        return null;
    };
    const ns_win = cef.nsWindowForBrowserHandle(win.native_handle);
    if (ns_win == null) {
        std.log.warn("dialog: windowId={d} (browser handle={d}) has no NSWindow — sheet fallback to free-floating", .{ id, win.native_handle });
    }
    return ns_win;
}

fn parseStyleString(s: []const u8) cef.MessageBoxStyle {
    if (std.mem.eql(u8, s, "info")) return .info;
    if (std.mem.eql(u8, s, "warning")) return .warning;
    if (std.mem.eql(u8, s, "error")) return .err;
    if (std.mem.eql(u8, s, "question")) return .question;
    return .none;
}

/// FileFilterJson [] → cef.FileFilter [] 변환. arena 위에 alloc.
fn convertFilters(arena: std.mem.Allocator, src: []const FileFilterJson) ![]cef.FileFilter {
    var result = try arena.alloc(cef.FileFilter, src.len);
    for (src, 0..) |f, i| {
        result[i] = .{ .name = f.name, .extensions = f.extensions };
    }
    return result;
}

fn handleDialogShowMessageBox(req_clean: []const u8, response_buf: []u8) ?[]const u8 {
    var arena_buf: [DIALOG_PARSE_ARENA]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arena_buf);
    const arena = fba.allocator();

    const parsed = std.json.parseFromSlice(MessageBoxJson, arena, req_clean, .{
        .ignore_unknown_fields = true,
    }) catch {
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"dialog_show_message_box\",\"response\":0,\"checkboxChecked\":false,\"error\":\"parse\"}}",
            .{},
        ) catch null;
    };
    defer parsed.deinit();
    const opts = parsed.value;

    // icon 경로 fs gate (이미지 로드 = 렌더러-제어 경로 읽기 sink — tray_create.iconPath 동일).
    if (opts.icon.len > 0) {
        if (rendererPathFsGate(response_buf, "dialog_show_message_box", opts.icon)) |e| return e;
    }
    const r = cef.showMessageBox(.{
        .style = parseStyleString(opts.type),
        .title = opts.title,
        .message = opts.message,
        .detail = opts.detail,
        .buttons = opts.buttons,
        .default_id = opts.defaultId,
        .cancel_id = opts.cancelId,
        .checkbox_label = opts.checkboxLabel,
        .checkbox_checked = opts.checkboxChecked,
        .icon = opts.icon,
        .parent_window = dialogParentNSWindow(opts.windowId),
    });

    return std.fmt.bufPrint(
        response_buf,
        "{{\"from\":\"zig-core\",\"cmd\":\"dialog_show_message_box\",\"response\":{d},\"checkboxChecked\":{}}}",
        .{ r.response, r.checkbox_checked },
    ) catch null;
}

fn handleDialogShowErrorBox(req_clean: []const u8, response_buf: []u8) ?[]const u8 {
    var arena_buf: [DIALOG_PARSE_ARENA]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arena_buf);
    const arena = fba.allocator();

    const parsed = std.json.parseFromSlice(ErrorBoxJson, arena, req_clean, .{
        .ignore_unknown_fields = true,
    }) catch return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"dialog_show_error_box\",\"success\":false}}", .{}) catch null;
    defer parsed.deinit();

    cef.showErrorBox(parsed.value.title, parsed.value.content);

    return std.fmt.bufPrint(
        response_buf,
        "{{\"from\":\"zig-core\",\"cmd\":\"dialog_show_error_box\",\"success\":true}}",
        .{},
    ) catch null;
}

/// `__core__` cmd handler 공용 에러 응답. 모든 핸들러가 같은 wire 포맷 사용.
fn coreError(response_buf: []u8, cmd: []const u8, err: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"{s}\",\"success\":false,\"error\":\"{s}\"}}", .{ cmd, err }) catch null;
}

fn unescapeField(
    req_clean: []const u8,
    key: []const u8,
    dst: []u8,
    required: bool,
) ?[]const u8 {
    const raw = util.extractJsonString(req_clean, key) orelse {
        if (required) return null;
        return "";
    };
    const n = util.unescapeJsonStr(raw, dst) orelse return null;
    return dst[0..n];
}

fn handleAutoUpdaterCheckUpdate(req_clean: []const u8, response_buf: []u8) ?[]const u8 {
    var current_buf: [128]u8 = undefined;
    var latest_buf: [128]u8 = undefined;
    var url_buf: [4096]u8 = undefined;
    var sha_buf: [128]u8 = undefined;
    var notes_buf: [1024]u8 = undefined;
    var pub_buf: [128]u8 = undefined;

    const current_req = unescapeField(req_clean, "currentVersion", &current_buf, false) orelse
        return coreError(response_buf, "auto_updater_check_update", "current_version");
    const current = if (current_req.len > 0) current_req else if (g_config) |c| c.app.version else "0.0.0";

    const latest_raw = util.extractJsonString(req_clean, "latestVersion") orelse
        util.extractJsonString(req_clean, "version") orelse
        return coreError(response_buf, "auto_updater_check_update", "missing_latest_version");
    const latest_n = util.unescapeJsonStr(latest_raw, &latest_buf) orelse
        return coreError(response_buf, "auto_updater_check_update", "latest_version");
    const latest = latest_buf[0..latest_n];

    const url = unescapeField(req_clean, "url", &url_buf, true) orelse
        return coreError(response_buf, "auto_updater_check_update", "url");
    const sha = unescapeField(req_clean, "sha256", &sha_buf, false) orelse
        return coreError(response_buf, "auto_updater_check_update", "sha256");
    const notes = unescapeField(req_clean, "notes", &notes_buf, false) orelse
        return coreError(response_buf, "auto_updater_check_update", "notes");
    const pub_date = blk: {
        if (util.extractJsonString(req_clean, "pubDate")) |raw| {
            const n = util.unescapeJsonStr(raw, &pub_buf) orelse
                return coreError(response_buf, "auto_updater_check_update", "pub_date");
            break :blk pub_buf[0..n];
        }
        if (util.extractJsonString(req_clean, "pub_date")) |raw| {
            const n = util.unescapeJsonStr(raw, &pub_buf) orelse
                return coreError(response_buf, "auto_updater_check_update", "pub_date");
            break :blk pub_buf[0..n];
        }
        break :blk "";
    };

    const result = auto_updater.checkUpdate(current, latest, url, sha, notes, pub_date) catch |err| {
        return coreError(response_buf, "auto_updater_check_update", auto_updater.errorCode(err));
    };

    var current_esc: [256]u8 = undefined;
    var version_esc: [256]u8 = undefined;
    var url_esc: [8192]u8 = undefined;
    var sha_esc: [128]u8 = undefined;
    var notes_esc: [6144]u8 = undefined;
    var pub_esc: [256]u8 = undefined;
    const current_n = util.escapeJsonStrFull(result.current_version, &current_esc) orelse
        return coreError(response_buf, "auto_updater_check_update", "encode");
    const version_n = util.escapeJsonStrFull(result.version, &version_esc) orelse
        return coreError(response_buf, "auto_updater_check_update", "encode");
    const url_n = util.escapeJsonStrFull(result.url, &url_esc) orelse
        return coreError(response_buf, "auto_updater_check_update", "encode");
    const sha_n = util.escapeJsonStrFull(result.sha256, &sha_esc) orelse
        return coreError(response_buf, "auto_updater_check_update", "encode");
    const notes_n = util.escapeJsonStrFull(result.notes, &notes_esc) orelse
        return coreError(response_buf, "auto_updater_check_update", "encode");
    const pub_n = util.escapeJsonStrFull(result.pub_date, &pub_esc) orelse
        return coreError(response_buf, "auto_updater_check_update", "encode");

    return std.fmt.bufPrint(
        response_buf,
        "{{\"from\":\"zig-core\",\"cmd\":\"auto_updater_check_update\",\"success\":true,\"updateAvailable\":{},\"currentVersion\":\"{s}\",\"version\":\"{s}\",\"url\":\"{s}\",\"sha256\":\"{s}\",\"notes\":\"{s}\",\"pubDate\":\"{s}\"}}",
        .{
            result.update_available,
            current_esc[0..current_n],
            version_esc[0..version_n],
            url_esc[0..url_n],
            sha_esc[0..sha_n],
            notes_esc[0..notes_n],
            pub_esc[0..pub_n],
        },
    ) catch null;
}

fn handleAutoUpdaterVerifyFile(req_clean: []const u8, response_buf: []u8) ?[]const u8 {
    var path_buf: [FS_MAX_PATH_BYTES]u8 = undefined;
    var sha_buf: [128]u8 = undefined;
    const path = unescapeField(req_clean, "path", &path_buf, true) orelse
        return coreError(response_buf, "auto_updater_verify_file", "path");
    if (!g_in_backend_invoke) {
        if (fsSandboxCheck(response_buf, "auto_updater_verify_file", path)) |err| return err;
    }
    const expected = unescapeField(req_clean, "sha256", &sha_buf, true) orelse
        return coreError(response_buf, "auto_updater_verify_file", "sha256");
    if (!auto_updater.isValidSha256Hex(expected) or expected.len == 0) {
        return coreError(response_buf, "auto_updater_verify_file", "invalid_sha256");
    }

    var actual_buf: [64]u8 = undefined;
    const actual = auto_updater.sha256File(runtime.io, path, &actual_buf) catch
        return coreError(response_buf, "auto_updater_verify_file", "read");
    const ok = auto_updater.sha256Equal(actual, expected);
    return std.fmt.bufPrint(
        response_buf,
        "{{\"from\":\"zig-core\",\"cmd\":\"auto_updater_verify_file\",\"success\":{},\"actualSha256\":\"{s}\"}}",
        .{ ok, actual },
    ) catch null;
}

fn handleAutoUpdaterDownloadArtifact(req_clean: []const u8, response_buf: []u8) ?[]const u8 {
    var url_buf: [4096]u8 = undefined;
    var path_buf: [FS_MAX_PATH_BYTES]u8 = undefined;
    var sha_buf: [128]u8 = undefined;
    const url = unescapeField(req_clean, "url", &url_buf, true) orelse
        return coreError(response_buf, "auto_updater_download_artifact", "url");
    const path = blk: {
        if (unescapeField(req_clean, "path", &path_buf, false)) |p| {
            if (p.len > 0) break :blk p;
        } else return coreError(response_buf, "auto_updater_download_artifact", "path");
        if (unescapeField(req_clean, "destination", &path_buf, false)) |p| {
            if (p.len > 0) break :blk p;
        } else return coreError(response_buf, "auto_updater_download_artifact", "path");
        return coreError(response_buf, "auto_updater_download_artifact", "path");
    };
    if (!g_in_backend_invoke) {
        if (std.mem.startsWith(u8, url, "file://")) {
            var source_path_buf: [FS_MAX_PATH_BYTES]u8 = undefined;
            const source_path = auto_updater.filePathFromUrl(url, &source_path_buf) catch
                return coreError(response_buf, "auto_updater_download_artifact", "invalid_url");
            if (fsSandboxCheck(response_buf, "auto_updater_download_artifact", source_path)) |err| return err;
        }
        if (fsSandboxCheck(response_buf, "auto_updater_download_artifact", path)) |err| return err;
    }
    const expected = unescapeField(req_clean, "sha256", &sha_buf, false) orelse
        return coreError(response_buf, "auto_updater_download_artifact", "sha256");

    var temp_path_buf: [FS_MAX_PATH_BYTES + 32]u8 = undefined;
    var actual_buf: [64]u8 = undefined;
    const result = auto_updater.downloadArtifact(
        runtime.gpa,
        runtime.io,
        url,
        path,
        expected,
        &temp_path_buf,
        &actual_buf,
    ) catch |err| {
        return coreError(response_buf, "auto_updater_download_artifact", auto_updater.errorCode(err));
    };

    var path_esc: [8192]u8 = undefined;
    var sha_esc: [128]u8 = undefined;
    const path_n = util.escapeJsonStrFull(result.path, &path_esc) orelse
        return coreError(response_buf, "auto_updater_download_artifact", "encode");
    const sha_n = util.escapeJsonStrFull(result.sha256, &sha_esc) orelse
        return coreError(response_buf, "auto_updater_download_artifact", "encode");
    return std.fmt.bufPrint(
        response_buf,
        "{{\"from\":\"zig-core\",\"cmd\":\"auto_updater_download_artifact\",\"success\":{},\"path\":\"{s}\",\"sha256\":\"{s}\",\"size\":{d}}}",
        .{ result.success, path_esc[0..path_n], sha_esc[0..sha_n], result.size },
    ) catch null;
}

fn handleAutoUpdaterPrepareInstall(req_clean: []const u8, response_buf: []u8) ?[]const u8 {
    if (builtin.os.tag == .windows) {
        return coreError(response_buf, "auto_updater_prepare_install", "unsupported_platform");
    }

    var artifact_buf: [FS_MAX_PATH_BYTES]u8 = undefined;
    var stage_buf: [FS_MAX_PATH_BYTES + 64]u8 = undefined;
    var target_buf: [FS_MAX_PATH_BYTES]u8 = undefined;
    var format_buf: [32]u8 = undefined;
    var sha_buf: [128]u8 = undefined;

    const artifact = blk: {
        if (unescapeField(req_clean, "path", &artifact_buf, false)) |p| {
            if (p.len > 0) break :blk p;
        } else return coreError(response_buf, "auto_updater_prepare_install", "path");
        if (unescapeField(req_clean, "artifact", &artifact_buf, false)) |p| {
            if (p.len > 0) break :blk p;
        } else return coreError(response_buf, "auto_updater_prepare_install", "path");
        return coreError(response_buf, "auto_updater_prepare_install", "path");
    };
    const format_raw = unescapeField(req_clean, "format", &format_buf, false) orelse
        return coreError(response_buf, "auto_updater_prepare_install", "format");
    const format = auto_updater.parseInstallFormat(format_raw, artifact) catch |err|
        return coreError(response_buf, "auto_updater_prepare_install", auto_updater.errorCode(err));

    const explicit_stage = unescapeField(req_clean, "stageDir", &stage_buf, false) orelse
        return coreError(response_buf, "auto_updater_prepare_install", "stage_dir");
    const stage_dir = if (explicit_stage.len > 0)
        explicit_stage
    else
        (auto_updater.defaultPrepareInstallStageDir(artifact, &stage_buf) catch |err|
            return coreError(response_buf, "auto_updater_prepare_install", auto_updater.errorCode(err)));

    const explicit_target = unescapeField(req_clean, "target", &target_buf, false) orelse
        return coreError(response_buf, "auto_updater_prepare_install", "target");
    const target = if (format == .deb)
        ""
    else if (explicit_target.len > 0)
        explicit_target
    else
        (defaultAutoUpdaterInstallTarget(&target_buf) orelse
            return coreError(response_buf, "auto_updater_prepare_install", "target"));

    const expected = unescapeField(req_clean, "sha256", &sha_buf, false) orelse
        return coreError(response_buf, "auto_updater_prepare_install", "sha256");
    if (!auto_updater.isValidSha256Hex(expected)) {
        return coreError(response_buf, "auto_updater_prepare_install", "invalid_sha256");
    }

    if (!g_in_backend_invoke) {
        if (fsSandboxCheck(response_buf, "auto_updater_prepare_install", artifact)) |err| return err;
        if (fsSandboxCheck(response_buf, "auto_updater_prepare_install", stage_dir)) |err| return err;
        if (explicit_target.len > 0) {
            if (fsSandboxCheck(response_buf, "auto_updater_prepare_install", target)) |err| return err;
        }
    }

    if (expected.len > 0) {
        var actual_buf: [64]u8 = undefined;
        const actual = auto_updater.sha256File(runtime.io, artifact, &actual_buf) catch
            return coreError(response_buf, "auto_updater_prepare_install", "read");
        if (!auto_updater.sha256Equal(actual, expected)) {
            return coreError(response_buf, "auto_updater_prepare_install", "checksum_mismatch");
        }
    }

    auto_updater.validatePrepareInstallOptions(runtime.io, .{
        .artifact_path = artifact,
        .stage_dir = stage_dir,
        .target_path = target,
        .format = format,
    }) catch |err| {
        return coreError(response_buf, "auto_updater_prepare_install", auto_updater.errorCode(err));
    };

    var owned_source: ?[]u8 = null;
    defer if (owned_source) |p| runtime.gpa.free(p);

    const prepared = prepareAutoUpdaterInstallArtifact(format, artifact, stage_dir, target, &owned_source) catch |err| {
        return coreError(response_buf, "auto_updater_prepare_install", auto_updater.errorCode(err));
    };

    var source_esc: [8192]u8 = undefined;
    var target_esc: [8192]u8 = undefined;
    var stage_esc: [8192]u8 = undefined;
    var action_esc: [64]u8 = undefined;
    const source_n = util.escapeJsonStrFull(prepared.source_path, &source_esc) orelse
        return coreError(response_buf, "auto_updater_prepare_install", "encode");
    const target_n = util.escapeJsonStrFull(prepared.target_path, &target_esc) orelse
        return coreError(response_buf, "auto_updater_prepare_install", "encode");
    const stage_n = util.escapeJsonStrFull(prepared.stage_dir, &stage_esc) orelse
        return coreError(response_buf, "auto_updater_prepare_install", "encode");
    const action_n = util.escapeJsonStrFull(prepared.action, &action_esc) orelse
        return coreError(response_buf, "auto_updater_prepare_install", "encode");
    return std.fmt.bufPrint(
        response_buf,
        "{{\"from\":\"zig-core\",\"cmd\":\"auto_updater_prepare_install\",\"success\":true,\"path\":\"{s}\",\"source\":\"{s}\",\"target\":\"{s}\",\"stageDir\":\"{s}\",\"format\":\"{s}\",\"action\":\"{s}\",\"requiresQuitAndInstall\":{}}}",
        .{
            source_esc[0..source_n],
            source_esc[0..source_n],
            target_esc[0..target_n],
            stage_esc[0..stage_n],
            auto_updater.installFormatName(prepared.format),
            action_esc[0..action_n],
            prepared.requires_quit_and_install,
        },
    ) catch null;
}

fn handleAutoUpdaterQuitAndInstall(req_clean: []const u8, response_buf: []u8) ?[]const u8 {
    if (builtin.os.tag == .windows) {
        return coreError(response_buf, "auto_updater_quit_and_install", "unsupported_platform");
    }

    var source_buf: [FS_MAX_PATH_BYTES]u8 = undefined;
    var target_buf: [FS_MAX_PATH_BYTES]u8 = undefined;
    var helper_buf: [FS_MAX_PATH_BYTES + 64]u8 = undefined;
    var sha_buf: [128]u8 = undefined;

    const source = blk: {
        if (unescapeField(req_clean, "path", &source_buf, false)) |p| {
            if (p.len > 0) break :blk p;
        } else return coreError(response_buf, "auto_updater_quit_and_install", "path");
        if (unescapeField(req_clean, "source", &source_buf, false)) |p| {
            if (p.len > 0) break :blk p;
        } else return coreError(response_buf, "auto_updater_quit_and_install", "path");
        return coreError(response_buf, "auto_updater_quit_and_install", "path");
    };
    const explicit_target = unescapeField(req_clean, "target", &target_buf, false) orelse
        return coreError(response_buf, "auto_updater_quit_and_install", "target");
    const target = if (explicit_target.len > 0)
        explicit_target
    else
        (defaultAutoUpdaterInstallTarget(&target_buf) orelse
            return coreError(response_buf, "auto_updater_quit_and_install", "target"));
    const explicit_helper = unescapeField(req_clean, "helperPath", &helper_buf, false) orelse
        return coreError(response_buf, "auto_updater_quit_and_install", "helper_path");
    const helper = if (explicit_helper.len > 0)
        explicit_helper
    else
        (auto_updater.defaultQuitAndInstallHelperPath(source, &helper_buf) catch |err|
            return coreError(response_buf, "auto_updater_quit_and_install", auto_updater.errorCode(err)));
    const expected = unescapeField(req_clean, "sha256", &sha_buf, false) orelse
        return coreError(response_buf, "auto_updater_quit_and_install", "sha256");
    if (!auto_updater.isValidSha256Hex(expected)) {
        return coreError(response_buf, "auto_updater_quit_and_install", "invalid_sha256");
    }

    if (!g_in_backend_invoke) {
        if (fsSandboxCheck(response_buf, "auto_updater_quit_and_install", source)) |err| return err;
        if (explicit_target.len > 0) {
            if (fsSandboxCheck(response_buf, "auto_updater_quit_and_install", target)) |err| return err;
        }
        if (fsSandboxCheck(response_buf, "auto_updater_quit_and_install", helper)) |err| return err;
    }

    if (expected.len > 0) {
        var actual_buf: [64]u8 = undefined;
        const actual = auto_updater.sha256File(runtime.io, source, &actual_buf) catch
            return coreError(response_buf, "auto_updater_quit_and_install", "read");
        if (!auto_updater.sha256Equal(actual, expected)) {
            return coreError(response_buf, "auto_updater_quit_and_install", "checksum_mismatch");
        }
    }

    const relaunch = util.extractJsonBool(req_clean, "relaunch") orelse true;
    auto_updater.writeQuitAndInstallScript(runtime.gpa, runtime.io, .{
        .source_path = source,
        .target_path = target,
        .helper_path = helper,
        .wait_pid = getCurrentPid(),
        .relaunch = relaunch,
    }) catch |err| {
        return coreError(response_buf, "auto_updater_quit_and_install", auto_updater.errorCode(err));
    };

    launchQuitAndInstallHelper(helper) catch {
        return coreError(response_buf, "auto_updater_quit_and_install", "spawn");
    };

    var source_esc: [8192]u8 = undefined;
    var target_esc: [8192]u8 = undefined;
    var helper_esc: [8192]u8 = undefined;
    const source_n = util.escapeJsonStrFull(source, &source_esc) orelse
        return coreError(response_buf, "auto_updater_quit_and_install", "encode");
    const target_n = util.escapeJsonStrFull(target, &target_esc) orelse
        return coreError(response_buf, "auto_updater_quit_and_install", "encode");
    const helper_n = util.escapeJsonStrFull(helper, &helper_esc) orelse
        return coreError(response_buf, "auto_updater_quit_and_install", "encode");
    const resp = std.fmt.bufPrint(
        response_buf,
        "{{\"from\":\"zig-core\",\"cmd\":\"auto_updater_quit_and_install\",\"success\":true,\"path\":\"{s}\",\"target\":\"{s}\",\"helperPath\":\"{s}\",\"relaunch\":{}}}",
        .{ source_esc[0..source_n], target_esc[0..target_n], helper_esc[0..helper_n], relaunch },
    ) catch return null;

    if (g_in_backend_invoke) {
        cef.quit();
    } else {
        cef.quitAfterNextResponse();
    }
    return resp;
}

fn prepareAutoUpdaterInstallArtifact(
    format: auto_updater.InstallFormat,
    artifact: []const u8,
    stage_dir: []const u8,
    target: []const u8,
    owned_source: *?[]u8,
) auto_updater.PrepareError!auto_updater.PreparedInstall {
    switch (format) {
        .app => return auto_updater.preparedQuitAndInstall(artifact, target, stage_dir, .app),
        .raw => return auto_updater.preparedQuitAndInstall(artifact, target, stage_dir, .raw),
        .appimage => {
            runCmd(runtime.gpa, &.{ "chmod", "+x", artifact }) catch return error.CommandFailed;
            return auto_updater.preparedQuitAndInstall(artifact, target, stage_dir, .appimage);
        },
        .deb => return auto_updater.preparedSystemPackage(artifact, stage_dir),
        .zip => {
            if (builtin.os.tag == .windows) {
                const source = prepareWindowsZip(artifact, stage_dir) catch |err| return err;
                owned_source.* = source;
                return auto_updater.preparedQuitAndInstall(source, target, stage_dir, .zip);
            }
            const source = prepareMacZipApp(artifact, stage_dir) catch |err| return err;
            owned_source.* = source;
            return auto_updater.preparedQuitAndInstall(source, target, stage_dir, .zip);
        },
        .dmg => {
            const source = prepareMacDmgApp(artifact, stage_dir) catch |err| return err;
            owned_source.* = source;
            return auto_updater.preparedQuitAndInstall(source, target, stage_dir, .dmg);
        },
    }
}

/// Windows `.zip` extraction → 압축 풀린 stage 디렉토리의 single child dir
/// (Suji packaging 이 `<name>-<ver>-windows-x64/` 하나만 만듦) 반환.
/// quitAndInstall 이 이 source dir 를 target install dir 로 통째 교체.
fn prepareWindowsZip(artifact: []const u8, stage_dir: []const u8) auto_updater.PrepareError![]u8 {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
    std.Io.Dir.cwd().createDirPath(runtime.io, stage_dir) catch return error.CommandFailed;

    const extract_dir = std.fmt.allocPrint(runtime.gpa, "{s}/extract", .{stage_dir}) catch
        return error.OutOfMemory;
    defer runtime.gpa.free(extract_dir);

    std.Io.Dir.cwd().deleteTree(runtime.io, extract_dir) catch {};
    std.Io.Dir.cwd().createDirPath(runtime.io, extract_dir) catch return error.CommandFailed;

    // PowerShell Expand-Archive — .zip → extract_dir.
    const ps_cmd = std.fmt.allocPrint(
        runtime.gpa,
        "Expand-Archive -LiteralPath '{s}' -DestinationPath '{s}' -Force",
        .{ artifact, extract_dir },
    ) catch return error.OutOfMemory;
    defer runtime.gpa.free(ps_cmd);
    runCmd(runtime.gpa, &.{ "powershell", "-NoProfile", "-Command", ps_cmd }) catch
        return error.CommandFailed;

    // 압축 풀린 디렉토리 안의 single child 디렉토리를 찾는다 (suji packaging
    // 이 `<name>-<ver>-windows-x64/` 디렉토리 하나만 생성). 여러 entry 면
    // extract_dir 자체를 source 로 사용 (사용자가 직접 만든 zip 호환).
    var d = std.Io.Dir.cwd().openDir(runtime.io, extract_dir, .{ .iterate = true }) catch
        return error.CommandFailed;
    defer d.close(runtime.io);
    var it = d.iterate();
    var single: ?[]u8 = null;
    var multiple = false;
    while (it.next(runtime.io) catch return error.CommandFailed) |entry| {
        if (entry.kind != .directory) continue;
        if (single != null) {
            multiple = true;
            if (single) |p| runtime.gpa.free(p);
            single = null;
            break;
        }
        single = std.fmt.allocPrint(runtime.gpa, "{s}/{s}", .{ extract_dir, entry.name }) catch
            return error.OutOfMemory;
    }
    if (multiple or single == null) {
        if (single) |p| runtime.gpa.free(p);
        return runtime.gpa.dupe(u8, extract_dir) catch error.OutOfMemory;
    }
    return single.?;
}

fn prepareMacZipApp(artifact: []const u8, stage_dir: []const u8) auto_updater.PrepareError![]u8 {
    if (builtin.os.tag != .macos) return error.UnsupportedPlatform;
    std.Io.Dir.cwd().createDirPath(runtime.io, stage_dir) catch return error.CommandFailed;

    const extract_dir = std.fmt.allocPrint(runtime.gpa, "{s}/extract", .{stage_dir}) catch
        return error.OutOfMemory;
    defer runtime.gpa.free(extract_dir);

    runCmd(runtime.gpa, &.{ "rm", "-rf", extract_dir }) catch return error.CommandFailed;
    std.Io.Dir.cwd().createDirPath(runtime.io, extract_dir) catch return error.CommandFailed;
    runCmd(runtime.gpa, &.{ "ditto", "-x", "-k", artifact, extract_dir }) catch return error.CommandFailed;

    return auto_updater.findAppBundle(runtime.gpa, runtime.io, extract_dir);
}

fn prepareMacDmgApp(artifact: []const u8, stage_dir: []const u8) auto_updater.PrepareError![]u8 {
    if (builtin.os.tag != .macos) return error.UnsupportedPlatform;
    std.Io.Dir.cwd().createDirPath(runtime.io, stage_dir) catch return error.CommandFailed;

    const mount_dir = std.fmt.allocPrint(runtime.gpa, "{s}/mount", .{stage_dir}) catch
        return error.OutOfMemory;
    defer runtime.gpa.free(mount_dir);

    runCmd(runtime.gpa, &.{ "rm", "-rf", mount_dir }) catch return error.CommandFailed;
    std.Io.Dir.cwd().createDirPath(runtime.io, mount_dir) catch return error.CommandFailed;

    runCmd(runtime.gpa, &.{ "hdiutil", "attach", "-nobrowse", "-readonly", "-mountpoint", mount_dir, artifact }) catch
        return error.CommandFailed;
    var attached = true;
    defer if (attached) {
        runCmd(runtime.gpa, &.{ "hdiutil", "detach", mount_dir, "-quiet" }) catch {};
    };

    const mounted_app = auto_updater.findAppBundle(runtime.gpa, runtime.io, mount_dir) catch |err| return err;
    defer runtime.gpa.free(mounted_app);

    const app_name = std.fs.path.basename(mounted_app);
    const staged_app = std.fmt.allocPrint(runtime.gpa, "{s}/{s}", .{ stage_dir, app_name }) catch
        return error.OutOfMemory;
    errdefer runtime.gpa.free(staged_app);

    runCmd(runtime.gpa, &.{ "rm", "-rf", staged_app }) catch return error.CommandFailed;
    runCmd(runtime.gpa, &.{ "ditto", mounted_app, staged_app }) catch return error.CommandFailed;

    runCmd(runtime.gpa, &.{ "hdiutil", "detach", mount_dir, "-quiet" }) catch return error.CommandFailed;
    attached = false;
    return staged_app;
}

fn defaultAutoUpdaterInstallTarget(buf: []u8) ?[]const u8 {
    if (builtin.os.tag == .macos) {
        const bundle_path = cef.appGetBundlePath(buf);
        if (std.mem.endsWith(u8, bundle_path, ".app")) return bundle_path;
    } else if (builtin.os.tag == .linux) {
        if (runtime.env("APPIMAGE")) |appimage| {
            if (std.fs.path.isAbsolute(appimage) and appimage.len <= buf.len) {
                @memcpy(buf[0..appimage.len], appimage);
                return buf[0..appimage.len];
            }
        }
    }

    const exe_len = std.process.executablePath(runtime.io, buf) catch return null;
    return buf[0..exe_len];
}

fn launchQuitAndInstallHelper(helper_path: []const u8) !void {
    if (builtin.os.tag == .windows) {
        // PowerShell `.ps1` helper. `-ExecutionPolicy Bypass` 로 사용자 정책
        // (RestrictedScript 등) 우회 — script 는 우리가 직접 쓴 파일이고
        // 즉시 종료 후 self-delete 하므로 영구 정책 변경 아님.
        const child = try std.process.spawn(runtime.io, .{
            .argv = &.{ "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", helper_path },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        _ = child;
        return;
    }
    const child = try std.process.spawn(runtime.io, .{
        .argv = &.{ "/bin/sh", helper_path },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    _ = child;
}

const FS_MAX_TEXT_BYTES: usize = 8192;
const FS_MAX_PATH_BYTES: usize = 4096;

/// 전체 suji.json config을 glob 노출 — fs sandbox / 향후 network/shell allowlist /
/// 플러그인 접근까지 단일 진입점. dev/run 시작 시 setGlobalConfig로 주입.
/// lifetime: dev/run 함수가 process lifetime이라 stack address 안전.
var g_config: ?*const suji.Config = null;

pub fn setGlobalConfig(c: *const suji.Config) void {
    g_config = c;
}

/// Backend invoke 흐름에서는 sandbox 적용 X (사용자 자체 코드라 신뢰).
/// BackendRegistry __core__ 채널 핸들러가 set, frontend IPC origin은 false 유지.
threadlocal var g_in_backend_invoke: bool = false;

/// fs frontend sandbox — fs 는 **default-deny** (cfg null/roots empty → 차단).
/// 공통 매처는 util.* (CEF-free, 모바일 embed 와 공용).
fn isPathAllowedForFrontend(path: []const u8) bool {
    const cfg = g_config orelse return false;
    const roots = cfg.fs.allowed_roots;
    if (roots.len == 0) return false;
    return util.pathAllowedInRoots(path, roots);
}

/// 렌더러 경로 fs sandbox 허용 판정(공용 술어) — opt-in: backend 우회 /
/// allowedRoots 미설정=레거시 허용 / 설정 시 prefix+boundary 매치(util.pathAllowedInRoots).
/// rendererPathFsGate(에러 응답 sink)와 menuIconPathAllowed(bool, per-item) 가 공유 —
/// 보안 게이트 로직을 단일 출처로.
fn rendererPathAllowed(path: []const u8) bool {
    if (g_in_backend_invoke) return true;
    const cfg = g_config orelse return true;
    if (cfg.fs.allowed_roots.len == 0) return true; // opt-in: 미설정=레거시 허용
    return util.pathAllowedInRoots(path, cfg.fs.allowed_roots);
}

/// 렌더러-제어 파일경로 게이트 — fs.* 외에 path 를 받는 역사적-무제한 API 가
/// fs 샌드박스를 우회하던 갭 보완(보안 점검 지적·후속). 대상:
///  - 쓰기: print_to_pdf / capture_page / desktop_capturer_capture_thumbnail
///  - 읽기: native_image_get_size / native_image_to_png|jpeg (임의 파일을
///    base64 로 인코딩해 렌더러로 반환 = 파일내용 유출) /
///    native_image_is_empty|is_template (파일 존재·디코드·메타 유출)
///  - 파일 probe/read sink: tray_create.iconPath / dialog_show_message_box.icon
/// (menu_set_application_menu 의 MenuItem.icon 은 per-item drop 이라 menuIconPathAllowed 로 별도 게이트)
/// **opt-in**: fs.allowedRoots 미설정/빈이면 레거시 무제한(비파괴 — 이 API
/// 들은 그동안 무제한 출하), 설정 시 `fs.*` 와 동일 경계로 enforce(설정한 fs
/// 통제가 이 경로들도 포함 → 신뢰불가 렌더러의 임의 파일 읽기/쓰기/이미지 로드 차단).
/// backend SDK 호출은 fs 와 동일 thread-local 마커로 우회. 판정은 rendererPathAllowed 공유.
fn rendererPathFsGate(response_buf: []u8, cmd: []const u8, path: []const u8) ?[]const u8 {
    if (rendererPathAllowed(path)) return null;
    return coreError(response_buf, cmd, "forbidden");
}

// hasParentTraversalSegment / pathHasRootBoundary / urlAllowedInList 단위 테스트는
// util.zig 로 이동(공통 매처와 함께 — 데스크톱/모바일 embed 공용).

test "isPathAllowedForFrontend: 종합 시나리오" {
    // g_config은 process global이라 test 사이 reset 필요.
    const saved = g_config;
    defer g_config = saved;

    // 1) g_config null → 차단 (config 미설정)
    g_config = null;
    try std.testing.expect(!isPathAllowedForFrontend("/any/path"));

    // 2) allowedRoots empty → 차단 (default safe)
    var cfg_empty = suji.Config{};
    cfg_empty.fs.allowed_roots = &.{};
    g_config = &cfg_empty;
    try std.testing.expect(!isPathAllowedForFrontend("/any/path"));

    // 3) wildcard ["*"] → 일반 path 허용, .. 거부
    var cfg_wild = suji.Config{};
    const wild_roots = [_][:0]const u8{"*"};
    cfg_wild.fs.allowed_roots = &wild_roots;
    g_config = &cfg_wild;
    try std.testing.expect(isPathAllowedForFrontend("/etc/hosts"));
    try std.testing.expect(isPathAllowedForFrontend("/Users/x/safe"));
    try std.testing.expect(!isPathAllowedForFrontend("/foo/../etc/passwd")); // .. 항상 차단

    // 4) specific root → boundary 가드 검증 (prefix-extension attack)
    var cfg_specific = suji.Config{};
    const spec_roots = [_][:0]const u8{"/Users/x/myapp"};
    cfg_specific.fs.allowed_roots = &spec_roots;
    g_config = &cfg_specific;
    try std.testing.expect(isPathAllowedForFrontend("/Users/x/myapp"));
    try std.testing.expect(isPathAllowedForFrontend("/Users/x/myapp/data.txt"));
    try std.testing.expect(!isPathAllowedForFrontend("/Users/x/myapp_secret/data")); // prefix-extension
    try std.testing.expect(!isPathAllowedForFrontend("/Users/x/other"));

    // 5) mixed ["*", "/specific"] → wildcard로 모두 허용
    var cfg_mixed = suji.Config{};
    const mixed_roots = [_][:0]const u8{ "*", "/Users/x/myapp" };
    cfg_mixed.fs.allowed_roots = &mixed_roots;
    g_config = &cfg_mixed;
    try std.testing.expect(isPathAllowedForFrontend("/anywhere"));
    try std.testing.expect(!isPathAllowedForFrontend("/foo/../etc")); // .. 차단

    // 6) 정상 파일명에 .. 포함 → 통과 (false positive 회귀)
    g_config = &cfg_wild;
    try std.testing.expect(isPathAllowedForFrontend("/foo/my..file.txt"));
    try std.testing.expect(isPathAllowedForFrontend("/foo/archive..bak"));
}

test "fsSandboxCheck: g_in_backend_invoke 마커는 sandbox 우회" {
    const saved_cfg = g_config;
    const saved_marker = g_in_backend_invoke;
    defer {
        g_config = saved_cfg;
        g_in_backend_invoke = saved_marker;
    }

    // sandbox 차단 config (empty roots = forbidden)
    var cfg = suji.Config{};
    cfg.fs.allowed_roots = &.{};
    g_config = &cfg;

    var resp_buf: [256]u8 = undefined;

    // Frontend 흐름 — 차단 (forbidden 에러 반환).
    g_in_backend_invoke = false;
    const fe = fsSandboxCheck(&resp_buf, "fs_test", "/any/path");
    try std.testing.expect(fe != null);
    try std.testing.expect(std.mem.indexOf(u8, fe.?, "\"error\":\"forbidden\"") != null);

    // Backend 흐름 — 우회 (null 반환 = 검사 통과).
    g_in_backend_invoke = true;
    const be = fsSandboxCheck(&resp_buf, "fs_test", "/any/path");
    try std.testing.expect(be == null);
}

test "rendererPathFsGate: opt-in (fs.allowedRoots 미설정=레거시 허용, 설정=enforce) + backend 우회" {
    const saved_cfg = g_config;
    const saved_marker = g_in_backend_invoke;
    defer {
        g_config = saved_cfg;
        g_in_backend_invoke = saved_marker;
    }
    g_in_backend_invoke = false;
    var resp: [256]u8 = undefined;

    // g_config null → 레거시 허용.
    g_config = null;
    try std.testing.expect(rendererPathFsGate(&resp, "capture_page", "/etc/evil.png") == null);

    // fs.allowedRoots 미설정(빈) → 레거시 무제한(비파괴 — 기존 동작 불변).
    var cfg_unset = suji.Config{};
    cfg_unset.fs.allowed_roots = &.{};
    g_config = &cfg_unset;
    try std.testing.expect(rendererPathFsGate(&resp, "print_to_pdf", "/etc/evil.pdf") == null);

    // fs.allowedRoots 설정 → enforce: 안쪽 허용, 밖/`..` 차단(fs_write_file 동형).
    var cfg_set = suji.Config{};
    const roots = [_][:0]const u8{"/Users/x/app"};
    cfg_set.fs.allowed_roots = &roots;
    g_config = &cfg_set;
    try std.testing.expect(rendererPathFsGate(&resp, "capture_page", "/Users/x/app/shot.png") == null);
    const denied = rendererPathFsGate(&resp, "capture_page", "/etc/passwd");
    try std.testing.expect(denied != null and std.mem.indexOf(u8, denied.?, "\"error\":\"forbidden\"") != null);
    try std.testing.expect(rendererPathFsGate(&resp, "print_to_pdf", "/Users/x/app/../etc/x.pdf") != null); // `..` 차단
    try std.testing.expect(rendererPathFsGate(&resp, "desktop_capturer_capture_thumbnail", "/Users/x/app_evil/t.png") != null); // prefix-extension
    // 읽기 sink(nativeImage) 도 동일 경계 — 임의 파일 base64 유출 차단.
    try std.testing.expect(rendererPathFsGate(&resp, "native_image_get_size", "/Users/x/app/i.png") == null);
    try std.testing.expect(rendererPathFsGate(&resp, "native_image_to_png", "/etc/shadow") != null);
    try std.testing.expect(rendererPathFsGate(&resp, "native_image_to_jpeg", "/Users/x/app/../secret.jpg") != null);
    // tray iconPath도 renderer-controlled file path이므로 동일 경계 적용.
    try std.testing.expect(rendererPathFsGate(&resp, "tray_create", "/Users/x/app/tray.png") == null);
    try std.testing.expect(rendererPathFsGate(&resp, "tray_create", "/etc/tray.png") != null);

    // backend SDK 호출 → 우회(설정돼 있어도 null).
    g_in_backend_invoke = true;
    try std.testing.expect(rendererPathFsGate(&resp, "capture_page", "/etc/passwd") == null);
}

test "shell/dialog 게이트: opt-in (키 부재=레거시 허용, 존재=enforce) + backend 우회" {
    const saved_cfg = g_config;
    const saved_marker = g_in_backend_invoke;
    defer {
        g_config = saved_cfg;
        g_in_backend_invoke = saved_marker;
    }
    g_in_backend_invoke = false;
    var resp: [256]u8 = undefined;

    // g_config null → 레거시 허용 (null 반환).
    g_config = null;
    try std.testing.expect(shellPathGate(&resp, "shell_open_path", "/x") == null);
    try std.testing.expect(shellUrlGate(&resp, "shell_open_external", "https://x") == null);
    try std.testing.expect(dialogPathGate(&resp, "dialog_show_open_dialog", "/x") == null);

    // 키 부재 (optional null) → 레거시 허용.
    var cfg_absent = suji.Config{};
    g_config = &cfg_absent;
    try std.testing.expect(shellPathGate(&resp, "shell_open_path", "/etc/passwd") == null);
    try std.testing.expect(shellUrlGate(&resp, "shell_open_external", "https://evil.com") == null);

    // 키 존재하지만 빈 슬라이스 → enforce deny-all (forbidden).
    var cfg_deny = suji.Config{};
    cfg_deny.shell.allowed_paths = &.{};
    cfg_deny.shell.allowed_external_urls = &.{};
    cfg_deny.dialog.allowed_paths = &.{};
    g_config = &cfg_deny;
    const d1 = shellPathGate(&resp, "shell_open_path", "/x");
    try std.testing.expect(d1 != null and std.mem.indexOf(u8, d1.?, "\"error\":\"forbidden\"") != null);
    try std.testing.expect(shellUrlGate(&resp, "shell_open_external", "https://x") != null);
    try std.testing.expect(dialogPathGate(&resp, "dialog_show_open_dialog", "/x") != null);
    // 빈 defaultPath 는 dialog 무제약 (deny config 라도 null).
    try std.testing.expect(dialogPathGate(&resp, "dialog_show_open_dialog", "") == null);

    // 특정 allowlist → boundary/glob enforce.
    var cfg_spec = suji.Config{};
    const sp = [_][:0]const u8{"/Users/x/app"};
    const su = [_][:0]const u8{"https://*.ok.com/*"};
    cfg_spec.shell.allowed_paths = &sp;
    cfg_spec.shell.allowed_external_urls = &su;
    cfg_spec.dialog.allowed_paths = &sp;
    g_config = &cfg_spec;
    try std.testing.expect(shellPathGate(&resp, "shell_open_path", "/Users/x/app/f") == null);
    try std.testing.expect(shellPathGate(&resp, "shell_open_path", "/Users/x/app_secret") != null); // prefix-ext
    try std.testing.expect(shellPathGate(&resp, "shell_open_path", "/Users/x/app/../etc") != null); // ..
    try std.testing.expect(shellUrlGate(&resp, "shell_open_external", "https://a.ok.com/p") == null);
    try std.testing.expect(shellUrlGate(&resp, "shell_open_external", "https://evil.com/") != null);
    try std.testing.expect(dialogPathGate(&resp, "dialog_show_save_dialog", "/Users/x/app/s.txt") == null);
    try std.testing.expect(dialogPathGate(&resp, "dialog_show_save_dialog", "/etc/x") != null);

    // backend invoke 마커 → 전 게이트 우회 (deny config 라도 null).
    g_config = &cfg_deny;
    g_in_backend_invoke = true;
    try std.testing.expect(shellPathGate(&resp, "shell_open_path", "/x") == null);
    try std.testing.expect(shellUrlGate(&resp, "shell_open_external", "https://x") == null);
    try std.testing.expect(dialogPathGate(&resp, "dialog_show_open_dialog", "/x") == null);
}

fn fsSandboxCheck(response_buf: []u8, cmd: []const u8, path: []const u8) ?[]const u8 {
    if (g_in_backend_invoke) return null;
    if (isPathAllowedForFrontend(path)) return null;
    return coreError(response_buf, cmd, "forbidden");
}

/// shell/dialog allowlist 게이트 (opt-in). backend invoke 우회. config 키 부재
/// (optional null) → null 반환 = 레거시 무제한(비파괴). 키 존재 시 enforce:
/// 빈 슬라이스 → 매치 0 → forbidden(deny-all), `["*"]` → 허용, 특정 → 제한.
fn shellPathGate(response_buf: []u8, cmd: []const u8, path: []const u8) ?[]const u8 {
    if (g_in_backend_invoke) return null;
    const cfg = g_config orelse return null;
    const list = cfg.shell.allowed_paths orelse return null;
    if (util.pathAllowedInRoots(path, list)) return null;
    return coreError(response_buf, cmd, "forbidden");
}
fn shellUrlGate(response_buf: []u8, cmd: []const u8, url: []const u8) ?[]const u8 {
    if (g_in_backend_invoke) return null;
    const cfg = g_config orelse return null;
    const list = cfg.shell.allowed_external_urls orelse return null;
    if (util.urlAllowedInList(url, list)) return null;
    return coreError(response_buf, cmd, "forbidden");
}
/// dialog defaultPath 게이트 — 빈 defaultPath 는 무제약(다이얼로그 자체가 사용자 중재).
fn dialogPathGate(response_buf: []u8, cmd: []const u8, path: []const u8) ?[]const u8 {
    if (g_in_backend_invoke) return null;
    if (path.len == 0) return null;
    const cfg = g_config orelse return null;
    const list = cfg.dialog.allowed_paths orelse return null;
    if (util.pathAllowedInRoots(path, list)) return null;
    return coreError(response_buf, cmd, "forbidden");
}

/// `__core__` 핸들러 공통 — JSON에서 string field 추출 후 unescape. 빈 문자열은 거부.
fn extractEscapedField(req_clean: []const u8, key: []const u8, out: []u8) ?[]const u8 {
    const raw = util.extractJsonString(req_clean, key) orelse return null;
    const n = util.unescapeJsonStr(raw, out) orelse return null;
    if (n == 0) return null;
    return out[0..n];
}

fn fsPathFromRequest(req_clean: []const u8, out: []u8) ?[]const u8 {
    return extractEscapedField(req_clean, "path", out);
}

fn fsKindName(kind: std.Io.File.Kind) []const u8 {
    return switch (kind) {
        .file => "file",
        .directory => "directory",
        .sym_link => "symlink",
        .block_device => "blockDevice",
        .character_device => "characterDevice",
        .named_pipe => "fifo",
        .unix_domain_socket => "socket",
        .whiteout => "whiteout",
        .door => "door",
        .event_port => "eventPort",
        .unknown => "unknown",
    };
}

fn handleFsReadFile(req_clean: []const u8, response_buf: []u8) ?[]const u8 {
    var path_buf: [FS_MAX_PATH_BYTES]u8 = undefined;
    const path = fsPathFromRequest(req_clean, &path_buf) orelse return coreError(response_buf, "fs_read_file", "path");
    if (fsSandboxCheck(response_buf, "fs_read_file", path)) |err| return err;

    var text_buf: [FS_MAX_TEXT_BYTES]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&text_buf);
    const text = std.Io.Dir.cwd().readFileAlloc(runtime.io, path, fba.allocator(), .limited(FS_MAX_TEXT_BYTES)) catch |err| {
        // FBA가 OOM을 던지는 케이스는 8KiB 초과가 유일 → too_large로 surface.
        const code: []const u8 = if (err == error.OutOfMemory or err == error.StreamTooLong) "too_large" else "read";
        return coreError(response_buf, "fs_read_file", code);
    };

    var esc_buf: [util.MAX_RESPONSE]u8 = undefined;
    const esc_len = util.escapeJsonStrFull(text, &esc_buf) orelse return coreError(response_buf, "fs_read_file", "too_large");
    return std.fmt.bufPrint(
        response_buf,
        "{{\"from\":\"zig-core\",\"cmd\":\"fs_read_file\",\"success\":true,\"text\":\"{s}\"}}",
        .{esc_buf[0..esc_len]},
    ) catch null;
}

fn handleFsWriteFile(req_clean: []const u8, response_buf: []u8) ?[]const u8 {
    var path_buf: [FS_MAX_PATH_BYTES]u8 = undefined;
    const path = fsPathFromRequest(req_clean, &path_buf) orelse return coreError(response_buf, "fs_write_file", "path");
    if (fsSandboxCheck(response_buf, "fs_write_file", path)) |err| return err;
    const raw_text = util.extractJsonString(req_clean, "text") orelse "";

    var text_buf: [FS_MAX_TEXT_BYTES]u8 = undefined;
    const text_len = util.unescapeJsonStr(raw_text, &text_buf) orelse return coreError(response_buf, "fs_write_file", "too_large");

    var file = std.Io.Dir.cwd().createFile(runtime.io, path, .{}) catch return coreError(response_buf, "fs_write_file", "write");
    defer file.close(runtime.io);
    var writer_buf: [4096]u8 = undefined;
    var fw = file.writer(runtime.io, &writer_buf);
    fw.interface.writeAll(text_buf[0..text_len]) catch return coreError(response_buf, "fs_write_file", "write");
    fw.interface.flush() catch return coreError(response_buf, "fs_write_file", "write");

    return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"fs_write_file\",\"success\":true}}", .{}) catch null;
}

fn handleFsStat(req_clean: []const u8, response_buf: []u8) ?[]const u8 {
    var path_buf: [FS_MAX_PATH_BYTES]u8 = undefined;
    const path = fsPathFromRequest(req_clean, &path_buf) orelse return coreError(response_buf, "fs_stat", "path");
    if (fsSandboxCheck(response_buf, "fs_stat", path)) |err| return err;
    const st = std.Io.Dir.cwd().statFile(runtime.io, path, .{}) catch return coreError(response_buf, "fs_stat", "not_found");
    // ns since epoch → ms — JS `Date(ms)` 호환 + 2^53 안전 범위 확보 (ns 그대로면 ~104일 후 손실).
    const mtime_ms = @divFloor(st.mtime.nanoseconds, 1_000_000);
    return std.fmt.bufPrint(
        response_buf,
        "{{\"from\":\"zig-core\",\"cmd\":\"fs_stat\",\"success\":true,\"type\":\"{s}\",\"size\":{d},\"mtime\":{d}}}",
        .{ fsKindName(st.kind), st.size, mtime_ms },
    ) catch null;
}

fn handleFsMkdir(req_clean: []const u8, response_buf: []u8) ?[]const u8 {
    var path_buf: [FS_MAX_PATH_BYTES]u8 = undefined;
    const path = fsPathFromRequest(req_clean, &path_buf) orelse return coreError(response_buf, "fs_mkdir", "path");
    if (fsSandboxCheck(response_buf, "fs_mkdir", path)) |err| return err;
    const recursive = util.extractJsonBool(req_clean, "recursive") orelse false;
    if (recursive) {
        // recursive=true는 createDirPath 자체가 idempotent (POSIX `mkdir -p`).
        std.Io.Dir.cwd().createDirPath(runtime.io, path) catch return coreError(response_buf, "fs_mkdir", "mkdir");
    } else {
        // POSIX mkdir(2) / Node `fs.mkdir(p)` 호환 — 이미 존재하면 명시적 exists 에러.
        std.Io.Dir.cwd().createDir(runtime.io, path, .default_dir) catch |err| {
            const code: []const u8 = if (err == error.PathAlreadyExists) "exists" else "mkdir";
            return coreError(response_buf, "fs_mkdir", code);
        };
    }
    return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"fs_mkdir\",\"success\":true}}", .{}) catch null;
}

fn handleFsRm(req_clean: []const u8, response_buf: []u8) ?[]const u8 {
    var path_buf: [FS_MAX_PATH_BYTES]u8 = undefined;
    const path = fsPathFromRequest(req_clean, &path_buf) orelse return coreError(response_buf, "fs_rm", "path");
    if (fsSandboxCheck(response_buf, "fs_rm", path)) |err| return err;
    const recursive = util.extractJsonBool(req_clean, "recursive") orelse false;
    const force = util.extractJsonBool(req_clean, "force") orelse false;

    const cwd = std.Io.Dir.cwd();
    if (recursive) {
        // deleteTree는 not-exist를 자체 swallow → force는 다른 에러 swallow에만 영향.
        cwd.deleteTree(runtime.io, path) catch {
            if (!force) return coreError(response_buf, "fs_rm", "rm");
        };
    } else {
        cwd.deleteFile(runtime.io, path) catch |err| switch (err) {
            error.FileNotFound => if (!force) return coreError(response_buf, "fs_rm", "not_found"),
            error.IsDir => return coreError(response_buf, "fs_rm", "is_dir"),
            else => return coreError(response_buf, "fs_rm", "rm"),
        };
    }
    return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"fs_rm\",\"success\":true}}", .{}) catch null;
}

fn handleFsReadDir(req_clean: []const u8, response_buf: []u8) ?[]const u8 {
    var path_buf: [FS_MAX_PATH_BYTES]u8 = undefined;
    const path = fsPathFromRequest(req_clean, &path_buf) orelse return coreError(response_buf, "fs_readdir", "path");
    if (fsSandboxCheck(response_buf, "fs_readdir", path)) |err| return err;
    var dir = std.Io.Dir.cwd().openDir(runtime.io, path, .{ .iterate = true }) catch return coreError(response_buf, "fs_readdir", "open");
    defer dir.close(runtime.io);

    // 닫는 `]}}` 3바이트 + 안전 마진을 reserve해 partial JSON으로 잘리는 것을 방지.
    const tail_reserve: usize = 8;
    var out_pos: usize = 0;
    out_pos += (std.fmt.bufPrint(response_buf[out_pos..], "{{\"from\":\"zig-core\",\"cmd\":\"fs_readdir\",\"success\":true,\"entries\":[", .{}) catch return null).len;
    var iter = dir.iterate();
    var first = true;
    while (iter.next(runtime.io) catch return coreError(response_buf, "fs_readdir", "read")) |entry| {
        var esc_name: [1024]u8 = undefined;
        // entry name escape 실패 = 1024바이트 한도 초과. silent skip 대신 명시적 too_large.
        const n = util.escapeJsonStrFull(entry.name, &esc_name) orelse return coreError(response_buf, "fs_readdir", "too_large");
        const sep: []const u8 = if (first) "" else ",";
        const remaining = response_buf.len - out_pos;
        if (remaining <= tail_reserve) return coreError(response_buf, "fs_readdir", "too_large");
        const part = std.fmt.bufPrint(
            response_buf[out_pos .. response_buf.len - tail_reserve],
            "{s}{{\"name\":\"{s}\",\"type\":\"{s}\"}}",
            .{ sep, esc_name[0..n], fsKindName(entry.kind) },
        ) catch return coreError(response_buf, "fs_readdir", "too_large");
        out_pos += part.len;
        first = false;
    }
    out_pos += (std.fmt.bufPrint(response_buf[out_pos..], "]}}", .{}) catch return null).len;
    return response_buf[0..out_pos];
}

fn handleDialogShowOpenDialog(req_clean: []const u8, response_buf: []u8) ?[]const u8 {
    var arena_buf: [DIALOG_PARSE_ARENA]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arena_buf);
    const arena = fba.allocator();

    const parsed = std.json.parseFromSlice(OpenDialogJson, arena, req_clean, .{
        .ignore_unknown_fields = true,
    }) catch {
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"dialog_show_open_dialog\",\"canceled\":true,\"filePaths\":[],\"error\":\"parse\"}}",
            .{},
        ) catch null;
    };
    defer parsed.deinit();
    const opts = parsed.value;

    if (dialogPathGate(response_buf, "dialog_show_open_dialog", opts.defaultPath)) |e| return e;

    const filters = convertFilters(arena, opts.filters) catch &[_]cef.FileFilter{};
    var dialog_buf: [util.MAX_RESPONSE]u8 = undefined;
    const dialog_json = cef.showOpenDialog(.{
        .title = opts.title,
        .default_path = opts.defaultPath,
        .button_label = opts.buttonLabel,
        .message = opts.message,
        .can_choose_files = hasProp(opts.properties, "openFile") or !hasProp(opts.properties, "openDirectory"),
        .can_choose_directories = hasProp(opts.properties, "openDirectory"),
        .allows_multiple_selection = hasProp(opts.properties, "multiSelections"),
        .shows_hidden_files = hasProp(opts.properties, "showHiddenFiles"),
        .can_create_directories = hasProp(opts.properties, "createDirectory") or !hasProp(opts.properties, "openDirectory"),
        .no_resolve_aliases = hasProp(opts.properties, "noResolveAliases"),
        .treat_packages_as_dirs = hasProp(opts.properties, "treatPackageAsDirectory"),
        .filters = filters,
        .parent_window = dialogParentNSWindow(opts.windowId),
    }, &dialog_buf);

    return std.fmt.bufPrint(
        response_buf,
        "{{\"from\":\"zig-core\",\"cmd\":\"dialog_show_open_dialog\",{s}",
        .{dialog_json[1..]}, // strip leading '{' from dialog_json, keep trailing '}'
    ) catch null;
}

// ============================================
// Tray handlers — menu item 재귀 파싱
// ============================================

fn handleTraySetMenu(req_clean: []const u8, response_buf: []u8) ?[]const u8 {
    var arena_buf: [DIALOG_PARSE_ARENA * 2]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arena_buf);
    const arena = fba.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, arena, req_clean, .{}) catch {
        return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"tray_set_menu\",\"success\":false,\"error\":\"parse\"}}", .{}) catch null;
    };
    if (parsed.value != .object) return coreError(response_buf, "tray_set_menu", "parse");
    const obj = parsed.value.object;
    const tray_id = util.nonNegU32(util.extractJsonInt(req_clean, "trayId") orelse return coreError(response_buf, "tray_set_menu", "parse"));
    const items_val = obj.get("items") orelse return coreError(response_buf, "tray_set_menu", "parse");
    if (items_val != .array) return coreError(response_buf, "tray_set_menu", "parse");
    const items = parseTrayMenuItems(arena, items_val.array.items) catch return coreError(response_buf, "tray_set_menu", "parse");

    const ok = cef.setTrayMenu(tray_id, items);
    return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"tray_set_menu\",\"success\":{}}}", .{ok}) catch null;
}

fn parseTrayMenuItems(arena: std.mem.Allocator, values: []const std.json.Value) MenuParseError![]cef.TrayMenuItem {
    var out = try arena.alloc(cef.TrayMenuItem, values.len);
    for (values, 0..) |v, i| out[i] = try parseTrayMenuItem(arena, v);
    return out;
}

fn parseTrayMenuItem(arena: std.mem.Allocator, value: std.json.Value) MenuParseError!cef.TrayMenuItem {
    if (value != .object) return error.InvalidMenuItem;
    const obj = value.object;
    const typ = util.jsonObjectGetString(obj, "type") orelse "";
    if (std.mem.eql(u8, typ, "separator")) return .separator;

    const label = util.jsonObjectGetString(obj, "label") orelse "";
    const click = util.jsonObjectGetString(obj, "click") orelse "";
    const enabled = util.jsonObjectGetBool(obj, "enabled") orelse true;

    if (std.mem.eql(u8, typ, "submenu") or obj.get("submenu") != null) {
        const sub_val = obj.get("submenu") orelse return error.InvalidMenuItem;
        if (sub_val != .array) return error.InvalidMenuItem;
        return .{ .submenu = .{
            .label = label,
            .enabled = enabled,
            .items = try parseTrayMenuItems(arena, sub_val.array.items),
        } };
    }
    if (std.mem.eql(u8, typ, "checkbox")) {
        return .{ .checkbox = .{
            .label = label,
            .click = click,
            .checked = util.jsonObjectGetBool(obj, "checked") orelse false,
            .enabled = enabled,
        } };
    }
    return .{ .item = .{
        .label = label,
        .click = click,
        .enabled = enabled,
    } };
}

// ============================================
// webRequest — URL glob blocklist 등록
// ============================================

const WebRequestSetBlockedUrlsJson = struct {
    patterns: []const []const u8 = &.{},
};

fn handleWebRequestSetBlockedUrls(req_clean: []const u8, response_buf: []u8) ?[]const u8 {
    var arena_buf: [DIALOG_PARSE_ARENA]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arena_buf);
    const arena = fba.allocator();

    const parsed = std.json.parseFromSlice(WebRequestSetBlockedUrlsJson, arena, req_clean, .{
        .ignore_unknown_fields = true,
    }) catch {
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"web_request_set_blocked_urls\",\"success\":false,\"error\":\"parse\"}}",
            .{},
        ) catch null;
    };
    defer parsed.deinit();

    const n = cef.webRequestSetBlockedUrls(parsed.value.patterns);
    return std.fmt.bufPrint(
        response_buf,
        "{{\"from\":\"zig-core\",\"cmd\":\"web_request_set_blocked_urls\",\"count\":{d}}}",
        .{n},
    ) catch null;
}

fn handleWebRequestSetListenerFilter(req_clean: []const u8, response_buf: []u8) ?[]const u8 {
    var arena_buf: [DIALOG_PARSE_ARENA]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arena_buf);
    const arena = fba.allocator();

    const parsed = std.json.parseFromSlice(WebRequestSetBlockedUrlsJson, arena, req_clean, .{
        .ignore_unknown_fields = true,
    }) catch {
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"web_request_set_listener_filter\",\"success\":false,\"error\":\"parse\"}}",
            .{},
        ) catch null;
    };
    defer parsed.deinit();

    const n = cef.webRequestSetListenerFilter(parsed.value.patterns);
    return std.fmt.bufPrint(
        response_buf,
        "{{\"from\":\"zig-core\",\"cmd\":\"web_request_set_listener_filter\",\"count\":{d}}}",
        .{n},
    ) catch null;
}

/// Electron onBeforeSendHeaders (declarative) — urls glob + requestHeaders 객체.
/// patterns 는 std.json 파싱, requestHeaders 는 임의-키라 raw object 추출(네이티브가 unescape).
fn handleWebRequestSetRequestHeaders(req_clean: []const u8, response_buf: []u8) ?[]const u8 {
    var arena_buf: [DIALOG_PARSE_ARENA]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arena_buf);
    const arena = fba.allocator();

    const parsed = std.json.parseFromSlice(WebRequestSetBlockedUrlsJson, arena, req_clean, .{
        .ignore_unknown_fields = true,
    }) catch {
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"web_request_set_request_headers\",\"success\":false,\"error\":\"parse\"}}",
            .{},
        ) catch null;
    };
    defer parsed.deinit();

    const headers = util.extractJsonObjectRaw(req_clean, "requestHeaders") orelse "{}";
    const n = cef.webRequestSetRequestHeaders(parsed.value.patterns, headers);
    return std.fmt.bufPrint(
        response_buf,
        "{{\"from\":\"zig-core\",\"cmd\":\"web_request_set_request_headers\",\"count\":{d}}}",
        .{n},
    ) catch null;
}

// ============================================
// Global shortcut handlers
// ============================================

fn globalShortcutStatusToErrorCode(status: cef.GlobalShortcutStatus) []const u8 {
    return switch (status) {
        .ok => "",
        .capacity => "capacity_full",
        .duplicate => "already_registered",
        .parse => "parse_failed",
        .os_reject => "os_reject",
        .too_long => "too_long",
        .timed_out => "timed_out",
    };
}

fn handleGlobalShortcutRegister(req_clean: []const u8, response_buf: []u8) ?[]const u8 {
    var accel_buf: [128]u8 = undefined;
    const accel = extractEscapedField(req_clean, "accelerator", &accel_buf) orelse
        return coreError(response_buf, "global_shortcut_register", "accelerator");

    var click_buf: [128]u8 = undefined;
    const click = extractEscapedField(req_clean, "click", &click_buf) orelse
        return coreError(response_buf, "global_shortcut_register", "click");

    const status = cef.globalShortcutRegister(accel, click);
    if (status != .ok) return coreError(response_buf, "global_shortcut_register", globalShortcutStatusToErrorCode(status));
    return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"global_shortcut_register\",\"success\":true}}", .{}) catch null;
}

fn handleGlobalShortcutUnregister(req_clean: []const u8, response_buf: []u8) ?[]const u8 {
    var accel_buf: [128]u8 = undefined;
    const accel = extractEscapedField(req_clean, "accelerator", &accel_buf) orelse
        return coreError(response_buf, "global_shortcut_unregister", "accelerator");
    const ok = cef.globalShortcutUnregister(accel);
    return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"global_shortcut_unregister\",\"success\":{}}}", .{ok}) catch null;
}

fn handleGlobalShortcutIsRegistered(req_clean: []const u8, response_buf: []u8) ?[]const u8 {
    var accel_buf: [128]u8 = undefined;
    const accel = extractEscapedField(req_clean, "accelerator", &accel_buf) orelse
        return coreError(response_buf, "global_shortcut_is_registered", "accelerator");
    const registered = cef.globalShortcutIsRegistered(accel);
    return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"global_shortcut_is_registered\",\"registered\":{}}}", .{registered}) catch null;
}

// ============================================
// Application menu handlers — std.json.Value로 재귀 submenu 파싱
// ============================================

// getApplicationMenu(Electron Menu.getApplicationMenu) 용 — 마지막 set 한 items 배열 raw
// JSON 스냅샷. set 성공 시 저장, reset 시 클리어. SDK 가 getMenuItemById 를 이 위에 구현.
var g_app_menu_buf: [8192]u8 = undefined;
var g_app_menu_len: usize = 0;

fn storeAppMenuItems(req_clean: []const u8) void {
    const items = util.extractJsonArrayRaw(req_clean, "items") orelse "[]";
    if (items.len > g_app_menu_buf.len) {
        g_app_menu_len = 0; // 너무 큰 메뉴 — 스냅샷 미저장(getApplicationMenu 는 [])
        return;
    }
    @memcpy(g_app_menu_buf[0..items.len], items);
    g_app_menu_len = items.len;
}

fn handleMenuSetApplicationMenu(req_clean: []const u8, response_buf: []u8) ?[]const u8 {
    // submenu 깊이가 깊어질 수 있어 dialog 대비 2배 arena.
    var arena_buf: [DIALOG_PARSE_ARENA * 2]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arena_buf);
    const arena = fba.allocator();

    const items = parseMenuItemsFromRequest(arena, req_clean) catch return coreError(response_buf, "menu_set_application_menu", "parse");
    const ok = cef.setApplicationMenu(items);
    if (ok) storeAppMenuItems(req_clean);
    return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"menu_set_application_menu\",\"success\":{}}}", .{ok}) catch null;
}

/// Electron Menu.getApplicationMenu — 마지막 set 한 메뉴의 items 배열 스냅샷(없으면 []).
/// 라이브 mutation 아님(suji 메뉴는 fire-and-forget) — 정직 경계. getMenuItemById 는 SDK 가
/// 이 스냅샷을 파싱해 id 로 재귀 탐색.
fn handleMenuGetApplicationMenu(response_buf: []u8) ?[]const u8 {
    const items: []const u8 = if (g_app_menu_len > 0) g_app_menu_buf[0..g_app_menu_len] else "[]";
    return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"menu_get_application_menu\",\"items\":{s}}}", .{items}) catch null;
}

/// Electron `Menu.popup({x?,y?})` — 임의 위치 컨텍스트 메뉴. items 파싱은
/// menu_set_application_menu 와 동일(parseMenuItemsFromRequest). 선택은
/// 기존 `menu:click` 이벤트로 수신(setApplicationMenu 와 동일 경로).
fn handleMenuPopup(req_clean: []const u8, response_buf: []u8) ?[]const u8 {
    var arena_buf: [DIALOG_PARSE_ARENA * 2]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arena_buf);
    const arena = fba.allocator();

    const items = parseMenuItemsFromRequest(arena, req_clean) catch return coreError(response_buf, "menu_popup", "parse");
    const x = util.extractJsonFloat(req_clean, "x");
    const y = util.extractJsonFloat(req_clean, "y");
    const ok = cef.popupContextMenu(items, x, y);
    return std.fmt.bufPrint(response_buf, "{{\"from\":\"zig-core\",\"cmd\":\"menu_popup\",\"success\":{}}}", .{ok}) catch null;
}

fn parseMenuItemsFromRequest(arena: std.mem.Allocator, req_clean: []const u8) MenuParseError![]cef.ApplicationMenuItem {
    // FixedBufferAllocator로 알로케이션이 끝난 뒤 arena 전체가 한 번에 회수되므로
    // parsed.deinit()은 no-op. 따라서 호출하지 않는다.
    const parsed = std.json.parseFromSlice(std.json.Value, arena, req_clean, .{}) catch return error.InvalidMenuItem;
    if (parsed.value != .object) return error.InvalidMenuItem;
    const items_val = parsed.value.object.get("items") orelse return error.InvalidMenuItem;
    if (items_val != .array) return error.InvalidMenuItem;
    return parseApplicationMenuItems(arena, items_val.array.items);
}

const MenuParseError = error{ OutOfMemory, InvalidMenuItem };

fn parseApplicationMenuItems(arena: std.mem.Allocator, values: []const std.json.Value) MenuParseError![]cef.ApplicationMenuItem {
    var out = try arena.alloc(cef.ApplicationMenuItem, values.len);
    for (values, 0..) |v, i| out[i] = try parseApplicationMenuItem(arena, v);
    return out;
}

fn parseApplicationMenuItem(arena: std.mem.Allocator, value: std.json.Value) MenuParseError!cef.ApplicationMenuItem {
    if (value != .object) return error.InvalidMenuItem;
    const obj = value.object;
    const typ = util.jsonObjectGetString(obj, "type") orelse "";
    if (std.mem.eql(u8, typ, "separator")) return .separator;

    const label = util.jsonObjectGetString(obj, "label") orelse "";
    const click = util.jsonObjectGetString(obj, "click") orelse "";
    const enabled = util.jsonObjectGetBool(obj, "enabled") orelse true;
    const id = util.jsonObjectGetString(obj, "id") orelse "";
    const visible = util.jsonObjectGetBool(obj, "visible") orelse true;
    const accelerator = util.jsonObjectGetString(obj, "accelerator") orelse "";
    const role = util.jsonObjectGetString(obj, "role") orelse "";
    // icon 은 렌더러 경로 → fs sandbox 게이트(per-item, 차단 시 아이콘만 drop, 메뉴 유지).
    const icon_raw = util.jsonObjectGetString(obj, "icon") orelse "";
    const icon = if (menuIconPathAllowed(icon_raw)) icon_raw else "";

    if (std.mem.eql(u8, typ, "submenu") or obj.get("submenu") != null) {
        const sub_val = obj.get("submenu") orelse return error.InvalidMenuItem;
        if (sub_val != .array) return error.InvalidMenuItem;
        return .{ .submenu = .{
            .label = label,
            .enabled = enabled,
            .items = try parseApplicationMenuItems(arena, sub_val.array.items),
            .id = id,
            .visible = visible,
        } };
    }
    if (std.mem.eql(u8, typ, "checkbox")) {
        return .{ .checkbox = .{
            .label = label,
            .click = click,
            .checked = util.jsonObjectGetBool(obj, "checked") orelse false,
            .enabled = enabled,
            .id = id,
            .visible = visible,
            .accelerator = accelerator,
            .icon = icon,
        } };
    }
    return .{ .item = .{
        .label = label,
        .click = click,
        .enabled = enabled,
        .id = id,
        .visible = visible,
        .accelerator = accelerator,
        .role = role,
        .icon = icon,
    } };
}

/// MenuItem.icon 경로 fs sandbox 게이트 — rendererPathAllowed 공용 술어 재사용. per-item
/// 이라 차단 시 아이콘만 drop(메뉴 자체는 유지). 빈 경로(아이콘 없음)는 무조건 허용.
fn menuIconPathAllowed(path: []const u8) bool {
    return path.len == 0 or rendererPathAllowed(path);
}

/// notification id 카운터 — `suji-notif-{N}` 형식 식별자 발급.
var g_next_notification_id: u32 = 1;

fn nextNotificationId() u32 {
    const id = g_next_notification_id;
    g_next_notification_id += 1;
    return id;
}

/// cef.zig native click target이 NSApp UI thread에서 호출 → BackendRegistry.global 안전 access.
/// data는 호출자가 std.fmt 포맷으로 미리 빌드한 JSON 페이로드.
/// 1KB 버퍼 — 일반 emit은 ~50B, 가장 큰 정규 caller(globalShortcut: accel256+click256 escape)도
/// ~570B로 충분. page-title-updated는 worst-case ~1.5KB라 자체 버퍼로 emitBusRaw 직행.
fn emitToBus(channel: []const u8, comptime fmt: []const u8, args: anytype) void {
    var data_buf: [1024]u8 = undefined;
    const data = std.fmt.bufPrint(&data_buf, fmt, args) catch return;
    emitBusRaw(channel, data);
}

/// 이미 빌드된 JSON 페이로드를 EventBus로 직접 전달 — 큰 페이로드(page-title-updated 등)가
/// emitToBus의 1KB 버퍼를 우회해 자체 스택 버퍼를 쓸 수 있게 한다.
fn emitBusRaw(channel: []const u8, data: []const u8) void {
    const registry = suji.BackendRegistry.global orelse return;
    const bus = registry.event_bus orelse return;
    bus.emit(channel, data);
}

fn notificationEmitHandler(notification_id: []const u8) void {
    var id_esc: [128]u8 = undefined;
    const id_n = util.escapeJsonStrFull(notification_id, &id_esc) orelse return;
    emitToBus("notification:click", "{{\"notificationId\":\"{s}\"}}", .{id_esc[0..id_n]});
}

fn trayEmitHandler(tray_id: u32, click: []const u8) void {
    var click_esc: [256]u8 = undefined;
    const click_n = util.escapeJsonStrFull(click, &click_esc) orelse return;
    emitToBus("tray:menu-click", "{{\"trayId\":{d},\"click\":\"{s}\"}}", .{ tray_id, click_esc[0..click_n] });
}

fn menuEmitHandler(click: []const u8) void {
    var click_esc: [256]u8 = undefined;
    const click_n = util.escapeJsonStrFull(click, &click_esc) orelse return;
    emitToBus("menu:click", "{{\"click\":\"{s}\"}}", .{click_esc[0..click_n]});
}

/// menu:will-show / menu:will-close — context-menu popup 라이프사이클(빈 payload).
/// channel 은 cef_menu 가 고정 문자열로 전달(escape 불요). UI 스레드, emitBusRaw thread-safe.
fn menuLifecycleEmitHandler(channel: []const u8) void {
    emitBusRaw(channel, "{}");
}

// screen display 변경 → `screen:display-added`/`display-removed`/`display-metrics-changed`.
// (screenChangedC 가 count diff 후 Zig 호출 — C 콜백 아님이라 callconv(.c) 불요.)
fn screenEmitHandler(event: [*:0]const u8) void {
    var ch_buf: [64]u8 = undefined;
    const channel = std.fmt.bufPrint(&ch_buf, "screen:{s}", .{std.mem.span(event)}) catch return;
    emitBusRaw(channel, "{}");
}

/// powerMonitor: power_monitor.m이 dispatch한 이벤트(suspend/resume/lock-screen/unlock-screen
/// + macOS shutdown/on-battery/on-ac)를 `power:<event>` 채널로 emit.
fn powerMonitorEmitHandler(event: [*:0]const u8) callconv(.c) void {
    const event_slice = std.mem.span(event);
    // 화면 잠금 상태 추적 — getSystemIdleState "locked" 판정용(Electron 동등).
    if (std.mem.eql(u8, event_slice, "lock-screen")) {
        cef.powerMonitorSetScreenLocked(true);
    } else if (std.mem.eql(u8, event_slice, "unlock-screen")) {
        cef.powerMonitorSetScreenLocked(false);
    }
    var ch_buf: [64]u8 = undefined;
    const channel = std.fmt.bufPrint(&ch_buf, "power:{s}", .{event_slice}) catch return;
    emitBusRaw(channel, "{}");
}

/// second-instance: 두 번째 인스턴스가 보낸 argv(JSON 배열)를 받아 `app:second-instance`
/// 채널로 emit. argv 는 secondary 가 setLaunchArgv 로 넣은 JSON 배열 문자열(escape 완료).
/// accept 스레드(임의 스레드)에서 호출되지만 emitBusRaw 가 EventBus mutex 로 thread-safe.
fn secondInstanceEmitHandler(argv: [*:0]const u8) callconv(.c) void {
    const argv_json = std.mem.span(argv);
    const aj: []const u8 = if (argv_json.len == 0) "[]" else argv_json;
    var buf: [4160]u8 = undefined;
    const payload = std.fmt.bufPrint(&buf, "{{\"argv\":{s}}}", .{aj}) catch return;
    emitBusRaw("app:second-instance", payload);
}

/// nativeTheme: NSAppearance KVO가 fire되면 현재 dark 여부를 payload로 emit.
fn nativeThemeEmitHandler() callconv(.c) void {
    const dark = cef.nativeThemeIsDark();
    var buf: [64]u8 = undefined;
    const payload = std.fmt.bufPrint(&buf, "{{\"dark\":{}}}", .{dark}) catch return;
    emitBusRaw("nativeTheme:updated", payload);
}

/// webRequest: cef.zig의 onBeforeResourceLoad/onResourceLoadComplete가 IO thread에서
/// 호출. EventBus.emit이 mutex로 thread-safe하므로 그대로 dispatch.
fn webRequestEmitHandler(channel: [*:0]const u8, payload: [*:0]const u8) callconv(.c) void {
    const ch = std.mem.span(channel);
    const data = std.mem.span(payload);
    emitBusRaw(ch, data);
}

/// session.setPermissionRequestHandler: on_show/on_dismiss_permission_prompt(UI 스레드)가
/// 발신. EventBus.emit 이 mutex 로 thread-safe 하므로 그대로 dispatch(webRequest 동형).
fn permissionEmitHandler(channel: [*:0]const u8, payload: [*:0]const u8) callconv(.c) void {
    emitBusRaw(std.mem.span(channel), std.mem.span(payload));
}

fn downloadEmitHandler(channel: [*:0]const u8, payload: [*:0]const u8) callconv(.c) void {
    emitBusRaw(std.mem.span(channel), std.mem.span(payload));
}

/// Electron `app.on('before-quit')` — quit 직전 1회 발신(cef.quit chokepoint).
fn beforeQuitHandler() callconv(.c) void {
    emitBusRaw("app:before-quit", "{}");
}

/// Electron webContents.setWindowOpenHandler — popup 마다 web-contents:new-window 발신.
fn windowOpenEmitHandler(channel: [*:0]const u8, payload: [*:0]const u8) callconv(.c) void {
    emitBusRaw(std.mem.span(channel), std.mem.span(payload));
}

fn globalShortcutEmitHandler(accelerator: []const u8, click: []const u8) void {
    var accel_esc: [256]u8 = undefined;
    var click_esc: [256]u8 = undefined;
    const accel_n = util.escapeJsonStrFull(accelerator, &accel_esc) orelse return;
    const click_n = util.escapeJsonStrFull(click, &click_esc) orelse return;
    emitToBus("globalShortcut:trigger", "{{\"accelerator\":\"{s}\",\"click\":\"{s}\"}}", .{ accel_esc[0..accel_n], click_esc[0..click_n] });
}

/// CEF browser native handle → WindowManager.windowId 변환 helper.
fn windowIdFromHandle(handle: u64) ?u32 {
    const wm = window_mod.WindowManager.global orelse return null;
    return wm.findByNativeHandle(handle);
}

fn windowResizedHandler(handle: u64, x: f64, y: f64, width: f64, height: f64) void {
    const win_id = windowIdFromHandle(handle) orelse return;
    emitToBus("window:resized", "{{\"windowId\":{d},\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d}}}", .{ win_id, @as(i64, @intFromFloat(x)), @as(i64, @intFromFloat(y)), @as(i64, @intFromFloat(width)), @as(i64, @intFromFloat(height)) });
}

fn windowMovedHandler(handle: u64, x: f64, y: f64) void {
    const win_id = windowIdFromHandle(handle) orelse return;
    emitToBus("window:moved", "{{\"windowId\":{d},\"x\":{d},\"y\":{d}}}", .{ win_id, @as(i64, @intFromFloat(x)), @as(i64, @intFromFloat(y)) });
}

/// `{windowId}` 단일 필드 이벤트 발화 — focus/blur/minimize/restore/maximize/
/// unmaximize/enter-full-screen/leave-full-screen 공통.
fn emitWindowIdEvent(comptime channel: []const u8, handle: u64) void {
    const win_id = windowIdFromHandle(handle) orelse return;
    emitToBus(channel, "{{\"windowId\":{d}}}", .{win_id});
}

fn windowFocusHandler(handle: u64) void {
    emitWindowIdEvent("window:focus", handle);
}
fn windowBlurHandler(handle: u64) void {
    emitWindowIdEvent("window:blur", handle);
}
fn windowMinimizeHandler(handle: u64) void {
    emitWindowIdEvent(window_mod.events.minimize, handle);
}
fn windowRestoreHandler(handle: u64) void {
    emitWindowIdEvent(window_mod.events.restore, handle);
}
fn windowMaximizeHandler(handle: u64) void {
    emitWindowIdEvent(window_mod.events.maximize, handle);
}
fn windowUnmaximizeHandler(handle: u64) void {
    emitWindowIdEvent(window_mod.events.unmaximize, handle);
}
fn windowEnterFullScreenHandler(handle: u64) void {
    emitWindowIdEvent(window_mod.events.enter_full_screen, handle);
}
fn windowLeaveFullScreenHandler(handle: u64) void {
    emitWindowIdEvent(window_mod.events.leave_full_screen, handle);
}

fn windowWillResizeHandler(handle: u64, curr_w: f64, curr_h: f64, proposed_w: *f64, proposed_h: *f64) void {
    const wm = window_mod.WindowManager.global orelse return;
    wm.applyWillResizeForHandle(handle, curr_w, curr_h, proposed_w, proposed_h);
}

/// CEF find_handler.OnFindResult는 incremental(검색 진행) + final 두 종류로 발화. final만
/// frontend에 forward해 검색어 입력 중 noise 차단 (Electron의 `found-in-page` 의도와 동일).
fn windowFindResultHandler(handle: u64, identifier: i32, count: i32, active_match_ordinal: i32, final_update: bool) void {
    if (!final_update) return;
    const win_id = windowIdFromHandle(handle) orelse return;
    emitToBus(
        window_mod.events.find_result,
        "{{\"windowId\":{d},\"identifier\":{d},\"count\":{d},\"activeMatchOrdinal\":{d},\"finalUpdate\":true}}",
        .{ win_id, identifier, count, active_match_ordinal },
    );
}

/// `app.quitOnAllWindowsClosed: true` 시 EventBus에 등록되는 listener — window:all-closed 발화 시
/// 자동으로 cef.quit() 호출. C ABI라 ([*c]u8, [*c]u8, ?*anyopaque) 시그니처.
fn allClosedAutoQuit(_: [*c]const u8, _: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
    cef.quit();
}

fn windowReadyToShowHandler(handle: u64) void {
    emitWindowIdEvent(window_mod.events.ready_to_show, handle);
}

fn windowTitleChangeHandler(handle: u64, title: []const u8) void {
    const win_id = windowIdFromHandle(handle) orelse return;
    // JSON escape 최악 6×(`\uXXXX`) — cef.MAX_TITLE_BYTES와 페어. emitToBus의 1KB 버퍼는
    // 이 케이스(~1.5KB)를 못 담아서 자체 페이로드 버퍼로 emitBusRaw 직행. escape 결과를
    // payload_buf 안에 직접 써 중간 버퍼 한 단계 제거.
    var payload_buf: [cef.MAX_TITLE_BYTES * 6 + 64]u8 = undefined;
    const prefix = std.fmt.bufPrint(&payload_buf, "{{\"windowId\":{d},\"title\":\"", .{win_id}) catch return;
    const after_prefix = prefix.len;
    const escape_room = payload_buf.len - after_prefix - 2; // "\"}" 마진
    const title_n = util.escapeJsonStrFull(title, payload_buf[after_prefix..][0..escape_room]) orelse {
        std.debug.print(
            "[suji] page-title-updated: escape overflow (title bytes={d}) — event dropped\n",
            .{title.len},
        );
        return;
    };
    const tail = after_prefix + title_n;
    payload_buf[tail] = '"';
    payload_buf[tail + 1] = '}';
    emitBusRaw(window_mod.events.page_title_updated, payload_buf[0 .. tail + 2]);
}

const window_lifecycle_handlers: cef.WindowLifecycleHandlers = .{
    .resized = &windowResizedHandler,
    .moved = &windowMovedHandler,
    .focus = &windowFocusHandler,
    .blur = &windowBlurHandler,
    .minimize = &windowMinimizeHandler,
    .restore = &windowRestoreHandler,
    .maximize = &windowMaximizeHandler,
    .unmaximize = &windowUnmaximizeHandler,
    .enter_fullscreen = &windowEnterFullScreenHandler,
    .leave_fullscreen = &windowLeaveFullScreenHandler,
    .will_resize = &windowWillResizeHandler,
};

fn handleDialogShowSaveDialog(req_clean: []const u8, response_buf: []u8) ?[]const u8 {
    var arena_buf: [DIALOG_PARSE_ARENA]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arena_buf);
    const arena = fba.allocator();

    const parsed = std.json.parseFromSlice(SaveDialogJson, arena, req_clean, .{
        .ignore_unknown_fields = true,
    }) catch {
        return std.fmt.bufPrint(
            response_buf,
            "{{\"from\":\"zig-core\",\"cmd\":\"dialog_show_save_dialog\",\"canceled\":true,\"filePath\":\"\",\"error\":\"parse\"}}",
            .{},
        ) catch null;
    };
    defer parsed.deinit();
    const opts = parsed.value;

    if (dialogPathGate(response_buf, "dialog_show_save_dialog", opts.defaultPath)) |e| return e;

    const filters = convertFilters(arena, opts.filters) catch &[_]cef.FileFilter{};
    var dialog_buf: [util.MAX_RESPONSE]u8 = undefined;
    const dialog_json = cef.showSaveDialog(.{
        .title = opts.title,
        .default_path = opts.defaultPath,
        .button_label = opts.buttonLabel,
        .message = opts.message,
        .name_field_label = opts.nameFieldLabel,
        .shows_hidden_files = hasProp(opts.properties, "showHiddenFiles"),
        .can_create_directories = !hasProp(opts.properties, "createDirectory") or hasProp(opts.properties, "createDirectory"),
        .show_overwrite_confirmation = !hasProp(opts.properties, "noOverwriteConfirmation"),
        .shows_tag_field = opts.showsTagField,
        .filters = filters,
        .parent_window = dialogParentNSWindow(opts.windowId),
    }, &dialog_buf);

    return std.fmt.bufPrint(
        response_buf,
        "{{\"from\":\"zig-core\",\"cmd\":\"dialog_show_save_dialog\",{s}",
        .{dialog_json[1..]},
    ) catch null;
}

// JSON 필드 추출은 core/util.zig(util.extractJsonString / util.extractJsonInt) 사용

/// JSON 이스케이프 복원: \" → ", \\ → \
fn unescapeJson(src: []const u8, buf: []u8) []const u8 {
    var i: usize = 0;
    var o: usize = 0;
    while (i < src.len and o < buf.len) {
        if (src[i] == '\\' and i + 1 < src.len) {
            buf[o] = switch (src[i + 1]) {
                '"' => '"',
                '\\' => '\\',
                'n' => '\n',
                else => src[i + 1],
            };
            i += 2;
        } else {
            buf[o] = src[i];
            i += 1;
        }
        o += 1;
    }
    return buf[0..o];
}

/// CEF emit 콜백 — EventBus로 전달. target이 있으면 해당 창만(webContents.send).
fn cefEmitHandler(target: ?u32, event: []const u8, data: []const u8) void {
    const registry = suji.BackendRegistry.global orelse return;
    const bus = registry.event_bus orelse return;
    if (target) |id| {
        bus.emitTo(id, event, data);
    } else {
        bus.emit(event, data);
    }
}

/// dist 디렉토리 절대 경로 탐색 (로컬 → .app/AppImage 번들)
fn findDistPath(allocator: std.mem.Allocator, dist_dir: []const u8) ?[]const u8 {
    // realPathFileAlloc 가 sentinel 포함 [:0]u8 (alloc N+1) 을 반환 — caller 가
    // []const u8 로 받아 free 하면 size mismatch panic. dupe 로 length-exact 재할당.
    const dupe = struct {
        fn run(a: std.mem.Allocator, sentinel: [:0]u8) ?[]const u8 {
            defer a.free(sentinel);
            return a.dupe(u8, sentinel) catch null;
        }
    }.run;

    // 1. CWD 기준 (로컬 개발)
    if (std.Io.Dir.cwd().realPathFileAlloc(runtime.io, dist_dir, allocator)) |p| return dupe(allocator, p) else |_| {}

    // 2. .app 번들: exe/../Resources/frontend/dist
    var exe_buf: [1024]u8 = undefined;
    const exe_len = std.process.executablePath(runtime.io, &exe_buf) catch return null;
    const exe_path = exe_buf[0..exe_len];
    const macos_dir = std.fs.path.dirname(exe_path) orelse return null;
    const contents_dir = std.fs.path.dirname(macos_dir) orelse return null;

    const bundle_dist = std.fmt.allocPrint(allocator, "{s}/Resources/frontend/dist", .{contents_dir}) catch return null;
    defer allocator.free(bundle_dist);
    if (std.Io.Dir.cwd().realPathFileAlloc(runtime.io, bundle_dist, allocator)) |p| return dupe(allocator, p) else |_| {}

    // 3. .app 번들: Resources/frontend (dist 없이)
    const bundle_frontend = std.fmt.allocPrint(allocator, "{s}/Resources/frontend", .{contents_dir}) catch return null;
    defer allocator.free(bundle_frontend);
    if (std.Io.Dir.cwd().realPathFileAlloc(runtime.io, bundle_frontend, allocator)) |p| return dupe(allocator, p) else |_| {}

    // 3.5. Windows packaged: <exe_dir>/resources/frontend (소문자 r). packageWindows
    // 가 만드는 layout — macOS 의 macos_dir/contents_dir 계층 대신 단순 flat.
    if (builtin.os.tag == .windows) {
        const exe_dir_win = std.fs.path.dirname(exe_path) orelse return null;
        const win_pkg_dist = std.fmt.allocPrint(allocator, "{s}/resources/frontend/dist", .{exe_dir_win}) catch return null;
        defer allocator.free(win_pkg_dist);
        if (std.Io.Dir.cwd().realPathFileAlloc(runtime.io, win_pkg_dist, allocator)) |p| return dupe(allocator, p) else |_| {}
        const win_pkg_frontend = std.fmt.allocPrint(allocator, "{s}/resources/frontend", .{exe_dir_win}) catch return null;
        defer allocator.free(win_pkg_frontend);
        if (std.Io.Dir.cwd().realPathFileAlloc(runtime.io, win_pkg_frontend, allocator)) |p| return dupe(allocator, p) else |_| {}
    }

    // 4. Linux AppImage/AppDir: AppDir/usr/bin/<exe> + AppDir/usr/resources/frontend.
    if (builtin.os.tag == .linux) {
        const bin_dir = std.fs.path.dirname(exe_path) orelse return null;
        const usr_dir = std.fs.path.dirname(bin_dir) orelse return null;
        const appdir_resources_dist = std.fmt.allocPrint(allocator, "{s}/resources/frontend/dist", .{usr_dir}) catch return null;
        defer allocator.free(appdir_resources_dist);
        if (std.Io.Dir.cwd().realPathFileAlloc(runtime.io, appdir_resources_dist, allocator)) |p| return dupe(allocator, p) else |_| {}

        const appdir_resources_frontend = std.fmt.allocPrint(allocator, "{s}/resources/frontend", .{usr_dir}) catch return null;
        defer allocator.free(appdir_resources_frontend);
        if (std.Io.Dir.cwd().realPathFileAlloc(runtime.io, appdir_resources_frontend, allocator)) |p| return dupe(allocator, p) else |_| {}
    }

    return null;
}
