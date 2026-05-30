//! Shared Notification event emit state.

pub const NotificationEmitHandler = *const fn (notification_id: []const u8) void;
pub var g_notification_emit_handler: ?NotificationEmitHandler = null;

pub fn setNotificationEmitHandler(handler: NotificationEmitHandler) void {
    g_notification_emit_handler = handler;
}

pub fn emit(notification_id: []const u8) void {
    if (g_notification_emit_handler) |handler| handler(notification_id);
}
