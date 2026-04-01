//! # suji-plugin-state
//!
//! State plugin wrapper for Suji Rust backends.
//! All calls go through `suji::invoke("state:*", ...)`.
//!
//! ```rust
//! use suji_plugin_state as state;
//!
//! state::set("user", r#""yoon""#);
//! let val = state::get("user");
//! state::delete("user");
//! let keys = state::keys();
//! ```

/// Get a value by key. Returns the raw JSON value string, or None if not found.
pub fn get(key: &str) -> Option<String> {
    let req = serde_json::json!({"cmd": "state:get", "key": key}).to_string();
    let resp = suji::invoke("state", &req)?;
    let parsed: serde_json::Value = serde_json::from_str(&resp).ok()?;
    let value = parsed.get("result")?.get("value")?;
    if value.is_null() {
        return None;
    }
    Some(value.to_string())
}

/// Set a key to a raw JSON value.
/// Value should be a valid JSON fragment: `"\"hello\""`, `"42"`, `"true"`, etc.
pub fn set(key: &str, value: &str) {
    let val: serde_json::Value = serde_json::from_str(value).unwrap_or(serde_json::Value::Null);
    let req = serde_json::json!({"cmd": "state:set", "key": key, "value": val}).to_string();
    suji::invoke("state", &req);
}

/// Delete a key.
pub fn delete(key: &str) {
    let req = serde_json::json!({"cmd": "state:delete", "key": key}).to_string();
    suji::invoke("state", &req);
}

/// Get all keys.
pub fn keys() -> Vec<String> {
    let req = r#"{"cmd":"state:keys"}"#;
    let resp = match suji::invoke("state", req) {
        Some(r) => r,
        None => return vec![],
    };
    let parsed: serde_json::Value = match serde_json::from_str(&resp) {
        Ok(v) => v,
        Err(_) => return vec![],
    };
    let keys_val = parsed
        .get("result")
        .and_then(|r| r.get("keys"))
        .and_then(|k| k.as_array());
    match keys_val {
        Some(arr) => arr.iter().filter_map(|v| v.as_str().map(String::from)).collect(),
        None => vec![],
    }
}

/// Clear all state.
pub fn clear() {
    let req = r#"{"cmd":"state:clear"}"#;
    suji::invoke("state", req);
}

/// Watch a key for changes via EventBus.
/// Returns a listener ID that can be passed to `suji::off()` to unsubscribe.
pub fn watch(
    key: &str,
    callback: extern "C" fn(*const std::os::raw::c_char, *const std::os::raw::c_char, *mut std::os::raw::c_void),
    arg: *mut std::os::raw::c_void,
) -> u64 {
    let channel = format!("state:{}", key);
    suji::on(&channel, callback, arg)
}
