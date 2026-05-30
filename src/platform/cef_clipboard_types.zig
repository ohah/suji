//! Shared Clipboard API constants.

/// 클립보드 텍스트 최대 길이 (null terminator 포함). main.zig IPC handler가 동일 cap을
/// 사용하므로 여기 한도를 넘는 입력은 caller 단에서 이미 잘려 있음.
pub const CLIPBOARD_MAX_TEXT: usize = 16384;

pub const PASTEBOARD_TYPE_STRING: [*:0]const u8 = "public.utf8-plain-text";
pub const PASTEBOARD_TYPE_HTML: [*:0]const u8 = "public.html";
pub const PASTEBOARD_TYPE_RTF: [*:0]const u8 = "public.rtf";
