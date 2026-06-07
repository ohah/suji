//! Shared CEF C API import.

const builtin = @import("builtin");

const is_macos = builtin.os.tag == .macos;
const is_windows = builtin.os.tag == .windows;

pub const c = @cImport({
    @cDefine("CEF_API_VERSION", "999999");
    // macOS만: uchar.h 없어서 CEF가 char16_t를 typedef → 매크로로 선회피.
    // Linux/Windows: uchar.h가 있으므로 매크로 불필요 (충돌 방지).
    if (is_macos) {
        @cDefine("char16_t", "unsigned short");
    }
    // Windows(MinGW): _FORTIFY_SOURCE=0 강제 (#14). MinGW <string.h> 는
    // `__MINGW_FORTIFY_LEVEL > 0` 일 때 wcscat/wcscpy 를 wcscat_s/wcscpy_s 호출
    // 하는 bos-check inline override 로 재정의하고, 그 게이트는 _mingw_mac.h:331
    // 에서 `_FORTIFY_SOURCE > 0 && __OPTIMIZE__ > 0`. Zig 의 ReleaseSafe 는 C 를
    // 최적화 번역(`__OPTIMIZE__>0`)해 override 가 생성되는데, Zig 0.16 translate-c
    // 가 그 fortified wrapper struct(`extern_local_wcscat_s`)를 `_ = &` discard
    // 없이 생성 → "unused local constant" 로 의미분석 실패. Debug(-O0)는
    // `__OPTIMIZE__` 미정의라 override 자체가 없어 통과. _FORTIFY_SOURCE=0 으로
    // 게이트를 닫으면 두 모드 동형(override 미생성). fortify 는 우리 CEF 바인딩과
    // 무관(prebuilt lib 사용, cimport 는 헤더 번역만) — 안전.
    if (is_windows) {
        @cDefine("_FORTIFY_SOURCE", "0");
    }
    @cInclude("include/capi/cef_app_capi.h");
    @cInclude("include/capi/cef_browser_capi.h");
    @cInclude("include/capi/cef_client_capi.h");
    @cInclude("include/capi/cef_drag_handler_capi.h");
    @cInclude("include/capi/cef_life_span_handler_capi.h");
    @cInclude("include/capi/cef_frame_capi.h");
    @cInclude("include/capi/cef_v8_capi.h");
    @cInclude("include/capi/cef_process_message_capi.h");
    @cInclude("include/capi/cef_render_process_handler_capi.h");
    @cInclude("include/capi/cef_keyboard_handler_capi.h");
    @cInclude("include/capi/cef_scheme_capi.h");
    @cInclude("include/capi/cef_resource_handler_capi.h");
    @cInclude("include/capi/cef_task_capi.h");
    @cInclude("include/capi/cef_cookie_capi.h");
    @cInclude("include/capi/cef_preference_capi.h");
    @cInclude("include/capi/cef_request_context_capi.h");
    @cInclude("include/capi/cef_values_capi.h");
    @cInclude("include/capi/cef_crash_util_capi.h");
    @cInclude("include/capi/cef_print_handler_capi.h");
    @cInclude("include/capi/views/cef_browser_view_capi.h");
    @cInclude("include/capi/views/cef_window_capi.h");
    @cInclude("include/capi/views/cef_overlay_controller_capi.h");
});
