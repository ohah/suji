const std = @import("std");
const toml = @import("toml");

/// Suji 프로젝트 설정
/// suji.toml 또는 suji.json에서 로드
pub const Config = struct {
    app: App = .{},
    window: Window = .{},
    backend: ?SingleBackend = null,
    backends: ?[]const MultiBackend = null,
    frontend: Frontend = .{},

    pub const App = struct {
        name: []const u8 = "Suji App",
        version: []const u8 = "0.1.0",
    };

    pub const Window = struct {
        title: []const u8 = "Suji App",
        width: i64 = 800,
        height: i64 = 600,
        debug: bool = false,
    };

    pub const SingleBackend = struct {
        lang: []const u8 = "zig",
        entry: []const u8 = "src/main.zig",
    };

    pub const MultiBackend = struct {
        name: []const u8,
        lang: []const u8,
        entry: []const u8,
    };

    pub const Frontend = struct {
        dir: []const u8 = "frontend",
        dev_url: []const u8 = "http://localhost:5173",
        dist_dir: []const u8 = "frontend/dist",
    };

    /// TOML용 struct (zig-toml은 struct로 직접 디코딩)
    const TomlConfig = struct {
        app: ?App = null,
        window: ?Window = null,
        backend: ?SingleBackend = null,
        backends: ?[]const MultiBackend = null,
        frontend: ?Frontend = null,
    };

    /// suji.toml 또는 suji.json을 자동 감지해서 로드
    pub fn load(allocator: std.mem.Allocator) !Config {
        // suji.toml 먼저 시도
        if (loadToml(allocator)) |config| return config else |_| {}
        // suji.json 시도
        if (loadJson(allocator)) |config| return config else |_| {}
        return error.ConfigNotFound;
    }

    /// suji.toml 파싱
    fn loadToml(allocator: std.mem.Allocator) !Config {
        const content = std.fs.cwd().readFileAlloc(allocator, "suji.toml", 1024 * 64) catch return error.TomlNotFound;
        defer allocator.free(content);

        var parser = toml.Parser(TomlConfig).init(allocator);
        defer parser.deinit();

        var result = parser.parseString(content) catch return error.TomlParseError;
        defer result.deinit();

        const tc = result.value;
        return Config{
            .app = tc.app orelse .{},
            .window = tc.window orelse .{},
            .backend = tc.backend,
            .backends = tc.backends,
            .frontend = tc.frontend orelse .{},
        };
    }

    /// suji.json 파싱
    fn loadJson(allocator: std.mem.Allocator) !Config {
        const content = std.fs.cwd().readFileAlloc(allocator, "suji.json", 1024 * 64) catch return error.JsonNotFound;
        defer allocator.free(content);

        var config = Config{};
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return error.JsonParseError;
        defer parsed.deinit();

        const root = parsed.value.object;

        // app
        if (root.get("app")) |app_val| {
            if (app_val == .object) {
                const app = app_val.object;
                if (app.get("name")) |v| if (v == .string) {
                    config.app.name = v.string;
                };
                if (app.get("version")) |v| if (v == .string) {
                    config.app.version = v.string;
                };
            }
        }

        // window
        if (root.get("window")) |win_val| {
            if (win_val == .object) {
                const win = win_val.object;
                if (win.get("title")) |v| if (v == .string) {
                    config.window.title = v.string;
                };
                if (win.get("width")) |v| if (v == .integer) {
                    config.window.width = v.integer;
                };
                if (win.get("height")) |v| if (v == .integer) {
                    config.window.height = v.integer;
                };
                if (win.get("debug")) |v| if (v == .bool) {
                    config.window.debug = v.bool;
                };
            }
        }

        // backend (단일)
        if (root.get("backend")) |be_val| {
            if (be_val == .object) {
                const be = be_val.object;
                config.backend = SingleBackend{
                    .lang = if (be.get("lang")) |v| if (v == .string) v.string else "zig" else "zig",
                    .entry = if (be.get("entry")) |v| if (v == .string) v.string else "src/main.zig" else "src/main.zig",
                };
            }
        }

        // backends (멀티)
        if (root.get("backends")) |bs_val| {
            if (bs_val == .array) {
                var list = std.ArrayListUnmanaged(MultiBackend){};
                for (bs_val.array.items) |item| {
                    if (item == .object) {
                        const obj = item.object;
                        const name = if (obj.get("name")) |v| if (v == .string) v.string else continue else continue;
                        const lang = if (obj.get("lang")) |v| if (v == .string) v.string else continue else continue;
                        const entry = if (obj.get("entry")) |v| if (v == .string) v.string else continue else continue;
                        try list.append(allocator, .{ .name = name, .lang = lang, .entry = entry });
                    }
                }
                config.backends = try list.toOwnedSlice(allocator);
            }
        }

        // frontend
        if (root.get("frontend")) |fe_val| {
            if (fe_val == .object) {
                const fe = fe_val.object;
                if (fe.get("dir")) |v| if (v == .string) {
                    config.frontend.dir = v.string;
                };
                if (fe.get("dev_url")) |v| if (v == .string) {
                    config.frontend.dev_url = v.string;
                };
                if (fe.get("dist_dir")) |v| if (v == .string) {
                    config.frontend.dist_dir = v.string;
                };
            }
        }

        return config;
    }

    /// 백엔드가 단일인지 멀티인지
    pub fn isMultiBackend(self: *const Config) bool {
        return self.backends != null;
    }

    /// 백엔드 개수
    pub fn getBackendCount(self: *const Config) usize {
        if (self.backends) |bs| return bs.len;
        if (self.backend != null) return 1;
        return 0;
    }
};
