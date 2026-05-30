//! Shared menu API types.

pub const ApplicationMenuItem = union(enum) {
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
        items: []const ApplicationMenuItem,
    },
};

pub const MenuEmitHandler = *const fn (click: []const u8) void;
