//! Shared public Dialog API types.

pub const MAX_DIALOG_BUTTONS: usize = 16;
pub const MAX_DIALOG_PATHS: usize = 64;

pub const MessageBoxStyle = enum { none, info, warning, err, question };

pub const MessageBoxOpts = struct {
    style: MessageBoxStyle = .none,
    title: []const u8 = "",
    message: []const u8 = "",
    detail: []const u8 = "",
    buttons: []const []const u8 = &.{},
    default_id: ?usize = null,
    cancel_id: ?usize = null,
    checkbox_label: []const u8 = "",
    checkbox_checked: bool = false,
    /// 커스텀 아이콘 이미지 경로 (Electron MessageBoxOptions.icon) — NSAlert.setIcon (NSImage).
    /// 빈 문자열이면 기본 스타일 아이콘. macOS only.
    icon: []const u8 = "",
    /// 부모 창 NSWindow 포인터 — null이면 free-floating runModal, 있으면 sheet.
    parent_window: ?*anyopaque = null,
};

pub const MessageBoxResult = struct {
    response: usize = 0,
    checkbox_checked: bool = false,
};

pub const FileFilter = struct {
    name: []const u8 = "",
    extensions: []const []const u8 = &.{},
};

pub const OpenDialogOpts = struct {
    title: []const u8 = "",
    default_path: []const u8 = "",
    button_label: []const u8 = "",
    message: []const u8 = "",
    can_choose_files: bool = true,
    can_choose_directories: bool = false,
    allows_multiple_selection: bool = false,
    shows_hidden_files: bool = false,
    can_create_directories: bool = true,
    no_resolve_aliases: bool = false,
    treat_packages_as_dirs: bool = false,
    filters: []const FileFilter = &.{},
    /// 부모 창 NSWindow 포인터 — null이면 free-floating, 있으면 sheet.
    parent_window: ?*anyopaque = null,
};

pub const SaveDialogOpts = struct {
    title: []const u8 = "",
    default_path: []const u8 = "",
    button_label: []const u8 = "",
    message: []const u8 = "",
    name_field_label: []const u8 = "",
    shows_hidden_files: bool = false,
    can_create_directories: bool = true,
    show_overwrite_confirmation: bool = true,
    /// macOS Finder 태그 입력 필드 (NSSavePanel.setShowsTagField:). 기본 false.
    shows_tag_field: bool = false,
    filters: []const FileFilter = &.{},
    /// 부모 창 NSWindow 포인터 — null이면 free-floating, 있으면 sheet.
    parent_window: ?*anyopaque = null,
};
