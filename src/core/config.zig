const std = @import("std");
const runtime = @import("runtime");

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

    // _arena는 포인터로 보관. 값으로 담으면 `Config { ._arena = arena }` 시점에 arena의
    // 내부 state(buffer 리스트 head)가 COPY되고, 이후 동일 arena를 거치는 할당(예:
    // parseFromSlice 내부)은 stack-local 원본만 갱신 → return으로 스택이 사라지면 그 뒤에
    // 할당된 buffer가 deinit 경로에 잡히지 않아 leak.
    _arena: ?*std.heap.ArenaAllocator = null,

    pub const App = struct {
        name: [:0]const u8 = "Suji App",
        version: [:0]const u8 = "0.1.0",
    };

    pub const Protocol = enum { suji, file };

    pub const Window = struct {
        /// WM 등록 이름 (singleton 키). null이면 익명. 첫 창의 기본값은 "main".
        name: ?[:0]const u8 = null,
        title: [:0]const u8 = "Suji App",
        width: i64 = 1024,
        height: i64 = 768,
        debug: bool = false,
        protocol: Protocol = .file,
        /// 시작 시 자동 로드할 URL. null이면 frontend dev_url/dist 자동 선택 (첫 창에만 적용).
        /// 두 번째 창부터는 명시 권장.
        url: ?[:0]const u8 = null,
        /// false면 hidden 상태로 생성 (Phase 3+에서 setVisible과 연동 예정).
        visible: bool = true,
    };

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
                if (app.get("name")) |v| if (v == .string) { config.app.name = dupeStr(a, v.string); };
                if (app.get("version")) |v| if (v == .string) { config.app.version = dupeStr(a, v.string); };
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
                    if (w.get("name")) |v| if (v == .string) { win.name = dupeStr(a, v.string); };
                    if (w.get("title")) |v| if (v == .string) { win.title = dupeStr(a, v.string); };
                    if (w.get("width")) |v| if (v == .integer) { win.width = v.integer; };
                    if (w.get("height")) |v| if (v == .integer) { win.height = v.integer; };
                    if (w.get("debug")) |v| if (v == .bool) { win.debug = v.bool; };
                    if (w.get("url")) |v| if (v == .string) { win.url = dupeStr(a, v.string); };
                    if (w.get("visible")) |v| if (v == .bool) { win.visible = v.bool; };
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
                    .lang = if (be.get("lang")) |v| if (v == .string) dupeStr(a, v.string) else "zig" else "zig",
                    .entry = if (be.get("entry")) |v| if (v == .string) dupeStr(a, v.string) else "src/main.zig" else "src/main.zig",
                };
            }
        }

        if (root.get("backends")) |bs_val| {
            if (bs_val == .array) {
                var list = std.ArrayList(MultiBackend).empty;
                for (bs_val.array.items) |item| {
                    if (item == .object) {
                        const obj = item.object;
                        const name = if (obj.get("name")) |v| if (v == .string) dupeStr(a, v.string) else continue else continue;
                        const lang = if (obj.get("lang")) |v| if (v == .string) dupeStr(a, v.string) else continue else continue;
                        const entry = if (obj.get("entry")) |v| if (v == .string) dupeStr(a, v.string) else continue else continue;
                        list.append(a, .{ .name = name, .lang = lang, .entry = entry }) catch continue;
                    }
                }
                config.backends = list.toOwnedSlice(a) catch null;
            }
        }

        if (root.get("asset_dir")) |v| {
            if (v == .string) config.asset_dir = dupeStr(a, v.string);
        }

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
                if (fe.get("dir")) |v| if (v == .string) { config.frontend.dir = dupeStr(a, v.string); };
                if (fe.get("dev_url")) |v| if (v == .string) { config.frontend.dev_url = dupeStr(a, v.string); };
                if (fe.get("dist_dir")) |v| if (v == .string) { config.frontend.dist_dir = dupeStr(a, v.string); };
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
