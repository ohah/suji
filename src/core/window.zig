const std = @import("std");
const WebView = @import("webview.zig").WebView;

/// 윈도우 설정
pub const WindowConfig = struct {
    title: [:0]const u8 = "Suji App",
    width: i32 = 1024,
    height: i32 = 768,
    debug: bool = false,
    url: ?[:0]const u8 = null,
    html: ?[:0]const u8 = null,
};

/// 윈도우 — WebView를 감싸는 상위 레이어
pub const Window = struct {
    webview: WebView,
    config: WindowConfig,

    /// 윈도우 생성
    pub fn create(config: WindowConfig) !Window {
        var wv = try WebView.create(config.debug);
        wv.setTitle(config.title);
        wv.setSize(config.width, config.height, .none);

        return .{
            .webview = wv,
            .config = config,
        };
    }

    /// 콘텐츠 로드 (URL 또는 HTML)
    pub fn loadContent(self: *Window) void {
        if (self.config.url) |url| {
            self.webview.navigate(url);
        } else if (self.config.html) |html| {
            self.webview.setHtml(html);
        }
    }

    /// 타이틀 변경
    pub fn setTitle(self: *Window, title: [:0]const u8) void {
        self.webview.setTitle(title);
    }

    /// 크기 변경
    pub fn setSize(self: *Window, width: i32, height: i32) void {
        self.webview.setSize(width, height, .none);
    }

    /// JavaScript 실행
    pub fn eval(self: *Window, js: [:0]const u8) void {
        self.webview.eval(js);
    }

    /// 이벤트 루프 실행 (블로킹)
    pub fn run(self: *Window) void {
        self.webview.run();
    }

    /// 윈도우 닫기
    pub fn close(self: *Window) void {
        self.webview.terminate();
    }

    /// 윈도우 해제
    pub fn destroy(self: *Window) void {
        self.webview.destroy();
    }
};
