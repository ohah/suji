//! Shared menu API types.

pub const ApplicationMenuItem = union(enum) {
    item: struct {
        label: []const u8,
        click: []const u8,
        enabled: bool = true,
        /// Electron MenuItem.id — UI 효과 없음(getMenuItemById 라운드트립용 식별자).
        id: []const u8 = "",
        /// Electron MenuItem.visible — false 면 메뉴에 존재하되 숨김(setHidden:).
        visible: bool = true,
        /// Electron MenuItem.accelerator — "Cmd+Shift+K" 등. macOS NSMenuItem keyEquivalent.
        accelerator: []const u8 = "",
    },
    checkbox: struct {
        label: []const u8,
        click: []const u8,
        checked: bool = false,
        enabled: bool = true,
        id: []const u8 = "",
        visible: bool = true,
        accelerator: []const u8 = "",
    },
    separator,
    submenu: struct {
        label: []const u8,
        enabled: bool = true,
        items: []const ApplicationMenuItem,
        id: []const u8 = "",
        visible: bool = true,
    },
};

pub const MenuEmitHandler = *const fn (click: []const u8) void;
