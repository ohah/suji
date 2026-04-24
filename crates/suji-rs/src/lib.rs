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

pub use suji_macros::command as handle;
pub use serde_json;
pub use serde;

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

pub mod prelude {
    pub use crate::handle;
    pub use crate::invoke;
    pub use crate::send;
    pub use crate::on;
    pub use crate::off;
    pub use serde_json::json;
}

#[macro_export]
macro_rules! export_handlers {
    ($($handler:ident),* $(,)?) => {
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
