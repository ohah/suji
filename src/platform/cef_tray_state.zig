//! Shared Tray event emit state.

pub const TrayEmitHandler = *const fn (tray_id: u32, click: []const u8) void;
pub var g_tray_emit_handler: ?TrayEmitHandler = null;

pub fn setTrayEmitHandler(handler: TrayEmitHandler) void {
    g_tray_emit_handler = handler;
}

pub fn emit(tray_id: u32, click: []const u8) void {
    if (tray_id == 0) return;
    if (g_tray_emit_handler) |handler| handler(tray_id, click);
}
