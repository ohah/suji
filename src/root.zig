/// Suji — Zig 코어 기반 올인원 데스크톱 앱 프레임워크
pub const backends = @import("backends/loader.zig");
pub const window = @import("core/window.zig");
pub const webview = @import("core/webview.zig");
pub const ipc = @import("core/ipc.zig");

pub const Backend = backends.Backend;
pub const BackendRegistry = backends.BackendRegistry;
pub const Window = window.Window;
pub const WindowConfig = window.WindowConfig;
pub const WebView = webview.WebView;
pub const Bridge = ipc.Bridge;
