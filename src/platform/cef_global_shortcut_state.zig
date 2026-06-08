//! Shared Global Shortcut event emit state.

const std = @import("std");

pub const GlobalShortcutEmitHandler = *const fn (accelerator: []const u8, click: []const u8) void;
pub var g_global_shortcut_emit_handler: ?GlobalShortcutEmitHandler = null;

/// Electron `globalShortcut.setSuspended` — suspended 동안 등록은 유지하되 trigger 발신만
/// 차단(등록 해제 아님; isRegistered 는 true 유지). 전 플랫폼 emit 경로(emit)에서 단일 게이트.
/// IPC 스레드에서 write, 이벤트 스레드(Carbon/X11/WM_HOTKEY)에서 read 라 atomic
/// (런타임 토글 — set-once 인 emit_handler 와 달리 가시성 보장 필요).
pub var g_suspended = std.atomic.Value(bool).init(false);

pub fn setGlobalShortcutEmitHandler(handler: GlobalShortcutEmitHandler) void {
    g_global_shortcut_emit_handler = handler;
}

pub fn setSuspended(v: bool) void {
    g_suspended.store(v, .monotonic);
}

pub fn isSuspended() bool {
    return g_suspended.load(.monotonic);
}

pub fn emit(accelerator: []const u8, click: []const u8) void {
    if (g_suspended.load(.monotonic)) return; // suspended → trigger 삼킴(네이티브 등록은 유지).
    if (g_global_shortcut_emit_handler) |handler| handler(accelerator, click);
}
