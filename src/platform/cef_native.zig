//! CefNative lifecycle shell.

const std = @import("std");
const builtin = @import("builtin");
const runtime = @import("runtime");
const window_mod = @import("window");
const logger = @import("logger");
const cef = @import("cef.zig");
const cef_views_policy = @import("cef_views_policy.zig");
const cef_browser_state = @import("cef_browser_state.zig");
const cef_client_handler = @import("cef_client_handler.zig");
const cef_native_entry = @import("cef_native_entry.zig");
const cef_native_refs = @import("cef_native_refs.zig");
const cef_native_registry = @import("cef_native_registry.zig");
const cef_native_vtable = @import("cef_native_vtable.zig");
const cef_web_contents_view = @import("cef_web_contents_view.zig");

const c = cef.c;
const log = logger.module("cef");

const cef_views_platform: cef_views_policy.Platform = switch (builtin.os.tag) {
    .macos => .macos,
    .linux => .linux,
    .windows => .windows,
    else => .other,
};

// 스레드 계약 (docs/WINDOW_API.md#스레드-모델):
// - 모든 vtable 함수는 CEF UI 스레드에서만 호출
// - 각 진입점에서 std.debug.assert로 방어
// - 잘못된 스레드 호출은 debug에서 crash, release에서 CEF CHECK abort
pub const CefNative = struct {
    pub const URL_CACHE_LEN = cef_native_entry.URL_CACHE_LEN;
    pub const BrowserEntry = cef_native_entry.BrowserEntry;

    allocator: std.mem.Allocator,
    use_views: bool = false,
    /// 모든 윈도우가 공유하는 client (콜백이 전부 module-global이라 공유 안전)
    client: c.cef_client_t = undefined,
    /// WindowManager의 native_handle (= CEF browser identifier를 u64로 캐스팅) → (browser, NSWindow).
    browsers: std.AutoHashMap(u64, BrowserEntry),
    /// opts.url이 null일 때 사용. 빈 문자열이면 createWindow의 setUrlOrBlank가 about:blank로
    /// fallback 처리 (CEF는 빈 URL이면 페이지 로드 skip — 라이프사이클 이벤트 미발화).
    default_url: [:0]const u8 = "",

    pub fn init(allocator: std.mem.Allocator) CefNative {
        cef_browser_state.ensureGlobalHandlers();
        var self: CefNative = .{
            .allocator = allocator,
            .browsers = std.AutoHashMap(u64, BrowserEntry).init(allocator),
            .use_views = cef_views_policy.enabled(cef_views_platform, runtime.env("SUJI_CEF_VIEWS")),
        };
        if (self.use_views) log.info("CEF Views path enabled", .{});
        cef_client_handler.initClient(&self.client);
        return self;
    }

    pub fn deinit(self: *CefNative) void {
        // 브라우저 수명은 CEF가 OnBeforeClose로 관리 → 우리는 테이블만 정리.
        var it = self.browsers.valueIterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.drag_regions);
            cef_native_refs.releaseDevToolsReg(entry);
            cef_web_contents_view.closeChildViewWindow(self, entry);
            cef_native_refs.releaseViewsEntry(entry);
        }
        self.browsers.deinit();
    }

    /// life_span_handler 콜백이 참조할 수 있도록 stable 포인터 등록.
    pub fn registerGlobal(self: *CefNative) void {
        cef_native_registry.registerGlobal(self);
    }

    pub fn unregisterGlobal() void {
        cef_native_registry.unregisterGlobal();
    }

    /// CEF가 OnBeforeClose에서 확정 파괴를 알렸을 때 테이블에서 제거.
    /// BrowserEntry가 보유한 CEF Views refs와 auxiliary NSWindow 포인터를 정리한다.
    pub fn purge(self: *CefNative, handle: u64) void {
        if (self.browsers.fetchRemove(handle)) |kv| {
            var entry = kv.value;
            self.allocator.free(entry.drag_regions);
            cef_native_refs.releaseReg(entry.devtools_reg); // 제거된 value — 포인터만 release(복사 X)
            cef_web_contents_view.closeChildViewWindow(self, &entry);
            cef_native_refs.releaseViewsEntry(&entry);
        }
    }

    pub fn asNative(self: *CefNative) window_mod.Native {
        return .{ .vtable = &cef_native_vtable.vtable, .ctx = self };
    }
};
