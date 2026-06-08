const cef = @import("cef.zig");
const cef_browser_ipc = @import("cef_browser_ipc.zig");
const cef_download_handler = @import("cef_download_handler.zig");
const cef_drag_handler = @import("cef_drag_handler.zig");
const cef_keyboard_handler = @import("cef_keyboard_handler.zig");
const cef_life_span_handler = @import("cef_life_span_handler.zig");
const cef_request_handler = @import("cef_request_handler.zig");
const cef_session_permission = @import("cef_session_permission.zig");
const cef_window_display = @import("cef_window_display.zig");

const c = cef.c;

pub fn initClient(client_ptr: *c.cef_client_t) void {
    cef.zeroCefStruct(c.cef_client_t, client_ptr);
    cef.initBaseRefCounted(&client_ptr.base);
    client_ptr.get_life_span_handler = &cef_life_span_handler.getLifeSpanHandler;
    client_ptr.get_keyboard_handler = &cef_keyboard_handler.getKeyboardHandler;
    client_ptr.get_drag_handler = &cef_drag_handler.getDragHandler;
    client_ptr.get_display_handler = &getDisplayHandler;
    client_ptr.get_load_handler = &getLoadHandler;
    client_ptr.get_find_handler = &getFindHandler;
    client_ptr.get_print_handler = &getPrintHandler;
    client_ptr.get_request_handler = &getRequestHandler;
    client_ptr.get_permission_handler = &getPermissionHandler;
    client_ptr.get_download_handler = &getDownloadHandler;
    client_ptr.on_process_message_received = &cef_browser_ipc.onBrowserProcessMessageReceived;
}

fn getDisplayHandler(client: ?*c._cef_client_t) callconv(.c) ?*c._cef_display_handler_t {
    return cef_window_display.getDisplayHandler(client);
}

fn getLoadHandler(client: ?*c._cef_client_t) callconv(.c) ?*c._cef_load_handler_t {
    return cef_window_display.getLoadHandler(client);
}

fn getFindHandler(client: ?*c._cef_client_t) callconv(.c) ?*c._cef_find_handler_t {
    return cef_window_display.getFindHandler(client);
}

fn getPrintHandler(client: ?*c._cef_client_t) callconv(.c) ?*c._cef_print_handler_t {
    return cef_window_display.getPrintHandler(client);
}

fn getRequestHandler(client: ?*c._cef_client_t) callconv(.c) ?*c._cef_request_handler_t {
    return cef_request_handler.getRequestHandler(client);
}

fn getPermissionHandler(client: ?*c._cef_client_t) callconv(.c) ?*c._cef_permission_handler_t {
    return cef_session_permission.getPermissionHandler(client);
}

fn getDownloadHandler(client: ?*c._cef_client_t) callconv(.c) ?*c._cef_download_handler_t {
    return cef_download_handler.getDownloadHandler(client);
}
