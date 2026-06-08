//! nativeTheme API — cef.zig 에서 분리(동작 무변경).
//! macOS NSAppearance + Windows registry/WM_SETTINGCHANGE bridge.
const std = @import("std");
const builtin = @import("builtin");
const cef = @import("cef.zig");

const is_macos = builtin.os.tag == .macos;

const objc = cef.objc;
const getClass = cef.getClass;
const msgSend = cef.msgSend;
const nsStringFromCstr = cef.nsStringFromCstr;
const nsStringToUtf8Buf = cef.nsStringToUtf8Buf;
const win_pump = cef.win_pump;

// ============================================
// Win32 NativeTheme FFI (Windows only).
// ============================================

const win_theme = if (builtin.os.tag == .windows) struct {
    const HKEY_CURRENT_USER: usize = 0x80000001;
    const KEY_SET_VALUE: u32 = 0x0002;
    const REG_DWORD: u32 = 4;
    const RRF_RT_REG_DWORD: u32 = 0x00000010;
    const HWND_BROADCAST: ?*anyopaque = @ptrFromInt(0xFFFF);
    const WM_SETTINGCHANGE: u32 = 0x001A;
    const SMTO_ABORTIFHUNG: u32 = 0x0002;
    const SPI_GETHIGHCONTRAST: u32 = 0x0042;
    const HCF_HIGHCONTRASTON: u32 = 0x00000001;

    const HIGHCONTRASTW = extern struct {
        cbSize: u32,
        dwFlags: u32,
        lpszDefaultScheme: ?[*:0]u16,
    };
    extern "user32" fn SystemParametersInfoW(
        uiAction: u32,
        uiParam: u32,
        pvParam: ?*anyopaque,
        fWinIni: u32,
    ) callconv(.winapi) i32;

    extern "advapi32" fn RegGetValueW(
        hkey: usize,
        lpSubKey: ?[*:0]const u16,
        lpValue: ?[*:0]const u16,
        dwFlags: u32,
        pdwType: ?*u32,
        pvData: ?*anyopaque,
        pcbData: ?*u32,
    ) callconv(.winapi) i32;
    extern "advapi32" fn RegOpenKeyExW(
        hkey: usize,
        lpSubKey: ?[*:0]const u16,
        ulOptions: u32,
        samDesired: u32,
        phkResult: *usize,
    ) callconv(.winapi) i32;
    extern "advapi32" fn RegSetValueExW(
        hkey: usize,
        lpValueName: ?[*:0]const u16,
        Reserved: u32,
        dwType: u32,
        lpData: *const anyopaque,
        cbData: u32,
    ) callconv(.winapi) i32;
    extern "advapi32" fn RegCloseKey(hkey: usize) callconv(.winapi) i32;
    extern "user32" fn SendMessageTimeoutW(
        hwnd: ?*anyopaque,
        Msg: u32,
        wParam: usize,
        lParam: isize,
        fuFlags: u32,
        uTimeout: u32,
        lpdwResult: ?*usize,
    ) callconv(.winapi) isize;

    /// HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize\AppsUseLightTheme
    /// DWORD: 0 = dark, 1 = light (default). 값 부재 시 light 가정 → false.
    fn isDark() bool {
        const sub_key = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize");
        const value_name = std.unicode.utf8ToUtf16LeStringLiteral("AppsUseLightTheme");
        var data: u32 = 1;
        var size: u32 = @sizeOf(u32);
        const status = RegGetValueW(
            HKEY_CURRENT_USER,
            sub_key.ptr,
            value_name.ptr,
            RRF_RT_REG_DWORD,
            null,
            &data,
            &size,
        );
        if (status != 0) return false; // ERROR_SUCCESS 가 아니면 default light.
        return data == 0;
    }

    /// HKCU AppsUseLightTheme write + WM_SETTINGCHANGE broadcast. CEF/Chromium
    /// 이 WM_SETTINGCHANGE("ImmersiveColorSet") 를 받아 즉시 dark/light refresh.
    /// source = "light"|"dark"|"system". "system" 은 registry 값 unchanged + broadcast
    /// (Windows 자체에는 "system follows OS" 개념이 앱 단에서 노출 안 됨 → no-op +
    /// nativeTheme:updated 만 emit 되도록 broadcast).
    /// 정직한 한계: Windows 는 OS-level dark mode 만 있고 "app 만 system 따라가게"
    /// 토글이 native 로 없음. system / dark / light 3 케이스 모두 HKCU
    /// AppsUseLightTheme 를 직접 set 한다 — system 은 현재 OS 의 SystemUsesLightTheme
    /// 값을 mirror 해서 AppsUseLightTheme 에 박는다. broadcast 후 Chromium 이 refresh.
    fn setSource(source: []const u8) bool {
        const sub_key = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize");
        const value_name = std.unicode.utf8ToUtf16LeStringLiteral("AppsUseLightTheme");
        const sys_value_name = std.unicode.utf8ToUtf16LeStringLiteral("SystemUsesLightTheme");
        var data: u32 = undefined;
        if (std.mem.eql(u8, source, "light")) {
            data = 1;
        } else if (std.mem.eql(u8, source, "dark")) {
            data = 0;
        } else if (std.mem.eql(u8, source, "system")) {
            // SystemUsesLightTheme 읽어 AppsUseLightTheme 에 mirror.
            var sys_data: u32 = 1;
            var sz: u32 = @sizeOf(u32);
            const rc = RegGetValueW(
                HKEY_CURRENT_USER,
                sub_key.ptr,
                sys_value_name.ptr,
                RRF_RT_REG_DWORD,
                null,
                &sys_data,
                &sz,
            );
            data = if (rc == 0) sys_data else 1;
        } else {
            return false;
        }
        var hkey: usize = 0;
        if (RegOpenKeyExW(HKEY_CURRENT_USER, sub_key.ptr, 0, KEY_SET_VALUE, &hkey) != 0) return false;
        defer _ = RegCloseKey(hkey);
        if (RegSetValueExW(hkey, value_name.ptr, 0, REG_DWORD, &data, @sizeOf(u32)) != 0) return false;
        broadcastSettingChange();
        return true;
    }

    fn broadcastSettingChange() void {
        const param_w = std.unicode.utf8ToUtf16LeStringLiteral("ImmersiveColorSet");
        _ = SendMessageTimeoutW(
            HWND_BROADCAST,
            WM_SETTINGCHANGE,
            0,
            @as(isize, @bitCast(@intFromPtr(param_w.ptr))),
            SMTO_ABORTIFHUNG,
            100,
            null,
        );
    }

    /// 고대비 모드 — SystemParametersInfo(SPI_GETHIGHCONTRAST) dwFlags & HCF_HIGHCONTRASTON.
    fn highContrast() bool {
        var hc: HIGHCONTRASTW = .{ .cbSize = @sizeOf(HIGHCONTRASTW), .dwFlags = 0, .lpszDefaultScheme = null };
        if (SystemParametersInfoW(SPI_GETHIGHCONTRAST, @sizeOf(HIGHCONTRASTW), &hc, 0) == 0) return false;
        return (hc.dwFlags & HCF_HIGHCONTRASTON) != 0;
    }

    /// 투명도 감소 선호 — HKCU\...\Themes\Personalize\EnableTransparency DWORD.
    /// 1 = 투명 효과 on(기본), 0 = off → reducedTransparency. 값 부재 시 on 가정 → false.
    fn reducedTransparency() bool {
        const sub_key = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize");
        const value_name = std.unicode.utf8ToUtf16LeStringLiteral("EnableTransparency");
        var data: u32 = 1;
        var size: u32 = @sizeOf(u32);
        const status = RegGetValueW(HKEY_CURRENT_USER, sub_key.ptr, value_name.ptr, RRF_RT_REG_DWORD, null, &data, &size);
        if (status != 0) return false; // 부재/오류 → 투명 on 가정.
        return data == 0;
    }
} else struct {};

/// 다크 모드 감지 (Electron `nativeTheme.shouldUseDarkColors`).
/// macOS 10.14+ NSApp.effectiveAppearance.name이 "Dark"를 포함하면 dark.
/// (NSAppearanceNameDarkAqua / NSAppearanceNameVibrantDark 둘 다 "Dark" 포함).
pub fn nativeThemeIsDark() bool {
    if (comptime builtin.os.tag == .windows) return win_theme.isDark();
    if (!comptime is_macos) return false;
    const NSApplication = getClass("NSApplication") orelse return false;
    const app = msgSend(NSApplication, "sharedApplication") orelse return false;
    const appearance = msgSend(app, "effectiveAppearance") orelse return false;
    const name_obj = msgSend(appearance, "name") orelse return false;
    var buf: [128]u8 = undefined;
    const name = nsStringToUtf8Buf(name_obj, &buf);
    return std.mem.indexOf(u8, name, "Dark") != null;
}

/// nativeTheme.themeSource 강제 (Electron `nativeTheme.themeSource = "light"|"dark"|"system"`).
/// system은 OS 설정 따름 (NSApp.appearance = nil), 그 외는 NSAppearance 명시.
/// 잘못된 source는 false. macOS 10.14+.
pub fn nativeThemeSetSource(source: []const u8) bool {
    if (comptime builtin.os.tag == .windows) return win_theme.setSource(source);
    if (!comptime is_macos) return false;
    const NSApplication = getClass("NSApplication") orelse return false;
    const app = msgSend(NSApplication, "sharedApplication") orelse return false;
    const setApFn: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) void =
        @ptrCast(&objc.objc_msgSend);

    if (std.mem.eql(u8, source, "system")) {
        setApFn(app, @ptrCast(objc.sel_registerName("setAppearance:")), null);
        return true;
    }
    const name_cstr: [*:0]const u8 = if (std.mem.eql(u8, source, "dark"))
        "NSAppearanceNameDarkAqua"
    else if (std.mem.eql(u8, source, "light"))
        "NSAppearanceNameAqua"
    else
        return false;
    const NSAppearance = getClass("NSAppearance") orelse return false;
    const ns_name = nsStringFromCstr(name_cstr) orelse return false;
    const namedFn: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque =
        @ptrCast(&objc.objc_msgSend);
    const appearance = namedFn(NSAppearance, @ptrCast(objc.sel_registerName("appearanceNamed:")), ns_name) orelse return false;
    setApFn(app, @ptrCast(objc.sel_registerName("setAppearance:")), appearance);
    return true;
}

/// NSWorkspace BOOL accessor 공용 — accessibilityDisplay* 접근성 플래그 계열.
/// 비-macOS 는 false(아래 호출부가 플랫폼 분기).
fn workspaceBool(sel_name: [:0]const u8) bool {
    if (!comptime is_macos) return false;
    const NSWorkspace = getClass("NSWorkspace") orelse return false;
    const ws = msgSend(NSWorkspace, "sharedWorkspace") orelse return false;
    return cef.msgSendBool(ws, sel_name);
}

/// 고대비 모드 (Electron `nativeTheme.shouldUseHighContrastColors`).
/// macOS: NSWorkspace.accessibilityDisplayShouldIncreaseContrast.
/// Windows: SystemParametersInfo(SPI_GETHIGHCONTRAST) HCF_HIGHCONTRASTON. Linux: false(미지원).
pub fn nativeThemeHighContrast() bool {
    if (comptime builtin.os.tag == .windows) return win_theme.highContrast();
    return workspaceBool("accessibilityDisplayShouldIncreaseContrast");
}

/// 투명도 감소 선호 (Electron `nativeTheme.prefersReducedTransparency`).
/// macOS 10.12+: NSWorkspace.accessibilityDisplayShouldReduceTransparency.
/// Windows: HKCU EnableTransparency==0. Linux: false(미지원).
pub fn nativeThemeReducedTransparency() bool {
    if (comptime builtin.os.tag == .windows) return win_theme.reducedTransparency();
    return workspaceBool("accessibilityDisplayShouldReduceTransparency");
}

// nativeTheme:updated callback — Windows pump WM_SETTINGCHANGE 가 호출.
pub var g_native_theme_cb_windows: ?*const fn () callconv(.c) void = null;

// nativeTheme — NSApp.effectiveAppearance KVO 옵저버 (Electron `nativeTheme.on('updated')` 동등).
extern "c" fn suji_native_theme_install(cb: *const fn () callconv(.c) void) void;
extern "c" fn suji_native_theme_uninstall() void;

pub fn nativeThemeInstall(cb: *const fn () callconv(.c) void) void {
    if (comptime builtin.os.tag == .windows) {
        g_native_theme_cb_windows = cb;
        win_pump.ensureRunning();
        return;
    }
    if (!comptime is_macos) return;
    suji_native_theme_install(cb);
}

pub fn nativeThemeUninstall() void {
    if (comptime builtin.os.tag == .windows) {
        g_native_theme_cb_windows = null;
        return;
    }
    if (!comptime is_macos) return;
    suji_native_theme_uninstall();
}
