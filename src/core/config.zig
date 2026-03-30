const std = @import("std");
const toml = @import("toml");

/// Suji 프로젝트 설정
pub const Config = struct {
    app: App = .{},
    window: Window = .{},
    backend: ?SingleBackend = null,
    backends: ?[]const MultiBackend = null,
    frontend: Frontend = .{},

    // 내부 메모리 관리
    _arena: ?std.heap.ArenaAllocator = null,

    pub const App = struct {
        name: [:0]const u8 = "Suji App",
        version: [:0]const u8 = "0.1.0",
    };

    pub const Window = struct {
        title: [:0]const u8 = "Suji App",
        width: i64 = 800,
        height: i64 = 600,
        debug: bool = false,
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

    // TOML 파서용 struct ([]const u8 — toml 라이브러리가 [:0] 미지원)
    const TomlApp = struct { name: []const u8 = "Suji App", version: []const u8 = "0.1.0" };
    const TomlWindow = struct { title: []const u8 = "Suji App", width: i64 = 800, height: i64 = 600, debug: bool = false };
    const TomlBackend = struct { lang: []const u8 = "zig", entry: []const u8 = "src/main.zig" };
    const TomlFrontend = struct { dir: []const u8 = "frontend", dev_url: []const u8 = "http://localhost:5173", dist_dir: []const u8 = "frontend/dist" };
    const TomlConfig = struct {
        app: ?TomlApp = null,
        window: ?TomlWindow = null,
        backend: ?TomlBackend = null,
        frontend: ?TomlFrontend = null,
    };

    pub fn load(allocator: std.mem.Allocator) !Config {
        if (loadToml(allocator)) |config| return config else |_| {}
        if (loadJson(allocator)) |config| return config else |_| {}
        return error.ConfigNotFound;
    }

    pub fn deinit(self: *Config) void {
        if (self._arena) |*arena| {
            arena.deinit();
            self._arena = null;
        }
    }

    /// 문자열을 arena에 복사 + null terminate 보장
    fn dupeStr(arena: std.mem.Allocator, s: []const u8) [:0]const u8 {
        return arena.dupeZ(u8, s) catch @ptrCast(s);
    }

    fn loadToml(allocator: std.mem.Allocator) !Config {
        const content = std.fs.cwd().readFileAlloc(allocator, "suji.toml", 1024 * 64) catch return error.TomlNotFound;
        defer allocator.free(content);

        var parser = toml.Parser(TomlConfig).init(allocator);
        defer parser.deinit();

        var result = parser.parseString(content) catch return error.TomlParseError;
        // result의 arena에서 문자열을 빌려오므로, 우리 arena에 복사
        defer result.deinit();

        const tc = result.value;
        var arena = std.heap.ArenaAllocator.init(allocator);
        const a = arena.allocator();

        var config = Config{
            ._arena = arena,
        };

        if (tc.app) |app| {
            config.app = .{
                .name = dupeStr(a, app.name),
                .version = dupeStr(a, app.version),
            };
        }
        if (tc.window) |win| {
            config.window = .{
                .title = dupeStr(a, win.title),
                .width = win.width,
                .height = win.height,
                .debug = win.debug,
            };
        }
        if (tc.backend) |be| {
            config.backend = .{
                .lang = dupeStr(a, be.lang),
                .entry = dupeStr(a, be.entry),
            };
        }
        if (tc.frontend) |fe| {
            config.frontend = .{
                .dir = dupeStr(a, fe.dir),
                .dev_url = dupeStr(a, fe.dev_url),
                .dist_dir = dupeStr(a, fe.dist_dir),
            };
        }

        return config;
    }

    fn loadJson(allocator: std.mem.Allocator) !Config {
        const content = std.fs.cwd().readFileAlloc(allocator, "suji.json", 1024 * 64) catch return error.JsonNotFound;

        var arena = std.heap.ArenaAllocator.init(allocator);
        const a = arena.allocator();

        // content를 arena에 복사 (JSON 파서가 원본 슬라이스를 참조하므로)
        const owned = a.dupe(u8, content) catch return error.OutOfMemory;
        allocator.free(content);

        var config = Config{ ._arena = arena };

        const parsed = std.json.parseFromSlice(std.json.Value, a, owned, .{}) catch return error.JsonParseError;
        // parsed는 arena 소유이므로 deinit 불필요

        const root = parsed.value.object;

        if (root.get("app")) |app_val| {
            if (app_val == .object) {
                const app = app_val.object;
                if (app.get("name")) |v| if (v == .string) { config.app.name = dupeStr(a, v.string); };
                if (app.get("version")) |v| if (v == .string) { config.app.version = dupeStr(a, v.string); };
            }
        }

        if (root.get("window")) |win_val| {
            if (win_val == .object) {
                const win = win_val.object;
                if (win.get("title")) |v| if (v == .string) { config.window.title = dupeStr(a, v.string); };
                if (win.get("width")) |v| if (v == .integer) { config.window.width = v.integer; };
                if (win.get("height")) |v| if (v == .integer) { config.window.height = v.integer; };
                if (win.get("debug")) |v| if (v == .bool) { config.window.debug = v.bool; };
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
                var list = std.ArrayListUnmanaged(MultiBackend){};
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
