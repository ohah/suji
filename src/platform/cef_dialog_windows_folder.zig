//! Windows folder picker backend for showOpenDialog(openDirectory).

const std = @import("std");
const builtin = @import("builtin");
const util = @import("util");
const dialog_types = @import("cef_dialog_types.zig");
const dialog_response = @import("cef_dialog_response.zig");

const OpenDialogOpts = dialog_types.OpenDialogOpts;
const writeCanceledResponse = dialog_response.writeCanceledResponse;

pub fn showFolder(opts: OpenDialogOpts, response_buf: []u8) []const u8 {
    if (comptime builtin.os.tag != .windows) return writeCanceledResponse(response_buf, true);
    return folder_dlg.showFolder(opts, response_buf);
}

// ============================================
// COM IFileOpenDialog — 디렉토리 선택 (FOS_PICKFOLDERS). GetOpenFileNameW
// 가 디렉토리 선택 불가능해서 별도 COM 경로. CoInitializeEx + CoCreateInstance
// + vtable indirection — Zig 에서는 extern struct VTable 로 매핑한다.
// ============================================
const folder_dlg = if (builtin.os.tag == .windows) struct {
    const GUID = extern struct { a: u32, b: u16, c: u16, d: [8]u8 };

    const CLSID_FileOpenDialog = GUID{
        .a = 0xDC1C5A9C,
        .b = 0xE88A,
        .c = 0x4DDE,
        .d = .{ 0xA5, 0xA1, 0x60, 0xF8, 0x2A, 0x20, 0xAE, 0xF7 },
    };
    const IID_IFileOpenDialog = GUID{
        .a = 0xD57C7288,
        .b = 0xD4AD,
        .c = 0x4768,
        .d = .{ 0xBE, 0x02, 0x9D, 0x96, 0x95, 0x32, 0xD9, 0x60 },
    };

    const COINIT_APARTMENTTHREADED: u32 = 0x2;
    const CLSCTX_INPROC_SERVER: u32 = 0x1;
    const S_OK: i32 = 0;
    const FOS_PICKFOLDERS: u32 = 0x20;
    const FOS_NOCHANGEDIR: u32 = 0x8;
    const FOS_PATHMUSTEXIST: u32 = 0x800;
    const FOS_FORCEFILESYSTEM: u32 = 0x40;
    const SIGDN_FILESYSPATH: u32 = @bitCast(@as(u32, 0x80058000));

    extern "ole32" fn CoInitializeEx(pvReserved: ?*anyopaque, dwCoInit: u32) callconv(.winapi) i32;
    extern "ole32" fn CoUninitialize() callconv(.winapi) void;
    extern "ole32" fn CoCreateInstance(rclsid: *const GUID, pUnkOuter: ?*anyopaque, dwClsContext: u32, riid: *const GUID, ppv: *?*anyopaque) callconv(.winapi) i32;
    extern "ole32" fn CoTaskMemFree(pv: ?*anyopaque) callconv(.winapi) void;

    const IFileOpenDialogVtbl = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (self: *anyopaque) callconv(.winapi) u32,
        // IModalWindow
        Show: *const fn (self: *anyopaque, hwndOwner: ?*anyopaque) callconv(.winapi) i32,
        // IFileDialog
        SetFileTypes: *const anyopaque,
        SetFileTypeIndex: *const anyopaque,
        GetFileTypeIndex: *const anyopaque,
        Advise: *const anyopaque,
        Unadvise: *const anyopaque,
        SetOptions: *const fn (self: *anyopaque, fos: u32) callconv(.winapi) i32,
        GetOptions: *const fn (self: *anyopaque, pfos: *u32) callconv(.winapi) i32,
        SetDefaultFolder: *const anyopaque,
        SetFolder: *const anyopaque,
        GetFolder: *const anyopaque,
        GetCurrentSelection: *const anyopaque,
        SetFileName: *const anyopaque,
        GetFileName: *const anyopaque,
        SetTitle: *const fn (self: *anyopaque, pszTitle: [*:0]const u16) callconv(.winapi) i32,
        SetOkButtonLabel: *const anyopaque,
        SetFileNameLabel: *const anyopaque,
        GetResult: *const fn (self: *anyopaque, ppsi: *?*anyopaque) callconv(.winapi) i32,
        AddPlace: *const anyopaque,
        SetDefaultExtension: *const anyopaque,
        Close: *const anyopaque,
        SetClientGuid: *const anyopaque,
        ClearClientData: *const anyopaque,
        SetFilter: *const anyopaque,
        // IFileOpenDialog
        GetResults: *const anyopaque,
        GetSelectedItems: *const anyopaque,
    };

    const IShellItemVtbl = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (self: *anyopaque) callconv(.winapi) u32,
        BindToHandler: *const anyopaque,
        GetParent: *const anyopaque,
        GetDisplayName: *const fn (self: *anyopaque, sigdnName: u32, ppszName: *?[*:0]u16) callconv(.winapi) i32,
        GetAttributes: *const anyopaque,
        Compare: *const anyopaque,
    };

    const ComObj = extern struct { vtable: *const anyopaque };

    fn showFolder(opts: OpenDialogOpts, response_buf: []u8) []const u8 {
        const hr_init = CoInitializeEx(null, COINIT_APARTMENTTHREADED);
        const need_uninit = (hr_init == S_OK) or (hr_init == 1); // S_OK 또는 S_FALSE(이미 init)
        defer if (need_uninit) CoUninitialize();

        var dialog_raw: ?*anyopaque = null;
        if (CoCreateInstance(&CLSID_FileOpenDialog, null, CLSCTX_INPROC_SERVER, &IID_IFileOpenDialog, &dialog_raw) != S_OK or dialog_raw == null) {
            return writeCanceledResponse(response_buf, true);
        }
        const dialog = dialog_raw.?;
        const dialog_obj: *ComObj = @ptrCast(@alignCast(dialog));
        const dialog_vt: *const IFileOpenDialogVtbl = @ptrCast(@alignCast(dialog_obj.vtable));
        defer _ = dialog_vt.Release(dialog);

        var current_opts: u32 = 0;
        _ = dialog_vt.GetOptions(dialog, &current_opts);
        const new_opts = current_opts | FOS_PICKFOLDERS | FOS_NOCHANGEDIR | FOS_PATHMUSTEXIST | FOS_FORCEFILESYSTEM;
        _ = dialog_vt.SetOptions(dialog, new_opts);

        if (opts.title.len > 0) {
            var title_buf: [256]u16 = undefined;
            if (utf8ToZ16(&title_buf, opts.title)) |title_z| {
                _ = dialog_vt.SetTitle(dialog, title_z.ptr);
            }
        }

        if (dialog_vt.Show(dialog, null) != S_OK) {
            return writeCanceledResponse(response_buf, true);
        }

        var item_raw: ?*anyopaque = null;
        if (dialog_vt.GetResult(dialog, &item_raw) != S_OK or item_raw == null) {
            return writeCanceledResponse(response_buf, true);
        }
        const item = item_raw.?;
        const item_obj: *ComObj = @ptrCast(@alignCast(item));
        const item_vt: *const IShellItemVtbl = @ptrCast(@alignCast(item_obj.vtable));
        defer _ = item_vt.Release(item);

        var path_w: ?[*:0]u16 = null;
        if (item_vt.GetDisplayName(item, SIGDN_FILESYSPATH, &path_w) != S_OK or path_w == null) {
            return writeCanceledResponse(response_buf, true);
        }
        defer CoTaskMemFree(@ptrCast(path_w));

        var path_utf8_buf: [4096]u8 = undefined;
        const slice = std.mem.span(path_w.?);
        const path_len = std.unicode.utf16LeToUtf8(&path_utf8_buf, slice) catch return writeCanceledResponse(response_buf, true);
        const path = path_utf8_buf[0..path_len];

        var w: std.Io.Writer = .fixed(response_buf);
        w.writeAll("{\"canceled\":false,\"filePaths\":[\"") catch return writeCanceledResponse(response_buf, true);
        var esc_buf: [8192]u8 = undefined;
        const esc_n = util.escapeJsonStrFull(path, &esc_buf) orelse 0;
        w.print("{s}", .{esc_buf[0..esc_n]}) catch return writeCanceledResponse(response_buf, true);
        w.writeAll("\"]}") catch return writeCanceledResponse(response_buf, true);
        return w.buffered();
    }

    /// utf-8 → null-terminated utf-16 (caller-supplied buffer).
    fn utf8ToZ16(buf: []u16, src: []const u8) ?[:0]const u16 {
        const len = std.unicode.calcUtf16LeLen(src) catch return null;
        if (len + 1 > buf.len) return null;
        const written = std.unicode.utf8ToUtf16Le(buf[0..len], src) catch return null;
        buf[written] = 0;
        return buf[0..written :0];
    }
} else struct {};
