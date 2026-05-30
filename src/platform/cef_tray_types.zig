//! Shared Tray API types.

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
