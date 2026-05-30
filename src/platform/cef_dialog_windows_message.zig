//! Windows message dialog backend facade.

const builtin = @import("builtin");
const dialog_types = @import("cef_dialog_types.zig");
const messagebox = @import("cef_dialog_windows_messagebox.zig");
const task_dialog = @import("cef_dialog_windows_task_dialog.zig");

const MessageBoxOpts = dialog_types.MessageBoxOpts;
const MessageBoxResult = dialog_types.MessageBoxResult;

pub fn messageBox(opts: MessageBoxOpts) MessageBoxResult {
    if (comptime builtin.os.tag != .windows) return .{};
    if (messagebox.hasCustomButtonLabels(opts.buttons)) {
        return task_dialog.messageBox(opts);
    }
    return messagebox.messageBox(opts);
}

pub fn errorBox(title: []const u8, content: []const u8) void {
    if (comptime builtin.os.tag != .windows) return;
    messagebox.errorBox(title, content);
}
