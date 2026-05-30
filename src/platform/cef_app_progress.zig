//! app.setProgressBar — cef.zig 에서 분리(동작 무변경).
//! macOS NSDockTile 진행률 표시 bridge.
const builtin = @import("builtin");
const cef = @import("cef.zig");

const is_macos = builtin.os.tag == .macos;

const objc = cef.objc;
const getClass = cef.getClass;
const msgSend = cef.msgSend;
const msgSendVoid1 = cef.msgSendVoid1;
const msgSendVoidBool = cef.msgSendVoidBool;

/// dock 진행률 표시 (Electron `BrowserWindow.setProgressBar(progress)`).
/// progress < 0이면 hide, 0~1은 진행률 표시, 1 초과는 100%로 clamp.
/// macOS는 BrowserWindow별이 아닌 NSApp.dockTile 단일 — Electron의 멀티 윈도우 시도는
/// 어차피 마지막 호출이 win. 단순화로 NSApp.dockTile.contentView 직접 set.
pub fn appSetProgressBar(progress: f64) bool {
    if (!comptime is_macos) return false;
    const NSApplication = getClass("NSApplication") orelse return false;
    const app = msgSend(NSApplication, "sharedApplication") orelse return false;
    const tile = msgSend(app, "dockTile") orelse return false;

    if (progress < 0) {
        msgSendVoid1(tile, "setContentView:", null);
        _ = msgSend(tile, "display");
        return true;
    }

    const NSProgressIndicator = getClass("NSProgressIndicator") orelse return false;
    const indicator_alloc = msgSend(NSProgressIndicator, "alloc") orelse return false;
    const indicator = msgSend(indicator_alloc, "init") orelse return false;

    msgSendVoidBool(indicator, "setIndeterminate:", false);
    const setF: *const fn (?*anyopaque, ?*anyopaque, f64) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    setF(indicator, @ptrCast(objc.sel_registerName("setMinValue:")), 0);
    setF(indicator, @ptrCast(objc.sel_registerName("setMaxValue:")), 1);
    const clamped = if (progress > 1) 1.0 else progress;
    setF(indicator, @ptrCast(objc.sel_registerName("setDoubleValue:")), clamped);

    msgSendVoid1(tile, "setContentView:", indicator);
    _ = msgSend(tile, "display");
    return true;
}
