use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::OnceLock;
use tokio::sync::RwLock;

/// Zig 코어가 제공하는 API (다른 백엔드 호출용)
#[repr(C)]
struct SujiCore {
    invoke: extern "C" fn(*const c_char, *const c_char) -> *const c_char,
    free: extern "C" fn(*const c_char),
}

unsafe impl Send for SujiCore {}
unsafe impl Sync for SujiCore {}

static TOKIO_RT: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
static CALL_COUNT: AtomicU64 = AtomicU64::new(0);
static SHARED_STATE: OnceLock<RwLock<Vec<String>>> = OnceLock::new();
static CORE: OnceLock<&'static SujiCore> = OnceLock::new();

fn get_runtime() -> &'static tokio::runtime::Runtime {
    TOKIO_RT.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(4)
            .enable_all()
            .build()
            .expect("Failed to create tokio runtime")
    })
}

fn get_state() -> &'static RwLock<Vec<String>> {
    SHARED_STATE.get_or_init(|| RwLock::new(Vec::new()))
}

/// 다른 백엔드 호출 헬퍼
fn call_backend(name: &str, request: &str) -> Option<String> {
    let core = CORE.get()?;
    let c_name = CString::new(name).ok()?;
    let c_req = CString::new(request).ok()?;
    let resp_ptr = (core.invoke)(c_name.as_ptr(), c_req.as_ptr());
    if resp_ptr.is_null() {
        return None;
    }
    let result = unsafe { CStr::from_ptr(resp_ptr) }
        .to_str()
        .ok()?
        .to_string();
    // Note: core.free should be called but current impl is no-op
    // (core.free)(resp_ptr);
    Some(result)
}

#[no_mangle]
pub extern "C" fn backend_init(core: *const SujiCore) {
    if !core.is_null() {
        let core_ref = unsafe { &*core };
        // 안전하게 static으로 변환 (코어가 앱 수명 동안 유지되므로)
        let core_static: &'static SujiCore = unsafe { std::mem::transmute(core_ref) };
        let _ = CORE.set(core_static);
    }
    get_runtime();
    get_state();
    eprintln!("[Rust] initialized (tokio 4 threads, core API connected)");
}

#[no_mangle]
pub extern "C" fn backend_handle_ipc(request: *const c_char) -> *mut c_char {
    let req_str = unsafe { CStr::from_ptr(request) }.to_str().unwrap_or("");
    let count = CALL_COUNT.fetch_add(1, Ordering::Relaxed);

    let parsed: Value = serde_json::from_str(req_str).unwrap_or(json!({"cmd": req_str}));
    let cmd = parsed
        .get("cmd")
        .and_then(|v| v.as_str())
        .unwrap_or(req_str);

    let rt = get_runtime();
    let result = rt.block_on(async {
        match cmd {
            "ping" => json!({"from": "rust", "msg": "pong", "count": count}).to_string(),

            "async_work" => {
                let (r1, r2, r3) = tokio::join!(
                    async { tokio::time::sleep(std::time::Duration::from_millis(5)).await; "task1" },
                    async { tokio::time::sleep(std::time::Duration::from_millis(3)).await; "task2" },
                    async { tokio::time::sleep(std::time::Duration::from_millis(1)).await; "task3" },
                );
                json!({"from": "rust", "tasks": [r1, r2, r3], "count": count}).to_string()
            }

            "state_write" => {
                let state = get_state();
                let mut w = state.write().await;
                w.push(format!("entry_{}", count));
                json!({"from": "rust", "action": "write", "state_len": w.len(), "count": count}).to_string()
            }

            "state_read" => {
                let state = get_state();
                let r = state.read().await;
                let last = r.last().cloned().unwrap_or_default();
                json!({"from": "rust", "action": "read", "state_len": r.len(), "last": last}).to_string()
            }

            "cpu_heavy" => {
                let data = parsed.get("data").and_then(|v| v.as_str()).unwrap_or("default").to_string();
                let handle = tokio::task::spawn_blocking(move || {
                    let mut hasher = Sha256::new();
                    let mut result = data.as_bytes().to_vec();
                    for _ in 0..1000 {
                        hasher.update(&result);
                        result = hasher.finalize_reset().to_vec();
                    }
                    hex::encode(&result)
                });
                let hash = handle.await.unwrap_or_default();
                json!({"from": "rust", "hash_len": hash.len(), "count": count}).to_string()
            }

            "transform" => {
                let data = parsed.get("data").and_then(|v| v.as_str()).unwrap_or("");
                json!({"from": "rust", "cmd": "transform", "original": data, "result": data.to_uppercase(), "count": count}).to_string()
            }

            "process_and_relay" => {
                let msg = parsed.get("msg").and_then(|v| v.as_str()).unwrap_or("");
                let processed = format!("[rust processed: {}]", msg);
                json!({"from": "rust", "cmd": "process_and_relay", "processed": processed, "count": count}).to_string()
            }

            // Rust에서 Go 호출 (크로스 백엔드)
            "call_go" => {
                let go_request = parsed.get("go_request").and_then(|v| v.as_str()).unwrap_or(r#"{"cmd":"ping"}"#);
                match call_backend("go", go_request) {
                    Some(go_resp) => {
                        json!({"from": "rust", "cmd": "call_go", "go_response": serde_json::from_str::<Value>(&go_resp).unwrap_or(json!(go_resp)), "count": count}).to_string()
                    }
                    None => json!({"from": "rust", "error": "failed to call go"}).to_string(),
                }
            }

            // Rust tokio + Go goroutine 협업
            "collab" => {
                let data = parsed.get("data").and_then(|v| v.as_str()).unwrap_or("hello world").to_string();

                // 1. Rust에서 SHA256 해싱 (tokio spawn_blocking)
                let data_clone = data.clone();
                let hash_handle = tokio::task::spawn_blocking(move || {
                    let mut hasher = Sha256::new();
                    hasher.update(data_clone.as_bytes());
                    hex::encode(&hasher.finalize())
                });
                let hash = hash_handle.await.unwrap_or_default();

                // 2. Go에 통계 계산 요청 (크로스 백엔드)
                let go_req = format!(r#"{{"cmd":"stats_for_rust","data":"{}"}}"#, data);
                let go_resp = call_backend("go", &go_req).unwrap_or_default();

                json!({
                    "from": "rust",
                    "cmd": "collab",
                    "rust_hash": hash,
                    "go_stats": serde_json::from_str::<Value>(&go_resp).unwrap_or(json!(go_resp)),
                    "count": count
                }).to_string()
            }

            _ => json!({"from": "rust", "echo": cmd, "count": count}).to_string(),
        }
    });

    CString::new(result).unwrap().into_raw()
}

#[no_mangle]
pub extern "C" fn backend_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        unsafe { drop(CString::from_raw(ptr)); }
    }
}

#[no_mangle]
pub extern "C" fn backend_destroy() {
    let count = CALL_COUNT.load(Ordering::Relaxed);
    eprintln!("[Rust] destroyed (total calls: {})", count);
}

mod hex {
    pub fn encode(data: &[u8]) -> String {
        data.iter().map(|b| format!("{:02x}", b)).collect()
    }
}
