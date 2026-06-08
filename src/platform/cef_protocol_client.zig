//! app.setAsDefaultProtocolClient / isDefaultProtocolClient / removeAsDefaultProtocolClient
//! — macOS Launch Services (protocol_client.m). 비-macOS 는 false(extern 은 comptime
//! is_macos 분기로 prune → Linux/Windows 링크 안전, nativetheme/screen 패턴 동형).
//!
//! 정직 경계: 실 .app 번들에서만 동작(번들 identifier 필요) — dev=graceful false.
//! scheme 등록 자체는 선언적 deepLinkSchemes→CFBundleURLTypes 가 담당(이건 기본-핸들러
//! 강제/조회 보조 API). removeAsDefault 는 macOS LS 에 해제 API 부재 → false(Electron 동형).

const builtin = @import("builtin");
const is_macos = builtin.os.tag == .macos;

extern "c" fn suji_protocol_set_default(scheme: [*:0]const u8) c_int;
extern "c" fn suji_protocol_is_default(scheme: [*:0]const u8) c_int;
extern "c" fn suji_protocol_remove_default(scheme: [*:0]const u8) c_int;

pub fn setAsDefault(scheme: [*:0]const u8) bool {
    if (!comptime is_macos) return false;
    return suji_protocol_set_default(scheme) == 1;
}

pub fn isDefault(scheme: [*:0]const u8) bool {
    if (!comptime is_macos) return false;
    return suji_protocol_is_default(scheme) == 1;
}

pub fn removeAsDefault(scheme: [*:0]const u8) bool {
    if (!comptime is_macos) return false;
    return suji_protocol_remove_default(scheme) == 1;
}
