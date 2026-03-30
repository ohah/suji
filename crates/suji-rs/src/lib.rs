//! # Suji Rust SDK
//!
//! ```rust
//! use suji::prelude::*;
//!
//! #[suji::command]
//! fn greet(name: String) -> String {
//!     format!("Hello, {}!", name)
//! }
//!
//! #[suji::command]
//! fn add(a: i64, b: i64) -> i64 {
//!     a + b
//! }
//!
//! suji::export_commands!(greet, add);
//! ```

pub use suji_macros::command;
pub use serde_json;
pub use serde;

/// Zig 코어가 백엔드에게 제공하는 API
#[repr(C)]
pub struct SujiCore {
    pub invoke: extern "C" fn(*const std::os::raw::c_char, *const std::os::raw::c_char) -> *const std::os::raw::c_char,
    pub free: extern "C" fn(*const std::os::raw::c_char),
}

unsafe impl Send for SujiCore {}
unsafe impl Sync for SujiCore {}

/// 다른 백엔드 호출
pub fn call_backend(backend: &str, request: &str) -> Option<String> {
    let core = __SUJI_CORE_GLOBAL.get()?;
    let c_name = std::ffi::CString::new(backend).ok()?;
    let c_req = std::ffi::CString::new(request).ok()?;
    let resp = (core.invoke)(c_name.as_ptr(), c_req.as_ptr());
    if resp.is_null() { return None; }
    let result = unsafe { std::ffi::CStr::from_ptr(resp) }.to_str().ok()?.to_string();
    Some(result)
}

#[doc(hidden)]
pub static __SUJI_CORE_GLOBAL: std::sync::OnceLock<&'static SujiCore> = std::sync::OnceLock::new();

pub mod prelude {
    pub use crate::command;
    pub use crate::call_backend;
    pub use serde_json::json;
}

/// C ABI export 자동 생성
///
/// ```rust
/// suji::export_commands!(ping, greet, add);
/// ```
#[macro_export]
macro_rules! export_commands {
    ($($cmd:ident),* $(,)?) => {
        #[no_mangle]
        pub extern "C" fn backend_init(core: *const $crate::SujiCore) {
            if !core.is_null() {
                let core_ref: &'static $crate::SujiCore = unsafe { std::mem::transmute(&*core) };
                let _ = $crate::__SUJI_CORE_GLOBAL.set(core_ref);
            }
            eprintln!("[Rust] ready (suji SDK)");
        }

        #[no_mangle]
        pub extern "C" fn backend_handle_ipc(
            request: *const std::os::raw::c_char,
        ) -> *mut std::os::raw::c_char {
            let req_str = unsafe { std::ffi::CStr::from_ptr(request) }
                .to_str()
                .unwrap_or("");
            let parsed: $crate::serde_json::Value = $crate::serde_json::from_str(req_str)
                .unwrap_or($crate::serde_json::json!({}));
            let cmd = parsed.get("cmd")
                .and_then(|v| v.as_str())
                .unwrap_or("");

            let response = match cmd {
                $(
                    stringify!($cmd) => {
                        let result = $cmd(parsed.clone());
                        $crate::serde_json::json!({
                            "from": "rust",
                            "cmd": cmd,
                            "result": result
                        }).to_string()
                    }
                ),*
                _ => $crate::serde_json::json!({
                    "from": "rust",
                    "error": format!("unknown command: {}", cmd)
                }).to_string(),
            };

            std::ffi::CString::new(response).unwrap().into_raw()
        }

        #[no_mangle]
        pub extern "C" fn backend_free(ptr: *mut std::os::raw::c_char) {
            if !ptr.is_null() {
                unsafe { drop(std::ffi::CString::from_raw(ptr)); }
            }
        }

        #[no_mangle]
        pub extern "C" fn backend_destroy() {
            eprintln!("[Rust] bye (suji SDK)");
        }
    };
}
