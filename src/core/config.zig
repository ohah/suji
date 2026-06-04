const std = @import("std");
const runtime = @import("runtime");
const window_mod = @import("window");
const util = @import("util");
const crash_reporter = @import("crash_reporter.zig");

/// Suji 프로젝트 설정
/// suji.json 에서 로드 (정적 JSON 단일 출처 — 모든 백엔드 언어가 node 없이 읽음).
pub const Config = struct {
    app: App = .{},
    /// 시작 시 자동 생성할 창 목록. 첫 항목이 main 창 (CEF 초기화 시 사이즈/타이틀 사용).
    /// config에 `windows` 배열이 없거나 비어있으면 default 1개.
    windows: []const Window = &.{Window{}},
    backend: ?SingleBackend = null,
    backends: ?[]const MultiBackend = null,
    plugins: ?[]const Plugin = null,
    asset_dir: [:0]const u8 = "assets",
    frontend: Frontend = .{},
    fs: Fs = .{},
    shell: Shell = .{},
    dialog: Dialog = .{},
    security: Security = .{},

    // _arena는 포인터로 보관. 값으로 담으면 `Config { ._arena = arena }` 시점에 arena의
    // 내부 state(buffer 리스트 head)가 COPY되고, 이후 동일 arena를 거치는 할당(예:
    // parseFromSlice 내부)은 stack-local 원본만 갱신 → return으로 스택이 사라지면 그 뒤에
    // 할당된 buffer가 deinit 경로에 잡히지 않아 leak.
    _arena: ?*std.heap.ArenaAllocator = null,

    pub const App = struct {
        name: [:0]const u8 = "Suji App",
        version: [:0]const u8 = "0.1.0",
        /// 사용자 추가 entitlements plist 경로 — Suji default helper별 entitlements 대신
        /// 모든 binary에 단독 적용 (예: `app.entitlements: "my-app.entitlements"`).
        /// 비어있으면 Suji default (assets/entitlements/{main,helper,helper-{gpu,renderer,plugin}}.plist).
        entitlements: ?[:0]const u8 = null,
        /// 번들에 포함할 CEF locale (`en`, `ko` 등). 비어있으면 default `["en"]`만 →
        /// ~110MB 절약. `["*"]`면 220개 전부 (i18n 앱).
        locales: []const [:0]const u8 = &.{},
        /// CEF framework binary strip — debug symbols 제거 (~30MB 절약). default true.
        strip_cef: bool = true,
        /// macOS 최소 배포 타겟(`app.minimumSystemVersion`). Info.plist `LSMinimumSystemVersion`
        /// + 메인 바이너리 `LC_BUILD_VERSION` minos(vtool) + Go 백엔드 `MACOSX_DEPLOYMENT_TARGET`
        /// 에 일관 적용 → 실효 floor(번들 내 mach-o minos 최댓값)가 한 값으로 모인다. 기본 "12.0".
        /// 번들 CEF 가 12.0 으로 프리빌트라 그 아래는 로드 불가 → 파싱 시 12.0 으로 clamp.
        /// macOS 빌드에서만 의미(Win/Linux 무시).
        macos_min_version: [:0]const u8 = "12.0",
        /// 마지막 창이 닫힐 때 (window:all-closed 발화 시점) 코어가 자동으로 cef.quit().
        /// default false — Electron canonical 패턴(`suji.on("window:all-closed", ...)`로 user
        /// 코드가 platform 분기 후 quit 호출). true로 설정 시 모든 플랫폼에서 자동 종료.
        /// 두 경로(user code + 코어)가 동시에 발화해도 cef.quit()이 idempotent라 안전.
        quit_on_all_windows_closed: bool = false,
        /// 딥링크 URL scheme (Electron `protocol.registerSchemesAsPrivileged` +
        /// macOS `CFBundleURLTypes`). 비어있으면 미주입. 예: `["myapp"]` →
        /// `myapp://...` 가 OS 레벨에서 이 앱으로 라우팅(.app 번들 한정).
        deep_link_schemes: []const [:0]const u8 = &.{},
        /// CEF Crashpad/Breakpad startup config. CEF는 initialize 전에
        /// `crash_reporter.cfg`를 읽으므로 설정이 있으면 시작 전 cfg를 생성한다.
        crash_reporter: ?CrashReporter = null,

        pub const CrashReporter = struct {
            enabled: bool = true,
            product_name: ?[:0]const u8 = null,
            submit_url: ?[:0]const u8 = null,
            upload_to_server: bool = true,
            ignore_system_crash_handler: bool = false,
            rate_limit: bool = true,
            max_uploads_per_day: u32 = 5,
            max_database_size_mb: u32 = 20,
            max_database_age_days: u32 = 5,
            extra: []const crash_reporter.ExtraParam = &.{},
            global_extra: []const crash_reporter.ExtraParam = &.{},

            pub fn toOptions(self: CrashReporter, app_name: []const u8, app_version: []const u8) crash_reporter.Options {
                return .{
                    .enabled = self.enabled,
                    .product_name = self.product_name orelse app_name,
                    .product_version = app_version,
                    .app_name = app_name,
                    .submit_url = self.submit_url,
                    .upload_to_server = self.upload_to_server,
                    .ignore_system_crash_handler = self.ignore_system_crash_handler,
                    .rate_limit = self.rate_limit,
                    .max_uploads_per_day = self.max_uploads_per_day,
                    .max_database_size_mb = self.max_database_size_mb,
                    .max_database_age_days = self.max_database_age_days,
                    .extra = self.extra,
                    .global_extra = self.global_extra,
                };
            }
        };
    };

    pub const Protocol = enum { suji, file };

    pub const Window = struct {
        /// WM 등록 이름 (singleton 키). null이면 익명. 첫 창의 기본값은 "main".
        name: ?[:0]const u8 = null,
        title: [:0]const u8 = "Suji App",
        width: i64 = 1024,
        height: i64 = 768,
        /// 초기 위치 (px). 0이면 OS cascade 자동 배치.
        x: i64 = 0,
        y: i64 = 0,
        debug: bool = false,
        protocol: Protocol = .file,
        /// 시작 시 자동 로드할 URL. null이면 frontend dev_url/dist 자동 선택 (첫 창에만 적용).
        url: ?[:0]const u8 = null,
        /// false면 hidden 상태로 생성 (Phase 3+에서 setVisible과 연동 예정).
        visible: bool = true,
        /// 부모 창 이름. wm.fromName으로 lookup → CreateOptions.parent_id 세팅.
        parent: ?[:0]const u8 = null,
        // ── 외형 (window.Appearance와 동일 의미; 단 background_color는 arena가 소유한 [:0]). ──
        frame: bool = true,
        transparent: bool = false,
        background_color: ?[:0]const u8 = null,
        title_bar_style: TitleBarStyle = .default,
        // ── 제약 (window.Constraints와 동일). ──
        resizable: bool = true,
        always_on_top: bool = false,
        min_width: u32 = 0,
        min_height: u32 = 0,
        max_width: u32 = 0,
        max_height: u32 = 0,
        fullscreen: bool = false,
    };

    pub const TitleBarStyle = window_mod.TitleBarStyle;

    pub const SingleBackend = struct {
        lang: [:0]const u8 = "zig",
        entry: [:0]const u8 = "src/main.zig",
    };

    pub const MultiBackend = struct {
        name: [:0]const u8,
        lang: [:0]const u8,
        entry: [:0]const u8,
    };

    pub const Plugin = struct {
        name: [:0]const u8,
        source: ?[:0]const u8 = null,
        /// null = legacy/unrestricted. [] = explicit deny-all outbound invoke.
        permissions: ?[]const [:0]const u8 = null,
    };

    pub const Frontend = struct {
        dir: [:0]const u8 = "frontend",
        dev_url: [:0]const u8 = "http://localhost:12300",
        dev_command: [:0]const u8 = "bun run dev",
        build_command: [:0]const u8 = "bun run build",
        dist_dir: [:0]const u8 = "frontend/dist",
    };

    /// File system sandbox (Electron `webPreferences.sandbox` 대응).
    /// frontend(renderer)에서 호출되는 fs.* cmd가 검증 대상. backend는 항상 무제한.
    /// allowedRoots 비어있으면 frontend fs 완전 차단. ["*"] = unrestricted (escape hatch).
    pub const Fs = struct {
        allowed_roots: []const [:0]const u8 = &.{},
    };

    /// renderer shell.* allowlist. **opt-in** — fs(default-deny)와 달리 shell 은
    /// 그동안 무제한 출하라 키 부재 시 동작 불변(레거시 무제한)으로 비파괴.
    /// 키 존재 시 enforce: `[]`=전부 차단, `["*"]`=전부 허용, 특정=제한.
    /// null = suji.json 에 키 없음(레거시 허용), non-null = enforce.
    pub const Shell = struct {
        /// shell_open_path / show_item_in_folder / trash_item 의 path (fs 동일 prefix+boundary).
        allowed_paths: ?[]const [:0]const u8 = null,
        /// shell_open_external 의 url (glob — util.matchGlob, `~` expand 안 함).
        allowed_external_urls: ?[]const [:0]const u8 = null,
    };

    /// renderer dialog.* allowlist (opt-in, Shell 과 동일 semantics). open/save
    /// 의 defaultPath 만 제약 — 다이얼로그 자체는 사용자 중재라 빈 defaultPath 는 무제약.
    pub const Dialog = struct {
        allowed_paths: ?[]const [:0]const u8 = null,
    };

    /// 보안 정책 — `suji://` custom protocol 응답에 적용되는 헤더.
    /// csp 비어있으면 cef.zig의 default CSP 적용 (iframe_allowed_origins로 frame-src 합성).
    /// CSP 비활성화는 csp `"disabled"` 명시. iframe_allowed_origins 빈 배열이면 모든 iframe 차단,
    /// `["*"]`이면 무제한.
    pub const Security = struct {
        csp: ?[:0]const u8 = null,
        iframe_allowed_origins: []const [:0]const u8 = &.{},
    };

    /// 시작 시 자동 생성할 창의 최대 개수.
    /// 사용자가 실수로 큰 배열을 넣어도 시작 hang/OOM 방지 (각 창은 NSWindow + GPU surface 생성).
    /// 런타임에 추가 창이 필요하면 wm.create / create_window IPC로 만들 수 있음.
    pub const MAX_STARTUP_WINDOWS: usize = 32;

    pub fn load(allocator: std.mem.Allocator) !Config {
        return loadConfigFile(allocator);
    }

    pub fn deinit(self: *Config) void {
        if (self._arena) |arena| {
            const child = arena.child_allocator;
            arena.deinit();
            child.destroy(arena);
            self._arena = null;
        }
    }

    fn dupeStr(a: std.mem.Allocator, s: []const u8) [:0]const u8 {
        return a.dupeZ(u8, s) catch @ptrCast(s);
    }

    /// macOS 최소 배포 타겟을 CEF 프리빌트 floor(12.0) 이상으로 보정. 번들 CEF 프레임워크가
    /// 12.0 으로 빌드돼 있어 그보다 낮게 선언하면 그 macOS 에선 CEF 로드 실패(Info.plist 만
    /// 거짓으로 낮아짐). major < 12 이면 "12.0" 으로 올리고 경고. 12.x 이상은 그대로 둔다.
    fn clampMacosVersion(a: std.mem.Allocator, raw: []const u8) [:0]const u8 {
        var it = std.mem.splitScalar(u8, raw, '.');
        const major = std.fmt.parseInt(u32, it.next() orelse "", 10) catch 0;
        if (major < 12) {
            std.debug.print("[suji] warn: app.minimumSystemVersion '{s}' < 12.0 (CEF floor) → 12.0 으로 보정\n", .{raw});
            return dupeStr(a, "12.0");
        }
        return dupeStr(a, raw);
    }

    /// `~` / `~/path` 만 확장. `~user/foo` 같은 POSIX 형태는 명시 거부 (보안 — 잘못된
    /// expand로 sandbox bypass 위험). "*" sentinel은 그대로 보존.
    fn expandHomeAtLoad(a: std.mem.Allocator, raw: []const u8) [:0]const u8 {
        if (raw.len == 0) return dupeStr(a, raw);
        if (std.mem.eql(u8, raw, "*")) return dupeStr(a, raw);
        if (raw[0] != '~') return dupeStr(a, raw);
        if (raw.len > 1 and raw[1] != '/' and raw[1] != '\\') return dupeStr(a, raw);
        const home_key: []const u8 = if (@import("builtin").os.tag == .windows) "USERPROFILE" else "HOME";
        const home = runtime.env(home_key) orelse return dupeStr(a, raw);
        const rest = raw[1..];
        const total = home.len + rest.len;
        const buf = a.alloc(u8, total + 1) catch return dupeStr(a, raw);
        @memcpy(buf[0..home.len], home);
        @memcpy(buf[home.len..total], rest);
        buf[total] = 0;
        return buf[0..total :0];
    }

    /// JSON string 배열 → `[:0]const u8` 슬라이스. expand_home=true 면 path 로 보고
    /// `~` 사전 확장(fs allowedRoots 동일), false 면 raw(URL glob). non-array →
    /// 빈(non-null) 슬라이스 = enforce-deny-all (opt-in: 호출부가 키 존재 시에만 호출).
    fn parseAllowList(a: std.mem.Allocator, v: std.json.Value, expand_home: bool) []const [:0]const u8 {
        if (v != .array) return &.{};
        var list = std.ArrayList([:0]const u8).empty;
        for (v.array.items) |item| {
            if (item != .string) continue;
            const s = if (expand_home) expandHomeAtLoad(a, item.string) else dupeStr(a, item.string);
            list.append(a, s) catch continue;
        }
        return list.toOwnedSlice(a) catch &.{};
    }

    fn parseCrashParams(a: std.mem.Allocator, v: std.json.Value) []const crash_reporter.ExtraParam {
        if (v != .object) return &.{};
        var list = std.ArrayList(crash_reporter.ExtraParam).empty;
        var it = v.object.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* != .string) continue;
            list.append(a, .{
                .key = dupeStr(a, entry.key_ptr.*),
                .value = dupeStr(a, entry.value_ptr.string),
            }) catch continue;
        }
        return list.toOwnedSlice(a) catch &.{};
    }

    // ============================================
    // JSON ObjectMap 필드 추출 헬퍼 — 16+ 회 반복되는 `if (m.get("X")) |v| if (v == .Y)` 패턴 단축.
    // 매 필드마다 (1) key 존재 (2) 타입 일치 두 가드를 하나로 묶음.
    // ============================================

    fn getStr(m: std.json.ObjectMap, key: []const u8) ?[]const u8 {
        const v = m.get(key) orelse return null;
        return if (v == .string) v.string else null;
    }

    fn getInt(m: std.json.ObjectMap, key: []const u8) ?i64 {
        const v = m.get(key) orelse return null;
        return if (v == .integer) v.integer else null;
    }

    fn getBool(m: std.json.ObjectMap, key: []const u8) ?bool {
        const v = m.get(key) orelse return null;
        return if (v == .bool) v.bool else null;
    }

    // util.nonNegU32 직접 사용 (이 모듈 내부 alias 불필요).

    pub const CONFIG_FILE_PATHS = [_][]const u8{
        "suji.json",
    };

    const CONFIG_JSON_MAX_BYTES = 1024 * 256;

    fn loadConfigFile(allocator: std.mem.Allocator) !Config {
        var path_buf: [1200]u8 = undefined;
        const config_path = findConfigFilePath(&path_buf) orelse return error.ConfigNotFound;
        return loadJsonConfigFile(allocator, config_path);
    }

    /// suji.json 탐색. (1) CWD — 로컬 dev. (2) 패키지된 앱의 실행파일 기준 Resources —
    /// 프로덕션. 더블클릭/LaunchServices 는 CWD=/ 로 띄우므로 (1) 이 실패한다(빌드가 복사).
    /// 반환 경로가 `buf` 에 기록될 수 있어 호출 직후 access/read 에 바로 써야 한다.
    fn findConfigFilePath(buf: []u8) ?[]const u8 {
        // 1. CWD (로컬 개발) — 상대경로 그대로 반환.
        for (CONFIG_FILE_PATHS) |path| {
            std.Io.Dir.cwd().access(runtime.io, path, .{}) catch continue;
            return path;
        }
        // 2. 패키지된 앱: 실행파일 기준 Resources(절대경로).
        //    macOS .app: <exe>/Contents/MacOS/<name> → Contents/Resources/suji.json
        //    Windows/Linux packaged: <exe_dir>/resources/suji.json (소문자 r)
        var exe_buf: [1024]u8 = undefined;
        const exe_len = std.process.executablePath(runtime.io, &exe_buf) catch return null;
        const exe_dir = std.fs.path.dirname(exe_buf[0..exe_len]) orelse return null;
        for (CONFIG_FILE_PATHS) |path| {
            if (std.fs.path.dirname(exe_dir)) |contents_dir| {
                const mac = std.fmt.bufPrint(buf, "{s}/Resources/{s}", .{ contents_dir, path }) catch return null;
                if (std.Io.Dir.cwd().access(runtime.io, mac, .{})) |_| return mac else |_| {}
            }
            const flat = std.fmt.bufPrint(buf, "{s}/resources/{s}", .{ exe_dir, path }) catch return null;
            if (std.Io.Dir.cwd().access(runtime.io, flat, .{})) |_| return flat else |_| {}
        }
        return null;
    }

    fn loadJsonConfigFile(allocator: std.mem.Allocator, path: []const u8) !Config {
        const content = std.Io.Dir.cwd().readFileAlloc(runtime.io, path, allocator, .limited(CONFIG_JSON_MAX_BYTES)) catch return error.ConfigNotFound;
        defer allocator.free(content);
        return loadFromJsonBytes(allocator, content);
    }

    pub fn loadFromJsonBytes(allocator: std.mem.Allocator, content: []const u8) !Config {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const owned = a.dupe(u8, content) catch return error.OutOfMemory;

        var config = Config{ ._arena = arena };

        const parsed = std.json.parseFromSlice(std.json.Value, a, owned, .{}) catch return error.JsonParseError;

        const root = parsed.value.object;

        if (root.get("app")) |app_val| {
            if (app_val == .object) {
                const app = app_val.object;
                if (getStr(app, "name")) |s| config.app.name = dupeStr(a, s);
                if (getStr(app, "version")) |s| config.app.version = dupeStr(a, s);
                if (getStr(app, "entitlements")) |s| config.app.entitlements = dupeStr(a, s);
                if (getBool(app, "stripCef")) |b| config.app.strip_cef = b;
                if (getStr(app, "minimumSystemVersion")) |s| config.app.macos_min_version = clampMacosVersion(a, s);
                if (getBool(app, "quitOnAllWindowsClosed")) |b| config.app.quit_on_all_windows_closed = b;
                if (app.get("crashReporter")) |cr_val| {
                    if (cr_val == .object) {
                        const cr_obj = cr_val.object;
                        var cr = App.CrashReporter{};
                        if (getBool(cr_obj, "enabled")) |b| cr.enabled = b;
                        if (getStr(cr_obj, "productName")) |s| cr.product_name = dupeStr(a, s);
                        if (getStr(cr_obj, "submitURL")) |s| cr.submit_url = dupeStr(a, s);
                        if (getBool(cr_obj, "uploadToServer")) |b| cr.upload_to_server = b;
                        if (getBool(cr_obj, "ignoreSystemCrashHandler")) |b| cr.ignore_system_crash_handler = b;
                        if (getBool(cr_obj, "rateLimit")) |b| cr.rate_limit = b;
                        if (getInt(cr_obj, "maxUploadsPerDay")) |n| cr.max_uploads_per_day = util.nonNegU32(n);
                        if (getInt(cr_obj, "maxDatabaseSizeInMb")) |n| cr.max_database_size_mb = util.nonNegU32(n);
                        if (getInt(cr_obj, "maxDatabaseAgeInDays")) |n| cr.max_database_age_days = util.nonNegU32(n);
                        if (cr_obj.get("extra")) |v| cr.extra = parseCrashParams(a, v);
                        if (cr_obj.get("globalExtra")) |v| cr.global_extra = parseCrashParams(a, v);
                        config.app.crash_reporter = cr;
                    }
                }
                if (app.get("locales")) |loc_val| {
                    if (loc_val == .array) {
                        var list = std.ArrayList([:0]const u8).empty;
                        for (loc_val.array.items) |item| {
                            if (item != .string) continue;
                            list.append(a, dupeStr(a, item.string)) catch continue;
                        }
                        config.app.locales = list.toOwnedSlice(a) catch &.{};
                    }
                }
                if (app.get("deepLinkSchemes")) |dl_val| {
                    if (dl_val == .array) {
                        var list = std.ArrayList([:0]const u8).empty;
                        for (dl_val.array.items) |item| {
                            if (item != .string) continue;
                            list.append(a, dupeStr(a, item.string)) catch continue;
                        }
                        config.app.deep_link_schemes = list.toOwnedSlice(a) catch &.{};
                    }
                }
            }
        }

        if (root.get("windows")) |arr_val| {
            if (arr_val == .array) {
                var list = std.ArrayList(Window).empty;
                if (arr_val.array.items.len > MAX_STARTUP_WINDOWS) {
                    std.debug.print(
                        "[suji] warning: windows[] has {d} entries, capping at {d} (use create_window for more at runtime)\n",
                        .{ arr_val.array.items.len, MAX_STARTUP_WINDOWS },
                    );
                }
                for (arr_val.array.items) |item| {
                    if (list.items.len >= MAX_STARTUP_WINDOWS) break;
                    if (item != .object) continue;
                    const w = item.object;
                    var win = Window{};
                    if (getStr(w, "name")) |s| win.name = dupeStr(a, s);
                    if (getStr(w, "title")) |s| win.title = dupeStr(a, s);
                    if (getInt(w, "width")) |n| win.width = n;
                    if (getInt(w, "height")) |n| win.height = n;
                    if (getInt(w, "x")) |n| win.x = n;
                    if (getInt(w, "y")) |n| win.y = n;
                    if (getBool(w, "debug")) |b| win.debug = b;
                    if (getStr(w, "url")) |s| win.url = dupeStr(a, s);
                    if (getBool(w, "visible")) |b| win.visible = b;
                    if (getStr(w, "parent")) |s| win.parent = dupeStr(a, s);
                    // 외형
                    if (getBool(w, "frame")) |b| win.frame = b;
                    if (getBool(w, "transparent")) |b| win.transparent = b;
                    if (getStr(w, "backgroundColor")) |s| win.background_color = dupeStr(a, s);
                    if (getStr(w, "titleBarStyle")) |s| win.title_bar_style = TitleBarStyle.fromString(s);
                    // 제약 — i64 → u32 음수 clamp는 nonNegU32에서.
                    if (getBool(w, "alwaysOnTop")) |b| win.always_on_top = b;
                    if (getBool(w, "resizable")) |b| win.resizable = b;
                    if (getInt(w, "minWidth")) |n| win.min_width = util.nonNegU32(n);
                    if (getInt(w, "minHeight")) |n| win.min_height = util.nonNegU32(n);
                    if (getInt(w, "maxWidth")) |n| win.max_width = util.nonNegU32(n);
                    if (getInt(w, "maxHeight")) |n| win.max_height = util.nonNegU32(n);
                    if (getBool(w, "fullscreen")) |b| win.fullscreen = b;
                    if (w.get("protocol")) |v| if (v == .string) {
                        if (std.mem.eql(u8, v.string, "file")) {
                            win.protocol = .file;
                        } else if (std.mem.eql(u8, v.string, "suji")) {
                            win.protocol = .suji;
                        } else {
                            std.debug.print("[suji] warning: unknown protocol '{s}', using default 'file'\n", .{v.string});
                        }
                    };
                    list.append(a, win) catch continue;
                }
                if (list.items.len > 0) {
                    config.windows = list.toOwnedSlice(a) catch &.{Window{}};
                }
            }
        }

        if (root.get("backend")) |be_val| {
            if (be_val == .object) {
                const be = be_val.object;
                config.backend = SingleBackend{
                    .lang = if (getStr(be, "lang")) |s| dupeStr(a, s) else "zig",
                    .entry = if (getStr(be, "entry")) |s| dupeStr(a, s) else "src/main.zig",
                };
            }
        }

        if (root.get("backends")) |bs_val| {
            if (bs_val == .array) {
                var list = std.ArrayList(MultiBackend).empty;
                for (bs_val.array.items) |item| {
                    if (item != .object) continue;
                    const obj = item.object;
                    const name = getStr(obj, "name") orelse continue;
                    const lang = getStr(obj, "lang") orelse continue;
                    const entry = getStr(obj, "entry") orelse continue;
                    list.append(a, .{
                        .name = dupeStr(a, name),
                        .lang = dupeStr(a, lang),
                        .entry = dupeStr(a, entry),
                    }) catch continue;
                }
                config.backends = list.toOwnedSlice(a) catch null;
            }
        }

        if (getStr(root, "asset_dir")) |s| config.asset_dir = dupeStr(a, s);

        if (root.get("plugins")) |pl_val| {
            if (pl_val == .array) {
                var list = std.ArrayList(Plugin).empty;
                for (pl_val.array.items) |item| {
                    if (item == .string) {
                        list.append(a, .{ .name = dupeStr(a, item.string) }) catch continue;
                    } else if (item == .object) {
                        const obj = item.object;
                        const name = getStr(obj, "name") orelse continue;
                        list.append(a, .{
                            .name = dupeStr(a, name),
                            .source = if (getStr(obj, "source")) |s| dupeStr(a, s) else null,
                            .permissions = if (obj.get("permissions")) |v| parseStringList(a, v) else null,
                        }) catch continue;
                    }
                }
                config.plugins = list.toOwnedSlice(a) catch null;
            }
        }

        if (root.get("frontend")) |fe_val| {
            if (fe_val == .object) {
                const fe = fe_val.object;
                if (getStr(fe, "dir")) |s| config.frontend.dir = dupeStr(a, s);
                if (getStr(fe, "dev_url")) |s| config.frontend.dev_url = dupeStr(a, s);
                if (getStr(fe, "dev_command")) |s| config.frontend.dev_command = dupeStr(a, s);
                if (getStr(fe, "build_command")) |s| config.frontend.build_command = dupeStr(a, s);
                if (getStr(fe, "dist_dir")) |s| config.frontend.dist_dir = dupeStr(a, s);
            }
        }

        if (root.get("fs")) |fs_val| {
            if (fs_val == .object) {
                // "*"는 expandHomeAtLoad 가 그대로 보존(escape hatch), 그 외 ~ 사전 확장.
                if (fs_val.object.get("allowedRoots")) |v| config.fs.allowed_roots = parseAllowList(a, v, true);
            }
        }

        // shell/dialog allowlist (opt-in — 키 존재 시에만 optional 을 non-null 로
        // 설정해 enforce; 부재 시 null 유지 = 레거시 무제한). paths 는 ~ expand,
        // urls 는 raw(glob).
        if (root.get("shell")) |sh_val| {
            if (sh_val == .object) {
                const sh = sh_val.object;
                if (sh.get("allowedPaths")) |v| config.shell.allowed_paths = parseAllowList(a, v, true);
                if (sh.get("allowedExternalUrls")) |v| config.shell.allowed_external_urls = parseAllowList(a, v, false);
            }
        }
        if (root.get("dialog")) |dl_val| {
            if (dl_val == .object) {
                if (dl_val.object.get("allowedPaths")) |v| config.dialog.allowed_paths = parseAllowList(a, v, true);
            }
        }

        if (root.get("security")) |sec_val| {
            if (sec_val == .object) {
                if (getStr(sec_val.object, "csp")) |s| config.security.csp = dupeStr(a, s);
                if (sec_val.object.get("iframeAllowedOrigins")) |arr_val| {
                    if (arr_val == .array) {
                        var list = std.ArrayList([:0]const u8).empty;
                        for (arr_val.array.items) |item| {
                            if (item != .string) continue;
                            list.append(a, dupeStr(a, item.string)) catch continue;
                        }
                        config.security.iframe_allowed_origins = list.toOwnedSlice(a) catch &.{};
                    }
                }
            }
        }

        return config;
    }

    pub fn isMultiBackend(self: *const Config) bool {
        return self.backends != null;
    }

    pub fn getBackendCount(self: *const Config) usize {
        if (self.backends) |bs| return bs.len;
        if (self.backend != null) return 1;
        return 0;
    }

    fn parseStringList(a: std.mem.Allocator, v: std.json.Value) []const [:0]const u8 {
        if (v != .array) return &.{};
        var list = std.ArrayList([:0]const u8).empty;
        for (v.array.items) |item| {
            if (item != .string) continue;
            list.append(a, dupeStr(a, item.string)) catch continue;
        }
        return list.toOwnedSlice(a) catch &.{};
    }
};

test "expandHomeAtLoad: ~ 단독 / ~/ prefix만 expand" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `*` sentinel은 그대로 (escape hatch).
    try std.testing.expectEqualStrings("*", Config.expandHomeAtLoad(a, "*"));
    // 빈 문자열은 그대로.
    try std.testing.expectEqualStrings("", Config.expandHomeAtLoad(a, ""));
    // 절대 경로는 그대로.
    try std.testing.expectEqualStrings("/Users/x/myapp", Config.expandHomeAtLoad(a, "/Users/x/myapp"));
    // ~user 같은 POSIX 형태는 expand 거부 — 이후 startsWith 매치 실패라 안전.
    try std.testing.expectEqualStrings("~user/secret", Config.expandHomeAtLoad(a, "~user/secret"));
    // ~ + ~/... 만 expand. HOME env 의존이라 결과 prefix만 검사.
    const tilde = Config.expandHomeAtLoad(a, "~/Documents/myapp");
    if (tilde[0] != '~') {
        try std.testing.expect(std.mem.endsWith(u8, tilde, "/Documents/myapp"));
    }
}
