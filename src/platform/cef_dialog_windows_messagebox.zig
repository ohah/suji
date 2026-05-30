//! Windows MessageBoxW backend for standard message dialogs.

const std = @import("std");
const builtin = @import("builtin");
const dialog_types = @import("cef_dialog_types.zig");

const MessageBoxOpts = dialog_types.MessageBoxOpts;
const MessageBoxResult = dialog_types.MessageBoxResult;

pub fn messageBox(opts: MessageBoxOpts) MessageBoxResult {
    if (comptime builtin.os.tag != .windows) return .{};
    return msgbox.messageBox(opts);
}

pub fn messageBoxFallback(opts: MessageBoxOpts) MessageBoxResult {
    if (comptime builtin.os.tag != .windows) return .{};
    return msgbox.messageBoxFallback(opts);
}

pub fn errorBox(title: []const u8, content: []const u8) void {
    if (comptime builtin.os.tag != .windows) return;
    msgbox.errorBox(title, content);
}

pub fn hasCustomButtonLabels(buttons: []const []const u8) bool {
    if (comptime builtin.os.tag != .windows) return false;
    return msgbox.hasCustomButtonLabels(buttons);
}

pub fn utf8ToZ16(buf: []u16, src: []const u8) ?[:0]const u16 {
    if (comptime builtin.os.tag != .windows) return null;
    return msgbox.utf8ToZ16Impl(buf, src);
}

const msgbox = if (builtin.os.tag == .windows) struct {
    extern "user32" fn MessageBoxW(hwnd: ?*anyopaque, lpText: [*:0]const u16, lpCaption: ?[*:0]const u16, uType: u32) callconv(.winapi) i32;

    const MB_OK: u32 = 0;
    const MB_OKCANCEL: u32 = 1;
    const MB_YESNO: u32 = 4;
    const MB_YESNOCANCEL: u32 = 3;
    const MB_ICONERROR: u32 = 0x10;
    const MB_ICONQUESTION: u32 = 0x20;
    const MB_ICONWARNING: u32 = 0x30;
    const MB_ICONINFORMATION: u32 = 0x40;
    const IDOK: i32 = 1;
    const IDCANCEL: i32 = 2;
    const IDYES: i32 = 6;
    const IDNO: i32 = 7;

    /// utf8 → null-terminated utf16. buf 부족 시 null.
    fn utf8ToZ16Impl(buf: []u16, src: []const u8) ?[:0]const u16 {
        const len = std.unicode.calcUtf16LeLen(src) catch return null;
        if (len + 1 > buf.len) return null;
        const written = std.unicode.utf8ToUtf16Le(buf[0..len], src) catch return null;
        buf[written] = 0;
        return buf[0..written :0];
    }

    /// 표준 버튼 세트(OK/Cancel/Yes/No 조합) 전용 MessageBoxW 경로.
    /// 빈 buttons → MB_OK.
    fn messageBox(opts: MessageBoxOpts) MessageBoxResult {
        var text_buf: [4096]u16 = undefined;
        const caption_max: usize = 511;
        var caption_w_buf: [512]u16 = undefined;

        // message + detail 조합. detail 비어있으면 message 만.
        var combined_buf: [4096]u8 = undefined;
        const text_utf8 = if (opts.detail.len > 0) blk: {
            const combined = std.fmt.bufPrint(&combined_buf, "{s}\n\n{s}", .{ opts.message, opts.detail }) catch opts.message;
            break :blk combined;
        } else opts.message;
        const text_z = utf8ToZ16Impl(&text_buf, text_utf8) orelse return .{};

        const caption_z: ?[*:0]const u16 = if (opts.title.len > 0) blk: {
            const caption_src = if (opts.title.len > caption_max) opts.title[0..caption_max] else opts.title;
            const z = utf8ToZ16Impl(&caption_w_buf, caption_src) orelse break :blk null;
            break :blk z.ptr;
        } else null;

        const icon: u32 = switch (opts.style) {
            .info => MB_ICONINFORMATION,
            .err => MB_ICONERROR,
            .warning => MB_ICONWARNING,
            .question => MB_ICONQUESTION,
            .none => 0,
        };
        // button 매핑 — n=0/1 → OK, 2 → OK/Cancel 또는 Yes/No, 3 → YesNoCancel.
        const button_type: u32 = switch (opts.buttons.len) {
            0, 1 => MB_OK,
            2 => if (isYesNoButtons(opts.buttons)) MB_YESNO else MB_OKCANCEL,
            else => MB_YESNOCANCEL,
        };
        const response_id = MessageBoxW(null, text_z.ptr, caption_z, icon | button_type);

        // response id → button index 매핑. 사용자 정의 buttons 순서에 맞춰 매핑 시도.
        const response_idx: usize = switch (response_id) {
            IDOK => 0,
            IDYES => 0,
            IDNO => 1,
            IDCANCEL => if (opts.buttons.len >= 3) 2 else 1,
            else => 0,
        };
        return .{ .response = response_idx, .checkbox_checked = opts.checkbox_checked };
    }

    fn isYesNoButtons(buttons: []const []const u8) bool {
        if (buttons.len != 2) return false;
        const b0_yes = std.ascii.eqlIgnoreCase(buttons[0], "yes") or std.ascii.eqlIgnoreCase(buttons[0], "ok");
        const b1_no = std.ascii.eqlIgnoreCase(buttons[1], "no") or std.ascii.eqlIgnoreCase(buttons[1], "cancel");
        // "Yes"/"No" 명시 또는 "OK"/"Cancel" 도 같은 매핑.
        return b0_yes and b1_no;
    }

    /// 표준이 아닌 라벨이 하나라도 있으면 TaskDialog 경로 사용.
    /// 표준 = "ok"|"cancel"|"yes"|"no" (case-insensitive). 0/1 개는 OK 만 표시되므로
    /// 항상 MessageBoxW 로 충분 → 표준 처리.
    fn hasCustomButtonLabels(buttons: []const []const u8) bool {
        if (buttons.len < 2) return false;
        for (buttons) |b| {
            const is_std = std.ascii.eqlIgnoreCase(b, "ok") or
                std.ascii.eqlIgnoreCase(b, "cancel") or
                std.ascii.eqlIgnoreCase(b, "yes") or
                std.ascii.eqlIgnoreCase(b, "no");
            if (!is_std) return true;
        }
        return false;
    }

    fn errorBox(title: []const u8, content: []const u8) void {
        var text_buf: [4096]u16 = undefined;
        var caption_buf: [512]u16 = undefined;
        const text_z = utf8ToZ16Impl(&text_buf, content) orelse return;
        const caption_z: ?[*:0]const u16 = if (title.len > 0) blk: {
            const z = utf8ToZ16Impl(&caption_buf, title) orelse break :blk null;
            break :blk z.ptr;
        } else null;
        _ = MessageBoxW(null, text_z.ptr, caption_z, MB_OK | MB_ICONERROR);
    }

    /// TaskDialogIndirect 가 사용 불가(manifest 누락 등) 일 때 MessageBoxW 로 fallback.
    /// 커스텀 라벨은 보존 못 하지만 최소 dialog 는 표시.
    fn messageBoxFallback(opts: MessageBoxOpts) MessageBoxResult {
        var text_buf: [4096]u16 = undefined;
        var caption_w_buf: [512]u16 = undefined;
        var combined_buf: [4096]u8 = undefined;
        const text_utf8 = if (opts.detail.len > 0) blk: {
            const combined = std.fmt.bufPrint(&combined_buf, "{s}\n\n{s}", .{ opts.message, opts.detail }) catch opts.message;
            break :blk combined;
        } else opts.message;
        const text_z = utf8ToZ16Impl(&text_buf, text_utf8) orelse return .{};
        const caption_z: ?[*:0]const u16 = if (opts.title.len > 0) blk: {
            const z = utf8ToZ16Impl(&caption_w_buf, opts.title) orelse break :blk null;
            break :blk z.ptr;
        } else null;
        const button_type: u32 = switch (opts.buttons.len) {
            0, 1 => MB_OK,
            // 2-button 케이스 — isYesNoButtons 가 true 면 MB_YESNO (else MB_OKCANCEL),
            // messageBox path 와 동일 컨벤션.
            2 => if (isYesNoButtons(opts.buttons)) MB_YESNO else MB_OKCANCEL,
            else => MB_YESNOCANCEL,
        };
        const icon: u32 = switch (opts.style) {
            .info => MB_ICONINFORMATION,
            .err => MB_ICONERROR,
            .warning => MB_ICONWARNING,
            .question => MB_ICONQUESTION,
            .none => 0,
        };
        const response_id = MessageBoxW(null, text_z.ptr, caption_z, icon | button_type);
        const idx: usize = switch (response_id) {
            IDOK, IDYES => 0,
            IDNO => 1,
            IDCANCEL => if (opts.buttons.len > 0) opts.buttons.len - 1 else 0,
            else => 0,
        };
        return .{ .response = idx, .checkbox_checked = opts.checkbox_checked };
    }
} else struct {};
