use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::sync::OnceLock;

// pub — `backend_init`이 pub extern이면서 파라미터 타입이 private이면 Rust linter가
// "type `SujiCore` is more private than the item" 경고. public으로 맞춤.
#[repr(C)]
pub struct SujiCore {
    invoke: extern "C" fn(*const c_char, *const c_char) -> *const c_char,
    free: extern "C" fn(*const c_char),
    emit: extern "C" fn(*const c_char, *const c_char),
    on: extern "C" fn(*const c_char, Option<extern "C" fn(*const c_char, *const c_char, *mut std::os::raw::c_void)>, *mut std::os::raw::c_void) -> u64,
    off: extern "C" fn(u64),
    register: extern "C" fn(*const c_char),
    get_io: extern "C" fn() -> *const std::os::raw::c_void,
    quit: extern "C" fn(),
    platform: extern "C" fn() -> *const c_char,
}

extern "C" fn on_window_all_closed(
    _ch: *const c_char,
    _data: *const c_char,
    _arg: *mut std::os::raw::c_void,
) {
    let core = match CORE.get() { Some(c) => c, None => return };
    let p_ptr = (core.platform)();
    let p = if p_ptr.is_null() { "unknown" } else {
        unsafe { CStr::from_ptr(p_ptr) }.to_str().unwrap_or("unknown")
    };
    eprintln!("[Rust] window-all-closed received (platform={})", p);
    if p != "macos" {
        eprintln!("[Rust] non-macOS → suji quit()");
        (core.quit)();
    }
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
        for name in &["ping", "greet", "call_go", "collab", "emit_event", "rust-stress", "rust-thread-node"] {
            let ch = CString::new(*name).unwrap();
            (core_ref.register)(ch.as_ptr());
        }
        // window:all-closed 리스너 — Electron 패턴
        let ev = CString::new("window:all-closed").unwrap();
        (core_ref.on)(ev.as_ptr(), Some(on_window_all_closed), std::ptr::null_mut());
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

    // 재진입 경로: 이미 tokio runtime thread 위에 있으면 block_on 재호출은 panic.
    // 체인에서 Rust → Go → Node → ... → Rust 로 돌아올 때 발생.
    // rust-stress는 동기 로직이라 block_on 없이 직접 처리.
    // 별도 OS 스레드에서 Node 재진입 호출 — thread_local g_in_sync_invoke가 false인 경로
    // 기술 부채 C (다른 스레드 재진입 deadlock) 재현 및 수정 검증용.
    // 구조: Node main thread가 js_suji_invoke_sync("rust", ...) 로 block 중.
    //       Rust는 std::thread::spawn으로 sub-thread 생성, 거기서 core.invoke("node", ...) 호출.
    //       Sub-thread는 Node main이 queue를 처리해주기를 기다린다.
    if cmd == "rust-thread-node" {
        let result = std::thread::spawn(|| {
            let core = CORE.get().unwrap();
            let name = CString::new("node").unwrap();
            let req = CString::new(r#"{"cmd":"node-ping"}"#).unwrap();
            let resp = (core.invoke)(name.as_ptr(), req.as_ptr());
            let out = if resp.is_null() {
                String::from("null")
            } else {
                unsafe { CStr::from_ptr(resp) }.to_string_lossy().to_string()
            };
            // core.free는 Suji 코어 소유 메모리 해제 (length-prefix header)
            if !resp.is_null() {
                (core.free)(resp);
            }
            out
        })
        .join()
        .unwrap_or_else(|_| "thread panic".into());
        let wrapped = json!({"from":"rust","node_resp":result}).to_string();
        return CString::new(wrapped).unwrap().into_raw();
    }

    if cmd == "rust-stress" {
        let depth = parsed.get("depth").and_then(|v| v.as_i64()).unwrap_or(0);
        let result = if depth <= 0 {
            json!({"base":"rust","remaining":0}).to_string()
        } else {
            let next_req = json!({"cmd":"go-stress","depth":depth-1}).to_string();
            let core = CORE.get().unwrap();
            let name = CString::new("go").unwrap();
            let req_c = CString::new(next_req).unwrap();
            let resp_ptr = (core.invoke)(name.as_ptr(), req_c.as_ptr());
            let child: Value = if resp_ptr.is_null() {
                json!({"error":"go invoke failed"})
            } else {
                let s = unsafe { CStr::from_ptr(resp_ptr) }.to_string_lossy().to_string();
                serde_json::from_str(&s).unwrap_or(json!({"raw":s}))
            };
            json!({"at":"rust","child":child}).to_string()
        };
        return CString::new(result).unwrap().into_raw();
    }

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
