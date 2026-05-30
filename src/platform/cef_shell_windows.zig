//! Windows backend for Electron-compatible shell APIs.

const std = @import("std");
const builtin = @import("builtin");

const impl = if (builtin.os.tag == .windows) struct {
    const SW_SHOWNORMAL: i32 = 1;
    const FO_DELETE: u32 = 0x0003;
    const FOF_ALLOWUNDO: u16 = 0x0040; // 휴지통으로 (skip = permanent delete)
    const FOF_NOCONFIRMATION: u16 = 0x0010;
    const FOF_NOERRORUI: u16 = 0x0400;
    const FOF_SILENT: u16 = 0x0004;
    const MB_OK: u32 = 0;

    const SHFILEOPSTRUCTW = extern struct {
        hwnd: ?*anyopaque = null,
        wFunc: u32 = 0,
        pFrom: ?[*:0]const u16 = null,
        pTo: ?[*:0]const u16 = null,
        fFlags: u16 = 0,
        fAnyOperationsAborted: i32 = 0,
        hNameMappings: ?*anyopaque = null,
        lpszProgressTitle: ?[*:0]const u16 = null,
    };

    extern "shell32" fn ShellExecuteW(
        hwnd: ?*anyopaque,
        lpOperation: ?[*:0]const u16,
        lpFile: [*:0]const u16,
        lpParameters: ?[*:0]const u16,
        lpDirectory: ?[*:0]const u16,
        nShowCmd: i32,
    ) callconv(.winapi) ?*anyopaque;

    extern "shell32" fn SHFileOperationW(lpFileOp: *SHFILEOPSTRUCTW) callconv(.winapi) i32;
    extern "user32" fn MessageBeep(uType: u32) callconv(.winapi) i32;
    extern "kernel32" fn GetFileAttributesW(lpFileName: [*:0]const u16) callconv(.winapi) u32;
    const INVALID_FILE_ATTRIBUTES: u32 = 0xFFFFFFFF;

    /// path 가 존재하는지 (file or dir). macOS fileExistsAtPath 동등.
    fn pathExists(path: []const u8) bool {
        if (path.len == 0) return false;
        var buf: [4096]u16 = undefined;
        const path_z = utf8ToZ16(&buf, path) orelse return false;
        return GetFileAttributesW(path_z.ptr) != INVALID_FILE_ATTRIBUTES;
    }

    /// URL 문자열 sanity 검사 — control char(\t, \n, \r, < 0x20) 포함 시 invalid.
    /// macOS NSURL.URLWithString 의 RFC-strict 동작 매칭.
    fn urlIsValid(url: []const u8) bool {
        if (url.len == 0) return false;
        for (url) |b| if (b < 0x20 or b == 0x7f) return false;
        return true;
    }

    /// utf8 → null-terminated utf16 in caller-provided buf. 빈 slice 반환 시 buf 부족/invalid.
    fn utf8ToZ16(buf: []u16, src: []const u8) ?[:0]const u16 {
        const len = std.unicode.calcUtf16LeLen(src) catch return null;
        if (len + 1 > buf.len) return null;
        const written = std.unicode.utf8ToUtf16Le(buf[0..len], src) catch return null;
        buf[written] = 0;
        return buf[0..written :0];
    }

    /// ShellExecuteW 결과: HINSTANCE > 32 = 성공, <= 32 = 에러 코드.
    fn execOpen(target: []const u8, params: ?[]const u8) bool {
        var target_buf: [4096]u16 = undefined;
        const target_z = utf8ToZ16(&target_buf, target) orelse return false;
        var params_buf: [8192]u16 = undefined;
        const params_z: ?[*:0]const u16 = if (params) |p| blk: {
            const z = utf8ToZ16(&params_buf, p) orelse return false;
            break :blk z.ptr;
        } else null;
        const op_buf = std.unicode.utf8ToUtf16LeStringLiteral("open");
        const result = ShellExecuteW(null, op_buf, target_z.ptr, params_z, null, SW_SHOWNORMAL);
        return @intFromPtr(result) > 32;
    }

    pub fn openExternal(url: []const u8) bool {
        // scheme 검사 — 매개변수 없는 URL/path 가 ShellExecute 에 전달되면 OS 가 본
        // path 추측하므로 안전을 위해 ':' 포함 (scheme 식별) + control char 차단
        // (macOS NSURL.URLWithString 의 RFC-strict 거부 매칭).
        if (!urlIsValid(url)) return false;
        if (std.mem.indexOfScalar(u8, url, ':') == null) return false;
        return execOpen(url, null);
    }

    pub fn showItemInFolder(path: []const u8) bool {
        // 사전 path 존재 검증 (macOS NSFileManager.fileExistsAtPath 동등).
        // 없는 path 를 explorer 에 넘기면 빈 새 창 열림 → 호출자에게 false 못 알림.
        if (!pathExists(path)) return false;
        // explorer.exe /select,"<path>" 가 부모 폴더 열고 해당 항목 선택.
        // Windows 파일명은 " 금지 → escape 불필요. buf 부족 시 false.
        var arg_buf: [4200]u8 = undefined;
        const arg = std.fmt.bufPrint(&arg_buf, "/select,\"{s}\"", .{path}) catch return false;
        return execOpen("explorer.exe", arg);
    }

    pub fn beep() void {
        _ = MessageBeep(MB_OK);
    }

    pub fn openPath(path: []const u8) bool {
        // ShellExecuteW 자체가 없는 path → SE_ERR_FNF (2) 반환 ≤ 32 → false.
        // 단 path 가 URL 처럼 보이면 (e.g. "..") 다른 해석 가능 — 명시적 존재 검증.
        if (!pathExists(path)) return false;
        return execOpen(path, null);
    }

    /// SHFileOperationW + FO_DELETE + FOF_ALLOWUNDO = 휴지통으로 이동.
    /// pFrom 은 **double-null-terminated** 필요 (path\0\0 — 여러 파일 list 종료자).
    pub fn trashItem(path: []const u8) bool {
        var path_buf: [4096]u16 = undefined;
        const path_z = utf8ToZ16(&path_buf, path) orelse return false;
        // 명시적 double-null: path_z 는 단일 null 까지. 다음 슬롯에 또 null.
        if (path_z.len + 2 > path_buf.len) return false;
        path_buf[path_z.len + 1] = 0;
        var op: SHFILEOPSTRUCTW = .{
            .wFunc = FO_DELETE,
            .pFrom = path_buf[0 .. path_z.len + 1 :0].ptr,
            .fFlags = FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_NOERRORUI | FOF_SILENT,
        };
        return SHFileOperationW(&op) == 0 and op.fAnyOperationsAborted == 0;
    }
} else struct {
    pub fn openExternal(_: []const u8) bool {
        return false;
    }
    pub fn showItemInFolder(_: []const u8) bool {
        return false;
    }
    pub fn beep() void {}
    pub fn openPath(_: []const u8) bool {
        return false;
    }
    pub fn trashItem(_: []const u8) bool {
        return false;
    }
};

pub const openExternal = impl.openExternal;
pub const showItemInFolder = impl.showItemInFolder;
pub const beep = impl.beep;
pub const openPath = impl.openPath;
pub const trashItem = impl.trashItem;
