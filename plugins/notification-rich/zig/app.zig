//! @suji/plugin-notification-rich — rich toast notifications.
//!
//! 코어 `suji.notification.show` 는 Win32 Shell_NotifyIcon balloon (action 버튼
//! 없음, Action Center 영속 제한적). 이 플러그인은 Windows 에서 WinRT
//! ToastNotificationManager 로 정식 toast 를 표시 — action 버튼, 이미지,
//! Action Center 영속 (시스템이 종료 후에도 알림 보관).
//!
//! 채널:
//!   notification:rich_show   {title, body, actions?, image?, scenario?, silent?}
//!                                                          → {id}
//!   notification:rich_hide   {id}                          → {ok:true}
//!
//! 플랫폼:
//!   Windows: WinRT Windows.UI.Notifications.ToastNotificationManager — 정식
//!     toast XML 템플릿 (ToastGeneric), action 버튼 표시, Action Center 자동 영속.
//!     ⚠️ action 버튼 click 콜백은 NotificationActivator COM 클래스 등록 필요
//!     (별도 인스톨러 + AppUserModelID HKCU 등록) — 미등록 시 click 무반응.
//!     v1 정직 경계: 표시/영속/AUMID set 까지. click→back-channel 은 backlog.
//!   macOS: UNUserNotificationCenter category/action 기반 버튼 + attachment
//!     image(best-effort). loose binary 에서는 Bundle ID/권한 한계로 show 실패 가능.
//!   Linux: Freedesktop Notifications D-Bus Notify actions + ActionInvoked
//!     signal. notification daemon/session bus 부재 시 graceful error.

const std = @import("std");
const builtin = @import("builtin");
const suji = @import("suji");

const is_macos = builtin.os.tag == .macos;
const is_linux = builtin.os.tag == .linux;

pub const app = suji.app()
    .named("notification-rich")
    .handle("notification:rich_show", richShow)
    .handle("notification:rich_hide", richHide)
    .handle("notification:set_image_roots", setImageRoots)
    .handle("notification:get_image_roots", getImageRoots);

var gpa: std.heap.DebugAllocator(.{}) = .init;
const alloc = gpa.allocator();

const MAX_TITLE: usize = 256;
const MAX_BODY: usize = 1024;
const MAX_ACTIONS: usize = 5;
const MAX_LABEL: usize = 64;
const MAX_ID: usize = 64;
const MAX_IMAGE_PATH: usize = 4096;
const MAX_IMAGE_ROOTS: usize = 32;
const MAX_ROOT_LEN: usize = 4096;

var next_id: u64 = 1;
var id_mutex: std.Io.Mutex = .init;

fn nextId() u64 {
    id_mutex.lockUncancelable(suji.io());
    defer id_mutex.unlock(suji.io());
    next_id += 1;
    return next_id;
}

// ============================================
// Image path allowlist — fs sandbox 와 동형:
//   * "..": 어떤 모드든 차단 (path traversal)
//   * roots 비어 있음 → 모든 image 차단 (deny-by-default)
//   * 매칭은 prefix + separator boundary (/foo/bar 허용 시 /foo/barX 통과 X)
//   * ["*"] = escape hatch (".." 만 차단)
// ============================================

var image_roots: std.ArrayList([]const u8) = .empty;
var image_roots_mutex: std.Io.Mutex = .init;

fn clearImageRoots() void {
    for (image_roots.items) |r| alloc.free(r);
    image_roots.clearRetainingCapacity();
}

fn hasParentTraversal(path: []const u8) bool {
    // ".." path component 검출 — / 와 \ 둘 다 separator 로 취급.
    var i: usize = 0;
    while (i < path.len) {
        // 다음 component 의 시작
        const start = i;
        while (i < path.len and path[i] != '/' and path[i] != '\\') : (i += 1) {}
        if (std.mem.eql(u8, path[start..i], "..")) return true;
        if (i < path.len) i += 1; // separator 건너뛰기
    }
    return false;
}

/// `/` 와 `\` 를 동치 separator 로 보고, 호스트 OS 가 path case-insensitive 면
/// (Windows/macOS) ASCII case 무시. Linux 만 case-sensitive 비교.
fn pathByteEqual(a: u8, b: u8) bool {
    if (a == b) return true;
    if ((a == '/' or a == '\\') and (b == '/' or b == '\\')) return true;
    if (builtin.os.tag != .linux) {
        return std.ascii.toLower(a) == std.ascii.toLower(b);
    }
    return false;
}

fn pathPrefixMatchesRoot(path: []const u8, root: []const u8) bool {
    if (root.len == 0) return false;
    if (path.len < root.len) return false;
    var i: usize = 0;
    while (i < root.len) : (i += 1) {
        if (!pathByteEqual(path[i], root[i])) return false;
    }
    if (path.len == root.len) return true;
    // separator boundary — root 끝이 / 거나 \ 면 OK, 아니면 다음 char 가 separator 여야.
    const last = root[root.len - 1];
    if (last == '/' or last == '\\') return true;
    const next = path[root.len];
    return next == '/' or next == '\\';
}

fn isImageAllowed(path: []const u8) bool {
    if (path.len == 0 or path.len > MAX_IMAGE_PATH) return false;
    if (hasParentTraversal(path)) return false;
    image_roots_mutex.lockUncancelable(suji.io());
    defer image_roots_mutex.unlock(suji.io());
    if (image_roots.items.len == 0) return false;
    for (image_roots.items) |root| {
        if (std.mem.eql(u8, root, "*")) return true; // escape hatch
        if (pathPrefixMatchesRoot(path, root)) return true;
    }
    return false;
}

// ============================================
// JSON helpers
// ============================================

/// JSON output 용 진짜 JSON 이스케이프 — `"\` 와 제어문자 처리.
fn realJsonEscapeAppend(buf: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(a, "\\\""),
            '\\' => try buf.appendSlice(a, "\\\\"),
            '\n' => try buf.appendSlice(a, "\\n"),
            '\r' => try buf.appendSlice(a, "\\r"),
            '\t' => try buf.appendSlice(a, "\\t"),
            0...8, 11, 12, 14...31 => {
                var tmp: [6]u8 = undefined;
                const out = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c}) catch continue;
                try buf.appendSlice(a, out);
            },
            else => try buf.append(a, c),
        }
    }
}

/// XML 콘텐츠/속성 이스케이프 (이름은 jsonEscapeAppend 지만 실제로는 XML/HTML
/// 엔티티). toast XML body 에서만 사용. ⚠️ JSON output 에는 realJsonEscapeAppend 사용.
fn jsonEscapeAppend(buf: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(a, "&quot;"),
            '&' => try buf.appendSlice(a, "&amp;"),
            '<' => try buf.appendSlice(a, "&lt;"),
            '>' => try buf.appendSlice(a, "&gt;"),
            '\'' => try buf.appendSlice(a, "&apos;"),
            else => try buf.append(a, c),
        }
    }
}

// ============================================
// Windows WinRT bindings (combase / RoActivate / vtable plumbing)
// ============================================

const winrt = if (builtin.os.tag == .windows) struct {
    const HRESULT = i32;
    const HSTRING = ?*opaque {};
    const HSTRING_HEADER = extern struct {
        reserved: [24]u8 align(@alignOf(usize)) = [_]u8{0} ** 24,
    };
    const TrustLevel = u32;

    const IID = extern struct {
        a: u32,
        b: u16,
        c: u16,
        d: [8]u8,
    };

    const S_OK: HRESULT = 0;
    const RPC_E_CHANGED_MODE: HRESULT = @bitCast(@as(u32, 0x80010106));

    const RO_INIT_MULTITHREADED: u32 = 1;

    // combase / shell32 동적 로드 — MinGW import lib 부재 회피.
    const RoInitializeFn = *const fn (u32) callconv(.winapi) HRESULT;
    const WindowsCreateStringFn = *const fn (?[*]const u16, u32, *HSTRING) callconv(.winapi) HRESULT;
    const WindowsDeleteStringFn = *const fn (HSTRING) callconv(.winapi) HRESULT;
    const RoActivateInstanceFn = *const fn (HSTRING, *?*IInspectable) callconv(.winapi) HRESULT;
    const RoGetActivationFactoryFn = *const fn (HSTRING, *const IID, *?*anyopaque) callconv(.winapi) HRESULT;
    const SetAumidFn = *const fn ([*:0]const u16) callconv(.winapi) HRESULT;

    const HMODULE = ?*opaque {};
    extern "kernel32" fn LoadLibraryW(name: [*:0]const u16) callconv(.winapi) HMODULE;
    extern "kernel32" fn GetProcAddress(mod: HMODULE, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;

    var combase_loaded: bool = false;
    var combase_load_mutex: std.Io.Mutex = .init;
    var pRoInitialize: ?RoInitializeFn = null;
    var pWindowsCreateString: ?WindowsCreateStringFn = null;
    var pWindowsDeleteString: ?WindowsDeleteStringFn = null;
    var pRoActivateInstance: ?RoActivateInstanceFn = null;
    var pRoGetActivationFactory: ?RoGetActivationFactoryFn = null;
    var pSetAumid: ?SetAumidFn = null;

    fn loadCombase() bool {
        combase_load_mutex.lockUncancelable(suji.io());
        defer combase_load_mutex.unlock(suji.io());
        if (combase_loaded) return pRoInitialize != null;
        combase_loaded = true;
        const combase_name = std.unicode.utf8ToUtf16LeStringLiteral("combase.dll");
        const shell32_name = std.unicode.utf8ToUtf16LeStringLiteral("shell32.dll");
        const combase = LoadLibraryW(combase_name) orelse return false;
        const shell32 = LoadLibraryW(shell32_name) orelse return false;
        pRoInitialize = @ptrCast(GetProcAddress(combase, "RoInitialize") orelse return false);
        pWindowsCreateString = @ptrCast(GetProcAddress(combase, "WindowsCreateString") orelse return false);
        pWindowsDeleteString = @ptrCast(GetProcAddress(combase, "WindowsDeleteString") orelse return false);
        pRoActivateInstance = @ptrCast(GetProcAddress(combase, "RoActivateInstance") orelse return false);
        pRoGetActivationFactory = @ptrCast(GetProcAddress(combase, "RoGetActivationFactory") orelse return false);
        pSetAumid = @ptrCast(GetProcAddress(shell32, "SetCurrentProcessExplicitAppUserModelID") orelse return false);
        return true;
    }

    fn RoInitialize(t: u32) HRESULT {
        return (pRoInitialize orelse return -1)(t);
    }
    fn WindowsCreateString(src: ?[*]const u16, len: u32, hs: *HSTRING) HRESULT {
        return (pWindowsCreateString orelse return -1)(src, len, hs);
    }
    fn WindowsDeleteString(hs: HSTRING) HRESULT {
        return (pWindowsDeleteString orelse return -1)(hs);
    }
    fn RoActivateInstance(name: HSTRING, out: *?*IInspectable) HRESULT {
        return (pRoActivateInstance orelse return -1)(name, out);
    }
    fn RoGetActivationFactory(name: HSTRING, iid: *const IID, out: *?*anyopaque) HRESULT {
        return (pRoGetActivationFactory orelse return -1)(name, iid, out);
    }
    fn SetCurrentProcessExplicitAppUserModelID(aumid: [*:0]const u16) HRESULT {
        return (pSetAumid orelse return -1)(aumid);
    }

    // ---- IID 정의 (Windows SDK 헤더에서 발췌) ----
    const IID_IInspectable: IID = .{ .a = 0xAF86E2E0, .b = 0xB12D, .c = 0x4c6a, .d = .{ 0x9C, 0x5A, 0xD7, 0xAA, 0x65, 0x10, 0x1E, 0x90 } };
    const IID_IXmlDocument: IID = .{ .a = 0xf7f3a506, .b = 0x1e87, .c = 0x42d6, .d = .{ 0xbc, 0xfb, 0xb8, 0xc8, 0x09, 0xfa, 0x54, 0x94 } };
    const IID_IXmlDocumentIO: IID = .{ .a = 0x6cd0e74e, .b = 0xee65, .c = 0x4489, .d = .{ 0x9e, 0xbf, 0xca, 0x43, 0xe8, 0x7b, 0xa6, 0x37 } };
    const IID_IToastNotificationFactory: IID = .{ .a = 0x04124b20, .b = 0x82c6, .c = 0x4229, .d = .{ 0xb1, 0x09, 0xfd, 0x9e, 0xd4, 0x66, 0x2b, 0x53 } };
    const IID_IToastNotificationManagerStatics: IID = .{ .a = 0x50ac103f, .b = 0xd235, .c = 0x4598, .d = .{ 0xbb, 0xef, 0x98, 0xfe, 0x4d, 0x1a, 0x3a, 0xd4 } };
    const IID_IToastNotification: IID = .{ .a = 0x997e2675, .b = 0x059e, .c = 0x4e60, .d = .{ 0x8b, 0x06, 0x17, 0x60, 0x91, 0x74, 0x95, 0x52 } };

    // ---- IInspectable (IUnknown + 3 more) ----
    const IInspectable = extern struct {
        vtbl: *const VTable,

        const VTable = extern struct {
            QueryInterface: *const fn (*IInspectable, *const IID, *?*anyopaque) callconv(.winapi) HRESULT,
            AddRef: *const fn (*IInspectable) callconv(.winapi) u32,
            Release: *const fn (*IInspectable) callconv(.winapi) u32,
            GetIids: *const fn (*IInspectable, *u32, *?[*]IID) callconv(.winapi) HRESULT,
            GetRuntimeClassName: *const fn (*IInspectable, *HSTRING) callconv(.winapi) HRESULT,
            GetTrustLevel: *const fn (*IInspectable, *TrustLevel) callconv(.winapi) HRESULT,
        };

        fn queryInterface(self: *IInspectable, iid: *const IID, out: *?*anyopaque) HRESULT {
            return self.vtbl.QueryInterface(self, iid, out);
        }
        fn release(self: *IInspectable) void {
            _ = self.vtbl.Release(self);
        }
    };

    // ---- IXmlDocumentIO (IInspectable + 2) ----
    const IXmlDocumentIO = extern struct {
        vtbl: *const VTable,

        const VTable = extern struct {
            // IUnknown
            QueryInterface: *const anyopaque,
            AddRef: *const anyopaque,
            Release: *const fn (*IXmlDocumentIO) callconv(.winapi) u32,
            // IInspectable
            GetIids: *const anyopaque,
            GetRuntimeClassName: *const anyopaque,
            GetTrustLevel: *const anyopaque,
            // IXmlDocumentIO
            LoadXml: *const fn (*IXmlDocumentIO, HSTRING) callconv(.winapi) HRESULT,
            LoadXmlWithSettings: *const anyopaque,
            SaveToFileAsync: *const anyopaque,
        };

        fn loadXml(self: *IXmlDocumentIO, xml: HSTRING) HRESULT {
            return self.vtbl.LoadXml(self, xml);
        }
        fn release(self: *IXmlDocumentIO) void {
            _ = self.vtbl.Release(self);
        }
    };

    // ---- IToastNotificationFactory ----
    const IToastNotificationFactory = extern struct {
        vtbl: *const VTable,

        const VTable = extern struct {
            QueryInterface: *const anyopaque,
            AddRef: *const anyopaque,
            Release: *const fn (*IToastNotificationFactory) callconv(.winapi) u32,
            GetIids: *const anyopaque,
            GetRuntimeClassName: *const anyopaque,
            GetTrustLevel: *const anyopaque,
            CreateToastNotification: *const fn (*IToastNotificationFactory, *anyopaque, *?*IToastNotification) callconv(.winapi) HRESULT,
        };

        fn createToastNotification(self: *IToastNotificationFactory, xml_doc: *anyopaque, out: *?*IToastNotification) HRESULT {
            return self.vtbl.CreateToastNotification(self, xml_doc, out);
        }
        fn release(self: *IToastNotificationFactory) void {
            _ = self.vtbl.Release(self);
        }
    };

    // ---- IToastNotificationManagerStatics ----
    const IToastNotificationManagerStatics = extern struct {
        vtbl: *const VTable,

        const VTable = extern struct {
            QueryInterface: *const anyopaque,
            AddRef: *const anyopaque,
            Release: *const fn (*IToastNotificationManagerStatics) callconv(.winapi) u32,
            GetIids: *const anyopaque,
            GetRuntimeClassName: *const anyopaque,
            GetTrustLevel: *const anyopaque,
            CreateToastNotifier: *const anyopaque,
            CreateToastNotifierWithId: *const fn (*IToastNotificationManagerStatics, HSTRING, *?*IToastNotifier) callconv(.winapi) HRESULT,
            GetTemplateContent: *const anyopaque,
        };

        fn createToastNotifierWithId(self: *IToastNotificationManagerStatics, aumid: HSTRING, out: *?*IToastNotifier) HRESULT {
            return self.vtbl.CreateToastNotifierWithId(self, aumid, out);
        }
        fn release(self: *IToastNotificationManagerStatics) void {
            _ = self.vtbl.Release(self);
        }
    };

    // ---- IToastNotifier ----
    const IToastNotifier = extern struct {
        vtbl: *const VTable,

        const VTable = extern struct {
            QueryInterface: *const anyopaque,
            AddRef: *const anyopaque,
            Release: *const fn (*IToastNotifier) callconv(.winapi) u32,
            GetIids: *const anyopaque,
            GetRuntimeClassName: *const anyopaque,
            GetTrustLevel: *const anyopaque,
            Show: *const fn (*IToastNotifier, *IToastNotification) callconv(.winapi) HRESULT,
            Hide: *const fn (*IToastNotifier, *IToastNotification) callconv(.winapi) HRESULT,
            GetSetting: *const anyopaque,
            AddToSchedule: *const anyopaque,
            RemoveFromSchedule: *const anyopaque,
            GetScheduledToastNotifications: *const anyopaque,
        };

        fn show(self: *IToastNotifier, toast: *IToastNotification) HRESULT {
            return self.vtbl.Show(self, toast);
        }
        fn hide(self: *IToastNotifier, toast: *IToastNotification) HRESULT {
            return self.vtbl.Hide(self, toast);
        }
        fn release(self: *IToastNotifier) void {
            _ = self.vtbl.Release(self);
        }
    };

    // ---- IToastNotification (subset — opaque, 우리는 Show/Hide 인자로만 사용) ----
    const IToastNotification = extern struct {
        vtbl: *const VTable,
        const VTable = extern struct {
            QueryInterface: *const anyopaque,
            AddRef: *const anyopaque,
            Release: *const fn (*IToastNotification) callconv(.winapi) u32,
            // ... 추가 메서드는 v1 에서 호출 안 함
        };

        fn release(self: *IToastNotification) void {
            _ = self.vtbl.Release(self);
        }
    };

    // ============================================
    // 헬퍼: UTF-8 → HSTRING
    // ============================================

    fn utf8ToHstring(a: std.mem.Allocator, src: []const u8) !HSTRING {
        const u16_slice = try std.unicode.utf8ToUtf16LeAlloc(a, src);
        defer a.free(u16_slice);
        var hs: HSTRING = null;
        const hr = WindowsCreateString(u16_slice.ptr, @intCast(u16_slice.len), &hs);
        if (hr != S_OK) return error.HstringCreate;
        return hs;
    }

    fn deleteHstring(hs: HSTRING) void {
        _ = WindowsDeleteString(hs);
    }

    // ============================================
    // 영속 toast 저장 (hide 용)
    // ============================================

    var live_toasts_mutex: std.Io.Mutex = .init;
    var live_toasts: std.AutoHashMap(u64, LiveToast) = std.AutoHashMap(u64, LiveToast).init(alloc);
    const LiveToast = struct {
        toast: *IToastNotification,
        notifier: *IToastNotifier,
    };

    /// OOM 시 toast/notifier release (COM AddRef 해제) — 호출자가 fail 알기.
    fn rememberToast(id: u64, toast: *IToastNotification, notifier: *IToastNotifier) bool {
        live_toasts_mutex.lockUncancelable(suji.io());
        defer live_toasts_mutex.unlock(suji.io());
        live_toasts.put(id, .{ .toast = toast, .notifier = notifier }) catch return false;
        return true;
    }

    fn forgetAndHide(id: u64) bool {
        live_toasts_mutex.lockUncancelable(suji.io());
        defer live_toasts_mutex.unlock(suji.io());
        if (live_toasts.fetchRemove(id)) |kv| {
            _ = kv.value.notifier.hide(kv.value.toast);
            kv.value.toast.release();
            kv.value.notifier.release();
            return true;
        }
        return false;
    }

    // ============================================
    // AUMID 초기화 (idempotent)
    // ============================================

    var aumid_set: bool = false;
    var aumid_mutex: std.Io.Mutex = .init;
    const DEFAULT_AUMID = "ohah.Suji.App";

    fn ensureAumid(a: std.mem.Allocator) !void {
        aumid_mutex.lockUncancelable(suji.io());
        defer aumid_mutex.unlock(suji.io());
        if (aumid_set) return;
        if (!loadCombase()) return error.NoWinRT;
        const u16_aumid = std.unicode.utf8ToUtf16LeAllocZ(a, DEFAULT_AUMID) catch return error.HstringCreate;
        defer a.free(u16_aumid);
        const set_hr = SetCurrentProcessExplicitAppUserModelID(u16_aumid.ptr);
        if (set_hr < 0) return error.NoWinRT;
        // RoInitialize — S_OK(0), S_FALSE(1 = 이미 init), RPC_E_CHANGED_MODE 모두
        // 후속 호출 가능. 실패(< 0 이면서 changed_mode 아님) 시 flag 안 set.
        const init_hr = RoInitialize(RO_INIT_MULTITHREADED);
        if (init_hr < 0 and init_hr != RPC_E_CHANGED_MODE) return error.NoWinRT;
        aumid_set = true;
    }

    // ============================================
    // 메인 show: XML → toast → show
    // ============================================

    fn showRich(a: std.mem.Allocator, xml: []const u8) !u64 {
        try ensureAumid(a);

        // 1. RoActivateInstance("Windows.Data.Xml.Dom.XmlDocument") → IInspectable
        const xml_doc_class_name = "Windows.Data.Xml.Dom.XmlDocument";
        const xml_doc_hs = try utf8ToHstring(a, xml_doc_class_name);
        defer deleteHstring(xml_doc_hs);
        var xml_doc_inspectable: ?*IInspectable = null;
        if (RoActivateInstance(xml_doc_hs, &xml_doc_inspectable) != S_OK) return error.XmlDocActivate;
        const xml_doc = xml_doc_inspectable orelse return error.XmlDocActivate;
        defer xml_doc.release();

        // 2. QueryInterface(IXmlDocumentIO) → LoadXml
        var xml_io_raw: ?*anyopaque = null;
        if (xml_doc.queryInterface(&IID_IXmlDocumentIO, &xml_io_raw) != S_OK) return error.QIXmlIO;
        const xml_io: *IXmlDocumentIO = @ptrCast(@alignCast(xml_io_raw.?));
        defer xml_io.release();

        const xml_hs = try utf8ToHstring(a, xml);
        defer deleteHstring(xml_hs);
        if (xml_io.loadXml(xml_hs) != S_OK) return error.LoadXml;

        // 3. RoGetActivationFactory("Windows.UI.Notifications.ToastNotification", IID_IToastNotificationFactory)
        const toast_class_name = "Windows.UI.Notifications.ToastNotification";
        const toast_class_hs = try utf8ToHstring(a, toast_class_name);
        defer deleteHstring(toast_class_hs);
        var factory_raw: ?*anyopaque = null;
        if (RoGetActivationFactory(toast_class_hs, &IID_IToastNotificationFactory, &factory_raw) != S_OK) return error.GetFactory;
        const factory: *IToastNotificationFactory = @ptrCast(@alignCast(factory_raw.?));
        defer factory.release();

        // 4. factory.CreateToastNotification(xml_doc) → IToastNotification
        var toast: ?*IToastNotification = null;
        // CreateToastNotification 은 IXmlDocument* 를 요구; xml_doc 자체가 IInspectable
        // 인데 IXmlDocument 와 호환되는 vtable layout 임 — QI 로 안전하게 받아도 되지만
        // 여기서는 IInspectable 포인터를 그대로 넘김(WinRT 표준 동작).
        if (factory.createToastNotification(@ptrCast(xml_doc), &toast) != S_OK) return error.CreateToast;
        const toast_obj = toast orelse return error.CreateToast;
        errdefer toast_obj.release();

        // 5. RoGetActivationFactory("Windows.UI.Notifications.ToastNotificationManager", ...)
        const mgr_class_name = "Windows.UI.Notifications.ToastNotificationManager";
        const mgr_class_hs = try utf8ToHstring(a, mgr_class_name);
        defer deleteHstring(mgr_class_hs);
        var mgr_raw: ?*anyopaque = null;
        if (RoGetActivationFactory(mgr_class_hs, &IID_IToastNotificationManagerStatics, &mgr_raw) != S_OK) return error.GetMgr;
        const mgr: *IToastNotificationManagerStatics = @ptrCast(@alignCast(mgr_raw.?));
        defer mgr.release();

        // 6. CreateToastNotifierWithId(aumid) → IToastNotifier
        const aumid_hs = try utf8ToHstring(a, DEFAULT_AUMID);
        defer deleteHstring(aumid_hs);
        var notifier: ?*IToastNotifier = null;
        if (mgr.createToastNotifierWithId(aumid_hs, &notifier) != S_OK) return error.GetNotifier;
        const notifier_obj = notifier orelse return error.GetNotifier;
        errdefer notifier_obj.release();

        // 7. notifier.Show(toast)
        if (notifier_obj.show(toast_obj) != S_OK) return error.Show;

        // 8. live_toasts 에 보관 (hide 가능하도록 — release 보류). put OOM 시
        // error 반환하면 위쪽 errdefer toast_obj.release/notifier_obj.release 가
        // AddRef 된 COM 객체 정리 — silent leak 방지.
        const id = nextId();
        if (!rememberToast(id, toast_obj, notifier_obj)) return error.RegistryFull;
        return id;
    }
} else struct {};

const CStr = [*:0]const u8;

const macos_rich = if (is_macos) struct {
    extern fn suji_notification_rich_macos_set_action_callback(
        cb: ?*const fn (CStr, CStr) callconv(.c) void,
    ) void;
    extern fn suji_notification_rich_macos_show(
        id: CStr,
        title: CStr,
        body: CStr,
        image_path: ?CStr,
        silent: c_int,
        action_ids: [*]const CStr,
        action_labels: [*]const CStr,
        action_count: c_int,
    ) c_int;
    extern fn suji_notification_rich_macos_hide(id: CStr) void;
} else struct {};

const linux_rich = if (is_linux) struct {
    extern fn suji_notification_rich_linux_set_action_callback(
        cb: ?*const fn (CStr, CStr) callconv(.c) void,
    ) void;
    extern fn suji_notification_rich_linux_show(
        id: CStr,
        title: CStr,
        body: CStr,
        image_path: ?CStr,
        silent: c_int,
        action_ids: [*]const CStr,
        action_labels: [*]const CStr,
        action_count: c_int,
    ) c_int;
    extern fn suji_notification_rich_linux_hide(id: CStr) void;
} else struct {};

fn emitRichActionClick(notification_id_c: CStr, action_id_c: CStr) callconv(.c) void {
    const notification_id = std.mem.span(notification_id_c);
    const action_id = std.mem.span(action_id_c);
    var id_esc: [MAX_ID * 6]u8 = undefined;
    var action_esc: [MAX_ID * 6]u8 = undefined;
    const id_n = escapeJsonFixed(notification_id, &id_esc) orelse return;
    const action_n = escapeJsonFixed(action_id, &action_esc) orelse return;
    var payload: [MAX_ID * 12 + 80]u8 = undefined;
    const json = std.fmt.bufPrint(
        &payload,
        "{{\"notificationId\":\"{s}\",\"actionId\":\"{s}\"}}",
        .{ id_esc[0..id_n], action_esc[0..action_n] },
    ) catch return;
    suji.send("notification:click", json);
}

fn ensurePlatformActionCallback() void {
    if (comptime is_macos) {
        macos_rich.suji_notification_rich_macos_set_action_callback(&emitRichActionClick);
    } else if (comptime is_linux) {
        linux_rich.suji_notification_rich_linux_set_action_callback(&emitRichActionClick);
    }
}

fn escapeJsonFixed(src: []const u8, dst: []u8) ?usize {
    var n: usize = 0;
    for (src) |c| {
        const out = switch (c) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            0...8, 11, 12, 14...31 => return null,
            else => null,
        };
        if (out) |s| {
            if (n + s.len > dst.len) return null;
            @memcpy(dst[n .. n + s.len], s);
            n += s.len;
        } else {
            if (n + 1 > dst.len) return null;
            dst[n] = c;
            n += 1;
        }
    }
    return n;
}

var live_notifications_mutex: std.Io.Mutex = .init;
var live_notifications: std.AutoHashMap(u64, void) = std.AutoHashMap(u64, void).init(alloc);

fn rememberLiveNotification(id: u64) bool {
    live_notifications_mutex.lockUncancelable(suji.io());
    defer live_notifications_mutex.unlock(suji.io());
    live_notifications.put(id, {}) catch return false;
    return true;
}

fn forgetLiveNotification(id: u64) bool {
    live_notifications_mutex.lockUncancelable(suji.io());
    defer live_notifications_mutex.unlock(suji.io());
    return live_notifications.remove(id);
}

// ============================================
// XML 빌더
// ============================================

fn buildToastXml(a: std.mem.Allocator, title: []const u8, body: []const u8, actions_raw: ?[]const u8, image_path: ?[]const u8, scenario: ?[]const u8, silent: bool) ?[]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);

    buf.appendSlice(a, "<toast") catch return null;
    if (scenario) |s| {
        if (std.mem.eql(u8, s, "alarm") or std.mem.eql(u8, s, "reminder") or std.mem.eql(u8, s, "incomingCall") or std.mem.eql(u8, s, "urgent")) {
            buf.appendSlice(a, " scenario=\"") catch return null;
            buf.appendSlice(a, s) catch return null;
            buf.append(a, '"') catch return null;
        }
    }
    buf.appendSlice(a, "><visual><binding template=\"ToastGeneric\"><text>") catch return null;
    jsonEscapeAppend(&buf, a, title) catch return null;
    buf.appendSlice(a, "</text><text>") catch return null;
    jsonEscapeAppend(&buf, a, body) catch return null;
    buf.appendSlice(a, "</text>") catch return null;
    if (image_path) |img| if (img.len > 0) {
        buf.appendSlice(a, "<image src=\"file:///") catch return null;
        for (img) |c| {
            switch (c) {
                '"' => buf.appendSlice(a, "&quot;") catch return null,
                '\\' => buf.append(a, '/') catch return null,
                '&' => buf.appendSlice(a, "&amp;") catch return null,
                '<' => buf.appendSlice(a, "&lt;") catch return null,
                '>' => buf.appendSlice(a, "&gt;") catch return null,
                else => buf.append(a, c) catch return null,
            }
        }
        buf.appendSlice(a, "\"/>") catch return null;
    };
    buf.appendSlice(a, "</binding></visual>") catch return null;

    // actions: [{id, label}]
    if (actions_raw) |arr| if (arr.len > 0) {
        const parsed = std.json.parseFromSlice(std.json.Value, a, arr, .{}) catch return null;
        defer parsed.deinit();
        if (parsed.value == .array and parsed.value.array.items.len > 0) {
            buf.appendSlice(a, "<actions>") catch return null;
            var count: usize = 0;
            for (parsed.value.array.items) |item| {
                if (count >= MAX_ACTIONS) break;
                if (item != .object) continue;
                const id_val = item.object.get("id") orelse continue;
                const label_val = item.object.get("label") orelse continue;
                if (id_val != .string or label_val != .string) continue;
                if (id_val.string.len == 0 or id_val.string.len > MAX_ID) continue;
                if (label_val.string.len == 0 or label_val.string.len > MAX_LABEL) continue;
                buf.appendSlice(a, "<action content=\"") catch return null;
                jsonEscapeAppend(&buf, a, label_val.string) catch return null;
                buf.appendSlice(a, "\" arguments=\"action=") catch return null;
                jsonEscapeAppend(&buf, a, id_val.string) catch return null;
                buf.appendSlice(a, "\" activationType=\"foreground\"/>") catch return null;
                count += 1;
            }
            buf.appendSlice(a, "</actions>") catch return null;
        }
    };

    if (silent) {
        buf.appendSlice(a, "<audio silent=\"true\"/>") catch return null;
    }

    buf.appendSlice(a, "</toast>") catch return null;
    return buf.toOwnedSlice(a) catch null;
}

const ActionPointers = struct {
    ids: [MAX_ACTIONS]CStr = undefined,
    labels: [MAX_ACTIONS]CStr = undefined,
    count: usize = 0,
};

fn containsNul(s: []const u8) bool {
    return std.mem.indexOfScalar(u8, s, 0) != null;
}

fn collectActionPointers(req: suji.Request, actions_raw: ?[]const u8) !ActionPointers {
    var out: ActionPointers = .{};
    const raw = actions_raw orelse return out;
    if (raw.len == 0) return out;

    const parsed = std.json.parseFromSlice(std.json.Value, req.arena, raw, .{}) catch return error.InvalidActions;
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidActions;

    for (parsed.value.array.items) |item| {
        if (out.count >= MAX_ACTIONS) break;
        if (item != .object) continue;
        const id_val = item.object.get("id") orelse continue;
        const label_val = item.object.get("label") orelse continue;
        if (id_val != .string or label_val != .string) continue;
        if (id_val.string.len == 0 or id_val.string.len > MAX_ID) continue;
        if (label_val.string.len == 0 or label_val.string.len > MAX_LABEL) continue;
        if (containsNul(id_val.string) or containsNul(label_val.string)) continue;
        const id_z = req.arena.dupeZ(u8, id_val.string) catch return error.Alloc;
        const label_z = req.arena.dupeZ(u8, label_val.string) catch return error.Alloc;
        out.ids[out.count] = id_z.ptr;
        out.labels[out.count] = label_z.ptr;
        out.count += 1;
    }

    return out;
}

fn platformShowRich(
    req: suji.Request,
    id: u64,
    title: []const u8,
    body: []const u8,
    image_path: ?[]const u8,
    silent: bool,
    actions: *const ActionPointers,
) !void {
    if (containsNul(title) or containsNul(body)) return error.InvalidString;
    if (image_path) |img| if (containsNul(img)) return error.InvalidString;

    var id_buf: [32]u8 = undefined;
    const id_z = std.fmt.bufPrintZ(&id_buf, "{d}", .{id}) catch return error.Alloc;
    const title_z = req.arena.dupeZ(u8, title) catch return error.Alloc;
    const body_z = req.arena.dupeZ(u8, body) catch return error.Alloc;
    const image_z: ?[:0]u8 = if (image_path) |img| req.arena.dupeZ(u8, img) catch return error.Alloc else null;
    const image_ptr: ?CStr = if (image_z) |img| img.ptr else null;

    ensurePlatformActionCallback();
    const ok = if (comptime is_macos)
        macos_rich.suji_notification_rich_macos_show(
            id_z.ptr,
            title_z.ptr,
            body_z.ptr,
            image_ptr,
            if (silent) 1 else 0,
            actions.ids[0..].ptr,
            actions.labels[0..].ptr,
            @intCast(actions.count),
        ) != 0
    else if (comptime is_linux)
        linux_rich.suji_notification_rich_linux_show(
            id_z.ptr,
            title_z.ptr,
            body_z.ptr,
            image_ptr,
            if (silent) 1 else 0,
            actions.ids[0..].ptr,
            actions.labels[0..].ptr,
            @intCast(actions.count),
        ) != 0
    else
        false;

    if (!ok) return error.ShowFailed;
}

fn platformHideRich(id: u64) void {
    var id_buf: [32]u8 = undefined;
    const id_z = std.fmt.bufPrintZ(&id_buf, "{d}", .{id}) catch return;
    if (comptime is_macos) {
        macos_rich.suji_notification_rich_macos_hide(id_z.ptr);
    } else if (comptime is_linux) {
        linux_rich.suji_notification_rich_linux_hide(id_z.ptr);
    }
}

// ============================================
// Handlers
// ============================================

fn richShow(req: suji.Request, _: suji.InvokeEvent) suji.Response {
    const title = req.string("title") orelse return req.err("missing title");
    const body = req.string("body") orelse return req.err("missing body");
    if (title.len == 0 or title.len > MAX_TITLE) return req.err("invalid title");
    if (body.len > MAX_BODY) return req.err("body too long");

    const actions_raw = suji.extractJsonValue(req.raw, "actions");
    // image: 플러그인-자체 allowlist (set_image_roots) 통과 시 활성.
    // deny-by-default — roots 빈 상태 = image 무시(toast 는 표시되지만 image 없음).
    // 명시적 거부가 아니라 무시 — 호출자 친화(잘못된 image 가 전체 toast 실패시키지 않음).
    const image_path_raw = req.string("image");
    const image_path: ?[]const u8 = if (image_path_raw) |p|
        (if (isImageAllowed(p)) p else null)
    else
        null;
    const scenario = req.string("scenario");
    const silent_str = suji.extractJsonValue(req.raw, "silent");
    const silent = if (silent_str) |s| std.mem.eql(u8, std.mem.trim(u8, s, " \t\n\r"), "true") else false;

    const actions = collectActionPointers(req, actions_raw) catch |e| switch (e) {
        error.InvalidActions => return req.err("invalid actions"),
        else => return req.err("alloc"),
    };

    if (comptime is_macos or is_linux) {
        const id = nextId();
        platformShowRich(req, id, title, body, image_path, silent, &actions) catch |e| {
            const msg = switch (e) {
                error.InvalidString => "invalid string",
                error.ShowFailed => "show failed",
                else => "alloc",
            };
            return req.err(msg);
        };
        if (!rememberLiveNotification(id)) {
            platformHideRich(id);
            return req.err("registry full");
        }
        var buf: [64]u8 = undefined;
        const body_out = std.fmt.bufPrint(&buf, "{{\"id\":{d}}}", .{id}) catch return req.err("alloc");
        const owned = alloc.dupe(u8, body_out) catch return req.err("alloc");
        defer alloc.free(owned);
        return req.okRaw(owned);
    }

    if (comptime builtin.os.tag != .windows) return req.err("unsupported_platform");

    const xml = buildToastXml(alloc, title, body, actions_raw, image_path, scenario, silent) orelse return req.err("xml build failed");
    defer alloc.free(xml);

    // comptime 분기로 winrt 심볼이 non-Windows 빌드에서 semantic analysis 안 됨.
    const id = if (comptime builtin.os.tag == .windows) winrt.showRich(alloc, xml) catch |e| {
        const msg = switch (e) {
            error.HstringCreate => "hstring failed",
            error.XmlDocActivate => "xml activate failed",
            error.QIXmlIO => "qi xml io failed",
            error.LoadXml => "load xml failed",
            error.GetFactory => "get factory failed",
            error.CreateToast => "create toast failed",
            error.GetMgr => "get manager failed",
            error.GetNotifier => "get notifier failed",
            error.Show => "show failed",
            error.NoWinRT => "winrt unavailable",
            error.RegistryFull => "registry full",
            else => "winrt failed",
        };
        return req.err(msg);
    } else unreachable;

    var buf: [64]u8 = undefined;
    const body_out = std.fmt.bufPrint(&buf, "{{\"id\":{d}}}", .{id}) catch return req.err("alloc");
    const owned = alloc.dupe(u8, body_out) catch return req.err("alloc");
    defer alloc.free(owned);
    return req.okRaw(owned);
}

fn richHide(req: suji.Request, _: suji.InvokeEvent) suji.Response {
    const id_i = req.int("id") orelse return req.err("missing id");
    if (id_i < 0) return req.err("invalid id");
    if (comptime is_macos or is_linux) {
        const id: u64 = @intCast(id_i);
        if (!forgetLiveNotification(id)) return req.err("not_found");
        platformHideRich(id);
        return req.okRaw("{\"ok\":true}");
    }
    if (comptime builtin.os.tag != .windows) return req.err("unsupported_platform");
    const ok = if (comptime builtin.os.tag == .windows) winrt.forgetAndHide(@intCast(id_i)) else unreachable;
    if (!ok) return req.err("not_found");
    return req.okRaw("{\"ok\":true}");
}

fn setImageRoots(req: suji.Request, _: suji.InvokeEvent) suji.Response {
    const raw_array = suji.extractJsonValue(req.raw, "roots") orelse return req.err("missing roots");

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, raw_array, .{}) catch return req.err("invalid roots");
    defer parsed.deinit();
    if (parsed.value != .array) return req.err("roots must be array");
    if (parsed.value.array.items.len > MAX_IMAGE_ROOTS) return req.err("too many roots");

    var new_list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (new_list.items) |p| alloc.free(p);
        new_list.deinit(alloc);
    }
    for (parsed.value.array.items) |val| {
        if (val != .string) return req.err("root not string");
        if (val.string.len == 0 or val.string.len > MAX_ROOT_LEN) return req.err("invalid root");
        // 보안: root 자체에 ".." 가 들어가면 의도된 sandbox 가 아니므로 거부.
        // ("*" 는 단일 char escape hatch, ".." 검사 통과)
        if (!std.mem.eql(u8, val.string, "*") and hasParentTraversal(val.string)) return req.err("root has parent traversal");
        const owned = alloc.dupe(u8, val.string) catch return req.err("alloc");
        new_list.append(alloc, owned) catch {
            alloc.free(owned);
            return req.err("alloc");
        };
    }

    image_roots_mutex.lockUncancelable(suji.io());
    defer image_roots_mutex.unlock(suji.io());
    clearImageRoots();
    image_roots.deinit(alloc);
    image_roots = new_list;
    return req.okRaw("{\"ok\":true}");
}

fn getImageRoots(req: suji.Request, _: suji.InvokeEvent) suji.Response {
    image_roots_mutex.lockUncancelable(suji.io());
    defer image_roots_mutex.unlock(suji.io());

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(req.arena);
    out.appendSlice(req.arena, "{\"roots\":[") catch return req.err("alloc");
    for (image_roots.items, 0..) |root, i| {
        if (i > 0) out.append(req.arena, ',') catch return req.err("alloc");
        out.append(req.arena, '"') catch return req.err("alloc");
        realJsonEscapeAppend(&out, req.arena, root) catch return req.err("alloc");
        out.append(req.arena, '"') catch return req.err("alloc");
    }
    out.appendSlice(req.arena, "]}") catch return req.err("alloc");
    const final = out.toOwnedSlice(req.arena) catch return req.err("alloc");
    return req.okRaw(final);
}

comptime {
    _ = suji.exportApp(app);
}
