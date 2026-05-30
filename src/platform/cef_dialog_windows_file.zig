//! Windows open/save dialog backend.

const std = @import("std");
const builtin = @import("builtin");
const util = @import("util");
const dialog_types = @import("cef_dialog_types.zig");
const dialog_response = @import("cef_dialog_response.zig");
const windows_folder = @import("cef_dialog_windows_folder.zig");

const OpenDialogOpts = dialog_types.OpenDialogOpts;
const SaveDialogOpts = dialog_types.SaveDialogOpts;
const FileFilter = dialog_types.FileFilter;
const writeCanceledResponse = dialog_response.writeCanceledResponse;
const writeSaveCanceledResponse = dialog_response.writeSaveCanceledResponse;
const writeSaveSuccessResponse = dialog_response.writeSaveSuccessResponse;

pub fn showOpen(opts: OpenDialogOpts, response_buf: []u8) []const u8 {
    if (comptime builtin.os.tag != .windows) return writeCanceledResponse(response_buf, true);
    return win_dlg.showOpen(opts, response_buf);
}

pub fn showSave(opts: SaveDialogOpts, response_buf: []u8) []const u8 {
    if (comptime builtin.os.tag != .windows) return writeSaveCanceledResponse(response_buf, true);
    return win_dlg.showSave(opts, response_buf);
}

// ============================================
// Win32 commdlg FFI — showOpenDialog/showSaveDialog (Windows).
// ============================================
// GetOpenFileNameW/GetSaveFileNameW (legacy commdlg) 사용. COM IFileOpenDialog
// 대비 단순 (OPENFILENAMEW struct 한 번 채우면 끝). Vista+ 의 modern dialog 도
// 자동 적용됨. multi-select 시 buffer 가 "dir\0f1\0f2\0\0" 형식.
const win_dlg = if (builtin.os.tag == .windows) struct {
    const OFN_FILEMUSTEXIST: u32 = 0x00001000;
    const OFN_PATHMUSTEXIST: u32 = 0x00000800;
    const OFN_ALLOWMULTISELECT: u32 = 0x00000200;
    const OFN_EXPLORER: u32 = 0x00080000;
    const OFN_OVERWRITEPROMPT: u32 = 0x00000002;
    const OFN_NOCHANGEDIR: u32 = 0x00000008;
    const OFN_HIDEREADONLY: u32 = 0x00000004;

    const OPENFILENAMEW = extern struct {
        lStructSize: u32 = 0,
        hwndOwner: ?*anyopaque = null,
        hInstance: ?*anyopaque = null,
        lpstrFilter: ?[*]const u16 = null,
        lpstrCustomFilter: ?[*]u16 = null,
        nMaxCustFilter: u32 = 0,
        nFilterIndex: u32 = 0,
        lpstrFile: [*]u16 = undefined,
        nMaxFile: u32 = 0,
        lpstrFileTitle: ?[*]u16 = null,
        nMaxFileTitle: u32 = 0,
        lpstrInitialDir: ?[*:0]const u16 = null,
        lpstrTitle: ?[*:0]const u16 = null,
        Flags: u32 = 0,
        nFileOffset: u16 = 0,
        nFileExtension: u16 = 0,
        lpstrDefExt: ?[*:0]const u16 = null,
        lCustData: isize = 0,
        lpfnHook: ?*anyopaque = null,
        lpTemplateName: ?[*:0]const u16 = null,
        pvReserved: ?*anyopaque = null,
        dwReserved: u32 = 0,
        FlagsEx: u32 = 0,
    };

    extern "comdlg32" fn GetOpenFileNameW(lpofn: *OPENFILENAMEW) callconv(.winapi) i32;
    extern "comdlg32" fn GetSaveFileNameW(lpofn: *OPENFILENAMEW) callconv(.winapi) i32;

    fn utf8ToZ16(buf: []u16, src: []const u8) ?[:0]const u16 {
        const len = std.unicode.calcUtf16LeLen(src) catch return null;
        if (len + 1 > buf.len) return null;
        const written = std.unicode.utf8ToUtf16Le(buf[0..len], src) catch return null;
        buf[written] = 0;
        return buf[0..written :0];
    }

    /// FileFilter[] → `"name\0*.ext;*.ext\0...\0\0"` 형식 utf-16 buffer.
    /// 필터 없으면 `"All Files\0*.*\0\0"`. buf 부족 시 fallback all-files.
    fn buildFilter(buf: []u16, filters: []const FileFilter) []u16 {
        var idx: usize = 0;
        const all_files = std.unicode.utf8ToUtf16LeStringLiteral("All Files");
        const star_pattern = std.unicode.utf8ToUtf16LeStringLiteral("*.*");

        if (filters.len == 0) {
            // "All Files\0*.*\0\0"
            const needed = all_files.len + 1 + star_pattern.len + 1 + 1;
            if (buf.len < needed) return buf[0..0];
            @memcpy(buf[0..all_files.len], all_files);
            buf[all_files.len] = 0;
            idx = all_files.len + 1;
            @memcpy(buf[idx .. idx + star_pattern.len], star_pattern);
            idx += star_pattern.len;
            buf[idx] = 0;
            idx += 1;
            buf[idx] = 0;
            return buf[0 .. idx + 1];
        }

        for (filters) |f| {
            // name + \0
            const name_len = std.unicode.calcUtf16LeLen(f.name) catch continue;
            if (idx + name_len + 1 >= buf.len) break;
            _ = std.unicode.utf8ToUtf16Le(buf[idx .. idx + name_len], f.name) catch continue;
            idx += name_len;
            buf[idx] = 0;
            idx += 1;
            // patterns: "*.ext;*.ext2"
            for (f.extensions, 0..) |ext, i| {
                if (i > 0) {
                    if (idx + 1 >= buf.len) break;
                    buf[idx] = ';';
                    idx += 1;
                }
                if (idx + 2 >= buf.len) break;
                buf[idx] = '*';
                buf[idx + 1] = '.';
                idx += 2;
                const ext_len = std.unicode.calcUtf16LeLen(ext) catch continue;
                if (idx + ext_len >= buf.len) break;
                _ = std.unicode.utf8ToUtf16Le(buf[idx .. idx + ext_len], ext) catch continue;
                idx += ext_len;
            }
            if (idx + 1 >= buf.len) break;
            buf[idx] = 0;
            idx += 1;
        }
        if (idx + 1 >= buf.len) return buf[0..0];
        buf[idx] = 0; // 최종 double-null
        return buf[0 .. idx + 1];
    }

    /// Path utf-16 → utf-8 (response JSON 빌드용). caller buf 부족 시 빈 slice.
    fn z16ToUtf8(buf: []u8, src: [*:0]const u16) []const u8 {
        const slice = std.mem.span(src);
        const n = std.unicode.utf16LeToUtf8(buf, slice) catch return buf[0..0];
        return buf[0..n];
    }

    fn showOpen(opts: OpenDialogOpts, response_buf: []u8) []const u8 {
        // 디렉토리 선택 모드 — COM IFileOpenDialog + FOS_PICKFOLDERS. GetOpenFileNameW
        // 는 디렉토리 선택 불가 (Electron `properties:["openDirectory"]` 패리티).
        if (opts.can_choose_directories and !opts.can_choose_files) {
            return windows_folder.showFolder(opts, response_buf);
        }
        // multi-select 의 경우 path list buffer 가 더 커야 함.
        var file_buf: [16384]u16 = undefined;
        file_buf[0] = 0;
        var filter_buf: [2048]u16 = undefined;
        var title_buf: [256]u16 = undefined;
        var initial_dir_buf: [1024]u16 = undefined;

        const title_z: ?[*:0]const u16 = if (opts.title.len > 0) blk: {
            const z = utf8ToZ16(&title_buf, opts.title) orelse break :blk null;
            break :blk z.ptr;
        } else null;
        const initial_dir_z: ?[*:0]const u16 = if (opts.default_path.len > 0) blk: {
            const z = utf8ToZ16(&initial_dir_buf, opts.default_path) orelse break :blk null;
            break :blk z.ptr;
        } else null;
        const filter_slice = buildFilter(&filter_buf, opts.filters);

        var ofn: OPENFILENAMEW = .{};
        ofn.lStructSize = @sizeOf(OPENFILENAMEW);
        ofn.lpstrFile = &file_buf;
        ofn.nMaxFile = @intCast(file_buf.len);
        ofn.lpstrFilter = if (filter_slice.len > 0) filter_slice.ptr else null;
        ofn.lpstrTitle = title_z;
        ofn.lpstrInitialDir = initial_dir_z;
        var flags: u32 = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_EXPLORER | OFN_NOCHANGEDIR | OFN_HIDEREADONLY;
        if (opts.allows_multiple_selection) flags |= OFN_ALLOWMULTISELECT;
        ofn.Flags = flags;

        if (GetOpenFileNameW(&ofn) == 0) return writeCanceledResponse(response_buf, true);

        // 결과 parsing: single = file_buf 가 단일 path. multi = "dir\0f1\0f2\0\0".
        var w: std.Io.Writer = .fixed(response_buf);
        w.writeAll("{\"canceled\":false,\"filePaths\":[") catch return writeCanceledResponse(response_buf, true);

        // 첫 segment 길이
        var first_len: usize = 0;
        while (first_len < file_buf.len and file_buf[first_len] != 0) : (first_len += 1) {}
        if (first_len == file_buf.len) return writeCanceledResponse(response_buf, true);

        // 두 번째 segment 가 0 이면 first 만 = single file
        const has_more = (first_len + 1 < file_buf.len) and file_buf[first_len + 1] != 0;
        if (!has_more) {
            // single path
            var path_buf: [4096]u8 = undefined;
            const p = z16ToUtf8(&path_buf, file_buf[0..first_len :0].ptr);
            var esc_buf: [8192]u8 = undefined;
            const esc_n = util.escapeJsonStrFull(p, &esc_buf) orelse 0;
            w.print("\"{s}\"", .{esc_buf[0..esc_n]}) catch {};
        } else {
            // multi: file_buf[0..first_len] = dir, then each segment 다음 file name.
            // dir/name 둘 다 4096-byte UTF-8 까지 수용 — Windows long-path 와 한자/이모지
            // 혼합 시도 안전. z16ToUtf8 는 overflow 시 truncate-and-return-empty 동작이고
            // 그 경우 bufPrint catch 가 segment 를 skip.
            var dir_buf: [4096]u8 = undefined;
            const dir = z16ToUtf8(&dir_buf, file_buf[0..first_len :0].ptr);
            var cursor: usize = first_len + 1;
            var first = true;
            while (cursor < file_buf.len and file_buf[cursor] != 0) {
                var seg_end = cursor;
                while (seg_end < file_buf.len and file_buf[seg_end] != 0) : (seg_end += 1) {}
                var name_buf: [4096]u8 = undefined;
                const name = z16ToUtf8(&name_buf, file_buf[cursor..seg_end :0].ptr);
                if (!first) w.writeByte(',') catch break;
                first = false;
                var path_buf: [8208]u8 = undefined; // dir(4096) + '\\' + name(4096) + slack
                const full = std.fmt.bufPrint(&path_buf, "{s}\\{s}", .{ dir, name }) catch break;
                var esc_buf: [16416]u8 = undefined; // worst-case JSON escape ~2x
                const esc_n = util.escapeJsonStrFull(full, &esc_buf) orelse 0;
                w.print("\"{s}\"", .{esc_buf[0..esc_n]}) catch {};
                cursor = seg_end + 1;
            }
        }
        w.writeAll("]}") catch {};
        return w.buffered();
    }

    fn showSave(opts: SaveDialogOpts, response_buf: []u8) []const u8 {
        var file_buf: [4096]u16 = undefined;
        file_buf[0] = 0;
        var filter_buf: [2048]u16 = undefined;
        var title_buf: [256]u16 = undefined;
        // default_path 가 디렉토리+파일명 분리 가능 — 단순화: full path 가 file_buf 초기값.
        if (opts.default_path.len > 0) {
            _ = utf8ToZ16(&file_buf, opts.default_path);
        }
        const title_z: ?[*:0]const u16 = if (opts.title.len > 0) blk: {
            const z = utf8ToZ16(&title_buf, opts.title) orelse break :blk null;
            break :blk z.ptr;
        } else null;
        const filter_slice = buildFilter(&filter_buf, opts.filters);

        var ofn: OPENFILENAMEW = .{};
        ofn.lStructSize = @sizeOf(OPENFILENAMEW);
        ofn.lpstrFile = &file_buf;
        ofn.nMaxFile = @intCast(file_buf.len);
        ofn.lpstrFilter = if (filter_slice.len > 0) filter_slice.ptr else null;
        ofn.lpstrTitle = title_z;
        var flags: u32 = OFN_EXPLORER | OFN_NOCHANGEDIR | OFN_HIDEREADONLY;
        if (opts.show_overwrite_confirmation) flags |= OFN_OVERWRITEPROMPT;
        ofn.Flags = flags;

        if (GetSaveFileNameW(&ofn) == 0) return writeSaveCanceledResponse(response_buf, true);

        var path_buf: [4096]u8 = undefined;
        const path = z16ToUtf8(&path_buf, @ptrCast(&file_buf));
        return writeSaveSuccessResponse(response_buf, path);
    }
} else struct {};
