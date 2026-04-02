/// Suji — Zig 코어 기반 올인원 데스크톱 앱 프레임워크
///
/// Electron 스타일 API:
///   handle — 요청/응답 등록
///   on     — 이벤트 수신
///   send   — 이벤트 발신
///   invoke — 다른 백엔드 호출
pub const backends = @import("loader");
pub const config = @import("core/config.zig");
pub const events = @import("events");
pub const scaffold = @import("core/init.zig");
pub const app_mod = @import("core/app.zig");

// 타입 re-export
pub const Backend = backends.Backend;
pub const BackendRegistry = backends.BackendRegistry;
pub const Config = config.Config;
pub const EventBus = events.EventBus;

// Zig 백엔드 API (Electron 스타일)
pub const App = app_mod.App;
pub const Request = app_mod.Request;
pub const Response = app_mod.Response;
pub const Event = app_mod.Event;
pub const app = app_mod.app;
pub const send = app_mod.send;
pub const callBackend = app_mod.callBackend;
pub const exportApp = app_mod.exportApp;
