const std = @import("std");
const runtime = @import("runtime");
const window_mod = @import("window");
const util = @import("util");

/// Suji 프로젝트 설정
/// suji.json에서 로드
pub const Config = struct {
    app: App = .{},
    /// 시작 시 자동 생성할 창 목록. 첫 항목이 main 창 (CEF 초기화 시 사이즈/타이틀 사용).
    /// suji.json에 `windows` 배열이 없거나 비어있으면 default 1개.
    windows: []const Window = &.{Window{}},
    backend: ?SingleBackend = null,
    backends: ?[]const MultiBackend = null,
    plugins: ?[]const [:0]const u8 = null,
    asset_dir: [:0]const u8 = "assets",
    frontend: Frontend = .{},
    fs: Fs = .{},
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
        /// 마지막 창이 닫힐 때 (window:all-closed 발화 시점) 코어가 자동으로 cef.quit().
        /// default false — Electron canonical 패턴(`suji.on("window:all-closed", ...)`로 user
        /// 코드가 platform 분기 후 quit 호출). true로 설정 시 모든 플랫폼에서 자동 종료.
        /// 두 경로(user code + 코어)가 동시에 발화해도 cef.quit()이 idempotent라 안전.
        quit_on_all_windows_closed: bool = false,
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

    pub const Frontend = struct {
        dir: [:0]const u8 = "frontend",
        dev_url: [:0]const u8 = "http://localhost:5173",
        dist_dir: [:0]const u8 = "frontend/dist",
    };

    /// File system sandbox (Electron `webPreferences.sandbox` 대응).
    /// frontend(renderer)에서 호출되는 fs.* cmd가 검증 대상. backend는 항상 무제한.
    /// allowedRoots 비어있으면 frontend fs 완전 차단. ["*"] = unrestricted (escape hatch).
    pub const Fs = struct {
        allowed_roots: []const [:0]const u8 = &.{},
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
        return loadJson(allocator);
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

    fn loadJson(allocator: std.mem.Allocator) !Config {
        const content = std.Io.Dir.cwd().readFileAlloc(runtime.io, "suji.json", allocator, .limited(1024 * 64)) catch return error.ConfigNotFound;

        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const owned = a.dupe(u8, content) catch return error.OutOfMemory;
        allocator.free(content);

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
                if (getBool(app, "quitOnAllWindowsClosed")) |b| config.app.quit_on_all_windows_closed = b;
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
                var list = std.ArrayList([:0]const u8).empty;
                for (pl_val.array.items) |item| {
                    if (item == .string) {
                        list.append(a, dupeStr(a, item.string)) catch continue;
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
                if (getStr(fe, "dist_dir")) |s| config.frontend.dist_dir = dupeStr(a, s);
            }
        }

        if (root.get("fs")) |fs_val| {
            if (fs_val == .object) {
                const fs_obj = fs_val.object;
                if (fs_obj.get("allowedRoots")) |roots_val| {
                    if (roots_val == .array) {
                        var list = std.ArrayList([:0]const u8).empty;
                        for (roots_val.array.items) |item| {
                            if (item != .string) continue;
                            // "*"는 escape hatch sentinel — expand 없이 그대로 보존.
                            // 그 외는 ~ 사전 확장해 핫 패스에서 다시 resolve 안 하게.
                            const expanded = expandHomeAtLoad(a, item.string);
                            list.append(a, expanded) catch continue;
                        }
                        config.fs.allowed_roots = list.toOwnedSlice(a) catch &.{};
                    }
                }
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
