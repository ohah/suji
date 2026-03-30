/// Suji — Zig 코어 기반 올인원 데스크톱 앱 프레임워크
pub const backends = @import("loader");
pub const window = @import("core/window.zig");
pub const webview = @import("core/webview.zig");
pub const ipc = @import("core/ipc.zig");
pub const config = @import("core/config.zig");
pub const events = @import("events");
pub const init_mod = @import("core/init.zig");
pub const app_mod = @import("core/app.zig");

pub const Backend = backends.Backend;
pub const BackendRegistry = backends.BackendRegistry;
pub const Window = window.Window;
pub const WindowConfig = window.WindowConfig;
pub const WebView = webview.WebView;
pub const Bridge = ipc.Bridge;
pub const Config = config.Config;
pub const EventBus = events.EventBus;

// Zig 내장 백엔드 API
pub const App = app_mod.App;
pub const Request = app_mod.Request;
pub const Response = app_mod.Response;
pub const Event = app_mod.Event;
pub const app = app_mod.init;
