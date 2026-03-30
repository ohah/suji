use serde_json::json;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;

#[repr(C)]
struct SujiCore {
    invoke: extern "C" fn(*const c_char, *const c_char) -> *const c_char,
    free: extern "C" fn(*const c_char),
}

#[no_mangle]
pub extern "C" fn backend_init(_core: *const SujiCore) {
    eprintln!("[Rust] ready");
}

#[no_mangle]
pub extern "C" fn backend_handle_ipc(request: *const c_char) -> *mut c_char {
    let req_str = unsafe { CStr::from_ptr(request) }.to_str().unwrap_or("");
    let parsed: serde_json::Value = serde_json::from_str(req_str).unwrap_or(json!({}));
    let cmd = parsed.get("cmd").and_then(|v| v.as_str()).unwrap_or("");

    let result = match cmd {
        "ping" => json!({"from": "rust", "msg": "pong"}).to_string(),
        "greet" => {
            let name = parsed.get("name").and_then(|v| v.as_str()).unwrap_or("world");
            json!({"from": "rust", "msg": format!("Hello, {}!", name)}).to_string()
        }
        _ => json!({"from": "rust", "echo": cmd}).to_string(),
    };

    CString::new(result).unwrap().into_raw()
}

#[no_mangle]
pub extern "C" fn backend_free(ptr: *mut c_char) {
    if !ptr.is_null() { unsafe { drop(CString::from_raw(ptr)); } }
}

#[no_mangle]
pub extern "C" fn backend_destroy() { eprintln!("[Rust] bye"); }
