//! Shared Tray API types.

/// tray.getBounds() 결과 — top-left origin 화면 좌표 rect (cef.NSRect 동형).
/// 플랫폼 backend(Windows/Linux)가 cef 순환 import 없이 반환하는 공용 타입.
pub const Bounds = struct { x: f64, y: f64, width: f64, height: f64 };

pub const TrayMenuItem = union(enum) {
    item: struct {
        label: []const u8,
        click: []const u8,
        enabled: bool = true,
    },
    checkbox: struct {
        label: []const u8,
        click: []const u8,
        checked: bool = false,
        enabled: bool = true,
    },
    separator,
    submenu: struct {
        label: []const u8,
        enabled: bool = true,
        items: []const TrayMenuItem,
    },
};
