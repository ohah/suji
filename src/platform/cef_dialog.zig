//! Dialog API — cef.zig 에서 분리(동작 무변경). NSAlert/NSOpenPanel/NSSavePanel(macOS),
//! GTK3(Linux), TaskDialog/commdlg/IFileOpenDialog(Windows). main.zig 의 __core__
//! 디스패치는 cef.dialog* 타입/API 를 호출하며, cef.zig 가 이 파일의 pub decl 을 re-export 한다.
const std = @import("std");
const builtin = @import("builtin");
const util = @import("util");
const cef = @import("cef.zig");
const dialog_types = @import("cef_dialog_types.zig");
const dialog_response = @import("cef_dialog_response.zig");
const cef_dialog_linux = @import("cef_dialog_linux.zig");
const cef_dialog_windows_message = @import("cef_dialog_windows_message.zig");
const cef_dialog_windows_file = @import("cef_dialog_windows_file.zig");

const is_macos = builtin.os.tag == .macos;
const is_linux = builtin.os.tag == .linux;

const objc = cef.objc;
const getClass = cef.getClass;
const msgSend = cef.msgSend;
const msgSendVoid1 = cef.msgSendVoid1;
const msgSendVoidBool = cef.msgSendVoidBool;
const nsStringFromSlice = cef.nsStringFromSlice;
const writeCanceledResponse = dialog_response.writeCanceledResponse;
const writeSaveCanceledResponse = dialog_response.writeSaveCanceledResponse;
const writeSaveSuccessResponse = dialog_response.writeSaveSuccessResponse;

// dialog.m C 함수 (sheet path). nested run loop로 동기화.
extern "c" fn suji_run_sheet_alert(parent_window: ?*anyopaque, alert: ?*anyopaque) i64;
extern "c" fn suji_run_sheet_save_panel(parent_window: ?*anyopaque, panel: ?*anyopaque) i64;

pub const MAX_DIALOG_BUTTONS = dialog_types.MAX_DIALOG_BUTTONS;
pub const MAX_DIALOG_PATHS = dialog_types.MAX_DIALOG_PATHS;
pub const MessageBoxStyle = dialog_types.MessageBoxStyle;
pub const MessageBoxOpts = dialog_types.MessageBoxOpts;
pub const MessageBoxResult = dialog_types.MessageBoxResult;
pub const FileFilter = dialog_types.FileFilter;
pub const OpenDialogOpts = dialog_types.OpenDialogOpts;
pub const SaveDialogOpts = dialog_types.SaveDialogOpts;

/// NSAlert 메시지 박스. macOS HIG 기본: 첫 버튼 = default(Enter), 마지막 버튼 = Cancel(ESC).
/// `default_id`/`cancel_id`로 명시적 변경.
pub fn showMessageBox(opts: MessageBoxOpts) MessageBoxResult {
    if (comptime builtin.os.tag == .windows) return cef_dialog_windows_message.messageBox(opts);
    if (comptime is_linux) return cef_dialog_linux.showMessageBox(opts);
    if (!comptime is_macos) return .{};
    const NSAlert = getClass("NSAlert") orelse return .{};
    const alloc = msgSend(NSAlert, "alloc") orelse return .{};
    const alert = msgSend(alloc, "init") orelse return .{};

    if (opts.message.len > 0) {
        if (nsStringFromSlice(opts.message)) |ns| msgSendVoid1(alert, "setMessageText:", ns);
    }
    if (opts.detail.len > 0) {
        if (nsStringFromSlice(opts.detail)) |ns| msgSendVoid1(alert, "setInformativeText:", ns);
    }

    // NSAlertStyle: warning=0, info=1, critical=2. question/none → warning(0).
    const style: u64 = switch (opts.style) {
        .info => 1,
        .err => 2,
        .none, .warning, .question => 0,
    };
    const setStyleFn: *const fn (?*anyopaque, ?*anyopaque, u64) callconv(.c) void =
        @ptrCast(&objc.objc_msgSend);
    setStyleFn(alert, @ptrCast(objc.sel_registerName("setAlertStyle:")), style);

    if (opts.title.len > 0) {
        if (msgSend(alert, "window")) |win| {
            if (nsStringFromSlice(opts.title)) |ns| msgSendVoid1(win, "setTitle:", ns);
        }
    }

    // 버튼 추가 — 빈 배열이면 기본 "OK".
    var added_buttons: [MAX_DIALOG_BUTTONS]?*anyopaque = [_]?*anyopaque{null} ** MAX_DIALOG_BUTTONS;
    const button_titles: []const []const u8 = if (opts.buttons.len > 0) opts.buttons else &.{"OK"};
    const button_count: usize = @min(button_titles.len, MAX_DIALOG_BUTTONS);
    const addBtnFn: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque =
        @ptrCast(&objc.objc_msgSend);
    for (button_titles[0..button_count], 0..) |btn_title, i| {
        const ns = nsStringFromSlice(btn_title) orelse continue;
        added_buttons[i] = addBtnFn(alert, @ptrCast(objc.sel_registerName("addButtonWithTitle:")), ns);
    }

    // default_id 지정 — NSAlert는 기본적으로 첫 버튼이 default (Enter). 다른 index를
    // default로 만들려면 첫 버튼의 keyEquivalent를 지우고 대상에 "\r" 설정.
    if (opts.default_id) |def_idx| {
        if (def_idx < button_count) {
            if (def_idx != 0) {
                if (added_buttons[0]) |b0| {
                    if (nsStringFromSlice("")) |empty| msgSendVoid1(b0, "setKeyEquivalent:", empty);
                }
            }
            if (added_buttons[def_idx]) |btn| {
                if (nsStringFromSlice("\r")) |ret| msgSendVoid1(btn, "setKeyEquivalent:", ret);
            }
        }
    }
    // cancel_id 지정 — ESC 매핑.
    if (opts.cancel_id) |can_idx| {
        if (can_idx < button_count) {
            if (added_buttons[can_idx]) |btn| {
                if (nsStringFromSlice("\x1b")) |esc| msgSendVoid1(btn, "setKeyEquivalent:", esc);
            }
        }
    }

    // Suppression button (체크박스) — checkbox_label 있을 때만.
    if (opts.checkbox_label.len > 0) {
        msgSendVoidBool(alert, "setShowsSuppressionButton:", true);
        if (msgSend(alert, "suppressionButton")) |sb| {
            if (nsStringFromSlice(opts.checkbox_label)) |ns| msgSendVoid1(sb, "setTitle:", ns);
            const setStateFn: *const fn (?*anyopaque, ?*anyopaque, i64) callconv(.c) void =
                @ptrCast(&objc.objc_msgSend);
            setStateFn(sb, @ptrCast(objc.sel_registerName("setState:")), if (opts.checkbox_checked) 1 else 0);
        }
    }

    // parent_window 지정 → sheet path (.m). 없으면 free-floating runModal.
    const ns_response: i64 = if (opts.parent_window) |parent|
        suji_run_sheet_alert(parent, alert)
    else blk: {
        const runModalFn: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) i64 =
            @ptrCast(&objc.objc_msgSend);
        break :blk runModalFn(alert, @ptrCast(objc.sel_registerName("runModal")));
    };
    // NSAlertFirstButtonReturn = 1000.
    const NS_ALERT_FIRST_BTN: i64 = 1000;
    const idx_signed: i64 = ns_response - NS_ALERT_FIRST_BTN;
    const response_idx: usize = if (idx_signed < 0 or idx_signed >= @as(i64, @intCast(button_count)))
        0
    else
        @intCast(idx_signed);

    var checkbox_state: bool = opts.checkbox_checked;
    if (opts.checkbox_label.len > 0) {
        if (msgSend(alert, "suppressionButton")) |sb| {
            const stateFn: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) i64 =
                @ptrCast(&objc.objc_msgSend);
            const state = stateFn(sb, @ptrCast(objc.sel_registerName("state")));
            checkbox_state = (state != 0);
        }
    }

    return .{ .response = response_idx, .checkbox_checked = checkbox_state };
}

/// 단순 에러 popup — NSAlert critical style + 단일 OK 버튼 (Electron `dialog.showErrorBox`).
pub fn showErrorBox(title: []const u8, content: []const u8) void {
    if (comptime builtin.os.tag == .windows) {
        cef_dialog_windows_message.errorBox(title, content);
        return;
    }
    if (comptime is_linux) {
        cef_dialog_linux.showErrorBox(title, content);
        return;
    }
    if (!comptime is_macos) return;
    _ = showMessageBox(.{
        .style = .err,
        .title = title,
        .message = content,
        .buttons = &.{"OK"},
    });
}

pub fn showOpenDialog(opts: OpenDialogOpts, response_buf: []u8) []const u8 {
    if (comptime builtin.os.tag == .windows) return cef_dialog_windows_file.showOpen(opts, response_buf);
    if (comptime is_linux) return cef_dialog_linux.showOpen(opts, response_buf);
    if (!comptime is_macos) return writeCanceledResponse(response_buf, true);
    const NSOpenPanel = getClass("NSOpenPanel") orelse return writeCanceledResponse(response_buf, true);
    const panel = msgSend(NSOpenPanel, "openPanel") orelse return writeCanceledResponse(response_buf, true);

    applySavePanelCommon(panel, .{
        .title = opts.title,
        .default_path = opts.default_path,
        .button_label = opts.button_label,
        .message = opts.message,
        .shows_hidden_files = opts.shows_hidden_files,
        .can_create_directories = opts.can_create_directories,
        .filters = opts.filters,
    });

    msgSendVoidBool(panel, "setCanChooseFiles:", opts.can_choose_files);
    msgSendVoidBool(panel, "setCanChooseDirectories:", opts.can_choose_directories);
    msgSendVoidBool(panel, "setAllowsMultipleSelection:", opts.allows_multiple_selection);
    msgSendVoidBool(panel, "setResolvesAliases:", !opts.no_resolve_aliases);
    msgSendVoidBool(panel, "setTreatsFilePackagesAsDirectories:", opts.treat_packages_as_dirs);

    const result: i64 = if (opts.parent_window) |parent|
        suji_run_sheet_save_panel(parent, panel)
    else blk: {
        const runModalFn: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) i64 =
            @ptrCast(&objc.objc_msgSend);
        break :blk runModalFn(panel, @ptrCast(objc.sel_registerName("runModal")));
    };
    // NSModalResponseOK = 1, NSModalResponseCancel = 0.
    if (result != 1) return writeCanceledResponse(response_buf, true);

    const urls = msgSend(panel, "URLs") orelse return writeCanceledResponse(response_buf, true);
    return writeOpenResponse(response_buf, urls);
}

/// NSSavePanel — 저장 경로 선택.
/// 형식: `{"canceled":bool,"filePath":"/path/file.ext"}`.
pub fn showSaveDialog(opts: SaveDialogOpts, response_buf: []u8) []const u8 {
    if (comptime builtin.os.tag == .windows) return cef_dialog_windows_file.showSave(opts, response_buf);
    if (comptime is_linux) return cef_dialog_linux.showSave(opts, response_buf);
    if (!comptime is_macos) return writeSaveCanceledResponse(response_buf, true);
    const NSSavePanel = getClass("NSSavePanel") orelse return writeSaveCanceledResponse(response_buf, true);
    const panel = msgSend(NSSavePanel, "savePanel") orelse return writeSaveCanceledResponse(response_buf, true);

    applySavePanelCommon(panel, .{
        .title = opts.title,
        .default_path = opts.default_path,
        .button_label = opts.button_label,
        .message = opts.message,
        .shows_hidden_files = opts.shows_hidden_files,
        .can_create_directories = opts.can_create_directories,
        .filters = opts.filters,
    });

    if (opts.name_field_label.len > 0) {
        if (nsStringFromSlice(opts.name_field_label)) |ns| msgSendVoid1(panel, "setNameFieldLabel:", ns);
    }
    msgSendVoidBool(panel, "setShowsTagField:", opts.shows_tag_field);
    // overwrite confirmation은 NSSavePanel 기본 ON (allowsOtherFileTypes와 별도). API 노출 없어서
    // 옵션 무시 — 기본 동작 유지.

    const result: i64 = if (opts.parent_window) |parent|
        suji_run_sheet_save_panel(parent, panel)
    else blk: {
        const runModalFn: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) i64 =
            @ptrCast(&objc.objc_msgSend);
        break :blk runModalFn(panel, @ptrCast(objc.sel_registerName("runModal")));
    };
    if (result != 1) return writeSaveCanceledResponse(response_buf, true);

    const url = msgSend(panel, "URL") orelse return writeSaveCanceledResponse(response_buf, true);
    var path_buf: [4096]u8 = undefined;
    const path = nsUrlToPath(url, &path_buf);
    return writeSaveSuccessResponse(response_buf, path);
}

const SavePanelCommonOpts = struct {
    title: []const u8,
    default_path: []const u8,
    button_label: []const u8,
    message: []const u8,
    shows_hidden_files: bool,
    can_create_directories: bool,
    filters: []const FileFilter,
};

/// NSSavePanel 계열(Open/Save) 공통 옵션 적용. setDirectoryURL/setNameFieldStringValue는
/// default_path가 디렉토리/파일에 따라 동작이 다름 — 슬래시로 끝나거나 기존 디렉토리면
/// directoryURL, 아니면 (디렉토리, 파일명) 분리.
fn applySavePanelCommon(panel: *anyopaque, opts: SavePanelCommonOpts) void {
    if (opts.title.len > 0) {
        if (nsStringFromSlice(opts.title)) |ns| msgSendVoid1(panel, "setTitle:", ns);
    }
    if (opts.message.len > 0) {
        if (nsStringFromSlice(opts.message)) |ns| msgSendVoid1(panel, "setMessage:", ns);
    }
    if (opts.button_label.len > 0) {
        if (nsStringFromSlice(opts.button_label)) |ns| msgSendVoid1(panel, "setPrompt:", ns);
    }
    msgSendVoidBool(panel, "setShowsHiddenFiles:", opts.shows_hidden_files);
    msgSendVoidBool(panel, "setCanCreateDirectories:", opts.can_create_directories);

    if (opts.default_path.len > 0) applyDefaultPath(panel, opts.default_path);
    if (opts.filters.len > 0) applyFileFilters(panel, opts.filters);
}

fn applyDefaultPath(panel: *anyopaque, default_path: []const u8) void {
    // path 끝이 '/'면 directory만, 아니면 마지막 segment를 파일명으로 분리.
    const ends_with_slash = default_path.len > 0 and default_path[default_path.len - 1] == '/';
    if (ends_with_slash) {
        setDirectoryURLFromPath(panel, default_path[0 .. default_path.len - 1]);
        return;
    }
    if (std.mem.lastIndexOfScalar(u8, default_path, '/')) |slash_idx| {
        const dir = default_path[0..slash_idx];
        const name = default_path[slash_idx + 1 ..];
        if (dir.len > 0) setDirectoryURLFromPath(panel, dir);
        if (name.len > 0) {
            if (nsStringFromSlice(name)) |ns| msgSendVoid1(panel, "setNameFieldStringValue:", ns);
        }
    } else {
        // 슬래시 없음 — 그냥 파일명으로 취급.
        if (nsStringFromSlice(default_path)) |ns| msgSendVoid1(panel, "setNameFieldStringValue:", ns);
    }
}

fn setDirectoryURLFromPath(panel: *anyopaque, dir_path: []const u8) void {
    const ns_dir = nsStringFromSlice(dir_path) orelse return;
    const NSURL = getClass("NSURL") orelse return;
    const fileUrlFn: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque =
        @ptrCast(&objc.objc_msgSend);
    const url = fileUrlFn(NSURL, @ptrCast(objc.sel_registerName("fileURLWithPath:")), ns_dir) orelse return;
    msgSendVoid1(panel, "setDirectoryURL:", url);
}

fn applyFileFilters(panel: *anyopaque, filters: []const FileFilter) void {
    // setAllowedFileTypes:는 macOS 12에서 deprecated이지만 여전히 동작 — UTType 기반 신규 API
    // (setAllowedContentTypes:)는 추후 작업. 모든 필터의 extension을 평탄화해 단일 NSArray로 전달.
    const NSMutableArray = getClass("NSMutableArray") orelse return;
    const arr = msgSend(NSMutableArray, "array") orelse return;
    const addObjFn: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) void =
        @ptrCast(&objc.objc_msgSend);
    var added: usize = 0;
    for (filters) |f| {
        for (f.extensions) |ext| {
            // "*" 또는 빈 문자열은 무시 — 모든 파일 허용 의미라 setAllowedFileTypes 자체를 안 부름이 맞음.
            if (ext.len == 0 or std.mem.eql(u8, ext, "*")) continue;
            if (nsStringFromSlice(ext)) |ns| {
                addObjFn(arr, @ptrCast(objc.sel_registerName("addObject:")), ns);
                added += 1;
            }
        }
    }
    if (added > 0) msgSendVoid1(panel, "setAllowedFileTypes:", arr);
}

fn nsUrlToPath(ns_url: *anyopaque, buf: []u8) []const u8 {
    const path_ns = msgSend(ns_url, "path") orelse return buf[0..0];
    const utf8Fn: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) ?[*:0]const u8 =
        @ptrCast(&objc.objc_msgSend);
    const cstr = utf8Fn(path_ns, @ptrCast(objc.sel_registerName("UTF8String"))) orelse return buf[0..0];
    const len = std.mem.span(cstr).len;
    const copy_len = @min(len, buf.len);
    @memcpy(buf[0..copy_len], cstr[0..copy_len]);
    return buf[0..copy_len];
}

/// NSArray<NSURL *> → JSON paths array. 응답 버퍼 부족하면 한도까지만.
fn writeOpenResponse(buf: []u8, urls: *anyopaque) []const u8 {
    const countFn: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) usize =
        @ptrCast(&objc.objc_msgSend);
    const count = countFn(urls, @ptrCast(objc.sel_registerName("count")));

    var w: usize = 0;
    const header = std.fmt.bufPrint(buf[w..], "{{\"canceled\":false,\"filePaths\":[", .{}) catch return writeCanceledResponse(buf, true);
    w += header.len;

    const objAtFn: *const fn (?*anyopaque, ?*anyopaque, usize) callconv(.c) ?*anyopaque =
        @ptrCast(&objc.objc_msgSend);
    var path_buf: [4096]u8 = undefined;
    var esc_buf: [4096]u8 = undefined;
    var written_count: usize = 0;
    const max_paths = @min(count, MAX_DIALOG_PATHS);
    var i: usize = 0;
    while (i < max_paths) : (i += 1) {
        const url = objAtFn(urls, @ptrCast(objc.sel_registerName("objectAtIndex:")), i) orelse continue;
        const path = nsUrlToPath(url, &path_buf);
        const esc_len = util.escapeJsonStrFull(path, &esc_buf) orelse continue;

        const sep: []const u8 = if (written_count == 0) "\"" else ",\"";
        const part = std.fmt.bufPrint(buf[w..], "{s}{s}\"", .{ sep, esc_buf[0..esc_len] }) catch break;
        w += part.len;
        written_count += 1;
    }

    const tail = std.fmt.bufPrint(buf[w..], "]}}", .{}) catch return writeCanceledResponse(buf, true);
    w += tail.len;
    return buf[0..w];
}
