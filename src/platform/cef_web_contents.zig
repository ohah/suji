//! WebContents vtable glue for CefNative.
//! Navigation, JavaScript, DevTools, UA, zoom/audio, edit, and find commands.
const std = @import("std");
const window_mod = @import("window");
const logger = @import("logger");
const cef = @import("cef.zig");

const c = cef.c;
const log = logger.module("cef");

const URL_BUF_SIZE: usize = 2048;
/// executeJavascript fast path stack buffer. Larger snippets use heap.
const JS_STACK_BUF_SIZE: usize = 4096;
/// find_in_page text stack buffer. Longer search strings are dropped with a warning.
const FIND_TEXT_STACK_BUF: usize = 1024;

fn fromCtx(ctx: ?*anyopaque) *cef.CefNative {
    return @ptrCast(@alignCast(ctx.?));
}

fn assertUiThread() void {
    std.debug.assert(c.cef_currently_on(c.TID_UI) == 1);
}

/// Execute JavaScript on a single browser main frame.
pub fn evalJsOnBrowser(browser: *c.cef_browser_t, js: [:0]const u8) void {
    const frame = cef.asPtr(c.cef_frame_t, browser.get_main_frame.?(browser)) orelse return;
    var code: c.cef_string_t = .{};
    cef.setCefString(&code, js);
    var url: c.cef_string_t = .{};
    cef.setCefString(&url, "");
    frame.execute_java_script.?(frame, &code, &url, 0);
}

pub fn loadUrl(ctx: ?*anyopaque, handle: u64, url: []const u8) void {
    assertUiThread();
    const self = fromCtx(ctx);
    const entry = self.browsers.get(handle) orelse return;
    const frame = cef.asPtr(c.cef_frame_t, entry.browser.get_main_frame.?(entry.browser)) orelse return;
    var url_buf: [URL_BUF_SIZE]u8 = undefined;
    const url_z = cef.nullTerminateOrTruncate(url, &url_buf) orelse return;
    var cef_url: c.cef_string_t = .{};
    cef.setCefString(&cef_url, url_z);
    const load_url = frame.load_url orelse return;
    load_url(frame, &cef_url);
}

pub fn reload(ctx: ?*anyopaque, handle: u64, ignore_cache: bool) void {
    assertUiThread();
    const self = fromCtx(ctx);
    const entry = self.browsers.get(handle) orelse return;
    const br = entry.browser;
    if (ignore_cache) {
        const fn_ptr = br.reload_ignore_cache orelse return;
        fn_ptr(br);
    } else {
        const fn_ptr = br.reload orelse return;
        fn_ptr(br);
    }
}

pub fn executeJavascript(ctx: ?*anyopaque, handle: u64, code: []const u8) void {
    assertUiThread();
    const self = fromCtx(ctx);
    const entry = self.browsers.get(handle) orelse return;
    var stack_buf: [JS_STACK_BUF_SIZE]u8 = undefined;
    if (code.len < stack_buf.len) {
        @memcpy(stack_buf[0..code.len], code);
        stack_buf[code.len] = 0;
        evalJsOnBrowser(entry.browser, stack_buf[0..code.len :0]);
        return;
    }
    const heap = self.allocator.allocSentinel(u8, code.len, 0) catch {
        log.warn("execute_javascript: alloc {d} bytes failed — code dropped", .{code.len});
        return;
    };
    defer self.allocator.free(heap);
    @memcpy(heap, code);
    evalJsOnBrowser(entry.browser, heap);
}

/// Electron webContents.stop() — 진행 중 로드/네비게이션 중단(CEF cef_browser_t.stop_load).
pub fn stopLoad(ctx: ?*anyopaque, handle: u64) void {
    assertUiThread();
    const self = fromCtx(ctx);
    const entry = self.browsers.get(handle) orelse return;
    const fn_ptr = entry.browser.stop_load orelse return;
    fn_ptr(entry.browser);
}

/// Electron webContents.insertCSS() — `<style data-suji-css=key>` 주입(author-origin).
/// css 는 raw 바이트(호출부가 JSON-unescape 완료) → base64 후 atob+TextDecoder 로 복원해
/// 따옴표/백슬래시/유니코드 escape 문제를 원천 차단(executeJavascript 의 escape 한계 회피).
/// key 는 caller 가 보장하는 영숫자+하이픈('suji-css-N')이라 JS literal 에 raw 삽입 안전.
pub fn insertCss(ctx: ?*anyopaque, handle: u64, css: []const u8, key: []const u8) void {
    assertUiThread();
    const self = fromCtx(ctx);
    const entry = self.browsers.get(handle) orelse return;
    const enc = std.base64.standard.Encoder;
    const b64 = self.allocator.alloc(u8, enc.calcSize(css.len)) catch return;
    defer self.allocator.free(b64);
    _ = enc.encode(b64, css);
    const js = std.fmt.allocPrintSentinel(self.allocator, "(function(){{try{{var b=atob('{s}');var u=new Uint8Array(b.length);for(var i=0;i<b.length;i++)u[i]=b.charCodeAt(i);var s=document.createElement('style');s.setAttribute('data-suji-css','{s}');s.textContent=new TextDecoder().decode(u);(document.head||document.documentElement).appendChild(s);}}catch(e){{}}}})()", .{ b64, key }, 0) catch return;
    defer self.allocator.free(js);
    evalJsOnBrowser(entry.browser, js);
}

/// Electron webContents.removeInsertedCSS() — insertCss 가 반환한 key 의 style 제거.
pub fn removeInsertedCss(ctx: ?*anyopaque, handle: u64, key: []const u8) void {
    assertUiThread();
    const self = fromCtx(ctx);
    const entry = self.browsers.get(handle) orelse return;
    const js = std.fmt.allocPrintSentinel(self.allocator, "(function(){{try{{var l=document.querySelectorAll('style[data-suji-css=\"{s}\"]');for(var i=0;i<l.length;i++)l[i].remove();}}catch(e){{}}}})()", .{key}, 0) catch return;
    defer self.allocator.free(js);
    evalJsOnBrowser(entry.browser, js);
}

/// Return the OnAddressChange URL cache. Cache misses intentionally stay null.
pub fn getUrl(ctx: ?*anyopaque, handle: u64) ?[]const u8 {
    const self = fromCtx(ctx);
    const entry = self.browsers.getPtr(handle) orelse return null;
    if (entry.url_cache_len == 0) return null;
    return entry.url_cache_buf[0..entry.url_cache_len];
}

pub fn isLoading(ctx: ?*anyopaque, handle: u64) bool {
    const self = fromCtx(ctx);
    const entry = self.browsers.get(handle) orelse return false;
    const fn_ptr = entry.browser.is_loading orelse return false;
    return fn_ptr(entry.browser) == 1;
}

pub fn openDevToolsImpl(ctx: ?*anyopaque, handle: u64) void {
    assertUiThread();
    const self = fromCtx(ctx);
    const entry = self.browsers.get(handle) orelse return;
    cef.openDevTools(entry.browser);
}

pub fn closeDevToolsImpl(ctx: ?*anyopaque, handle: u64) void {
    assertUiThread();
    const self = fromCtx(ctx);
    const entry = self.browsers.get(handle) orelse return;
    cef.closeDevTools(entry.browser);
}

pub fn isDevToolsOpenedImpl(ctx: ?*anyopaque, handle: u64) bool {
    const self = fromCtx(ctx);
    const entry = self.browsers.get(handle) orelse return false;
    return cef.hasDevTools(entry.browser);
}

pub fn toggleDevToolsImpl(ctx: ?*anyopaque, handle: u64) void {
    assertUiThread();
    const self = fromCtx(ctx);
    const entry = self.browsers.get(handle) orelse return;
    cef.toggleDevTools(entry.browser);
}

/// Dynamic UA override through CDP Network.setUserAgentOverride.
pub fn setUserAgentImpl(ctx: ?*anyopaque, handle: u64, ua: []const u8) void {
    assertUiThread();
    const self = fromCtx(ctx);
    const entry = self.browsers.getPtr(handle) orelse return;
    const n = @min(ua.len, entry.ua_buf.len);
    @memcpy(entry.ua_buf[0..n], ua[0..n]);
    entry.ua_len = n;

    var esc: [4096]u8 = undefined;
    const en = window_mod.escapeJsonChars(entry.ua_buf[0..n], &esc);
    var msg: [4352]u8 = undefined;
    const m = std.fmt.bufPrint(
        &msg,
        "{{\"id\":1,\"method\":\"Network.setUserAgentOverride\",\"params\":{{\"userAgent\":\"{s}\"}}}}",
        .{esc[0..en]},
    ) catch return;
    const host = cef.asPtr(c.cef_browser_host_t, entry.browser.get_host.?(entry.browser)) orelse return;
    const send = host.send_dev_tools_message orelse return;
    _ = send(host, m.ptr, m.len);
}

pub fn getUserAgentImpl(ctx: ?*anyopaque, handle: u64) ?[]const u8 {
    const self = fromCtx(ctx);
    const entry = self.browsers.getPtr(handle) orelse return null;
    if (entry.ua_len == 0) return null;
    return entry.ua_buf[0..entry.ua_len];
}

pub fn setZoomLevelImpl(ctx: ?*anyopaque, handle: u64, level: f64) void {
    assertUiThread();
    const self = fromCtx(ctx);
    const entry = self.browsers.get(handle) orelse return;
    const host = cef.asPtr(c.cef_browser_host_t, entry.browser.get_host.?(entry.browser)) orelse return;
    host.set_zoom_level.?(host, level);
}

pub fn getZoomLevelImpl(ctx: ?*anyopaque, handle: u64) f64 {
    const self = fromCtx(ctx);
    const entry = self.browsers.get(handle) orelse return 0;
    const host = cef.asPtr(c.cef_browser_host_t, entry.browser.get_host.?(entry.browser)) orelse return 0;
    return host.get_zoom_level.?(host);
}

pub fn setAudioMutedImpl(ctx: ?*anyopaque, handle: u64, muted: bool) void {
    assertUiThread();
    const self = fromCtx(ctx);
    const entry = self.browsers.get(handle) orelse return;
    const host = cef.asPtr(c.cef_browser_host_t, entry.browser.get_host.?(entry.browser)) orelse return;
    host.set_audio_muted.?(host, if (muted) 1 else 0);
}

pub fn isAudioMutedImpl(ctx: ?*anyopaque, handle: u64) bool {
    const self = fromCtx(ctx);
    const entry = self.browsers.get(handle) orelse return false;
    const host = cef.asPtr(c.cef_browser_host_t, entry.browser.get_host.?(entry.browser)) orelse return false;
    return host.is_audio_muted.?(host) != 0;
}

/// Six trivial edit methods that dispatch to the main frame.
pub fn makeFrameEditFn(comptime field: []const u8) *const fn (?*anyopaque, u64) void {
    comptime {
        if (!@hasField(c.cef_frame_t, field)) {
            @compileError("cef_frame_t에 '" ++ field ++ "' 필드 없음");
        }
    }
    return struct {
        fn call(ctx: ?*anyopaque, handle: u64) void {
            assertUiThread();
            const self = fromCtx(ctx);
            const entry = self.browsers.get(handle) orelse return;
            const frame = cef.asPtr(c.cef_frame_t, entry.browser.get_main_frame.?(entry.browser)) orelse return;
            const fn_ptr = @field(frame, field) orelse return;
            fn_ptr(frame);
        }
    }.call;
}

pub fn findInPageImpl(ctx: ?*anyopaque, handle: u64, text: []const u8, forward: bool, match_case: bool, find_next: bool) void {
    assertUiThread();
    const self = fromCtx(ctx);
    const entry = self.browsers.get(handle) orelse return;
    const host = cef.asPtr(c.cef_browser_host_t, entry.browser.get_host.?(entry.browser)) orelse return;

    var text_buf: [FIND_TEXT_STACK_BUF]u8 = undefined;
    const text_z = cef.nullTerminateOrTruncate(text, &text_buf) orelse {
        log.warn("find_in_page: text {d} bytes > {d} stack buf — dropped", .{ text.len, FIND_TEXT_STACK_BUF });
        return;
    };
    var cef_text: c.cef_string_t = .{};
    cef.setCefString(&cef_text, text_z);
    const find = host.find orelse return;
    find(host, &cef_text, @intFromBool(forward), @intFromBool(match_case), @intFromBool(find_next));
}

pub fn stopFindInPageImpl(ctx: ?*anyopaque, handle: u64, clear_selection: bool) void {
    assertUiThread();
    const self = fromCtx(ctx);
    const entry = self.browsers.get(handle) orelse return;
    const host = cef.asPtr(c.cef_browser_host_t, entry.browser.get_host.?(entry.browser)) orelse return;
    const stop = host.stop_finding orelse return;
    stop(host, @intFromBool(clear_selection));
}
