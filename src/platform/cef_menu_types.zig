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
        /// Electron MenuItem.role — copy/paste/quit 등 표준 동작. macOS NSMenuItem 네이티브
        /// selector(first responder). 설정 시 click 무시(role 이 동작). macOS only.
        role: []const u8 = "",
        /// Electron MenuItem.icon — 이미지 파일 경로. macOS NSImage(setImage:). fs sandbox
        /// 게이트 적용(렌더러 경로). macOS only.
        icon: []const u8 = "",
    },
    checkbox: struct {
        label: []const u8,
        click: []const u8,
        checked: bool = false,
        enabled: bool = true,
        id: []const u8 = "",
        visible: bool = true,
        accelerator: []const u8 = "",
        icon: []const u8 = "",
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

/// 컨텍스트 메뉴 생명주기 이벤트(menu:will-show / menu:will-close) emit 핸들러. click
/// payload 없는 고정 채널 발신이라 MenuEmitHandler 와 별도 시그니처(channel only).
pub const MenuLifecycleEmitHandler = *const fn (channel: []const u8) void;
