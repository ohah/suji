//! Shared Global Shortcut event emit state.

pub const GlobalShortcutEmitHandler = *const fn (accelerator: []const u8, click: []const u8) void;
pub var g_global_shortcut_emit_handler: ?GlobalShortcutEmitHandler = null;

pub fn setGlobalShortcutEmitHandler(handler: GlobalShortcutEmitHandler) void {
    g_global_shortcut_emit_handler = handler;
}

pub fn emit(accelerator: []const u8, click: []const u8) void {
    if (g_global_shortcut_emit_handler) |handler| handler(accelerator, click);
}
