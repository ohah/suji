use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::sync::OnceLock;

#[repr(C)]
struct SujiCore {
    invoke: extern "C" fn(*const c_char, *const c_char) -> *const c_char,
    free: extern "C" fn(*const c_char),
    emit: extern "C" fn(*const c_char, *const c_char),
    on: extern "C" fn(*const c_char, Option<extern "C" fn(*const c_char, *const c_char, *mut std::os::raw::c_void)>, *mut std::os::raw::c_void) -> u64,
    off: extern "C" fn(u64),
    register: extern "C" fn(*const c_char),
}
unsafe impl Send for SujiCore {}
unsafe impl Sync for SujiCore {}

static CORE: OnceLock<&'static SujiCore> = OnceLock::new();
static RT: OnceLock<tokio::runtime::Runtime> = OnceLock::new();

fn call_go(request: &str) -> String {
    let core = match CORE.get() { Some(c) => c, None => return "{}".into() };
    let name = CString::new("go").unwrap();
    let req = CString::new(request).unwrap();
    let resp = (core.invoke)(name.as_ptr(), req.as_ptr());
    if resp.is_null() { return "{}".into(); }
    unsafe { CStr::from_ptr(resp) }.to_string_lossy().to_string()
}

#[no_mangle]
pub extern "C" fn backend_init(core: *const SujiCore) {
    if !core.is_null() {
        let core_ref: &'static SujiCore = unsafe { std::mem::transmute(&*core) };
        let _ = CORE.set(core_ref);
        // 핸들러 채널 등록
        for name in &["ping", "greet", "call_go", "collab", "emit_event"] {
            let ch = CString::new(*name).unwrap();
            (core_ref.register)(ch.as_ptr());
        }
    }
    RT.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2).enable_all().build().unwrap()
    });
    eprintln!("[Rust] ready");
}

#[no_mangle]
pub extern "C" fn backend_handle_ipc(request: *const c_char) -> *mut c_char {
    let req_str = unsafe { CStr::from_ptr(request) }.to_str().unwrap_or("");
    let parsed: Value = serde_json::from_str(req_str).unwrap_or(json!({"cmd": req_str}));
    let cmd = parsed.get("cmd").and_then(|v| v.as_str()).unwrap_or("");

    let rt = RT.get().unwrap();
    let result = rt.block_on(async {
        match cmd {
            "ping" => json!({"from":"rust","msg":"pong"}).to_string(),

            // Rust에서 Go 호출
            "call_go" => {
                let go_resp = call_go(r#"{"cmd":"ping"}"#);
                format!(r#"{{"from":"rust","go_said":{}}}"#, go_resp)
            }

            // 협업: Rust가 해싱, Go가 통계
            "collab" => {
                let data = parsed.get("data").and_then(|v| v.as_str()).unwrap_or("hello");
                let data_owned = data.to_string();

                // tokio로 해싱
                let hash = tokio::task::spawn_blocking(move || {
                    let mut h = Sha256::new();
                    h.update(data_owned.as_bytes());
                    format!("{:x}", h.finalize())
                }).await.unwrap_or_default();

                // Go에 통계 요청
                let go_resp = call_go(&format!(r#"{{"cmd":"stats_for_rust","data":"{}"}}"#, data));

                format!(r#"{{"from":"rust","hash":"{}","go_stats":{}}}"#, hash, go_resp)
            }

            // 이벤트 발신 (send)
            "emit_event" => {
                let channel = parsed.get("channel").and_then(|v| v.as_str()).unwrap_or("rust-event");
                let msg = parsed.get("msg").and_then(|v| v.as_str()).unwrap_or("hello from rust");
                if let Some(core) = CORE.get() {
                    let c_ch = CString::new(channel).unwrap();
                    let data = format!(r#"{{"from":"rust","msg":"{}"}}"#, msg);
                    let c_data = CString::new(data).unwrap();
                    (core.emit)(c_ch.as_ptr(), c_data.as_ptr());
                }
                json!({"from":"rust","cmd":"emit_event","sent_to":channel}).to_string()
            }

            _ => json!({"from":"rust","echo":cmd}).to_string(),
        }
    });

    CString::new(result).unwrap().into_raw()
}

#[no_mangle]
pub extern "C" fn backend_free(ptr: *mut c_char) {
    if !ptr.is_null() { unsafe { drop(CString::from_raw(ptr)); } }
}

#[no_mangle]
pub extern "C" fn backend_destroy() { eprintln!("[Rust] bye"); }
