//! Linux GTK Dialog backend facade.

const builtin = @import("builtin");
const dialog_types = @import("cef_dialog_types.zig");
const dialog_response = @import("cef_dialog_response.zig");
const linux_message = @import("cef_dialog_linux_message.zig");
const linux_file = @import("cef_dialog_linux_file.zig");

const is_linux = builtin.os.tag == .linux;

const MessageBoxOpts = dialog_types.MessageBoxOpts;
const MessageBoxResult = dialog_types.MessageBoxResult;
const OpenDialogOpts = dialog_types.OpenDialogOpts;
const SaveDialogOpts = dialog_types.SaveDialogOpts;
const writeCanceledResponse = dialog_response.writeCanceledResponse;
const writeSaveCanceledResponse = dialog_response.writeSaveCanceledResponse;

pub fn showMessageBox(opts: MessageBoxOpts) MessageBoxResult {
    if (!comptime is_linux) return .{};
    return linux_message.showMessageBox(opts);
}

pub fn showErrorBox(title: []const u8, content: []const u8) void {
    if (!comptime is_linux) return;
    linux_message.showErrorBox(title, content);
}

pub fn showOpen(opts: OpenDialogOpts, response_buf: []u8) []const u8 {
    if (!comptime is_linux) return writeCanceledResponse(response_buf, true);
    return linux_file.showOpen(opts, response_buf);
}

pub fn showSave(opts: SaveDialogOpts, response_buf: []u8) []const u8 {
    if (!comptime is_linux) return writeSaveCanceledResponse(response_buf, true);
    return linux_file.showSave(opts, response_buf);
}
