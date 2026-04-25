//! # Suji Rust SDK
//!
//! ```rust
//! use suji::prelude::*;
//!
//! #[suji::handle]
//! fn ping() -> String { "pong".to_string() }
//!
//! #[suji::handle]
//! fn greet(name: String) -> String { format!("Hello, {}!", name) }
//!
//! suji::export_handlers!(ping, greet);
//! ```

// `#[suji::handle]` 매크로가 `::suji::InvokeEvent::from_request(...)` 경로를 확장한다.
// crate 내부 (테스트 포함)에서도 그 경로를 유효하게 하려면 self를 `suji`라는 이름으로 노출.
extern crate self as suji;

pub use suji_macros::command as handle;
pub use serde_json;
pub use serde;

/// IPC 요청의 sender 창 컨텍스트 — Electron의 `event.sender`/`BrowserWindow.fromWebContents` 대응.
///
/// 2-arity 핸들러 `fn(..., event: InvokeEvent)`의 두 번째 파라미터로 받는다.
/// 파싱 실패/누락 시 id=0, name=None.
///
/// ```ignore
/// #[suji::handle]
/// fn save(filename: String, event: suji::InvokeEvent) -> serde_json::Value {
///     if event.window.name.as_deref() == Some("settings") { /* ... */ }
///     serde_json::json!({ "ok": true, "from": event.window.id })
/// }
/// ```
#[derive(Debug, Clone, Default)]
pub struct InvokeEvent {
    pub window: Window,
}

#[derive(Debug, Clone, Default)]
pub struct Window {
    pub id: u32,
    pub name: Option<String>,
    /// sender 창의 main frame URL (Electron `event.sender.url` 대응).
    /// wire 레벨 `__window_url`에서 파생. 로드 전/빈 페이지면 None.
    pub url: Option<String>,
    /// sender frame이 페이지의 main frame인지 (false면 iframe 내부 호출).
    /// wire의 `__window_main_frame`에서 파생.
    pub is_main_frame: Option<bool>,
}

impl InvokeEvent {
    /// wire의 `__window` / `__window_name` / `__window_url` / `__window_main_frame` 필드에서 파생.
    /// #[doc(hidden)] 루트 request JSON Value를 받아 구성 — proc macro가 자동 호출.
    #[doc(hidden)]
    pub fn from_request(parsed: &serde_json::Value) -> Self {
        let id = parsed
            .get("__window")
            .and_then(|v| v.as_u64())
            .map(|n| n as u32)
            .unwrap_or(0);
        let name = parsed
            .get("__window_name")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string());
        let url = parsed
            .get("__window_url")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string());
        let is_main_frame = parsed
            .get("__window_main_frame")
            .and_then(|v| v.as_bool());
        Self { window: Window { id, name, url, is_main_frame } }
    }
}

#[repr(C)]
pub struct SujiCore {
    pub invoke: extern "C" fn(*const std::os::raw::c_char, *const std::os::raw::c_char) -> *const std::os::raw::c_char,
    pub free: extern "C" fn(*const std::os::raw::c_char),
    pub emit: extern "C" fn(*const std::os::raw::c_char, *const std::os::raw::c_char),
    pub on: extern "C" fn(*const std::os::raw::c_char, Option<extern "C" fn(*const std::os::raw::c_char, *const std::os::raw::c_char, *mut std::os::raw::c_void)>, *mut std::os::raw::c_void) -> u64,
    pub off: extern "C" fn(u64),
    pub register: extern "C" fn(*const std::os::raw::c_char),
    /// Zig plugin 전용. Rust plugin은 `std::sync`/`std::fs` 사용 권장.
    pub get_io: extern "C" fn() -> *const std::os::raw::c_void,
    /// 앱 종료 요청 (Electron `app.quit()` 호환). 메인 프로세스가 종료 함수를 주입.
    pub quit: extern "C" fn(),
    /// 플랫폼 이름 — "macos" | "linux" | "windows" | "other".
    pub platform: extern "C" fn() -> *const std::os::raw::c_char,
    /// 특정 창(WindowManager id)에만 이벤트 전달 (Electron `webContents.send`).
    pub emit_to: extern "C" fn(u32, *const std::os::raw::c_char, *const std::os::raw::c_char),
}

unsafe impl Send for SujiCore {}
unsafe impl Sync for SujiCore {}

#[doc(hidden)]
pub static __SUJI_CORE: std::sync::OnceLock<&'static SujiCore> = std::sync::OnceLock::new();

pub fn invoke(backend: &str, request: &str) -> Option<String> {
    let core = __SUJI_CORE.get()?;
    let c_name = std::ffi::CString::new(backend).ok()?;
    let c_req = std::ffi::CString::new(request).ok()?;
    let resp = (core.invoke)(c_name.as_ptr(), c_req.as_ptr());
    if resp.is_null() { return None; }
    Some(unsafe { std::ffi::CStr::from_ptr(resp) }.to_str().ok()?.to_string())
}

pub fn send(channel: &str, data: &str) {
    if let Some(core) = __SUJI_CORE.get() {
        let c_ch = std::ffi::CString::new(channel).unwrap_or_default();
        let c_data = std::ffi::CString::new(data).unwrap_or_default();
        (core.emit)(c_ch.as_ptr(), c_data.as_ptr());
    }
}

/// 특정 창(window id)에만 이벤트 전달 (Electron `webContents.send`).
/// 대상 창이 닫혔거나 core가 주입 전이면 silent no-op.
pub fn send_to(window_id: u32, channel: &str, data: &str) {
    if let Some(core) = __SUJI_CORE.get() {
        let c_ch = std::ffi::CString::new(channel).unwrap_or_default();
        let c_data = std::ffi::CString::new(data).unwrap_or_default();
        (core.emit_to)(window_id, c_ch.as_ptr(), c_data.as_ptr());
    }
}

/// 이벤트 수신 (Electron: ipcMain.on)
/// 리스너 ID를 반환 (off로 해제 가능)
pub fn on(channel: &str, callback: extern "C" fn(*const std::os::raw::c_char, *const std::os::raw::c_char, *mut std::os::raw::c_void), arg: *mut std::os::raw::c_void) -> u64 {
    if let Some(core) = __SUJI_CORE.get() {
        let c_ch = std::ffi::CString::new(channel).unwrap_or_default();
        (core.on)(c_ch.as_ptr(), Some(callback), arg)
    } else {
        0
    }
}

/// 리스너 해제
pub fn off(listener_id: u64) {
    if let Some(core) = __SUJI_CORE.get() {
        (core.off)(listener_id);
    }
}

/// 앱 종료 요청 (Electron `app.quit()` 호환).
/// 주로 `on("window:all-closed", ...)` 핸들러에서 플랫폼 확인 후 호출.
/// core 주입 전이면 silent no-op.
pub fn quit() {
    if let Some(core) = __SUJI_CORE.get() {
        (core.quit)();
    }
}

// ============================================
// windows API — Phase 4-A 백엔드 SDK
// dlopen 환경에선 in-process 코어 접근 불가 → 모두 invoke("__core__", ...) 경유.
// Frontend `@suji/api` windows.* 와 동일한 cmd JSON 형식.
// ============================================

pub mod windows {
    use super::invoke;

    /// 새 창 생성. `opts_json`은 cmd 객체 안에 들어갈 필드 (예: `r#""title":"x","frame":false"#`).
    /// caller가 JSON-safe 보장. 단순 경우는 `create_simple()` 사용.
    pub fn create(opts_json: &str) -> Option<String> {
        let req = if opts_json.is_empty() {
            r#"{"cmd":"create_window"}"#.to_string()
        } else {
            format!(r#"{{"cmd":"create_window",{}}}"#, opts_json)
        };
        invoke("__core__", &req)
    }

    /// 단축: title + url만으로 익명 창 생성.
    pub fn create_simple(title: &str, url: &str) -> Option<String> {
        let opts = format!(
            r#""title":"{}","url":"{}""#,
            escape_json(title),
            escape_json(url),
        );
        create(&opts)
    }

    pub fn load_url(window_id: u32, url: &str) -> Option<String> {
        let req = format!(
            r#"{{"cmd":"load_url","windowId":{},"url":"{}"}}"#,
            window_id,
            escape_json(url),
        );
        invoke("__core__", &req)
    }

    pub fn reload(window_id: u32, ignore_cache: bool) -> Option<String> {
        let req = format!(
            r#"{{"cmd":"reload","windowId":{},"ignoreCache":{}}}"#,
            window_id, ignore_cache,
        );
        invoke("__core__", &req)
    }

    /// 렌더러에 임의 JS 실행. fire-and-forget — 결과 회신 없음.
    pub fn execute_javascript(window_id: u32, code: &str) -> Option<String> {
        let req = format!(
            r#"{{"cmd":"execute_javascript","windowId":{},"code":"{}"}}"#,
            window_id,
            escape_json(code),
        );
        invoke("__core__", &req)
    }

    pub fn get_url(window_id: u32) -> Option<String> {
        invoke("__core__", &format!(r#"{{"cmd":"get_url","windowId":{}}}"#, window_id))
    }

    pub fn is_loading(window_id: u32) -> Option<String> {
        invoke("__core__", &format!(r#"{{"cmd":"is_loading","windowId":{}}}"#, window_id))
    }

    pub fn set_title(window_id: u32, title: &str) -> Option<String> {
        let req = format!(
            r#"{{"cmd":"set_title","windowId":{},"title":"{}"}}"#,
            window_id,
            escape_json(title),
        );
        invoke("__core__", &req)
    }

    #[derive(Default, Clone, Copy)]
    pub struct SetBoundsArgs {
        pub x: i32,
        pub y: i32,
        pub width: u32,
        pub height: u32,
    }

    pub fn set_bounds(window_id: u32, b: SetBoundsArgs) -> Option<String> {
        let req = format!(
            r#"{{"cmd":"set_bounds","windowId":{},"x":{},"y":{},"width":{},"height":{}}}"#,
            window_id, b.x, b.y, b.width, b.height,
        );
        invoke("__core__", &req)
    }

    /// JSON 문자열 escape — `"` `\\` 이스케이프 + control char drop.
    fn escape_json(s: &str) -> String {
        let mut out = String::with_capacity(s.len());
        for ch in s.chars() {
            match ch {
                '"' => out.push_str("\\\""),
                '\\' => out.push_str("\\\\"),
                c if (c as u32) < 0x20 => continue,
                c => out.push(c),
            }
        }
        out
    }

    #[cfg(test)]
    mod tests {
        use super::escape_json;

        #[test]
        fn escape_quote_and_backslash() {
            assert_eq!(escape_json("a\"b\\c"), "a\\\"b\\\\c");
        }

        #[test]
        fn drop_control_chars() {
            assert_eq!(escape_json("a\nb\tc"), "abc");
        }

        #[test]
        fn passthrough_normal() {
            assert_eq!(escape_json("hello world!"), "hello world!");
        }
    }
}

/// 플랫폼 이름 — `"macos"` | `"linux"` | `"windows"` | `"other"`.
/// Electron `process.platform` 대응 (단 Suji는 `"darwin"` 대신 `"macos"`).
pub fn platform() -> &'static str {
    let core = match __SUJI_CORE.get() {
        Some(c) => c,
        None => return "unknown",
    };
    let ptr = (core.platform)();
    if ptr.is_null() {
        return "unknown";
    }
    unsafe { std::ffi::CStr::from_ptr(ptr) }
        .to_str()
        .unwrap_or("unknown")
}

/// 플랫폼 상수 — `platform()` 반환값과 비교할 때 사용.
/// Suji는 macOS/Linux/Windows만 지원.
pub const PLATFORM_MACOS: &str = "macos";
pub const PLATFORM_LINUX: &str = "linux";
pub const PLATFORM_WINDOWS: &str = "windows";

// ============================================
// Tests — 1 기능 1 테스트
// ============================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quit_is_noop_when_core_missing() {
        // __SUJI_CORE가 주입 전이면 silent no-op (crash 없음)
        quit();
    }

    #[test]
    fn platform_returns_unknown_when_core_missing() {
        // 주입 전 기본값
        assert_eq!(platform(), "unknown");
    }

    #[test]
    fn platform_constants_match_known_strings() {
        assert_eq!(PLATFORM_MACOS, "macos");
        assert_eq!(PLATFORM_LINUX, "linux");
        assert_eq!(PLATFORM_WINDOWS, "windows");
    }

    #[test]
    fn off_is_noop_on_invalid_id() {
        // id=0 등 존재하지 않는 listener off — crash 없음
        off(0);
        off(99999);
    }

    #[test]
    fn send_and_send_to_are_noop_when_core_missing() {
        // __SUJI_CORE 없을 때 crash 없음
        send("test", "{}");
        send_to(5, "test", "{}");
    }

    #[test]
    fn invoke_event_from_request_parses_window_fields() {
        let v = serde_json::json!({
            "cmd": "save",
            "__window": 7u32,
            "__window_name": "settings",
        });
        let ev = InvokeEvent::from_request(&v);
        assert_eq!(ev.window.id, 7);
        assert_eq!(ev.window.name.as_deref(), Some("settings"));
    }

    #[test]
    fn invoke_event_defaults_when_fields_missing() {
        let v = serde_json::json!({ "cmd": "ping" });
        let ev = InvokeEvent::from_request(&v);
        assert_eq!(ev.window.id, 0);
        assert!(ev.window.name.is_none());
    }

    #[test]
    fn invoke_event_parses_url_field() {
        let v = serde_json::json!({
            "__window": 2,
            "__window_name": "main",
            "__window_url": "http://localhost:5173/",
        });
        let ev = InvokeEvent::from_request(&v);
        assert_eq!(ev.window.id, 2);
        assert_eq!(ev.window.name.as_deref(), Some("main"));
        assert_eq!(ev.window.url.as_deref(), Some("http://localhost:5173/"));
    }

    #[test]
    fn invoke_event_url_is_none_when_missing() {
        let ev = InvokeEvent::from_request(&serde_json::json!({ "__window": 3 }));
        assert!(ev.window.url.is_none());
    }

    #[test]
    fn invoke_event_parses_main_frame_field() {
        let ev_main = InvokeEvent::from_request(&serde_json::json!({
            "__window": 1, "__window_main_frame": true,
        }));
        assert_eq!(ev_main.window.is_main_frame, Some(true));

        let ev_iframe = InvokeEvent::from_request(&serde_json::json!({
            "__window": 1, "__window_main_frame": false,
        }));
        assert_eq!(ev_iframe.window.is_main_frame, Some(false));

        let ev_none = InvokeEvent::from_request(&serde_json::json!({ "__window": 1 }));
        assert!(ev_none.window.is_main_frame.is_none());
    }

    #[test]
    fn invoke_event_defaults_when_types_wrong() {
        // 음수/문자열 __window, 숫자 __window_name — 전부 default로 안전 폴백.
        let v = serde_json::json!({
            "__window": "not-a-number",
            "__window_name": 42,
        });
        let ev = InvokeEvent::from_request(&v);
        assert_eq!(ev.window.id, 0);
        assert!(ev.window.name.is_none());
    }

    // proc macro 통합 테스트 — 매크로가 확장한 함수가 기대한 대로 동작하는지 검증.
    // 일반 필드 추출 경로 / InvokeEvent 자동 파생 경로 / 두 파라미터 혼합 경로.

    #[suji::handle]
    #[allow(dead_code)]
    fn greet_test(name: String) -> String {
        format!("hi {name}")
    }

    #[suji::handle]
    #[allow(dead_code)]
    fn whoami_test(event: suji::InvokeEvent) -> serde_json::Value {
        serde_json::json!({
            "id": event.window.id,
            "name": event.window.name,
        })
    }

    #[suji::handle]
    #[allow(dead_code)]
    fn save_test(text: String, event: suji::InvokeEvent) -> serde_json::Value {
        serde_json::json!({
            "text": text,
            "from_window": event.window.id,
        })
    }

    #[test]
    fn handle_macro_extracts_named_fields() {
        let req = serde_json::json!({ "name": "kim" });
        let resp = greet_test(req);
        assert_eq!(resp, serde_json::json!("hi kim"));
    }

    #[test]
    fn handle_macro_auto_injects_invoke_event() {
        let req = serde_json::json!({
            "__window": 3,
            "__window_name": "settings",
        });
        let resp = whoami_test(req);
        assert_eq!(resp, serde_json::json!({ "id": 3, "name": "settings" }));
    }

    #[test]
    fn handle_macro_mixes_fields_and_invoke_event() {
        let req = serde_json::json!({
            "text": "hi",
            "__window": 9,
        });
        let resp = save_test(req);
        assert_eq!(resp, serde_json::json!({ "text": "hi", "from_window": 9 }));
    }

    #[test]
    fn handle_macro_fills_defaults_for_missing_fields() {
        // name 필드 없음 → String::default()인 ""
        // __window 없음 → 0, name=None → json에서 null
        let resp_greet = greet_test(serde_json::json!({}));
        assert_eq!(resp_greet, serde_json::json!("hi "));

        let resp_who = whoami_test(serde_json::json!({}));
        assert_eq!(resp_who, serde_json::json!({ "id": 0, "name": null }));
    }
}

pub mod prelude {
    pub use crate::handle;
    pub use crate::invoke;
    pub use crate::send;
    pub use crate::send_to;
    pub use crate::on;
    pub use crate::off;
    pub use crate::quit;
    pub use crate::platform;
    pub use crate::InvokeEvent;
    pub use crate::Window;
    pub use crate::PLATFORM_MACOS;
    pub use crate::PLATFORM_LINUX;
    pub use crate::PLATFORM_WINDOWS;
    pub use serde_json::json;
}

#[macro_export]
macro_rules! export_handlers {
    // 기본 형태: handlers만
    ($($handler:ident),* $(,)?) => {
        $crate::export_handlers!(@impl [$($handler),*]; []);
    };
    // 확장 형태: handlers + event listeners (`channel => extern_fn`)
    ($($handler:ident),* $(,)? ; $($ch:literal => $listener:ident),* $(,)?) => {
        $crate::export_handlers!(@impl [$($handler),*]; [$($ch => $listener),*]);
    };
    (@impl [$($handler:ident),*]; [$($ch:literal => $listener:ident),*]) => {
        #[no_mangle]
        pub extern "C" fn backend_init(core: *const $crate::SujiCore) {
            if !core.is_null() {
                let core_ref: &'static $crate::SujiCore = unsafe { std::mem::transmute(&*core) };
                let _ = $crate::__SUJI_CORE.set(core_ref);
                // 핸들러 채널 등록
                $(
                    let ch = std::ffi::CString::new(stringify!($handler)).unwrap();
                    (core_ref.register)(ch.as_ptr());
                )*
                // 이벤트 리스너 등록 (있으면)
                $(
                    let ch = std::ffi::CString::new($ch).unwrap();
                    (core_ref.on)(ch.as_ptr(), Some($listener), std::ptr::null_mut());
                )*
            }
            eprintln!("[Rust] ready");
        }

        #[no_mangle]
        pub extern "C" fn backend_handle_ipc(request: *const std::os::raw::c_char) -> *mut std::os::raw::c_char {
            let req_str = unsafe { std::ffi::CStr::from_ptr(request) }.to_str().unwrap_or("");
            let parsed: $crate::serde_json::Value = $crate::serde_json::from_str(req_str)
                .unwrap_or($crate::serde_json::json!({}));
            let cmd = parsed.get("cmd").and_then(|v| v.as_str()).unwrap_or("");

            let response = match cmd {
                $(stringify!($handler) => {
                    let result = $handler(parsed.clone());
                    $crate::serde_json::json!({"from":"rust","cmd":cmd,"result":result}).to_string()
                }),*
                _ => $crate::serde_json::json!({"from":"rust","error":format!("unknown: {}",cmd)}).to_string(),
            };

            std::ffi::CString::new(response).unwrap().into_raw()
        }

        #[no_mangle]
        pub extern "C" fn backend_free(ptr: *mut std::os::raw::c_char) {
            if !ptr.is_null() { unsafe { drop(std::ffi::CString::from_raw(ptr)); } }
        }

        #[no_mangle]
        pub extern "C" fn backend_destroy() { eprintln!("[Rust] bye"); }
    };
}
