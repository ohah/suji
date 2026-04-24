//! 테스트 전용 백엔드: suji-plugin-state (Rust 래퍼)가 실제로 state dylib로
//! invoke를 라우팅하는지 end-to-end 검증용. 통합 테스트에서만 로드.

use serde_json::{json, Value};
use suji_plugin_state as state;

fn rust_state_set(req: Value) -> Value {
    let key = req.get("key").and_then(|v| v.as_str()).unwrap_or("");
    // value는 JSON 프래그먼트 문자열을 그대로 전달 (래퍼가 파싱)
    let raw = req
        .get("value")
        .map(|v| v.to_string())
        .unwrap_or_else(|| "null".into());
    state::set(key, &raw);
    json!({"ok": true})
}

fn rust_state_get(req: Value) -> Value {
    let key = req.get("key").and_then(|v| v.as_str()).unwrap_or("");
    json!({"value": state::get(key)})
}

fn rust_state_delete(req: Value) -> Value {
    let key = req.get("key").and_then(|v| v.as_str()).unwrap_or("");
    state::delete(key);
    json!({"ok": true})
}

fn rust_state_keys(_req: Value) -> Value {
    json!({"keys": state::keys()})
}

fn rust_state_clear(_req: Value) -> Value {
    state::clear();
    json!({"ok": true})
}

suji::export_handlers!(
    rust_state_set,
    rust_state_get,
    rust_state_delete,
    rust_state_keys,
    rust_state_clear,
);
