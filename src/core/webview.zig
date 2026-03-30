const std = @import("std");
const wv = @import("webview");

/// WebView 래퍼
pub const WebView = struct {
    handle: wv.WebView,

    pub const Error = wv.WebView.WebViewError;
    pub const BindCallback = wv.WebView.BindCallback;

    pub const SizeHint = enum {
        none,
        min,
        max,
        fixed,
    };

    pub fn create(debug: bool) !WebView {
        const handle = wv.WebView.create(debug, null);
        return .{ .handle = handle };
    }

    pub fn setTitle(self: *WebView, title: [:0]const u8) void {
        self.handle.setTitle(title) catch {};
    }

    pub fn setSize(self: *WebView, width: i32, height: i32, hint: SizeHint) void {
        const wv_hint: wv.WebView.WindowSizeHint = switch (hint) {
            .none => .none,
            .min => .min,
            .max => .max,
            .fixed => .fixed,
        };
        self.handle.setSize(width, height, wv_hint) catch {};
    }

    pub fn navigate(self: *WebView, url: [:0]const u8) void {
        self.handle.navigate(url) catch {};
    }

    pub fn setHtml(self: *WebView, html: [:0]const u8) void {
        self.handle.setHtml(html) catch {};
    }

    pub fn eval(self: *WebView, js: [:0]const u8) void {
        self.handle.eval(js) catch {};
    }

    pub fn init(self: *WebView, js: [:0]const u8) void {
        self.handle.init(js) catch {};
    }

    pub fn bind(self: *WebView, name: [:0]const u8, callback: BindCallback, arg: ?*anyopaque) void {
        _ = wv.raw.webview_bind(self.handle.webview, name.ptr, @ptrCast(callback), arg);
    }

    pub fn returnResult(self: *WebView, seq: [:0]const u8, status: i32, result: [:0]const u8) void {
        _ = wv.raw.webview_return(self.handle.webview, seq.ptr, status, result.ptr);
    }

    pub fn run(self: *WebView) void {
        self.handle.run() catch {};
    }

    pub fn terminate(self: *WebView) void {
        self.handle.terminate() catch {};
    }

    pub fn destroy(self: *WebView) void {
        self.handle.destroy() catch {};
    }
};
