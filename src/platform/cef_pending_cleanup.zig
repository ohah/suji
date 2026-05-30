//! Cleanup glue for CEF async operations keyed by browser handle.

const cef_browser_ipc = @import("cef_browser_ipc.zig");
const cef_page_output = @import("cef_page_output.zig");

pub fn purgePendingResponsesForBrowser(handle: u64) void {
    cef_browser_ipc.purgeDeferredResponsesForBrowser(handle);
    cef_page_output.purgeCapturePendingForBrowser(handle);
}
